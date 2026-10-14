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
    private struct ViewportRequest {
        let region: CGRect
        let scale: Double
        let generation: UInt
        let readyAt: CFAbsoluteTime
    }
    private var viewports = [String: ViewportRequest]()
    private var viewportGeneration: UInt = 0
    private let viewportQuietInterval: CFAbsoluteTime = 0.18
    // Detail work must yield to user gestures. These parsers belong exclusively
    // to this serial queue, so tiles can reuse decoded fonts and image resources.
    private let queue = DispatchQueue(label: "com.drawbridge.snapshot-preview", qos: .utility)
    private var documents = [(key: String, document: CGPDFDocument)]()
    private var completedCaptures = Set<String>()
    private var notificationScheduled = false

    // Immutable observation-only seam; callbacks run on the rendering caller's
    // thread and must be thread-safe. Production retains the default nil observer.
    private let onRenderCompleted: (@Sendable (CGRect, Double) -> Void)?

    init(onRenderCompleted: (@Sendable (CGRect, Double) -> Void)? = nil) {
        self.onRenderCompleted = onRenderCompleted
        images.totalCostLimit = 48 * 1024 * 1024; images.countLimit = 64
        previews.totalCostLimit = 32 * 1024 * 1024; previews.countLimit = 16
    }

    static func key(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func prepare(_ data: Data, key: String, page: CGPDFPage) -> CGImage? {
        // Compressed vector PDFs can be small but expensive to paint. Always
        // prepare a bounded editing preview rather than guessing from file size.
        if let cached = previews.object(forKey: key as NSString) { return cached }
        let media = page.getBoxRect(.mediaBox)
        let scale = min(1, 1024 / max(media.width, media.height))
        guard let image = render(page, region: media, scale: scale) else { return nil }
        previews.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    func draw(data: Data, key: String, preview: CGImage, page: CGPDFPage, visibleRegion: CGRect? = nil, deviceScale: Double? = nil, in context: CGContext) {
        let media = page.getBoxRect(.mediaBox)
        let ctm = context.ctm
        // PDFKit may oversample a cached annotation layer. The viewport density
        // is authoritative when available; its internal CTM is not the zoom.
        let scale: Double = deviceScale ?? Double(max(hypot(ctm.a, ctm.b), hypot(ctm.c, ctm.d)))
        context.interpolationQuality = .high
        context.draw(preview, in: media)
        requestTiles(data: data, key: key, preview: preview, media: media,
                     visible: context.boundingBoxOfClipPath.intersection(media).intersection(visibleRegion ?? media),
                     scale: scale, context: context)
    }

    func prepareVisible(data: Data, key: String, preview: CGImage, page: CGPDFPage, region: CGRect, scale: Double) {
        let media = page.getBoxRect(.mediaBox)
        let visible = region.intersection(media)
        lock.lock()
        if let old = viewports[key], old.region == visible, old.scale == scale {
            lock.unlock()
            return
        }
        if viewports.count > 64 { viewports.removeAll(keepingCapacity: true) }
        viewportGeneration &+= 1
        let generation = viewportGeneration
        viewports[key] = ViewportRequest(region: visible, scale: scale, generation: generation,
                                        readyAt: CFAbsoluteTimeGetCurrent() + viewportQuietInterval)
        latestResolution[key] = ceil(scale * 4) / 4
        lock.unlock()
        // Tiny zoom steps otherwise queue expensive traversals for resolutions
        // that have already gone out of view. Render only the settled viewport.
        queue.asyncAfter(deadline: .now() + viewportQuietInterval) { [self] in
            lock.lock()
            let current = viewports[key]?.generation == generation
            lock.unlock()
            guard current else { return }
            requestTiles(data: data, key: key, preview: preview, media: media,
                         visible: visible, scale: scale, context: nil)
        }
    }

    private func requestTiles(data: Data, key: String, preview: CGImage, media: CGRect, visible: CGRect, scale: Double, context: CGContext?) {
        let previewScale = Double(preview.width) / media.width
        guard scale.isFinite, scale > previewScale * 1.2, scale <= 512,
              !visible.isNull, !visible.isEmpty else { return }
        let resolution = ceil(scale * 4) / 4
        lock.lock()
        if latestResolution.count > 64 { latestResolution.removeAll(keepingCapacity: true) }
        latestResolution[key] = resolution
        let mayRequest = viewports[key].map { CFAbsoluteTimeGetCurrent() >= $0.readyAt } ?? true
        lock.unlock()
        let span = 1024 / resolution
        let minX = Int(floor(visible.minX / span)), maxX = Int(floor(visible.maxX / span))
        let minY = Int(floor(visible.minY / span)), maxY = Int(floor(visible.maxY / span))
        var requested = 0
        for y in minY...maxY { for x in minX...maxX {
            let region = CGRect(x: Double(x) * span, y: Double(y) * span, width: span, height: span).intersection(media)
            // The inclusive grid endpoint may lie exactly on the viewport's
            // far edge. Such a tile contributes no pixels, but traversing its
            // vector page still consumes render work and a request-budget slot.
            guard !region.isEmpty, !region.intersection(visible).isEmpty else { continue }
            let tileKey = "\(key):\(resolution):\(x):\(y)"
            if let image = images.object(forKey: tileKey as NSString) {
                context?.draw(image, in: region)
            } else if mayRequest && requested < 8 {
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
            let relevant = isRelevant(captureKey: captureKey, region: region, scale: scale)
            if !relevant { pending.remove(key) }
            lock.unlock()
            guard relevant else { return }
            // Queue-owned parsers never share PDFKit's mutable document.
            var rendered = false
            if let document = document(data: data, key: captureKey),
               let page = document.page(at: 1), let image = render(page, region: region, scale: scale) {
                store(image, key: key)
                rendered = true
            }
            lock.lock()
            pending.remove(key)
            let stillRelevant = isRelevant(captureKey: captureKey, region: region, scale: scale)
            lock.unlock()
            if rendered && stillRelevant { announce(captureKey) }
        }
    }

    // Caller holds lock. Discard old-resolution and offscreen work before drawing
    // and avoid announcing a completed tile in the middle of another gesture.
    private func isRelevant(captureKey: String, region: CGRect, scale: Double) -> Bool {
        guard latestResolution[captureKey] == scale else { return false }
        guard let viewport = viewports[captureKey] else { return true }
        return CFAbsoluteTimeGetCurrent() >= viewport.readyAt && viewport.region.intersects(region)
    }

    // Called only on the serial rendering queue. Retain at most four captures.
    private func document(data: Data, key: String) -> CGPDFDocument? {
        if let index = documents.firstIndex(where: { $0.key == key }) {
            let entry = documents.remove(at: index)
            documents.append(entry)
            return entry.document
        }
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { return nil }
        documents.append((key, document))
        if documents.count > 4 { documents.removeFirst() }
        return document
    }

    private func announce(_ key: String) {
        lock.lock()
        completedCaptures.insert(key)
        guard !notificationScheduled else { lock.unlock(); return }
        notificationScheduled = true
        lock.unlock()
        // Coalesce fast tiles instead of rebuilding PDFKit's page for each tile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            lock.lock()
            let keys = completedCaptures
            completedCaptures.removeAll(keepingCapacity: true)
            notificationScheduled = false
            lock.unlock()
            NotificationCenter.default.post(name: Self.ready, object: nil, userInfo: ["captureKeys": keys])
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
        let image = context.makeImage()
        if image != nil { onRenderCompleted?(region, scale) }
        return image
    }
}
