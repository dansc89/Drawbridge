import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class DrawingMeasurementTests: XCTestCase {
    let points = [CGPoint(x: 100,y: 100), CGPoint(x: 190,y: 100), CGPoint(x: 190,y: 280), CGPoint(x: 100,y: 280)]
    var eighth: DrawingScale { DrawingScale.architectural(inches: 0.125, name: "1/8\" = 1'")! }
    var quarter: DrawingScale { DrawingScale.architectural(inches: 0.25, name: "1/4\" = 1'")! }

    func testRotatedMeasurementAppearanceUsesValidPDFMatrixNumbers() {
        for rotation in [0, 90, 180, 270] {
            var record = RectangleMarkupRecord(id: "rotation-test", pageIndex: 0,
                bounds: CGRect(x: 100, y: 100, width: 180, height: 90),
                red: 1, green: 0, blue: 0, lineWidth: 2)
            record.vertices = points
            record.measurement = DrawingMeasurement(kind: .area, scale: eighth, closed: true)
            record.textRotation = rotation
            let appearance = MeasurementAppearance.pdf(record)
            let matrix = appearance.components(separatedBy: " cm")[0].dropFirst(2).split(separator: " ")
            XCTAssertEqual(matrix.count, 6)
            for number in matrix {
                XCTAssertNotNil(Double(number))
                XCTAssertFalse(number.lowercased().contains("e"), "PDF numbers cannot use exponent notation")
            }
            let values = matrix.compactMap { Double($0) }
            XCTAssertEqual(values[4], 90, accuracy: 1e-8)
            XCTAssertEqual(values[5], 45, accuracy: 1e-8)
            if rotation == 90 { XCTAssertGreaterThan(values[1], 0); XCTAssertLessThan(values[2], 0) }
            if rotation == 270 { XCTAssertLessThan(values[1], 0); XCTAssertGreaterThan(values[2], 0) }
        }
    }

    func testShiftConstrainsAllDrawingToolsAtEveryPageRotation() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1100,height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        let view = MarkupPDFView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view); view.setMarkupDocument(document)
        let session = view.rectangleMarkup
        let start = CGPoint(x: 100,y: 100), diagonal = CGPoint(x: 190,y: 170)
        for index in 0..<4 {
            let page = try XCTUnwrap(document.page(at: index)); view.go(to: page); window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
            session.applyDrawingScale(eighth, to: [page])
            func location(_ point: CGPoint) -> CGPoint { view.convert(point,from: page) }
            for tool in [RectangleMarkupController.Tool.line, .arrow] {
                session.tool = tool
                XCTAssertTrue(session.pointerDown(at: location(start)))
                session.pointerMoved(at: location(diagonal), modifiers: .shift)
                XCTAssertTrue(session.pointerDown(at: location(diagonal), modifiers: .shift))
                let annotation = try XCTUnwrap(session.selected)
                XCTAssertEqual(annotation.startPoint.y,annotation.endPoint.y,accuracy: 1e-8)
                XCTAssertEqual(abs(annotation.startPoint.x-annotation.endPoint.x),90,accuracy: 1e-8)
            }
            for tool in [RectangleMarkupController.Tool.polyline, .polygon, .area, .perimeter] {
                session.tool = tool
                let inputs = [start,diagonal,CGPoint(x: 230,y: 280),CGPoint(x: 100,y: 230)]
                for point in inputs { XCTAssertTrue(session.pointerDown(at: location(point), modifiers: .shift)) }
                XCTAssertTrue(session.finishPolyline(closed: tool != .polyline))
                let vertices = RectangleMarkupRecord.vertices(try XCTUnwrap(session.selected))
                XCTAssertEqual(vertices.count,4)
                for (a,b) in zip(vertices,vertices.dropFirst()) { XCTAssertTrue(abs(a.x-b.x)<1e-8 || abs(a.y-b.y)<1e-8) }
                if tool == .area { XCTAssertEqual(session.selected?.contents,"Area: 200.00 sq ft") }
                if tool == .perimeter { XCTAssertEqual(session.selected?.contents,"Perimeter: 60.00 ft") }
            }
            session.tool = .pen
            XCTAssertTrue(session.pointerDown(at: location(start), modifiers: .shift))
            for point in [CGPoint(x: 140,y: 105),CGPoint(x: 175,y: 90),diagonal] { XCTAssertTrue(session.pointerDragged(at: location(point), modifiers: .shift)) }
            XCTAssertTrue(session.pointerUp(at: location(diagonal), modifiers: .shift))
            let ink = try XCTUnwrap(page.annotations.last { $0.type == "Ink" && MeasurementMetadata.measurement($0) == nil })
            let vertices = RectangleMarkupRecord.vertices(ink)
            XCTAssertEqual(vertices.count,2)
            XCTAssertEqual(vertices[0].y,vertices[1].y,accuracy: 1e-8)
            XCTAssertEqual(vertices[1].x,190,accuracy: 1e-8)
            for tool in [RectangleMarkupController.Tool.rectangle, .ellipse] {
                session.tool = tool
                XCTAssertTrue(session.pointerDown(at: location(start)))
                XCTAssertTrue(session.pointerDragged(at: location(diagonal), modifiers: .shift))
                XCTAssertTrue(session.pointerUp(at: location(diagonal), modifiers: .shift))
                let shape = try XCTUnwrap(session.selected)
                XCTAssertEqual(shape.bounds.width,shape.bounds.height,accuracy: 1e-8)
                XCTAssertEqual(shape.bounds.width,90,accuracy: 1e-8)
            }
            session.tool = .line
            XCTAssertTrue(session.pointerDown(at: location(start)))
            XCTAssertTrue(session.pointerDown(at: location(diagonal)))
            let free = try XCTUnwrap(session.selected)
            XCTAssertEqual(abs(free.startPoint.y-free.endPoint.y),70,accuracy: 1e-8,"Releasing Shift restores unconstrained drawing")
            var calibrated: CGPoint?
            session.onCalibrationCompleted = { _,_,end in calibrated = end }
            session.tool = .calibrate
            XCTAssertTrue(session.pointerDown(at: location(start)))
            XCTAssertTrue(session.pointerDown(at: location(CGPoint(x: 170,y: 190)), modifiers: .shift))
            XCTAssertEqual(try XCTUnwrap(calibrated).x,start.x,accuracy: 1e-8)
        }
    }

    func testPenShiftTransitionsCancelAndSaveRoundTrip() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        let page = try XCTUnwrap(document.page(at: 0))
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1100,height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        let view = MarkupPDFView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view); view.setMarkupDocument(document)
        view.go(to: page); window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
        let session = view.rectangleMarkup
        func location(_ x: CGFloat, _ y: CGFloat) -> CGPoint { view.convert(CGPoint(x: x,y: y),from: page) }
        session.tool = .pen
        XCTAssertTrue(session.pointerDown(at: location(100,100)))
        XCTAssertTrue(session.pointerDragged(at: location(120,120)))
        XCTAssertTrue(session.pointerDragged(at: location(150,125), modifiers: .shift))
        XCTAssertTrue(session.pointerDragged(at: location(180,135), modifiers: .shift))
        XCTAssertTrue(session.pointerDragged(at: location(200,150)))
        XCTAssertTrue(session.pointerUp(at: location(220,160)))
        let ink = try XCTUnwrap(page.annotations.last { $0.type == "Ink" })
        let expected = [CGPoint(x:100,y:100),CGPoint(x:120,y:120),CGPoint(x:180,y:120),CGPoint(x:200,y:150),CGPoint(x:220,y:160)]
        let vertices = RectangleMarkupRecord.vertices(ink)
        XCTAssertEqual(vertices.count,expected.count)
        for (actual,target) in zip(vertices,expected) {
            XCTAssertEqual(actual.x,target.x,accuracy:1e-8)
            XCTAssertEqual(actual.y,target.y,accuracy:1e-8)
        }
        let count = page.annotations.count
        XCTAssertTrue(session.pointerDown(at: location(300,100)))
        XCTAssertTrue(session.pointerDragged(at: location(310,180), modifiers: .shift))
        session.escape()
        XCTAssertEqual(page.annotations.count,count,"Escape must discard the pending stroke")
        session.tool = .pen
        XCTAssertTrue(session.pointerDown(at: location(300,300)))
        XCTAssertTrue(session.pointerDragged(at: location(340,360)))
        XCTAssertTrue(session.pointerUp(at: location(370,390)))
        let freeInk = try XCTUnwrap(page.annotations.last { $0.type == "Ink" })
        XCTAssertEqual(RectangleMarkupRecord.vertices(freeInk).last?.x,370)
        XCTAssertEqual(RectangleMarkupRecord.vertices(freeInk).last?.y,390,"Cancelled Shift state must not constrain the next stroke")
        XCTAssertTrue(PDFRectangleWriter.write(document: document,source: source,destination: source,pageLabels: [:],records: RectangleMarkupRecord.capture(document)))
        let reopened = try XCTUnwrap(PDFDocument(url: source))
        let restored = try XCTUnwrap(reopened.page(at: 0)?.annotations.first { $0.type == "Ink" })
        let restoredVertices = RectangleMarkupRecord.vertices(restored)
        XCTAssertEqual(restoredVertices.count,expected.count)
        for (actual,target) in zip(restoredVertices,expected) {
            XCTAssertEqual(actual.x,target.x,accuracy:0.001)
            XCTAssertEqual(actual.y,target.y,accuracy:0.001)
        }
        XCTAssertEqual(reopened.pageCount,document.pageCount)
    }

    func testMeasurementMenusRequireAnEditableDocument() {
        let controller = MainViewController(); controller.loadViewIfNeeded()
        let actions = [#selector(MainViewController.commandSetPageDrawingScale(_:)), #selector(MainViewController.commandCalibrateDrawingScale(_:)), #selector(MainViewController.areaMeasure(_:)), #selector(MainViewController.perimeterMeasure(_:))]
        for action in actions { XCTAssertFalse(controller.validateMenuItem(NSMenuItem(title: "Measurement", action: action, keyEquivalent: ""))) }
        let document = PDFDocument(); document.insert(PDFPage(), at: 0)
        controller.pdfView.setMarkupDocument(document)
        controller.pdfView.rectangleMarkup.canEdit = { true }
        for action in actions { XCTAssertTrue(controller.validateMenuItem(NSMenuItem(title: "Measurement", action: action, keyEquivalent: ""))) }
        controller.pdfView.rectangleMarkup.canEdit = { false }
        for action in actions { XCTAssertFalse(controller.validateMenuItem(NSMenuItem(title: "Measurement", action: action, keyEquivalent: ""))) }
    }
    func testDistanceLabelStaysOffTheStrokeAndInsideBounds() {
        XCTAssertEqual(MeasurementAppearance.labelOffset(bounds: CGRect(x: 0,y: 0,width: 150,height: 50), rotation: 0, closed: false),12)
        XCTAssertEqual(MeasurementAppearance.labelOffset(bounds: CGRect(x: 0,y: 0,width: 50,height: 150), rotation: 90, closed: false),12)
        XCTAssertEqual(MeasurementAppearance.labelOffset(bounds: CGRect(x: 0,y: 0,width: 150,height: 18), rotation: 0, closed: false),0)
        XCTAssertEqual(MeasurementAppearance.labelOffset(bounds: CGRect(x: 0,y: 0,width: 150,height: 50), rotation: 0, closed: true),0)
    }
    func testCalibrationInputAndResizedDrawing() throws {
        XCTAssertEqual(CalibrationDistance.parse("20' 6\"", unit: "ft"), 20.5)
        XCTAssertEqual(CalibrationDistance.parse("20'-6 1/2\"", unit: "ft"), 20 + 6.5/12)
        XCTAssertEqual(CalibrationDistance.parse("20′ 6″", unit: "ft"), 20.5)
        XCTAssertEqual(CalibrationDistance.parse("2.54", unit: "m"), 2.54)
        for input in ["20' garbage", "20' 1/0\"", "20' 6 1/0\"", "20' 14\"", "20' 6 2/1\"", "-1", "0", "nan", "20 feet", "1/0", ""] {
            XCTAssertNil(CalibrationDistance.parse(input, unit: "ft"), input)
        }
        XCTAssertNil(CalibrationDistance.parse("20' 6\"", unit: "m"))
        let scale = try XCTUnwrap(DrawingScale.calibrated(from: points[0], to: points[1], distance: 10, unit: "ft"))
        XCTAssertEqual(scale.unitsPerPoint, eighth.unitsPerPoint, accuracy: 1e-12)
        let reduced = points.map { CGPoint(x: $0.x*0.5, y: $0.y*0.5) }
        let resized = try XCTUnwrap(DrawingScale.calibrated(from: reduced[0], to: reduced[1], distance: 10, unit: "ft"))
        XCTAssertEqual(DrawingMeasurement(kind: .area, scale: resized, closed: true).value(points: reduced), 200, accuracy: 1e-10)
        XCTAssertEqual(DrawingMeasurement(kind: .perimeter, scale: resized, closed: true).value(points: reduced), 60, accuracy: 1e-10)
        XCTAssertNil(DrawingScale.calibrated(from: .zero, to: .zero, distance: 10, unit: "ft"))
        XCTAssertNil(DrawingScale.calibrated(from: .zero, to: CGPoint(x: 1, y: 0), distance: .infinity, unit: "ft"))
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let doc = try XCTUnwrap(PDFDocument(url: source)), controller = RectangleMarkupController(); controller.bind(to: doc)
        let page = try XCTUnwrap(doc.page(at: 0)), other = try XCTUnwrap(doc.page(at: 2))
        controller.applyDrawingScale(scale, to: [page, other])
        _ = controller.createMeasurement(on: page, points: points, kind: .area, closed: true, scale: scale)
        let original = try Data(contentsOf: source)
        XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: source, pageLabels: [:], records: RectangleMarkupRecord.capture(doc)))
        XCTAssertEqual(try Data(contentsOf: source).prefix(original.count), original)
        let reopened = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(MeasurementMetadata.scale(on: try XCTUnwrap(reopened.page(at: 2))), scale)
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first { MeasurementMetadata.measurement($0) != nil }?.contents, "Area: 200.00 sq ft")
    }
    func testCalibrationGesturesAndDraftCorrectionAtRotatedZooms() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1100,height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        let view = MarkupPDFView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view); view.setMarkupDocument(document)
        let controller = view.rectangleMarkup
        for index in 0..<4 {
            let page = try XCTUnwrap(document.page(at: index)); view.go(to: page); window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
            for zoom in [0.8, 1.2] {
                view.scaleFactor = zoom; view.layoutSubtreeIfNeeded()
                var endpoints: (CGPoint, CGPoint)?
                controller.onCalibrationCompleted = { actualPage, start, end in XCTAssertTrue(actualPage === page); endpoints = (start,end) }
                controller.tool = .calibrate
                let count = page.annotations.count
                XCTAssertTrue(controller.pointerDown(at: view.convert(points[0],from: page)))
                XCTAssertTrue(controller.pointerUp(at: view.convert(points[0],from: page)))
                XCTAssertNil(endpoints)
                XCTAssertTrue(controller.pointerDown(at: view.convert(points[1],from: page)))
                let pair = try XCTUnwrap(endpoints)
                XCTAssertEqual(pair.0.x, points[0].x, accuracy: 1e-8)
                XCTAssertEqual(pair.1.y, points[1].y, accuracy: 1e-8)
                XCTAssertEqual(page.annotations.count,count,"Calibration endpoints are transient and must not add markups")
                XCTAssertEqual(controller.tool, .select)
                controller.applyDrawingScale(eighth, to: [page])
                controller.tool = .perimeter
                XCTAssertTrue(controller.pointerDown(at: view.convert(points[0], from: page)))
                XCTAssertTrue(controller.pointerDown(at: view.convert(CGPoint(x: 190,y: 105),from: page), modifiers: .shift))
                XCTAssertTrue(controller.removeLastDraftPoint())
                XCTAssertTrue(controller.pointerDown(at: view.convert(points[1],from: page), modifiers: .shift))
                XCTAssertTrue(controller.finishPolyline())
                XCTAssertEqual(controller.selected?.contents,"Length: 10.00 ft")
                let vertices = RectangleMarkupRecord.vertices(try XCTUnwrap(controller.selected))
                XCTAssertEqual(vertices[0].y,vertices[1].y,accuracy: 1e-8)
                controller.tool = .area
                XCTAssertTrue(controller.pointerDown(at: view.convert(points[0],from: page)))
                XCTAssertTrue(controller.removeLastDraftPoint())
                XCTAssertFalse(controller.removeLastDraftPoint())
                XCTAssertFalse(controller.finishPolyline())
                controller.tool = .calibrate
                XCTAssertTrue(controller.pointerDown(at: view.convert(points[0],from: page)))
                endpoints = nil; controller.escape(); XCTAssertNil(endpoints)
            }
        }
    }

    func testArchitecturalMetricAndInvalidScales() {
        XCTAssertEqual(eighth.unitsPerPoint, 1/9, accuracy: 1e-12)
        XCTAssertEqual(DrawingScale.metric(ratio: 100)!.unitsPerPoint * 72, 2.54, accuracy: 1e-12)
        for value in [0.0, -1, .nan, .infinity] {
            XCTAssertNil(DrawingScale.architectural(inches: value, name: "Invalid"))
            XCTAssertNil(DrawingScale.metric(ratio: value))
        }
        let area = DrawingMeasurement(kind: .area, scale: eighth, closed: true)
        XCTAssertEqual(area.value(points: points), 200, accuracy: 1e-10)
        XCTAssertEqual(area.label(points: points), "Area: 200.00 sq ft")
        XCTAssertEqual(DrawingMeasurement(kind: .perimeter, scale: eighth, closed: true).value(points: points), 60, accuracy: 1e-10)
        XCTAssertEqual(DrawingMeasurement(kind: .perimeter, scale: eighth, closed: false).value(points: Array(points.prefix(3))), 30, accuracy: 1e-10)
        let translated = points.map { CGPoint(x: $0.x+1_000_000,y: $0.y-1_000_000) }
        XCTAssertEqual(area.value(points: translated), 200, accuracy: 1e-10)
    }
    func testBoundaryAndPageRangeValidation() {
        XCTAssertTrue(MeasurementGeometry.valid(points, closed: true))
        XCTAssertFalse(MeasurementGeometry.valid([points[0],points[2],points[1],points[3]], closed: true))
        XCTAssertFalse(MeasurementGeometry.valid([.zero,.zero,CGPoint(x: 1,y: 1)], closed: true))
        XCTAssertFalse(MeasurementGeometry.valid([.zero,CGPoint(x: CGFloat.infinity,y: 1)], closed: false))
        XCTAssertFalse(MeasurementGeometry.valid([.zero,CGPoint(x: 1e308,y: 1e308),CGPoint(x: -1e308,y: 0)], closed: false))
        XCTAssertEqual(MeasurementGeometry.pages("1, 3-6, 3", count: 8), [0,2,3,4,5])
        for text in ["", "0", "9", "6-2", "1,", "1-2-3", "no", "-1"] { XCTAssertNil(MeasurementGeometry.pages(text,count: 8),text) }
    }
    func testBatchScaleAndMeasurementUndoRedo() throws {
        let document = PDFDocument(); for _ in 0..<3 { document.insert(PDFPage(), at: document.pageCount) }
        let controller = RectangleMarkupController(); controller.bind(to: document)
        let a = try XCTUnwrap(document.page(at: 0)), b = try XCTUnwrap(document.page(at: 1)), c = try XCTUnwrap(document.page(at: 2))
        controller.undo.groupsByEvent = false
        func transaction(_ body: () throws -> Void) rethrows { controller.undo.beginUndoGrouping(); defer { controller.undo.endUndoGrouping() }; try body() }
        transaction { controller.applyDrawingScale(eighth,to: [a,c]) }
        XCTAssertEqual(MeasurementMetadata.scale(on: a),eighth); XCTAssertNil(MeasurementMetadata.scale(on: b)); XCTAssertEqual(MeasurementMetadata.scale(on: c),eighth)
        controller.undo.undo(); XCTAssertNil(MeasurementMetadata.scale(on: a)); XCTAssertNil(MeasurementMetadata.scale(on: c))
        controller.undo.redo(); XCTAssertEqual(MeasurementMetadata.scale(on: a),eighth)
        controller.undo.beginUndoGrouping()
        let measurement = try XCTUnwrap(controller.createMeasurement(on: a, points: points, kind: .area, closed: true, scale: eighth))
        controller.undo.endUndoGrouping()
        transaction { controller.applyDrawingScale(quarter,to: [a,c]) }
        XCTAssertEqual(measurement.contents,"Area: 50.00 sq ft")
        controller.undo.undo(); XCTAssertEqual(measurement.contents,"Area: 200.00 sq ft"); XCTAssertEqual(MeasurementMetadata.scale(on: c),eighth)
        controller.undo.redo(); XCTAssertEqual(measurement.contents,"Area: 50.00 sq ft")
        let marker = try XCTUnwrap(a.annotations.first { MeasurementMetadata.pageScale($0) != nil })
        XCTAssertFalse(marker.shouldDisplay); XCTAssertFalse(marker.shouldPrint); XCTAssertFalse(MarkupListPresentation.includes(marker))
        XCTAssertEqual(MarkupListPresentation.typeName(measurement), "Area")
    }
    func testEditingMeasurementRecalculatesAndRejectsCrossedBoundary() throws {
        let doc = PDFDocument(); doc.insert(PDFPage(),at: 0)
        let page = try XCTUnwrap(doc.page(at: 0)), controller = RectangleMarkupController(); controller.bind(to: doc)
        controller.undo.groupsByEvent = false
        func transaction(_ body: () throws -> Void) rethrows { controller.undo.beginUndoGrouping(); defer { controller.undo.endUndoGrouping() }; try body() }
        controller.undo.beginUndoGrouping()
        let annotation = try XCTUnwrap(controller.createMeasurement(on: page,points: points,kind: .area,closed: true,scale: eighth))
        controller.undo.endUndoGrouping()
        let moved = points.map { CGPoint(x: $0.x+20,y: $0.y+40) }
        transaction { controller.setVertexPositions(moved,of: annotation,on: page) }
        XCTAssertEqual(annotation.contents,"Area: 200.00 sq ft")
        controller.setVertexPositions([moved[0],moved[2],moved[1],moved[3]],of: annotation,on: page)
        XCTAssertEqual(RectangleMarkupRecord.vertices(annotation),moved)
        controller.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.vertices(annotation),points)
        var expanded = points; expanded[2].y = 460; expanded[3].y = 460
        transaction { controller.setVertexPositions(expanded,of: annotation,on: page) }
        XCTAssertEqual(annotation.contents,"Area: 400.00 sq ft")
        controller.undo.undo(); XCTAssertEqual(annotation.contents,"Area: 200.00 sq ft")
        XCTAssertTrue(RectangleMarkupRecord.capture(doc).allSatisfy(\.isValid))
    }
    func testScalesAndMeasurementsSaveWithoutRewritingOriginalDrawing() throws {
        guard let helper = PDFTKBookmarkWriter.executableURL() else { throw XCTSkip("PDF helper required") }
        let source = try fixture(), output = source.deletingLastPathComponent().appendingPathComponent("Measured-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let original = try Data(contentsOf: source)
        let doc = try XCTUnwrap(PDFDocument(url: source)), controller = RectangleMarkupController(); controller.bind(to: doc)
        let pages = (0..<doc.pageCount).compactMap { doc.page(at: $0) }
        controller.applyDrawingScale(eighth,to: pages)
        for page in pages {
            _ = try XCTUnwrap(controller.createMeasurement(on: page,points: points,kind: .area,closed: true,scale: eighth))
            _ = try XCTUnwrap(controller.createMeasurement(on: page,points: Array(points.prefix(3)),kind: .perimeter,closed: false,scale: eighth))
        }
        let records = RectangleMarkupRecord.capture(doc)
        XCTAssertTrue(records.allSatisfy(\.isValid))
        XCTAssertTrue(PDFRectangleWriter.write(document: doc,source: source,destination: output,pageLabels: [:],records: records))
        let bytes = try Data(contentsOf: output); XCTAssertEqual(bytes.prefix(original.count),original)
        XCTAssertTrue(PDFTKBookmarkWriter.run(helper, arguments: ["--check",output.path]))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("/MeasureFont"))
        if let directory = ProcessInfo.processInfo.environment["DRAWBRIDGE_MEASUREMENT_QA_DIR"] {
            try bytes.write(to: URL(fileURLWithPath: directory).appendingPathComponent("Measurements.pdf"))
            try original.write(to: URL(fileURLWithPath: directory).appendingPathComponent("Original.pdf"))
        }
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(RectangleMarkupRecord.capture(reopened),records)
        for index in 0..<4 {
            let page = try XCTUnwrap(reopened.page(at: index))
            XCTAssertEqual(page.rotation,index*90); XCTAssertEqual(page.bounds(for: .mediaBox),pages[index].bounds(for: .mediaBox))
            XCTAssertEqual(MeasurementMetadata.scale(on: page),eighth)
            XCTAssertEqual(page.annotations.filter(MarkupListPresentation.includes).count,2)
            XCTAssertEqual(Set(page.annotations.filter(MarkupListPresentation.includes).compactMap(\.contents)),["Area: 200.00 sq ft","Length: 30.00 ft"])

        }
        let editing = RectangleMarkupController(); editing.bind(to: reopened)
        editing.applyDrawingScale(quarter,to: [try XCTUnwrap(reopened.page(at: 2))])
        XCTAssertTrue(PDFRectangleWriter.write(document: reopened,source: output,destination: output,pageLabels: [:],records: RectangleMarkupRecord.capture(reopened)))
        let again = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(MeasurementMetadata.scale(on: try XCTUnwrap(again.page(at: 2))),quarter)
        XCTAssertEqual(MeasurementMetadata.scale(on: try XCTUnwrap(again.page(at: 0))),eighth)
        XCTAssertEqual(RectangleMarkupRecord.capture(again).count,12)
    }
    func testScaleOnlyAndPageReordering() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let doc = try XCTUnwrap(PDFDocument(url: source)), controller = RectangleMarkupController(); controller.bind(to: doc)
        let page = try XCTUnwrap(doc.page(at: 1)); controller.applyDrawingScale(eighth,to: [page])
        XCTAssertTrue(PDFRectangleWriter.write(document: doc,source: source,destination: source,pageLabels: [:],records: RectangleMarkupRecord.capture(doc)))
        let reopened = try XCTUnwrap(PDFDocument(url: source)); let scaled = try XCTUnwrap(reopened.page(at: 1))
        let stamp = try XCTUnwrap(PDFMarkupSourceStamp.capture(source))
        let structure = PDFPageStructureState(document: reopened, stamp: stamp, source: source)
        reopened.removePage(at: 1); reopened.insert(scaled,at: 0)
        XCTAssertEqual(MeasurementMetadata.scale(on: try XCTUnwrap(reopened.page(at: 0))),eighth)
        XCTAssertNil(MeasurementMetadata.scale(on: try XCTUnwrap(reopened.page(at: 1))))
        let plan = try XCTUnwrap(structure.plan(for: reopened))
        XCTAssertTrue(plan.write(document: reopened,currentSource: source,destination: source,expectedStamp: stamp,labels: [:],records: RectangleMarkupRecord.capture(reopened),navigation: PDFTKBookmarkWriter.captureNavigation(in: reopened),onCommitted: { _ in }))
        let saved = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(MeasurementMetadata.scale(on: try XCTUnwrap(saved.page(at: 0))),eighth)
        XCTAssertNil(MeasurementMetadata.scale(on: try XCTUnwrap(saved.page(at: 1))))
    }
    func testMeasurementGesturesAtEveryRotationAndZoom() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1100,height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        let view = MarkupPDFView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view); view.setMarkupDocument(document)
        let controller = view.rectangleMarkup
        for index in 0..<4 {
            let page = try XCTUnwrap(document.page(at: index)); view.go(to: page)
            window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
            controller.applyDrawingScale(eighth,to: [page])
            for zoom in [0.8,1.2] {
                view.scaleFactor = zoom; view.layoutSubtreeIfNeeded()
                controller.tool = .area
                for point in points { XCTAssertTrue(controller.pointerDown(at: view.convert(point,from: page))) }
                XCTAssertTrue(controller.finishPolyline())
                let area = try XCTUnwrap(controller.selected)
                XCTAssertEqual(area.contents,"Area: 200.00 sq ft")
                controller.tool = .perimeter
                for point in points { XCTAssertTrue(controller.pointerDown(at: view.convert(point,from: page))) }
                XCTAssertTrue(controller.pointerDown(at: view.convert(points[0],from: page)))
                XCTAssertEqual(controller.selected?.contents,"Perimeter: 60.00 ft")
                let count = page.annotations.count
                XCTAssertTrue(controller.pointerDown(at: view.convert(points[0],from: page)))
                controller.escape(); XCTAssertEqual(page.annotations.count,count)
            }
        }
    }
    func testNonstandardPageUnitsAndUnchangedScaleAreSafe() throws {
        let source = try fixture(userUnit: 2); defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source)), controller = RectangleMarkupController(); controller.bind(to: document)
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertFalse(MeasurementMetadata.supportedPage(page))
        controller.applyDrawingScale(eighth,to: [page])
        XCTAssertTrue(page.annotations.isEmpty); XCTAssertFalse(controller.hasUnsavedChanges)
        XCTAssertNil(controller.createMeasurement(on: page,points: points,kind: .area,closed: true,scale: eighth))
        let normal = PDFDocument(); normal.insert(PDFPage(),at: 0); controller.bind(to: normal)
        let normalPage = try XCTUnwrap(normal.page(at: 0)); controller.applyDrawingScale(eighth,to: [normalPage])
        let records = RectangleMarkupRecord.capture(normal)
        controller.applyDrawingScale(eighth,to: [normalPage])
        XCTAssertEqual(RectangleMarkupRecord.capture(normal),records,"Reapplying the same scale should not replace markers or create extra save work")
    }

    func testSeveralNewMeasurementsReuseExistingSavedAppearances() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let doc = try XCTUnwrap(PDFDocument(url: source)), controller = RectangleMarkupController(); controller.bind(to: doc)
        let page = try XCTUnwrap(doc.page(at: 0)); controller.applyDrawingScale(eighth,to: [page])
        for _ in 0..<100 { _ = try XCTUnwrap(controller.createMeasurement(on: page,points: points,kind: .area,closed: true,scale: eighth)) }
        XCTAssertTrue(PDFRectangleWriter.write(document: doc,source: source,destination: source,pageLabels: [:],records: RectangleMarkupRecord.capture(doc)))
        let original = try Data(contentsOf: source)
        let reopened = try XCTUnwrap(PDFDocument(url: source)), editing = RectangleMarkupController(); editing.bind(to: reopened)
        let target = try XCTUnwrap(reopened.page(at: 0))
        for _ in 0..<6 { _ = try XCTUnwrap(editing.createMeasurement(on: target,points: points,kind: .perimeter,closed: true,scale: eighth)) }
        let start = Date()
        XCTAssertTrue(PDFRectangleWriter.write(document: reopened,source: source,destination: source,pageLabels: [:],records: RectangleMarkupRecord.capture(reopened)))
        print("SIX NEW MEASUREMENTS WITH 100 EXISTING: \(Date().timeIntervalSince(start))s")
        let saved = try Data(contentsOf: source)
        XCTAssertEqual(saved.prefix(original.count),original)
        XCTAssertLessThan(saved.count-original.count,30_000,"Unchanged measurement appearances should be reused")
        XCTAssertEqual(RectangleMarkupRecord.capture(try XCTUnwrap(PDFDocument(url: source))).count,107)
    }

    private func fixture(userUnit: Double = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeasurementBase-\(UUID().uuidString).pdf")
        let drawing = "q 0.85 g 90 90 110 200 re f Q BT /F1 12 Tf 110 330 Td (MEASUREMENT TEST DRAWING) Tj ET\n"
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 6 0 R] /Count 4 >>"]
        for rotation in [0,90,180,270] { objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [10 20 610 820] /CropBox [40 50 560 780] /Rotate \(rotation) /UserUnit \(userUnit) /Resources << /Font << /F1 8 0 R >> >> /Contents 7 0 R >>") }
        objects.append("<< /Length \(drawing.utf8.count) >>\nstream\n\(drawing)endstream")
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (i,object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(i+1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = data.count; data.append(Data("xref\n0 \(objects.count+1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format:"%010d 00000 n \n",offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)); try data.write(to: url)
        return url
    }
}
