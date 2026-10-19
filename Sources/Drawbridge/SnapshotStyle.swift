import AppKit
import PDFKit
import CryptoKit

struct SnapshotStyle: Codable, Equatable, Sendable {
    enum Filter: String, Codable, CaseIterable, Sendable {
        case original, grayscale, colorize, invert
        case blackAndWhite, sepia, brighten, darken, increaseContrast
        var title: String {
            switch self {
            case .original: "Original"
            case .grayscale: "Grayscale"
            case .colorize: "Change Color"
            case .invert: "Invert"
            case .blackAndWhite: "Black & White"
            case .sepia: "Sepia"
            case .brighten: "Brighten"
            case .darken: "Darken"
            case .increaseContrast: "Increase Contrast"
            }
        }
    }
    static let key = PDFAnnotationKey(rawValue: "DrawbridgeSnapshotStyle")
    var overlay = false
    var opacity: Double = 1
    var filter: Filter = .original
    var color: [Double] = [1, 0, 0]
    var isValid: Bool { opacity.isFinite && (0...1).contains(opacity) && color.count == 3 && color.allSatisfy { $0.isFinite && (0...1).contains($0) } }
    var json: String { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return String(data: try! encoder.encode(self), encoding: .utf8)! }
    static func read(_ annotation: PDFAnnotation) -> Self {
        guard let json = annotation.value(forAnnotationKey: key) as? String, json.utf8.count < 2048,
              let data = json.data(using: .utf8), let style = try? JSONDecoder().decode(Self.self, from: data), style.isValid else { return Self() }
        return style
    }
    var nsColor: NSColor { NSColor(deviceRed: color[0], green: color[1], blue: color[2], alpha: 1) }
}

