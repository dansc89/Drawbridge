import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class MarkupRefreshPerformanceTests: XCTestCase {
    private func document(pages: Int = 2) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    private func scroll(_ view: MarkupPDFView) {
        // Invoke the actual Objective-C notification handler, independent of PDFKit layout noise.
        _ = view.perform(NSSelectorFromString("handleClipViewBoundsDidChange:"), with: Notification(name: NSView.boundsDidChangeNotification) as NSNotification)
    }

    func testControllerScrollRefreshesOverlaysOncePreservingSnapshotRequestsAndInspectorDraft() throws {
        _ = NSApplication.shared
        let controller = MainViewController(); _ = controller.view
        let doc = try document()
        controller.pdfView.setMarkupDocument(doc)
        defer { controller.pdfView.setMarkupDocument(nil) }
        let page = try XCTUnwrap(doc.page(at: 0))
        let session = controller.pdfView.rectangleMarkup
        session.canEdit = { true }
        _ = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 40, y: 40, width: 80, height: 60), kind: .rectangle))
        let inspector = controller.rectangleToolbar.propertiesController
        inspector.refresh(); inspector.strokeOpacity.stringValue = "37.25"
        var overlays = 0, rectangles = 0, snapshotRequests = 0, presentations = 0, callbacks = 0
        controller.pdfView.onViewportRefreshOperation = {
            switch $0 { case .hyperlinkOverlay: overlays += 1; case .snapshotPreviewViewports: snapshotRequests += 1 }
        }
        session.onOverlayRefresh = { rectangles += 1 }
        let presentation = session.onPresentationChanged
        session.onPresentationChanged = { presentations += 1; presentation?() }
        let viewport = controller.pdfView.onViewportChanged
        controller.pdfView.onViewportChanged = { callbacks += 1; viewport?() }
        scroll(controller.pdfView)
        XCTAssertEqual(overlays, 1)
        XCTAssertEqual(rectangles, 1)
        XCTAssertEqual(snapshotRequests, 1)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(presentations, 0)
        XCTAssertEqual(inspector.strokeOpacity.stringValue, "37.25")
        // Explicit refresh callers retain their complete refresh behavior.
        controller.pdfView.refreshHyperlinkHighlights()
        XCTAssertEqual(overlays, 2)
        XCTAssertEqual(rectangles, 2)
        XCTAssertEqual(snapshotRequests, 2)
    }

    func testStandaloneScrollRefreshesSnapshotViewportsWithoutController() throws {
        let view = MarkupPDFView(frame: .zero)
        var snapshotRequests = 0, overlays = 0, rectangles = 0
        view.onViewportRefreshOperation = {
            switch $0 { case .snapshotPreviewViewports: snapshotRequests += 1; case .hyperlinkOverlay: overlays += 1 }
        }
        view.rectangleMarkup.onOverlayRefresh = { rectangles += 1 }
        scroll(view)
        XCTAssertEqual(snapshotRequests, 1)
        XCTAssertEqual(overlays, 1)
        XCTAssertEqual(rectangles, 1)
    }

    private func snapshotView() throws -> (MarkupPDFView, NSWindow, String) {
        _ = NSApplication.shared
        let doc = try document(pages: 1)
        let page = try XCTUnwrap(doc.page(at: 0))
        // A unique key prevents another test's cached detail from satisfying this test.
        let data = try XCTUnwrap(doc.dataRepresentation()) + Data(("\n%viewport-" + UUID().uuidString + "\n").utf8)
        let stamp = try XCTUnwrap(try SnapshotStampFactory.make(payload: SnapshotPayload(data: data),
            bounds: page.bounds(for: .mediaBox), rotation: 0) as? DrawbridgeSnapshotAnnotation)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = MarkupPDFView(frame: try XCTUnwrap(window.contentView).bounds)
        window.contentView!.addSubview(view)
        view.setMarkupDocument(doc)
        view.autoScales = false; view.scaleFactor = 0.5
        view.go(to: page); window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.visiblePages.contains { $0 === page })
        page.addAnnotation(stamp)
        // Do not deliver clip notifications: scale/feedback must own snapshot updates.
        NotificationCenter.default.removeObserver(view, name: NSView.boundsDidChangeNotification, object: nil)
        return (view, window, try XCTUnwrap(stamp.previewKey))
    }

    func testScaleNotificationRequestsSnapshotDetailWithoutClipNotificationOrDraw() throws {
        let (view, window, key) = try snapshotView()
        defer { view.setMarkupDocument(nil); withExtendedLifetime(window) {} }
        var snapshotRequests = 0
        view.onViewportRefreshOperation = { if case .snapshotPreviewViewports = $0 { snapshotRequests += 1 } }
        expectation(forNotification: SnapshotPreviewCache.ready, object: nil) {
            ($0.userInfo?["captureKeys"] as? Set<String>)?.contains(key) == true
        }
        view.scaleFactor = 4
        XCTAssertGreaterThan(snapshotRequests, 0, "Scale notifications must update the snapshot viewport/device density")
        waitForExpectations(timeout: 5)
    }

    func testZoomFeedbackRequestsSnapshotDetailWithoutPDFOrClipNotificationOrDraw() throws {
        let (view, window, key) = try snapshotView()
        defer { view.setMarkupDocument(nil); withExtendedLifetime(window) {} }
        // Isolate the real zoom -> interactive feedback producer from PDFKit notifications.
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewDocumentChanged] {
            NotificationCenter.default.removeObserver(view, name: name, object: view)
        }
        var snapshotRequests = 0, callbacks = 0
        view.onViewportRefreshOperation = { if case .snapshotPreviewViewports = $0 { snapshotRequests += 1 } }
        view.onViewportChanged = { callbacks += 1 }
        expectation(forNotification: SnapshotPreviewCache.ready, object: nil) {
            ($0.userInfo?["captureKeys"] as? Set<String>)?.contains(key) == true
        }
        XCTAssertTrue(view.zoom(by: 8))
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(snapshotRequests, 1, "Interactive feedback must refresh once even when no clip notification arrives")
        waitForExpectations(timeout: 5)
    }

    func testBatchScaleUndoNotifiesEachPageOnceWithFinalHeterogeneousMeasurementStates() throws {
        let doc = try document(pages: 3)
        let pages = try (0..<3).map { try XCTUnwrap(doc.page(at: $0)) }
        let session = RectangleMarkupController(); session.bind(to: doc)
        let eighth = try XCTUnwrap(DrawingScale.architectural(inches: 0.125, name: "eighth"))
        let quarter = try XCTUnwrap(DrawingScale.architectural(inches: 0.25, name: "quarter"))
        let metric = try XCTUnwrap(DrawingScale.metric(ratio: 100))
        session.applyDrawingScale(eighth, to: [pages[0]])
        session.applyDrawingScale(quarter, to: [pages[1]])
        let points = [CGPoint(x: 40, y: 40), CGPoint(x: 130, y: 40)]
        let measurements = try [eighth, quarter, metric, eighth].enumerated().map { index, scale in
            try XCTUnwrap(session.createMeasurement(on: pages[index / 2], points: points, kind: .perimeter, closed: false, scale: scale))
        }
        let prior = measurements.map { MeasurementMetadata.measurement($0)! }
        let labels = measurements.map(\.contents)
        session.undo.removeAllActions(); session.undo.groupsByEvent = false
        var notified: [Int] = []
        var expectedMeasurements = prior
        var expectedPageScales: [DrawingScale?] = [eighth, quarter, nil]
        session.onMutation = { page in
            notified.append(doc.index(for: page))
            XCTAssertEqual(measurements.map { MeasurementMetadata.measurement($0)! }, expectedMeasurements, "Observers must see the final states, never intermediate page-scale-derived measurements")
            XCTAssertEqual(pages.map { MeasurementMetadata.scale(on: $0) }, expectedPageScales)
        }
        expectedMeasurements = prior.map { var value = $0; value.scale = metric; return value }
        expectedPageScales = [metric, metric, nil]
        session.undo.beginUndoGrouping(); session.applyDrawingScale(metric, to: Array(pages.prefix(2))); session.undo.endUndoGrouping()
        // Initial apply and every undo/redo must publish one final notification per page.
        XCTAssertEqual(notified.sorted(), [0, 1])
        for _ in 0..<3 {
            notified = []; expectedMeasurements = prior; expectedPageScales = [eighth, quarter, nil]
            session.undo.undo()
            XCTAssertEqual(notified.sorted(), [0, 1])
            XCTAssertEqual(measurements.map(\.contents), labels)
            notified = []; expectedMeasurements = prior.map { var value = $0; value.scale = metric; return value }; expectedPageScales = [metric, metric, nil]
            session.undo.redo()
            XCTAssertEqual(notified.sorted(), [0, 1])
        }
        notified = []
        session.undo.beginUndoGrouping(); session.applyDrawingScale(metric, to: Array(pages.prefix(2))); session.undo.endUndoGrouping()
        XCTAssertTrue(notified.isEmpty, "Unchanged scales must not notify")
    }

    func testFilteredPublicationReloadsRealTableExactlyOnceOnColdAndWarmCache() throws {
        _ = NSApplication.shared
        let controller = MainViewController(); _ = controller.view
        let doc = try document()
        for index in 0..<2 {
            let page = try XCTUnwrap(doc.page(at: index))
            for title in ["matching", "other"] {
                let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 50, height: 50), forType: .square, withProperties: nil)
                annotation.contents = title; page.addAnnotation(annotation)
            }
        }
        controller.pdfView.setMarkupDocument(doc)
        defer { controller.pdfView.setMarkupDocument(nil) }
        controller.markupFilterText = "matching"
        var reloads = 0
        controller.onMarkupListReload = { reloads += 1 }
        for _ in 0..<2 {
            reloads = 0
            controller.performRefreshMarkups(selecting: nil, forceImmediate: true)
            XCTAssertEqual(reloads, 1)
            XCTAssertEqual(controller.markupItems.count, 2)
            XCTAssertEqual(controller.markupsTable.numberOfRows, 2)
            XCTAssertEqual(controller.markupsCountLabel.stringValue, "2 matches")
        }
    }
}
