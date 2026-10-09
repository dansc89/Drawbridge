import Foundation
import PDFKit

/// Retains the immutable opening snapshot so deleting pages and undoing a saved
/// deletion both preserve the original vector streams, fonts, and raster images.
@MainActor
final class PDFPageStructureState {
    weak var document: PDFDocument?
    let stamp: PDFMarkupSourceStamp
    let source: URL
    let originalPages: [PDFPage]
    var savedPages: [ObjectIdentifier]

    init(document: PDFDocument, stamp: PDFMarkupSourceStamp, source: URL) {
        self.document = document; self.stamp = stamp; self.source = source
        originalPages = (0..<document.pageCount).compactMap(document.page(at:))
        savedPages = originalPages.map(ObjectIdentifier.init)
    }

    func plan(for document: PDFDocument, forceOriginal: Bool = false) -> PDFPageStructurePlan? {
        guard self.document === document else { return nil }
        let pages = (0..<document.pageCount).compactMap(document.page(at:))
        guard pages.map(ObjectIdentifier.init) != savedPages || (forceOriginal && pages.map(ObjectIdentifier.init) != originalPages.map(ObjectIdentifier.init)) else { return nil }
        let sourceIndexes = pages.compactMap { page in originalPages.firstIndex { $0 === page } }
        guard sourceIndexes.count == pages.count else { return nil }
        return PDFPageStructurePlan(source: source, retainedStamp: stamp, sourceIndexes: sourceIndexes)
    }
}

struct PDFPageStructurePlan: Sendable {
    let source: URL
    // Retain ownership of the frozen snapshot throughout the asynchronous save.
    let retainedStamp: PDFMarkupSourceStamp
    let sourceIndexes: [Int]

    func write(document: PDFDocument, currentSource: URL, destination: URL,
               expectedStamp: PDFMarkupSourceStamp?, labels: [Int: String],
               records: [RectangleMarkupRecord], navigation: PDFTKBookmarkWriter.NavigationSnapshot,
               importedPlan: ImportedMarkupPlan? = nil,
               onCommitted: (PDFMarkupSourceStamp) -> Void) -> Bool {
        guard let executable = PDFTKBookmarkWriter.executableURL(), !sourceIndexes.isEmpty,
              expectedStamp?.matchesSource(currentSource) == true else { return false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgePageSave-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let selected = directory.appendingPathComponent("pages.pdf")
            let candidate = directory.appendingPathComponent("candidate.pdf")
            let range = sourceIndexes.map { String($0 + 1) }.joined(separator: ",")
            guard PDFTKBookmarkWriter.run(executable, arguments: [source.path, "--stream-data=preserve", "--pages", ".", range, "--", selected.path]),
                  verifySelectedPages(at: selected),
                  let selectedStamp = PDFMarkupSourceStamp.capture(selected),
                  PDFRectangleWriter.prepareInspection(source: selected),
                  PDFRectangleWriter.write(document: document, source: selected, destination: candidate,
                    pageLabels: labels, records: records, expectedSourceStamp: selectedStamp, navigationSnapshot: navigation, importedPlan: importedPlan?.rebased(to: selectedStamp)),
                  verifySelectedPages(at: candidate),
                  expectedStamp?.matchesSource(currentSource) == true else { return false }
            try MainViewController.commitStagedSave(from: candidate, to: destination)
            guard let stamp = PDFMarkupSourceStamp.capture(destination) else { return false }
            onCommitted(stamp)
            return true
        } catch { return false }
    }

    private func verifySelectedPages(at url: URL) -> Bool {
        guard let original = CGPDFDocument(source as CFURL), let result = CGPDFDocument(url as CFURL),
              result.numberOfPages == sourceIndexes.count else { return false }
        for (index, sourceIndex) in sourceIndexes.enumerated() {
            guard let before = original.page(at: sourceIndex + 1), let after = result.page(at: index + 1),
                  before.rotationAngle == after.rotationAngle else { return false }
            for box in [CGPDFBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
                guard before.getBoxRect(box) == after.getBoxRect(box) else { return false }
            }
        }
        return true
    }
}
