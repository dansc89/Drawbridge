import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class PolygonPreviewRenderingTests: XCTestCase {
    private let rotations = [0, 90, 180, 270]
    private let polygonBounds = CGRect(x: 50, y: 60, width: 100, height: 80)

    private func fixture(rotation: Int) throws -> (PDFPage, DrawbridgePolygonAnnotation) {
        // In-memory, synthetic geometry only; no document, window, or disk PDF needed.
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 320, height: 240), for: .mediaBox)
        page.rotation = rotation
        let polygon = DrawbridgePolygonAnnotation(bounds: polygonBounds,
            forType: PDFAnnotationSubtype(rawValue: "/Polygon"), withProperties: nil)
        polygon.color = .red
        let border = PDFBorder(); border.lineWidth = 2; polygon.border = border
        polygon.setValue(RectangleMarkupRecord.prefix + "polygon-preview-test", forAnnotationKey: RectangleMarkupRecord.identityKey)
        RectangleMarkupRecord.setVertices([
            CGPoint(x: 50, y: 60), CGPoint(x: 150, y: 60),
            CGPoint(x: 150, y: 140), CGPoint(x: 50, y: 140)
        ], on: polygon)
        let measurement = DrawingMeasurement(kind: .area,
            scale: DrawingScale(unitsPerPoint: 0.1, unit: "ft", name: "Synthetic"), closed: true)
        polygon.setValue(MeasurementMetadata.json(measurement), forAnnotationKey: MeasurementMetadata.measurementKey)
        XCTAssertNotNil(MeasurementMetadata.measurement(polygon), "Fixture must actually render an area label")
        page.addAnnotation(polygon)
        return (page, polygon)
    }

    private func displayRect(_ page: PDFPage) -> CGRect {
        let size = page.bounds(for: .mediaBox).size
        return CGRect(origin: .zero, size: page.rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width))
    }

    private struct Ink {
        var outline = 0
        var label = 0
        var total: Int { outline + label }
    }

    private func render(_ page: PDFPage, _ polygon: DrawbridgePolygonAnnotation,
                        transform: CGAffineTransform = .identity, clip: CGRect? = nil,
                        draw: ((CGContext) -> Void)? = nil) throws -> Ink {
        let rect = displayRect(page), width = Int(rect.width), height = Int(rect.height)
        func pixels() throws -> [UInt8] {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor); context.fill(rect)
            context.concatenate(transform)
            if let clip { context.clip(to: clip) }
            let beforeCTM = context.ctm, beforeClip = context.boundingBoxOfClipPath
            if let draw { draw(context) } else { polygon.draw(with: .mediaBox, in: context) }
            XCTAssertEqual(context.ctm, beforeCTM, "Drawing must preserve caller's transform")
            XCTAssertEqual(context.boundingBoxOfClipPath, beforeClip, "Drawing must preserve caller's clip")
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: bytes, count: height * context.bytesPerRow))
        }
        let labeled = try pixels()
        let measurement = try XCTUnwrap(polygon.value(forAnnotationKey: MeasurementMetadata.measurementKey))
        polygon.removeValue(forAnnotationKey: MeasurementMetadata.measurementKey)
        defer { polygon.setValue(measurement, forAnnotationKey: MeasurementMetadata.measurementKey) }
        let unlabeled = try pixels()
        // Differential pixels isolate actual label glyphs from the polygon, without
        // assuming CoreText's text orientation or bitmap row-coordinate convention.
        var ink = Ink()
        for offset in stride(from: 1, to: labeled.count, by: 4) {
            if unlabeled[offset] < 245 { ink.outline += 1 }
            if Int(labeled[offset]) + 10 < Int(unlabeled[offset]) { ink.label += 1 }
        }
        return ink
    }

    private func assertPainted(_ ink: Ink, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(ink.outline, 100, "Outline: " + message, file: file, line: line)
        XCTAssertGreaterThan(ink.label, 10, "Area label: " + message, file: file, line: line)
    }

    func testUnscopedRotatedWholePageIdentityCallbackPaintsNeitherPolygonNorLabel() throws {
        for rotation in rotations where rotation != 0 {
            let (page, polygon) = try fixture(rotation: rotation)
            let ink = try render(page, polygon)
            XCTAssertEqual(ink.outline, 0, "No cached polygon copy at rotation \(rotation)")
            XCTAssertEqual(ink.label, 0, "No cached area label at rotation \(rotation)")
        }
    }

    func testNativePrintContextPreservesWholePagePolygonAndLabel() throws {
        _ = NSApplication.shared
        let previous = NSPrintOperation.current
        let operation = NSPrintOperation(view: NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 240)))
        NSPrintOperation.current = operation
        defer { NSPrintOperation.current = previous }
        for rotation in rotations {
            let (page, polygon) = try fixture(rotation: rotation)
            assertPainted(try render(page, polygon), "native print, rotation \(rotation)")
        }
    }

    func testUnrotatedWholePageIdentityCallbackStillPaints() throws {
        let (page, polygon) = try fixture(rotation: 0)
        assertPainted(try render(page, polygon), "unrotated full page")
    }

    func testOrdinaryPageSpaceAnnotationCallbacksStillPaintAtEveryRotation() throws {
        for rotation in rotations {
            let (page, polygon) = try fixture(rotation: rotation)
            assertPainted(try render(page, polygon, transform: page.transform(for: .mediaBox),
                clip: polygonBounds.insetBy(dx: -3, dy: -3)), "page-space annotation, rotation \(rotation)")
        }
    }

    func testExplicitPreviewAndVectorScopesPreserveWholePagePainting() throws {
        for rotation in rotations {
            let (page, polygon) = try fixture(rotation: rotation)
            // These controls preserve existing polygon coordinates. This fix does not
            // redefine the display-space transform contract of explicit rendering.
            assertPainted(try render(page, polygon, draw: { context in
                SnapshotPageRendering.preview { polygon.draw(with: .mediaBox, in: context) }
            }), "explicit preview, rotation \(rotation)")
            XCTAssertFalse(SnapshotPageRendering.isPreview)
            assertPainted(try render(page, polygon, draw: { context in
                SnapshotPageRendering.vector { polygon.draw(with: .mediaBox, in: context) }
            }), "vector output, rotation \(rotation)")
            XCTAssertFalse(SnapshotPageRendering.isVectorOutput)
            if rotation != 0 {
                XCTAssertEqual(try render(page, polygon).total, 0, "Explicit scope must not leak")
            }
        }
    }

    func testPartialAndNonmatchingContextsStillPaintAtEveryRotation() throws {
        for rotation in rotations {
            let (page, polygon) = try fixture(rotation: rotation)
            let full = displayRect(page)
            let clips = [polygonBounds.insetBy(dx: -3, dy: -3),
                full.insetBy(dx: 2, dy: 3),
                CGRect(x: 1, y: 0, width: full.width - 1, height: full.height),
                CGRect(x: 0, y: 1, width: full.width, height: full.height - 1)]
            for clip in clips {
                assertPainted(try render(page, polygon, clip: clip), "clip \(clip), rotation \(rotation)")
            }
            if rotation % 180 != 0 {
                assertPainted(try render(page, polygon, clip: page.bounds(for: .mediaBox)),
                    "unswapped page size, rotation \(rotation)")
            }
            // Even a near-identity CTM is not the exact PDFKit callback signature.
            assertPainted(try render(page, polygon, transform: CGAffineTransform(translationX: 0.25, y: 0.25)),
                "translated CTM, rotation \(rotation)")
            assertPainted(try render(page, polygon, transform: CGAffineTransform(scaleX: 0.9, y: 0.9)),
                "scaled CTM, rotation \(rotation)")
        }
    }

    func testInternalPreviewClipToleranceSuppressesBothOutlineAndLabel() throws {
        for rotation in rotations where rotation != 0 {
            let (page, polygon) = try fixture(rotation: rotation)
            let ink = try render(page, polygon, clip: displayRect(page).insetBy(dx: 0.25, dy: 0.25))
            XCTAssertEqual(ink.outline, 0, "Sub-point clip rounding, rotation \(rotation)")
            XCTAssertEqual(ink.label, 0, "Sub-point label clip rounding, rotation \(rotation)")
        }
    }
}
