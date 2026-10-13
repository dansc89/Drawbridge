import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

// Exercise the real router without launching/activating a foreground window.
@MainActor private final class TabShortcutWindow: NSWindow {
    var routesAsKeyWindow = true
    override var isKeyWindow: Bool { routesAsKeyWindow }
}

@MainActor
final class DocumentTabShortcutTests: XCTestCase {
    private func fixture() throws -> URL {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TabShortcut-\(UUID().uuidString).pdf")
        try (data as Data).write(to: url)
        return url
    }

    private func withTabs(_ body: (MainViewController, TabShortcutWindow, [URL], [PDFDocument]) throws -> Void) throws {
        _ = NSApplication.shared
        let urls = try (0..<3).map { _ in try fixture() }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let controller = MainViewController()
        let window = TabShortcutWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.layoutIfNeeded()
        var documents: [PDFDocument] = []
        for url in urls {
            controller.openDocument(at: url)
            documents.append(try XCTUnwrap(controller.pdfView.document))
        }
        try body(controller, window, urls, documents)
    }

    private func tab(_ flags: NSEvent.ModifierFlags, window: NSWindow, repeatKey: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: flags.contains(.shift) ? "\u{19}" : "\t", charactersIgnoringModifiers: "\t", isARepeat: repeatKey, keyCode: 48))
    }

    func testForwardAndBackwardWrapFromPDFSidebarAndTextFocus() throws {
        try withTabs { controller, window, urls, _ in
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
            text.string = "keep editing"
            controller.view.addSubview(text)
            let field = NSTextField(frame: NSRect(x: 0, y: 40, width: 100, height: 24))
            field.stringValue = "keep field"
            controller.view.addSubview(field)
            let responders: [NSResponder] = [controller.pdfView, controller.pagesTableView, controller.bookmarksOutlineView, text, field]
            for responder in responders {
                XCTAssertTrue(window.makeFirstResponder(responder))
                XCTAssertTrue(window.firstResponder === responder || (responder === field && window.firstResponder is NSTextView))
                XCTAssertNil(controller.routeKeyDownEvent(try tab(.control, window: window)))
                XCTAssertEqual(controller.openDocumentURL, urls[0], "Forward wraps last → first")
                XCTAssertTrue(window.makeFirstResponder(responder))
                XCTAssertNil(controller.routeKeyDownEvent(try tab([.control, .shift], window: window)))
                XCTAssertEqual(controller.openDocumentURL, urls[2], "Backward wraps first → last")
                XCTAssertEqual(controller.sessionDocumentURLs, urls)
            }
            XCTAssertEqual(text.string, "keep editing")
            XCTAssertEqual(field.stringValue, "keep field")
        }
    }

    func testCapsLockAndDeviceSpecificFlagsDoNotDisableTabCycling() throws {
        try withTabs { controller, window, urls, _ in
            // Low bits represent device-specific flags; capsLock is independent but not a shortcut modifier.
            let deviceControl = NSEvent.ModifierFlags(rawValue: 1)
            XCTAssertNil(controller.routeKeyDownEvent(try tab([.control, .capsLock, deviceControl], window: window)))
            XCTAssertEqual(controller.openDocumentURL, urls[0])
            XCTAssertNil(controller.routeKeyDownEvent(try tab([.control, .shift, .capsLock, deviceControl], window: window)))
            XCTAssertEqual(controller.openDocumentURL, urls[2])
        }
    }

    func testPlainTabAndOtherModifiedTabsPassThroughUnchanged() throws {
        try withTabs { controller, window, urls, documents in
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
            controller.view.addSubview(text)
            for responder in [controller.pdfView, controller.pagesTableView, text] as [NSResponder] {
                XCTAssertTrue(window.makeFirstResponder(responder))
                for flags: NSEvent.ModifierFlags in [[], .shift, [.control, .option], [.control, .command]] {
                    let event = try tab(flags, window: window)
                    XCTAssertTrue(controller.routeKeyDownEvent(event) === event)
                    XCTAssertEqual(controller.openDocumentURL, urls[2])
                    XCTAssertTrue(controller.pdfView.document === documents[2])
                    XCTAssertTrue(window.firstResponder === responder)
                }
            }
        }
    }

    func testInactiveWindowDoesNotConsumeControlTab() throws {
        try withTabs { controller, window, urls, _ in
            window.routesAsKeyWindow = false
            let event = try tab(.control, window: window)
            XCTAssertTrue(controller.routeKeyDownEvent(event) === event)
            XCTAssertEqual(controller.openDocumentURL, urls[2])
        }
    }

    func testRapidRepeatedCyclingRetainsPDFDocumentIdentityAndOrder() throws {
        try withTabs { controller, window, urls, documents in
            var index = 2
            for step in [1, -1] {
                for _ in 0..<18 {
                    index = (index + step + urls.count) % urls.count
                    let flags: NSEvent.ModifierFlags = step == 1 ? .control : [.control, .shift]
                    XCTAssertNil(controller.routeKeyDownEvent(try tab(flags, window: window, repeatKey: true)))
                    XCTAssertEqual(controller.openDocumentURL, urls[index])
                    XCTAssertTrue(controller.pdfView.document === documents[index])
                    XCTAssertEqual(controller.sessionDocumentURLs, urls)
                    XCTAssertFalse(window.isDocumentEdited)
                }
            }
        }
    }
}
