import AppKit
import PDFKit

@MainActor final class MarkupLayersView: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    weak var session: RectangleMarkupController?
    let table = NSTableView()
    let active = NSPopUpButton()
    private var counts: [String: Int] = [:]
    private let newLayerButton = NSButton(title: "New Layer…", target: nil, action: nil)
    private let rename = NSButton(title: "Rename", target: nil, action: nil)
    private let remove = NSButton(title: "Remove", target: nil, action: nil)
    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical; alignment = .leading; spacing = 10
        let title = NSTextField(labelWithString: "New markups go on:")
        active.target = self; active.action = #selector(changeActive(_:)); active.setAccessibilityLabel("Active markup layer")
        addArrangedSubview(title); addArrangedSubview(active)
        table.delegate = self; table.dataSource = self; table.headerView = NSTableHeaderView()
        table.rowHeight = 26; table.allowsMultipleSelection = false
        table.intercellSpacing = CGSize(width: 3, height: 2); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width) in [("visible", "Show", 36.0), ("name", "Layer", 125.0), ("count", "Items", 40.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; column.minWidth = width; table.addTableColumn(column)
        }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.widthAnchor.constraint(equalToConstant: 250).isActive = true; scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        addArrangedSubview(scroll)
        newLayerButton.target = self; newLayerButton.action = #selector(newLayer(_:))
        rename.target = self; rename.action = #selector(renameLayer(_:)); remove.target = self; remove.action = #selector(removeLayer(_:))
        addArrangedSubview(NSStackView(views: [newLayerButton, rename, remove]))
        let note = NSTextField(wrappingLabelWithString: "Layers apply across the PDF. Hidden markups remain in the Markups List. Removing a layer moves its markups to Unassigned.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; note.widthAnchor.constraint(equalToConstant: 250).isActive = true
        addArrangedSubview(note)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() {
        let row = table.selectedRow
        active.removeAllItems(); active.addItems(withTitles: ["Unassigned"] + (session?.layerCatalog.layers.map(\.name) ?? []))
        let catalog = session?.layerCatalog ?? .init()
        active.selectItem(at: catalog.activeID.flatMap { id in catalog.layers.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0)
        active.isEnabled = session?.canEdit() == true
        counts = [:]
        if let document = session?.view?.document {
            for index in 0..<document.pageCount {
                for annotation in document.page(at: index)?.annotations ?? [] {
                    if let id = MarkupLayers.id(annotation) { counts[id, default: 0] += 1 }
                }
            }
        }
        newLayerButton.isEnabled = session?.canEdit() == true && session?.view?.document != nil
        table.reloadData()
        if row >= 0 && row < catalog.layers.count { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        updateButtons()
    }
    private func updateButtons() { rename.isEnabled = table.selectedRow >= 0 && session?.canEdit() == true; remove.isEnabled = rename.isEnabled }
    func numberOfRows(in tableView: NSTableView) -> Int { session?.layerCatalog.layers.count ?? 0 }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let session, session.layerCatalog.layers.indices.contains(row) else { return nil }
        let layer = session.layerCatalog.layers[row]
        switch column?.identifier.rawValue {
        case "visible":
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleVisibility(_:)))
            check.state = layer.visible ? .on : .off; check.tag = row; check.setAccessibilityLabel("Show layer " + layer.name); check.isEnabled = session.canEdit(); return check
        case "count":
            return NSTextField(labelWithString: String(counts[layer.id, default: 0]))
        default: return NSTextField(labelWithString: layer.name)
        }
    }
    @objc private func toggleVisibility(_ sender: NSButton) {
        guard let session, session.layerCatalog.layers.indices.contains(sender.tag) else { return }
        session.setLayerVisible(session.layerCatalog.layers[sender.tag].id, sender.state == .on)
    }
    @objc private func changeActive(_ sender: NSPopUpButton) {
        guard let session else { return }; let index = sender.indexOfSelectedItem - 1
        session.setActiveLayer(session.layerCatalog.layers.indices.contains(index) ? session.layerCatalog.layers[index].id : nil)
    }
    private func prompt(title: String, initial: String = "") -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = "Enter a unique layer name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); field.stringValue = initial; alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
    @objc private func newLayer(_ sender: Any?) {
        guard let name = prompt(title: "New Layer"), let session else { return }
        if session.addLayer(named: name) == nil { NSSound.beep() }
    }
    @objc private func renameLayer(_ sender: Any?) {
        guard let session, session.layerCatalog.layers.indices.contains(table.selectedRow) else { return }
        let layer = session.layerCatalog.layers[table.selectedRow]
        if let name = prompt(title: "Rename Layer", initial: layer.name) { session.renameLayer(layer.id, to: name) }
    }
    @objc private func removeLayer(_ sender: Any?) {
        guard let session, session.layerCatalog.layers.indices.contains(table.selectedRow) else { return }
        session.removeLayer(session.layerCatalog.layers[table.selectedRow].id)
    }
}
