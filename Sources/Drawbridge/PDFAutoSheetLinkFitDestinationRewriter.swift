import Foundation

enum PDFAutoSheetLinkFitDestinationRewriter {
    enum DestinationMode: CaseIterable {
        case fit
        case fitH
        case fitR
        case xyzZero

        var suffix: String {
            switch self {
            case .fit: return "fit"
            case .fitH: return "fith"
            case .fitR: return "fitr"
            case .xyzZero: return "xyz0"
            }
        }
    }

    enum RewriteError: Error {
        case unreadableDocument
        case malformedDocument
    }

    static func rewriteAutoSheetLinksToFit(in fileURL: URL, marker: String = "DrawbridgeAutoSheetLink") throws {
        try rewriteAutoSheetLinks(in: fileURL, marker: marker, destinationMode: .fit)
    }

    static func rewriteAutoSheetLinks(
        in fileURL: URL,
        marker: String = "DrawbridgeAutoSheetLink",
        destinationMode: DestinationMode
    ) throws {
        var data = try Data(contentsOf: fileURL)
        guard let pdf = String(data: data, encoding: .isoLatin1) else {
            throw RewriteError.unreadableDocument
        }

        guard let startXrefMarker = pdf.range(of: "startxref", options: .backwards),
              let previousXrefOffset = parseTrailingInteger(in: pdf, after: startXrefMarker.upperBound),
              let trailerStart = pdf.range(of: "trailer", options: .backwards, range: pdf.startIndex..<startXrefMarker.lowerBound),
              let size = firstMatchInt(pattern: #"/Size\s+(\d+)"#, in: String(pdf[trailerStart.lowerBound..<startXrefMarker.lowerBound]), group: 1),
              let rootObjectNumber = firstMatchInt(pattern: #"/Root\s+(\d+)\s+(\d+)\s+R"#, in: String(pdf[trailerStart.lowerBound..<startXrefMarker.lowerBound]), group: 1),
              let rootGeneration = firstMatchInt(pattern: #"/Root\s+(\d+)\s+(\d+)\s+R"#, in: String(pdf[trailerStart.lowerBound..<startXrefMarker.lowerBound]), group: 2) else {
            throw RewriteError.malformedDocument
        }

        let objectRegex = try NSRegularExpression(pattern: #"\b(\d+)\s+(\d+)\s+obj\b"#)
        let nsPDF = pdf as NSString
        let fullRange = NSRange(location: 0, length: nsPDF.length)
        let objectMatches = objectRegex.matches(in: pdf, range: fullRange)
        if objectMatches.isEmpty { return }

        let pageObjects = collectPageObjects(pdf: pdf, matches: objectMatches, nsPDF: nsPDF)
        if pageObjects.isEmpty {
            throw RewriteError.malformedDocument
        }

        var replacements: [(objectNumber: Int, generation: Int, text: String)] = []
        replacements.reserveCapacity(32)
        var replacementMap: [Int: (generation: Int, text: String)] = [:]
        replacementMap.reserveCapacity(64)
        let markerRegex = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: marker) + #":(\d+)"#)
        var actionObjectTargets: [Int: (generation: Int, pageRef: (objectNumber: Int, generation: Int))] = [:]
        actionObjectTargets.reserveCapacity(32)

        for (index, match) in objectMatches.enumerated() {
            let objectNumber = Int(nsPDF.substring(with: match.range(at: 1))) ?? -1
            let generation = Int(nsPDF.substring(with: match.range(at: 2))) ?? 0
            guard objectNumber >= 0 else { continue }

            let objectStart = match.range.location
            let objectEnd: Int
            if index + 1 < objectMatches.count {
                objectEnd = objectMatches[index + 1].range.location
            } else {
                objectEnd = (pdf as NSString).range(of: "startxref", options: .backwards).location
            }
            guard objectEnd > objectStart else { continue }
            let objectText = nsPDF.substring(with: NSRange(location: objectStart, length: objectEnd - objectStart))

            guard objectText.contains("/Subtype /Link"),
                  objectText.contains(marker) else {
                continue
            }

            let nsObject = objectText as NSString
            let nsObjectRange = NSRange(location: 0, length: nsObject.length)
            guard let markerMatch = markerRegex.firstMatch(in: objectText, range: nsObjectRange),
                  markerMatch.numberOfRanges > 1 else {
                continue
            }
            let pageIndexText = nsObject.substring(with: markerMatch.range(at: 1))
            guard let pageIndex = Int(pageIndexText),
                  pageIndex >= 0,
                  pageIndex < pageObjects.count else {
                continue
            }
            let pageRef = pageObjects[pageIndex]
            let destination = destinationArray(for: pageRef, mode: destinationMode)
            if let actionRef = firstActionReference(in: objectText) {
                actionObjectTargets[actionRef.objectNumber] = (generation: actionRef.generation, pageRef: pageRef)
            }
            let rewritten = rewriteLinkObject(objectText, destinationArray: destination, preserveIndirectActionReference: true)
            guard rewritten != objectText else { continue }
            replacementMap[objectNumber] = (generation, rewritten)
        }

        if !actionObjectTargets.isEmpty {
            for (index, match) in objectMatches.enumerated() {
                let objectNumber = Int(nsPDF.substring(with: match.range(at: 1))) ?? -1
                let generation = Int(nsPDF.substring(with: match.range(at: 2))) ?? 0
                guard objectNumber >= 0 else { continue }
                guard let target = actionObjectTargets[objectNumber] else { continue }
                guard generation == target.generation else { continue }

                let objectStart = match.range.location
                let objectEnd: Int
                if index + 1 < objectMatches.count {
                    objectEnd = objectMatches[index + 1].range.location
                } else {
                    objectEnd = (pdf as NSString).range(of: "startxref", options: .backwards).location
                }
                guard objectEnd > objectStart else { continue }
                let objectText = nsPDF.substring(with: NSRange(location: objectStart, length: objectEnd - objectStart))
                let destination = destinationArray(for: target.pageRef, mode: destinationMode)
                let rewritten = rewriteActionObject(objectText, destinationArray: destination)
                guard rewritten != objectText else { continue }
                replacementMap[objectNumber] = (generation, rewritten)
            }
        }

        if replacementMap.isEmpty {
            // Fallback to raw token rewrites for non-marked links created by legacy builds.
            if try rewriteXYZNullDestinationsInPlace(data: &data, destinationMode: destinationMode) {
                try data.write(to: fileURL, options: .atomic)
            }
            return
        }
        replacements = replacementMap.keys.sorted().compactMap { objectNumber in
            guard let value = replacementMap[objectNumber] else { return nil }
            return (objectNumber: objectNumber, generation: value.generation, text: value.text)
        }

        var appended = Data()
        var xrefEntries: [Int: (offset: Int, generation: Int)] = [:]
        xrefEntries.reserveCapacity(replacements.count)

        for replacement in replacements {
            let offset = data.count + appended.count
            appended.append(replacement.text.data(using: .utf8)!)
            xrefEntries[replacement.objectNumber] = (offset, replacement.generation)
        }

        let xrefOffset = data.count + appended.count
        let xrefText = xrefBlockText(
            entries: xrefEntries,
            size: size,
            rootObjectNumber: rootObjectNumber,
            rootGeneration: rootGeneration,
            previousXrefOffset: previousXrefOffset,
            xrefOffset: xrefOffset
        )
        appended.append(xrefText.data(using: .utf8)!)
        data.append(appended)
        try data.write(to: fileURL, options: .atomic)
    }

    static func exportCompatibilityVariants(
        for sourceURL: URL,
        outputDirectory: URL? = nil,
        marker: String = "DrawbridgeAutoSheetLink"
    ) throws -> [URL] {
        let directory = outputDirectory ?? sourceURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension.isEmpty ? "pdf" : sourceURL.pathExtension

        var outputs: [URL] = []
        for mode in DestinationMode.allCases {
            let out = directory.appendingPathComponent("\(baseName).links-\(mode.suffix).\(ext)")
            if FileManager.default.fileExists(atPath: out.path) {
                try FileManager.default.removeItem(at: out)
            }
            try FileManager.default.copyItem(at: sourceURL, to: out)
            try rewriteAutoSheetLinks(in: out, marker: marker, destinationMode: mode)
            outputs.append(out)
        }
        return outputs
    }

    private static func collectPageObjects(
        pdf: String,
        matches: [NSTextCheckingResult],
        nsPDF: NSString
    ) -> [(objectNumber: Int, generation: Int)] {
        var pages: [(objectNumber: Int, generation: Int)] = []
        pages.reserveCapacity(256)
        for (index, match) in matches.enumerated() {
            let objectNumber = Int(nsPDF.substring(with: match.range(at: 1))) ?? -1
            let generation = Int(nsPDF.substring(with: match.range(at: 2))) ?? 0
            guard objectNumber >= 0 else { continue }

            let objectStart = match.range.location
            let objectEnd: Int
            if index + 1 < matches.count {
                objectEnd = matches[index + 1].range.location
            } else {
                objectEnd = (pdf as NSString).range(of: "startxref", options: .backwards).location
            }
            guard objectEnd > objectStart else { continue }
            let objectText = nsPDF.substring(with: NSRange(location: objectStart, length: objectEnd - objectStart))
            if objectText.range(of: #"/Type\s*/Page\b"#, options: .regularExpression) != nil {
                pages.append((objectNumber, generation))
            }
        }
        return pages
    }

    private static func destinationArray(
        for pageRef: (objectNumber: Int, generation: Int),
        mode: DestinationMode
    ) -> String {
        let head = "\(pageRef.objectNumber) \(pageRef.generation) R"
        switch mode {
        case .fit:
            return "[ \(head) /Fit ]"
        case .fitH:
            return "[ \(head) /FitH 99999 ]"
        case .fitR:
            return "[ \(head) /FitR 0 0 9999 9999 ]"
        case .xyzZero:
            return "[ \(head) /XYZ 0 0 0 ]"
        }
    }

    private static func firstActionReference(in objectText: String) -> (objectNumber: Int, generation: Int)? {
        guard let regex = try? NSRegularExpression(pattern: #"/A\s+(\d+)\s+(\d+)\s+R"#),
              let match = regex.firstMatch(in: objectText, range: NSRange(location: 0, length: (objectText as NSString).length)) else {
            return nil
        }
        let ns = objectText as NSString
        guard let objectNumber = Int(ns.substring(with: match.range(at: 1))),
              let generation = Int(ns.substring(with: match.range(at: 2))) else {
            return nil
        }
        return (objectNumber, generation)
    }

    private static func rewriteActionObject(_ objectText: String, destinationArray: String) -> String {
        var rewritten = objectText
        let dPattern = #"/D\s*(\[[^\]]*\]|\([^\)]*\)|/[A-Za-z0-9#_.-]+|\d+\s+\d+\s+R)"#
        if let updated = replacingFirstMatch(pattern: dPattern, in: rewritten, with: "/D \(destinationArray)") {
            rewritten = updated
        } else if let dictClose = rewritten.range(of: ">>", options: .backwards) {
            rewritten.insert(contentsOf: " /D \(destinationArray)", at: dictClose.lowerBound)
        }
        if rewritten.range(of: #"/S\s*/GoTo\b"#, options: .regularExpression) == nil {
            if let dictClose = rewritten.range(of: ">>", options: .backwards) {
                rewritten.insert(contentsOf: " /S /GoTo", at: dictClose.lowerBound)
            }
        }
        return rewritten
    }

    private static func rewriteLinkObject(
        _ objectText: String,
        destinationArray: String,
        preserveIndirectActionReference: Bool
    ) -> String {
        var rewritten = objectText

        rewritten = rewritten.replacingOccurrences(
            of: #"/Dest\s*\[[^\]]*\]"#,
            with: "",
            options: .regularExpression
        )
        rewritten = rewritten.replacingOccurrences(
            of: #"/Dest\s+\d+\s+\d+\s+R"#,
            with: "",
            options: .regularExpression
        )

        let actionText = "/A << /S /GoTo /D \(destinationArray) >>"
        if let updated = replacingFirstMatch(
            pattern: #"/A\s*<<[\s\S]*?>>"#,
            in: rewritten,
            with: actionText
        ) {
            rewritten = updated
        } else if preserveIndirectActionReference,
                  rewritten.range(of: #"/A\s+\d+\s+\d+\s+R"#, options: .regularExpression) != nil {
            // Keep indirect /A reference; target action object is rewritten separately.
            return rewritten
        } else if let dictClose = rewritten.range(of: ">>", options: .backwards) {
            rewritten.insert(contentsOf: " \(actionText)", at: dictClose.lowerBound)
        }
        return rewritten
    }

    private static func replacingFirstMatch(pattern: String, in text: String, with replacement: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }
        return regex.stringByReplacingMatches(in: text, options: [], range: match.range, withTemplate: replacement)
    }

    private static func rewriteXYZNullDestinationsInPlace(data: inout Data, destinationMode: DestinationMode) throws -> Bool {
        let xyzSource = Data("/XYZ null null null".utf8)
        let fitSource = Data("/Fit               ".utf8) // 19 bytes
        let fitRSource = Data("/FitR 0 0 9999 9999".utf8)
        let xyzZeroSource = Data("/XYZ 0 0 0         ".utf8)
        let fitHTarget = Data("/FitH 99999        ".utf8)
        let fitRTarget = Data("/FitR 0 0 9999 9999".utf8)
        let xyzTarget = Data("/XYZ 0 0 0         ".utf8)
        let fitTarget = Data("/Fit               ".utf8)
        let target: Data
        switch destinationMode {
        case .fit: target = fitTarget
        case .fitH: target = fitHTarget
        case .fitR: target = fitRTarget
        case .xyzZero: target = xyzTarget
        }
        guard xyzSource.count == target.count,
              fitSource.count == target.count,
              fitRSource.count == target.count,
              xyzZeroSource.count == target.count else {
            return false
        }

        var replacedAny = false
        for source in [xyzSource, fitSource, fitRSource, xyzZeroSource] {
            var searchStart = data.startIndex
            while searchStart < data.endIndex,
                  let range = data.range(of: source, in: searchStart..<data.endIndex) {
                data.replaceSubrange(range, with: target)
                replacedAny = true
                searchStart = range.lowerBound + target.count
            }
        }
        return replacedAny
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
