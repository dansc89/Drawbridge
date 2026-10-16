import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class HatchPDFNumberTests: XCTestCase {
    func testHatchAppearanceUsesPDFDecimalNumbers() {
        let exponent = #"(?<![A-Za-z])[+-]?(?:\d+\.?\d*|\.\d+)[eE][+-]?\d+"#
        for preset in DraftingHatch.Preset.allCases where preset != .solid {
            let style = DraftingHatch(preset: preset, foreground: [1e-8, 0, 1], background: [1, 1e-8, 0], scale: 1, angle: 90, lineWidth: 0.5)
            let appearance = style.pdf(path: "0 0 144 144 re", size: CGSize(width: 144, height: 144))
            XCTAssertNil(appearance.range(of: exponent, options: .regularExpression), "PDF numbers forbid scientific notation: \(preset)")
        }
    }

    func testSavedPDFRetainsLowerBoundaryHatchBandAtQuarterTurn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = CGRect(x: 0, y: 0, width: 168, height: 168)
        let source = root.appendingPathComponent("source.pdf")
        let blank = PDFDocument(); let blankPage = PDFPage(); blankPage.setBounds(box, for: .mediaBox); blank.insert(blankPage, at: 0)
        XCTAssertTrue(blank.write(to: source))
        func lowerBand(_ draw: (CGContext) -> Void) throws -> Int {
            let c = try XCTUnwrap(CGContext(data: nil, width: 504, height: 504, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(x: 0, y: 0, width: 504, height: 504)); c.scaleBy(x: 3, y: 3); draw(c)
            let bytes = try XCTUnwrap(c.data).assumingMemoryBound(to: UInt8.self)
            var blue = 0
            for y in 438..<459 { for x in 60..<444 {
                let i = y * c.bytesPerRow + x * 4
                if Int(bytes[i+2]) > Int(bytes[i]) + 38 && Int(bytes[i+2]) > Int(bytes[i+1]) + 38 { blue += 1 }
            } }
            return blue
        }
        for preset in [DraftingHatch.Preset.insulation, .wood, .expandedMetal] {
            let a = DrawbridgeShapeAnnotation(bounds: CGRect(x: 12, y: 12, width: 144, height: 144), forType: .square, withProperties: nil)
            a.setValue(RectangleMarkupRecord.prefix + UUID().uuidString, forAnnotationKey: RectangleMarkupRecord.identityKey)
            a.color = .red; let border = PDFBorder(); border.lineWidth = 1; a.border = border
            DraftingHatch.apply(DraftingHatch(preset: preset, foreground: [0,0,1], scale: 1, angle: 90, lineWidth: 0.5), to: a)
            let doc = PDFDocument(); let page = PDFPage(); page.setBounds(box, for: .mediaBox); doc.insert(page, at: 0); page.addAnnotation(a)
            let record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: a, pageIndex: 0))
            let output = root.appendingPathComponent(preset.rawValue + ".pdf")
            XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: output, pageLabels: [:], records: [record]))
            let saved = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
            let liveCount = try lowerBand { a.draw(with: .mediaBox, in: $0) }
            let pdfCount = try lowerBand { saved.draw(with: .mediaBox, to: $0) }
            XCTAssertGreaterThan(liveCount, 20, "Boundary fixture must contain visible hatch: \(preset)")
            XCTAssertGreaterThan(Double(pdfCount), Double(liveCount) * 0.7, "Saved lower band missing: \(preset), live=\(liveCount), PDF=\(pdfCount)")
            XCTAssertLessThan(Double(pdfCount), Double(liveCount) * 1.3, "Saved lower band overdraw: \(preset)")
        }
    }
}
