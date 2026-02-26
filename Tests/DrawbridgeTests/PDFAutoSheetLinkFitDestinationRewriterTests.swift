import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

final class PDFAutoSheetLinkFitDestinationRewriterTests: XCTestCase {
    func testRewriteAutoSheetLinksToFitRewritesXYZDestinations() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drawbridge-link-fit-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let pageImage = NSImage(size: NSSize(width: 320, height: 240))
        pageImage.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 240)).fill()
        pageImage.unlockFocus()

        let document = PDFDocument()
        guard let page1 = PDFPage(image: pageImage),
              let page2 = PDFPage(image: pageImage) else {
            XCTFail("Failed to create test pages")
            return
        }
        document.insert(page1, at: 0)
        document.insert(page2, at: 1)

        let destination = PDFDestination(page: page2, at: NSPoint(x: 0, y: page2.bounds(for: .cropBox).maxY))
        let link = PDFAnnotation(bounds: NSRect(x: 20, y: 20, width: 120, height: 40), forType: .link, withProperties: nil)
        link.contents = "DrawbridgeAutoSheetLink:1"
        link.userName = "DrawbridgeAutoSheetLink:1"
        link.destination = destination
        link.action = PDFActionGoTo(destination: destination)
        link.setValue(destination, forAnnotationKey: .destination)
        page1.addAnnotation(link)

        XCTAssertTrue(document.write(to: tempURL, withOptions: nil))

        let before = try String(contentsOf: tempURL, encoding: .isoLatin1)
        XCTAssertTrue(before.contains("/XYZ"))

        try PDFAutoSheetLinkFitDestinationRewriter.rewriteAutoSheetLinksToFit(in: tempURL)

        let after = try String(contentsOf: tempURL, encoding: .isoLatin1)
        XCTAssertTrue(after.contains("/GoTo /D ["))
        XCTAssertTrue(after.contains("/Fit ]"))
        XCTAssertTrue(after.contains("DrawbridgeAutoSheetLink:1"))
    }

    func testRewriteXYZNullDestinationsWithoutMarker() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drawbridge-link-fit-nomarker-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let pageImage = NSImage(size: NSSize(width: 320, height: 240))
        pageImage.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 240)).fill()
        pageImage.unlockFocus()

        let document = PDFDocument()
        guard let page1 = PDFPage(image: pageImage),
              let page2 = PDFPage(image: pageImage) else {
            XCTFail("Failed to create test pages")
            return
        }
        document.insert(page1, at: 0)
        document.insert(page2, at: 1)

        let destination = PDFDestination(
            page: page2,
            at: NSPoint(x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue)
        )
        destination.zoom = kPDFDestinationUnspecifiedValue
        let link = PDFAnnotation(bounds: NSRect(x: 20, y: 20, width: 120, height: 40), forType: .link, withProperties: nil)
        link.destination = destination
        link.action = PDFActionGoTo(destination: destination)
        link.setValue(destination, forAnnotationKey: .destination)
        page1.addAnnotation(link)

        XCTAssertTrue(document.write(to: tempURL, withOptions: nil))

        let before = try String(contentsOf: tempURL, encoding: .isoLatin1)
        XCTAssertTrue(before.contains("/XYZ null null null"))

        try PDFAutoSheetLinkFitDestinationRewriter.rewriteAutoSheetLinksToFit(in: tempURL)

        let after = try String(contentsOf: tempURL, encoding: .isoLatin1)
        XCTAssertFalse(after.contains("/XYZ null null null"))
        XCTAssertTrue(after.contains("/Fit"))
    }

    func testExportCompatibilityVariantsCreatesAllDestinationModes() throws {
        let sourceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drawbridge-link-fit-variants-\(UUID().uuidString).pdf")
        let outputDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drawbridge-link-fit-variants-out-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDir)
        }

        let pageImage = NSImage(size: NSSize(width: 320, height: 240))
        pageImage.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 240)).fill()
        pageImage.unlockFocus()

        let document = PDFDocument()
        guard let page1 = PDFPage(image: pageImage),
              let page2 = PDFPage(image: pageImage) else {
            XCTFail("Failed to create test pages")
            return
        }
        document.insert(page1, at: 0)
        document.insert(page2, at: 1)

        let destination = PDFDestination(page: page2, at: NSPoint(x: 0, y: page2.bounds(for: .cropBox).maxY))
        let link = PDFAnnotation(bounds: NSRect(x: 20, y: 20, width: 120, height: 40), forType: .link, withProperties: nil)
        link.contents = "DrawbridgeAutoSheetLink:1"
        link.userName = "DrawbridgeAutoSheetLink:1"
        link.action = PDFActionGoTo(destination: destination)
        page1.addAnnotation(link)

        XCTAssertTrue(document.write(to: sourceURL, withOptions: nil))

        let variants = try PDFAutoSheetLinkFitDestinationRewriter.exportCompatibilityVariants(
            for: sourceURL,
            outputDirectory: outputDir
        )
        XCTAssertEqual(variants.count, PDFAutoSheetLinkFitDestinationRewriter.DestinationMode.allCases.count)
        let fitURL = try XCTUnwrap(variants.first { $0.lastPathComponent.contains(".links-fit.") })
        let fitHURL = try XCTUnwrap(variants.first { $0.lastPathComponent.contains(".links-fith.") })
        let fitRURL = try XCTUnwrap(variants.first { $0.lastPathComponent.contains(".links-fitr.") })
        let xyzURL = try XCTUnwrap(variants.first { $0.lastPathComponent.contains(".links-xyz0.") })

        let fitText = try String(contentsOf: fitURL, encoding: .isoLatin1)
        let fitHText = try String(contentsOf: fitHURL, encoding: .isoLatin1)
        let fitRText = try String(contentsOf: fitRURL, encoding: .isoLatin1)
        let xyzText = try String(contentsOf: xyzURL, encoding: .isoLatin1)
        XCTAssertTrue(fitText.contains("/D [") && fitText.contains("/Fit ]"))
        XCTAssertTrue(fitHText.contains("/D [") && fitHText.contains("/FitH"))
        XCTAssertTrue(fitRText.contains("/D [") && fitRText.contains("/FitR"))
        XCTAssertTrue(xyzText.contains("/D [") && xyzText.contains("/XYZ 0 0 0"))
    }
}
