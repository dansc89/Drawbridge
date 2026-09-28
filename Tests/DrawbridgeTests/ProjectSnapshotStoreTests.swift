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
}
