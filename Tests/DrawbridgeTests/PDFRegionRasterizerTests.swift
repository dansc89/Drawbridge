import AppKit
import PDFKit
import XCTest
import Vision
@testable import Drawbridge

@MainActor
final class PDFRegionRasterizerTests: XCTestCase {
    private func reference(_ page: PDFPage, rect: CGRect, scale: CGFloat) throws -> CGImage {
        let transform = page.transform(for: .cropBox)
        let full = page.bounds(for: .cropBox).applying(transform).standardized
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(ceil(full.width * scale)), height: Int(ceil(full.height * scale)), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high; context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: full.width * scale, height: full.height * scale))
        context.scaleBy(x: scale, y: scale); context.translateBy(x: -full.minX, y: -full.minY)
        page.draw(with: .cropBox, to: context)
        let crop = rect.applying(transform).standardized.intersection(full)
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(CIContext().createCGImage(CIImage(cgImage: image), from: CGRect(x: (crop.minX-full.minX)*scale, y: (crop.minY-full.minY)*scale, width: crop.width*scale, height: crop.height*scale)))
    }
    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width*image.height*4)
    }
    func testRegionMatchesFullPageCropForAllRotationsAndOffsetCropBoxes() throws {
        let image = NSImage(size: NSSize(width: 600, height: 400), flipped: false) { _ in
            NSColor.white.setFill(); NSRect(x: 0,y: 0,width: 600,height: 400).fill()
            ("A0.00" as NSString).draw(at: NSPoint(x: 410,y: 70), withAttributes: [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.black])
            NSColor.red.setFill(); NSRect(x: 400,y: 60,width: 5,height: 60).fill(); return true
        }
        let page = try XCTUnwrap(PDFPage(image: image))
        let document = PDFDocument(); document.insert(page, at: 0)
        defer { withExtendedLifetime(document) {} }
        page.setBounds(CGRect(x: 30,y: 40,width: 530,height: 320), for: .cropBox)
        for rotation in [0,90,180,270] {
            page.rotation = rotation
            let rect = CGRect(x: 390,y: 50,width: 160,height: 100)
            let actual = try XCTUnwrap(PDFRegionRasterizer.render(page: page, box: .cropBox, rect: rect))
            let expected = try reference(page, rect: rect, scale: 4)
            XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
            let a = try pixels(actual), b = try pixels(expected)
            let difference = zip(a,b).reduce(0.0) { $0 + Double(abs(Int($1.0)-Int($1.1))) } / Double(a.count)
            print("REGION PIXEL mean difference", rotation, difference)
            XCTAssertLessThan(difference, 0.5, "Rotation \(rotation): antialiasing must not change alignment")
        }
    }
    func testArchitecturalSheetNumberOCRFromClippedRegions() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_ARCHITECTURAL_FIXTURE"] else { throw XCTSkip("Provide local Architectural PDF") }
        let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)))
        for (index, expected) in ["A0.00", "A0.10"].enumerated() {
            let page = try XCTUnwrap(document.page(at: index))
            let box = page.bounds(for: .cropBox)
            let rect = CGRect(x: box.maxX-260,y: box.minY+15,width: 230,height: 120)
            let start = Date()
            let image = try XCTUnwrap(PDFRegionRasterizer.render(page: page, box: .cropBox, rect: rect))
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let readings = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            print("ARCHITECTURAL clipped render + OCR page=\(index+1) seconds=\(Date().timeIntervalSince(start)) readings=\(readings)")
            XCTAssertTrue(readings.contains(expected), "Expected \(expected) in the actual title block")
        }
    }

    func testArchitecturalRegionBenchmark() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_ARCHITECTURAL_FIXTURE"] else { throw XCTSkip("Provide local Architectural PDF") }
        let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)))
        for index in 0..<2 {
            let page = try XCTUnwrap(document.page(at: index))
            let box = page.bounds(for: .cropBox)
            let rect = CGRect(x: box.maxX-260,y: box.minY+15,width: 230,height: 120)
            let start = Date(); let expected = try reference(page, rect: rect, scale: 4)
            let baseline = Date().timeIntervalSince(start)
            let next = Date(); let actual = try XCTUnwrap(PDFRegionRasterizer.render(page: page, box: .cropBox, rect: rect))
            print("ARCHITECTURAL REGION page=\(index+1) full=\(baseline)s region=\(Date().timeIntervalSince(next))s")
            let a = try pixels(actual), b = try pixels(expected)
            XCTAssertEqual(a.count, b.count)
            let difference = zip(a,b).reduce(0.0) { $0 + Double(abs(Int($1.0)-Int($1.1))) } / Double(a.count)
            print("ARCHITECTURAL REGION mean pixel difference=\(difference)")
            XCTAssertLessThan(difference, 0.5)
        }
    }
}
