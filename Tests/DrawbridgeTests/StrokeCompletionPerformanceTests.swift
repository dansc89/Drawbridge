import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

private final class StrokeCountingPage: PDFPage {
    var annotationReads = 0
    override var annotations: [PDFAnnotation] {
        annotationReads += 1
        return super.annotations
    }
}

@MainActor final class StrokeCompletionPerformanceTests: XCTestCase {
    func testSavedInkDeletionUsesAppearanceCleanupEvenWhenAPDictionaryIsOpaque() throws {
        _ = NSApplication.shared
        let source = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x:0,y:0,width:400,height:300),for:.mediaBox)
        source.insert(page,at:0)
        let ink = PDFAnnotation(bounds:CGRect(x:20,y:20,width:100,height:100),forType:.ink,withProperties:nil)
        ink.setValue(RectangleMarkupRecord.prefix+UUID().uuidString,forAnnotationKey:RectangleMarkupRecord.identityKey)
        let path = NSBezierPath(); path.move(to:CGPoint(x:5,y:5)); path.line(to:CGPoint(x:75,y:75)); ink.add(path)
        page.addAnnotation(ink)
        let document = try XCTUnwrap(PDFDocument(data:XCTUnwrap(source.dataRepresentation())))
        let savedPage = try XCTUnwrap(document.page(at:0))
        let view = MarkupPDFView(frame:CGRect(x:0,y:0,width:800,height:600)); view.setMarkupDocument(document)
        let savedInk = try XCTUnwrap(savedPage.annotations.first)
        XCTAssertTrue(savedInk.hasAppearanceStream,"The fixture must exercise a saved appearance")
        let session = view.rectangleMarkup; session.canEdit = { true }; session.setSelectedItems([savedInk])
        var cleanup: Bool?
        view.annotationRefreshObserver = { _, imported, _, _ in cleanup = imported }
        session.deleteSelected()
        XCTAssertNil(savedInk.page)
        XCTAssertEqual(cleanup,true,"Opaque saved APs must not use the live-annotation shortcut")
    }
    func testNativeLineInsertionAndUndoUseBoundedAnnotationRefresh() throws {
        _ = NSApplication.shared
        let document = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x:0,y:0,width:1000,height:1000),for:.mediaBox)
        document.insert(page,at:0)
        let view = MarkupPDFView(frame:CGRect(x:0,y:0,width:800,height:600))
        view.document = document
        let session = view.rectangleMarkup; session.bind(to:document)
        var requests: [(Bool,CGRect?,MarkupPDFView.AnnotationRefreshReason)] = []
        view.annotationRefreshObserver = { _, imported, region, reason in requests.append((imported,region,reason)) }
        session.undo.beginUndoGrouping()
        let annotation = try XCTUnwrap(session.create(on:page,bounds:CGRect(x:18,y:18,width:74,height:64),kind:.line,endpoints:(CGPoint(x:20,y:20),CGPoint(x:90,y:80))))
        session.undo.endUndoGrouping()
        XCTAssertEqual(requests.count,1)
        XCTAssertFalse(try XCTUnwrap(requests.last).0)
        XCTAssertEqual(requests.last?.2,.nativeMarkupChanged)
        let region = try XCTUnwrap(requests.last?.1)
        XCTAssertTrue(region.contains(annotation.bounds))
        XCTAssertLessThan(region.width, page.bounds(for:.mediaBox).width)
        session.undo.undo()
        XCTAssertFalse(try XCTUnwrap(requests.last).0)
        XCTAssertEqual(requests.last?.2,.nativeMarkupChanged)
        XCTAssertNil(annotation.page)
        session.undo.redo()
        XCTAssertTrue(annotation.page === page)
        XCTAssertFalse(try XCTUnwrap(requests.last).0)
        XCTAssertEqual(requests.last?.2,.nativeMarkupChanged)
    }
    func testRepeatedLineCompletionBenchmark() throws {
        guard ProcessInfo.processInfo.environment["DRAWBRIDGE_STROKE_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in multi-page stroke completion timing")
        }
        _ = NSApplication.shared
        let document = PDFDocument()
        let pages = (0..<20).map { _ in StrokeCountingPage() }
        for (index,page) in pages.enumerated() {
            page.setBounds(CGRect(x:0,y:0,width:400,height:300),for:.mediaBox)
            document.insert(page,at:index)
        }
        let view = MarkupPDFView(frame:CGRect(x:0,y:0,width:800,height:600))
        view.document = document
        let session = view.rectangleMarkup
        session.bind(to:document)
        let layer = try XCTUnwrap(session.addLayer(named:"Drawing"))
        session.layerState?.catalog.activeID = layer
        for page in pages {
            for index in 0..<300 {
                let annotation = PDFAnnotation(bounds:CGRect(x:index % 200,y:index % 150,width:8,height:6),forType:.square,withProperties:nil)
                annotation.setValue(layer,forAnnotationKey:MarkupLayers.membershipKey)
                page.addAnnotation(annotation)
            }
        }
        view.go(to:pages[0])
        for page in pages { page.annotationReads = 0 }
        var samples: [Double] = []
        for _ in 0..<12 {
            session.tool = .line
            let begin = CFAbsoluteTimeGetCurrent()
            session.undo.beginUndoGrouping()
            XCTAssertNotNil(session.create(on:pages[0],bounds:CGRect(x:18,y:18,width:74,height:64),kind:.line,endpoints:(CGPoint(x:20,y:20),CGPoint(x:90,y:80))))
            session.undo.endUndoGrouping()
            samples.append((CFAbsoluteTimeGetCurrent()-begin)*1000)
        }
        let offPageReads = pages.dropFirst().reduce(0) { $0 + $1.annotationReads }
        XCTAssertEqual(offPageReads,0,"Completing a stroke must not traverse other pages' annotations")
        print("STROKE_COMPLETION pages=20 existing=6000 samplesMs=\(samples) offPageReads=\(offPageReads)")
    }
}
