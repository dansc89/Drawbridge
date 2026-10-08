import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class PlumbingLinkBoundsTests: XCTestCase {
    func testPlumbingIndexReferences() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_PLUMBING_FIXTURE"] else {
            throw XCTSkip("Provide the plumbing sheet-index fixture")
        }
        let source = URL(fileURLWithPath: path)
        let original = try XCTUnwrap(PDFDocument(url: source))
        let recovered = try XCTUnwrap(PDFSelectableTextRecovery.document(for: source))
        let page = try XCTUnwrap(original.page(at: 0))
        let textPage = try XCTUnwrap(recovered.page(at: 0))
        let tokens = Set((0..<original.pageCount).compactMap { original.page(at: $0)?.label?.components(separatedBy: " - ").first })
        let controller = MainViewController()
        let hints = controller.selectableSheetTokenHits(on: textPage, knownExactTokens: tokens)
        let hits = VisualSheetReferenceLocator.locate(on: page, hints: hints)
        XCTAssertEqual(Set(hits.map(\.token)), tokens)
        let originalBytes = try Data(contentsOf: source)
        let missing = ["P0.20": 1, "P0.40": 3, "P0.60": 5]
        for (token, index) in missing {
            let hint = try XCTUnwrap(hints.first { $0.token == token })
            let hit = try XCTUnwrap(hits.first { $0.token == token && $0.bounds.intersects(hint.bounds) })
            XCTAssertLessThan(abs(hit.bounds.midX - hint.bounds.midX), 5)
            XCTAssertLessThan(abs(hit.bounds.midY - hint.bounds.midY), 5)
            let link = PDFAnnotation(bounds: hit.bounds.insetBy(dx: -1.5, dy: -1), forType: .link, withProperties: nil)
            link.userName = "DrawbridgeAutoSheetLink:\(index)"
            link.contents = "DrawbridgeAutoSheetLink:\(index)"
            link.isReadOnly = true
            link.action = PDFActionGoTo(destination: PDFDestination(page: try XCTUnwrap(original.page(at: index)), at: .zero))
            page.addAnnotation(link)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = ProcessInfo.processInfo.environment["DRAWBRIDGE_PLUMBING_OUTPUT"].map { URL(fileURLWithPath: $0) } ?? directory.appendingPathComponent("linked.pdf")
        XCTAssertTrue(PDFRectangleWriter.write(document: original, source: source, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(original)))
        let saved = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(saved.pageCount, 21)
        let savedPage = try XCTUnwrap(saved.page(at: 0))
        for (token, index) in missing {
            let hit = try XCTUnwrap(hits.first { $0.token == token })
            let link = try XCTUnwrap(savedPage.annotations.first { $0.type == "Link" && $0.bounds.contains(CGPoint(x: hit.bounds.midX, y: hit.bounds.midY)) })
            let destination = try XCTUnwrap((link.action as? PDFActionGoTo)?.destination ?? link.destination)
            XCTAssertEqual(saved.index(for: try XCTUnwrap(destination.page)), index)
        }
        XCTAssertEqual(try Data(contentsOf: output).prefix(originalBytes.count), originalBytes)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
    }
}
