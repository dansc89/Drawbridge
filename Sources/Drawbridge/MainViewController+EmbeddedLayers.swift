import AppKit
import PDFKit

/// Immutable content provenance is attached to the document, not the open URL.
/// Undo and retained tab/split sessions keep their exact document/backing pair.
final class NativePDFOriginalSource: @unchecked Sendable {
    var url: URL
    var stamp: PDFMarkupSourceStamp
    init(url: URL, stamp: PDFMarkupSourceStamp) { self.url = url; self.stamp = stamp }
}
final class NativePDFWorkingSource: NSObject, @unchecked Sendable {
    let output: NativePDFLayerMutation.Output
    let stamp: PDFMarkupSourceStamp
    var original: NativePDFOriginalSource?
    // A sidecar cannot commit this generation's native drawing streams.
    var requiresPDFSave = true
    init(output: NativePDFLayerMutation.Output) throws {
        guard let stamp = PDFMarkupSourceStamp.capture(output.url) else { throw NativePDFLayerMutation.Failure.invalid }
        self.output = output; self.stamp = stamp
    }
}

@MainActor final class NativePDFLayerUndoTransaction {
    private weak var undo: UndoManager?
    private let before: () -> Void
    private let after: () -> Void
    private let changed: () -> Void
    init(undo: UndoManager, before: @escaping () -> Void, after: @escaping () -> Void, changed: @escaping () -> Void) {
        self.undo = undo; self.before = before; self.after = after; self.changed = changed
    }
    func apply(name: String) { transition(forward: true, name: name) }
    private func transition(forward: Bool, name: String) {
        if forward { after() } else { before() }
        // NSUndoManager does not retain its target. The handler must own this
        // otherwise-local transaction until undo/redo consumes the registration.
        undo?.registerUndo(withTarget: self) { [self] _ in
            MainActor.assumeIsolated { self.transition(forward: !forward, name: name) }
        }
        undo?.setActionName(name); changed()
    }
}

