import Foundation

enum PDFPageLabelsEmbedder {
    enum EmbedError: Error {
        case unreadableDocument
        case malformedDocument
    }

    static func embedPageLabels(_ labels: [Int: String], in fileURL: URL) throws {
        let normalized = normalizedLabels(labels)
        guard !normalized.isEmpty else { return }

        var data = try Data(contentsOf: fileURL)
        guard let pdf = String(data: data, encoding: .isoLatin1) else {
            throw EmbedError.unreadableDocument
        }

        guard let startXrefMarker = pdf.range(of: "startxref", options: .backwards),
              let previousXrefOffset = parseTrailingInteger(in: pdf, after: startXrefMarker.upperBound),
              let trailerStart = pdf.range(of: "trailer", options: .backwards, range: pdf.startIndex..<startXrefMarker.lowerBound),
              let size = firstMatchInt(pattern: #"/Size\s+(\d+)"#, in: String(pdf[trailerStart.lowerBound..<startXrefMarker.lowerBound]), group: 1),
              let rootObjectNumber = firstMatchInt(pattern: #"/Root\s+(\d+)\s+(\d+)\s+R"#, in: String(pdf[trailerStart.lowerBound..<startXrefMarker.lowerBound]), group: 1),
              let rootGeneration = firstMatchInt(pattern: #"/Root\s+(\d+)\s+(\d+)\s+R"#, in: String(pdf[trailerStart.lowerBound..<startXrefMarker.lowerBound]), group: 2),
              let rootObjectRange = objectRange(objectNumber: rootObjectNumber, generation: rootGeneration, in: pdf) else {
            throw EmbedError.malformedDocument
        }

        let labelsObjectNumber = size
        let rootObject = String(pdf[rootObjectRange])
        let rewrittenRootObject = try rewriteRootObject(rootObject, labelsObjectNumber: labelsObjectNumber)
        let labelsObject = labelsObjectBody(objectNumber: labelsObjectNumber, labels: normalized)

        var appended = Data()
        var xrefEntries: [Int: (offset: Int, generation: Int)] = [:]

        let labelsOffset = data.count + appended.count
        appended.append(labelsObject.data(using: .utf8)!)
        xrefEntries[labelsObjectNumber] = (labelsOffset, 0)

        let rootOffset = data.count + appended.count
        appended.append(rewrittenRootObject.data(using: .utf8)!)
        xrefEntries[rootObjectNumber] = (rootOffset, rootGeneration)

        let xrefOffset = data.count + appended.count
        let newSize = max(size, labelsObjectNumber + 1)
        let xrefBlock = xrefBlockText(
            entries: xrefEntries,
            size: newSize,
            rootObjectNumber: rootObjectNumber,
            rootGeneration: rootGeneration,
            previousXrefOffset: previousXrefOffset,
            xrefOffset: xrefOffset
        )
        appended.append(xrefBlock.data(using: .utf8)!)

        data.append(appended)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func normalizedLabels(_ labels: [Int: String]) -> [(index: Int, label: String)] {
        labels.compactMap { index, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard index >= 0, !trimmed.isEmpty else { return nil }
            return (index, trimmed)
        }.sorted { $0.index < $1.index }
    }

    private static func labelsObjectBody(objectNumber: Int, labels: [(index: Int, label: String)]) -> String {
        var body = "\(objectNumber) 0 obj\n<< /Nums ["
        for entry in labels {
            body += "\n\(entry.index) << /P \(pdfHexUTF16String(entry.label)) >>"
        }
        body += "\n] >>\nendobj\n"
        return body
    }

    private static func rewriteRootObject(_ objectText: String, labelsObjectNumber: Int) throws -> String {
        let stripped = objectText.replacingOccurrences(
            of: #"/PageLabels\s+\d+\s+\d+\s+R"#,
            with: "",
            options: .regularExpression
        )
        guard let dictClose = stripped.range(of: ">>", options: .backwards) else {
            throw EmbedError.malformedDocument
        }
        var rewritten = stripped
        rewritten.insert(contentsOf: " /PageLabels \(labelsObjectNumber) 0 R", at: dictClose.lowerBound)
        return rewritten
    }

    private static func objectRange(objectNumber: Int, generation: Int, in pdf: String) -> Range<String.Index>? {
        let pattern = #"\b"# + "\(objectNumber)\\s+\(generation)\\s+obj\\b"
        guard let start = pdf.range(of: pattern, options: .regularExpression),
              let end = pdf.range(of: "endobj", range: start.upperBound..<pdf.endIndex) else {
            return nil
        }
        return start.lowerBound..<end.upperBound
    }

    private static func parseTrailingInteger(in text: String, after start: String.Index) -> Int? {
        let suffix = text[start...]
        guard let match = suffix.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(suffix[match])
    }

    private static func firstMatchInt(pattern: String, in text: String, group: Int) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: range), group < match.numberOfRanges else {
            return nil
        }
        let groupRange = match.range(at: group)
        guard groupRange.location != NSNotFound else { return nil }
        return Int(nsText.substring(with: groupRange))
    }

    private static func pdfHexUTF16String(_ value: String) -> String {
        let units = Array(value.utf16)
        var bytes: [UInt8] = [0xFE, 0xFF]
        bytes.reserveCapacity(2 + units.count * 2)
        for unit in units {
            bytes.append(UInt8((unit >> 8) & 0xFF))
            bytes.append(UInt8(unit & 0xFF))
        }
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        return "<\(hex)>"
    }

    private static func xrefBlockText(
        entries: [Int: (offset: Int, generation: Int)],
        size: Int,
        rootObjectNumber: Int,
        rootGeneration: Int,
        previousXrefOffset: Int,
        xrefOffset: Int
    ) -> String {
        let sorted = entries.keys.sorted()
        var lines: [String] = ["xref"]
        var index = 0
        while index < sorted.count {
            let start = sorted[index]
            var end = start
            while index + 1 < sorted.count, sorted[index + 1] == end + 1 {
                index += 1
                end = sorted[index]
            }
            let count = end - start + 1
            lines.append("\(start) \(count)")
            for object in start...end {
                let entry = entries[object]!
                lines.append(String(format: "%010d %05d n ", entry.offset, entry.generation))
            }
            index += 1
        }

        lines.append("trailer")
        lines.append("<< /Size \(size) /Root \(rootObjectNumber) \(rootGeneration) R /Prev \(previousXrefOffset) >>")
        lines.append("startxref")
        lines.append("\(xrefOffset)")
        lines.append("%%EOF")
        return lines.joined(separator: "\n") + "\n"
    }
}
