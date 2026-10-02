import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class HyperlinkRegressionTests: XCTestCase {
    func testCapturedZoneUsesVisibleCoordinatesAcrossRotationsAndCropOrigins() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        let page = try XCTUnwrap(document.page(at: 0))
        page.setBounds(CGRect(x: 20, y: 35, width: 550, height: 720), for: .cropBox)
        let controller = MainViewController()
        let visible = CGRect(x: 0.91, y: 0.02, width: 0.065, height: 0.035)
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let geometry = PDFBookmarkExtractor.Geometry(page: page, box: .cropBox)
            let raw = geometry.pageRect(visible)
            let zone = controller.normalize(rectInPage: raw, for: page)
            XCTAssertEqual(zone.x, 1 - visible.maxX, accuracy: 0.000001)
            for targetRotation in [0, 90, 180, 270] {
                page.rotation = targetRotation
                let target = PDFBookmarkExtractor.Geometry(page: page, box: .cropBox)
                let mapped = target.normalized(controller.denormalize(rect: zone, for: page))
                XCTAssertEqual(mapped.minX, visible.minX, accuracy: 0.000001)
                XCTAssertEqual(mapped.minY, visible.minY, accuracy: 0.000001)
                XCTAssertEqual(mapped.width, visible.width, accuracy: 0.000001)
                XCTAssertEqual(mapped.height, visible.height, accuracy: 0.000001)
            }
        }
    }

    func testSaltairMixedRotationSheetZonesAlign() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_SALTAIR_FIXTURE"] else { throw XCTSkip("Set DRAWBRIDGE_SALTAIR_FIXTURE") }
        let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)))
        let reference = try XCTUnwrap(document.page(at: 0))
        let controller = MainViewController()
        let visible = CGRect(x: 0.93, y: 0.015, width: 0.055, height: 0.03)
        let geometry = PDFBookmarkExtractor.Geometry(page: reference, box: .cropBox)
        let zone = controller.normalize(rectInPage: geometry.pageRect(visible), for: reference)
        for i in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: i))
            let target = PDFBookmarkExtractor.Geometry(page: page, box: .cropBox)
            let mapped = target.normalized(controller.denormalize(rect: zone, for: page))
            XCTAssertEqual(mapped.minX, visible.minX, accuracy: 0.000001, "Page \(i + 1)")
            XCTAssertEqual(mapped.minY, visible.minY, accuracy: 0.000001, "Page \(i + 1)")
            XCTAssertEqual(mapped.width, visible.width, accuracy: 0.000001)
            XCTAssertEqual(mapped.height, visible.height, accuracy: 0.000001)
        }
    }

    func testDefaultPageLabelsCannotBecomeSheetTargets() {
        let controller = MainViewController()
        for label in ["1", "2", "56", "Page 4 - Untitled", "PROJECT INFO"] {
            XCTAssertNil(controller.sheetInfoFromPageLabel(label).number, label)
        }
        for label in ["G0.01 - PROJECT INFO", "A101 - PLAN", "L2.12 - PLANTING PLAN", "GO.10 - DIAGRAMS"] {
            XCTAssertNotNil(controller.sheetInfoFromPageLabel(label).number, label)
        }
        XCTAssertFalse(SheetReferencePolicy.isSheetIdentifier("ALLO"))
        XCTAssertFalse(SheetReferencePolicy.isSheetIdentifier("PAGE4UNTITLED"))
    }

    func testGeneratedLinksHaveRecognizablePDFKitType() throws {
        let controller = MainViewController()
        let link = PDFAnnotation(bounds: NSRect(x: 0, y: 0, width: 20, height: 10), forType: .link, withProperties: nil)
        link.contents = "DrawbridgeAutoSheetLink:12"
        XCTAssertTrue(controller.isProtectedAutoSheetLink(link))
        let unrelated = PDFAnnotation(bounds: link.bounds, forType: .link, withProperties: nil)
        unrelated.contents = "User link"
        XCTAssertFalse(controller.isProtectedAutoSheetLink(unrelated))
    }

    func testReferencesMustMatchWholeTokens() {
        XCTAssertFalse(SheetReferencePolicy.isWholeToken(NSRange(location: 0, length: 4), in: "A1.10" as NSString))
        XCTAssertFalse(SheetReferencePolicy.isWholeToken(NSRange(location: 1, length: 5), in: "XA1.10" as NSString))
        XCTAssertTrue(SheetReferencePolicy.isWholeToken(NSRange(location: 4, length: 5), in: "SEE A1.10." as NSString))
    }

    func testOnlyFullUnambiguousOCRIdentifiersCreateTargets() {
        XCTAssertNil(SheetReferencePolicy.uniqueOCRSheetIdentifier(in: "12"))
        XCTAssertNil(SheetReferencePolicy.uniqueOCRSheetIdentifier(in: "SHEET NO:"))
        XCTAssertNil(SheetReferencePolicy.uniqueOCRSheetIdentifier(in: "A1.12 B1.12"))
        XCTAssertEqual(SheetReferencePolicy.uniqueOCRSheetIdentifier(in: "SHEET NO:\nA1.12"), "A1.12")
        var index = OCRSheetTargetIndex()
        index.record("12", pageIndex: 11)
        index.record("A1.12", pageIndex: 3)
        index.record("A1.12", pageIndex: 7)
        index.record("A1.12", pageIndex: 9)
        index.record("L2.12", pageIndex: 5)
        XCTAssertEqual(index.targets, ["L2.12": 5])
    }

    func testMalformedCMapRecoveryPreservesMappingsAndLeavesValidMapsAlone() {
        let mappings = "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n2 beginbfchar\n<0036> <0053>\n<0015> <0032>\nendbfchar\n"
        let malformed = "begincmap\n/CMapName /Adobe-Identity-UCS (def)\n/CMapType (2) def\n" + mappings + "endcmap\nend"
        let normalized = PDFSelectableTextRecovery.normalizedCMap(malformed)
        XCTAssertTrue(normalized?.contains(mappings) == true)
        XCTAssertTrue(normalized?.contains("/CMapType 2 def") == true)
        XCTAssertTrue(normalized?.hasSuffix("end\nend\n") == true)
        XCTAssertNil(PDFSelectableTextRecovery.normalizedCMap(normalized ?? ""))
        XCTAssertNil(PDFSelectableTextRecovery.normalizedCMap("not a CMap"))
    }

    func testWestwoodMalformedFontMapsRecoverExactIndexReferencesAndSaveS202() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_WESTWOOD_FIXTURE"] else { throw XCTSkip("Set DRAWBRIDGE_WESTWOOD_FIXTURE") }
        let source = URL(fileURLWithPath: path)
        let originalData = try Data(contentsOf: source)
        let original = try XCTUnwrap(PDFDocument(url: source))
        let recovered = try XCTUnwrap(PDFSelectableTextRecovery.document(for: source))
        let index = try XCTUnwrap(recovered.page(at: 0))
        let controller = MainViewController()
        let hits = controller.selectableSheetTokenHits(on: index, knownExactTokens: ["S202", "S202A", "S202B", "S202C"])
        XCTAssertEqual(hits.map(\.token).sorted(), ["S202", "S202A", "S202B", "S202C"])
        let hit = try XCTUnwrap(hits.first { $0.token == "S202" })
        let page = try XCTUnwrap(original.page(at: 0))
        let target = try XCTUnwrap(original.page(at: 21))
        let link = PDFAnnotation(bounds: hit.bounds, forType: .link, withProperties: nil)
        link.contents = "DrawbridgeAutoSheetLink:21"
        link.action = PDFActionGoTo(destination: PDFDestination(page: target, at: .zero))
        page.addAnnotation(link)
        let outputPath = ProcessInfo.processInfo.environment["DRAWBRIDGE_WESTWOOD_OUTPUT"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("westwood-s202-verified.pdf").path
        let output = URL(fileURLWithPath: outputPath)
        XCTAssertEqual(PDFTKBookmarkWriter.writeNavigation(in: original, sourceURL: source, to: output, pageLabels: [:]), .saved)
        let saved = try XCTUnwrap(PDFDocument(url: output))
        let savedLink = try XCTUnwrap(saved.page(at: 0)?.annotations.first { $0.contents == "DrawbridgeAutoSheetLink:21" })
        let destination = try XCTUnwrap((savedLink.action as? PDFActionGoTo)?.destination.page)
        XCTAssertEqual(saved.index(for: destination), 21)
        XCTAssertEqual(try Data(contentsOf: source), originalData)
        print("Verified exact S202 link to page 22: \(output.path)")
    }

    func testOrientationRecoveryRequiresOneLiteralIdentifier() {
        XCTAssertEqual(SheetReferencePolicy.uniqueOCRSheetIdentifier(inOrientationReadings: ["ZOZS", "S202", "S202"]), "S202")
        XCTAssertNil(SheetReferencePolicy.uniqueOCRSheetIdentifier(inOrientationReadings: ["ZOZS", "5202", "SZOZ"]))
        XCTAssertNil(SheetReferencePolicy.uniqueOCRSheetIdentifier(inOrientationReadings: ["S202", "S202A"]))
        XCTAssertNil(SheetReferencePolicy.uniqueOCRSheetIdentifier(inOrientationReadings: ["S202 S203", "22"]))
        XCTAssertEqual(SheetReferencePolicy.exactReferences(in: "S202\n3RD FLOOR DECK FRAMING PLAN (PODIUM)\nS202A", knownTokens: ["S202", "S202A", "S202B", "S202C"]), ["S202", "S202A"])
    }

    func testExactOCRWhitelistDoesNotGeneralizeReferences() {
        let known: Set<String> = ["A1.12", "G0.10"]
        XCTAssertEqual(SheetReferencePolicy.exactReferences(in: "12 1.12 A112 GO.10 XA1.12 A1.12.0", knownTokens: known), [])
        XCTAssertEqual(SheetReferencePolicy.exactReferences(in: "SEE 3/A1.12. AND G0.10", knownTokens: known), ["A1.12", "G0.10"])
    }

    func testParkmanLinksSaveAndReopenWithoutRunawayMatches() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_LINK_FIXTURE"] else { throw XCTSkip("Set DRAWBRIDGE_LINK_FIXTURE") }
        let source = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: source)
        let document = try XCTUnwrap(PDFDocument(url: source))
        let controller = MainViewController()
        var targets: [String: Int] = [:]
        for i in 0..<document.pageCount {
            if let token = controller.sheetInfoFromPageLabel(document.page(at: i)?.label ?? "").number {
                targets[controller.canonicalizeSheetToken(token)] = i
            }
        }
        var count = 0
        for i in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: i))
            for hit in controller.selectableSheetTokenHits(on: page, knownCanonicalTokens: Set(targets.keys)) {
                guard let target = targets[controller.canonicalizeSheetToken(hit.token)], target != i else { continue }
                let link = PDFAnnotation(bounds: hit.bounds.insetBy(dx: -1.5, dy: -1), forType: .link, withProperties: nil)
                link.contents = "DrawbridgeAutoSheetLink:\(target)"
                link.action = PDFActionGoTo(destination: PDFDestination(page: try XCTUnwrap(document.page(at: target)), at: .zero))
                page.addAnnotation(link)
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThan(count, 2000)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("parkman-v34-save-verification.pdf")
        let start = CFAbsoluteTimeGetCurrent()
        XCTAssertEqual(PDFTKBookmarkWriter.writeNavigation(in: document, sourceURL: source, to: output, pageLabels: [:]), .saved)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let saved = try XCTUnwrap(PDFDocument(url: output))
        let writtenLinks = (0..<saved.pageCount).flatMap { saved.page(at: $0)?.annotations ?? [] }.filter { $0.type == "Link" }
        XCTAssertEqual(writtenLinks.count, count)
        XCTAssertTrue(writtenLinks.allSatisfy(controller.isProtectedAutoSheetLink), "Saved links must be removable on the next run")
        XCTAssertEqual(saved.pageCount, document.pageCount)
        for i in 0..<document.pageCount {
            XCTAssertEqual(saved.page(at: i)?.rotation, document.page(at: i)?.rotation)
            XCTAssertEqual(saved.page(at: i)?.bounds(for: .mediaBox), document.page(at: i)?.bounds(for: .mediaBox))
            XCTAssertEqual(saved.page(at: i)?.bounds(for: .cropBox), document.page(at: i)?.bounds(for: .cropBox))
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertLessThan(try Data(contentsOf: output).count, original.count + 1024 * 1024)
        print("verified_links=\(count) save_seconds=\(elapsed) original_bytes=\(original.count) saved_bytes=\(try Data(contentsOf: output).count)")
    }
}
