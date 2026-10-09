import Foundation
import PDFKit

/// PDFKit's asynchronous find keeps large drawing sets searchable without a
/// synchronous loop on the UI thread. Cancellation invalidates old callbacks.
@MainActor
final class PDFTextSearch {
    // Foundation delivers these observers on OperationQueue.main. The wrapper
    // expresses that confinement across Swift's unannotated observer boundary.
    private struct MainQueueNotification: @unchecked Sendable { let value: Notification }
    struct Result { let selections: [PDFSelection]; let limited: Bool }
    private var document: PDFDocument?
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    private var selections: [PDFSelection] = []
    private var seen = Set<String>()
    private var completion: ((Result) -> Void)?
    private var progress: ((Int, Int) -> Void)?
    private var limit = 1500
    private var lastProgress = Date.distantPast
    private(set) var isSearching = false

    func start(document: PDFDocument, query: String, limit: Int = 1500,
               progress: @escaping (Int, Int) -> Void, completion: @escaping (Result) -> Void) {
        cancel()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { completion(Result(selections: [], limited: false)); return }
        self.document = document; self.limit = max(1, limit)
        self.progress = progress; self.completion = completion
        isSearching = true
        let token = generation
        func observe(_ name: Notification.Name, _ callback: @escaping @MainActor (Notification) -> Void) {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: document, queue: .main) { note in
                let delivered = MainQueueNotification(value: note)
                MainActor.assumeIsolated { callback(delivered.value) }
            })
        }
        observe(.PDFDocumentDidFindMatch) { [weak self] note in
            guard let self, self.isSearching, self.generation == token,
                  let selection = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection,
                  let page = selection.pages.first else { return }
            let index = document.index(for: page)
            guard index >= 0, index < document.pageCount else { return }
            let rect = selection.bounds(for: page)
            // Exact bounds, not rounded pixels: closely spaced small CAD text
            // can otherwise be silently merged into one hit.
            let key = "\(index)|\(rect.origin.x)|\(rect.origin.y)|\(rect.width)|\(rect.height)|\(selection.string ?? "")"
            guard self.seen.insert(key).inserted else { return }
            self.selections.append(selection)
            if self.selections.count >= self.limit { self.finish(limited: true) }
        }
        observe(.PDFDocumentDidEndPageFind) { [weak self] note in
            guard let self, self.isSearching, self.generation == token else { return }
            if Date().timeIntervalSince(self.lastProgress) > 0.1 {
                let index = (note.userInfo?[PDFDocumentPageIndexKey] as? NSNumber)?.intValue ?? 0
                self.progress?(self.selections.count, min(document.pageCount, index + 1))
                self.lastProgress = Date()
            }
        }
        observe(.PDFDocumentDidEndFind) { [weak self] _ in
            guard let self, self.isSearching, self.generation == token else { return }
            self.finish(limited: false)
        }
        progress(0, 0)
        document.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    func cancel() {
        generation &+= 1
        isSearching = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        let previous = document; document = nil
        completion = nil; progress = nil
        selections.removeAll(keepingCapacity: true); seen.removeAll(keepingCapacity: true)
        if previous?.isFinding == true { previous?.cancelFindString() }
    }

    private func finish(limited: Bool) {
        let result = Result(selections: selections, limited: limited)
        let callback = completion
        cancel()
        callback?(result)
    }
}
