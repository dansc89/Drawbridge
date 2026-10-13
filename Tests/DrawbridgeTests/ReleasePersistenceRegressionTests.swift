import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class ReleasePersistenceRegressionTests: XCTestCase {
    private func fixture(_ url: URL, pages: Int = 1, markups: Bool = false, color: NSColor = .white) throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 500, height: 500)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil); context.setFillColor(color.cgColor); context.fill(box); context.endPDFPage()
        }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        if markups {
            for index in 0..<pages {
                for text in ["row-\(index)", "DrawbridgeMeasure|\(72 + index)"] {
                    let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 50, height: 50), forType: .square, withProperties: nil)
                    annotation.contents = text
                    document.page(at: index)?.addAnnotation(annotation)
                }
            }
        }
        XCTAssertTrue(document.write(to: url))
    }

    private func directory() throws -> URL {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReleasePersistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testSaveBeforeInitialIndexTimerResumesCompleteRowsAndTotals() throws {
        try checkInterruptedIndex(duringScan: false, fail: false)
    }
    func testFailedSaveBeforeInitialIndexTimerResumesCompleteRowsAndTotals() throws {
        try checkInterruptedIndex(duringScan: false, fail: true)
    }
    func testSaveDuringInitialScanResumesCompleteRowsAndTotals() throws {
        try checkInterruptedIndex(duringScan: true, fail: false)
    }
    func testFailedSaveDuringInitialScanResumesCompleteRowsAndTotals() throws {
        try checkInterruptedIndex(duringScan: true, fail: true)
    }

    func testFailedSaveAsBeforeInitialIndexTimerResumesCompleteRowsAndTotals() throws {
        try checkInterruptedIndex(duringScan: false, fail: true, adopt: true)
    }
    func testFailedSaveAsDuringInitialScanResumesCompleteRowsAndTotals() throws {
        try checkInterruptedIndex(duringScan: true, fail: true, adopt: true)
    }

    private func checkInterruptedIndex(duringScan: Bool, fail: Bool, adopt: Bool = false) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.pdf")
        try fixture(source, pages: 65, markups: true)
        let controller = MainViewController(); _ = controller.view
        defer { controller.onMarkupPageIndexed = nil; controller.clearToStartState() }
        var indexed: [Int] = []
        controller.onMarkupPageIndexed = { _, index in indexed.append(index) }
        controller.openDocument(at: source)
        if duringScan {
            controller.pendingMarkupsRefreshWorkItem?.cancel(); controller.pendingMarkupsRefreshWorkItem = nil
            controller.performRefreshMarkups(selecting: nil)
            XCTAssertGreaterThan(indexed.count, 0)
            XCTAssertLessThan(indexed.count, 65)
        } else {
            XCTAssertTrue(indexed.isEmpty)
        }
        var errors: [String] = []
        let presentError: (String) -> NSApplication.ModalResponse = {
            errors.append($0)
            return .alertSecondButtonReturn
        }
        controller.saveErrorPresenter = presentError
        var result: Bool?
        let target = fail ? dir.appendingPathComponent("missing/output.pdf") : source
        controller.persistDocument(to: target, adoptAsPrimaryDocument: adopt, busyMessage: "Saving…", showBusyOverlay: false) { result = $0 }
        pump(until: { result != nil })
        XCTAssertEqual(result, !fail, errors.joined(separator: "\n"))
        pump(until: { controller.markupItems.count == 130 })
        XCTAssertEqual(controller.markupItems.count, 130, "Save must resume interrupted opening index even on failure")
        XCTAssertEqual(controller.markupsTable.numberOfRows, 130)
        XCTAssertEqual(controller.totalCachedAnnotationCount(), 130)
        XCTAssertEqual(controller.markupsCountLabel.stringValue, "130 markups")
        XCTAssertEqual(controller.indexedMeasurementSummary.count, 65)
        XCTAssertEqual(controller.indexedMeasurementSummary.totalPoints, CGFloat((0..<65).reduce(0) { $0 + 72 + $1 }))
        XCTAssertEqual(indexed, Array(0..<65), "Only unfinished pages should be scanned")
        XCTAssertEqual(controller.markupItems.map(\.pageIndex), (0..<65).flatMap { [$0, $0] })
        let before = indexed.count
        for fullyIndexedSaveFails in [false, true] {
            result = nil
            let fullyIndexedTarget = fullyIndexedSaveFails ? dir.appendingPathComponent("missing/output.pdf") : source
            controller.persistDocument(to: fullyIndexedTarget, adoptAsPrimaryDocument: false, busyMessage: "Saving…", showBusyOverlay: false) { result = $0 }
            pump(until: { result != nil })
            XCTAssertEqual(result, !fullyIndexedSaveFails, errors.joined(separator: "\n"))
            XCTAssertNil(controller.pendingMarkupsRefreshWorkItem, "A fully indexed save must not schedule another index")
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            XCTAssertEqual(indexed.count, before, "A fully indexed document must not be rescanned on save success or failure")
        }
    }

    func testNavigationOnlyRejectsSamePageCountExternalReplacementWithoutTouchingFiles() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.pdf"), output = dir.appendingPathComponent("output.pdf")
        try fixture(source)
        let document = try XCTUnwrap(PDFDocument(url: source))
        let stamp = try XCTUnwrap(PDFMarkupSourceStamp.capture(source))
        try fixture(output, color: .blue)
        let destinationBefore = try Data(contentsOf: output)
        try fixture(source, color: .red)
        let sourceBefore = try Data(contentsOf: source)
        XCTAssertEqual(document.pageCount, PDFDocument(url: source)?.pageCount)
        for target in [output, source] {
            var failure: PDFRectangleWriter.SaveFailure?
            XCTAssertFalse(MainViewController.writePDFDocument(document, to: target, pageLabels: [0: "Edited"], navigationSourceURL: source, rectangleSourceStamp: stamp, onMarkupSaveFailure: { failure = $0 }))
            XCTAssertTrue(failure?.isSourceConflict == true, "Navigation must surface the existing recovery flow")
            XCTAssertEqual(try Data(contentsOf: source), sourceBefore)
            XCTAssertEqual(try Data(contentsOf: output), destinationBefore)
        }
    }

    func testNavigationOnlyMissingSourceDoesNotFallBackToPDFKit() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.pdf"), output = dir.appendingPathComponent("output.pdf")
        try fixture(source)
        let document = try XCTUnwrap(PDFDocument(url: source))
        let stamp = try XCTUnwrap(PDFMarkupSourceStamp.capture(source))
        try fixture(output, color: .blue)
        let destinationBefore = try Data(contentsOf: output)
        try FileManager.default.removeItem(at: source)
        var failures: [PDFRectangleWriter.SaveFailure] = []
        XCTAssertFalse(MainViewController.writePDFDocument(document, to: output, pageLabels: [:], navigationSourceURL: source, rectangleSourceStamp: stamp, onMarkupSaveFailure: { failures.append($0) }))
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.first?.isSourceConflict == true)
        XCTAssertEqual(try Data(contentsOf: output), destinationBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testNavigationOnlyAcceptsExpectedStampAndRecoverySnapshot() throws {
        guard PDFTKBookmarkWriter.executableURL() != nil else { throw XCTSkip("qpdf required") }
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.pdf"), output = dir.appendingPathComponent("output.pdf")
        try fixture(source)
        let document = try XCTUnwrap(PDFDocument(url: source))
        let stamp = try XCTUnwrap(PDFMarkupSourceStamp.capture(source))
        let root = PDFOutline(), child = PDFOutline(); child.label = "Edited navigation"
        child.destination = PDFDestination(page: try XCTUnwrap(document.page(at: 0)), at: .zero)
        root.insertChild(child, at: 0); document.outlineRoot = root
        XCTAssertTrue(MainViewController.writePDFDocument(document, to: output, pageLabels: [:], navigationSourceURL: source, rectangleSourceStamp: stamp))
        XCTAssertEqual(PDFDocument(url: output)?.outlineRoot?.child(at: 0)?.label, "Edited navigation")
        try fixture(source, color: .red)
        let frozen = try XCTUnwrap(stamp.recoverySourceURL)
        let recoveryStamp = try XCTUnwrap(PDFMarkupSourceStamp.capture(frozen))
        XCTAssertTrue(MainViewController.writePDFDocument(document, to: output, pageLabels: [:], navigationSourceURL: frozen, rectangleSourceStamp: recoveryStamp))
        XCTAssertEqual(PDFDocument(url: output)?.outlineRoot?.child(at: 0)?.label, "Edited navigation")
    }

    func testNavigationRecoveryUnavailableHelperPathRejectsChangedPDFKitBacking() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.pdf"), output = dir.appendingPathComponent("output.pdf")
        try fixture(source)
        let document = try XCTUnwrap(PDFDocument(url: source))
        let originalStamp = try XCTUnwrap(PDFMarkupSourceStamp.capture(source))
        let frozen = try XCTUnwrap(originalStamp.recoverySourceURL)
        let recoveryStamp = try XCTUnwrap(PDFMarkupSourceStamp.capture(frozen))
        try fixture(source, color: .red)
        try fixture(output, color: .blue)
        let destinationBefore = try Data(contentsOf: output)
        // A mismatched snapshot deterministically makes navigation serialization
        // unavailable, exercising the same fallback as a missing helper.
        let mismatched = PDFDocument(); mismatched.insert(PDFPage(), at: 0); mismatched.insert(PDFPage(), at: 1)
        var failure: PDFRectangleWriter.SaveFailure?
        XCTAssertFalse(MainViewController.writePDFDocument(document, to: output, pageLabels: [:], navigationSourceURL: frozen, rectangleSourceStamp: recoveryStamp, navigationSnapshot: PDFTKBookmarkWriter.captureNavigation(in: mismatched), onMarkupSaveFailure: { failure = $0 }))
        XCTAssertTrue(failure?.isSourceConflict == true, "Recovery must not serialize the changed original PDFKit backing")
        XCTAssertEqual(try Data(contentsOf: output), destinationBefore)
    }

    func testFrozenNavigationUnavailableDoesNotSerializeLiveDocument() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.pdf"), output = dir.appendingPathComponent("output.pdf")
        try fixture(source)
        try fixture(output, color: .blue)
        let before = try Data(contentsOf: output)
        let document = try XCTUnwrap(PDFDocument(url: source))
        let stamp = try XCTUnwrap(PDFMarkupSourceStamp.capture(source))
        let capturedDocument = PDFDocument()
        capturedDocument.insert(PDFPage(), at: 0)
        capturedDocument.insert(PDFPage(), at: 1)
        // Page-count mismatch deterministically rejects helper serialization.
        let captured = PDFTKBookmarkWriter.captureNavigation(in: capturedDocument)
        let root = PDFOutline(), child = PDFOutline()
        child.label = "Live edit after capture"
        child.destination = PDFDestination(page: try XCTUnwrap(document.page(at: 0)), at: .zero)
        root.insertChild(child, at: 0); document.outlineRoot = root
        XCTAssertFalse(MainViewController.writePDFDocument(document, to: output, pageLabels: [:], navigationSourceURL: source, rectangleSourceStamp: stamp, navigationSnapshot: captured), "Unavailable frozen save must not fall back to serializing live edits")
        XCTAssertEqual(try Data(contentsOf: output), before)
        XCTAssertEqual(document.outlineRoot?.child(at: 0)?.label, "Live edit after capture")
    }

    func testStackingUndoReplacesRetiredTilesAtUnchangedBounds() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.pdf"); try fixture(source)
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        let fragment = dir.appendingPathComponent("red.pdf"); try fixture(fragment, color: .red)
        let stamp = try XCTUnwrap(SnapshotStampFactory.make(payload: SnapshotPayload(data: try Data(contentsOf: fragment)), bounds: CGRect(x: 150, y: 150, width: 200, height: 200), rotation: 0) as? DrawbridgeSnapshotAnnotation)
        let above = PDFAnnotation(bounds: stamp.bounds, forType: .square, withProperties: nil)
        above.color = .blue; above.interiorColor = .blue
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = MarkupPDFView(frame: window.contentView!.bounds); window.contentView?.addSubview(view)
        view.setMarkupDocument(document); page.addAnnotation(stamp); page.addAnnotation(above)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        view.autoScales = false; view.maxScaleFactor = 64; view.scaleFactor = 24
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded(); view.revealMarkup(stamp)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1)); view.updateSnapshotViewportTiles()
        let originals = page.annotations
        let oldTiles = originals.compactMap { $0 as? SnapshotViewportTileAnnotation }
        XCTAssertFalse(oldTiles.isEmpty)
        let session = view.rectangleMarkup
        session.undo.removeAllActions(); session.setSelectedItems([stamp])
        func clipView(in node: NSView) -> NSClipView? {
            if let clip = node as? NSClipView { return clip }
            return node.subviews.lazy.compactMap { clipView(in: $0) }.first
        }
        let clip = try XCTUnwrap(clipView(in: view))
        let viewportOrigin = clip.bounds.origin
        session.undo.beginUndoGrouping(); session.reorderSelected(toFront: true); session.undo.endUndoGrouping()
        // Reordering preserves tiles. A real zoom below the tiling threshold
        // retires them while the undo record still retains their identities.
        view.scaleFactor = 12
        view.updateSnapshotViewportTiles()
        XCTAssertTrue(oldTiles.allSatisfy { !$0.shouldDisplay }, "Zoom retires the tiles retained by stacking undo")
        view.scaleFactor = 24
        clip.scroll(to: viewportOrigin)
        view.updateSnapshotViewportTiles()
        session.undo.undo()
        view.updateSnapshotViewportTiles()
        let tiles = page.annotations.compactMap { $0 as? SnapshotViewportTileAnnotation }
        XCTAssertEqual(tiles.count, oldTiles.count)
        for (tile, oldTile) in zip(tiles, oldTiles) {
            XCTAssertEqual(tile.bounds.minX, oldTile.bounds.minX, accuracy: 1e-6)
            XCTAssertEqual(tile.bounds.minY, oldTile.bounds.minY, accuracy: 1e-6)
            XCTAssertEqual(tile.bounds.width, oldTile.bounds.width, accuracy: 1e-6)
            XCTAssertEqual(tile.bounds.height, oldTile.bounds.height, accuracy: 1e-6)
        }
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertTrue(tiles.allSatisfy(\.shouldDisplay), "Undo must not accept retired tiles just because bounds match")
        XCTAssertFalse(tiles.contains { tile in oldTiles.contains { $0 === tile } })
        let aboveIndex = try XCTUnwrap(page.annotations.firstIndex { $0 === above })
        XCTAssertTrue(tiles.allSatisfy { page.annotations.firstIndex(of: $0)! < aboveIndex })
        let tile = try XCTUnwrap(tiles.first)
        let bitmapContext = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmapContext.setFillColor(NSColor.white.cgColor); bitmapContext.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        bitmapContext.translateBy(x: 32, y: 32); bitmapContext.scaleBy(x: 24, y: 24); bitmapContext.translateBy(x: -tile.bounds.midX, y: -tile.bounds.midY)
        tile.draw(with: .mediaBox, in: bitmapContext)
        let pixel = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(bitmapContext.makeImage())).colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(pixel.redComponent, 0.8); XCTAssertLessThan(pixel.greenComponent, 0.2, "Restored tile must draw visible snapshot content")
        XCTAssertTrue(SnapshotViewportTileAnnotation.withoutScreenTiles(in: document) {
            XCTAssertEqual(page.annotations.count, 2)
            return document.write(to: dir.appendingPathComponent("export.pdf"))
        })
        XCTAssertEqual(PDFDocument(url: dir.appendingPathComponent("export.pdf"))?.page(at: 0)?.annotations.count, 2)
    }
}
