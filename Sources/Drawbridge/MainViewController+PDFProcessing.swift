import AppKit
import PDFKit

@MainActor
extension MainViewController {
    func isExtraneousEmbeddedPDFAnnotation(_ annotation: PDFAnnotation) -> Bool {
        let userName = (annotation.userName ?? "").lowercased()
        let contents = (annotation.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (annotation.type ?? "").lowercased()
        if userName.contains("autocad shx text") {
            return true
        }
        return type.contains("square") && !annotation.shouldPrint && !contents.isEmpty
    }

    @objc func commandPurgeLayers(_ sender: Any?) {
        guard let source = openDocumentURL, pdfView.document != nil, !isPDFProcessingBusy, !isPDFFileProcessingOperation else { beep(); return }
        let response = runAlert(title: "Purge Layers", informativeText: "All layers will be removed from the PDF you have open, and current edits will be saved. Your artwork and annotations will be retained. Previously hidden content will become visible. Annotations remain editable.", style: .warning, buttons: ["Purge and Save", "Cancel"])
        guard response == .alertFirstButtonReturn else { return }
        purgeLayersInPlace { [weak self] success in
            self?.runAlert(title: success ? "Layers Purged and Saved" : "Purge Layers Failed", informativeText: success ? "Saved to \(source.path). Layer controls were removed; artwork and editable annotations were retained." : (self?.lastPurgeErrorMessage ?? "The purge could not be completed."))
        }
    }

    func purgeLayersInPlace(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let source = openDocumentURL else { completion(false); return }
        processPurgedLayers(to: canonicalDocumentURL(source), replacingOpenDocument: true, completion: completion)
    }

    /// Freeze the same structural/markup/navigation inputs as Save, but never run
    /// Save's adoption/clean-state callbacks and never write to the open source.
    func savePurgedLayersCopy(to destination: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        processPurgedLayers(to: destination, replacingOpenDocument: false, completion: completion)
    }

    private func processPurgedLayers(to destination: URL, replacingOpenDocument: Bool,
                                     completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let document = pdfView.document, let source = openDocumentURL,
              !isPDFProcessingBusy, !isPDFFileProcessingOperation,
              replacingOpenDocument || (canonicalDocumentURL(source) != canonicalDocumentURL(destination)
                && !FileManager.default.fileExists(atPath: destination.path)) else { completion(false); return }
        lastPurgeErrorMessage = nil
        let snapshotDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgePurgeSnapshot-\(UUID())")
        do { try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: false) }
        catch { lastPurgeErrorMessage = error.localizedDescription; completion(false); return }
        let snapshot = snapshotDirectory.appendingPathComponent("snapshot.pdf")
        let purged = replacingOpenDocument ? snapshotDirectory.appendingPathComponent("purged.pdf") : destination
        pdfView.rectangleMarkup.finishTextEditing()
        let changeVersion = markupChangeVersion
        let records = RectangleMarkupRecord.capture(document)
        let navigation = PDFTKBookmarkWriter.captureNavigation(in: document)
        let labels = embeddedPageLabelsForSave(in: document)
        let stamp = pdfView.rectangleMarkup.sourceStamp
        let imported = pdfView.rectangleMarkup.importedPlan()
        let structure = pageStructureState?.document === document ? pageStructureState?.plan(for: document, forceOriginal: imported != nil) : nil
        let box = PDFDocumentBox(document: document)
        let cancellation = PDFProcessingCancellation()
        isPDFFileProcessingOperation = true
        beginBusyIndicator("Purging Layers…", detail: "Preparing current edits…")
        updateStatusBar()
        setBusyCancelAction { [weak self] in cancellation.cancel(); self?.setBusyCancelAction(nil) }
        let controller = self
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                var stage = "Checking the source PDF"
                do {
                    defer { try? FileManager.default.removeItem(at: snapshotDirectory) }
                    if cancellation.cancelled { throw CancellationError() }
                    if replacingOpenDocument {
                        guard let stamp, stamp.matchesSource(destination) else {
                            throw NSError(domain: "DrawbridgePurge", code: 2, userInfo: [NSLocalizedDescriptionKey: "The PDF changed outside Drawbridge or is no longer accessible. Reload it before purging layers."])
                        }
                    }
                    let original = replacingOpenDocument ? try Data(contentsOf: destination) : nil
                    stage = "Preparing current edits"
                    let saved: Bool
                    if let structure {
                        saved = structure.write(document: box.document, currentSource: source, destination: snapshot, expectedStamp: stamp, labels: labels, records: records, navigation: navigation, importedPlan: imported, onCommitted: { _ in })
                    } else {
                        saved = Self.writePDFDocument(box.document, to: snapshot, pageLabels: labels, navigationSourceURL: source, rectangleRecords: records, rectangleSourceStamp: stamp, navigationSnapshot: navigation, importedPlan: imported)
                    }
                    guard saved else { throw CocoaError(.fileWriteUnknown) }
                    stage = "Removing layer controls"
                    try PDFLayerPurger.purge(source: snapshot, destination: purged, cancelled: { cancellation.cancelled })
                    if replacingOpenDocument {
                        stage = "Saving the purged PDF"
                        guard !cancellation.cancelled, try Data(contentsOf: destination) == original else { throw CocoaError(.fileWriteUnknown) }
                        // Serialize the final identity check and commit with UI edits.
                        try DispatchQueue.main.sync {
                            guard !cancellation.cancelled, controller.pdfView.document === box.document,
                                  controller.openDocumentURL.map(controller.canonicalDocumentURL) == destination,
                                  controller.markupChangeVersion == changeVersion else { throw CancellationError() }
                            try Self.commitStagedSave(from: purged, to: destination)
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { throw NSError(domain: "DrawbridgePurge", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(stage): \(error.localizedDescription)", NSUnderlyingErrorKey: error]) }
            }
            DispatchQueue.main.async {
                controller.isPDFFileProcessingOperation = false
                controller.endBusyIndicator()
                controller.updateStatusBar()
                if case .success = result {
                    if replacingOpenDocument, controller.pdfView.document === box.document,
                       controller.markupChangeVersion == changeVersion { controller.reloadAfterPurgingLayers(at: destination) }
                    completion(true)
                } else {
                    if case .failure(let error) = result { controller.lastPurgeErrorMessage = error.localizedDescription }
                    completion(false)
                }
            }
        }
    }

    private func saveCompressedCopy(to destination: URL, level: PDFCompressionLevel) {
        guard let document = pdfView.document, let source = openDocumentURL,
              !isPDFProcessingBusy, !isPDFFileProcessingOperation,
              canonicalDocumentURL(source) != canonicalDocumentURL(destination),
              !FileManager.default.fileExists(atPath: destination.path) else { runAlert(title: "Compression Not Started", informativeText: "Choose a new filename. Your original and existing PDFs stay unchanged."); return }
        let snapshotDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeCompressionSnapshot-\(UUID())")
        do { try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: false) }
        catch { runAlert(title: "Compression Not Started", informativeText: "Choose a new filename. Your original and existing PDFs stay unchanged."); return }
        let snapshot = snapshotDirectory.appendingPathComponent("snapshot.pdf")
        pdfView.rectangleMarkup.finishTextEditing()
        let records = RectangleMarkupRecord.capture(document)
        let navigation = PDFTKBookmarkWriter.captureNavigation(in: document)
        let labels = embeddedPageLabelsForSave(in: document)
        let stamp = pdfView.rectangleMarkup.sourceStamp
        let imported = pdfView.rectangleMarkup.importedPlan()
        let structure = pageStructureState?.document === document ? pageStructureState?.plan(for: document, forceOriginal: imported != nil) : nil
        let box = PDFDocumentBox(document: document)
        let cancellation = PDFProcessingCancellation()
        isPDFFileProcessingOperation = true
        beginBusyIndicator("Reducing File Size…", detail: "Capturing current edits into a private copy…")
        updateStatusBar()
        setBusyCancelAction { [weak self] in cancellation.cancel(); self?.setBusyCancelAction(nil) }
        let controller = self
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                defer { try? FileManager.default.removeItem(at: snapshotDirectory) }
                if cancellation.cancelled { throw CancellationError() }
                let saved: Bool
                if let structure {
                    saved = structure.write(document: box.document, currentSource: source, destination: snapshot, expectedStamp: stamp, labels: labels, records: records, navigation: navigation, importedPlan: imported, onCommitted: { _ in })
                } else {
                    saved = Self.writePDFDocument(box.document, to: snapshot, pageLabels: labels, navigationSourceURL: source, rectangleRecords: records, rectangleSourceStamp: stamp, navigationSnapshot: navigation, importedPlan: imported)
                }
                guard saved else { throw CocoaError(.fileWriteUnknown) }
                return try PDFCompression.saveCopy(source: snapshot, destination: destination, level: level, progress: { detail in
                    DispatchQueue.main.async { controller.updateBusyIndicatorDetail(detail) }
                }, cancelled: { cancellation.cancelled })
            }
            DispatchQueue.main.async {
                controller.isPDFFileProcessingOperation = false
                controller.endBusyIndicator()
                controller.updateStatusBar()
                switch result {
                case .success(let report):
                    let before = ByteCountFormatter.string(fromByteCount: Int64(report.originalBytes), countStyle: .file)
                    let after = ByteCountFormatter.string(fromByteCount: Int64(report.reducedBytes), countStyle: .file)
                    controller.runAlert(title: report.saved ? (level == .high ? "Rasterized Copy Saved" : "Compressed Copy Saved") : "PDF Already Compact", informativeText: report.saved
                        ? "Before: \(before)\nAfter: \(after)\n\nSaved to \(destination.path). Your original PDF and current edits are unchanged.\n\n" + (level == .high ? "Pages are rasterized; text, links, layers, forms and markups are no longer editable. File size can increase for some PDFs." : "Vector linework and text were preserved. Images may have reduced quality.")
                        : "No smaller result was available at this level. No copy was saved; your original and current edits are unchanged.")
                case .failure(let error):
                    if !(error is CancellationError) { controller.runAlert(title: "Compression Failed", informativeText: error.localizedDescription, style: .warning) }
                }
            }
        }
    }

