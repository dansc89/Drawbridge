import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class TextEditorVisibilityTests:XCTestCase {
    private final class RecordingView:PDFView {
        var invalidated:[PDFPage]=[]
        override func annotationsChanged(on page:PDFPage) {invalidated.append(page);super.annotationsChanged(on:page)}
    }
    private func fixture()->(PDFPage,RectangleMarkupController,RecordingView) {
        _=NSApplication.shared
        let doc=PDFDocument(),page=PDFPage();page.setBounds(CGRect(x:0,y:0,width:600,height:400),for:.mediaBox);doc.insert(page,at:0)
        let view=RecordingView(frame:CGRect(x:0,y:0,width:800,height:600));view.document=doc
        let session=RectangleMarkupController();session.install(on:view);session.bind(to:doc);session.canEdit={true}
        return(page,session,view)
    }
    func testEnteringAndCancellingEditingInvalidatesOriginalWithoutDirtyingPDF() throws {
        let(page,s,view)=fixture()
        let text=try XCTUnwrap(s.create(on:page,bounds:CGRect(x:60,y:120,width:120,height:60),kind:.text,text:"Original"))
        let saved=FileManager.default.temporaryDirectory.appendingPathComponent("TextVisibility-\(UUID()).pdf");defer{try? FileManager.default.removeItem(at:saved)}
        XCTAssertTrue(view.document!.write(to:saved));s.markSaved(at:saved);view.invalidated=[]
        s.beginTextEditing(on:page,bounds:text.bounds,annotation:text)
        XCTAssertFalse(text.shouldDisplay);XCTAssertFalse(s.hasUnsavedChanges)
        XCTAssertTrue(view.invalidated.contains{$0===page},"PDFKit cached original must be invalidated before editor appears")
        view.invalidated=[];s.finishTextEditing(cancel:true)
        XCTAssertTrue(text.shouldDisplay);XCTAssertEqual(text.contents,"Original");XCTAssertFalse(s.hasUnsavedChanges)
        XCTAssertTrue(view.invalidated.contains{$0===page},"Cancel must restore page rendering even without a mutation")
    }
    func testLayerRefreshCannotRevealTextUnderEditorAndCancellationRespectsHiddenLayer() throws {
        let(page,s,view)=fixture();defer{withExtendedLifetime(view){}}
        let layer=try XCTUnwrap(s.addLayer(named:"Notes"))
        let text=try XCTUnwrap(s.create(on:page,bounds:CGRect(x:60,y:120,width:120,height:60),kind:.text,text:"Original"))
        s.assignLayer(layer,to:[text]);s.beginTextEditing(on:page,bounds:text.bounds,annotation:text)
        s.applyLayerVisibility();XCTAssertFalse(text.shouldDisplay,"Layer refresh must not double paint the original")
        s.setLayerVisible(layer,false);s.finishTextEditing(cancel:true)
        XCTAssertFalse(text.shouldDisplay,"Finishing an edit must not reveal a hidden layer");XCTAssertFalse(text.shouldPrint)
        s.setLayerVisible(layer,true);XCTAssertTrue(text.shouldDisplay)
    }
    func testCancelRestoresOriginallyHiddenAnnotation() throws {
        let(page,s,view)=fixture();defer{withExtendedLifetime(view){}}
        let text=try XCTUnwrap(s.create(on:page,bounds:CGRect(x:60,y:120,width:120,height:60),kind:.text,text:"Hidden"))
        text.shouldDisplay=false;s.beginTextEditing(on:page,bounds:text.bounds,annotation:text);s.finishTextEditing(cancel:true)
        XCTAssertFalse(text.shouldDisplay)
    }
    func testImportedCommitSurvivesLayerHiddenDuringEditing() throws {
        let(page,_,view)=fixture();defer{withExtendedLifetime(view){}}
        let text=PDFAnnotation(bounds:CGRect(x:60,y:120,width:120,height:60),forType:.freeText,withProperties:nil)
        text.contents="Original";text.font=NSFont.systemFont(ofSize:12);text.fontColor = .red;page.addAnnotation(text)
        let s=RectangleMarkupController();s.install(on:view);s.bind(to:view.document);s.canEdit={true}
        let layer=try XCTUnwrap(s.addLayer(named:"Review"))
        s.assignLayer(layer,to:[text]);s.beginTextEditing(on:page,bounds:text.bounds,annotation:text)
        let editor=try XCTUnwrap(view.subviews.compactMap{$0 as? NSTextView}.first)
        editor.string="Updated";s.setLayerVisible(layer,false);s.finishTextEditing()
        let updated=try XCTUnwrap(page.annotations.first{$0.contents=="Updated"})
        XCTAssertFalse(updated.shouldDisplay);XCTAssertFalse(updated.shouldPrint)
        s.setLayerVisible(layer,true);XCTAssertTrue(updated.shouldDisplay);XCTAssertTrue(updated.shouldPrint)
    }
}
