import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class CivilLinkBoundsTests: XCTestCase {
    func testRecoveredCivilReferencesUseVisibleWordBounds() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_CIVIL_FIXTURE"],
              ProcessInfo.processInfo.environment["DRAWBRIDGE_RUN_VISION_TESTS"] == "1" else {
            throw XCTSkip("Provide the civil fixture and a native Vision-capable test environment")
        }
        let source = URL(fileURLWithPath: path)
        let originalBytes = try Data(contentsOf: source)
        let original = try XCTUnwrap(PDFDocument(url: source))
        let recovered = try XCTUnwrap(PDFSelectableTextRecovery.document(for: source))
        let page = try XCTUnwrap(original.page(at: 6))
        let textPage = try XCTUnwrap(recovered.page(at: 6))
        let controller = MainViewController()
        let hints = controller.selectableSheetTokenHits(on: textPage, knownExactTokens: ["C2.00", "C2.01", "C2.02"])
        let located = VisualSheetReferenceLocator.locate(on: page, hints: hints)
        XCTAssertEqual(located.count, 6)
        // These are the six visible references in the user's construction notes,
        // independently reviewed against the rendered sheet rather than text metrics.
        let expected: [(String, CGRect)] = [
            ("C2.01", CGRect(x: 378.18, y: 1005.46, width: 12.67, height: 27.58)),
            ("C2.00", CGRect(x: 342.18, y: 1091.46, width: 12, height: 27.5)),
            ("C2.02", CGRect(x: 257.88, y: 934.29, width: 11.95, height: 26.97)),
            ("C2.01", CGRect(x: 233.65, y: 994.54, width: 14.28, height: 26.84)),
            ("C2.02", CGRect(x: 114.92, y: 1133.72, width: 10.17, height: 27.33)),
            ("C2.00", CGRect(x: 88.36, y: 999.76, width: 11.95, height: 28))
        ]
        for (token, bounds) in expected {
            let hit = try XCTUnwrap(located.filter { $0.token == token }.min { abs($0.bounds.midX - bounds.midX) < abs($1.bounds.midX - bounds.midX) })
            XCTAssertEqual(hit.bounds.midX, bounds.midX, accuracy: 3)
            XCTAssertEqual(hit.bounds.midY, bounds.midY, accuracy: 3)
        }
        let sheetTokens = ["C0.01", "C0.02", "C1.00", "C1.10", "C1.11", "C1.20", "C1.30", "C1.40", "C2.00", "C2.01", "C2.02"]
        for (index, expectedCount) in [(0, 10), (7, 15)] {
            let originalPage = try XCTUnwrap(original.page(at: index))
            let recoveredPage = try XCTUnwrap(recovered.page(at: index))
            let allHints = controller.selectableSheetTokenHits(on: recoveredPage, knownExactTokens: Set(sheetTokens))
            let hits = VisualSheetReferenceLocator.locate(on: originalPage, hints: allHints)
                .filter { $0.token != sheetTokens[index] }
            XCTAssertEqual(hits.count, expectedCount, "Page \(index + 1) reference coverage")
        }
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
    }
}
