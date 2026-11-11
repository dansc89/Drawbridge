import XCTest
import AppKit
import PDFKit
import ObjectiveC.runtime
@testable import Drawbridge

/// Serial AppKit regression. Only DRAWBRIDGE_PALETTE_NATIVE_DIR opts into an owned background window.
@MainActor final class PaletteLiveRefreshTests: XCTestCase {
    private func withIsolatedDefaults(_ body: () throws -> Void) throws {
        let name = "Drawbridge.PaletteLiveRefreshTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let getter = try XCTUnwrap(class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults")))
        let replacement: @convention(block) () -> UserDefaults = { defaults }
        let implementation = imp_implementationWithBlock(replacement)
        let original = method_setImplementation(getter, implementation)
        defer {
            method_setImplementation(getter, original)
            imp_removeBlock(implementation)
            defaults.removePersistentDomain(forName: name)
        }
        XCTAssertTrue(UserDefaults.standard === defaults)
        try body()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func assertColor(_ actual: CGColor?, _ expected: NSColor, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let actual, let rgb = NSColor(cgColor: actual)?.usingColorSpace(.sRGB),
              let expected = expected.usingColorSpace(.sRGB) else {
            XCTFail("Missing color: \(message)", file: file, line: line); return
        }
        XCTAssertEqual(rgb.redComponent, expected.redComponent, accuracy: 0.004, message, file: file, line: line)
        XCTAssertEqual(rgb.greenComponent, expected.greenComponent, accuracy: 0.004, message, file: file, line: line)
        XCTAssertEqual(rgb.blueComponent, expected.blueComponent, accuracy: 0.004, message, file: file, line: line)
    }

    private func drawnBackground(_ table: NSTableView) throws -> CGColor {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.magenta.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        table.effectiveAppearance.performAsCurrentDrawingAppearance {
            table.drawBackground(inClipRect: NSRect(x: 0, y: 0, width: 16, height: 16))
        }
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return NSColor(srgbRed: CGFloat(data[0]) / 255, green: CGFloat(data[1]) / 255,
                       blue: CGFloat(data[2]) / 255, alpha: 1).cgColor
    }

    func testCustomPaletteColorsAreImmutableSnapshotsAndReassignmentChangesValue() throws {
        try withIsolatedDefaults {
            let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
            InterfaceTheme.select(.nightOwlDark)
            let retained = [AppAppearance.chrome, AppAppearance.panel, AppAppearance.sidebar, AppAppearance.canvas]
            let roles = ["chrome", "panel", "sidebar", "canvas"]
            // Freeze numeric RGB before mutating preferences; never compare two live providers.
            var prior: [NSColor] = []
            appearance.performAsCurrentDrawingAppearance {
                prior = retained.map { $0.usingColorSpace(.sRGB)! }
            }
            InterfaceTheme.select(.absolutelyDark)
            appearance.performAsCurrentDrawingAppearance {
                let current = [AppAppearance.chrome, AppAppearance.panel, AppAppearance.sidebar, AppAppearance.canvas]
                for index in roles.indices {
                    assertColor(retained[index].cgColor, prior[index], "Retained custom snapshot must not mutate: \(roles[index])")
                    assertColor(current[index].cgColor, InterfaceTheme.absolutelyDark.color(for: roles[index])!, "New custom value")
                    XCTAssertFalse(retained[index].isEqual(current[index]), "Custom reassignment must change native setter value: \(roles[index])")
                }
            }
        }
    }

    /// WindowServer capture, not drawBackground/cacheDisplay. Never captures the desktop.
    private func capture(_ window: NSWindow, table: NSTableView, expected: NSColor, name: String, directory: String) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.18))
        let path = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: path)))
        let visible = table.visibleRect
        XCTAssertGreaterThan(visible.width, 20)
        XCTAssertGreaterThan(visible.height, 20)
        let point = table.convert(NSPoint(x: visible.midX, y: visible.maxY - 12), to: nil)
        let x = Int(point.x / window.frame.width * CGFloat(bitmap.pixelsWide))
        let y = Int((window.frame.height - point.y) / window.frame.height * CGFloat(bitmap.pixelsHigh))
        let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        let target = try XCTUnwrap(expected.usingColorSpace(.sRGB))
        for (actual, wanted) in zip([pixel.redComponent, pixel.greenComponent, pixel.blueComponent],
                                    [target.redComponent, target.greenComponent, target.blueComponent]) {
            XCTAssertEqual(actual, wanted, accuracy: 0.035, "Composited \(name) sample (\(x),\(y))")
        }
        print("PALETTE_COMPOSITOR \(name) window=\(window.windowNumber) sample=\(x),\(y) rgb=\(pixel) expected=\(target)")
    }

    func testSameSessionPaletteTransitionsRefreshAttachedAndDetachedNavigation() throws {
        try withIsolatedDefaults {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            InterfaceTheme.select(.nightOwlDark)
            let editor = MainViewController()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1420, height: 820),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.contentViewController = nil; window.close() }
            window.contentViewController = editor
            let nativeDirectory = ProcessInfo.processInfo.environment["DRAWBRIDGE_PALETTE_NATIVE_DIR"]
            if nativeDirectory != nil { window.orderBack(nil) }
            editor.viewDidAppear()
            let navigation = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? NSSegmentedControl }
                .first { $0.segmentCount == 2 && $0.label(forSegment: 0) == "Pages" })
            let pagesScroll = try XCTUnwrap(editor.pagesTableView.enclosingScrollView)
            let bookmarksScroll = try XCTUnwrap(editor.bookmarksOutlineView.enclosingScrollView)
            let document = PDFDocument()
            let page = PDFPage()
            let annotation = PDFAnnotation(bounds: NSRect(x: 10, y: 10, width: 30, height: 30), forType: .square, withProperties: nil)
            annotation.color = .systemRed
            annotation.interiorColor = .systemYellow
            page.addAnnotation(annotation)
            document.insert(page, at: 0)
            editor.pdfView.document = document
            let rootAppearance = editor.view.appearance
            let stroke = annotation.color, fill = annotation.interiorColor
            let pageBounds = page.bounds(for: .mediaBox)

            // Repeat same-native-appearance palettes as well as light/dark/native.
            for (index, theme) in [InterfaceTheme.nightOwlDark, .absolutelyDark, .codexDark,
                                    .nightOwlDark, .absolutelyLight, .system, .nightOwlDark,
                                    .absolutelyDark, .system].enumerated() {
                navigation.selectedSegment = index % 2
                XCTAssertTrue(NSApp.sendAction(navigation.action!, to: navigation.target, from: navigation))
                // NSStackView detaches hidden arranged subviews by default.
                let hidden = navigation.selectedSegment == 0 ? bookmarksScroll : pagesScroll
                XCTAssertTrue(hidden.isHidden)
                // needsDisplay is not an oracle on a never-ordered/detached native view.
                InterfaceTheme.select(theme)
                let native = NSAppearance(named: index % 2 == 0 ? .aqua : .darkAqua)!
                if theme == .system {
                    // Native fallback must remain dynamic after custom colors are cleared.
                    window.appearance = native
                    editor.view.viewDidChangeEffectiveAppearance()
                }
                editor.view.layoutSubtreeIfNeeded()
                let pagesPixels = try drawnBackground(editor.pagesTableView)
                let bookmarkPixels = try drawnBackground(editor.bookmarksOutlineView)
                let appearance = theme.nativeAppearance ?? window.effectiveAppearance
                appearance.performAsCurrentDrawingAppearance {
                    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    let sidebar = theme.color(for: "sidebar") ?? NSColor(calibratedWhite: dark ? 0.14 : 0.94, alpha: 1)
                    let panel = theme.color(for: "panel") ?? NSColor(calibratedWhite: dark ? 0.12 : 0.98, alpha: 1)
                    let canvas = theme.color(for: "canvas") ?? NSColor(calibratedWhite: dark ? 0.07 : 0.82, alpha: 1)
                    if pagesScroll.contentView.drawsBackground {
                        assertColor(pagesScroll.contentView.backgroundColor.cgColor, sidebar, "Pages clip \(theme)")
                    }
                    if bookmarksScroll.contentView.drawsBackground {
                        assertColor(bookmarksScroll.contentView.backgroundColor.cgColor, sidebar, "Bookmarks clip \(theme)")
                    }
                    assertColor(pagesPixels, sidebar, "Drawn Pages \(theme)")
                    assertColor(bookmarkPixels, sidebar, "Drawn Bookmarks \(theme)")
                    assertColor(editor.pagesTableView.backgroundColor.cgColor, sidebar, "Pages \(theme)")
                    assertColor(editor.bookmarksOutlineView.backgroundColor.cgColor, sidebar, "Bookmarks \(theme)")
                    assertColor(editor.statusBar.layer?.backgroundColor, panel, "Panel \(theme)")
                    assertColor(editor.pdfView.backgroundColor.cgColor, canvas, "Canvas surround \(theme)")
                }
                XCTAssertEqual(editor.pagesTableView.effectiveAppearance.name, appearance.name)
                XCTAssertEqual(editor.bookmarksOutlineView.effectiveAppearance.name, appearance.name)
                XCTAssertFalse(pagesScroll.drawsBackground)
                XCTAssertFalse(bookmarksScroll.drawsBackground)
                if let nativeDirectory {
                    let appearance = theme.nativeAppearance ?? window.effectiveAppearance
                    var expected = NSColor.black
                    appearance.performAsCurrentDrawingAppearance {
                        expected = AppAppearance.sidebar.usingColorSpace(.sRGB)!
                    }
                    // Capture the retained visible tab before reopening the other tab.
                    try capture(window, table: navigation.selectedSegment == 0 ? editor.pagesTableView : editor.bookmarksOutlineView,
                                expected: expected, name: "\(index)-\(theme.rawValue)-visible", directory: nativeDirectory)
                }
                // Restore the other tab without changing palette or recreating controller.
                navigation.selectedSegment = 1 - navigation.selectedSegment
                XCTAssertTrue(NSApp.sendAction(navigation.action!, to: navigation.target, from: navigation))
                if let nativeDirectory {
                    var expected = NSColor.black
                    (theme.nativeAppearance ?? window.effectiveAppearance).performAsCurrentDrawingAppearance {
                        expected = AppAppearance.sidebar.usingColorSpace(.sRGB)!
                    }
                    try capture(window, table: navigation.selectedSegment == 0 ? editor.pagesTableView : editor.bookmarksOutlineView,
                                expected: expected, name: "\(index)-\(theme.rawValue)-tab-reopened", directory: nativeDirectory)
                    if index == 3 {
                        window.orderOut(nil)
                        XCTAssertFalse(window.isVisible)
                        window.orderBack(nil)
                        try capture(window, table: navigation.selectedSegment == 0 ? editor.pagesTableView : editor.bookmarksOutlineView,
                                    expected: expected, name: "\(index)-window-reopened", directory: nativeDirectory)
                    }
                }
                XCTAssertEqual(editor.view.appearance, rootAppearance)
                XCTAssertNil(editor.pdfView.appearance)
                XCTAssertTrue(editor.pdfView.document === document)
                XCTAssertTrue(document.page(at: 0) === page)
                XCTAssertEqual(page.bounds(for: .mediaBox), pageBounds)
                XCTAssertEqual(annotation.color, stroke)
                XCTAssertEqual(annotation.interiorColor, fill)
                XCTAssertEqual(window.isVisible, nativeDirectory != nil)
            }
        }
    }
}
