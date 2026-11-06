import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class ImportedMarkupEditingTests: XCTestCase {
    private func fixture(dashed:Bool=false) throws -> (URL, PDFDocument, PDFPage, MarkupPDFView) {
        _ = NSApplication.shared
        let source=FileManager.default.temporaryDirectory.appendingPathComponent("Imported-edit-\(UUID()).pdf")
        let seed=PDFDocument(), page=PDFPage();page.setBounds(CGRect(x:0,y:0,width:600,height:800),for:.mediaBox);seed.insert(page,at:0)
        let text=PDFAnnotation(bounds:CGRect(x:40,y:350,width:300,height:180),forType:.freeText,withProperties:nil)
        text.contents="Consultant comment";text.font=NSFont(name:"Helvetica-Bold",size:13);text.fontColor = .red;text.color=NSColor(calibratedRed:1,green:1,blue:0.9,alpha:1);text.userName="Consultant"
        let border=PDFBorder();border.lineWidth=1.5;text.border=border
        text.setValue("foreign-id",forAnnotationKey:PDFAnnotationKey(rawValue:"/NM"));text.setValue("retained",forAnnotationKey:PDFAnnotationKey(rawValue:"/VendorPrivate"));page.addAnnotation(text)
        let square=PDFAnnotation(bounds:CGRect(x:50,y:100,width:80,height:60),forType:.square,withProperties:nil);square.color = .blue;square.interiorColor = .yellow;page.addAnnotation(square)
        XCTAssertTrue(seed.write(to:source))
        let helper=try XCTUnwrap(PDFTKBookmarkWriter.executableURL())
        let json=source.appendingPathExtension("json"), seeded=source.appendingPathExtension("seed.pdf")
        defer{try? FileManager.default.removeItem(at:json);try? FileManager.default.removeItem(at:seeded)}
        XCTAssertTrue(PDFTKBookmarkWriter.run(helper,arguments:["--json=2","--json-stream-data=inline","--decode-level=all",source.path,json.path]))
        var graph=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:json)) as? [String:Any])
        var tables=graph["qpdf"] as! [[String:Any]]
        for (key,entry) in tables[1] { if var object=entry as? [String:Any],var value=object["value"] as? [String:Any],value["/Subtype"] as? String == "/FreeText" {value["/NM"]="u:foreign-id"
            if dashed {value["/BS"]=["/S":"/D","/W":1.5,"/D":[4,2]]}
            if dashed,let ap=value["/AP"] as? [String:Any],let ref=ap["/N"] as? String,var form=tables[1]["obj:"+ref] as? [String:Any],var stream=form["stream"] as? [String:Any],let encoded=stream["data"] as? String,let data=Data(base64Encoded:encoded) {
                var bytes=Data("[4 2] 0 d\n".utf8);bytes.append(data);stream["data"]=bytes.base64EncodedString();form["stream"]=stream;tables[1]["obj:"+ref]=form
                value["/BS"]=["/S":"/D","/W":1.5,"/D":[4,2]]
            }
            object["value"]=value;tables[1][key]=object} }
        graph=["qpdf":tables];try JSONSerialization.data(withJSONObject:graph,options:[.withoutEscapingSlashes]).write(to:json)
        let process=Process();process.executableURL=helper;process.arguments=[source.path,"--update-from-json="+json.path,seeded.path]
        let errors=Pipe();process.standardError=errors;process.standardOutput=FileHandle.nullDevice
        try process.run();process.waitUntilExit()
        let diagnostic=String(data:errors.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
        XCTAssertTrue([0,3].contains(process.terminationStatus),diagnostic)
        try FileManager.default.removeItem(at:source);try FileManager.default.moveItem(at:seeded,to:source)
        let document=try XCTUnwrap(PDFDocument(url:source)), reopened=try XCTUnwrap(document.page(at:0))
        let view=MarkupPDFView(frame:CGRect(x:0,y:0,width:800,height:900));view.setMarkupDocument(document);view.rectangleMarkup.bind(to:document);view.rectangleMarkup.canEdit={true};view.rectangleMarkup.undo.groupsByEvent=false
        addTeardownBlock{try? FileManager.default.removeItem(at:source)}
        return(source,document,reopened,view)
    }
    func testImportedTextEditUndoRedoAndPropertiesAreAvailable() throws {
        let (_,_,page,view)=try fixture(), s=view.rectangleMarkup
        let text=try XCTUnwrap(page.annotations.first{$0.type=="FreeText"});s.selectFromList(text)
        s.undo.beginUndoGrouping();s.editSelectedText("Edited consultant comment",size:17);s.undo.endUndoGrouping()
        XCTAssertEqual(s.selected?.contents,"Edited consultant comment")
        XCTAssertFalse(RectangleMarkupRecord.owns(text));XCTAssertEqual(text.userName,"Consultant")
        XCTAssertEqual(s.selected?.font?.pointSize,17)
        s.undo.undo();XCTAssertTrue(s.selected === text);XCTAssertEqual(text.contents,"Consultant comment")
        s.undo.redo();XCTAssertEqual(s.selected?.contents,"Edited consultant comment")
        let inspector=MarkupPropertiesViewController();inspector.session=s;inspector.loadViewIfNeeded();inspector.refresh()
        XCTAssertTrue(inspector.fontSize.isEnabled);XCTAssertTrue(inspector.stroke.isEnabled)
    }
    func testImportedTextAndShapeAppearanceSaveReopenTwice() throws {
        let(source,document,page,view)=try fixture(), s=view.rectangleMarkup
        let text=try XCTUnwrap(page.annotations.first{$0.type=="FreeText"}), square=try XCTUnwrap(page.annotations.first{$0.type=="Square"})
        s.undo.beginUndoGrouping()
        s.selectFromList(text);s.editSelectedText("Saved imported edit",size:15)
        s.selectFromList(square);s.styleSelected(color:.green,width:4);s.fillSelected(.cyan)
        s.undo.endUndoGrouping()
        let output=source.deletingPathExtension().appendingPathExtension("edited.pdf");defer{try? FileManager.default.removeItem(at:output)}
        for _ in 0..<2 {
            XCTAssertTrue(PDFRectangleWriter.write(document:document,source:FileManager.default.fileExists(atPath:output.path) ? output:source,destination:output,pageLabels:[:],records:RectangleMarkupRecord.capture(document),importedPlan:s.importedPlan()))
            let saved=try XCTUnwrap(PDFDocument(url:output)), p=try XCTUnwrap(saved.page(at:0))
            XCTAssertEqual(p.annotations.count,2)
            let t=try XCTUnwrap(p.annotations.first{$0.type=="FreeText"})
            XCTAssertEqual(t.contents,"Saved imported edit");XCTAssertEqual(t.userName,"Consultant")
            XCTAssertEqual(t.value(forAnnotationKey:PDFAnnotationKey(rawValue:"/NM")) as? String,"foreign-id")
            XCTAssertEqual(t.value(forAnnotationKey:PDFAnnotationKey(rawValue:"/VendorPrivate")) as? String,"retained")
            XCTAssertEqual(t.font?.pointSize ?? 0,15,accuracy:0.1)
            let box=try XCTUnwrap(p.annotations.first{$0.type=="Square"});XCTAssertEqual(box.border?.lineWidth ?? 0,4,accuracy:0.1)
            XCTAssertLessThan(box.color.usingColorSpace(.deviceRGB)!.redComponent,0.1)
            XCTAssertGreaterThan(box.interiorColor!.usingColorSpace(.deviceRGB)!.blueComponent,0.8)
        }
    }
    func testReadOnlyImportedTextRemainsProtected() throws {
        let(_,_,page,view)=try fixture(),s=view.rectangleMarkup
        let text=try XCTUnwrap(page.annotations.first{$0.type=="FreeText"});text.isReadOnly=true
        s.selectFromList(text);s.editSelectedText("Forbidden",size:17)
        XCTAssertEqual(text.contents,"Consultant comment")
    }
    func testInlineForeignTextEditorCommitsAndCancelKeepsOriginal() throws {
        let(_,_,page,view)=try fixture(),s=view.rectangleMarkup
        s.undo.groupsByEvent=true
        let text=try XCTUnwrap(page.annotations.first{$0.type=="FreeText"})
        s.beginTextEditing(on:page,bounds:text.bounds,annotation:text)
        let editor=try XCTUnwrap(view.subviews.compactMap{$0 as? NSTextView}.first)
        editor.insertText(" Updated",replacementRange:NSRange(location:editor.string.utf16.count,length:0))
        s.finishTextEditing()
        let changed=try XCTUnwrap(s.selected)
        XCTAssertEqual(changed.contents,"Consultant comment Updated");XCTAssertEqual(page.annotations.count,2)
        s.beginTextEditing(on:page,bounds:changed.bounds,annotation:changed)
        let next=try XCTUnwrap(view.subviews.compactMap{$0 as? NSTextView}.first)
        next.string="Cancel me";s.finishTextEditing(cancel:true)
        XCTAssertTrue(page.annotations.contains{$0===changed});XCTAssertEqual(changed.contents,"Consultant comment Updated")
    }
    func testImportedLocksMoveDeleteAndNativeAppearanceValues() throws {
        let(_,_,page,view)=try fixture(),s=view.rectangleMarkup
        let text=try XCTUnwrap(page.annotations.first{$0.type=="FreeText"})
        s.undo.beginUndoGrouping();let layer=try XCTUnwrap(s.addLayer(named:"Consultant"));s.assignLayer(layer,to:[text]);s.setLayerLocked(layer,true);s.undo.endUndoGrouping()
        s.selected=text;s.editSelectedText("Forbidden",size:15);XCTAssertEqual(text.contents,"Consultant comment")
        s.undo.beginUndoGrouping();s.setLayerLocked(layer,false);s.selectFromList(text);s.editSelectedText("Editable again",size:13);s.undo.endUndoGrouping()
        let edited=try XCTUnwrap(s.selected),old=edited.bounds
        s.undo.beginUndoGrouping();s.setBounds(old.offsetBy(dx:20,dy:30),of:edited,on:page,action:"Move");s.undo.endUndoGrouping()
        XCTAssertEqual(edited.bounds.minX,old.minX+20)
        s.deleteSelected();XCTAssertFalse(page.annotations.contains{$0===edited})
        s.undo.undo();XCTAssertTrue(page.annotations.contains{$0===edited})
        s.undo.undo();XCTAssertEqual(edited.bounds,old)
        let square=try XCTUnwrap(page.annotations.first{$0.type=="Square"});s.selectFromList(square)
        s.undo.beginUndoGrouping();s.setLineAppearance(pattern:.dashDot,opacity:0.5);s.undo.endUndoGrouping()
        XCTAssertEqual(MarkupStyle.pattern(try XCTUnwrap(s.selected)),.dashDot)
        XCTAssertEqual(MarkupStyle.strokeOpacity(try XCTUnwrap(s.selected)),0.5)
    }

    func testDashedForeignTextBorderSurvivesEditing() throws {
        let(_,_,page,view)=try fixture(dashed:true),s=view.rectangleMarkup
        let text=try XCTUnwrap(page.annotations.first{$0.type=="FreeText"})
        let solid=PDFAnnotation(bounds:text.bounds,forType:.freeText,withProperties:nil)
        solid.setValue(["/S":"/S","/D":[4,2]],forAnnotationKey:PDFAnnotationKey(rawValue:"/BS"))
        XCTAssertEqual(ImportedTextBorder.standardDash(solid),[])
        let expected:[CGFloat]=[4,2]
        XCTAssertEqual(ImportedTextBorder.standardDash(text),expected)
        s.selectFromList(text);s.undo.beginUndoGrouping();s.editSelectedText("Dashed comment",size:13);s.undo.endUndoGrouping()
        let after=try XCTUnwrap(ImportedTextContent.appearance(try XCTUnwrap(s.selected)))
        XCTAssertEqual(try XCTUnwrap(ImportedTextBorder.read(after)).dash,expected)
    }
    func testEditedCalloutLeaderMovesWithBox() throws {
        let(_,_,page,view)=try fixture(),s=view.rectangleMarkup
        let text=try XCTUnwrap(page.annotations.first{$0.type=="FreeText"})
        text.setValue([40,350,80,400],forAnnotationKey:PDFAnnotationKey(rawValue:"/CL"))
        s.selectFromList(text);s.undo.beginUndoGrouping();s.editSelectedText("Moved callout",size:13);s.undo.endUndoGrouping()
        let edited=try XCTUnwrap(s.selected as? ImportedTextAnnotation),before=try XCTUnwrap(ImportedTextContent.appearance(edited))
        let origin=edited.calloutOrigin
        s.undo.beginUndoGrouping();s.setBounds(edited.bounds.offsetBy(dx:50,dy:60),of:edited,on:page,action:"Move");s.undo.endUndoGrouping()
        XCTAssertEqual(edited.calloutOrigin,origin)
        let after=try XCTUnwrap(ImportedTextContent.appearance(edited))
        XCTAssertEqual(PDFDocument(data:before)?.string,PDFDocument(data:after)?.string)
        func pixels(_ data:Data)throws->[UInt8] {
            let provider=try XCTUnwrap(CGDataProvider(data:data as CFData)),pdf=try XCTUnwrap(CGPDFDocument(provider)),page=try XCTUnwrap(pdf.page(at:1))
            var bytes=[UInt8](repeating:255,count:600*360*4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context=try XCTUnwrap(CGContext(data:buffer.baseAddress,width:600,height:360,bitsPerComponent:8,bytesPerRow:600*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                context.scaleBy(x:2,y:2);context.drawPDFPage(page)
            }
            return bytes
        }
        let aPixels=try pixels(before),bPixels=try pixels(after)
        XCTAssertLessThan(zip(aPixels,bPixels).filter{$0 != $1}.count,40,"Moving the callout must preserve its annotation-local pixels, including leader")
        // The annotation-local appearance must be translation invariant.
        let a=try XCTUnwrap(PDFDocument(data:before)?.page(at:0)),b=try XCTUnwrap(PDFDocument(data:after)?.page(at:0))
        XCTAssertEqual(a.selection(for:NSRange(location:0,length:1))?.bounds(for:a),b.selection(for:NSRange(location:0,length:1))?.bounds(for:b))
    }

    func testRichEditorZoomDoesNotChangeSavedFontSize() throws {
        let(_,_,page,view)=try fixture(),s=view.rectangleMarkup
        s.undo.groupsByEvent=true;view.autoScales=false;view.scaleFactor=1
        let text=try XCTUnwrap(page.annotations.first{$0.type=="FreeText"})
        s.beginTextEditing(on:page,bounds:text.bounds,annotation:text)
        let editor=try XCTUnwrap(view.subviews.compactMap{$0 as? NSTextView}.first)
        editor.insertText(" Updated",replacementRange:NSRange(location:editor.string.utf16.count,length:0))
        view.scaleFactor=2
        s.finishTextEditing()
        let rich=try XCTUnwrap((s.selected as? ImportedTextAnnotation)?.richText)
        XCTAssertEqual((rich.attribute(.font,at:0,effectiveRange:nil) as? NSFont)?.pointSize ?? 0,13,accuracy:0.01)
    }
    func testInlineEditorUsesRotatedAsymmetricTextBoxAndOriginalFontInsets() throws {
        let(_,_,page,view)=try fixture(),s=view.rectangleMarkup
        s.undo.groupsByEvent=true;view.autoScales=false;view.scaleFactor=1
        let text=try XCTUnwrap(page.annotations.first{$0.type=="FreeText"})
        text.setValue([60,20,5,10],forAnnotationKey:PDFAnnotationKey(rawValue:"/RD"))
        for rotation in [0,90,180,270] {
            text.setValue(rotation,forAnnotationKey:PDFAnnotationKey(rawValue:"/Rotate"))
            s.beginTextEditing(on:page,bounds:text.bounds,annotation:text)
            let editor=try XCTUnwrap(view.subviews.compactMap{$0 as? NSTextView}.first)
            XCTAssertEqual(editor.textContainerInset,.zero)
            let expected=rotation%180==0 ? CGSize(width:235,height:150):CGSize(width:150,height:235)
            XCTAssertEqual(editor.bounds.width,expected.width,accuracy:0.01);XCTAssertEqual(editor.bounds.height,expected.height,accuracy:0.01)
            let transform=ImportedTextContent.rotationTransform(rotation,size:text.bounds.size)
            let a=CGPoint.zero.applying(transform),b=CGPoint(x:1,y:0).applying(transform)
            let expectedA=view.convert(CGPoint(x:text.bounds.minX+a.x,y:text.bounds.minY+a.y),from:page)
            let expectedB=view.convert(CGPoint(x:text.bounds.minX+b.x,y:text.bounds.minY+b.y),from:page)
            let actualA=editor.convert(CGPoint.zero,to:view),actualB=editor.convert(CGPoint(x:1,y:0),to:view)
            let actual=CGPoint(x:actualB.x-actualA.x,y:actualB.y-actualA.y),expectedDirection=CGPoint(x:expectedB.x-expectedA.x,y:expectedB.y-expectedA.y)
            let dot=(actual.x*expectedDirection.x+actual.y*expectedDirection.y)/(hypot(actual.x,actual.y)*hypot(expectedDirection.x,expectedDirection.y))
            XCTAssertEqual(dot,1,accuracy:0.001)
            s.finishTextEditing(cancel:true)
        }
        text.removeValue(forAnnotationKey:PDFAnnotationKey(rawValue:"/RD"));text.setValue(0,forAnnotationKey:PDFAnnotationKey(rawValue:"/Rotate"))
        let original=ImportedTextContent.insets(text,rich:ImportedTextContent.read(text),rotation:0)
        s.selectFromList(text);s.undo.beginUndoGrouping();s.editSelectedText(text.contents!,size:22);s.undo.endUndoGrouping()
        let edited=try XCTUnwrap(s.selected as? ImportedTextAnnotation)
        XCTAssertEqual(edited.textInsets.top,original.top,accuracy:0.01)
    }

    func testAlignmentInsetsRotationAndFillOpacityPersist() throws {
        let(source,document,page,view)=try fixture(),s=view.rectangleMarkup
        let text=try XCTUnwrap(page.annotations.first{$0.type=="FreeText"})
        for rotation in [0,90,180,270] {
            for alignment in [NSTextAlignment.left,.center,.right] {
                let seed=text.copy() as! PDFAnnotation;seed.alignment=alignment
                seed.setValue(rotation,forAnnotationKey:PDFAnnotationKey(rawValue:"/Rotate"))
                seed.setValue([10,20,30,40],forAnnotationKey:PDFAnnotationKey(rawValue:"/RD"))
                let rich=ImportedTextContent.read(seed),copy=ImportedTextAnnotation(source:seed,richText:rich)
                XCTAssertEqual((rich.attribute(.paragraphStyle,at:0,effectiveRange:nil) as? NSParagraphStyle)?.alignment,alignment)
                XCTAssertEqual(copy.textRotation,rotation)
                let physical=ImportedTextContent.textBox(seed).offsetBy(dx:-seed.bounds.minX,dy:-seed.bounds.minY)
                let logical=physical.applying(ImportedTextContent.rotationTransform(rotation,size:seed.bounds.size).inverted())
                XCTAssertEqual(copy.textInsets.left,logical.minX,accuracy:0.001)
                let appearance=try XCTUnwrap(ImportedTextContent.appearance(copy))
                let rendered=try XCTUnwrap(PDFDocument(data:appearance))
                XCTAssertEqual(rendered.string?.components(separatedBy:.whitespacesAndNewlines).filter{!$0.isEmpty}.joined(separator:" "),seed.contents)
                if let dir=ProcessInfo.processInfo.environment["DRAWBRIDGE_IMPORTED_EDIT_OUTPUT"] {try appearance.write(to:URL(fileURLWithPath:dir).appendingPathComponent("layout-\(rotation)-\(alignment.rawValue).pdf"))}
            }
        }
        let square=try XCTUnwrap(page.annotations.first{$0.type=="Square"});s.selectFromList(square)
        s.undo.beginUndoGrouping();s.fillSelected(NSColor.cyan.withAlphaComponent(0.5));s.setLineAppearance(pattern:.dashDot,opacity:0.5);s.undo.endUndoGrouping()
        let output=source.appendingPathExtension("opacity.pdf");defer{try? FileManager.default.removeItem(at:output)}
        XCTAssertTrue(PDFRectangleWriter.write(document:document,source:source,destination:output,pageLabels:[:],records:RectangleMarkupRecord.capture(document),importedPlan:s.importedPlan()))
        let saved=try XCTUnwrap(PDFDocument(url:output)),box=try XCTUnwrap(saved.page(at:0)?.annotations.first{$0.type=="Square"})
        XCTAssertEqual(MarkupStyle.fillOpacity(box),0.5);XCTAssertEqual(MarkupStyle.strokeOpacity(box),0.5)
        XCTAssertEqual(MarkupStyle.pattern(box),.dashDot)
    }

    func testLocalCalloutPreservesBoldAuthorPeersAndRepeatedSave() throws {
        guard let path=ProcessInfo.processInfo.environment["DRAWBRIDGE_IMPORTED_EDIT_FIXTURE"] else{throw XCTSkip("Optional local imported callout PDF")}
        let original=try Data(contentsOf:URL(fileURLWithPath:path))
        let source=FileManager.default.temporaryDirectory.appendingPathComponent("Foreign-callouts-\(UUID()).pdf")
        try original.write(to:source);defer{try? FileManager.default.removeItem(at:source)}
        let document=try XCTUnwrap(PDFDocument(url:source)),page=try XCTUnwrap(document.page(at:0))
        let view=MarkupPDFView();view.setMarkupDocument(document);let s=view.rectangleMarkup;s.bind(to:document);s.canEdit={true};s.undo.groupsByEvent=false
        let text=try XCTUnwrap(page.annotations.first{$0.type=="FreeText" && !RectangleMarkupRecord.owns($0)})
        let before=ImportedTextContent.read(text), count=page.annotations.count,contents=text.contents ?? "",author=text.userName
        XCTAssertTrue((before.attribute(.font,at:0,effectiveRange:nil) as? NSFont).map{NSFontManager.shared.traits(of:$0).contains(.boldFontMask)} == true)
        if let dir=ProcessInfo.processInfo.environment["DRAWBRIDGE_IMPORTED_EDIT_OUTPUT"],let data=ImportedTextContent.appearance(text){try data.write(to:URL(fileURLWithPath:dir).appendingPathComponent("before-callout.pdf"))}
        s.selectFromList(text);s.undo.beginUndoGrouping();s.editSelectedText(contents+" Reviewed.",size:text.font?.pointSize ?? 13);s.undo.endUndoGrouping()
        let edited=try XCTUnwrap(s.selected)
        let appearance=try XCTUnwrap(ImportedTextContent.appearance(edited))
        let border=try XCTUnwrap((edited as? ImportedTextAnnotation)?.originalBorder)
        let rgb=try XCTUnwrap(border.color.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(rgb.redComponent,0.6);XCTAssertLessThan(rgb.blueComponent,0.2)
        if let dir=ProcessInfo.processInfo.environment["DRAWBRIDGE_IMPORTED_EDIT_OUTPUT"],let data=ImportedTextContent.appearance(edited){try data.write(to:URL(fileURLWithPath:dir).appendingPathComponent("after-callout.pdf"))}
        for _ in 0..<2 {
            XCTAssertTrue(PDFRectangleWriter.write(document:document,source:source,destination:source,pageLabels:[:],records:RectangleMarkupRecord.capture(document),importedPlan:s.importedPlan()))
            let saved=try XCTUnwrap(PDFDocument(url:source)),p=try XCTUnwrap(saved.page(at:0))
            XCTAssertEqual(p.annotations.count,count);XCTAssertEqual(p.string,page.string)
            let restored=try XCTUnwrap(p.annotations.first{$0.contents==contents+" Reviewed."})
            XCTAssertEqual(restored.userName,author)
            XCTAssertEqual(restored.bounds.minX,edited.bounds.minX,accuracy:0.000001);XCTAssertEqual(restored.bounds.minY,edited.bounds.minY,accuracy:0.000001);XCTAssertEqual(restored.bounds.size,edited.bounds.size)
            if let dir=ProcessInfo.processInfo.environment["DRAWBRIDGE_IMPORTED_EDIT_OUTPUT"],let data=ImportedTextContent.appearance(restored){try data.write(to:URL(fileURLWithPath:dir).appendingPathComponent("saved-callout.pdf"))}
            let rich=ImportedTextContent.read(restored)
            XCTAssertTrue((rich.attribute(.font,at:0,effectiveRange:nil) as? NSFont).map{NSFontManager.shared.traits(of:$0).contains(.boldFontMask)} == true)
        }
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:path)),original)
    }
}
