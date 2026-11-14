import AppKit
import PDFKit

@MainActor final class MarkupLayersView: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    weak var session: RectangleMarkupController?
    /// Installed only with lossless snapshot and undoable session adoption hooks.
    var onEmbeddedVisibility: ((EmbeddedPDFLayers.Layer, Bool) -> Void)?
    var onEmbeddedDelete: ((EmbeddedPDFLayers.Layer) -> Void)?
    private weak var presentedDocument: PDFDocument?
    private var presentationGeneration = UUID()
    private final class NativeLayerButton: NSButton {
        var generation: UUID?
        weak var document: PDFDocument?
        var embeddedLayer: EmbeddedPDFLayers.Layer?
    }
    let table = NSTableView()
    let active = NSPopUpButton()
    private var counts: [String: Int] = [:]
    private var embeddedLayers: [EmbeddedPDFLayers.Layer] = []
    private let embeddedNote = NSTextField(wrappingLabelWithString: "Embedded PDF drawing layers use native PDF visibility. Delete Content removes supported drawing paint, not markups, and retains an empty native group. Unsupported drawings are rejected unchanged. Changes are unsaved until Save. Rename and Lock are unavailable. Purge and Save replaces the open PDF and reveals hidden artwork; it is not selective deletion.")
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
        for (id, title, width) in [("visible", "Show", 36.0), ("name", "Layer", 98.0), ("locked", "Lock", 36.0), ("count", "Items", 40.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; column.minWidth = width; table.addTableColumn(column)
        }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.widthAnchor.constraint(equalToConstant: 250).isActive = true; scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        addArrangedSubview(scroll)
        newLayerButton.target = self; newLayerButton.action = #selector(newLayer(_:))
        rename.target = self; rename.action = #selector(renameLayer(_:)); remove.target = self; remove.action = #selector(removeLayer(_:))
        addArrangedSubview(NSStackView(views: [newLayerButton, rename, remove]))
        let note = NSTextField(wrappingLabelWithString: "Locked layers protect markups from editing or deletion. Hidden markups remain in the Markups List. Removing a layer moves its markups to Unassigned.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; note.widthAnchor.constraint(equalToConstant: 250).isActive = true
        addArrangedSubview(note)
        embeddedNote.font = .systemFont(ofSize: 11); embeddedNote.textColor = .secondaryLabelColor
        embeddedNote.widthAnchor.constraint(equalToConstant: 250).isActive = true
        embeddedNote.isHidden = true; addArrangedSubview(embeddedNote)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() {
        let document = session?.view?.document
        let row = presentedDocument === document ? table.selectedRow : -1
        presentedDocument = document; presentationGeneration = UUID()
        active.removeAllItems(); active.addItems(withTitles: ["Unassigned"] + (session?.layerCatalog.layers.map(\.name) ?? []))
        let catalog = session?.layerCatalog ?? .init()
        active.selectItem(at: catalog.activeID.flatMap { id in catalog.layers.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0)
        for (index, layer) in catalog.layers.enumerated() { active.item(at: index + 1)?.isEnabled = !layer.locked }
        active.isEnabled = session?.canManageLayers() == true && session?.canEdit() == true
        counts = [:]
        if let document = session?.view?.document {
            for index in 0..<document.pageCount {
                for annotation in document.page(at: index)?.annotations ?? [] {
                    if let id = MarkupLayers.id(annotation) { counts[id, default: 0] += 1 }
                }
            }
        }
        newLayerButton.isEnabled = session?.canManageLayers() == true && session?.canEdit() == true && session?.view?.document != nil
        embeddedLayers = EmbeddedPDFLayers.read(session?.view?.document)
        embeddedNote.isHidden = embeddedLayers.isEmpty
        table.reloadData()
        if row >= 0 && row < numberOfRows(in: table) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        updateButtons()
    }
    private func updateButtons() {
        let layers = session?.layerCatalog.layers ?? []
        let isMarkup = layers.indices.contains(table.selectedRow)
        rename.isEnabled = isMarkup && session?.canManageLayers() == true && session?.canEdit() == true
        remove.isEnabled = rename.isEnabled && !layers[table.selectedRow].locked
        let native = table.selectedRow - layers.count
        if embeddedLayers.indices.contains(native) {
            remove.title = "Delete Content…"
            remove.isEnabled = onEmbeddedDelete != nil && session?.canManageLayers() == true && session?.canEdit() == true && presentedDocument === session?.view?.document
        } else { remove.title = "Remove" }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { (session?.layerCatalog.layers.count ?? 0) + embeddedLayers.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let session, row >= 0 else { return nil }
        let nativeIndex = row - session.layerCatalog.layers.count
        if embeddedLayers.indices.contains(nativeIndex) {
            let layer = embeddedLayers[nativeIndex]
            let explanation = "Native PDF drawing layer. Edits remain unsaved and unsupported programs are rejected."
            switch column?.identifier.rawValue {
            case "visible":
                let check = NativeLayerButton(checkboxWithTitle: "", target: self, action: #selector(toggleEmbeddedVisibility(_:)))
                check.generation = presentationGeneration; check.document = presentedDocument; check.embeddedLayer = layer
                check.allowsMixedState = true
                check.state = layer.visible.map { $0 ? NSControl.StateValue.on : .off } ?? .mixed
                check.isEnabled = layer.visible != nil && onEmbeddedVisibility != nil && session.canManageLayers() && session.canEdit()
                check.toolTip = layer.visible == nil ? "Visibility depends on an unsupported PDF configuration." : explanation
                check.setAccessibilityLabel("Show PDF drawing layer " + layer.name)
                return check
            case "locked":
                let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                check.allowsMixedState = true; check.state = .mixed; check.isEnabled = false
                check.toolTip = explanation; check.setAccessibilityLabel(explanation + " " + layer.name)
                return check
            case "count":
                let label = NSTextField(labelWithString: "PDF"); label.toolTip = explanation; return label
            default:
                let label = NSTextField(labelWithString: layer.name); label.toolTip = layer.name + " — " + explanation
                label.lineBreakMode = .byTruncatingTail; return label
            }
        }
        guard session.layerCatalog.layers.indices.contains(row) else { return nil }
        let layer = session.layerCatalog.layers[row]
        switch column?.identifier.rawValue {
        case "visible":
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleVisibility(_:)))
            check.state = layer.visible ? .on : .off; check.tag = row; check.setAccessibilityLabel("Show layer " + layer.name); check.isEnabled = session.canManageLayers() && session.canEdit(); return check
        case "locked":
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleLock(_:)))
            check.state = layer.locked ? .on : .off; check.tag = row
            check.setAccessibilityLabel("Lock layer " + layer.name); check.isEnabled = session.canManageLayers() && session.canEdit(); return check
        case "count":
            return NSTextField(labelWithString: String(counts[layer.id, default: 0]))
        default: return NSTextField(labelWithString: layer.name)
        }
    }
    @objc private func toggleEmbeddedVisibility(_ sender: NativeLayerButton) {
        guard sender.generation == presentationGeneration, let document = sender.document,
              document === presentedDocument, document === session?.view?.document,
              session?.canManageLayers() == true && session?.canEdit() == true, let layer = sender.embeddedLayer,
              embeddedLayers.contains(layer) else { return }
        onEmbeddedVisibility?(layer, sender.state == .on)
        // Dispatch isn't successful adoption: saved state remains authoritative.
        sender.state = layer.visible.map { $0 ? .on : .off } ?? .mixed
    }
    @objc private func toggleVisibility(_ sender: NSButton) {
        guard let session, session.layerCatalog.layers.indices.contains(sender.tag) else { return }
        session.setLayerVisible(session.layerCatalog.layers[sender.tag].id, sender.state == .on)
    }
    @objc private func toggleLock(_ sender: NSButton) {
        guard let session, session.layerCatalog.layers.indices.contains(sender.tag) else { return }
        session.setLayerLocked(session.layerCatalog.layers[sender.tag].id, sender.state == .on)
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
        guard let session, session.canManageLayers(), session.canEdit(),
              let name = prompt(title: "New Layer") else { return }
        if session.addLayer(named: name) == nil { NSSound.beep() }
    }
    @objc private func renameLayer(_ sender: Any?) {
        guard let session, session.canManageLayers(), session.canEdit(),
              session.layerCatalog.layers.indices.contains(table.selectedRow) else { return }
        let layer = session.layerCatalog.layers[table.selectedRow]
        if let name = prompt(title: "Rename Layer", initial: layer.name) { session.renameLayer(layer.id, to: name) }
    }
    @objc private func removeLayer(_ sender: Any?) {
        let nativeIndex = table.selectedRow - (session?.layerCatalog.layers.count ?? 0)
        if embeddedLayers.indices.contains(nativeIndex) {
            guard let document = presentedDocument, document === session?.view?.document,
                  session?.canManageLayers() == true && session?.canEdit() == true, let callback = onEmbeddedDelete else { return }
            let layer = embeddedLayers[nativeIndex], generation = presentationGeneration
            let alert = NSAlert(); alert.messageText = "Delete drawing content from \(layer.name)?"
            alert.informativeText = "Supported drawing paint is deleted, not hidden. Markups and other layers are preserved. The empty PDF group remains. This is undoable and is not saved until you save the document. Unsupported drawings are rejected unchanged."
            alert.addButton(withTitle: "Delete Content"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn,
                  generation == presentationGeneration, document === session?.view?.document else { return }
            callback(layer); return
        }
        guard let session, session.canManageLayers(), session.canEdit(),
              session.layerCatalog.layers.indices.contains(table.selectedRow) else { return }
        session.removeLayer(session.layerCatalog.layers[table.selectedRow].id)
    }
}
