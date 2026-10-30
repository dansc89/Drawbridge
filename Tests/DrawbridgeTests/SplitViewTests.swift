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
    private func fixture(presentDocument: Bool = false, _ body: (MainViewController, NSWindow, PDFDocument) throws -> Void) throws {
        _ = NSApplication.shared
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let ctx = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        for _ in 0..<6 { ctx.beginPDFPage(nil); ctx.endPDFPage() }; ctx.closePDF()
        var doc = try XCTUnwrap(PDFDocument(data: data as Data))
        let c = MainViewController()
        let w = SplitTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentViewController = c
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("split-gesture-\(UUID().uuidString).pdf")
        defer { if presentDocument { try? FileManager.default.removeItem(at: url) } }
        if presentDocument {
            // Pointer routing needs the controller's presentation lifecycle, not
            // just a PDFKit document assignment beneath the hidden empty state.
            try (data as Data).write(to: url)
            c.openDocument(at: url)
            doc = try XCTUnwrap(c.pdfView.document)
        } else {
            c.pdfView.setMarkupDocument(doc)
        }
        c.pdfView.go(to: doc.page(at: 1)!)
        w.layoutIfNeeded()
        defer { w.makeFirstResponder(nil); w.contentViewController = nil }
        try body(c, w, doc)
    }
    func testPaneCloseButtonsKeepOtherViewportAndSharedEdits() throws {
        for closeActive in [false, true] {
            try fixture { c, w, doc in
                toggle(c);w.layoutIfNeeded()
                let original=c.pdfView,peer=try XCTUnwrap(c.secondaryPDFView)
                peer.go(to:try XCTUnwrap(peer.document?.page(at:4)));peer.scaleFactor=1.7
                original.go(to:try XCTUnwrap(doc.page(at:2)));original.scaleFactor=1.3
                original.rectangleMarkup.canEdit={true}
                let mark=try XCTUnwrap(original.rectangleMarkup.create(on:try XCTUnwrap(doc.page(at:2)),bounds:CGRect(x:50,y:50,width:60,height:60),kind:.rectangle))
                let closed=closeActive ? original : peer,kept=closeActive ? peer : original
                let index=try XCTUnwrap(kept.currentPage.flatMap {kept.document?.index(for:$0)})
                let scale=kept.scaleFactor
                let container=try XCTUnwrap(closed.superview as? PDFPaneContainerView)
                XCTAssertFalse(container.header.isHidden);XCTAssertNotNil(container.closeButton.action)
                container.closeButton.performClick(nil);w.layoutIfNeeded()
                XCTAssertNil(c.secondaryPDFView);XCTAssertTrue(c.pdfView === kept)
                XCTAssertTrue(kept.document === doc)
                XCTAssertEqual(kept.currentPage.flatMap {kept.document?.index(for:$0)},index)
                XCTAssertEqual(kept.scaleFactor,scale,accuracy:0.01)
                XCTAssertTrue(doc.page(at:2)?.annotations.contains {$0 === mark} == true)
                XCTAssertTrue((kept.superview as? PDFPaneContainerView)?.header.isHidden == true)
                XCTAssertNil(closed.document)
            }
        }
    }

    func testDeletionRemapsDetachedPeerBySheetIdentityAcrossUndoRedo() throws {
        for displayedIndex in [3, 5] {
            for deleteDisplayed in [false, true] {
                for activateBeforeUndo in [false, true] {
                    try fixture { c, w, doc in
                        let source = FileManager.default.temporaryDirectory.appendingPathComponent("split-delete-\(UUID().uuidString).pdf")
                        XCTAssertTrue(doc.write(to: source))
                        defer { try? FileManager.default.removeItem(at: source) }
                        c.pdfView.rectangleMarkup.rememberSource(source)
                        let originals = try (0..<6).map { try XCTUnwrap(doc.page(at: $0)) }
                        // Distinct sheet metadata proves detached content, not only its index.
                        for (index, page) in originals.enumerated() {
                            let marker = PDFAnnotation(bounds: CGRect(x: 200, y: 300, width: 100, height: 100), forType: .square, withProperties: nil)
                            marker.contents = "sheet-\(index)"; page.addAnnotation(marker)
                        }
                        c.pdfView.go(to: originals[displayedIndex]); toggle(c); w.layoutIfNeeded()
                        let peer = try XCTUnwrap(c.secondaryPDFView)
                        c.pdfView.go(to: originals[0])
                        let undo = try XCTUnwrap(w.undoManager)
                        undo.removeAllActions(); undo.beginUndoGrouping()
                        let deletedIndex = deleteDisplayed ? displayedIndex : 1
                        try c.deletePages(at: IndexSet(integer: deletedIndex))
                        undo.endUndoGrouping()
                        let expected = deleteDisplayed ? originals[min(displayedIndex + 1, 5) == displayedIndex ? displayedIndex - 1 : displayedIndex + 1] : originals[displayedIndex]
                        XCTAssertEqual(peer.document?.pageCount, 5)
                        XCTAssertEqual(peer.currentPage?.annotations.first { $0.contents?.hasPrefix("sheet-") == true }?.contents,
                                       expected.annotations.first?.contents)
                        XCTAssertEqual(peer.document?.index(for: try XCTUnwrap(peer.currentPage)), doc.index(for: expected))
                        if activateBeforeUndo {
                            c.activatePDFPane(peer)
                            XCTAssertTrue(peer.currentPage === expected)
                        }
                        undo.undo()
                        XCTAssertEqual(doc.pageCount, 6)
                        if !activateBeforeUndo {
                            XCTAssertEqual(peer.document?.pageCount, 6)
                            c.activatePDFPane(peer)
                            XCTAssertTrue(peer.currentPage === expected)
                        }
                        undo.redo()
                        XCTAssertEqual(doc.pageCount, 5)
                        let inactive = try XCTUnwrap(c.secondaryPDFView)
                        XCTAssertEqual(inactive.document?.pageCount, 5)
                        c.activatePDFPane(inactive)
                        XCTAssertTrue(inactive.document === doc)
                        XCTAssertNotNil(originals.first { $0 === inactive.currentPage })
                        undo.undo()
                        XCTAssertEqual(doc.pageCount, 6)
                        XCTAssertEqual(c.secondaryPDFView?.document?.pageCount, 6)
                        XCTAssertFalse(w.isVisible)
                    }
                }
            }
        }
    }

    func testSameDocumentIndependentNavigationZoomAndCollapseRetainsActiveView() throws {
        try fixture { c, w, doc in
            let left = c.pdfView
            toggle(c); w.layoutIfNeeded()
            let views = panes(c)
            XCTAssertEqual(views.count, 2, "Toggle must create a second real PDF pane")
            guard views.count == 2 else { return }
            let right = try XCTUnwrap(views.first { $0 !== left })
            XCTAssertFalse(right.document === doc); XCTAssertTrue(left.document === doc)
            XCTAssertEqual(right.document?.index(for: right.currentPage!), doc.index(for: left.currentPage!))
            XCTAssertFalse(right.currentPage === left.currentPage)
            left.autoScales = false; right.autoScales = false
            left.scaleFactor = 0.7; right.scaleFactor = 1.3
            XCTAssertTrue(w.makeFirstResponder(right))
            c.commandNextPage(nil)
            XCTAssertTrue(c.pdfView === right)
            XCTAssertTrue(right.currentPage === doc.page(at: 2))
            XCTAssertEqual(left.document?.index(for: left.currentPage!), 1)
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

    func testRealTabCycleCachesActivePositionAndPreservesSecondary() throws {
        try fixture { c, w, fixtureDocument in
            let a = FileManager.default.temporaryDirectory.appendingPathComponent("Split-A-\(UUID().uuidString).pdf")
            let b = FileManager.default.temporaryDirectory.appendingPathComponent("Split-B-\(UUID().uuidString).pdf")
            defer { [a,b].forEach { try? FileManager.default.removeItem(at: $0) } }
            XCTAssertTrue(fixtureDocument.write(to: a)); XCTAssertTrue(fixtureDocument.write(to: b))
            c.openDocument(at: a)
            let aDocument = try XCTUnwrap(c.pdfView.document)
            // A now remains visible in the original pane when B replaces the
            // focused pane. Seed its viewport before splitting so cycling back
            // must preserve the same strict page/zoom expectations.
            c.pdfView.go(to: try XCTUnwrap(aDocument.page(at: 4)))
            c.pdfView.autoScales = false; c.pdfView.scaleFactor = 1.7
            toggle(c)
            let right = try XCTUnwrap(c.secondaryPDFView), left = c.pdfView
            w.makeFirstResponder(right)
            right.go(to: try XCTUnwrap(aDocument.page(at: 4)))
            right.autoScales = false; right.scaleFactor = 1.7
            c.openDocument(at: b)
            XCTAssertEqual(panes(c).count, 2)
            XCTAssertTrue(left.document === aDocument)
            XCTAssertFalse(left.rectangleMarkup === right.rectangleMarkup)
            let bDocument = try XCTUnwrap(right.document)
            XCTAssertEqual(c.sessionDocumentURLs, [a,b])
            c.commandCycleNextDocument(nil)
            XCTAssertEqual(c.openDocumentURL, a)
            XCTAssertTrue(c.pdfView.document === aDocument)
            XCTAssertTrue(c.pdfView.currentPage === aDocument.page(at: 4))
            XCTAssertEqual(c.pdfView.scaleFactor, 1.7, accuracy: 0.001)
            XCTAssertEqual(panes(c).count, 2)
            XCTAssertTrue(c.pdfView === left)
            XCTAssertTrue(c.secondaryPDFView === right)
            XCTAssertTrue(c.secondaryPDFView?.document === bDocument)
            XCTAssertFalse(c.secondaryPDFView?.document === aDocument)
            XCTAssertEqual(c.secondaryPDFView?.document?.pageCount, aDocument.pageCount)
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
        XCTAssertFalse(left.document === doc); XCTAssertTrue(right.document === doc)
    }

    func testActivationRefreshesSelectionForDistinctPageAndZoom() throws {
        try fixture { c, w, doc in
            let left = c.pdfView
            toggle(c); w.layoutIfNeeded()
            let right = try XCTUnwrap(c.secondaryPDFView)
            left.go(to: doc.page(at: 1)!); right.go(to: right.document!.page(at: 4)!)
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
            let before = left.document?.index(for: left.currentPage!)
            c.commandNextPage(nil)
            XCTAssertTrue(c.pdfView === right, "Command focus resolution must not reactivate the old pane")
            XCTAssertEqual(left.document?.index(for: left.currentPage!), before)
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
            c.activatePDFPane(retired)
            retired.autoScales = false; retired.scaleFactor = 10
            retired.snapshotViewportTilesEnabled = true
            retired.updateSnapshotViewportTiles()
            XCTAssertFalse(page.annotations.compactMap { $0 as? SnapshotViewportTileAnnotation }.isEmpty)
            NotificationCenter.default.post(name: .PDFViewScaleChanged, object: retired)
            let pending = try XCTUnwrap(Mirror(reflecting: retired).children.first { $0.label == "snapshotTilesWorkItem" }?.value as? DispatchWorkItem)
            XCTAssertFalse(pending.isCancelled, "Fixture must capture genuinely queued work")
            c.activatePDFPane(left)
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

    func testSplitHeadersIdentifyDocumentActiveSideAndReserveCanvasSpace() throws {
        try fixture { c, w, _ in
            let containers = { c.pdfPaneSplitView.arrangedSubviews.compactMap { $0 as? PDFPaneContainerView } }
            XCTAssertTrue(try XCTUnwrap(containers().first).header.isHidden)
            toggle(c); w.layoutIfNeeded()
            let split = containers()
            XCTAssertEqual(split.count, 2)
            guard split.count == 2 else { return }
            XCTAssertEqual(c.pdfPaneSplitView.dividerThickness, 10)
            XCTAssertEqual(split[0].modeLabel.stringValue, "Split view · Left · Active")
            XCTAssertEqual(split[1].modeLabel.stringValue, "Split view · Right")
            for container in split {
                XCTAssertFalse(container.header.isHidden)
                XCTAssertEqual(container.header.frame.height, 30, accuracy: 0.1)
                XCTAssertEqual(container.pdfView.frame.height + 30, container.bounds.height, accuracy: 0.1)
                XCTAssertFalse(container.header.frame.intersects(container.pdfView.frame))
                XCTAssertEqual(container.titleLabel.stringValue, "PDF")
                XCTAssertTrue(container.header.toolTip?.contains("same PDF") == true)
            }
            c.activatePDFPane(split[1].pdfView)
            XCTAssertEqual(split[0].modeLabel.stringValue, "Split view · Left")
            XCTAssertEqual(split[1].modeLabel.stringValue, "Split view · Right · Active")
            c.pdfPaneSplitView.setPosition(420, ofDividerAt: 0); w.layoutIfNeeded()
            XCTAssertEqual(split[1].modeLabel.stringValue, "Split view · Right · Active")
            toggle(c); w.layoutIfNeeded()
            let remaining = try XCTUnwrap(containers().first)
            XCTAssertTrue(remaining.pdfView === split[1].pdfView)
            XCTAssertTrue(remaining.header.isHidden)
            XCTAssertEqual(remaining.pdfView.frame.height, remaining.bounds.height, accuracy: 0.1)
        }
    }
    func testSplitPresentationUpdatesWithoutSharingLiveAnnotationInstances() throws {
        try fixture { c, w, doc in
            toggle(c); w.layoutIfNeeded()
            let session = c.pdfView.rectangleMarkup
            session.canEdit = { true }
            let page = try XCTUnwrap(c.pdfView.currentPage)
            let peer = try XCTUnwrap(c.secondaryPDFView)
            let annotation = try XCTUnwrap(session.create(on: page,
                bounds: CGRect(x: 100, y: 100, width: 100, height: 80), kind: .rectangle))
            let generation = try XCTUnwrap(peer.document)
            let displayed = try XCTUnwrap(peer.currentPage?.annotations.first)
            XCTAssertFalse(displayed === annotation)
            XCTAssertTrue(displayed is DrawbridgeShapeAnnotation)
            XCTAssertEqual(displayed.bounds, annotation.bounds)
            XCTAssertEqual(RectangleMarkupRecord.capture(annotation: displayed, pageIndex: 1),
                           RectangleMarkupRecord.capture(annotation: annotation, pageIndex: 1))
            session.selectFromList(annotation)
            session.fillSelected(.blue)
            session.setLineAppearance(pattern: .dashDot, opacity: 0.5)
            session.setBounds(CGRect(x: 250, y: 200, width: 120, height: 90), of: annotation, on: page, action: "Move")
            let moved = try XCTUnwrap(peer.currentPage?.annotations.first)
            XCTAssertEqual(moved.bounds, annotation.bounds)
            XCTAssertEqual(RectangleMarkupRecord.capture(annotation: moved, pageIndex: 1),
                           RectangleMarkupRecord.capture(annotation: annotation, pageIndex: 1))
            XCTAssertEqual(displayed.bounds, CGRect(x: 100, y: 100, width: 100, height: 80))
            session.undo.removeAllActions()
            session.deleteSelected()
            XCTAssertTrue(peer.currentPage?.annotations.isEmpty == true)
            XCTAssertEqual(generation.page(at: 1)?.annotations.count, 1,
                           "An already submitted rendering generation must stay immutable")
            c.rectangleUndo(nil)
            XCTAssertEqual(peer.currentPage?.annotations.count, 1)
            XCTAssertEqual(doc.page(at: 1)?.annotations.count, 1)
            c.activatePDFPane(peer)
            XCTAssertTrue(peer.document === doc)
            XCTAssertTrue(peer.currentPage?.annotations.first === annotation)
        }
    }

    func testFirstPenGestureInInactivePaneCreatesCanonicalMarkup() throws {
        try fixture(presentDocument: true) { c, w, doc in
            toggle(c); w.layoutIfNeeded()
            let peer = try XCTUnwrap(c.secondaryPDFView)
            let session = c.pdfView.rectangleMarkup
            session.canEdit = { true }; session.tool = .pen
            let page = try XCTUnwrap(peer.currentPage)
            let start = peer.convert(CGPoint(x: 250, y: 300), from: page)
            let end = peer.convert(CGPoint(x: 320, y: 370), from: page)
            XCTAssertFalse(c.pdfPaneSplitView.isHidden, "A pointer gesture requires a presented split container")
            XCTAssertFalse(peer.isHiddenOrHasHiddenAncestor, "The inactive canvas must be eligible for AppKit hit testing")
            XCTAssertTrue(peer.hitTest(peer.convert(start, to: peer.superview)) === peer,
                          "The first drag must target the stable canvas, not a PDFKit descendant retired during activation")
            for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
                    location: peer.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                if type == .leftMouseDown { peer.mouseDown(with: event) }
                else if type == .leftMouseDragged { peer.mouseDragged(with: event) }
                else { peer.mouseUp(with: event) }
            }
            XCTAssertTrue(c.pdfView === peer)
            XCTAssertEqual(doc.page(at: 1)?.annotations.count, 1)
            XCTAssertEqual(c.secondaryPDFView?.currentPage?.annotations.count, 1)
        }
    }

    func testSnapshotPresentationRetainsRenderedCaptureAndEffects() throws {
        try fixture { c, w, _ in
            let bytes = NSMutableData()
            var media = CGRect(x: 0, y: 0, width: 100, height: 100)
            let writer = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: bytes)), mediaBox: &media, nil))
            writer.beginPDFPage(nil)
            writer.setFillColor(NSColor.black.cgColor)
            writer.fill(CGRect(x: 10, y: 10, width: 80, height: 80))
            writer.endPDFPage(); writer.closePDF()
            let source = try XCTUnwrap(PDFDocument(data: bytes as Data))
            var payload = try SnapshotPayload.capture(page: XCTUnwrap(source.page(at: 0)),
                points: [CGPoint(x: 0,y: 0), CGPoint(x: 100,y: 0), CGPoint(x: 100,y: 100), CGPoint(x: 0,y: 100)])
            payload.style = SnapshotStyle(overlay: true, opacity: 0.5, filter: .colorize, color: [1, 0, 0])
            let session = c.pdfView.rectangleMarkup
            session.canEdit = { true }
            let original = try XCTUnwrap(session.pasteSnapshot(payload, on: XCTUnwrap(c.pdfView.currentPage), center: CGPoint(x: 200,y: 200)))
            toggle(c); w.layoutIfNeeded()
            let copy = try XCTUnwrap(c.secondaryPDFView?.currentPage?.annotations.first as? DrawbridgeSnapshotAnnotation)
            XCTAssertFalse(copy === original)
            func raster(_ stamp: PDFAnnotation) throws -> Data {
                let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 800, bitsPerComponent: 8,
                    bytesPerRow: 2400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0,y: 0,width: 600,height: 800))
                stamp.draw(with: .cropBox, in: context)
                return Data(bytes: try XCTUnwrap(context.data), count: 2400 * 800)
            }
            let expected = try raster(original)
            XCTAssertTrue(expected.contains { $0 < 240 }, "Fixture must contain actual captured linework")
            XCTAssertEqual(try raster(copy), expected, "A copied Stamp must retain its capture renderer, not an empty decoded subclass")
            session.selectFromList(original); session.deleteSelected()
            XCTAssertTrue(c.secondaryPDFView?.currentPage?.annotations.isEmpty == true)
            XCTAssertEqual(try raster(copy), expected, "A retired display generation must not lose its immutable capture")
        }
    }

    func testSplitCreationActivationAndMarkupRefreshPreserveVisiblePageCenter() throws {
        try fixture { c, w, doc in
            let left = c.pdfView
            left.autoScales = false; left.scaleFactor = 2
            left.centerViewport(on: CGPoint(x: 300, y: 400))
            let before = try XCTUnwrap(left.captureTabViewState())
            toggle(c); w.layoutIfNeeded()
            let right = try XCTUnwrap(c.secondaryPDFView)
            @MainActor func center(_ pane: MarkupPDFView) throws -> CGPoint { try XCTUnwrap(pane.captureTabViewState()).viewportCenter }
            for pane in [left, right] {
                XCTAssertEqual(try center(pane).x, before.viewportCenter.x, accuracy: 1)
                XCTAssertEqual(try center(pane).y, before.viewportCenter.y, accuracy: 1)
            }
            let rightBefore = try center(right)
            c.activatePDFPane(right)
            XCTAssertEqual(try center(right).x, rightBefore.x, accuracy: 1)
            XCTAssertEqual(try center(right).y, rightBefore.y, accuracy: 1)
            let leftBefore = try center(left)
            let session = right.rectangleMarkup; session.canEdit = { true }
            _ = try XCTUnwrap(session.create(on: XCTUnwrap(doc.page(at:1)),bounds:CGRect(x:250,y:350,width:100,height:80),kind:.rectangle))
            XCTAssertEqual(try center(left).x, leftBefore.x, accuracy: 1)
            XCTAssertEqual(try center(left).y, leftBefore.y, accuracy: 1)
            XCTAssertEqual(left.scaleFactor, 2, accuracy: 0.001)
        }
    }

}
