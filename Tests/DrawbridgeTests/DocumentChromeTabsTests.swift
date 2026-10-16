import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class DocumentChromeTabsTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testBoundedTabsOverflowSelectAndCloseIndependently() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let c = MainViewController()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.contentViewController = c
        defer { w.makeFirstResponder(nil); w.contentViewController = nil }
        var urls: [URL] = []
        for i in 1...7 {
            let d = PDFDocument(); d.insert(PDFPage(), at: 0)
            let url = folder.appendingPathComponent("Sheet \(i) - Architectural drawings with a very long document name.pdf")
            try XCTUnwrap(d.dataRepresentation()).write(to: url)
            urls.append(url); c.openDocument(at: url)
        }
        w.layoutIfNeeded(); c.view.layoutSubtreeIfNeeded()
        func tabs() -> [DocumentChromeTabButton] { descendants(c.view).compactMap { $0 as? DocumentChromeTabButton } }
        XCTAssertEqual(tabs().count, 7)
        for tab in tabs() {
            XCTAssertEqual(tab.frame.width, 240, accuracy: 0.5)
            XCTAssertEqual(tab.frame.height, 32, accuracy: 0.5)
            XCTAssertFalse(tab.closeButton.isHidden)
            XCTAssertEqual(tab.toolTip, tab.identifier?.rawValue)
        }
        let selected = try XCTUnwrap(tabs().first { $0.state == .on })
        let scroll = try XCTUnwrap(selected.enclosingScrollView)
        XCTAssertEqual(scroll.contentSize.height, 40, accuracy: 0.5)
        XCTAssertTrue(scroll.documentVisibleRect.intersects(selected.frame))
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.width, scroll.contentSize.width)
        let earlier = try XCTUnwrap(descendants(c.view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "drawbridgeEarlierTabs" })
        let later = try XCTUnwrap(descendants(c.view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "drawbridgeLaterTabs" })
        XCTAssertFalse(earlier.isHidden)
        let overflowStart = scroll.contentView.bounds.minX
        earlier.performClick(nil)
        XCTAssertLessThan(scroll.contentView.bounds.minX, overflowStart)
        later.performClick(nil)
        XCTAssertEqual(scroll.contentView.bounds.minX, overflowStart, accuracy: 0.5)
        // Exercise actual wheel handling, not just programmatic reveal-on-select.
        let startX = scroll.contentView.bounds.minX
        XCTAssertGreaterThan(startX, 0)
        let leftWheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 120, wheel3: 0))
        scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: leftWheel)))
        let leftX = scroll.contentView.bounds.minX
        XCTAssertLessThan(leftX, startX, "Earlier tabs must be reachable with a horizontal wheel gesture")
        let rightWheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -120, wheel3: 0))
        scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: rightWheel)))
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, leftX, "Later tabs must be reachable too")
        if let directory = ProcessInfo.processInfo.environment["DRAWBRIDGE_TAB_PREVIEW_DIR"],
           let strip = scroll.superview {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                w.appearance = NSAppearance(named: name)
                tabs().forEach { $0.refreshChromeColors() }
                strip.displayIfNeeded()
                let bitmap = try XCTUnwrap(strip.bitmapImageRepForCachingDisplay(in: strip.bounds))
                strip.cacheDisplay(in: strip.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("tabs-\(name.rawValue).png"))
            }
        }
        let activeDocument = c.pdfView.document
        let inactive = try XCTUnwrap(tabs().first { $0.identifier?.rawValue == urls[0].path })
        inactive.closeButton.performClick(nil)
        XCTAssertEqual(tabs().count, 6)
        XCTAssertTrue(c.pdfView.document === activeDocument)
        XCTAssertEqual(c.openDocumentURL, urls.last)
        let target = try XCTUnwrap(tabs().first { $0.identifier?.rawValue == urls[1].path })
        target.performClick(nil)
        XCTAssertEqual(c.openDocumentURL, urls[1])
        XCTAssertEqual(tabs().filter { $0.state == .on }.count, 1)
        try XCTUnwrap(tabs().first { $0.state == .on }).closeButton.performClick(nil)
        XCTAssertEqual(tabs().count, 5)
        XCTAssertFalse(c.sessionDocumentURLs.contains(urls[1]))
        while !c.sessionDocumentURLs.isEmpty { c.commandCloseDocument(nil) }
        XCTAssertTrue(tabs().isEmpty)
        XCTAssertTrue(earlier.isHidden)
        XCTAssertTrue(later.isHidden)
        XCTAssertFalse(w.isVisible)
    }
}
