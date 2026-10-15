import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class SplitChromeReadabilityTests: XCTestCase {
    private func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
    private func fixture() throws -> URL {
        let d = PDFDocument(); d.insert(PDFPage(), at: 0)
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("Chrome-\(UUID().uuidString).pdf")
        try XCTUnwrap(d.dataRepresentation()).write(to: u)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }
    private func controller() -> (MainViewController, NSWindow) {
        _ = NSApplication.shared
        let old = UserDefaults.standard.object(forKey: InterfaceTheme.defaultsKey)
        addTeardownBlock {
            if let old { UserDefaults.standard.set(old, forKey: InterfaceTheme.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: InterfaceTheme.defaultsKey) }
        }
        let c = MainViewController()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.contentViewController = c; w.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            XCTAssertFalse(w.isVisible)
            w.makeFirstResponder(nil); w.contentViewController = nil
        }
        return (c, w)
    }
    // Independently calculate WCAG contrast, including alpha compositing.
    private func contrast(_ foreground: NSColor, _ background: NSColor, appearance: NSAppearance) -> CGFloat {
        var result: CGFloat = 0
        appearance.performAsCurrentDrawingAppearance {
            let b = background.usingColorSpace(.sRGB)!, f = foreground.usingColorSpace(.sRGB)!
            let bg = [b.redComponent, b.greenComponent, b.blueComponent]
            let fg = zip([f.redComponent, f.greenComponent, f.blueComponent], bg).map { $0 * f.alphaComponent + $1 * (1 - f.alphaComponent) }
            func luminance(_ v: [CGFloat]) -> CGFloat {
                let s = v.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
                return s[0] * 0.2126 + s[1] * 0.7152 + s[2] * 0.0722
            }
            let a = luminance(fg), z = luminance(bg)
            result = (max(a,z) + 0.05) / (min(a,z) + 0.05)
        }
        return result
    }
    func testPaneTextContrastAcrossEveryThemeActivationAndRebuild() throws {
        let (c,w) = controller(); c.openDocument(at: try fixture())
        let document = try XCTUnwrap(c.pdfView.document)
        let annotation = PDFAnnotation(bounds: NSRect(x: 1,y: 1,width: 20,height: 20), forType: .square, withProperties: nil)
        annotation.color = .red; document.page(at: 0)!.addAnnotation(annotation)
        let pdfBackgroundAppearance = c.pdfView.appearance
        c.commandToggleSplitView(nil)
        for native in [NSAppearance.Name.aqua, .darkAqua] {
            w.appearance = NSAppearance(named: native)
            for theme in InterfaceTheme.presets + [.system] {
                InterfaceTheme.select(theme)
                for _ in 0..<2 {
                    for pane in c.pdfPaneSplitView.arrangedSubviews.compactMap({ $0 as? PDFPaneContainerView }) {
                        let bg = try XCTUnwrap(pane.header.layer?.backgroundColor).copy(alpha: 1)!
                        let background = NSColor(cgColor: bg)!
                        for label in [pane.titleLabel, pane.modeLabel] {
                            XCTAssertGreaterThanOrEqual(contrast(try XCTUnwrap(label.textColor), background, appearance: pane.header.effectiveAppearance), 4.5, "\(native) \(theme) \(label.stringValue)")
                        }
                        if let panel = theme.color(for: "panel"), pane.pdfView !== c.pdfView {
                            XCTAssertEqual(background.usingColorSpace(.sRGB), panel.usingColorSpace(.sRGB), "Inactive header retains palette")
                        }
                    }
                    XCTAssertEqual(c.pdfView.layer?.borderWidth, 2)
                    XCTAssertEqual(c.secondaryPDFView?.layer?.borderWidth, 0)
                    c.activatePDFPane(try XCTUnwrap(c.secondaryPDFView))
                }
                c.collapsePDFSplit(); c.commandToggleSplitView(nil)
                XCTAssertTrue(c.pdfView.document === document)
                XCTAssertEqual(c.pdfView.appearance, pdfBackgroundAppearance)
                XCTAssertNil(c.secondaryPDFView?.appearance)
                XCTAssertEqual(annotation.color, .red)
            }
        }
        c.commandCloseDocument(nil)
    }
    func testDocumentTabTitlesHaveContrastAfterThemeSwitchAndRebuild() throws {
        let (c,w) = controller(); let a = try fixture(), b = try fixture()
        c.openDocument(at: a); c.openDocument(at: b)
        for native in [NSAppearance.Name.aqua, .darkAqua] {
            w.appearance = NSAppearance(named: native)
            for theme in InterfaceTheme.presets + [.system] {
                InterfaceTheme.select(theme)
                for url in [a,b] {
                    c.openDocument(at: url)
                    let tabs = descendants(c.view).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue == a.path || $0.identifier?.rawValue == b.path }
                    XCTAssertEqual(tabs.count, 2)
                    for tab in tabs {
                        let bg = try XCTUnwrap(tab.layer?.backgroundColor, "Tab needs a deterministic chrome background")
                        let fg = try XCTUnwrap(tab.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
                        XCTAssertGreaterThanOrEqual(contrast(fg, NSColor(cgColor: bg)!, appearance: tab.effectiveAppearance), 4.5, "\(theme) \(tab.state)")
                    }
                }
            }
        }
        c.commandCloseDocument(nil); c.commandCloseDocument(nil)
    }
    func testWelcomeCentersInSurvivingCanvasAcrossSplitCloseResizeAndSidebar() throws {
        let (c,w) = controller(); let url = try fixture()
        func assertCentered() throws {
            w.layoutIfNeeded(); c.view.layoutSubtreeIfNeeded()
            let title = try XCTUnwrap(descendants(c.view).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Open a drawing set to get started" })
            let panel = try XCTUnwrap(title.superview?.superview)
            XCTAssertFalse(panel.isHidden)
            let canvas = c.pdfPaneSplitView.convert(c.pdfPaneSplitView.bounds, to: c.view)
            let frame = panel.convert(panel.bounds, to: c.view)
            XCTAssertGreaterThan(canvas.width, 600)
            XCTAssertEqual(frame.midX, canvas.midX, accuracy: 0.5)
            XCTAssertEqual(frame.midY, canvas.midY, accuracy: 0.5)
            for name in ["Open Existing PDF", "Open Recent", "Merge PDFs…"] {
                let button = try XCTUnwrap(descendants(panel).compactMap { $0 as? NSButton }.first { $0.title == name })
                XCTAssertTrue(frame.contains(button.convert(button.bounds, to: c.view)))
            }
        }
        try assertCentered()
        for cycle in 0..<4 {
            c.openDocument(at: url); c.commandToggleSplitView(nil)
            if cycle % 2 == 1 { c.activatePDFPane(try XCTUnwrap(c.secondaryPDFView)) }
            c.commandCloseDocument(nil)
            try assertCentered()
            w.setContentSize(NSSize(width: cycle % 2 == 0 ? 1300 : 1800, height: 900))
            try assertCentered()
            c.commandToggleSidebar(nil)
            try assertCentered()
        }
    }
}
