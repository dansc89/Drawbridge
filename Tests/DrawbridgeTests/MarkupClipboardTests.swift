import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class MarkupClipboardTests: XCTestCase {
    private func setup() -> (MainViewController, PDFPage) {
        _ = NSApplication.shared
        NSPasteboard.general.clearContents()
        let c = MainViewController(); c.loadViewIfNeeded()
        let d = PDFDocument(), p = PDFPage()
        p.setBounds(CGRect(x: 0, y: 0, width: 600, height: 400), for: .mediaBox)
        d.insert(p, at: 0); c.pdfView.setMarkupDocument(d)
        c.pdfView.rectangleMarkup.canEdit = { true }
        return (c, p)
    }
    private func snapshotData() throws -> Data {
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 70, height: 50)
        let consumer = try XCTUnwrap(CGDataConsumer(data: output))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.setFillColor(NSColor.red.cgColor)
        context.fill(box); context.endPDFPage(); context.closePDF()
        return output as Data
    }

    func testCrossDocumentForeignLayerWithoutActiveLayerCanSave() throws {
        let (source, sourcePage) = setup(), sourceSession = source.pdfView.rectangleMarkup
        let foreignID = try XCTUnwrap(sourceSession.addLayer(named: "Source only"))
        sourceSession.setActiveLayer(foreignID)
        let original = try XCTUnwrap(sourceSession.create(on: sourcePage, bounds: CGRect(x: 20, y: 30, width: 70, height: 50)))
        XCTAssertEqual(MarkupLayers.id(original), foreignID)
        let board = NSPasteboard(name: .init("ClipboardLayers-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        XCTAssertTrue(MarkupClipboard.copy([original], to: board))
        let (destination, page) = setup(), session = destination.pdfView.rectangleMarkup
        XCTAssertNil(session.layerCatalog.activeID)
        let pasted = try XCTUnwrap(session.pasteMarkups(try XCTUnwrap(MarkupClipboard.read(from: board)), on: page, center: CGPoint(x: 200, y: 150)).first)
        XCTAssertNil(MarkupLayers.id(pasted), "Foreign membership must be cleared when there is no active destination layer")
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardLayer-" + UUID().uuidString + ".pdf")
        let output = input.deletingPathExtension().appendingPathExtension("saved.pdf")
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        // Use a real blank PDF source, not PDFKit's synthetic empty page.
        var box = page.bounds(for: .mediaBox)
        let context = try XCTUnwrap(CGContext(input as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        XCTAssertTrue(PDFRectangleWriter.write(document: try XCTUnwrap(page.document), source: input, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(try XCTUnwrap(page.document))))
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        let saved = try XCTUnwrap(reopened.page(at: 0)?.annotations.first { RectangleMarkupRecord.owns($0) })
        XCTAssertNil(MarkupLayers.id(saved))
        XCTAssertEqual(saved.bounds, pasted.bounds)
    }

    func testKnownLayerPreservedAndForeignLayerUsesActiveDestination() throws {
        let (c, page) = setup(), session = c.pdfView.rectangleMarkup
        let known = try XCTUnwrap(session.addLayer(named: "Known"))
        let active = try XCTUnwrap(session.addLayer(named: "Active"))
        session.setActiveLayer(active)
        let original = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 20, y: 30, width: 70, height: 50)))
        original.setValue(known, forAnnotationKey: MarkupLayers.membershipKey)
        let kept = try XCTUnwrap(session.pasteMarkups([original], on: page, center: .zero, inPlace: true).first)
        XCTAssertEqual(MarkupLayers.id(kept), known)
        original.setValue(UUID().uuidString, forAnnotationKey: MarkupLayers.membershipKey)
        let assigned = try XCTUnwrap(session.pasteMarkups([original], on: page, center: .zero, inPlace: true).first)
        XCTAssertEqual(MarkupLayers.id(assigned), active)
    }

    private func checkSnapshotPaste(sourceRotation: Int, destinationRotation: Int, inPlace: Bool) throws {
        let (source, sourcePage) = setup(), sourceSession = source.pdfView.rectangleMarkup
        sourcePage.rotation = sourceRotation
        let data = try snapshotData()
        let original = try XCTUnwrap(sourceSession.pasteSnapshot(SnapshotPayload(data: data), on: sourcePage, center: CGPoint(x: 100, y: 100)))
        // Deliberately resize away from the payload's natural 70 x 50 dimensions.
        let bounds = CGRect(x: 30, y: 40, width: 160, height: 60)
        original.bounds = bounds
        XCTAssertEqual(try XCTUnwrap(RectangleMarkupRecord.capture(annotation: original, pageIndex: 0)).textRotation, sourceRotation)
        let board = NSPasteboard(name: .init("ClipboardRotation-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        XCTAssertTrue(MarkupClipboard.copy([original], to: board))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(board.data(forType: MarkupClipboard.type))) as? [String: Any])
        let entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        let record = try XCTUnwrap(entries.first?["record"] as? [String: Any])
        XCTAssertEqual(record["textRotation"] as? Int, sourceRotation, "Clipboard must save the source snapshot rotation")
        let decoded = try XCTUnwrap(MarkupClipboard.read(from: board))
        let (destination, page) = setup(), session = destination.pdfView.rectangleMarkup
        page.rotation = destinationRotation
        session.undo.groupsByEvent = false; session.undo.removeAllActions()
        let swapped = sourceRotation % 180 != destinationRotation % 180
        let size = swapped ? CGSize(width: 60, height: 160) : bounds.size
        // Edge-center placement exposes clamping performed before the swap.
        let expected = inPlace
            ? CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            : CGRect(x: 600 - size.width, y: 400 - size.height, width: size.width, height: size.height)
        let pasted = try XCTUnwrap(session.pasteMarkups(decoded, on: page, center: CGPoint(x: 595, y: 395), inPlace: inPlace).first)
        XCTAssertEqual(pasted.bounds, expected, "Snapshot dimensions must follow destination rotation before placement/clamping")
        XCTAssertEqual(SnapshotPayload.read(pasted)?.data, data)
        XCTAssertEqual(decoded[0].bounds, bounds)
        XCTAssertEqual(original.bounds, bounds)
        session.undo.undo(); XCTAssertFalse(page.annotations.contains { $0 === pasted })
        session.undo.redo(); XCTAssertTrue(page.annotations.contains { $0 === pasted }); XCTAssertEqual(pasted.bounds, expected)
    }

    func testSnapshotPasteEvenToOddRotationSwapsResizedBoundsBeforeClamping() throws {
        try checkSnapshotPaste(sourceRotation: 0, destinationRotation: 90, inPlace: false)
    }
    func testSnapshotPasteOddToEvenRotationRetainsSavedSourceRotation() throws {
        try checkSnapshotPaste(sourceRotation: 90, destinationRotation: 0, inPlace: false)
    }
    func testSnapshotPasteSameParityPreservesResizedBounds() throws {
        try checkSnapshotPaste(sourceRotation: 90, destinationRotation: 270, inPlace: false)
        try checkSnapshotPaste(sourceRotation: 0, destinationRotation: 180, inPlace: false)
    }
    func testSnapshotPasteInPlaceSwapsAroundOriginalCenter() throws {
        try checkSnapshotPaste(sourceRotation: 270, destinationRotation: 180, inPlace: true)
        try checkSnapshotPaste(sourceRotation: 180, destinationRotation: 180, inPlace: true)
    }

    func testSingleSnapshotCopyPublishesPDFAndCompatiblePrivateTypesOnSuppliedBoard() throws {
        let (c, page) = setup(), session = c.pdfView.rectangleMarkup
        page.rotation = 90
        let data = try snapshotData()
        let original = try XCTUnwrap(session.pasteSnapshot(SnapshotPayload(data: data), on: page, center: CGPoint(x: 100, y: 100)))
        original.bounds = CGRect(x: 30, y: 40, width: 160, height: 60)
        let board = NSPasteboard(name: .init("ClipboardRepresentations-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        NSPasteboard.general.setString("Do not replace general board", forType: .string)
        board.setString("Stale", forType: .string)
        XCTAssertTrue(MarkupClipboard.copy([original], to: board))
        XCTAssertEqual(board.data(forType: .pdf), data)
        XCTAssertEqual(board.data(forType: SnapshotPayload.clipboardType), data)
        XCTAssertNil(board.string(forType: .string))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Do not replace general board")
        let placement = try JSONDecoder().decode(SnapshotPayload.Placement.self, from: XCTUnwrap(board.data(forType: SnapshotPayload.placementType)))
        XCTAssertEqual(placement.x, 30); XCTAssertEqual(placement.y, 40)
        XCTAssertEqual(placement.width, 160); XCTAssertEqual(placement.height, 60); XCTAssertEqual(placement.rotation, 90)
        let style = try JSONDecoder().decode(SnapshotStyle.self, from: XCTUnwrap(board.data(forType: SnapshotPayload.styleType)))
        XCTAssertEqual(style, SnapshotStyle.read(original))
        XCTAssertTrue(MarkupClipboard.canPaste(from: board))
        XCTAssertEqual(MarkupClipboard.read(from: board)?.count, 1)
    }

    func testMultiMarkupCopyDoesNotPublishOneSnapshotsPDF() throws {
        let (c, page) = setup(), session = c.pdfView.rectangleMarkup
        let snapshot = try XCTUnwrap(session.pasteSnapshot(SnapshotPayload(data: snapshotData()), on: page, center: CGPoint(x: 100, y: 100)))
        let rectangle = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 20, y: 30, width: 70, height: 50)))
        let board = NSPasteboard(name: .init("ClipboardMulti-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        for items in [[snapshot, rectangle], [snapshot, snapshot], [rectangle]] {
            board.clearContents(); board.setData(Data("stale".utf8), forType: .pdf)
            XCTAssertTrue(MarkupClipboard.copy(items, to: board))
            XCTAssertNil(board.data(forType: .pdf))
            XCTAssertNil(board.data(forType: SnapshotPayload.clipboardType))
            XCTAssertNil(board.data(forType: SnapshotPayload.placementType))
            XCTAssertNil(board.data(forType: SnapshotPayload.styleType))
            XCTAssertEqual(MarkupClipboard.read(from: board)?.count, items.count)
        }
        board.setString("Preserve on rejection", forType: .string)
        XCTAssertFalse(MarkupClipboard.copy(Array(repeating: rectangle, count: MarkupClipboard.maximumItems + 1), to: board))
        XCTAssertEqual(board.string(forType: .string), "Preserve on rejection")
    }

    func testRectangleMenuCopyPasteInPlaceAndUndoRedo() throws {
        let (c, p) = setup(), s = c.pdfView.rectangleMarkup
        s.undo.groupsByEvent = false; s.undo.beginUndoGrouping()
        let original = try XCTUnwrap(s.create(on: p, bounds: CGRect(x: 20, y: 30, width: 70, height: 50)))
        s.undo.endUndoGrouping(); s.undo.removeAllActions()
        XCTAssertTrue(c.validateMenuItem(NSMenuItem(title: "Copy", action: #selector(c.commandCopy(_:)), keyEquivalent: "c")))
        XCTAssertTrue(MarkupClipboard.copy([original]))
        c.commandCopy(nil)
        XCTAssertNotNil(NSPasteboard.general.data(forType: MarkupClipboard.type))
        XCTAssertNotNil(MarkupClipboard.read())
        XCTAssertTrue(c.validateMenuItem(NSMenuItem(title: "Paste", action: #selector(c.commandPaste(_:)), keyEquivalent: "v")))
        s.undo.beginUndoGrouping(); c.commandPasteInPlace(nil); s.undo.endUndoGrouping()
        XCTAssertEqual(p.annotations.count, 2)
        guard p.annotations.count == 2 else { return }
        let pasted = try XCTUnwrap(s.selected)
        XCTAssertFalse(pasted === original); XCTAssertEqual(pasted.bounds, original.bounds)
        XCTAssertNotEqual(RectangleMarkupRecord.identity(pasted), RectangleMarkupRecord.identity(original))
        s.undo.undo(); XCTAssertEqual(p.annotations.count, 1)
        s.undo.redo(); XCTAssertEqual(p.annotations.count, 2); XCTAssertTrue(s.selected === pasted)
    }
    func testRepeatedPasteOffsetsAndRejectsMalformedClipboardWithoutMutation() throws {
        let (c, p) = setup(), s = c.pdfView.rectangleMarkup
        s.undo.groupsByEvent = false; s.undo.beginUndoGrouping()
        let vertices = [CGPoint(x: 25, y: 35), CGPoint(x: 80, y: 70)]
        let original = try XCTUnwrap(s.create(on: p, bounds: CGRect(x: 20, y: 30, width: 70, height: 50), kind: .polyline, vertices: vertices))
        s.undo.endUndoGrouping(); s.undo.removeAllActions()
        XCTAssertTrue(MarkupClipboard.copy([original]))
        let decoded = try XCTUnwrap(MarkupClipboard.read())
        var previous: PDFAnnotation?
        for _ in 0..<2 {
            s.undo.beginUndoGrouping()
            let pasted = try XCTUnwrap(s.pasteMarkups(decoded, on: p, center: CGPoint(x: 255, y: 155)).first)
            s.undo.endUndoGrouping()
            XCTAssertEqual(pasted.bounds, CGRect(x: 220, y: 130, width: 70, height: 50))
            XCTAssertEqual(RectangleMarkupRecord.vertices(pasted), vertices.map { CGPoint(x: $0.x + 200, y: $0.y + 100) })
            XCTAssertEqual(decoded[0].bounds, original.bounds)
            XCTAssertEqual(RectangleMarkupRecord.vertices(original), vertices)
            XCTAssertFalse(pasted === previous)
            previous = pasted
        }
        let count = p.annotations.count
        for json in ["{}", "{\"version\":99,\"records\":[]}", "{\"version\":1,\"records\":[]}"] {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setData(Data(json.utf8), forType: MarkupClipboard.type)
            XCTAssertNil(MarkupClipboard.read())
            c.commandPasteInPlace(nil)
            XCTAssertEqual(p.annotations.count, count)
        }
        s.canEdit = { false }
        XCTAssertTrue(s.pasteMarkups(decoded, on: p, center: .zero).isEmpty)
        XCTAssertEqual(p.annotations.count, count)
    }

    func testValidationCacheInvalidatesAndPasteStillCreatesFreshInstances() throws {
        let (c, p) = setup(), s = c.pdfView.rectangleMarkup
        let annotation = try XCTUnwrap(s.create(on: p, bounds: CGRect(x: 20, y: 30, width: 80, height: 40)))
        let board = NSPasteboard(name: NSPasteboard.Name("DrawbridgeClipboardTests-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        XCTAssertFalse(MarkupClipboard.canPaste(from: board))
        XCTAssertTrue(MarkupClipboard.copy([annotation], to: board))
        XCTAssertTrue(MarkupClipboard.canPaste(from: board))
        XCTAssertTrue(MarkupClipboard.canPaste(from: board))
        let first = try XCTUnwrap(MarkupClipboard.read(from: board)?.first)
        let second = try XCTUnwrap(MarkupClipboard.read(from: board)?.first)
        XCTAssertFalse(first === second)
        XCTAssertNotEqual(RectangleMarkupRecord.identity(first), RectangleMarkupRecord.identity(second))
        board.clearContents(); board.setData(Data("{}".utf8), forType: MarkupClipboard.type)
        XCTAssertFalse(MarkupClipboard.canPaste(from: board))
        XCTAssertNil(MarkupClipboard.read(from: board))
    }

    func testClipboardRejectsInconsistentTextAndPageScaleRecordsBeforePaste() throws {
        let (c, p) = setup(), s = c.pdfView.rectangleMarkup
        let annotation = try XCTUnwrap(s.create(on: p, bounds: CGRect(x: 20, y: 30, width: 80, height: 40), kind: .text, text: "Valid text"))
        var record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: annotation, pageIndex: 0))
        struct Entry: Codable { let record: RectangleMarkupRecord; let contents: String? }
        struct Envelope: Codable { let version: Int; let entries: [Entry] }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(try JSONEncoder().encode(Envelope(version: 1, entries: [Entry(record: record, contents: "")])), forType: MarkupClipboard.type)
        XCTAssertNil(MarkupClipboard.read())
        record.kind = .rectangle; record.measurement = nil
        record.pageScale = try XCTUnwrap(DrawingScale.architectural(inches: 0.125, name: "Clipboard scale"))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(try JSONEncoder().encode(Envelope(version: 1, entries: [Entry(record: record, contents: "")])), forType: MarkupClipboard.type)
        XCTAssertNil(MarkupClipboard.read())
    }

    func testAllActiveKindsMultiSelectionStyleGeometryAndMetadata() throws {
        let (c, p) = setup(), s = c.pdfView.rectangleMarkup
        s.strokeColor = .blue; s.lineWidth = 3; s.linePattern = .dashed; s.strokeOpacity = 0.6
        s.undo.groupsByEvent = false; s.undo.beginUndoGrouping()
        var originals: [PDFAnnotation] = []
        for kind in [RectangleMarkupRecord.Kind.rectangle, .ellipse, .line, .arrow, .text, .polyline, .polygon] {
            s.tool = kind == .polyline ? .pen : .rectangle
            originals.append(try XCTUnwrap(s.create(on: p, bounds: CGRect(x: 20, y: 30, width: 70, height: 50), kind: kind, endpoints: (CGPoint(x: 25, y: 35), CGPoint(x: 80, y: 70)), text: "Clipboard text", vertices: [CGPoint(x: 25, y: 35), CGPoint(x: 80, y: 35), CGPoint(x: 80, y: 70)])))
        }
        s.tool = .polyline
        originals.append(try XCTUnwrap(s.create(on: p, bounds: CGRect(x: 20, y: 30, width: 70, height: 50), kind: .polyline, vertices: [CGPoint(x: 25, y: 35), CGPoint(x: 80, y: 70)])))
        let scale = try XCTUnwrap(DrawingScale.architectural(inches: 0.125, name: "Clipboard scale"))
        for measurementKind in [DrawingMeasurement.Kind.area, .perimeter] {
            let closed = true
            originals.append(try XCTUnwrap(s.create(on: p, bounds: CGRect(x: 20, y: 30, width: 70, height: 50), kind: .polygon, vertices: [CGPoint(x: 25, y: 35), CGPoint(x: 80, y: 35), CGPoint(x: 80, y: 70)], measurement: DrawingMeasurement(kind: measurementKind, scale: scale, closed: closed))))
        }
        let output = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 70, height: 50)
        let consumer = try XCTUnwrap(CGDataConsumer(data: output))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil); context.setFillColor(NSColor.red.cgColor); context.fill(media); context.endPDFPage(); context.closePDF()
        let snapshot = try XCTUnwrap(s.pasteSnapshot(SnapshotPayload(data: output as Data), on: p, center: CGPoint(x: 55, y: 55)))
        originals.append(snapshot)
        s.undo.endUndoGrouping(); s.undo.removeAllActions(); s.setSelectedItems(originals)
        for original in originals { XCTAssertTrue(try XCTUnwrap(RectangleMarkupRecord.capture(annotation: original, pageIndex: 0)).isValid, "Invalid \(original.type ?? "unknown")") }
        XCTAssertTrue(MarkupClipboard.copy(originals))
        c.commandCopy(nil)
        s.undo.beginUndoGrouping(); c.commandPasteInPlace(nil); s.undo.endUndoGrouping()
        XCTAssertEqual(p.annotations.count, originals.count * 2)
        XCTAssertEqual(s.selectedItems.count, originals.count)
        for (a, b) in zip(originals, s.selectedItems) {
            XCTAssertEqual(a.type, b.type); XCTAssertEqual(a.bounds, b.bounds)
            XCTAssertEqual(a.contents, b.contents); XCTAssertEqual(a.userName ?? "", b.userName ?? "")
            XCTAssertEqual(MeasurementMetadata.measurement(a), MeasurementMetadata.measurement(b))
            XCTAssertEqual(SnapshotPayload.read(a)?.data, SnapshotPayload.read(b)?.data)
            XCTAssertFalse(a === b)
            XCTAssertEqual(MarkupStyle.pattern(a), MarkupStyle.pattern(b))
            XCTAssertEqual(MarkupStyle.strokeOpacity(a), MarkupStyle.strokeOpacity(b))
            XCTAssertEqual(RectangleMarkupRecord.vertices(a), RectangleMarkupRecord.vertices(b))
            XCTAssertEqual(a.value(forAnnotationKey: RectangleMarkupRecord.inkToolKey) as? String, b.value(forAnnotationKey: RectangleMarkupRecord.inkToolKey) as? String)
        }
        s.undo.undo(); XCTAssertEqual(p.annotations.count, originals.count)
        s.undo.redo(); XCTAssertEqual(s.selectedItems.count, originals.count)
    }
}
