import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class SavedMarkupDefaultsTests: XCTestCase {
    private func preferences() -> (String, UserDefaults) {
        let name = "DrawbridgeDefaultsTests.\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }
    func testPolygonDefaultsSurviveRestartAndDoNotLeakIntoPen() throws {
        let (name, prefs) = preferences(); defer { prefs.removePersistentDomain(forName: name) }
        let session = RectangleMarkupController(defaults: prefs)
        session.tool = .polygon
        session.strokeColor = .blue; session.lineWidth = 5.5; session.linePattern = .dashDot
        session.strokeOpacity = 0.7
        session.fillColor = NSColor(deviceRed: 0.3, green: 0.4, blue: 0.5, alpha: 0.25)
        XCTAssertTrue(session.saveCurrentAsDefault())
        session.tool = .pen
        XCTAssertEqual(session.lineWidth, 2); XCTAssertEqual(SavedMarkupAppearance.components(session.strokeColor), SavedMarkupAppearance.components(.red))
        XCTAssertEqual(session.linePattern, .solid); XCTAssertEqual(session.strokeOpacity, 1)
        let reopened = RectangleMarkupController(defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
        reopened.tool = .polygon
        XCTAssertEqual(reopened.lineWidth, 5.5); XCTAssertEqual(reopened.linePattern, .dashDot)
        XCTAssertEqual(reopened.strokeOpacity, 0.7); XCTAssertEqual(reopened.fillColor?.alphaComponent, 0.25)
        XCTAssertEqual(SavedMarkupAppearance.components(reopened.strokeColor), SavedMarkupAppearance.components(.blue))
        reopened.fillColor = nil; XCTAssertTrue(reopened.saveCurrentAsDefault())
        reopened.tool = .line; reopened.tool = .polygon
        XCTAssertNil(reopened.fillColor)
    }
    func testSelectedAppearanceIsSavedWithoutMutatingPDFOrUndoAndUsedForNewMarkup() throws {
        let (name, prefs) = preferences(); defer { prefs.removePersistentDomain(forName: name) }
        let document = PDFDocument(), page = PDFPage(); document.insert(page, at: 0)
        let session = RectangleMarkupController(defaults: prefs); session.bind(to: document)
        session.undo.groupsByEvent = false
        session.undo.beginUndoGrouping()
        let annotation = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 30,y: 30,width: 70,height: 70)))
        session.styleSelected(color: .green, width: 6); session.setLineAppearance(pattern: .longDash, opacity: 0.6)
        session.undo.endUndoGrouping(); session.undo.removeAllActions()
        let records = RectangleMarkupRecord.capture(document), dirty = session.hasUnsavedChanges
        let inspector = MarkupPropertiesViewController(); inspector.session = session; inspector.refresh()
        XCTAssertTrue(inspector.setAsDefault.isEnabled)
        inspector.saveDefault(nil)
        XCTAssertEqual(inspector.defaultStatus.stringValue, "Default saved for this tool.")
        XCTAssertEqual(RectangleMarkupRecord.capture(document), records)
        XCTAssertEqual(session.hasUnsavedChanges, dirty); XCTAssertFalse(session.undo.canUndo)
        session.tool = .rectangle
        XCTAssertEqual(session.lineWidth, 6); XCTAssertEqual(session.linePattern, .longDash)
        session.undo.beginUndoGrouping()
        let next = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 130,y: 30,width: 70,height: 70)))
        session.undo.endUndoGrouping()
        XCTAssertEqual(next.border?.lineWidth, annotation.border?.lineWidth)
        XCTAssertEqual(MarkupStyle.strokeOpacity(next), 0.6)
        XCTAssertEqual(MarkupStyle.pattern(next), .longDash)
        session.tool = .line; session.tool = .select
        inspector.refresh(); XCTAssertFalse(inspector.setAsDefault.isEnabled)
    }
    func testRectangleAndEllipseSaveFillDefaultsIndependently() throws {
        let (name, prefs) = preferences(); defer { prefs.removePersistentDomain(forName: name) }
        let document = PDFDocument(), page = PDFPage(); document.insert(page, at: 0)
        let session = RectangleMarkupController(defaults: prefs); session.bind(to: document)
        for (kind, tool, opacity) in [(RectangleMarkupRecord.Kind.rectangle, RectangleMarkupController.Tool.rectangle, 0.5), (.ellipse, .ellipse, 0.25)] {
            session.tool = tool
            let annotation = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 30,y: 30,width: 70,height: 70), kind: kind))
            session.fillSelected(NSColor.blue.withAlphaComponent(CGFloat(opacity)))
            XCTAssertTrue(session.saveCurrentAsDefault())
            XCTAssertEqual(RectangleMarkupRecord.polygonFill(annotation).map { Double($0.alphaComponent) }, opacity)
        }
        let restored = RectangleMarkupController(defaults: prefs); restored.bind(to: document)
        for (kind, tool, opacity) in [(RectangleMarkupRecord.Kind.rectangle, RectangleMarkupController.Tool.rectangle, 0.5), (.ellipse, .ellipse, 0.25)] {
            restored.tool = tool
            let shape = try XCTUnwrap(restored.create(on: page, bounds: CGRect(x: 130,y: 30,width: 70,height: 70), kind: kind))
            XCTAssertEqual(RectangleMarkupRecord.polygonFill(shape).map { Double($0.alphaComponent) }, opacity)
            XCTAssertEqual(RectangleMarkupRecord.polygonFill(shape)?.blueComponent, 1)
        }
    }

    func testTextAndPenHaveSeparateDefaultsAndPenSelectionTargetsPen() throws {
        let (name, prefs) = preferences(); defer { prefs.removePersistentDomain(forName: name) }
        let session = RectangleMarkupController(defaults: prefs)
        session.tool = .text; session.fontSize = 32; session.strokeColor = .purple
        XCTAssertTrue(session.saveCurrentAsDefault())
        session.tool = .pen; session.lineWidth = 7; XCTAssertTrue(session.saveCurrentAsDefault())
        session.tool = .text; XCTAssertEqual(session.fontSize, 32); XCTAssertEqual(session.lineWidth, 2)
        session.tool = .pen; XCTAssertEqual(session.lineWidth, 7); XCTAssertEqual(session.fontSize, 18)
        let document = PDFDocument(), page = PDFPage(); document.insert(page, at: 0); session.bind(to: document)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("DefaultsPen-\(UUID().uuidString).pdf")
        let output = source.appendingPathExtension("saved.pdf")
        defer { [source, output].forEach { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertTrue(document.write(to: source))
        session.tool = .pen; session.undo.groupsByEvent = false; session.undo.beginUndoGrouping()
        let pen = try XCTUnwrap(session.createPolyline(on: page, points: [CGPoint(x: 20,y: 20),CGPoint(x: 50,y: 50)]))
        session.undo.endUndoGrouping()
        XCTAssertEqual(pen.value(forAnnotationKey: RectangleMarkupRecord.inkToolKey) as? String, "pen"); XCTAssertEqual(session.defaultTool, .pen)
        pen.contents = "A user comment"; XCTAssertEqual(session.defaultTool, .pen)
        let records = RectangleMarkupRecord.capture(document)
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: records))
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(RectangleMarkupRecord.capture(reopened), records)
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.value(forAnnotationKey: RectangleMarkupRecord.inkToolKey) as? String, "pen")
        session.tool = .polyline; XCTAssertEqual(session.lineWidth, 2)
    }
    func testSnapshotAppearanceDefaultsAreSharedByBothCaptureGestures() throws {
        let (name, prefs) = preferences(); defer { prefs.removePersistentDomain(forName: name) }
        let data = NSMutableData(); var box = CGRect(x: 0,y: 0,width: 400,height: 300)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data)), page = try XCTUnwrap(document.page(at: 0))
        var payload = try SnapshotPayload.capture(page: page, points: [CGPoint(x: 20,y: 20),CGPoint(x: 80,y: 20),CGPoint(x: 80,y: 80),CGPoint(x: 20,y: 80)])
        payload.style = SnapshotStyle(overlay: true, opacity: 0.65, filter: .grayscale)
        let session = RectangleMarkupController(defaults: prefs); session.bind(to: document)
        session.undo.groupsByEvent = false; session.undo.beginUndoGrouping()
        let annotation = try XCTUnwrap(session.pasteSnapshot(payload, on: page, center: CGPoint(x: 150,y: 150)))
        session.undo.endUndoGrouping(); session.undo.removeAllActions()
        XCTAssertTrue(session.saveCurrentAsDefault())
        for tool in [RectangleMarkupController.Tool.snapshotBox, .snapshotPolygon] {
            XCTAssertEqual(SavedMarkupAppearance.load(tool, from: prefs)?.snapshot, payload.style)
        }
        XCTAssertEqual(SnapshotStyle.read(annotation), payload.style); XCTAssertFalse(session.undo.canUndo)
    }
    func testDefaultsOnLargeDrawingSetSaveReopenAndRepeatSave() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_MARKUP_DEFAULTS_FIXTURE"] else {
            throw XCTSkip("Provide a large local drawing set to verify saved tool defaults")
        }
        let (name, prefs) = preferences(); defer { prefs.removePersistentDomain(forName: name) }
        let source = URL(fileURLWithPath: path)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("LargeDefaults-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: source, to: copy)
        let original = try Data(contentsOf: source, options: .mappedIfSafe)
        let document = try XCTUnwrap(PDFDocument(url: copy))
        let pageCount = document.pageCount
        let geometry = (0..<pageCount).map { document.page(at: $0)!.bounds(for: .cropBox) }
        let rotations = (0..<pageCount).map { document.page(at: $0)!.rotation }
        let tools: [RectangleMarkupController.Tool] = [.pen, .rectangle, .polygon, .text, .area, .perimeter]
        let setup = RectangleMarkupController(defaults: prefs)
        for (index, tool) in tools.enumerated() {
            setup.tool = tool; setup.lineWidth = CGFloat(index + 3); setup.linePattern = .dashDot
            setup.strokeOpacity = 0.65; setup.fontSize = 24
            setup.fillColor = NSColor(deviceRed: 0.1, green: 0.4, blue: 0.8, alpha: 0.25)
            XCTAssertTrue(setup.saveCurrentAsDefault())
        }
        // A new controller represents a reopened application using persisted preferences.
        let session = RectangleMarkupController(defaults: prefs); session.bind(to: document)
        session.undo.groupsByEvent = false
        let scale = try XCTUnwrap(DrawingScale.architectural(inches: 0.125, name: "1/8 inch = 1 foot"))
        for pageIndex in Set([0, pageCount / 2, pageCount - 1]).sorted() {
            let page = try XCTUnwrap(document.page(at: pageIndex)), crop = page.bounds(for: .cropBox)
            session.undo.beginUndoGrouping()
            for (index, tool) in tools.enumerated() {
                session.tool = tool
                XCTAssertEqual(session.lineWidth, CGFloat(index + 3))
                let origin = CGPoint(x: crop.minX + 30 + CGFloat(index) * 110, y: crop.minY + 40)
                let bounds = CGRect(origin: origin, size: CGSize(width: 80,height: 60))
                let points = [origin, CGPoint(x: bounds.maxX,y: bounds.minY), CGPoint(x: bounds.maxX,y: bounds.maxY), CGPoint(x: bounds.minX,y: bounds.maxY)]
                let annotation: PDFAnnotation?
                switch tool {
                case .pen: annotation = session.createPolyline(on: page, points: points)
                case .polygon: annotation = session.createPolyline(on: page, points: points, closed: true)
                case .text: annotation = session.create(on: page, bounds: bounds, kind: .text, text: "Large defaults QA")
                case .area, .perimeter: annotation = session.createMeasurement(on: page, points: points, kind: tool == .area ? .area : .perimeter, closed: tool == .area, scale: scale)
                default: annotation = session.create(on: page, bounds: bounds)
                }
                let created = try XCTUnwrap(annotation)
                XCTAssertEqual(MarkupStyle.strokeOpacity(created), 0.65)
                if tool != .text { XCTAssertEqual(MarkupStyle.pattern(created), .dashDot) }
            }
            session.undo.endUndoGrouping()
        }
        let expected = RectangleMarkupRecord.capture(document)
        let preparation = Date(); XCTAssertTrue(PDFRectangleWriter.prepareInspection(source: copy))
        print("Large defaults QA: pages", pageCount, "bytes", original.count, "preparation seconds", Date().timeIntervalSince(preparation))
        for pass in 1...2 {
            let start = Date()
            XCTAssertTrue(PDFRectangleWriter.write(document: document, source: copy, destination: copy, pageLabels: [:], records: expected))
            print("Large defaults QA save", pass, "seconds", Date().timeIntervalSince(start))
            let reopened = try XCTUnwrap(PDFDocument(url: copy))
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened), expected)
            XCTAssertEqual(reopened.pageCount, pageCount)
            XCTAssertEqual((0..<pageCount).map { reopened.page(at: $0)!.bounds(for: .cropBox) }, geometry)
            XCTAssertEqual((0..<pageCount).map { reopened.page(at: $0)!.rotation }, rotations)
        }
        XCTAssertTrue(try Data(contentsOf: copy, options: .mappedIfSafe).starts(with: original))
        XCTAssertEqual(try Data(contentsOf: source, options: .mappedIfSafe), original)
    }
    func testSavedSnapshotStyleReachesRectangleAndPolygonClipboardCaptures() throws {
        _ = NSApplication.shared
        let (name, prefs) = preferences(); defer { prefs.removePersistentDomain(forName: name) }
        let board = NSPasteboard.general
        let previousItems = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            board.clearContents()
            let items = previousItems.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            board.writeObjects(items)
        }
        let source = try SnapshotTests().fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let view = PDFView(frame: window.contentView!.bounds); window.contentView!.addSubview(view)
        view.document = document; view.go(to: page); window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
        let session = RectangleMarkupController(defaults: prefs); session.install(on: view); session.bind(to: document)
        var appearance = session.currentAppearance
        appearance.snapshot = SnapshotStyle(overlay: true, opacity: 0.4, filter: .colorize, color: [0.1, 0.8, 0.3])
        prefs.set(try JSONEncoder().encode(appearance), forKey: SavedMarkupAppearance.key(.snapshotBox))
        func location(_ x: CGFloat, _ y: CGFloat) -> CGPoint { view.convert(CGPoint(x: x, y: y), from: page) }
        session.tool = .snapshotBox
        XCTAssertTrue(session.pointerDown(at: location(80, 90)))
        XCTAssertTrue(session.pointerDragged(at: location(200, 170)))
        XCTAssertTrue(session.pointerUp(at: location(200, 170)))
        SnapshotTests().waitForCapture(session)
        XCTAssertEqual(try XCTUnwrap(SnapshotPayload.clipboard()).style, appearance.snapshot)
        session.tool = .snapshotBox
        XCTAssertTrue(session.pointerDown(at: location(80, 90))); _ = session.pointerUp(at: location(80, 90))
        XCTAssertTrue(session.pointerDown(at: location(200, 90))); _ = session.pointerUp(at: location(200, 90))
        XCTAssertTrue(session.pointerDown(at: location(80, 170), clickCount: 2)); _ = session.pointerUp(at: location(80, 170))
        SnapshotTests().waitForCapture(session)
        let payload = try XCTUnwrap(SnapshotPayload.clipboard())
        XCTAssertEqual(payload.style, appearance.snapshot)
        let annotation = try XCTUnwrap(session.pasteSnapshot(payload, on: page, center: .zero, inPlace: true))
        XCTAssertEqual(SnapshotStyle.read(annotation), appearance.snapshot)
    }

    func testCorruptOversizedAndIncompletePreferencesFallBackWithoutChangingOtherTools() throws {
        let (name, prefs) = preferences(); defer { prefs.removePersistentDomain(forName: name) }
        let session = RectangleMarkupController(defaults: prefs)
        session.tool = .pen; session.lineWidth = 5; XCTAssertTrue(session.saveCurrentAsDefault())
        for corrupt in [Data("not JSON".utf8), Data(repeating: 32, count: 4096), Data("{}".utf8)] {
            prefs.set(corrupt, forKey: SavedMarkupAppearance.key(.polygon))
            session.tool = .polygon
            XCTAssertEqual(session.lineWidth, 2)
            XCTAssertNil(SavedMarkupAppearance.load(.polygon, from: prefs))
            session.tool = .pen
            XCTAssertEqual(session.lineWidth, 5)
        }
    }

    func testInvalidStoredValuesAreIgnoredAndReadOnlyCannotSaveDefaults() throws {
        let (name, prefs) = preferences(); defer { prefs.removePersistentDomain(forName: name) }
        let session = RectangleMarkupController(defaults: prefs)
        var style = session.currentAppearance; style.width = 1000
        prefs.set(try JSONEncoder().encode(style), forKey: SavedMarkupAppearance.key(.polygon))
        session.tool = .polygon; XCTAssertEqual(session.lineWidth, 2)
        session.canEdit = { false }; XCTAssertFalse(session.saveCurrentAsDefault())
        let inspector = MarkupPropertiesViewController(); inspector.session = session; inspector.refresh()
        XCTAssertFalse(inspector.setAsDefault.isEnabled)
    }
}
