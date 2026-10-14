import AppKit
import PDFKit
import CoreText
import XCTest
@testable import Drawbridge

@MainActor
final class ArchitecturalDimensionTests: XCTestCase {
    func testImperialDistanceRoundsToReducedSixteenthsAndCarries() {
        let cases: [(Double, String)] = [
            (14, "14'-0\""), (22 + 10.5/12, "22'-10 1/2\""),
            (1 + 0.0625/12, "1'-0 1/16\""), (0.75/12, "0'-0 3/4\""),
            (2 + 11.99/12, "3'-0\""), (0.03/12, "0'-0\""),
            (0.032/12, "0'-0 1/16\"")
        ]
        for (feet, expected) in cases {
            let measurement = DrawingMeasurement(kind: .perimeter,
                scale: DrawingScale(unitsPerPoint: feet/200, unit: "ft", name: "test"), closed: false)
            XCTAssertEqual(measurement.label(points: [CGPoint(x: 80,y: 120), CGPoint(x: 280,y: 120)]), expected)
        }
    }

    func testVerticalLabelsFollowEndpointsAtEveryPageRotation() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "8'-0\"", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        for rotation in [0, 90, 180, 270] {
            for points in [[CGPoint(x: 120,y: 80), CGPoint(x: 120,y: 280)], [CGPoint(x: 80,y: 120), CGPoint(x: 280,y: 120)]] {
                let bounds = CGRect(x: min(points[0].x,points[1].x)-24, y: min(points[0].y,points[1].y)-24, width: abs(points[1].x-points[0].x)+48, height: abs(points[1].y-points[0].y)+48)
                let layout = MeasurementAppearance.DimensionLayout(points: points, bounds: bounds, rotation: rotation, line: line, lineWidth: 1)
                let reverse = MeasurementAppearance.DimensionLayout(points: points.reversed(), bounds: bounds, rotation: rotation, line: line, lineWidth: 1)
                let dx = points[1].x-points[0].x, dy = points[1].y-points[0].y
                XCTAssertEqual(layout.cosine*dy-layout.sine*dx, 0, accuracy: 0.000001, "Text must follow dimension, not page horizontal")
                XCTAssertEqual(layout.cosine, reverse.cosine, accuracy: 0.000001)
                XCTAssertEqual(layout.sine, reverse.sine, accuracy: 0.000001)
                let angle = CGFloat(rotation)*CGFloat.pi/180
                let screenX = layout.cosine*cos(angle)+layout.sine*sin(angle)
                let screenY = -layout.cosine*sin(angle)+layout.sine*cos(angle)
                XCTAssertTrue(screenX > 0.000001 || (abs(screenX) < 0.000001 && screenY > 0), "Vertical text reads bottom-to-top")
            }
        }
        let document = PDFDocument(); let page = PDFPage(); document.insert(page, at: 0)
        let controller = RectangleMarkupController(); controller.bind(to: document)
        let annotation = try XCTUnwrap(controller.createMeasurement(on: page, points: [CGPoint(x: 120,y: 80), CGPoint(x: 120,y: 280)], kind: .perimeter, closed: false, scale: DrawingScale(unitsPerPoint: 0.04, unit: "ft", name: "test")))
        let pixels = try render(annotation)
        XCTAssertFalse((90...104).contains { x in (165...195).contains { pixels.ink(x,$0) } }, "No horizontal glyphs extending left of vertical text")
        let record = try XCTUnwrap(RectangleMarkupRecord.capture(document).first)
        XCTAssertTrue(MeasurementAppearance.pdf(record).contains("0.0000000000 1.0000000000 -1.0000000000 0.0000000000"), "Saved text has the same bottom-to-top transform")
    }

    func testAllImperialLinearLabelsUseArchitecturalFormatting() {
        let scale = DrawingScale(unitsPerPoint: 1, unit: "ft", name: "test")
        XCTAssertEqual(DrawingMeasurement(kind: .perimeter, scale: scale, closed: false).label(points: [.zero, CGPoint(x: 3,y: 0), CGPoint(x: 3,y: 4)]), "7'-0\"")
        XCTAssertEqual(DrawingMeasurement(kind: .perimeter, scale: scale, closed: true).label(points: [.zero, CGPoint(x: 3,y: 0), CGPoint(x: 3,y: 4)]), "12'-0\"")
    }

    func testAreaAndMetricLabelsAreUnchanged() {
        let scale = DrawingScale(unitsPerPoint: 1, unit: "ft", name: "test")
        XCTAssertEqual(DrawingMeasurement(kind: .area, scale: scale, closed: true).label(points: [.zero, CGPoint(x: 3,y: 0), CGPoint(x: 3,y: 4)]), "Area: 6.00 sq ft")
        XCTAssertEqual(DrawingMeasurement(kind: .perimeter, scale: DrawingScale(unitsPerPoint: 0.07, unit: "m", name: "metric"), closed: false).label(points: [.zero, CGPoint(x: 200,y: 0)]), "Length: 14.00 m")
    }

    func testLiveDistanceHasFilledOutwardArrowsAsymmetricTicksAndCenteredText() throws {
        let document = PDFDocument(); let page = PDFPage(); document.insert(page, at: 0)
        let controller = RectangleMarkupController(); controller.bind(to: document)
        let annotation = try XCTUnwrap(controller.createMeasurement(on: page,
            points: [CGPoint(x: 80,y: 120), CGPoint(x: 280,y: 120)], kind: .perimeter, closed: false,
            scale: DrawingScale(unitsPerPoint: 0.07, unit: "ft", name: "test")))
        annotation.color = .systemRed
        let pixels = try render(annotation)
        XCTAssertTrue(pixels.ink(80, 109), "Long extension below endpoint")
        XCTAssertTrue(pixels.ink(80, 123), "Short extension above endpoint")
        XCTAssertTrue(pixels.ink(86, 122), "Filled arrow base is inside measured span")
        XCTAssertFalse(pixels.ink(74, 122), "No exterior arrow base")
        XCTAssertFalse(pixels.ink(162, 120), "Original InkList must not draw through the label gap")
        let labelRows = (90...135).filter { y in (155...205).contains { pixels.ink($0, y) } }
        XCTAssertEqual(Double(try XCTUnwrap(labelRows.first) + XCTUnwrap(labelRows.last))/2, 120, accuracy: 2,
            "Text must be centered on the dimension, not placed below it")
    }

    func testPartialOpacityIsAppliedOnceToLiveStrokeArrowsAndText() throws {
        let document = PDFDocument(); let page = PDFPage(); document.insert(page, at: 0)
        let controller = RectangleMarkupController(); controller.bind(to: document)
        let annotation = try XCTUnwrap(controller.createMeasurement(on: page,
            points: [CGPoint(x: 80,y: 120), CGPoint(x: 280,y: 120)], kind: .perimeter, closed: false,
            scale: DrawingScale(unitsPerPoint: 0.07, unit: "ft", name: "test")))
        annotation.color = .black
        MarkupStyle.apply(pattern: .solid, opacity: 1, to: annotation)
        let opaque = try render(annotation)
        MarkupStyle.apply(pattern: .solid, opacity: 0.5, to: annotation)
        let translucent = try render(annotation)
        for (name, xs, ys) in [("stroke", 105...115, 119...120),
                               ("arrow", 86...87, 122...122),
                               ("text", 170...190, 116...124)] {
            let full = opaque.darkness(xs, ys)
            XCTAssertGreaterThan(full, 0.1, name)
            XCTAssertEqual(translucent.darkness(xs, ys) / full, 0.5, accuracy: 0.05,
                           "\(name) must apply selected opacity once, not square it")
        }
        XCTAssertFalse(translucent.ink(162, 120), "Label gap remains transparent")
    }

    func testSelectedDashPatternIsPreservedInLiveSegmentsTicksAndSavedAppearance() throws {
        let document = PDFDocument(); let page = PDFPage(); document.insert(page, at: 0)
        let controller = RectangleMarkupController(); controller.bind(to: document)
        let annotation = try XCTUnwrap(controller.createMeasurement(on: page,
            points: [CGPoint(x: 80,y: 120), CGPoint(x: 280,y: 120)], kind: .perimeter, closed: false,
            scale: DrawingScale(unitsPerPoint: 0.07, unit: "ft", name: "test")))
        annotation.color = .black
        let border = try XCTUnwrap(annotation.border); border.lineWidth = 2; annotation.border = border
        for pattern in MarkupLinePattern.allCases {
            MarkupStyle.apply(pattern: pattern, opacity: 1, to: annotation)
            let record = try XCTUnwrap(RectangleMarkupRecord.capture(document).first)
            let dash = pattern.dash(width: 2).map { String($0) }.joined(separator: " ")
            XCTAssertTrue(MeasurementAppearance.pdf(record).contains("[\(dash)] 0 d"), pattern.rawValue)
        }
        MarkupStyle.apply(pattern: .dashed, opacity: 1, to: annotation)
        let pixels = try render(annotation)
        XCTAssertTrue(pixels.ink(108, 120), "Dash on split dimension segment")
        XCTAssertFalse(pixels.ink(112, 120), "Dash gap on split dimension segment")
        XCTAssertTrue(pixels.ink(80, 110), "Dash on extension tick")
        XCTAssertFalse(pixels.ink(80, 122), "Dash gap on extension tick")
        XCTAssertTrue(pixels.ink(86, 122), "Arrow stays filled despite dash pattern")
        XCTAssertGreaterThan(pixels.darkness(170...190, 116...124), 0.5, "Text stays filled")
    }

    func testExplicitSelectedLineWeightIsPreservedExceptForShortSpanFitting() throws {
        let document = PDFDocument(); let page = PDFPage(); document.insert(page, at: 0)
        let controller = RectangleMarkupController(); controller.bind(to: document)
        let points = [CGPoint(x: 80,y: 120), CGPoint(x: 280,y: 120)]
        let annotation = try XCTUnwrap(controller.createMeasurement(on: page, points: points, kind: .perimeter, closed: false,
            scale: DrawingScale(unitsPerPoint: 0.07, unit: "ft", name: "test")))
        let border = try XCTUnwrap(annotation.border); border.lineWidth = 4; annotation.border = border
        annotation.color = .black
        XCTAssertTrue(try render(annotation).ink(110, 121), "Selected four-point stroke must not be capped at one")
        let record = try XCTUnwrap(RectangleMarkupRecord.capture(document).first)
        XCTAssertTrue(MeasurementAppearance.pdf(record).contains("4.0000000000 w"))
        XCTAssertEqual(RectangleMarkupRecord.vertices(annotation), points)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "14'-0\""))
        let short = MeasurementAppearance.DimensionLayout(points: [.zero, CGPoint(x: 4,y: 0)],
            bounds: CGRect(x: -24,y: -24,width: 52,height: 48), rotation: 0, line: line, lineWidth: 4)
        XCTAssertLessThanOrEqual(short.strokeWidth, 0.1)
    }

    func testSavedDimensionsPreserveEndpointsAndContainCompleteAppearanceAtEveryRotation() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("Dimensions-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        var media = CGRect(x: 0,y: 0,width: 400,height: 400)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &media, nil))
        for _ in 0..<4 { context.beginPDFPage(nil); context.endPDFPage() }; context.closePDF()
        let base = try XCTUnwrap(PDFDocument(url: source))
        for index in 0..<4 { base.page(at: index)?.rotation = index*90 }
        XCTAssertTrue(base.write(to: source))
        let document = try XCTUnwrap(PDFDocument(url: source))
        let controller = RectangleMarkupController(); controller.bind(to: document)
        let pairs = [ [CGPoint(x: 80,y: 120), CGPoint(x: 280,y: 120)],
                      [CGPoint(x: 120,y: 80), CGPoint(x: 120,y: 280)],
                      [CGPoint(x: 80,y: 80), CGPoint(x: 280,y: 280)],
                      [CGPoint(x: 280,y: 120), CGPoint(x: 80,y: 120)],
                      [CGPoint(x: 180,y: 180), CGPoint(x: 184,y: 182)] ]
        for index in 0..<4 {
            let page = try XCTUnwrap(document.page(at: index)); page.rotation = index*90
            for pair in pairs {
                let annotation = try XCTUnwrap(controller.createMeasurement(on: page, points: pair, kind: .perimeter, closed: false,
                    scale: DrawingScale(unitsPerPoint: 0.07, unit: "ft", name: "test")))
                annotation.color = .magenta
            }
        }
        let records = RectangleMarkupRecord.capture(document)
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: source, pageLabels: [:], records: records))
        let reopened = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(RectangleMarkupRecord.capture(reopened), records)
        for index in 0..<4 {
            let page = try XCTUnwrap(reopened.page(at: index))
            let dictionary = try XCTUnwrap(page.pageRef?.dictionary)
            var annotations: CGPDFArrayRef?; XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "Annots", &annotations))
            let array = try XCTUnwrap(annotations)
            for i in 0..<CGPDFArrayGetCount(array) {
                var annotation: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFArrayGetDictionary(array, i, &annotation))
                var appearance: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(annotation), "AP", &appearance))
                var stream: CGPDFStreamRef?; XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(appearance), "N", &stream))
                var format = CGPDFDataFormat.raw
                let bytes = try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(stream), &format)) as Data
                let drawing = String(decoding: bytes, as: UTF8.self)
                let record = records.filter { $0.pageIndex == index }[i]
                XCTAssertEqual(drawing, MeasurementAppearance.pdf(record), "Saved appearance must not prepend an unsplit polyline")
                XCTAssertEqual(drawing.components(separatedBy: " h f").count-1, 2, "Two filled arrowheads")
                XCTAssertFalse(drawing.contains("1 1 1 rg"), "Gap must not white-out the source drawing")
                XCTAssertTrue(drawing.contains("0.0 1.0 rg") || drawing.contains("1.0 0.0 1.0 rg"), "Selected magenta is preserved")
                XCTAssertFalse(drawing.contains("Length:"))
            }
        }
        let editing = RectangleMarkupController(); editing.bind(to: reopened)
        let page = try XCTUnwrap(reopened.page(at: 0)), annotation = try XCTUnwrap(page.annotations.first)
        XCTAssertTrue(annotation is DrawbridgeMeasuredPathAnnotation)
        editing.undo.groupsByEvent = false; editing.undo.beginUndoGrouping()
        editing.setVertexPositions([CGPoint(x: 80,y: 120), CGPoint(x: 180,y: 120)], of: annotation, on: page)
        editing.undo.endUndoGrouping()
        XCTAssertEqual(annotation.contents, "7'-0\"")
        editing.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.vertices(annotation), pairs[0])
        editing.undo.redo(); XCTAssertEqual(annotation.contents, "7'-0\"")
    }

    func testDimensionLayoutFitsAndIsStableForReversedVerticalAndShortSpans() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "22'-10 1/2\"", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        let glyph = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let pairs = [[CGPoint(x: 80,y: 120), CGPoint(x: 280,y: 120)],
                     [CGPoint(x: 120,y: 80), CGPoint(x: 120,y: 280)],
                     [CGPoint(x: 80,y: 80), CGPoint(x: 280,y: 280)],
                     [CGPoint(x: 180,y: 180), CGPoint(x: 184,y: 182)]]
        for rotation in [0, 90, 180, 270] {
            for pair in pairs {
                let bounds = CGRect(x: min(pair[0].x,pair[1].x)-24, y: min(pair[0].y,pair[1].y)-24,
                                    width: abs(pair[0].x-pair[1].x)+48, height: abs(pair[0].y-pair[1].y)+48)
                let layout = MeasurementAppearance.DimensionLayout(points: pair, bounds: bounds, rotation: rotation, line: line, lineWidth: 2)
                let reversed = MeasurementAppearance.DimensionLayout(points: Array(pair.reversed()), bounds: bounds, rotation: rotation, line: line, lineWidth: 2)
                XCTAssertEqual(layout.arrows, reversed.arrows)
                XCTAssertTrue(pair.contains(layout.arrows[0][0]))
                XCTAssertTrue(pair.contains(layout.arrows[1][0]))
                XCTAssertNotEqual(layout.arrows[0][0], layout.arrows[1][0])
                XCTAssertGreaterThan(layout.factor, 0)
                XCTAssertLessThanOrEqual(layout.factor, 1)
                for segment in layout.segments { XCTAssertTrue(bounds.contains(segment.0)); XCTAssertTrue(bounds.contains(segment.1)) }
                for x in [glyph.minX-layout.width/2, glyph.maxX-layout.width/2] {
                    for y in [glyph.minY+layout.baseline, glyph.maxY+layout.baseline] {
                        let p = CGPoint(x: layout.center.x+layout.factor*(x*layout.cosine-y*layout.sine),
                                        y: layout.center.y+layout.factor*(x*layout.sine+y*layout.cosine))
                        XCTAssertTrue(bounds.contains(p), "Rotated label must fit the saved appearance box")
                    }
                }
            }
        }
    }

    private struct Pixels {
        let bytes: [UInt8]
        func darkness(_ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>) -> Double {
            ys.flatMap { y in xs.map { x in
                1 - Double(bytes[((399-y)*400+x)*4]) / 255
            } }.max() ?? 0
        }
        func ink(_ x: Int, _ y: Int) -> Bool {
            // CoreGraphics bitmap storage is top-down; sample in PDF coordinates.
            let offset = ((399-y)*400+x)*4
            return bytes[offset] < 240 || bytes[offset+1] < 240 || bytes[offset+2] < 240
        }
    }
    private func render(_ annotation: PDFAnnotation) throws -> Pixels {
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 1600,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0,y: 0,width: 400,height: 400))
        annotation.draw(with: .mediaBox, in: context)
        return Pixels(bytes: Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: 640000)))
    }
}
