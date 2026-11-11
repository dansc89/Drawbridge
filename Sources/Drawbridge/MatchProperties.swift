import AppKit
import PDFKit

/// A value-only brush. Never carries identity, bounds, vertices, text, calibration,
/// line endings, layers, or foreign dictionaries from the source.
@MainActor struct MatchMarkupAppearance {
    var stroke: NSColor
    var width: CGFloat
    var pattern: MarkupLinePattern
    var opacity: Double
    var fill: NSColor?
    var supportsFill: Bool
    var text: RectangleMarkupController.TextBoxPaint?
    var snapshot: SnapshotStyle?
    var hatch: DraftingHatch?

    static func supports(_ a: PDFAnnotation) -> Bool {
        ["FreeText", "Square", "Circle", "Line", "Polygon", "PolyLine", "Ink", "Highlight", "Underline", "StrikeOut", "Squiggly", "Stamp"].contains(a.type ?? "") && (a.type != "Stamp" || SnapshotPayload.isSnapshot(a))
    }
    static func hasFill(_ a: PDFAnnotation) -> Bool {
        ["FreeText", "Square", "Circle", "Polygon"].contains(a.type ?? "")
    }
    init(_ a: PDFAnnotation, importedEntry: ImportedMarkupState.Entry? = nil) {
        text = a.type == "FreeText" ? .init(appearance: TextBoxAppearance.read(a), color: RectangleMarkupRecord.markupColor(a), size: RectangleMarkupRecord.textFontSize(a), opacity: MarkupStyle.strokeOpacity(a)) : nil
        snapshot = SnapshotPayload.isSnapshot(a) ? SnapshotStyle.read(a) : nil
        stroke = text.map { TextBoxAppearance.color($0.appearance.borderColor) } ?? a.color
        width = text.map { CGFloat($0.appearance.borderWidth) } ?? a.border?.lineWidth ?? 2
        pattern = text.flatMap { MarkupLinePattern(rawValue: $0.appearance.borderPattern) } ?? MarkupStyle.pattern(a)
        opacity = text?.appearance.borderOpacity ?? MarkupStyle.strokeOpacity(a)
        supportsFill = Self.hasFill(a)
        let standardOpacity: Double? = {
            if let value = a.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/CA")) as? NSNumber, value.doubleValue.isFinite { return min(1, max(0, value.doubleValue)) }
            // A bound entry is authoritative even when its original /CA is absent.
            // Never associate a moved/reordered annotation with a live peer's slot.
            if let importedEntry { return importedEntry.standardOpacity }
            return Self.originalStandardOpacity(a)
        }()
        if text == nil, a.value(forAnnotationKey: MarkupStyle.strokeOpacityKey) == nil, let standardOpacity { opacity = standardOpacity }
        fill = text?.appearance.fill.map(TextBoxAppearance.color) ?? (text == nil ? (RectangleMarkupRecord.polygonFill(a) ?? a.interiorColor.map { color in
            if a.value(forAnnotationKey: MarkupStyle.fillOpacityKey) != nil { return color.withAlphaComponent(MarkupStyle.fillOpacity(a)) }
            return standardOpacity.map { alpha in color.withAlphaComponent(alpha) } ?? color
        }) : nil)
        hatch = DraftingHatch.read(a)
        if let snapshot { opacity = snapshot.opacity }
    }
    /// Called once at bind, before live annotation geometry or stacking can change.
    /// Also retains the guarded fallback for standalone brush construction.
    static func originalStandardOpacity(_ a: PDFAnnotation) -> Double? {
            if let value = a.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/CA")) as? NSNumber, value.doubleValue.isFinite { return min(1, max(0, value.doubleValue)) }
            guard !RectangleMarkupRecord.owns(a), let page = a.page, let index = page.annotations.firstIndex(where: { $0 === a }), let source = page.pageRef?.dictionary else { return nil }
            var annotations: CGPDFArrayRef?, dictionary: CGPDFDictionaryRef?, rect: CGPDFArrayRef?, subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetArray(source, "Annots", &annotations), let annotations, index < CGPDFArrayGetCount(annotations), CGPDFArrayGetDictionary(annotations, index, &dictionary), let dictionary,
                  CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == a.type,
                  CGPDFDictionaryGetArray(dictionary, "Rect", &rect), let rect, CGPDFArrayGetCount(rect) == 4 else { return nil }
            var values = [CGPDFReal](repeating: 0, count: 4)
            for i in 0..<4 { guard CGPDFArrayGetNumber(rect, i, &values[i]) else { return nil } }
            guard CGRect(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1]).standardized == a.bounds.standardized else { return nil }
            var value: CGPDFReal = 1
            guard CGPDFDictionaryGetNumber(dictionary, "CA", &value), value.isFinite else { return nil }
            return min(1, max(0, Double(value)))
    }
    func install(on a: PDFAnnotation) {
        if SnapshotPayload.isSnapshot(a) {
            var style = snapshot ?? SnapshotStyle.read(a)
            if snapshot == nil { style.opacity = opacity }
            a.setValue(style.json, forAnnotationKey: SnapshotStyle.key); a.removeAllAppearanceStreams()
            return
        }
        if snapshot != nil {
            if a.type == "FreeText" {
                var style = TextBoxAppearance.read(a); style.borderOpacity = opacity; style.install(on: a)
            } else { MarkupStyle.apply(pattern: MarkupStyle.pattern(a), opacity: opacity, to: a) }
            return
        }
        if a.type == "FreeText" {
            var style = TextBoxAppearance.read(a)
            style.borderColor = TextBoxAppearance.rgb(stroke); style.borderWidth = Double(width)
            style.borderPattern = pattern.rawValue; style.borderOpacity = opacity
            if supportsFill { style.fill = fill.map(SavedMarkupAppearance.components) }
            if let text {
                style.fontName = text.appearance.fontName; style.bold = text.appearance.bold
                style.italic = text.appearance.italic; style.underline = text.appearance.underline
                RectangleMarkupRecord.setTextColor(text.color, on: a); RectangleMarkupRecord.setTextFontSize(text.size, on: a)
                MarkupStyle.apply(pattern: MarkupStyle.pattern(a), opacity: text.opacity, to: a)
            }
            style.install(on: a)
        } else {
            a.color = stroke
            let border = a.border?.copy() as? PDFBorder ?? PDFBorder(); border.lineWidth = width; a.border = border
            MarkupStyle.apply(pattern: pattern, opacity: opacity, to: a)
            if supportsFill && Self.hasFill(a) {
                RectangleMarkupRecord.setPolygonFill(fill, on: a)
                a.interiorColor = fill
                a.setValue(fill.map { Double($0.alphaComponent) } ?? 1, forAnnotationKey: MarkupStyle.fillOpacityKey)
                DraftingHatch.apply(hatch, to: a)
            }
            a.removeAllAppearanceStreams()
        }
    }
}

