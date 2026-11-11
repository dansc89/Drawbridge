import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class PageManagementTests: XCTestCase {
    func fixture(_ directory: URL, name: String, widths: [Int]) throws -> URL {
        let document = PDFDocument()
        for (index, width) in widths.enumerated() {
            let page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: width, height: 500), for: .mediaBox)
            let note = PDFAnnotation(bounds: CGRect(x: 20, y: 40, width: 100, height: 30), forType: .freeText, withProperties: nil)
            note.contents = "\(name)-\(index)"; note.font = .systemFont(ofSize: 12); page.addAnnotation(note)
            let link = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 30, height: 20), forType: .link, withProperties: nil)
            link.action = PDFActionURL(url: URL(string: "https://example.com/\(name)/\(index)")!); page.addAnnotation(link)
            document.insert(page, at: index)
        }
        let root = PDFOutline(), child = PDFOutline(); child.label = name
        child.destination = PDFDestination(page: document.page(at: widths.count - 1)!, at: .zero); root.insertChild(child, at: 0); document.outlineRoot = root
        let url = directory.appendingPathComponent(name + ".pdf"); XCTAssertTrue(document.write(to: url)); return url
    }
    func setup() throws -> (URL, URL, MainViewController) {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PageManagementTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = try fixture(dir, name: "original", widths: [300,310,320,330,340])
        let c = MainViewController(); _ = c.view; c.openDocument(at: url)
        c.pdfView.rectangleMarkup.canEdit = { true }
        c.pdfView.rectangleMarkup.undo.groupsByEvent = false
        return (dir,url,c)
    }
    func widths(_ d: PDFDocument) -> [Int] { (0..<d.pageCount).map { Int(d.page(at:$0)!.bounds(for:.mediaBox).width) } }
    func grouped(_ c: MainViewController, _ operation: () throws -> Void) rethrows {
        let undo = c.pdfView.rectangleMarkup.undo; undo.beginUndoGrouping(); defer { undo.endUndoGrouping() }; try operation()
    }
    func testReorderKeepsStableSelectedOrderIdentityLabelsAndUndo() throws {
        let (dir,url,c) = try setup(); defer { try? FileManager.default.removeItem(at:dir) }
        let bytes = try Data(contentsOf:url), d = try XCTUnwrap(c.pdfView.document)
        let pages = (0..<d.pageCount).map { d.page(at:$0)! }; c.pageLabelOverrides = [1:"B",3:"D"]
        try grouped(c) { XCTAssertTrue(try c.reorderPages(at:IndexSet([1,3]),to:5)) }
        XCTAssertEqual(widths(d),[300,320,340,310,330]); XCTAssertTrue(d.page(at:3) === pages[1]); XCTAssertTrue(d.page(at:4) === pages[3])
        XCTAssertEqual(c.displayPageLabel(forPageIndex:3),"B"); XCTAssertEqual(c.displayPageLabel(forPageIndex:4),"D")
        XCTAssertEqual(c.pagesTableView.selectedRowIndexes,IndexSet([3,4]))
        XCTAssertTrue(d.outlineRoot?.child(at:0)?.destination?.page === pages[4])
        c.pdfView.rectangleMarkup.undo.undo(); XCTAssertEqual(widths(d),[300,310,320,330,340])
        c.pdfView.rectangleMarkup.undo.redo(); XCTAssertEqual(widths(d),[300,320,340,310,330])
        XCTAssertEqual(try Data(contentsOf:url),bytes)
    }
    func testInsertionUsesSelectedSourceOrderIndependentPagesAndUndo() throws {
        let (dir,url,c) = try setup(); defer { try? FileManager.default.removeItem(at:dir) }
        let foreign = try fixture(dir,name:"foreign",widths:[610,620,630]), bytes = try Data(contentsOf:foreign)
        let d = try XCTUnwrap(c.pdfView.document), original = d.page(at:0)
        try grouped(c) { XCTAssertTrue(try c.insertPages(from:foreign,indexes:[2,0],at:1)) }
        XCTAssertEqual(widths(d),[300,610,630,310,320,330,340])
        XCTAssertTrue(d.page(at:0) === original); XCTAssertEqual(d.page(at:1)?.annotations.first {$0.type == "FreeText"}?.contents,"foreign-0")
        XCTAssertNotNil((d.page(at:2)?.annotations.first {$0.type == "Link"}?.action as? PDFActionURL)?.url)
        XCTAssertNotNil(c.pageStructureState?.plan(for:d))
        c.pdfView.rectangleMarkup.undo.undo(); XCTAssertEqual(widths(d),[300,310,320,330,340])
        c.pdfView.rectangleMarkup.undo.redo(); XCTAssertEqual(widths(d),[300,610,630,310,320,330,340])
        XCTAssertEqual(try Data(contentsOf:foreign),bytes); XCTAssertTrue(FileManager.default.fileExists(atPath:url.path))
    }
    func testInsertReorderSaveUndoRedoUsesFrozenForeignAnnotationsAndLabels() async throws {
        let (dir,url,c) = try setup(); defer { try? FileManager.default.removeItem(at:dir) }
        let foreign = try fixture(dir,name:"foreign",widths:[610,620,630])
        let d = try XCTUnwrap(c.pdfView.document)
        c.pageLabelOverrides = [1:"ORIGINAL B"]
        try grouped(c) { XCTAssertTrue(try c.insertPages(from:foreign,indexes:[0,2],at:1)) }
        let plan = try XCTUnwrap(c.pageStructureState?.plan(for:d))
        XCTAssertEqual(plan.pageSources.map(\.index),[0,0,2,1,2,3,4])
        XCTAssertNotEqual(plan.pageSources[1].source,foreign)
        try Data("replaced externally".utf8).write(to:foreign)
        try grouped(c) { XCTAssertTrue(try c.reorderPages(at:IndexSet([1,2]),to:d.pageCount)) }
        let imported = try XCTUnwrap(d.page(at:5)?.annotations.first { $0.type == "FreeText" })
        let movedBounds = imported.bounds.offsetBy(dx:17,dy:9)
        imported.bounds = movedBounds
        c.pdfView.rectangleMarkup.importedState?.touch(imported)
        c.markMarkupChanged()
        func save() async -> Bool {
            await withCheckedContinuation { continuation in
                c.persistDocument(to:url,adoptAsPrimaryDocument:false,busyMessage:"Test save",showBusyOverlay:false) { continuation.resume(returning:$0) }
            }
        }
        let saved = await save(); XCTAssertTrue(saved)
        var reopened = try XCTUnwrap(PDFDocument(url:url))
        XCTAssertEqual(widths(reopened),[300,310,320,330,340,610,630])
        XCTAssertEqual(reopened.page(at:5)?.annotations.first {$0.type == "FreeText"}?.contents,"foreign-0")
        XCTAssertEqual(reopened.page(at:5)?.annotations.first {$0.type == "FreeText"}?.bounds,movedBounds)
        XCTAssertNotNil((reopened.page(at:6)?.annotations.first {$0.type == "Link"}?.action as? PDFActionURL)?.url)
        XCTAssertEqual(c.displayPageLabel(forPageIndex:1),"ORIGINAL B")
        XCTAssertEqual(reopened.page(at:1)?.label,"ORIGINAL B")
        c.pdfView.rectangleMarkup.undo.undo()
        let undone = await save(); XCTAssertTrue(undone)
        reopened = try XCTUnwrap(PDFDocument(url:url)); XCTAssertEqual(widths(reopened),[300,610,630,310,320,330,340])
        c.pdfView.rectangleMarkup.undo.undo()
        let removed = await save(); XCTAssertTrue(removed)
        XCTAssertEqual(PDFDocument(url:url)?.pageCount,5)
        c.pdfView.rectangleMarkup.undo.redo()
        let redone = await save(); XCTAssertTrue(redone)
        XCTAssertEqual(PDFDocument(url:url)?.pageCount,7)
    }

    func testInsertionUsesPreviewWhenExternalSourceIsReplacedBeforeInsert() async throws {
        let (dir,url,c) = try setup(); defer { try? FileManager.default.removeItem(at:dir) }
        let foreign = try fixture(dir,name:"foreign",widths:[610,620,630])
        let preview = try XCTUnwrap(MainViewController.InsertionSource(url:foreign))
        XCTAssertEqual(widths(preview.document),[610,620,630])
        let replacement = try fixture(dir,name:"replacement",widths:[710,720,730])
        try Data(contentsOf:replacement).write(to:foreign,options:.atomic)
        try grouped(c) { XCTAssertTrue(try c.insertPages(from:preview,indexes:[0,2],at:1)) }
        XCTAssertEqual(widths(try XCTUnwrap(c.pdfView.document)),[300,610,630,310,320,330,340])
        let saved = await withCheckedContinuation { continuation in
            c.persistDocument(to:url,adoptAsPrimaryDocument:false,busyMessage:"Test save",showBusyOverlay:false) { continuation.resume(returning:$0) }
        }
        XCTAssertTrue(saved)
        let reopened = try XCTUnwrap(PDFDocument(url:url))
        XCTAssertEqual(widths(reopened),[300,610,630,310,320,330,340])
        XCTAssertEqual(reopened.page(at:1)?.annotations.first {$0.type == "FreeText"}?.contents,"foreign-0")
        XCTAssertEqual(reopened.page(at:2)?.annotations.first {$0.type == "FreeText"}?.contents,"foreign-2")
    }

    func testOriginalImportedMoveAfterReorderSaveUndoSavePreservesExactBounds() async throws {
        let (dir,url,c) = try setup(); defer { try? FileManager.default.removeItem(at:dir) }
        let d = try XCTUnwrap(c.pdfView.document)
        let note = try XCTUnwrap(d.page(at:1)?.annotations.first {$0.type == "FreeText"})
        func save() async -> Bool {
            await withCheckedContinuation { continuation in
                c.persistDocument(to:url,adoptAsPrimaryDocument:false,busyMessage:"Test save",showBusyOverlay:false) { continuation.resume(returning:$0) }
            }
        }
        try grouped(c) { XCTAssertTrue(try c.reorderPages(at:IndexSet([1,3]),to:5)) }
        let reordered = await save(); XCTAssertTrue(reordered)
        c.pdfView.rectangleMarkup.undo.undo()
        let restored = await save(); XCTAssertTrue(restored)
        XCTAssertEqual(widths(try XCTUnwrap(PDFDocument(url:url))),[300,310,320,330,340])
        let movedBounds = note.bounds.offsetBy(dx:27,dy:19)
        note.bounds = movedBounds
        c.pdfView.rectangleMarkup.importedState?.touch(note); c.markMarkupChanged()
        let moved = await save(); XCTAssertTrue(moved)
        let reopened = try XCTUnwrap(PDFDocument(url:url))
        XCTAssertEqual(widths(reopened),[300,310,320,330,340])
        let savedNote = try XCTUnwrap(reopened.page(at:1)?.annotations.first {$0.type == "FreeText"})
        XCTAssertEqual(savedNote.contents,"original-1")
        XCTAssertEqual(savedNote.bounds,movedBounds)
    }

    func layeredSource(_ dir: URL, id: String, foreign: Bool, readOnly: Bool = false) throws -> URL {
        let input = try fixture(dir, name: "layer-input", widths: [610,620,630])
        let d = try XCTUnwrap(PDFDocument(url: input))
        let view = MarkupPDFView(frame: .zero); view.document = d
        let s = view.rectangleMarkup; s.canEdit = { true }; s.bind(to: d)
        let layer = MarkupLayer(id: id, name: "Review", visible: false, locked: true)
        s.layerState?.catalog = .init(layers: [layer]); s.ensureLayerCatalogMarker()
        let a = try XCTUnwrap(s.create(on: d.page(at: 2)!, bounds: CGRect(x: 130,y: 140,width: 60,height: 40)))
        a.setValue(id, forAnnotationKey: MarkupLayers.membershipKey)
        if foreign {
            let note = try XCTUnwrap(d.page(at: 2)?.annotations.first { $0.type == "FreeText" })
            note.setValue(id, forAnnotationKey: MarkupLayers.membershipKey); s.importedState?.touch(note)
        }
        let output = dir.appendingPathComponent("layer-source.pdf")
        XCTAssertTrue(PDFRectangleWriter.write(document: d, source: input, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(d), importedPlan: s.importedState?.plan(document: d, stamp: nil)))
        if readOnly {
            let executable = try XCTUnwrap(PDFTKBookmarkWriter.executableURL()), jsonURL = dir.appendingPathComponent("readonly.json")
            XCTAssertTrue(PDFTKBookmarkWriter.run(executable, arguments:["--json=2","--json-stream-data=none","--decode-level=none",output.path,jsonURL.path]))
            let baseline = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:jsonURL)) as? [String:Any])
            var updated = baseline, tables = try XCTUnwrap(baseline["qpdf"] as? [[String:Any]])
            for (key, raw) in tables[1] {
                guard var object = raw as? [String:Any], var value = object["value"] as? [String:Any],
                      value["/Subtype"] as? String == "/FreeText", value["/DrawbridgeLayerID"] != nil else { continue }
                value["/F"] = ((value["/F"] as? Int) ?? 0) | 64
                object["value"] = value; tables[1][key] = object
            }
            updated["qpdf"] = tables
            let patched = dir.appendingPathComponent("readonly.pdf")
            _ = try PDFIncrementalMarkupPatch.append(original:Data(contentsOf:output),baseline:baseline,updated:updated,snapshot:output,to:patched)
            return patched
        }
        return output
    }

    func testInsertionRejectsMissingOrMismatchedForeignLayerOCAtomically() throws {
        for missing in [true, false] {
            let (dir, url, c) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
            let s = c.pdfView.rectangleMarkup, id = UUID().uuidString
            grouped(c) { s.setLayerCatalog(.init(layers: [MarkupLayer(id: id, name: "Review")]), action: "Setup") }
            s.undo.removeAllActions()
            let source = try layeredSource(dir, id: id, foreign: true, readOnly: true)
            let executable = try XCTUnwrap(PDFTKBookmarkWriter.executableURL())
            let json = dir.appendingPathComponent("invalid-oc.json")
            XCTAssertTrue(PDFTKBookmarkWriter.run(executable, arguments: ["--json=2", "--json-stream-data=none", "--decode-level=none", source.path, json.path]))
            let baseline = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
            var updated = baseline, tables = try XCTUnwrap(baseline["qpdf"] as? [[String: Any]])
            var changed = 0
            for (key, raw) in tables[1] {
                guard var object = raw as? [String: Any], var value = object["value"] as? [String: Any] else { continue }
                if missing && value["/Subtype"] as? String == "/FreeText" && value["/DrawbridgeLayerID"] != nil {
                    XCTAssertNotNil(value.removeValue(forKey: "/OC")); changed += 1
                } else if !missing && value["/Type"] as? String == "/OCG" && value["/DrawbridgeLayerID"] as? String == "u:" + id {
                    value["/DrawbridgeLayerID"] = "u:" + UUID().uuidString; changed += 1
                } else { continue }
                object["value"] = value; tables[1][key] = object
            }
            XCTAssertEqual(changed, 1)
            updated["qpdf"] = tables
            let malformed = dir.appendingPathComponent("invalid-oc.pdf")
            _ = try PDFIncrementalMarkupPatch.append(original: Data(contentsOf: source), baseline: baseline, updated: updated, snapshot: source, to: malformed)
            let preview = try XCTUnwrap(MainViewController.InsertionSource(url: malformed))
            let sourceBytes = try Data(contentsOf: malformed), destinationBytes = try Data(contentsOf: url)
            let d = try XCTUnwrap(c.pdfView.document), before = c.pageManagementSnapshot(d)
            let labelOverrides = c.pageLabelOverrides
            XCTAssertNil(c.pageStructureState)
            // Replace the external file: validation must inspect the retained frozen preview.
            try Data("externally replaced".utf8).write(to: malformed)
            XCTAssertThrowsError(try c.insertPages(from: preview, indexes: [2], at: 1))
            XCTAssertEqual((0..<d.pageCount).compactMap(d.page(at:)).map(ObjectIdentifier.init), before.pages.map(ObjectIdentifier.init))
            XCTAssertEqual(s.layerCatalog, before.layers)
            XCTAssertEqual(c.pageLabelOverrides, labelOverrides)
            XCTAssertEqual(c.pagesTableView.selectedRowIndexes, IndexSet(before.selected.compactMap { page in before.pages.firstIndex { $0 === page } }))
            XCTAssertNil(c.pageStructureState)
            XCTAssertFalse(s.undo.canUndo); XCTAssertFalse(s.undo.canRedo)
            XCTAssertEqual(try Data(contentsOf: url), destinationBytes)
            XCTAssertEqual(try Data(contentsOf: preview.url), sourceBytes)
        }
    }

    func testInsertedLayerCatalogSaveUndoRedoAndCollision() async throws {
        for (collision, readOnly, includeMarker) in [(false,false,false),(true,false,false),(true,true,false),(true,true,true)] {
            let (dir,url,c) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
            c.saveErrorPresenter = { _ in .alertFirstButtonReturn }
            let s = c.pdfView.rectangleMarkup, id = UUID().uuidString
            if collision { grouped(c) { s.setLayerCatalog(.init(layers: [MarkupLayer(id:id,name:"Review")], activeID:id), action:"Setup") } }
            s.undo.beginUndoGrouping()
            let destinationMarkup = try XCTUnwrap(s.create(on:c.pdfView.document!.page(at:0)!,bounds:CGRect(x:150,y:160,width:40,height:30)))
            s.undo.endUndoGrouping()
            let before = s.layerCatalog
            s.undo.removeAllActions()
            let source = try layeredSource(dir, id:id, foreign:collision,readOnly:readOnly), bytes = try Data(contentsOf:source)
            var sourceReadOnlyFlags: Int?
            if readOnly {
                let sourceDocument = try XCTUnwrap(PDFDocument(url: source))
                let sourceNote = try XCTUnwrap(sourceDocument.page(at: 2)?.annotations.first { $0.type == "FreeText" })
                let flags = try XCTUnwrap(sourceNote.value(forAnnotationKey: .flags) as? NSNumber).intValue
                // PDFKit's isReadOnly getter does not reflect /F bit 64 for this FreeText fixture.
                XCTAssertNotEqual(flags & 64, 0)
                sourceReadOnlyFlags = flags
            }
            let indexes = includeMarker ? [0,2] : [2], insertedIndex = includeMarker ? 2 : 1
            try grouped(c) { XCTAssertTrue(try c.insertPages(from:source,indexes:indexes,at:1)) }
            let d = try XCTUnwrap(c.pdfView.document), page = try XCTUnwrap(d.page(at:insertedIndex))
            let owned = try XCTUnwrap(page.annotations.first { RectangleMarkupRecord.owns($0) && !MarkupLayers.isMetadata($0) })
            let target = try XCTUnwrap(MarkupLayers.id(owned))
            XCTAssertEqual(target == id, !collision)
            XCTAssertEqual(s.layerCatalog.layers.count, before.layers.count + 1)
            XCTAssertEqual(s.layerCatalog.activeID, before.activeID)
            XCTAssertTrue(s.layerIsVisible(destinationMarkup)); XCTAssertFalse(s.layerIsLocked(destinationMarkup))
            XCTAssertEqual(MarkupLayers.id(destinationMarkup),collision ? id : nil)
            XCTAssertEqual(s.layerCatalog.layers.first { $0.id == target }?.name,collision ? "Review (2)" : "Review")
            XCTAssertFalse(s.layerIsVisible(owned)); XCTAssertTrue(s.layerIsLocked(owned))
            func saveAndCheck(_ inserted: Bool) async throws {
                let ok = await withCheckedContinuation { continuation in
                    c.persistDocument(to:url,adoptAsPrimaryDocument:false,busyMessage:"Test",showBusyOverlay:false) { continuation.resume(returning:$0) }
                }
                XCTAssertTrue(ok); guard ok else { return }
                let reopened = try XCTUnwrap(PDFDocument(url:url))
                XCTAssertEqual(MarkupLayers.catalog(reopened), inserted ? s.layerCatalog : before)
                XCTAssertEqual(reopened.pageCount, inserted ? 5 + indexes.count : 5)
                if inserted {
                    let members = reopened.page(at:insertedIndex)!.annotations.filter { MarkupLayers.id($0) != nil }
                    XCTAssertEqual(members.count, collision ? 2 : 1)
                    XCTAssertTrue(members.allSatisfy { MarkupLayers.id($0) == target })
                    XCTAssertEqual(members.first { RectangleMarkupRecord.owns($0) }?.bounds, owned.bounds)
                    if collision { XCTAssertEqual(members.first { !RectangleMarkupRecord.owns($0) }?.contents,"layer-input-2") }
                    if let expectedFlags = sourceReadOnlyFlags {
                        let note = try XCTUnwrap(members.first { !RectangleMarkupRecord.owns($0) })
                        let flags = try XCTUnwrap(note.value(forAnnotationKey: .flags) as? NSNumber).intValue
                        XCTAssertEqual(flags, expectedFlags)
                        XCTAssertNotEqual(flags & 64, 0)
                    }
                    let v = MarkupPDFView(frame:.zero); v.document = reopened; v.rectangleMarkup.bind(to:reopened)
                    XCTAssertTrue(members.allSatisfy { !v.rectangleMarkup.layerIsVisible($0) && v.rectangleMarkup.layerIsLocked($0) })
                    if collision {
                        let originalMember = try XCTUnwrap(reopened.page(at:0)?.annotations.first { MarkupLayers.id($0) == id })
                        XCTAssertTrue(v.rectangleMarkup.layerIsVisible(originalMember)); XCTAssertFalse(v.rectangleMarkup.layerIsLocked(originalMember))
                    }
                }
            }
            try await saveAndCheck(true); try await saveAndCheck(true)
            s.undo.undo(); XCTAssertEqual(s.layerCatalog,before); try await saveAndCheck(false)
            s.undo.redo(); XCTAssertTrue(d.page(at:insertedIndex) === page); XCTAssertEqual(MarkupLayers.id(owned),target)
            try await saveAndCheck(true)
            XCTAssertEqual(try Data(contentsOf:source),bytes)
        }
    }

    func testRealSidebarDragWriterPreservesBulkSelectionAndMenuGate() throws {
        let (dir,_,c) = try setup(); defer { try? FileManager.default.removeItem(at:dir) }
        let table = c.pagesTableView
        XCTAssertTrue(table.dataSource === c)
        XCTAssertTrue(table.registeredDraggedTypes.contains(PageThumbnailTableView.pageDragType))
        XCTAssertTrue(table.menu?.items.contains { $0.action == #selector(MainViewController.commandInsertPages(_:)) } == true)
        let menu = NSMenuItem(title:"Insert Pages",action:#selector(MainViewController.commandInsertPages(_:)),keyEquivalent:"")
        XCTAssertTrue(c.validateMenuItem(menu))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        table.selectRowIndexes([1,3],byExtendingSelection:false)
        table.mouseDownSelection = [1,3]
        XCTAssertTrue(c.tableView(table,writeRowsWith:IndexSet(integer:1),to:board))
        XCTAssertEqual(table.draggedIndexes,IndexSet([1,3]))
        XCTAssertEqual(table.selectedRowIndexes,IndexSet([1,3]))
        XCTAssertEqual(board.string(forType:PageThumbnailTableView.pageDragType),table.dragToken)
        XCTAssertEqual(table.draggedPageIdentities.count,5)
        c.isPDFFileProcessingOperation = true
        XCTAssertFalse(c.validateMenuItem(menu))
        XCTAssertFalse(c.tableView(table,writeRowsWith:IndexSet(integer:1),to:board))
        c.isPDFFileProcessingOperation = false
    }

    func testInvalidBusyPermissionAndNoOpRejectWithoutUndo() throws {
        let (dir,_,c) = try setup(); defer { try? FileManager.default.removeItem(at:dir) }
        let d = try XCTUnwrap(c.pdfView.document), foreign = try fixture(dir,name:"foreign",widths:[610])
        XCTAssertFalse(try c.reorderPages(at:IndexSet([1,2]),to:2))
        XCTAssertFalse(try c.reorderPages(at:IndexSet([7]),to:0))
        XCTAssertFalse(try c.reorderPages(at:IndexSet([1]),to:9))
        XCTAssertFalse(try c.insertPages(from:foreign,indexes:[4],at:0))
        c.isPDFFileProcessingOperation = true; XCTAssertFalse(try c.reorderPages(at:IndexSet([1]),to:0)); XCTAssertFalse(try c.insertPages(from:foreign,indexes:[0],at:0)); c.isPDFFileProcessingOperation = false
        c.pdfView.rectangleMarkup.canEdit = { false }; XCTAssertFalse(try c.reorderPages(at:IndexSet([1]),to:0)); XCTAssertFalse(try c.insertPages(from:foreign,indexes:[0],at:0))
        XCTAssertEqual(widths(d),[300,310,320,330,340]); XCTAssertFalse(c.pdfView.rectangleMarkup.undo.canUndo)
    }
    func testFileAndSidebarExposeInsertAndRealDragDatasource() throws {
        let (dir,_,c) = try setup(); defer { try? FileManager.default.removeItem(at:dir) }
        let old = NSApp.mainMenu; defer { NSApp.mainMenu = old }
        AppDelegate().setupMainMenu(controller:c)
        let file = try XCTUnwrap(NSApp.mainMenu?.items.first {$0.title == "File"}?.submenu)
        XCTAssertTrue(file.items.contains {$0.title == "Insert Pages…" && $0.target as? MainViewController === c})
        XCTAssertTrue(c.pagesTableView.menu?.items.contains {$0.title == "Insert Pages…"} == true)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        c.pagesTableView.selectRowIndexes(IndexSet([1,3]),byExtendingSelection:false)
        XCTAssertTrue((c as NSTableViewDataSource).tableView?(c.pagesTableView,writeRowsWith:IndexSet([1,3]),to:board) ?? false)
        XCTAssertEqual(c.pagesTableView.selectedRowIndexes,IndexSet([1,3]))
    }
}
