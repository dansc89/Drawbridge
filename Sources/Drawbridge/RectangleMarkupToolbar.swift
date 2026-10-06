import AppKit

/// Explicit selection drawing keeps the active tool visible inside macOS toolbars,
/// where textured button tint and toggle bezels can otherwise disappear.
@MainActor
final class MarkupToolButton: NSButton {
    var showsActiveTool: Bool { isEnabled && state == .on }
    override func draw(_ dirtyRect: NSRect) {
        guard showsActiveTool else { super.draw(dirtyRect); return }
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        guard let image else { return }
        let symbol = image.withSymbolConfiguration(.init(paletteColors: [.white])) ?? image
        let size = image.size
        symbol.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height))
    }
}

/// The first completed tools live in their own toolbar group, away from indexing.
@MainActor
final class RectangleMarkupToolbar: NSStackView {
    let selectButton = MarkupToolButton(title: "Select", target: nil, action: nil)
    let rectangleButton = MarkupToolButton(title: "Rectangle", target: nil, action: nil)
    let ellipseButton = MarkupToolButton(title: "Ellipse", target: nil, action: nil)
    let lineButton = MarkupToolButton(title: "Line", target: nil, action: nil)
    let arrowButton = MarkupToolButton(title: "Arrow", target: nil, action: nil)
    let polygonButton = MarkupToolButton(title:"Polygon",target:nil,action:nil)
    let fillPopup = NSPopUpButton()
    let polylineButton = MarkupToolButton(title:"Polyline",target:nil,action:nil)
    let textButton = MarkupToolButton(title:"Text",target:nil,action:nil)
    let editTextButton = NSButton(title:"",target:nil,action:nil)
    let fontPopup = NSPopUpButton()
    let fontSizes: [CGFloat] = [8,10,12,14,18,24,36,48,72]
    let propertiesButton = NSButton(title: "", target: nil, action: nil)
    let propertiesPopover = NSPopover()
    let propertiesController = MarkupPropertiesViewController()
    let colorPopup = NSPopUpButton()
    let widthPopup = NSPopUpButton()
    let deleteButton = NSButton(title: "", target: nil, action: nil)
    let undoButton = NSButton(title: "", target: nil, action: nil)
    let redoButton = NSButton(title: "", target: nil, action: nil)
    let colors: [NSColor] = [.red, .blue, .black, .orange, .green]
    let widths: [CGFloat] = [0.5, 1, 2, 4, 8]
    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .horizontal; spacing = 6; alignment = .centerY
        for (button, symbol, name) in [(selectButton,"cursorarrow","Select markups (V)"),(rectangleButton,"rectangle","Draw Rectangle (R)"),(ellipseButton,"circle","Draw Ellipse (E)"),(lineButton,"line.diagonal","Draw Line (L)"),(arrowButton,"arrow.up.right","Draw Arrow (A)"),(polygonButton,"pentagon","Draw Polygon (Shift+P)"),(polylineButton,"point.topleft.down.to.point.bottomright.curvepath","Draw Polyline (Shift+N)"),(textButton,"textformat","Draw Text Box (T)"),(editTextButton,"square.and.pencil","Edit Text"),(deleteButton,"trash","Delete selected markup (Delete)"),(undoButton,"arrow.uturn.backward","Undo (⌘Z)"),(redoButton,"arrow.uturn.forward","Redo (⇧⌘Z)")] {
            button.bezelStyle = .texturedRounded; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
            button.imagePosition = .imageOnly; button.toolTip = name; button.setAccessibilityLabel(name)
            if button is MarkupToolButton {
                button.setButtonType(.toggle)
                button.isBordered = false
                button.widthAnchor.constraint(equalToConstant: 30).isActive = true
                button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            }
            addArrangedSubview(button)
        }
        colorPopup.addItems(withTitles: ["Red","Blue","Black","Orange","Green"])
        colorPopup.toolTip = "Stroke color"; colorPopup.setAccessibilityLabel("Stroke color")
        widthPopup.addItems(withTitles: ["0.5 pt","1 pt","2 pt","4 pt","8 pt"])
        widthPopup.selectItem(at: 2); widthPopup.toolTip = "Line weight"; widthPopup.setAccessibilityLabel("Line weight")
        insertArrangedSubview(colorPopup, at: 8); insertArrangedSubview(widthPopup, at: 9)
        fontPopup.addItems(withTitles:fontSizes.map { "\(Int($0)) pt" }); fontPopup.selectItem(at:4)
        fontPopup.setAccessibilityLabel("Font size"); fontPopup.toolTip = "Font size"
        insertArrangedSubview(fontPopup,at:10)
        fillPopup.addItems(withTitles:["No Fill","Fill Red","Fill Blue","Fill Black","Fill Orange","Fill Green"]); fillPopup.selectItem(at:4)
        fillPopup.setAccessibilityLabel("Polygon fill"); fillPopup.toolTip = "Polygon fill color"
        insertArrangedSubview(fillPopup,at:10)
        for popup in [colorPopup,widthPopup,fontPopup,fillPopup] { popup.menu?.autoenablesItems = false }
        propertiesButton.bezelStyle = .texturedRounded
        propertiesButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Markup Properties")
        propertiesButton.toolTip = "Markup Properties"; propertiesButton.setAccessibilityLabel("Markup Properties")
        insertArrangedSubview(propertiesButton, at: 10)
        propertiesPopover.behavior = .transient
        propertiesPopover.contentViewController = propertiesController
        propertiesPopover.contentSize = NSSize(width: 260, height: 200)
        setHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
extension MainViewController {
    func configureRectangleMarkup() {
        let session = pdfView.rectangleMarkup
        session.canEdit = { [weak self] in
            guard let self, let doc = self.pdfView.document else { return false }
            return self.openDocumentURL != nil && !self.isPDFProcessingBusy && !doc.isLocked && doc.allowsCommenting
        }
        session.onMutation = { [weak self] page in
            guard let self else { return }
            self.markPageMarkupCacheDirty(page)
            self.markMarkupChanged()
            self.updateStatusBar()
            self.updatePDFContentsSummary()
        }
        // Typing changes the editor draft, not the PDF annotation collection.
        // Keep the unsaved indicator current without rescanning the entire set
        // (potentially tens of thousands of consultant markups) on each key.
        session.onDraftChanged = { [weak self] in
            self?.markMarkupChanged()
        }
        var dirtyBeforeDraft = false
        session.onDraftBegan = { [weak self] in dirtyBeforeDraft = self?.hasUnsavedChanges() ?? false }
        session.onDraftEnded = { [weak self] in
            guard let self, !self.pdfView.rectangleMarkup.hasUnsavedChanges else { return }
            self.view.window?.isDocumentEdited = dirtyBeforeDraft
        }
        session.onPresentationChanged = { [weak self] in self?.refreshRectangleToolbar() }
        rectangleToolbar.propertiesController.session = session
        rectangleToolbar.propertiesButton.target = self
        rectangleToolbar.propertiesButton.action = #selector(showMarkupProperties(_:))
        for (control, action) in [(rectangleToolbar.selectButton, #selector(rectangleSelect(_:))), (rectangleToolbar.rectangleButton, #selector(rectangleDraw(_:))), (rectangleToolbar.ellipseButton, #selector(ellipseDraw(_:))), (rectangleToolbar.lineButton, #selector(lineDraw(_:))), (rectangleToolbar.arrowButton, #selector(arrowDraw(_:))), (rectangleToolbar.polygonButton, #selector(polygonDraw(_:))), (rectangleToolbar.fillPopup, #selector(polygonFill(_:))), (rectangleToolbar.polylineButton, #selector(polylineDraw(_:))), (rectangleToolbar.textButton, #selector(textDraw(_:))), (rectangleToolbar.editTextButton, #selector(editMarkupText(_:))), (rectangleToolbar.fontPopup, #selector(markupFontSize(_:))), (rectangleToolbar.deleteButton, #selector(rectangleDelete(_:))), (rectangleToolbar.undoButton, #selector(rectangleUndo(_:))), (rectangleToolbar.redoButton, #selector(rectangleRedo(_:))), (rectangleToolbar.colorPopup, #selector(rectangleStyle(_:))), (rectangleToolbar.widthPopup, #selector(rectangleStyle(_:)))] as [(NSControl, Selector)] {
            control.target = self; control.action = action
        }
        for (index,item) in rectangleToolbar.fillPopup.itemArray.enumerated() { item.tag = index; item.target = self; item.action = #selector(polygonFill(_:)) }
        refreshRectangleToolbar()
    }
    func refreshRectangleToolbar() {
        let s = pdfView.rectangleMarkup
        let enabled = s.canEdit()
        rectangleToolbar.propertiesButton.isEnabled = enabled && s.selected?.isReadOnly != true
        if rectangleToolbar.propertiesPopover.isShown { rectangleToolbar.propertiesController.refresh() }
        for (button, tool) in [(rectangleToolbar.selectButton, RectangleMarkupController.Tool.select), (rectangleToolbar.rectangleButton, .rectangle), (rectangleToolbar.ellipseButton, .ellipse), (rectangleToolbar.lineButton, .line), (rectangleToolbar.arrowButton, .arrow), (rectangleToolbar.polygonButton, .polygon), (rectangleToolbar.polylineButton, .polyline), (rectangleToolbar.textButton, .text)] {
            button.isEnabled = enabled
            button.state = s.tool == tool ? .on : .off
            button.contentTintColor = s.tool == tool ? .systemBlue : .labelColor
            button.needsDisplay = true
        }
        let polygonSelected = s.selected?.type == "Polygon"
        rectangleToolbar.fillPopup.isHidden = !(polygonSelected || s.tool == .polygon)
        rectangleToolbar.fillPopup.isEnabled = enabled
        rectangleToolbar.fillPopup.menu?.autoenablesItems = false
        rectangleToolbar.fillPopup.itemArray.forEach { $0.isEnabled = enabled }
        let fill = polygonSelected ? RectangleMarkupRecord.polygonFill(s.selected!) : s.fillColor
        let textSelected = s.selected?.type == "FreeText"
        rectangleToolbar.editTextButton.isEnabled = enabled && textSelected
        rectangleToolbar.fontPopup.isHidden = !(textSelected || s.tool == .text)
        rectangleToolbar.fontPopup.isEnabled = enabled
        rectangleToolbar.widthPopup.isHidden = textSelected || s.tool == .text
        rectangleToolbar.colorPopup.isEnabled = enabled; rectangleToolbar.widthPopup.isEnabled = enabled
        rectangleToolbar.deleteButton.isEnabled = enabled && s.selected != nil
        rectangleToolbar.undoButton.isEnabled = enabled && s.undo.canUndo
        rectangleToolbar.redoButton.isEnabled = enabled && s.undo.canRedo
        // Custom values must never display an unrelated preset. The inspector
        // edits arbitrary supported values; menus continue offering quick presets.
        func display(_ popup: NSPopUpButton, titles: [String], index: Int?, custom: String) {
            while popup.numberOfItems > titles.count { popup.removeItem(at: popup.numberOfItems - 1) }
            if let index { popup.selectItem(at: index) }
            else { popup.addItem(withTitle: custom); popup.lastItem?.isEnabled = false; popup.selectItem(at: titles.count) }
        }
        let color = s.selected.map(RectangleMarkupRecord.markupColor) ?? s.strokeColor
        let colorIndex = rectangleToolbar.colors.firstIndex { $0.usingColorSpace(.deviceRGB) == color.usingColorSpace(.deviceRGB) }
        display(rectangleToolbar.colorPopup, titles: ["Red","Blue","Black","Orange","Green"], index: colorIndex, custom: "Custom")
        let width = s.selected?.border?.lineWidth ?? s.lineWidth
        display(rectangleToolbar.widthPopup, titles: rectangleToolbar.widths.map { "\($0) pt" }, index: rectangleToolbar.widths.firstIndex(of: width), custom: String(format: "%g pt", Double(width)))
        let font = textSelected ? s.selected.map(RectangleMarkupRecord.textFontSize) ?? s.fontSize : s.fontSize
        display(rectangleToolbar.fontPopup, titles: rectangleToolbar.fontSizes.map { "\(Int($0)) pt" }, index: rectangleToolbar.fontSizes.firstIndex(of: font), custom: String(format: "%g pt", Double(font)))
        let fillIndex = fill.flatMap { color in rectangleToolbar.colors.firstIndex { $0.usingColorSpace(.deviceRGB) == color.usingColorSpace(.deviceRGB) }.map { $0 + 1 } } ?? (fill == nil ? 0 : nil)
        display(rectangleToolbar.fillPopup, titles: ["No Fill","Fill Red","Fill Blue","Fill Black","Fill Orange","Fill Green"], index: fillIndex, custom: "Custom Fill")
    }
    @objc func showMarkupProperties(_ sender: NSButton) {
        guard pdfView.rectangleMarkup.canEdit() else { return }
        if rectangleToolbar.propertiesPopover.isShown { rectangleToolbar.propertiesPopover.close(); return }
        pdfView.rectangleMarkup.finishTextEditing()
        rectangleToolbar.propertiesController.refresh()
        rectangleToolbar.propertiesPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
    @objc func rectangleSelect(_ sender: Any?) { pdfView.rectangleMarkup.tool = .select; view.window?.makeFirstResponder(pdfView) }
    @objc func rectangleDraw(_ sender: Any?) {
        guard pdfView.rectangleMarkup.canEdit() else { return }
        pdfView.rectangleMarkup.tool = .rectangle; view.window?.makeFirstResponder(pdfView)
    }
    private func chooseShape(_ tool: RectangleMarkupController.Tool) {
        guard pdfView.rectangleMarkup.canEdit() else { return }
        pdfView.rectangleMarkup.tool = tool; view.window?.makeFirstResponder(pdfView)
    }
    @objc func ellipseDraw(_ sender: Any?) { chooseShape(.ellipse) }
    @objc func lineDraw(_ sender: Any?) { chooseShape(.line) }
    @objc func arrowDraw(_ sender: Any?) { chooseShape(.arrow) }
    @objc func polygonDraw(_ sender: Any?) { chooseShape(.polygon) }
    @objc func polygonFill(_ sender: Any?) {
        let index = (sender as? NSMenuItem)?.tag ?? rectangleToolbar.fillPopup.indexOfSelectedItem
        guard index >= 0, index <= rectangleToolbar.colors.count else { return }
        pdfView.rectangleMarkup.fillSelected(index == 0 ? nil : rectangleToolbar.colors[index-1])
    }
    @objc func polylineDraw(_ sender: Any?) { chooseShape(.polyline) }
    @objc func textDraw(_ sender: Any?) { chooseShape(.text) }
    @objc func editMarkupText(_ sender: Any?) {
        let s = pdfView.rectangleMarkup
        guard s.canEdit(), let selected = s.selected, selected.type == "FreeText", let page = selected.page else { return }
        s.beginTextEditing(on:page,bounds:selected.bounds,annotation:selected)
    }
    @objc func markupFontSize(_ sender: Any?) {
        let s = pdfView.rectangleMarkup, i = rectangleToolbar.fontPopup.indexOfSelectedItem
        guard s.canEdit(), rectangleToolbar.fontSizes.indices.contains(i) else { return }
        s.setFontSize(rectangleToolbar.fontSizes[i])
    }
    @objc func rectangleDelete(_ sender:Any?) { pdfView.rectangleMarkup.deleteSelected() }
    @objc func rectangleUndo(_ sender: Any?) { guard pdfView.rectangleMarkup.canEdit() else { return }; pdfView.rectangleMarkup.undo.undo(); refreshRectangleToolbar() }
    @objc func rectangleRedo(_ sender: Any?) { guard pdfView.rectangleMarkup.canEdit() else { return }; pdfView.rectangleMarkup.undo.redo(); refreshRectangleToolbar() }
    @objc func rectangleStyle(_ sender: Any?) {
        let c = rectangleToolbar.colorPopup.indexOfSelectedItem, w = rectangleToolbar.widthPopup.indexOfSelectedItem
        let s = pdfView.rectangleMarkup
        let color = rectangleToolbar.colors.indices.contains(c) ? rectangleToolbar.colors[c] : s.selected.map(RectangleMarkupRecord.markupColor) ?? s.strokeColor
        let width = rectangleToolbar.widths.indices.contains(w) ? rectangleToolbar.widths[w] : s.selected?.border?.lineWidth ?? s.lineWidth
        s.styleSelected(color: color, width: width)
    }
}