/// Change Color uses PDF luminosity/alpha masks, retaining source vector detail.
/// Other optional filters retain their bounded raster implementation; the original
/// capture always remains embedded so returning to Original never loses detail.
enum SnapshotFilterRenderer {
    // NSCache synchronizes concurrent reads and writes internally.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSData>()
    static func filtered(_ data: Data, style: SnapshotStyle) throws -> Data {
        guard style.isValid else { throw CocoaError(.fileReadCorruptFile) }
        if style.filter == .original { return data }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let key = (digest + style.filter.rawValue + style.color.description) as NSString
        cache.totalCostLimit = 64 * 1024 * 1024
        if let cached = cache.object(forKey: key) { return cached as Data }
        guard let page = SnapshotPayload(data: data).page else { throw CocoaError(.fileReadCorruptFile) }
        if style.filter == .colorize {
            let filtered = try vectorColorize(data, style: style)
            cache.setObject(filtered as NSData, forKey: key, cost: filtered.count)
            return filtered
        }
        let size = page.getBoxRect(.mediaBox).size
        let scale = min(300.0 / 72.0, sqrt(8_000_000 / (size.width * size.height)))
        let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
        let row = width * 4
        var pixels = [UInt8](repeating: 0, count: row * height)
        let filtered: Data = try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw CocoaError(.fileWriteUnknown) }
            context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
            context.drawPDFPage(page)
            let p = bytes.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: p.count, by: 4) {
                let alpha = Double(p[i+3]) / 255
                if alpha == 0 { continue }
                let luminance = min(1, (0.2126 * Double(p[i]) + 0.7152 * Double(p[i+1]) + 0.0722 * Double(p[i+2])) / (255 * alpha))
                let rgb = (0..<3).map { Double(p[i+$0]) / (255 * alpha) }
                for c in 0..<3 {
                    let value: Double
                    switch style.filter {
                    case .original: value = rgb[c]
                    case .grayscale: value = luminance
                    case .blackAndWhite: value = luminance >= 0.5 ? 1 : 0
                    case .sepia:
                        let weights = [[0.393, 0.769, 0.189], [0.349, 0.686, 0.168], [0.272, 0.534, 0.131]]
                        value = zip(rgb, weights[c]).reduce(0) { $0 + $1.0 * $1.1 }
                    case .brighten: value = rgb[c] + 0.2
                    case .darken: value = rgb[c] - 0.2
                    case .increaseContrast: value = (rgb[c] - 0.5) * 1.5 + 0.5
                    case .invert: value = 1 - rgb[c]
                    case .colorize: value = luminance + (1-luminance) * style.color[c]
                    }
                    p[i+c] = UInt8(min(255, max(0, (value * alpha * 255).rounded())))
                }
            }
            guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            let output = NSMutableData(); var media = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: output), let pdf = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw CocoaError(.fileWriteUnknown) }
            pdf.beginPDFPage(nil); pdf.draw(image, in: media); pdf.endPDFPage(); pdf.closePDF()
            return output as Data
        }
        cache.setObject(filtered as NSData, forKey: key, cost: filtered.count)
        return filtered
    }

    /// Paint white through the source alpha, then tint through its inverse
    /// luminosity. PDF transparency evaluates the original paths/fonts/images at
    /// the reader's output resolution, not at a preselected bitmap density.
    private static func vectorColorize(_ data: Data, style: SnapshotStyle) throws -> Data {
        guard let executable = PDFTKBookmarkWriter.executableURL(),
              let source = SnapshotPayload(data: data).page else { throw CocoaError(.fileReadCorruptFile) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeSnapshotColor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.pdf")
        let jsonURL = directory.appendingPathComponent("input.json")
        let update = directory.appendingPathComponent("update.json")
        let output = directory.appendingPathComponent("output.pdf")
        try data.write(to: input)
        guard PDFTKBookmarkWriter.run(executable, arguments: ["--json=2", "--json-stream-data=inline", "--decode-level=generalized", input.path, jsonURL.path]),
              ((try? jsonURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max) <= 128 * 1024 * 1024,
              var json = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any],
              var tables = json["qpdf"] as? [[String: Any]], tables.count == 2,
              let pages = json["pages"] as? [[String: Any]], pages.count == 1,
              let pageRef = pages[0]["object"] as? String,
              var pageObject = tables[1]["obj:" + pageRef] as? [String: Any],
              var page = pageObject["value"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        var objects = tables[1]
        let refs = (page["/Contents"] as? [String]) ?? (page["/Contents"] as? String).map { [$0] } ?? []
        var commands = Data()
        for ref in refs {
            guard let object = objects["obj:" + ref] as? [String: Any],
                  let stream = object["stream"] as? [String: Any],
                  let dict = stream["dict"] as? [String: Any], dict["/Filter"] == nil,
                  let encoded = stream["data"] as? String, let bytes = Data(base64Encoded: encoded) else { throw CocoaError(.fileReadCorruptFile) }
            commands.append(bytes); commands.append(10)
        }
        var next = (objects.keys.compactMap { Int($0.dropFirst(4).split(separator: " ").first ?? "") }.max() ?? 0) + 1
        func addStream(_ dictionary: [String: Any], _ bytes: Data) -> String {
            let ref = "\(next) 0 R"; next += 1
            objects["obj:" + ref] = ["stream": ["dict": dictionary, "data": bytes.base64EncodedString()]]
            return ref
        }
        let media = source.getBoxRect(.mediaBox)
        let group: [String: Any] = ["/S": "/Transparency", "/CS": "/DeviceRGB", "/I": true]
        let form = addStream(["/Type": "/XObject", "/Subtype": "/Form", "/BBox": [media.minX, media.minY, media.maxX, media.maxY],
                              "/Resources": page["/Resources"] ?? [String: Any](), "/Group": group], commands)
        let inverse: [String: Any] = ["/FunctionType": 2, "/Domain": [0, 1], "/C0": [1], "/C1": [0], "/N": 1]
        let resources: [String: Any] = ["/ExtGState": [
            "/SourceAlpha": ["/Type": "/ExtGState", "/SMask": ["/S": "/Alpha", "/G": form]],
            "/SourceInk": ["/Type": "/ExtGState", "/SMask": ["/S": "/Luminosity", "/G": form, "/BC": [1, 1, 1], "/TR": inverse]]]]
        // Decimal formatting avoids PDF's unsupported exponent notation.
        func number(_ value: Double) -> String { String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), value) }
        let rect = "\(number(media.minX)) \(number(media.minY)) \(number(media.width)) \(number(media.height)) re f"
        let tint = style.color.map(number).joined(separator: " ")
        let drawing = "q /SourceAlpha gs 1 1 1 rg \(rect) Q\nq /SourceInk gs \(tint) rg \(rect) Q\n"
        page["/Contents"] = addStream([:], Data(drawing.utf8))
        page["/Resources"] = resources
        page["/Group"] = group
        pageObject["value"] = page; objects["obj:" + pageRef] = pageObject
        tables[1] = objects; json["qpdf"] = tables
        // qpdf consumes inline base64 literally; JSON-escaped slashes corrupt it.
        try PDFJSONPatchEncoder.data(withJSONObject: json, options: [.withoutEscapingSlashes]).write(to: update)
        guard PDFTKBookmarkWriter.run(executable, arguments: [input.path, "--update-from-json=" + update.path, output.path]) else { throw CocoaError(.fileWriteUnknown) }
        let result = try Data(contentsOf: output)
        guard SnapshotPayload(data: result).page != nil else { throw CocoaError(.fileWriteUnknown) }
        return result
    }
}
