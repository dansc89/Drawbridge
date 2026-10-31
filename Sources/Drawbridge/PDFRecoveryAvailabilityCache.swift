import PDFKit

/// Recovery metadata belongs to the immutable Core Graphics backing document,
/// not the current page or markup selection. Keep only one active inspection;
/// a reload/new backing reference or page-structure change must inspect again.
@MainActor
final class PDFRecoveryAvailabilityCache {
    private weak var owner: PDFDocument?
    private var backing: CGPDFDocument?
    private var pageCount = -1
    private var result = false
    private(set) var inspectionCount = 0

    func canUnflatten(_ document: PDFDocument?) -> Bool {
        guard let document, let reference = document.documentRef else {
            owner = nil; backing = nil; pageCount = -1; result = false
            return false
        }
        if owner === document, backing === reference, pageCount == document.pageCount { return result }
        owner = document; backing = reference; pageCount = document.pageCount
        inspectionCount += 1
        result = PDFAnnotationFlattener.canUnflatten(document)
        return result
    }
}
