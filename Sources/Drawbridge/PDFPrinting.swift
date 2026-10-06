import AppKit
import PDFKit

/// Printing uses PDFKit's document rendering, never the filtered viewer or
/// a rasterized screenshot. Creating a job does not serialize or save the PDF.
@MainActor
enum PDFPrinting {
    static func canPrint(_ document: PDFDocument?) -> Bool {
        guard let document else { return false }
        return document.pageCount > 0 && !document.isLocked && document.allowsPrinting
    }

    static func operation(for document: PDFDocument, currentPageIndex: Int? = nil,
                          printInfo: NSPrintInfo = .shared) -> NSPrintOperation? {
        guard canPrint(document), let info = printInfo.copy() as? NSPrintInfo else { return nil }
        if let currentPageIndex, !(0..<document.pageCount).contains(currentPageIndex) { return nil }
        let settings = info.dictionary()
        // Do not inherit a stale range or scale from another document's job.
        info.scalingFactor = 1
        settings[NSPrintInfo.AttributeKey.allPages] = currentPageIndex == nil
        let firstPage = currentPageIndex.map { $0 + 1 } ?? 1
        settings[NSPrintInfo.AttributeKey.firstPage] = firstPage
        settings[NSPrintInfo.AttributeKey.lastPage] = currentPageIndex == nil ? document.pageCount : firstPage
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false) else { return nil }
        operation.printPanel.options.formUnion([.showsPageRange, .showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        return operation
    }
}

@MainActor
extension MainViewController {
    @objc func commandPrint(_ sender: Any?) { printPDF(currentSheetOnly: false) }
    @objc func commandPrintCurrentSheet(_ sender: Any?) { printPDF(currentSheetOnly: true) }

    private func printPDF(currentSheetOnly: Bool) {
        guard !isPDFProcessingBusy, let document = pdfView.document,
              PDFPrinting.canPrint(document) else { return }
        pdfView.rectangleMarkup.finishTextEditing()
        let pageIndex: Int?
        if currentSheetOnly {
            guard let page = pdfView.currentPage else { return }
            pageIndex = document.index(for: page)
        } else {
            pageIndex = nil
        }
        guard let operation = PDFPrinting.operation(for: document, currentPageIndex: pageIndex) else {
            runAlert(title: "Could Not Prepare Printing", informativeText: "The PDF could not be prepared for the print dialog. Your document and edits remain open.", style: .warning)
            return
        }
        operation.jobTitle = openDocumentURL?.lastPathComponent ?? "Drawbridge PDF"
        if let window = view.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}
