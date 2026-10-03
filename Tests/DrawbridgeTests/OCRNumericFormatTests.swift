import XCTest
@testable import Drawbridge

final class OCRNumericFormatTests: XCTestCase {
    func testNumericLetterConfusionUsesStrongOCRCohortAndOrderedAnchors() {
        let expected = (0..<40).map { String(format: "G0.%02d", $0) }
        var readings = expected
        for index in 10...16 { readings[index] = String(format: "GO.%02d", index) }
        XCTAssertEqual(SheetReferencePolicy.reconcileOCRNumbers(readings), expected)
    }

    func testMissingHyperlinkTargetsUseSameCorrectionAsBookmarks() {
        let expected = (0..<40).map { String(format: "G0.%02d", $0) }
        var readings = expected
        for index in [11, 13, 16] { readings[index] = String(format: "GO.%02d", index) }
        XCTAssertEqual(SheetReferencePolicy.reconcileOCRNumbers(readings), expected)
        XCTAssertEqual(SheetReferencePolicy.exactReferences(in: "SEE G0.11. 11 GO.11", knownTokens: ["G0.11"]), ["G0.11"])
    }

    func testInsufficientEvidenceAndLegitimateLetterPrefixArePreserved() {
        for readings in [["G0.10", "GO.11", "G0.12"], ["GO.10", "GO.11", "GO.12"], ["12", "11", "10"]] {
            XCTAssertEqual(SheetReferencePolicy.reconcileOCRNumbers(readings), readings)
        }
        var unordered = (0..<40).map { String(format: "G0.%02d", $0) }
        unordered[11] = "GO.99"
        XCTAssertEqual(SheetReferencePolicy.reconcileOCRNumbers(unordered), unordered)
    }
}
