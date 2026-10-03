import Foundation
import PDFKit
import CryptoKit

/// Flattens existing appearance streams using qpdf, without a PDFKit redraw or raster export.
/// Interactive/nonvisual annotations are temporarily protected in a reachable catalog entry;
/// this lets qpdf renumber objects normally while retaining their destinations and resources.
enum PDFAnnotationFlattener {
    struct Report: Sendable {
        let flattened: Int
        let retainedMarkups: Int
        let removedSHXComments: Int
        let restoredAnnotations: Int
        init(flattened: Int, retainedMarkups: Int, removedSHXComments: Int, restoredAnnotations: Int = 0) {
            self.flattened = flattened
            self.retainedMarkups = retainedMarkups
            self.removedSHXComments = removedSHXComments
            self.restoredAnnotations = restoredAnnotations
        }
    }
    private static let recoveryKey = "/DrawbridgeUnflattenData"
    private static let marker = "/DrawbridgeFlattenProtectedAnnotations"
    private static let visualTypes: Set<String> = ["/Text", "/FreeText", "/Line", "/Square", "/Circle", "/Polygon", "/PolyLine", "/Highlight", "/Underline", "/Squiggly", "/StrikeOut", "/Stamp", "/Caret", "/Ink", "/Redact"]
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "DrawbridgeFlatten", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func flatten(source originalSource: URL, destination: URL, progress: @Sendable (String) -> Void = { _ in }) throws -> Report {
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        let replacingSource = originalSource.standardizedFileURL.resolvingSymlinksInPath() == destination
        guard let executable = PDFTKBookmarkWriter.executableURL() else { throw failure("The PDF processing helper is unavailable.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeFlatten-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Work against a stable local snapshot, including for cloud-provider files.
        let source = directory.appendingPathComponent("input.pdf")
        try FileManager.default.copyItem(at: originalSource, to: source)
        func run(_ arguments: [String]) throws {
            let logURL = directory.appendingPathComponent("qpdf-error.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            let process = Process(); process.executableURL = executable; process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = log
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 || process.terminationStatus == 3 else {
                let diagnostic = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                throw failure("The PDF could not be flattened safely. No changes were saved.\n" + String(diagnostic.prefix(1500)))
            }
        }
        func read(_ pdf: URL, name: String) throws -> [String: Any] {
            let url = directory.appendingPathComponent(name)
            try run(["--json=2", "--json-stream-data=inline", "--decode-level=none", pdf.path, url.path])
            guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw failure("Could not inspect PDF objects.") }
            return result
        }
        func writeJSON(_ json: [String: Any], name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try JSONSerialization.data(withJSONObject: metadataJSON(json), options: [.withoutEscapingSlashes, .sortedKeys]).write(to: url)
            return url
        }
        progress("Inspecting markup appearances…")
        var json = try read(source, name: "source.json")
        if let encryption = json["encrypt"] as? [String: Any], encryption["encrypted"] as? Bool == true {
            throw failure("Flattening encrypted PDFs is not supported. Export an unlocked copy first.")
        }
        var objects = try objectTable(json)
        guard !objects.values.contains(where: { entry in
            let value = (entry as? [String: Any])?["value"] as? [String: Any]
            return value?["/FT"] as? String == "/Sig" || value?["/Type"] as? String == "/Sig"
        }) else { throw failure("This PDF contains a signature field. Flatten an unsigned copy instead.") }
        let root = try rootReference(objects)
        var catalog = try dictionary(root, objects)
        guard catalog[marker] == nil else { throw failure("This PDF already contains an unfinished flatten operation.") }
        guard catalog[recoveryKey] == nil else { throw failure("This PDF is already flattened with recovery data. Unflatten it first.") }
        let pages = try pageReferences(json)
        let originalGeometry = try pages.map { try geometry($0, objects) }
        var protection: [[String: Any]] = []
        var recovery: [[String: Any]] = []
        var flattened = 0
        var retained = 0
        var removedSHXComments = 0
        for reference in pages {
            var page = try dictionary(reference, objects)
            let annotations = array(page["/Annots"], objects)
            var targets: [Any] = []
            var protected: [Any] = []
            var removed: [Any] = []
            for annotation in annotations {
                let value = resolve(annotation, objects) as? [String: Any] ?? [:]
                let type = value["/Subtype"] as? String ?? ""
                let flags = value["/F"] as? Int ?? 0
                // AutoCAD already draws SHX glyphs in the page content. These
                // zero-border comments contain redundant text metadata, not ink.
                // Some viewers still display/select their rectangular hit areas.
                if isRedundantSHXComment(value, objects) {
                    removed.append(annotation)
                    removedSHXComments += 1
                    continue
                }
                // No visual appearance means no safe flattening. Redaction annotations
                // are deliberately excluded: flattening is not secure redaction.
                if visualTypes.contains(type), type != "/Redact", flags & (1 | 2 | 32) == 0,
                   hasAppearance(value, objects) {
                    targets.append(annotation)
                    removed.append(annotation)
                    flattened += 1
                } else {
                    protected.append(annotation)
                    if visualTypes.contains(type) { retained += 1 }
                }
            }
            recovery.append([
                "/Page": reference, "/Contents": contentSnapshot(page["/Contents"], objects),
                "/Resources": try resourceSnapshot(reference, objects),
                "/Geometry": originalGeometry[recovery.count], "/Annots": removed
            ])
            protection.append(["/Page": reference, "/Annots": protected])
            page["/Annots"] = targets
            objects["obj:\(reference)"] = ["value": page]
        }
        guard flattened + removedSHXComments > 0 else { throw failure("No visible markups with usable appearances were found. Links, forms, hidden items, and unsupported markups are left unchanged.") }
        catalog[recoveryKey] = ["/Version": 1, "/Pages": recovery]
        catalog[marker] = protection
        objects["obj:\(root)"] = ["value": catalog]
        setObjects(objects, in: &json)
        let prepareJSON = try writeJSON(json, name: "protect.json")
        let prepared = directory.appendingPathComponent("protected.pdf")
        try run([source.path, "--stream-data=preserve", "--update-from-json=\(prepareJSON.path)", prepared.path])
        progress(flattened > 0 ? "Flattening \(flattened) markups into page content…" : "Removing \(removedSHXComments) redundant CAD text comments…")
        let flat = directory.appendingPathComponent("flattened.pdf")
        try run([prepared.path, "--flatten-annotations=screen", "--stream-data=preserve", flat.path])
        progress("Restoring links and checking page geometry…")
        var output = try read(flat, name: "flat.json")
        var outputObjects = try objectTable(output)
        let outputRoot = try rootReference(outputObjects)
        var outputCatalog = try dictionary(outputRoot, outputObjects)
        guard let entries = outputCatalog.removeValue(forKey: marker) as? [[String: Any]], entries.count == pages.count else { throw failure("Could not restore interactive annotations.") }
        for entry in entries {
            guard let reference = entry["/Page"] as? String, let annotations = entry["/Annots"] as? [Any] else { throw failure("Invalid protected annotation record.") }
            var page = try dictionary(reference, outputObjects)
            // A usable appearance should have been consumed. Never silently drop a
            // markup that qpdf declined to flatten.
            guard array(page["/Annots"], outputObjects).isEmpty else { throw failure("Some markup appearances could not be flattened safely. No copy was saved.") }
            page["/Annots"] = annotations
            outputObjects["obj:\(reference)"] = ["value": page]
        }
        guard var archive = outputCatalog[recoveryKey] as? [String: Any],
              var recoveryPages = archive["/Pages"] as? [[String: Any]] else { throw failure("Missing unflatten recovery data.") }
        for index in recoveryPages.indices {
            let reference = recoveryPages[index]["/Page"] as! String
            let page = try dictionary(reference, outputObjects)
            recoveryPages[index]["/FlattenedContents"] = contentSnapshot(page["/Contents"], outputObjects)
            recoveryPages[index]["/FlattenedDrawingHash"] = "u:" + (try drawingHash(reference, outputObjects))
            recoveryPages[index]["/FlattenedResources"] = try resourceSnapshot(reference, outputObjects)
        }
        archive["/Pages"] = recoveryPages
        outputCatalog[recoveryKey] = archive
        outputObjects["obj:\(outputRoot)"] = ["value": outputCatalog]
        setObjects(outputObjects, in: &output)
        let restoreJSON = try writeJSON(output, name: "restore.json")
        let final = directory.appendingPathComponent("verified.pdf")
        try run([flat.path, "--stream-data=preserve", "--update-from-json=\(restoreJSON.path)", final.path])
        try run(["--check", final.path])
        let verified = try read(final, name: "verified.json")
        let verifiedObjects = try objectTable(verified)
        let finalPages = try pageReferences(verified)
        guard finalPages.count == pages.count else { throw failure("Page count changed; no flattened copy was saved.") }
        for (index, page) in finalPages.enumerated() {
            guard NSDictionary(dictionary: try geometry(page, verifiedObjects)).isEqual(to: originalGeometry[index]) else { throw failure("Page geometry changed; no flattened copy was saved.") }
            let pageValue = try dictionary(page, verifiedObjects)
            guard array(pageValue["/Annots"], verifiedObjects).count == (entries[index]["/Annots"] as? [Any])?.count else { throw failure("Interactive annotations were not preserved.") }
        }
        if replacingSource {
            // Do not overwrite edits made by another application while we worked.
            guard try Data(contentsOf: originalSource, options: .mappedIfSafe) == Data(contentsOf: source, options: .mappedIfSafe) else {
                throw failure("The PDF changed while flattening. Reopen the current file and try again; it has not been overwritten.")
            }
        }
        progress(replacingSource ? "Saving flattened PDF…" : "Writing flattened copy…")
        try MainViewController.commitStagedSave(from: final, to: destination)
        return Report(flattened: flattened, retainedMarkups: retained, removedSHXComments: removedSHXComments)
    }

    static func canUnflatten(_ document: PDFDocument) -> Bool {
        guard let ref = document.documentRef, let catalog = ref.catalog else { return false }
        var archive: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(catalog, "DrawbridgeUnflattenData", &archive)
    }

    /// Recovery keeps references to original streams/annotations inside the PDF,
    /// rather than embedding a second PDF. Navigation edits survive this operation.
    static func unflatten(source: URL, progress: @Sendable (String) -> Void = { _ in }) throws -> Report {
        guard let executable = PDFTKBookmarkWriter.executableURL() else { throw failure("The PDF processing helper is unavailable.") }
        let destination = source.standardizedFileURL.resolvingSymlinksInPath()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeUnflatten-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = directory.appendingPathComponent("input.pdf")
        try FileManager.default.copyItem(at: destination, to: snapshot)
        let jsonURL = directory.appendingPathComponent("restore.json")
        let output = directory.appendingPathComponent("restored.pdf")
        progress("Checking unflatten recovery data…")
        guard PDFTKBookmarkWriter.run(executable, arguments: ["--json=2", "--json-stream-data=inline", "--decode-level=none", snapshot.path, jsonURL.path]),
              var json = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any] else { throw failure("Could not read recovery data.") }
        var objects = try objectTable(json)
        guard !objects.values.contains(where: { entry in
            let value = (entry as? [String: Any])?["value"] as? [String: Any]
            return value?["/FT"] as? String == "/Sig" || value?["/Type"] as? String == "/Sig"
        }) else { throw failure("Unflatten an unsigned copy instead of changing a signed PDF.") }
        let root = try rootReference(objects)
        var catalog = try dictionary(root, objects)
        guard let archive = catalog[recoveryKey] as? [String: Any], archive["/Version"] as? Int == 1,
              let entries = archive["/Pages"] as? [[String: Any]] else { throw failure("This PDF has no Drawbridge unflatten recovery data.") }
        let pages = try pageReferences(json)
        guard entries.count == pages.count else { throw failure("Pages have changed since flattening. Unflatten was cancelled to protect the newer edits.") }
        var restored = 0
        for (index, entry) in entries.enumerated() {
            guard let reference = entry["/Page"] as? String, reference == pages[index],
                  let removed = entry["/Annots"] as? [Any], let contents = entry["/Contents"],
                  let resources = entry["/Resources"] as? [String: Any],
                  let flattenedContents = entry["/FlattenedContents"],
                  let flattenedResources = entry["/FlattenedResources"] as? [String: Any],
                  let flattenedHash = entry["/FlattenedDrawingHash"] as? String,
                  let originalGeometry = entry["/Geometry"] as? [String: Any] else { throw failure("Invalid recovery data; no changes were saved.") }
            var page = try dictionary(reference, objects)
            guard NSDictionary(dictionary: try geometry(reference, objects)).isEqual(to: originalGeometry),
                  NSArray(array: [contentSnapshot(page["/Contents"], objects)]).isEqual(to: [flattenedContents]),
                  "u:" + (try drawingHash(reference, objects)) == flattenedHash,
                  NSDictionary(dictionary: try resourceSnapshot(reference, objects)).isEqual(to: flattenedResources) else {
                throw failure("Drawing content has changed since flattening. Unflatten was cancelled to protect the newer edits.")
            }
            page["/Contents"] = contents
            page["/Resources"] = resources
            page["/Annots"] = array(page["/Annots"], objects) + removed
            restored += removed.count
            objects["obj:\(reference)"] = ["value": page]
        }
        catalog.removeValue(forKey: recoveryKey)
        objects["obj:\(root)"] = ["value": catalog]
        setObjects(objects, in: &json)
        try JSONSerialization.data(withJSONObject: metadataJSON(json), options: [.withoutEscapingSlashes, .sortedKeys]).write(to: jsonURL)
        progress("Restoring \(restored) editable annotations…")
        guard PDFTKBookmarkWriter.run(executable, arguments: [snapshot.path, "--stream-data=preserve", "--update-from-json=\(jsonURL.path)", output.path]),
              PDFTKBookmarkWriter.run(executable, arguments: ["--check", output.path]) else { throw failure("Could not restore annotations safely; no changes were saved.") }
        guard try Data(contentsOf: destination, options: .mappedIfSafe) == Data(contentsOf: snapshot, options: .mappedIfSafe) else {
            throw failure("The file changed during unflattening. Reopen it and try again.")
        }
        progress("Saving restored PDF…")
        try MainViewController.commitStagedSave(from: output, to: destination)
        return Report(flattened: 0, retainedMarkups: 0, removedSHXComments: 0, restoredAnnotations: restored)
    }

    private static func contentSnapshot(_ value: Any?, _ objects: [String: Any]) -> Any {
        // qpdf may append to an existing indirect contents array. Archive a copy
        // of its entries, not a pointer to that mutable array.
        (resolve(value, objects) as? [Any]) ?? value ?? []
    }

    private static func drawingHash(_ reference: String, _ objects: [String: Any]) throws -> String {
        var cache: [String: String] = [:]
        func digest(_ value: Any, visiting: Set<String>) throws -> String {
            if let ref = value as? String, let object = objects["obj:\(ref)"] as? [String: Any] {
                if visiting.contains(ref) { return "cycle" }
                if let cached = cache[ref] { return cached }
                var next = visiting; next.insert(ref)
                let result = try digest(object["value"] ?? object["stream"] ?? NSNull(), visiting: next)
                cache[ref] = result
                return result
            }
            let normalized: Any
            if let dictionary = value as? [String: Any] {
                var result: [String: String] = [:]
                for (key, child) in dictionary where key != "/Length" {
                    result[key] = try digest(child, visiting: visiting)
                }
                normalized = result
            } else if let array = value as? [Any] {
                normalized = try array.map { try digest($0, visiting: visiting) }
            } else { normalized = value }
            let data = try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys, .fragmentsAllowed])
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let page = try dictionary(reference, objects)
        return try digest(["contents": contentSnapshot(page["/Contents"], objects), "resources": resourceSnapshot(reference, objects)], visiting: [])
    }

