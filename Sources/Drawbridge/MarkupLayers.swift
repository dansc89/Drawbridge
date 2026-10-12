import AppKit
import PDFKit

struct MarkupLayer: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var name: String
    var visible = true
    var locked = false
}
extension MarkupLayer {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        visible = try values.decode(Bool.self, forKey: .visible)
        locked = try values.decodeIfPresent(Bool.self, forKey: .locked) ?? false
    }
}
struct MarkupLayerCatalog: Codable, Equatable, Sendable {
    var layers: [MarkupLayer] = []
    var activeID: String? = nil
    var isValid: Bool {
        layers.count <= 1000 && Set(layers.map(\.id)).count == layers.count &&
        layers.allSatisfy { UUID(uuidString: $0.id) != nil && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.utf8.count <= 200 } &&
        (activeID == nil || layers.contains { $0.id == activeID })
    }
    var json: String { String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "" }
}
enum MarkupLayers {
    static let catalogKey = PDFAnnotationKey(rawValue: "DrawbridgeLayerCatalog")
    static let membershipKey = PDFAnnotationKey(rawValue: "DrawbridgeLayerID")
    static func id(_ annotation: PDFAnnotation) -> String? { annotation.value(forAnnotationKey: membershipKey) as? String }
    static func catalog(_ document: PDFDocument?) -> MarkupLayerCatalog {
        guard let document else { return .init() }
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                if let text = annotation.value(forAnnotationKey: catalogKey) as? String,
                   let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(MarkupLayerCatalog.self, from: data), value.isValid { return value }
            }
        }
        return .init()
    }
    static func isMetadata(_ annotation: PDFAnnotation) -> Bool { annotation.value(forAnnotationKey: catalogKey) != nil }
}

@MainActor final class MarkupLayerFlags: NSObject {
    let display: Bool; let printFlag: Bool
    init(_ annotation: PDFAnnotation) { display = annotation.shouldDisplay; printFlag = annotation.shouldPrint }
}

@MainActor final class MarkupLayerState: NSObject {
    var catalog: MarkupLayerCatalog
    let originalFlags = NSMapTable<PDFAnnotation, MarkupLayerFlags>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    init(_ catalog: MarkupLayerCatalog) { self.catalog = catalog }
}

