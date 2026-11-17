import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class SnapshotPayloadReadPerformanceTests: XCTestCase {
    // A scoped, thread-local cache/budget keeps accounting tests deterministic without
    // changing the process-wide production cache or other concurrently running tests.
    private func withCacheBudget(_ budget: Int, body: () throws -> Void) rethrows {
        let dictionary = Thread.current.threadDictionary
        let keys = ["DrawbridgeSnapshotReadBudget", "DrawbridgeSnapshotReadCache"]
        let saved = keys.map { dictionary[$0] }
        let savedObserver = SnapshotPayload.onReadDecode
        dictionary[keys[0]] = budget
        dictionary.removeObject(forKey: keys[1])
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { dictionary[key] = value } else { dictionary.removeObject(forKey: key) }
            }
            SnapshotPayload.onReadDecode = savedObserver
        }
        try body()
    }

    // A valid one-page PDF with an unreferenced padding stream BEFORE xref/trailer.
    // Offsets and stream length are exact: no parser repair or bytes after %%EOF.
    private func fixture(padding: Int = 0, width: Int = 240) -> Data {
        var data = Data("%PDF-1.4\n".utf8)
        var offsets = [0]
        func object(_ number: Int, _ contents: String) {
            offsets.append(data.count)
            data.append(Data("\(number) 0 obj\n\(contents)\nendobj\n".utf8))
        }
        object(1, "<< /Type /Catalog /Pages 2 0 R >>")
        object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) 180] >>")
        offsets.append(data.count)
        data.append(Data("4 0 obj\n<< /Length \(padding) >>\nstream\n".utf8))
        data.append(Data(repeating: 32, count: padding))
        data.append(Data("\nendstream\nendobj\n".utf8))
        let xref = data.count
        data.append(Data("xref\n0 5\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

    private func annotation(_ data: Data) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 240, height: 180), forType: .stamp, withProperties: nil)
        annotation.setValue(data.base64EncodedString(), forAnnotationKey: SnapshotPayload.key)
        return annotation
    }

    func testOversizedValidPayloadDoesNotEvictWarmSmallPayloads() throws {
        let small = fixture()
        let large = fixture(padding: 17 * 1024 * 1024)
        XCTAssertGreaterThan(large.count, 16 * 1024 * 1024)
        XCTAssertLessThanOrEqual(large.count, SnapshotPayload.maximumBytes)
        XCTAssertNotNil(SnapshotPayload(data: large).page)
        try withCacheBudget(64 * 1024 * 1024) {
            let warm = annotation(small), oversized = annotation(large)
            var decodes = 0
            SnapshotPayload.onReadDecode = { decodes += 1 }
            XCTAssertEqual(try XCTUnwrap(SnapshotPayload.read(warm)).data, small)
            for _ in 0..<3 {
                XCTAssertEqual(try XCTUnwrap(SnapshotPayload.read(oversized)).data, large)
                XCTAssertEqual(try XCTUnwrap(SnapshotPayload.read(warm)).data, small)
            }
            XCTAssertEqual(decodes, 4, "Uncacheable valid payload must not flush warm entries on each read")
        }
    }

    func testReplacementChargesOnlyCurrentEntryAndRevalidatesValidChanges() throws {
        // Also crosses the original fixed budget after repeated admissions, so
        // this regression can run against the pre-fix source without a seam.
        let a = fixture(padding: 2 * 1024 * 1024, width: 240)
        let b = fixture(padding: 2 * 1024 * 1024, width: 241)
        try withCacheBudget(4 * (a.count + b.count)) {
            let warm = annotation(a), changing = annotation(a)
            var decodes = 0
            SnapshotPayload.onReadDecode = { decodes += 1 }
            XCTAssertNotNil(SnapshotPayload.read(warm))
            for i in 0..<12 {
                let data = i.isMultiple(of: 2) ? a : b
                changing.setValue(data.base64EncodedString(), forAnnotationKey: SnapshotPayload.key)
                XCTAssertEqual(try XCTUnwrap(SnapshotPayload.read(changing)).data, data)
                XCTAssertEqual(SnapshotPayload.read(warm)?.data, a)
            }
            XCTAssertEqual(decodes, 13, "Replacement must subtract its previous cost, not evict the other live entry")
        }
    }

    func testDeadWeakKeysReclaimAdmissionCostAndDoNotRetainAnnotations() throws {
        let data = fixture(padding: 2 * 1024 * 1024)
        withCacheBudget(data.count * 8) {
            let warm = annotation(data)
            var decodes = 0
            SnapshotPayload.onReadDecode = { decodes += 1 }
            XCTAssertNotNil(SnapshotPayload.read(warm))
            for _ in 0..<12 {
                weak var released: PDFAnnotation?
                autoreleasepool {
                    let transient = annotation(data)
                    released = transient
                    XCTAssertNotNil(SnapshotPayload.read(transient))
                }
                XCTAssertNil(released, "Cache must never retain the annotation or its page")
                XCTAssertNotNil(SnapshotPayload.read(warm))
            }
            XCTAssertEqual(decodes, 13, "Dead weak keys must not accumulate phantom admission cost")
        }
    }

    func testAdmissionRemainsBoundedWhenLiveEntriesExceedBudget() {
        let data = fixture()
        withCacheBudget(data.count * 8) {
            let first = annotation(data), second = annotation(data), third = annotation(data)
            var decodes = 0
            SnapshotPayload.onReadDecode = { decodes += 1 }
            XCTAssertNotNil(SnapshotPayload.read(first))
            XCTAssertNotNil(SnapshotPayload.read(second))
            XCTAssertNotNil(SnapshotPayload.read(second))
            XCTAssertEqual(decodes, 2)
            XCTAssertNotNil(SnapshotPayload.read(third))
            XCTAssertNotNil(SnapshotPayload.read(third))
            XCTAssertEqual(decodes, 3, "A cacheable newly admitted payload should be reused")
            XCTAssertNotNil(SnapshotPayload.read(first))
            XCTAssertEqual(decodes, 4, "Three live payloads cannot remain in a two-entry byte budget")
        }
    }

    func testInvalidAndRemovedPayloadsDiscardPreviouslyValidatedBytes() {
        let data = fixture()
        withCacheBudget(data.count * 8) {
            let changing = annotation(data), warm = annotation(data)
            var decodes = 0
            SnapshotPayload.onReadDecode = { decodes += 1 }
            XCTAssertNotNil(SnapshotPayload.read(warm))
            XCTAssertNotNil(SnapshotPayload.read(changing))
            for invalid in ["invalid-base64", Data("not a PDF".utf8).base64EncodedString()] {
                changing.setValue(invalid, forAnnotationKey: SnapshotPayload.key)
                XCTAssertNil(SnapshotPayload.read(changing))
                let afterInvalid = decodes
                changing.setValue(data.base64EncodedString(), forAnnotationKey: SnapshotPayload.key)
                XCTAssertNotNil(SnapshotPayload.read(changing))
                XCTAssertEqual(decodes, afterInvalid + 1, "Invalid payload must discard previously cached bytes")
                XCTAssertNotNil(SnapshotPayload.read(warm))
                XCTAssertEqual(decodes, afterInvalid + 1, "Invalidation must release cost without evicting other entries")
            }
            changing.removeValue(forAnnotationKey: SnapshotPayload.key)
            XCTAssertNil(SnapshotPayload.read(changing))
            let afterRemoval = decodes
            changing.setValue(data.base64EncodedString(), forAnnotationKey: SnapshotPayload.key)
            XCTAssertNotNil(SnapshotPayload.read(changing))
            XCTAssertEqual(decodes, afterRemoval + 1, "Removing the key must release previously cached bytes")
            XCTAssertNotNil(SnapshotPayload.read(warm))
            XCTAssertEqual(decodes, afterRemoval + 1)
        }
    }

    func testReparentingAndRotationReadFreshPlacementWithoutRevalidation() throws {
        let data = fixture()
        let document = try XCTUnwrap(PDFDocument(data: data))
        let first = try XCTUnwrap(document.page(at: 0))
        let second = PDFPage()
        document.insert(second, at: 1)
        first.rotation = 90
        second.rotation = 270
        let stamp = annotation(data)
        first.addAnnotation(stamp)
        var decodes = 0
        let previous = SnapshotPayload.onReadDecode
        SnapshotPayload.onReadDecode = { decodes += 1 }
        defer { SnapshotPayload.onReadDecode = previous }
        XCTAssertEqual(SnapshotPayload.read(stamp)?.placement?.rotation, 90)
        first.removeAnnotation(stamp)
        second.addAnnotation(stamp)
        stamp.bounds = CGRect(x: 31, y: 47, width: 80, height: 60)
        var style = SnapshotStyle(); style.opacity = 0.23
        stamp.setValue(style.json, forAnnotationKey: SnapshotStyle.key)
        let payload = try XCTUnwrap(SnapshotPayload.read(stamp))
        XCTAssertEqual(payload.placement?.rotation, 270)
        XCTAssertEqual(payload.placement?.x, 31)
        XCTAssertEqual(payload.placement?.y, 47)
        XCTAssertEqual(payload.placement?.width, 80)
        XCTAssertEqual(payload.placement?.height, 60)
        XCTAssertEqual(payload.style, style)
        XCTAssertEqual(decodes, 1)
        second.rotation = 180
        XCTAssertEqual(SnapshotPayload.read(stamp)?.placement?.rotation, 180)
        XCTAssertEqual(decodes, 1)
    }

    func testRepeatedRecordReadsReuseValidationAndObserveMutations() throws {
        var box = CGRect(x: 0, y: 0, width: 2400, height: 1800)
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        for i in 0..<20000 {
            context.move(to: CGPoint(x: i % 2400, y: i % 1800))
            context.addLine(to: CGPoint(x: (i * 17) % 2400, y: (i * 31) % 1800))
            context.strokePath()
        }
        context.endPDFPage(); context.closePDF()
        let data = bytes as Data
        let annotation = PDFAnnotation(bounds: box, forType: .stamp, withProperties: nil)
        annotation.setValue(data.base64EncodedString(), forAnnotationKey: SnapshotPayload.key)
        var decodes = 0
        SnapshotPayload.onReadDecode = { decodes += 1 }
        defer { SnapshotPayload.onReadDecode = nil }
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 {
            XCTAssertEqual(try XCTUnwrap(SnapshotPayload.read(annotation)).data, data)
        }
        print("SNAPSHOT_READ_PROFILE bytes=\(data.count) reads=100 decodes=\(decodes) elapsed_ms=\((ProcessInfo.processInfo.systemUptime-start)*1000)")
        XCTAssertEqual(decodes, 1, "Unchanged annotation payload must not repeatedly base64-decode/parse PDF during record comparison")
        annotation.bounds = CGRect(x: 17, y: 19, width: 300, height: 200)
        XCTAssertEqual(SnapshotPayload.read(annotation)?.placement?.x, 17)
        XCTAssertEqual(decodes, 1)
        var style = SnapshotStyle(); style.opacity = 0.37; style.overlay = true
        annotation.setValue(style.json, forAnnotationKey: SnapshotStyle.key)
        XCTAssertEqual(SnapshotPayload.read(annotation)?.style, style)
        XCTAssertEqual(decodes, 1)
        annotation.setValue(Data("not a PDF".utf8).base64EncodedString(), forAnnotationKey: SnapshotPayload.key)
        XCTAssertNil(SnapshotPayload.read(annotation), "Valid base64 must still undergo PDF validation on a miss")
        annotation.setValue("invalid-pdf", forAnnotationKey: SnapshotPayload.key)
        XCTAssertNil(SnapshotPayload.read(annotation), "Changed bytes must never reuse stale validated payload")
        annotation.setValue(data.base64EncodedString(), forAnnotationKey: SnapshotPayload.key)
        XCTAssertEqual(SnapshotPayload.read(annotation)?.data, data)
        annotation.removeValue(forAnnotationKey: SnapshotPayload.key)
        XCTAssertNil(SnapshotPayload.read(annotation))
    }
}
