import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor private final class PageMarkupShortcutWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor final class SelectAllPageMarkupsTests: XCTestCase {
    func testCommandAThenBackspaceDeletesOnlyCurrentPageEditableMarkupsAndUndoesAsBatch() throws {
        _ = NSApplication.shared
        let controller = MainViewController()
        let window = PageMarkupShortcutWindow(contentRect:CGRect(x:0,y:0,width:1400,height:800),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentViewController = controller
        let document = PDFDocument(), page = PDFPage(), other = PDFPage()
        for (index,item) in [page,other].enumerated() { item.setBounds(CGRect(x:0,y:0,width:600,height:400),for:.mediaBox); document.insert(item,at:index) }
        controller.pdfView.setMarkupDocument(document)
        let session = controller.pdfView.rectangleMarkup; session.canEdit = { true }
        func square(on page: PDFPage, owned: Bool = true) -> PDFAnnotation {
            let annotation = PDFAnnotation(bounds:CGRect(x:50,y:50,width:60,height:40),forType:.square,withProperties:nil)
            if owned { annotation.setValue(RectangleMarkupRecord.prefix+UUID().uuidString,forAnnotationKey:RectangleMarkupRecord.identityKey) }
            page.addAnnotation(annotation); return annotation
        }
        let own = square(on:page), imported = square(on:page,owned:false)
        let protected = square(on:page); protected.isReadOnly = true
        let hidden = square(on:page); hidden.shouldDisplay = false
        let otherMarkup = square(on:other)
        let link = PDFAnnotation(bounds:CGRect(x:10,y:10,width:20,height:20),forType:.link,withProperties:nil); page.addAnnotation(link)
        controller.pdfView.go(to:page)
        window.makeFirstResponder(controller.pdfView)
        session.undo.removeAllActions()
        func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code))
        }
        XCTAssertNil(controller.routeKeyDownEvent(try key("a",code:0,flags:.command)))
        XCTAssertEqual(Set(session.selectedItems.map(ObjectIdentifier.init)),Set([own,imported].map(ObjectIdentifier.init)))
        XCTAssertTrue(window.firstResponder === controller.pdfView)
        var refreshes = 0
        controller.pdfView.annotationRefreshObserver = { _,_,_,_ in refreshes += 1 }
        XCTAssertNil(controller.routeKeyDownEvent(try key("\u{7f}",code:51)))
        XCTAssertNil(own.page); XCTAssertNil(imported.page)
        XCTAssertTrue(protected.page === page); XCTAssertTrue(hidden.page === page); XCTAssertTrue(link.page === page)
        XCTAssertTrue(otherMarkup.page === other)
        XCTAssertEqual(refreshes,1,"Batch deletion must not rerender a dense page once per markup")
        session.undo.undo()
        XCTAssertTrue(own.page === page); XCTAssertTrue(imported.page === page)
        XCTAssertTrue(otherMarkup.page === other)
        session.undo.redo()
        XCTAssertNil(own.page); XCTAssertNil(imported.page)
    }

    func testSelectAllKeepsNormalTextEditing() throws {
        _ = NSApplication.shared
        let controller = MainViewController()
        let window = PageMarkupShortcutWindow(contentRect:CGRect(x:0,y:0,width:1400,height:800),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentViewController = controller
        let text = NSTextView(frame:CGRect(x:20,y:20,width:200,height:50)); text.string = "Markup note"
        controller.view.addSubview(text); window.makeFirstResponder(text)
        controller.commandSelectAll(nil)
        XCTAssertEqual(text.selectedRange(),NSRange(location:0,length:text.string.utf16.count))
        XCTAssertTrue(controller.pdfView.rectangleMarkup.selectedItems.isEmpty)
    }
}
