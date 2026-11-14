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
    /// Preflight only: no page/catalog/undo mutation until every membership resolves.
    static func insertionPlan(source: PDFDocument, pages: [PDFPage], destination: MarkupLayerCatalog) throws -> (catalog: MarkupLayerCatalog, mapping: [String: String]) {
        func invalid(_ reason: String) -> NSError {
            NSError(domain: "Drawbridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot insert layered pages: " + reason])
        }
        let annotations = pages.flatMap(\.annotations).filter { !isMetadata($0) }
        var referenced = Set<String>()
        for annotation in annotations where annotation.value(forAnnotationKey: membershipKey) != nil {
            guard let id = id(annotation), UUID(uuidString: id) != nil else { throw invalid("invalid layer membership.") }
            referenced.insert(id)
        }
        guard !referenced.isEmpty else { return (destination, [:]) }
        var sourceCatalog: MarkupLayerCatalog?
        for index in 0..<source.pageCount {
            for annotation in source.page(at: index)?.annotations ?? [] where isMetadata(annotation) {
                guard let text = annotation.value(forAnnotationKey: catalogKey) as? String,
                      let data = text.data(using: .utf8), let catalog = try? JSONDecoder().decode(MarkupLayerCatalog.self, from: data), catalog.isValid else { throw invalid("invalid source layer catalog.") }
                if let previous = sourceCatalog, previous != catalog { throw invalid("conflicting source layer catalogs.") }
                sourceCatalog = catalog
            }
        }
        guard destination.isValid, let sourceCatalog,
              referenced.isSubset(of: Set(sourceCatalog.layers.map(\.id))) else { throw invalid("missing layer definition.") }
        try validateInsertionMemberships(source: source, pages: pages)
        var result = destination, mapping: [String: String] = [:]
        for var layer in sourceCatalog.layers where referenced.contains(layer.id) {
            let original = layer.id
            if result.layers.contains(where: { $0.id == layer.id }) { layer.id = UUID().uuidString }
            let base = layer.name
            var suffix = 2
            while result.layers.contains(where: { $0.name.caseInsensitiveCompare(layer.name) == .orderedSame }) {
                let ending = " (\(suffix))"; suffix += 1
                var stem = base
                while stem.utf8.count + ending.utf8.count > 200 { stem.removeLast() }
                layer.name = stem + ending
            }
            mapping[original] = layer.id; result.layers.append(layer)
        }
        guard result.isValid else { throw invalid("merged catalog exceeds the 1000-layer limit.") }
        return (result, mapping)
    }
    /// Match the writer's immutable slot/OC ownership check before insertion mutates
    /// anything. PDFKit's annotation values can flatten indirect dictionaries; read
    /// the raw graph from the retained InsertionSource document's frozen URL instead.
    private static func validateInsertionMemberships(source: PDFDocument, pages: [PDFPage]) throws {
        let foreign = pages.flatMap { page in
            page.annotations.enumerated().compactMap { slot, annotation -> (PDFPage, Int, String)? in
                guard !isMetadata(annotation), !RectangleMarkupRecord.owns(annotation), let id = id(annotation) else { return nil }
                return (page, slot, id)
            }
        }
        guard !foreign.isEmpty else { return }
        let error = NSError(domain: "Drawbridge", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Cannot insert layered pages: unverifiable source layer membership or optional-content group."])
        guard let url = source.documentURL, let executable = PDFTKBookmarkWriter.executableURL() else { throw error }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Drawbridge-layer-preflight-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: output) }
        guard PDFTKBookmarkWriter.run(executable, arguments: ["--json=2", "--json-stream-data=none", "--decode-level=none", url.path, output.path]),
              let graph = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any],
              let tables = graph["qpdf"] as? [[String: Any]], tables.count == 2,
              let rawPages = graph["pages"] as? [[String: Any]], rawPages.count == source.pageCount else { throw error }
        let objects = tables[1]
        func dictionary(_ reference: Any?) -> [String: Any]? {
            guard let reference = reference as? String else { return nil }
            return (objects["obj:" + reference] as? [String: Any])?["value"] as? [String: Any]
        }
        for (page, slot, id) in foreign {
            let index = source.index(for: page)
            guard rawPages.indices.contains(index), let rawPage = dictionary(rawPages[index]["object"]) else { throw error }
            let indirectEntries = (rawPage["/Annots"] as? String).flatMap { (objects["obj:" + $0] as? [String: Any])?["value"] as? [Any] }
            let entries = (rawPage["/Annots"] as? [Any]) ?? indirectEntries
            guard let entries, entries.count == page.annotations.count, entries.indices.contains(slot),
                  let annotation = dictionary(entries[slot]), annotation["/DrawbridgeLayerID"] as? String == "u:" + id,
                  let group = dictionary(annotation["/OC"]), group["/DrawbridgeLayerID"] as? String == "u:" + id else { throw error }
        }
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
        guard canManageLayers(), !annotation.isReadOnly, !layerIsLocked(annotation), !MarkupLayers.isMetadata(annotation), !MeasurementMetadata.isPageScaleMetadata(annotation) else { return false }
        // Preserve foreign OCG/OCMD relationships instead of flattening them.
        guard annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/OC")) == nil || MarkupLayers.id(annotation) != nil else { return false }
        return RectangleMarkupRecord.owns(annotation) || ImportedMarkupState.selectable(annotation) ||
            (MarkupLayers.id(annotation) != nil && layerState?.originalFlags.object(forKey: annotation)?.display == true)
    }
    @discardableResult func addLayer(named raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canManageLayers(), canEdit(), !name.isEmpty, name.utf8.count <= 200, layerCatalog.layers.count < 1000,
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
        guard canManageLayers(), canEdit(), !layerCatalog.layers.contains(where: { $0.id == id && $0.locked }), annotations.allSatisfy(canAssignLayer) else { NSSound.beep(); return }
        undo.beginUndoGrouping()
        assignLayer(nil, to: annotations)
        var catalog = layerCatalog; catalog.layers.removeAll { $0.id == id }; if catalog.activeID == id { catalog.activeID = nil }
        setLayerCatalog(catalog, action: "Remove Layer")
        undo.endUndoGrouping(); undo.setActionName("Remove Layer")
    }
    func setLayerCatalog(_ catalog: MarkupLayerCatalog, action: String) {
        guard canManageLayers(), canEdit(), catalog.isValid, let state = layerState, catalog != state.catalog,
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
        guard canManageLayers(), canEdit(), id == nil || layerCatalog.layers.contains(where: { $0.id == id && !$0.locked }) else { return }
        undo.beginUndoGrouping()
        for annotation in annotations where canAssignLayer(annotation) { setLayerMembership(id, on: annotation) }
        undo.endUndoGrouping(); undo.setActionName("Assign to Layer")
    }
    private func setLayerMembership(_ id: String?, on annotation: PDFAnnotation) {
        guard canManageLayers(), let page = annotation.page, page.document === view?.document, MarkupLayers.id(annotation) != id else { return }
        let before = MarkupLayers.id(annotation)
        undo.registerUndo(withTarget: self) { $0.setLayerMembership(before, on: annotation) }
        if !RectangleMarkupRecord.owns(annotation) { importedState?.touch(annotation) }
        if let id { annotation.setValue(id, forAnnotationKey: MarkupLayers.membershipKey) }
        else { annotation.removeValue(forAnnotationKey: MarkupLayers.membershipKey) }
        applyLayerVisibility(); changed(page, importedAppearanceChanged: true)
    }
    func assignNewMarkupLayer(_ annotation: PDFAnnotation) {
        guard canManageLayers(), let id = layerCatalog.activeID else { return }
        if layerCatalog.layers.first(where: { $0.id == id })?.visible == false { setLayerVisible(id, true) }
        annotation.setValue(id, forAnnotationKey: MarkupLayers.membershipKey)
    }
    func applyLayerVisibility() {
        guard let document = view?.document, let state = layerState else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var changedVisibility = false
            for annotation in page.annotations where MarkupLayers.id(annotation) != nil || state.originalFlags.object(forKey: annotation) != nil {
                // Editor visibility is transient: never restore or capture it as a layer default.
                if isEditingTextAnnotation(annotation) {continue}
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
        guard canManageLayers(), canEdit() else { return menu }
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
        guard canManageLayers(), canEdit() else { return }
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
