import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor private final class HyperlinkTestWindow: NSWindow {
    var routesAsKeyWindow = true
    override var isKeyWindow: Bool { routesAsKeyWindow }
}

@MainActor final class HyperlinkVisibilityTests: XCTestCase {
    private let flags: NSEvent.ModifierFlags = [.command, .option, .shift]
    private func isolated(_ body: (MainViewController, HyperlinkTestWindow) throws -> Void) rethrows {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["DrawbridgeShortcutBindings", MainViewController.defaultsHyperlinkHighlightsVisibleKey, MainViewController.defaultsHyperlinkHighlightsDefaultMigrationKey]
        let old = keys.map { defaults.object(forKey: $0) }
        let menu = NSApp.mainMenu
        defer {
            NSApp.mainMenu = menu
            for (key, value) in zip(keys, old) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
        }
        defaults.removeObject(forKey: keys[0])
        // Old persisted visibility must not turn a view-only session toggle on.
        defaults.set(true, forKey: keys[1]); defaults.set(true, forKey: keys[2])
        let c = MainViewController(); _ = c.view; c.loadShortcutBindings()
        let w = HyperlinkTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.contentViewController = c
        defer { c.pdfView.document = nil; w.close() }
        try body(c, w)
    }
    private func event(_ w: NSWindow, key: String = "h", modifiers: NSEvent.ModifierFlags? = nil, repeatKey: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers ?? flags, timestamp: 0, windowNumber: w.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: repeatKey, keyCode: 4))
    }
    private func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func fixture() -> PDFDocument {
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil); context.setFillColor(NSColor.white.cgColor); context.fill(box); context.endPDFPage(); context.closePDF()
        let d = PDFDocument(data: data as Data)!; let p = d.page(at: 0)!
        let url = PDFAnnotation(bounds: NSRect(x: 100, y: 300, width: 80, height: 18), forType: .link, withProperties: nil)
        url.action = PDFActionURL(url: URL(string: "https://example.com")!); p.addAnnotation(url)
        let internalLink = PDFAnnotation(bounds: NSRect(x: 210, y: 350, width: 70, height: 20), forType: .link, withProperties: nil)
        internalLink.destination = PDFDestination(page: p, at: .zero); p.addAnnotation(internalLink)
        // A non-Link annotation with an action is NOT a PDF link annotation.
        let widget = PDFAnnotation(bounds: NSRect(x: 300, y: 400, width: 50, height: 20), forType: .text, withProperties: nil)
        widget.action = PDFActionURL(url: URL(string: "https://example.org")!); p.addAnnotation(widget)
        for annotation in p.annotations { annotation.color = .clear }
        return d
    }
    private func overlay(_ v: MarkupPDFView) throws -> CAShapeLayer {
        try XCTUnwrap(v.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.zPosition == 6 })
    }
    private func rects(_ layer: CAShapeLayer) -> [CGRect] {
        var result: [CGRect] = []; var points: [CGPoint] = []
        layer.path?.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint: points = [element.points[0]]
            case .addLineToPoint: points.append(element.points[0])
            case .closeSubpath:
                if let first = points.first { result.append(points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }) }
            default: break
            }
        }
        return result
    }
    func testDefaultOffMenuPlacementUniqueShortcutAndNoDocumentValidation() throws {
        try isolated { c, w in
            XCTAssertFalse(c.isHyperlinkHighlightsVisible)
            let action = try XCTUnwrap(ShortcutAction(rawValue: "hyperlinks"))
            XCTAssertEqual(c.currentShortcutBinding(for: action).encoded, "commandOptionShift:h")
            let delegate = AppDelegate(); delegate.setupMainMenu(controller: c)
            let menu = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "Hyperlinks")?.submenu)
            let toggle = try XCTUnwrap(menu.items.first { $0.action == #selector(MainViewController.commandToggleHyperlinkHighlights(_:)) })
            XCTAssertEqual(toggle.title, "Show Hyperlinks"); XCTAssertFalse(c.validateMenuItem(toggle))
            XCTAssertEqual(toggle.keyEquivalentModifierMask, flags)
            XCTAssertEqual(items(NSApp.mainMenu!).filter { $0.keyEquivalent == "h" && $0.keyEquivalentModifierMask == flags }.count, 1)
            let e = try event(w); XCTAssertTrue(c.routeKeyDownEvent(e) === e)
            c.commandToggleHyperlinkHighlights(nil); XCTAssertFalse(c.isHyperlinkHighlightsVisible)
        }
    }
    func testRealOverlayHasTightTranslucentLinkRectsWithoutMutatingPDFOrUndo() throws {
        try isolated { c, w in
            let d = fixture(); let p = try XCTUnwrap(d.page(at: 0)); c.pdfView.document = d
            c.pdfView.autoScales = false; c.pdfView.scaleFactor = 1; c.pdfView.layoutSubtreeIfNeeded()
            let before = p.annotations.map { ($0.bounds, $0.type, $0.color, $0.border?.lineWidth) }
            let canUndo = w.undoManager?.canUndo
            // PDFKit serializes an action-bearing Text annotation with a companion Link.
            let baseline = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(d.dataRepresentation())))
            let serializedBounds = baseline.page(at: 0)?.annotations.map(\.bounds)
            c.setHyperlinkHighlightsVisible(true)
            let layer = try overlay(c.pdfView)
            XCTAssertFalse(layer.isHidden)
            let color = try XCTUnwrap(layer.fillColor); XCTAssertGreaterThan(color.alpha, 0.05); XCTAssertLessThan(color.alpha, 0.4)
            XCTAssertEqual(rects(layer).count, 2, "Only real Link subtypes, internal and external")
            for a in p.annotations.prefix(2) { XCTAssertTrue(rects(layer).contains(c.pdfView.convert(a.bounds, from: p).standardized)) }
            XCTAssertEqual(w.undoManager?.canUndo, canUndo)
            for (a, b) in zip(p.annotations, before) { XCTAssertEqual(a.bounds, b.0); XCTAssertEqual(a.type, b.1); XCTAssertEqual(a.color, b.2); XCTAssertEqual(a.border?.lineWidth, b.3) }
            let shown = try XCTUnwrap(d.dataRepresentation())
            c.setHyperlinkHighlightsVisible(false)
            XCTAssertTrue(layer.isHidden); XCTAssertNil(layer.path)
            let hidden = try XCTUnwrap(d.dataRepresentation())
            let a = try XCTUnwrap(PDFDocument(data: shown)); let b = try XCTUnwrap(PDFDocument(data: hidden))
            XCTAssertEqual(a.page(at: 0)?.annotations.map(\.bounds), serializedBounds)
            XCTAssertEqual(b.page(at: 0)?.annotations.map(\.bounds), serializedBounds)
            XCTAssertEqual(a.page(at: 0)?.annotations.map(\.bounds), b.page(at: 0)?.annotations.map(\.bounds))
        }
    }
    func testOverlayRefreshForZoomRotationCropAddedLinksAndReplacement() throws {
        try isolated { c, _ in
            let d = fixture(); let p = try XCTUnwrap(d.page(at: 0)); c.pdfView.document = d
            c.pdfView.autoScales = false; c.pdfView.scaleFactor = 1; c.pdfView.layoutSubtreeIfNeeded(); c.setHyperlinkHighlightsVisible(true)
            let layer = try overlay(c.pdfView)
            for rotation in [0, 90, 180, 270] {
                p.rotation = rotation; p.setBounds(NSRect(x: 30, y: 50, width: 540, height: 700), for: .cropBox)
                c.pdfView.scaleFactor = 0.7; c.pdfView.layoutSubtreeIfNeeded(); c.pdfView.refreshHyperlinkHighlights()
                for a in p.annotations.prefix(2) { XCTAssertTrue(rects(layer).contains(c.pdfView.convert(a.bounds, from: p).standardized), "rotation \(rotation)") }
            }
            let added = PDFAnnotation(bounds: NSRect(x: 100, y: 450, width: 40, height: 20), forType: .link, withProperties: nil); p.addAnnotation(added)
            c.pdfView.refreshHyperlinkHighlights(); XCTAssertEqual(rects(layer).count, 3)
            c.pdfView.setColorInverted(true); c.pdfView.refreshHyperlinkHighlights(); XCTAssertFalse(layer.isHidden)
            c.pdfView.document = fixture()
            XCTAssertFalse(c.isHyperlinkHighlightsVisible, "A replacement/tab session starts hidden")
            XCTAssertTrue(layer.isHidden); XCTAssertNil(layer.path)
        }
    }
    private func assertShown(_ c: MainViewController, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(c.isHyperlinkHighlightsVisible, file: file, line: line)
        for pane in [c.pdfView, c.secondaryPDFView].compactMap({ $0 }) {
            let layer = try overlay(pane)
            XCTAssertFalse(layer.isHidden, "Every presented pane retains Show Hyperlinks", file: file, line: line)
            let page = try XCTUnwrap(pane.currentPage, file: file, line: line)
            let links = page.annotations.filter { $0.type == "Link" }
            XCTAssertFalse(links.isEmpty, file: file, line: line)
            XCTAssertEqual(rects(layer).count, links.count, file: file, line: line)
            for link in links {
                XCTAssertTrue(rects(layer).contains(pane.convert(link.bounds, from: page).standardized), file: file, line: line)
            }
        }
    }
    func testShowThenCreateSplitPreservesVisibleLinkOverlays() throws {
        try isolated { c, _ in
            let document = fixture(); c.pdfView.setMarkupDocument(document)
            c.commandToggleHyperlinkHighlights(nil)
            try assertShown(c)
            c.commandToggleSplitView(nil)
            XCTAssertNotNil(c.secondaryPDFView)
            XCTAssertTrue(c.pdfView.document === document)
            try assertShown(c)
        }
    }
    func testShownLinksSurviveRepeatedPaneTransfersPresentationRefreshAndCollapse() throws {
        try isolated { c, _ in
            let source = fixture(); source.insert(PDFPage(), at: 1)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertTrue(source.write(to: url))
            let document = try XCTUnwrap(PDFDocument(url: url))
            c.pdfView.setMarkupDocument(document)
            c.commandToggleSplitView(nil)
            // Enable after creation to independently expose the pane-transfer reset.
            c.commandToggleHyperlinkHighlights(nil)
            try assertShown(c)
            for _ in 0..<4 {
                c.activatePDFPane(try XCTUnwrap(c.secondaryPDFView))
                XCTAssertTrue(c.pdfView.document === document)
                try assertShown(c)
            }
            // Real controller structural refresh reinstalls the detached presentation.
            try c.deletePages(at: IndexSet(integer: 1))
            try assertShown(c)
            c.collapsePDFSplit()
            XCTAssertNil(c.secondaryPDFView)
            XCTAssertTrue(c.pdfView.document === document)
            try assertShown(c)
        }
    }
    func testActualDocumentReplacementAfterSplitStillStartsHidden() throws {
        try isolated { c, _ in
            c.pdfView.setMarkupDocument(fixture())
            c.commandToggleSplitView(nil)
            c.commandToggleHyperlinkHighlights(nil)
            let layer = try overlay(c.pdfView)
            XCTAssertFalse(layer.isHidden)
            let replacement = fixture()
            c.pdfView.setMarkupDocument(replacement)
            XCTAssertNil(c.secondaryPDFView)
            XCTAssertTrue(c.pdfView.document === replacement)
            XCTAssertFalse(c.isHyperlinkHighlightsVisible)
            XCTAssertTrue(layer.isHidden)
            XCTAssertNil(layer.path)
        }
    }
    func testShortcutRoutesOncePassesTextForeignWindowsAndExactModifiers() throws {
        try isolated { c, w in
            c.pdfView.document = fixture()
            for responder in [c.pdfView, c.pagesTableView, c.bookmarksOutlineView] as [NSResponder] {
                XCTAssertTrue(w.makeFirstResponder(responder))
                XCTAssertNil(c.routeKeyDownEvent(try event(w, modifiers: flags.union(.capsLock))))
                XCTAssertTrue(c.isHyperlinkHighlightsVisible)
                XCTAssertNil(c.routeKeyDownEvent(try event(w, repeatKey: true))); XCTAssertTrue(c.isHyperlinkHighlightsVisible)
                XCTAssertNil(c.routeKeyDownEvent(try event(w))); XCTAssertFalse(c.isHyperlinkHighlightsVisible)
            }
            // Cmd+Shift+H belongs to Batch Link and intentionally opens a modal.
            XCTAssertNil(c.shortcutAction(for: try event(w, modifiers: [.command, .shift])))
            for modifiers: NSEvent.ModifierFlags in [[], .command, [.command, .option], flags.union(.control)] {
                let e = try event(w, modifiers: modifiers); XCTAssertTrue(c.routeKeyDownEvent(e) === e); XCTAssertFalse(c.isHyperlinkHighlightsVisible)
            }
            let delegate = AppDelegate(); delegate.setupMainMenu(controller: c)
            let toggle = try XCTUnwrap(items(NSApp.mainMenu!).first { $0.action == #selector(MainViewController.commandToggleHyperlinkHighlights(_:)) })
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30)); c.view.addSubview(text); XCTAssertTrue(w.makeFirstResponder(text))
            let editing = try event(w); XCTAssertTrue(c.routeKeyDownEvent(editing) === editing); XCTAssertFalse(c.validateMenuItem(toggle))
            XCTAssertTrue(w.makeFirstResponder(c.pdfView)); XCTAssertTrue(c.validateMenuItem(toggle))
            c.commandToggleHyperlinkHighlights(nil); _ = c.validateMenuItem(toggle); XCTAssertEqual(toggle.title, "Hide Hyperlinks")
            c.commandToggleHyperlinkHighlights(nil)
            w.routesAsKeyWindow = false
            let foreign = try event(w); XCTAssertTrue(c.routeKeyDownEvent(foreign) === foreign)
        }
    }
    func testSettingsRemapPersistenceResetAndAllOfferedModifierActions() throws {
        try isolated { c, w in
            let action = try XCTUnwrap(ShortcutAction(rawValue: "hyperlinks"))
            let modifier = try XCTUnwrap(ShortcutModifier(rawValue: "commandOptionShift"))
            UserDefaults.standard.set(["selectTool": "shift:x"], forKey: "DrawbridgeShortcutBindings"); c.loadShortcutBindings()
            let delegate = AppDelegate(); delegate.setupMainMenu(controller: c)
            let toggle = try XCTUnwrap(items(NSApp.mainMenu!).first { $0.action == #selector(MainViewController.commandToggleHyperlinkHighlights(_:)) })
            let settings = SettingsWindowController(editor: c); settings.prepare(section: .shortcuts); defer { settings.window?.close() }
            let all = views(settings.window!.contentView!)
            let field = try XCTUnwrap(all.first { $0.identifier?.rawValue == "shortcut.hyperlinks" } as? NSTextField)
            XCTAssertEqual(field.stringValue, "H")
            XCTAssertEqual(field.superview?.subviews.compactMap { $0 as? NSPopUpButton }.first?.titleOfSelectedItem, "Cmd+Option+Shift")
            field.stringValue = "j"
            try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "Save Shortcuts" }).performClick(nil)
            c.loadShortcutBindings(); XCTAssertEqual(c.currentShortcutBinding(for: action).encoded, "commandOptionShift:j")
            XCTAssertEqual(c.currentShortcutBinding(for: .selectTool).encoded, "shift:x"); XCTAssertEqual(toggle.keyEquivalent, "j")
            c.pdfView.document = fixture(); XCTAssertTrue(w.makeFirstResponder(c.pdfView))
            let old = try event(w); XCTAssertTrue(c.routeKeyDownEvent(old) === old)
            XCTAssertNil(c.routeKeyDownEvent(try event(w, key: "j"))); XCTAssertTrue(c.isHyperlinkHighlightsVisible)
            c.shortcutBindings[.invert] = ShortcutBinding(key: "i", modifier: modifier)
            XCTAssertNil(c.routeKeyDownEvent(try event(w, key: "i"))); XCTAssertTrue(c.pdfView.isColorInverted)
            c.shortcutBindings[.selectTool] = ShortcutBinding(key: "v", modifier: modifier); c.setTool(.rectangle)
            XCTAssertNil(c.routeKeyDownEvent(try event(w, key: "v"))); XCTAssertEqual(c.pdfView.toolMode, .select)
            try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "Restore Defaults" }).performClick(nil)
            c.loadShortcutBindings(); XCTAssertEqual(c.currentShortcutBinding(for: action).encoded, "commandOptionShift:h"); XCTAssertEqual(toggle.keyEquivalent, "h")
        }
    }
}
