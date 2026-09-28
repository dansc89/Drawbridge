import AppKit
import PDFKit
import Vision

/// Region-based bookmark extraction. Deliberately independent of hyperlink token heuristics.
enum PDFBookmarkExtractor {
    enum Field { case number, title }
    struct Result {
        let text: String
        let source: String
        var alternatives: [String] = []
    }
    struct LocatedResult {
        let result: Result
        let normalizedXOffset: CGFloat
        let normalizedYOffset: CGFloat
    }
    struct Geometry {
        let bounds: CGRect
        let transform: CGAffineTransform
        init(page: PDFPage, box: PDFDisplayBox) {
            let raw = page.bounds(for: box).standardized
            let rotated = (page.rotation % 180) != 0
            bounds = CGRect(origin: .zero, size: rotated ? CGSize(width: raw.height, height: raw.width) : raw.size)
            let cgBox: CGPDFBox = box == .mediaBox ? .mediaBox : .cropBox
            transform = page.pageRef?.getDrawingTransform(cgBox, rect: bounds, rotate: 0, preserveAspectRatio: true) ?? .identity
        }
        func normalized(_ rect: CGRect) -> CGRect {
            let r = rect.applying(transform).intersection(bounds)
            guard !r.isNull, bounds.width > 0, bounds.height > 0 else { return .zero }
            return CGRect(x: r.minX / bounds.width, y: r.minY / bounds.height,
                          width: r.width / bounds.width, height: r.height / bounds.height)
        }
        func pageRect(_ normalized: CGRect) -> CGRect {
            displayedRect(normalized).applying(transform.inverted())
        }
        func displayedRect(_ normalized: CGRect) -> CGRect {
            CGRect(x: normalized.minX * bounds.width, y: normalized.minY * bounds.height,
                   width: normalized.width * bounds.width, height: normalized.height * bounds.height)
        }
    }

    static func outline(document: PDFDocument,
                        sheets: [(pageIndex: Int, number: String, title: String)],
                        destination: (PDFPage) -> PDFDestination) -> PDFOutline {
        let root = PDFOutline()
        for sheet in sheets {
            guard let page = document.page(at: sheet.pageIndex) else { continue }
            let item = PDFOutline()
            item.label = "\(sheet.number) - \(sheet.title.isEmpty ? "Untitled" : sheet.title)"
            item.destination = destination(page)
            root.insertChild(item, at: root.numberOfChildren)
        }
        return root
    }

