import AppKit
import PDFKit
import CryptoKit

/// Editing previews are bounded and shared between repeated pastes. The embedded
/// PDF remains the source for capture, printing, thumbnails and saved appearances.
final class SnapshotPreviewCache: @unchecked Sendable {
    static let shared = SnapshotPreviewCache()
    static let ready = Notification.Name("DrawbridgeSnapshotPreviewReady")
    private let images = NSCache<NSString, CGImage>()
    private let previews = NSCache<NSString, CGImage>()
    private let lock = NSLock()
    private var pending = Set<String>()
    private var latestResolution = [String: Double]()
    private let queue = DispatchQueue(label: "com.drawbridge.snapshot-preview", qos: .userInitiated)

    private init() {
        images.totalCostLimit = 48 * 1024 * 1024; images.countLimit = 64
        previews.totalCostLimit = 32 * 1024 * 1024; previews.countLimit = 16
    }

    static func key(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func prepare(_ data: Data, key: String, page: CGPDFPage) -> CGImage? {
        guard data.count > 1_000_000 else { return nil }
        if let cached = previews.object(forKey: key as NSString) { return cached }
        let media = page.getBoxRect(.mediaBox)
        let scale = min(2, 1024 / max(media.width, media.height))
        guard let image = render(page, region: media, scale: scale) else { return nil }
        previews.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    func draw(data: Data, key: String, preview: CGImage, page: CGPDFPage, visibleRegion: CGRect? = nil, in context: CGContext) {
        let media = page.getBoxRect(.mediaBox)
        let ctm = context.ctm
        let scale = max(hypot(ctm.a, ctm.b), hypot(ctm.c, ctm.d))
        let previewScale = Double(preview.width) / media.width
        context.interpolationQuality = .high
        context.draw(preview, in: media)
        // A preview keeps zooming responsive. Visible tiles then replace it at
        // the actual device resolution, without rasterizing the whole sheet.
        guard scale.isFinite, scale > previewScale * 1.2, scale <= 64 else { return }
        let resolution = ceil(scale * 4) / 4
        lock.lock()
        if latestResolution.count > 64 { latestResolution.removeAll(keepingCapacity: true) }
        latestResolution[key] = resolution
        lock.unlock()
        let span = 512 / resolution
        let visible = context.boundingBoxOfClipPath.intersection(media).intersection(visibleRegion ?? media)
        guard !visible.isNull, !visible.isEmpty else { return }
        let minX = Int(floor(visible.minX / span)), maxX = Int(floor(visible.maxX / span))
        let minY = Int(floor(visible.minY / span)), maxY = Int(floor(visible.maxY / span))
        // PDFKit can request full-page tiles. Bound each draw's queued work and
        // let subsequent visible redraws request the remaining tiles.
        var requested = 0
        for y in minY...maxY { for x in minX...maxX {
            let region = CGRect(x: Double(x) * span, y: Double(y) * span, width: span, height: span).intersection(media)
            guard !region.isEmpty else { continue }
            let tileKey = "\(key):\(resolution):\(x):\(y)"
            if let image = images.object(forKey: tileKey as NSString) {
                context.draw(image, in: region)
            } else if requested < 8 {
                request(data: data, key: tileKey, captureKey: key, region: region, scale: resolution)
                requested += 1
            }
        } }
    }

    private func request(data: Data, key: String, captureKey: String, region: CGRect, scale: Double) {
        lock.lock()
        guard pending.count < 16, !pending.contains(key) else { lock.unlock(); return }
        pending.insert(key); lock.unlock()
        queue.async { [self] in
            lock.lock()
            let relevant = latestResolution[captureKey] == scale
            if !relevant { pending.remove(key) }
            lock.unlock()
            guard relevant else { return }
            // Each job owns its PDF parser. Never share PDFKit pages or their
            // mutable document with the background rendering queue.
            if let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
               let page = document.page(at: 1), let image = render(page, region: region, scale: scale) {
                store(image, key: key)
            }
            lock.lock(); pending.remove(key); lock.unlock()
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.ready, object: nil) }
        }
    }

    private func store(_ image: CGImage, key: String) {
        images.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    private func render(_ page: CGPDFPage, region: CGRect, scale: Double) -> CGImage? {
        let width = max(1, Int(ceil(region.width * scale - 0.000001)))
        let height = max(1, Int(ceil(region.height * scale - 0.000001)))
        guard width <= 2048, height <= 2048,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: Double(width) / region.width, y: Double(height) / region.height)
        context.translateBy(x: -region.minX, y: -region.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
