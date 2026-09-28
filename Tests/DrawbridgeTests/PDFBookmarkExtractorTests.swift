import AppKit
import CoreText
import PDFKit
import XCTest
@testable import Drawbridge

final class PDFBookmarkExtractorTests: XCTestCase {
    func testPageLabelOrdinalPrefixIsNotTreatedAsSheetTitle() {
        XCTAssertEqual(
            PDFBookmarkExtractor.removingPageLabelOrdinalPrefix("[3] -Planting Details"),
            "Planting Details"
        )
        XCTAssertEqual(
            PDFBookmarkExtractor.removingPageLabelOrdinalPrefix("[ 12 ] — FLOOR PLAN"),
            "FLOOR PLAN"
        )
    }

    func testEquivalentPageLabelHintPreservesRecognizedTitleCapitalization() {
        let original = PDFBookmarkExtractor.Result(
            text: "PLANTING DETAILS",
            source: "OCR disagreement",
            alternatives: ["PLANTING DETAIL"]
        )
        let resolved = PDFBookmarkExtractor.resolveTitles(
            [original],
            labelHints: ["Planting Details"]
        )
        XCTAssertEqual(resolved[0].text, "PLANTING DETAILS")
        XCTAssertEqual(resolved[0].source, "OCR disagreement")
    }
    private func document() throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 3600, height: 2400)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        for (text, x, y, size) in [("A1.02", 3200.0, 100.0, 30.0), ("FLOOR PLAN", 3200, 200, 24), ("AND NOTES", 3200, 170, 14), ("OLD TITLE", 2700, 200, 24), ("NEW TITLE", 2700, 200, 24)] {
            context.textPosition = CGPoint(x: x, y: y)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)]))
            CTLineDraw(line, context)
        }
        context.endPDFPage(); context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    func testSavedBookmarksPreserveDuplicatesMissingTitlesAndPageOrder() throws {
        let d = try document()
        let second = try XCTUnwrap(try document().page(at: 0)?.copy() as? PDFPage)
        d.insert(second, at: 1)
        d.outlineRoot = PDFBookmarkExtractor.outline(document: d,
            sheets: [(0, "A101", "PLAN"), (1, "A101", "")],
            destination: { PDFDestination(page: $0, at: CGPoint(x: 0, y: 2400)) })
        let reloaded = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(d.dataRepresentation())))
        let root = try XCTUnwrap(reloaded.outlineRoot)
        XCTAssertEqual(root.numberOfChildren, 2)
        XCTAssertEqual(root.child(at: 0)?.label, "A101 - PLAN")
        XCTAssertEqual(root.child(at: 1)?.label, "A101 - Untitled")
        for index in 0..<2 {
            let target = try XCTUnwrap(root.child(at: index)?.destination?.page)
            XCTAssertEqual(reloaded.index(for: target), index)
        }
    }

    @MainActor
    func testReviewRetainsUserCorrections() {
        let view = BookmarkReviewView(rows: [.init(number: "MO.10", title: "PLAN", note: "OCR disagreement")])
        let table = NSTableView()
        view.tableView(table, setObjectValue: " M0.10 ", for: NSTableColumn(identifier: .init("Sheet number")), row: 0)
        view.tableView(table, setObjectValue: "ROOF PLAN", for: NSTableColumn(identifier: .init("Sheet title")), row: 0)
        XCTAssertEqual(view.rows[0].number, "M0.10")
        XCTAssertEqual(view.rows[0].title, "ROOF PLAN")
        XCTAssertEqual(view.rows[0].note, "OCR disagreement")
    }

    func testOCRLinesDoNotMergeUnrelatedCaptionIntoIdentifier() {
        XCTAssertEqual(PDFBookmarkExtractor.recognizedValue(["SHEET NO", "E1.00"], field: .number), "E1.00")
        XCTAssertEqual(PDFBookmarkExtractor.recognizedValue(["NG", "E1.00"], field: .number), "E1.00")
        XCTAssertEqual(PDFBookmarkExtractor.recognizedValue(["A", "101"], field: .number), "A101")
        XCTAssertNil(PDFBookmarkExtractor.recognizedValue(["A101", "A102"], field: .number))
        XCTAssertEqual(PDFBookmarkExtractor.preferredTitleReading(["DIAGRAM - I|", "DIAGRAM - Il", "DIAGRAM - II"]), "DIAGRAM - II")
        XCTAssertEqual(PDFBookmarkExtractor.preferredTitleReading(["DIAGRAM - I|", "DIAGRAM - III"]), "DIAGRAM - I|")
        XCTAssertEqual(PDFBookmarkExtractor.preferredTitleReading(["PLAN | SECTION", "PLAN I SECTION"]), "PLAN | SECTION")
    }

    func testRepeatedTitleCanResolveToAnActuallyObservedAlternative() {
        typealias R = PDFBookmarkExtractor.Result
        let rows = PDFBookmarkExtractor.resolveTitles([
            R(text: "MECHANICAL TLE 24 FORMS", source: "OCR disagreement", alternatives: ["MECHANICAL TITLE 24 FORMS"]),
            R(text: "MECHANICAL TITLE 24 FORMS", source: "OCR"),
            R(text: "MECHANICAL TITLE 24 FORMS", source: "OCR")
        ])
        XCTAssertEqual(rows[0].text, "MECHANICAL TITLE 24 FORMS")
        XCTAssertEqual(rows[0].alternatives, ["MECHANICAL TLE 24 FORMS"])
        XCTAssertEqual(PDFBookmarkExtractor.resolveTitles([
            R(text: "UNIQUE TLE", source: "OCR disagreement", alternatives: ["UNIQUE TITLE"])
        ])[0].text, "UNIQUE TLE")
    }

    func testCloseTitleLabelCanDisambiguateOCRButNotNativeOrDifferentText() {
        typealias R = PDFBookmarkExtractor.Result
        XCTAssertEqual(PDFBookmarkExtractor.resolveTitles([
            R(text: "MICUNANIVAL NOTES SYMBOLS LEGEND", source: "OCR disagreement", alternatives: ["MCUNANIVAL NOTES SYMBOLS LEGEND"])
        ], labelHints: ["MECHANICAL NOTES SYMBOLS LEGEND"])[0].text,
        "MECHANICAL NOTES SYMBOLS LEGEND")
        XCTAssertEqual(PDFBookmarkExtractor.resolveTitles([
            R(text: "ROOF PLAN", source: "OCR disagreement", alternatives: ["ROOF PLA"])
        ], labelHints: ["FLOOR PLAN"])[0].text, "ROOF PLAN")
        XCTAssertEqual(PDFBookmarkExtractor.resolveTitles([
            R(text: "VISIBLE TITLE", source: "PDF text", alternatives: ["OLD TITLE"])
        ], labelHints: ["OLD TITLE"])[0].text, "VISIBLE TITLE")
        XCTAssertEqual(PDFBookmarkExtractor.resolveTitles([
            R(text: "MECHANICAL DETAILS", source: "OCR", alternatives: []),
            R(text: "NILVIINIVNL DETAILS", source: "OCR disagreement", alternatives: ["IVIL DETAILS"])
        ], labelHints: ["MECHANICAL DETAILS", "MECHANICAL DETAILS"])[1].text,
        "MECHANICAL DETAILS")
    }

    func testOCRCandidateAlternativesParticipateInPeerResolution() {
        typealias R = PDFBookmarkExtractor.Result
        let rows = PDFBookmarkExtractor.resolveTitles([
            R(text: "SEVENTH FLOOF PLAN", source: "OCR candidates", alternatives: ["SEVENTH FLOOR PLAN"]),
            R(text: "FIRST FLOOR PLAN", source: "OCR"),
            R(text: "SECOND FLOOR PLAN", source: "OCR")
        ])
        // Exact whole-title support is required; a shared word alone must not rewrite a field.
        XCTAssertEqual(rows[0].text, "SEVENTH FLOOF PLAN")
        XCTAssertEqual(rows[0].alternatives, ["SEVENTH FLOOR PLAN"])
    }

    func testAdaptiveNumberSearchReportsVerticalOffset() throws {
        let d = try document(), page = try XCTUnwrap(d.page(at: 0))
        let geometry = PDFBookmarkExtractor.Geometry(page: page, box: .cropBox)
        let actual = geometry.normalized(CGRect(x: 3190, y: 85, width: 250, height: 60))
        let displaced = actual.offsetBy(dx: 0, dy: -0.03)
        let located = PDFBookmarkExtractor.extractAdaptiveNumber(
            page: page, normalizedRect: displaced, box: .cropBox)
        XCTAssertEqual(located.result.text, "A1.02")
        XCTAssertGreaterThanOrEqual(located.normalizedXOffset, -0.03)
        XCTAssertLessThanOrEqual(located.normalizedXOffset, 0.03)
        XCTAssertGreaterThan(located.normalizedYOffset, 0)
        XCTAssertLessThanOrEqual(located.normalizedYOffset, 0.03)
    }

    func testNumberFormatsAndAmbiguity() {
        for (input, expected) in [("A 1 . 02", "A1.02"), ("LC-1", "LC-1"), ("E0.03A", "E0.03A"), ("101", "101"), ("SHEET NO:\nA101", "A101"), ("SHEET 1 OF 1 SHEET", "1")] {
            XCTAssertEqual(PDFBookmarkExtractor.value(input, field: .number), expected)
        }
        XCTAssertNil(PDFBookmarkExtractor.value("SHEET 3 OF 2 SHEETS", field: .number))
        XCTAssertNil(PDFBookmarkExtractor.value("A7.20 A7.41", field: .number))
        XCTAssertNil(PDFBookmarkExtractor.value("A1�01", field: .number))
        XCTAssertEqual(PDFBookmarkExtractor.value("SHEET TITLE:\nFLOOR PLAN\nAND NOTES", field: .title), "FLOOR PLAN AND NOTES")
    }

    func testResolutionUsesObservedAlternativeAndIndependentPeerFormats() {
        typealias R = PDFBookmarkExtractor.Result
        let ambiguous = R(text: "MO.10", source: "OCR disagreement", alternatives: ["M0.10"])
        let resolved = PDFBookmarkExtractor.resolveNumbers([ambiguous,
            R(text: "M0.20", source: "OCR"), R(text: "M0.30", source: "OCR")])
        XCTAssertEqual(resolved[0].text, "M0.10")
        XCTAssertEqual(resolved[0].alternatives, ["MO.10"])
        XCTAssertEqual(PDFBookmarkExtractor.resolveNumbers([ambiguous])[0].text, "MO.10")
        // Repeated copies of one identifier are not independent evidence.
        XCTAssertEqual(PDFBookmarkExtractor.resolveNumbers([ambiguous,
            R(text: "M0.20", source: "OCR"), R(text: "M0.20", source: "OCR")])[0].text, "MO.10")
        XCTAssertEqual(PDFBookmarkExtractor.resolveNumbers([
            R(text: "MO.10", source: "PDF text", alternatives: ["M0.10"]),
            R(text: "M0.20", source: "OCR"), R(text: "M0.30", source: "OCR")])[0].text, "MO.10")
        XCTAssertEqual(PDFBookmarkExtractor.resolveNumbers([ambiguous,
            R(text: "MO.20", source: "OCR"), R(text: "M0.20", source: "OCR"),
            R(text: "M0.30", source: "OCR")])[0].text, "MO.10")
    }

    func testOCRLabelHintOnlyDisambiguatesCloseNonNativeReadings() {
        typealias R = PDFBookmarkExtractor.Result
        let results = [
            R(text: "M1.10", source: "OCR"),
            R(text: "M1.20", source: "OCR"),
            R(text: "M1.50", source: "OCR disagreement", alternatives: ["M1.30"])
        ]
        XCTAssertEqual(PDFBookmarkExtractor.resolveNumbers(
            results, labelHints: ["M1.10", "M1.20", "M1.30"])[2].text, "M1.30")
        XCTAssertEqual(PDFBookmarkExtractor.resolveNumbers([
            R(text: "L1.22", source: "OCR")
        ], labelHints: ["L1.31"])[0].text, "L1.22")
        XCTAssertEqual(PDFBookmarkExtractor.resolveNumbers([
            R(text: "L1.11", source: "OCR"),
            R(text: "L1.12", source: "OCR"),
            R(text: "L1.22", source: "OCR")
        ], labelHints: ["L1.11", "L1.12", "L1.31"])[2].text, "L1.22")
        XCTAssertEqual(PDFBookmarkExtractor.resolveNumbers([
            R(text: "A1.20", source: "PDF text", alternatives: ["A1.30"])
        ], labelHints: ["A1.30"])[0].text, "A1.20")
        XCTAssertEqual(PDFBookmarkExtractor.resolveNumbers([
            R(text: "M1.60", source: "OCR"),
            R(text: "M1.1U", source: "OCR"),
            R(text: "M1.80", source: "OCR")
        ], labelHints: ["M1.60", "M1.70", "M1.80"])[1].text, "M1.70")
        XCTAssertEqual(PDFBookmarkExtractor.resolveNumbers([
            R(text: "L1.21", source: "OCR"),
            R(text: "L1.22", source: "OCR"),
            R(text: "L1.23", source: "OCR")
        ], labelHints: ["L1.21", "L1.31", "L1.23"])[1].text, "L1.22")
    }

    func testNativeTextPreservesSmallerTitleLine() throws {
        let d = try document(), p = try XCTUnwrap(d.page(at: 0))
        let result = PDFBookmarkExtractor.extract(page: p, rect: CGRect(x: 3190, y: 160, width: 350, height: 80), box: .cropBox, field: .title)
        XCTAssertEqual(result.text, "FLOOR PLAN AND NOTES")
        XCTAssertEqual(result.source, "PDF text")
    }

    func testOverlappingTextDoesNotSilentlyWinOverVisibleContent() throws {
        let d = try document(), p = try XCTUnwrap(d.page(at: 0))
        let result = PDFBookmarkExtractor.extract(page: p, rect: CGRect(x: 2690, y: 185, width: 350, height: 60), box: .cropBox, field: .title)
        XCTAssertNotEqual(result.source, "PDF text")
    }

    func testCropOriginAndEveryRotationRoundTripAndRenderLargePage() throws {
        let d = try document(), p = try XCTUnwrap(d.page(at: 0))
        p.setBounds(CGRect(x: 50, y: 60, width: 3500, height: 2300), for: .cropBox)
        let region = CGRect(x: 3190, y: 85, width: 250, height: 60)
        for rotation in [0, 90, 180, 270] {
            p.rotation = rotation
            let g = PDFBookmarkExtractor.Geometry(page: p, box: .cropBox)
            let roundTrip = g.pageRect(g.normalized(region))
            XCTAssertEqual(roundTrip.minX, region.minX, accuracy: 0.001)
            XCTAssertEqual(roundTrip.minY, region.minY, accuracy: 0.001)
            XCTAssertEqual(roundTrip.width, region.width, accuracy: 0.001)
            let image = try XCTUnwrap(PDFBookmarkExtractor.render(page: p, rect: region, box: .cropBox))
            XCTAssertLessThanOrEqual(max(image.width, image.height), 1000)
            // Rasterized crops at every page rotation must retain the identifier.
            do {
                let raster = try XCTUnwrap(PDFPage(image: NSImage(cgImage: image, size: .zero)))
                let rd = PDFDocument(); rd.insert(raster, at: 0)
                let result = PDFBookmarkExtractor.extract(page: raster, rect: raster.bounds(for: .cropBox), box: .cropBox, field: .number)
                XCTAssertEqual(result.text, "A1.02")
                XCTAssertEqual(result.source, "OCR")
            }
        }
    }
}
