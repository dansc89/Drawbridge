import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class FullscreenToolbarThemeTests: XCTestCase {
    func testReparentedToolbarUsesEveryThemeWithoutRethemingPDFWindow() throws {
        _ = NSApplication.shared
        let old = UserDefaults.standard.object(forKey: InterfaceTheme.defaultsKey)
        defer {
            if let old { UserDefaults.standard.set(old, forKey: InterfaceTheme.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: InterfaceTheme.defaultsKey) }
        }
        let editor = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1500,height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = editor
        let toolbar = editor.makeToolbar(); window.toolbar = toolbar
        editor.viewDidAppear()
        let inherited = window.appearance
        let page = PDFPage(); let document = PDFDocument(); document.insert(page, at: 0)
        editor.pdfView.document = document
        let annotation = PDFAnnotation(bounds: NSRect(x: 10,y: 10,width: 30,height: 30), forType: .square, withProperties: nil)
        annotation.color = .red; page.addAnnotation(annotation)
        let primary = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == .drawbridgePrimaryControls }?.view)
        // AppKit reparents toolbar views into a separate fullscreen host window.
        let host = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1500,height: 45), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { host.contentView?.subviews.forEach { $0.removeFromSuperview() }; window.contentViewController = nil }
        let markup = editor.rectangleToolbar
        for controls in [primary, markup] {
            InterfaceTheme.select(.nightOwlDark)
            host.appearance = nil; host.backgroundColor = .white
            controls.removeFromSuperview(); host.contentView?.addSubview(controls)
            XCTAssertEqual(host.appearance?.name, NSAppearance.Name.darkAqua, "Reparenting must immediately theme the host")
            for theme in InterfaceTheme.presets + [.system] {
                InterfaceTheme.select(theme)
                XCTAssertEqual(host.appearance?.name, theme.nativeAppearance?.name, "\(theme)")
                if let color = theme.color(for: "chrome") {
                    XCTAssertEqual(host.backgroundColor.usingColorSpace(.sRGB), color.usingColorSpace(.sRGB), "\(theme)")
                }
                XCTAssertEqual(window.appearance, inherited)
                XCTAssertNil(editor.view.appearance)
                XCTAssertNil(editor.pdfView.appearance)
                XCTAssertTrue(editor.pdfView.document === document)
                XCTAssertEqual(annotation.color, .red)
                for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                    window.backgroundColor = .white
                    NotificationCenter.default.post(name: name, object: window)
                    if let color = theme.color(for: "chrome") {
                        XCTAssertEqual(window.backgroundColor.usingColorSpace(.sRGB), color.usingColorSpace(.sRGB))
                    }
                    XCTAssertEqual(window.appearance, inherited)
                    XCTAssertNil(editor.pdfView.appearance)
                }
            }
            controls.removeFromSuperview()
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1500, height: 40))
        host.contentView?.addSubview(container)
        container.addSubview(primary); container.addSubview(markup)
        for theme in InterfaceTheme.presets {
            InterfaceTheme.select(theme)
            let backing = try XCTUnwrap(container.subviews.compactMap { $0 as? ToolbarThemeBackgroundView }.first)
            XCTAssertEqual(backing.frame, container.bounds, "Backdrop must fill the toolbar, including the gaps")
            XCTAssertEqual(NSColor(cgColor: try XCTUnwrap(backing.layer?.backgroundColor))?.usingColorSpace(.sRGB), theme.color(for: "chrome")?.usingColorSpace(.sRGB))
            XCTAssertNil(backing.hitTest(NSPoint(x: 10, y: 10)), "Backdrop must not intercept toolbar clicks")
            XCTAssertFalse(editor.view.isDescendant(of: backing))
        }
        InterfaceTheme.select(.system)
        XCTAssertFalse(container.subviews.contains { $0 is ToolbarThemeBackgroundView })
    }
}
