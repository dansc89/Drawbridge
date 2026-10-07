import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class SystemAppearanceTests: XCTestCase {
    func testInterfaceFollowsInheritedAppearanceAndRefreshesLayerColors() throws {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        XCTAssertNil(controller.view.appearance)
        let root = try XCTUnwrap(controller.view as? StartupDropView)
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))

        // Simulate system inheritance at the window, without changing the user's settings.
        for (appearance, expected) in [(light, 0.91), (dark, 0.08), (light, 0.91)] {
            window.appearance = appearance
            let color = try XCTUnwrap(root.layer?.backgroundColor)
            let rgb = try XCTUnwrap(NSColor(cgColor: color)?.usingColorSpace(.genericRGB))
            XCTAssertEqual(rgb.redComponent, expected, accuracy: 0.01)
            XCTAssertNil(controller.pdfView.appearance)
            appearance.performAsCurrentDrawingAppearance {
                let canvas = controller.pdfView.backgroundColor.usingColorSpace(.genericRGB)!
                XCTAssertEqual(canvas.redComponent, expected > 0.5 ? 0.82 : 0.07, accuracy: 0.01)
            }
        }
    }
}
