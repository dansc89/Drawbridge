import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class ImportedMarkupTests: XCTestCase {
    func testImportedDeleteMoveSaveUndoAndPageDeletion() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("external.pdf")
        if let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_IMPORTED_PDF"] {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: source)
        } else {
            var box = CGRect(x: 0, y: 0, width: 600, height: 800)
            let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &box, nil))
            for _ in 0..<3 { context.beginPDFPage(nil); context.setFillColor(NSColor.white.cgColor); context.fill(box); context.endPDFPage() }
            context.closePDF()
            let document = try XCTUnwrap(PDFDocument(url: source))
            let page = document.page(at: 0)!
            for (i, type) in [PDFAnnotationSubtype.freeText, .ink, .line, .square].enumerated() {
                let annotation = PDFAnnotation(bounds: CGRect(x: 60, y: 50 + i * 100, width: 180, height: 60), forType: type, withProperties: nil)
                annotation.userName = "External author"; annotation.contents = "External markup"
                annotation.setValue("external-\(i)", forAnnotationKey: PDFAnnotationKey(rawValue: "/NM"))
                annotation.setValue("Keep this metadata", forAnnotationKey: PDFAnnotationKey(rawValue: "/ExternalPrivateData"))
                if type == .ink { let p = NSBezierPath(); p.move(to: .zero); p.line(to: CGPoint(x: 170, y: 55)); annotation.add(p) }
                if type == .line { annotation.startPoint = CGPoint(x: 5, y: 5); annotation.endPoint = CGPoint(x: 170, y: 55) }
                page.addAnnotation(annotation)
            }
            XCTAssertTrue(document.write(to: source))
        }
        let original = try Data(contentsOf: source)
        let controller = MainViewController(); _ = controller.view
        controller.openDocument(at: source)
        let document = try XCTUnwrap(controller.pdfView.document)
        let page = try XCTUnwrap(document.page(at: 0))
        let session = controller.pdfView.rectangleMarkup; session.canEdit = { true }; session.undo.groupsByEvent = false
        let external = page.annotations.filter { ImportedMarkupState.selectable($0) && !RectangleMarkupRecord.owns($0) }
        XCTAssertGreaterThanOrEqual(external.count, 4)
        let text = try XCTUnwrap(external.first { $0.type == "FreeText" })
        let ink = try XCTUnwrap(external.first { $0.type == "Ink" })
        let originalCount = page.annotations.count
        let originalRotation = page.rotation
        let originalPageBounds = page.bounds(for: .mediaBox)
        let originalBounds = text.bounds
        let identifier = text.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NM")) as? String
        session.undo.beginUndoGrouping()
        session.setBounds(text.bounds.offsetBy(dx: 20, dy: 30), of: text, on: page, action: "Move Markup")
        session.undo.endUndoGrouping()
        var firstPoint = [CGPoint](repeating: .zero, count: 3)
        _ = try XCTUnwrap(ink.paths?.first).element(at: 0, associatedPoints: &firstPoint)
        let point = CGPoint(x: ink.bounds.minX + firstPoint[0].x, y: ink.bounds.minY + firstPoint[0].y)
        controller.pdfView.go(to: page)
        controller.pdfView.layoutSubtreeIfNeeded()
        XCTAssertTrue(session.pointerDown(at: controller.pdfView.convert(point, from: page)))
        XCTAssertTrue(session.selected === ink)
        session.undo.beginUndoGrouping(); session.deleteSelected(); session.undo.endUndoGrouping()
        XCTAssertEqual(page.rotation, originalRotation)
        XCTAssertEqual(page.bounds(for: .mediaBox), originalPageBounds)
        XCTAssertEqual(page.annotations.count, originalCount - 1)
        func save() async throws -> PDFDocument {
            let started = Date()
            let success = await withCheckedContinuation { continuation in
                controller.persistDocument(to: source, adoptAsPrimaryDocument: false, busyMessage: "Saving", showBusyOverlay: false) { continuation.resume(returning: $0) }
            }
            print("IMPORTED SAVE pages=\(document.pageCount) seconds=\(Date().timeIntervalSince(started))")
            XCTAssertTrue(success)
            return try XCTUnwrap(PDFDocument(url: source))
        }
        var reopened = try await save()
        XCTAssertEqual(try Data(contentsOf: source).prefix(original.count), original)
        XCTAssertEqual(reopened.page(at: 0)?.annotations.count, originalCount - 1)
        let savedText = try XCTUnwrap(reopened.page(at: 0)?.annotations.first { $0.type == "FreeText" && ($0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NM")) as? String) == identifier })
        XCTAssertEqual(savedText.bounds.minX, originalBounds.minX + 20, accuracy: 0.0001)
        XCTAssertEqual(savedText.bounds.minY, originalBounds.minY + 30, accuracy: 0.0001)
        session.undo.undo(); session.undo.undo()
        reopened = try await save()
        XCTAssertEqual(reopened.page(at: 0)?.annotations.count, originalCount)
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first { $0.type == "FreeText" }?.bounds, originalBounds)
        session.undo.redo(); session.undo.redo()
        reopened = try await save()
        XCTAssertEqual(reopened.page(at: 0)?.annotations.count, originalCount - 1)
        // A structural save rebuilds from opening pages; it must not resurrect a
        // deleted external markup or lose its translation.
        try controller.deletePages(at: IndexSet(integer: document.pageCount - 1))
        reopened = try await save()
        XCTAssertEqual(reopened.pageCount, document.pageCount)
        XCTAssertEqual(reopened.page(at: 0)?.annotations.filter { ImportedMarkupState.selectable($0) }.count, external.count - 1)
        // Save again after qpdf renumbered the selected pages.
        reopened = try await save()
        XCTAssertEqual(reopened.page(at: 0)?.annotations.filter { ImportedMarkupState.selectable($0) }.count, external.count - 1)
    }

    func testExcludesHelpersFormsAndLockedAnnotations() {
        let annotation = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 20, height: 20), forType: .square, withProperties: nil)
        XCTAssertTrue(ImportedMarkupState.selectable(annotation))
        annotation.isReadOnly = true
        XCTAssertFalse(ImportedMarkupState.selectable(annotation))
        for type in [PDFAnnotationSubtype.link, .widget, .popup] {
            XCTAssertFalse(ImportedMarkupState.selectable(PDFAnnotation(bounds: annotation.bounds, forType: type, withProperties: nil)))
        }
    }
}
