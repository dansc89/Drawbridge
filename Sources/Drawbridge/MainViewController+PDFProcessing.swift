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
        let response = runAlert(title: "Purge Layers", informativeText: "Save a new PDF copy? All layers will be removed, but artwork and annotations will be retained. Previously hidden content will become visible. Annotations remain editable. The original PDF and your current edits stay unchanged.", style: .warning, buttons: ["Save Purged Copy…", "Cancel"])
        guard response == .alertFirstButtonReturn else { return }
        let panel = NSSavePanel()
        panel.title = "Purge Layers — Save Copy"
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + " - Purged.pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        savePurgedLayersCopy(to: destination) { [weak self] success in
            self?.runAlert(title: success ? "Purged Copy Saved" : "Purge Layers Failed", informativeText: success ? "Saved to \(destination.path). Your original document is still open and unchanged." : "No purged copy was saved. Choose a new filename; existing files are never replaced. Your original and current edits remain unchanged.")
        }
    }

    /// Freeze the same structural/markup/navigation inputs as Save, but never run
    /// Save's adoption/clean-state callbacks and never write to the open source.
    func savePurgedLayersCopy(to destination: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let document = pdfView.document, let source = openDocumentURL,
              !isPDFProcessingBusy, !isPDFFileProcessingOperation,
              canonicalDocumentURL(source) != canonicalDocumentURL(destination),
              !FileManager.default.fileExists(atPath: destination.path) else { completion(false); return }
        let snapshotDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgePurgeSnapshot-\(UUID())")
        do { try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: false) }
        catch { completion(false); return }
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
        beginBusyIndicator("Purging Layers…", detail: "Capturing current edits into a private copy…")
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
                try PDFLayerPurger.purge(source: snapshot, destination: destination, cancelled: { cancellation.cancelled })
            }
            DispatchQueue.main.async {
                controller.isPDFFileProcessingOperation = false
                controller.endBusyIndicator()
                controller.updateStatusBar()
                if case .success = result { completion(true) } else { completion(false) }
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
        guard let document = pdfView.document, let source = openDocumentURL, !isPDFProcessingBusy else { beep(); return }
        if hasUnsavedChanges() {
            persistDocument(to: source, adoptAsPrimaryDocument: false, busyMessage: "Saving PDF…", document: document, completion: { [weak self] saved in
                if saved { self?.reduceFileSize() }
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
