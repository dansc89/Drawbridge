import Foundation
import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

final class PDFAnnotationFlattenerTests: XCTestCase {
    private func fixture(in directory: URL, noAppearance: Bool = false, signed: Bool = false, shxComments: Bool = false) throws -> URL {
        // Nonzero crop origin, inherited rotation, transformed appearance, interactive
        // link, widget, hidden markup, missing appearance, outline and page label.
        let base = "0.9 g 20 30 260 180 re f 0 G 2 w 40 50 m 250 170 l S\n"
        let appearance = "1 0 0 rg 0 0 40 20 re f\n"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 10 0 R /PageLabels << /Nums [0 << /P (A1.00) >>] >> /AcroForm << /Fields [7 0 R] >> >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] /MediaBox [0 0 320 240] /CropBox [20 30 280 210] /Rotate 270 >>",
            "<< /Type /Page /Parent 2 0 R /Resources << >> /Contents 4 0 R /Annots [5 0 R 6 0 R 7 0 R 8 0 R 9 0 R] >>",
            "<< /Length \(base.utf8.count) >>\nstream\n\(base)endstream",
            "<< /Type /Annot /Subtype /Stamp /Rect [60 70 140 110] /F 4 \(noAppearance ? "" : "/AP << /N 12 0 R >>") >>",
            "<< /Type /Annot /Subtype /Link /Rect [180 100 220 140] /A << /S /GoTo /D [3 0 R /Fit] >> >>",
            "<< /Type /Annot /Subtype /Widget /FT \(signed ? "/Sig" : "/Tx") /T (consultant) /V (Keep me) /Rect [150 60 200 90] /AP << /N 12 0 R >> >>",
            "<< /Type /Annot /Subtype /Ink /Rect [10 10 30 30] /F 2 /AP << /N 12 0 R >> >>",
            "<< /Type /Annot /Subtype /FreeText /Rect [30 30 50 50] /Contents (Missing appearance) >>",
            "<< /Type /Outlines /First 11 0 R /Last 11 0 R /Count 1 >>",
            "<< /Title (Sheet A1.00) /Parent 10 0 R /Dest [3 0 R /Fit] >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 40 20] /Matrix [2 0 0 2 10 15] /Resources << >> /Length \(appearance.utf8.count) >>\nstream\n\(appearance)endstream"
        ]
        if shxComments {
            let common = "/Subtype /Square /T (AutoCAD SHX Text) /Contents (Existing drawing text) /Rect [140 70 60 110]"
            objects += [
                "<< \(common) /Border [0 0 0] /F 64 >>",
                "<< \(common) /Border [0 0 0] /C [1 0 0] >>",
                "<< \(common) /Border [0 0 1] >>",
                "<< /Subtype /Square /T (Consultant) /Contents (Keep) /Border [0 0 0] /Rect [60 70 140 110] >>",
                "<< \(common) /Border [0 0 0] /F 4 >>"
            ]
            objects[2] = objects[2].replacingOccurrences(of: "9 0 R]", with: "9 0 R 13 0 R 14 0 R 15 0 R 16 0 R 17 0 R]")
        }
        var bytes = Data("%PDF-1.7\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let url = directory.appendingPathComponent("original.pdf")
        try bytes.write(to: url)
        return url
    }
    private func bluebeamFixture(in directory: URL, duplicate: Bool = false, missing: Bool = false) throws -> URL {
        let base = "0.8 g 0 0 200 200 re f\n"
        let melted = "0 1 0 rg 120 120 20 20 re f\nq 1 0 0 1 50 60 cm /BB Do Q\n"
        let permanent = "0 0 1 rg 10 10 20 20 re f\n"
        let appearance = "1 0 0 rg 0 0 40 20 re f\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] /MediaBox [0 0 200 200] >>",
            "<< /Type /Page /Parent 2 0 R /Resources << /XObject << /BB 8 0 R >> >> /Contents [4 0 R 5 0 R 6 0 R] /Annots [9 0 R \(duplicate ? "7 0 R" : "")] >>",
            "<< /Length \(base.utf8.count) >>\nstream\n\(base)endstream",
            "<< /BBType /Melted /Annots [\(missing ? "4" : "7") 0 R] /Length \(melted.utf8.count) >>\nstream\n\(melted)endstream",
            "<< /BBType /Melted /Length \(permanent.utf8.count) >>\nstream\n\(permanent)endstream",
            "<< /Type /Annot /Subtype /Stamp /P 3 0 R /Rect [50 60 90 80] /F 4 /NM (Recovered) /AP << /N 8 0 R >> >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 40 20] /Resources << >> /Length \(appearance.utf8.count) >>\nstream\n\(appearance)endstream",
            "<< /Type /Annot /Subtype /Link /Rect [0 0 10 10] /A << /S /URI /URI (https://example.com) >> >>"
        ]
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index+1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count+1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format:"%010d 00000 n \n",offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let url=directory.appendingPathComponent("bluebeam.pdf");try bytes.write(to:url);return url
    }

    @MainActor
    func testBluebeamRecoveryRestoresOriginalAndRemovesOnlyRecoverableDrawing() throws {
        let dir=try directory();defer { try? FileManager.default.removeItem(at:dir) }
        let source=try bluebeamFixture(in:dir)
        XCTAssertTrue(PDFAnnotationFlattener.canUnflatten(try XCTUnwrap(PDFDocument(url:source))))
        XCTAssertEqual(try PDFAnnotationFlattener.unflatten(source:source).restoredAnnotations,1)
        let doc=try XCTUnwrap(PDFDocument(url:source)), page=try XCTUnwrap(doc.page(at:0))
        XCTAssertEqual(page.annotations.count,2)
        let stamp=try XCTUnwrap(page.annotations.first {$0.type == "Stamp"})
        XCTAssertEqual(stamp.bounds,CGRect(x:50,y:60,width:40,height:20))
        XCTAssertTrue(ImportedMarkupState.selectable(stamp))
        XCTAssertFalse(PDFAnnotationFlattener.canUnflatten(doc))
        let restored=try Data(contentsOf:source)
        XCTAssertThrowsError(try PDFAnnotationFlattener.unflatten(source:source))
        XCTAssertEqual(try Data(contentsOf:source),restored)
        // Removing the original annotation must remove its only visible appearance.
        page.removeAnnotation(stamp)
        XCTAssertTrue(doc.write(to:dir.appendingPathComponent("deleted.pdf")))
        if let path=ProcessInfo.processInfo.environment["DRAWBRIDGE_BLUEBEAM_QA_OUTPUT"] {
            let output=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            _ = try bluebeamFixture(in:output)
            try restored.write(to:output.appendingPathComponent("restored.pdf"))
            try Data(contentsOf:dir.appendingPathComponent("deleted.pdf")).write(to:output.appendingPathComponent("deleted.pdf"))
        }
    }

    func testBluebeamRecoveryRejectsDuplicateAndMissingAnnotationsWithoutChangingFile() throws {
        for duplicate in [true,false] {
            let dir=try directory();defer { try? FileManager.default.removeItem(at:dir) }
            let source=try bluebeamFixture(in:dir,duplicate:duplicate,missing:!duplicate)
            let before=try Data(contentsOf:source)
            XCTAssertThrowsError(try PDFAnnotationFlattener.unflatten(source:source))
            XCTAssertEqual(try Data(contentsOf:source),before)
        }
    }

    func testBluebeamAppearanceStrippingPreservesOtherOperatorsAndOpaqueOperands() throws {
        let input = Data("q /OC /Layer BDC (/BB Do) Tj % /BB Do\n/Other Do /B#42 Do EMC Q\n".utf8)
        let result = try PDFLayerPurger.unconditional(input,removingXObjects:["/BB"])
        XCTAssertEqual(String(decoding:result,as:UTF8.self),"q /OC /Layer BDC (/BB Do) Tj % /BB Do\n/Other Do  EMC Q\n")
        XCTAssertThrowsError(try PDFLayerPurger.unconditional(Data("/BB Do /BB Do".utf8),removingXObjects:["/BB"]))
        XCTAssertThrowsError(try PDFLayerPurger.unconditional(Data("/Other Do".utf8),removingXObjects:["/BB"]))
    }

    func testBluebeamRecoveryOnExternalCopy() throws {
        guard let path=ProcessInfo.processInfo.environment["DRAWBRIDGE_BLUEBEAM_RECOVERY_PDF"],
              let output=ProcessInfo.processInfo.environment["DRAWBRIDGE_BLUEBEAM_RECOVERY_OUTPUT"] else { throw XCTSkip("Set Bluebeam recovery corpus paths") }
        let original=URL(fileURLWithPath:path), before=try Data(contentsOf:original)
        let copy=URL(fileURLWithPath:output);try before.write(to:copy)
        let result=try PDFAnnotationFlattener.unflatten(source:copy)
        XCTAssertGreaterThan(result.restoredAnnotations,0)
        let doc=try XCTUnwrap(PDFDocument(url:copy))
        XCTAssertFalse(PDFAnnotationFlattener.canUnflatten(doc))
        XCTAssertEqual(try Data(contentsOf:original),before)
        print("Bluebeam recovered annotations: \(result.restoredAnnotations); pages: \(doc.pageCount)")
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FlattenTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    @MainActor
    func testSeparateFlattenAndUnflattenControlsKeepStableRolesAcrossRecovery() throws {
        _ = NSApplication.shared
        let dir = try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let source = try fixture(in:dir)
        let controller = MainViewController(); _ = controller.view
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1400,height:900),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentViewController=controller;window.toolbar=controller.makeToolbar()
        defer { window.toolbar=nil;window.contentViewController=nil }
        let primary = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier == .drawbridgePrimaryControls }?.view as? NSStackView)
        let buttons=primary.arrangedSubviews.compactMap { $0 as? NSButton }
        let flatten=try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "drawbridgeFlattenPDF" })
        let unflatten=try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "drawbridgeUnflattenPDF" })
        XCTAssertEqual(flatten.action,#selector(MainViewController.commandFlattenPDF(_:)))
        XCTAssertEqual(unflatten.action,#selector(MainViewController.commandUnflattenPDF(_:)))
        XCTAssertEqual(flatten.image?.name(),NSImage.Name("DrawbridgeFlattenLayers"))
        XCTAssertEqual(unflatten.image?.name(),NSImage.Name("DrawbridgeUnflattenLayers"))
        XCTAssertTrue(flatten.image?.isTemplate == true);XCTAssertTrue(unflatten.image?.isTemplate == true)
        XCTAssertFalse(flatten.isEnabled);XCTAssertFalse(unflatten.isEnabled)
        let flattenMenu=NSMenuItem(title:"Flatten PDF…",action:#selector(MainViewController.commandFlattenPDF(_:)),keyEquivalent:"")
        let unflattenMenu=NSMenuItem(title:"Unflatten PDF…",action:#selector(MainViewController.commandUnflattenPDF(_:)),keyEquivalent:"")
        controller.openDocument(at:source);controller.updateStatusBar()
        XCTAssertTrue(flatten.isEnabled);XCTAssertTrue(unflatten.isEnabled)
        _ = try PDFAnnotationFlattener.flatten(source:source,destination:source)
        controller.openDocument(at:source);controller.updateStatusBar()
        XCTAssertFalse(flatten.isEnabled);XCTAssertTrue(unflatten.isEnabled)
        XCTAssertFalse(controller.validateMenuItem(flattenMenu));XCTAssertTrue(controller.validateMenuItem(unflattenMenu))
        XCTAssertEqual(flattenMenu.title,"Flatten PDF…");XCTAssertEqual(unflattenMenu.title,"Unflatten PDF…")
        XCTAssertEqual(flatten.accessibilityLabel(),"Flatten PDF");XCTAssertEqual(unflatten.accessibilityLabel(),"Unflatten PDF")
        XCTAssertEqual(flatten.image?.name(),NSImage.Name("DrawbridgeFlattenLayers"))
        controller.isPDFFileProcessingOperation=true;controller.updateStatusBar()
        XCTAssertFalse(flatten.isEnabled);XCTAssertFalse(unflatten.isEnabled)
        XCTAssertFalse(controller.validateMenuItem(unflattenMenu))
        controller.isPDFFileProcessingOperation=false
        let restored=try PDFAnnotationFlattener.unflatten(source:source)
        XCTAssertEqual(restored.restoredAnnotations,1)
        controller.openDocument(at:source);controller.updateStatusBar()
        XCTAssertTrue(flatten.isEnabled);XCTAssertTrue(unflatten.isEnabled)
        XCTAssertEqual(controller.pdfView.document?.page(at:0)?.annotations.count,5)
    }

    @MainActor
    func testExplicitControllerActionsFlattenThenUnflattenSavedPDF() throws {
        _ = NSApplication.shared
        let dir = try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let source=try fixture(in:dir)
        let c=MainViewController();_ = c.view
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:800),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentViewController=c;defer { window.contentViewController=nil }
        c.openDocument(at:source)
        var titles=[String]()
        func descendants(_ v:NSView)->[NSView] { [v]+v.subviews.flatMap(descendants) }
        let timer=Timer(timeInterval:0.02,repeats:true) { _ in
            MainActor.assumeIsolated {
                guard let content=NSApp.modalWindow?.contentView else { return }
                let fields=descendants(content).compactMap { $0 as? NSTextField }.map(\.stringValue)
                if let title=fields.first(where: { ["PDF Flattened and Saved","PDF Unflattened and Saved","No Markups Found","Unflatten Failed","Flatten Failed"].contains($0) }) { titles.append(title) }
                if let ok=descendants(content).compactMap({$0 as? NSButton}).first(where:{$0.title=="OK"}) { ok.performClick(nil) }
                else { NSApp.abortModal() }
            }
        }
        RunLoop.main.add(timer,forMode:.default);RunLoop.main.add(timer,forMode:.modalPanel)
        defer { timer.invalidate() }
        func finish(_ operation:()->Void) {
            let count=titles.count;operation()
            let end=Date().addingTimeInterval(15)
            while titles.count==count && Date()<end { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
            XCTAssertEqual(titles.count,count+1)
            XCTAssertFalse(c.isPDFFileProcessingOperation)
        }
        let original=try Data(contentsOf:source)
        finish { c.commandUnflattenPDF(nil) }
        XCTAssertEqual(titles.last,"No Markups Found")
        XCTAssertEqual(try Data(contentsOf:source),original)
        finish { c.commandFlattenPDF(nil) }
        XCTAssertEqual(titles.last,"PDF Flattened and Saved")
        XCTAssertTrue(PDFAnnotationFlattener.canUnflatten(try XCTUnwrap(c.pdfView.document)))
        finish { c.commandUnflattenPDF(nil) }
        XCTAssertEqual(titles.last,"PDF Unflattened and Saved")
        XCTAssertFalse(PDFAnnotationFlattener.canUnflatten(try XCTUnwrap(c.pdfView.document)))
        XCTAssertEqual(c.pdfView.document?.page(at:0)?.annotations.count,5)
        XCTAssertFalse(c.hasUnsavedChanges())
    }

    func testLosslessReductionKeepsUnflattenRecovery() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory)
        let original = try XCTUnwrap(PDFDocument(url: source))
        _ = try PDFAnnotationFlattener.flatten(source: source, destination: source)
        let reduced = try PDFLosslessReducer.reduce(source: source)
        XCTAssertTrue(reduced.saved)
        XCTAssertTrue(PDFAnnotationFlattener.canUnflatten(try XCTUnwrap(PDFDocument(url: source))))
        _ = try PDFAnnotationFlattener.unflatten(source: source)
        let restored = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(restored.page(at: 0)?.annotations.count, original.page(at: 0)?.annotations.count)
        XCTAssertEqual(restored.page(at: 0)?.rotation, original.page(at: 0)?.rotation)
    }

    func testFlattenPreservesGeometryNavigationFormsAndUnsupportedAnnotations() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory)
        let before = try Data(contentsOf: source)
        let output = directory.appendingPathComponent("flat.pdf")
        let result = try PDFAnnotationFlattener.flatten(source: source, destination: output)
        XCTAssertEqual(result.flattened, 1)
        XCTAssertEqual(result.retainedMarkups, 2)
        XCTAssertEqual(try Data(contentsOf: source), before)
        let document = try XCTUnwrap(PDFDocument(url: output))
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.rotation, 270)
        XCTAssertEqual(page.bounds(for: .cropBox), CGRect(x: 20, y: 30, width: 260, height: 180))
        XCTAssertEqual(page.annotations.count, 4)
        XCTAssertFalse(page.annotations.contains { $0.type == "Stamp" })
        let link = try XCTUnwrap(page.annotations.first { $0.type == "Link" })
        XCTAssertNotNil((link.action as? PDFActionGoTo)?.destination.page)
        XCTAssertEqual(page.annotations.first { $0.type == "Widget" }?.widgetStringValue, "Keep me")
        XCTAssertEqual(document.outlineRoot?.child(at: 0)?.label, "Sheet A1.00")
        XCTAssertEqual(page.label, "A1.00")
        // Retain a reproducible visual fixture only when explicitly requested.
        if let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_FLATTEN_QA"] {
            let qa = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
            try before.write(to: qa.appendingPathComponent("before.pdf"))
            try Data(contentsOf: output).write(to: qa.appendingPathComponent("after.pdf"))
        }
    }
    func testRejectsNoAppearanceWithoutReplacingOriginalOrWritingCopy() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory, noAppearance: true)
        let original = try Data(contentsOf: source)
        XCTAssertThrowsError(try PDFAnnotationFlattener.flatten(source: source, destination: source))
        let output = directory.appendingPathComponent("flat.pdf")
        XCTAssertThrowsError(try PDFAnnotationFlattener.flatten(source: source, destination: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testInPlaceSaveIsImmediatelyReadableAndPreservesNavigation() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory)
        let before = try Data(contentsOf: source)
        let result = try PDFAnnotationFlattener.flatten(source: source, destination: source)
        XCTAssertEqual(result.flattened, 1)
        XCTAssertNotEqual(try Data(contentsOf: source), before)
        let reloaded = try XCTUnwrap(PDFDocument(url: source))
        let page = try XCTUnwrap(reloaded.page(at: 0))
        XCTAssertEqual(page.annotations.count, 4)
        XCTAssertEqual(page.rotation, 270)
        XCTAssertEqual(page.label, "A1.00")
        XCTAssertEqual(reloaded.outlineRoot?.child(at: 0)?.label, "Sheet A1.00")
        XCTAssertNotNil((page.annotations.first { $0.type == "Link" }?.action as? PDFActionGoTo)?.destination.page)
    }

    func testInPlaceSaveDoesNotOverwriteExternalEdits() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory)
        var edited = try Data(contentsOf: source)
        edited.append(Data("\n% External edit\n".utf8))
        let externalEdit = edited
        XCTAssertThrowsError(try PDFAnnotationFlattener.flatten(source: source, destination: source, progress: { detail in
            if detail.hasPrefix("Restoring links") { try! externalEdit.write(to: source) }
        }))
        XCTAssertEqual(try Data(contentsOf: source), externalEdit)
        XCTAssertEqual(PDFDocument(url: source)?.page(at: 0)?.annotations.count, 5)
    }

    func testUnflattenSurvivesReopenAndPreservesNewBookmarksAndLinks() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory)
        _ = try PDFAnnotationFlattener.flatten(source: source, destination: source)
        let flattened = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertTrue(PDFAnnotationFlattener.canUnflatten(flattened))
        let page = try XCTUnwrap(flattened.page(at: 0))
        let root = PDFOutline(); let bookmark = PDFOutline()
        bookmark.label = "Changed after flattening"
        bookmark.destination = PDFDestination(page: page, at: .zero)
        root.insertChild(bookmark, at: 0); flattened.outlineRoot = root
        let link = PDFAnnotation(bounds: CGRect(x: 50, y: 50, width: 20, height: 20), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: page, at: .zero))
        link.contents = "DrawbridgeAutoSheetLink"
        page.addAnnotation(link)
        XCTAssertEqual(PDFTKBookmarkWriter.writeNavigation(in: flattened, sourceURL: source, to: source, pageLabels: [0: "A2.00"]), .saved)
        let reopened = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertTrue(PDFAnnotationFlattener.canUnflatten(reopened))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.count, 5)
        let result = try PDFAnnotationFlattener.unflatten(source: source)
        XCTAssertEqual(result.restoredAnnotations, 1)
        let restored = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertFalse(PDFAnnotationFlattener.canUnflatten(restored))
        XCTAssertEqual(restored.page(at: 0)?.annotations.count, 6)
        XCTAssertEqual(restored.page(at: 0)?.annotations.filter { $0.type == "Stamp" }.count, 1)
        XCTAssertEqual(restored.page(at: 0)?.rotation, 270)
        XCTAssertEqual(restored.page(at: 0)?.label, "A2.00")
        XCTAssertEqual(restored.outlineRoot?.child(at: 0)?.label, "Changed after flattening")
        _ = try PDFAnnotationFlattener.flatten(source: source, destination: source)
        XCTAssertTrue(PDFAnnotationFlattener.canUnflatten(try XCTUnwrap(PDFDocument(url: source))))
    }

    func testUnflattenRejectsEditedStreamEvenWhenObjectReferencesStayTheSame() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory)
        _ = try PDFAnnotationFlattener.flatten(source: source, destination: source)
        let executable = try XCTUnwrap(PDFTKBookmarkWriter.executableURL())
        let jsonURL = directory.appendingPathComponent("edit.json")
        XCTAssertTrue(PDFTKBookmarkWriter.run(executable, arguments: ["--json=2", source.path, jsonURL.path]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        var tables = try XCTUnwrap(json["qpdf"] as? [[String: Any]])
        var objects = tables[1]
        let pages = try XCTUnwrap(json["pages"] as? [[String: Any]])
        let pageRef = try XCTUnwrap(pages[0]["object"] as? String)
        let page = try XCTUnwrap((objects["obj:" + pageRef] as? [String: Any])?["value"] as? [String: Any])
        var contents = try XCTUnwrap(page["/Contents"])
        if let ref = contents as? String, let array = (objects["obj:" + ref] as? [String: Any])?["value"] as? [Any] { contents = array }
        let refs: [String]
        if let array = contents as? [String] { refs = array }
        else { refs = [try XCTUnwrap(contents as? String)] }
        let streamRef = try XCTUnwrap(refs.first)
        let edited = Data("q 0 1 0 rg 40 40 20 20 re f Q\n".utf8)
        objects["obj:" + streamRef] = ["stream": ["dict": ["/Length": edited.count], "data": edited.base64EncodedString()]]
        tables[1] = objects; json["qpdf"] = tables
        try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes, .sortedKeys]).write(to: jsonURL)
        let changedURL = directory.appendingPathComponent("changed.pdf")
        XCTAssertTrue(PDFTKBookmarkWriter.run(executable, arguments: [source.path, "--stream-data=preserve", "--update-from-json=\(jsonURL.path)", changedURL.path]))
        let before = try Data(contentsOf: changedURL)
        XCTAssertThrowsError(try PDFAnnotationFlattener.unflatten(source: changedURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Drawing content has changed"))
        }
        XCTAssertEqual(try Data(contentsOf: changedURL), before)
        XCTAssertThrowsError(try PDFLosslessReducer.reduce(source: changedURL))
        XCTAssertEqual(try Data(contentsOf: changedURL), before)
    }

    func testUnflattenRejectsChangedDrawingStreamWithoutOverwriting() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory)
        _ = try PDFAnnotationFlattener.flatten(source: source, destination: source)
        let editor = try XCTUnwrap(PDFDocument(url: source))
        // A changed rotation must not be lost by restoring the older page state.
        editor.page(at: 0)?.rotation = 90
        XCTAssertTrue(editor.write(to: source))
        let changed = try Data(contentsOf: source)
        XCTAssertThrowsError(try PDFAnnotationFlattener.unflatten(source: source))
        XCTAssertEqual(try Data(contentsOf: source), changed)
    }

    func testRedundantSHXCommentsAreRemovedWithoutDroppingVisibleOrPrintableAnnotations() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory, noAppearance: true, shxComments: true)
        let before = try Data(contentsOf: source)
        let output = directory.appendingPathComponent("flat.pdf")
        let result = try PDFAnnotationFlattener.flatten(source: source, destination: output)
        XCTAssertEqual(result.flattened, 0)
        XCTAssertEqual(result.removedSHXComments, 1)
        XCTAssertEqual(result.retainedMarkups, 7)
        XCTAssertEqual(try Data(contentsOf: source), before)
        let page = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
        XCTAssertEqual(page.annotations.count, 9)
        XCTAssertEqual(page.rotation, 270)
    }

    @MainActor
    func testFlattenMenuRequiresASavedDocumentAndDisablesDuringProcessing() throws {
        guard ProcessInfo.processInfo.environment["DRAWBRIDGE_RUN_NATIVE_UI_TESTS"] == "1" else {
            throw XCTSkip("Run menu integration in a native app test environment")
        }
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory)
        let controller = MainViewController()
        _ = controller.view
        let item = NSMenuItem(title: "Flatten PDF…", action: #selector(MainViewController.commandFlattenPDF(_:)), keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(item))
        controller.pdfView.document = try XCTUnwrap(PDFDocument(url: source))
        controller.openDocumentURL = source
        XCTAssertTrue(controller.validateMenuItem(item))
        controller.beginBusyIndicator("Test flatten", lockInteraction: false)
        XCTAssertFalse(controller.validateMenuItem(item))
        controller.endBusyIndicator()
        XCTAssertTrue(controller.validateMenuItem(item))
    }

    func testRepresentativeMarkupCorpus() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_FLATTEN_CORPUS"] else {
            throw XCTSkip("Set DRAWBRIDGE_FLATTEN_CORPUS for the visual/performance corpus")
        }
        let root = URL(fileURLWithPath: path)
        let outputs = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        for source in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "pdf" }) {
            let original = try Data(contentsOf: source)
            let start = Date()
            let result = try PDFAnnotationFlattener.flatten(source: source, destination: outputs.appendingPathComponent(source.lastPathComponent))
            XCTAssertGreaterThan(result.flattened + result.removedSHXComments, 0)
            XCTAssertEqual(try Data(contentsOf: source), original)
            let toggle = outputs.appendingPathComponent("roundtrip-" + source.lastPathComponent)
            try? FileManager.default.removeItem(at: toggle)
            try FileManager.default.copyItem(at: outputs.appendingPathComponent(source.lastPathComponent), to: toggle)
            let recovery = try PDFAnnotationFlattener.unflatten(source: toggle)
            XCTAssertEqual(recovery.restoredAnnotations, result.flattened + result.removedSHXComments)
            XCTAssertFalse(PDFAnnotationFlattener.canUnflatten(try XCTUnwrap(PDFDocument(url: toggle))))
            print("Flatten corpus: \(source.lastPathComponent): \(result.flattened) markups, \(result.removedSHXComments) CAD comments in \(Date().timeIntervalSince(start)) seconds")
        }
    }

    func testRejectsSignatureField() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory, signed: true)
        XCTAssertThrowsError(try PDFAnnotationFlattener.flatten(source: source, destination: directory.appendingPathComponent("flat.pdf")))
    }
}
