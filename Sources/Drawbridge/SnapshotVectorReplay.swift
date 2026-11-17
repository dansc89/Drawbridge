import Foundation
import CoreGraphics

/// A PDF-context vector display list, never serialized as AP.
/// Source admission is bounded, not an estimate/guarantee of native heap usage.
/// Rendering is serialized per native owner.
final class SnapshotVectorReplay: @unchecked Sendable {
    private final class Admission: @unchecked Sendable {
        let lock = NSLock()
        var bytes = 0
        var entries = 0
        func hasCapacity(for count: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return entries < 8 && bytes + count <= 32 * 1024 * 1024
        }
        func acquire(_ count: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard count > 0, count <= SnapshotVectorReplay.maximumSourceBytes, entries < 8,
                  bytes + count <= 32 * 1024 * 1024 else { return false }
            bytes += count; entries += 1; return true
        }
        func release(_ count: Int) {
            lock.lock(); defer { lock.unlock() }
            bytes -= count; entries -= 1
        }
    }
    static let maximumSourceBytes = 8 * 1024 * 1024
    private static let admission = Admission()

    static func hasCapacity(for count: Int) -> Bool {
        admission.hasCapacity(for: count)
    }
    private let lock = NSLock()
    private let document: CGPDFDocument
    private let page: CGPDFPage
    private let consumer: CGDataConsumer
    private let owner: CGContext
    private var layer: CGLayer?
    private let media: CGRect
    private let sourceBytes: Int

    init?(document: CGPDFDocument, sourceBytes: Int) {
        guard let page = document.page(at: 1) else { return nil }
        var media = page.getBoxRect(.mediaBox)
        guard media.width > 0, media.height > 0, media.width.isFinite, media.height.isFinite,
              Self.admission.acquire(sourceBytes) else { return nil }
        // Discard the recording PDF output instead of retaining a growing data
        // buffer. The open PDF context still owns the vector layer's resources.
        var callbacks = CGDataConsumerCallbacks(putBytes: { _, _, count in count }, releaseConsumer: nil)
        guard let consumer = CGDataConsumer(info: nil, cbks: &callbacks),
              let owner = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            Self.admission.release(sourceBytes); return nil
        }
        owner.beginPDFPage(nil)
        guard let layer = CGLayer(owner, size: media.size, auxiliaryInfo: nil), let recording = layer.context else {
            owner.endPDFPage(); owner.closePDF(); Self.admission.release(sourceBytes); return nil
        }
        recording.translateBy(x: -media.minX, y: -media.minY)
        recording.drawPDFPage(page)
        self.document = document; self.page = page; self.media = media
        self.consumer = consumer; self.owner = owner; self.layer = layer; self.sourceBytes = sourceBytes
    }

    static var onDraw: (() -> Void)? {
        get { Thread.current.threadDictionary["DrawbridgeSnapshotVectorReplayDraw"] as? (() -> Void) }
        set { Thread.current.threadDictionary["DrawbridgeSnapshotVectorReplayDraw"] = newValue }
    }

    func draw(in context: CGContext) {
        Self.onDraw?()
        lock.lock(); defer { lock.unlock() }
        if let layer {
            context.saveGState()
            // PDF-backed CGLayer replay adds per-operation bounding-box clips.
            // Antialiasing those clips multiplies edge coverage a second time
            // (including opaque fills), unlike direct CGPDF rendering. Disable
            // AA only for replay's wrapper clips: the recorded PDF operations
            // retain their own antialiasing state. Do not disable *allows* AA,
            // which would also turn off the recorded curves/text antialiasing.
            context.setShouldAntialias(false)
            context.draw(layer, in: media)
            context.restoreGState()
        }
    }

    deinit {
        layer = nil
        owner.endPDFPage(); owner.closePDF()
        withExtendedLifetime((document, page, consumer)) {}
        Self.admission.release(sourceBytes)
        DispatchQueue.main.async { SnapshotReplayPreparation.shared.prepareNext() }
    }
}

/// Holds only visible, deduplicated sources. Tile callbacks take a short
/// strong lease without waiting for PDF interpretation on the worker.
@MainActor
final class SnapshotReplayPreparation {
    static let shared = SnapshotReplayPreparation()

    struct Source: Sendable {
        let key: String
        let data: Data
    }

    final class Viewport {
        let id = UUID()

        deinit {
            let id = id
            DispatchQueue.main.async { SnapshotReplayPreparation.shared.update(id, sources: []) }
        }
    }

    private final class Resident: @unchecked Sendable {
        private let lock = NSLock()
        private var values = [String: SnapshotVectorReplay]()

        func lease(_ key: String) -> SnapshotVectorReplay? {
            lock.withLock { values[key] }
        }

        func insert(_ replay: SnapshotVectorReplay, for key: String) {
            lock.withLock { values[key] = replay }
        }

        func removeInactive(keeping keys: Set<String>) -> [SnapshotVectorReplay] {
            lock.withLock {
                values.keys.filter { !keys.contains($0) }.compactMap { values.removeValue(forKey: $0) }
            }
        }
    }

    private nonisolated static let resident = Resident()
    private let worker = DispatchQueue(label: "com.drawbridge.snapshot-vector-replay", qos: .userInitiated)
    private var viewports = [UUID: [Source]]()
    private var order = [UUID]()
    private var pending: String?
    private var failed = Set<String>()

    nonisolated static func lease(_ key: String) -> SnapshotVectorReplay? {
        resident.lease(key)
    }

    func update(_ id: UUID, sources: [Source]) {
        if sources.isEmpty {
            viewports.removeValue(forKey: id)
            order.removeAll { $0 == id }
        } else {
            if viewports[id] == nil { order.append(id) }
            viewports[id] = sources
        }
        let keys = Set(viewports.values.flatMap { $0.map(\.key) })
        failed.formIntersection(keys)
        let retired = Self.resident.removeInactive(keeping: keys)
        if !retired.isEmpty {
            worker.async { withExtendedLifetime(retired) {} }
        }
        prepareNext()
    }

    func prepareNext() {
        guard pending == nil else { return }
        let sources = order.compactMap { viewports[$0] }.joined()
        guard let source = sources.first(where: {
            $0.data.count <= SnapshotVectorReplay.maximumSourceBytes
                && !failed.contains($0.key)
                && Self.lease($0.key) == nil
                && SnapshotVectorReplay.hasCapacity(for: $0.data.count)
        }) else { return }

        pending = source.key
        worker.async {
            let replay = CGDataProvider(data: source.data as CFData)
                .flatMap(CGPDFDocument.init)
                .flatMap { SnapshotVectorReplay(document: $0, sourceBytes: source.data.count) }
            DispatchQueue.main.async {
                self.didPrepare(replay, source: source)
            }
        }
    }

    private func didPrepare(_ replay: SnapshotVectorReplay?, source: Source) {
        pending = nil
        if viewports.values.contains(where: { $0.contains(where: { $0.key == source.key }) }) {
            if let replay {
                Self.resident.insert(replay, for: source.key)
                NotificationCenter.default.post(name: SnapshotPreviewCache.ready, object: nil,
                                                userInfo: ["captureKeys": Set([source.key])])
            } else if SnapshotVectorReplay.hasCapacity(for: source.data.count) {
                failed.insert(source.key)
            }
        }
        if let replay, Self.lease(source.key) == nil {
            worker.async { withExtendedLifetime(replay) {} }
        }
        prepareNext()
    }
}
