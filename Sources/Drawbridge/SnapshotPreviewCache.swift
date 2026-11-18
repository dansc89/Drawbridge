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
    private struct Tile {
        let key: String
        let region: CGRect
    }

    private var pending = Set<String>()
    private var pendingPreviews = Set<String>()
    private var latestResolution = [String: Double]()
    private struct ViewportRequest {
        let region: CGRect
        let scale: Double
        let generation: UInt
        let readyAt: CFAbsoluteTime
    }
    private var viewports = [String: ViewportRequest]()
    private var viewportGeneration: UInt = 0
    private let viewportQuietInterval: CFAbsoluteTime = 0.08
    // Detail work must yield to user gestures. These parsers belong exclusively
    // to this serial queue, so tiles can reuse decoded fonts and image resources.
    private let queue = DispatchQueue(label: "com.drawbridge.snapshot-preview", qos: .utility)
    // First display has a separate worker so a detail render for another
    // capture cannot stall a newly pasted stamp. Each worker owns its parser.
    private let previewQueue = DispatchQueue(label: "com.drawbridge.snapshot-first-preview", qos: .userInitiated)
    private var documents = [(key: String, document: CGPDFDocument)]()
    private var completedCaptures = Set<String>()
    private var notificationScheduled = false

    // Immutable observation-only seam; callbacks run on the rendering caller's
    // thread and must be thread-safe. Production retains the default nil observer.
    private let onRenderCompleted: (@Sendable (CGRect, Double) -> Void)?

    init(onRenderCompleted: (@Sendable (CGRect, Double) -> Void)? = nil) {
        self.onRenderCompleted = onRenderCompleted
        // A 5K display can expose more than twelve 1024-pixel tiles.
        // Keep enough for a full viewport without immediately evicting its first row.
        images.totalCostLimit = 80 * 1024 * 1024; images.countLimit = 64
        previews.totalCostLimit = 48 * 1024 * 1024; previews.countLimit = 16
    }

    static func key(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func readyPreview(for key: String) -> CGImage? {
        previews.object(forKey: key as NSString)
    }

    /// A soft-mask PDF can take hundreds of milliseconds even to draw a
    /// clipped tile. Keep both parsing and initial sampling off the canvas.
    func requestPreview(data: Data, key: String, filter: SnapshotStyle? = nil) {
        guard readyPreview(for: key) == nil else { return }
        // A viewport can fill the detail queue with sixteen tiles. A newly
        // visible stamp still needs to be admitted for its first preview.
        guard lock.withLock({ pendingPreviews.count < 16 && pendingPreviews.insert(key).inserted }) else { return }
        previewQueue.async { [self] in
            let image: CGImage?
            if let provider = CGDataProvider(data: data as CFData),
               let document = CGPDFDocument(provider), let page = document.page(at: 1) {
                let media = page.getBoxRect(.mediaBox)
                // Show a bounded whole-capture preview first. Visible detail
                // tiles refine at screen density once the viewport settles.
                let scale = min(2, 1024 / max(media.width, media.height))
                image = withExtendedLifetime(document) {
                    render(page, region: media, scale: scale, tint: filter?.color)
                }
            } else {
                image = nil
            }
            if let image {
                previews.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
            }
            _ = lock.withLock { pendingPreviews.remove(key) }
            if image != nil {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.ready, object: nil, userInfo: ["captureKeys": Set([key])])
                }
            }
        }
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

    func draw(data: Data, key: String, preview: CGImage, page: CGPDFPage, visibleRegion: CGRect? = nil, deviceScale: Double? = nil, filter: SnapshotStyle? = nil, in context: CGContext) {
        let media = page.getBoxRect(.mediaBox)
        let ctm = context.ctm
        // PDFKit may oversample a cached annotation layer. The viewport density
        // is authoritative when available; its internal CTM is not the zoom.
        let scale: Double = deviceScale ?? Double(max(hypot(ctm.a, ctm.b), hypot(ctm.c, ctm.d)))
        context.interpolationQuality = .high
        let clip = context.boundingBoxOfClipPath.intersection(media)
        let tiles = requestTiles(data: data, key: key, preview: preview, media: media,
                                 visible: clip.intersection(visibleRegion ?? media),
                                 scale: scale, filter: filter, collectImages: true)
        if tiles.isEmpty {
            context.draw(preview, in: media)
            return
        }
        if let coveringTile = tiles.first(where: { $0.region.contains(clip) }),
           media.contains(context.boundingBoxOfClipPath) {
            context.draw(coveringTile.image, in: coveringTile.region)
            return
        }
        context.saveGState()
        // Clear pixels in a refined tile must reveal the underlying PDF.
        // Painting them on top of the coarse preview would double the tint.
        context.beginPath()
        context.addRect(media)
        for tile in tiles { context.addRect(tile.region) }
        context.clip(using: .evenOdd)
        context.draw(preview, in: media)
        context.restoreGState()
        for tile in tiles { context.draw(tile.image, in: tile.region) }
    }

    func prepareVisible(data: Data, key: String, preview: CGImage, page: CGPDFPage, region: CGRect, scale: Double, filter: SnapshotStyle? = nil) {
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
            _ = requestTiles(data: data, key: key, preview: preview, media: media,
                             visible: visible, scale: scale, filter: filter, collectImages: false)
        }
    }

    private func requestTiles(data: Data, key: String, preview: CGImage, media: CGRect, visible: CGRect, scale: Double, filter: SnapshotStyle?, collectImages: Bool) -> [(region: CGRect, image: CGImage)] {
        let previewScale = Double(preview.width) / media.width
        guard scale.isFinite, scale > previewScale * 1.2, scale <= 512,
              !visible.isNull, !visible.isEmpty else { return [] }
        let resolution = ceil(scale * 4) / 4
        lock.lock()
        if latestResolution.count > 64 { latestResolution.removeAll(keepingCapacity: true) }
        latestResolution[key] = resolution
        let mayRequest = viewports[key].map { CFAbsoluteTimeGetCurrent() >= $0.readyAt } ?? true
        lock.unlock()
        let span = 1024 / resolution
        let minX = Int(floor(visible.minX / span)), maxX = Int(floor(visible.maxX / span))
        let minY = Int(floor(visible.minY / span)), maxY = Int(floor(visible.maxY / span))
        var batches = [[Tile]]()
        var ready = [(region: CGRect, image: CGImage)]()
        for y in minY...maxY { for x in minX...maxX {
            let region = CGRect(x: Double(x) * span, y: Double(y) * span, width: span, height: span).intersection(media)
            // The inclusive grid endpoint may lie exactly on the viewport's
            // far edge. Such a tile contributes no pixels, but traversing its
            // vector page still consumes render work and a request-budget slot.
            guard !region.isEmpty, !region.intersection(visible).isEmpty else { continue }
            let tileKey = "\(key):\(resolution):\(x):\(y)"
            if let image = images.object(forKey: tileKey as NSString) {
                if collectImages { ready.append((region, image)) }
            } else if mayRequest {
                let tile = Tile(key: tileKey, region: region)
                // Adjacent full cells share one PDF traversal at identical
                // pixel density. Keep clipped sheet-edge cells independent.
                if let pair = batches.indices.last, batches[pair].count == 1,
                   let previous = batches[pair].first,
                   previous.region.minY == region.minY,
                   abs(previous.region.maxX - region.minX) * resolution < 0.000001,
                   abs(previous.region.width * resolution - 1024) < 0.000001,
                   abs(region.width * resolution - 1024) < 0.000001,
                   abs(region.height * resolution - 1024) < 0.000001 {
                    batches[pair].append(tile)
                } else if batches.count < 16 {
                    batches.append([tile])
                }
            }
        } }
        for batch in batches {
            request(data: data, tiles: batch, captureKey: key, scale: resolution, filter: filter)
        }
        return ready
    }

    private func request(data: Data, tiles: [Tile], captureKey: String, scale: Double, filter: SnapshotStyle?) {
        let admitted = lock.withLock {
            tiles.filter { pending.count < 16 && pending.insert($0.key).inserted }
        }
        guard !admitted.isEmpty else { return }
        queue.async { [self] in
            let current = lock.withLock {
                admitted.filter { tile in
                    if isRelevant(captureKey: captureKey, region: tile.region, scale: scale) { return true }
                    pending.remove(tile.key)
                    return false
                }
            }
            guard let first = current.first else { return }
            let region = current.dropFirst().reduce(first.region) { $0.union($1.region) }
            var rendered = false
            if let document = document(data: data, key: captureKey),
               let page = document.page(at: 1),
               let image = render(page, region: region, scale: scale, bleed: 2, tint: filter?.color) {
                if current.count == 1 {
                    store(image, key: first.key)
                    rendered = true
                } else {
                    for tile in current {
                        let x = ((tile.region.minX - region.minX) * scale).rounded()
                        if let cell = independentCell(in: image, x: x) {
                            store(cell, key: tile.key)
                            rendered = true
                        }
                    }
                }
            }
            let stillRelevant = lock.withLock {
                current.forEach { pending.remove($0.key) }
                return isRelevant(captureKey: captureKey, region: region, scale: scale)
            }
            if rendered && stillRelevant { announce(captureKey) }
        }
    }

    private func independentCell(in image: CGImage, x: CGFloat) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        guard let crop = image.cropping(to: bounds.offsetBy(dx: x, dy: 0)),
              let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        // Quartz crops share the atlas's backing allocation. Give each cached
        // cell its own allocation so eviction can release the unused half.
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(crop, in: bounds)
        return context.makeImage()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [self] in
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

    private func render(_ page: CGPDFPage, region: CGRect, scale: Double, bleed: Int = 0, tint: [Double]? = nil) -> CGImage? {
        let width = max(1, Int(ceil(region.width * scale - 0.000001)))
        let height = max(1, Int(ceil(region.height * scale - 0.000001)))
        guard width <= 2048, height <= 2048,
              let context = CGContext(data: nil, width: width + 2 * bleed, height: height + 2 * bleed, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        if tint != nil {
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        }
        // Sample beyond tile edges so strokes and PDF transparency masks
        // receive their neighboring pixels before the final crop.
        context.translateBy(x: CGFloat(bleed), y: CGFloat(bleed))
        context.scaleBy(x: Double(width) / region.width, y: Double(height) / region.height)
        context.translateBy(x: -region.minX, y: -region.minY)
        context.drawPDFPage(page)
        if let tint { SnapshotFilterRenderer.applyOverlayTint(tint, to: context) }
        let image = context.makeImage().flatMap {
            bleed == 0 ? $0 : $0.cropping(to: CGRect(x: bleed, y: bleed, width: width, height: height))
        }
        if image != nil { onRenderCompleted?(region, scale) }
        return image
    }
}
