import Foundation
import PDFKit

/// Creates a disposable text-reading copy for AutoCAD ToUnicode maps that
/// Apple rejects. Drawing streams and the user's document are never rewritten.
enum PDFSelectableTextRecovery {
    static func normalizedCMap(_ source: String) -> String? {
        guard source.contains("begincmap"), source.contains("(def)"),
              let start = source.range(of: #"\d+\s+begincodespacerange"#, options: .regularExpression),
              let end = source.range(of: "endcmap"), start.lowerBound < end.lowerBound else { return nil }
        let mappings = source[start.lowerBound..<end.lowerBound]
        return """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /Adobe-Identity-UCS def
        /CMapType 2 def
        \(mappings)
        endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end

        """
    }

    static func document(for sourceURL: URL) -> PDFDocument? {
        guard sourceURL.isFileURL, let executable = PDFTKBookmarkWriter.executableURL() else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeTextRecovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let jsonURL = directory.appendingPathComponent("maps.json")
            guard PDFTKBookmarkWriter.run(executable, arguments: ["--json=2", "--json-key=qpdf", sourceURL.path, jsonURL.path]),
                  let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any] else { return nil }
            var references = Set<String>()
            func collect(_ value: Any) {
                if let dictionary = value as? [String: Any] {
                    if let reference = dictionary["/ToUnicode"] as? String { references.insert(reference) }
                    for child in dictionary.values { collect(child) }
                } else if let array = value as? [Any] { array.forEach(collect) }
            }
            collect(metadata)
            guard !references.isEmpty else { return nil }
            let arguments = ["--json=2", "--json-key=qpdf", "--json-stream-data=inline"]
                + references.sorted().map { "--json-object=\($0)" } + [sourceURL.path, jsonURL.path]
            guard PDFTKBookmarkWriter.run(executable, arguments: arguments),
                  var json = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any],
                  var qpdf = json["qpdf"] as? [[String: Any]], qpdf.count == 2 else { return nil }
            var changed: [String: Any] = [:]
            for (key, value) in qpdf[1] {
                guard var object = value as? [String: Any], var stream = object["stream"] as? [String: Any],
                      let encoded = stream["data"] as? String, let data = Data(base64Encoded: encoded),
                      let text = String(data: data, encoding: .utf8), let repaired = normalizedCMap(text) else { continue }
                stream["data"] = Data(repaired.utf8).base64EncodedString()
                object["stream"] = stream
                changed[key] = object
            }
            guard !changed.isEmpty else { return nil }
            qpdf[1] = changed
            json["qpdf"] = qpdf
            try JSONSerialization.data(withJSONObject: json).write(to: jsonURL)
            let output = directory.appendingPathComponent("text-only.pdf")
            guard PDFTKBookmarkWriter.run(executable, arguments: [sourceURL.path, "--update-from-json=\(jsonURL.path)", output.path]) else { return nil }
            return PDFDocument(data: try Data(contentsOf: output))
        } catch { return nil }
    }
}
