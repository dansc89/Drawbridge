import AppKit
import PDFKit
import CoreText

/// Optional extension to native FreeText. Absence means the historical borderless
/// Helvetica box. Text ink and box ink deliberately have independent alpha.
struct TextBoxAppearance: Codable, Equatable, Sendable {
    var fontName = "Helvetica"
    var bold = false
    var italic = false
    var underline = false
    var borderColor: [Double] = [0, 0, 0]
    var borderWidth: Double = 0
    var borderPattern = "solid"
    var borderOpacity: Double = 1
    var fill: [Double]? = nil
    var valid: Bool {
        !fontName.isEmpty && fontName.utf8.count < 256 && borderColor.count == 3 && borderColor.allSatisfy { $0.isFinite && (0...1).contains($0) } && borderWidth.isFinite && (0...72).contains(borderWidth) && borderOpacity.isFinite && (0...1).contains(borderOpacity) && MarkupLinePattern(rawValue: borderPattern) != nil && (fill == nil || (fill!.count == 4 && fill!.allSatisfy { $0.isFinite && (0...1).contains($0) }))
    }
    static let key = PDFAnnotationKey(rawValue: "DrawbridgeTextBoxAppearance")
    /// Ownership alone also includes foreign copies. Require native text markers,
    /// and reject payload presence even when decoding that payload would fail.
    static func isNative(_ a: PDFAnnotation) -> Bool {
        guard a.type == "FreeText", RectangleMarkupRecord.owns(a),
              !(a is ImportedTextAnnotation), a.value(forAnnotationKey: CopiedMarkupPayload.key) == nil,
              // Our writer emits /DS even for plain native text. It is a
              // default style declaration, not evidence of imported rich text.
              ["/RC", "/CL", "/RD"].allSatisfy({ a.value(forAnnotationKey: PDFAnnotationKey(rawValue: $0)) == nil }) else { return false }
        return a is DrawbridgeTextBoxAnnotation ||
            (a.value(forAnnotationKey: RectangleMarkupRecord.textColorKey) != nil &&
             a.value(forAnnotationKey: RectangleMarkupRecord.textFontSizeKey) != nil)
    }
    var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    static func read(_ a: PDFAnnotation) -> TextBoxAppearance {
        if let json = a.value(forAnnotationKey: key) as? String, let data = json.data(using: .utf8), let style = try? JSONDecoder().decode(Self.self, from: data), style.valid { return style }
        var style = Self(); style.fontName = a.font?.fontName ?? "Helvetica"
        let traits = a.font.map { NSFontManager.shared.traits(of: $0) } ?? []
        style.bold = traits.contains(.boldFontMask); style.italic = traits.contains(.italicFontMask)
        // A newly reconstructed native textbox may draw before its style key is
        // installed. Never render it to discover an imported appearance: that
        // would recurse through DrawbridgeTextBoxAnnotation.draw -> read.
        if !isNative(a), !(a is DrawbridgeTextBoxAnnotation) {
            if let border = (a as? ImportedTextAnnotation)?.originalBorder ?? ImportedTextContent.appearance(a).flatMap(ImportedTextBorder.read) {
                style.borderWidth = Double(border.width); style.borderColor = rgb(border.color)
                style.borderPattern = border.dash.isEmpty ? "solid" : "dashed"
            }
            style.borderOpacity = MarkupStyle.strokeOpacity(a)
            let color = a.color.usingColorSpace(.deviceRGB) ?? .clear
            if color.alphaComponent > 0 { style.fill = rgb(color) + [Double(color.alphaComponent)] }
        }
        return style
    }
    static func rgb(_ color: NSColor) -> [Double] {
        let c = color.usingColorSpace(.deviceRGB) ?? .black
        return [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
    }
    static func color(_ components: [Double]) -> NSColor {
        NSColor(deviceRed: components[0], green: components[1], blue: components[2], alpha: components.count > 3 ? components[3] : 1)
    }
    func font(size: CGFloat) -> NSFont {
        var font = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        font = NSFontManager.shared.convert(font, toHaveTrait: bold ? .boldFontMask : .unboldFontMask)
        font = NSFontManager.shared.convert(font, toHaveTrait: italic ? .italicFontMask : .unitalicFontMask)
        return font
    }
    func install(on a: PDFAnnotation) {
        guard valid else { return }
        a.setValue(json, forAnnotationKey: Self.key)
        RectangleMarkupRecord.setTextFontSize(RectangleMarkupRecord.textFontSize(a), on: a)
        let border = PDFBorder(); border.lineWidth = borderWidth
        let pattern = MarkupLinePattern(rawValue: borderPattern) ?? .solid
        border.style = pattern == .solid ? .solid : .dashed
        border.dashPattern = pattern.dash(width: borderWidth).map(NSNumber.init(value:)); a.border = border
        a.removeAllAppearanceStreams()
    }
    func attributed(_ text: String, size: CGFloat, color: NSColor, alignment: NSTextAlignment) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment; paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [.font: font(size: size), .foregroundColor: color, .paragraphStyle: paragraph, .underlineStyle: underline ? NSUnderlineStyle.single.rawValue : 0])
    }
}

