import AppKit
import PDFKit

/// User preferences, never PDF metadata. Each tool has its own saved appearance.
struct SavedMarkupAppearance: Codable {
    var stroke: [Double]
    var width: Double
    var pattern: String
    var opacity: Double
    var fill: [Double]?
    var fontSize: Double
    var snapshot: SnapshotStyle = SnapshotStyle()
    var hatch: DraftingHatch? = nil

    private static func validColor(_ color: [Double]) -> Bool {
        color.count == 4 && color.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    var isValid: Bool {
        Self.validColor(stroke) && (fill.map(Self.validColor) ?? true) &&
        width.isFinite && (0.25...72).contains(width) &&
        MarkupLinePattern(rawValue: pattern) != nil && opacity.isFinite && (0...1).contains(opacity) &&
        fontSize.isFinite && (6...144).contains(fontSize) && snapshot.isValid && (hatch?.isValid ?? true)
    }
    static func components(_ color: NSColor) -> [Double] {
        let rgb = color.usingColorSpace(.deviceRGB) ?? .red
        return [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent), Double(rgb.alphaComponent)]
    }
    static func color(_ values: [Double]) -> NSColor {
        NSColor(deviceRed: values[0], green: values[1], blue: values[2], alpha: values[3])
    }
    static func key(_ tool: RectangleMarkupController.Tool) -> String {
        "MarkupDefaults.v1." + (tool == .snapshotPolygon ? "snapshotBox" : tool.rawValue)
    }
    @MainActor static func load(_ tool: RectangleMarkupController.Tool, from preferences: UserDefaults) -> Self? {
        guard let data = preferences.data(forKey: key(tool)), data.count < 4096,
              let style = try? JSONDecoder().decode(Self.self, from: data), style.isValid else { return nil }
        return style
    }
}

@MainActor
extension RectangleMarkupController {
    var currentAppearance: SavedMarkupAppearance {
        SavedMarkupAppearance(stroke: SavedMarkupAppearance.components(strokeColor), width: Double(lineWidth),
                              pattern: linePattern.rawValue, opacity: strokeOpacity,
                              fill: fillColor.map(SavedMarkupAppearance.components), fontSize: Double(fontSize), hatch: hatchStyle)
    }
    func applyDefaults(_ style: SavedMarkupAppearance) {
        strokeColor = SavedMarkupAppearance.color(style.stroke); lineWidth = CGFloat(style.width)
        linePattern = MarkupLinePattern(rawValue: style.pattern) ?? .solid; strokeOpacity = style.opacity
        fillColor = style.fill.map(SavedMarkupAppearance.color); fontSize = CGFloat(style.fontSize)
        hatchStyle = style.hatch
    }
    var defaultTool: Tool? {
        if let annotation = selected {
            guard RectangleMarkupRecord.owns(annotation), !annotation.isReadOnly else { return nil }
            if let measurement = MeasurementMetadata.measurement(annotation) { return measurement.kind == .area ? .area : .perimeter }
            if SnapshotPayload.isSnapshot(annotation) { return .snapshotBox }
            switch annotation.type {
            case "Highlight": return .highlight
            case "Square": return .rectangle
            case "Circle": return .ellipse
            case "Line": return annotation.endLineStyle == .openArrow ? .arrow : .line
            case "FreeText": return .text
            case "Polygon": return .polygon
            case "Ink": return annotation.value(forAnnotationKey: RectangleMarkupRecord.inkToolKey) as? String == "pen" ? .pen : .polyline
            default: return nil
            }
        }
        switch tool {
        case .select, .calibrate: return nil
        default: return tool
        }
    }
    @discardableResult func saveCurrentAsDefault() -> Bool {
        guard canEdit(), let target = defaultTool else { return false }
        var style = currentAppearance
        if let annotation = selected {
            if SnapshotPayload.isSnapshot(annotation) { style.snapshot = SnapshotStyle.read(annotation) }
            else {
                style.stroke = SavedMarkupAppearance.components(RectangleMarkupRecord.markupColor(annotation))
                // Text annotations have no border. Keep the valid tool line weight.
                if annotation.type != "FreeText" { style.width = Double(annotation.border?.lineWidth ?? 2) }
                style.pattern = MarkupStyle.pattern(annotation).rawValue
                style.opacity = MarkupStyle.strokeOpacity(annotation)
                style.fill = RectangleMarkupRecord.polygonFill(annotation).map(SavedMarkupAppearance.components)
                style.hatch = DraftingHatch.read(annotation)
                if annotation.type == "FreeText" { style.fontSize = Double(RectangleMarkupRecord.textFontSize(annotation)) }
            }
        } else if target == .snapshotBox || target == .snapshotPolygon {
            style.snapshot = SavedMarkupAppearance.load(target, from: defaultPreferences)?.snapshot ?? SnapshotStyle()
        }
        guard style.isValid, let data = try? JSONEncoder().encode(style) else { return false }
        defaultPreferences.set(data, forKey: SavedMarkupAppearance.key(target))
        return true
    }
}
