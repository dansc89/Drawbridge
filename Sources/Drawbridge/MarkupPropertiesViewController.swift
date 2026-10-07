import AppKit

/// A nonmodal inspector edits the selection, or the next tool's defaults when
/// nothing is selected. Only properties supported by the verified writer appear.
@MainActor
final class MarkupPropertiesViewController: NSViewController {
    weak var session: RectangleMarkupController?
    let heading = NSTextField(labelWithString: "Markup Properties")
    let stroke = NSColorWell()
    let fill = NSColorWell()
    let filled = NSButton(checkboxWithTitle: "Fill", target: nil, action: nil)
    let weight = NSTextField()
    let fontSize = NSTextField()
    private var weightRow = NSStackView()
    private var fontRow = NSStackView()
    private var fillRow = NSStackView()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        for (field, minimum, maximum, label) in [(weight, 0.25, 12.0, "Line weight in points"), (fontSize, 6.0, 144.0, "Font size in points")] {
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
            title.widthAnchor.constraint(equalToConstant: 115).isActive = true
            let row = NSStackView(views: [title, control]); row.spacing = 12; row.alignment = .centerY
            return row
        }
        weightRow = row("Line weight (pt)", weight)
        fontRow = row("Font size (pt)", fontSize)
        fillRow = NSStackView(views: [filled, fill]); fillRow.spacing = 12
        let stack = NSStackView(views: [heading, row("Color", stroke), weightRow, fontRow, fillRow])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16), stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16)])
    }
    func refresh() {
        _ = view
        guard let session else { return }
        let selection = session.selected
        let text = selection.map { $0.type == "FreeText" } ?? (session.tool == .text)
        let polygon = selection.map { $0.type == "Polygon" } ?? (session.tool == .polygon)
        let enabled = session.canEdit() && selection?.isReadOnly != true
        heading.stringValue = selection == nil ? "New Markup Defaults" : "Selected Markup"
        stroke.color = selection.map(RectangleMarkupRecord.markupColor) ?? session.strokeColor
        weight.doubleValue = Double(selection?.border?.lineWidth ?? session.lineWidth)
        fontSize.doubleValue = Double(selection.map(RectangleMarkupRecord.textFontSize) ?? session.fontSize)
        let color = selection.flatMap(RectangleMarkupRecord.polygonFill) ?? (selection == nil ? session.fillColor : nil)
        filled.state = color == nil ? .off : .on
        if let color { fill.color = color }
        weightRow.isHidden = text; fontRow.isHidden = !text; fillRow.isHidden = !polygon
        for control in [stroke, weight, fontSize, filled] as [NSControl] { control.isEnabled = enabled }
        fill.isEnabled = enabled && color != nil
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
        let color = rgb.map { NSColor(deviceRed: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent, alpha: 1) }
        session.fillSelected(filled.state == .on ? color : nil)
        refresh()
    }
}