/// Native live drawing uses exactly the same frame/layout and style as the
/// writer. Never delegate the box to PDFKit's ambiguous FreeText /C semantics.
final class DrawbridgeTextBoxAnnotation: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard shouldDisplay else { return }
        let style = TextBoxAppearance.read(self)
        context.saveGState(); defer { context.restoreGState() }
        if let fill = style.fill { context.setFillColor(TextBoxAppearance.color(fill).cgColor); context.fill(bounds) }
        if style.borderWidth > 0 {
            context.saveGState(); context.setAlpha(style.borderOpacity)
            context.setStrokeColor(TextBoxAppearance.color(style.borderColor).cgColor); context.setLineWidth(style.borderWidth)
            context.setLineDash(phase: 0, lengths: (MarkupLinePattern(rawValue: style.borderPattern) ?? .solid).dash(width: style.borderWidth).map { CGFloat($0) })
            context.stroke(bounds.insetBy(dx: style.borderWidth / 2, dy: style.borderWidth / 2)); context.restoreGState()
        }
        context.setAlpha(MarkupStyle.strokeOpacity(self)); context.clip(to: bounds)
        context.translateBy(x: bounds.minX, y: bounds.minY)
        let rotation = (((page?.rotation ?? 0) % 360) + 360) % 360
        context.concatenate(ImportedTextContent.rotationTransform(rotation, size: bounds.size))
        let size = abs(rotation) % 180 == 90 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let text = style.attributed(contents ?? "", size: RectangleMarkupRecord.textFontSize(self), color: RectangleMarkupRecord.markupColor(self).withAlphaComponent(1), alignment: alignment)
        context.textMatrix = .identity
        let frame = TextMarkupAppearance.frame(text, size: size)
        CTFrameDraw(frame, context)
    }
}

@MainActor extension RectangleMarkupController {
    struct TextBoxPaint {
        let appearance: TextBoxAppearance
        let color: NSColor
        let size: CGFloat
        let opacity: Double
    }
    func captureTextBoxPaint(_ annotation: PDFAnnotation) -> TextBoxPaint? {
        guard annotation.type == "FreeText", annotation.page?.document === view?.document, annotation.shouldDisplay else { return nil }
        return TextBoxPaint(appearance: TextBoxAppearance.read(annotation), color: RectangleMarkupRecord.markupColor(annotation), size: RectangleMarkupRecord.textFontSize(annotation), opacity: MarkupStyle.strokeOpacity(annotation))
    }
    func setTextBoxAppearance(_ style: TextBoxAppearance, on annotation: PDFAnnotation? = nil, paint: TextBoxPaint? = nil) {
        guard canEdit(), style.valid, let a = annotation ?? selected, TextBoxAppearance.isNative(a), !a.isReadOnly, !layerIsLocked(a), let page = a.page, page.document === view?.document else { return }
        let old = TextBoxPaint(appearance: TextBoxAppearance.read(a), color: RectangleMarkupRecord.markupColor(a), size: RectangleMarkupRecord.textFontSize(a), opacity: MarkupStyle.strokeOpacity(a))
        let next = paint ?? TextBoxPaint(appearance: style, color: old.color, size: old.size, opacity: old.opacity)
        undo.registerUndo(withTarget: self) { $0.setTextBoxAppearance(old.appearance, on: a, paint: old) }
        undo.setActionName(paint == nil ? "Text Box Appearance" : "Match Properties")
        RectangleMarkupRecord.setTextColor(next.color, on: a)
        RectangleMarkupRecord.setTextFontSize(next.size, on: a)
        MarkupStyle.apply(pattern: MarkupStyle.pattern(a), opacity: next.opacity, to: a)
        next.appearance.install(on: a)
        changed(page)
    }
    func beginMatchProperties() {
        guard canEdit() else { return }
        finishTextEditing(); let captured = selected.flatMap(captureMatchAppearance)
        tool = .select; cancelGesture(); matchPropertiesActive = true; matchAppearance = captured
        refresh()
    }
    /// Called before ordinary selection/drawing so clicks cannot drag a target.
    func matchPropertiesPointerDown(at point: CGPoint) -> Bool {
        guard matchPropertiesActive else { return false }
        guard canEdit(), let view, let page = view.page(for: point, nearest: false), page.document === view.document else { return true }
        let p = view.convert(point, to: page)
        guard let a = page.annotations.reversed().first(where: { $0.shouldDisplay && $0.bounds.contains(p) && MatchMarkupAppearance.supports($0) }) else { return true }
        if let paint = matchAppearance { applyMatchAppearance(paint, to: a) }
        else { matchAppearance = captureMatchAppearance(a); refresh() }
        return true
    }
}