@MainActor extension RectangleMarkupController {
    var layerState: MarkupLayerState? {
        guard let document = view?.document else { return nil }
        if let state = layerStates.object(forKey: document) { return state }
        let state = MarkupLayerState(MarkupLayers.catalog(document)); layerStates.setObject(state, forKey: document)
        return state
    }
    var layerCatalog: MarkupLayerCatalog { layerState?.catalog ?? .init() }
    func layerName(for annotation: PDFAnnotation) -> String {
        layerCatalog.layers.first { $0.id == MarkupLayers.id(annotation) }?.name ?? "Unassigned"
    }
    func layerIsVisible(_ annotation: PDFAnnotation) -> Bool {
        layerCatalog.layers.first { $0.id == MarkupLayers.id(annotation) }?.visible ?? true
    }
    func layerIsLocked(_ annotation: PDFAnnotation) -> Bool {
        layerCatalog.layers.first { $0.id == MarkupLayers.id(annotation) }?.locked ?? false
    }
    var activeLayerIsLocked: Bool {
        layerCatalog.layers.first { $0.id == layerCatalog.activeID }?.locked ?? false
    }
    func canAssignLayer(_ annotation: PDFAnnotation) -> Bool {
        guard !annotation.isReadOnly, !layerIsLocked(annotation), !MarkupLayers.isMetadata(annotation), !MeasurementMetadata.isPageScaleMetadata(annotation) else { return false }
        // Preserve foreign OCG/OCMD relationships instead of flattening them.
        guard annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/OC")) == nil || MarkupLayers.id(annotation) != nil else { return false }
        return RectangleMarkupRecord.owns(annotation) || ImportedMarkupState.selectable(annotation) ||
            (MarkupLayers.id(annotation) != nil && layerState?.originalFlags.object(forKey: annotation)?.display == true)
    }
    @discardableResult func addLayer(named raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit(), !name.isEmpty, name.utf8.count <= 200, layerCatalog.layers.count < 1000,
              !layerCatalog.layers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        var catalog = layerCatalog; let layer = MarkupLayer(name: name); catalog.layers.append(layer)
        setLayerCatalog(catalog, action: "New Layer"); return layer.id
    }
    func renameLayer(_ id: String, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var catalog = layerCatalog
        guard !name.isEmpty, name.utf8.count <= 200, let index = catalog.layers.firstIndex(where: { $0.id == id }),
              !catalog.layers.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        catalog.layers[index].name = name; setLayerCatalog(catalog, action: "Rename Layer")
    }
    func setLayerVisible(_ id: String, _ visible: Bool) {
        var catalog = layerCatalog
        guard let index = catalog.layers.firstIndex(where: { $0.id == id }) else { return }
        catalog.layers[index].visible = visible; setLayerCatalog(catalog, action: "Layer Visibility")
    }
    func setLayerLocked(_ id: String, _ locked: Bool) {
        guard canEdit() else { return }
        finishTextEditing(); cancelGesture()
        var catalog = layerCatalog
        guard let index = catalog.layers.firstIndex(where: { $0.id == id }) else { return }
        catalog.layers[index].locked = locked
        if locked && catalog.activeID == id { catalog.activeID = nil }
        setLayerCatalog(catalog, action: locked ? "Lock Layer" : "Unlock Layer")
    }
    func setActiveLayer(_ id: String?) {
        guard id == nil || layerCatalog.layers.contains(where: { $0.id == id && !$0.locked }) else { return }
        var catalog = layerCatalog; catalog.activeID = id; setLayerCatalog(catalog, action: "Active Layer")
    }
    func removeLayer(_ id: String) {
        guard let document = view?.document else { return }
        let annotations = (0..<document.pageCount).flatMap { document.page(at: $0)?.annotations ?? [] }.filter { MarkupLayers.id($0) == id }
        guard canEdit(), !layerCatalog.layers.contains(where: { $0.id == id && $0.locked }), annotations.allSatisfy(canAssignLayer) else { NSSound.beep(); return }
        undo.beginUndoGrouping()
        assignLayer(nil, to: annotations)
        var catalog = layerCatalog; catalog.layers.removeAll { $0.id == id }; if catalog.activeID == id { catalog.activeID = nil }
        setLayerCatalog(catalog, action: "Remove Layer")
        undo.endUndoGrouping(); undo.setActionName("Remove Layer")
    }
    func setLayerCatalog(_ catalog: MarkupLayerCatalog, action: String) {
        guard canEdit(), catalog.isValid, let state = layerState, catalog != state.catalog,
              let page = view?.document?.page(at: 0) else { return }
        let before = state.catalog
        undo.registerUndo(withTarget: self) { $0.setLayerCatalog(before, action: action) }; undo.setActionName(action)
        state.catalog = catalog
        ensureLayerCatalogMarker()
        applyLayerVisibility(); changed(page, importedAppearanceChanged: true)
    }
    /// Keep document metadata available when its original page is removed or restored.
    func ensureLayerCatalogMarker() {
        guard let document = view?.document, let state = layerState, let firstPage = document.page(at: 0) else { return }
        let markers = (0..<document.pageCount).flatMap { document.page(at: $0)?.annotations ?? [] }.filter(MarkupLayers.isMetadata)
        guard !markers.isEmpty || !state.catalog.layers.isEmpty else { return }
        let marker: PDFAnnotation
        if let existing = markers.first { marker = existing }
        else {
            marker = PDFAnnotation(bounds: CGRect(x: firstPage.bounds(for: .mediaBox).minX, y: firstPage.bounds(for: .mediaBox).minY, width: 2, height: 2), forType: .square, withProperties: nil)
            marker.setValue(RectangleMarkupRecord.prefix + UUID().uuidString, forAnnotationKey: RectangleMarkupRecord.identityKey)
            marker.color = .clear; let border = PDFBorder(); border.lineWidth = 2; marker.border = border
            marker.isReadOnly = true; marker.shouldDisplay = false; marker.shouldPrint = false; firstPage.addAnnotation(marker)
        }
        marker.setValue(state.catalog.json, forAnnotationKey: MarkupLayers.catalogKey)
        for duplicate in markers.dropFirst() { duplicate.page?.removeAnnotation(duplicate) }
    }
    func assignLayer(_ id: String?, to annotations: [PDFAnnotation]) {
        guard canEdit(), id == nil || layerCatalog.layers.contains(where: { $0.id == id && !$0.locked }) else { return }
        undo.beginUndoGrouping()
        for annotation in annotations where canAssignLayer(annotation) { setLayerMembership(id, on: annotation) }
        undo.endUndoGrouping(); undo.setActionName("Assign to Layer")
    }
    private func setLayerMembership(_ id: String?, on annotation: PDFAnnotation) {
        guard let page = annotation.page, page.document === view?.document, MarkupLayers.id(annotation) != id else { return }
        let before = MarkupLayers.id(annotation)
        undo.registerUndo(withTarget: self) { $0.setLayerMembership(before, on: annotation) }
        if !RectangleMarkupRecord.owns(annotation) { importedState?.touch(annotation) }
        if let id { annotation.setValue(id, forAnnotationKey: MarkupLayers.membershipKey) }
        else { annotation.removeValue(forAnnotationKey: MarkupLayers.membershipKey) }
        applyLayerVisibility(); changed(page, importedAppearanceChanged: true)
    }
    func assignNewMarkupLayer(_ annotation: PDFAnnotation) {
        guard let id = layerCatalog.activeID else { return }
        if layerCatalog.layers.first(where: { $0.id == id })?.visible == false { setLayerVisible(id, true) }
        annotation.setValue(id, forAnnotationKey: MarkupLayers.membershipKey)
    }
    func applyLayerVisibility() {
        guard let document = view?.document, let state = layerState else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var changedVisibility = false
            for annotation in page.annotations where MarkupLayers.id(annotation) != nil || state.originalFlags.object(forKey: annotation) != nil {
                let flags = state.originalFlags.object(forKey: annotation) ?? MarkupLayerFlags(annotation)
                state.originalFlags.setObject(flags, forKey: annotation)
                let visible = layerIsVisible(annotation)
                let display = visible && flags.display, printFlag = visible && flags.printFlag
                if annotation.shouldDisplay != display || annotation.shouldPrint != printFlag {
                    annotation.shouldDisplay = display; annotation.shouldPrint = printFlag
                    (annotation as? DrawbridgeSnapshotAnnotation)?.isRetired = !display
                    changedVisibility = true
                }
            }
            if changedVisibility { (view as? MarkupPDFView)?.refreshAnnotationRendering(on: page, importedAppearanceChanged: true); onMutation?(page) }
        }
        if let selected, !layerIsVisible(selected) || layerIsLocked(selected) { self.selected = nil; onClickAway?() }
        refresh()
    }
    func layerAssignmentMenu(for annotations: [PDFAnnotation]) -> NSMenu {
        let menu = NSMenu(title: "Assign to Layer")
        for (title, id) in [("Unassigned", Optional<String>.none)] + layerCatalog.layers.map({ ($0.name, Optional($0.id)) }) {
            let item = NSMenuItem(title: title, action: #selector(assignLayerMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = LayerMenuAssignment(id: id, annotations: annotations)
            item.state = !annotations.isEmpty && annotations.allSatisfy { MarkupLayers.id($0) == id } ? .on : .off
            item.isEnabled = canEdit() && !annotations.isEmpty && annotations.allSatisfy(canAssignLayer) && !layerCatalog.layers.contains(where: { $0.id == id && $0.locked }); menu.addItem(item)
        }
        menu.addItem(.separator())
        let item = NSMenuItem(title: "New Layer…", action: #selector(newLayerMenu(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = LayerMenuAssignment(id: nil, annotations: annotations); menu.addItem(item)
        return menu
    }
    @objc private func assignLayerMenu(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? LayerMenuAssignment else { return }
        assignLayer(selection.id, to: selection.annotations)
    }
    @objc private func newLayerMenu(_ sender: NSMenuItem) {
        let annotations = (sender.representedObject as? LayerMenuAssignment)?.annotations ?? []
        let alert = NSAlert(); alert.messageText = "New Layer"; alert.informativeText = "Enter a unique layer name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); alert.accessoryView = field
        alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            undo.beginUndoGrouping()
            if let id = addLayer(named: field.stringValue) { assignLayer(id, to: annotations) }
            else { NSSound.beep() }
            undo.endUndoGrouping(); undo.setActionName("New Layer")
        }
    }
}
@MainActor private final class LayerMenuAssignment: NSObject {
    let id: String?; let annotations: [PDFAnnotation]
    init(id: String?, annotations: [PDFAnnotation]) { self.id = id; self.annotations = annotations }
}
