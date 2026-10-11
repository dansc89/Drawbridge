import AppKit

private final class MarkupInspectorContentView: NSView {
    override var isFlipped: Bool { true }
}

/// A nonmodal inspector edits the selection, or the next tool's defaults when
/// nothing is selected. Only properties supported by the verified writer appear.
@MainActor
final class MarkupPropertiesViewController: NSViewController, NSTextFieldDelegate {
    weak var session: RectangleMarkupController?
    let layersView = MarkupLayersView()
    let membership = NSPopUpButton()
    private var propertiesContent = NSStackView()
    var onHide: (() -> Void)?
    let setAsDefault = NSButton(title: "Set as Default", target: nil, action: nil)
    let defaultStatus = NSTextField(labelWithString: "")
    private var lastDefaultTool: RectangleMarkupController.Tool?
    let linePattern = NSPopUpButton()
    let strokeOpacity = NSTextField()
    let fillOpacity = NSTextField()
    let strokePercent = NSTextField(labelWithString: "%")
    let fillPercent = NSTextField(labelWithString: "%")
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
    private var strokeRow = NSStackView()
    private var strokeOpacityRow = NSStackView()
    private var snapshotRows = NSStackView()
    let snapshotOverlay = NSButton(checkboxWithTitle: "Overlay (multiply)", target: nil, action: nil)
    let snapshotFilter = NSPopUpButton()
    let snapshotColor = NSColorWell()
    let snapshotOpacity = NSTextField()
    private let captureHint = NSTextField(wrappingLabelWithString: "Drag a rectangle, or click polygon corners and double-click to finish. Paste with Cmd+V, or paste in place with Cmd+Shift+V. Select a pasted snapshot to adjust its appearance.")
    private let note = NSTextField(wrappingLabelWithString: "")
    let snapshotPercent = NSTextField(labelWithString: "%")

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
            field.target = self; field.action = #selector(changeNumber(_:)); field.delegate = self
        }
        stroke.target = self; stroke.action = #selector(changeStroke(_:)); stroke.setAccessibilityLabel("Markup color")
        fill.target = self; fill.action = #selector(changeFill(_:)); fill.setAccessibilityLabel("Shape fill color")
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
        for (field, label) in [(strokeOpacity, "Stroke opacity percent"), (fillOpacity, "Fill opacity percent"), (snapshotOpacity, "Snapshot opacity percent")] {
            let formatter = NumberFormatter()
            formatter.minimum = 0; formatter.maximum = 100
            formatter.maximumFractionDigits = 2; formatter.allowsFloats = true
            field.formatter = formatter
            field.doubleValue = 100
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 65).isActive = true
            field.cell?.sendsActionOnEndEditing = true
            field.target = self; field.action = #selector(changeNumber(_:)); field.delegate = self
        }
        let hide = NSButton(title: "Hide", target: self, action: #selector(hideInspector(_:)))
        let header = NSStackView(views: [heading, hide]); header.spacing = 12
        patternRow = row("Line pattern", linePattern)
        fillOpacityRow = row("Fill opacity", NSStackView(views: [fillOpacity, fillPercent]))
        note.stringValue = "Changes apply to the selected markup. With nothing selected, they set the next markup’s appearance. Line weights range from 0.25 to 72 pt."
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 11)
        note.widthAnchor.constraint(lessThanOrEqualToConstant: 265).isActive = true
        captureHint.font = .systemFont(ofSize: 11); captureHint.textColor = .secondaryLabelColor
        captureHint.widthAnchor.constraint(lessThanOrEqualToConstant: 265).isActive = true
        snapshotFilter.addItems(withTitles: SnapshotStyle.Filter.allCases.map(\.title))
        snapshotFilter.setAccessibilityLabel("Snapshot filter")
        snapshotColor.setAccessibilityLabel("Snapshot linework color")
        snapshotColor.widthAnchor.constraint(equalToConstant: 85).isActive = true
        for control in [snapshotOverlay, snapshotFilter, snapshotColor] as [NSControl] { control.target = self; control.action = #selector(changeSnapshot(_:)) }
        let snapshotNote = NSTextField(wrappingLabelWithString: "Change Color recolors dark linework and keeps white areas white. Overlay lets the drawing beneath show through white areas. Filters use a high-resolution image; Original restores untouched vector detail.")
        snapshotNote.textColor = .secondaryLabelColor; snapshotNote.font = .systemFont(ofSize: 11)
        snapshotNote.widthAnchor.constraint(lessThanOrEqualToConstant: 265).isActive = true
        snapshotRows = NSStackView(views: [snapshotOverlay, row("Filter", snapshotFilter), row("Change color", snapshotColor), row("Opacity", NSStackView(views: [snapshotOpacity, snapshotPercent])), snapshotNote])
        snapshotRows.orientation = .vertical; snapshotRows.alignment = .leading; snapshotRows.spacing = 10
        strokeRow = row("Stroke color", stroke)
        strokeOpacityRow = row("Stroke opacity", NSStackView(views: [strokeOpacity, strokePercent]))
        setAsDefault.target = self; setAsDefault.action = #selector(saveDefault(_:))
        setAsDefault.toolTip = "Remember this appearance for future markups made with this tool."
        defaultStatus.font = .systemFont(ofSize: 11); defaultStatus.textColor = .secondaryLabelColor
        propertiesContent = NSStackView(views: [membership, editingContext, captureHint, snapshotRows, strokeRow, weightRow, patternRow, strokeOpacityRow, fontRow, fillRow, fillOpacityRow, note, setAsDefault, defaultStatus])
        propertiesContent.orientation = .vertical; propertiesContent.alignment = .leading; propertiesContent.spacing = 10
        membership.target = self; membership.action = #selector(changeMembership(_:)); membership.setAccessibilityLabel("Assigned markup layer")
        let separator = NSBox(); separator.boxType = .separator
        let layersHeading = NSTextField(labelWithString: "Layers")
        layersHeading.font = .systemFont(ofSize: 12, weight: .semibold)
        let stack = NSStackView(views: [header, propertiesContent, separator, layersHeading, layersView])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let content = MarkupInspectorContentView(); content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        content.addSubview(stack); view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    @objc private func changeMembership(_ sender: NSPopUpButton) {
        guard let session else { return }; let index = sender.indexOfSelectedItem - 1
        let id = session.layerCatalog.layers.indices.contains(index) ? session.layerCatalog.layers[index].id : nil
        if let annotation = session.selected { session.assignLayer(id, to: [annotation]) } else { session.setActiveLayer(id) }
    }
    func refresh() {
        _ = view
        guard let session else { return }
        layersView.session = session; layersView.refresh()
        membership.removeAllItems(); membership.addItems(withTitles: ["Unassigned"] + session.layerCatalog.layers.map(\.name))
        let currentID = session.selected.flatMap(MarkupLayers.id) ?? (session.selected == nil ? session.layerCatalog.activeID : nil)
        membership.selectItem(at: currentID.flatMap { id in session.layerCatalog.layers.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0)
        membership.isEnabled = session.canEdit() && (session.selected.map(session.canAssignLayer) ?? true)
        membership.toolTip = session.selected == nil ? "Layer for new markups" : "Selected markup's layer"
        if lastDefaultTool != session.defaultTool { defaultStatus.stringValue = ""; lastDefaultTool = session.defaultTool }
        setAsDefault.isEnabled = session.canEdit() && session.defaultTool != nil
        let selection = session.selected
        let text = selection.map { $0.type == "FreeText" } ?? (session.tool == .text)
        let closedShape = selection.map { ["Square", "Circle", "Polygon"].contains($0.type ?? "") } ?? ([.rectangle, .ellipse, .polygon, .area].contains(session.tool))
        let snapshot = selection.flatMap(SnapshotPayload.read) != nil
        let capturing = selection == nil && (session.tool == .snapshotBox || session.tool == .snapshotPolygon)
        captureHint.isHidden = !capturing
        note.isHidden = snapshot || capturing
        snapshotRows.isHidden = !snapshot
        strokeRow.isHidden = snapshot || capturing; strokeOpacityRow.isHidden = snapshot || capturing
        if let selection, snapshot {
            let style = SnapshotStyle.read(selection)
            snapshotOverlay.state = style.overlay ? .on : .off
            snapshotFilter.selectItem(at: SnapshotStyle.Filter.allCases.firstIndex(of: style.filter) ?? 0)
            snapshotColor.color = style.nsColor; snapshotOpacity.doubleValue = style.opacity * 100
            let editable = session.canEdit() && !selection.isReadOnly && RectangleMarkupRecord.owns(selection)
            for control in [snapshotOverlay, snapshotFilter, snapshotOpacity] as [NSControl] { control.isEnabled = editable }
            snapshotColor.isEnabled = editable
        }
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
        patternRow.isHidden = text || snapshot || capturing; fillOpacityRow.isHidden = !closedShape
        weightRow.isHidden = text || snapshot || capturing; fontRow.isHidden = !text; fillRow.isHidden = !closedShape
        for control in [stroke, weight, fontSize, filled, linePattern, strokeOpacity] as [NSControl] { control.isEnabled = enabled }
        fill.isEnabled = enabled && color != nil
        fillOpacity.isEnabled = enabled && color != nil
    }
    @objc func saveDefault(_ sender: Any?) {
        guard view.window?.makeFirstResponder(nil) != false, let session else { return }
        defaultStatus.stringValue = session.saveCurrentAsDefault() ? "Default saved for this tool." : "Select a markup or drawing tool first."
        refresh()
    }
    @objc func changeSnapshot(_ sender: NSControl) {
        guard let session, let rgb = snapshotColor.color.usingColorSpace(.deviceRGB) else { return }
        if sender === snapshotColor { snapshotFilter.selectItem(at: SnapshotStyle.Filter.allCases.firstIndex(of: .colorize)!) }
        let style = SnapshotStyle(overlay: snapshotOverlay.state == .on, opacity: snapshotOpacity.doubleValue / 100,
                                  filter: SnapshotStyle.Filter.allCases[max(0, snapshotFilter.indexOfSelectedItem)],
                                  color: [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)])
        session.styleSelectedSnapshot(style); refresh()
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
    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField { changeNumber(field) }
    }
    @objc func changeNumber(_ sender: NSTextField) {
        guard let session, let value = sender.objectValue as? NSNumber else { refresh(); return }
        if sender === strokeOpacity || sender === fillOpacity || sender === snapshotOpacity {
            guard value.doubleValue.isFinite, (0...100).contains(value.doubleValue) else { refresh(); return }
            if sender === snapshotOpacity { changeSnapshot(sender) } else { changeAppearance(sender) }
            return
        }
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
