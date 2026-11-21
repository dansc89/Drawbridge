import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

enum ReviewPDFLayerFixture {
    static func data(withAnnotation: Bool = false) -> Data {
        let content = "/OC /A BDC 0 0 0 rg 10 10 30 30 re f EMC\n/OC /B BDC 60 60 20 20 re f EMC\n"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /BaseState /ON /Order [5 0 R 6 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /Properties << /A 5 0 R /B 6 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Type /OCG /Name (Duplicate) >>", "<< /Type /OCG /Name (Duplicate) >>"
        ]
        if withAnnotation {
            objects[2] = objects[2].replacingOccurrences(of:"/Contents 4 0 R",with:"/Contents 4 0 R /Annots [7 0 R]")
            objects.append("<< /Type /Annot /Subtype /Square /Rect [45 10 55 20] /C [1 0 0] /IC [1 0 0] /OC 5 0 R /F 4 >>")
        }
        return make(objects)
    }
    static func forms() -> Data {
        let content = "/OC /A BDC q 1 0 0 1 10 10 cm /F Do Q q 1 0 0 1 60 60 cm /F Do Q EMC\n"
        let form = "0 0 0 rg 0 0 10 10 re f 12 0 5 10 re f\n"
        return make([
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /BaseState /ON /Order [5 0 R 6 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /Properties << /A 5 0 R /B 6 0 R >> /XObject << /F 7 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Type /OCG /Name (Duplicate) >>", "<< /Type /OCG /Name (Duplicate) >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 20 10] /Resources << >> /OC 5 0 R /Length \(form.utf8.count) >>\nstream\n\(form)endstream"
        ])
    }
    private static func make(_ objects: [String]) -> Data {
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return bytes
    }
}

