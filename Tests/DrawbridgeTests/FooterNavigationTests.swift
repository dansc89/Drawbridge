import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor private final class FooterTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor final class FooterNavigationTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    private func field(_ id: String, _ controller: MainViewController) throws -> NSTextField {
        try XCTUnwrap(descendants(controller.statusBar).first { $0.identifier?.rawValue == id } as? NSTextField)
    }
    private func withFooter(_ body: (MainViewController, NSWindow, PDFDocument) throws -> Void) throws {
        _ = NSApplication.shared
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: bytes)), mediaBox: &box, nil))
        for _ in 0..<8 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: bytes as Data))
        let controller = MainViewController()
        let window = FooterTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.pdfView.setMarkupDocument(document)
        controller.pdfView.go(to: document.page(at: 0)!)
        controller.updateStatusBar()
        window.layoutIfNeeded()
        defer { window.makeFirstResponder(nil); window.contentViewController = nil }
        try body(controller, window, document)
    }
    func testFixedControlGroupIsCenteredAndSheetLabelIsIndependentlyTrailing() throws {
        try withFooter { controller, window, document in
            let buttons = descendants(controller.statusBar).compactMap { $0 as? NSButton }
            XCTAssertGreaterThanOrEqual(buttons.count, 7)
            let entry = try XCTUnwrap(try field("drawbridgeFooterPageNumber", controller).superview)
            let group = try XCTUnwrap(entry.superview as? NSStackView)
            @MainActor func controlFrame() -> NSRect {
                group.convert(group.bounds, to: controller.statusBar)
            }
            @MainActor func assertCentered(file: StaticString = #filePath, line: UInt = #line) throws {
                let frame = controlFrame()
                XCTAssertEqual(frame.midX, controller.statusBar.bounds.midX, accuracy: 0.1, file: file, line: line)
                let label = try field("drawbridgeFooterPageLabel", controller)
                let labelFrame = label.convert(label.bounds, to: controller.statusBar)
                XCTAssertEqual(labelFrame.maxX, controller.statusBar.bounds.maxX - 10, accuracy: 0.1, file: file, line: line)
                XCTAssertGreaterThanOrEqual(labelFrame.minX, frame.maxX + 10 - 0.1, file: file, line: line)
                XCTAssertFalse(group.arrangedSubviews.contains { $0 === label }, file: file, line: line)
            }
            try assertCentered()
            let initialCenter = controller.statusBar.bounds.midX
            let positions = buttons.map { $0.convert($0.bounds, to: controller.statusBar).minX }
            for (index, label, scale) in [(0, "A", 0.1), (7, String(repeating: "Long sheet name ", count: 30), 4.0), (2, "123456", 1.0)] {
                controller.pageLabelOverrides[index] = label
                document.page(at: index)!.setBounds(CGRect(x: 0, y: 0, width: index == 7 ? 12000 : 600, height: 800), for: .mediaBox)
                controller.pdfView.go(to: document.page(at: index)!)
                controller.pdfView.scaleFactor = scale
                controller.updateStatusBar(); window.layoutIfNeeded()
                try assertCentered()
                for (button, x) in zip(buttons, positions) {
                    XCTAssertEqual(button.convert(button.bounds, to: controller.statusBar).minX, x, accuracy: 0.1)
                }
            }
            window.setContentSize(NSSize(width: 1100, height: 900)); window.layoutIfNeeded()
            try assertCentered()
            let resizeDelta = controller.statusBar.bounds.midX - initialCenter
            for (button, x) in zip(buttons, positions) {
                XCTAssertEqual(button.convert(button.bounds, to: controller.statusBar).minX, x + resizeDelta, accuracy: 0.1)
            }
            // Enabled-state transitions must not change the fixed control geometry.
            let resizedPositions = buttons.map { $0.convert($0.bounds, to: controller.statusBar).minX }
            controller.pdfView.setMarkupDocument(nil)
            controller.updateStatusBar(); window.layoutIfNeeded()
            try assertCentered()
            for (button, x) in zip(buttons, resizedPositions) {
                XCTAssertEqual(button.convert(button.bounds, to: controller.statusBar).minX, x, accuracy: 0.1)
            }
            controller.pdfView.setMarkupDocument(document)
            controller.pdfView.go(to: document.page(at: 2)!)
            controller.updateStatusBar(); window.layoutIfNeeded()
            let label = try field("drawbridgeFooterPageLabel", controller)
            XCTAssertTrue(label.isSelectable)
            XCTAssertEqual(label.toolTip, "123456")
            XCTAssertTrue(try field("drawbridgeFooterSize", controller).isSelectable)
            XCTAssertTrue(try field("drawbridgeFooterZoom", controller).isSelectable)
            let overflow = try XCTUnwrap(descendants(controller.statusBar).first { $0.identifier?.rawValue == "drawbridgeFooterOverflow" } as? NSScrollView)
            window.setContentSize(NSSize(width: 700, height: 900)); window.layoutIfNeeded()
            // AppKit enforces the controller's minimum width even for a requested 700-point window.
            // Overflow is required only when the actual viewport is smaller than the fixed block.
            let overflowDocument = try XCTUnwrap(overflow.documentView)
            XCTAssertGreaterThanOrEqual(overflowDocument.frame.width, overflow.contentView.bounds.width)
            XCTAssertGreaterThanOrEqual(overflowDocument.frame.width, group.frame.width + 20)
            if overflow.contentView.bounds.width >= group.frame.width + 20 { try assertCentered() }
            let documentPositions = buttons.map { $0.convert($0.bounds, to: overflow.documentView).minX }
            controller.pageLabelOverrides[2] = String(repeating: "Long", count: 100)
            controller.updateStatusBar(); window.layoutIfNeeded()
            for (button, x) in zip(buttons, documentPositions) {
                XCTAssertEqual(button.convert(button.bounds, to: overflow.documentView).minX, x, accuracy: 0.1)
            }
        }
    }
    private func edit(_ value: String, controller: MainViewController, window: NSWindow) throws -> NSTextView {
        let number = try field("drawbridgeFooterPageNumber", controller)
        XCTAssertTrue(number.isEditable)
        XCTAssertTrue(window.makeFirstResponder(number))
        let editor = try XCTUnwrap(number.currentEditor() as? NSTextView)
        editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        return editor
    }
    func testEnterJumpsToPhysicalPageNotCustomLabel() throws {
        try withFooter { controller, window, document in
            controller.pageLabelOverrides[0] = "5"
            let editor = try edit("5", controller: controller, window: window)
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertTrue(controller.pdfView.currentPage === document.page(at: 4))
            XCTAssertEqual(try field("drawbridgeFooterPageNumber", controller).stringValue, "5")
            XCTAssertEqual(try field("drawbridgeFooterPageTotal", controller).stringValue, "of 8")
        }
    }
    func testInvalidEntriesDoNotNavigateAndRestoreCurrentNumber() throws {
        try withFooter { controller, window, document in
            for value in ["", "0", "-1", "9", "abc", "1.5", "999999999999999999999999999999999"] {
                let editor = try edit(value, controller: controller, window: window)
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                XCTAssertTrue(controller.pdfView.currentPage === document.page(at: 0), value)
                XCTAssertEqual(try field("drawbridgeFooterPageNumber", controller).stringValue, "1", value)
            }
        }
    }
    func testRefreshDoesNotOverwriteEditorAndEscapeOrBlurReverts() throws {
        try withFooter { controller, window, document in
            let editor = try edit("5", controller: controller, window: window)
            controller.pdfView.go(to: document.page(at: 2)!); controller.updateStatusBar()
            XCTAssertEqual(editor.string, "5")
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            XCTAssertTrue(controller.pdfView.currentPage === document.page(at: 2))
            XCTAssertEqual(try field("drawbridgeFooterPageNumber", controller).stringValue, "3")
            _ = try edit("7", controller: controller, window: window)
            window.makeFirstResponder(controller.pdfView)
            XCTAssertEqual(try field("drawbridgeFooterPageNumber", controller).stringValue, "3")
        }
    }
    func testEditorArrowsAndCommandShortcutsPassThroughRealRouter() throws {
        try withFooter { controller, window, document in
            let editor = try edit("5", controller: controller, window: window)
            for (code, text, flags) in [(UInt16(123), "\u{f702}", NSEvent.ModifierFlags()), (124, "\u{f703}", []), (125, "\u{f701}", []), (126, "\u{f700}", []), (0, "a", .command), (8, "c", .command), (9, "v", .command), (6, "z", .command)] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
                XCTAssertTrue(controller.routeKeyDownEvent(event) === event)
                XCTAssertTrue(window.firstResponder === editor)
                XCTAssertTrue(controller.pdfView.currentPage === document.page(at: 0))
            }
            editor.selectedRange = NSRange(location: 1, length: 0)
            editor.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{f702}", charactersIgnoringModifiers: "\u{f702}", isARepeat: false, keyCode: 123)))
            XCTAssertEqual(editor.selectedRange.location, 0)
        }
    }
}
