import AppKit
import XCTest
@testable import Drawbridge

@MainActor final class MarkupToolCursorTests: XCTestCase {
    func testMatchPropertiesHasDistinctBrushAndEscAndToolChangesRetireIt() throws {
        _ = NSApplication.shared
        let view = MarkupPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        let session = view.rectangleMarkup
        session.canEdit = { true }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        defer { NSCursor.arrow.set() }
        session.tool = .pen
        view.cursorUpdate(with: event)
        let pen = NSCursor.current
        XCTAssertTrue(pen === MarkupPDFView.penCursor)
        session.tool = .highlight
        view.cursorUpdate(with: event)
        XCTAssertTrue(NSCursor.current === pen)
        session.beginMatchProperties() // no source: still visibly in capture mode
        NSCursor.arrow.set(); view.cursorUpdate(with: event)
        let brush = NSCursor.current
        XCTAssertFalse(brush === NSCursor.arrow, "Match Properties must show an explicit paintbrush, not Select")
        XCTAssertFalse(brush === pen, "Paintbrush must be distinct from the drawing pen")
        XCTAssertTrue(session.matchPropertiesActive)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        XCTAssertFalse(session.matchPropertiesActive)
        XCTAssertEqual(session.tool, .select)
        NSCursor.arrow.set(); view.cursorUpdate(with: event)
        XCTAssertFalse(NSCursor.current === brush)
        session.beginMatchProperties(); session.tool = .pen
        view.cursorUpdate(with: event)
        XCTAssertFalse(session.matchPropertiesActive)
        XCTAssertTrue(NSCursor.current === pen)
        session.beginMatchProperties(); session.cancelGesture()
        XCTAssertFalse(session.matchPropertiesActive)
        NSCursor.arrow.set(); view.cursorUpdate(with: event)
        XCTAssertFalse(NSCursor.current === brush)
    }

    func testRegionCaptureKeepsCrosshairInsteadOfMarkupCursor() throws {
        _ = NSApplication.shared
        let view = MarkupPDFView()
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        view.rectangleMarkup.beginMatchProperties()
        view.beginRegionCaptureMode()
        defer { view.cancelRegionCaptureMode(); NSCursor.arrow.set() }
        view.cursorUpdate(with: event)
        XCTAssertTrue(NSCursor.current === NSCursor.crosshair)
    }
}
