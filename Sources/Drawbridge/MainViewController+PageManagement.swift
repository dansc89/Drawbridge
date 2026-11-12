import AppKit
import PDFKit

/// Page boundaries are zero-based insertion slots, including pageCount (end).
@MainActor
extension MainViewController {
    var canManagePages: Bool {
        guard !isActiveReview, let document = pdfView.document else { return false }
        return document.pageCount > 0 && document.allowsDocumentChanges && !document.isLocked
            && !isPDFProcessingBusy && !isPDFFileProcessingOperation
            && !persistenceCoordinator.isManualSaveInFlight && pdfView.rectangleMarkup.canEdit()
    }

    func preparePageStructure(_ document: PDFDocument) throws -> PDFPageStructureState {
        if let state = pageStructureState, state.document === document { return state }
        guard let stamp = pdfView.rectangleMarkup.openingMarkupSourceStamp,
              let source = stamp.recoverySourceURL else {
            throw NSError(domain: "Drawbridge", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Save this PDF first so Drawbridge can preserve its original drawing content."])
        }
        let state = PDFPageStructureState(document: document, stamp: stamp, source: source)
        pageStructureState = state
        return state
    }

    @discardableResult func reorderPages(at indexes: IndexSet, to boundary: Int) throws -> Bool {
        guard canManagePages, let document = pdfView.document,
              !indexes.isEmpty, indexes.allSatisfy({ $0 >= 0 && $0 < document.pageCount }),
              (0...document.pageCount).contains(boundary) else { return false }
        let before = pageManagementSnapshot(document)
        let selected = indexes.map { before.pages[$0] }
        var pages = before.pages.enumerated().filter { !indexes.contains($0.offset) }.map(\.element)
        let insertion = boundary - indexes.filter { $0 < boundary }.count
        pages.insert(contentsOf: selected, at: insertion)
        guard pages.map(ObjectIdentifier.init) != before.pages.map(ObjectIdentifier.init) else { return false }
        _ = try preparePageStructure(document)
        let after = remapPageManagementSnapshot(before, pages: pages, selected: selected)
        applyPageManagement(after, document: document, undo: before, action: "Reorder Pages")
        return true
    }

    /// One immutable snapshot supplies both the modal's page range and insertion.
    /// Retaining its stamp keeps the recovery file alive through insertion and save.
    struct InsertionSource {
        let url: URL
        let stamp: PDFMarkupSourceStamp
        let document: PDFDocument

        init?(url: URL) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let stamp = PDFMarkupSourceStamp.capture(url), let frozen = stamp.recoverySourceURL,
                  let document = PDFDocument(url: frozen), document.pageCount > 0,
                  !document.isLocked, document.allowsCopying else { return nil }
            self.url = frozen; self.stamp = stamp; self.document = document
        }
    }

    @discardableResult func insertPages(from source: URL, indexes: [Int], at boundary: Int) throws -> Bool {
        guard canManagePages, let document = pdfView.document,
              (0...document.pageCount).contains(boundary), !indexes.isEmpty,
              let frozen = InsertionSource(url: source) else { return false }
        return try insertPages(from: frozen, indexes: indexes, at: boundary)
    }

    @discardableResult func insertPages(from source: InsertionSource, indexes: [Int], at boundary: Int) throws -> Bool {
        guard canManagePages, let document = pdfView.document,
              (0...document.pageCount).contains(boundary), !indexes.isEmpty else { return false }
        let foreign = source.document, frozen = source.url, stamp = source.stamp
        guard indexes.allSatisfy({ $0 >= 0 && $0 < foreign.pageCount }) else { return false }
        let ordered = Array(Set(indexes)).sorted()
        // PDFKit pages remain backed by a retained immutable source document.
        let inserted = ordered.compactMap(foreign.page(at:))
        guard inserted.count == ordered.count else { return false }
        let layerPlan = try MarkupLayers.insertionPlan(source: foreign, pages: inserted, destination: pdfView.rectangleMarkup.layerCatalog)
        let structure = try preparePageStructure(document)
        let before = pageManagementSnapshot(document)
        for (index, page) in zip(ordered, inserted) {
            structure.register(page: page, source: frozen, stamp: stamp, index: index, document: foreign)
        }
        var pages = before.pages; pages.insert(contentsOf: inserted, at: boundary)
        var after = remapPageManagementSnapshot(before, pages: pages, selected: inserted)
        after.layers = layerPlan.catalog
        for (offset, page) in inserted.enumerated() { after.labels[boundary + offset] = page.label ?? String(ordered[offset] + 1) }
        // Copy only bookmark destinations whose selected pages are present; retain hierarchy.
        let mapping = Dictionary(uniqueKeysWithValues: inserted.map { (ObjectIdentifier($0), $0) })
        func copyOutline(_ outline: PDFOutline) -> PDFOutline? {
            let node = PDFOutline(); node.label = outline.label
            if let destination = outline.destination, let page = destination.page, let target = mapping[ObjectIdentifier(page)] {
                node.destination = PDFDestination(page: target, at: destination.point)
            }
            for index in 0..<outline.numberOfChildren {
                if let child = outline.child(at: index), let copy = copyOutline(child) { node.insertChild(copy, at: node.numberOfChildren) }
            }
            return node.destination != nil || node.numberOfChildren > 0 ? node : nil
        }
        if let root = foreign.outlineRoot {
            for index in 0..<root.numberOfChildren {
                if let child = root.child(at: index), let copy = copyOutline(child) { after.bookmarks.append(copy) }
            }
        }
        pdfView.rectangleMarkup.importedState?.register(pages: inserted, indexes: ordered)
        for annotation in inserted.flatMap(\.annotations) where !MarkupLayers.isMetadata(annotation) {
            if let id = MarkupLayers.id(annotation), let mapped = layerPlan.mapping[id] {
                annotation.setValue(mapped, forAnnotationKey: MarkupLayers.membershipKey)
            }
        }
        applyPageManagement(after, document: document, undo: before, action: "Insert Pages")
        return true
    }