    func flattenPDF() {
        guard let document = pdfView.document, let source = openDocumentURL,
              !isPDFProcessingBusy else { beep(); return }
        if hasUnsavedChanges() {
            persistDocument(to: source, adoptAsPrimaryDocument: false, busyMessage: "Saving PDF…", document: document, completion: { [weak self] saved in
                if saved { self?.flattenPDF() }
            })
            return
        }
        let cancellation = PDFProcessingCancellation()
        let unflattening = PDFAnnotationFlattener.canUnflatten(document)
        let output = canonicalDocumentURL(source)
        isPDFFileProcessingOperation = true
        beginBusyIndicator(unflattening ? "Unflattening PDF…" : "Flattening PDF…", detail: "Checking annotations…")
        setBusyCancelAction({ [weak self] in
            cancellation.cancel()
            self?.setBusyCancelAction(nil)
            self?.updateBusyIndicatorDetail("Canceling after the current processing step…")
        })
        let documentID = ObjectIdentifier(document)
        let controller = self
        DispatchQueue.global(qos: .userInitiated).async {
            let progress: @Sendable (String) -> Void = { detail in
                DispatchQueue.main.async { controller.updateBusyIndicatorDetail(detail) }
            }
            let result = Result {
                try unflattening ? PDFAnnotationFlattener.unflatten(source: output, progress: progress, cancelled: { cancellation.cancelled })
                    : PDFAnnotationFlattener.flatten(source: source, destination: output, progress: progress, cancelled: { cancellation.cancelled })
            }
            DispatchQueue.main.async {
                let owner = controller
                owner.isPDFFileProcessingOperation = false
                owner.endBusyIndicator()
                switch result {
                case .success(let report):
                    if owner.pdfView.document.map(ObjectIdentifier.init) == documentID, !owner.hasUnsavedChanges() {
                        owner.openDocument(at: output)
                    }
                    var details: [String] = []
                    if unflattening { details.append("Restored \(report.restoredAnnotations) editable annotation(s) without duplicating their visible content.") }
                    if report.flattened > 0 {
                        details.append("Made \(report.flattened) visible markup(s) part of the page. Click Unflatten to restore editing.")
                    }
                    if report.removedSHXComments > 0 {
                        details.append("Removed \(report.removedSHXComments) redundant AutoCAD text comment box(es). The original drawing text and linework are preserved.")
                    }
                    if report.retainedMarkups > 0 {
                        details.append("\(report.retainedMarkups) unsupported or hidden markup(s) remain editable.")
                    }
                    details.append("Saved to the PDF you have open. Links and forms were preserved.")
                    owner.runAlert(title: unflattening ? "PDF Unflattened and Saved" : "PDF Flattened and Saved", informativeText: details.joined(separator: "\n\n"))
                case .failure(let error):
                    if !(error is CancellationError) { owner.runAlert(title: unflattening ? "Unflatten Failed" : "Flatten Failed", informativeText: error.localizedDescription, style: .warning) }
                }
            }
        }
    }

