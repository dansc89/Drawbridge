import AppKit
import Foundation
import PDFKit

@MainActor
extension MainViewController {
    func ensureSearchPanel() {
        guard searchPanel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 56),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Find"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 56))
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = content

        let row = NSStackView(views: [toolbarSearchField, toolbarSearchPrevButton, toolbarSearchNextButton, toolbarSearchCountLabel])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
        searchPanel = panel
    }

    @objc func searchFieldChanged() {
        scheduleSearchRefresh()
    }

    @objc func selectNextSearchHit() {
        guard !searchHits.isEmpty else {
            NSSound.beep()
            return
        }
        searchHitIndex = (searchHitIndex + 1) % searchHits.count
        revealCurrentSearchHit()
    }

    @objc func selectPreviousSearchHit() {
        guard !searchHits.isEmpty else {
            NSSound.beep()
            return
        }
        searchHitIndex = (searchHitIndex - 1 + searchHits.count) % searchHits.count
        revealCurrentSearchHit()
    }

    private func scheduleSearchRefresh() {
        pendingSearchWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.runUnifiedSearchNow()
        }
        pendingSearchWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    func refreshSearchIfNeeded() {
        let query = toolbarSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        scheduleSearchRefresh()
    }

    func resetSearchState(clearQuery: Bool = false) {
        pendingSearchWorkItem?.cancel()
        pendingSearchWorkItem = nil
        searchHits.removeAll()
        searchHitIndex = -1
        if clearQuery {
            toolbarSearchField.stringValue = ""
        }
        if pdfView.currentSelection != nil {
            pdfView.setCurrentSelection(nil, animate: false)
        }
        updateSearchControlsState()
    }

    private func runUnifiedSearchNow() {
        pendingSearchWorkItem?.cancel()
        pendingSearchWorkItem = nil
        let query = toolbarSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchSpan = PerformanceMetrics.begin(
            "unified_search",
            thresholdMs: 80,
            fields: ["query_len": "\(query.count)"]
        )
        guard let document = pdfView.document else {
            resetSearchState(clearQuery: false)
            PerformanceMetrics.end(searchSpan, extra: ["result": "no_document"])
            return
        }

        guard !query.isEmpty else {
            resetSearchState(clearQuery: false)
            PerformanceMetrics.end(searchSpan, extra: ["result": "empty_query"])
            return
        }

        let loweredQuery = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var hits: [SearchHit] = []
        hits.reserveCapacity(256)
        var markupHitCount = 0

        // Markup-text search: fast pass through annotation contents across the full PDF.
        for pageIndex in 0..<document.pageCount {
            let annotations = annotationsForPageIndex(pageIndex, in: document)
            for annotation in annotations {
                let normalized = searchableAnnotationText(for: annotation, pageIndex: pageIndex)
                guard normalized.contains(loweredQuery) else { continue }
                let raw = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let raw, !raw.isEmpty else { continue }
                hits.append(.markup(pageIndex: pageIndex, annotation: annotation, preview: raw))
                markupHitCount += 1
                if hits.count >= 2500 { break }
            }
            if hits.count >= 2500 { break }
        }

        // Document-text search: iterate PDFKit selections with cap for responsiveness.
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var cursor: PDFSelection?
        var seenSelectionKeys = Set<String>()
        var textHitCount = 0
        while textHitCount < 1500,
              let match = document.findString(query, fromSelection: cursor, withOptions: options),
              let page = match.pages.first {
            let pageIndex = document.index(for: page)
            let bounds = match.bounds(for: page).integral
            let key = "\(pageIndex)|\(bounds.origin.x)|\(bounds.origin.y)|\(bounds.width)|\(bounds.height)"
            if seenSelectionKeys.contains(key) {
                break
            }
            seenSelectionKeys.insert(key)
            let preview = match.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? query
            hits.append(.document(selection: match, pageIndex: max(0, pageIndex), preview: preview))
            cursor = match
            textHitCount += 1
            if hits.count >= 2500 { break }
        }

        hits = hitsByPageOrder(hits, pageCount: document.pageCount)

        searchHits = hits
        searchHitIndex = hits.isEmpty ? -1 : 0
        updateSearchControlsState()
        if !hits.isEmpty {
            revealCurrentSearchHit()
        }
        PerformanceMetrics.end(
            searchSpan,
            extra: [
                "result": "ok",
                "hits": "\(hits.count)",
                "markup_hits": "\(markupHitCount)",
                "text_hits": "\(textHitCount)",
                "pages": "\(document.pageCount)"
            ]
        )
    }

    private func hitsByPageOrder(_ hits: [SearchHit], pageCount: Int) -> [SearchHit] {
        guard hits.count > 1, pageCount > 1 else { return hits }
        var buckets: [Int: [SearchHit]] = [:]
        buckets.reserveCapacity(min(pageCount, hits.count))
        for hit in hits {
            let pageIndex: Int
            switch hit {
            case let .document(selection: _, pageIndex: index, preview: _):
                pageIndex = index
            case let .markup(pageIndex: index, annotation: _, preview: _):
                pageIndex = index
            }
            buckets[pageIndex, default: []].append(hit)
        }

        var ordered: [SearchHit] = []
        ordered.reserveCapacity(hits.count)
        for pageIndex in 0..<pageCount {
            guard let pageHits = buckets.removeValue(forKey: pageIndex), !pageHits.isEmpty else { continue }
            ordered.append(contentsOf: pageHits)
        }
        if !buckets.isEmpty {
            let remainingKeys = buckets.keys.sorted()
            for key in remainingKeys {
                if let pageHits = buckets[key], !pageHits.isEmpty {
                    ordered.append(contentsOf: pageHits)
                }
            }
        }
        return ordered
    }

    private func revealCurrentSearchHit() {
        guard searchHitIndex >= 0, searchHitIndex < searchHits.count else {
            updateSearchControlsState()
            return
        }
        switch searchHits[searchHitIndex] {
        case let .document(selection: selection, pageIndex: _, preview: preview):
            pdfView.go(to: selection)
            pdfView.setCurrentSelection(selection, animate: true)
            updateSearchControlsState(overridePreview: preview)
        case let .markup(pageIndex: pageIndex, annotation: annotation, preview: preview):
            if let page = pdfView.document?.page(at: pageIndex) {
                let destination = PDFDestination(page: page, at: NSPoint(x: annotation.bounds.minX, y: annotation.bounds.maxY))
                pdfView.go(to: destination)
                selectMarkupFromPageClick(page: page, annotation: annotation)
            }
            updateSearchControlsState(overridePreview: preview)
        }
    }

    func updateSearchControlsState(overridePreview: String? = nil) {
        let hasDocument = (pdfView.document != nil)
        toolbarSearchField.isEnabled = hasDocument
        let hasResults = !searchHits.isEmpty
        toolbarSearchPrevButton.isEnabled = hasResults
        toolbarSearchNextButton.isEnabled = hasResults

        if hasResults, searchHitIndex >= 0 {
            let index = min(searchHitIndex + 1, searchHits.count)
            toolbarSearchCountLabel.stringValue = "\(index)/\(searchHits.count)"
            let preview = (overridePreview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !preview.isEmpty {
                toolbarSearchCountLabel.toolTip = preview
            } else {
                toolbarSearchCountLabel.toolTip = nil
            }
        } else {
            let hasQuery = !toolbarSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            toolbarSearchCountLabel.stringValue = hasQuery ? "0" : ""
            toolbarSearchCountLabel.toolTip = nil
        }
    }
}
