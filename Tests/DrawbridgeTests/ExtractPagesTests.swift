import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class ExtractPagesTests: XCTestCase {
    func directory() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("ExtractTests-\(UUID())")
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url
    }
    func fixture(_ dir:URL) throws -> URL {
        let doc=PDFDocument()
        for i in 0..<5 {
            let p=PDFPage();p.setBounds(CGRect(x:0,y:0,width:400+i*10,height:500+i*20),for:.mediaBox);p.rotation=(i%4)*90
            let text=PDFAnnotation(bounds:CGRect(x:30,y:50,width:130,height:40),forType:.freeText,withProperties:nil)
            text.contents="Sheet \(i+1)";text.font = .systemFont(ofSize:12);text.fontColor = .red
            if [1,3].contains(i) { p.addAnnotation(text) }
            let link=PDFAnnotation(bounds:CGRect(x:10,y:10,width:20,height:20),forType:.link,withProperties:nil)
            link.action=PDFActionURL(url:URL(string:"https://example.com")!);p.addAnnotation(link)
            doc.insert(p,at:i)
        }
        let url=dir.appendingPathComponent("source.pdf");XCTAssertTrue(doc.write(to:url));return url
    }
    func testExtractionWithoutFirstPageRetainsLayerCatalog() throws {
        let dir=try directory();defer { try? FileManager.default.removeItem(at:dir) }
        let source=try fixture(dir),doc=try XCTUnwrap(PDFDocument(url:source))
        var layer=MarkupLayer(name:"Review");layer.visible=false;layer.locked=true
        let catalog=MarkupLayerCatalog(layers:[layer],activeID:layer.id)
        let marker=PDFAnnotation(bounds:CGRect(x:0,y:0,width:2,height:2),forType:.square,withProperties:nil)
        marker.shouldDisplay=false;marker.shouldPrint=false;marker.isReadOnly=true
        marker.userName=RectangleMarkupRecord.prefix+UUID().uuidString
        marker.setValue(marker.userName!,forAnnotationKey:RectangleMarkupRecord.identityKey)
        marker.setValue(catalog.json,forAnnotationKey:MarkupLayers.catalogKey);doc.page(at:0)?.addAnnotation(marker)
        let markup=try XCTUnwrap(doc.page(at:1)?.annotations.first {$0.type == "FreeText"})
        markup.setValue(layer.id,forAnnotationKey:MarkupLayers.membershipKey)
        XCTAssertTrue(doc.write(to:source));let before=try Data(contentsOf:source)
        for indices in [[1,3],[0,1]] {
            let out=dir.appendingPathComponent("layers-\(indices[0]).pdf")
            try PDFPageExtractor.extract(source:source,destination:out,indices:indices)
            let saved=try XCTUnwrap(PDFDocument(url:out))
            XCTAssertEqual(MarkupLayers.catalog(saved),catalog)
            let annotations=(0..<saved.pageCount).flatMap {saved.page(at:$0)?.annotations ?? []}
            XCTAssertEqual(annotations.filter(MarkupLayers.isMetadata).count,1)
            XCTAssertEqual(RectangleMarkupRecord.capture(saved).compactMap(\.layerCatalog).count,1)
            XCTAssertEqual(annotations.first {$0.type == "FreeText"}.flatMap(MarkupLayers.id),layer.id)
            XCTAssertEqual(try Data(contentsOf:source),before)
        }
    }
    func testRangeAndScopeValidationAndDefaults() throws {
        let form=ExtractPagesForm(pageCount:40,currentPage:4,selectedPages:[],selectedMarkups:[],allMarkups:[1,3])
        XCTAssertEqual(form.scope.indexOfSelectedItem,0);XCTAssertEqual(form.indices,[4])
        form.range.stringValue="1-20, 20, 25, 30-35";XCTAssertEqual(form.indices,Array(0..<20)+[24]+Array(29..<35))
        for bad in ["", "0", "41", "20-1", "1,,2", "-1", "1-99999999999"] { form.range.stringValue=bad;XCTAssertNil(form.indices,bad) }
        form.scope.selectItem(at:3);form.update();XCTAssertEqual(form.indices,[1,3]);XCTAssertFalse(form.range.isEnabled)
        let selected=ExtractPagesForm(pageCount:40,currentPage:0,selectedPages:[2,4],selectedMarkups:[1,3],allMarkups:[1,3,8])
        XCTAssertEqual(selected.scope.indexOfSelectedItem,2);XCTAssertEqual(selected.indices,[1,3])
        selected.scope.selectItem(at:1);XCTAssertEqual(selected.indices,[2,4])
    }
    func testExtractionPreservesPagesAnnotationsAndOriginal() throws {
        let dir=try directory();defer { try? FileManager.default.removeItem(at:dir) }
        let source=try fixture(dir),before=try Data(contentsOf:source),out=dir.appendingPathComponent("out.pdf")
        try PDFPageExtractor.extract(source:source,destination:out,indices:[3,1,3])
        let original=try XCTUnwrap(PDFDocument(url:source)),extracted=try XCTUnwrap(PDFDocument(url:out))
        XCTAssertEqual(extracted.pageCount,2)
        for (i,index) in [1,3].enumerated() {
            let a=try XCTUnwrap(original.page(at:index)),b=try XCTUnwrap(extracted.page(at:i))
            XCTAssertEqual(a.bounds(for:.mediaBox),b.bounds(for:.mediaBox));XCTAssertEqual(a.rotation,b.rotation)
            XCTAssertEqual(b.annotations.count,2);XCTAssertEqual(b.annotations.first {$0.type == "FreeText"}?.contents,"Sheet \(index+1)")
            XCTAssertNotNil((b.annotations.first {$0.type == "Link"}?.action as? PDFActionURL)?.url)
        }
        XCTAssertEqual(try Data(contentsOf:source),before)
        let outputBefore=try Data(contentsOf:out)
        for bad in [[],[-1],[5]] { XCTAssertThrowsError(try PDFPageExtractor.extract(source:source,destination:out,indices:bad));XCTAssertEqual(try Data(contentsOf:out),outputBefore) }
        XCTAssertThrowsError(try PDFPageExtractor.extract(source:source,destination:source,indices:[1]))
        let hardlink=dir.appendingPathComponent("alias.pdf");try FileManager.default.linkItem(at:source,to:hardlink)
        XCTAssertThrowsError(try PDFPageExtractor.extract(source:source,destination:hardlink,indices:[1]))
        XCTAssertEqual(try Data(contentsOf:source),before)
    }
    func testControllerDetectsSelectedMarkupsDeduplicatesAndExcludesHelpers() throws {
        _ = NSApplication.shared
        let dir=try directory();defer { try? FileManager.default.removeItem(at:dir) }
        let source=try fixture(dir),controller=MainViewController();_ = controller.view;controller.openDocument(at:source)
        let doc=try XCTUnwrap(controller.pdfView.document),page=try XCTUnwrap(doc.page(at:1)),text=try XCTUnwrap(page.annotations.first {$0.type == "FreeText"})
        let helper=PDFAnnotation(bounds:.zero,forType:.square,withProperties:nil);helper.userName="AutoCAD SHX Text";doc.page(at:0)?.addAnnotation(helper)
        controller.pdfView.rectangleMarkup.selectFromList(text)
        let form=controller.extractionForm(for:doc)
        XCTAssertEqual(form.selectedMarkups,[1]);XCTAssertEqual(form.allMarkups,[1,3]);XCTAssertEqual(form.indices,[1])
        let item=NSMenuItem(title:"Extract Pages…",action:#selector(MainViewController.commandExtractPages(_:)),keyEquivalent:"")
        XCTAssertTrue(controller.validateMenuItem(item));controller.isPDFFileProcessingOperation=true;XCTAssertFalse(controller.validateMenuItem(item))
        controller.isPDFFileProcessingOperation=false
        let previous=NSApp.mainMenu;defer { NSApp.mainMenu=previous }
        let delegate=AppDelegate();delegate.setupMainMenu(controller:controller)
        let file=try XCTUnwrap(NSApp.mainMenu?.items.first {$0.title == "File"}?.submenu)
        let extract=try XCTUnwrap(file.items.first {$0.title == "Extract Pages…"})
        XCTAssertEqual(file.index(of:extract),2)
        XCTAssertEqual(extract.action,#selector(MainViewController.commandExtractPages(_:)))
        XCTAssertTrue(extract.target as? MainViewController === controller)

    }
    func testCurrentUnsavedMarkupExportDoesNotSaveOrCleanOriginal() async throws {
        _ = NSApplication.shared
        let dir=try directory();defer { try? FileManager.default.removeItem(at:dir) }
        let source=try fixture(dir),before=try Data(contentsOf:source),out=dir.appendingPathComponent("edited.pdf")
        let controller=MainViewController();_ = controller.view;controller.openDocument(at:source)
        let doc=try XCTUnwrap(controller.pdfView.document),page=try XCTUnwrap(doc.page(at:0))
        let a=PDFAnnotation(bounds:CGRect(x:100,y:100,width:80,height:40),forType:.square,withProperties:nil)
        a.color = .blue;a.setValue(RectangleMarkupRecord.prefix+UUID().uuidString,forAnnotationKey:RectangleMarkupRecord.identityKey);page.addAnnotation(a)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1400,height:900),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentViewController=controller
        defer { window.contentViewController=nil }
        window.isDocumentEdited=true
        controller.markupChangeVersion += 1;let dirty=controller.hasUnsavedChanges()
        let done=expectation(description:"Extract current edits")
        controller.startPageExtraction(document:doc,indices:[0],destination:out) { ok in XCTAssertTrue(ok);done.fulfill() }
        await fulfillment(of:[done],timeout:40)
        XCTAssertEqual(try Data(contentsOf:source),before);XCTAssertTrue(dirty);XCTAssertTrue(controller.hasUnsavedChanges())
        XCTAssertTrue(controller.pdfView.document === doc);XCTAssertTrue(page.annotations.contains {$0 === a})
        let saved=try XCTUnwrap(PDFDocument(url:out));XCTAssertEqual(saved.pageCount,1);XCTAssertEqual(saved.page(at:0)?.annotations.filter {$0.type == "Square"}.count,1)
    }
    func testCurrentPageDeletionIsReflectedInExtractedCopy() async throws {
        _ = NSApplication.shared
        let dir=try directory();defer { try? FileManager.default.removeItem(at:dir) }
        let source=try fixture(dir),before=try Data(contentsOf:source),out=dir.appendingPathComponent("deleted-pages.pdf")
        let c=MainViewController();_ = c.view;c.openDocument(at:source)
        let doc=try XCTUnwrap(c.pdfView.document);try c.deletePages(at:IndexSet(integer:0))
        let done=expectation(description:"Extract reordered current pages")
        c.startPageExtraction(document:doc,indices:[0],destination:out) { ok in XCTAssertTrue(ok);done.fulfill() }
        await fulfillment(of:[done],timeout:40)
        XCTAssertEqual(doc.pageCount,4);XCTAssertEqual(try Data(contentsOf:source),before)
        let extracted=try XCTUnwrap(PDFDocument(url:out));XCTAssertEqual(extracted.pageCount,1)
        XCTAssertEqual(extracted.page(at:0)?.annotations.first {$0.type == "FreeText"}?.contents,"Sheet 2")
    }
    func testMarkupListSelectionUsesDistinctPagesAndRejectsForeignAnnotations() throws {
        _ = NSApplication.shared
        let dir=try directory();defer { try? FileManager.default.removeItem(at:dir) }
        let source=try fixture(dir),c=MainViewController();_ = c.view;c.openDocument(at:source)
        let doc=try XCTUnwrap(c.pdfView.document)
        let a=try XCTUnwrap(doc.page(at:1)?.annotations.first {$0.type == "FreeText"}),b=try XCTUnwrap(doc.page(at:3)?.annotations.first {$0.type == "FreeText"})
        c.markupItems=[MarkupItem(pageIndex:1,annotation:a),MarkupItem(pageIndex:3,annotation:b),MarkupItem(pageIndex:1,annotation:a)]
        let foreignDoc=PDFDocument(),foreignPage=PDFPage(),foreign=PDFAnnotation(bounds:.zero,forType:.freeText,withProperties:nil)
        foreignPage.addAnnotation(foreign);foreignDoc.insert(foreignPage,at:0)
        c.markupItems.append(MarkupItem(pageIndex:0,annotation:foreign))
        c.isMarkupsPanelVisible=true;c.markupsTable.reloadData();c.markupsTable.selectRowIndexes(IndexSet(integersIn:0..<4),byExtendingSelection:false)
        let form=c.extractionForm(for:doc);XCTAssertEqual(form.indices,[1,3]);XCTAssertEqual(form.scope.indexOfSelectedItem,2)
    }
    func testArchitecturalCorpusExtraction() throws {
        guard let path=ProcessInfo.processInfo.environment["DRAWBRIDGE_EXTRACT_CORPUS"],let output=ProcessInfo.processInfo.environment["DRAWBRIDGE_EXTRACT_OUTPUT"] else { throw XCTSkip("Set extraction corpus paths") }
        let source=URL(fileURLWithPath:path),out=URL(fileURLWithPath:output),before=try Data(contentsOf:source)
        let doc=try XCTUnwrap(PDFDocument(url:source))
        let indices=(0..<doc.pageCount).filter { doc.page(at:$0)?.annotations.contains(where:MarkupListPresentation.includes) == true }
        XCTAssertGreaterThan(indices.count,1)
        try PDFPageExtractor.extract(source:source,destination:out,indices:indices)
        let extracted=try XCTUnwrap(PDFDocument(url:out));XCTAssertEqual(extracted.pageCount,indices.count)
        for (i,old) in indices.enumerated() {
            let a=try XCTUnwrap(doc.page(at:old)),b=try XCTUnwrap(extracted.page(at:i))
            XCTAssertEqual(a.rotation,b.rotation);XCTAssertEqual(a.bounds(for:.mediaBox),b.bounds(for:.mediaBox));XCTAssertEqual(a.annotations.count,b.annotations.count)
            XCTAssertEqual(a.annotations.filter(MarkupListPresentation.includes).map(\.contents),b.annotations.filter(MarkupListPresentation.includes).map(\.contents))
        }
        XCTAssertEqual(try Data(contentsOf:source),before)
        print("EXTRACT_CORPUS pages=\(doc.pageCount) selected=\(indices.map {$0+1})")
    }
    func testExtractedDrawbridgeFlattenRecoveryStillWorks() throws {
        let dir=try directory();defer { try? FileManager.default.removeItem(at:dir) }
        let source=try fixture(dir),out=dir.appendingPathComponent("flattened-selection.pdf")
        _ = try PDFAnnotationFlattener.flatten(source:source,destination:source)
        try PDFPageExtractor.extract(source:source,destination:out,indices:[3])
        let doc=try XCTUnwrap(PDFDocument(url:out));XCTAssertEqual(doc.pageCount,1);XCTAssertTrue(PDFAnnotationFlattener.canUnflatten(doc))
        let result=try PDFAnnotationFlattener.unflatten(source:out);XCTAssertEqual(result.restoredAnnotations,1)
        XCTAssertEqual(PDFDocument(url:out)?.page(at:0)?.annotations.first {$0.type == "FreeText"}?.contents,"Sheet 4")
    }
}
