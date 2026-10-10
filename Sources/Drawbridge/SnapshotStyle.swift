import AppKit
import PDFKit
import CryptoKit

struct SnapshotStyle: Codable, Equatable, Sendable {
    enum Filter: String, Codable, CaseIterable, Sendable {
        case original, grayscale, colorize, invert
        var title: String { switch self { case .original: return "Original"; case .grayscale: return "Grayscale"; case .colorize: return "Colorize"; case .invert: return "Invert" } }
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

/// Optional filters are rendered once at a bounded high resolution. The original
/// vector capture remains embedded so returning to Original never loses detail.
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
                for c in 0..<3 {
                    let value: Double
                    switch style.filter {
                    case .original: value = Double(p[i+c]) / (255 * alpha)
                    case .grayscale: value = luminance
                    case .invert: value = 1 - Double(p[i+c]) / (255 * alpha)
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
}