@MainActor final class ReviewPDFLayerAssignmentTests: XCTestCase {
    private func pixels(_ draw: (CGContext) -> Void) throws -> NSBitmapImageRep {
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        draw(context)
        return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    }
    private func drawingRecord(path: [Int]) -> RectangleMarkupRecord {
        var record = RectangleMarkupRecord(id: RectangleMarkupRecord.prefix + "drawing-test", pageIndex: 0,
            bounds: CGRect(x: 9,y: 9,width: 32,height: 32), red: 0, green: 0, blue: 0, lineWidth: 1)
        record.strokeOpacity = 0; record.nativeDrawing = .init(path: path, originalLayers: [0]); record.pdfLayerIndex = 1
        return record
    }
    func testOriginalPathMovesOutOfOldLayerAndDeletionRestoresItAfterSave() throws {
        let source = ReviewPDFLayerFixture.data(), record = drawingRecord(path: [0])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = directory.appendingPathComponent("saved.pdf"), restored = directory.appendingPathComponent("restored.pdf")
        try SharedReviewPDFExport.write(basePDF: source, records: [record], to: saved)
        XCTAssertTrue(try Data(contentsOf: saved).starts(with: source), "Original vector streams remain byte-identical in the incremental prefix")
        let oldHidden = try NativePDFLayerMutation.transform(source: saved, registryIndex: 0, operation: .visibility(false))
        let document = try XCTUnwrap(PDFDocument(url: oldHidden.url)), page = try XCTUnwrap(document.page(at: 0))
        let image = try pixels { page.draw(with: .cropBox, to: $0) }
        XCTAssertLessThan(try XCTUnwrap(image.colorAt(x:25,y:75)?.usingColorSpace(.deviceRGB)).redComponent, 0.05, "The moved path must no longer depend on its original layer")
        try SharedReviewPDFExport.write(basePDF: Data(contentsOf: saved), records: [], to: restored)
        let targetHidden = try NativePDFLayerMutation.transform(source: restored, registryIndex: 1, operation: .visibility(false))
        let restoredDocument = try XCTUnwrap(PDFDocument(url: targetHidden.url))
        let restoredPage = try XCTUnwrap(restoredDocument.page(at:0))
        let restoredImage = try pixels { restoredPage.draw(with: .cropBox, to:$0) }
        XCTAssertLessThan(try XCTUnwrap(restoredImage.colorAt(x:25,y:75)?.usingColorSpace(.deviceRGB)).redComponent, 0.05)
        XCTAssertGreaterThan(try XCTUnwrap(restoredImage.colorAt(x:70,y:30)?.usingColorSpace(.deviceRGB)).redComponent, 0.95)
    }
    func testOriginalPathInSharedFormMovesOnlySelectedInvocation() throws {
        let source = ReviewPDFLayerFixture.forms(), original = try XCTUnwrap(PDFDocument(data:source)), originalPage = try XCTUnwrap(original.page(at:0))
        let index = PDFPathScanner.index(page: try XCTUnwrap(originalPage.pageRef))
        XCTAssertEqual(index.nativeSelection(at: CGPoint(x:10,y:15), tolerance:2)?.path, [0,0])
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at:saved) }
        try SharedReviewPDFExport.write(basePDF:source,records:[drawingRecord(path:[0,0])],to:saved)
        let hidden = try NativePDFLayerMutation.transform(source:saved,registryIndex:0,operation:.visibility(false))
        if let root = ProcessInfo.processInfo.environment["DRAWBRIDGE_NATIVE_DRAWING_ARTIFACTS"] {
            let directory = URL(fileURLWithPath: root); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(contentsOf: saved).write(to: directory.appendingPathComponent("shared-form.pdf"))
            try Data(contentsOf: hidden.url).write(to: directory.appendingPathComponent("shared-form-old-hidden.pdf"))
        }
        let display = try XCTUnwrap(NativeDrawingLayerPatch.displayCopy(source:hidden.url,hiddenIndices:[0]))
        let document = try XCTUnwrap(PDFDocument(url:display.url)), page = try XCTUnwrap(document.page(at:0))
        let image = try pixels { page.draw(with:.cropBox,to:$0) }
        XCTAssertLessThan(try XCTUnwrap(image.colorAt(x:15,y:85)?.usingColorSpace(.deviceRGB)).redComponent,0.05)
        XCTAssertGreaterThan(try XCTUnwrap(image.colorAt(x:24,y:85)?.usingColorSpace(.deviceRGB)).redComponent,0.95)
        XCTAssertGreaterThan(try XCTUnwrap(image.colorAt(x:65,y:35)?.usingColorSpace(.deviceRGB)).redComponent,0.95)
    }
    func testExistingDuplicateLayersAssignmentUndoAndNativeSave() throws {
        _ = NSApplication.shared
        let bytes = ReviewPDFLayerFixture.data(), document = try XCTUnwrap(PDFDocument(data: bytes))
        let page = try XCTUnwrap(document.page(at: 0))
        let view = MarkupPDFView(); view.setMarkupDocument(document)
        let session = view.rectangleMarkup; session.bind(to: document); session.canEdit = { true }; session.canManageLayers = { false }
        session.undo.groupsByEvent = false
        session.undo.beginUndoGrouping()
        let snapshot = try XCTUnwrap(session.pasteSnapshot(SnapshotPayload(data: bytes), on: page, center: CGPoint(x: 50, y: 50)))
        session.undo.endUndoGrouping()
        let menu = session.layerAssignmentMenu(for: [snapshot])
        XCTAssertEqual(menu.items.filter { $0.title == "Duplicate (PDF)" }.count, 2)
        XCTAssertFalse(menu.items.contains { $0.title == "New Layer…" })
        XCTAssertTrue(session.canAssignLayer(snapshot))
        session.assignPDFLayer(1, to: [snapshot])
        XCTAssertEqual(MarkupLayers.pdfIndex(snapshot), 1)
        session.undo.undo(); XCTAssertNil(MarkupLayers.pdfIndex(snapshot))
        session.undo.redo(); XCTAssertEqual(MarkupLayers.pdfIndex(snapshot), 1)
        let record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: snapshot, pageIndex: 0))
        XCTAssertEqual(record.pdfLayerIndex, 1); XCTAssertTrue(record.isValid)
        let wire = try JSONDecoder().decode(RectangleMarkupRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(wire.pdfLayerIndex, 1)
        session.layerState?.pdfVisibility[1] = false; session.applyLayerVisibility()
        XCTAssertFalse(snapshot.shouldDisplay)
        session.layerState?.pdfVisibility[1] = true; session.applyLayerVisibility()
        XCTAssertTrue(snapshot.shouldDisplay)
        snapshot.isReadOnly = true
        session.assignPDFLayer(0, to: [snapshot]); XCTAssertEqual(MarkupLayers.pdfIndex(snapshot), 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try SharedReviewPDFExport.write(basePDF: bytes, records: [wire], to: url)
        let saved = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(EmbeddedPDFLayers.read(saved).map(\.name), ["Duplicate", "Duplicate"])
        let annotation = try XCTUnwrap(saved.page(at: 0)?.annotations.first(where: RectangleMarkupRecord.owns))
        XCTAssertEqual(MarkupLayers.pdfIndex(annotation), 1)
        XCTAssertNotNil(annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/OC")))
        let reopenedView = MarkupPDFView(); reopenedView.setMarkupDocument(saved); reopenedView.rectangleMarkup.bind(to:saved)
        let reopened = try XCTUnwrap(saved.page(at:0)?.annotations.first(where:RectangleMarkupRecord.owns))
        XCTAssertEqual(MarkupLayers.pdfIndex(reopened),1,"Reconstructing a saved Snapshot must retain its native layer")
        let unassigned = try XCTUnwrap(record.clipboardAnnotation(contents: record.text, rotation: 0))
        XCTAssertEqual(MarkupLayers.pdfIndex(unassigned), 1, "Review reconstruction preserves native membership")
    }
    func testNativePresentationChangesOnlyHiddenBaseDrawingAndKeepsLiveMarkup() throws {
        let bytes = ReviewPDFLayerFixture.data(), document = try XCTUnwrap(PDFDocument(data: bytes))
        let page = try XCTUnwrap(document.page(at: 0))
        let annotation = PDFAnnotation(bounds: CGRect(x: 45, y: 10, width: 10, height: 10), forType: .square, withProperties: nil)
        annotation.color = .red; annotation.interiorColor = .red; page.addAnnotation(annotation)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try bytes.write(to: source); defer { try? FileManager.default.removeItem(at: source) }
        let output = try NativePDFLayerMutation.transform(source: source, registryIndex: 0, operation: .visibility(false))
        let filtered = try XCTUnwrap(PDFDocument(data: Data(contentsOf: output.url)))
        let presentation = ReviewLayerPresentation(); presentation.install(filtered, for: document)
        let image = try pixels { presentation.draw(page, to: $0) }
        // Bitmap rows run from the top, page coordinates from the bottom.
        let hidden = try XCTUnwrap(image.colorAt(x: 25, y: 75)?.usingColorSpace(.deviceRGB))
        let retained = try XCTUnwrap(image.colorAt(x: 70, y: 30)?.usingColorSpace(.deviceRGB))
        let red = try XCTUnwrap(image.colorAt(x: 50, y: 85)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(hidden.redComponent, 0.95)
        XCTAssertLessThan(retained.redComponent, 0.05)
        XCTAssertGreaterThan(red.redComponent, 0.95); XCTAssertLessThan(red.greenComponent, 0.05)
        XCTAssertTrue(page.document === document); XCTAssertTrue(page.annotations.first === annotation)
    }
    func testDefaultDrawingMatchesPDFPageAcrossRotations() throws {
        let document = try XCTUnwrap(PDFDocument(data: ReviewPDFLayerFixture.data())), page = try XCTUnwrap(document.page(at: 0))
        let presentation = ReviewLayerPresentation()
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let expected = try pixels { page.draw(with: .cropBox, to: $0) }
            let actual = try pixels { presentation.draw(page, to: $0) }
            XCTAssertEqual(actual.tiffRepresentation, expected.tiffRepresentation)
        }
    }
    func testDerivedDrawingMatchesNonSquareCroppedRotatedPageWithLiveAnnotation() throws {
        for custom in [false,true] {
        let document = try XCTUnwrap(PDFDocument(data:ReviewPDFLayerFixture.data())), page = try XCTUnwrap(document.page(at:0))
        page.setBounds(CGRect(x:0,y:0,width:180,height:120),for:.mediaBox)
        page.setBounds(CGRect(x:15,y:10,width:140,height:80),for:.cropBox)
        let annotation: PDFAnnotation = custom
            ? DrawbridgeShapeAnnotation(bounds:CGRect(x:45,y:10,width:10,height:10),forType:.square,withProperties:nil)
            : PDFAnnotation(bounds:CGRect(x:45,y:10,width:10,height:10),forType:.square,withProperties:nil)
        annotation.color = .red; annotation.interiorColor = .red; page.addAnnotation(annotation)
        for rotation in [0,90,180,270] {
            page.rotation = rotation
            let source = try XCTUnwrap(PDFDocument(data:XCTUnwrap(document.dataRepresentation())))
            let presentation = ReviewLayerPresentation(); presentation.install(source,for:document)
            let expected = try pixels { page.draw(with:.cropBox,to:$0) }
            let actual = try pixels { presentation.draw(page,to:$0) }
            if let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_NATIVE_DRAWING_ARTIFACTS"] {
                let directory = URL(fileURLWithPath:path); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                try expected.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("crop-expected-\(rotation).png"))
                try actual.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("crop-actual-\(rotation).png"))
            }
            XCTAssertEqual(actual.tiffRepresentation,expected.tiffRepresentation,"rotation \(rotation)")
        }
        }
    }

    func testSnapshotCaptureUsesVisibleDerivedDrawingAndCurrentLiveAnnotations() throws {
        let bytes = ReviewPDFLayerFixture.data(), document = try XCTUnwrap(PDFDocument(data:bytes)), page = try XCTUnwrap(document.page(at:0))
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pdf")
        try bytes.write(to:source); defer { try? FileManager.default.removeItem(at:source) }
        let hidden = try NativePDFLayerMutation.transform(source:source,registryIndex:0,operation:.visibility(false))
        let filtered = try XCTUnwrap(NativeDrawingLayerPatch.displayCopy(source:hidden.url,hiddenIndices:[0]))
        let visible = try XCTUnwrap(PDFDocument(url:filtered.url)), visiblePage = try XCTUnwrap(visible.page(at:0))
        let live = PDFAnnotation(bounds:CGRect(x:45,y:10,width:10,height:10),forType:.square,withProperties:nil)
        live.color = .red; live.interiorColor = .red; page.addAnnotation(live)
        let payload = try SnapshotPayload.capture(page:page,points:[CGPoint(x:0,y:0),CGPoint(x:100,y:0),CGPoint(x:100,y:100),CGPoint(x:0,y:100)],drawingSource:visiblePage)
        let captured = try XCTUnwrap(payload.page)
        let image = try pixels { $0.drawPDFPage(captured) }
        XCTAssertGreaterThan(try XCTUnwrap(image.colorAt(x:25,y:75)?.usingColorSpace(.deviceRGB)).redComponent,0.95)
        XCTAssertLessThan(try XCTUnwrap(image.colorAt(x:70,y:30)?.usingColorSpace(.deviceRGB)).redComponent,0.05)
        XCTAssertLessThan(try XCTUnwrap(image.colorAt(x:50,y:85)?.usingColorSpace(.deviceRGB)).greenComponent,0.05)
    }

}
