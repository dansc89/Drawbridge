import AppKit
import Foundation
import PDFKit

@MainActor
private final class BatchCombineOrderWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private var urls: [URL]
    private let panel: NSPanel
    private let tableView = NSTableView(frame: .zero)
    private var modalResult: NSApplication.ModalResponse = .cancel

    init(urls: [URL]) {
        self.urls = urls
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
    }

    func runModal() -> [URL]? {
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        modalResult = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return modalResult == .OK ? urls : nil
    }

    private func configurePanel() {
        panel.title = "Batch Combine PDFs"
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = content

        let title = NSTextField(labelWithString: "Arrange PDFs in the order they should be combined:")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let scroll = NSScrollView(frame: .zero)
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.title = "PDF File"
        column.width = 520
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(moveSelectedDown)
        scroll.documentView = tableView

        let moveUpButton = NSButton(title: "Move Up", target: self, action: #selector(moveSelectedUp))
        let moveDownButton = NSButton(title: "Move Down", target: self, action: #selector(moveSelectedDown))
        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeSelected))
        let combineButton = NSButton(title: "Combine", target: self, action: #selector(confirmCombine))
        combineButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"

        let controlsRow = NSStackView(views: [moveUpButton, moveDownButton, removeButton, NSView(), cancelButton, combineButton])
        controlsRow.orientation = .horizontal
        controlsRow.spacing = 8
        controlsRow.alignment = .centerY

        let stack = NSStackView(views: [title, scroll, controlsRow])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        urls.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("pdfRow")
        let field: NSTextField
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = existing
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingMiddle
            field.font = NSFont.systemFont(ofSize: 12)
        }
        guard row >= 0, row < urls.count else { return field }
        field.stringValue = "\(row + 1). \(urls[row].lastPathComponent)"
        return field
    }

    @objc private func moveSelectedUp() {
        let row = tableView.selectedRow
        guard row > 0, row < urls.count else { return }
        urls.swapAt(row, row - 1)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: row - 1), byExtendingSelection: false)
    }

    @objc private func moveSelectedDown() {
        let row = tableView.selectedRow
        guard row >= 0, row < urls.count - 1 else { return }
        urls.swapAt(row, row + 1)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
    }

    @objc private func removeSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < urls.count else { return }
        urls.remove(at: row)
        tableView.reloadData()
        let next = min(row, max(0, urls.count - 1))
        if !urls.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        }
    }

    @objc private func confirmCombine() {
        guard !urls.isEmpty else { NSSound.beep(); return }
        modalResult = .OK
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancel() {
        modalResult = .cancel
        NSApp.stopModal(withCode: .cancel)
    }

    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === panel {
            NSApp.stopModal(withCode: .cancel)
        }
    }
}

@MainActor
extension MainViewController {
    @objc func commandOpen(_ sender: Any?) { openPDF() }
    @objc func commandNew(_ sender: Any?) { createNewPDFAction() }
    @objc func commandSave(_ sender: Any?) { saveDocument() }
    @objc func commandSaveCopy(_ sender: Any?) { saveCopy() }
    @objc func commandExportCSV(_ sender: Any?) { exportMarkupsCSV() }
    @objc func commandExportPagesAsJPEG(_ sender: Any?) { exportPagesAsJPEG() }
    @objc func commandExportPagesAsJPEGAndRebuildPDF(_ sender: Any?) { exportPagesAsJPEGAndRebuildPDF() }
    @objc func commandBatchExportPDFsAsJPEG(_ sender: Any?) { batchExportPDFsAsJPEG() }
    @objc func commandConvertImagesToPDF(_ sender: Any?) { convertImageFolderToPDF() }
    @objc func commandBatchCombinePDFs(_ sender: Any?) { batchCombinePDFs() }
    @objc func commandBatchLinkSheetNumbers(_ sender: Any?) { startAutoLinkSheetNumbersFlow() }
    @objc func commandAutoGenerateSheetNames(_ sender: Any?) { startAutoGenerateSheetNamesFlow() }
    @objc func commandSetScale(_ sender: Any?) { commandSetDrawingScale(sender) }
    @objc func commandLockScalePages(_ sender: Any?) { commandLockScaleToPages(sender) }
    @objc func commandClearScalePages(_ sender: Any?) { commandClearScaleLocks(sender) }
    @objc func commandToggleOrthoSnap(_ sender: Any?) {
        let enabled = !isOrthoSnapEnabled
        setOrthoSnapEnabled(enabled)
        (sender as? NSMenuItem)?.state = enabled ? .on : .off
    }
    @objc func commandToggleHyperlinkHighlights(_ sender: Any?) {
        let enabled = !isHyperlinkHighlightsVisible
        setHyperlinkHighlightsVisible(enabled)
        (sender as? NSMenuItem)?.state = enabled ? .on : .off
    }
    @objc func commandKeyboardShortcuts(_ sender: Any?) {
        let actions = ShortcutAction.allCases
        var keyFields: [ShortcutAction: NSTextField] = [:]
        var modifierPopups: [ShortcutAction: NSPopUpButton] = [:]

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 6
        rows.translatesAutoresizingMaskIntoConstraints = false

        for action in actions {
            let binding = shortcutBindings[action] ?? defaultShortcutBindings()[action]!
            let label = NSTextField(labelWithString: action.displayName)
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)

            let modifierPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            modifierPopup.addItems(withTitles: ["None", "Shift", "Cmd+Shift"])
            switch binding.modifier {
            case .plain:
                modifierPopup.selectItem(at: 0)
            case .shift:
                modifierPopup.selectItem(at: 1)
            case .commandShift:
                modifierPopup.selectItem(at: 2)
            }
            modifierPopup.translatesAutoresizingMaskIntoConstraints = false
            modifierPopup.widthAnchor.constraint(equalToConstant: 108).isActive = true

            let keyField = NSTextField(string: binding.key.uppercased())
            keyField.alignment = .center
            keyField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            keyField.translatesAutoresizingMaskIntoConstraints = false
            keyField.widthAnchor.constraint(equalToConstant: 46).isActive = true

            modifierPopups[action] = modifierPopup
            keyFields[action] = keyField

            let row = NSStackView(views: [label, NSView(), modifierPopup, keyField])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            rows.addArrangedSubview(row)
        }