    struct PageManagementSnapshot {
        var pages: [PDFPage]
        var labels: [Int: String]
        var scales: [Int: PageScaleLock]
        var suppressed: Set<Int>
        var selected: [PDFPage]
        var bookmarks: [PDFOutline]
        var layers: MarkupLayerCatalog
    }

    func pageManagementSnapshot(_ document: PDFDocument) -> PageManagementSnapshot {
        let pages = (0..<document.pageCount).compactMap(document.page(at:))
        let root = document.outlineRoot
        return .init(pages: pages,
            labels: Dictionary(uniqueKeysWithValues: pages.indices.map { ($0, displayPageLabel(forPageIndex: $0)) }),
            scales: pageScaleLocks, suppressed: suppressedEmbeddedPageLabelIndexes,
            selected: pagesTableView.selectedRowIndexes.compactMap { $0 < pages.count ? pages[$0] : nil },
            bookmarks: (0..<(root?.numberOfChildren ?? 0)).compactMap { root?.child(at: $0) }, layers: pdfView.rectangleMarkup.layerCatalog)
    }

    func remapPageManagementSnapshot(_ old: PageManagementSnapshot, pages: [PDFPage], selected: [PDFPage]) -> PageManagementSnapshot {
        let positions = Dictionary(uniqueKeysWithValues: pages.enumerated().map { (ObjectIdentifier($0.element), $0.offset) })
        func remap(_ index: Int) -> Int? { old.pages.indices.contains(index) ? positions[ObjectIdentifier(old.pages[index])] : nil }
        return .init(pages: pages,
            labels: Dictionary(uniqueKeysWithValues: old.labels.compactMap { k,v in remap(k).map { ($0,v) } }),
            scales: Dictionary(uniqueKeysWithValues: old.scales.compactMap { k,v in remap(k).map { ($0,v) } }),
            suppressed: Set(old.suppressed.compactMap(remap)), selected: selected, bookmarks: old.bookmarks, layers: old.layers)
    }

