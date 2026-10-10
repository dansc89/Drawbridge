import AppKit
import PDFKit
import CryptoKit

enum SnapshotError: LocalizedError {
    case unsupportedPageUnits
    var errorDescription: String? { "This page uses nonstandard PDF units. Snapshot cannot preserve its physical size safely." }
}

/// A portable vector PDF, never a pointer to an external temporary file.
struct SnapshotPayload: Sendable {
    static let key = PDFAnnotationKey(rawValue: "DrawbridgeSnapshotPDF")
    static let clipboardType = NSPasteboard.PasteboardType("com.drawbridge.vector-snapshot")
    static let maximumBytes = 32 * 1024 * 1024
    let data: Data
    var placement: Placement? = nil
    var style: SnapshotStyle = SnapshotStyle()
    struct Placement: Codable, Sendable { var x: Double; var y: Double; var width: Double; var height: Double; var rotation: Int }
    static let placementType = NSPasteboard.PasteboardType("com.drawbridge.snapshot-placement")
    static let styleType = NSPasteboard.PasteboardType("com.drawbridge.snapshot-style")
    var page: CGPDFPage? {
        guard !data.isEmpty, data.count <= Self.maximumBytes,
              let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider), pdf.numberOfPages == 1 else { return nil }
        guard let page = pdf.page(at: 1) else { return nil }
        let size = page.getBoxRect(.mediaBox).size
        guard size.width.isFinite, size.height.isFinite, (2...14400).contains(size.width), (2...14400).contains(size.height) else { return nil }
        return page
    }
    var size: CGSize? { page?.getBoxRect(.mediaBox).size }
    static func read(_ annotation: PDFAnnotation) -> SnapshotPayload? {
        guard let string = annotation.value(forAnnotationKey: key) as? String,
              string.utf8.count <= maximumBytes * 2, let data = Data(base64Encoded: string) else { return nil }
        var payload = Self(data: data)
        let b = annotation.bounds
        payload.placement = Placement(x: b.minX, y: b.minY, width: b.width, height: b.height, rotation: annotation.page?.rotation ?? 0)
        payload.style = SnapshotStyle.read(annotation)
        return payload.page == nil ? nil : payload
    }
    @MainActor static func clipboard() -> SnapshotPayload? {
        guard let data = NSPasteboard.general.data(forType: clipboardType), data.count <= maximumBytes else { return nil }
        var payload = Self(data: data)
        if let data = NSPasteboard.general.data(forType: placementType), data.count < 2048 { payload.placement = try? JSONDecoder().decode(Placement.self, from: data) }
        if let data = NSPasteboard.general.data(forType: styleType), data.count < 2048, let style = try? JSONDecoder().decode(SnapshotStyle.self, from: data), style.isValid { payload.style = style }
        return payload.page == nil ? nil : payload
    }
    @MainActor func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: Self.clipboardType)
        NSPasteboard.general.setData(data, forType: .pdf)
        if let placement, let encoded = try? JSONEncoder().encode(placement) { NSPasteboard.general.setData(encoded, forType: Self.placementType) }
        NSPasteboard.general.setString(style.json, forType: Self.styleType)
    }
    @MainActor static func capture(page: PDFPage, points: [CGPoint]) throws -> Self {
        guard points.count >= 3, points.count <= 512, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              page.document?.allowsCopying != false, let source = page.pageRef else { throw CocoaError(.fileReadNoPermission) }
        guard MeasurementMetadata.supportedPage(page) else { throw SnapshotError.unsupportedPageUnits }
        let crop = source.getBoxRect(.cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        guard [0,90,180,270].contains(rotation) else { throw CocoaError(.fileReadCorruptFile) }
        let displaySize = rotation % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
        let transform = source.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: displaySize), rotate: 0, preserveAspectRatio: true)
        let polygon = points.map { $0.applying(transform) }
        let minX = polygon.map(\.x).min()!, minY = polygon.map(\.y).min()!
        let maxX = polygon.map(\.x).max()!, maxY = polygon.map(\.y).max()!
        var media = CGRect(x: 0, y: 0, width: maxX-minX, height: maxY-minY)
        guard media.width >= 2, media.height >= 2 else { throw CocoaError(.fileReadCorruptFile) }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        let path = CGMutablePath()
        for (index, p) in polygon.enumerated() {
            let local = CGPoint(x: p.x-minX, y: p.y-minY)
            if index == 0 { path.move(to: local) } else { path.addLine(to: local) }
        }
        path.closeSubpath(); context.addPath(path); context.clip()
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(media)
        context.translateBy(x: -minX, y: -minY)
        context.saveGState(); context.concatenate(transform)
        context.drawPDFPage(source); context.restoreGState()
        // The source's current annotations belong in the captured appearance too.
        let origin = page.bounds(for: .mediaBox).origin
        for annotation in page.annotations where annotation.shouldDisplay && annotation.type != "Link" {
            context.saveGState()
            if annotation is DrawbridgePolygonAnnotation || annotation is DrawbridgeMeasuredPathAnnotation {
                context.concatenate(transform); context.translateBy(x: origin.x, y: origin.y)
                annotation.draw(with: .mediaBox, in: context)
            } else { annotation.draw(with: .cropBox, in: context) }
            context.restoreGState()
        }
        context.endPDFPage(); context.closePDF()
        var payload = Self(data: output as Data)
        let xs = points.map(\.x), ys = points.map(\.y)
        payload.placement = Placement(x: xs.min()!, y: ys.min()!, width: xs.max()!-xs.min()!, height: ys.max()!-ys.min()!, rotation: rotation)
        guard payload.page != nil else { throw CocoaError(.fileWriteUnknown) }
        return payload
    }
    /// Counter-rotate the pasted fragment so it keeps the orientation the user captured.
    static func transform(size: CGSize, bounds: CGRect, rotation: Int) -> CGAffineTransform {
        switch ((rotation % 360) + 360) % 360 {
        case 90: return CGAffineTransform(a: 0, b: bounds.height/size.width, c: -bounds.width/size.height, d: 0, tx: bounds.maxX, ty: bounds.minY)
        case 180: return CGAffineTransform(a: -bounds.width/size.width, b: 0, c: 0, d: -bounds.height/size.height, tx: bounds.maxX, ty: bounds.maxY)
        case 270: return CGAffineTransform(a: 0, b: -bounds.height/size.width, c: bounds.width/size.height, d: 0, tx: bounds.minX, ty: bounds.maxY)
        default: return CGAffineTransform(a: bounds.width/size.width, b: 0, c: 0, d: bounds.height/size.height, tx: bounds.minX, ty: bounds.minY)
        }
    }
}