    private static func resourceSnapshot(_ reference: String, _ objects: [String: Any]) throws -> [String: Any] {
        var page = try dictionary(reference, objects)
        var visited: Set<String> = []
        while page["/Resources"] == nil, let parent = page["/Parent"] as? String, visited.insert(parent).inserted {
            page = try dictionary(parent, objects)
        }
        var resources = resolve(page["/Resources"], objects) as? [String: Any] ?? [:]
        // Snapshot the dictionaries qpdf extends, while retaining existing stream,
        // font and image references; their data is never duplicated.
        for key in ["/XObject", "/ExtGState"] {
            if let dictionary = resolve(resources[key], objects) as? [String: Any] { resources[key] = dictionary }
        }
        return resources
    }

    private static func metadataJSON(_ json: [String: Any]) -> [String: Any] {
        var result = json
        guard var qpdf = result["qpdf"] as? [[String: Any]], qpdf.count > 1 else { return result }
        var objects = qpdf[1]
        for (key, value) in objects {
            guard var object = value as? [String: Any], var stream = object["stream"] as? [String: Any] else { continue }
            // Inline data is read only for verification. Let qpdf reuse the input
            // stream bytes on writes instead of decoding/re-encoding JSON data.
            stream.removeValue(forKey: "data")
            stream.removeValue(forKey: "datafile")
            object["stream"] = stream
            objects[key] = object
        }
        qpdf[1] = objects; result["qpdf"] = qpdf
        return result
    }

