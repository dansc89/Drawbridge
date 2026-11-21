import AppKit
import PDFKit

/// A view-only native-layer rendering source. The editable Review document,
/// annotation instances, revision cursor and undo targets never change.
final class ReviewLayerPresentation: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var source: PDFDocument?
    private var box: PDFDisplayBox = .cropBox
    private var pages: [ObjectIdentifier: PDFPage] = [:]
    func install(_ source: PDFDocument, for document: PDFDocument, box: PDFDisplayBox = .cropBox) {
        lock.lock(); defer { lock.unlock() }
        var mapping: [ObjectIdentifier: PDFPage] = [:]
        for index in 0..<source.pageCount {
            guard let target = document.page(at: index), let page = source.page(at: index) else { continue }
            page.displaysAnnotations = false
            mapping[ObjectIdentifier(target)] = page
        }
        self.source = source; self.box = box; pages = mapping
    }
    func selectionSource(for page: PDFPage) -> (PDFPage, PDFDocument)? {
        lock.lock(); defer { lock.unlock() }
        guard let source, let mapped = pages[ObjectIdentifier(page)] else { return nil }
        return (mapped, source)
    }
    func isInstalled(in document: PDFDocument) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let page = document.page(at: 0) else { return false }
        return pages[ObjectIdentifier(page)] != nil
    }
    func clear() { lock.lock(); defer { lock.unlock() }; source = nil; pages.removeAll() }
    func setBox(_ box: PDFDisplayBox) { lock.lock(); defer { lock.unlock() }; self.box = box }
    func draw(_ page: PDFPage, box requestedBox: PDFDisplayBox? = nil, to context: CGContext) {
        lock.lock()
        let base = pages[ObjectIdentifier(page)], retainedSource = source, box = requestedBox ?? self.box
        lock.unlock()
        defer { withExtendedLifetime(retainedSource) {} }
        context.saveGState()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: page.bounds(for: box).size))
        if let base { base.draw(with: box, to: context) }
        else { page.draw(with: box, to: context); context.restoreGState(); return }
        if page.displaysAnnotations {
            for annotation in page.annotations where annotation.shouldDisplay {
                context.saveGState()
                // Match PDFPage.draw: annotation renderers receive the caller's
                // context, and handle their own box/rotation coordinates.
                annotation.draw(with: box, in: context)
                context.restoreGState()
            }
        }
        context.restoreGState()
    }
}
