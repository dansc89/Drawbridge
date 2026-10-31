import AppKit
import CryptoKit
import PDFKit

/// Local viewing preferences only. Never writes a PDF, sidecar, or undo record.
@MainActor
final class SavedReadingPositionStore {
    private struct Record: Codable {
        let page: Int
        let pageCount: Int
        let zoom: Double
        let autoScales: Bool
        let x: Double
        let y: Double
        let bounds: [Double]
        let rotation: Int
        let updated: Date
    }
    private let defaults: UserDefaults
    private let key = "Drawbridge.savedReadingPositions.v1"
    private let limit = 200

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func identifier(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func records() -> [String: Record] {
        guard let data = defaults.data(forKey: key), data.count <= 1_000_000,
              let records = try? JSONDecoder().decode([String: Record].self, from: data) else { return [:] }
        return records
    }
    private func geometry(_ page: PDFPage) -> [Double] {
        let box = page.bounds(for: .cropBox)
        return [Double(box.minX), Double(box.minY), Double(box.width), Double(box.height)]
    }
    func save(_ state: MarkupPDFView.TabViewState, for url: URL, document: PDFDocument) {
        guard url.isFileURL, state.current.pageIndex >= 0,
              let page = document.page(at: state.current.pageIndex),
              state.current.scale.isFinite, state.current.scale > 0,
              state.viewportCenter.x.isFinite, state.viewportCenter.y.isFinite else { return }
        var entries = records()
        entries[identifier(url)] = Record(page: state.current.pageIndex, pageCount: document.pageCount,
            zoom: Double(state.current.scale), autoScales: state.autoScales,
            x: Double(state.viewportCenter.x), y: Double(state.viewportCenter.y),
            bounds: geometry(page), rotation: page.rotation, updated: Date())
        let retained = entries.sorted { $0.value.updated > $1.value.updated }.prefix(limit)
        if let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })) {
            defaults.set(data, forKey: key)
        }
    }
    func load(for url: URL, document: PDFDocument) -> MarkupPDFView.TabViewState? {
        guard url.isFileURL, let record = records()[identifier(url)], record.page >= 0,
              record.pageCount == document.pageCount, let page = document.page(at: record.page),
              record.bounds == geometry(page), record.rotation == page.rotation,
              record.zoom.isFinite, record.zoom > 0, record.x.isFinite, record.y.isFinite else { return nil }
        let point = NSPoint(x: record.x, y: record.y)
        return .init(current: .init(pageIndex: record.page, point: point, scale: record.zoom),
                     back: [], forward: [], autoScales: record.autoScales, viewportCenter: point)
    }
}
