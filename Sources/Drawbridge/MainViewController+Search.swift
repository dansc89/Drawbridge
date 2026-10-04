import AppKit
import Foundation
import PDFKit

@MainActor
extension MainViewController {
    private func truncatedSearchPreview(_ text: String, maxLength: Int = 140) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxLength else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: maxLength)
        return "\(normalized[..<end])…"
    }

    private func showSearchNoResultsFeedback() {
        toolbarSearchCountLabel.stringValue = "No results"
        toolbarSearchCountLabel.toolTip = "No matches found in document text."
        NSSound.beep()
    }

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
        NotificationCenter.default.addObserver(self, selector: #selector(findPanelClosed(_:)), name: NSWindow.willCloseNotification, object: panel)
    }

    @objc private func findPanelClosed(_ note: Notification) { resetSearchState() }

    @objc func searchFieldChanged() {
        scheduleSearchRefresh()
    }

    @objc func selectNextSearchHit() {
        guard !searchHits.isEmpty else {
            showSearchNoResultsFeedback()
            return
        }
        searchHitIndex = (searchHitIndex + 1) % searchHits.count
        revealCurrentSearchHit()
    }

    @objc func selectPreviousSearchHit() {
        guard !searchHits.isEmpty else {
            showSearchNoResultsFeedback()
            return
        }
        searchHitIndex = (searchHitIndex - 1 + searchHits.count) % searchHits.count
        revealCurrentSearchHit()
    }

    private func scheduleSearchRefresh() {
        textSearch.cancel()
        pdfView.setCurrentSelection(nil, animate: false)
        searchHits.removeAll()
        searchHitIndex = -1
        searchResultsLimited = false
        updateSearchControlsState()
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
        textSearch.cancel()
        searchResultsLimited = false
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

        guard !isPDFProcessingBusy else { PerformanceMetrics.end(searchSpan, extra: ["result": "busy"]); return }
        searchResultsLimited = false
        textSearch.start(document: document, query: query, progress: { [weak self, weak document] count, pages in
            guard let self, let document, self.pdfView.document === document else { return }
            self.toolbarSearchCountLabel.stringValue = "Searching… \(count)"
            self.toolbarSearchCountLabel.toolTip = "Read \(pages) of \(document.pageCount) pages. You can keep navigating or change the query."
        }, completion: { [weak self, weak document] result in
            guard let self, let document, self.pdfView.document === document,
                  self.toolbarSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            let hits: [SearchHit] = result.selections.compactMap { match in
                guard let page = match.pages.first else { return nil }
                let index = document.index(for: page)
                guard index >= 0, index < document.pageCount else { return nil }
                return .document(selection: match, pageIndex: index, preview: match.string ?? query)
            }
            self.searchHits = self.hitsByPageOrder(hits, pageCount: document.pageCount)
            self.searchResultsLimited = result.limited
            self.searchHitIndex = hits.isEmpty ? -1 : 0
            self.updateSearchControlsState()
            if !hits.isEmpty, self.searchPanel?.isVisible == true { self.revealCurrentSearchHit() }
            PerformanceMetrics.end(searchSpan, extra: ["result": "ok", "hits": "\(hits.count)", "pages": "\(document.pageCount)"])
        })
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
            pdfView.navigateToSelectionWithHistory(selection)
            pdfView.setCurrentSelection(selection, animate: true)
            updateSearchControlsState(overridePreview: preview)
        case let .markup(pageIndex: pageIndex, annotation: annotation, preview: preview):
            if let page = pdfView.document?.page(at: pageIndex) {
                let destination = PDFDestination(page: page, at: NSPoint(x: annotation.bounds.minX, y: annotation.bounds.maxY))
                pdfView.navigateToDestinationWithHistory(destination)
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
            toolbarSearchCountLabel.stringValue = "\(index)/\(searchHits.count)" + (searchResultsLimited ? "+" : "")
            let preview = truncatedSearchPreview(overridePreview ?? "")
            if !preview.isEmpty {
                toolbarSearchCountLabel.toolTip = preview + (searchResultsLimited ? "\nShowing the first 1,500 matches. Narrow your search to see more." : "")
            } else {
                toolbarSearchCountLabel.toolTip = nil
            }
        } else {
            let hasQuery = !toolbarSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasQuery {
                toolbarSearchCountLabel.stringValue = "0/0"
                toolbarSearchCountLabel.toolTip = "No matches in searchable PDF text. Image-only sheets may need OCR."
            } else {
                toolbarSearchCountLabel.stringValue = ""
                toolbarSearchCountLabel.toolTip = nil
            }
        }
    }
}
