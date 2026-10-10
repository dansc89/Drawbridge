import AppKit
import PDFKit
import CoreText

/// Coordinates are PDF page coordinates, independent of the viewport's zoom.
struct DrawingScale: Codable, Equatable, Sendable {
    var unitsPerPoint: Double
    var unit: String
    var name: String
    var isValid: Bool {
        unitsPerPoint.isFinite && unitsPerPoint > 0 && unitsPerPoint <= 1_000_000 &&
        ["ft", "m"].contains(unit) && !name.isEmpty && name.utf8.count < 200
    }
    static func calibrated(from start: CGPoint, to end: CGPoint, distance: Double, unit: String) -> Self? {
        let length = hypot(end.x-start.x, end.y-start.y)
        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite,
              length.isFinite, length > 0.0001, distance.isFinite, distance > 0 else { return nil }
        let value = Self(unitsPerPoint: distance / length, unit: unit, name: "Calibrated (\(unit))")
        return value.isValid ? value : nil
    }
    static func architectural(inches: Double, feet: Double = 1, name: String) -> Self? {
        let value = Self(unitsPerPoint: feet / (inches * 72), unit: "ft", name: name)
        return inches.isFinite && inches > 0 && feet.isFinite && feet > 0 && value.isValid ? value : nil
    }
    static func metric(ratio: Double) -> Self? {
        let value = Self(unitsPerPoint: ratio * 0.0254 / 72, unit: "m", name: "1:\(ratio.formatted(.number.precision(.fractionLength(0...4))))")
        return ratio.isFinite && ratio > 0 && value.isValid ? value : nil
    }
}

struct DrawingMeasurement: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case area, perimeter }
    var kind: Kind
    var scale: DrawingScale
    var closed: Bool
    var isValid: Bool { scale.isValid && (kind != .area || closed) }
    func valid(points: [CGPoint]) -> Bool {
        isValid && MeasurementGeometry.valid(points, closed: closed) && value(points: points).isFinite
    }
    func value(points: [CGPoint]) -> Double {
        let factor = scale.unitsPerPoint
        return kind == .area ? MeasurementGeometry.area(points) * factor * factor
            : MeasurementGeometry.length(points, closed: closed) * factor
    }
    func label(points: [CGPoint]) -> String {
        let name = kind == .area ? "Area" : (closed ? "Perimeter" : "Length")
        let units = kind == .area ? "sq \(scale.unit)" : scale.unit
        return String(format: "%@: %.2f %@", locale: Locale(identifier: "en_US_POSIX"), name, value(points: points), units)
    }
}

enum CalibrationDistance {
    /// Strict input validation: never silently turn a misspelled dimension into zero inches.
    static func parse(_ text: String, unit: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "′", with: "'").replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "″", with: "\"")
        let number = #"(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)"#
        var value: Double?
        if text.range(of: "^" + number + "$", options: .regularExpression) != nil { value = Double(text) }
        else if unit == "ft" {
            let pattern = "^(" + number + ")'\\s*(?:-\\s*)?(?:([0-9]+(?:\\.[0-9]+)?)(?:\\s+([0-9]+/[0-9]+))?\\s*\")?$"
            if let expression = try? NSRegularExpression(pattern: pattern), let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                func component(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
                let feet = Double(component(1) ?? "") ?? 0
                let inches = Double(component(2) ?? "0") ?? 0
                let fraction: Double
                if let token = component(3) {
                    guard let parsed = MeasurementParsing.parseFractionOrDecimal(token), parsed.isFinite else { return nil }
                    fraction = parsed
                } else { fraction = 0 }
                if inches + fraction < 12, fraction < 1 { value = feet + (inches + fraction) / 12 }
            }
        }
        guard ["ft", "m"].contains(unit), let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

