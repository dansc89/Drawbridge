import AppKit
import CoreText
import PDFKit
import XCTest
@testable import Drawbridge

/// Qualification uses real PDFKit rasterization/writer/NSPasteboard and native control
/// actions in never-ordered windows. It is NOT physical mouse/keyboard or cross-app QA.
@MainActor final class HighlightQualificationTests: XCTestCase {
    private let evidence = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DRAWBRIDGE_HIGHLIGHT_EVIDENCE"]
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("Drawbridge-Highlight-Qualification").path)

    private func directory(_ name: String) throws -> URL {
        let url = evidence.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture(at url: URL, rotation: Int = 0, mixed: Bool = false) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 320, height: 320)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setStrokeColor(NSColor.black.cgColor); context.setLineWidth(4)
        context.move(to: CGPoint(x: 55, y: 110)); context.addLine(to: CGPoint(x: 265, y: 110)); context.strokePath()
        let text = NSAttributedString(string: "BLACK TEXT 123", attributes: [
            .font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black
        ])
        context.textPosition = CGPoint(x: 55, y: 180)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        let page = try XCTUnwrap(document.page(at: 0))
        page.rotation = rotation
        if mixed {
            page.setBounds(CGRect(x: 20, y: 30, width: 280, height: 260), for: .cropBox)
            let square = PDFAnnotation(bounds: CGRect(x: 45, y: 45, width: 35, height: 25), forType: .square, withProperties: nil)
            square.color = .red; square.contents = "Foreign square: preserve me"
            let note = PDFAnnotation(bounds: CGRect(x: 230, y: 245, width: 20, height: 20), forType: .text, withProperties: nil)
            note.contents = "Foreign note: preserve me"; note.color = .blue
            page.addAnnotation(square); page.addAnnotation(note)
        }
        XCTAssertTrue(document.write(to: url))
        return try XCTUnwrap(PDFDocument(url: url))
    }

    private func record(opacity: Double = 0.35) -> RectangleMarkupRecord {
        var record = RectangleMarkupRecord(id: RectangleMarkupRecord.prefix + UUID().uuidString, pageIndex: 0,
            bounds: CGRect(x: 40, y: 90, width: 240, height: 140), red: 1, green: 1, blue: 0, lineWidth: 2)
        record.kind = .highlight; record.strokeOpacity = opacity
        return record
    }

    private func save(_ document: PDFDocument, at source: URL, to destination: URL, records: [RectangleMarkupRecord]) throws -> PDFDocument {
        var failure: PDFRectangleWriter.SaveFailure?
        let success = PDFRectangleWriter.write(document: document, source: source, destination: destination,
            pageLabels: [:], records: records, onFailure: { failure = $0 })
        XCTAssertTrue(success, "Real writer failed at \(failure?.stage ?? "unknown")")
        guard success else { throw CocoaError(.fileWriteUnknown) }
        return try XCTUnwrap(PDFDocument(url: destination))
    }

    private struct Raster {
        let bytes: [UInt8]
        let width = 640
        func rgb(_ x: Int, _ y: Int) -> [Double] {
            let i = (y * width + x) * 4
            return (0..<3).map { Double(bytes[i + $0]) / 255 }
        }
    }

    private func raster(_ page: PDFPage, png: URL? = nil) throws -> Raster {
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 640, bitsPerComponent: 8,
            bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
        context.scaleBy(x: 2, y: 2)
        page.draw(with: .mediaBox, to: context)
        if let png {
            let image = try XCTUnwrap(context.makeImage())
            let representation = NSBitmapImageRep(cgImage: image)
            try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(to: png)
        }
        let pointer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Raster(bytes: Array(UnsafeBufferPointer(start: pointer, count: 640 * 640 * 4)))
    }

    func testRenderedSavedReopenedYellowOpacityKeepsBlackTextAndLineReadable() throws {
        let root = try directory("rendered")
        let source = root.appendingPathComponent("original.pdf")
        let original = try fixture(at: source)
        let page = try XCTUnwrap(original.page(at: 0))
        let baseline = try raster(page, png: root.appendingPathComponent("baseline.png"))
        for opacity in [0.20, 0.35, 0.65] {
            let live = try record(opacity: opacity).clipboardAnnotation(contents: nil)
            page.addAnnotation(live)
            let liveRaster = try raster(page, png: root.appendingPathComponent("live-\(opacity).png"))
            XCTAssertEqual(liveRaster.rgb(200, 340)[2], 1 - opacity, accuracy: 0.09)
            XCTAssertLessThan(liveRaster.rgb(200, 420).max()!, 0.16)
            page.removeAnnotation(live)
            let output = root.appendingPathComponent("yellow-\(opacity).pdf")
            let reopened = try save(original, at: source, to: output, records: [record(opacity: opacity)])
            let savedPage = try XCTUnwrap(reopened.page(at: 0))
            let rendered = try raster(savedPage, png: root.appendingPathComponent("yellow-\(opacity).png"))
            XCTAssertTrue(savedPage.string?.contains("BLACK TEXT 123") == true)
            // Blank area within the highlight: actual rendered blue attenuation,
            // not merely /CA metadata. Yellow should not darken red or green.
            let blank = rendered.rgb(200, 340)
            XCTAssertGreaterThan(blank[0], 0.94); XCTAssertGreaterThan(blank[1], 0.94)
            XCTAssertEqual(blank[2], 1 - opacity, accuracy: 0.09, "Rendered yellow opacity \(opacity)")
            // PDFKit draws PDF coordinates into a top-down bitmap: y = 640 - 2 * pageY.
            for (label, rows) in [("line", 416..<424), ("text", 248..<280)] {
                var black = 0, readable = 0
                for y in rows { for x in 110..<530 {
                    if baseline.rgb(x, y).allSatisfy({ $0 < 0.08 }) {
                        black += 1
                        if rendered.rgb(x, y).max()! < 0.16 { readable += 1 }
                    }
                } }
                XCTAssertGreaterThan(black, 100, "Non-vacuous baseline \(label) mask")
                XCTAssertGreaterThan(Double(readable) / Double(max(black, 1)), 0.98,
                    "Yellow must preserve black \(label), opacity \(opacity)")
            }
            XCTAssertEqual(MarkupStyle.strokeOpacity(try XCTUnwrap(savedPage.annotations.first)), opacity, accuracy: 0.001)
        }
    }

    func testMixedForeignAnnotationsCropRotationAndRepeatedInPlaceSavesPreserveOriginal() throws {
        for rotation in [0, 90, 180, 270] {
            let root = try directory("in-place-\(rotation)")
            let url = root.appendingPathComponent("mixed.pdf")
            var document = try fixture(at: url, rotation: rotation, mixed: true)
            let initial = try Data(contentsOf: url)
            let page = try XCTUnwrap(document.page(at: 0))
            let media = page.bounds(for: .mediaBox), crop = page.bounds(for: .cropBox)
            let text = page.string
            // PDFKit adds a Popup companion for the foreign Text note at fixture write.
            let originalForeignCount = page.annotations.count
            let originalForeignTypes = page.annotations.compactMap(\.type).sorted()
            let originalForeignBounds = page.annotations.map { NSStringFromRect($0.bounds) }.sorted()
            let baseline = try raster(page, png: root.appendingPathComponent("baseline.png"))
            var highlight = record()
            var rectangle = record(); rectangle.kind = .rectangle
            rectangle.bounds = CGRect(x: 120, y: 240, width: 65, height: 30)
            rectangle.red = 0; rectangle.green = 0; rectangle.blue = 1; rectangle.strokeOpacity = 1
            for pass in 1...3 {
                highlight.bounds.origin.x += 2
                highlight.strokeOpacity = Double(pass) * 0.15
                let previous = try Data(contentsOf: url)
                document = try save(document, at: url, to: url, records: [highlight, rectangle])
                let bytes = try Data(contentsOf: url)
                XCTAssertTrue(bytes.starts(with: previous), "Every in-place revision preserves preceding bytes")
                XCTAssertTrue(bytes.starts(with: initial), "Original PDF streams retained byte-for-byte")
                let saved = try XCTUnwrap(document.page(at: 0))
                XCTAssertEqual(saved.rotation, rotation); XCTAssertEqual(saved.bounds(for: .mediaBox), media)
                XCTAssertEqual(saved.bounds(for: .cropBox), crop); XCTAssertEqual(saved.string, text)
                XCTAssertEqual(saved.annotations.count, originalForeignCount + 2, "No duplicate/vanished annotations after pass \(pass)")
                let foreign = saved.annotations.filter { !RectangleMarkupRecord.owns($0) }
                XCTAssertEqual(Set(foreign.compactMap(\.contents)), Set(["Foreign square: preserve me", "Foreign note: preserve me"]))
                XCTAssertEqual(foreign.compactMap(\.type).sorted(), originalForeignTypes)
                XCTAssertEqual(foreign.map { NSStringFromRect($0.bounds) }.sorted(), originalForeignBounds)
                let captured = RectangleMarkupRecord.capture(document)
                XCTAssertEqual(captured.count, 2)
                let capturedHighlight = try XCTUnwrap(captured.first { $0.kind == .highlight })
                XCTAssertEqual(capturedHighlight.bounds, highlight.bounds)
                XCTAssertEqual(capturedHighlight.strokeOpacity, highlight.strokeOpacity, accuracy: 0.001)
                _ = try raster(saved, png: root.appendingPathComponent("pass-\(pass).png"))
                // Remove only owned overlays from an independent reopened document.
                // Original page artwork + foreign annotation rendering must be exact.
                let comparison = try XCTUnwrap(PDFDocument(url: url))
                let comparisonPage = try XCTUnwrap(comparison.page(at: 0))
                for annotation in comparisonPage.annotations where RectangleMarkupRecord.owns(annotation) {
                    comparisonPage.removeAnnotation(annotation)
                }
                XCTAssertEqual(try raster(comparisonPage).bytes, baseline.bytes,
                    "Original artwork/foreign annotation appearance changed, rotation \(rotation), pass \(pass)")
            }
        }
    }

    private func canvas(_ body: (MarkupPDFView, PDFPage) throws -> Void) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = MarkupPDFView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        let document = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 320, height: 320), for: .mediaBox)
        document.insert(page, at: 0); view.setMarkupDocument(document)
        view.rectangleMarkup.canEdit = { true }; view.rectangleMarkup.undo.groupsByEvent = false
        XCTAssertFalse(window.isVisible)
        try body(view, page)
    }

    func testRealCustomPasteboardCopyDecodePasteInPlaceAndOffsetUndoRedo() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("HighlightQualification-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let source = try record().clipboardAnnotation(contents: "clipboard highlight")
        XCTAssertTrue(MarkupClipboard.copy([source], to: board))
        XCTAssertNotNil(board.data(forType: MarkupClipboard.type)); XCTAssertTrue(MarkupClipboard.canPaste(from: board))
        let decoded = try XCTUnwrap(MarkupClipboard.read(from: board))
        XCTAssertEqual(decoded.count, 1); XCTAssertFalse(decoded[0] === source)
        try canvas { view, page in
            let controller = view.rectangleMarkup
            for inPlace in [true, false] {
                let items = try XCTUnwrap(MarkupClipboard.read(from: board))
                let pasted = controller.pasteMarkups(items, on: page, center: CGPoint(x: 160, y: 170), inPlace: inPlace)
                let annotation = try XCTUnwrap(pasted.first)
                XCTAssertEqual(pasted.count, 1); XCTAssertEqual(annotation.type, "Highlight")
                XCTAssertEqual(annotation.contents, "clipboard highlight")
                XCTAssertNotEqual(RectangleMarkupRecord.identity(annotation), RectangleMarkupRecord.identity(source))
                XCTAssertEqual(annotation.bounds, inPlace ? source.bounds : CGRect(x: 40, y: 100, width: 240, height: 140))
                XCTAssertEqual(annotation.quadrilateralPoints?.map(\.pointValue), [CGPoint(x: 0, y: 140), CGPoint(x: 240, y: 140), .zero, CGPoint(x: 240, y: 0)])
                XCTAssertEqual(MarkupStyle.strokeOpacity(annotation), 0.35, accuracy: 0.001)
                let count = page.annotations.count
                controller.undo.undo(); XCTAssertEqual(page.annotations.count, count - 1)
                controller.undo.redo(); XCTAssertEqual(page.annotations.count, count)
                XCTAssertTrue(page.annotations.contains { $0 === annotation })
            }
        }
    }

    private func assertRGB(_ actual: NSColor, _ expected: NSColor, file: StaticString = #filePath, line: UInt = #line) throws {
        let a = try XCTUnwrap(actual.usingColorSpace(.deviceRGB), file: file, line: line)
        let b = try XCTUnwrap(expected.usingColorSpace(.deviceRGB), file: file, line: line)
        XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.001, file: file, line: line)
    }

    func testInspectorNativeOpacityColorUndoAndSetDefaultControls() throws {
        let name = "HighlightQualificationDefaults-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = RectangleMarkupController(defaults: defaults)
        controller.undo.groupsByEvent = false
        controller.tool = .highlight
        let inspector = MarkupPropertiesViewController(); inspector.session = controller; inspector.refresh()
        XCTAssertTrue(inspector.strokeOpacity.isEnabled); XCTAssertTrue(inspector.setAsDefault.isEnabled)
        XCTAssertFalse(inspector.weight.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(inspector.linePattern.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(inspector.strokeOpacity.doubleValue, 20, accuracy: 0.001)
        inspector.strokeOpacity.doubleValue = 45
        XCTAssertTrue(inspector.strokeOpacity.sendAction(inspector.strokeOpacity.action, to: inspector.strokeOpacity.target))
        XCTAssertEqual(controller.strokeOpacity, 0.45, accuracy: 0.001)
        inspector.stroke.color = .orange
        XCTAssertTrue(inspector.stroke.sendAction(inspector.stroke.action, to: inspector.stroke.target))
        XCTAssertTrue(inspector.setAsDefault.sendAction(inspector.setAsDefault.action, to: inspector.setAsDefault.target))
        XCTAssertEqual(inspector.defaultStatus.stringValue, "Default saved for this tool.")
        let reloaded = RectangleMarkupController(defaults: defaults); reloaded.tool = .highlight
        XCTAssertEqual(reloaded.strokeOpacity, 0.45, accuracy: 0.001)
        XCTAssertEqual(reloaded.strokeColor.usingColorSpace(.deviceRGB), NSColor.orange.usingColorSpace(.deviceRGB))
        reloaded.tool = .rectangle; XCTAssertEqual(reloaded.strokeOpacity, 1)
        try canvas { view, page in
            let session = view.rectangleMarkup
            let annotation = try record().clipboardAnnotation(contents: nil)
            page.addAnnotation(annotation); session.setSelectedItems([annotation]); session.undo.removeAllActions()
            inspector.session = session; inspector.refresh()
            XCTAssertEqual(inspector.editingContext.stringValue, "Selected markup")
            session.undo.beginUndoGrouping()
            inspector.strokeOpacity.doubleValue = 60
            XCTAssertTrue(inspector.strokeOpacity.sendAction(inspector.strokeOpacity.action, to: inspector.strokeOpacity.target))
            session.undo.endUndoGrouping()
            XCTAssertEqual(MarkupStyle.strokeOpacity(annotation), 0.60, accuracy: 0.001)
            session.undo.undo(); inspector.refresh()
            XCTAssertEqual(inspector.strokeOpacity.doubleValue, 35, accuracy: 0.001)
            session.undo.redo(); inspector.refresh()
            XCTAssertEqual(inspector.strokeOpacity.doubleValue, 60, accuracy: 0.001)
            session.undo.beginUndoGrouping()
            inspector.stroke.color = .green
            XCTAssertTrue(inspector.stroke.sendAction(inspector.stroke.action, to: inspector.stroke.target))
            session.undo.endUndoGrouping()
            try assertRGB(annotation.color, .green)
            XCTAssertEqual(MarkupStyle.strokeOpacity(annotation), 0.60, accuracy: 0.001)
            session.undo.undo()
            try assertRGB(annotation.color, .yellow)
            XCTAssertEqual(MarkupStyle.strokeOpacity(annotation), 0.60, accuracy: 0.001)
        }
    }
}
