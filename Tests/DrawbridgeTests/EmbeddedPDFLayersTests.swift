import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class EmbeddedPDFLayersTests: XCTestCase {
    // Literal native OCGs: duplicate names must remain distinct; an app-owned
    // OCG must not be duplicated in the embedded list.
    func fixture(base: String = "ON", off: String = "6 0 R") throws -> URL {
        let stream = "/OC /Walls BDC 0 0 0 rg 10 10 30 30 re f EMC\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R 7 0 R] /D << /BaseState /\(base) /OFF [\(off)] /Order [[(Architecture) 6 0 R 5 0 R]] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /Properties << /Walls 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream",
            "<< /Type /OCG /Name (A - Walls - Interior) >>",
            "<< /Type /OCG /Name (A - Walls - Interior) >>",
            "<< /Type /OCG /Name (Review) /DrawbridgeLayerID (owned) >>"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (i, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(i + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EmbeddedLayers-\(UUID()).pdf")
        try data.write(to: url); return url
    }
    func testNativeLayerNamesAppearAlongsideCustomLayersWithoutBecomingAssignable() throws {
        _ = NSApplication.shared
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let view = MarkupPDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        view.document = doc
        let session = view.rectangleMarkup; session.canEdit = { true }; session.bind(to: doc)
        session.undo.groupsByEvent = false; session.undo.beginUndoGrouping()
        _ = session.addLayer(named: "Review")
        session.undo.endUndoGrouping()
        let records = RectangleMarkupRecord.capture(doc)
        let panel = MarkupLayersView(); panel.session = session; panel.refresh()
        XCTAssertEqual(panel.numberOfRows(in: panel.table), 3, "Native drawing OCGs are missing from Layers")
        XCTAssertEqual(panel.active.itemTitles, ["Unassigned", "Review"], "Native content is not an annotation assignment target")
        let nameColumn = panel.table.tableColumns.first { $0.identifier.rawValue == "name" }
        for row in 1...2 {
            XCTAssertEqual((panel.tableView(panel.table, viewFor: nameColumn, row: row) as? NSTextField)?.stringValue, "A - Walls - Interior")
        }
        XCTAssertEqual(RectangleMarkupRecord.capture(doc), records, "Inspection must not manufacture catalog/membership edits")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testNativeRegistryIdentityDoesNotDependOnNameOrDefaultVisibility() throws {
        let url = try fixture(base: "OFF", off: "5 0 R 6 0 R")
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let layers = EmbeddedPDFLayers.read(doc)
        XCTAssertEqual(layers.map(\.registryIndex), [0, 1])
        XCTAssertEqual(layers.map(\.name), ["A - Walls - Interior", "A - Walls - Interior"])
        XCTAssertEqual(layers.map(\.visible), [false, false])
        XCTAssertEqual(EmbeddedPDFLayers.read(doc), layers)
        XCTAssertTrue(EmbeddedPDFLayers.read(nil).isEmpty)
    }
    func testReplacingDocumentClearsEmbeddedRowsAndDoesNotLeaveEnabledActions() throws {
        _ = NSApplication.shared
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let view = MarkupPDFView(frame: .zero); view.document = doc
        let session = view.rectangleMarkup; session.canEdit = { true }; session.bind(to: doc)
        let panel = MarkupLayersView(); panel.session = session; panel.refresh()
        XCTAssertEqual(panel.numberOfRows(in: panel.table), 2)
        panel.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let empty = PDFDocument(); view.document = empty; session.bind(to: empty); panel.refresh()
        XCTAssertEqual(panel.numberOfRows(in: panel.table), 0)
        XCTAssertTrue(EmbeddedPDFLayers.read(empty).isEmpty)
        XCTAssertEqual(panel.active.itemTitles, ["Unassigned"])
    }
    func testPrivatePurgeReloadKeepsRenderedArtworkOnEveryPreviouslyNonblankPage() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_PURGE_PRIVATE_FIXTURE"] else {
            throw XCTSkip("Private PDF render qualification opt-in")
        }
        _ = NSApplication.shared
        let originalURL = URL(fileURLWithPath: path)
        let originalBytes = try Data(contentsOf: originalURL)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmbeddedLayerRender-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("copy.pdf")
        try FileManager.default.copyItem(at: originalURL, to: copy)
        let controller = MainViewController(); _ = controller.view
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { window.contentViewController = nil }
        controller.openDocument(at: copy)
        let before = try XCTUnwrap(controller.pdfView.document)
        XCTAssertFalse(EmbeddedPDFLayers.read(before).isEmpty)
        func ink(_ page: PDFPage) throws -> Int {
            let image = page.thumbnail(of: CGSize(width: 192, height: 192), for: .cropBox)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.alphaComponent > 0.05 && min(color.redComponent, color.greenComponent, color.blueComponent) < 0.92 { count += 1 }
                }
            }
            return count
        }
        var beforeInk: [Int] = []
        for index in 0..<before.pageCount { beforeInk.append(try ink(try XCTUnwrap(before.page(at: index)))) }
        XCTAssertTrue(beforeInk.contains { $0 > 0 }, "Fixture must contain visible artwork")
        let lastPage = try XCTUnwrap(before.page(at: before.pageCount - 1))
        controller.pdfView.go(to: lastPage)
        let initialIndex = before.index(for: try XCTUnwrap(controller.pdfView.currentPage))
        var completed: Bool?
        controller.purgeLayersInPlace { completed = $0 }
        let deadline = Date().addingTimeInterval(240)
        while completed == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(completed, true, controller.lastPurgeErrorMessage ?? "Purge did not complete")
        let after = try XCTUnwrap(controller.pdfView.document)
        XCTAssertFalse(after === before, "In-place purge must replace the viewer document")
        XCTAssertEqual(after.pageCount, beforeInk.count)
        XCTAssertTrue(EmbeddedPDFLayers.read(after).isEmpty)
        XCTAssertEqual(after.index(for: try XCTUnwrap(controller.pdfView.currentPage)), initialIndex)
        var checked = 0
        for index in 0..<min(after.pageCount, beforeInk.count) {
            let afterInk = try ink(try XCTUnwrap(after.page(at: index)))
            if beforeInk[index] > 0 {
                XCTAssertGreaterThan(afterInk, 0, "Previously visible artwork became blank on page \(index + 1)")
                checked += 1
            }
        }
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes, "Read-only qualification fixture changed")
        print("PRIVATE RENDER QUALIFICATION pages=\(after.pageCount) previouslyNonblank=\(checked) thumbnail=192x192; not pixel-equivalence or live-window qualification")
    }

    func testEmbeddedNoticeWarnsThatPurgeAndSaveReplacesTheOpenPDF() throws {
        _ = NSApplication.shared
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let view = MarkupPDFView(frame: .zero); view.document = doc
        let session = view.rectangleMarkup; session.canEdit = { true }; session.bind(to: doc)
        let panel = MarkupLayersView(); panel.session = session; panel.refresh()
        let notice = try XCTUnwrap(panel.arrangedSubviews.compactMap { $0 as? NSTextField }.first {
            $0.stringValue.contains("Embedded PDF drawing layers")
        })
        XCTAssertFalse(notice.isHidden)
        XCTAssertTrue(notice.stringValue.contains("replaces the open PDF"), "Do not promise a separate copy for the in-place purge command")
        XCTAssertFalse(notice.stringValue.contains("create a separate copy"))
    }

    func testNativeRowsRequireHostHooksAndNeverOfferAnnotationRenameOrLock() throws {
        _ = NSApplication.shared
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let view = MarkupPDFView(frame: .zero); view.document = doc
        let session = view.rectangleMarkup; session.canEdit = { true }; session.bind(to: doc)
        let panel = MarkupLayersView(); panel.session = session; panel.refresh()
        XCTAssertEqual(panel.numberOfRows(in: panel.table), 2)
        for columnID in ["visible", "locked"] {
            let column = panel.table.tableColumns.first { $0.identifier.rawValue == columnID }
            let button = try XCTUnwrap(panel.tableView(panel.table, viewFor: column, row: 0) as? NSButton)
            XCTAssertFalse(button.isEnabled, "Host snapshot/adoption hooks are required for native edits")
            XCTAssertEqual(button.state, columnID == "visible" ? .on : .mixed)
        }
        panel.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let buttons = panel.arrangedSubviews.compactMap { $0 as? NSStackView }.flatMap(\.arrangedSubviews).compactMap { $0 as? NSButton }
        XCTAssertFalse(try XCTUnwrap(buttons.first { $0.title == "Delete Content…" }).isEnabled)
        XCTAssertFalse(try XCTUnwrap(buttons.first { $0.title == "Rename" }).isEnabled)
        XCTAssertTrue(session.layerCatalog.layers.isEmpty)
        XCTAssertFalse(session.undo.canUndo)
    }
}
