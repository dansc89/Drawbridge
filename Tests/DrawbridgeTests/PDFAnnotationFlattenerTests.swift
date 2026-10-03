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
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FlattenTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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
