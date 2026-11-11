import AppKit

/// Whole-box controls; these do not pretend to edit an inline selected range.
@MainActor final class TextBoxAppearanceControls: NSStackView {
    weak var session: RectangleMarkupController?
    let borderColor = SwatchColorWell(), fillColor = SwatchColorWell()
    let borderWidth = NSTextField(), borderOpacity = NSTextField()
    let borderPattern = NSPopUpButton(), fontFamily = NSPopUpButton()
    let bold = NSButton(checkboxWithTitle: "Bold", target: nil, action: nil)
    let italic = NSButton(checkboxWithTitle: "Italic", target: nil, action: nil)
    let underline = NSButton(checkboxWithTitle: "Underline", target: nil, action: nil)
    override init(frame: NSRect) {
        super.init(frame: frame); orientation = .vertical; alignment = .leading; spacing = 10
        func row(_ label: String, _ control: NSView) {
            let title = NSTextField(labelWithString: label); title.widthAnchor.constraint(equalToConstant: 100).isActive = true
            let row = NSStackView(views: [title, control]); row.spacing = 12; addArrangedSubview(row)
        }
        fillColor.allowsNoColor = true
        borderColor.allowsOpacity = false
        for (control, id, label) in [(borderColor, "borderColor", "Border color"), (borderWidth, "borderWidth", "Border weight (pt)"), (borderPattern, "borderPattern", "Border pattern"), (borderOpacity, "borderOpacity", "Border opacity (%)"), (fillColor, "fill", "Text box fill"), (fontFamily, "font", "Font family"), (bold, "bold", "Bold"), (italic, "italic", "Italic"), (underline, "underline", "Underline")] as [(NSControl, String, String)] {
            control.identifier = NSUserInterfaceItemIdentifier("textbox." + id); control.setAccessibilityLabel(label)
            control.target = self; control.action = #selector(change(_:))
        }
        for (field, min, max) in [(borderWidth, 0.0, 72.0), (borderOpacity, 0.0, 100.0)] {
            let f = NumberFormatter(); f.minimum = NSNumber(value: min); f.maximum = NSNumber(value: max); f.maximumFractionDigits = 2; f.allowsFloats = true
            field.formatter = f; field.cell?.sendsActionOnEndEditing = true
        }
        for control in [borderColor, borderWidth, borderOpacity, fillColor] as [NSControl] { control.widthAnchor.constraint(equalToConstant: 85).isActive = true }
        borderWidth.toolTip = "0 = no border. Text color is independent of this line."
        borderPattern.addItems(withTitles: MarkupLinePattern.allCases.map(\.title))
        fontFamily.addItems(withTitles: Array(Set(["Helvetica", "Courier", "Times"] + NSFontManager.shared.availableFontFamilies)).sorted())
        fontFamily.widthAnchor.constraint(equalToConstant: 145).isActive = true
        row("Font family", fontFamily)
        addArrangedSubview(NSStackView(views: [bold, italic, underline]))
        row("Border color", borderColor); row("Border weight (pt)", borderWidth); row("Border pattern", borderPattern); row("Border opacity (%)", borderOpacity); row("Box fill", fillColor)
        let hint = NSTextField(wrappingLabelWithString: "Font and style apply to the whole text box. Border weight 0 removes the border. Paintbrush: select a source, click Match Properties, then click compatible target markups. Escape cancels.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor; hint.widthAnchor.constraint(lessThanOrEqualToConstant: 265).isActive = true
        addArrangedSubview(hint)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() {
        guard let session else { isHidden = true; return }
        guard let a = session.selected, TextBoxAppearance.isNative(a) else { isHidden = true; return }
        isHidden = false
        let s = TextBoxAppearance.read(a)
        borderColor.color = TextBoxAppearance.color(s.borderColor); borderWidth.doubleValue = s.borderWidth
        borderOpacity.doubleValue = s.borderOpacity * 100
        borderPattern.selectItem(at: MarkupLinePattern.allCases.firstIndex(of: MarkupLinePattern(rawValue: s.borderPattern) ?? .solid) ?? 0)
        if fontFamily.item(withTitle: s.fontName) == nil { fontFamily.addItem(withTitle: s.fontName) }
        fontFamily.selectItem(withTitle: s.fontName)
        bold.state = s.bold ? .on : .off; italic.state = s.italic ? .on : .off; underline.state = s.underline ? .on : .off
        fillColor.isNoColor = s.fill == nil
        if let fill = s.fill { fillColor.color = TextBoxAppearance.color(fill) }
        for control in [borderColor, borderWidth, borderOpacity, borderPattern, fillColor, fontFamily, bold, italic, underline] as [NSControl] {
            control.isEnabled = session.canEdit() && !a.isReadOnly && !session.layerIsLocked(a)
        }
    }
    @objc func change(_ sender: NSControl) {
        guard let session, let a = session.selected else { return }
        var s = TextBoxAppearance.read(a)
        switch sender {
        case borderColor: s.borderColor = TextBoxAppearance.rgb(borderColor.color)
        case borderWidth:
            guard let n = Double(borderWidth.stringValue), n.isFinite, (0...72).contains(n) else { refresh(); return }; s.borderWidth = n
        case borderOpacity:
            guard let n = Double(borderOpacity.stringValue), n.isFinite, (0...100).contains(n) else { refresh(); return }; s.borderOpacity = n / 100
        case borderPattern: s.borderPattern = MarkupLinePattern.allCases[borderPattern.indexOfSelectedItem].rawValue
        case fontFamily: s.fontName = fontFamily.titleOfSelectedItem ?? "Helvetica"
        case bold: s.bold = bold.state == .on
        case italic: s.italic = italic.state == .on
        case underline: s.underline = underline.state == .on
        case fillColor: s.fill = fillColor.isNoColor ? nil : TextBoxAppearance.rgb(fillColor.color) + [Double(fillColor.color.alphaComponent)]
        default: return
        }
        session.setTextBoxAppearance(s); refresh()
    }
}
