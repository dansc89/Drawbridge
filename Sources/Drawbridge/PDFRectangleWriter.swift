import Foundation
import PDFKit

/// New markup saves never invoke PDFKit's document renderer. Annotation appearances
/// are portable Form XObjects; unchanged page content/resources are verified before commit.
enum PDFRectangleWriter {
    static func write(document: PDFDocument, source: URL, destination: URL,
                      pageLabels: [Int: String], records: [RectangleMarkupRecord], expectedSourceStamp: PDFMarkupSourceStamp? = nil) -> Bool {
        guard let executable = PDFTKBookmarkWriter.executableURL(), records.allSatisfy(\.isValid),
              Set(records.map(\.id)).count == records.count else { return false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeRectangleSave-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch { return false }
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            if let expectedSourceStamp, PDFMarkupSourceStamp.read(source) != expectedSourceStamp { return false }
            let original = try Data(contentsOf: source)
            let input = directory.appendingPathComponent("input.pdf")
            try original.write(to: input)
            func read(_ url: URL, _ name: String, decoded: Bool = true) throws -> [String: Any] {
                let json = directory.appendingPathComponent(name)
                guard PDFTKBookmarkWriter.run(executable, arguments: ["--json=2", "--json-stream-data=inline", "--decode-level=\(decoded ? "generalized" : "none")", url.path, json.path]),
                      let result = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
                return result
            }
            let inspected = try read(input, "input.json")
            guard (inspected["encrypt"] as? [String: Any])?["encrypted"] as? Bool != true else { return false }
            let table = try objectTable(inspected)
            guard !table.values.contains(where: { entry in
                let value = (entry as? [String: Any])?["value"] as? [String: Any]
                return value?["/FT"] as? String == "/Sig" || value?["/Type"] as? String == "/Sig"
            }) else { return false }
            let navigation = directory.appendingPathComponent("navigation.pdf")
            guard PDFTKBookmarkWriter.writeNavigation(in: document, sourceURL: input, to: navigation, pageLabels: pageLabels) == .saved else { print("Rectangle writer: navigation failed"); return false }
            let baseline = try read(navigation, "navigation.json")
            let originalHash = try PDFLosslessReducer.semanticHash(removingOwnedRectangles(baseline))
            var json = try read(navigation, "encoded-navigation.json", decoded: false)
            try update(&json, records: records)
            let patch = directory.appendingPathComponent("rectangles.json")
            // Keep original streams in qpdf's input; supply data only for our new appearances.
            var metadata = PDFAnnotationFlattener.metadataJSON(json)
            if var qpdf = metadata["qpdf"] as? [[String: Any]], var objects = qpdf.last,
               let originalObjects = (json["qpdf"] as? [[String: Any]])?.last {
                for (key, entry) in originalObjects {
                    if let stream = (entry as? [String: Any])?["stream"] as? [String: Any],
                       let dict = stream["dict"] as? [String: Any], dict["/DrawbridgeRectangleAppearance"] as? Bool == true {
                        objects[key] = entry
                    }
                }
                qpdf[qpdf.count - 1] = objects; metadata["qpdf"] = qpdf
            }
            try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: patch)
            let candidate = directory.appendingPathComponent("candidate.pdf")
            guard PDFTKBookmarkWriter.run(executable, arguments: [navigation.path, "--stream-data=preserve", "--update-from-json=\(patch.path)", candidate.path]),
                  PDFTKBookmarkWriter.run(executable, arguments: ["--check", candidate.path]) else { return false }
            let written = try read(candidate, "written.json")
            guard try PDFLosslessReducer.semanticHash(removingOwnedRectangles(written)) == originalHash,
                  try ownedRecordsMatch(written, records: records),
                  try Data(contentsOf: source, options: .mappedIfSafe) == original else { print("Rectangle writer: verification failed"); return false }
            let size = try candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= original.count + max(5 * 1024 * 1024, records.count * 4096) else { print("Rectangle writer: size limit \(size) vs \(original.count)"); return false }
            try MainViewController.commitStagedSave(from: candidate, to: destination)
            return true
        } catch { print("Rectangle writer: \(error)"); return false }
    }

    static func removingOwnedRectangles(_ source: [String: Any]) throws -> [String: Any] {
        var json = source; var qpdf = try tableArray(json); var objects = qpdf[1]
        for reference in try pages(json) {
            guard var object = objects["obj:\(reference)"] as? [String: Any], var page = object["value"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            let remaining = annotations(page["/Annots"], objects: objects).filter { !owned($0, objects: objects) }
            if remaining.isEmpty { page.removeValue(forKey: "/Annots") } else { page["/Annots"] = remaining }
            object["value"] = page; objects["obj:\(reference)"] = object
        }
        qpdf[1] = objects; json["qpdf"] = qpdf; return json
    }

    private static func update(_ json: inout [String: Any], records: [RectangleMarkupRecord]) throws {
        var qpdf = try tableArray(json); var objects = qpdf[1]
        var next = (qpdf[0]["maxobjectid"] as? Int ?? 0) + 1
        let references = try pages(json)
        guard records.allSatisfy({ $0.pageIndex < references.count }) else { throw CocoaError(.fileReadCorruptFile) }
        for (index, reference) in references.enumerated() {
            guard var object = objects["obj:\(reference)"] as? [String: Any], var page = object["value"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            var entries = annotations(page["/Annots"], objects: objects).filter { !owned($0, objects: objects) }
            for record in records where record.pageIndex == index {
                let annotationRef = "\(next) 0 R"; next += 1
                let appearanceRef = "\(next) 0 R"; next += 1
                let b = record.bounds
                let drawing = appearanceDrawing(record)
                objects["obj:\(appearanceRef)"] = ["stream": ["dict": ["/Type": "/XObject", "/Subtype": "/Form", "/BBox": [0,0,b.width,b.height], "/Resources": [String:Any](), "/DrawbridgeRectangleAppearance": true], "data": Data(drawing.utf8).base64EncodedString()]]
                var annotation: [String:Any] = ["/Type": "/Annot", "/Subtype": subtype(record.kind), "/Rect": [b.minX,b.minY,b.maxX,b.maxY], "/T": "u:\(record.id)", "/NM": "u:\(record.id)", "/Contents": "u:\(record.kind.rawValue.capitalized)", "/F": 4, "/C": [record.red,record.green,record.blue], "/BS": ["/W":record.lineWidth,"/S":"/S"], "/AP": ["/N":appearanceRef]]
                if let a = record.start, let z = record.end {
                    annotation["/L"] = [a.x,a.y,z.x,z.y]
                    annotation["/LE"] = ["/None",record.kind == .arrow ? "/OpenArrow" : "/None"]
                }
                if record.kind == .polygon {
                    annotation["/Vertices"] = record.vertices.flatMap { [Double($0.x),Double($0.y)] }
                    annotation["/DrawbridgePolylineVertices"] = record.vertices.flatMap { [Double($0.x),Double($0.y)] }
                    if let fill = record.fill { annotation["/IC"] = fill; annotation["/DrawbridgePolygonFill"] = fill }
                }
                if record.kind == .polyline {
                    let values = record.vertices.flatMap { [Double($0.x),Double($0.y)] }
                    annotation["/InkList"] = [values]
                    annotation["/DrawbridgePolylineVertices"] = values
                }
                if record.kind == .text {
                    annotation.removeValue(forKey: "/C")
                    annotation["/DrawbridgeTextColor"] = [record.red,record.green,record.blue]
                    annotation["/Contents"] = "u:" + record.text
                    annotation["/DA"] = "u:/Helv \(record.fontSize) Tf \(record.red) \(record.green) \(record.blue) rg"
                    annotation["/DS"] = "u:font: Helvetica \(record.fontSize)pt; color: rgb(\(Int(record.red*255)),\(Int(record.green*255)),\(Int(record.blue*255)))"
                    annotation["/DR"] = ["/Font":["/Helv":["/Type":"/Font","/Subtype":"/Type1","/BaseFont":"/Helvetica"]]]
                    annotation["/BS"] = ["/W":0]; annotation["/Q"] = 0
                }
                objects["obj:\(annotationRef)"] = ["value": annotation]
                entries.append(annotationRef)
            }
            if entries.isEmpty { page.removeValue(forKey: "/Annots") } else { page["/Annots"] = entries }
            object["value"] = page; objects["obj:\(reference)"] = object
        }
        qpdf[0]["maxobjectid"] = next - 1; qpdf[1] = objects; json["qpdf"] = qpdf
    }

    private static func subtype(_ kind: RectangleMarkupRecord.Kind) -> String {
        switch kind { case .rectangle: return "/Square"; case .ellipse: return "/Circle"; case .line, .arrow: return "/Line"; case .text: return "/FreeText"; case .polyline: return "/Ink"; case .polygon: return "/Polygon" }
    }

    /// Appearance coordinates are local to the annotation; page rotation is untouched.
    private static func appearanceDrawing(_ r: RectangleMarkupRecord) -> String {
        let half = r.lineWidth/2, w = max(0,Double(r.bounds.width)-r.lineWidth), h = max(0,Double(r.bounds.height)-r.lineWidth)
        var path: String
        switch r.kind {
        case .polyline, .polygon:
            path = r.vertices.enumerated().map { i,p in "\(p.x-r.bounds.minX) \(p.y-r.bounds.minY) " + (i == 0 ? "m" : "l") }.joined(separator:" ")
        case .text: return TextMarkupAppearance.drawing(r)
        case .rectangle: path = "\(half) \(half) \(w) \(h) re"
        case .ellipse:
            let cx = Double(r.bounds.width)/2, cy = Double(r.bounds.height)/2, rx = w/2, ry = h/2, k = 0.5522847498307936
            path = "\(cx+rx) \(cy) m \(cx+rx) \(cy+k*ry) \(cx+k*rx) \(cy+ry) \(cx) \(cy+ry) c \(cx-k*rx) \(cy+ry) \(cx-rx) \(cy+k*ry) \(cx-rx) \(cy) c \(cx-rx) \(cy-k*ry) \(cx-k*rx) \(cy-ry) \(cx) \(cy-ry) c \(cx+k*rx) \(cy-ry) \(cx+rx) \(cy-k*ry) \(cx+rx) \(cy) c h"
        case .line, .arrow:
            guard let start = r.start, let end = r.end else { return "" }
            let a = CGPoint(x:start.x-r.bounds.minX,y:start.y-r.bounds.minY), b = CGPoint(x:end.x-r.bounds.minX,y:end.y-r.bounds.minY)
            path = "\(a.x) \(a.y) m \(b.x) \(b.y) l"
            if r.kind == .arrow {
                let angle = atan2(b.y-a.y,b.x-a.x), length = max(8,r.lineWidth*4)
                let left = CGPoint(x:b.x-length*cos(angle-0.5),y:b.y-length*sin(angle-0.5))
                let right = CGPoint(x:b.x-length*cos(angle+0.5),y:b.y-length*sin(angle+0.5))
                path += " \(left.x) \(left.y) m \(b.x) \(b.y) l \(right.x) \(right.y) l"
            }
        }
        if r.kind == .polygon {
            path += " h"
            if let fill = r.fill { return "q \(r.red) \(r.green) \(r.blue) RG \(fill[0]) \(fill[1]) \(fill[2]) rg \(r.lineWidth) w 1 j \(path) B Q\n" }
        }
        return "q \(r.red) \(r.green) \(r.blue) RG \(r.lineWidth) w 1 J 1 j \(path) S Q\n"
    }

    private static func ownedRecordsMatch(_ json: [String: Any], records: [RectangleMarkupRecord]) throws -> Bool {
        let objects = try objectTable(json); let references = try pages(json)
        var found = Set<String>()
        for (index, reference) in references.enumerated() {
            let page = (objects["obj:\(reference)"] as? [String: Any])?["value"] as? [String: Any] ?? [:]
            for entry in annotations(page["/Annots"], objects: objects) where owned(entry, objects: objects) {
                let value = dictionary(entry, objects: objects)
                guard let id = value["/T"] as? String,
                      let expected = records.first(where: { "u:" + $0.id == id && $0.pageIndex == index }),
                      value["/Subtype"] as? String == subtype(expected.kind),
                      let rect = value["/Rect"] as? [Double], rect.count == 4,
                      zip(rect, [expected.bounds.minX,expected.bounds.minY,expected.bounds.maxX,expected.bounds.maxY]).allSatisfy({ abs($0.0 - $0.1) < 0.0001 }),
                      let appearance = (value["/AP"] as? [String: Any])?["/N"] as? String,
                      (objects["obj:\(appearance)"] as? [String: Any])?["stream"] != nil,
                      found.insert(id).inserted else { return false }
                if expected.kind == .polygon {
                    guard value["/Vertices"] as? [Double] == expected.vertices.flatMap({ [Double($0.x),Double($0.y)] }),
                          value["/IC"] as? [Double] == expected.fill else { return false }
                }
                if expected.kind == .polyline {
                    let expectedVertices = expected.vertices.flatMap { [Double($0.x),Double($0.y)] }
                    guard let ink = value["/InkList"] as? [[Double]], ink.count == 1,
                          ink[0].count == expectedVertices.count,
                          zip(ink[0],expectedVertices).allSatisfy({ abs($0.0-$0.1) < 0.0001 }) else { return false }
                }
                if expected.kind == .text && value["/Contents"] as? String != "u:" + expected.text { return false }
                if let a = expected.start, let b = expected.end {
                    guard let endpoints = value["/L"] as? [Double], endpoints.count == 4,
                          zip(endpoints,[a.x,a.y,b.x,b.y]).allSatisfy({ abs($0.0-$0.1) < 0.0001 }),
                          value["/LE"] as? [String] == ["/None",expected.kind == .arrow ? "/OpenArrow" : "/None"] else { return false }
                }
            }
        }
        return found.count == records.count
    }

    private static func tableArray(_ json: [String: Any]) throws -> [[String: Any]] {
        guard let q = json["qpdf"] as? [[String: Any]], q.count == 2 else { throw CocoaError(.fileReadCorruptFile) }; return q
    }
    private static func objectTable(_ json: [String: Any]) throws -> [String: Any] { try tableArray(json)[1] }
    private static func pages(_ json: [String: Any]) throws -> [String] {
        guard let p = json["pages"] as? [[String:Any]] else { throw CocoaError(.fileReadCorruptFile) }; return p.compactMap { $0["object"] as? String }
    }
    private static func dictionary(_ entry: Any, objects: [String:Any]) -> [String:Any] {
        if let ref = entry as? String { return (objects["obj:\(ref)"] as? [String:Any])?["value"] as? [String:Any] ?? [:] }
        return entry as? [String:Any] ?? [:]
    }
    private static func annotations(_ value: Any?, objects: [String:Any]) -> [Any] {
        if let ref = value as? String { return (objects["obj:\(ref)"] as? [String:Any])?["value"] as? [Any] ?? [] }; return value as? [Any] ?? []
    }
    private static func owned(_ entry: Any, objects: [String:Any]) -> Bool {
        let d = dictionary(entry, objects: objects)
        return ["/Square","/Circle","/Line","/FreeText","/Ink","/Polygon"].contains(d["/Subtype"] as? String ?? "") && (d["/T"] as? String)?.hasPrefix("u:" + RectangleMarkupRecord.prefix) == true
    }
}
