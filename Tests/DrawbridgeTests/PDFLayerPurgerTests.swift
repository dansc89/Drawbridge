import XCTest
import CryptoKit
import PDFKit
@testable import Drawbridge

final class PDFLayerPurgerTests: XCTestCase {
    @MainActor private static func views(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { views($0) }
    }
    func fixture(_ dir: URL, layered: Bool = true, contentStreams: [String]? = nil) throws -> URL {
        let content = contentStreams?.first ?? (layered ? "/OC /L BDC q 1 0 0 rg 10 10 50 50 re f /Span BMC /OC /M BDC BT /F1 12 Tf 10 80 Td (Hidden /OC BDC EMC) Tj ET EMC EMC Q EMC /X Do" : "q 10 10 50 50 re f Q /X Do")
        let form = "/OC /L BDC 0 0 1 rg 60 60 20 20 re f EMC"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 10 0 R /OCProperties << /OCGs [5 0 R] /D << /OFF [5 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /CropBox [5 5 195 195] /Resources << /Properties << /L 5 0 R /M 6 0 R >> /Font << /F1 9 0 R >> /XObject << /X 8 0 R >> >> /Contents 4 0 R /Annots [7 0 R] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /OCG /Name (Imported hidden) >>",
            "<< /Type /OCMD /OCGs [5 0 R] /P /AllOff >>",
            "<< /Type /Annot /Subtype /Link /Rect [10 10 50 50] /OC 6 0 R /A << /S /URI /URI (https://example.com) >> >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 200 200] /OC 5 0 R /Resources << /Properties << /L 5 0 R >> >> /Length \(form.utf8.count) >>\nstream\n\(form)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Outlines /First 11 0 R /Last 11 0 R /Count 1 >>",
            "<< /Title (Bookmark) /Parent 10 0 R /Dest [3 0 R /Fit] >>"
        ]
        if let streams = contentStreams, streams.count > 1 {
            var refs = ["4 0 R"]
            for stream in streams.dropFirst() {
                refs.append("\(objects.count + 1) 0 R")
                objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
            }
            objects[2] = objects[2].replacingOccurrences(of: "/Contents 4 0 R", with: "/Contents [\(refs.joined(separator: " "))]")
        }
        if !layered {
            objects[0] = "<< /Type /Catalog /Pages 2 0 R /Outlines 10 0 R >>"
            objects[2] = objects[2].replacingOccurrences(of: "/Properties << /L 5 0 R /M 6 0 R >>", with: "")
            objects[6] = objects[6].replacingOccurrences(of: "/OC 6 0 R", with: "")
            objects[7] = "<< /Type /XObject /Subtype /Form /BBox [0 0 200 200] /Length 0 >>\nstream\n\nendstream"
            objects[4] = "null"; objects[5] = "null"
        }
        var pdf = "%PDF-1.7\n", offsets = [0]
        for (i, object) in objects.enumerated() { offsets.append(pdf.utf8.count); pdf += "\(i+1) 0 obj\n\(object)\nendobj\n" }
        let start = pdf.utf8.count
        pdf += "xref\n0 \(objects.count+1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        let url = dir.appendingPathComponent("input.pdf"); try Data(pdf.utf8).write(to:url); return url
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url
    }
    func testHiddenNestedContentFormsAnnotationsAndNavigationSurvive() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let source = try fixture(dir), original = try Data(contentsOf:source), out = dir.appendingPathComponent("out.pdf")
        try PDFLayerPurger.purge(source:source,destination:out)
        let json = try PDFLayerPurger.inspect(out)
        let text = String(decoding:try JSONSerialization.data(withJSONObject:json),as:UTF8.self)
        XCTAssertFalse(text.contains("/OCG")); XCTAssertFalse(text.contains("/OCMD")); XCTAssertFalse(text.contains("/OCProperties"))
        let doc = try XCTUnwrap(PDFDocument(url:out)); XCTAssertEqual(doc.pageCount,1)
        XCTAssertTrue(doc.string?.contains("Hidden /OC BDC EMC") == true)
        XCTAssertEqual(doc.page(at:0)?.annotations.count,1); XCTAssertEqual(doc.outlineRoot?.child(at:0)?.label,"Bookmark")
        XCTAssertEqual(doc.page(at:0)?.bounds(for:.cropBox),CGRect(x:5,y:5,width:190,height:190))
        XCTAssertEqual(try Data(contentsOf:source),original)
        let second = dir.appendingPathComponent("second.pdf"); try PDFLayerPurger.purge(source:out,destination:second)
        XCTAssertEqual(PDFDocument(url:second)?.string,doc.string)
    }
    func testCancelFailureAndAliasLeaveDestinationAndOriginalUntouched() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let source = try fixture(dir), original = try Data(contentsOf:source), out = dir.appendingPathComponent("out.pdf")
        let sentinel = Data("sentinel".utf8); try sentinel.write(to:out)
        XCTAssertThrowsError(try PDFLayerPurger.purge(source:source,destination:out,cancelled:{ true }))
        XCTAssertEqual(try Data(contentsOf:out),sentinel)
        XCTAssertThrowsError(try PDFLayerPurger.purge(source:source,destination:out,helper:nil))
        XCTAssertEqual(try Data(contentsOf:out),sentinel)
        XCTAssertThrowsError(try PDFLayerPurger.purge(source:source,destination:out))
        XCTAssertEqual(try Data(contentsOf:out),sentinel)
        XCTAssertThrowsError(try PDFLayerPurger.purge(source:source,destination:source))
        XCTAssertEqual(try Data(contentsOf:source),original)
    }
    func testInlineImageBytesSurviveLayerPurgeIncludingOperatorLikeData() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        var image = Data("abc EI /OC /L BDC defghijklmnop".utf8)
        while image.count % 3 != 0 { image.append(42) }
        let content = "/OC /L BDC q 50 0 0 20 20 20 cm BI /W \(image.count / 3) /H 1 /CS /RGB /BPC 8 ID\n" + String(decoding:image,as:UTF8.self) + "\nEI Q EMC"
        let source = try fixture(dir,contentStreams:[content]), original = try Data(contentsOf:source), out=dir.appendingPathComponent("purged.pdf")
        try PDFLayerPurger.purge(source:source,destination:out)
        let objects = try XCTUnwrap((try PDFLayerPurger.inspect(out)["qpdf"] as? [[String:Any]])?.last)
        let streams = objects.values.compactMap { ($0 as? [String:Any])?["stream"] as? [String:Any] }
        let expected = try PDFLayerPurger.unconditional(Data(content.utf8))
        XCTAssertTrue(streams.contains { ($0["data"] as? String).flatMap { Data(base64Encoded:$0) } == expected })
        XCTAssertTrue(expected.range(of:image) != nil)
        XCTAssertFalse(String(describing:objects).contains("/OCProperties"))
        XCTAssertEqual(try Data(contentsOf:source),original)
    }

    func testInlineImageEncodingsStayOpaqueAndMalformedImagesFailClosed() throws {
        for encoded in [
            "BI /W 1 /H 1 /IM true /BPC 1 /F [/AHx] ID\r\n00>\r\nEI",
            "BI /W 1 /H 1 /CS /RGB /BPC 8 /F /A85 ID\n/OC BDC~>\nEI",
            "BI /W 8 /H 1 /IM true /BPC 1 ID\nX\nEI"
        ] {
            let source = Data(("/OC /L BDC q " + encoded + " Q EMC").utf8)
            XCTAssertEqual(try PDFLayerPurger.unconditional(source),Data(("/Artifact BMC q " + encoded + " Q EMC").utf8))
        }
        for malformed in [
            "BI /W 1 /H 1 /CS /RGB /BPC 8 ID\nA\nEI",
            "BI /W 1 /H 1 /F /AHx ID\n00\nEI",
            "BI /W 1 /H 1 /F /DCT ID\nabc EI",
            "BI /W 999999999999999999 /H 99 /CS /RGB /BPC 16 ID\nabc\nEI",
            "BI /W 1 /H 1 /IM true ID\nX\nEX"
        ] { XCTAssertThrowsError(try PDFLayerPurger.unconditional(Data(malformed.utf8))) }
    }

    @MainActor func testPrivateControllerPurgeInPlace() throws {
        guard let path=ProcessInfo.processInfo.environment["DRAWBRIDGE_PURGE_PRIVATE_FIXTURE"] else { throw XCTSkip("Private controller fixture opt-in") }
        _ = NSApplication.shared
        let dir=try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let source=dir.appendingPathComponent("input.pdf");try FileManager.default.copyItem(at:URL(fileURLWithPath:path),to:source)
        let c=MainViewController();_ = c.view
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:1200,height:800),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentViewController=c;defer { window.contentViewController=nil }
        c.openDocument(at:source)
        var complete:Bool?
        c.purgeLayersInPlace { complete=$0 }
        let deadline=Date().addingTimeInterval(240)
        while complete==nil && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(complete,true,c.lastPurgeErrorMessage ?? "No detailed error")
        XCTAssertEqual(c.pdfView.document?.pageCount,PDFDocument(url:URL(fileURLWithPath:path))?.pageCount)
        XCTAssertFalse(c.hasUnsavedChanges())
        XCTAssertEqual(c.openDocumentURL,source)
    }

    func testPrivateFixtureAllPagesAndDecodedStreamSafety() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_PURGE_PRIVATE_FIXTURE"] else { throw XCTSkip("Private fixture opt-in") }
        let source = URL(fileURLWithPath:path), dir = try directory(), out = dir.appendingPathComponent("purged.pdf")
        defer { try? FileManager.default.removeItem(at:dir) }
        let original = try Data(contentsOf:source)
        try PDFLayerPurger.purge(source:source,destination:out)
        let before = try PDFLayerPurger.inspect(source), after = try PDFLayerPurger.inspect(out)
        let beforeObjects = try XCTUnwrap((before["qpdf"] as? [[String:Any]])?.last)
        let afterObjects = try XCTUnwrap((after["qpdf"] as? [[String:Any]])?.last)
        func streams(_ objects: [String:Any], normalize: Bool) throws -> [String] {
            var content = Set<String>()
            func collect(_ value:Any?) {
                if let ref = value as? String, let entry = objects["obj:"+ref] as? [String:Any] {
                    if entry["stream"] != nil { content.insert("obj:"+ref) }
                    else if let array = entry["value"] as? [Any] { array.forEach { collect($0) } }
                } else if let array = value as? [Any] { array.forEach { collect($0) } }
            }
            for (key,value) in objects {
                let entry = value as? [String:Any] ?? [:]
                if let dict = entry["value"] as? [String:Any], dict["/Type"] as? String == "/Page" { collect(dict["/Contents"]) }
                if let stream = entry["stream"] as? [String:Any], let dict = stream["dict"] as? [String:Any], dict["/Subtype"] as? String == "/Form" || dict["/PatternType"] as? Int == 1 { content.insert(key) }
            }
            return try objects.compactMap { key,value -> String? in
                guard let stream = (value as? [String:Any])?["stream"] as? [String:Any], let text = stream["data"] as? String, let data = Data(base64Encoded:text) else { return nil }
                let type = (stream["dict"] as? [String:Any])?["/Type"] as? String
                // qpdf rebuilds object and cross-reference containers; these are not document content.
                if type == "/ObjStm" || type == "/XRef" { return nil }
                return try (normalize && content.contains(key) ? PDFLayerPurger.unconditional(data) : data).base64EncodedString()
            }.sorted()
        }
        XCTAssertEqual(try streams(beforeObjects,normalize:true),try streams(afterObjects,normalize:false),"Every decoded stream retained except OC wrapper replacement")
        let a = try XCTUnwrap(PDFDocument(url:source)), b = try XCTUnwrap(PDFDocument(url:out))
        XCTAssertEqual(a.pageCount,b.pageCount)
        var annotations = 0, characters = 0
        for index in 0..<a.pageCount {
            let x = try XCTUnwrap(a.page(at:index)), y = try XCTUnwrap(b.page(at:index))
            XCTAssertEqual(x.string,y.string,"page \(index+1) text")
            XCTAssertEqual(x.annotations.count,y.annotations.count,"page \(index+1) annotations")
            for box:PDFDisplayBox in [.mediaBox,.cropBox,.bleedBox,.trimBox,.artBox] { XCTAssertEqual(x.bounds(for:box),y.bounds(for:box)) }
            XCTAssertEqual(x.rotation,y.rotation); annotations += y.annotations.count; characters += y.string?.count ?? 0
        }
        XCTAssertEqual(try Data(contentsOf:source),original)
        let second = dir.appendingPathComponent("purged-reopened.pdf")
        try PDFLayerPurger.purge(source:out,destination:second)
        XCTAssertEqual(PDFDocument(url:second)?.pageCount,b.pageCount)
        XCTAssertEqual(PDFDocument(url:second)?.string,b.string)
        print("PRIVATE PURGE QUALIFICATION pages=\(b.pageCount) annotations=\(annotations) textCharacters=\(characters) inputStreams=\(try streams(beforeObjects,normalize:false).count) outputStreams=\(try streams(afterObjects,normalize:false).count)")
    }
    @MainActor func testDocumentToolbarOffersAccessiblePurgeInPlace() throws {
        _ = NSApplication.shared
        let c = MainViewController(); _ = c.view
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:1400,height:900), styleMask:[.titled], backing:.buffered, defer:false)
        window.contentViewController = c
        window.toolbar = c.makeToolbar()
        defer { window.toolbar = nil; window.contentViewController = nil }
        let button = try XCTUnwrap(Self.views(window.contentView!.superview!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "drawbridgePurgeLayers" })
        XCTAssertEqual(button.title, "Purge Layers")
        XCTAssertEqual(button.accessibilityLabel(), "Purge Layers")
        XCTAssertTrue(button.toolTip?.contains("save this PDF") == true)
        XCTAssertNotNil(button.image); XCTAssertTrue(button.target === c)
        let siblings = try XCTUnwrap(button.superview as? NSStackView).arrangedSubviews.compactMap { $0 as? NSButton }
        let purgeIndex = try XCTUnwrap(siblings.firstIndex(of: button))
        XCTAssertEqual(siblings[0].title, "Open")
        XCTAssertEqual(purgeIndex, 1)
        XCTAssertTrue(siblings[purgeIndex + 1].toolTip?.contains("Auto-Generate Sheet Names") == true)
        XCTAssertTrue(siblings[purgeIndex + 2].toolTip?.contains("Batch Link Sheet Numbers") == true)
        XCTAssertFalse(button.isEnabled)
        let dir = try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        c.openDocument(at: try fixture(dir)); c.updateStatusBar()
        XCTAssertTrue(button.isEnabled)
        c.isPDFFileProcessingOperation = true; c.updateStatusBar()
        XCTAssertFalse(button.isEnabled)
        c.isPDFFileProcessingOperation = false
    }
    @MainActor func testToolbarConfirmationExplainsInPlaceSaveAndCancelPreservesDirtySession() throws {
        _ = NSApplication.shared
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir), original = try Data(contentsOf: source)
        let c = MainViewController(); _ = c.view
        let window = NSWindow(contentRect: CGRect(x:0,y:0,width:1400,height:900), styleMask:[.titled], backing:.buffered, defer:false)
        window.contentViewController = c
        window.toolbar = c.makeToolbar()
        defer { window.toolbar = nil; window.contentViewController = nil }
        c.openDocument(at: source)
        let document = try XCTUnwrap(c.pdfView.document)
        window.isDocumentEdited = true
        c.markupChangeVersion += 1
        let button = try XCTUnwrap(Self.views(window.contentView!.superview!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "drawbridgePurgeLayers" })
        var sawConfirmation = false
        c.updateStatusBar()
        XCTAssertTrue(button.isEnabled)
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let modal = NSApp.modalWindow, let content = modal.contentView else { return }
                let text = Self.views(content).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
                guard text.contains("Purge Layers") else { NSApp.abortModal(); return }
                sawConfirmation = true
                XCTAssertTrue(text.contains("All layers will be removed"))
                XCTAssertTrue(text.contains("artwork and annotations"))
                XCTAssertTrue(text.contains("hidden content will become visible"))
                XCTAssertTrue(text.contains("current edits will be saved"))
                let buttons = Self.views(content).compactMap { $0 as? NSButton }
                XCTAssertTrue(buttons.contains { $0.title == "Purge and Save" })
                guard let cancel = buttons.first(where: { $0.title == "Cancel" }) else { NSApp.abortModal(); return }
                cancel.performClick(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        button.performClick(nil)
        XCTAssertTrue(sawConfirmation)
        XCTAssertTrue(c.pdfView.document === document)
        XCTAssertTrue(c.hasUnsavedChanges())
        XCTAssertFalse(c.isPDFFileProcessingOperation)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["input.pdf"])
    }
    @MainActor func testSavedCopyIncludesUnsavedAnnotationsWithoutSavingOriginalOrCleaningSession() throws {
        _ = NSApplication.shared
        let dir = try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let source = try fixture(dir), original = try Data(contentsOf:source), destination = dir.appendingPathComponent("copy.pdf")
        let c = MainViewController(); _ = c.view
        let window = NSWindow(contentRect: CGRect(x:0,y:0,width:1000,height:700), styleMask:[.titled], backing:.buffered, defer:false)
        window.contentViewController = c
        window.toolbar = c.makeToolbar()
        defer { window.toolbar = nil; window.contentViewController = nil }
        c.openDocument(at:source)
        let document = try XCTUnwrap(c.pdfView.document)
        let annotation = PDFAnnotation(bounds:CGRect(x:80,y:80,width:80,height:20),forType:.freeText,withProperties:nil)
        annotation.setValue(RectangleMarkupRecord.prefix + UUID().uuidString, forAnnotationKey: PDFAnnotationKey(rawValue:"/NM"))
        annotation.contents = "Unsaved note"; document.page(at:0)!.addAnnotation(annotation)
        window.isDocumentEdited = true
        c.markupChangeVersion += 1
        var completed: Bool?
        c.savePurgedLayersCopy(to:destination) { completed = $0 }
        let deadline = Date().addingTimeInterval(25)
        while completed == nil && Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(completed,true)
        XCTAssertEqual(try Data(contentsOf:source),original)
        XCTAssertTrue(c.pdfView.document === document); XCTAssertEqual(c.openDocumentURL,source)
        XCTAssertTrue(c.hasUnsavedChanges())
        let result = try XCTUnwrap(PDFDocument(url:destination))
        XCTAssertTrue(result.page(at:0)?.annotations.contains { $0.contents == "Unsaved note" } == true)
        var rejected: Bool?
        c.savePurgedLayersCopy(to:source) { rejected = $0 }
        XCTAssertEqual(rejected,false); XCTAssertEqual(try Data(contentsOf:source),original)
    }
    @MainActor func testInPlacePurgeSavesDirtyAnnotationsAndReloadsBothSplitPanes() throws {
        _ = NSApplication.shared
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir)
        let c = MainViewController(); _ = c.view
        let window = NSWindow(contentRect: CGRect(x:0,y:0,width:1400,height:900), styleMask:[.titled], backing:.buffered, defer:false)
        window.contentViewController = c
        defer { window.contentViewController = nil }
        c.openDocument(at: source)
        let document = try XCTUnwrap(c.pdfView.document)
        let note = PDFAnnotation(bounds: CGRect(x:80,y:80,width:80,height:20), forType: .freeText, withProperties: nil)
        note.setValue(RectangleMarkupRecord.prefix + UUID().uuidString, forAnnotationKey: PDFAnnotationKey(rawValue:"/NM"))
        note.contents = "Saved in place"; document.page(at: 0)!.addAnnotation(note)
        window.isDocumentEdited = true; c.markupChangeVersion += 1
        c.commandToggleSplitView(nil)
        XCTAssertNotNil(c.secondaryPDFView)
        var completed: Bool?
        c.purgeLayersInPlace { completed = $0 }
        let deadline = Date().addingTimeInterval(30)
        while completed == nil && Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(completed, true)
        XCTAssertEqual(c.openDocumentURL, source)
        XCTAssertFalse(c.pdfView.document === document)
        XCTAssertFalse(c.hasUnsavedChanges())
        XCTAssertFalse(c.isPDFFileProcessingOperation)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:dir.path), ["input.pdf"])
        let reopened = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertTrue(reopened.page(at:0)?.annotations.contains { $0.contents == "Saved in place" } == true)
        XCTAssertTrue(c.pdfView.document?.page(at:0)?.annotations.contains { $0.contents == "Saved in place" } == true)
        XCTAssertTrue(c.secondaryPDFView?.document?.page(at:0)?.annotations.contains { $0.contents == "Saved in place" } == true)
        let objects = try PDFLayerPurger.inspect(source)
        XCTAssertFalse(String(describing: objects).contains("/OCProperties"))
        XCTAssertNotNil(reopened.page(at:0)?.annotations.first { ($0.action as? PDFActionURL)?.url?.absoluteString == "https://example.com" })
        XCTAssertEqual(reopened.outlineRoot?.child(at:0)?.label, "Bookmark")
    }

    @MainActor func testInPlacePurgeDoesNotOverwriteExternallyChangedSource() throws {
        _ = NSApplication.shared
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir)
        let c = MainViewController(); _ = c.view
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:1000,height:700),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentViewController = c; defer { window.contentViewController = nil }
        c.openDocument(at: source)
        let document = try XCTUnwrap(c.pdfView.document)
        window.isDocumentEdited = true; c.markupChangeVersion += 1
        var replacement = try Data(contentsOf: source); replacement.append(Data("\n% External revision\n".utf8))
        try replacement.write(to:source)
        var completed: Bool?
        c.purgeLayersInPlace { completed = $0 }
        let deadline = Date().addingTimeInterval(20)
        while completed == nil && Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(completed,false)
        XCTAssertEqual(try Data(contentsOf:source),replacement)
        XCTAssertTrue(c.pdfView.document === document)
        XCTAssertTrue(c.hasUnsavedChanges())
        XCTAssertTrue(c.lastPurgeErrorMessage?.contains("changed outside Drawbridge") == true)
        XCTAssertFalse(c.isPDFFileProcessingOperation)
    }

    func testSplitOptionalContentOperandsFailClosedWithoutPublishing() throws {
        for parts in [["/OC /L", "BDC 10 10 20 20 re f EMC"], ["/OC", "/L BDC 10 10 20 20 re f EMC"], ["/OC /L % boundary", "BDC 10 10 20 20 re f EMC"]] {
            let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let source = try fixture(dir, contentStreams: parts), original = try Data(contentsOf: source)
            let out = dir.appendingPathComponent("out.pdf")
            XCTAssertThrowsError(try PDFLayerPurger.purge(source: source, destination: out), "Incomplete stream operands must fail closed")
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "No unresolved wrapper may be published")
            try? FileManager.default.removeItem(at: out)
            let sentinel = Data("existing destination".utf8); try sentinel.write(to: out)
            XCTAssertThrowsError(try PDFLayerPurger.purge(source: source, destination: out))
            XCTAssertEqual(try Data(contentsOf: out), sentinel)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }
    func testEscapedOptionalContentNamesAreDecodedLexically() throws {
        for name in ["/#4F#43", "/#4f#43", "/O#43", "/#4FC"] {
            let input = Data("\(name) /L BDC (/#4F#43 /L BDC) Tj EMC".utf8)
            XCTAssertEqual(try PDFLayerPurger.unconditional(input), Data("/Artifact BMC (/#4F#43 /L BDC) Tj EMC".utf8), name)
        }
    }
    func testEscapedOptionalContentWrapperDoesNotSurviveSavedCopy() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir, contentStreams: ["/#4F#43 /L BDC 10 10 20 20 re f EMC"])
        let original = try Data(contentsOf: source), out = dir.appendingPathComponent("out.pdf")
        try PDFLayerPurger.purge(source: source, destination: out)
        let objects = try XCTUnwrap((try PDFLayerPurger.inspect(out)["qpdf"] as? [[String: Any]])?.last)
        let texts = objects.values.compactMap { value -> String? in
            guard let stream = (value as? [String: Any])?["stream"] as? [String: Any], let encoded = stream["data"] as? String, let data = Data(base64Encoded: encoded) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        XCTAssertFalse(texts.contains { $0.contains("/#4F#43") })
        XCTAssertTrue(texts.contains { $0.contains("/Artifact BMC 10 10 20 20 re f EMC") })
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testNoLayersRetainsPageContent() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let source = try fixture(dir,layered:false), out = dir.appendingPathComponent("out.pdf")
        try PDFLayerPurger.purge(source:source,destination:out)
        XCTAssertEqual(PDFDocument(url:out)?.pageCount,1)
        XCTAssertEqual(PDFDocument(url:out)?.page(at:0)?.annotations.count,1)
    }
}