    func reduceFileSize() {
        guard pdfView.document != nil, openDocumentURL != nil, !isPDFProcessingBusy, !isPDFFileProcessingOperation else { beep(); return }
        guard let level = PDFCompressionPicker().choose() else { return }
        if level == .low { reduceFileSizeLosslessly(); return }
        guard let source = openDocumentURL else { return }
        let panel = NSSavePanel(); panel.title = level == .high ? "Save Rasterized Copy" : "Save Compressed Copy"
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + (level == .high ? " - Rasterized.pdf" : " - Compressed.pdf")
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        saveCompressedCopy(to: destination, level: level)
    }

    private func reduceFileSizeLosslessly() {
        guard let document = pdfView.document, let source = openDocumentURL, !isPDFProcessingBusy else { beep(); return }
        if hasUnsavedChanges() {
            persistDocument(to: source, adoptAsPrimaryDocument: false, busyMessage: "Saving PDF…", document: document, completion: { [weak self] saved in
                if saved { self?.reduceFileSizeLosslessly() }
            })
            return
        }
        let output = canonicalDocumentURL(source)
        let cancellation = PDFProcessingCancellation()
        let documentID = ObjectIdentifier(document)
        isPDFFileProcessingOperation = true
        beginBusyIndicator("Reducing File Size…", detail: "Preparing lossless compression…")
        setBusyCancelAction({ [weak self] in
            cancellation.cancel()
            self?.setBusyCancelAction(nil)
            self?.updateBusyIndicatorDetail("Canceling after the current processing step…")
        })
        let controller = self
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try PDFLosslessReducer.reduce(source: output, progress: { detail in
                    DispatchQueue.main.async { controller.updateBusyIndicatorDetail(detail) }
                }, cancelled: { cancellation.cancelled })
            }
            DispatchQueue.main.async {
                controller.isPDFFileProcessingOperation = false
                controller.endBusyIndicator()
                switch result {
                case .success(let report):
                    if report.saved, controller.pdfView.document.map(ObjectIdentifier.init) == documentID,
                       !controller.hasUnsavedChanges() {
                        controller.openDocument(at: output)
                    }
                    let before = ByteCountFormatter.string(fromByteCount: Int64(report.originalBytes), countStyle: .file)
                    let after = ByteCountFormatter.string(fromByteCount: Int64(report.reducedBytes), countStyle: .file)
                    controller.runAlert(title: report.saved ? "PDF Reduced and Saved" : "PDF Already Compact", informativeText: report.saved
                        ? "Before: \(before)\nAfter: \(after)\n\nSaved to the PDF you have open. Image resolution, graphics, text, links and Unflatten recovery were preserved."
                        : "No smaller lossless result was available. Your PDF was left unchanged. Images already compressed as JPEG may not shrink without reducing quality.")
                case .failure(let error):
                    if !(error is CancellationError) { controller.runAlert(title: "Reduce File Size Failed", informativeText: error.localizedDescription, style: .warning) }
                }
            }
        }
    }
}
