import Foundation
import PDFKit
import XCTest
@testable import Drawbridge

/// Optional local corpus: no customer PDFs are copied into the repository.
final class PDFBookmarkCorpusTests: XCTestCase {
    func testDesktopMixedLayoutAndAmbiguousProductionSheets() throws {
        guard let desktop = ProcessInfo.processInfo.environment["DRAWBRIDGE_BOOKMARK_DESKTOP_FIXTURES"] else {
            throw XCTSkip("Set DRAWBRIDGE_BOOKMARK_DESKTOP_FIXTURES to the Desktop PDF folder")
        }

        let expo = URL(fileURLWithPath: desktop).appendingPathComponent("12222 EXPO")
        let mechanical = try XCTUnwrap(PDFDocument(url: expo.appendingPathComponent(
            "260925 - 12222 EXPOSITION - BID SET 2 - MECH.pdf")))
        let expectedMechanical = [
            "M0.10", "M0.20", "M0.30", "M0.40", "M1.10", "M1.20", "M1.30", "M1.40",
            "M1.50", "M1.60", "M1.70", "M1.80", "M2.00", "M2.01", "M3.00", "M3.10",
            "M3.20", "M3.30", "M3.40", "M3.50", "M4.00", "M4.10", "M4.20", "M5.00",
        ]
        let numberRegion = CGRect(x: 0.918, y: 0.024, width: 0.070, height: 0.043)
        let titleRegion = CGRect(x: 0.913, y: 0.077, width: 0.082, height: 0.060)
        var numbers: [PDFBookmarkExtractor.Result] = []
        var titles: [PDFBookmarkExtractor.Result] = []
        for index in 0..<mechanical.pageCount {
            let page = try XCTUnwrap(mechanical.page(at: index))
            let geometry = PDFBookmarkExtractor.Geometry(page: page, box: .cropBox)
            let located = PDFBookmarkExtractor.extractAdaptiveNumber(
                page: page, normalizedRect: numberRegion, box: .cropBox)
            numbers.append(located.result)
            titles.append(PDFBookmarkExtractor.extract(
                page: page,
                rect: geometry.pageRect(titleRegion.offsetBy(
                    dx: located.normalizedXOffset, dy: located.normalizedYOffset)),
                box: .cropBox,
                field: .title))
        }
        numbers = PDFBookmarkExtractor.resolveNumbers(numbers, labelHints: expectedMechanical)
        XCTAssertEqual(numbers.map(\.text), expectedMechanical)
        XCTAssertTrue(titles.allSatisfy { !$0.text.isEmpty })

        let westwood = URL(fileURLWithPath: desktop).appendingPathComponent("2323 WESTWOOD")
        let electrical = try XCTUnwrap(PDFDocument(url: westwood.appendingPathComponent(
            "260925 - 2323 WESTWOOD - BID SET 2 - ELEC.pdf")))
        var electricalResults: [PDFBookmarkExtractor.Result] = []
        let electricalRegion = CGRect(x: 0.91, y: 0.015, width: 0.08, height: 0.055)
        for index in 0..<electrical.pageCount {
            let page = try XCTUnwrap(electrical.page(at: index))
            electricalResults.append(PDFBookmarkExtractor.extractAdaptiveNumber(
                page: page, normalizedRect: electricalRegion, box: .cropBox).result)
        }
        let electricalHints = (0..<electrical.pageCount).map { index in
            index == 29 ? "E3.02" : index == 30 ? "E3.03" : nil
        }
        electricalResults = PDFBookmarkExtractor.resolveNumbers(
            electricalResults, labelHints: electricalHints)
        XCTAssertEqual(electricalResults[29].text, "E3.02")
        XCTAssertEqual(electricalResults[30].text, "E3.03")

        let landscape = try XCTUnwrap(PDFDocument(url: westwood.appendingPathComponent(
            "260925 - 2323 WESTWOOD - BID SET 2 - LAND.pdf")))
        let landscapeRegion = CGRect(x: 0.895, y: 0.024, width: 0.09, height: 0.040)
        var landscapeResults: [PDFBookmarkExtractor.Result] = []
        for index in 0..<landscape.pageCount {
            let page = try XCTUnwrap(landscape.page(at: index))
            landscapeResults.append(PDFBookmarkExtractor.extractAdaptiveNumber(
                page: page, normalizedRect: landscapeRegion, box: .cropBox).result)
        }
        let landscapeHints: [String?] = [
            "L1.11", "L1.12", "L1.13", "L1.21", "L1.22", "L1.31",
            "L2.11", "L2.12", "L2.13", "L2.21",
        ]
        landscapeResults = PDFBookmarkExtractor.resolveNumbers(
            landscapeResults, labelHints: landscapeHints)
        XCTAssertEqual(landscapeResults[5].text, "L1.22", "Visible title block wins over a stale page label")

        let expoLandscape = try XCTUnwrap(PDFDocument(url: expo.appendingPathComponent(
            "260925 - 12222 EXPOSITION - BID SET 2 - LAND.pdf")))
        let expectedExpoLandscape = ["L1.11", "L1.12", "L1.21", "L1.22", "L1.31", "L2.11", "L2.12", "L2.21"]
        let expoNumberRegion = CGRect(x: 0.918, y: 0.024, width: 0.070, height: 0.043)
        let expoTitleRegion = CGRect(x: 0.918, y: 0.080, width: 0.064, height: 0.045)
        var expoNumbers: [String] = []
        var expoTitles: [String] = []
        for index in 0..<expoLandscape.pageCount {
            let page = try XCTUnwrap(expoLandscape.page(at: index))
            let geometry = PDFBookmarkExtractor.Geometry(page: page, box: .cropBox)
            expoNumbers.append(PDFBookmarkExtractor.extractAdaptiveNumber(
                page: page, normalizedRect: expoNumberRegion, box: .cropBox).result.text)
            expoTitles.append(PDFBookmarkExtractor.extract(
                page: page,
                rect: geometry.pageRect(expoTitleRegion),
                box: .cropBox,
                field: .title
            ).text)
        }
        XCTAssertEqual(expoNumbers, expectedExpoLandscape)
        XCTAssertEqual(expoTitles[7], "PLANTING DETAILS")
    }

