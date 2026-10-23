import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class FreehandHighlighterTests: XCTestCase {
    private func canvas(rotation: Int = 0, _ body: (MarkupPDFView, PDFPage) throws -> Void) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = MarkupPDFView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        let document = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 320, height: 320), for: .mediaBox)
        page.rotation = rotation; document.insert(page, at: 0)
        view.setMarkupDocument(document); view.displayMode = .singlePage; view.autoScales = true; view.go(to: page)
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
        view.rectangleMarkup.canEdit = { true }; view.rectangleMarkup.undo.groupsByEvent = false
        let key = "MarkupDefaults.v1.highlight", prior = UserDefaults.standard.object(forKey: "MarkupDefaults.v1.highlight")
        UserDefaults.standard.removeObject(forKey: key)
        defer { if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        try body(view, page)
    }
    private let points = [CGPoint(x: 50, y: 70), CGPoint(x: 100, y: 70), CGPoint(x: 100, y: 150), CGPoint(x: 240, y: 150)]
    private func stroke(_ view: MarkupPDFView, _ page: PDFPage) throws -> PDFAnnotation {
        let c = view.rectangleMarkup
        XCTAssertTrue(c.pointerDown(at: view.convert(points[0], from: page)))
        for point in points.dropFirst() { XCTAssertTrue(c.pointerDragged(at: view.convert(point, from: page))) }
        XCTAssertTrue(page.annotations.isEmpty)
        c.undo.beginUndoGrouping()
        XCTAssertTrue(c.pointerUp(at: view.convert(points.last!, from: page)))
        c.undo.endUndoGrouping()
        return try XCTUnwrap(page.annotations.last)
    }
    func testContinuousBentStrokesRepeatUntilEscapeWithoutSelectionAtAllRotations() throws {
        for rotation in [0, 90, 180, 270] {
            try canvas(rotation: rotation) { view, page in
                let c = view.rectangleMarkup; c.tool = .highlight
                for _ in 0..<2 {
                    let annotation = try stroke(view, page)
                    XCTAssertEqual(annotation.type, "Ink")
                    XCTAssertEqual(annotation.value(forAnnotationKey: RectangleMarkupRecord.inkToolKey) as? String, "highlight")
                    let actual = RectangleMarkupRecord.vertices(annotation)
                    XCTAssertEqual(actual.count, points.count)
                    for (a, b) in zip(actual, points) { XCTAssertEqual(a.x, b.x, accuracy: 1e-6); XCTAssertEqual(a.y, b.y, accuracy: 1e-6) }
                    XCTAssertEqual(c.tool, .highlight); XCTAssertNil(c.selected); XCTAssertTrue(c.selectedItems.isEmpty)
                    c.undo.undo(); XCTAssertTrue(page.annotations.isEmpty)
                    c.undo.redo(); XCTAssertTrue(page.annotations.first === annotation)
                    page.removeAnnotation(annotation)
                }
                c.escape(); XCTAssertEqual(c.tool, .select)
            }
        }
    }
    func testIndependentDefaultsInspectorAndSavedAppearance() throws {
        let name = "FreehandHighlighter-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let c = RectangleMarkupController(defaults: defaults)
        c.tool = .pen; c.lineWidth = 3; c.strokeOpacity = 0.8; c.strokeColor = .red
        c.tool = .highlight
        XCTAssertEqual(c.lineWidth, 20); XCTAssertEqual(c.strokeOpacity, 0.20)
        let color = try XCTUnwrap(c.strokeColor.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, 0.9); XCTAssertGreaterThan(color.greenComponent, 0.9); XCTAssertLessThan(color.blueComponent, 0.5)
        let inspector = MarkupPropertiesViewController(); inspector.session = c; inspector.refresh()
        XCTAssertFalse(inspector.weight.isHiddenOrHasHiddenAncestor); XCTAssertTrue(inspector.weight.isEnabled)
        inspector.weight.doubleValue = 28
        XCTAssertTrue(inspector.weight.sendAction(inspector.weight.action, to: inspector.weight.target))
        XCTAssertEqual(c.lineWidth, 28)
        c.strokeColor = .green; c.strokeOpacity = 0.4
        XCTAssertTrue(c.saveCurrentAsDefault())
        c.tool = .pen; XCTAssertEqual(c.lineWidth, 3); XCTAssertEqual(c.strokeOpacity, 0.8)
        c.tool = .highlight; XCTAssertEqual(c.lineWidth, 28); XCTAssertEqual(c.strokeOpacity, 0.4)
    }
    func testClipboardInspectorStyleUndoAndRealWriterRenderingWithLegacyControl() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DRAWBRIDGE_FREEHAND_EVIDENCE"] ?? NSTemporaryDirectory()).appendingPathComponent("rendered-freehand")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for rotation in [0, 90, 180, 270] {
            try canvas(rotation: rotation) { view, page in
                let c = view.rectangleMarkup; c.tool = .highlight
                let annotation = try stroke(view, page)
                c.setSelectedItems([annotation])
                let inspector = MarkupPropertiesViewController(); inspector.session = c; inspector.refresh()
                XCTAssertFalse(inspector.weight.isHiddenOrHasHiddenAncestor)
                c.undo.beginUndoGrouping(); inspector.strokeOpacity.doubleValue = 40
                XCTAssertTrue(inspector.strokeOpacity.sendAction(inspector.strokeOpacity.action, to: inspector.strokeOpacity.target)); c.undo.endUndoGrouping()
                XCTAssertEqual(MarkupStyle.strokeOpacity(annotation), 0.4, accuracy: 0.001)
                c.undo.undo(); XCTAssertEqual(MarkupStyle.strokeOpacity(annotation), 0.2, accuracy: 0.001)
                c.undo.redo(); XCTAssertEqual(MarkupStyle.strokeOpacity(annotation), 0.4, accuracy: 0.001)
                let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString)); defer { board.releaseGlobally() }
                XCTAssertTrue(MarkupClipboard.copy([annotation], to: board))
                let copied = try XCTUnwrap(MarkupClipboard.read(from: board)?.first)
                let record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: copied, pageIndex: 0))
                XCTAssertEqual(record.inkTool, "highlight"); XCTAssertEqual(record.kind, .polyline); XCTAssertTrue(record.isValid)
                let pasted = try XCTUnwrap(c.pasteMarkups([copied], on: page, center: CGPoint(x: 160, y: 160), inPlace: true).first)
                XCTAssertEqual(RectangleMarkupRecord.vertices(pasted), RectangleMarkupRecord.vertices(annotation))
                var legacy = RectangleMarkupRecord(id: record.id + "legacy", pageIndex: 0, bounds: CGRect(x: 250, y: 250, width: 40, height: 25), red: 1, green: 1, blue: 0, lineWidth: 2)
                legacy.kind = .highlight; legacy.strokeOpacity = 0.35
                let source = root.appendingPathComponent("source-\(rotation).pdf"), output = root.appendingPathComponent("saved-\(rotation).pdf")
                let blank = PDFDocument(); let blankPage = PDFPage(); blankPage.setBounds(page.bounds(for: .mediaBox), for: .mediaBox); blankPage.rotation = rotation; blank.insert(blankPage, at: 0)
                XCTAssertTrue(blank.write(to: source))
                let original = try Data(contentsOf: source)
                var loaded = try XCTUnwrap(PDFDocument(url: source))
                for pass in 0..<2 {
                    let input = pass == 0 ? source : output
                    var failure: PDFRectangleWriter.SaveFailure?
                    XCTAssertTrue(PDFRectangleWriter.write(document: loaded, source: input, destination: output, pageLabels: [:], records: [record, legacy], onFailure: { failure = $0 }), "\(failure?.stage ?? "unknown")")
                    loaded = try XCTUnwrap(PDFDocument(url: output))
                    let records = RectangleMarkupRecord.capture(loaded)
                    XCTAssertEqual(records.first { $0.id == record.id }?.inkTool, "highlight")
                    XCTAssertEqual(records.first { $0.id == legacy.id }?.kind, .highlight)
                }
                XCTAssertEqual(try Data(contentsOf: source), original)
                let savedPage = try XCTUnwrap(loaded.page(at: 0))
                XCTAssertEqual(savedPage.rotation, rotation)
                // Inspect appearance in unrotated page space so each quarter-turn has the same pixel oracle.
                savedPage.rotation = 0
                let bitmap = try raster(savedPage, png: root.appendingPathComponent("saved-\(rotation).png"))
                XCTAssertEqual(bitmap[70 * 320 + 75], 0.7, accuracy: 0.04, "Stroke center")
                XCTAssertEqual(bitmap[110 * 320 + 75], 1, accuracy: 0.02, "Bent path must not fill its bounding rectangle")
                XCTAssertLessThan(bitmap[70 * 320 + 43], 0.9, "Rounded starting cap extends behind endpoint")
                page.removeAnnotation(pasted)
                let live = try raster(page, png: root.appendingPathComponent("live-\(rotation).png"))
                if rotation == 0 { XCTAssertEqual(live[70 * 320 + 75], 0.7, accuracy: 0.04); XCTAssertEqual(live[110 * 320 + 75], 1, accuracy: 0.02) }
            }
        }
    }
    func testFreehandKeepsUnderlyingBlackContentLegibleLiveAndAfterSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("black-source.pdf"), output = root.appendingPathComponent("black-saved.pdf")
        var media = CGRect(x: 0, y: 0, width: 320, height: 320)
        let ctx = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &media, nil))
        ctx.beginPDFPage(nil); ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 90, y: 40, width: 20, height: 40)); ctx.endPDFPage(); ctx.closePDF()
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        let controller = RectangleMarkupController(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        controller.bind(to: document); controller.tool = .highlight; controller.strokeOpacity = 0.8
        let annotation = try XCTUnwrap(controller.createPolyline(on: page, points: [CGPoint(x: 50, y: 60), CGPoint(x: 150, y: 60)]))
        let live = try raster(page, png: root.appendingPathComponent("live.png"))
        XCTAssertEqual(live[60 * 320 + 100], 0, accuracy: 0.02, "Live highlighter must not wash out black source content")
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: [try XCTUnwrap(RectangleMarkupRecord.capture(annotation: annotation, pageIndex: 0))]))
        let saved = try XCTUnwrap(PDFDocument(url: output))
        let pixels = try raster(try XCTUnwrap(saved.page(at: 0)), png: root.appendingPathComponent("saved.png"))
        XCTAssertEqual(pixels[60 * 320 + 100], 0, accuracy: 0.02, "Saved appearance must agree with live highlighter")
    }

    func testCancelledDraftsAndToolChangesNeverCommitOrRegisterUndo() throws {
        try canvas { view, page in
            let c = view.rectangleMarkup
            let start = view.convert(points[0], from: page), end = view.convert(points[1], from: page)
            for cancellation in 0..<3 {
                c.tool = .highlight
                XCTAssertTrue(c.pointerDown(at: start))
                XCTAssertTrue(c.pointerDragged(at: end))
                if cancellation == 0 { c.escape() }
                else if cancellation == 1 { c.cancelGesture() }
                else { c.tool = .pen }
                _ = c.pointerUp(at: end)
                XCTAssertTrue(page.annotations.isEmpty)
                XCTAssertFalse(c.undo.canUndo)
                XCTAssertFalse(c.hasUnsavedChanges)
                XCTAssertNil(c.selected)
            }
            c.tool = .highlight
            XCTAssertTrue(c.pointerDown(at: start))
            _ = c.pointerUp(at: start)
            XCTAssertTrue(page.annotations.isEmpty, "A click is not a marker stroke")
            XCTAssertEqual(c.tool, .highlight)
        }
    }

    func testHiddenNativeControllerGestureSaveAsAndReopen() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DRAWBRIDGE_FREEHAND_EVIDENCE"] ?? NSTemporaryDirectory()).appendingPathComponent("controller-save")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.pdf"), output = root.appendingPathComponent("saved.pdf")
        var media = CGRect(x: 0, y: 0, width: 320, height: 320)
        let ctx = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &media, nil))
        ctx.beginPDFPage(nil); ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 90, y: 50, width: 20, height: 40)); ctx.endPDFPage(); ctx.closePDF()
        let original = try Data(contentsOf: source)
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        defer { window.makeFirstResponder(nil); window.contentViewController = nil; window.close() }
        controller.openDocument(at: source); window.layoutIfNeeded()
        let view = controller.pdfView, c = controller.pdfView.rectangleMarkup
        let page = try XCTUnwrap(view.document?.page(at: 0))
        c.canEdit = { true }; c.undo.groupsByEvent = false
        c.tool = .highlight; c.lineWidth = 20; c.strokeColor = .yellow; c.strokeOpacity = 0.8
        let annotation = try stroke(view, page)
        XCTAssertTrue(annotation is DrawbridgeHighlighterAnnotation)
        XCTAssertTrue(c.hasUnsavedChanges); XCTAssertNil(c.selected); XCTAssertEqual(c.tool, .highlight)
        let live = try raster(page, png: root.appendingPathComponent("live.png"))
        XCTAssertEqual(live[70 * 320 + 100], 0, accuracy: 0.02)
        var result: Bool?
        controller.persistDocument(to: output, adoptAsPrimaryDocument: true, busyMessage: "Saving", showBusyOverlay: false) { result = $0 }
        let deadline = Date().addingTimeInterval(20)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(result, true)
        XCTAssertFalse(c.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let reopened = try XCTUnwrap(PDFDocument(url: output)), savedPage = try XCTUnwrap(reopened.page(at: 0))
        let saved = try raster(savedPage, png: root.appendingPathComponent("saved.png"))
        XCTAssertEqual(saved[70 * 320 + 100], 0, accuracy: 0.02)
        let reloaded = RectangleMarkupController(); reloaded.bind(to: reopened)
        let imported = try XCTUnwrap(savedPage.annotations.first)
        XCTAssertTrue(imported is DrawbridgeHighlighterAnnotation)
        XCTAssertEqual(RectangleMarkupRecord.identity(imported), RectangleMarkupRecord.identity(annotation))
        let vertices = RectangleMarkupRecord.vertices(imported)
        XCTAssertEqual(vertices.count, points.count)
        for (actual, expected) in zip(vertices, points) {
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.0001)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.0001)
        }
        let native = try raster(savedPage, png: root.appendingPathComponent("reopened-live.png"))
        XCTAssertEqual(native[70 * 320 + 100], 0, accuracy: 0.02)
        XCTAssertFalse(window.isVisible)
    }

    func testPenPolylineAndUnlabelledInkKeepNormalAlphaOverLiveAndSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf"), output = root.appendingPathComponent("saved.pdf")
        var media = CGRect(x: 0, y: 0, width: 320, height: 320)
        let ctx = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &media, nil))
        ctx.beginPDFPage(nil); ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 90, y: 40, width: 20, height: 40)); ctx.endPDFPage(); ctx.closePDF()
        for tool: String? in ["pen", "polyline", nil] {
            let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
            var record = RectangleMarkupRecord(id: RectangleMarkupRecord.prefix + UUID().uuidString, pageIndex: 0, bounds: CGRect(x: 40, y: 50, width: 120, height: 20), red: 0, green: 0, blue: 1, lineWidth: 20)
            record.kind = .polyline; record.inkTool = tool; record.strokeOpacity = 0.8
            record.vertices = [CGPoint(x: 50, y: 60), CGPoint(x: 150, y: 60)]
            let annotation = try record.clipboardAnnotation(contents: nil); page.addAnnotation(annotation)
            XCTAssertFalse(annotation is DrawbridgeHighlighterAnnotation)
            let live = try raster(page, png: root.appendingPathComponent("live.png"))
            XCTAssertEqual(live[60 * 320 + 100], 0.8, accuracy: 0.02)
            XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: [record]))
            let saved = try XCTUnwrap(PDFDocument(url: output))
            let pixels = try raster(try XCTUnwrap(saved.page(at: 0)), png: root.appendingPathComponent("saved.png"))
            XCTAssertEqual(pixels[60 * 320 + 100], 0.8, accuracy: 0.02)
        }
    }

    private func raster(_ page: PDFPage, png: URL) throws -> [Double] {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 320, height: 320, bitsPerComponent: 8, bytesPerRow: 1280, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
        page.draw(with: .mediaBox, to: ctx)
        let image = try XCTUnwrap(ctx.makeImage())
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: png)
        let bytes = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(320 * 320)).map { index in
            let x = index % 320, y = index / 320
            return Double(bytes[((319 - y) * 320 + x) * 4 + 2]) / 255
        }
    }
}
