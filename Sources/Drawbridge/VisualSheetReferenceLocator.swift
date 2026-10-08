import AppKit
import PDFKit
import Vision

/// Font recovery is useful for finding references, but its selection metrics are
/// not authoritative. Locate the visible word in nearby rendered pixels instead.
enum VisualSheetReferenceLocator {
    typealias Hit = (token: String, bounds: NSRect)

    static func locate(on page: PDFPage, hints: [Hit], observedText: ((String) -> Void)? = nil) -> [Hit] {
        var hits = locate(on: page, hints: hints, scale: 3, contextWidth: 140, observedText: observedText)
        // Pair results with hints once each. Retry only missing words in a wider
        // isolated crop, rather than rasterizing every note block a second time.
        var unpaired = hints
        for hit in hits {
            let candidates = unpaired.indices.filter { unpaired[$0].token.uppercased() == hit.token }
            if let index = candidates.min(by: {
                let a = unpaired[$0].bounds, b = unpaired[$1].bounds
                return hypot(a.midX - hit.bounds.midX, a.midY - hit.bounds.midY) <
                    hypot(b.midX - hit.bounds.midX, b.midY - hit.bounds.midY)
            }) { unpaired.remove(at: index) }
        }
        for hint in unpaired {
            for hit in locate(on: page, hints: [hint], scale: 3, contextWidth: 400, observedText: observedText) {
                if !hits.contains(where: { $0.token == hit.token && $0.bounds.intersects(hit.bounds) }) {
                    hits.append(hit)
                }
            }
        }
        return hits
    }

    private static func locate(on page: PDFPage, hints: [Hit], scale: CGFloat, contextWidth: CGFloat, observedText: ((String) -> Void)?) -> [Hit] {
        guard let pageRef = page.pageRef, !hints.isEmpty else { return [] }
        let geometry = PDFBookmarkExtractor.Geometry(page: page, box: .mediaBox)
        let displayed = hints.map { (token: $0.token.uppercased(), bounds: $0.bounds.applying(geometry.transform).standardized) }
        var regions: [CGRect] = []
        for hint in displayed {
            var region = hint.bounds.insetBy(dx: -max(contextWidth, hint.bounds.width * 4), dy: -max(18, hint.bounds.height * 2)).intersection(geometry.bounds)
            // Coalesce overlapping searches so an index or note block renders once.
            var i = 0
            while i < regions.count {
                if region.intersects(regions[i]) { region = region.union(regions.remove(at: i)); i = 0 }
                else { i += 1 }
            }
            if !region.isEmpty { regions.append(region) }
        }
        var hits: [Hit] = []
        for region in regions {
            let width = Int(ceil(region.width * scale)), height = Int(ceil(region.height * scale))
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -region.minX, y: -region.minY)
            context.concatenate(geometry.transform)
            context.drawPDFPage(pageRef)
            guard let image = context.makeImage() else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0
            request.customWords = Array(Set(displayed.map(\.token))).sorted()
            do { try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request]) }
            catch { continue }
            let localTokens = Set(displayed.filter { $0.bounds.intersects(region) }.map(\.token))
            for observation in request.results ?? [] {
                for candidate in observation.topCandidates(3) {
                    observedText?(candidate.string)
                    for match in wordBounds(in: candidate, knownTokens: localTokens, allowOCRDigitConfusion: true) {
                        let box = match.bounds
                        let visible = CGRect(x: region.minX + box.minX * CGFloat(width) / scale,
                                             y: region.minY + box.minY * CGFloat(height) / scale,
                                             width: box.width * CGFloat(width) / scale, height: box.height * CGFloat(height) / scale)
                        guard displayed.contains(where: { $0.token == match.token &&
                            abs($0.bounds.midX - visible.midX) <= max(140, $0.bounds.width * 4) &&
                            abs($0.bounds.midY - visible.midY) <= max(18, $0.bounds.height * 2) }) else { continue }
                        let raw = visible.applying(geometry.transform.inverted()).standardized
                        if !hits.contains(where: { $0.token == match.token && $0.bounds.intersects(raw) }) { hits.append((match.token, raw)) }
                    }
                }
            }
        }
        return hits
    }

    static func exactWordBounds(in candidate: VNRecognizedText, knownTokens: Set<String>) -> [Hit] {
        wordBounds(in: candidate, knownTokens: knownTokens, allowOCRDigitConfusion: false)
    }

    /// These tokens come from literal selectable text at nearby positions, not
    /// inferred destinations. Vision may read the printed digit 0 as O (or 1 as
    /// I/L); tolerate that only while locating an already confirmed reference.
    static func wordBounds(in candidate: VNRecognizedText, knownTokens: Set<String>, allowOCRDigitConfusion: Bool) -> [Hit] {
        let text = candidate.string
        let nsText = text as NSString
        var hits: [Hit] = []
        for token in knownTokens.sorted() {
            let pattern = token.map { character -> String in
                if allowOCRDigitConfusion && character == "0" { return "[0O]" }
                if allowOCRDigitConfusion && character == "1" { return "[1IL]" }
                return NSRegularExpression.escapedPattern(for: String(character))
            }.joined()
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                guard SheetReferencePolicy.isWholeToken(match.range, in: nsText),
                      let range = Range(match.range, in: text),
                      let box = try? candidate.boundingBox(for: range) else { continue }
                let literal = nsText.substring(with: match.range).uppercased()
                // Never reinterpret a different known literal sheet identifier.
                if literal != token.uppercased() && knownTokens.contains(literal) { continue }
                hits.append((token.uppercased(), box.boundingBox))
            }
        }
        return hits
    }
}