    static func clean(_ raw: String) -> String {
        raw.precomposedStringWithCompatibilityMapping
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func value(_ raw: String, field: Field) -> String? {
        let lines = raw.components(separatedBy: .newlines).map(clean).filter { !$0.isEmpty }
            .filter { !["SHEET TITLE", "SHEET NAME", "SHEET NO", "SHEET NUMBER"].contains($0.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: ":. "))) }
        let text = clean(lines.joined(separator: " "))
        guard !text.isEmpty, !text.unicodeScalars.contains(where: {
            $0.value == 0xFFFD || (0xE000...0xF8FF).contains($0.value) || CharacterSet.controlCharacters.contains($0)
        }) else { return nil }
        switch field {
        case .number:
            // Survey title blocks commonly use a complete "SHEET n OF m SHEETS" field.
            if let match = text.range(of: #"^SHEET\s+[0-9]+\s+OF\s+[0-9]+(?:\s+SHEETS?)?$"#, options: [.regularExpression, .caseInsensitive]) {
                let parts = text[match].split(separator: " ")
                if let current = Int(parts[1]), let total = Int(parts[3]), current > 0, current <= total {
                    return String(current)
                }
                return nil
            }
            // A region is a field, not a bag of potential sheet references. Reject ambiguity.
            let compact = text.uppercased().replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "−", with: "-")
            guard compact.range(of: #"^(?:[A-Z]{1,4}[-._]?)?[0-9]{1,4}(?:[._-][0-9]{1,4}){0,2}[A-Z]?$"#, options: .regularExpression) != nil else { return nil }
            return compact
        case .title:
            guard text.count <= 240, text.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return nil }
            return text
        }
    }

    static func extract(page: PDFPage, rect: CGRect, box: PDFDisplayBox, field: Field) -> Result {
        let geometry = Geometry(page: page, box: box)
        let bounded = rect.intersection(page.bounds(for: box))
        guard !bounded.isNull, !bounded.isEmpty else { return Result(text: "", source: "outside page") }
        // Order by visible geometry, keeping every title line regardless of font size.
        let selection = page.selection(for: bounded)
        let lines = (selection?.selectionsByLine() ?? []).sorted {
            let a = $0.bounds(for: page).applying(geometry.transform)
            let b = $1.bounds(for: page).applying(geometry.transform)
            if abs(a.midY - b.midY) > min(a.height, b.height) * 0.5 { return a.midY > b.midY }
            return a.minX < b.minX
        }
        let native = lines.compactMap(\.string).joined(separator: "\n")
        let overlapping = lines.indices.contains { i in
            lines.indices.contains { j in
                guard j > i else { return false }
                let a = lines[i].bounds(for: page), b = lines[j].bounds(for: page)
                let overlap = a.intersection(b)
                return !overlap.isNull && overlap.width * overlap.height > min(a.width * a.height, b.width * b.height) * 0.25
            }
        }
        // PDFKit can merge overprinted runs into one selection line. Check glyphs too.
        var glyphs: [CGRect] = []
        let pageText = (page.string ?? "") as NSString
        if let selection {
            for index in 0..<selection.numberOfTextRanges(on: page) {
                let range = selection.range(at: index, on: page)
                guard range.location != NSNotFound, NSMaxRange(range) <= pageText.length else { continue }
                for offset in range.location..<NSMaxRange(range) {
                    guard !clean(pageText.substring(with: NSRange(location: offset, length: 1))).isEmpty else { continue }
                    let glyph = page.characterBounds(at: offset)
                    if glyph.width > 0, glyph.height > 0 { glyphs.append(glyph) }
                    if glyphs.count >= 2000 { break }
                }
                if glyphs.count >= 2000 { break }
            }
        }
        let overprintedGlyphs = glyphs.indices.contains { i in
            glyphs.indices.contains { j in
                guard j > i else { return false }
                let a = glyphs[i], b = glyphs[j], overlap = a.intersection(b)
                return !overlap.isNull && overlap.width * overlap.height > min(a.width * a.height, b.width * b.height) * 0.65
            }
        }
        if !overlapping, !overprintedGlyphs, let text = value(native, field: field) { return Result(text: text, source: "PDF text") }
        guard let image = render(page: page, rect: bounded, box: box) else { return Result(text: "", source: "render failed") }
        let primary = recognize(image: image, field: field)

        // Sample lower and higher resolutions: PDF rasterization can change OCR character choices.
        var readings = primary.text.isEmpty ? [] : [primary.text] + primary.alternatives
        let scales: [CGFloat] = field == .number ? [2, 6] : [2, 8]
        for scale in scales {
            guard let image = render(page: page, rect: bounded, box: box, requestedScale: scale) else { continue }
            let reading = recognize(image: image, field: field)
            for candidate in [reading.text] + reading.alternatives where !candidate.isEmpty && !readings.contains(candidate) {
                readings.append(candidate)
            }
        }
        guard let first = readings.first else { return primary }
        let chosen = field == .title ? preferredTitleReading(readings) : first
        return Result(text: chosen, source: readings.count == 1 ? "OCR" : "OCR disagreement", alternatives: readings.filter { $0 != chosen })
    }

    static func extractAdaptiveNumber(page: PDFPage, normalizedRect: CGRect,
                                      box: PDFDisplayBox) -> LocatedResult {
        let geometry = Geometry(page: page, box: box)
        let yOffsets: [CGFloat] = [0, -0.01, 0.01, -0.02, 0.02, -0.03, 0.03, -0.04, 0.04]
        let centeredXOffsets: [CGFloat] = [0, -0.01, 0.01, -0.02, 0.02, -0.03, 0.03]
        let shiftedXOffsets: [CGFloat] = [-0.03, -0.02, -0.01, 0, 0.01, 0.02, 0.03]
        var firstFailure = Result(text: "", source: "needs review")
        for yOffset in yOffsets {
            let xOffsets = yOffset == 0 ? centeredXOffsets : shiftedXOffsets
            for xOffset in xOffsets {
                let candidate = normalizedRect.offsetBy(dx: xOffset, dy: yOffset)
                guard geometry.bounds.contains(geometry.displayedRect(candidate)) else { continue }
                let pageRect = geometry.pageRect(candidate)
                if xOffset == 0, yOffset == 0 {
                    let result = extract(page: page, rect: pageRect, box: box, field: .number)
                    firstFailure = result
                    if !result.text.isEmpty {
                        return LocatedResult(result: result, normalizedXOffset: 0,
                                             normalizedYOffset: 0)
                    }
                    continue
                }
                guard let image = render(page: page, rect: pageRect, box: box, requestedScale: 2),
                      !recognize(image: image, field: .number).text.isEmpty else { continue }
                let verified = extract(page: page, rect: pageRect, box: box, field: .number)
                if !verified.text.isEmpty {
                    return LocatedResult(result: verified, normalizedXOffset: xOffset,
                                         normalizedYOffset: yOffset)
                }
            }
        }
        return LocatedResult(result: firstFailure, normalizedXOffset: 0, normalizedYOffset: 0)
    }

    static func preferredTitleReading(_ readings: [String]) -> String {
        guard let first = readings.first else { return "" }
        // Roman suffixes are often read as I| or Il. Select only a clean, actually observed
        // equivalent; do not rewrite an arbitrary title or infer a numeral from page order.
        let separator = " - "
        guard let range = first.range(of: separator, options: .backwards) else { return first }
        let prefix = String(first[..<range.upperBound])
        let suffix = String(first[range.upperBound...])
        guard suffix.range(of: #"^[IVXl|]+$"#, options: .regularExpression) != nil,
              suffix.contains("l") || suffix.contains("|") else { return first }
        let corrected = suffix.replacingOccurrences(of: "l", with: "I").replacingOccurrences(of: "|", with: "I")
        return readings.first { $0 == prefix + corrected } ?? first
    }

    static func resolveTitles(_ results: [Result], labelHints: [String?] = []) -> [Result] {
        let normalized: (String) -> String = { text in
            text.uppercased()
                .replacingOccurrences(of: "[^A-Z0-9]", with: "", options: .regularExpression)
        }
        var support: [String: Int] = [:]
        for result in results {
            let keys = Set(([result.text] + result.alternatives).filter { !$0.isEmpty }.map(normalized))
            for key in keys { support[key, default: 0] += 1 }
        }
        let observedTitles = Set(results.map { normalized($0.text) }.filter { !$0.isEmpty })
        return results.enumerated().map { index, result in
            guard result.source != "PDF text", !result.alternatives.isEmpty else { return result }
            if index < labelHints.count, let hint = labelHints[index], !hint.isEmpty {
                let left = normalized(result.text), right = normalized(hint)
                let denominator = max(left.count, right.count, 1)
                let resultWords = Set(result.text.uppercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
                let hintWords = Set(hint.uppercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
                let overlap = hintWords.isEmpty ? 0 : Double(resultWords.intersection(hintWords).count) / Double(hintWords.count)
                let closeReading = overlap >= 0.65 &&
                    Double(editDistance(left, right)) / Double(denominator) <= 0.35
                let peerSupported = overlap >= 0.5 && observedTitles.contains(right)
                if closeReading || peerSupported {
                    return Result(text: hint, source: "OCR (label-disambiguated)",
                                  alternatives: Array(Set([result.text] + result.alternatives).filter { $0 != hint }).sorted())
                }
            }
            let candidates = [result.text] + result.alternatives
            let ranked = candidates.sorted { lhs, rhs in
                let lhsSupport = support[normalized(lhs), default: 0]
                let rhsSupport = support[normalized(rhs), default: 0]
                if lhsSupport != rhsSupport { return lhsSupport > rhsSupport }
                let lhsNoise = lhs.unicodeScalars.filter { !CharacterSet.alphanumerics.union(.whitespaces).contains($0) }.count
                let rhsNoise = rhs.unicodeScalars.filter { !CharacterSet.alphanumerics.union(.whitespaces).contains($0) }.count
                return lhsNoise < rhsNoise
            }
            guard let chosen = ranked.first, chosen != result.text,
                  support[normalized(chosen), default: 0] >= 2 else { return result }
            return Result(text: chosen, source: "OCR (peer-supported alternative)",
                          alternatives: candidates.filter { $0 != chosen })
        }
    }

    static func recognizedValue(_ lines: [String], field: Field) -> String? {
        if field == .number {
            let valid = Set(lines.compactMap { value($0, field: .number) })
            if valid.count == 1 {
                if let token = valid.first, token.range(of: #"^[0-9]+(?:[._-][0-9]+)*$"#, options: .regularExpression) != nil,
                   lines.count == 2, lines.contains(where: { clean($0).range(of: #"^[A-Z]{1,4}$"#, options: .regularExpression) != nil }) {
                    return value(lines.joined(), field: .number)
                }
                return valid.first
            }
            if valid.count > 1 { return nil }
        }
        return value(lines.joined(separator: "\n"), field: field)
    }

    static func recognize(image: CGImage, field: Field) -> Result {
        // Upright first. Only try other orientations if no valid reading exists.
        for orientation: CGImagePropertyOrientation in [.up, .right, .left, .down] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = field == .title
            request.minimumTextHeight = 0
            do {
                try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([request])
                let observations = (request.results ?? []).sorted {
                    let a = $0.boundingBox, b = $1.boundingBox
                    if abs(a.midY - b.midY) > min(a.height, b.height) * 0.5 { return a.midY > b.midY }
                    return a.minX < b.minX
                }
                let candidateSets = observations.map { $0.topCandidates(3) }
                let topCandidates = candidateSets.compactMap(\.first)
                if !topCandidates.isEmpty, topCandidates.allSatisfy({ $0.confidence >= 0.3 }),
                   let text = recognizedValue(topCandidates.map(\.string), field: field) {
                    var alternatives: [String] = []
                    for rank in 1..<3 {
                        let lines = candidateSets.compactMap { rank < $0.count ? $0[rank].string : $0.first?.string }
                        if let alternate = recognizedValue(lines, field: field), alternate != text,
                           !alternatives.contains(alternate) {
                            alternatives.append(alternate)
                        }
                    }
                    return Result(text: text, source: alternatives.isEmpty ? "OCR" : "OCR candidates",
                                  alternatives: alternatives)
                }
            } catch { return Result(text: "", source: "OCR failed") }
        }
        return Result(text: "", source: "needs review")
    }

    static func numberFormat(_ text: String) -> String {
        text.replacingOccurrences(of: "[0-9]", with: "#", options: .regularExpression)
    }

    /// Resolve only OCR-observed alternatives supported by at least two distinct peer identifiers.
    /// Never rewrite native text, consult stale labels, or invent a character replacement.
    static func resolveNumbers(_ results: [Result], labelHints: [String?] = []) -> [Result] {
        let support = Dictionary(grouping: results.filter { !$0.text.isEmpty }, by: { numberFormat($0.text) })
            .mapValues { Set($0.map(\.text)).count }
        let readingCounts = Dictionary(grouping: results.filter { !$0.text.isEmpty }, by: \.text)
            .mapValues(\.count)
        var resolved = results.enumerated().map { index, result in
            guard result.source != "PDF text" else { return result }
            let stableDuplicate = result.alternatives.isEmpty && readingCounts[result.text, default: 0] > 1
            let visualSupportedElsewhere = labelHints.enumerated().contains {
                $0.offset != index && $0.element == result.text
            }
            if index < labelHints.count, let hint = labelHints[index],
               !stableDuplicate, !visualSupportedElsewhere,
               support[numberFormat(hint), default: 0] >= 2,
               (!result.alternatives.isEmpty || result.text.isEmpty ||
                support[numberFormat(result.text), default: 0] < 2) {
                return Result(text: hint, source: "OCR (label-disambiguated)",
                              alternatives: Array(Set([result.text] + result.alternatives).filter { $0 != hint }).sorted())
            }
            guard !result.alternatives.isEmpty,
                  support[numberFormat(result.text), default: 0] < 2 else { return result }
            let supported = Set(result.alternatives.filter { support[numberFormat($0), default: 0] >= 2 })
            if index < labelHints.count, let hint = labelHints[index],
               ([result.text] + result.alternatives).contains(hint) {
                return Result(text: hint, source: "OCR (label-matched alternative)",
                              alternatives: Array(Set([result.text] + result.alternatives).filter { $0 != hint }).sorted())
            }
            guard supported.count == 1, let chosen = supported.first else { return result }
            return Result(text: chosen, source: "OCR (format-supported alternative)", alternatives: [result.text])
        }
        if resolved.count >= 2 {
            for index in resolved.indices {
                let result = resolved[index]
                let readings = [result.text] + result.alternatives
                let hasTwoNeighbors = index > 0 && index + 1 < resolved.count
                guard result.source.hasPrefix("OCR"), index < labelHints.count,
                      let hint = labelHints[index],
                      (hasTwoNeighbors || !result.alternatives.isEmpty ||
                       support[numberFormat(result.text), default: 0] < 2),
                      readings.map({ editDistance($0, hint) }).min() ?? .max <= 3,
                      (isOrderedSheetHint(
                            hint,
                            after: index > 0 ? resolved[index - 1].text : nil,
                            before: index + 1 < resolved.count ? resolved[index + 1].text : nil
                       ) || (readingCounts[result.text, default: 0] > 1 &&
                             isAdjacentSheetHint(hint, to: result.text))) else { continue }
                resolved[index] = Result(text: hint, source: "OCR (sequence-disambiguated)",
                    alternatives: Array(Set([result.text] + result.alternatives).filter { $0 != hint }).sorted())
            }
        }
        return resolved
    }

    static func isOrderedSheetHint(_ hint: String, after previous: String?, before next: String?) -> Bool {
        func series(_ value: String) -> String {
            if let dot = value.firstIndex(of: ".") { return String(value[..<dot]) }
            return String(value.prefix { $0.isLetter })
        }
        if let previous {
            guard !previous.isEmpty, series(hint) == series(previous),
                  previous.localizedStandardCompare(hint) == .orderedAscending else { return false }
        }
        if let next {
            guard !next.isEmpty, series(hint) == series(next),
                  hint.localizedStandardCompare(next) == .orderedAscending else { return false }
        }
        return previous != nil || next != nil
    }

    static func isAdjacentSheetHint(_ hint: String, to reading: String) -> Bool {
        let hintParts = hint.split(separator: ".", maxSplits: 1).map(String.init)
        let readingParts = reading.split(separator: ".", maxSplits: 1).map(String.init)
        guard hintParts.count == 2, readingParts.count == 2,
              hintParts[0] == readingParts[0],
              let hintSuffix = Int(hintParts[1]), let readingSuffix = Int(readingParts[1]) else { return false }
        return abs(hintSuffix - readingSuffix) == 1
    }

    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1]
            for (j, right) in b.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1,
                                   previous[j] + (left == right ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    static func render(page: PDFPage, rect: CGRect, box: PDFDisplayBox, requestedScale: CGFloat = 4) -> CGImage? {
        guard let ref = page.pageRef else { return nil }
        let geometry = Geometry(page: page, box: box)
        let crop = rect.applying(geometry.transform).intersection(geometry.bounds)
        guard !crop.isNull, crop.width > 0, crop.height > 0 else { return nil }
        // Allocate only the selected region; large sheets must not disable OCR.
        let scale = min(requestedScale, 4096 / max(crop.width, crop.height))
        let width = Int(ceil(crop.width * scale)), height = Int(ceil(crop.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -crop.minX, y: -crop.minY)
        context.concatenate(geometry.transform)
        context.drawPDFPage(ref)
        return context.makeImage()
    }
}
