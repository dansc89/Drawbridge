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
    private var foreign: [ObjectIdentifier: PDFPageStructurePlan.PageSource] = [:]
    private var retainedDocuments: [PDFDocument] = []

    func register(page: PDFPage, source: URL, stamp: PDFMarkupSourceStamp, index: Int, document: PDFDocument) {
        foreign[ObjectIdentifier(page)] = .init(source: source, stamp: stamp, index: index)
        if !retainedDocuments.contains(where: { $0 === document }) { retainedDocuments.append(document) }
    }

    init(document: PDFDocument, stamp: PDFMarkupSourceStamp, source: URL) {
        self.document = document; self.stamp = stamp; self.source = source
        originalPages = (0..<document.pageCount).compactMap(document.page(at:))
        savedPages = originalPages.map(ObjectIdentifier.init)
    }

    func plan(for document: PDFDocument, forceOriginal: Bool = false) -> PDFPageStructurePlan? {
        guard self.document === document else { return nil }
        let pages = (0..<document.pageCount).compactMap(document.page(at:))
        // Imported object references always refer to the immutable opening graph,
        // even after saving a reorder and then saving its undo back to original order.
        guard forceOriginal || pages.map(ObjectIdentifier.init) != savedPages else { return nil }
        let sources = pages.compactMap { page -> PDFPageStructurePlan.PageSource? in
            if let imported = foreign[ObjectIdentifier(page)] { return imported }
            return originalPages.firstIndex { $0 === page }.map { .init(source: source, stamp: stamp, index: $0) }
        }
        guard sources.count == pages.count else { return nil }
        return PDFPageStructurePlan(source: source, retainedStamp: stamp, pageSources: sources)
    }
}

struct PDFPageStructurePlan: Sendable {
    let source: URL
    // Retain ownership of the frozen snapshot throughout the asynchronous save.
    let retainedStamp: PDFMarkupSourceStamp
    struct PageSource: Sendable {
        let source: URL
        let stamp: PDFMarkupSourceStamp
        let index: Int
    }
    let pageSources: [PageSource]
    var sourceIndexes: [Int] { pageSources.map(\.index) }

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
            var arguments = [source.path, "--stream-data=preserve", "--pages"]
            // Each page carries its own immutable provenance, including foreign PDFs.
            for page in pageSources { arguments += [page.source.path, String(page.index + 1)] }
            arguments += ["--", selected.path]
            guard PDFTKBookmarkWriter.run(executable, arguments: arguments),
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
        guard let result = CGPDFDocument(url as CFURL),
              result.numberOfPages == pageSources.count else { return false }
        for (index, provenance) in pageSources.enumerated() {
            guard let original = CGPDFDocument(provenance.source as CFURL),
                  let before = original.page(at: provenance.index + 1), let after = result.page(at: index + 1),
                  before.rotationAngle == after.rotationAngle else { return false }
            for box in [CGPDFBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
                guard before.getBoxRect(box) == after.getBoxRect(box) else { return false }
            }
        }
        return true
    }
}