enum MeasurementGeometry {
    static func constrained(_ point: CGPoint, from anchor: CGPoint) -> CGPoint {
        let dx = point.x-anchor.x, dy = point.y-anchor.y
        return abs(dx) >= abs(dy) ? CGPoint(x: point.x, y: anchor.y) : CGPoint(x: anchor.x, y: point.y)
    }
    static func length(_ points: [CGPoint], closed: Bool) -> Double {
        guard points.count > 1 else { return 0 }
        var result = zip(points, points.dropFirst()).reduce(0.0) { $0 + hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y) }
        if closed, let first = points.first, let last = points.last { result += hypot(first.x - last.x, first.y - last.y) }
        return result
    }
    static func area(_ points: [CGPoint]) -> Double {
        guard points.count >= 3, let origin = points.first else { return 0 }
        // Translate first to avoid cancellation on pages with a large box origin.
        let p = points.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
        return abs(p.indices.reduce(0.0) { sum, i in
            let j = (i + 1) % p.count
            return sum + p[i].x * p[j].y - p[j].x * p[i].y
        }) / 2
    }
    static func valid(_ points: [CGPoint], closed: Bool) -> Bool {
        guard points.count >= (closed ? 3 : 2), points.count <= 512,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), length(points, closed: closed).isFinite, length(points, closed: closed) > 0 else { return false }
        guard closed else { return true }
        guard area(points).isFinite, area(points) > 0.0001 else { return false }
        let edges = points.indices.map { (points[$0], points[($0 + 1) % points.count]) }
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
            (b.x-a.x)*(c.y-a.y) - (b.y-a.y)*(c.x-a.x)
        }
        func onSegment(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> Bool {
            abs(cross(a,b,p)) < 1e-8 && p.x >= min(a.x,b.x)-1e-8 && p.x <= max(a.x,b.x)+1e-8 && p.y >= min(a.y,b.y)-1e-8 && p.y <= max(a.y,b.y)+1e-8
        }
        for i in edges.indices {
            guard hypot(edges[i].0.x-edges[i].1.x, edges[i].0.y-edges[i].1.y) > 1e-8 else { return false }
            for j in edges.indices where j > i + 1 && !(i == 0 && j == edges.count-1) {
                let (a,b) = edges[i], (c,d) = edges[j]
                if cross(a,b,c)*cross(a,b,d) < 0 && cross(c,d,a)*cross(c,d,b) < 0 { return false }
                if onSegment(a,b,c) || onSegment(a,b,d) || onSegment(c,d,a) || onSegment(c,d,b) { return false }
            }
        }
        return true
    }
    static func pages(_ text: String, count: Int) -> [Int]? {
        guard count > 0 else { return nil }
        var result = Set<Int>()
        for item in text.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = item.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let start = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let end = Int(parts.last!.trimmingCharacters(in: .whitespaces)), start >= 1, end >= start, end <= count else { return nil }
            result.formUnion((start...end).map { $0-1 })
        }
        return result.isEmpty ? nil : result.sorted()
    }
}

enum MeasurementMetadata {
    static let measurementKey = PDFAnnotationKey(rawValue: "DrawbridgeMeasurement")
    static let pageScaleKey = PDFAnnotationKey(rawValue: "DrawbridgePageScale")
    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    static func decode<T: Decodable>(_ type: T.Type, from annotation: PDFAnnotation, key: PDFAnnotationKey) -> T? {
        guard let text = annotation.value(forAnnotationKey: key) as? String, text.utf8.count < 4096 else { return nil }
        return try? JSONDecoder().decode(type, from: Data(text.utf8))
    }
    static func measurement(_ annotation: PDFAnnotation) -> DrawingMeasurement? {
        guard RectangleMarkupRecord.owns(annotation), let value = decode(DrawingMeasurement.self, from: annotation, key: measurementKey), value.isValid else { return nil }
        return value
    }
    static func pageScale(_ annotation: PDFAnnotation) -> DrawingScale? {
        guard RectangleMarkupRecord.owns(annotation), let value = decode(DrawingScale.self, from: annotation, key: pageScaleKey), value.isValid else { return nil }
        return value
    }
    static func scale(on page: PDFPage) -> DrawingScale? { page.annotations.compactMap(pageScale).last }
    static func updateLabel(_ annotation: PDFAnnotation) {
        guard let measurement = measurement(annotation) else { return }
        annotation.contents = measurement.label(points: RectangleMarkupRecord.vertices(annotation))
        // PDFKit must not reuse the saved appearance after geometry or scale edits.
        annotation.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/AP"))
    }
    static func supportedPage(_ page: PDFPage) -> Bool {
        // Non-default PDF /UserUnit needs explicit physical-size calibration.
        var value: CGPDFReal = 1
        if let dictionary = page.pageRef?.dictionary { CGPDFDictionaryGetNumber(dictionary, "UserUnit", &value) }
        return value == 1
    }
}

