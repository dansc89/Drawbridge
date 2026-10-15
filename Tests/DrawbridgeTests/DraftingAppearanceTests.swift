import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class DraftingAppearanceTests: XCTestCase {
    let key = PDFAnnotationKey(rawValue: "DrawbridgeHatchStyle")
    func hatch(_ preset: String, background: [Double]? = nil) throws -> String {
        var object: [String: Any] = ["preset": preset, "foreground": [0.0, 0.0, 1.0], "scale": 1.0, "angle": 0.0, "lineWidth": 0.8]
        if let background { object["background"] = background }
        return String(data: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), encoding: .utf8)!
    }
    func shape(_ preset: String) throws -> PDFAnnotation {
        let a = DrawbridgeShapeAnnotation(bounds: CGRect(x: 0,y: 0,width: 100,height: 100), forType: .square, withProperties: nil)
        a.setValue(RectangleMarkupRecord.prefix + UUID().uuidString, forAnnotationKey: RectangleMarkupRecord.identityKey)
        a.color = .red; let border = PDFBorder(); border.lineWidth = 2; a.border = border
        RectangleMarkupRecord.setPolygonFill(.green, on: a)
        a.setValue(try hatch(preset), forAnnotationKey: key)
        return a
    }
    func bitmap(_ draw: (CGContext) -> Void) throws -> NSBitmapImageRep {
        let c = try XCTUnwrap(CGContext(data: nil, width: 100,height: 100,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(x: 0,y: 0,width: 100,height: 100)); draw(c)
        return NSBitmapImageRep(cgImage: try XCTUnwrap(c.makeImage()))
    }
    func assertHatch(_ image: NSBitmapImageRep, file: StaticString = #filePath, line: UInt = #line) throws {
        var blue = 0, white = 0, green = 0
        for y in 5..<95 { for x in 5..<95 {
            let c = try XCTUnwrap(image.colorAt(x: x,y: y)?.usingColorSpace(.deviceRGB))
            if c.blueComponent > c.redComponent + 0.15 && c.blueComponent > c.greenComponent + 0.15 { blue += 1 }
            if c.redComponent > 0.95 && c.greenComponent > 0.95 && c.blueComponent > 0.95 { white += 1 }
            if c.greenComponent > 0.7 && c.redComponent < 0.5 && c.blueComponent < 0.5 { green += 1 }
        } }
        XCTAssertGreaterThan(blue, 15, file: file,line: line)
        XCTAssertGreaterThan(white, 500, "Transparent gaps must not paint solid fill", file: file,line: line)
        XCTAssertEqual(green, 0, file: file,line: line)
    }
    func testAllDraftingPresetsRenderIndependentLinesWithTransparentGaps() throws {
        for preset in ["diagonal", "crosshatch", "horizontal", "vertical", "grid", "brick", "concrete", "sand", "earth", "insulation", "wood"] {
            let a = try shape(preset)
            try assertHatch(bitmap { a.draw(with: .mediaBox, in: $0) })
        }
    }
    func testHatchSurvivesClipboardRecordAndSavedAppearance() throws {
        let a = try shape("brick")
        let doc = PDFDocument(); let page = PDFPage(); page.setBounds(CGRect(x: 0,y: 0,width: 100,height: 100), for: .mediaBox); doc.insert(page, at: 0); page.addAnnotation(a)
        let record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: a, pageIndex: 0))
        let decoded = try JSONDecoder().decode(RectangleMarkupRecord.self, from: JSONEncoder().encode(record))
        let pasted = try decoded.clipboardAnnotation(contents: nil)
        XCTAssertEqual(DraftingHatch.read(pasted), DraftingHatch.read(a))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.pdf"), output = directory.appendingPathComponent("output.pdf")
        let blank = PDFDocument(); let blankPage = PDFPage(); blankPage.setBounds(page.bounds(for: .mediaBox), for: .mediaBox); blank.insert(blankPage, at: 0)
        XCTAssertTrue(blank.write(to: source))
        XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: output, pageLabels: [:], records: [record]))
        let reopened = try XCTUnwrap(PDFDocument(url: output)); let saved = try XCTUnwrap(reopened.page(at: 0))
        XCTAssertEqual(saved.annotations.first.flatMap(DraftingHatch.read), DraftingHatch.read(a))
        try assertHatch(bitmap { saved.draw(with: .mediaBox, to: $0) })
    }
    func testHatchCornerPixelsInLiveAndSavedPDFAtRotatedAngles() throws {
        let box = CGRect(x: 0, y: 0, width: 600, height: 600)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.pdf")
        let blank = PDFDocument(); let blankPage = PDFPage()
        blankPage.setBounds(box, for: .mediaBox); blank.insert(blankPage, at: 0)
        XCTAssertTrue(blank.write(to: source))
        func render(_ draw: (CGContext) -> Void) throws -> NSBitmapImageRep {
            let c = try XCTUnwrap(CGContext(data: nil, width: 600, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            c.setFillColor(NSColor.white.cgColor); c.fill(box); draw(c)
            return NSBitmapImageRep(cgImage: try XCTUnwrap(c.makeImage()))
        }
        func cornerCounts(_ image: NSBitmapImageRep) throws -> [Int] {
            try [(10,10),(530,10),(10,530),(530,530)].map { origin in
                var count = 0
                for y in origin.1..<(origin.1 + 60) { for x in origin.0..<(origin.0 + 60) {
                    let c = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if c.blueComponent > c.redComponent + 0.15 && c.blueComponent > c.greenComponent + 0.15 { count += 1 }
                } }
                return count
            }
        }
        for angle in [0.0, 27.0, 73.0] {
            var diagonalCounts = [[Int]]()
            for preset in DraftingHatch.Preset.allCases where preset != .solid {
                let a = try shape(preset.rawValue); a.bounds = box
                var style = try XCTUnwrap(DraftingHatch.read(a)); style.angle = angle
                DraftingHatch.apply(style, to: a)
                let doc = PDFDocument(); let page = PDFPage(); page.setBounds(box, for: .mediaBox)
                doc.insert(page, at: 0); page.addAnnotation(a)
                let record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: a, pageIndex: 0))
                let output = directory.appendingPathComponent("output.pdf")
                XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: output, pageLabels: [:], records: [record]))
                let reopened = try XCTUnwrap(PDFDocument(url: output)); let saved = try XCTUnwrap(reopened.page(at: 0))
                let counts = try [cornerCounts(render { a.draw(with: .mediaBox, in: $0) }), cornerCounts(render { saved.draw(with: .mediaBox, to: $0) })]
                for (renderer, corners) in counts.enumerated() {
                    for count in corners { XCTAssertGreaterThan(count, 3, "\(preset) angle=\(angle) renderer=\(renderer): empty corner band") }
                }
                if preset == .diagonal { diagonalCounts = counts }
                if preset == .crosshatch {
                    for renderer in 0..<2 { for corner in 0..<4 {
                        XCTAssertGreaterThan(Double(counts[renderer][corner]), Double(diagonalCounts[renderer][corner]) * 1.3, "Both crosshatch families must reach each corner, angle=\(angle), renderer=\(renderer)")
                    } }
                }
            }
        }
    }

    func testHatchExtremeDimensionsAreBoundedWithoutRasterAllocation() {
        for preset in DraftingHatch.Preset.allCases {
            var style = DraftingHatch(); style.preset = preset; style.angle = 37
            for size in [CGSize(width: 1.7e308, height: 1.7e308), CGSize(width: CGFloat.greatestFiniteMagnitude, height: 1), CGSize(width: CGFloat.infinity, height: 600), CGSize(width: CGFloat.nan, height: 600), CGSize(width: -1, height: 600), .zero] {
                XCTAssertTrue(style.lines(size: size).isEmpty, "Reject unrenderable geometry for \(preset)")
            }
            for size in [CGSize(width: 1e9, height: 1e9), CGSize(width: 1e9, height: 1), CGSize(width: 1, height: 1e9)] {
                let lines = style.lines(size: size)
                XCTAssertLessThan(lines.count, 70_000)
                XCTAssertTrue(lines.joined().allSatisfy { $0.x.isFinite && $0.y.isFinite })
            }
        }
    }

    func testExtendedFiltersTransformPixelsAndPreserveRawModes() throws {
        XCTAssertEqual(Array(SnapshotStyle.Filter.allCases.prefix(4)).map(\.rawValue), ["original", "grayscale", "colorize", "invert"])
        let data = NSMutableData(); var box = CGRect(x: 0,y: 0,width: 100,height: 100)
        let c = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        c.beginPDFPage(nil); c.setFillColor(NSColor(deviceRed: 0.4, green: 0.3, blue: 0.2, alpha: 1).cgColor); c.fill(box); c.endPDFPage(); c.closePDF()
        let original = try bitmap { $0.drawPDFPage(SnapshotPayload(data: data as Data).page!) }.colorAt(x: 50,y: 50)!.usingColorSpace(.deviceRGB)!
        for raw in ["blackAndWhite", "sepia", "brighten", "darken", "increaseContrast"] {
            guard let filter = SnapshotStyle.Filter(rawValue: raw) else { XCTFail("Missing filter \(raw)"); continue }
            var style = SnapshotStyle(); style.filter = filter
            let result = try SnapshotFilterRenderer.filtered(data as Data, style: style)
            let pixel = try bitmap { $0.drawPDFPage(SnapshotPayload(data: result).page!) }.colorAt(x: 50,y: 50)!.usingColorSpace(.deviceRGB)!
            switch raw {
            case "blackAndWhite": XCTAssertLessThan(pixel.redComponent, 0.02); XCTAssertLessThan(pixel.greenComponent, 0.02)
            case "sepia": XCTAssertGreaterThan(pixel.redComponent, pixel.blueComponent + 0.05)
            case "brighten": XCTAssertGreaterThan(pixel.redComponent, original.redComponent + 0.05)
            default: XCTAssertLessThan(pixel.redComponent, original.redComponent - 0.02)
            }
        }
    }
}
