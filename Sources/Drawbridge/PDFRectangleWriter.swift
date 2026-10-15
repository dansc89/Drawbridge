import Foundation
import PDFKit
import CommonCrypto
import Darwin
import OSLog

/// New markup saves never invoke PDFKit's document renderer. Annotation appearances
/// are portable Form XObjects; unchanged page content/resources are verified before commit.
enum PDFRectangleWriter {
    struct SaveFailure: Sendable {
        let stage: String
        let errorCode: Int?
        var isSourceConflict: Bool { stage.hasPrefix("source changed") || stage == "source snapshot" }
        var explanation: String {
            if isSourceConflict { return "The original PDF is unavailable or changed outside Drawbridge. Your edits remain open. Save a recovered copy to preserve the version you were editing." }
            if stage == "source permissions" { return "This PDF is encrypted or digitally signed. Drawbridge cannot safely append markups to it. Your edits remain open." }
            if stage == "file replacement" { return "The verified PDF could not be committed to this location. Check that the folder is writable and available, or save a copy elsewhere. Your edits remain open." }
            return "Drawbridge could not verify the annotation-only save (\(stage)). The original page content was not rewritten; your edits remain open."
        }
    }
    private static let inspectionCache = MarkupInspectionCache()
    /// Inspect once while the drawing opens, so the first small markup save does
    /// not have to discover every PDF object. Called on a background queue.
    @discardableResult
    static func prepareInspection(source: URL) -> Bool {
        guard let executable = PDFTKBookmarkWriter.executableURL() else { return false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeMarkupInspection-\(UUID().uuidString)")
        do {
            let version = try MarkupFileVersion.read(source)
            if inspectionCache.snapshot(for: source, version: version) != nil { return true }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let snapshot = directory.appendingPathComponent("input.pdf"), output = directory.appendingPathComponent("input.json")
            if clonefile(source.path, snapshot.path, 0) != 0 { try FileManager.default.copyItem(at: source, to: snapshot) }
            guard try MarkupFileVersion.read(source) == version,
                  PDFTKBookmarkWriter.run(executable, arguments: ["--json=2", "--json-stream-data=none", "--decode-level=none", snapshot.path, output.path]) else { return false }
            let data = try Data(contentsOf: output)
            guard let graph = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  try MarkupFileVersion.read(source) == version else { return false }
            try inspectionCache.store(url: source, graph: graph, cost: data.count, expectedVersion: version)
            return true
        } catch { return false }
    }
    // Keep this verification boundary intact: the packaged production pen-save
    // workflow regresses when the optimizer folds the writer into its caller.
    @inline(never)
    static func write(document: PDFDocument, source: URL, destination: URL,
                      pageLabels: [Int: String], records: [RectangleMarkupRecord], expectedSourceStamp: PDFMarkupSourceStamp? = nil,
                      navigationSnapshot: PDFTKBookmarkWriter.NavigationSnapshot? = nil,
                      importedPlan: ImportedMarkupPlan? = nil,
                      onCommitted: ((PDFMarkupSourceStamp) -> Void)? = nil,
                      onFailure: ((SaveFailure) -> Void)? = nil) -> Bool {
        var stage = "record validation"
        var succeeded = false
        var errorCode: Int?
        defer {
            if !succeeded {
                Logger(subsystem: "com.drawbridge.app", category: "MarkupSave").error("Markup save rejected at \(stage, privacy: .public), code \(errorCode ?? 0, privacy: .public)")
                onFailure?(SaveFailure(stage: stage, errorCode: errorCode))
            }
        }
        guard let executable = PDFTKBookmarkWriter.executableURL(), records.allSatisfy(\.isValid),
              Set(records.map(\.id)).count == records.count else { print("Rectangle writer: unavailable helper or invalid markup records"); return false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeRectangleSave-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch { return false }
        defer { try? FileManager.default.removeItem(at: directory) }
        let profilingStart = Date()
        func profile(_ phase: String) {
            guard ProcessInfo.processInfo.environment["DRAWBRIDGE_PROFILE_SAVE"] == "1" else { return }
            print("Markup save \(phase): \(Date().timeIntervalSince(profilingStart))s")
        }
        do {
            stage = "source snapshot"
            let sourceVersion = try MarkupFileVersion.read(source)
            if let expectedSourceStamp, !expectedSourceStamp.matchesSource(source) {
                stage = "source changed since opening"
                return false
            }
            let input = directory.appendingPathComponent("input.pdf")
            if clonefile(source.path, input.path, 0) != 0,
               copyfile(source.path, input.path, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL)) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard try MarkupFileVersion.read(source) == sourceVersion else { return false }
            let original = try Data(contentsOf: input, options: .mappedIfSafe)
            func read(_ url: URL, _ name: String, decoded: Bool = true) throws -> [String: Any] {
                let json = directory.appendingPathComponent(name)
                guard PDFTKBookmarkWriter.run(executable, arguments: ["--json=2", "--json-stream-data=none", "--decode-level=\(decoded ? "generalized" : "none")", url.path, json.path]),
                      let result = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
                return result
            }
            profile("source snapshot")
            stage = "source inspection"
            let inspected: [String: Any]
            let inspectionCost: Int
            if let cached = inspectionCache.snapshot(for: source, version: sourceVersion) {
                inspected = cached.graph
                inspectionCost = cached.cost
                profile("reused verified inspection")
            } else {
                inspected = try read(input, "input.json", decoded: false)
                inspectionCost = try directory.appendingPathComponent("input.json").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            }
            profile("inspection")
            stage = "source permissions"
            guard (inspected["encrypt"] as? [String: Any])?["encrypted"] as? Bool != true else { return false }
            let table = try objectTable(inspected)
            guard !table.values.contains(where: { entry in
                let value = (entry as? [String: Any])?["value"] as? [String: Any]
                return value?["/FT"] as? String == "/Sig" || value?["/Type"] as? String == "/Sig"
            }) else { return false }
            // Apply navigation and markups in one object patch. Previously this
            // saved a whole intermediate PDF and read its streams twice again.
            // Preserve the entire original byte prefix, including every stream.
            stage = "navigation update"
            var json = inspected
            let navigation = navigationSnapshot ?? PDFTKBookmarkWriter.captureNavigation(in: document)
            guard PDFTKBookmarkWriter.updateNavigationJSON(&json, snapshot: navigation, pageLabels: pageLabels) else { return false }
            try reuseUnchangedNavigation(baseline: inspected, updated: &json)
            profile("navigation changes")
            stage = "annotation update"
            let scaleViewports = try update(&json, records: records, document: document)
            var importedArrays: [Int: [Any]] = [:]
            var importedObjects: [String: [String: Any]] = [:]
            if let importedPlan {
                guard let originalSource = importedPlan.source else { return false }
                let version = try MarkupFileVersion.read(originalSource)
                let originalGraph: [String: Any]
                if let cached = inspectionCache.snapshot(for: originalSource, version: version) { originalGraph = cached.graph }
                else {
                    originalGraph = try read(originalSource, "imported.json", decoded: false)
                    try? inspectionCache.store(url: originalSource, graph: originalGraph, cost: (try Data(contentsOf: directory.appendingPathComponent("imported.json"))).count, expectedVersion: version)
                }
                try updateImported(&json, original: originalGraph, plan: importedPlan, arrays: &importedArrays, objects: &importedObjects)
            }
            try refreshImportedLayerReferences(&json, authorized: &importedObjects)
            if try changedObjects(baseline: inspected, updated: json).isEmpty {
                guard try MarkupFileVersion.read(source) == sourceVersion else { return false }
                let verifiedInput = PDFMarkupSourceStamp.capture(input)
                if source.standardizedFileURL != destination.standardizedFileURL {
                    let unchanged = directory.appendingPathComponent("unchanged.pdf")
                    try original.write(to: unchanged)
                    try MainViewController.commitStagedSave(from: unchanged, to: destination)
                }
                stage = "source changed after save"
                let committedVersion = try MarkupFileVersion.read(destination)
                guard let committedStamp = PDFMarkupSourceStamp.capture(destination),
                      let frozen = committedStamp.recoverySourceURL,
                      verifiedInput?.matchesSource(frozen) == true else { return false }
                try? inspectionCache.store(url: destination, graph: inspected, cost: inspectionCost, expectedVersion: committedVersion)
                succeeded = true
                onCommitted?(committedStamp)
                return true
            }
            let candidate = directory.appendingPathComponent("candidate.pdf")
            let changed = try changedObjects(baseline: inspected, updated: json)
            stage = "original content verification"
            guard try preservesOriginalObjects(baseline: inspected, updated: json, changed: changed, importedArrays: importedArrays, importedObjects: importedObjects, scaleViewports: scaleViewports) else { return false }
            stage = "incremental serialization"
            let expectedSize = try PDFIncrementalMarkupPatch.append(original: original, baseline: inspected, updated: json, snapshot: input, to: candidate)
            profile("candidate write")
            // Check object relationships without decoding the original images.
            let verificationURL = directory.appendingPathComponent("changed.json")
            let selectors = changed.map { "--json-object=" + $0.dropFirst(4).split(separator: " ").prefix(2).joined(separator: ",") }
            stage = "serialized object verification"
            guard PDFTKBookmarkWriter.run(executable, arguments: ["--json=2", "--json-key=qpdf", "--json-stream-data=inline", "--decode-level=none", "--json-object=trailer"] + selectors + [candidate.path, verificationURL.path]),
                  let delta = try JSONSerialization.jsonObject(with: Data(contentsOf: verificationURL)) as? [String: Any],
                  try changedObjectsMatch(expected: json, written: delta, keys: changed) else { return false }
            let written = try mergingVerifiedChanges(baseline: inspected, delta: delta)
            profile("candidate inspection")
            stage = "annotation verification"
            guard try ownedRecordsMatch(written, records: records) else { print("Rectangle writer: markup verification failed"); return false }
            stage = "Apple reader verification"
            guard let readable = PDFDocument(url: candidate), readable.pageCount == (try pages(inspected).count) else {
                print("Rectangle writer: Apple PDF reader rejected candidate"); return false
            }
            stage = "source changed during save"
            guard try MarkupFileVersion.read(source) == sourceVersion else { print("Rectangle writer: source changed during save"); return false }
            stage = "candidate size verification"
            let size = try candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            // Filtered captures may expand a tiny compressed source into a large
            // bounded raster appearance. Verify the exact serialized revision,
            // rather than estimating its size from the compressed source payload.
            guard size == expectedSize, size > original.count else {
                print("Rectangle writer: serialized size mismatch \(size) vs \(expectedSize)")
                return false
            }
            profile("candidate verification")
            let verifiedCandidate = PDFMarkupSourceStamp.capture(candidate)
            stage = "file replacement"
            try MainViewController.commitStagedSave(from: candidate, to: destination)
            stage = "source changed after save"
            let committedVersion = try MarkupFileVersion.read(destination)
            guard let committedStamp = PDFMarkupSourceStamp.capture(destination),
                  let frozen = committedStamp.recoverySourceURL,
                  verifiedCandidate?.matchesSource(frozen) == true else { return false }
            // A cache failure must not report a verified, committed PDF as an
            // unsuccessful save. The next save can simply inspect it again.
            try? inspectionCache.store(url: destination, graph: written, cost: inspectionCost + (try verificationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0), expectedVersion: committedVersion)
            profile("commit")
            succeeded = true
            onCommitted?(committedStamp)
            return true
        } catch { errorCode = (error as NSError).code; print("Rectangle writer: \(error)"); return false }
    }

    static func changedObjects(baseline: [String: Any], updated: [String: Any]) throws -> [String] {
        let before = try objectTable(baseline), after = try objectTable(updated)
        return after.keys.filter { key in
            guard key.hasPrefix("obj:"), let value = after[key] as? [String: Any] else { return false }
            return !((before[key] as? NSDictionary)?.isEqual(to: value) ?? false)
        }.sorted()
    }

    /// Check the mutation boundary before serializing. Only navigation, annotation
    /// arrays, owned annotations, and explicitly authorized scale viewports may
    /// change. Original streams/resources and other page fields stay immutable.
    static func preservesOriginalObjects(baseline: [String: Any], updated: [String: Any], changed: [String], importedArrays: [Int: [Any]] = [:], importedObjects: [String: [String: Any]] = [:], scaleViewports: [String: Any] = [:]) throws -> Bool {
        let before = try objectTable(baseline), after = try objectTable(updated)
        let pageRefs = try pages(baseline)
        let pageKeys = Set(pageRefs.map { "obj:" + $0 })
        let catalog = ((before["trailer"] as? [String: Any])?["value"] as? [String: Any])?["/Root"] as? String ?? ""
        let arrays = Set(pageRefs.compactMap { ref in ((before["obj:" + ref] as? [String: Any])?["value"] as? [String: Any])?["/Annots"] as? String }.map { "obj:" + $0 })
        func generated(_ entry: Any, _ objects: [String: Any]) -> Bool {
            let d = dictionary(entry, objects: objects)
            return [d["/Contents"], d["/T"]].compactMap { $0 as? String }.contains { $0.contains("DrawbridgeAutoSheetLink") }
        }
        for key in changed {
            guard let old = before[key] as? [String: Any] else { continue }
            guard old["stream"] == nil, let new = after[key] as? [String: Any] else { return false }
            if pageKeys.contains(key) || key == "obj:" + catalog {
                guard var a = old["value"] as? [String: Any], var b = new["value"] as? [String: Any] else { return false }
                var allowed = pageKeys.contains(key) ? ["/Annots"] : ["/Outlines", "/PageLabels", "/OCProperties"]
                if let expected = scaleViewports[key], pageKeys.contains(key) {
                    guard NSArray(array: [expected]).isEqual(to: [b["/VP"] ?? NSNull()]) else { return false }
                    allowed.append("/VP")
                }
                for field in allowed { a.removeValue(forKey: field); b.removeValue(forKey: field) }
                guard NSDictionary(dictionary: a).isEqual(to: b) else { return false }
                if key == "obj:" + catalog && !PDFMarkupLayersPatch.preservesForeignLayers(before: before, after: after, root: catalog) { return false }
                if pageKeys.contains(key) {
                    let a = old["value"] as! [String: Any], b = new["value"] as! [String: Any]
                    let importedBefore = annotations(a["/Annots"], objects: before).filter { !owned($0, objects: before) && !generated($0, before) }
                    let importedAfter = annotations(b["/Annots"], objects: after).filter { !owned($0, objects: after) && !generated($0, after) }
                    let expected = importedArrays[pageRefs.firstIndex(of: String(key.dropFirst(4))) ?? -1] ?? importedBefore
                    guard NSArray(array: expected).isEqual(to: importedAfter) else { return false }
                }
            } else if arrays.contains(key) {
                guard let a = old["value"] as? [Any], let b = new["value"] as? [Any] else { return false }
                let importedBefore = a.filter { !owned($0, objects: before) && !generated($0, before) }
                let importedAfter = b.filter { !owned($0, objects: after) && !generated($0, after) }
                let pageIndex = pageRefs.firstIndex { ref in
                    ((before["obj:" + ref] as? [String: Any])?["value"] as? [String: Any])?["/Annots"] as? String == String(key.dropFirst(4))
                } ?? -1
                guard NSArray(array: importedArrays[pageIndex] ?? importedBefore).isEqual(to: importedAfter) else { return false }
            } else if let expected = importedObjects[key] {
                guard NSDictionary(dictionary: new).isEqual(to: expected) else { return false }
            } else if owned(String(key.dropFirst(4)), objects: before) || generated(String(key.dropFirst(4)), before) {
                guard new["value"] is [String: Any] else { return false }
            } else { return false }
        }
        return true
    }

    private static func comparisonGraph(_ values: [Any]) -> [String: Any] {
        ["qpdf": [["maxobjectid": 1], ["trailer": ["value": ["/Root": "verification-root"]], "obj:verification-root": ["value": values]]]]
    }

    private static func changedObjectsMatch(expected: [String: Any], written: [String: Any], keys: [String]) throws -> Bool {
        let a = try objectTable(expected), b = try objectTable(written)
        guard keys.allSatisfy({ a[$0] != nil && b[$0] != nil }) else { return false }
        // References compare literally here. The untouched referenced objects
        // retain their original bytes and cross-reference entries.
        return try PDFLosslessReducer.semanticGraphsMatch(comparisonGraph(keys.map { a[$0]! }), comparisonGraph(keys.map { b[$0]! }))
    }

    private static func mergingVerifiedChanges(baseline: [String: Any], delta: [String: Any]) throws -> [String: Any] {
        var result = baseline, tables = try tableArray(baseline)
        let changed = try tableArray(delta)
        tables[0] = changed[0]
        for (key, value) in changed[1] {
            if var object = value as? [String: Any], var stream = object["stream"] as? [String: Any] {
                stream.removeValue(forKey: "data"); object["stream"] = stream; tables[1][key] = object
            } else { tables[1][key] = value }
        }
        result["qpdf"] = tables
        return result
    }

    private static func reuseUnchangedNavigation(baseline: [String: Any], updated: inout [String: Any]) throws {
        let before = try objectTable(baseline)
        let pageReferences = try pages(baseline)
        var tables = try tableArray(updated), after = tables[1]
        guard let catalogRef = ((before["trailer"] as? [String: Any])?["value"] as? [String: Any])?["/Root"] as? String,
              let oldCatalog = (before["obj:" + catalogRef] as? [String: Any])?["value"] as? [String: Any],
              var newObject = after["obj:" + catalogRef] as? [String: Any], var newCatalog = newObject["value"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        for field in ["/Outlines", "/PageLabels"] {
            func graph(_ table: [String: Any], _ root: Any?) -> [String: Any] {
                var t = table
                // Destinations refer to existing pages by identity. Following
                // them would turn an outline check into a whole-PDF traversal.
                for ref in pageReferences { t.removeValue(forKey: "obj:" + ref) }
                t["trailer"] = ["value": ["/Root": root ?? NSNull()]]
                return ["qpdf": [["maxobjectid": 0], t]]
            }
            if try PDFLosslessReducer.semanticGraphsMatch(graph(before, oldCatalog[field]), graph(after, newCatalog[field])) {
                // Discard the unused new outline/label tree, without visiting
                // pages referenced by outline destinations.
                var pending = [newCatalog[field]], seen = Set<String>()
                while let value = pending.popLast() {
                    if let ref = value as? String, before["obj:" + ref] == nil, let object = after["obj:" + ref] as? [String: Any], seen.insert(ref).inserted {
                        pending.append(object["value"]); after.removeValue(forKey: "obj:" + ref)
                    } else if let dict = value as? [String: Any] { pending.append(contentsOf: dict.values.map { Optional($0) }) }
                    else if let array = value as? [Any] { pending.append(contentsOf: array.map { Optional($0) }) }
                }
                newCatalog[field] = oldCatalog[field]
            }
        }
        newObject["value"] = newCatalog; after["obj:" + catalogRef] = newObject
        let originalMaximum = try tableArray(baseline)[0]["maxobjectid"] as? Int ?? 0
        let retainedMaximum = after.keys.compactMap { key -> Int? in
            guard key.hasPrefix("obj:") else { return nil }
            return Int(key.dropFirst(4).split(separator: " ").first ?? "")
        }.max() ?? 0
        tables[0]["maxobjectid"] = max(originalMaximum, retainedMaximum)
        tables[1] = after; updated["qpdf"] = tables
    }

    /// qpdf emits stream payloads as single-line base64 strings. Replace those
    /// payloads before Foundation parses JSON, so raster bytes never become huge
    /// bridged strings. PDF dictionary keys begin with /, unlike this qpdf key.
    static func compactStreamJSON(_ input: Data) throws -> Data {
        let marker = Data("          \"data\": \"".utf8)
        let quote = Data([34])
        var output = Data(), cursor = input.startIndex
        while let match = input.range(of: marker, in: cursor..<input.endIndex) {
            let start = match.upperBound
            guard let end = input.range(of: quote, in: start..<input.endIndex)?.lowerBound,
                  let bytes = Data(base64Encoded: input.subdata(in: start..<end)) else { throw CocoaError(.fileReadCorruptFile) }
            output.append(input[cursor..<start])
            output.append(Data(("sha256:" + streamDigest(bytes)).utf8))
            cursor = end
        }
        output.append(input[cursor..<input.endIndex])
        return output
    }

    static func streamDigest(_ bytes: Data) -> String {
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                let count = min(bytes.count - offset, 1024 * 1024)
                CC_SHA256_Update(&context, buffer.baseAddress!.advanced(by: offset), CC_LONG(count))
                offset += count
            }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return Data(digest).base64EncodedString()
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

    /// External annotation dictionaries and AP streams stay unchanged except for
    /// an explicitly requested translation. Deletion only changes page membership.
    private static func updateImported(_ json: inout [String: Any], original: [String: Any], plan: ImportedMarkupPlan,
                                       arrays: inout [Int: [Any]], objects authorized: inout [String: [String: Any]]) throws {
        let originalObjects = try objectTable(original), originalPages = try pages(original)
        var tables = try tableArray(json), objects = tables[1]
        let currentPages = try pages(json)
        func generated(_ entry: Any, _ table: [String: Any]) -> Bool {
            let d = dictionary(entry, objects: table)
            return [d["/Contents"], d["/T"]].compactMap { $0 as? String }.contains { $0.contains("DrawbridgeAutoSheetLink") }
        }
        for (pageIndex, changes) in Dictionary(grouping: plan.changes, by: \.page) {
            guard currentPages.indices.contains(pageIndex), let sourceIndex = changes.first?.sourcePage,
                  originalPages.indices.contains(sourceIndex), changes.allSatisfy({ $0.sourcePage == sourceIndex }) else { throw CocoaError(.fileReadCorruptFile) }
            let originalPage = dictionary(originalPages[sourceIndex], objects: originalObjects)
            let originalEntries = annotations(originalPage["/Annots"], objects: originalObjects)
            let pageKey = "obj:" + currentPages[pageIndex]
            guard var pageObject = objects[pageKey] as? [String: Any], var page = pageObject["value"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            let currentEntries = annotations(page["/Annots"], objects: objects)
            var deleted = Set(changes.filter(\.deleted).map(\.slot))
            let deletedRefs = Set(deleted.compactMap { originalEntries.indices.contains($0) ? originalEntries[$0] as? String : nil })
            for (slot, entry) in originalEntries.enumerated() {
                let value = dictionary(entry, objects: originalObjects)
                if value["/Subtype"] as? String == "/Popup", let parent = value["/Parent"] as? String, deletedRefs.contains(parent) { deleted.insert(slot) }
            }
            for change in changes {
                guard originalEntries.indices.contains(change.slot), let ref = originalEntries[change.slot] as? String,
                      var value = (originalObjects["obj:" + ref] as? [String: Any])?["value"] as? [String: Any],
                      let existingObject = objects["obj:" + ref] as? [String: Any],
                      let existing = existingObject["value"] as? [String: Any],
                      !owned(ref, objects: originalObjects), !generated(ref, originalObjects),
                      ["/Square", "/Circle", "/Line", "/FreeText", "/Ink", "/Polygon", "/PolyLine", "/Highlight", "/Underline", "/StrikeOut", "/Squiggly", "/Text", "/Stamp", "/Caret"].contains(value["/Subtype"] as? String ?? ""),
                      ((value["/F"] as? Int ?? 0) & (1 | 2 | 32 | 64 | 128 | 512)) == 0 else { throw CocoaError(.fileReadCorruptFile) }
                guard value["/Subtype"] as? String == "/" + change.subtype,
                      let rect = value["/Rect"] as? [NSNumber], rect.count == 4,
                      zip(rect.map(\.doubleValue), [change.originalBounds.minX, change.originalBounds.minY, change.originalBounds.maxX, change.originalBounds.maxY]).allSatisfy({ abs($0.0 - Double($0.1)) < 0.01 }) else { throw CocoaError(.fileReadCorruptFile) }
                if let name = change.name, let rawName = value["/NM"] as? String, rawName.hasPrefix("u:"), rawName != "u:" + name { throw CocoaError(.fileReadCorruptFile) }
                let geometry = ["/Rect", "/L", "/Vertices", "/InkList", "/QuadPoints", "/CL"]
                var a = value, b = existing
                for field in geometry { a.removeValue(forKey: field); b.removeValue(forKey: field) }
                // Previous saves may have assigned this imported annotation to a
                // Drawbridge OCG. Validate that ownership before ignoring only
                // those two membership fields in the immutable metadata check.
                func withoutManagedLayer(_ dictionary: [String: Any], table: [String: Any]) throws -> [String: Any] {
                    var result = dictionary
                    if let id = dictionary["/DrawbridgeLayerID"] as? String {
                        guard id.hasPrefix("u:"), UUID(uuidString: String(id.dropFirst(2))) != nil,
                              let group = dictionary["/OC"] as? String,
                              let definition = (table["obj:" + group] as? [String: Any])?["value"] as? [String: Any],
                              definition["/DrawbridgeLayerID"] as? String == id else { throw CocoaError(.fileReadCorruptFile) }
                        result.removeValue(forKey: "/DrawbridgeLayerID"); result.removeValue(forKey: "/OC")
                    }
                    return result
                }
                a = try withoutManagedLayer(a, table: originalObjects)
                b = try withoutManagedLayer(b, table: objects)
                guard NSDictionary(dictionary: a).isEqual(to: b), change.offset.x.isFinite, change.offset.y.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                func translated(_ raw: Any) throws -> [Double] {
                    guard let numbers = raw as? [NSNumber], numbers.count.isMultiple(of: 2) else { throw CocoaError(.fileReadCorruptFile) }
                    return numbers.enumerated().map { $0.element.doubleValue + Double($0.offset.isMultiple(of: 2) ? change.offset.x : change.offset.y) }
                }
                for field in geometry {
                    guard let raw = value[field] else { continue }
                    if field == "/InkList" {
                        guard let paths = raw as? [Any] else { throw CocoaError(.fileReadCorruptFile) }
                        value[field] = try paths.map(translated)
                    } else { value[field] = try translated(raw) }
                }
                if change.layerChanged {
                    if let id = change.layerID {
                        guard let ref = PDFMarkupLayersPatch.references(objects)[id] else { throw CocoaError(.fileWriteUnknown) }
                        guard value["/OC"] == nil || value["/DrawbridgeLayerID"] != nil else { throw CocoaError(.fileWriteUnknown) }
                        value["/OC"] = ref; value["/DrawbridgeLayerID"] = "u:" + id
                    } else if value["/DrawbridgeLayerID"] != nil { value.removeValue(forKey: "/OC"); value.removeValue(forKey: "/DrawbridgeLayerID") }
                } else if let id = change.layerID, let ref = PDFMarkupLayersPatch.references(objects)[id] { value["/OC"] = ref }
                let object: [String: Any] = ["value": value]
                objects["obj:" + ref] = object; authorized["obj:" + ref] = object
            }
            // Keep all original imported entries in their original order, including
            // CAD helpers and ordinary links. Owned/generated annotations use the
            // current save's entries. Deleted objects remain available for undo.
            let imported = originalEntries.enumerated().filter { !deleted.contains($0.offset) && !owned($0.element, objects: originalObjects) && !generated($0.element, originalObjects) }.map(\.element)
            let managed = currentEntries.filter { owned($0, objects: objects) || generated($0, objects) }
            let entries = imported + managed
            if entries.isEmpty { page.removeValue(forKey: "/Annots") } else { page["/Annots"] = entries }
            pageObject["value"] = page; objects[pageKey] = pageObject; arrays[pageIndex] = imported
        }
        // Reorder references only. Every imported object and appearance remains
        // immutable, and all current annotation references must be retained once.
        for order in plan.orders {
            guard currentPages.indices.contains(order.page), originalPages.indices.contains(order.sourcePage) else { throw CocoaError(.fileReadCorruptFile) }
            let originalPage = dictionary(originalPages[order.sourcePage], objects: originalObjects)
            let originals = annotations(originalPage["/Annots"], objects: originalObjects)
            let pageKey = "obj:" + currentPages[order.page]
            guard var object = objects[pageKey] as? [String: Any], var page = object["value"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            let current = annotations(page["/Annots"], objects: objects)
            guard let references = current as? [String] else { throw CocoaError(.fileReadCorruptFile) }
            var ordered: [String] = []
            for item in order.items {
                let ref: String?
                switch item {
                case .original(let slot):
                    guard originals.indices.contains(slot) else { throw CocoaError(.fileReadCorruptFile) }
                    ref = originals[slot] as? String
                case .owned(let id):
                    ref = references.first { ownedIdentity(dictionary($0, objects: objects)) == "u:" + id }
                }
                if let ref, references.contains(ref), !ordered.contains(ref) { ordered.append(ref) }
            }
            ordered += references.filter { !ordered.contains($0) }
            guard ordered.count == references.count, Set(ordered) == Set(references) else { throw CocoaError(.fileReadCorruptFile) }
            page["/Annots"] = ordered; object["value"] = page; objects[pageKey] = object
            arrays[order.page] = ordered.filter { !owned($0, objects: objects) && !generated($0, objects) }
        }
        tables[1] = objects; json["qpdf"] = tables
    }

    private static func refreshImportedLayerReferences(_ json: inout [String: Any], authorized: inout [String: [String: Any]]) throws {
        var tables = try tableArray(json), objects = tables[1]
        let mapping = PDFMarkupLayersPatch.references(objects)
        for ref in try pages(json) {
            let page = dictionary(ref, objects: objects)
            for entry in annotations(page["/Annots"], objects: objects) where !owned(entry, objects: objects) {
                guard let ref = entry as? String, var object = objects["obj:" + ref] as? [String: Any], var value = object["value"] as? [String: Any],
                      let rawID = value["/DrawbridgeLayerID"] as? String, rawID.hasPrefix("u:"), let group = mapping[String(rawID.dropFirst(2))] else { continue }
                value["/OC"] = group; object["value"] = value
                objects["obj:" + ref] = object; authorized["obj:" + ref] = object
            }
        }
        tables[1] = objects; json["qpdf"] = tables
    }

    private static func update(_ json: inout [String: Any], records: [RectangleMarkupRecord], document: PDFDocument) throws -> [String: Any] {
        var scaleViewports: [String: Any] = [:]
        var qpdf = try tableArray(json); var objects = qpdf[1]
        var next = (qpdf[0]["maxobjectid"] as? Int ?? 0) + 1
        let layerCatalogs = records.compactMap(\.layerCatalog)
        guard layerCatalogs.count <= 1 else { throw CocoaError(.fileWriteUnknown) }
        let layerReferences = try PDFMarkupLayersPatch.install(catalogText: layerCatalogs.first, objects: &objects, next: &next)
        guard records.allSatisfy({ $0.layerID == nil || layerReferences[$0.layerID!] != nil }) else { throw CocoaError(.fileWriteUnknown) }
        var snapshotForms: [Data:String] = [:]
        var snapshotPayloads: [Data:String] = [:]
        // Identical captures share one indirect PDF string rather than embedding
        // many copies of a potentially large image in every annotation.
        for (key, object) in objects where key.hasPrefix("obj:") {
            guard let encoded = (object as? [String:Any])?["value"] as? String,
                  encoded.hasPrefix("u:"), encoded.utf8.count <= SnapshotPayload.maximumBytes * 2,
                  let data = Data(base64Encoded:String(encoded.dropFirst(2))), SnapshotPayload(data:data).page != nil else { continue }
            snapshotPayloads[data] = String(key.dropFirst(4))
        }
        var reusedFragments = Set<String>()
        for object in objects.values {
            guard let value = (object as? [String:Any])?["value"] as? [String:Any], ownedIdentity(value) != nil,
                  let payloadValue = value["/DrawbridgeSnapshotPDF"] as? String,
                  let appearance = (value["/AP"] as? [String:Any])?["/N"] as? String,
                  let stream = (objects["obj:" + appearance] as? [String:Any])?["stream"] as? [String:Any],
                  let resources = (stream["dict"] as? [String:Any])?["/Resources"] as? [String:Any],
                  let fragment = (resources["/XObject"] as? [String:Any])?["/Snapshot"] as? String,
                  let fragmentStream = (objects["obj:" + fragment] as? [String:Any])?["stream"] as? [String:Any],
                  let fragmentDict = fragmentStream["dict"] as? [String:Any],
                  (fragmentDict["/Group"] as? [String:Any])?["/S"] as? String == "/Transparency",
                  reusedFragments.insert(fragment).inserted else { continue }
            let encoded = (objects["obj:" + payloadValue] as? [String:Any])?["value"] as? String ?? payloadValue
            guard encoded.hasPrefix("u:"), encoded.utf8.count <= SnapshotPayload.maximumBytes * 2,
                  let data = Data(base64Encoded:String(encoded.dropFirst(2))), SnapshotPayload(data:data).page != nil else { continue }
            let styleJSON = (value["/DrawbridgeSnapshotStyle"] as? String).flatMap { $0.hasPrefix("u:") ? String($0.dropFirst(2)).data(using:.utf8) : nil }
            let style = styleJSON.flatMap { try? JSONDecoder().decode(SnapshotStyle.self,from:$0) } ?? SnapshotStyle()
            guard style.isValid else { continue }
            snapshotForms[try SnapshotFilterRenderer.filtered(data,style:style)] = fragment
        }
        let references = try pages(json)
        guard records.allSatisfy({ $0.pageIndex < references.count }) else { throw CocoaError(.fileReadCorruptFile) }
        let recordsByPage = Dictionary(grouping: records, by: \.pageIndex)
        for (index, reference) in references.enumerated() {
            guard var object = objects["obj:\(reference)"] as? [String: Any], var page = object["value"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            let existing = annotations(page["/Annots"], objects: objects)
            let existingByID = Dictionary(existing.compactMap { entry -> (String, String)? in
                guard owned(entry, objects: objects), let reference = entry as? String,
                      let id = ownedIdentity(dictionary(entry, objects: objects)) else { return nil }
                return (id, reference)
            }, uniquingKeysWith: { first, _ in first })
            var entries = existing.filter { !owned($0, objects: objects) }
            for record in recordsByPage[index] ?? [] {
                let oldReference = existingByID["u:" + record.id]
                let annotationRef = oldReference ?? "\(next) 0 R"; if oldReference == nil { next += 1 }
                let appearanceRef = "\(next) 0 R"; next += 1
                let b = record.bounds
                var annotation: [String:Any] = ["/Type": "/Annot", "/Subtype": subtype(record.kind), "/Rect": [b.minX,b.minY,b.maxX,b.maxY], "/T": "u:\(record.author)", "/NM": "u:\(record.id)", "/Contents": "u:\(record.kind.rawValue.capitalized)", "/F": 4, "/C": [record.red,record.green,record.blue], "/BS": ["/W":record.lineWidth,"/S":"/S"], "/AP": ["/N":appearanceRef]]
                if let id = record.layerID { annotation["/DrawbridgeLayerID"] = "u:" + id; annotation["/OC"] = layerReferences[id] }
                else if let oldReference, let old = (objects["obj:" + oldReference] as? [String: Any])?["value"] as? [String: Any], old["/DrawbridgeLayerID"] == nil { annotation["/OC"] = old["/OC"] }
                if let catalog = record.layerCatalog { annotation["/DrawbridgeLayerCatalog"] = "u:" + catalog; annotation["/F"] = 98 }
                if let tool = record.inkTool { annotation["/DrawbridgeInkTool"] = "u:" + tool }
                annotation["/DrawbridgeLinePattern"] = "u:" + record.linePattern.rawValue
                annotation["/DrawbridgeStrokeOpacity"] = record.strokeOpacity
                annotation["/DrawbridgeFillOpacity"] = record.fillOpacity
                if let hatch = record.hatch { annotation["/DrawbridgeHatchStyle"] = "u:" + hatch.json }
                annotation["/BS"] = ["/W": record.lineWidth, "/S": record.linePattern == .solid ? "/S" : "/D", "/D": record.linePattern.dash(width: CGFloat(record.lineWidth))]
                if record.kind == .snapshot, let data = record.snapshotData {
                    let payloadRef: String
                    if let existing = snapshotPayloads[data] { payloadRef = existing }
                    else {
                        payloadRef = "\(next) 0 R"; next += 1
                        objects["obj:" + payloadRef] = ["value":"u:" + data.base64EncodedString()]
                        snapshotPayloads[data] = payloadRef
                    }
                    annotation["/DrawbridgeSnapshotPDF"] = payloadRef
                    annotation["/DrawbridgeSnapshotStyle"] = "u:" + record.snapshotStyle.json
                }
                if record.pageScaleCleared { annotation["/DrawbridgePageScaleCleared"] = true; annotation["/F"] = 98 }
                if let scale = record.pageScale {
                    annotation["/DrawbridgePageScale"] = "u:" + MeasurementMetadata.json(scale)
                    annotation["/F"] = 98 // Hidden, NoView, ReadOnly; never printed.
                }
                if let measurement = record.measurement {
                    annotation["/DrawbridgeMeasurement"] = "u:" + MeasurementMetadata.json(measurement)
                    annotation["/Contents"] = "u:" + measurement.label(points: record.vertices)
                    // Semantic equality alone cannot validate a legacy unsplit AP.
                    // Version only distance appearances so other markups retain reuse.
                    if measurement.isDistance(points: record.vertices) { annotation["/DrawbridgeDimensionAppearanceVersion"] = 2 }
                }
                if let a = record.start, let z = record.end {
                    annotation["/L"] = [a.x,a.y,z.x,z.y]
                    annotation["/LE"] = ["/None",record.kind == .arrow ? "/OpenArrow" : "/None"]
                }
                if record.kind == .polygon {
                    annotation["/Vertices"] = record.vertices.flatMap { [Double($0.x),Double($0.y)] }
                    annotation["/DrawbridgePolylineVertices"] = record.vertices.flatMap { [Double($0.x),Double($0.y)] }
                }
                if [.rectangle, .ellipse, .polygon].contains(record.kind), let fill = record.fill { annotation["/IC"] = fill; annotation["/DrawbridgePolygonFill"] = fill }
                if record.kind == .polyline {
                    let values = record.vertices.flatMap { [Double($0.x),Double($0.y)] }
                    annotation["/InkList"] = [values]
                    annotation["/DrawbridgePolylineVertices"] = values
                }
                if record.kind == .text {
                    annotation.removeValue(forKey: "/C")
                    annotation["/DrawbridgeTextColor"] = [record.red,record.green,record.blue]
                    annotation["/DrawbridgeTextFontSize"] = record.fontSize
                    annotation["/Contents"] = "u:" + record.text
                    annotation["/DA"] = "u:/Helv \(record.fontSize) Tf \(record.red) \(record.green) \(record.blue) rg"
                    annotation["/DS"] = "u:font: Helvetica \(record.fontSize)pt; color: rgb(\(Int(record.red*255)),\(Int(record.green*255)),\(Int(record.blue*255)))"
                    annotation["/DR"] = ["/Font":["/Helv":["/Type":"/Font","/Subtype":"/Type1","/BaseFont":"/Helvetica"]]]
                    annotation["/BS"] = ["/W":0]; annotation["/Q"] = 0
                    annotation["/Rotate"] = record.textRotation
                }
                if let oldReference {
                    var old = dictionary(oldReference, objects: objects), desired = annotation
                    old.removeValue(forKey: "/AP"); desired.removeValue(forKey: "/AP")
                    if NSDictionary(dictionary: old).isEqual(to: desired) {
                        next -= 1 // No new appearance object is needed.
                        entries.append(oldReference)
                        continue
                    }
                }
                if record.kind == .snapshot {
                    objects["obj:\(appearanceRef)"] = try SnapshotAppearance.install(data: record.snapshotData!, bounds: b, rotation: record.textRotation, style: record.snapshotStyle, objects: &objects, next: &next, forms: &snapshotForms)
                    objects["obj:\(annotationRef)"] = ["value": annotation]; entries.append(annotationRef); continue
                }
                let drawing = appearanceDrawing(record)
                let isDimension = record.measurement?.isDistance(points: record.vertices) == true
                var resources: [String: Any] = ["/ExtGState": ["/MarkupGS": ["/Type": "/ExtGState", "/CA": record.strokeOpacity, "/ca": record.kind == .text || isDimension ? record.strokeOpacity : record.fillOpacity]]]
                if record.measurement != nil { resources["/Font"] = ["/MeasureFont": ["/Type": "/Font", "/Subtype": "/Type1", "/BaseFont": "/Helvetica"]] }
                if record.hatch != nil {
                    var states = resources["/ExtGState"] as! [String: Any]
                    states["/HatchGS"] = ["/Type": "/ExtGState", "/CA": record.fillOpacity, "/ca": record.fillOpacity]
                    resources["/ExtGState"] = states
                }
                objects["obj:\(appearanceRef)"] = ["stream": ["dict": ["/Type": "/XObject", "/Subtype": "/Form", "/BBox": [0,0,b.width,b.height], "/Resources": resources, "/DrawbridgeRectangleAppearance": true], "data": Data(drawing.utf8).base64EncodedString()]]
                objects["obj:\(annotationRef)"] = ["value": annotation]
                entries.append(annotationRef)
            }
            if entries.isEmpty { page.removeValue(forKey: "/Annots") } else { page["/Annots"] = entries }
            let carriers = (recordsByPage[index] ?? []).filter { $0.pageScale != nil || $0.pageScaleCleared }
            guard carriers.count <= 1 else { throw CocoaError(.fileWriteUnknown) }
            if let carrier = carriers.first {
                let standard = PDFPageScaleMetadata.scale(page: page, objects: objects)
                let desired = carrier.pageScale
                let equivalent = standard != nil && desired != nil && standard!.unit == desired!.unit && abs(standard!.unitsPerPoint - desired!.unitsPerPoint) <= desired!.unitsPerPoint * 1e-12
                let pending = document.page(at: index)?.annotations.contains { RectangleMarkupRecord.identity($0) == carrier.id && $0.value(forAnnotationKey: MeasurementMetadata.pendingScaleKey) as? Bool == true } == true
                let hasWhole = PDFPageScaleMetadata.entries(page, objects: objects).contains { PDFPageScaleMetadata.wholePage(PDFPageScaleMetadata.dictionary($0, objects: objects), page: PDFPageScaleMetadata.effectivePage(page, objects: objects)) }
                if !equivalent && (pending || !hasWhole) {
                    scaleViewports["obj:" + reference] = PDFPageScaleMetadata.install(scale: desired, page: &page, objects: &objects, next: &next)
                }
            }
            object["value"] = page; objects["obj:\(reference)"] = object
        }
        qpdf[0]["maxobjectid"] = next - 1; qpdf[1] = objects; json["qpdf"] = qpdf
        return scaleViewports
    }

    private static func subtype(_ kind: RectangleMarkupRecord.Kind) -> String {
        switch kind { case .snapshot: return "/Stamp"; case .rectangle: return "/Square"; case .ellipse: return "/Circle"; case .line, .arrow: return "/Line"; case .text: return "/FreeText"; case .polyline: return "/Ink"; case .polygon: return "/Polygon" }
    }

    /// Appearance coordinates are local to the annotation; page rotation is untouched.
    private static func appearanceDrawing(_ r: RectangleMarkupRecord) -> String {
        if r.pageScale != nil || r.pageScaleCleared { return "" }
        // The dimension appearance owns its split stroke, ticks, and arrows.
        // Do not paint the underlying InkList through the transparent label gap.
        if r.measurement?.isDistance(points: r.vertices) == true { return MeasurementAppearance.pdf(r) }
        let style = "/MarkupGS gs [" + r.linePattern.dash(width: CGFloat(r.lineWidth)).map { String($0) }.joined(separator: " ") + "] 0 d"
        let half = r.lineWidth/2, w = max(0,Double(r.bounds.width)-r.lineWidth), h = max(0,Double(r.bounds.height)-r.lineWidth)
        var path: String
        switch r.kind {
        case .snapshot: return ""
        case .polyline, .polygon:
            path = r.vertices.enumerated().map { i,p in "\(p.x-r.bounds.minX) \(p.y-r.bounds.minY) " + (i == 0 ? "m" : "l") }.joined(separator:" ")
        case .text: return "q /MarkupGS gs\n" + TextMarkupAppearance.drawing(r) + "\nQ"
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
        if r.kind == .polygon { path += " h" }
        if [.rectangle, .ellipse, .polygon].contains(r.kind) {
            if let hatch = r.hatch, hatch.preset != .solid {
                return hatch.pdf(path: path, size: r.bounds.size) + "q \(style) \(r.red) \(r.green) \(r.blue) RG \(r.lineWidth) w 1 j \(path) S Q\n" + MeasurementAppearance.pdf(r)
            }
            if let fill = r.fill { return "q \(style) \(r.red) \(r.green) \(r.blue) RG \(fill[0]) \(fill[1]) \(fill[2]) rg \(r.lineWidth) w 1 j \(path) B Q\n" + MeasurementAppearance.pdf(r) }
        }
        return "q \(style) \(r.red) \(r.green) \(r.blue) RG \(r.lineWidth) w 1 J 1 j \(path) S Q\n" + MeasurementAppearance.pdf(r)
    }

    private static func ownedRecordsMatch(_ json: [String: Any], records: [RectangleMarkupRecord]) throws -> Bool {
        let objects = try objectTable(json); let references = try pages(json)
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ("u:" + $0.id, $0) })
        var found = Set<String>()
        for (index, reference) in references.enumerated() {
            let page = (objects["obj:\(reference)"] as? [String: Any])?["value"] as? [String: Any] ?? [:]
            for entry in annotations(page["/Annots"], objects: objects) where owned(entry, objects: objects) {
                let value = dictionary(entry, objects: objects)
                guard let id = ownedIdentity(value),
                      value["/T"] as? String == "u:" + (recordsByID[id]?.author ?? ""),
                      let expected = recordsByID[id], expected.pageIndex == index,
                      value["/Subtype"] as? String == subtype(expected.kind),
                      let rect = value["/Rect"] as? [Double], rect.count == 4,
                      zip(rect, [expected.bounds.minX,expected.bounds.minY,expected.bounds.maxX,expected.bounds.maxY]).allSatisfy({ abs($0.0 - $0.1) < 0.0001 }),
                      let appearance = (value["/AP"] as? [String: Any])?["/N"] as? String,
                      (objects["obj:\(appearance)"] as? [String: Any])?["stream"] != nil,
                      found.insert(id).inserted else { return false }
                guard value["/DrawbridgeLinePattern"] as? String == "u:" + expected.linePattern.rawValue,
                      value["/DrawbridgeStrokeOpacity"] as? Double == expected.strokeOpacity,
                      value["/DrawbridgeFillOpacity"] as? Double == expected.fillOpacity else { return false }
                if value["/DrawbridgeLayerID"] as? String != expected.layerID.map({ "u:" + $0 }) || value["/DrawbridgeLayerCatalog"] as? String != expected.layerCatalog.map({ "u:" + $0 }) { return false }
                if value["/DrawbridgeHatchStyle"] as? String != expected.hatch.map({ "u:" + $0.json }) { return false }
                if let id = expected.layerID, value["/OC"] as? String != PDFMarkupLayersPatch.references(objects)[id] { return false }
                if expected.layerCatalog != nil && value["/F"] as? Int != 98 { return false }
                if let tool = expected.inkTool, value["/DrawbridgeInkTool"] as? String != "u:" + tool { return false }
                if expected.kind == .snapshot, value["/DrawbridgeSnapshotStyle"] as? String != "u:" + expected.snapshotStyle.json { return false }
                let payloadValue = value["/DrawbridgeSnapshotPDF"] as? String
                let payloadString = payloadValue.flatMap { ref in
                    (objects["obj:" + ref] as? [String:Any])?["value"] as? String ?? ref
                }
                if payloadString != expected.snapshotData.map({ "u:" + $0.base64EncodedString() }) { return false }
                if value["/DrawbridgeMeasurement"] as? String != expected.measurement.map({ "u:" + MeasurementMetadata.json($0) }) { return false }
                if value["/DrawbridgePageScale"] as? String != expected.pageScale.map({ "u:" + MeasurementMetadata.json($0) }) { return false }
                if let scale = expected.pageScale, (!scale.isValid || value["/F"] as? Int != 98) { return false }
                if (value["/DrawbridgePageScaleCleared"] as? Bool ?? false) != expected.pageScaleCleared { return false }
                if let measurement = expected.measurement, value["/Contents"] as? String != "u:" + measurement.label(points: expected.vertices) { return false }
                if expected.kind == .polygon {
                    guard value["/Vertices"] as? [Double] == expected.vertices.flatMap({ [Double($0.x),Double($0.y)] }) else { return false }
                }
                if [.rectangle, .ellipse, .polygon].contains(expected.kind), value["/IC"] as? [Double] != expected.fill { return false }
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
    private static func ownedIdentity(_ value: [String: Any]) -> String? {
        for key in ["/NM", "/T"] {
            if let name = value[key] as? String, name.hasPrefix("u:" + RectangleMarkupRecord.prefix) { return name }
        }
        return nil
    }
    private static func owned(_ entry: Any, objects: [String:Any]) -> Bool {
        let d = dictionary(entry, objects: objects)
        return ["/Square","/Circle","/Line","/FreeText","/Ink","/Polygon","/Stamp"].contains(d["/Subtype"] as? String ?? "") && ownedIdentity(d) != nil
    }
}

/// A file identity/version changes for both in-place writes and atomic replacement.
/// Nanosecond ctime also catches an external editor restoring the original mtime.
private struct MarkupFileVersion: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    static func read(_ url: URL) throws -> Self {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Self(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino), size: info.st_size,
                    modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                    changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
}

/// One bounded inspected version. Each save clones a frozen source snapshot;
/// metadata identity/version checks invalidate it after any external write.
private final class MarkupInspectionCache: @unchecked Sendable {
    static let byteBudget = 96 * 1024 * 1024
    struct Snapshot {
        let graph: [String: Any]
        let cost: Int
    }
    private struct Entry {
        let url: URL
        let version: MarkupFileVersion
        let snapshot: Snapshot
    }
    private let lock = NSLock()
    private var entry: Entry?

    func snapshot(for url: URL, version: MarkupFileVersion) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let entry, entry.url == url.standardizedFileURL, entry.version == version else { return nil }
        return entry.snapshot
    }

    func store(url: URL, graph: [String: Any], cost: Int, expectedVersion: MarkupFileVersion? = nil) throws {
        let version = try MarkupFileVersion.read(url)
        guard expectedVersion == nil || expectedVersion == version else { return }
        lock.lock(); defer { lock.unlock() }
        entry = cost <= Self.byteBudget ? Entry(url: url.standardizedFileURL, version: version, snapshot: Snapshot(graph: graph, cost: cost)) : nil
    }
}
