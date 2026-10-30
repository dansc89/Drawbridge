import Foundation
import Darwin

/// Page selection through qpdf; preserves vector content and annotation appearances.
enum PDFPageExtractor {
    static func extract(source: URL, destination: URL, indices: [Int], protectedSources: [URL] = [],
                        helper: URL? = PDFTKBookmarkWriter.executableURL()) throws {
        func fail(_ text: String) -> NSError { NSError(domain:"DrawbridgeExtract",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }
        let fm = FileManager.default
        guard let helper, source.isFileURL, destination.isFileURL else { throw fail("The PDF processing helper is unavailable.") }
        let pages = Array(Set(indices)).sorted()
        guard !pages.isEmpty, pages.allSatisfy({ $0 >= 0 }) else { throw fail("Choose at least one valid page.") }
        let output = destination.standardizedFileURL.resolvingSymlinksInPath()
        let protected = [source] + protectedSources
        func identity(_ url: URL) throws -> String {
            let a = try fm.attributesOfItem(atPath:url.path)
            guard let device=a[.systemNumber],let inode=a[.systemFileNumber] else { throw fail("Could not verify file identity safely.") }
            return "\(device)|\(inode)"
        }
        func checkDestination() throws {
            for original in protected {
                guard original.standardizedFileURL.resolvingSymlinksInPath() != output else { throw fail("Save the extracted pages to a different PDF. The original must remain unchanged.") }
                if fm.fileExists(atPath:output.path), fm.fileExists(atPath:original.path), try identity(output) == identity(original) {
                    throw fail("The destination is an alias of an open or source PDF. Choose another filename.")
                }
            }
        }
        try checkDestination()
        let dir = output.deletingLastPathComponent().appendingPathComponent(".DrawbridgeExtract-\(UUID())")
        try fm.createDirectory(at:dir,withIntermediateDirectories:false)
        defer { try? fm.removeItem(at:dir) }
        let snapshot = dir.appendingPathComponent("input.pdf"), staged = dir.appendingPathComponent("selected.pdf")
        try fm.copyItem(at:source,to:snapshot)
        func run(_ args: [String]) throws {
            guard PDFTKBookmarkWriter.run(helper,arguments:args) else { throw fail("Could not extract these pages. No output was replaced.") }
        }
        func inspect(_ url: URL) throws -> [String:Any] {
            let json = dir.appendingPathComponent("inspect.json")
            try run(["--json=2","--json-stream-data=none",url.path,json.path])
            return try JSONSerialization.jsonObject(with:Data(contentsOf:json)) as? [String:Any] ?? [:]
        }
        let input = try inspect(snapshot)
        guard let sourcePages = input["pages"] as? [[String:Any]], pages.last! < sourcePages.count else { throw fail("A page number is outside this document.") }
        guard let encrypt = input["encrypt"] as? [String:Any], encrypt["encrypted"] as? Bool == false else { throw fail("Save an unencrypted copy before extracting pages.") }
        if let objects = (input["qpdf"] as? [[String:Any]])?.last,
           objects.values.contains(where: { let d = ($0 as? [String:Any])?["value"] as? [String:Any]; return d?["/FT"] as? String == "/Sig" || d?["/Type"] as? String == "/Sig" }) {
            throw fail("Save an unsigned copy before extracting pages.")
        }
        try run([snapshot.path,"--stream-data=preserve","--pages",".",pages.map { String($0+1) }.joined(separator:","),"--",staged.path])
        var json = try inspect(staged)
        guard let selected = json["pages"] as? [[String:Any]], selected.count == pages.count else { throw fail("The extracted page count could not be verified.") }
        // Retain Drawbridge flatten recovery only for the exported pages, in order.
        if var tables = json["qpdf"] as? [[String:Any]], tables.count == 2,
           let trailer = tables[1]["trailer"] as? [String:Any], let value = trailer["value"] as? [String:Any],
           let root = value["/Root"] as? String, var entry = tables[1]["obj:"+root] as? [String:Any],
           var catalog = entry["value"] as? [String:Any], var archive = catalog["/DrawbridgeUnflattenData"] as? [String:Any] {
            guard let original = archive["/Pages"] as? [[String:Any]] else { throw fail("Invalid flatten recovery data. No output was replaced.") }
            var kept = [[String:Any]]()
            for page in selected {
                let matches = original.filter { $0["/Page"] as? String == page["object"] as? String }
                guard matches.count == 1 else { throw fail("Flatten recovery could not be preserved. No output was replaced.") }
                kept.append(matches[0])
            }
            archive["/Pages"] = kept; catalog["/DrawbridgeUnflattenData"] = archive; entry["value"] = catalog
            tables[1]["obj:"+root] = entry; json["qpdf"] = tables
            let patch = dir.appendingPathComponent("recovery.json"), repaired = dir.appendingPathComponent("recovered.pdf")
            try PDFJSONPatchEncoder.data(withJSONObject:PDFAnnotationFlattener.metadataJSON(json),options:[.sortedKeys,.withoutEscapingSlashes]).write(to:patch)
            try run([staged.path,"--stream-data=preserve","--update-from-json=\(patch.path)",repaired.path])
            try fm.removeItem(at:staged);try fm.moveItem(at:repaired,to:staged)
        }
        try run(["--check",staged.path])
        guard try Data(contentsOf:source,options:.mappedIfSafe) == Data(contentsOf:snapshot,options:.mappedIfSafe) else { throw fail("The source changed during extraction. Try again.") }
        try checkDestination()
        guard Darwin.rename(staged.path,output.path) == 0 else { throw fail("Could not save the extracted PDF. The destination was left unchanged.") }
    }
}
