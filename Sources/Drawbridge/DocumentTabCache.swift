import PDFKit

/// Retain only clean, inactive documents. File identity and timestamps must
/// still match before reuse; discarded edits must never enter this cache.
@MainActor
final class DocumentTabCache {
    struct Entry {
        let document: PDFDocument
        let stamp: PDFMarkupSourceStamp
        let labels: [Int: String]
        let suppressedLabels: Set<Int>
        let scaleLocks: [Int: PageScaleLock]
    }
    private var entries: [URL: Entry] = [:]
    private var order: [URL] = []
    let maximumBytes: Int
    let maximumCount: Int
    var count: Int { entries.count }
    init(maximumBytes: Int = 256 * 1024 * 1024, maximumCount: Int = 2) {
        self.maximumBytes = maximumBytes; self.maximumCount = maximumCount
    }
    func store(_ entry: Entry, for url: URL) {
        remove(url)
        guard entry.stamp.size <= maximumBytes, maximumCount > 0 else { return }
        entries[url] = entry; order.append(url)
        while entries.count > maximumCount || entries.values.reduce(0, { $0 + $1.stamp.size }) > maximumBytes {
            guard let oldest = order.first else { break }
            remove(oldest)
        }
    }
    func take(_ url: URL) -> Entry? {
        let entry = entries[url]
        remove(url)
        guard let entry, PDFMarkupSourceStamp.read(url) == entry.stamp else { return nil }
        return entry
    }
    func remove(_ url: URL) { entries.removeValue(forKey: url); order.removeAll { $0 == url } }
    func removeAll() { entries.removeAll(); order.removeAll() }
}
