import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

final class ProjectSnapshotStoreTests: XCTestCase {
    func testSnapshotWriteNeverArchivesPageAnnotations() throws {
        let sourceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drawbridge-snapshot-source-\(UUID().uuidString).pdf")
        let snapshotURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drawbridge-snapshot-\(UUID().uuidString).plist")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: snapshotURL)
        }
        let document = PDFDocument()
        let image = NSImage(size: NSSize(width: 200, height: 200))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 200, height: 200)).fill()
        image.unlockFocus()
        let page = try XCTUnwrap(PDFPage(image: image))
        document.insert(page, at: 0)
        XCTAssertTrue(document.write(to: sourceURL, withOptions: nil))
        let existingMarkup = PDFAnnotation(
            bounds: NSRect(x: 10, y: 20, width: 80, height: 20),
            forType: .freeText,
            withProperties: nil
        )
        existingMarkup.contents = "Existing markup stays in the PDF"
        page.addAnnotation(existingMarkup)
        let link = PDFAnnotation(
            bounds: NSRect(x: 100, y: 20, width: 80, height: 20),
            forType: .link,
            withProperties: nil
        )
        link.action = PDFActionGoTo(destination: PDFDestination(page: page, at: .zero))
        page.addAnnotation(link)
        let store = ProjectSnapshotStore()
        let snapshot = store.buildSnapshot(
            document: document,
            sourcePDFURL: sourceURL,
            initialCapacity: 1,
            pageScaleLocks: [0: PageScaleLock(unit: "ft", scale: 12)],
            resolvedLineWidth: { _ in XCTFail("Navigation snapshots must not normalize markup appearance"); return 1 }
        )

        try store.writeSnapshotOrThrow(snapshot, to: snapshotURL)

        let decoded = try PropertyListDecoder().decode(
            SidecarSnapshot.self,
            from: Data(contentsOf: snapshotURL)
        )
        XCTAssertEqual(decoded.sourcePDFPath, sourceURL.standardizedFileURL.path)
        XCTAssertEqual(decoded.pageCount, 1)
        XCTAssertTrue(decoded.annotations.isEmpty)
        XCTAssertNil(decoded.pageScaleLocks)
        XCTAssertTrue(page.annotations.contains { $0 === existingMarkup })
    }

    func testLegacySnapshotIgnoresMarkupsAndPreservesOriginalAnnotationsAndPageGeometry() throws {
        let sourceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drawbridge-legacy-snapshot-\(UUID().uuidString).pdf")
        let snapshotDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let store = ProjectSnapshotStore(snapshotDirectory: snapshotDirectory)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: store.sidecarURL(for: sourceURL))
        }
        let document = PDFDocument()
        let page = try makePage()
        page.rotation = 90
        page.setBounds(NSRect(x: 12, y: 24, width: 160, height: 140), for: .cropBox)
        document.insert(page, at: 0)
        XCTAssertTrue(document.write(to: sourceURL, withOptions: nil))

        let original = PDFAnnotation(
            bounds: NSRect(x: 30, y: 50, width: 80, height: 25),
            forType: .freeText,
            withProperties: nil
        )
        original.contents = "Keep original appearance"
        original.color = .systemRed
        original.font = NSFont(name: "Times-Roman", size: 19)
        original.isReadOnly = true
        original.shouldPrint = false
        original.shouldDisplay = true
        // Even a nonlink annotation carrying an action is outside recovery's scope.
        original.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.com/original")))
        page.addAnnotation(original)
        let originalInk = PDFAnnotation(
            bounds: NSRect(x: 20, y: 90, width: 100, height: 40),
            forType: .ink,
            withProperties: nil
        )
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        path.line(to: NSPoint(x: 80, y: 20))
        path.lineWidth = 3
        originalInk.add(path)
        originalInk.color = .systemBlue
        page.addAnnotation(originalInk)
        let obsoleteLink = PDFAnnotation(bounds: .zero, forType: .link, withProperties: nil)
        obsoleteLink.url = URL(string: "https://example.com/obsolete")
        page.addAnnotation(obsoleteLink)

        let expectedBounds = original.bounds
        let expectedInkBounds = originalInk.bounds
        let expectedColor = original.color
        let expectedFont = original.font
        let expectedFlags = original.value(forAnnotationKey: .flags) as? NSNumber
        let expectedRotation = page.rotation
        let expectedMediaBox = page.bounds(for: .mediaBox)
        let expectedCropBox = page.bounds(for: .cropBox)

        let staleMarkup = PDFAnnotation(
            bounds: NSRect(x: 1, y: 2, width: 3, height: 4),
            forType: .freeText,
            withProperties: nil
        )
        staleMarkup.contents = "Stale markup must never return"
        staleMarkup.color = .systemGreen
        staleMarkup.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.com/stale")))
        let restoredLink = PDFAnnotation(
            bounds: NSRect(x: 100, y: 130, width: 60, height: 20),
            forType: .link,
            withProperties: nil
        )
        restoredLink.url = URL(string: "https://example.com/recovered-sheet")
        let snapshot = SidecarSnapshot(
            sourcePDFPath: sourceURL.standardizedFileURL.path,
            pageCount: 1,
            annotations: [
                SidecarAnnotationRecord(pageIndex: 0, archivedAnnotation: Data(), lineWidth: 99),
                SidecarAnnotationRecord(pageIndex: 0, archivedAnnotation: Data(), lineWidth: 99)
            ],
            pageScaleLocks: [0: PageScaleLock(unit: "ft", scale: 100)],
            pageLabels: [0: "A1.01"],
            bookmarks: [],
            savedAt: Date()
        )
        try store.writeSnapshotOrThrow(snapshot, to: store.sidecarURL(for: sourceURL))
        // Make recency deterministic even on filesystems with coarse modification dates.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)],
            ofItemAtPath: sourceURL.path
        )
        var restoredScales: [Int: PageScaleLock] = [0: PageScaleLock(unit: "pt", scale: 2)]
        var restoredLabels: [Int: String] = [:]
        store.loadSnapshotIfAvailable(
            for: sourceURL,
            document: document,
            applyPageScaleLocks: { restoredScales = $0 },
            applyPageLabels: { restoredLabels = $0 },
            assignLineWidth: { _, _ in XCTFail("Recovery must not rewrite annotation appearance") }
        )

        XCTAssertEqual(page.annotations.count, 3)
        XCTAssertTrue(page.annotations.contains { $0 === original })
        XCTAssertTrue(page.annotations.contains { $0 === originalInk })
        XCTAssertTrue(page.annotations.contains { $0 === obsoleteLink })
        XCTAssertFalse(page.annotations.contains { $0.contents == staleMarkup.contents })
        XCTAssertEqual(original.bounds, expectedBounds)
        XCTAssertEqual(originalInk.bounds, expectedInkBounds)
        XCTAssertEqual(original.color, expectedColor)
        XCTAssertEqual(original.font, expectedFont)
        XCTAssertEqual(original.value(forAnnotationKey: .flags) as? NSNumber, expectedFlags)
        XCTAssertEqual(original.contents, "Keep original appearance")
        XCTAssertTrue(original.isReadOnly)
        XCTAssertFalse(original.shouldPrint)
        XCTAssertTrue(original.shouldDisplay)
        XCTAssertEqual(page.rotation, expectedRotation)
        XCTAssertEqual(page.bounds(for: .mediaBox), expectedMediaBox)
        XCTAssertEqual(page.bounds(for: .cropBox), expectedCropBox)
        XCTAssertTrue(restoredScales.isEmpty)
        XCTAssertEqual(restoredLabels, [0: "A1.01"])
        XCTAssertFalse(page.annotations.contains { $0 === restoredLink })
    }

    func testSnapshotRestoresBookmarksAndPageLabelsWithoutRewritingPDF() throws {
        let sourceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drawbridge-bookmark-snapshot-\(UUID().uuidString).pdf")
        let snapshotDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: ProjectSnapshotStore(snapshotDirectory: snapshotDirectory).sidecarURL(for: sourceURL))
        }

        let document = PDFDocument()
        for index in 0..<2 {
            let image = NSImage(size: NSSize(width: 200, height: 200))
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 200, height: 200)).fill()
            image.unlockFocus()
            let page = try XCTUnwrap(PDFPage(image: image))
            document.insert(page, at: index)
        }
        XCTAssertTrue(document.write(to: sourceURL, withOptions: nil))

        let root = PDFOutline()
        let parent = PDFOutline()
        parent.label = "ARCHITECTURAL"
        let child = PDFOutline()
        child.label = "A1.01 - FLOOR PLAN"
        child.destination = PDFDestination(page: try XCTUnwrap(document.page(at: 1)), at: NSPoint(x: 24, y: 180))
        parent.insertChild(child, at: 0)
        root.insertChild(parent, at: 0)
        document.outlineRoot = root

        let store = ProjectSnapshotStore(snapshotDirectory: snapshotDirectory)
        let snapshot = store.buildSnapshot(
            document: document,
            sourcePDFURL: sourceURL,
            initialCapacity: 0,
            pageScaleLocks: [:],
            pageLabels: [1: "A1.01 - FLOOR PLAN"],
            resolvedLineWidth: { _ in 1 }
        )
        XCTAssertTrue(store.writeSnapshot(snapshot, to: store.sidecarURL(for: sourceURL)))

        let reopened = try XCTUnwrap(PDFDocument(url: sourceURL))
        var restoredLabels: [Int: String] = [:]
        store.loadSnapshotIfAvailable(
            for: sourceURL,
            document: reopened,
            applyPageScaleLocks: { _ in },
            applyPageLabels: { restoredLabels = $0 },
            assignLineWidth: { _, _ in }
        )

        XCTAssertEqual(restoredLabels[1], "A1.01 - FLOOR PLAN")
        let restoredParent = try XCTUnwrap(reopened.outlineRoot?.child(at: 0))
        XCTAssertEqual(restoredParent.label, "ARCHITECTURAL")
        let restoredChild = try XCTUnwrap(restoredParent.child(at: 0))
        XCTAssertEqual(restoredChild.label, "A1.01 - FLOOR PLAN")
        XCTAssertEqual(restoredChild.destination?.page.map { reopened.index(for: $0) }, 1)
        let restoredPoint = try XCTUnwrap(restoredChild.destination?.point)
        XCTAssertEqual(restoredPoint.x, 24, accuracy: 0.01)
        XCTAssertEqual(restoredPoint.y, 180, accuracy: 0.01)
    }

    private func makePage() throws -> PDFPage {
        let image = NSImage(size: NSSize(width: 200, height: 200))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 200).fill()
        image.unlockFocus()
        return try XCTUnwrap(PDFPage(image: image))
    }
}
