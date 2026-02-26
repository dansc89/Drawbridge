import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

final class PDFPageLabelsEmbedderTests: XCTestCase {
    func testEmbedPageLabelsWritesCatalogEntryAndReloadsLabels() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drawbridge-page-label-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let pageImage = NSImage(size: NSSize(width: 320, height: 240))
        pageImage.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 240)).fill()
        pageImage.unlockFocus()

        let document = PDFDocument()
        for _ in 0..<3 {
            guard let page = PDFPage(image: pageImage) else {
                XCTFail("Failed to create test page")
                return
            }
            document.insert(page, at: document.pageCount)
        }
        XCTAssertTrue(document.write(to: tempURL, withOptions: nil))

        try PDFPageLabelsEmbedder.embedPageLabels(
            [0: "A100 - Cover", 1: "A101 - Plan", 2: "A102 - Sections"],
            in: tempURL
        )

        let bytes = try Data(contentsOf: tempURL)
        let text = String(data: bytes, encoding: .isoLatin1)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("/PageLabels") ?? false)
        XCTAssertTrue(text?.contains("/Nums") ?? false)

        guard let reloaded = PDFDocument(url: tempURL) else {
            XCTFail("Failed to reload document")
            return
        }
        XCTAssertEqual(reloaded.page(at: 0)?.label, "A100 - Cover")
        XCTAssertEqual(reloaded.page(at: 1)?.label, "A101 - Plan")
        XCTAssertEqual(reloaded.page(at: 2)?.label, "A102 - Sections")
    }
}
