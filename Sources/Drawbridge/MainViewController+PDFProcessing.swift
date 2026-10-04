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
                    if report.saved { controller.openDocument(at: output) }
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
