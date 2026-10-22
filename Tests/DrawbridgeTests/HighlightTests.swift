import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor private final class HighlightShortcutWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// Synthetic native handlers, never-ordered fixture windows; no physical input.
@MainActor final class HighlightTests: XCTestCase {
    private func canvas(rotation: Int = 0, _ body: (NSWindow, MarkupPDFView, PDFPage) throws -> Void) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = MarkupPDFView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        let document = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        page.rotation = rotation; document.insert(page, at: 0)
        view.setMarkupDocument(document); view.displayMode = .singlePage; view.autoScales = true; view.go(to: page)
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible)
        // The real view's controller owns event routing; isolate its saved appearance key.
        let key = "MarkupDefaults.v1.highlight"
        let old = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { if let old { UserDefaults.standard.set(old, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        view.rectangleMarkup.undo.groupsByEvent = false
        try body(window, view, page)
    }

    private func highlightTool() throws -> RectangleMarkupController.Tool {
        try XCTUnwrap(RectangleMarkupController.Tool(rawValue: "highlight"), "Highlight must be an actual authoring tool")
    }
    private func highlightKind() throws -> RectangleMarkupRecord.Kind { try XCTUnwrap(RectangleMarkupRecord.Kind(rawValue: "highlight")) }
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow, view: MarkupPDFView, page: PDFPage) throws {
        let location = view.convert(point, from: page)
        XCTAssertTrue(view.page(for: location, nearest: false) === page)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(location, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }
    private func assertQuads(_ annotation: PDFAnnotation, file: StaticString = #filePath, line: UInt = #line) {
        let w = annotation.bounds.width, h = annotation.bounds.height
        XCTAssertEqual(annotation.quadrilateralPoints?.map(\.pointValue), [CGPoint(x: 0, y: h), CGPoint(x: w, y: h), .zero, CGPoint(x: w, y: 0)], file: file, line: line)
    }

    func testNativeDragAllDirectionsAndRotationsFinishesSelectWithUndoRedo() throws {
        for rotation in [0, 90, 180, 270] {
            try canvas(rotation: rotation) { window, view, page in
                for (a, b) in [(CGPoint(x: 100, y: 100), CGPoint(x: 250, y: 140)), (CGPoint(x: 250, y: 140), CGPoint(x: 100, y: 100)), (CGPoint(x: 100, y: 140), CGPoint(x: 250, y: 100)), (CGPoint(x: 250, y: 100), CGPoint(x: 100, y: 140))] {
                    view.rectangleMarkup.tool = try highlightTool()
                    let undo = view.rectangleMarkup.undo; undo.removeAllActions()
                    try mouse(.leftMouseDown, at: a, window: window, view: view, page: page)
                    try mouse(.leftMouseDragged, at: b, window: window, view: view, page: page)
                    XCTAssertTrue(page.annotations.isEmpty, "Preview must not mutate the PDF")
                    undo.beginUndoGrouping()
                    try mouse(.leftMouseUp, at: b, window: window, view: view, page: page)
                    undo.endUndoGrouping()
                    let annotation = try XCTUnwrap(page.annotations.first)
                    XCTAssertEqual(page.annotations.count, 1); XCTAssertEqual(annotation.type, "Highlight")
                    XCTAssertEqual(annotation.bounds.minX, 100, accuracy: 1e-6); XCTAssertEqual(annotation.bounds.minY, 100, accuracy: 1e-6)
                    XCTAssertEqual(annotation.bounds.width, 150, accuracy: 1e-6); XCTAssertEqual(annotation.bounds.height, 40, accuracy: 1e-6)
                    assertQuads(annotation)
                    XCTAssertEqual(view.rectangleMarkup.tool, .select)
                    XCTAssertTrue(view.rectangleMarkup.selected === annotation)
                    undo.undo(); XCTAssertTrue(page.annotations.isEmpty)
                    undo.redo(); XCTAssertTrue(page.annotations.first === annotation)
                    page.removeAnnotation(annotation)
                }
            }
        }
    }

    func testCancelTinyDragAndToolSwitchDoNotCreateHighlight() throws {
        try canvas { window, view, page in
            let a = CGPoint(x: 100, y: 100), b = CGPoint(x: 220, y: 140)
            for cancel in [true, false] {
                view.rectangleMarkup.tool = try highlightTool()
                try mouse(.leftMouseDown, at: a, window: window, view: view, page: page)
                try mouse(.leftMouseDragged, at: b, window: window, view: view, page: page)
                if cancel { view.rectangleMarkup.escape() } else { view.rectangleMarkup.tool = .select }
                try mouse(.leftMouseUp, at: b, window: window, view: view, page: page)
                XCTAssertTrue(page.annotations.isEmpty); XCTAssertFalse(view.rectangleMarkup.undo.canUndo)
            }
            view.rectangleMarkup.tool = try highlightTool()
            try mouse(.leftMouseDown, at: a, window: window, view: view, page: page)
            try mouse(.leftMouseUp, at: a, window: window, view: view, page: page)
            XCTAssertTrue(page.annotations.isEmpty)
        }
    }

    func testYellowTranslucentDefaultsAreToolLocalAndSavedDefaultsWin() throws {
        let name = "HighlightDefaults-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let session = RectangleMarkupController(defaults: defaults)
        session.strokeColor = .red; session.strokeOpacity = 1
        session.tool = try highlightTool()
        let rgb = try XCTUnwrap(session.strokeColor.usingColorSpace(.deviceRGB))
        XCTAssertEqual(rgb.redComponent, 1, accuracy: 0.01); XCTAssertEqual(rgb.greenComponent, 1, accuracy: 0.01); XCTAssertEqual(rgb.blueComponent, 0, accuracy: 0.01)
        XCTAssertEqual(session.strokeOpacity, 0.35, accuracy: 0.001)
        session.tool = .rectangle
        XCTAssertEqual(session.strokeOpacity, 1); XCTAssertEqual(session.strokeColor.usingColorSpace(.deviceRGB), NSColor.red.usingColorSpace(.deviceRGB))
        session.tool = try highlightTool(); session.strokeColor = .green; session.strokeOpacity = 0.25
        XCTAssertTrue(session.saveCurrentAsDefault()); session.tool = .select; session.tool = try highlightTool()
        XCTAssertEqual(session.strokeOpacity, 0.25); XCTAssertEqual(session.strokeColor.usingColorSpace(.deviceRGB), NSColor.green.usingColorSpace(.deviceRGB))
    }

    func testGeometryClipboardAndStyleUndoPreserveNativeHighlight() throws {
        try canvas { _, view, page in
            let c = view.rectangleMarkup
            c.tool = try highlightTool()
            c.undo.beginUndoGrouping()
            let annotation = try XCTUnwrap(c.create(on: page, bounds: CGRect(x: 100, y: 100, width: 150, height: 40), kind: highlightKind()))
            c.undo.endUndoGrouping(); c.undo.removeAllActions()
            XCTAssertTrue(RectangleMarkupRecord.owns(annotation)); assertQuads(annotation)
            let old = annotation.bounds, resized = CGRect(x: 70, y: 80, width: 210, height: 60)
            c.undo.beginUndoGrouping(); c.setBounds(resized, of: annotation, on: page, action: "Resize Markup"); c.undo.endUndoGrouping()
            assertQuads(annotation); c.undo.undo(); XCTAssertEqual(annotation.bounds, old); assertQuads(annotation)
            c.undo.redo(); XCTAssertEqual(annotation.bounds, resized); assertQuads(annotation)
            let record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: annotation, pageIndex: 0))
            XCTAssertEqual(record.kind.rawValue, "highlight"); XCTAssertTrue(record.isValid)
            var decoded = try JSONDecoder().decode(RectangleMarkupRecord.self, from: JSONEncoder().encode(record))
            decoded.bounds = resized.offsetBy(dx: 30, dy: 20)
            let copy = try decoded.clipboardAnnotation(contents: nil)
            XCTAssertEqual(copy.type, "Highlight"); assertQuads(copy)
            XCTAssertEqual(MarkupStyle.strokeOpacity(copy), 0.35, accuracy: 0.001)
        }
    }

    private func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
    private func key(_ window: NSWindow, _ value: String = "h", flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: 4))
    }
    func testToolbarSettingsAndConfigurableHProtectTypingAndExistingModifiedH() throws {
        _ = NSApplication.shared
        let c = MainViewController(); _ = c.view; c.shortcutBindings = c.defaultShortcutBindings()
        let window = HighlightShortcutWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = c
        defer { window.close() }
        let document = PDFDocument(); document.insert(PDFPage(), at: 0); c.pdfView.setMarkupDocument(document)
        // This in-memory routing fixture has no opened source URL; isolate
        // edit authorization rather than weakening the production source guard.
        c.pdfView.rectangleMarkup.canEdit = { true }; c.refreshRectangleToolbar()
        let action = try XCTUnwrap(ShortcutAction(rawValue: "highlight"))
        XCTAssertEqual(action.defaultBinding, ShortcutBinding(key: "h", modifier: .plain))
        XCTAssertEqual(c.defaultShortcutBindings().values.filter { $0 == action.defaultBinding }.count, 1)
        XCTAssertNotEqual(ShortcutAction.hyperlinks.defaultBinding, action.defaultBinding)
        // Native NSToolbar hosts these controls outside the content-view tree.
        let toolbar = try XCTUnwrap(descendants(c.rectangleToolbar).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "markup.highlight" })
        XCTAssertTrue(toolbar.isEnabled); XCTAssertNotNil(toolbar.action)
        XCTAssertTrue(toolbar.sendAction(toolbar.action, to: toolbar.target)); XCTAssertEqual(c.pdfView.rectangleMarkup.tool.rawValue, "highlight")
        c.pdfView.rectangleMarkup.tool = .select
        XCTAssertTrue(window.makeFirstResponder(c.pdfView)); XCTAssertNil(c.routeKeyDownEvent(try key(window)))
        XCTAssertEqual(c.pdfView.rectangleMarkup.tool.rawValue, "highlight")
        for text in [NSTextView(frame: .zero), NSTextField(frame: .zero)] as [NSView] {
            c.view.addSubview(text); _ = window.makeFirstResponder(text); c.pdfView.rectangleMarkup.tool = .select
            let event = try key(window); XCTAssertTrue(c.routeKeyDownEvent(event) === event); XCTAssertEqual(c.pdfView.rectangleMarkup.tool, .select)
        }
        _ = window.makeFirstResponder(c.pdfView)
        c.shortcutBindings[action] = ShortcutBinding(key: "j", modifier: .plain)
        let old = try key(window); XCTAssertTrue(c.routeKeyDownEvent(old) === old)
        XCTAssertNil(c.routeKeyDownEvent(try key(window, "j"))); XCTAssertEqual(c.pdfView.rectangleMarkup.tool.rawValue, "highlight")
        let settings = SettingsWindowController(editor: c); settings.prepare(section: .shortcuts)
        defer { settings.window?.close() }
        let field = try XCTUnwrap(descendants(settings.window!.contentView!).first { $0.identifier?.rawValue == "shortcut.highlight" } as? NSTextField)
        XCTAssertEqual(field.stringValue.lowercased(), "j")
    }

    func testRealWriterReopensHighlightWithAbsoluteQuadPointsAtEveryRotation() throws {
        let kind = try highlightKind()
        for rotation in [0, 90, 180, 270] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("HighlightSave-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source.pdf"), output = root.appendingPathComponent("saved.pdf")
            let document = PDFDocument(), page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 400, height: 400), for: .mediaBox); page.rotation = rotation; document.insert(page, at: 0)
            XCTAssertTrue(document.write(to: source)); let original = try Data(contentsOf: source)
            var record = RectangleMarkupRecord(id: RectangleMarkupRecord.prefix + UUID().uuidString, pageIndex: 0, bounds: CGRect(x: 50.25, y: 70.5, width: 150.5, height: 30.25), red: 1, green: 1, blue: 0, lineWidth: 2)
            record.kind = kind; record.strokeOpacity = 0.35
            var failure: PDFRectangleWriter.SaveFailure?
            let loaded = try XCTUnwrap(PDFDocument(url: source))
            XCTAssertTrue(PDFRectangleWriter.write(document: loaded, source: source, destination: output, pageLabels: [:], records: [record], onFailure: { failure = $0 }), "\(failure?.stage ?? "unknown")")
            XCTAssertNil(failure); XCTAssertEqual(try Data(contentsOf: source), original)
            let reopened = try XCTUnwrap(PDFDocument(url: output)), savedPage = try XCTUnwrap(reopened.page(at: 0))
            XCTAssertEqual(savedPage.rotation, rotation)
            let annotation = try XCTUnwrap(savedPage.annotations.first)
            XCTAssertEqual(annotation.type, "Highlight"); assertQuads(annotation)
            let captured = try XCTUnwrap(RectangleMarkupRecord.capture(reopened).first)
            XCTAssertEqual(captured.kind, kind); XCTAssertEqual(captured.bounds, record.bounds)
            XCTAssertEqual(captured.strokeOpacity, 0.35, accuracy: 1e-9)
        }
    }
}
