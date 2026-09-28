import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

final class ProjectSnapshotStoreTests: XCTestCase {
    func testSnapshotWriteDurablyArchivesMinorEdit() throws {
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
        let annotation = PDFAnnotation(
            bounds: NSRect(x: 10, y: 20, width: 80, height: 20),
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = "Saved immediately"
        page.addAnnotation(annotation)
        let store = ProjectSnapshotStore()
        let snapshot = store.buildSnapshot(
            document: document,
            sourcePDFURL: sourceURL,
            initialCapacity: 1,
            pageScaleLocks: [:],
            resolvedLineWidth: { _ in 1 }
        )

        try store.writeSnapshotOrThrow(snapshot, to: snapshotURL)

        let decoded = try PropertyListDecoder().decode(
            SidecarSnapshot.self,
            from: Data(contentsOf: snapshotURL)
        )
        XCTAssertEqual(decoded.sourcePDFPath, sourceURL.standardizedFileURL.path)
        XCTAssertEqual(decoded.pageCount, 1)
        XCTAssertEqual(decoded.annotations.count, 1)
        let unarchiver = try NSKeyedUnarchiver(
            forReadingFrom: decoded.annotations[0].archivedAnnotation
        )
        unarchiver.requiresSecureCoding = false
        let restored = try XCTUnwrap(
            unarchiver.decodeObject(
                of: PDFAnnotation.self,
                forKey: NSKeyedArchiveRootObjectKey
            )
        )
        unarchiver.finishDecoding()
        XCTAssertEqual(restored.contents, "Saved immediately")
    }

    func testSnapshotRestoresBookmarksAndPageLabelsWithoutRewritingPDF() throws {
        let sourceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drawbridge-bookmark-snapshot-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: ProjectSnapshotStore().sidecarURL(for: sourceURL))
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

        let store = ProjectSnapshotStore()
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
}