enum MeasurementAppearance {
    private static func fit(width: CGFloat, bounds: CGRect, rotation: Int) -> CGFloat {
        let rotated = rotation % 180 != 0
        let availableWidth = rotated ? bounds.height : bounds.width
        let availableHeight = rotated ? bounds.width : bounds.height
        return max(0.001, min(1, availableWidth / (width + 8), availableHeight / 19))
    }
    static func labelOffset(bounds: CGRect, rotation: Int, closed: Bool) -> CGFloat {
        let height = rotation % 180 == 0 ? bounds.height : bounds.width
        // Keep a horizontal distance's text off its stroke and inside its appearance box.
        return closed ? 0 : min(12, max(0, (height-19)/2))
    }
    static func draw(_ annotation: PDFAnnotation, box: PDFDisplayBox, context: CGContext) {
        guard let measurement = MeasurementMetadata.measurement(annotation) else { return }
        let text = measurement.label(points: RectangleMarkupRecord.vertices(annotation))
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): annotation.color.cgColor
        ]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let origin = annotation.page?.bounds(for: box).origin ?? .zero
        let b = annotation.bounds
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: b.midX-origin.x, y: b.midY-origin.y)
        // Page /Rotate is clockwise; rotate the label counterclockwise in PDF space.
        context.rotate(by: CGFloat(annotation.page?.rotation ?? 0) * .pi / 180)
        context.translateBy(x: 0, y: -labelOffset(bounds: b, rotation: annotation.page?.rotation ?? 0, closed: measurement.closed))
        let factor = fit(width: width, bounds: b, rotation: annotation.page?.rotation ?? 0)
        context.scaleBy(x: factor, y: factor)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: -width/2-3, y: -7, width: width+6, height: 17))
        context.textMatrix = .identity; context.textPosition = CGPoint(x: -width/2, y: -4)
        CTLineDraw(line, context)
    }
    static func pdf(_ record: RectangleMarkupRecord) -> String {
        guard let measurement = record.measurement else { return "" }
        let label = measurement.label(points: record.vertices)
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let factor = fit(width: width, bounds: record.bounds, rotation: record.textRotation)
        let angle = Double(record.textRotation) * .pi / 180
        let offset = labelOffset(bounds: record.bounds, rotation: record.textRotation, closed: measurement.closed)
        let x = record.bounds.width/2 + sin(angle)*offset
        let y = record.bounds.height/2 - cos(angle)*offset
        let c = abs(cos(angle)) < 1e-10 ? 0 : cos(angle)*factor
        let s = abs(sin(angle)) < 1e-10 ? 0 : sin(angle)*factor
        return "q \(c) \(s) \(-s) \(c) \(x) \(y) cm 1 1 1 rg \(-width/2-3) -7 \(width+6) 17 re f BT /MeasureFont 11 Tf \(record.red) \(record.green) \(record.blue) rg 1 0 0 1 \(-width/2) -4 Tm (\(label)) Tj ET Q\n"
    }
}

final class DrawbridgeMeasuredPathAnnotation: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        super.draw(with: box, in: context)
        MeasurementAppearance.draw(self, box: box, context: context)
    }
}
