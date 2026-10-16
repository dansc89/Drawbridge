import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

/// Constructed NSEvents delivered to the real native view handlers in never-ordered
/// windows. These regressions do NOT qualify physical OS Control-click delivery.
@MainActor
final class MeasurementEventRoutingTests: XCTestCase {
    private let start = CGPoint(x: 100, y: 100)
    private let second = CGPoint(x: 190, y: 170)

    private func withCanvas(rotation: Int = 0, _ body: (NSWindow, MarkupPDFView, PDFPage) throws -> Void) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1000),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = MarkupPDFView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        page.rotation = rotation
        document.insert(page, at: 0)
        view.setMarkupDocument(document)
        view.displayMode = .singlePage
        view.autoScales = true
        view.go(to: page)
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(view.ownsMarkupInteraction)
        view.rectangleMarkup.applyDrawingScale(try XCTUnwrap(DrawingScale.architectural(inches: 0.125, name: "1/8\" = 1'")), to: [page])
        view.rectangleMarkup.tool = .perimeter
        view.rectangleMarkup.undo.removeAllActions()
        view.rectangleMarkup.undo.groupsByEvent = false
        let nonMeasurements = page.annotations.filter { MeasurementMetadata.measurement($0) == nil }
        try body(window, view, page)
        XCTAssertEqual(page.annotations.filter { MeasurementMetadata.measurement($0) == nil }.map(ObjectIdentifier.init),
                       nonMeasurements.map(ObjectIdentifier.init), "Gestures must preserve scale markers and add no unrelated annotations")
    }

    private func measurements(on page: PDFPage) -> [PDFAnnotation] {
        page.annotations.filter { MeasurementMetadata.measurement($0) != nil }
    }

    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, _ flags: NSEvent.ModifierFlags = [],
                       clicks: Int = 1, commits: Bool = false, window: NSWindow, view: MarkupPDFView, page: PDFPage) throws {
        let location = view.convert(point, from: page)
        XCTAssertTrue(view.page(for: location, nearest: false) === page)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(location, to: nil),
            modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clicks, pressure: 1))
        switch type {
        case .leftMouseDown:
            // Direct dispatch bypasses AppKit event transactions. Group expected commits
            // only: NSUndoManager retains even empty explicit groups as undo actions.
            // Unexpected draft registration must fail rather than be silently discarded.
            let undo = view.rectangleMarkup.undo
            if commits { undo.beginUndoGrouping() }
            view.mouseDown(with: event)
            if commits { undo.endUndoGrouping() }
        case .leftMouseUp: view.mouseUp(with: event)
        case .mouseMoved: view.mouseMoved(with: event)
        default: XCTFail("Unsupported fixture event")
        }
    }

    private func click(_ point: CGPoint, _ flags: NSEvent.ModifierFlags = [], clicks: Int = 1, commits: Bool = false,
                       window: NSWindow, view: MarkupPDFView, page: PDFPage) throws {
        try mouse(.leftMouseDown, point, flags, clicks: clicks, commits: commits, window: window, view: view, page: page)
        try mouse(.leftMouseUp, point, flags, clicks: clicks, window: window, view: view, page: page)
    }

    private func key(_ code: UInt16, view: MarkupPDFView, window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: code == 53 ? "\u{1b}" : "\r", charactersIgnoringModifiers: code == 53 ? "\u{1b}" : "\r",
            isARepeat: false, keyCode: code))
        view.keyDown(with: event)
    }

    private func assertVertices(_ annotation: PDFAnnotation, _ expected: [CGPoint], file: StaticString = #filePath, line: UInt = #line) {
        let actual = RectangleMarkupRecord.vertices(annotation)
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.x, e.x, accuracy: 1e-7, file: file, line: line)
            XCTAssertEqual(a.y, e.y, accuracy: 1e-7, file: file, line: line)
        }
    }

    private func assertUndoRedo(_ annotation: PDFAnnotation, view: MarkupPDFView, page: PDFPage) {
        let undo = view.rectangleMarkup.undo
        let vertices = RectangleMarkupRecord.vertices(annotation)
        for _ in 0..<2 {
            XCTAssertTrue(undo.canUndo)
            undo.undo()
            XCTAssertTrue(measurements(on: page).isEmpty, "One undo removes the entire measurement")
            XCTAssertFalse(undo.canUndo, "Hover, continuation and mouse-up must not register extra operations")
            XCTAssertTrue(undo.canRedo)
            undo.redo()
            XCTAssertEqual(measurements(on: page).count, 1)
            XCTAssertTrue(measurements(on: page).first === annotation)
            assertVertices(annotation, vertices)
            XCTAssertFalse(undo.canRedo)
        }
    }

    func testSecondClickAndShiftFinishThroughNativeHandlersAtEveryRotation() throws {
        for rotation in [0, 90, 180, 270] {
            for flags in [NSEvent.ModifierFlags(), .shift] {
                try withCanvas(rotation: rotation) { window, view, page in
                    try click(start, window: window, view: view, page: page)
                    try mouse(.mouseMoved, second, flags, window: window, view: view, page: page)
                    XCTAssertTrue(measurements(on: page).isEmpty, "Hover must not commit")
                    XCTAssertFalse(view.rectangleMarkup.undo.canUndo)
                    try mouse(.leftMouseDown, second, flags, commits: true, window: window, view: view, page: page)
                    XCTAssertEqual(measurements(on: page).count, 1, "Finish occurs on second down, not up")
                    let annotation = try XCTUnwrap(view.rectangleMarkup.selected)
                    assertVertices(annotation, [start, flags.contains(.shift) ? CGPoint(x: 190, y: 100) : second])
                    XCTAssertFalse(try XCTUnwrap(MeasurementMetadata.measurement(annotation)).closed)
                    XCTAssertEqual(view.rectangleMarkup.tool, .select)
                    for _ in 0..<2 { try mouse(.leftMouseUp, second, flags, window: window, view: view, page: page) }
                    XCTAssertEqual(measurements(on: page).count, 1, "Mouse-up cannot duplicate completion")
                    XCTAssertTrue(view.rectangleMarkup.selected === annotation)
                    assertUndoRedo(annotation, view: view, page: page)
                }
            }
        }
    }

    func testControlAndControlShiftContinueUntilControlReleasedAtEveryRotation() throws {
        for rotation in [0, 90, 180, 270] {
            for finalFlags in [NSEvent.ModifierFlags(), .shift] {
                try withCanvas(rotation: rotation) { window, view, page in
                    try click(start, window: window, view: view, page: page)
                    try mouse(.mouseMoved, second, .control, window: window, view: view, page: page)
                    try click(second, .control, window: window, view: view, page: page)
                    let third = CGPoint(x: 260, y: 260)
                    try mouse(.mouseMoved, third, [.control, .shift], window: window, view: view, page: page)
                    try click(third, [.control, .shift], window: window, view: view, page: page)
                    XCTAssertTrue(measurements(on: page).isEmpty)
                    XCTAssertEqual(view.rectangleMarkup.tool, .perimeter)
                    XCTAssertFalse(view.rectangleMarkup.undo.canUndo)
                    let last = CGPoint(x: 340, y: 310)
                    try mouse(.mouseMoved, last, finalFlags, window: window, view: view, page: page)
                    XCTAssertTrue(measurements(on: page).isEmpty, "Releasing Control during hover cannot finish")
                    try click(last, finalFlags, commits: true, window: window, view: view, page: page)
                    XCTAssertEqual(measurements(on: page).count, 1)
                    XCTAssertEqual(view.rectangleMarkup.tool, .select)
                    let annotation = try XCTUnwrap(view.rectangleMarkup.selected)
                    assertVertices(annotation, [start, second, CGPoint(x: 190, y: 260),
                        finalFlags.contains(.shift) ? CGPoint(x: 340, y: 260) : last])
                    XCTAssertFalse(try XCTUnwrap(MeasurementMetadata.measurement(annotation)).closed)
                    assertUndoRedo(annotation, view: view, page: page)
                }
            }
        }
    }

    func testDuplicateClicksDoNotFinishOrCreateUndoTransactions() throws {
        try withCanvas { window, view, page in
            try click(start, window: window, view: view, page: page)
            try click(start, .shift, window: window, view: view, page: page)
            try click(second, [.control, .shift], window: window, view: view, page: page)
            try click(CGPoint(x: 190, y: 100), window: window, view: view, page: page)
            XCTAssertTrue(measurements(on: page).isEmpty)
            XCTAssertFalse(view.rectangleMarkup.undo.canUndo)
            try click(CGPoint(x: 270, y: 250), commits: true, window: window, view: view, page: page)
            let annotation = try XCTUnwrap(view.rectangleMarkup.selected)
            assertVertices(annotation, [start, CGPoint(x: 190, y: 100), CGPoint(x: 270, y: 250)])
            assertUndoRedo(annotation, view: view, page: page)
        }
    }

    func testEscapeCancelsOnePointAndControlContinuedDraftsWithoutUndo() throws {
        for continued in [false, true] {
            try withCanvas { window, view, page in
                try click(start, window: window, view: view, page: page)
                if continued { try click(second, [.control, .shift], window: window, view: view, page: page) }
                try mouse(.mouseMoved, CGPoint(x: 300, y: 270), .shift, window: window, view: view, page: page)
                try key(53, view: view, window: window)
                try mouse(.leftMouseUp, second, window: window, view: view, page: page)
                try key(36, view: view, window: window)
                XCTAssertTrue(measurements(on: page).isEmpty)
                XCTAssertFalse(view.rectangleMarkup.undo.canUndo)
                view.rectangleMarkup.tool = .perimeter
                let fresh = CGPoint(x: 300, y: 300), end = CGPoint(x: 400, y: 350)
                try click(fresh, window: window, view: view, page: page)
                XCTAssertTrue(measurements(on: page).isEmpty, "Cancelled points cannot leak into a new draft")
                try click(end, commits: true, window: window, view: view, page: page)
                let annotation = try XCTUnwrap(view.rectangleMarkup.selected)
                assertVertices(annotation, [fresh, end])
                assertUndoRedo(annotation, view: view, page: page)
            }
        }
    }

    func testControlDoubleClickExplicitlyFinishesOpenChain() throws {
        try withCanvas { window, view, page in
            try click(start, window: window, view: view, page: page)
            try click(second, .control, window: window, view: view, page: page)
            let end = CGPoint(x: 300, y: 270)
            try click(end, .control, clicks: 2, commits: true, window: window, view: view, page: page)
            let annotation = try XCTUnwrap(view.rectangleMarkup.selected)
            XCTAssertEqual(measurements(on: page).count, 1)
            assertVertices(annotation, [start, second, end])
            XCTAssertFalse(try XCTUnwrap(MeasurementMetadata.measurement(annotation)).closed)
            assertUndoRedo(annotation, view: view, page: page)
        }
    }

    func testControlClickNearFirstExplicitlyClosesPerimeter() throws {
        try withCanvas { window, view, page in
            try click(start, window: window, view: view, page: page)
            try click(second, .control, window: window, view: view, page: page)
            let third = CGPoint(x: 300, y: 270)
            try click(third, .control, window: window, view: view, page: page)
            try click(CGPoint(x: 101, y: 101), .control, commits: true, window: window, view: view, page: page)
            let annotation = try XCTUnwrap(view.rectangleMarkup.selected)
            XCTAssertEqual(measurements(on: page).count, 1)
            assertVertices(annotation, [start, second, third])
            XCTAssertTrue(try XCTUnwrap(MeasurementMetadata.measurement(annotation)).closed)
            assertUndoRedo(annotation, view: view, page: page)
        }
    }
}
