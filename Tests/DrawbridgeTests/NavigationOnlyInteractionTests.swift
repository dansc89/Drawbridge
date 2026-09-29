import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class NavigationOnlyInteractionTests: XCTestCase {
    func testAllLegacyToolsAndEditingGesturesLeaveAnnotationsAndRotationUntouched() throws {
        let (window, view, page) = try makeView(rotation: 270)
        let note = PDFAnnotation(bounds: NSRect(x: 180, y: 180, width: 150, height: 70), forType: .freeText, withProperties: nil)
        note.contents = "Keep this annotation"
        note.font = NSFont(name: "Times-Roman", size: 17)
        note.color = .red
        note.isReadOnly = true
        page.addAnnotation(note)
        let originalBounds = note.bounds
        let originalFlags = note.value(forAnnotationKey: .flags) as? NSNumber
        let originalFont = note.font
        let point = NSPoint(x: note.bounds.midX, y: note.bounds.midY)
        for mode in ToolMode.allCases {
            view.toolMode = mode
            XCTAssertEqual(view.toolMode, .select, "Stale mode \(mode) must not reactivate markup")
            view.mouseDown(with: try mouse(.leftMouseDown, pagePoint: point, page: page, view: view, window: window))
            view.mouseDragged(with: try mouse(.leftMouseDragged, pagePoint: NSPoint(x: point.x + 40, y: point.y + 50), page: page, view: view, window: window))
            view.mouseUp(with: try mouse(.leftMouseUp, pagePoint: point, page: page, view: view, window: window))
        }
        view.mouseDown(with: try mouse(.leftMouseDown, pagePoint: point, page: page, view: view, window: window, clicks: 2))
        for key: UInt16 in [51, 117, 48, 36] { // Delete, forward delete, Tab, Return.
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
            view.keyDown(with: event)
        }
        view.addHighlightForCurrentSelection()
        view.addUnderlineForCurrentSelection()
        view.addStrikethroughForCurrentSelection()
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertTrue(page.annotations.first === note)
        XCTAssertEqual(note.bounds, originalBounds)
        XCTAssertEqual(note.contents, "Keep this annotation")
        XCTAssertEqual(note.font, originalFont)
        XCTAssertEqual(note.color, .red)
        XCTAssertTrue(note.isReadOnly)
        XCTAssertEqual(note.value(forAnnotationKey: .flags) as? NSNumber, originalFlags)
        XCTAssertEqual(page.rotation, 270)
        let menu = view.menu(for: try mouse(.rightMouseDown, pagePoint: point, page: page, view: view, window: window))
        XCTAssertEqual(menu?.items.map(\.title), ["Copy Text", "Select All Text"])
    }

    func testRegionCaptureAndLinkNavigationStillWorkWithoutCreatingMarkup() throws {
        let (window, view, page) = try makeView(rotation: 90)
        var captured: NSRect?
        view.onRegionCaptured = { capturedPage, rect in
            XCTAssertTrue(capturedPage === page)
            captured = rect
        }
        view.beginRegionCaptureMode()
        let start = NSPoint(x: 160, y: 160)
        let end = NSPoint(x: 300, y: 260)
        view.mouseDown(with: try mouse(.leftMouseDown, pagePoint: start, page: page, view: view, window: window))
        view.mouseDragged(with: try mouse(.leftMouseDragged, pagePoint: end, page: page, view: view, window: window))
        view.mouseUp(with: try mouse(.leftMouseUp, pagePoint: end, page: page, view: view, window: window))
        let region = try XCTUnwrap(captured)
        XCTAssertEqual(region.origin.x, 160, accuracy: 0.1)
        XCTAssertEqual(region.origin.y, 160, accuracy: 0.1)
        XCTAssertEqual(region.width, 140, accuracy: 0.1)
        XCTAssertEqual(region.height, 100, accuracy: 0.1)
        XCTAssertTrue(page.annotations.isEmpty)

        let second = try makePage()
        view.document?.insert(second, at: 1)
        let link = PDFAnnotation(bounds: NSRect(x: 160, y: 160, width: 100, height: 60), forType: .link, withProperties: nil)
        link.destination = PDFDestination(page: second, at: .zero)
        link.contents = "DrawbridgeAutoSheetLink:1"
        page.addAnnotation(link)
        view.mouseDown(with: try mouse(.leftMouseDown, pagePoint: NSPoint(x: 200, y: 190), page: page, view: view, window: window))
        XCTAssertTrue(view.currentPage === second)
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertEqual(page.rotation, 90)
    }

    func testLegacyControllerCommandsCannotEditOrPasteAnnotations() throws {
        let controller = MainViewController()
        _ = controller.view
        let doc = PDFDocument()
        let page = try makePage()
        let note = PDFAnnotation(bounds: NSRect(x: 50, y: 50, width: 80, height: 40), forType: .freeText, withProperties: nil)
        note.contents = "Existing"
        page.addAnnotation(note)
        doc.insert(page, at: 0)
        controller.pdfView.document = doc
        controller.lastDirectlySelectedAnnotation = note
        controller.commandDeleteMarkup(nil)
        controller.commandEditMarkup(nil)
        controller.commandPaste(nil)
        controller.pasteGrabSnapshotInPlace()
        controller.pasteCopiedMarkupsFromPasteboard()
        controller.applySelectedMarkupsToPages()
        controller.commandHighlight(nil)
        controller.commandBringMarkupToFront(nil)
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertTrue(page.annotations.first === note)
        XCTAssertEqual(note.contents, "Existing")
        for action in [#selector(MainViewController.commandDeleteMarkup(_:)), #selector(MainViewController.commandPaste(_:)), #selector(MainViewController.selectPenTool(_:)), #selector(MainViewController.commandFlattenPDF(_:))] {
            XCTAssertFalse(controller.validateMenuItem(NSMenuItem(title: "Legacy action", action: action, keyEquivalent: "")))
        }
        XCTAssertEqual(controller.toolbarDefaultItemIdentifiers(NSToolbar()), [.drawbridgePrimaryControls, .flexibleSpace])
    }

    private func makePage() throws -> PDFPage {
        let image = NSImage(size: NSSize(width: 640, height: 480))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        return try XCTUnwrap(PDFPage(image: image))
    }

    private func makeView(rotation: Int) throws -> (NSWindow, MarkupPDFView, PDFPage) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let view = MarkupPDFView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        let page = try makePage()
        page.rotation = rotation
        page.setBounds(NSRect(x: 40, y: 30, width: 540, height: 410), for: .cropBox)
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        view.document = doc
        view.autoScales = true
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        return (window, view, page)
    }

    private func mouse(_ type: NSEvent.EventType, pagePoint: NSPoint, page: PDFPage, view: MarkupPDFView, window: NSWindow, clicks: Int = 1) throws -> NSEvent {
        let point = view.convert(view.convert(pagePoint, from: page), to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }
}