    func applyPageManagement(_ state: PageManagementSnapshot, document: PDFDocument, undo previous: PageManagementSnapshot, action: String) {
        guard pdfView.document === document, canManagePages else { return }
        pdfView.rectangleMarkup.finishTextEditing(); pdfView.rectangleMarkup.cancelGesture()
        // Never serialize/reopen existing sheets: annotation and split-view identities survive.
        for index in (0..<document.pageCount).reversed() { document.removePage(at: index) }
        for (index,page) in state.pages.enumerated() { document.insert(page, at: index) }
        pdfView.rectangleMarkup.layerState?.catalog = state.layers
        pdfView.rectangleMarkup.ensureLayerCatalogMarker()
        pdfView.rectangleMarkup.applyLayerVisibility()
        let root = PDFOutline()
        for child in state.bookmarks { child.removeFromParent(); root.insertChild(child, at: root.numberOfChildren) }
        document.outlineRoot = root
        pageLabelOverrides = state.labels; pageScaleLocks = state.scales
        suppressedEmbeddedPageLabelIndexes = state.suppressed
        let expected = state.pages.map(ObjectIdentifier.init)
        let undo = pdfView.rectangleMarkup.undo
        undo.registerUndo(withTarget: self) { owner in
            guard owner.pdfView.document === document, owner.canManagePages,
                  (0..<document.pageCount).compactMap(document.page(at:)).map(ObjectIdentifier.init) == expected else { return }
            owner.applyPageManagement(previous, document: document, undo: state, action: action)
        }
        undo.setActionName(action)
        let selected = IndexSet(state.selected.compactMap { page in state.pages.firstIndex { $0 === page } })
        refreshAfterPageStructureChange(document: document, preferredIndex: selected.first ?? 0)
        pagesTableView.reloadData()
        pagesTableView.selectRowIndexes(selected, byExtendingSelection: false)
    }

    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pasteboard: NSPasteboard) -> Bool {
        guard tableView === pagesTableView, canManagePages, let document = pdfView.document else { return false }
        let table = pagesTableView
        let indexes = table.mouseDownSelection ?? rowIndexes
        guard !indexes.isEmpty, indexes.allSatisfy({ $0 < document.pageCount }) else { return false }
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        table.draggedDocument = document
        table.draggedPageIdentities = (0..<document.pageCount).compactMap(document.page(at:)).map(ObjectIdentifier.init)
        table.draggedIndexes = indexes
        let token = UUID().uuidString; table.dragToken = token
        pasteboard.declareTypes([PageThumbnailTableView.pageDragType], owner: nil)
        return pasteboard.setString(token, forType: PageThumbnailTableView.pageDragType)
    }

    func validPageDrag(_ info: NSDraggingInfo, row: Int) -> Bool {
        guard canManagePages, let document = pdfView.document,
              info.draggingSource as? NSTableView === pagesTableView,
              pagesTableView.draggedDocument === document,
              info.draggingPasteboard.string(forType: PageThumbnailTableView.pageDragType) == pagesTableView.dragToken,
              pagesTableView.dragToken != nil, (0...document.pageCount).contains(row),
              (0..<document.pageCount).compactMap(document.page(at:)).map(ObjectIdentifier.init) == pagesTableView.draggedPageIdentities else { return false }
        let indexes = pagesTableView.draggedIndexes
        guard !indexes.isEmpty else { return false }
        let before = Array(0..<document.pageCount)
        var after = before.filter { !indexes.contains($0) }
        after.insert(contentsOf: indexes, at: row - indexes.filter { $0 < row }.count)
        return before != after
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === pagesTableView, validPageDrag(info, row: row) else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        guard tableView === pagesTableView, validPageDrag(info, row: row) else { return false }
        defer { pagesTableView.dragToken = nil; pagesTableView.draggedIndexes = []; pagesTableView.draggedDocument = nil; pagesTableView.draggedPageIdentities = [] }
        do { return try reorderPages(at: pagesTableView.draggedIndexes, to: row) }
        catch { runAlert(title: "Could not reorder pages", informativeText: error.localizedDescription, style: .warning); return false }
    }

    @objc func commandInsertPages(_ sender: Any?) {
        guard canManagePages, let document = pdfView.document else { beep(); return }
        let identity = (0..<document.pageCount).compactMap(document.page(at:)).map(ObjectIdentifier.init)
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = false
        panel.message = "Choose the PDF containing the pages to insert."
        guard panel.runModal() == .OK, let source = panel.url,
              pdfView.document === document, canManagePages else { return }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard let preview = InsertionSource(url: source) else {
            runAlert(title: "Cannot insert pages", informativeText: "The source must be an unlocked PDF that permits copying.", style: .warning); return
        }
        let foreign = preview.document
        let alert = NSAlert(); alert.messageText = "Insert Pages"
        alert.informativeText = "Choose source pages (1–\(foreign.pageCount)) and their destination. Ranges such as 1–3, 5 are inserted once in source order."
        alert.addButton(withTitle: "Insert"); alert.addButton(withTitle: "Cancel")
        let range = NSTextField(string: "1-\(foreign.pageCount)")
        let position = NSPopUpButton(); position.addItems(withTitles: ["Before page", "After page", "Beginning", "End"])
        let page = NSTextField(string: String((pagesTableView.selectedRowIndexes.first ?? 0) + 1))
        let stack = NSStackView(views: [NSTextField(labelWithString: "Source pages:"), range, position, page])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 330, height: 130); range.widthAnchor.constraint(equalToConstant: 320).isActive = true
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn, pdfView.document === document, canManagePages,
              (0..<document.pageCount).compactMap(document.page(at:)).map(ObjectIdentifier.init) == identity else { return }
        guard let indexes = MeasurementGeometry.pages(range.stringValue, count: foreign.pageCount), !indexes.isEmpty else {
            runAlert(title: "Invalid source pages", informativeText: "Enter page numbers or ranges within the source PDF.", style: .warning); return
        }
        let boundary: Int
        switch position.indexOfSelectedItem {
        case 2: boundary = 0
        case 3: boundary = document.pageCount
        default:
            guard let number = Int(page.stringValue), (1...document.pageCount).contains(number) else {
                runAlert(title: "Invalid destination", informativeText: "Enter a destination page number in this PDF.", style: .warning); return
            }
            boundary = number - (position.indexOfSelectedItem == 0 ? 1 : 0)
        }
        do { _ = try insertPages(from: preview, indexes: indexes, at: boundary) }
        catch { runAlert(title: "Could not insert pages", informativeText: error.localizedDescription, style: .warning) }
    }
}
