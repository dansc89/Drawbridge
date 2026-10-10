import AppKit
import PDFKit

enum MarkupLinePattern: String, CaseIterable, Sendable {
    case solid, dashed, dotted, dashDot, dashDotDot, longDash
    var title: String {
        switch self {
        case .solid: "Solid"
        case .dashed: "Dashed"
        case .dotted: "Dotted"
        case .dashDot: "Dash dot"
        case .dashDotDot: "Dash dot dot"
        case .longDash: "Long dash"
        }
    }
    func dash(width: CGFloat) -> [Double] {
        let unit = max(Double(width), 0.5)
        let units: [Double]
        switch self {
        case .solid: units = []
        case .dashed: units = [6, 3]
        case .dotted: units = [1, 3]
        case .dashDot: units = [8, 3, 1, 3]
        case .dashDotDot: units = [8, 3, 1, 3, 1, 3]
        case .longDash: units = [12, 4]
        }
        return units.map { $0 * unit }
    }
}

enum MarkupStyle {
    static let patternKey = PDFAnnotationKey(rawValue: "DrawbridgeLinePattern")
    static let strokeOpacityKey = PDFAnnotationKey(rawValue: "DrawbridgeStrokeOpacity")
    static let fillOpacityKey = PDFAnnotationKey(rawValue: "DrawbridgeFillOpacity")
    static func pattern(_ annotation: PDFAnnotation) -> MarkupLinePattern {
        (annotation.value(forAnnotationKey: patternKey) as? String).flatMap(MarkupLinePattern.init(rawValue:)) ?? .solid
    }
    static func strokeOpacity(_ annotation: PDFAnnotation) -> Double { opacity(annotation, key: strokeOpacityKey) }
    static func fillOpacity(_ annotation: PDFAnnotation) -> Double { opacity(annotation, key: fillOpacityKey) }
    private static func opacity(_ annotation: PDFAnnotation, key: PDFAnnotationKey) -> Double {
        guard let value = annotation.value(forAnnotationKey: key) as? NSNumber, value.doubleValue.isFinite else { return 1 }
        return min(1, max(0, value.doubleValue))
    }
    static func apply(pattern: MarkupLinePattern, opacity: Double, to annotation: PDFAnnotation) {
        annotation.setValue(pattern.rawValue, forAnnotationKey: patternKey)
        annotation.setValue(opacity, forAnnotationKey: strokeOpacityKey)
        if annotation.type == "FreeText" {
            let size = RectangleMarkupRecord.textFontSize(annotation)
            annotation.fontColor = RectangleMarkupRecord.markupColor(annotation).withAlphaComponent(opacity)
            RectangleMarkupRecord.setTextFontSize(size, on: annotation)
        }
        else { annotation.color = annotation.color.withAlphaComponent(opacity) }
        if let border = annotation.border {
            border.style = pattern == .solid ? .solid : .dashed
            border.dashPattern = pattern.dash(width: border.lineWidth).map(NSNumber.init(value:))
            annotation.border = border
        }
    }
}
