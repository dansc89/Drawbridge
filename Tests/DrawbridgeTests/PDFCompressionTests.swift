import AppKit
import PDFKit
import CoreText
import XCTest
@testable import Drawbridge

final class PDFCompressionTests: XCTestCase {
    private func fixture(rotation: Int = 0) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Compression-\(UUID()).pdf")
        var box = CGRect(x: 10, y: 20, width: 320, height: 240)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.setFillColor(NSColor.white.cgColor); context.fill(box)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 500, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Photo-like variations: enough image detail to exercise JPEG optimization.
        for y in 0..<400 {
            for x in 0..<500 {
                bitmap.setFillColor(CGColor(red: CGFloat((x * 17 + y * 13) % 255) / 255, green: CGFloat(y) / 400, blue: CGFloat(x) / 500, alpha: 1))
                bitmap.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        context.draw(try XCTUnwrap(bitmap.makeImage()), in: CGRect(x: 30, y: 50, width: 180, height: 140))
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 220,y: 180,width: 60,height: 50))
        context.setStrokeColor(NSColor.blue.cgColor); context.setLineWidth(2); context.move(to: CGPoint(x: 25,y: 30)); context.addLine(to: CGPoint(x: 300,y: 70)); context.strokePath()
        context.textPosition = CGPoint(x: 35, y: 220)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Compression vector text", attributes: [.font: NSFont.systemFont(ofSize: 10)])), context)
        context.endPDFPage(); context.closePDF()
        let doc = try XCTUnwrap(PDFDocument(url: url)); let page = try XCTUnwrap(doc.page(at: 0))
        page.rotation = rotation
        page.setBounds(CGRect(x: 20, y: 30, width: 290, height: 210), for: .cropBox)
        let note = PDFAnnotation(bounds: CGRect(x: 230,y: 90,width: 30,height: 40), forType: .square, withProperties: nil)
        note.color = .green; note.interiorColor = .green; page.addAnnotation(note)
        let link = PDFAnnotation(bounds: CGRect(x: 30,y: 40,width: 50,height: 20), forType: .link, withProperties: nil)
        link.action = PDFActionURL(url: URL(string: "https://example.com")!); page.addAnnotation(link)
        let root = PDFOutline(); let item = PDFOutline(); item.label = "Drawing"; item.destination = PDFDestination(page: page, at: .zero); root.insertChild(item, at: 0); doc.outlineRoot = root
        try XCTUnwrap(doc.dataRepresentation()).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func json(_ url: URL) throws -> [String: Any] {
        let exe = try XCTUnwrap(PDFTKBookmarkWriter.executableURL())
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Compression-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertTrue(PDFTKBookmarkWriter.run(exe, arguments: ["--json=2","--json-stream-data=inline","--decode-level=generalized",url.path,output.path]))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String:Any])
    }
    private func contents(_ json: [String: Any]) throws -> [String] {
        let table = try XCTUnwrap((json["qpdf"] as? [[String:Any]])?.last)
        return try XCTUnwrap(json["pages"] as? [[String:Any]]).flatMap { page in
            (page["contents"] as? [String] ?? []).compactMap { ref in
                ((table["obj:\(ref)"] as? [String:Any])?["stream"] as? [String:Any])?["data"] as? String
            }
        }
    }
    func testMediumPreservesExactVectorStreamsGeometryLinksAndOriginal() throws {
        let source = try fixture(); let before = try Data(contentsOf: source); let original = try json(source)
        let destination = source.deletingLastPathComponent().appendingPathComponent("Medium-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: destination) }
        let report = try PDFCompression.saveCopy(source: source, destination: destination, level: .medium)
        XCTAssertTrue(report.saved); XCTAssertLessThan(report.reducedBytes, report.originalBytes)
        XCTAssertEqual(try Data(contentsOf: source), before)
        let after = try json(destination)
        XCTAssertFalse(try contents(original).isEmpty)
        XCTAssertEqual(try contents(original), try contents(after), "Decoded vector/text operators must be byte-for-byte identical")
        let resultDocument = try XCTUnwrap(PDFDocument(url: destination))
        let page = try XCTUnwrap(resultDocument.page(at: 0))
        XCTAssertEqual(page.bounds(for: .cropBox), PDFDocument(url: source)?.page(at: 0)?.bounds(for: .cropBox))
        XCTAssertTrue(page.string?.contains("Compression vector text") == true)
        XCTAssertEqual(page.annotations.count, 2)
        XCTAssertEqual((page.annotations.last?.action as? PDFActionURL)?.url?.absoluteString, "https://example.com")
    }
    func testHighFlattensVisibleAnnotationsAndRotationWithoutTouchingSource() throws {
        for rotation in [0,90,180,270] {
            let source = try fixture(rotation: rotation); let before = try Data(contentsOf: source)
            let destination = source.deletingLastPathComponent().appendingPathComponent("High-\(UUID()).pdf")
            defer { try? FileManager.default.removeItem(at: destination) }
            let originalDocument = try XCTUnwrap(PDFDocument(url: source))
            defer { withExtendedLifetime(originalDocument) {} }
            let originalPage = try XCTUnwrap(originalDocument.page(at: 0))
            let bounds = originalPage.bounds(for: .cropBox)
            let expected = bounds.applying(originalPage.transform(for: .cropBox)).standardized
            let report = try PDFCompression.saveCopy(source: source, destination: destination, level: .high)
            XCTAssertTrue(report.saved); XCTAssertEqual(try Data(contentsOf: source), before)
            let resultDocument = try XCTUnwrap(PDFDocument(url: destination))
            defer { withExtendedLifetime(resultDocument) {} }
            let page = try XCTUnwrap(resultDocument.page(at: 0))
            XCTAssertEqual(page.bounds(for: .mediaBox).width, expected.width, accuracy: 0.01)
            XCTAssertEqual(page.bounds(for: .mediaBox).height, expected.height, accuracy: 0.01)
            XCTAssertEqual(page.rotation, 0); XCTAssertTrue(page.annotations.isEmpty)
            XCTAssertTrue((page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let raster = try XCTUnwrap(PDFRegionRasterizer.render(page: page, box: .mediaBox, rect: page.bounds(for: .mediaBox), scale: 1))
            let reference = try XCTUnwrap(PDFRegionRasterizer.render(page: originalPage, box: .cropBox, rect: bounds, scale: 1))
            func pixels(_ image: CGImage) throws -> [UInt8] {
                let ctx = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                ctx.draw(image, in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
                return Array(UnsafeBufferPointer(start: try XCTUnwrap(ctx.data?.assumingMemoryBound(to: UInt8.self)), count: image.width * image.height * 4))
            }
            let a = try pixels(reference), b = try pixels(raster); XCTAssertEqual(a.count,b.count)
            if rotation == 0 {
                var green = 0
                for y in 0..<raster.height { for x in 210..<raster.width {
                    let offset = (y * raster.width + x) * 4
                    if b[offset] < 80 && b[offset+1] > 150 && b[offset+2] < 80 { green += 1 }
                } }
                XCTAssertGreaterThan(green, 500, "Visible green annotation must be baked into page pixels")
            }
            let error = zip(a,b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
            XCTAssertLessThan(error, 15, "Raster output must retain orientation and visible markup appearance at rotation \(rotation)")
        }
    }
    func testMediumRetainsSafeUnflattenRecovery() throws {
        let source = try fixture()
        let flattened = source.deletingLastPathComponent().appendingPathComponent("Flat-\(UUID()).pdf")
        let compressed = source.deletingLastPathComponent().appendingPathComponent("Recovery-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: flattened); try? FileManager.default.removeItem(at: compressed) }
        _ = try PDFAnnotationFlattener.flatten(source: source, destination: flattened)
        let report = try PDFCompression.saveCopy(source: flattened, destination: compressed, level: .medium)
        XCTAssertTrue(report.saved)
        let result = try PDFAnnotationFlattener.unflatten(source: compressed)
        XCTAssertGreaterThan(result.restoredAnnotations, 0)
        XCTAssertTrue(PDFDocument(url: compressed)?.page(at: 0)?.annotations.contains { $0.type == "Square" } == true)
    }

    func testCancellationAndExistingDestinationsAreNeverOverwritten() throws {
        let source = try fixture(); let before = try Data(contentsOf: source)
        for level in [PDFCompressionLevel.medium,.high] {
            let dest = source.deletingLastPathComponent().appendingPathComponent("Cancel-\(UUID()).pdf")
            XCTAssertThrowsError(try PDFCompression.saveCopy(source: source,destination: dest,level: level,cancelled: { true }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
            try Data("existing".utf8).write(to: dest); defer { try? FileManager.default.removeItem(at: dest) }
            XCTAssertThrowsError(try PDFCompression.saveCopy(source: source,destination: dest,level: level))
            XCTAssertEqual(try Data(contentsOf: dest),Data("existing".utf8)); XCTAssertEqual(try Data(contentsOf: source),before)
        }
    }
    func testMediumVerificationRejectsChangedVectorContentAndImageDimensions() throws {
        let original = try json(fixture())
        let originalHash = try PDFLosslessReducer.imageIndependentSemanticHash(original)
        let qpdf = try XCTUnwrap(original["qpdf"] as? [[String: Any]])
        let table = qpdf[1]
        let imageKey = try XCTUnwrap(table.first { _, value in
            let stream = (value as? [String: Any])?["stream"] as? [String: Any]
            return (stream?["dict"] as? [String: Any])?["/Subtype"] as? String == "/Image"
        }?.key)
        func replacingImage(width: Bool) throws -> [String: Any] {
            var result = original, entries = qpdf, objects = table
            var entry = try XCTUnwrap(objects[imageKey] as? [String: Any])
            var stream = try XCTUnwrap(entry["stream"] as? [String: Any])
            if width {
                var dict = try XCTUnwrap(stream["dict"] as? [String: Any]); dict["/Width"] = 999; stream["dict"] = dict
            } else { stream["data"] = "different-image-encoding" }
            entry["stream"] = stream; objects[imageKey] = entry; entries[1] = objects; result["qpdf"] = entries
            return result
        }
        XCTAssertEqual(try PDFLosslessReducer.imageIndependentSemanticHash(replacingImage(width: false)), originalHash)
        XCTAssertNotEqual(try PDFLosslessReducer.imageIndependentSemanticHash(replacingImage(width: true)), originalHash)
        let pages = try XCTUnwrap(original["pages"] as? [[String: Any]])
        let reference = try XCTUnwrap((pages.first?["contents"] as? [String])?.first)
        var changed = original, entries = qpdf, objects = table
        var entry = try XCTUnwrap(objects["obj:" + reference] as? [String: Any])
        var stream = try XCTUnwrap(entry["stream"] as? [String: Any]); stream["data"] = Data("0 0 1 rg".utf8).base64EncodedString()
        entry["stream"] = stream; objects["obj:" + reference] = entry; entries[1] = objects; changed["qpdf"] = entries
        XCTAssertNotEqual(try PDFLosslessReducer.imageIndependentSemanticHash(changed), originalHash)
    }

    func testRealDrawingCorpus() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_COMPRESSION_CORPUS"] else {
            throw XCTSkip("Set DRAWBRIDGE_COMPRESSION_CORPUS for real drawings")
        }
        let folder = URL(fileURLWithPath: path)
        let inputs = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "pdf" }
        XCTAssertFalse(inputs.isEmpty)
        let output = folder.appendingPathComponent("outputs")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for source in inputs {
            let original = try Data(contentsOf: source)
            for level in [PDFCompressionLevel.medium, .high] {
                let destination = output.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-" + String(level.rawValue) + ".pdf")
                let start = Date()
                print("CORPUS_START \(source.lastPathComponent) level=\(level)")
                let report = try PDFCompression.saveCopy(source: source, destination: destination, level: level)
                print("CORPUS \(source.lastPathComponent) level=\(level) bytes=\(report.originalBytes)->\(report.reducedBytes) saved=\(report.saved) seconds=\(Date().timeIntervalSince(start))")
                XCTAssertEqual(try Data(contentsOf: source), original)
                if report.saved {
                    XCTAssertEqual(PDFDocument(url: source)?.pageCount, PDFDocument(url: destination)?.pageCount)
                    if level == .medium { XCTAssertEqual(try contents(json(source)), try contents(json(destination))) }
                }
            }
        }
    }

    @MainActor func testPickerDefaultsToLosslessAndExplainsLossOfEditability() {
        let picker = PDFCompressionPicker()
        XCTAssertEqual(picker.level,.low); XCTAssertEqual(picker.popup.numberOfItems,3)
        picker.popup.selectItem(at: 1); picker.updateDetail(); XCTAssertEqual(picker.level,.medium)
        XCTAssertTrue(picker.descriptionLabel.stringValue.contains("Vector linework"))
        picker.popup.selectItem(at: 2); picker.updateDetail(); XCTAssertEqual(picker.level,.high)
        XCTAssertTrue(picker.descriptionLabel.stringValue.contains("no longer searchable"))
    }
}