extension MainViewController {
    func configureNativePDFLayerControls() {
        let panel = rectangleToolbar.propertiesController.layersView
        panel.onEmbeddedVisibility = { [weak self] layer, visible in
            self?.requestNativePDFLayerEdit(registryIndex: layer.registryIndex, operation: .visibility(visible))
        }
        panel.onEmbeddedDelete = { [weak self] layer in
            self?.requestNativePDFLayerEdit(registryIndex: layer.registryIndex, operation: .deleteContent)
        }
        panel.refresh()
    }
    private func requestNativePDFLayerEdit(registryIndex: Int, operation: NativePDFLayerMutation.Operation) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.editNativePDFLayer(registryIndex: registryIndex, operation: operation) }
            catch { if self.view.window != nil { self.runAlert(title: "PDF Layer Not Changed", informativeText: error.localizedDescription, style: .warning) } }
        }
    }

    func editNativePDFLayer(registryIndex: Int, operation: NativePDFLayerMutation.Operation) async throws {
        guard !isPDFProcessingBusy, !isPDFFileProcessingOperation,
              !persistenceCoordinator.isManualSaveInFlight, let originalURL = openDocumentURL,
              let document = pdfView.document, pdfView.rectangleMarkup.canEdit(),
              let originalStamp = currentPDFOriginalStamp,
              originalStamp.matchesSource(originalURL) else { throw NativePDFLayerMutation.Failure.unsupported("the document is busy or its original source changed") }
        let pane = pdfView, markup = pane.rectangleMarkup
        markup.finishTextEditing(); markup.cancelGesture(); markup.ensureLayerCatalogMarker()
        let generation = markupChangeVersion
        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeNativeSnapshot-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: snapshot) }
        let source = currentPDFWorkingSource(fallback: originalURL)
        let stamp = currentPDFWorkingStamp
        let records = RectangleMarkupRecord.capture(document)
        let navigation = PDFTKBookmarkWriter.captureNavigation(in: document)
        let labels = embeddedPageLabelsForSave(in: document)
        let imported = markup.importedPlan()
        let structure = pageStructureState?.plan(for: document, forceOriginal: imported != nil)
        let saved: Bool
        if let structure, let source {
            saved = structure.write(document: document, currentSource: source, destination: snapshot, expectedStamp: stamp, labels: labels, records: records, navigation: navigation, importedPlan: imported, onCommitted: { _ in })
        } else {
            saved = Self.writePDFDocument(document, to: snapshot, pageLabels: labels, navigationSourceURL: source, rectangleRecords: records, rectangleSourceStamp: stamp, navigationSnapshot: navigation, importedPlan: imported)
        }
        guard saved, let frozen = PDFDocument(url: snapshot),
              EmbeddedPDFLayers.read(frozen).map(\.name) == EmbeddedPDFLayers.read(document).map(\.name) else { throw NativePDFLayerMutation.Failure.unsupported("the current edits could not be captured losslessly") }
        let output = try await Task.detached(priority: .userInitiated) {
            try NativePDFLayerMutation.transform(source: snapshot, registryIndex: registryIndex, operation: operation)
        }.value
        guard pdfView === pane, pane.document === document, pane.rectangleMarkup === markup,
              markupChangeVersion == generation, !isPDFProcessingBusy,
              !persistenceCoordinator.isManualSaveInFlight, originalStamp.matchesSource(originalURL),
              let candidate = PDFDocument(url: output.url), candidate.pageCount == document.pageCount else { throw NativePDFLayerMutation.Failure.unsupported("the session changed while preparing the edit") }
        let replacement = RectangleMarkupController(defaults: markup.defaultPreferences)
        replacement.documentUndoManager = UndoManager()
        replacement.bind(to: candidate)
        replacement.acceptPersistedSource(at: originalURL, stamp: originalStamp)
        replacement.documentUndoManager = markup.undo
        // Retain before adoption, then record a structure baseline for the new pages.
        let before: () -> Void = { [weak self] in self?.installNativePDFSession(document, markup: markup) }
        let after: () -> Void = { [weak self, output] in
            _ = output
            self?.installNativePDFSession(candidate, markup: replacement)
        }
        let transaction = NativePDFLayerUndoTransaction(undo: markup.undo, before: before, after: after, changed: { [weak self] in
            guard let self else { return }
            self.nativeWorkingSource?.requiresPDFSave = true
            self.markMarkupChangedAndScheduleAutosave()
            self.retainActiveSplitSession()
            self.configureNativePDFLayerControls()
        })
        // Capture may throw; do so before changing the active session.
        let retained = try NativePDFWorkingSource(output: output)
        let provenance = nativeWorkingSource?.original ?? NativePDFOriginalSource(url: originalURL, stamp: originalStamp)
        retained.original = provenance
        // The pre-edit generation also needs immutable content after an overwrite
        // followed by undo. Never make it read from the subsequently saved file.
        if nativeWorkingSource == nil {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeNativeBefore-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let frozen = directory.appendingPathComponent("before.pdf")
            // Freeze the full opening page baseline, not the page-selected edit
            // snapshot: earlier page-deletion undo may still restore those pages.
            let baselineSource = pageStructureState?.source ?? originalURL
            do { try FileManager.default.copyItem(at: baselineSource, to: frozen) }
            catch { try? FileManager.default.removeItem(at: directory); throw error }
            let backing = NativePDFLayerMutation.Output(url: frozen, directory: directory)
            let previous = try NativePDFWorkingSource(output: backing)
            previous.original = provenance
            retainNativePDFSource(previous, document: document)
            markup.retainReaderSnapshot(previous.stamp, for: document)
        }
        retainNativePDFSource(retained, document: candidate)
        replacement.retainReaderSnapshot(retained.stamp, for: candidate)
        let undo = markup.undo
        undo.beginUndoGrouping()
        transaction.apply(name: { switch operation { case .visibility: "PDF Layer Visibility"; case .deleteContent: "Delete PDF Layer Content" } }())
        undo.endUndoGrouping()
    }
}