    private static func objectTable(_ json: [String: Any]) throws -> [String: Any] {
        guard let qpdf = json["qpdf"] as? [[String: Any]], qpdf.count > 1 else { throw failure("Missing PDF object table.") }
        return qpdf[1]
    }
    private static func setObjects(_ objects: [String: Any], in json: inout [String: Any]) {
        var qpdf = json["qpdf"] as! [[String: Any]]
        qpdf[1] = objects
        json["qpdf"] = qpdf
    }
    private static func resolve(_ value: Any?, _ objects: [String: Any]) -> Any? {
        if let ref = value as? String, let object = objects["obj:\(ref)"] as? [String: Any] { return object["value"] ?? object["stream"] }
        return value
    }
    private static func dictionary(_ ref: String, _ objects: [String: Any]) throws -> [String: Any] {
        guard let value = resolve(ref, objects) as? [String: Any] else { throw failure("Invalid PDF dictionary.") }
        return value
    }
    private static func array(_ value: Any?, _ objects: [String: Any]) -> [Any] { resolve(value, objects) as? [Any] ?? [] }
    private static func rootReference(_ objects: [String: Any]) throws -> String {
        guard let trailer = objects["trailer"] as? [String: Any], let value = trailer["value"] as? [String: Any], let ref = value["/Root"] as? String else { throw failure("Missing PDF catalog.") }
        return ref
    }
    private static func pageReferences(_ json: [String: Any]) throws -> [String] {
        guard let pages = json["pages"] as? [[String: Any]] else { throw failure("Missing page tree.") }
        return try pages.map { guard let ref = $0["object"] as? String else { throw failure("Invalid page reference.") }; return ref }
    }
    private static func isRedundantSHXComment(_ annotation: [String: Any], _ objects: [String: Any]) -> Bool {
        guard annotation["/Subtype"] as? String == "/Square",
              let author = annotation["/T"] as? String,
              author.lowercased() == "u:autocad shx text",
              let contents = annotation["/Contents"] as? String, contents.hasPrefix("u:"), contents.count > 2,
              annotation["/AP"] == nil, annotation["/BS"] == nil,
              annotation["/C"] == nil, annotation["/IC"] == nil,
              (annotation["/F"] as? Int ?? 0) & 4 == 0,
              let border = resolve(annotation["/Border"], objects) as? [NSNumber], border.count == 3,
              border.allSatisfy({ $0.doubleValue == 0 }) else { return false }
        return true
    }

