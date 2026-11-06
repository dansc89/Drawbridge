import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class CopiedMarkupPersistenceTests: XCTestCase {
    private func fixture() throws -> (URL, URL, PDFDocument, PDFPage) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CopiedPersistence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.pdf")
        let document = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 400), for: .mediaBox)
        document.insert(page, at: 0)
        XCTAssertTrue(document.write(to: source))
        return (root, source, document, page)
    }
    func testFreshForeignFilledShapesRetainFillThroughSaveAndRegeneration() throws {
        for type in [PDFAnnotationSubtype.square, .circle] {
            let (root, source, document, page) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let sourceBytes = try Data(contentsOf: source)
            let foreign = PDFAnnotation(bounds: CGRect(x: 60, y: 60, width: 100, height: 70), forType: type, withProperties: nil)
            foreign.color = .red; foreign.interiorColor = .yellow
            let record = try XCTUnwrap(MarkupClipboard.capture(foreign))
            XCTAssertEqual(record.fill, [1, 1, 0], "Fresh foreign interiorColor must enter the copied record")
            XCTAssertFalse(RectangleMarkupRecord.owns(foreign))
            XCTAssertNil(foreign.value(forAnnotationKey: RectangleMarkupRecord.fillKey))
            let copy = try record.clipboardAnnotation(contents: nil); page.addAnnotation(copy)
            var live = document, input = source
            for pass in 0..<2 {
                let output = root.appendingPathComponent("saved-\(pass).pdf")
                XCTAssertTrue(PDFRectangleWriter.write(document: live, source: input, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(live)))
                live = try XCTUnwrap(PDFDocument(url: output)); input = output
                let saved = try XCTUnwrap(live.page(at: 0)?.annotations.first(where: RectangleMarkupRecord.owns))
                XCTAssertEqual(RectangleMarkupRecord.capture(annotation: saved, pageIndex: 0)?.fill, [1, 1, 0])
                let fill = try XCTUnwrap(saved.interiorColor?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(fill.redComponent, 1, accuracy: 0.001)
                XCTAssertEqual(fill.greenComponent, 1, accuracy: 0.001)
                XCTAssertEqual(fill.blueComponent, 0, accuracy: 0.001)
                if pass == 0 {
                    let view = MarkupPDFView(); view.setMarkupDocument(live)
                    let session = view.rectangleMarkup; session.canEdit = { true }; session.setSelectedItems([saved])
                    // A stroke-only edit regenerates the appearance without a fill edit.
                    session.styleSelected(color: .blue, width: 4)
                    XCTAssertEqual(saved.border?.lineWidth, 4)
                } else {
                    XCTAssertEqual(saved.border?.lineWidth, 4)
                    XCTAssertEqual(saved.color.usingColorSpace(.deviceRGB)?.blueComponent, 1)
                }
            }
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        }
    }
    func testCopiedFreeTextLayoutMetadataSurvivesReopenAndSecondEdit() throws {
        for alignment in [NSTextAlignment.center, .right] {
            let (root, source, document, page) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let sourceBytes = try Data(contentsOf: source)
            page.rotation = 90
            let foreign = PDFAnnotation(bounds: CGRect(x: 60, y: 60, width: 160, height: 100), forType: .freeText, withProperties: nil)
            foreign.contents = "Consultant text"; foreign.font = NSFont.systemFont(ofSize: 13)
            foreign.alignment = alignment
            foreign.setValue(270, forAnnotationKey: .init(rawValue: "/Rotate"))
            foreign.setValue([3, 5, 7, 9], forAnnotationKey: .init(rawValue: "/RD"))
            let copy = try XCTUnwrap(MarkupClipboard.capture(foreign)).clipboardAnnotation(contents: foreign.contents)
            page.addAnnotation(copy)
            var live = document, input = source
            for pass in 0..<2 {
                let output = root.appendingPathComponent("text-\(pass).pdf")
                XCTAssertTrue(PDFRectangleWriter.write(document: live, source: input, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(live)))
                live = try XCTUnwrap(PDFDocument(url: output)); input = output
                let saved = try XCTUnwrap(live.page(at: 0)?.annotations.first(where: RectangleMarkupRecord.owns))
                XCTAssertEqual(saved.alignment, alignment)
                XCTAssertEqual((saved.value(forAnnotationKey: .init(rawValue: "/Rotate")) as? NSNumber)?.intValue, 270)
                XCTAssertEqual((saved.value(forAnnotationKey: .init(rawValue: "/RD")) as? [NSNumber])?.map(\.doubleValue), [3, 5, 7, 9])
                if pass == 0 {
                    let view = MarkupPDFView(); view.setMarkupDocument(live)
                    let session = view.rectangleMarkup; session.canEdit = { true }; session.setSelectedItems([saved])
                    session.editSelectedText("Consultant reviewed", size: 13)
                } else { XCTAssertEqual(saved.contents, "Consultant reviewed") }
            }
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
            XCTAssertFalse(RectangleMarkupRecord.owns(foreign))
        }
    }
}
