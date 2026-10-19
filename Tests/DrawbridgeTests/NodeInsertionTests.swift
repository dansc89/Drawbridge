import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class NodeInsertionTests: XCTestCase {
    private let points = [CGPoint(x: 140, y: 140), CGPoint(x: 300, y: 140), CGPoint(x: 300, y: 300)]

    func testContextMenuInsertsProjectedPolylineNodeWithDirtyUndoRedoAtEveryRotation() throws {
        for rotation in [0, 90, 180, 270] {
            let (window, view, page) = try fixture(rotation: rotation)
            let session = view.rectangleMarkup
            let annotation = try XCTUnwrap(session.createPolyline(on: page, points: points))
            let oldBounds = annotation.bounds
            session.markSaved(at: URL(fileURLWithPath: "/tmp/node-insertion-unused.pdf"))
            session.undo.removeAllActions(); session.undo.groupsByEvent = false
            session.setSelectedItems([])
            let item = try XCTUnwrap(menu(view, window, page, CGPoint(x: 220, y: 142)).item(withTitle: "Add Node"))
            XCTAssertTrue(session.selected === annotation, "Right-click selects the hit path")
            XCTAssertFalse(session.hasUnsavedChanges, "Opening menu is not an edit")
            session.undo.beginUndoGrouping(); try invoke(item); session.undo.endUndoGrouping()
            let expected = [points[0], CGPoint(x: 220, y: 140), points[1], points[2]]
            assertPoints(RectangleMarkupRecord.vertices(annotation), expected)
            XCTAssertTrue(session.hasUnsavedChanges)
            XCTAssertTrue(session.selected === annotation)
            XCTAssertEqual(session.undo.undoActionName, "Add Markup Node")
            for _ in 0..<2 {
                session.undo.undo(); assertPoints(RectangleMarkupRecord.vertices(annotation), points)
                XCTAssertEqual(annotation.bounds, oldBounds)
                session.undo.redo(); assertPoints(RectangleMarkupRecord.vertices(annotation), expected)
            }
            // Inserted nodes participate in the existing vertex-drag gesture.
            let from = view.convert(expected[1], from: page), to = view.convert(CGPoint(x: 220, y: 180), from: page)
            session.undo.beginUndoGrouping()
            XCTAssertTrue(session.pointerDown(at: from)); XCTAssertTrue(session.pointerDragged(at: to)); XCTAssertTrue(session.pointerUp(at: to))
            session.undo.endUndoGrouping()
            XCTAssertEqual(RectangleMarkupRecord.vertices(annotation)[1].y, 180, accuracy: 0.001)
        }
    }

    func testClosingEdgeAndMeasurementsKeepOrderedVerticesStyleAndPortableSaveReopen() throws {
        for rotation in [0, 90, 180, 270] {
            for variant in ["polyline", "polygon", "area", "closedPerimeter", "openPerimeter", "distance"] {
                let (window, view, page) = try fixture(rotation: rotation)
                let session = view.rectangleMarkup
                session.strokeColor = .systemRed; session.lineWidth = 3
                let closed = !["polyline", "openPerimeter", "distance"].contains(variant)
                let originalPoints = variant == "distance" ? Array(points.prefix(2)) : points
                let annotation: PDFAnnotation
                if variant == "polygon" || variant == "polyline" {
                    annotation = try XCTUnwrap(session.createPolyline(on: page, points: originalPoints, closed: closed))
                } else {
                    annotation = try XCTUnwrap(session.createMeasurement(on: page, points: originalPoints, kind: variant == "area" ? .area : .perimeter, closed: closed, scale: DrawingScale.architectural(inches: 0.25, name: "Quarter")!))
                }
                session.setLineAppearance(pattern: .dashed, opacity: 0.65)
                if closed { RectangleMarkupRecord.setPolygonFill(NSColor.systemBlue.withAlphaComponent(0.25), on: annotation) }
                let originalColor = annotation.color, originalWidth = annotation.border?.lineWidth
                let originalLabel = annotation.contents
                let before = RectangleMarkupRecord.capture(try XCTUnwrap(view.document))
                session.undo.removeAllActions(); session.undo.groupsByEvent = false
                let click = closed ? CGPoint(x: 220, y: 220) : CGPoint(x: 220, y: 140)
                let item = try XCTUnwrap(menu(view, window, page, click).item(withTitle: "Add Node"), variant)
                session.undo.beginUndoGrouping(); try invoke(item); session.undo.endUndoGrouping()
                let expected = closed ? originalPoints + [click] : [originalPoints[0], click] + originalPoints.dropFirst()
                assertPoints(RectangleMarkupRecord.vertices(annotation), expected)
                XCTAssertEqual(annotation.color, originalColor); XCTAssertEqual(annotation.border?.lineWidth, originalWidth)
                XCTAssertEqual(annotation.contents, originalLabel, "Collinear insertion preserves measurement")
                XCTAssertEqual(MarkupStyle.pattern(annotation), .dashed)
                XCTAssertEqual(MarkupStyle.strokeOpacity(annotation), 0.65)
                if closed { XCTAssertEqual(MarkupStyle.fillOpacity(annotation), 0.25) }
                let inserted = RectangleMarkupRecord.capture(try XCTUnwrap(view.document))
                session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.capture(try XCTUnwrap(view.document)), before)
                session.undo.redo(); XCTAssertEqual(RectangleMarkupRecord.capture(try XCTUnwrap(view.document)), inserted)
                if MeasurementMetadata.measurement(annotation) != nil {
                    var moved = expected; moved[closed ? 3 : 1].y += 20
                    session.undo.beginUndoGrouping()
                    session.setVertexPositions(moved, of: annotation, on: page)
                    session.undo.endUndoGrouping()
                    XCTAssertNotEqual(annotation.contents, originalLabel, "Existing node dragging updates measurement")
                }
                let source = FileManager.default.temporaryDirectory.appendingPathComponent("nodes-source-\(UUID().uuidString).pdf")
                let output = source.deletingPathExtension().appendingPathExtension("out.pdf")
                defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
                let blank = PDFDocument(); let blankPage = PDFPage(); blankPage.setBounds(page.bounds(for: .mediaBox), for: .mediaBox)
                blankPage.setBounds(page.bounds(for: .cropBox), for: .cropBox); blankPage.rotation = rotation; blank.insert(blankPage, at: 0)
                XCTAssertTrue(blank.write(to: source))
                let document = try XCTUnwrap(view.document), records = RectangleMarkupRecord.capture(document)
                XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: records))
                let reopened = try XCTUnwrap(PDFDocument(url: output))
                XCTAssertEqual(RectangleMarkupRecord.capture(reopened), records)
                XCTAssertTrue(PDFRectangleWriter.write(document: reopened, source: output, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(reopened)))
                XCTAssertEqual(RectangleMarkupRecord.capture(try XCTUnwrap(PDFDocument(url: output))), records)
            }
        }
    }

    func testNoInsertionAtEndpointsInteriorOrImaginaryClosingEdge() throws {
        let (window, view, page) = try fixture()
        let session = view.rectangleMarkup
        _ = try XCTUnwrap(session.createPolyline(on: page, points: points))
        for point in [points[0], points[1], CGPoint(x: 220, y: 220), CGPoint(x: 210, y: 180)] {
            XCTAssertNil(try menu(view, window, page, point).item(withTitle: "Add Node"))
        }
        let polygon = try XCTUnwrap(session.createPolyline(on: page, points: points, closed: true))
        XCTAssertNil(try menu(view, window, page, CGPoint(x: 260, y: 180)).item(withTitle: "Add Node"))
        XCTAssertEqual(RectangleMarkupRecord.vertices(polygon), points)
    }

    func testInsertionCannotExceedPortableVertexLimit() throws {
        let (window, view, page) = try fixture()
        let annotation = try XCTUnwrap(view.rectangleMarkup.createPolyline(on: page, points: [points[0], points[1]] + Array(repeating: points[2], count: 9998)))
        XCTAssertEqual(RectangleMarkupRecord.vertices(annotation).count, 10000)
        XCTAssertNil(try menu(view, window, page, CGPoint(x: 220, y: 140)).item(withTitle: "Add Node"), "Never create geometry the portable writer cannot save")
    }

    func testRepeatedInsertionOrdersNodesOnTheNewSegments() throws {
        let (window, view, page) = try fixture()
        let session = view.rectangleMarkup
        let annotation = try XCTUnwrap(session.createPolyline(on: page, points: points, closed: true))
        for point in [CGPoint(x: 220, y: 220), CGPoint(x: 180, y: 180), CGPoint(x: 300, y: 220), CGPoint(x: 220, y: 140)] {
            try invoke(XCTUnwrap(menu(view, window, page, point).item(withTitle: "Add Node")))
        }
        assertPoints(RectangleMarkupRecord.vertices(annotation), [points[0], CGPoint(x: 220, y: 140), points[1], CGPoint(x: 300, y: 220), points[2], CGPoint(x: 220, y: 220), CGPoint(x: 180, y: 180)])
    }

    func testRetainedMenuCannotEditReadOnlyBusyRemovedOrReplacedGeometry() throws {
        for restriction in ["readOnly", "busy", "removed", "geometry", "document", "locked", "hidden", "page"] {
            let (window, view, page) = try fixture()
            let session = view.rectangleMarkup
            let annotation = try XCTUnwrap(session.createPolyline(on: page, points: points))
            let item = try XCTUnwrap(menu(view, window, page, CGPoint(x: 220, y: 140)).item(withTitle: "Add Node"))
            switch restriction {
            case "readOnly": annotation.isReadOnly = true
            case "busy": session.canEdit = { false }
            case "removed": page.removeAnnotation(annotation)
            case "geometry": RectangleMarkupRecord.setVertices(points.reversed(), on: annotation)
            case "locked":
                let layer = try XCTUnwrap(session.addLayer(named: "Protected")); session.assignLayer(layer, to: [annotation]); session.setLayerLocked(layer, true)
            case "hidden": annotation.shouldDisplay = false
            case "page":
                let other = PDFPage(); view.document?.insert(other, at: 1); view.go(to: other)
            default: view.setMarkupDocument(PDFDocument())
            }
            let before = RectangleMarkupRecord.vertices(annotation)
            session.undo.removeAllActions()
            try invoke(item)
            XCTAssertEqual(RectangleMarkupRecord.vertices(annotation), before, restriction)
            XCTAssertFalse(session.undo.canUndo)
        }
    }

    private func fixture(rotation: Int = 0) throws -> (NSWindow, MarkupPDFView, PDFPage) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let view = MarkupPDFView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        let page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 640, height: 480), for: .mediaBox)
        page.setBounds(CGRect(x: 40, y: 30, width: 540, height: 410), for: .cropBox); page.rotation = rotation
        let document = PDFDocument(); document.insert(page, at: 0)
        view.setMarkupDocument(document); view.autoScales = true
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
        return (window, view, page)
    }

    private func menu(_ view: MarkupPDFView, _ window: NSWindow, _ page: PDFPage, _ point: CGPoint) throws -> NSMenu {
        let location = view.convert(view.convert(point, from: page), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        return try XCTUnwrap(view.menu(for: event))
    }

    private func invoke(_ item: NSMenuItem) throws {
        XCTAssertTrue(item.isEnabled)
        let target = try XCTUnwrap(item.target as? NSObject), action = try XCTUnwrap(item.action)
        XCTAssertTrue(target.responds(to: action)); target.perform(action, with: item)
    }

    private func assertPoints(_ actual: [CGPoint], _ expected: [CGPoint], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.x, e.x, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(a.y, e.y, accuracy: 0.001, file: file, line: line)
        }
    }
}
