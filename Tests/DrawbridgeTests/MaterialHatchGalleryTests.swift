import AppKit
import CoreText
import PDFKit
import XCTest
@testable import Drawbridge

/// Every case is exercised on every run. Set DRAWBRIDGE_HATCH_GALLERY_DIR to retain
/// labelled PNG contact sheets, source/output PDFs, and a case-level JSON manifest.
@MainActor final class MaterialHatchGalleryTests: XCTestCase {
    struct Case {
        let annotation: PDFAnnotation
        let path: CGPath
        let shape: String
        let scale: Double
        let angle: Double
        let colored: Bool
        let cell: CGRect
    }
    func context(_ width: Int, _ height: Int) throws -> CGContext {
        let c = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(x: 0, y: 0, width: width, height: height)); return c
    }
    func label(_ text: String, x: CGFloat, y: CGFloat, in c: CGContext) {
        c.saveGState(); defer { c.restoreGState() }
        c.textMatrix = .identity; c.textPosition = CGPoint(x: x, y: y)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.black]
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), c)
    }
    func testFixtureSamplingAndMultiRepeatProof() throws {
        // Keep the old failure as a control: fine legacy sand is real ink,
        // not missing geometry; 1x cannot reliably classify it over yellow.
        for preset in [DraftingHatch.Preset.sand, .expandedMetal] {
            for extent in [108, 576] {
                for density in [1, 3] {
                    let bounds = CGRect(x: 4, y: 4, width: extent, height: extent)
                    let annotation = DrawbridgeShapeAnnotation(bounds: bounds, forType: .square, withProperties: nil)
                    annotation.color = .red
                    let border = PDFBorder(); border.lineWidth = 1; annotation.border = border
                    let style = DraftingHatch(preset: preset, foreground: [0,0,1], background: [1,0.9,0.55], scale: preset == .sand ? 0.25 : 4, lineWidth: 0.5)
                    DraftingHatch.apply(style, to: annotation)
                    let c = try context((extent+8)*density, (extent+8)*density)
                    c.scaleBy(x: CGFloat(density), y: CGFloat(density))
                    annotation.draw(with: .mediaBox, in: c)
                    let bytes = try XCTUnwrap(c.data).assumingMemoryBound(to: UInt8.self)
                    var blue = 0
                    for y in (6*density)..<((extent+2)*density) { for x in (6*density)..<((extent+2)*density) {
                        let o = y*c.bytesPerRow+x*4
                        if Double(bytes[o+2])/255 > 0.64 && Double(bytes[o])/255 < 0.95 && Double(bytes[o+1])/255 < 0.89 { blue += 1 }
                    } }
                    print("FIXTURE_PROOF \(preset) extent=\(extent) density=\(density) blue=\(blue)")
                    if density == 3 && (preset == .sand || extent == 576) { XCTAssertGreaterThan(blue, 0) }
                }
            }
        }
    }
    func testEveryHatchShapeScaleAngleBackgroundLiveAndPortablePDF() throws {
        let requested = ProcessInfo.processInfo.environment["DRAWBRIDGE_HATCH_GALLERY_DIR"]
        let root = requested.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if requested == nil { try? FileManager.default.removeItem(at: root) } }
        // Real PDF geometry must contain multiple repeats even at 400% (192pt
        // new-material repeat). Contact sheets are presentation, not pixel evidence.
        let box = CGRect(x: 0, y: 0, width: 7488, height: 3744)
        let sheet = CGRect(x: 0, y: 0, width: 1584, height: 960)
        let density = 3
        let blank = PDFDocument(); let blankPage = PDFPage(); blankPage.setBounds(box, for: .mediaBox); blank.insert(blankPage, at: 0)
        let source = root.appendingPathComponent("source.pdf"); XCTAssertTrue(blank.write(to: source))
        var manifest = [[String: Any]]()
        for preset in DraftingHatch.Preset.allCases {
            try autoreleasepool {
                let document = PDFDocument(); let page = PDFPage(); page.setBounds(box, for: .mediaBox); document.insert(page, at: 0)
                var cases = [Case]()
                for shape in ["Square", "Circle", "Polygon"] { for scale in [0.25, 1.0, 4.0] { for angle in [0.0, 45, 90, 135] { for colored in [false, true] {
                    let index = cases.count
                    let cell = CGRect(x: (index % 12) * 132, y: (5 - index / 12) * 152, width: 132, height: 152)
                    let extent = max(108, 3 * 48 * scale)
                    let bounds = CGRect(x: (index % 12) * 624 + 12, y: (5 - index / 12) * 624 + 12, width: Int(extent), height: Int(extent))
                    let a: PDFAnnotation
                    let path = CGMutablePath()
                    if shape == "Polygon" {
                        a = DrawbridgePolygonAnnotation(bounds: bounds, forType: PDFAnnotationSubtype(rawValue: "/Polygon"), withProperties: nil)
                        // Concave polygon exercises clipping at internal corners, not just bounds.
                        let unitPoints: [(CGFloat, CGFloat)] = [(0,0),(1,0),(1,0.45),(0.5,0.45),(0.5,1),(0,1)]
                        let inner = bounds.insetBy(dx: 0.5, dy: 0.5)
                        let points: [CGPoint] = unitPoints.map { point in
                            CGPoint(x: inner.minX + point.0 * inner.width, y: inner.minY + point.1 * inner.height)
                        }
                        RectangleMarkupRecord.setVertices(points, on: a)
                        path.addLines(between: points); path.closeSubpath()
                    } else {
                        a = DrawbridgeShapeAnnotation(bounds: bounds, forType: shape == "Circle" ? .circle : .square, withProperties: nil)
                        if shape == "Circle" { path.addEllipse(in: bounds.insetBy(dx: 0.5, dy: 0.5)) }
                        else { path.addRect(bounds.insetBy(dx: 0.5, dy: 0.5)) }
                    }
                    a.setValue(RectangleMarkupRecord.prefix + UUID().uuidString, forAnnotationKey: RectangleMarkupRecord.identityKey)
                    a.color = .red; let border = PDFBorder(); border.lineWidth = 1; a.border = border
                    RectangleMarkupRecord.setPolygonFill(.green, on: a)
                    let style = DraftingHatch(preset: preset, foreground: [0,0,1], background: colored ? [1,0.9,0.55] : nil,
                        scale: scale, angle: angle, lineWidth: 0.5)
                    DraftingHatch.apply(style, to: a); page.addAnnotation(a)
                    let record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: a, pageIndex: 0))
                    let decoded = try JSONDecoder().decode(RectangleMarkupRecord.self, from: JSONEncoder().encode(record))
                    let pasted = try decoded.clipboardAnnotation(contents: nil)
                    XCTAssertEqual(DraftingHatch.read(pasted), style, "Clipboard/record \(preset) \(shape)")
                    cases.append(Case(annotation: a, path: path, shape: shape, scale: scale, angle: angle, colored: colored, cell: cell))
                } } } }
                let records = try cases.map { try XCTUnwrap(RectangleMarkupRecord.capture(annotation: $0.annotation, pageIndex: 0)) }
                let output = root.appendingPathComponent("\(preset.rawValue).pdf")
                XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: records))
                let reopened = try XCTUnwrap(PDFDocument(url: output)); let saved = try XCTUnwrap(reopened.page(at: 0))
                XCTAssertEqual(saved.annotations.count, cases.count)
                let restored = Dictionary(uniqueKeysWithValues: saved.annotations.map { (RectangleMarkupRecord.identity($0) ?? "", $0) })
                for item in cases {
                    let identity = try XCTUnwrap(RectangleMarkupRecord.identity(item.annotation))
                    XCTAssertEqual(restored[identity].flatMap(DraftingHatch.read), DraftingHatch.read(item.annotation))
                }
                var counts = [[Int]]()
                for renderer in ["live", "pdf"] {
                    let c = try context(Int(sheet.width)*density, Int(sheet.height)*density)
                    c.scaleBy(x: CGFloat(density), y: CGFloat(density))
                    var rendererCounts = [Int]()
                    for (index, item) in cases.enumerated() {
                        let b = item.annotation.bounds
                        let crop = b.insetBy(dx: -4, dy: -4)
                        let native = try context(Int(crop.width)*density, Int(crop.height)*density)
                        native.scaleBy(x: CGFloat(density), y: CGFloat(density))
                        native.translateBy(x: -crop.minX, y: -crop.minY)
                        if renderer == "live" { item.annotation.draw(with: .mediaBox, in: native) }
                        else {
                            // Render the actual reopened portable page, clipped by the
                            // bitmap extent, never a reconstructed live annotation.
                            saved.draw(with: .mediaBox, to: native)
                        }
                        let image = try XCTUnwrap(native.makeImage())
                        let bytes = try XCTUnwrap(native.data).assumingMemoryBound(to: UInt8.self)
                        let nearPath = item.path.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 10)
                        var blue = 0, white = 0, green = 0, outside = 0, yellow = 0
                        for y in 0..<native.height { for x in 0..<native.width {
                            // CGContext's bottom-up page coordinates versus image top-down rows.
                            let offset = (native.height-1-y)*native.bytesPerRow + x*4
                            let red = Double(bytes[offset])/255, g = Double(bytes[offset+1])/255, blueValue = Double(bytes[offset+2])/255
                            let p = CGPoint(x: crop.minX + (Double(x)+0.5)/Double(density), y: crop.minY + (Double(y)+0.5)/Double(density))
                            let inside = item.path.contains(p)
                            // Thin antialiased strokes blend with the selected underpaint.
                            // Over yellow, a visible blue stroke need not be blue-dominant.
                            let isBlue = item.colored
                                ? blueValue > 0.64 && red < 0.95 && g < 0.89
                                : blueValue > red + 0.15 && blueValue > g + 0.15
                            if inside {
                                if isBlue { blue += 1 }
                                // Partial white/yellow coverage is valid transparency at 25% scale;
                                // requiring pure pixels mistakes antialiasing for opaque fill.
                                if red > 0.7 && g > 0.7 && blueValue > 0.95 { white += 1 }
                                if g > 0.7 && red < 0.5 && blueValue < 0.5 { green += 1 }
                                if red > 0.55 && g > 0.45 && red > blueValue + 0.05 { yellow += 1 }
                            } else if isBlue {
                                // Antialiasing at the path edge is allowed, leakage beyond 2pt is not.
                                let near = nearPath.contains(p)
                                if !near { outside += 1 }
                            }
                        } }
                        let description = "\(preset) \(item.shape) \(item.scale) \(item.angle) \(item.colored) \(renderer)"
                        if preset != .solid {
                            XCTAssertGreaterThan(blue, 0, "Missing strokes: \(description)")
                            XCTAssertEqual(green, 0, "Underlying solid fill: \(description)")
                            if item.colored { XCTAssertGreaterThan(yellow, 10, "Missing background: \(description)") }
                            else { XCTAssertGreaterThan(white, 100, "Lost transparency: \(description)") }
                        }
                        XCTAssertEqual(outside, 0, "Clipping leak: \(description)")
                        rendererCounts.append(blue)
                        c.draw(image, in: CGRect(x: item.cell.minX+8, y: item.cell.minY+26, width: 116, height: 116))
                        label("\(item.shape) \(Int(item.scale*100))% \(Int(item.angle))°", x: item.cell.minX+4, y: item.cell.minY+16, in: c)
                        label(item.colored ? "colored background" : "transparent", x: item.cell.minX+4, y: item.cell.minY+3, in: c)
                        if renderer == "live" {
                            manifest.append(["preset": preset.rawValue, "title": preset.title, "shape": item.shape, "percentage": item.scale*100,
                                "angle": item.angle, "background": item.colored ? "colored" : "transparent", "cell": index,
                                "rectBottomLeft": [item.cell.minX,item.cell.minY,item.cell.width,item.cell.height],
                                "nativeBounds": [b.minX,b.minY,b.width,b.height], "rasterDensity": density,
                                "bluePixels": blue, "whitePixels": white, "yellowPixels": yellow,
                                "live": "\(preset.rawValue)-live.png", "pdf": "\(preset.rawValue)-pdf.png", "savedPDF": output.lastPathComponent,
                                "executed": true])
                        } else {
                            let manifestIndex = manifest.count - cases.count + index
                            manifest[manifestIndex]["pdfBluePixels"] = blue
                            manifest[manifestIndex]["pdfWhitePixels"] = white
                            manifest[manifestIndex]["pdfYellowPixels"] = yellow
                        }
                    }
                    counts.append(rendererCounts)
                    label("\(preset.title) [\(preset.rawValue)] — \(renderer) — 72 cases", x: 12, y: 940, in: c)
                    if requested != nil {
                        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(c.makeImage()))
                        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("\(preset.rawValue)-\(renderer).png"))
                    }
                }
                // Both real renderers must retain substantial stroke coverage, allowing raster differences.
                for i in cases.indices where preset != .solid {
                    let ratio = Double(counts[0][i]+1) / Double(counts[1][i]+1)
                    XCTAssertTrue((0.35...2.85).contains(ratio), "Live/PDF stroke mismatch \(preset) case \(i): \(ratio)")
                }
                if requested == nil { try? FileManager.default.removeItem(at: output) }
            }
        }
        XCTAssertEqual(manifest.count, DraftingHatch.Preset.allCases.count * 72)
        try JSONSerialization.data(withJSONObject: ["cases": manifest, "caseCount": manifest.count, "renderCount": manifest.count*2,
            "visualReviewPerformed": false, "coordinateSystem": "bottom-left page points; PNG rows top-down"], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("manifest.json"))
    }
}
