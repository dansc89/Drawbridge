import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class MarkupLayersTests: XCTestCase {
    func fixture() throws -> URL {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Layers-\(UUID().uuidString).pdf")
        var box = CGRect(x: 20, y: 30, width: 500, height: 400)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<3 {
            context.beginPDFPage(nil); context.setFillColor(NSColor.white.cgColor); context.fill(box)
            context.setStrokeColor(NSColor.black.cgColor); context.stroke(CGRect(x: 80, y: 100, width: 80, height: 50)); context.endPDFPage()
        }
        context.closePDF(); return url
    }
    func session(_ document: PDFDocument) -> MarkupPDFView {
        let view = MarkupPDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 700)); view.document = document
        view.rectangleMarkup.canEdit = { true }; view.rectangleMarkup.undo.groupsByEvent = false
        view.rectangleMarkup.bind(to: document); return view
    }
    func grouped<T>(_ session: RectangleMarkupController, _ body: () throws -> T) rethrows -> T {
        session.undo.beginUndoGrouping(); defer { session.undo.endUndoGrouping() }; return try body()
    }
    func testLayerNamesActiveLayerBatchVisibilityAndUndo() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let doc = try XCTUnwrap(PDFDocument(url: source)), view = session(doc), c = view.rectangleMarkup
        XCTAssertNil(c.addLayer(named: "   ")); XCTAssertNil(c.addLayer(named: String(repeating: "a", count: 201)))
        let id = try XCTUnwrap(grouped(c) { c.addLayer(named: " Review / 建築 ") })
        XCTAssertEqual(c.layerCatalog.layers.first?.name, "Review / 建築"); XCTAssertNil(c.addLayer(named: "review / 建築"))
        grouped(c) { c.setActiveLayer(id) }
        var annotations: [PDFAnnotation] = []
        for index in 0..<3 {
            let a = try XCTUnwrap(grouped(c) { c.create(on: doc.page(at: index)!, bounds: CGRect(x: 100, y: 100, width: 50, height: 40)) })
            XCTAssertEqual(MarkupLayers.id(a), id); annotations.append(a)
        }
        c.selectFromList(annotations[0]); XCTAssertNotNil(c.selected)
        grouped(c) { c.setLayerVisible(id, false) }
        XCTAssertTrue(annotations.allSatisfy { !$0.shouldDisplay && !$0.shouldPrint }); XCTAssertNil(c.selected)
        XCTAssertEqual(annotations.count, 3); XCTAssertEqual(RectangleMarkupRecord.capture(doc).count, 4)
        c.undo.undo(); XCTAssertTrue(annotations.allSatisfy(\.shouldDisplay)); c.undo.redo(); XCTAssertFalse(annotations[0].shouldDisplay)
        grouped(c) { c.assignLayer(nil, to: annotations) }; XCTAssertTrue(annotations.allSatisfy(\.shouldDisplay))
        c.undo.undo(); XCTAssertTrue(annotations.allSatisfy { MarkupLayers.id($0) == id && !$0.shouldDisplay })
        grouped(c) { c.removeLayer(id) }; XCTAssertTrue(c.layerCatalog.layers.isEmpty)
        XCTAssertTrue(annotations.allSatisfy { MarkupLayers.id($0) == nil && $0.shouldDisplay })
        c.undo.undo(); XCTAssertEqual(c.layerCatalog.layers.count, 1); XCTAssertTrue(annotations.allSatisfy { MarkupLayers.id($0) == id && !$0.shouldDisplay })
        let fresh = try XCTUnwrap(grouped(c) { c.create(on: doc.page(at: 1)!, bounds: CGRect(x: 200, y: 100, width: 40, height: 30)) })
        XCTAssertEqual(MarkupLayers.id(fresh), id); XCTAssertTrue(fresh.shouldDisplay); XCTAssertTrue(c.layerCatalog.layers[0].visible)
        grouped(c) { c.renameLayer(id, to: "Finished") }; XCTAssertEqual(c.layerName(for: fresh), "Finished")
    }
    func testSnapshotsRetainLayersAfterAppearanceChangesAndDocumentIsolation() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let doc = try XCTUnwrap(PDFDocument(url: source)), view = session(doc), c = view.rectangleMarkup
        let id = try XCTUnwrap(grouped(c) { c.addLayer(named: "Captures") }); grouped(c) { c.setActiveLayer(id) }
        let page = doc.page(at: 0)!, points = [CGPoint(x: 80,y:100), CGPoint(x:160,y:100), CGPoint(x:160,y:150), CGPoint(x:80,y:150)]
        let payload = try SnapshotPayload.capture(page: page, points: points)
        let stamp = try XCTUnwrap(grouped(c) { c.pasteSnapshot(payload, on: page, center: CGPoint(x: 250,y:250)) })
        XCTAssertEqual(MarkupLayers.id(stamp), id)
        c.selectFromList(stamp)
        var style = SnapshotStyle.read(stamp); style.opacity = 0.4
        grouped(c) { c.styleSelectedSnapshot(style) }
        let styled = try XCTUnwrap(c.selected)
        XCTAssertEqual(MarkupLayers.id(styled), id); XCTAssertEqual(SnapshotStyle.read(styled).opacity, 0.4)
        grouped(c) { c.setLayerVisible(id, false) }; XCTAssertFalse(styled.shouldDisplay); XCTAssertEqual((styled as? DrawbridgeSnapshotAnnotation)?.isRetired, true)
        grouped(c) { c.setLayerVisible(id, true) }; XCTAssertTrue(styled.shouldDisplay); XCTAssertEqual((styled as? DrawbridgeSnapshotAnnotation)?.isRetired, false)
        let another = try XCTUnwrap(PDFDocument(url: source)); view.document = another; c.bind(to: another)
        XCTAssertTrue(c.layerCatalog.layers.isEmpty)
        view.document = doc; c.bind(to: doc); XCTAssertEqual(c.layerCatalog.layers.first?.id, id)
    }
    func testEmptyLayerAndHiddenMarkupSaveReopenRepeatedSave() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let doc = try XCTUnwrap(PDFDocument(url: source)), view = session(doc), c = view.rectangleMarkup
        let id = try XCTUnwrap(grouped(c) { c.addLayer(named: "Hidden notes") })
        _ = grouped(c) { c.addLayer(named: "Empty layer") }; grouped(c) { c.setActiveLayer(id) }
        let annotation = try XCTUnwrap(grouped(c) { c.create(on: doc.page(at: 2)!, bounds: CGRect(x: 80,y:100,width:80,height:50), kind: .text, text: "Review") })
        grouped(c) { c.setLayerVisible(id, false) }
        let original = try Data(contentsOf: source)
        let output = source.deletingPathExtension().appendingPathExtension("saved.pdf"); defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(doc)))
        XCTAssertTrue(try Data(contentsOf: output).starts(with: original))
        let reopened = try XCTUnwrap(PDFDocument(url: output)); view.document = reopened; c.bind(to: reopened)
        XCTAssertEqual(c.layerCatalog.layers.count, 2); XCTAssertEqual(c.layerCatalog.activeID, id)
        let saved = try XCTUnwrap(reopened.page(at: 2)?.annotations.first { MarkupLayers.id($0) == id })
        XCTAssertFalse(saved.shouldDisplay); XCTAssertFalse(saved.shouldPrint); XCTAssertEqual(saved.contents, annotation.contents)
        XCTAssertNotNil(saved.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/OC")))
        grouped(c) { c.setLayerVisible(id, true) }
        XCTAssertTrue(PDFRectangleWriter.write(document: reopened, source: output, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(reopened)))
        let again = try XCTUnwrap(PDFDocument(url: output)); view.document = again; c.bind(to: again)
        XCTAssertEqual(c.layerCatalog.layers.count, 2); XCTAssertTrue(again.page(at: 2)!.annotations.first { MarkupLayers.id($0) == id }!.shouldDisplay)
        XCTAssertEqual((0..<again.pageCount).flatMap { again.page(at: $0)!.annotations }.filter(MarkupLayers.isMetadata).count, 1)
    }
    func testMarkerSurvivesPageDeletionAndUndo() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let doc = try XCTUnwrap(PDFDocument(url: source)), view = session(doc), c = view.rectangleMarkup
        let id = try XCTUnwrap(grouped(c) { c.addLayer(named: "Keep after page deletion") })
        let removed = doc.page(at: 0)!; doc.removePage(at: 0); c.ensureLayerCatalogMarker()
        XCTAssertEqual(MarkupLayers.catalog(doc).layers.first?.id, id)
        doc.insert(removed, at: 0); c.ensureLayerCatalogMarker()
        XCTAssertEqual(RectangleMarkupRecord.capture(doc).filter { $0.layerCatalog != nil }.count, 1)
    }
    func testForeignOptionalContentPreservedAndMalformedCatalogRejected() throws {
        let model = MarkupLayerCatalog(layers: [MarkupLayer(name: "Review", visible: false)])
        let foreign: [String: Any] = ["/Type": "/OCG", "/Name": "u:Original drawing"]
        var objects: [String: Any] = ["trailer": ["value": ["/Root": "1 0 R"]], "obj:1 0 R": ["value": ["/Type": "/Catalog", "/OCProperties": "3 0 R"]], "obj:2 0 R": ["value": foreign], "obj:3 0 R": ["value": ["/OCGs": ["2 0 R"], "/D": ["/BaseState": "/OFF", "/ON": ["2 0 R"], "/Order": ["2 0 R"], "/Locked": ["2 0 R"]], "/Configs": [["/Name": "u:Alternate", "/ON": ["2 0 R"]]]]]]
        let before = objects; var next = 10
        let refs = try PDFMarkupLayersPatch.install(catalogText: model.json, objects: &objects, next: &next)
        XCTAssertEqual(refs.count, 1); XCTAssertTrue(PDFMarkupLayersPatch.preservesForeignLayers(before: before, after: objects, root: "1 0 R"))
        XCTAssertTrue(NSDictionary(dictionary: objects["obj:2 0 R"] as! [String: Any]).isEqual(to: before["obj:2 0 R"] as! [String: Any]))
        let once = objects; _ = try PDFMarkupLayersPatch.install(catalogText: model.json, objects: &objects, next: &next)
        XCTAssertTrue(PDFMarkupLayersPatch.preservesForeignLayers(before: once, after: objects, root: "1 0 R"))
        var root = (objects["obj:1 0 R"] as! [String: Any])["value"] as! [String: Any]
        var props = root["/OCProperties"] as! [String: Any]; props["/Configs"] = []; root["/OCProperties"] = props; objects["obj:1 0 R"] = ["value": root]
        XCTAssertFalse(PDFMarkupLayersPatch.preservesForeignLayers(before: before, after: objects, root: "1 0 R"))
        XCTAssertThrowsError(try PDFMarkupLayersPatch.install(catalogText: "{}", objects: &objects, next: &next))
        XCTAssertFalse(MarkupLayerCatalog(layers: [MarkupLayer(id: "bad", name: "Bad")]).isValid)
    }
    func testImportedLayerAssignmentSaveUndoAndMetadataPreservation() async throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let setup = try XCTUnwrap(PDFDocument(url: source))
        let external = PDFAnnotation(bounds: CGRect(x: 100,y:100,width:100,height:60), forType: .freeText, withProperties: nil)
        external.contents = "External note"; external.userName = "External reviewer"
        external.setValue("Keep metadata", forAnnotationKey: PDFAnnotationKey(rawValue: "/ExternalPrivateData")); setup.page(at: 1)!.addAnnotation(external); XCTAssertTrue(setup.write(to: source))
        let controller = MainViewController(); _ = controller.view; controller.openDocument(at: source)
        let doc = try XCTUnwrap(controller.pdfView.document), c = controller.pdfView.rectangleMarkup; c.canEdit = {true}; c.undo.groupsByEvent = false
        let a = try XCTUnwrap(doc.page(at: 1)?.annotations.first { $0.type == "FreeText" })
        let id = try XCTUnwrap(grouped(c) { c.addLayer(named: "Consultant") })
        grouped(c) { c.assignLayer(id, to: [a]) }
        func save() async throws -> PDFAnnotation {
            let success = PDFRectangleWriter.write(document: doc, source: source, destination: source, pageLabels: [:], records: RectangleMarkupRecord.capture(doc), importedPlan: c.importedState?.plan(document: doc, stamp: nil), onFailure: { failure in
                FileHandle.standardError.write(Data(("LAYER SAVE FAILURE: " + failure.stage + "\n").utf8))
            })
            XCTAssertTrue(success)
            return try XCTUnwrap(PDFDocument(url: source)?.page(at: 1)?.annotations.first { $0.type == "FreeText" })
        }
        var saved = try await save(); XCTAssertEqual(MarkupLayers.id(saved), id)
        XCTAssertEqual(saved.userName, "External reviewer"); XCTAssertEqual(saved.contents, "External note")
        XCTAssertEqual(saved.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/ExternalPrivateData")) as? String, "Keep metadata")
        grouped(c) { c.setLayerVisible(id, false) }; _ = try await save()
        grouped(c) { c.assignLayer(nil, to: [a]) }; saved = try await save(); XCTAssertNil(MarkupLayers.id(saved)); XCTAssertNil(saved.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/OC")))
        c.undo.undo(); saved = try await save(); XCTAssertEqual(MarkupLayers.id(saved), id)
    }
    func testLockedAndForeignLayerAnnotationsCannotBeReassigned() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let doc = try XCTUnwrap(PDFDocument(url: source)), view = session(doc), c = view.rectangleMarkup
        let annotation = try XCTUnwrap(grouped(c) { c.create(on: doc.page(at: 0)!, bounds: CGRect(x: 100,y:100,width:40,height:30)) })
        annotation.isReadOnly = true; XCTAssertFalse(c.canAssignLayer(annotation))
        annotation.isReadOnly = false
        annotation.setValue(["/Type": "/OCG", "/Name": "Foreign"], forAnnotationKey: PDFAnnotationKey(rawValue: "/OC"))
        XCTAssertFalse(c.canAssignLayer(annotation))
    }
    func testClickAwayClearsSelectionWithRectangleToolStillActive() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let doc = try XCTUnwrap(PDFDocument(url: source)), view = session(doc), c = view.rectangleMarkup
        view.go(to: doc.page(at: 0)!); view.layoutSubtreeIfNeeded(); c.tool = .rectangle
        let annotation = try XCTUnwrap(grouped(c) { c.create(on: doc.page(at: 0)!, bounds: CGRect(x: 100,y:100,width:40,height:30)) })
        XCTAssertTrue(c.selected === annotation)
        XCTAssertTrue(c.pointerDown(at: view.convert(CGPoint(x: 300,y:250), from: doc.page(at: 0)!)))
        XCTAssertNil(c.selected); _ = c.pointerUp(at: view.convert(CGPoint(x: 300,y:250), from: doc.page(at: 0)!))
        XCTAssertEqual(RectangleMarkupRecord.capture(doc).count, 1)
    }
    func testMarkupListContextMenuAllowsDeletingSelectedHiddenMarkup() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let controller = MainViewController(); _ = controller.view; controller.openDocument(at: source)
        let doc = try XCTUnwrap(controller.pdfView.document), c = controller.pdfView.rectangleMarkup
        c.canEdit = { true }; c.undo.groupsByEvent = false
        let id = try XCTUnwrap(grouped(c) { c.addLayer(named: "Review") }); grouped(c) { c.setActiveLayer(id) }
        let annotation = try XCTUnwrap(grouped(c) { c.create(on: doc.page(at: 0)!, bounds: CGRect(x: 100,y:100,width:40,height:30)) })
        grouped(c) { c.setLayerVisible(id, false) }
        controller.performRefreshMarkups(selecting: nil, forceImmediate: true)
        let row = try XCTUnwrap(controller.markupItems.firstIndex { $0.annotation === annotation })
        controller.markupsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let menu = NSMenuItem(title: "Delete Selected Markups", action: #selector(MainViewController.deleteListedMarkups(_:)), keyEquivalent: "")
        XCTAssertTrue(controller.validateMenuItem(menu))
        annotation.isReadOnly = true; XCTAssertFalse(controller.validateMenuItem(menu))
    }
    func testLargeDrawingLayerSaveAndVisibility() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_LAYERS_FIXTURE"] else { throw XCTSkip("Optional architectural set") }
        let source = URL(fileURLWithPath: path), doc = try XCTUnwrap(PDFDocument(url: source)), view = session(doc), c = view.rectangleMarkup
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("LargeLayers-\(UUID().uuidString).pdf"); defer { try? FileManager.default.removeItem(at: output) }
        let id = try XCTUnwrap(grouped(c) { c.addLayer(named: "Review") }); grouped(c) { c.setActiveLayer(id) }
        for index in Set([0, doc.pageCount / 2, doc.pageCount - 1]) {
            _ = grouped(c) { c.create(on: doc.page(at: index)!, bounds: CGRect(x: 100,y:100,width:100,height:50)) }
        }
        grouped(c) { c.setLayerVisible(id, false) }
        XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(doc)))
        let reopened = try XCTUnwrap(PDFDocument(url: output)); view.document = reopened; c.bind(to: reopened)
        XCTAssertEqual(reopened.pageCount, doc.pageCount); XCTAssertEqual(c.layerCatalog.layers.first?.id, id)
        XCTAssertTrue((0..<doc.pageCount).flatMap { reopened.page(at: $0)?.annotations ?? [] }.filter { MarkupLayers.id($0) == id }.allSatisfy { !$0.shouldDisplay })
    }
}
