import XCTest
import AppKit
import CoreText
import PDFKit
@testable import Drawbridge

/// Synthetic qualification only. These callbacks do not prove PDFView/UI responsiveness.
final class SnapshotVectorReplayQualificationTests: XCTestCase {
    private let media = CGRect(x: 17, y: 29, width: 180, height: 110)

    private func source() -> Data {
        let bytes = NSMutableData(); var box = media
        let c = CGContext(consumer: CGDataConsumer(data: bytes)!, mediaBox: &box, nil)!
        c.beginPDFPage(nil)
        c.move(to: CGPoint(x: 22, y: 34)); c.addLine(to: CGPoint(x: 190, y: 38))
        c.addLine(to: CGPoint(x: 120, y: 130)); c.closePath(); c.clip()
        c.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 0.6))
        c.fill(media)
        c.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 0.5))
        c.fillEllipse(in: CGRect(x: 45, y: 40, width: 110, height: 65))
        c.setStrokeColor(CGColor(gray: 0, alpha: 0.9)); c.setLineWidth(0.3)
        for i in 0..<32 {
            let y = CGFloat(i) * 2 + 40
            c.move(to: CGPoint(x: 30, y: y))
            c.addCurve(to: CGPoint(x: 180, y: y + 5), control1: CGPoint(x: 50, y: 120), control2: CGPoint(x: 130, y: 35))
            c.strokePath()
        }
        let text = NSAttributedString(string: "Vector curves 0123", attributes: [.font: NSFont.systemFont(ofSize: 8)])
        c.textPosition = CGPoint(x: 45, y: 65)
        CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), c)
        c.endPDFPage(); c.closePDF(); return bytes as Data
    }

    private func document(_ data: Data) -> CGPDFDocument {
        CGPDFDocument(CGDataProvider(data: data as CFData)!)!
    }

    private func bitmap(_ draw: (CGContext) -> Void) -> [UInt8] {
        let c = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(c)
        return Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: 256 * 256 * 4))
    }

    private func matches(_ a: [UInt8], _ b: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        let maximum = zip(a, b).map { abs(Int($0) - Int($1)) }.max()!
        XCTAssertLessThanOrEqual(maximum, 2, file: file, line: line)
        XCTAssertGreaterThan(stride(from: 3, to: b.count, by: 4).filter { b[$0] > 0 }.count, 100, file: file, line: line)
        XCTAssertGreaterThan(stride(from: 3, to: b.count, by: 4).filter { b[$0] == 0 }.count, 100, file: file, line: line)
    }

    func testNonzeroMediaOriginNonSquareRotationsClippingTransparencyTextAndCurves() throws {
        let data = source(), doc = document(data)
        XCTAssertEqual(doc.page(at: 1)!.getBoxRect(.mediaBox), media)
        for rotation in [0, 90, 180, 270] {
            let stamp = DrawbridgeSnapshotAnnotation(bounds: CGRect(x: 10, y: 15, width: 190, height: 125), document: doc,
                rotation: rotation, style: SnapshotStyle(opacity: 0.65), previewData: data)
            let page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 240, height: 200), for: .mediaBox)
            page.addAnnotation(stamp); stamp.usesViewportTiles = true
            let tile = SnapshotViewportTileAnnotation(snapshot: stamp, bounds: stamp.bounds); page.addAnnotation(tile)
            let actual = bitmap { tile.draw(with: .mediaBox, in: $0) }
            let expected = bitmap { c in SnapshotPageRendering.vector { stamp.draw(with: .mediaBox, in: c) } }
            matches(actual, expected)
            XCTAssertTrue(stride(from: 3, to: actual.count, by: 4).contains { (1..<165).contains(Int(actual[$0])) })
            withExtendedLifetime((page, stamp, tile)) {}
        }
    }

    func testAdmissionExhaustionReleaseAndExplicitlyUnacceleratedFallback() throws {
        let data = source(), doc = document(data)
        var admitted = [SnapshotVectorReplay]()
        // Source-admission costs are synthetic charges, not native heap measurements.
        for _ in 0..<8 { admitted.append(try XCTUnwrap(SnapshotVectorReplay(document: doc, sourceBytes: 1))) }
        XCTAssertNil(SnapshotVectorReplay(document: doc, sourceBytes: 1), "Ninth list must be unaccelerated")
        let stamp = DrawbridgeSnapshotAnnotation(bounds: CGRect(x: 0, y: 0, width: 180, height: 110), document: doc,
            rotation: 0, style: SnapshotStyle(), previewData: data)
        let page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 256, height: 256), for: .mediaBox)
        page.addAnnotation(stamp); stamp.usesViewportTiles = true
        let tile = SnapshotViewportTileAnnotation(snapshot: stamp, bounds: stamp.bounds); page.addAnnotation(tile)
        matches(bitmap { tile.draw(with: .mediaBox, in: $0) }, bitmap { c in SnapshotPageRendering.vector { stamp.draw(with: .mediaBox, in: c) } })
        print("QUALIFICATION fallback=unaccelerated reason=entry-admission-exhaustion latency-not-qualified")
        admitted.removeLast()
        var replacement: SnapshotVectorReplay? = try XCTUnwrap(SnapshotVectorReplay(document: doc, sourceBytes: 1))
        XCTAssertNotNil(replacement); replacement = nil; admitted.removeAll()
        XCTAssertNil(SnapshotVectorReplay(document: doc, sourceBytes: 8 * 1024 * 1024 + 1))
        for _ in 0..<4 { admitted.append(try XCTUnwrap(SnapshotVectorReplay(document: doc, sourceBytes: 8 * 1024 * 1024))) }
        XCTAssertNil(SnapshotVectorReplay(document: doc, sourceBytes: 1), "Aggregate byte admission must also reject")
        admitted.removeAll()
        XCTAssertNotNil(SnapshotVectorReplay(document: doc, sourceBytes: 1))
        withExtendedLifetime((page, stamp, tile)) {}
    }

    private final class WorkerState: @unchecked Sendable {
        let replay: SnapshotVectorReplay
        let lock = NSLock()
        var times = [Double]()
        var mismatches = 0
        let expected: [UInt8]
        init(replay: SnapshotVectorReplay, expected: [UInt8]) { self.replay = replay; self.expected = expected }
    }

    func testNativeWorkerConcurrentReplayStressWithOriginalLatencyLimits() throws {
        let data = SnapshotVectorReplayTests().source(), doc = document(data)
        let replay = try XCTUnwrap(SnapshotVectorReplay(document: doc, sourceBytes: data.count))
        func render(_ c: CGContext) { c.scaleBy(x: 8, y: 8); c.translateBy(x: -284, y: -284); replay.draw(in: c) }
        let state = WorkerState(replay: replay, expected: bitmap(render))
        DispatchQueue.concurrentPerform(iterations: 60) { _ in
            autoreleasepool {
                let c = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.scaleBy(x: 8, y: 8); c.translateBy(x: -284, y: -284)
                let start = CFAbsoluteTimeGetCurrent(); state.replay.draw(in: c)
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                let pixels = Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: 256 * 256 * 4))
                state.lock.lock(); state.times.append(elapsed)
                if pixels != state.expected { state.mismatches += 1 }; state.lock.unlock()
            }
        }
        let times = state.times.sorted()
        XCTAssertEqual(times.count, 60); XCTAssertEqual(state.mismatches, 0)
        print("QUALIFICATION native-worker n=60 p95Ms=\(times[56]) maxMs=\(times.last!) includes-lock-contention=true")
        XCTAssertLessThan(times[56], 50); XCTAssertLessThan(times.last!, 250)
    }

    @MainActor func testActualPersistedSaveReopenAdoptionAndStyleReplacementChangesContent() throws {
        _ = NSApplication.shared
        XCTAssertNotNil(PDFTKBookmarkWriter.executableURL(), "Production save helper is required")
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/snapshot-lag-fix-20261117/qualification")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = PDFDocument(); let blank = PDFPage(); blank.setBounds(CGRect(x: 0, y: 0, width: 256, height: 256), for: .mediaBox); base.insert(blank, at: 0)
        let baseBytes = try XCTUnwrap(base.dataRepresentation())
        let view = MarkupPDFView(); view.document = base
        let session = view.rectangleMarkup; session.bind(to: base); session.canEdit = { true }
        let data = source()
        let original = try XCTUnwrap(session.pasteSnapshot(SnapshotPayload(data: data), on: blank, center: CGPoint(x: 110, y: 90)))
        let output = root.appendingPathComponent("synthetic-reopen.pdf")
        try SharedReviewPDFExport.write(basePDF: baseBytes, records: RectangleMarkupRecord.capture(base), to: output)
        let reopened = try XCTUnwrap(PDFDocument(url: output)), page = try XCTUnwrap(reopened.page(at: 0))
        let imported = try XCTUnwrap(page.annotations.first { SnapshotPayload.isSnapshot($0) })
        XCTAssertFalse(imported is DrawbridgeSnapshotAnnotation)
        XCTAssertEqual(SnapshotPayload.read(imported)?.data, data)
        let reopenedView = MarkupPDFView(); let editing = reopenedView.rectangleMarkup
        editing.prepareForDisplay(reopened); reopenedView.document = reopened; editing.bind(to: reopened); editing.canEdit = { true }
        let adopted = try XCTUnwrap(page.annotations.first { $0 is DrawbridgeSnapshotAnnotation } as? DrawbridgeSnapshotAnnotation)
        XCTAssertEqual(adopted.bounds, original.bounds)
        let before = bitmap { c in SnapshotPageRendering.vector { adopted.draw(with: .mediaBox, in: c) } }
        adopted.usesViewportTiles = true
        let adoptedTile = SnapshotViewportTileAnnotation(snapshot: adopted, bounds: adopted.bounds); page.addAnnotation(adoptedTile)
        matches(bitmap { adoptedTile.draw(with: .mediaBox, in: $0) }, before)
        page.removeAnnotation(adoptedTile)
        editing.selectFromList(adopted)
        let style = SnapshotStyle(opacity: 0.25)
        editing.styleSelectedSnapshot(style)
        let replacement = try XCTUnwrap(page.annotations.first { $0 is DrawbridgeSnapshotAnnotation } as? DrawbridgeSnapshotAnnotation)
        XCTAssertFalse(replacement === adopted); XCTAssertFalse(page.annotations.contains(adopted))
        XCTAssertEqual(SnapshotPayload.read(replacement)?.data, data); XCTAssertEqual(SnapshotStyle.read(replacement), style)
        let changed = bitmap { c in SnapshotPageRendering.vector { replacement.draw(with: .mediaBox, in: c) } }
        XCTAssertGreaterThan(zip(before, changed).filter { abs(Int($0) - Int($1)) > 20 }.count, 100)
        // Independently expect quarter-opacity alpha, not merely any content change.
        let beforeAlpha = stride(from: 3, to: before.count, by: 4).reduce(0) { $0 + Int(before[$1]) }
        let changedAlpha = stride(from: 3, to: changed.count, by: 4).reduce(0) { $0 + Int(changed[$1]) }
        XCTAssertGreaterThan(beforeAlpha, 1000)
        XCTAssertEqual(Double(changedAlpha) / Double(beforeAlpha), 0.25, accuracy: 0.02)
        replacement.usesViewportTiles = true
        let tile = SnapshotViewportTileAnnotation(snapshot: replacement, bounds: replacement.bounds); page.addAnnotation(tile)
        matches(bitmap { tile.draw(with: .mediaBox, in: $0) }, changed)
        let styledOutput = root.appendingPathComponent("synthetic-style-reopen.pdf")
        try SharedReviewPDFExport.write(basePDF: baseBytes, records: RectangleMarkupRecord.capture(reopened), to: styledOutput)
        let styled = try XCTUnwrap(PDFDocument(url: styledOutput))
        let saved = try XCTUnwrap(styled.page(at: 0)?.annotations.first { SnapshotPayload.isSnapshot($0) })
        XCTAssertEqual(SnapshotStyle.read(saved), style); XCTAssertEqual(SnapshotPayload.read(saved)?.data, data)
    }

    private final class Operators { var inlineImages = 0; var curves = 0; var text = 0; var images = 0; var forms = 0 }
    private static func inspect(_ stream: CGPDFContentStreamRef, counts: Operators, depth: Int = 0) {
        guard depth < 16 else { return }
        let table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "BI") { _, info in Unmanaged<Operators>.fromOpaque(info!).takeUnretainedValue().inlineImages += 1 }
        CGPDFOperatorTableSetCallback(table, "c") { _, info in Unmanaged<Operators>.fromOpaque(info!).takeUnretainedValue().curves += 1 }
        CGPDFOperatorTableSetCallback(table, "Tj") { _, info in Unmanaged<Operators>.fromOpaque(info!).takeUnretainedValue().text += 1 }
        CGPDFOperatorTableSetCallback(table, "TJ") { _, info in Unmanaged<Operators>.fromOpaque(info!).takeUnretainedValue().text += 1 }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(counts).toOpaque())
        XCTAssertTrue(CGPDFScannerScan(scanner))
    }

    func testReplayExportScansInlineImageOperatorsAndNestedForms() throws {
        let data = source(), doc = document(data)
        let replay = try XCTUnwrap(SnapshotVectorReplay(document: doc, sourceBytes: data.count))
        let bytes = NSMutableData(); var box = media
        let c = CGContext(consumer: CGDataConsumer(data: bytes)!, mediaBox: &box, nil)!
        c.beginPDFPage(nil); replay.draw(in: c); c.endPDFPage(); c.closePDF()
        let saved = document(bytes as Data), page = try XCTUnwrap(saved.page(at: 1))
        let counts = Operators()
        let pageStream = CGPDFContentStreamCreateWithPage(page)
        Self.inspect(pageStream, counts: counts)
        func resources(_ dictionary: CGPDFDictionaryRef?, parent: CGPDFContentStreamRef, depth: Int) {
            guard depth < 16, let dictionary else { return }
            var objects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "XObject", &objects), let objects else { return }
            final class Visitor {
                let visit: (CGPDFObjectRef) -> Void
                init(_ visit: @escaping (CGPDFObjectRef) -> Void) { self.visit = visit }
            }
            let visitor = Visitor { object in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
                var name: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dict, "Subtype", &name), let name else { return }
                if String(cString: name) == "Image" { counts.images += 1 }
                if String(cString: name) == "Form" {
                    counts.forms += 1
                    var nested: CGPDFDictionaryRef?; CGPDFDictionaryGetDictionary(dict, "Resources", &nested)
                    // Forms without Resources inherit the enclosing content stream's resources.
                    let effectiveResources = nested ?? dictionary
                    let content = CGPDFContentStreamCreateWithStream(stream, effectiveResources, parent)
                    Self.inspect(content, counts: counts, depth: depth + 1)
                    resources(effectiveResources, parent: content, depth: depth + 1)
                }
            }
            CGPDFDictionaryApplyFunction(objects, { _, object, info in
                Unmanaged<Visitor>.fromOpaque(info!).takeUnretainedValue().visit(object)
            }, Unmanaged.passUnretained(visitor).toOpaque())
        }
        let pageDictionary = try XCTUnwrap(page.dictionary)
        var res: CGPDFDictionaryRef?; CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &res)
        resources(res, parent: pageStream, depth: 0)
        XCTAssertGreaterThan(counts.forms, 0); XCTAssertGreaterThan(counts.curves, 0); XCTAssertGreaterThan(counts.text, 0)
        XCTAssertEqual(counts.images, 0); XCTAssertEqual(counts.inlineImages, 0)
        print("QUALIFICATION export forms=\(counts.forms) curves=\(counts.curves) text=\(counts.text) images=\(counts.images) inlineImages=\(counts.inlineImages)")
    }
}
