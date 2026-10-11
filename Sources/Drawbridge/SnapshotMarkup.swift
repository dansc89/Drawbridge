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
            if annotation is DrawbridgeSnapshotAnnotation || annotation is DrawbridgeShapeAnnotation || annotation is DrawbridgePolygonAnnotation || annotation is DrawbridgeMeasuredPathAnnotation {
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

/// Draw the captured fragment directly while editing. The incremental writer
/// installs a standard Stamp appearance for saved PDFs and other readers.
@MainActor enum SnapshotStampFactory {
    static func make(payload: SnapshotPayload, bounds: CGRect, rotation: Int, style: SnapshotStyle = SnapshotStyle()) throws -> PDFAnnotation {
        let data = try SnapshotFilterRenderer.filtered(payload.data, style: style)
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              document.page(at: 1) != nil else { throw CocoaError(.fileReadCorruptFile) }
        return DrawbridgeSnapshotAnnotation(bounds: bounds, document: document, rotation: rotation, style: style)
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

/// Live rendering uses the same fragment and transform as the saved appearance,
/// without PDFKit's imported Stamp appearance cache.
final class DrawbridgeSnapshotAnnotation: PDFAnnotation {
    private let fragment: CGPDFDocument?
    private let captureRotation: Int
    private let style: SnapshotStyle
    var isRetired = false

    init(bounds: CGRect, document: CGPDFDocument, rotation: Int, style: SnapshotStyle) {
        fragment = document
        captureRotation = rotation
        self.style = style
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        color = .clear
        shouldDisplay = true
        shouldPrint = true
    }

    required init?(coder: NSCoder) {
        fragment = nil
        captureRotation = 0
        style = SnapshotStyle()
        super.init(coder: coder)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard !isRetired, shouldDisplay else { return }
        guard let source = fragment?.page(at: 1) else {
            super.draw(with: box, in: context)
            return
        }
        context.saveGState()
        context.setAlpha(style.opacity)
        context.setBlendMode(style.overlay ? .multiply : .normal)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        let pageBounds = page?.bounds(for: box) ?? .zero
        // PDFView supplies page-space contexts. Whole-page PDFKit previews instead
        // draw custom annotations in display space; that entry point scopes this flag.
        if SnapshotPageRendering.isPreview {
            context.concatenate(page?.transform(for: box) ?? .identity)
        } else {
            context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
        }
        context.concatenate(SnapshotPayload.transform(size: source.getBoxRect(.mediaBox).size, bounds: bounds, rotation: captureRotation))
        context.drawPDFPage(source)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

/// Keep PDFKit's whole-page preview contract separate from PDFView's page-space
/// annotation contract. Thread-local scope also covers nested/background previews.
enum SnapshotPageRendering {
    private static let key = "DrawbridgeSnapshotPagePreview"
    static var isPreview: Bool { (Thread.current.threadDictionary[key] as? Int ?? 0) > 0 }
    static func preview<T>(_ body: () -> T) -> T {
        let depth = Thread.current.threadDictionary[key] as? Int ?? 0
        Thread.current.threadDictionary[key] = depth + 1
        defer {
            if depth == 0 { Thread.current.threadDictionary.removeObject(forKey: key) }
            else { Thread.current.threadDictionary[key] = depth }
        }
        return body()
    }
}

extension PDFPage {
    func drawbridgeThumbnail(of size: NSSize, for box: PDFDisplayBox) -> NSImage {
        SnapshotPageRendering.preview { thumbnail(of: size, for: box) }
    }
    func drawbridgeDraw(with box: PDFDisplayBox, to context: CGContext) {
        SnapshotPageRendering.preview { draw(with: box, to: context) }
    }
}
