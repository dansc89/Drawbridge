import AppKit
import Foundation
import PDFKit

@MainActor
extension MainViewController {
    @objc func commandOpen(_ sender: Any?) { openPDF() }
    @objc func commandNew(_ sender: Any?) { createNewPDFAction() }
    @objc func commandSave(_ sender: Any?) { saveDocument() }
    @objc func commandSaveCopy(_ sender: Any?) { saveCopy() }
    @objc func commandExportCSV(_ sender: Any?) { exportMarkupsCSV() }
    @objc func commandAutoGenerateSheetNames(_ sender: Any?) { startAutoGenerateSheetNamesFlow() }
    @objc func commandSetScale(_ sender: Any?) { commandSetDrawingScale(sender) }
    @objc func commandPerformanceSettings(_ sender: Any?) {
        let defaults = UserDefaults.standard
        let adaptiveDefault = defaults.bool(forKey: Self.defaultsAdaptiveIndexCapEnabledKey)
        let capDefault = configuredIndexCap()
        let watchdogDefault = defaults.bool(forKey: Self.defaultsWatchdogEnabledKey)
        let thresholdDefault = max(0.5, defaults.double(forKey: Self.defaultsWatchdogThresholdSecondsKey))

        let adaptiveButton = NSButton(checkboxWithTitle: "Adaptive index cap for very large PDFs", target: nil, action: nil)
        adaptiveButton.state = adaptiveDefault ? .on : .off

        let capLabel = NSTextField(labelWithString: "Max indexed markups:")
        let capField = NSTextField(string: "\(capDefault)")
        capField.alignment = NSTextAlignment.right
        capField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        capField.translatesAutoresizingMaskIntoConstraints = false
        capField.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let watchdogButton = NSButton(checkboxWithTitle: "Enable main-thread stall watchdog logging", target: nil, action: nil)
        watchdogButton.state = watchdogDefault ? .on : .off

        let thresholdLabel = NSTextField(labelWithString: "Stall threshold (seconds):")
        let thresholdField = NSTextField(string: String(format: "%.1f", thresholdDefault))
        thresholdField.alignment = NSTextAlignment.right
        thresholdField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        thresholdField.translatesAutoresizingMaskIntoConstraints = false
        thresholdField.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let capRow = NSStackView(views: [capLabel, capField])
        capRow.orientation = NSUserInterfaceLayoutOrientation.horizontal
        capRow.spacing = 10
        capRow.alignment = NSLayoutConstraint.Attribute.centerY
        capLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        capRow.distribution = NSStackView.Distribution.fill
        let thresholdRow = NSStackView(views: [thresholdLabel, thresholdField])
        thresholdRow.orientation = NSUserInterfaceLayoutOrientation.horizontal
        thresholdRow.spacing = 10
        thresholdRow.alignment = NSLayoutConstraint.Attribute.centerY
        thresholdLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        thresholdRow.distribution = NSStackView.Distribution.fill

        let help = NSTextField(labelWithString: "Watchdog logs: ~/Library/Application Support/Drawbridge/Logs/watchdog.log")
        help.textColor = .secondaryLabelColor
        help.font = NSFont.systemFont(ofSize: 11)
        help.lineBreakMode = .byWordWrapping
        help.maximumNumberOfLines = 2

        let stack = NSStackView(views: [adaptiveButton, capRow, watchdogButton, thresholdRow, help])
        stack.orientation = NSUserInterfaceLayoutOrientation.vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 160))
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            accessory.widthAnchor.constraint(equalToConstant: 520),
            stack.topAnchor.constraint(equalTo: accessory.topAnchor),
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
        ])

        let alert = NSAlert()
        alert.messageText = "Performance Settings"
        alert.informativeText = "Tune large-document indexing and watchdog behavior."
        alert.alertStyle = .informational
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let cap = min(max(capField.integerValue, minimumIndexedMarkupItems), maximumIndexedMarkupItems)
        let threshold = min(max(thresholdField.doubleValue, 0.5), 30.0)
        defaults.set(adaptiveButton.state == .on, forKey: Self.defaultsAdaptiveIndexCapEnabledKey)
        defaults.set(cap, forKey: Self.defaultsIndexCapKey)
        defaults.set(watchdogButton.state == .on, forKey: Self.defaultsWatchdogEnabledKey)
        defaults.set(threshold, forKey: Self.defaultsWatchdogThresholdSecondsKey)
        configureWatchdogFromDefaults()
        scheduleMarkupsRefresh(selecting: currentSelectedAnnotation())
    }
    @objc func commandCycleNextDocument(_ sender: Any?) {
        cycleDocument(step: 1)
    }
    @objc func commandCyclePreviousDocument(_ sender: Any?) {
        cycleDocument(step: -1)
    }
    @objc func commandCloseDocument(_ sender: Any?) {
        guard confirmDiscardUnsavedChangesIfNeeded() else {
            return
        }

        if let current = openDocumentURL.map({ canonicalDocumentURL($0) }) {
            sessionDocumentURLs.removeAll { canonicalDocumentURL($0) == current }
        }

        while let fallback = sessionDocumentURLs.last {
            guard FileManager.default.fileExists(atPath: fallback.path) else {
                sessionDocumentURLs.removeLast()
                continue
            }
            openDocument(at: fallback)
            return
        }

        clearToStartState()
    }

    private func cycleDocument(step: Int) {
        guard sessionDocumentURLs.count > 1 else {
            NSSound.beep()
            return
        }

        guard confirmDiscardUnsavedChangesIfNeeded() else {
            return
        }

        let normalizedCurrent = openDocumentURL.map { canonicalDocumentURL($0) }
        let currentIndex = normalizedCurrent.flatMap { current in
            sessionDocumentURLs.firstIndex(where: { canonicalDocumentURL($0) == current })
        } ?? (sessionDocumentURLs.count - 1)

        let count = sessionDocumentURLs.count
        let rawNext = (currentIndex + step) % count
        let nextIndex = rawNext < 0 ? rawNext + count : rawNext
        let nextURL = sessionDocumentURLs[nextIndex]
        openDocument(at: nextURL)
    }
    @objc func commandHighlight(_ sender: Any?) { highlightSelection() }
    @objc func commandRefreshMarkups(_ sender: Any?) { refreshMarkups() }
    @objc func commandCopy(_ sender: Any?) {
        if let firstResponder = view.window?.firstResponder,
           firstResponder is NSTextView || firstResponder is NSTextField {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: sender)
            return
        }
        guard let document = pdfView.document else {
            NSSound.beep()
            return
        }
        let selectedItems = currentSelectedMarkupItems()
        guard !selectedItems.isEmpty else {
            NSSound.beep()
            return
        }

        var uniqueByID: [ObjectIdentifier: (pageIndex: Int, annotation: PDFAnnotation)] = [:]
        for item in selectedItems {
            guard let page = document.page(at: item.pageIndex) else { continue }
            uniqueByID[ObjectIdentifier(item.annotation)] = (item.pageIndex, item.annotation)
            for sibling in relatedCalloutAnnotations(for: item.annotation, on: page) where sibling !== item.annotation {
                uniqueByID[ObjectIdentifier(sibling)] = (item.pageIndex, sibling)
            }
        }

        let records: [MarkupClipboardRecord] = uniqueByID.values.compactMap { entry in
            let archivedData = (try? NSKeyedArchiver.archivedData(withRootObject: entry.annotation, requiringSecureCoding: true))
                ?? (try? NSKeyedArchiver.archivedData(withRootObject: entry.annotation, requiringSecureCoding: false))
            guard let archivedData else { return nil }
            return MarkupClipboardRecord(
                pageIndex: entry.pageIndex,
                archivedAnnotation: archivedData,
                lineWidth: resolvedLineWidth(for: entry.annotation)
            )
        }
        guard !records.isEmpty else {
            NSSound.beep()
            return
        }

        let payload = MarkupClipboardPayload(sourceDocumentPageCount: document.pageCount, records: records)
        guard let encoded = try? PropertyListEncoder().encode(payload) else {
            NSSound.beep()
            return
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(encoded, forType: markupClipboardPasteboardType)
    }
    @objc func commandPaste(_ sender: Any?) {
        if let firstResponder = view.window?.firstResponder,
           firstResponder is NSTextView || firstResponder is NSTextField {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
            return
        }
        pasteCopiedMarkupsFromPasteboard()
    }
    @objc func commandDeleteMarkup(_ sender: Any?) { deleteSelectedMarkup() }
    @objc func commandBringMarkupToFront(_ sender: Any?) { reorderSelectedMarkups(.bringToFront) }
    @objc func commandSendMarkupToBack(_ sender: Any?) { reorderSelectedMarkups(.sendToBack) }
    @objc func commandBringMarkupForward(_ sender: Any?) { reorderSelectedMarkups(.bringForward) }
    @objc func commandSendMarkupBackward(_ sender: Any?) { reorderSelectedMarkups(.sendBackward) }
    @objc func commandSelectAll(_ sender: Any?) {
        if pdfView.selectAllInlineTextIfEditing() {
            return
        }
        if let textField = view.window?.firstResponder as? NSTextField {
            textField.currentEditor()?.selectAll(nil)
            return
        }
        if let textView = view.window?.firstResponder as? NSTextView {
            textView.selectAll(nil)
            return
        }
        guard let document = pdfView.document, let page = pdfView.currentPage else {
            NSSound.beep()
            return
        }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else {
            NSSound.beep()
            return
        }
        let rows = IndexSet(markupItems.enumerated().compactMap { idx, item in
            item.pageIndex == pageIndex ? idx : nil
        })
        guard !rows.isEmpty else {
            markupsTable.deselectAll(nil)
            updateSelectionOverlay()
            return
        }
        markupsTable.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first {
            markupsTable.scrollRowToVisible(first)
        }
        updateSelectionOverlay()
        updateStatusBar()
    }
    @objc func commandEditMarkup(_ sender: Any?) { editSelectedMarkupText() }
    @objc func commandToggleSidebar(_ sender: Any?) { toggleSidebar() }
    @objc func commandQuickStart(_ sender: Any?) { showQuickStartGuide() }
    @objc func commandFocusSearch(_ sender: Any?) {
        guard pdfView.document != nil else {
            NSSound.beep()
            return
        }
        ensureSearchPanel()
        if let panel = searchPanel {
            if let window = view.window {
                window.addChildWindow(panel, ordered: .above)
            }
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        searchPanel?.makeFirstResponder(toolbarSearchField)
        toolbarSearchField.currentEditor()?.selectAll(nil)
    }
    @objc func commandZoomIn(_ sender: Any?) { zoom(by: 1.12) }
    @objc func commandZoomOut(_ sender: Any?) { zoom(by: 1.0 / 1.12) }
    @objc func commandPreviousPage(_ sender: Any?) { navigatePage(delta: -1) }
    @objc func commandNextPage(_ sender: Any?) { navigatePage(delta: 1) }
    @objc func commandActualSize(_ sender: Any?) {
        guard pdfView.document != nil else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.0
        updateStatusBar()
    }
    @objc func commandFitWidth(_ sender: Any?) {
        guard pdfView.document != nil else { return }
        pdfView.autoScales = true
        let fit = pdfView.scaleFactorForSizeToFit
        if fit > 0 {
            pdfView.scaleFactor = fit
            pdfView.autoScales = false
        }
        updateStatusBar()
    }

    func openDocumentFromExternalURL(_ url: URL) {
        guard confirmDiscardUnsavedChangesIfNeeded() else {
            return
        }
        openDocument(at: url)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        let hasDocument = (pdfView.document != nil)
        let hasSelection = (currentSelectedMarkupItem() != nil)
        let hasTextSelection = (pdfView.currentSelection != nil)

        switch action {
        case #selector(commandOpen(_:)),
             #selector(commandNew(_:)),
             #selector(commandPerformanceSettings(_:)):
            return true
        case #selector(commandCycleNextDocument(_:)),
             #selector(commandCyclePreviousDocument(_:)):
            return sessionDocumentURLs.count > 1
        case #selector(commandCloseDocument(_:)):
            return hasDocument || !sessionDocumentURLs.isEmpty
        case #selector(commandSave(_:)),
             #selector(commandSaveCopy(_:)),
             #selector(commandExportCSV(_:)),
             #selector(commandAutoGenerateSheetNames(_:)),
             #selector(commandSetScale(_:)),
             #selector(commandRefreshMarkups(_:)),
             #selector(commandSelectAll(_:)),
             #selector(commandFocusSearch(_:)),
             #selector(commandZoomIn(_:)),
             #selector(commandZoomOut(_:)),
             #selector(commandPreviousPage(_:)),
             #selector(commandNextPage(_:)),
             #selector(commandActualSize(_:)),
             #selector(commandFitWidth(_:)),
             #selector(selectSelectionTool(_:)),
             #selector(selectGrabTool(_:)),
             #selector(selectPenTool(_:)),
             #selector(selectHighlighterTool(_:)),
             #selector(selectCloudTool(_:)),
             #selector(selectRectangleTool(_:)),
             #selector(selectTextTool(_:)),
             #selector(selectCalloutTool(_:)),
             #selector(selectMeasureTool(_:)),
             #selector(selectCalibrateTool(_:)):
            return hasDocument
        case #selector(commandHighlight(_:)):
            return hasTextSelection
        case #selector(commandCopy(_:)):
            if let firstResponder = view.window?.firstResponder,
               firstResponder is NSTextView || firstResponder is NSTextField {
                return true
            }
            return hasSelection
        case #selector(commandPaste(_:)):
            if let firstResponder = view.window?.firstResponder,
               firstResponder is NSTextView || firstResponder is NSTextField {
                return true
            }
            return hasDocument && NSPasteboard.general.data(forType: markupClipboardPasteboardType) != nil
        case #selector(commandDeleteMarkup(_:)),
             #selector(commandEditMarkup(_:)),
             #selector(commandBringMarkupToFront(_:)),
             #selector(commandSendMarkupToBack(_:)),
             #selector(commandBringMarkupForward(_:)),
             #selector(commandSendMarkupBackward(_:)):
            return hasSelection
        default:
            return true
        }
    }

    private func showQuickStartGuide() {
        let alert = NSAlert()
        alert.messageText = "Drawbridge Quick Start"
        alert.informativeText = "Open a PDF, choose a tool, and place markups directly on the page."
        alert.alertStyle = .informational

        let guide = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 210))
        guide.isEditable = false
        guide.drawsBackground = false
        guide.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        guide.string = """
1) Open PDF: ⌘O
2) Tools (keyboard shortcuts): V Select, D Draw, A Arrow, L Line, P Polyline, Shift+A Area, H Highlighter, C Cloud, R Rect, T Text, Q Callout, M Measure, K Calibrate
   Mac menu keys: ⌘1 Pen, ⌘2 Highlighter, ⌘3 Cloud, ⌘4 Rect, ⌘5 Text, ⌘6 Callout
3) Navigation:
   • Mouse wheel = zoom in/out
   • Middle mouse drag = pan
   • Single-page view only (no continuous scroll)
   • Page nav: use the left navigation pane (Pages/Bookmarks)
4) Markups:
   • Select text then Highlight
   • Use right panel to edit, filter, delete
5) Export:
   • Export CSV from Actions or File menu
6) System Requirements:
   • Apple Silicon Mac (M1/M2/M3/M4)
   • macOS 13.0 or newer
"""
        alert.accessoryView = guide
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func zoom(by factor: CGFloat) {
        guard pdfView.document != nil else { return }
        lastUserInteractionAt = Date()
        pdfView.autoScales = false
        let target = min(max(pdfView.minScaleFactor, pdfView.scaleFactor * factor), pdfView.maxScaleFactor)
        pdfView.scaleFactor = target
        updateStatusBar()
    }

    @objc func jumpToPageFromField() {
        defer {
            view.window?.makeFirstResponder(pdfView)
        }
        guard let document = pdfView.document else { return }
        let requested = pageJumpField.stringValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !requested.isEmpty else { return }

        for idx in 0..<document.pageCount {
            if displayPageLabel(forPageIndex: idx).lowercased() == requested.lowercased() {
                goToPageIndex(idx)
                return
            }
        }

        if let pageNumber = Int(requested) {
            goToPageIndex(pageNumber - 1)
            return
        }
        NSSound.beep()
    }

    private func navigatePage(delta: Int) {
        guard let document = pdfView.document else { return }
        let current = pdfView.currentPage.map { document.index(for: $0) } ?? 0
        let anchor = currentPageNavigationAnchor()
        goToPageIndex(current + delta, anchor: anchor)
    }

    private func currentPageNavigationAnchor() -> (x: CGFloat, y: CGFloat)? {
        guard let page = pdfView.currentPage else { return nil }
        let bounds = page.bounds(for: pdfView.displayBox)
        guard bounds.width > 0.01, bounds.height > 0.01 else { return nil }
        let viewCenter = NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        let point = pdfView.currentDestination?.point ?? pdfView.convert(viewCenter, to: page)
        let x = min(max((point.x - bounds.minX) / bounds.width, 0), 1)
        let y = min(max((point.y - bounds.minY) / bounds.height, 0), 1)
        return (x: x, y: y)
    }

    private func goToPageIndex(_ index: Int, anchor: (x: CGFloat, y: CGFloat)? = nil) {
        guard let document = pdfView.document else { return }
        let clamped = min(max(0, index), max(0, document.pageCount - 1))
        guard let page = document.page(at: clamped) else { return }
        let pageBounds = page.bounds(for: pdfView.displayBox)
        let destinationPoint: NSPoint
        if let anchor {
            destinationPoint = NSPoint(
                x: pageBounds.minX + pageBounds.width * anchor.x,
                y: pageBounds.minY + pageBounds.height * anchor.y
            )
        } else {
            destinationPoint = NSPoint(x: pageBounds.midX, y: pageBounds.midY)
        }
        let destination = PDFDestination(page: page, at: destinationPoint)
        pdfView.go(to: destination)
        updateStatusBar()
    }

}