        let hint = NSTextField(labelWithString: "Use single-character keys. Duplicate combinations are blocked.")
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: 11)

        let container = NSStackView(views: [rows, hint])
        container.orientation = .vertical
        container.spacing = 8
        container.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        container.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 420))
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = container
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            container.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            container.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = "Customize tool and drafting shortcuts."
        alert.alertStyle = .informational
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Restore Defaults")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertThirdButtonReturn {
            resetShortcutBindingsToDefaults()
            return
        }
        guard response == .alertFirstButtonReturn else { return }

        var updated: [ShortcutAction: ShortcutBinding] = [:]
        var seenCombos = Set<String>()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "[]\\;',./`-="))
        for action in actions {
            guard let keyField = keyFields[action],
                  let modifierPopup = modifierPopups[action] else { continue }
            let rawKey = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard rawKey.count == 1, rawKey.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                runAlert(
                    title: "Invalid Shortcut Key",
                    informativeText: "Each shortcut must use a single supported character.",
                    style: .warning
                )
                return
            }
            let modifier: ShortcutModifier
            switch modifierPopup.indexOfSelectedItem {
            case 1:
                modifier = .shift
            case 2:
                modifier = .commandShift
            default:
                modifier = .plain
            }
            let combo = "\(modifier.rawValue):\(rawKey)"
            guard !seenCombos.contains(combo) else {
                runAlert(
                    title: "Duplicate Shortcut",
                    informativeText: "Each shortcut combination can only be assigned once.",
                    style: .warning
                )
                return
            }
            seenCombos.insert(combo)
            updated[action] = ShortcutBinding(key: rawKey, modifier: modifier)
        }
        shortcutBindings = updated
        saveShortcutBindings()
        updateShortcutHintLabel()
    }
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
        guard guardOrBeep(sessionDocumentURLs.count > 1) else { return }

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
        guard let document = pdfView.document else { beep(); return }
        let selectedItems = currentSelectedMarkupItems()
        guard guardOrBeep(!selectedItems.isEmpty) else { return }

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
        guard guardOrBeep(!records.isEmpty) else { return }

        let payload = MarkupClipboardPayload(sourceDocumentPageCount: document.pageCount, records: records)
        guard let encoded = try? PropertyListEncoder().encode(payload) else { beep(); return }
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
        guard let document = pdfView.document, let page = pdfView.currentPage else { beep(); return }
        let pageIndex = document.index(for: page)
        guard guardOrBeep(pageIndex >= 0) else { return }
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
        guard guardOrBeep(pdfView.document != nil) else { return }
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
    @objc func commandNavigateBack(_ sender: Any?) {
        guard guardOrBeep(pdfView.navigateBackInHistory()) else { return }
        updateStatusBar()
    }
    @objc func commandNavigateForward(_ sender: Any?) {
        guard guardOrBeep(pdfView.navigateForwardInHistory()) else { return }
        updateStatusBar()
    }
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

    private func batchCombinePDFs() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.pdf]
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.prompt = "Select"
        openPanel.message = "Select the PDF files to combine."
        guard openPanel.runModal() == .OK else { return }

        let selected = openPanel.urls
            .map { $0.standardizedFileURL }
            .filter { $0.pathExtension.lowercased() == "pdf" }
        guard guardOrBeep(!selected.isEmpty) else { return }

        let orderController = BatchCombineOrderWindowController(urls: selected)
        guard let ordered = orderController.runModal(), !ordered.isEmpty else { return }

        let defaultName = ordered.count == 1
            ? "\(ordered[0].deletingPathExtension().lastPathComponent)-combined.pdf"
            : "Combined-\(ordered.count)-files.pdf"
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = defaultName
        savePanel.prompt = "Combine"
        guard savePanel.runModal() == .OK, let outputURL = savePanel.url else { return }

        beginBusyIndicator("Combining PDFs…", detail: "Preparing files…", lockInteraction: false)
        defer { endBusyIndicator() }

        let combined = PDFDocument()
        var failedFiles: [String] = []
        var insertedPages = 0
        for (fileIndex, sourceURL) in ordered.enumerated() {
            updateBusyIndicatorDetail("Reading \(fileIndex + 1)/\(ordered.count) • \(sourceURL.lastPathComponent)")
            updateBusyIndicatorSubdetail("\(insertedPages) pages merged")
            updateBusyIndicatorProgress(current: fileIndex + 1, total: max(1, ordered.count))
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))

            guard let sourceDocument = PDFDocument(url: sourceURL), sourceDocument.pageCount > 0 else {
                failedFiles.append(sourceURL.lastPathComponent)
                continue
            }
            for pageIndex in 0..<sourceDocument.pageCount {
                guard let page = sourceDocument.page(at: pageIndex) else { continue }
                if let copy = page.copy() as? PDFPage {
                    combined.insert(copy, at: combined.pageCount)
                    insertedPages += 1
                }
            }
        }

        guard combined.pageCount > 0 else {
            runAlert(
                title: "Batch Combine Failed",
                informativeText: "No pages were merged. Check that the selected files are valid PDFs.",
                style: .warning
            )
            return
        }

        updateBusyIndicatorDetail("Writing combined PDF…")
        updateBusyIndicatorSubdetail("\(combined.pageCount) pages total")
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
        guard combined.write(to: outputURL, withOptions: nil) else {
            runAlert(
                title: "Failed to Save Combined PDF",
                informativeText: "Could not write \(outputURL.lastPathComponent).",
                style: .warning
            )
            return
        }

        openDocument(at: outputURL)

        if failedFiles.isEmpty {
            runAlert(
                title: "Batch Combine Complete",
                informativeText: "Created \(outputURL.lastPathComponent) with \(combined.pageCount) pages."
            )
        } else {
            let preview = failedFiles.prefix(8).joined(separator: ", ")
            let suffix = failedFiles.count > 8 ? ", …" : ""
            runAlert(
                title: "Batch Combine Complete with Issues",
                informativeText: """
                Created \(outputURL.lastPathComponent) with \(combined.pageCount) pages.
                Could not read: \(preview)\(suffix)
                """
            )
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        let hasDocument = (pdfView.document != nil)
        let hasSelection = (currentSelectedMarkupItem() != nil)
        let hasTextSelection = (pdfView.currentSelection != nil)

        switch action {
        case #selector(commandOpen(_:)),
             #selector(commandNew(_:)),
             #selector(commandKeyboardShortcuts(_:)),
             #selector(commandPerformanceSettings(_:)),
             #selector(commandExportPagesAsJPEGAndRebuildPDF(_:)),
             #selector(commandConvertImagesToPDF(_:)),
             #selector(commandBatchCombinePDFs(_:)),
             #selector(commandBatchExportPDFsAsJPEG(_:)):
            return true
        case #selector(commandCycleNextDocument(_:)),
             #selector(commandCyclePreviousDocument(_:)):
            return sessionDocumentURLs.count > 1
        case #selector(commandCloseDocument(_:)):
            return hasDocument || !sessionDocumentURLs.isEmpty
        case #selector(commandSave(_:)),
             #selector(commandSaveCopy(_:)),
             #selector(commandExportCSV(_:)),
             #selector(commandExportPagesAsJPEG(_:)),
             #selector(commandAutoGenerateSheetNames(_:)),
             #selector(commandBatchLinkSheetNumbers(_:)),
             #selector(commandSetScale(_:)),
             #selector(commandLockScalePages(_:)),
             #selector(commandClearScalePages(_:)),
             #selector(commandToggleOrthoSnap(_:)),
             #selector(commandToggleHyperlinkHighlights(_:)),
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
            if action == #selector(commandToggleOrthoSnap(_:)) {
                menuItem.state = isOrthoSnapEnabled ? .on : .off
            }
            if action == #selector(commandToggleHyperlinkHighlights(_:)) {
                menuItem.state = isHyperlinkHighlightsVisible ? .on : .off
            }
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
2) Tools (keyboard shortcuts): V Select, D Draw, A Arrow, L Line, P Polyline, Shift+P Polygon, Shift+A Area, H Highlighter, C Cloud, R Rect, E Ellipse, T Text, Q Callout, M Measure, K Calibrate
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
        beep()
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
        pdfView.navigateToDestinationWithHistory(destination)
        updateStatusBar()
    }

}