    private static func hasAppearance(_ annotation: [String: Any], _ objects: [String: Any]) -> Bool {
        guard let ap = resolve(annotation["/AP"], objects) as? [String: Any] else { return false }
        var normal = ap["/N"]
        if let states = resolve(normal, objects) as? [String: Any], states["dict"] == nil {
            guard let state = annotation["/AS"] as? String else { return false }
            normal = states[state]
        }
        guard let ref = normal as? String, let object = objects["obj:\(ref)"] as? [String: Any], let stream = object["stream"] as? [String: Any], let dict = stream["dict"] as? [String: Any],
              let bounds = resolve(dict["/BBox"], objects) as? [NSNumber], bounds.count == 4,
              bounds.allSatisfy({ $0.doubleValue.isFinite }),
              bounds[2].doubleValue > bounds[0].doubleValue, bounds[3].doubleValue > bounds[1].doubleValue,
              let rectangle = resolve(annotation["/Rect"], objects) as? [NSNumber], rectangle.count == 4,
              rectangle.allSatisfy({ $0.doubleValue.isFinite }),
              rectangle[2].doubleValue > rectangle[0].doubleValue, rectangle[3].doubleValue > rectangle[1].doubleValue else { return false }
        if let value = dict["/Matrix"] {
            guard let matrix = resolve(value, objects) as? [NSNumber], matrix.count == 6,
                  matrix.allSatisfy({ $0.doubleValue.isFinite }),
                  abs(matrix[0].doubleValue * matrix[3].doubleValue - matrix[1].doubleValue * matrix[2].doubleValue) > 0 else { return false }
        }
        return true
    }
    private static func geometry(_ ref: String, _ objects: [String: Any]) throws -> [String: Any] {
        var page = try dictionary(ref, objects)
        var result: [String: Any] = [:]
        var visited: Set<String> = []
        while true {
            for key in ["/MediaBox", "/CropBox", "/Rotate", "/UserUnit"] where result[key] == nil {
                result[key] = resolve(page[key], objects)
            }
            guard let parent = page["/Parent"] as? String, visited.insert(parent).inserted else { break }
            page = try dictionary(parent, objects)
        }
        return result
    }
}
