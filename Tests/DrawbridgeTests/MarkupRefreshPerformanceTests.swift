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

    private func indexedFixture(at url: URL, pages: Int, prefix: String) throws -> [String] {
        let doc = try document(pages: pages)
        var contents: [String] = []
        for index in 0..<pages {
            let page = try XCTUnwrap(doc.page(at: index))
            for text in ["\(prefix)-\(index)", "DrawbridgeMeasure|\(72 + index)"] {
                let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 50, height: 50), forType: .square, withProperties: nil)
                annotation.contents = text
                page.addAnnotation(annotation)
                contents.append(text)
            }
        }
        XCTAssertTrue(doc.write(to: url))
        return contents
    }

    func testDocumentOpenYieldsBeforeIndexingAllPagesAndPreservesFinalResults() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chunked.pdf")
        let pageCount = 65
        let expectedContents = try indexedFixture(at: url, pages: pageCount, prefix: "opened")
        let controller = MainViewController(); _ = controller.view
        defer {
            controller.onMarkupPageIndexed = nil
            controller.onMarkupListReload = nil
            controller.clearToStartState()
        }
        var indexedPages: [Int] = []
        var publications: [Int] = []
        let complete = expectation(description: "final publication")
        controller.onMarkupPageIndexed = { _, index in indexedPages.append(index) }
        controller.onMarkupListReload = {
            publications.append(controller.markupItems.count)
            if controller.markupItems.count == expectedContents.count { complete.fulfill() }
        }
        controller.openDocument(at: url)
        print("Document-open work: \(indexedPages.count)/\(pageCount) pages indexed before return")
        XCTAssertLessThan(indexedPages.count, pageCount, "Opening must return control before indexing every markup page")
        XCTAssertLessThan(controller.totalCachedAnnotationCount(), expectedContents.count)
        wait(for: [complete], timeout: 10)
        controller.onMarkupListReload = nil
        XCTAssertEqual(indexedPages, Array(0..<pageCount), "Each page must be indexed exactly once in document order")
        XCTAssertTrue(publications.contains { $0 > 0 && $0 < expectedContents.count }, "Cold open retains provisional publication")
        XCTAssertEqual(controller.markupItems.map(\.pageIndex), (0..<pageCount).flatMap { [$0, $0] })
        XCTAssertEqual(controller.markupItems.map { $0.annotation.contents ?? "" }, expectedContents)
        XCTAssertEqual(controller.totalCachedAnnotationCount(), expectedContents.count)
        XCTAssertEqual(controller.markupsCountLabel.stringValue, "\(expectedContents.count) markups")
        XCTAssertEqual(controller.markupsTable.numberOfRows, expectedContents.count)
        XCTAssertEqual(controller.indexedMeasurementSummary.count, pageCount)
        XCTAssertEqual(controller.indexedMeasurementSummary.totalPoints, CGFloat((0..<pageCount).reduce(0) { $0 + 72 + $1 }))
        let finishedContents = controller.markupItems.map { $0.annotation.contents }
        controller.refreshMarkups()
        XCTAssertEqual(indexedPages.count, pageCount, "Warm synchronous refresh must not rebuild clean pages")
        XCTAssertEqual(controller.markupItems.map { $0.annotation.contents }, finishedContents)
        print("Document-open final: \(indexedPages.count) pages, \(controller.totalCachedAnnotationCount()) markups; publications \(publications); measurements \(controller.indexedMeasurementSummary)")
        let doc = try XCTUnwrap(controller.pdfView.document)
        for index in 0..<pageCount { controller.markPageMarkupCacheDirty(doc.page(at: index)) }
        controller.refreshMarkups()
        XCTAssertEqual(indexedPages, Array(0..<pageCount) + Array(0..<pageCount), "Explicit refresh must still rebuild every dirty page before returning")
        XCTAssertEqual(controller.markupItems.map { $0.annotation.contents }, finishedContents)
    }

    func testDocumentReplacementClearsPublishedRowsAndSelectionBeforeDeferredIndexing() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("indexed-old.pdf")
        let newURL = directory.appendingPathComponent("replacement.pdf")
        let oldContents = try indexedFixture(at: oldURL, pages: 2, prefix: "old")
        let expected = try indexedFixture(at: newURL, pages: 65, prefix: "replacement")
        let controller = MainViewController(); _ = controller.view
        defer {
            controller.onDocumentOpened = nil
            controller.onMarkupPageIndexed = nil
            controller.onMarkupListReload = nil
            controller.clearToStartState()
        }
        controller.openDocument(at: oldURL)
        controller.refreshMarkups()
        XCTAssertEqual(controller.markupItems.map { $0.annotation.contents ?? "" }, oldContents)
        controller.markupsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertNotNil(controller.currentSelectedAnnotation())
        let labels = Dictionary(uniqueKeysWithValues: Mirror(reflecting: controller).children.compactMap { child -> (String, NSTextField)? in
            guard let name = child.label, let field = child.value as? NSTextField else { return nil }
            return (name, field)
        })
        let measurementCount = try XCTUnwrap(labels["measurementCountLabel"])
        let measurementTotal = try XCTUnwrap(labels["measurementTotalLabel"])
        XCTAssertEqual(measurementCount.stringValue, "Measurements: 2")
        var indexedPages: [Int] = []
        var opened = false
        func assertCleared() {
            XCTAssertTrue(controller.markupItems.isEmpty, "Previous document rows must disappear synchronously")
            XCTAssertEqual(controller.markupsTable.numberOfRows, 0)
            XCTAssertTrue(controller.markupsTable.selectedRowIndexes.isEmpty)
            XCTAssertNil(controller.currentSelectedAnnotation())
            XCTAssertTrue(controller.pdfView.rectangleMarkup.selectedItems.isEmpty)
            XCTAssertEqual(controller.markupsCountLabel.stringValue, "0 items")
            XCTAssertEqual(controller.totalCachedAnnotationCount(), 0)
            XCTAssertEqual(controller.indexedMeasurementSummary.count, 0)
            XCTAssertEqual(controller.indexedMeasurementSummary.totalPoints, 0)
            XCTAssertEqual(measurementCount.stringValue, "Measurements: 0")
            XCTAssertEqual(measurementTotal.stringValue, "Total Length: 0 \(controller.pdfView.measurementUnitLabel)")
            XCTAssertTrue(indexedPages.isEmpty, "Clearing publication must not synchronously index the replacement")
        }
        controller.onDocumentOpened = { url in
            XCTAssertEqual(url, newURL)
            opened = true
            assertCleared()
        }
        controller.onMarkupPageIndexed = { _, index in indexedPages.append(index) }
        let complete = expectation(description: "replacement indexed")
        controller.onMarkupListReload = {
            if controller.markupItems.count == expected.count { complete.fulfill() }
        }
        controller.openDocument(at: newURL)
        XCTAssertTrue(opened)
        assertCleared()
        wait(for: [complete], timeout: 10)
        controller.onMarkupListReload = nil
        XCTAssertEqual(indexedPages, Array(0..<65))
        XCTAssertEqual(controller.markupItems.map(\.pageIndex), (0..<65).flatMap { [$0, $0] })
        XCTAssertEqual(controller.markupItems.map { $0.annotation.contents ?? "" }, expected)
        XCTAssertEqual(controller.markupsTable.numberOfRows, expected.count)
        XCTAssertEqual(controller.markupsCountLabel.stringValue, "\(expected.count) markups")
        XCTAssertEqual(controller.indexedMeasurementSummary.count, 65)
        XCTAssertEqual(controller.indexedMeasurementSummary.totalPoints, CGFloat((0..<65).reduce(0) { $0 + 72 + $1 }))
        XCTAssertTrue(controller.markupsTable.selectedRowIndexes.isEmpty)
        XCTAssertNil(controller.currentSelectedAnnotation())
    }

    func testDocumentOpenCancelsStaleIndexChunksBeforeTheyCanPublish() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("old.pdf")
        let newURL = directory.appendingPathComponent("new.pdf")
        _ = try indexedFixture(at: oldURL, pages: 65, prefix: "old")
        let expected = try indexedFixture(at: newURL, pages: 2, prefix: "new")
        let controller = MainViewController(); _ = controller.view
        defer {
            controller.onMarkupPageIndexed = nil
            controller.onMarkupListReload = nil
            controller.clearToStartState()
        }
        var oldDocument: PDFDocument?
        var oldPages: [Int] = []
        var newPages: [Int] = []
        var switched = false
        var queuedSwitch = false
        var oldPageCountAtSwitch = 0
        var publicationCountAfterSwitch = 0
        let complete = expectation(description: "replacement published and stale continuation drained")
        controller.onMarkupPageIndexed = { doc, index in
            if oldDocument == nil { oldDocument = doc }
            if doc === oldDocument {
                oldPages.append(index)
                if !queuedSwitch {
                    queuedSwitch = true
                    // FIFO sentinel runs after the first real chunk but before its continuation.
                    DispatchQueue.main.async {
                        XCTAssertLessThan(oldPages.count, 65, "A main-queue turn must occur before the old scan finishes")
                        oldPageCountAtSwitch = oldPages.count
                        switched = true
                        controller.openDocument(at: newURL)
                    }
                }
            } else { newPages.append(index) }
        }
        controller.onMarkupListReload = {
            guard switched else { return }
            publicationCountAfterSwitch += 1
            XCTAssertEqual(controller.markupItems.map { $0.annotation.contents ?? "" }, expected, "Cancelled document work must never publish over its replacement")
            DispatchQueue.main.async { complete.fulfill() }
        }
        controller.openDocument(at: oldURL)
        XCTAssertLessThan(oldPages.count, 65)
        wait(for: [complete], timeout: 10)
        controller.onMarkupListReload = nil
        XCTAssertEqual(publicationCountAfterSwitch, 1)
        XCTAssertEqual(newPages, [0, 1])
        XCTAssertLessThan(oldPages.count, 65, "Cancelled continuation must not do further old-document indexing")
        XCTAssertEqual(oldPages.count, oldPageCountAtSwitch, "Stale chunks must do zero indexing after the switch")
        print("Document-switch work: old \(oldPageCountAtSwitch)/65 pages at switch, \(oldPages.count) after drain; new \(newPages.count) pages; \(publicationCountAfterSwitch) replacement publication")
        XCTAssertEqual(controller.openDocumentURL, newURL)
        XCTAssertEqual(controller.markupsCountLabel.stringValue, "4 markups")
        XCTAssertEqual(controller.indexedMeasurementSummary.count, 2)
        XCTAssertEqual(controller.indexedMeasurementSummary.totalPoints, 145)
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