/// Use PDFKit's standard Stamp appearance for both the live view and other readers.
/// Custom drawing contexts differ between PDFView and PDFPage thumbnails on rotated pages.
@MainActor enum SnapshotStampFactory {
    private static let cache = NSCache<NSString, NSData>()
    private static let backing = NSMapTable<PDFAnnotation, PDFDocument>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    static func make(payload: SnapshotPayload, bounds: CGRect, rotation: Int, style: SnapshotStyle = SnapshotStyle()) throws -> PDFAnnotation {
        cache.totalCostLimit = 64 * 1024 * 1024
        let digest = SHA256.hash(data:payload.data).map { String(format:"%02x", $0) }.joined()
        let key = (digest + ":\(rotation):\(bounds.width):\(bounds.height):" + style.json) as NSString
        let data: Data
        if let cached = cache.object(forKey: key) { data = cached as Data }
        else {
            var objects: [String:Any] = [:], next = 5, forms: [Data:String] = [:]
            let appearance = try SnapshotAppearance.install(data: payload.data, bounds: bounds, rotation: rotation, style: style, objects: &objects, next: &next, forms: &forms)
            let ap = "\(next) 0 R"; objects["obj:" + ap] = appearance; next += 1
            objects["obj:1 0 R"] = ["value": ["/Type":"/Catalog", "/Pages":"2 0 R"]]
            objects["obj:2 0 R"] = ["value": ["/Type":"/Pages", "/Kids":["3 0 R"], "/Count":1]]
            objects["obj:3 0 R"] = ["value": ["/Type":"/Page", "/Parent":"2 0 R", "/MediaBox":[0,0,bounds.width,bounds.height], "/Annots":["4 0 R"]]]
            objects["obj:4 0 R"] = ["value": ["/Type":"/Annot", "/Subtype":"/Stamp", "/Rect":[0,0,bounds.width,bounds.height], "/AP":["/N":ap], "/F":4, "/C":[0,0,0], "/Border":[0,0,2]]]
            var output = Data("%PDF-1.7\n".utf8), offsets = [0]
            for number in 1..<next {
                offsets.append(output.count)
                let object = objects["obj:\(number) 0 R"] as! [String:Any]
                output.append(Data("\(number) 0 obj\n".utf8))
                if let value = object["value"] { output.append(Data(try PDFIncrementalMarkupPatch.encode(value).utf8)) }
                else if let stream = object["stream"] as? [String:Any], var dict = stream["dict"] as? [String:Any], let encoded = stream["data"] as? String, let bytes = Data(base64Encoded:encoded) {
                    dict["/Length"] = bytes.count
                    output.append(Data(try PDFIncrementalMarkupPatch.encode(dict).utf8)); output.append(Data("\nstream\n".utf8)); output.append(bytes); output.append(Data("\nendstream".utf8))
                } else { throw CocoaError(.fileReadCorruptFile) }
                output.append(Data("\nendobj\n".utf8))
            }
            let xref = output.count
            output.append(Data("xref\n0 \(next)\n0000000000 65535 f \n".utf8))
            for offset in offsets.dropFirst() { output.append(Data(String(format:"%010d 00000 n \n",offset).utf8)) }
            output.append(Data("trailer\n<< /Size \(next) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
            data = output; cache.setObject(data as NSData, forKey:key, cost:data.count + key.length*2)
        }
        guard let document = PDFDocument(data:data), let page = document.page(at:0), let annotation = page.annotations.first else { throw CocoaError(.fileReadCorruptFile) }
        backing.setObject(document, forKey: annotation)
        page.removeAnnotation(annotation); annotation.bounds = bounds
        return annotation
    }
}

/// Copy only the fragment's reachable resource objects into the incremental save.
/// No source page, catalog, filesystem path, or external reference is retained.
enum SnapshotAppearance {
    static func install(data originalData: Data, bounds: CGRect, rotation: Int, style: SnapshotStyle = SnapshotStyle(), objects: inout [String:Any], next: inout Int, forms: inout [Data:String]) throws -> [String:Any] {
        let data = try SnapshotFilterRenderer.filtered(originalData, style: style)
        guard SnapshotPayload(data: data).page != nil, let executable = PDFTKBookmarkWriter.executableURL() else { throw CocoaError(.fileReadCorruptFile) }
        if let fragmentRef = forms[data], let size = SnapshotPayload(data: data).size { return wrapper(fragmentRef: fragmentRef, size: size, bounds: bounds, rotation: rotation, style: style) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeSnapshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("fragment.pdf"), output = directory.appendingPathComponent("fragment.json")
        try data.write(to: input)
        guard PDFTKBookmarkWriter.run(executable, arguments: ["--json=2", "--json-stream-data=inline", "--decode-level=generalized", input.path, output.path]),
              ((try? output.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? Int.max) <= 128 * 1024 * 1024,
              let json = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String:Any],
              let tables = json["qpdf"] as? [[String:Any]], tables.count == 2,
              let pages = json["pages"] as? [[String:Any]], pages.count == 1,
              let reference = pages[0]["object"] as? String,
              let pageObject = tables[1]["obj:" + reference] as? [String:Any], let page = pageObject["value"] as? [String:Any] else { throw CocoaError(.fileReadCorruptFile) }
        let sourceObjects = tables[1]
        var mapping: [String:String] = [:]
        func remap(_ value: Any) throws -> Any {
            if let ref = value as? String, ref.range(of: #"^\d+ \d+ R$"#, options: .regularExpression) != nil {
                if let mapped = mapping[ref] { return mapped }
                guard let object = sourceObjects["obj:" + ref] else { throw CocoaError(.fileReadCorruptFile) }
                let mapped = "\(next) 0 R"; next += 1; mapping[ref] = mapped
                objects["obj:" + mapped] = try remap(object)
                return mapped
            }
            if let array = value as? [Any] { return try array.map(remap) }
            if let dictionary = value as? [String:Any] {
                var result = try dictionary.mapValues(remap)
                if var stream = result["stream"] as? [String:Any], var dict = stream["dict"] as? [String:Any] {
                    dict["/DrawbridgeRectangleAppearance"] = true
                    stream["dict"] = dict; result["stream"] = stream
                }
                return result
            }
            return value
        }
        let contentRefs = (page["/Contents"] as? [String]) ?? (page["/Contents"] as? String).map { [$0] } ?? []
        var content = Data()
        for ref in contentRefs {
            guard let object = sourceObjects["obj:" + ref] as? [String:Any], let stream = object["stream"] as? [String:Any],
                  let dict = stream["dict"] as? [String:Any], dict["/Filter"] == nil,
                  let encoded = stream["data"] as? String, let bytes = Data(base64Encoded: encoded) else { throw CocoaError(.fileReadCorruptFile) }
            content.append(bytes); content.append(10)
        }
        let size = SnapshotPayload(data: data).size!
        let fragmentRef = "\(next) 0 R"; next += 1
        let resources = try remap(page["/Resources"] ?? [String:Any]())
        objects["obj:" + fragmentRef] = ["stream": ["dict": ["/Type":"/XObject", "/Subtype":"/Form", "/BBox":[0,0,size.width,size.height], "/Group":["/S":"/Transparency", "/CS":"/DeviceRGB", "/I":true], "/Resources":resources, "/DrawbridgeRectangleAppearance":true], "data":content.base64EncodedString()]]
        forms[data] = fragmentRef
        return wrapper(fragmentRef: fragmentRef, size: size, bounds: bounds, rotation: rotation, style: style)
    }
    private static func wrapper(fragmentRef: String, size: CGSize, bounds: CGRect, rotation: Int, style: SnapshotStyle) -> [String:Any] {
        let t = SnapshotPayload.transform(size: size, bounds: CGRect(origin: .zero, size: bounds.size), rotation: rotation)
        let drawing = "q /SnapshotGS gs \(t.a) \(t.b) \(t.c) \(t.d) \(t.tx) \(t.ty) cm /Snapshot Do Q"
        return ["stream":["dict":["/Type":"/XObject", "/Subtype":"/Form", "/BBox":[0,0,bounds.width,bounds.height], "/Resources":["/XObject":["/Snapshot":fragmentRef], "/ExtGState":["/SnapshotGS":["/Type":"/ExtGState", "/ca":style.opacity, "/CA":style.opacity, "/BM":style.overlay ? "/Multiply" : "/Normal"]]], "/DrawbridgeRectangleAppearance":true], "data":Data(drawing.utf8).base64EncodedString()]]
    }
}
