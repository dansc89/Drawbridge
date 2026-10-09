import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class MarkupPDFViewZoomTests: XCTestCase {
    func testZoomKeepsPDFPointUnderCursorForZoomInAndOut() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let pdfView = MarkupPDFView(frame: window.contentView!.bounds)
        pdfView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(pdfView)

        let document = PDFDocument()
        let image = makePageImage()
        let page = try XCTUnwrap(PDFPage(image: image))
        document.insert(page, at: 0)
        pdfView.document = document
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        window.layoutIfNeeded()
        pdfView.layoutSubtreeIfNeeded()

        // Use an off-center point so the test detects center-based zooming.
        let pointerInView = NSPoint(x: 680, y: 220)
        let pointerInWindow = pdfView.convert(pointerInView, to: nil)
        let anchoredPagePoint = pdfView.convert(pointerInView, to: page)

        XCTAssertTrue(pdfView.zoom(by: 1.55, anchoredAtWindowPoint: pointerInWindow))
        drainMainQueue()
        assert(pagePoint: anchoredPagePoint, on: page, remainsAt: pointerInWindow, in: pdfView)

        XCTAssertTrue(pdfView.zoom(by: 1 / 1.55, anchoredAtWindowPoint: pointerInWindow))
        drainMainQueue()
        assert(pagePoint: anchoredPagePoint, on: page, remainsAt: pointerInWindow, in: pdfView)
    }

    func testVisibleCenterNormalizationUsesViewportOnCroppedRotatedPage() throws {
        let pdfView = MarkupPDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let document = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: makePageImage()))
        page.setBounds(NSRect(x: 120, y: 80, width: 900, height: 560), for: .cropBox)
        page.rotation = 90
        document.insert(page, at: 0)
        pdfView.document = document
        pdfView.displayBox = .cropBox
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.4
        pdfView.layoutSubtreeIfNeeded()

        let normalized = try XCTUnwrap(pdfView.normalizedVisibleCenter(on: page))
        XCTAssertGreaterThanOrEqual(normalized.x, 0)
        XCTAssertLessThanOrEqual(normalized.x, 1)
        XCTAssertGreaterThanOrEqual(normalized.y, 0)
        XCTAssertLessThanOrEqual(normalized.y, 1)
    }

    func testPageNavigationPreservesVisibleNormalizedPosition() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let pdfView = MarkupPDFView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(pdfView)
        let document = PDFDocument()
        let firstPage = try XCTUnwrap(PDFPage(image: makePageImage()))
        let secondPage = try XCTUnwrap(PDFPage(image: makePageImage()))
        secondPage.setBounds(NSRect(x: 90, y: 60, width: 960, height: 620), for: .cropBox)
        secondPage.rotation = 90
        document.insert(firstPage, at: 0)
        document.insert(secondPage, at: 1)
        pdfView.document = document
        pdfView.displayBox = .cropBox
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.8
        window.layoutIfNeeded()
        pdfView.layoutSubtreeIfNeeded()

        let pointerInView = NSPoint(x: 690, y: 250)
        let pointerInWindow = pdfView.convert(pointerInView, to: nil)
        XCTAssertTrue(pdfView.zoom(by: 1.2, anchoredAtWindowPoint: pointerInWindow))
        drainMainQueue()
        let sourceCenter = try XCTUnwrap(pdfView.normalizedVisibleCenter(on: firstPage))

        pdfView.navigateToPageWithHistory(secondPage, preservingNormalizedViewportCenter: sourceCenter)
        // PDFKit's scrollbar/page layout settles asynchronously and differs
        // between OS versions. Check the settled result, keeping the same
        // positional accuracy requirement.
        let deadline = Date().addingTimeInterval(1)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if let center = pdfView.normalizedVisibleCenter(on: secondPage),
               abs(center.x - sourceCenter.x) < 0.005,
               abs(center.y - sourceCenter.y) < 0.005 { break }
        } while Date() < deadline
        let targetCenter = try XCTUnwrap(pdfView.normalizedVisibleCenter(on: secondPage))
        XCTAssertEqual(targetCenter.x, sourceCenter.x, accuracy: 0.005)
        XCTAssertEqual(targetCenter.y, sourceCenter.y, accuracy: 0.005)
    }

    private func assert(
        pagePoint: NSPoint,
        on page: PDFPage,
        remainsAt expectedWindowPoint: NSPoint,
        in pdfView: MarkupPDFView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualViewPoint = pdfView.convert(pagePoint, from: page)
        let actualWindowPoint = pdfView.convert(actualViewPoint, to: nil)
        XCTAssertEqual(actualWindowPoint.x, expectedWindowPoint.x, accuracy: 1.0, file: file, line: line)
        XCTAssertEqual(actualWindowPoint.y, expectedWindowPoint.y, accuracy: 1.0, file: file, line: line)
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func makePageImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 1_200, height: 800))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        return image
    }
}
