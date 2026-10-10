import AppKit

/// A nonmodal inspector edits the selection, or the next tool's defaults when
/// nothing is selected. Only properties supported by the verified writer appear.
@MainActor
final class MarkupPropertiesViewController: NSViewController {
    weak var session: RectangleMarkupController?
    var onHide: (() -> Void)?
    let linePattern = NSPopUpButton()
    let strokeOpacity = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    let fillOpacity = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    let strokePercent = NSTextField(labelWithString: "100%")
    let fillPercent = NSTextField(labelWithString: "100%")
    private var patternRow = NSStackView()
    private var fillOpacityRow = NSStackView()
    let heading = NSTextField(labelWithString: "Markup Properties")
    let editingContext = NSTextField(labelWithString: "New markup defaults")
    let stroke = NSColorWell()
    let fill = NSColorWell()
    let filled = NSButton(checkboxWithTitle: "Fill", target: nil, action: nil)
    let weight = NSTextField()
    let fontSize = NSTextField()
    private var weightRow = NSStackView()
    private var fontRow = NSStackView()
    private var fillRow = NSStackView()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        editingContext.font = .systemFont(ofSize: 11)
        editingContext.textColor = .secondaryLabelColor
        for (field, minimum, maximum, label) in [(weight, 0.25, 72.0, "Line weight in points"), (fontSize, 6.0, 144.0, "Font size in points")] {
            let formatter = NumberFormatter()
            formatter.minimum = NSNumber(value: minimum); formatter.maximum = NSNumber(value: maximum)
            formatter.maximumFractionDigits = 2; formatter.allowsFloats = true
            field.formatter = formatter
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 85).isActive = true
            field.cell?.sendsActionOnEndEditing = true
            field.target = self; field.action = #selector(changeNumber(_:))
        }
        stroke.target = self; stroke.action = #selector(changeStroke(_:)); stroke.setAccessibilityLabel("Markup color")
        fill.target = self; fill.action = #selector(changeFill(_:)); fill.setAccessibilityLabel("Polygon fill color")
        filled.target = self; filled.action = #selector(changeFill(_:))
        for well in [stroke, fill] { well.widthAnchor.constraint(equalToConstant: 85).isActive = true }
        func row(_ label: String, _ control: NSView) -> NSStackView {
            let title = NSTextField(labelWithString: label)
            title.widthAnchor.constraint(equalToConstant: 100).isActive = true
            let row = NSStackView(views: [title, control]); row.spacing = 12; row.alignment = .centerY
            return row
        }
        weightRow = row("Line weight (pt)", weight)
        fontRow = row("Font size (pt)", fontSize)
        fillRow = NSStackView(views: [filled, fill]); fillRow.spacing = 12
        linePattern.widthAnchor.constraint(equalToConstant: 108).isActive = true
        linePattern.addItems(withTitles: MarkupLinePattern.allCases.map(\.title))
        linePattern.target = self; linePattern.action = #selector(changeAppearance(_:))
        linePattern.setAccessibilityLabel("Line pattern")
        for (slider, label) in [(strokeOpacity, "Stroke opacity"), (fillOpacity, "Fill opacity")] {
            slider.target = self; slider.action = #selector(changeAppearance(_:))
            slider.isContinuous = false
            slider.setAccessibilityLabel(label)
            slider.widthAnchor.constraint(equalToConstant: 65).isActive = true
        }
        let hide = NSButton(title: "Hide", target: self, action: #selector(hideInspector(_:)))
        let header = NSStackView(views: [heading, hide]); header.spacing = 12
        patternRow = row("Line pattern", linePattern)
        fillOpacityRow = row("Fill opacity", NSStackView(views: [fillOpacity, fillPercent]))
        let note = NSTextField(wrappingLabelWithString: "Changes apply to the selected markup. With nothing selected, they set the next markup’s appearance. Line weights range from 0.25 to 72 pt.")
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 11)
        note.widthAnchor.constraint(lessThanOrEqualToConstant: 265).isActive = true
        let stack = NSStackView(views: [header, editingContext, row("Stroke color", stroke), weightRow, patternRow, row("Stroke opacity", NSStackView(views: [strokeOpacity, strokePercent])), fontRow, fillRow, fillOpacityRow, note])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)])
    }
    func refresh() {
        _ = view
        guard let session else { return }
        let selection = session.selected
        let text = selection.map { $0.type == "FreeText" } ?? (session.tool == .text)
        let polygon = selection.map { $0.type == "Polygon" } ?? (session.tool == .polygon || session.tool == .area)
        let enabled = session.canEdit() && selection?.isReadOnly != true && selection?.type != "Stamp" && (selection == nil || selection.map(RectangleMarkupRecord.owns) == true)
        editingContext.stringValue = selection == nil ? "New markup defaults" : "Selected markup"
        stroke.color = selection.map(RectangleMarkupRecord.markupColor) ?? session.strokeColor
        weight.doubleValue = Double(selection?.border?.lineWidth ?? session.lineWidth)
        fontSize.doubleValue = Double(selection.map(RectangleMarkupRecord.textFontSize) ?? session.fontSize)
        let color = selection.flatMap(RectangleMarkupRecord.polygonFill) ?? (selection == nil ? session.fillColor : nil)
        filled.state = color == nil ? .off : .on
        if let color { fill.color = color; fillOpacity.doubleValue = Double(color.alphaComponent) * 100 }
        else { fillOpacity.doubleValue = 100 }
        linePattern.selectItem(at: MarkupLinePattern.allCases.firstIndex(of: selection.map(MarkupStyle.pattern) ?? session.linePattern) ?? 0)
        strokeOpacity.doubleValue = (selection.map(MarkupStyle.strokeOpacity) ?? session.strokeOpacity) * 100
        strokePercent.stringValue = "\(Int(strokeOpacity.doubleValue.rounded()))%"
        fillPercent.stringValue = "\(Int(fillOpacity.doubleValue.rounded()))%"
        patternRow.isHidden = text; fillOpacityRow.isHidden = !polygon
        weightRow.isHidden = text; fontRow.isHidden = !text; fillRow.isHidden = !polygon
        for control in [stroke, weight, fontSize, filled, linePattern, strokeOpacity] as [NSControl] { control.isEnabled = enabled }
        fill.isEnabled = enabled && color != nil
        fillOpacity.isEnabled = enabled && color != nil
    }
    @objc func hideInspector(_ sender: Any?) { onHide?() }
    @objc func changeAppearance(_ sender: NSControl) {
        guard let session else { return }
        if sender === fillOpacity { changeFill(sender); return }
        let pattern = MarkupLinePattern.allCases[max(0, linePattern.indexOfSelectedItem)]
        session.setLineAppearance(pattern: pattern, opacity: strokeOpacity.doubleValue / 100)
        refresh()
    }
    @objc func changeStroke(_ sender: Any?) {
        guard let session else { return }
        session.styleSelected(color: stroke.color, width: session.selected?.border?.lineWidth ?? session.lineWidth)
    }
    @objc func changeNumber(_ sender: NSTextField) {
        guard let session, let value = sender.objectValue as? NSNumber else { refresh(); return }
        if sender === fontSize { session.setFontSize(CGFloat(value.doubleValue)) }
        else { session.styleSelected(color: session.selected.map(RectangleMarkupRecord.markupColor) ?? session.strokeColor, width: CGFloat(value.doubleValue)) }
        refresh()
    }
    @objc func changeFill(_ sender: Any?) {
        guard let session else { return }
        let rgb = fill.color.usingColorSpace(.deviceRGB)
        let color = rgb.map { NSColor(deviceRed: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent, alpha: CGFloat(fillOpacity.doubleValue / 100)) }
        session.fillSelected(filled.state == .on ? color : nil)
        refresh()
    }
}
