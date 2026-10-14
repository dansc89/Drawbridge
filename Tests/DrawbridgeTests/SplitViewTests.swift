import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor private final class SplitTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor final class SplitViewTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func panes(_ c: MainViewController) -> [MarkupPDFView] { descendants(c.view).compactMap { $0 as? MarkupPDFView } }
    private func toggle(_ c: MainViewController) { _ = c.tryToPerform(NSSelectorFromString("commandToggleSplitView:"), with: nil) }
    private func fixture(_ body: (MainViewController, NSWindow, PDFDocument) throws -> Void) throws {
        _ = NSApplication.shared
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let ctx = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        for _ in 0..<6 { ctx.beginPDFPage(nil); ctx.endPDFPage() }; ctx.closePDF()
        let doc = try XCTUnwrap(PDFDocument(data: data as Data))
        let c = MainViewController()
        let w = SplitTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentViewController = c
        c.pdfView.setMarkupDocument(doc); c.pdfView.go(to: doc.page(at: 1)!)
        w.layoutIfNeeded()
        defer { w.makeFirstResponder(nil); w.contentViewController = nil }
        try body(c, w, doc)
    }
    func testSameDocumentIndependentNavigationZoomAndCollapseRetainsActiveView() throws {
        try fixture { c, w, doc in
            let left = c.pdfView
            toggle(c); w.layoutIfNeeded()
            let views = panes(c)
            XCTAssertEqual(views.count, 2, "Toggle must create a second real PDF pane")
            guard views.count == 2 else { return }
            let right = try XCTUnwrap(views.first { $0 !== left })
            XCTAssertTrue(right.document === doc); XCTAssertTrue(left.document === doc)
            XCTAssertTrue(right.currentPage === left.currentPage)
            left.autoScales = false; right.autoScales = false
            left.scaleFactor = 0.7; right.scaleFactor = 1.3
            XCTAssertTrue(w.makeFirstResponder(right))
            c.commandNextPage(nil)
            XCTAssertTrue(c.pdfView === right)
            XCTAssertTrue(right.currentPage === doc.page(at: 2))
            XCTAssertTrue(left.currentPage === doc.page(at: 1))
            XCTAssertEqual(left.scaleFactor, 0.7, accuracy: 0.001)
            XCTAssertEqual(right.scaleFactor, 1.3, accuracy: 0.001)
            XCTAssertTrue(left.rectangleMarkup === right.rectangleMarkup, "One editing/save/undo owner")
            let session = right.rectangleMarkup
            toggle(c); w.layoutIfNeeded()
            XCTAssertEqual(panes(c).count, 1)
            XCTAssertTrue(c.pdfView === right); XCTAssertTrue(c.pdfView.rectangleMarkup === session)
            XCTAssertTrue(c.pdfView.currentPage === doc.page(at: 2))
            toggle(c); XCTAssertEqual(panes(c).count, 2)
        }
    }
    func testReplacementRetiresSecondaryWithoutChangingDocumentOwner() throws {
        try fixture { c, w, doc in
            toggle(c)
            let old = panes(c)
            XCTAssertEqual(old.count, 2)
            guard old.count == 2 else { return }
            w.makeFirstResponder(old[1])
            let replacement = PDFDocument(); replacement.insert(PDFPage(), at: 0)
            c.pdfView.setMarkupDocument(replacement)
            XCTAssertEqual(panes(c).count, 1)
            XCTAssertTrue(c.pdfView.document === replacement)
            XCTAssertNil(old.first { $0 !== c.pdfView }?.document)
            NotificationCenter.default.post(name: .PDFViewPageChanged, object: old.first { $0 !== c.pdfView })
            XCTAssertTrue(c.pdfView.document === replacement)
        }
    }
    func testControlTwoRouterRejectsOtherModifiersAndTextEditing() throws {
        try fixture { c, w, _ in
            @MainActor func event(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
                try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: w.windowNumber, context: nil, characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19))
            }
            w.makeFirstResponder(c.pdfView)
            for flags: NSEvent.ModifierFlags in [[.command], [.control, .shift], [.control, .option], [.control, .command]] {
                let e = try event(flags); XCTAssertTrue(c.routeKeyDownEvent(e) === e)
            }
            XCTAssertNil(c.routeKeyDownEvent(try event([.control, .capsLock])))
            XCTAssertEqual(panes(c).count, 2)
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24)); c.view.addSubview(field)
            w.makeFirstResponder(field)
            let e = try event(.control); XCTAssertTrue(c.routeKeyDownEvent(e) === e)
            XCTAssertEqual(panes(c).count, 2)
        }
    }
    func testIndependentScrollDividerAndActiveZoomRouting() throws {
        try fixture { c, w, _ in
            let left = c.pdfView
            left.autoScales = false; left.scaleFactor = 2
            toggle(c); w.layoutIfNeeded()
            let right = try XCTUnwrap(c.secondaryPDFView)
            print("SPLIT ZOOM source=\(left.scaleFactor) secondary=\(right.scaleFactor) limits=\(right.minScaleFactor)...\(right.maxScaleFactor)")
            XCTAssertEqual(right.scaleFactor, 2, accuracy: 0.001, "Creation must retain the captured zoom")
            let leftClip = try XCTUnwrap(descendants(left).compactMap { $0 as? NSClipView }.first)
            let rightClip = try XCTUnwrap(descendants(right).compactMap { $0 as? NSClipView }.first)
            let beforeRight = rightClip.bounds.origin
            let beforeLeft = leftClip.bounds.origin
            leftClip.scroll(to: NSPoint(x: beforeLeft.x + 40, y: beforeLeft.y + 80))
            XCTAssertNotEqual(leftClip.bounds.origin, beforeLeft)
            XCTAssertEqual(rightClip.bounds.origin, beforeRight)
            w.makeFirstResponder(right)
            c.commandZoomIn(nil)
            XCTAssertEqual(left.scaleFactor, 2, accuracy: 0.001)
            XCTAssertGreaterThan(right.scaleFactor, 2)
            let page = right.currentPage, scale = right.scaleFactor
            c.pdfPaneSplitView.setPosition(420, ofDividerAt: 0)
            XCTAssertTrue(right.currentPage === page)
            XCTAssertEqual(right.scaleFactor, scale, accuracy: 0.001)
            toggle(c); w.layoutIfNeeded()
            XCTAssertTrue(c.pdfView === right)
            XCTAssertEqual(right.scaleFactor, scale, accuracy: 0.001)
        }
    }

    func testRealTabCycleCachesActivePositionAndRetiresSecondary() throws {
        try fixture { c, w, fixtureDocument in
            let a = FileManager.default.temporaryDirectory.appendingPathComponent("Split-A-\(UUID().uuidString).pdf")
            let b = FileManager.default.temporaryDirectory.appendingPathComponent("Split-B-\(UUID().uuidString).pdf")
            defer { [a,b].forEach { try? FileManager.default.removeItem(at: $0) } }
            XCTAssertTrue(fixtureDocument.write(to: a)); XCTAssertTrue(fixtureDocument.write(to: b))
            c.openDocument(at: a)
            let aDocument = try XCTUnwrap(c.pdfView.document)
            toggle(c)
            let right = try XCTUnwrap(c.secondaryPDFView), left = c.pdfView
            w.makeFirstResponder(right)
            right.go(to: try XCTUnwrap(aDocument.page(at: 4)))
            right.autoScales = false; right.scaleFactor = 1.7
            c.openDocument(at: b)
            XCTAssertEqual(panes(c).count, 1); XCTAssertNil(left.document)
            XCTAssertEqual(c.sessionDocumentURLs, [a,b])
            c.commandCycleNextDocument(nil)
            XCTAssertEqual(c.openDocumentURL, a)
            XCTAssertTrue(c.pdfView.document === aDocument)
            XCTAssertTrue(c.pdfView.currentPage === aDocument.page(at: 4))
            XCTAssertEqual(c.pdfView.scaleFactor, 1.7, accuracy: 0.001)
            toggle(c)
            XCTAssertTrue(c.secondaryPDFView?.document === aDocument)
            c.commandCloseDocument(nil)
            XCTAssertEqual(panes(c).count, 1)
            XCTAssertEqual(c.openDocumentURL, b)
        }
    }

    func testSharedMarkupUndoAndSaveFromSecondary() async throws {
        var controller: MainViewController!, window: NSWindow!, originalDocument: PDFDocument!
        try fixture { controller = $0; window = $1; originalDocument = $2 }
        window.contentViewController = controller
        defer { window.makeFirstResponder(nil); window.contentViewController = nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Split-save-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(originalDocument.write(to: url))
        controller.openDocument(at: url)
        let doc = try XCTUnwrap(controller.pdfView.document)
        let left = controller.pdfView
        toggle(controller)
        let right = try XCTUnwrap(controller.secondaryPDFView)
        window.makeFirstResponder(right)
        controller.textDraw(nil)
        let session = right.rectangleMarkup
        XCTAssertEqual(session.tool, .text)
        let page = try XCTUnwrap(doc.page(at: 0))
        _ = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 80, y: 100, width: 180, height: 60), kind: .text, text: "One split document"))
        XCTAssertTrue(window.isDocumentEdited)
        XCTAssertTrue(left.rectangleMarkup === session)
        window.makeFirstResponder(left)
        controller.rectangleUndo(nil)
        XCTAssertTrue(RectangleMarkupRecord.capture(doc).isEmpty)
        window.makeFirstResponder(right)
        controller.rectangleRedo(nil)
        let expected = RectangleMarkupRecord.capture(doc)
        XCTAssertEqual(expected.count, 1)
        let saved = await withCheckedContinuation { continuation in
            controller.persistDocument(to: url, adoptAsPrimaryDocument: false, busyMessage: "Saving PDF…") { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(saved)
        XCTAssertFalse(window.isDocumentEdited)
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(RectangleMarkupRecord.capture(try XCTUnwrap(PDFDocument(url: url))), expected)
        XCTAssertTrue(left.document === doc); XCTAssertTrue(right.document === doc)
    }

    func testActivationRefreshesSelectionForDistinctPageAndZoom() throws {
        try fixture { c, w, doc in
            let left = c.pdfView
            toggle(c); w.layoutIfNeeded()
            let right = try XCTUnwrap(c.secondaryPDFView)
            left.go(to: doc.page(at: 1)!); right.go(to: doc.page(at: 4)!)
            left.autoScales = false; right.autoScales = false
            left.scaleFactor = 0.7; right.scaleFactor = 1.6
            let session = left.rectangleMarkup
            session.canEdit = { true }
            let annotation = try XCTUnwrap(session.create(on: doc.page(at: 1)!, bounds: CGRect(x: 60, y: 80, width: 90, height: 50), kind: .rectangle))
            session.selectFromList(annotation)
            let overlay = try XCTUnwrap(left.layer?.sublayers?.first { $0.name == "drawbridge.activeMarkupSelection" } as? CAShapeLayer)
            XCTAssertFalse(overlay.path?.isEmpty ?? true)
            c.activatePDFPane(right)
            XCTAssertTrue(overlay.superlayer === right.layer)
            XCTAssertTrue(overlay.path?.isEmpty ?? true, "Selection on another page must not retain old pane geometry")
            c.activatePDFPane(left)
            XCTAssertFalse(overlay.path?.isEmpty ?? true)
            XCTAssertEqual(overlay.frame, left.bounds)
        }
    }

    func testInactivePaneCannotAdvanceOrCompleteSharedDraft() throws {
        try fixture { c, w, doc in
            let left = c.pdfView
            toggle(c); w.layoutIfNeeded()
            let right = try XCTUnwrap(c.secondaryPDFView)
            let session = left.rectangleMarkup
            session.canEdit = { true }
            session.tool = .line
            let point = left.convert(CGPoint(x: 200, y: 400), from: doc.page(at: 1)!)
            XCTAssertTrue(session.pointerDown(at: point))
            let overlay = try XCTUnwrap(left.layer?.sublayers?.first { $0.name == "drawbridge.activeMarkupSelection" } as? CAShapeLayer)
            let before = overlay.path?.boundingBox
            for type: NSEvent.EventType in [.mouseMoved, .leftMouseDragged, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: right.convert(CGPoint(x: point.x + 40, y: point.y + 40), to: nil), modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                if type == .mouseMoved { right.mouseMoved(with: event) }
                else if type == .leftMouseDragged { right.mouseDragged(with: event) }
                else { right.mouseUp(with: event) }
                XCTAssertEqual(overlay.path?.boundingBox, before, "Inactive events must not mutate the active draft")
            }
            XCTAssertTrue(RectangleMarkupRecord.capture(doc).isEmpty)
        }
    }

    func testPaneCreationAndActivationInheritAuthoritativeSettings() throws {
        try fixture { c, w, _ in
            c.isGridVisible = true; c.isOrthoSnapEnabled = false
            c.pdfView.setColorInverted(true)
            toggle(c); w.layoutIfNeeded()
            let right = try XCTUnwrap(c.secondaryPDFView)
            func value(_ key: String) -> Bool? { Mirror(reflecting: right).children.first { $0.label == key }?.value as? Bool }
            XCTAssertEqual(value("isGridVisible"), true)
            XCTAssertEqual(value("isOrthoSnapEnabled"), false)
            XCTAssertTrue(right.isColorInverted)
            c.isGridVisible = false; c.isOrthoSnapEnabled = true
            c.activatePDFPane(right)
            XCTAssertEqual(value("isGridVisible"), false)
            XCTAssertEqual(value("isOrthoSnapEnabled"), true)
        }
    }

    func testWheelActivationTransfersKeyboardFocusToHoveredPane() throws {
        try fixture { c, w, doc in
            let left = c.pdfView
            toggle(c); w.layoutIfNeeded()
            let right = try XCTUnwrap(c.secondaryPDFView)
            XCTAssertTrue(w.makeFirstResponder(left))
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0))
            let location = right.convert(NSPoint(x: right.bounds.midX, y: right.bounds.midY), to: nil)
            cg.location = CGPoint(x: location.x, y: try XCTUnwrap(NSScreen.screens.first).frame.maxY - location.y)
            let wheel = try XCTUnwrap(NSEvent(cgEvent: cg))
            XCTAssertEqual(wheel.locationInWindow.x, location.x, accuracy: 0.01)
            XCTAssertEqual(wheel.locationInWindow.y, location.y, accuracy: 0.01)
            XCTAssertNil(c.routeScrollWheelEvent(wheel))
            XCTAssertTrue(c.pdfView === right)
            XCTAssertTrue(w.firstResponder === right, "Wheel activation must transfer keyboard focus")
            let before = left.currentPage
            c.commandNextPage(nil)
            XCTAssertTrue(c.pdfView === right, "Command focus resolution must not reactivate the old pane")
            XCTAssertTrue(left.currentPage === before)
            XCTAssertTrue(right.currentPage === doc.page(at: 2))
        }
    }

    func testRetiredPanePendingTilesCannotMutateSurvivingSharedPage() throws {
        try fixture { c, w, doc in
            let left = c.pdfView
            toggle(c); w.layoutIfNeeded()
            let retired = try XCTUnwrap(c.secondaryPDFView)
            let page = try XCTUnwrap(doc.page(at: 1))
            let bytes = try XCTUnwrap(doc.dataRepresentation())
            let fragment = try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: bytes as CFData))))
            let snapshot = DrawbridgeSnapshotAnnotation(bounds: CGRect(x: 0, y: 0, width: 600, height: 800), document: fragment, rotation: 0, style: SnapshotStyle())
            page.addAnnotation(snapshot)
            retired.autoScales = false; retired.scaleFactor = 10
            retired.snapshotViewportTilesEnabled = true
            retired.updateSnapshotViewportTiles()
            XCTAssertFalse(page.annotations.compactMap { $0 as? SnapshotViewportTileAnnotation }.isEmpty)
            NotificationCenter.default.post(name: .PDFViewScaleChanged, object: retired)
            let pending = try XCTUnwrap(Mirror(reflecting: retired).children.first { $0.label == "snapshotTilesWorkItem" }?.value as? DispatchWorkItem)
            XCTAssertFalse(pending.isCancelled, "Fixture must capture genuinely queued work")
            toggle(c); w.layoutIfNeeded()
            XCTAssertNil(retired.document)
            let pendingAfterRetirement = Mirror(reflecting: retired).children.first { $0.label == "snapshotTilesWorkItem" }?.value as? DispatchWorkItem
            XCTAssertNil(pendingAfterRetirement)
            left.autoScales = false; left.scaleFactor = 10
            left.updateSnapshotViewportTiles()
            let tiles = page.annotations.compactMap { $0 as? SnapshotViewportTileAnnotation }
            XCTAssertFalse(tiles.isEmpty, "Surviving pane must have real tiles")
            let identities = tiles.map(ObjectIdentifier.init)
            XCTAssertTrue(pending.isCancelled, "Retirement must cancel already queued tile work")
            pending.perform()
            pendingAfterRetirement?.perform()
            XCTAssertEqual(page.annotations.compactMap { $0 as? SnapshotViewportTileAnnotation }.map(ObjectIdentifier.init), identities, "Queued retired work must not remove surviving tiles")
            XCTAssertTrue(tiles.allSatisfy(\.shouldDisplay), "Queued retired work must not hide surviving tiles")
            XCTAssertTrue(snapshot.usesViewportTiles)
            retired.updateSnapshotViewportTiles()
            XCTAssertEqual(page.annotations.compactMap { $0 as? SnapshotViewportTileAnnotation }.map(ObjectIdentifier.init), identities)
            XCTAssertTrue(tiles.allSatisfy(\.shouldDisplay))
            XCTAssertTrue(snapshot.usesViewportTiles)
        }
    }

    func testNoDocumentToggleIsSafe() throws {
        try fixture { c, _, _ in
            c.pdfView.setMarkupDocument(nil); toggle(c)
            XCTAssertEqual(panes(c).count, 1); XCTAssertNil(c.pdfView.document)
        }
    }
}
