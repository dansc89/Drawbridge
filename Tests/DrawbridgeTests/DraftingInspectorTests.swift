import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class DraftingInspectorTests: XCTestCase {
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func control<T: NSControl>(_ label: String, in inspector: MarkupPropertiesViewController, as type: T.Type) throws -> T {
        try XCTUnwrap(descendants(inspector.view).compactMap { $0 as? T }.first { $0.accessibilityLabel() == label }, "Missing inspector control: \(label)")
    }
    func fire(_ control: NSControl) { _ = control.target?.perform(control.action, with: control) }
    func testHatchDefaultsPersistPerToolAndCreateGeometry() throws {
        let name = "DraftingInspector.\(UUID())"
        let prefs = UserDefaults(suiteName: name)!
        defer { prefs.removePersistentDomain(forName: name) }
        let session = RectangleMarkupController(defaults: prefs); session.tool = .rectangle
        let style = DraftingHatch(preset: .brick, foreground: [0,0,1], background: [1,1,0], scale: 2, angle: 37, lineWidth: 1.2)
        session.hatchStyle = style
        XCTAssertTrue(session.saveCurrentAsDefault())
        session.tool = .ellipse; XCTAssertNil(session.hatchStyle, "Rectangle hatch must not leak into ellipse")
        let reopened = RectangleMarkupController(defaults: prefs); reopened.tool = .rectangle
        XCTAssertEqual(reopened.hatchStyle, style)
        let doc = PDFDocument(), page = PDFPage(); doc.insert(page, at: 0); reopened.bind(to: doc)
        // Binding a document deliberately returns to Select; activate the tool as the UI does.
        reopened.tool = .rectangle
        XCTAssertEqual(reopened.hatchStyle, style)
        let bounds = CGRect(x: 20,y: 30,width: 90,height: 50)
        let annotation = try XCTUnwrap(reopened.create(on: page, bounds: bounds))
        XCTAssertEqual(annotation.bounds, bounds); XCTAssertEqual(DraftingHatch.read(annotation), style)
    }
    func testInspectorEditsHatchColorsGeometryAndUndoWithoutChangingOutline() throws {
        let doc = PDFDocument(), page = PDFPage(); doc.insert(page, at: 0)
        let session = RectangleMarkupController(); session.bind(to: doc); session.undo.groupsByEvent = false
        session.undo.beginUndoGrouping()
        let annotation = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 20,y: 30,width: 90,height: 50)))
        session.undo.endUndoGrouping(); session.undo.removeAllActions()
        let inspector = MarkupPropertiesViewController(); inspector.session = session; inspector.refresh()
        let preset = try control("Hatch pattern", in: inspector, as: NSPopUpButton.self)
        XCTAssertEqual(preset.itemTitles, DraftingHatch.Preset.allCases.map(\.title))
        let fg = try control("Hatch foreground color", in: inspector, as: NSColorWell.self)
        let bg = try control("Hatch background color", in: inspector, as: NSColorWell.self)
        let transparent = try control("Transparent hatch background", in: inspector, as: NSButton.self)
        let scale = try control("Hatch scale", in: inspector, as: NSTextField.self)
        let angle = try control("Hatch angle degrees", in: inspector, as: NSTextField.self)
        let weight = try control("Hatch line weight points", in: inspector, as: NSTextField.self)
        let oldBounds = annotation.bounds, oldColor = annotation.color, oldWidth = annotation.border?.lineWidth
        session.undo.beginUndoGrouping()
        preset.selectItem(withTitle: "Grid"); fire(preset)
        fg.color = .blue; fire(fg); bg.color = .yellow; transparent.state = .off; fire(transparent)
        scale.doubleValue = 200; fire(scale); angle.doubleValue = 37; fire(angle); weight.doubleValue = 1.2; fire(weight)
        session.undo.endUndoGrouping()
        let expected = DraftingHatch(preset: .grid, foreground: [0,0,1], background: [1,1,0], scale: 2, angle: 37, lineWidth: 1.2)
        XCTAssertEqual(DraftingHatch.read(annotation), expected)
        XCTAssertEqual(annotation.bounds, oldBounds); XCTAssertEqual(annotation.color, oldColor); XCTAssertEqual(annotation.border?.lineWidth, oldWidth)
        for _ in 0..<2 { session.undo.undo(); XCTAssertNil(DraftingHatch.read(annotation)); session.undo.redo(); XCTAssertEqual(DraftingHatch.read(annotation), expected) }
        session.undo.beginUndoGrouping(); transparent.state = .on; fire(transparent); session.undo.endUndoGrouping()
        XCTAssertNil(DraftingHatch.read(annotation)?.background)
        session.undo.undo(); XCTAssertEqual(DraftingHatch.read(annotation)?.background, [1,1,0])
        session.undo.beginUndoGrouping(); angle.doubleValue = .nan; fire(angle); session.undo.endUndoGrouping()
        XCTAssertEqual(DraftingHatch.read(annotation), expected, "Invalid geometry must not mutate metadata")
        annotation.isReadOnly = true; inspector.refresh(); XCTAssertFalse(preset.isEnabled); XCTAssertFalse(fg.isEnabled)
        session.undo.beginUndoGrouping(); preset.selectItem(withTitle: "Wood"); fire(preset); session.undo.endUndoGrouping()
        XCTAssertEqual(DraftingHatch.read(annotation), expected)
    }
    func testClosedGeometryRendersIndependentColorsAndPersistsThroughClipboardAndPDF() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bounds = CGRect(x: 10, y: 10, width: 80, height: 80)
        for kind in [RectangleMarkupRecord.Kind.rectangle, .ellipse, .polygon] {
            let doc = PDFDocument(), page = PDFPage(); page.setBounds(CGRect(x: 0,y: 0,width: 100,height: 100), for: .mediaBox); doc.insert(page, at: 0)
            let session = RectangleMarkupController(); session.bind(to: doc)
            session.hatchStyle = DraftingHatch(preset: .grid, foreground: [0,0,1], background: [1,1,0], scale: 1.5, angle: 23, lineWidth: 1)
            let annotation = try XCTUnwrap(session.create(on: page, bounds: bounds, kind: kind,
                vertices: kind == .polygon ? [CGPoint(x: 11,y: 11), CGPoint(x: 89,y: 11), CGPoint(x: 50,y: 89)] : []))
            let record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: annotation, pageIndex: 0))
            let pasted = try JSONDecoder().decode(RectangleMarkupRecord.self, from: JSONEncoder().encode(record)).clipboardAnnotation(contents: nil)
            XCTAssertEqual(DraftingHatch.read(pasted), DraftingHatch.read(annotation)); XCTAssertEqual(pasted.bounds, bounds)
            let source = directory.appendingPathComponent("\(kind.rawValue)-source.pdf"), output = directory.appendingPathComponent("\(kind.rawValue)-output.pdf")
            let blank = PDFDocument(), blankPage = PDFPage(); blankPage.setBounds(page.bounds(for: .mediaBox), for: .mediaBox); blank.insert(blankPage, at: 0)
            XCTAssertTrue(blank.write(to: source))
            XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: output, pageLabels: [:], records: [record]))
            let savedDocument = try XCTUnwrap(PDFDocument(url: output))
            let reopened = try XCTUnwrap(savedDocument.page(at: 0))
            XCTAssertEqual(reopened.annotations.first.flatMap(DraftingHatch.read), DraftingHatch.read(annotation))
            for draw in [{ (context: CGContext) in annotation.draw(with: .mediaBox, in: context) }, { context in reopened.draw(with: .mediaBox, to: context) }] {
                let context = try XCTUnwrap(CGContext(data: nil, width: 100,height: 100,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0,y: 0,width: 100,height: 100)); draw(context)
                let image = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
                var blue = 0, yellow = 0
                for y in 30..<60 { for x in 40..<60 {
                    let color = try XCTUnwrap(image.colorAt(x: x,y: y)?.usingColorSpace(.deviceRGB))
                    if color.blueComponent > 0.7 && color.redComponent < 0.3 { blue += 1 }
                    if color.redComponent > 0.7 && color.greenComponent > 0.7 && color.blueComponent < 0.3 { yellow += 1 }
                } }
                XCTAssertGreaterThan(blue, 5, "\(kind) foreground"); XCTAssertGreaterThan(yellow, 100, "\(kind) background")
                let outside = try XCTUnwrap(image.colorAt(x: 2,y: 50))
                XCTAssertGreaterThan(outside.redComponent, 0.95); XCTAssertGreaterThan(outside.blueComponent, 0.95)
                if kind != .rectangle {
                    let corner = try XCTUnwrap(image.colorAt(x: 13,y: 13))
                    XCTAssertGreaterThan(corner.redComponent, 0.95); XCTAssertGreaterThan(corner.blueComponent, 0.95, "Hatch must clip to closed geometry")
                }
            }
        }
    }
    func testInspectorExposesHatchesOnlyForClosedShapesAndKeepsSnapshotFilters() throws {
        let session = RectangleMarkupController(), inspector = MarkupPropertiesViewController(); inspector.session = session
        session.tool = .rectangle; inspector.refresh()
        let preset = try control("Hatch pattern", in: inspector, as: NSPopUpButton.self)
        XCTAssertFalse(preset.isHiddenOrHasHiddenAncestor)
        session.tool = .line; inspector.refresh(); XCTAssertTrue(preset.isHiddenOrHasHiddenAncestor)
        session.tool = .polygon; inspector.refresh(); XCTAssertFalse(preset.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(inspector.snapshotFilter.itemTitles, SnapshotStyle.Filter.allCases.map(\.title))
        session.canEdit = { false }; inspector.refresh(); XCTAssertFalse(preset.isEnabled)
    }
}
