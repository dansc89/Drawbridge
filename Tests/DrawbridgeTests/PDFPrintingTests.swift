import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class PDFPrintingTests: XCTestCase {
    private func document() throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for index in 0..<3 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 30 + index * 20, y: 40, width: 60, height: 80))
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    func testPrintingAvailabilityAndBusyValidation() throws {
        _ = NSApplication.shared
        let controller = MainViewController()
        _ = controller.view
        let menu = NSMenuItem(title: "Print", action: #selector(MainViewController.commandPrint(_:)), keyEquivalent: "p")
        XCTAssertFalse(controller.validateMenuItem(menu))
        controller.pdfView.document = PDFDocument()
        XCTAssertFalse(controller.validateMenuItem(menu))
        controller.pdfView.document = try document()
        XCTAssertTrue(controller.validateMenuItem(menu))
        controller.beginBusyIndicator("Testing")
        XCTAssertFalse(controller.validateMenuItem(menu))
        controller.endBusyIndicator()
        XCTAssertTrue(controller.validateMenuItem(menu))
    }

    func testCurrentSheetJobPreservesOriginalAndDoesNotInheritStaleSettings() throws {
        _ = NSApplication.shared
        let document = try document()
        let page = try XCTUnwrap(document.page(at: 1))
        page.rotation = 90
        let annotation = PDFAnnotation(bounds: CGRect(x: 60, y: 50, width: 40, height: 60), forType: .square, withProperties: nil)
        annotation.shouldPrint = true
        annotation.color = .red
        page.addAnnotation(annotation)
        let originalPageRef = try XCTUnwrap(page.pageRef)
        let mediaBox = page.bounds(for: .mediaBox)
        let cropBox = page.bounds(for: .cropBox)
        let info = NSPrintInfo(dictionary: [:])
        info.scalingFactor = 0.25
        info.dictionary()[NSPrintInfo.AttributeKey.firstPage] = 7
        let operation = try XCTUnwrap(PDFPrinting.operation(for: document, currentPageIndex: 1, printInfo: info))
        XCTAssertEqual(operation.printInfo.scalingFactor, 1)
        XCTAssertEqual(operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.firstPage] as? Int, 2)
        XCTAssertEqual(operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.lastPage] as? Int, 2)
        XCTAssertEqual(operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] as? Bool, false)
        XCTAssertEqual(info.scalingFactor, 0.25)
        XCTAssertEqual(info.dictionary()[NSPrintInfo.AttributeKey.firstPage] as? Int, 7)
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertEqual(page.rotation, 90)
        XCTAssertEqual(page.bounds(for: .mediaBox), mediaBox)
        XCTAssertEqual(page.bounds(for: .cropBox), cropBox)
        XCTAssertTrue(page.annotations.first === annotation)
        XCTAssertTrue(page.pageRef === originalPageRef)
        XCTAssertNil(PDFPrinting.operation(for: document, currentPageIndex: 3, printInfo: info))
        XCTAssertNil(PDFPrinting.operation(for: document, currentPageIndex: -1, printInfo: info))
        XCTAssertNil(PDFPrinting.operation(for: document, currentPageIndex: NSNotFound, printInfo: info))
    }

    func testNativePrintToPDFIncludesUnsavedMarkupAndOnlyRequestedSheet() throws {
        _ = NSApplication.shared
        let document = try document()
        let page = try XCTUnwrap(document.page(at: 1))
        let annotation = PDFAnnotation(bounds: CGRect(x: 150, y: 100, width: 90, height: 60), forType: .square, withProperties: nil)
        annotation.shouldPrint = true
        annotation.color = .red
        annotation.interiorColor = .red
        page.addAnnotation(annotation)
        let controller = MainViewController()
        _ = controller.view
        controller.pdfView.document = document
        controller.pdfView.setColorInverted(true)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("drawbridge-print-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        let info = NSPrintInfo(dictionary: [:])
        info.paperSize = NSSize(width: 400, height: 300)
        info.leftMargin = 0; info.rightMargin = 0; info.topMargin = 0; info.bottomMargin = 0
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let operation = try XCTUnwrap(PDFPrinting.operation(for: document, currentPageIndex: 1, printInfo: info))
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        XCTAssertTrue(operation.run())
        let printed = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(printed.pageCount, 1)
        let printedPage = try XCTUnwrap(printed.page(at: 0))
        XCTAssertEqual(printedPage.bounds(for: .mediaBox).width, 400, accuracy: 1)
        let dictionary = try XCTUnwrap(printedPage.pageRef?.dictionary)
        var stream: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetStream(dictionary, "Contents", &stream))
        var format = CGPDFDataFormat.raw
        let content = try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(stream), &format)) as Data
        let operators = try XCTUnwrap(String(data: content, encoding: .ascii))
        XCTAssertTrue(operators.contains(" re "), "Print output must retain vector rectangle paths")
        var resources: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources))
        var images: CGPDFDictionaryRef?
        XCTAssertFalse(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &images), "Vector-only fixture must not become a raster image")
        // Printing bakes the visible unsaved markup into the job, leaving the
        // source annotation editable and the original document intact.
        let raster = try XCTUnwrap(printedPage.thumbnail(of: NSSize(width: 400, height: 300), for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: raster)
        var redPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.8 && color.greenComponent < 0.4 && color.blueComponent < 0.4 { redPixels += 1 }
            }
        }
        XCTAssertGreaterThan(redPixels, 1000)
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertTrue(page.annotations.first === annotation)
        XCTAssertTrue(controller.pdfView.isColorInverted)
    }
}
