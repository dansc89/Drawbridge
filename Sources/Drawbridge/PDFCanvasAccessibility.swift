import AppKit
import PDFKit

/// An immutable, detached page is read on the text queue, never the editing page.
private final class PDFCanvasTextPage: @unchecked Sendable {
    let document = PDFDocument()
    let page: PDFPage
    init?(_ source: PDFPage) {
        guard let copy = source.copy() as? PDFPage else { return nil }
        copy.annotations.forEach(copy.removeAnnotation)
        page = copy
        document.insert(copy, at: 0)
    }
}

private final class PDFCanvasTextRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

@MainActor
final class PDFCanvasAccessibility {
    private weak var view: MarkupPDFView?
    private let textElement = NSAccessibilityElement()
    private var textPageRef: CGPDFPage?
    private var textPage: PDFPage?
    private var textGeneration = 0
    private var textRequest: PDFCanvasTextRequest?
    private var text = ""
    private static let textQueue = DispatchQueue(label: "com.drawbridge.accessible-page-text", qos: .utility)

    init(view: MarkupPDFView) { self.view = view }

    func reset() {
        textRequest?.cancel()
        textRequest = nil
        textGeneration += 1
        textPageRef = nil
        textPage = nil
        text = ""
        textElement.setAccessibilityValue("")
    }

    func elements() -> [Any] {
        guard let view, let document = view.document, let page = view.currentPage else { return [] }
        let index = document.index(for: page)
        textElement.setAccessibilityParent(view)
        textElement.setAccessibilityRole(.staticText)
        textElement.setAccessibilityLabel("Page \(index + 1) of \(document.pageCount)")
        textElement.setAccessibilityFrame(NSAccessibility.screenRect(fromView: view, rect: view.bounds))
        // PDFKit's virtual tree exposes every page, even in single-page mode.
        // Keep page text readable without synchronously tagging the entire set.
        if (page.pageRef != nil && page.pageRef !== textPageRef) || (page.pageRef == nil && page !== textPage) {
            textPageRef = page.pageRef
            textPage = page
            text = ""
            textRequest?.cancel()
            let request = PDFCanvasTextRequest()
            textRequest = request
            textGeneration += 1
            let generation = textGeneration
            if let detached = PDFCanvasTextPage(page) {
                Self.textQueue.async { [weak self] in
                    guard !request.isCancelled else { return }
                    let value = detached.page.string ?? ""
                    guard !request.isCancelled else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.textGeneration == generation else { return }
                        self.text = value
                        self.textElement.setAccessibilityValue(value)
                        NSAccessibility.post(element: self.textElement, notification: .valueChanged)
                    }
                }
            }
        }
        textElement.setAccessibilityValue(text)
        var result: [Any] = [textElement]
        for annotation in page.annotations where annotation.shouldDisplay && !(annotation is SnapshotViewportTileAnnotation) {
            guard view.rectangleMarkup.layerIsVisible(annotation) else { continue }
            let frame = view.convert(annotation.bounds, from: page).intersection(view.bounds)
            guard !frame.isEmpty, !frame.isNull else { continue }
            let element = PDFCanvasMarkupElement(view: view, annotation: annotation)
            element.setAccessibilityParent(view)
            element.setAccessibilityRole(annotation.type == "Link" ? .button : .layoutItem)
            element.setAccessibilityLabel(annotation.contents ?? annotation.type ?? "Markup")
            element.setAccessibilityFrame(NSAccessibility.screenRect(fromView: view, rect: frame))
            result.append(element)
        }
        return result
    }
}

@MainActor
private final class PDFCanvasMarkupElement: NSAccessibilityElement {
    private nonisolated let press: @MainActor @Sendable () -> Void
    init(view: MarkupPDFView, annotation: PDFAnnotation) {
        let document = view.document
        let page = view.currentPage
        press = { [weak view, weak document, weak page] in
            guard let view, let document, let page,
                  view.document === document, view.currentPage === page else { return }
            _ = view.activateAccessibleAnnotation(annotation)
        }
        super.init()
    }
    override func accessibilityPerformPress() -> Bool {
        let action = press
        Task { @MainActor in action() }
        return true
    }
}