    func testFourLocalDrawingPDFs() throws {
        guard let folder = ProcessInfo.processInfo.environment["DRAWBRIDGE_BOOKMARK_FIXTURES"] else {
            throw XCTSkip("Set DRAWBRIDGE_BOOKMARK_FIXTURES to the local PDF folder")
        }
        let cases: [(String, [String])] = [
            ("260422 - 2323 WESTWOOD - 100 DD MECH.pdf", ["M0.10", "M0.20", "M0.30", "M0.40", "M1.10", "M1.20", "M1.30", "M1.40", "M1.60", "M1.70", "M1.80", "M2.00", "M2.01", "M2.02"]),
            ("SCALE TEST.pdf", ["A1.82"]),
            ("260423 - 25019 - 2127 WESTWOOD - ALTA Survey.pdf", ["1"]),
            ("260422 - 2323 WESTWOOD - 100 DD ARCH.pdf", architecturalNumbers)
        ]
        for (filename, expected) in cases {
            let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: folder).appendingPathComponent(filename)))
            XCTAssertEqual(document.pageCount, expected.count)
            var numbers: [PDFBookmarkExtractor.Result] = []
            var titles: [String] = []
            for index in 0..<document.pageCount {
                let page = try XCTUnwrap(document.page(at: index))
                let geometry = PDFBookmarkExtractor.Geometry(page: page, box: .cropBox)
                let survey = filename.contains("Survey")
                let numberRegion = survey ? CGRect(x: 0.952, y: 0.974, width: 0.037, height: 0.009) : CGRect(x: 0.916, y: 0.024, width: 0.073, height: 0.044)
                let titleRegion = survey ? CGRect(x: 0.848, y: 0.913, width: 0.11, height: 0.045) : CGRect(x: 0.916, y: 0.081, width: 0.073, height: 0.050)
                numbers.append(PDFBookmarkExtractor.extract(page: page, rect: geometry.pageRect(numberRegion), box: .cropBox, field: .number))
                titles.append(PDFBookmarkExtractor.extract(page: page, rect: geometry.pageRect(titleRegion), box: .cropBox, field: .title).text)
            }
            XCTAssertEqual(PDFBookmarkExtractor.resolveNumbers(numbers).map(\.text), expected, filename)
            XCTAssertTrue(titles.allSatisfy { !$0.isEmpty }, filename)
            if filename.contains("ARCH") {
                XCTAssertEqual(titles[69], "WINDOW SCHEDULE")
                XCTAssertEqual(titles[75], "FLOOR & WALL DETAILS")
            } else if filename.contains("MECH") {
                XCTAssertEqual(titles[0], "MECHANICAL NOTES, SYMBOLS & LEGEND")
            } else if filename.contains("SCALE") {
                XCTAssertEqual(titles[0], "ROOF DECK PLAN")
            } else {
                XCTAssertEqual(titles[0], "A.L.T.A. /N.S.P.S. LAND TITLE SURVEYS")
            }
        }
    }

    private let architecturalNumbers: [String] = [
        "G0.00", "G0.01", "G0.02", "G0.03", "G0.10", "G0.11", "G0.12", "G0.13", "G0.15", "G0.17",
        "G0.20", "G0.21", "G0.22", "G0.23", "G0.30", "G0.31", "G0.32", "G0.33", "G0.40", "G0.41",
        "G0.42", "G0.43", "G0.44", "G0.50", "G0.51", "G0.52", "G0.53", "G0.60", "A0.00", "A0.01",
        "A1.10", "A1.20", "A1.30", "A1.40", "A1.50", "A1.60", "A1.70", "A1.80", "A1.81", "A2.00",
        "A2.01", "A2.02", "A2.03", "A3.00", "A3.01", "A4.00", "A4.01", "A4.02", "A4.03", "A4.04",
        "A4.05", "A4.06", "A4.07", "A4.08", "A4.09", "A4.10", "A4.11", "A4.12", "A4.13", "A4.20",
        "A4.21", "A4.22", "A4.30", "A4.31", "A5.00", "A5.01", "A5.10", "A5.20", "A6.00", "A6.10",
        "A6.20", "A6.30", "A7.00", "A7.01", "A7.10", "A7.20", "A7.21", "A7.30", "A7.40", "A7.50",
        "A7.60", "A7.70", "A7.80", "A7.81", "A7.82",
    ]
}
