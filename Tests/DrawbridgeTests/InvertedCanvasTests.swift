import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class InvertedCanvasTests: XCTestCase {
    func testInvertRemovesPageGlowAndRestoresNormalShadowPreference() throws {
        _ = NSApplication.shared
        let view = MarkupPDFView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let document = PDFDocument(); let page = PDFPage(); document.insert(page, at: 0)
        let annotation = PDFAnnotation(bounds: NSRect(x: 10, y: 10, width: 30, height: 30), forType: .square, withProperties: nil)
        annotation.color = .red; page.addAnnotation(annotation); view.document = document
        for originalShadows in [true, false, true] {
            view.pageShadowsEnabled = originalShadows
            view.setColorInverted(true)
            XCTAssertFalse(view.pageShadowsEnabled, "A normal black page shadow must not invert into a white glow")
            XCTAssertEqual(view.contentFilters.count, 1)
            let gray = try XCTUnwrap(view.backgroundColor.usingColorSpace(.sRGB))
            XCTAssertEqual(gray.redComponent, 0.98, accuracy: 0.001, "Inversion needs a neutral charcoal surround")
            XCTAssertEqual(gray.greenComponent, gray.redComponent, accuracy: 0.001)
            XCTAssertEqual(gray.blueComponent, gray.redComponent, accuracy: 0.001)
            view.setColorInverted(true) // Repeated enable must not replace the saved normal setting.
            view.refreshAppearanceColors()
            XCTAssertFalse(view.pageShadowsEnabled)
            XCTAssertTrue(view.document === document)
            XCTAssertEqual(annotation.color, .red)
            view.setColorInverted(false)
            XCTAssertEqual(view.pageShadowsEnabled, originalShadows)
            XCTAssertTrue(view.contentFilters.isEmpty)
        }
    }
}