@MainActor extension RectangleMarkupController {
    func captureMatchAppearance(_ a: PDFAnnotation) -> MatchMarkupAppearance? {
        guard a.page?.document === view?.document, a.shouldDisplay, MatchMarkupAppearance.supports(a) else { return nil }
        return MatchMarkupAppearance(a, importedEntry: importedState?.entries.first { $0.annotation === a })
    }
    func applyMatchAppearance(_ paint: MatchMarkupAppearance, to a: PDFAnnotation) {
        guard canEdit(), !a.isReadOnly, !layerIsLocked(a), let page = a.page, page.document === view?.document, MatchMarkupAppearance.supports(a) else { return }
        if !RectangleMarkupRecord.owns(a) || a.value(forAnnotationKey: CopiedMarkupPayload.key) != nil {
            guard canEditImportedAppearance(a) else { return }
            var copy = editedImportedCopy(a)
            var fields: Set<String> = ["/C", "/BS", "/Border", "/CA", "/DrawbridgeStrokeOpacity"]
            if a.type == "FreeText" {
                let rich = NSMutableAttributedString(attributedString: ImportedTextContent.read(a))
                if let text = paint.text {
                    let range = NSRange(location: 0, length: rich.length)
                    rich.addAttributes([.font: text.appearance.font(size: text.size), .foregroundColor: text.color, .underlineStyle: text.appearance.underline ? NSUnderlineStyle.single.rawValue : 0], range: range)
                    fields.formUnion(["/RC", "/DS", "/DA", "/DR"])
                }
                let border = ImportedTextBorder.Style(color: paint.stroke, width: paint.width, dash: paint.pattern.dash(width: Double(paint.width)).map { CGFloat($0) }, phase: 0)
                copy = ImportedTextAnnotation(source: a, richText: rich, geometryOrigin: importedState?.originalOrigin(a), borderOverride: border)
                let b = PDFBorder(); b.lineWidth = paint.width; b.style = paint.pattern == .solid ? .solid : .dashed; b.dashPattern = border.dash.map { NSNumber(value: Double($0)) }; copy.border = b
                if paint.supportsFill { copy.color = paint.fill ?? .clear }
                if let text = paint.text {
                    copy.font = text.appearance.font(size: text.size); copy.fontColor = text.color
                    copy.setValue(ImportedTextContent.xhtml(rich), forAnnotationKey: PDFAnnotationKey(rawValue: "/RC"))
                }
                var style = TextBoxAppearance.read(a)
                style.borderColor = TextBoxAppearance.rgb(paint.stroke); style.borderWidth = Double(paint.width)
                style.borderPattern = paint.pattern.rawValue; style.borderOpacity = paint.opacity
                if paint.supportsFill { style.fill = paint.fill.map(SavedMarkupAppearance.components) }
                if let text = paint.text {
                    style.fontName = text.appearance.fontName; style.bold = text.appearance.bold
                    style.italic = text.appearance.italic; style.underline = text.appearance.underline
                }
                copy.setValue(style.json, forAnnotationKey: TextBoxAppearance.key)
                copy.setValue(style.fill?.last ?? 1, forAnnotationKey: MarkupStyle.fillOpacityKey)
                MarkupStyle.apply(pattern: paint.pattern, opacity: paint.text?.opacity ?? MarkupStyle.strokeOpacity(a), to: copy)
                fields.formUnion(["/DrawbridgeTextBoxAppearance", "/DrawbridgeFillOpacity"])
            } else {
                paint.install(on: copy)
                if paint.supportsFill && MatchMarkupAppearance.hasFill(a) { fields.formUnion(["/IC", "/DrawbridgeFillOpacity"]) }
            }
            _ = replaceImported(a, with: copy, on: page, fields: fields, action: "Match Properties")
            return
        }
        let old = MatchMarkupAppearance(a)
        undo.registerUndo(withTarget: self) { $0.applyMatchAppearance(old, to: a) }
        undo.setActionName("Match Properties")
        paint.install(on: a); changed(page)
    }
}
