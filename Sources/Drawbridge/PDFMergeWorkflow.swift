import AppKit
import UniformTypeIdentifiers
import os

/// A separate menu target keeps Merge available even with no document open.
@MainActor final class PDFMergeWorkflow: NSObject, NSMenuItemValidation {
    weak var controller: MainViewController?
    private var sheet: PDFMergeSheetController?
    private var cancellation: PDFProcessingCancellation?
    // Observation-only hook for verifying the asynchronous processing boundary.
    var onProcessingStarted: (@Sendable () -> Void)?

    func startMerge(sources: [URL], destination: URL) {
        guard cancellation == nil, let sheet, sheet.savedDestination == nil, let window = sheet.window else { return }
        let cancellation = PDFProcessingCancellation()
        self.cancellation = cancellation
        sheet.setProcessing(true)
        let onProcessingStarted = self.onProcessingStarted
        DispatchQueue.global(qos: .userInitiated).async {
            onProcessingStarted?()
            let result = Result { try PDFMergeService.merge(sources: sources, destination: destination, cancelled: { cancellation.cancelled }) }
            DispatchQueue.main.async {
                self.cancellation = nil
                switch result {
                case .success:
                    sheet.setSavedDestination(destination)
                    self.openSavedOutput()
                case .failure(let error):
                    if error is CancellationError { self.dismiss(); return }
                    sheet.setProcessing(false)
                    let alert = NSAlert()
                    alert.messageText = "Merge PDFs Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { true }

    @objc func showMerge(_ sender: Any?) {
        if let sheet { sheet.window?.makeKeyAndOrderFront(nil); return }
        guard let parent = controller?.view.window else { return }
        let sheet = PDFMergeSheetController()
        self.sheet = sheet
        sheet.onCancel = { [weak self] in
            guard let self else { return }
            if let cancellation = self.cancellation {
                cancellation.cancel()
                self.sheet?.countLabel.stringValue = "Canceling after the current processing step…"
            } else { self.dismiss() }
        }
        sheet.onMerge = { [weak self] in
            guard let self else { return }
            if self.sheet?.savedDestination != nil { self.openSavedOutput() }
            else { self.chooseDestination() }
        }
        if let window = sheet.window { parent.beginSheet(window) }
    }

    private var openingSavedOutput = false

    private func openSavedOutput() {
        guard !openingSavedOutput, let sheet, let destination = sheet.savedDestination,
              let controller, !controller.isPDFProcessingBusy else { return }
        openingSavedOutput = true
        sheet.mergeButton.isEnabled = false
        defer {
            openingSavedOutput = false
            sheet.mergeButton.isEnabled = true
        }
        // This retains the normal unsaved-changes protection. A declined prompt
        // (or another blocked open) leaves the saved result available for retry.
        guard controller.confirmDiscardUnsavedChangesIfNeeded() else { return }
        controller.openDocument(at: destination)
        if controller.openDocumentURL.map(controller.canonicalDocumentURL) == controller.canonicalDocumentURL(destination) {
            dismiss()
        }
    }

    private func dismiss() {
        if let window = sheet?.window {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }
        sheet = nil
        cancellation = nil
    }

    private func chooseDestination() {
        guard let sheet, sheet.savedDestination == nil, sheet.list.canMerge, let window = sheet.window else { return }
        let panel = NSSavePanel()
        panel.title = "Save Merged PDF"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Merged.pdf"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self, let sheet = self.sheet else { return }
            self.startMerge(sources: sheet.list.urls, destination: destination)
        }
    }
}

@MainActor final class PDFMergeSheetController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var list = PDFMergeList()
    let mergeButton = NSButton(title: "Merge…", target: nil, action: nil)
    let addButton = NSButton(title: "Add PDFs…", target: nil, action: nil)
    let countLabel = NSTextField(labelWithString: "")
    let table = NSTableView()
    let sortButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private var sortOrder: PDFMergeSort = .manual
    private var metadataGeneration = 0
    private var pendingMetadata: [UUID: PDFMergeMetadata]?
    private var pickerActive = false
    private var pickerDirectory: URL?
    private static let pickerLog = OSLog(subsystem: "Drawbridge", category: "MergePicker")
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let upButton = NSButton(title: "Move Up", target: nil, action: nil)
    private let downButton = NSButton(title: "Move Down", target: nil, action: nil)
    private var processing = false
    private(set) var savedDestination: URL?
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    var onMerge: (() -> Void)?
    var onCancel: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 460), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 800, height: 460)
        window.title = "Merge PDFs"
        super.init(window: window)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 460))
        window.contentView = content
        let heading = NSTextField(labelWithString: "Merge PDFs")
        heading.font = .boldSystemFont(ofSize: 18)
        heading.frame = NSRect(x: 20, y: 418, width: 760, height: 25)
        heading.autoresizingMask = [.width, .minYMargin]
        content.addSubview(heading)
        let note = NSTextField(wrappingLabelWithString: "Combines saved pages without rasterizing; keeps rotations and editable annotations. Unsaved edits are not included. Document-level bookmarks, forms and navigation may not carry over.")
        note.frame = NSRect(x: 20, y: 354, width: 760, height: 55)
        note.autoresizingMask = [.width, .minYMargin]
        content.addSubview(note)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 142, width: 760, height: 202))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        for (title, width) in [("Order", 55.0), ("Name", 380.0), ("Size", 90.0), ("Location", 400.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            column.title = title
            column.width = width
            column.minWidth = title == "Order" ? 45 : 70
            column.resizingMask = .userResizingMask
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 30
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        scroll.documentView = table
        content.addSubview(scroll)
        for (button, x, width, action) in [
            (addButton, 20.0, 125.0, #selector(addPDFs(_:))),
            (removeButton, 155.0, 105.0, #selector(removePDF(_:))),
            (upButton, 270.0, 115.0, #selector(movePDFUp(_:))),
            (downButton, 395.0, 125.0, #selector(movePDFDown(_:)))
        ] {
            button.frame = NSRect(x: x, y: 100, width: width, height: 32)
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            content.addSubview(button)
        }
        countLabel.frame = NSRect(x: 20, y: 69, width: 660, height: 23)
        countLabel.autoresizingMask = [.width]
        content.addSubview(countLabel)
        sortButton.frame = NSRect(x: 540, y: 100, width: 240, height: 32)
        sortButton.autoresizingMask = [.minXMargin]
        sortButton.addItems(withTitles: PDFMergeSort.allCases.map(\.rawValue))
        sortButton.target = self
        sortButton.action = #selector(changeSort(_:))
        sortButton.toolTip = "Sort changes the actual merge order. Unknown metadata sorts last; ties keep their current order. Manual order keeps the order shown."
        content.addSubview(sortButton)
        let cancel = cancelButton
        cancel.target = self
        cancel.action = #selector(cancelMerge(_:))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 485, y: 20, width: 105, height: 32)
        cancel.autoresizingMask = [.minXMargin]
        content.addSubview(cancel)
        mergeButton.frame = NSRect(x: 600, y: 20, width: 180, height: 32)
        mergeButton.autoresizingMask = [.minXMargin]
        mergeButton.bezelStyle = .rounded
        mergeButton.keyEquivalent = "\r"
        mergeButton.target = self
        mergeButton.action = #selector(mergePDFs(_:))
        content.addSubview(mergeButton)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func numberOfRows(in tableView: NSTableView) -> Int { list.urls.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard list.entries.indices.contains(row) else { return nil }
        let entry = list.entries[row], url = entry.url
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "Order": text = String(row + 1)
        case "Size": text = entry.metadata.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Unknown"
        case "Location": text = url.deletingLastPathComponent().path
        default: text = url.lastPathComponent
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = url.path
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    func addURLs(_ urls: [URL]) {
        guard !processing, savedDestination == nil else { return }
        list.add(urls)
        applySort()
        refresh()
        loadMetadata()
    }
    func setProcessing(_ processing: Bool) {
        self.processing = processing
        if !processing, savedDestination == nil, let pendingMetadata {
            self.pendingMetadata = nil
            list.updateMetadata(pendingMetadata)
            applySort()
        }
        refresh()
    }
    func setSavedDestination(_ destination: URL) {
        savedDestination = destination
        processing = false
        mergeButton.title = "Open Merged PDF"

        cancelButton.title = "Close"
        pendingMetadata = nil
        metadataGeneration += 1
        countLabel.frame = NSRect(x: 20, y: 55, width: (window?.contentView?.bounds.width ?? 800) - 40, height: 42)
        countLabel.maximumNumberOfLines = 2
        countLabel.lineBreakMode = .byTruncatingMiddle
        countLabel.toolTip = destination.path
        refresh()
    }
    private func applySort() {
        let selectedID = list.entries.indices.contains(table.selectedRow) ? list.entries[table.selectedRow].id : nil
        list.sort(sortOrder)
        refresh()
        if let selectedID, let index = list.entries.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }
    @objc private func changeSort(_ sender: NSPopUpButton) {
        guard !processing, savedDestination == nil,
              let title = sender.titleOfSelectedItem, let order = PDFMergeSort(rawValue: title) else {
            sortButton.selectItem(withTitle: sortOrder.rawValue)
            return
        }
        sortOrder = order
        applySort()
    }
    private func loadMetadata() {
        metadataGeneration += 1
        pendingMetadata = nil
        let generation = metadataGeneration
        let entries = list.entries
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let values = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, PDFMergeMetadata.read($0.url)) })
            DispatchQueue.main.async { [weak self] in
                guard let self, self.metadataGeneration == generation, self.savedDestination == nil else { return }
                // While processing, do not mutate order, selection, or the frozen inputs.
                if self.processing { self.pendingMetadata = values; return }
                self.list.updateMetadata(values)
                self.applySort()
            }
        }
    }
    private func refresh() {
        let selectedID = list.entries.indices.contains(table.selectedRow) ? list.entries[table.selectedRow].id : nil
        table.reloadData()
        if let selectedID, let index = list.entries.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        if let savedDestination {
            countLabel.stringValue = "Merged PDF saved. Open it when ready:\n\(savedDestination.path)"
        } else {
            countLabel.stringValue = processing ? "Merging PDFs… originals will not be changed" : "\(list.urls.count) PDFs • merged in the order shown"
        }
        updateControls()
    }
    private func updateControls() {
        let selected = table.selectedRow
        let editable = !processing && savedDestination == nil
        addButton.isEnabled = editable
        sortButton.isEnabled = editable
        mergeButton.isEnabled = !processing && (savedDestination != nil || list.canMerge)
        removeButton.isEnabled = selected >= 0 && editable
        upButton.isEnabled = selected > 0 && editable
        downButton.isEnabled = selected >= 0 && selected < list.urls.count - 1 && editable
    }
    @objc private func addPDFs(_ sender: Any?) {
        guard let window, !processing, savedDestination == nil, !pickerActive else { return }
        pickerActive = true
        let timing = OSSignpostID(log: Self.pickerLog)
        os_signpost(.begin, log: Self.pickerLog, name: "Construct Add PDFs panel", signpostID: timing)
        let panel = NSOpenPanel()
        os_signpost(.end, log: Self.pickerLog, name: "Construct Add PDFs panel", signpostID: timing)
        panel.title = "Add PDFs to Merge"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = pickerDirectory ?? list.urls.first?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        os_signpost(.begin, log: Self.pickerLog, name: "Begin Add PDFs sheet", signpostID: timing)
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.pickerActive = false
            self?.pickerDirectory = panel.directoryURL
            if response == .OK { self?.addURLs(panel.urls) }
        }
        os_signpost(.end, log: Self.pickerLog, name: "Begin Add PDFs sheet", signpostID: timing)
    }
    @objc private func removePDF(_ sender: Any?) {
        guard !processing, savedDestination == nil else { return }
        let index = table.selectedRow
        list.remove(index: index)
        loadMetadata()
        refresh()
        if !list.urls.isEmpty { table.selectRowIndexes(IndexSet(integer: min(max(index, 0), list.urls.count - 1)), byExtendingSelection: false) }
    }
    private func move(_ offset: Int) {
        guard !processing, savedDestination == nil else { return }
        let index = table.selectedRow, destination = index + offset
        guard list.urls.indices.contains(index), list.urls.indices.contains(destination) else { return }
        list.move(index: index, offset: offset)
        sortOrder = .manual
        sortButton.selectItem(withTitle: sortOrder.rawValue)
        refresh()
        table.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
    }
    @objc private func movePDFUp(_ sender: Any?) { move(-1) }
    @objc private func movePDFDown(_ sender: Any?) { move(1) }
    @objc private func mergePDFs(_ sender: Any?) { if !processing && (savedDestination != nil || list.canMerge) { onMerge?() } }
    @objc private func cancelMerge(_ sender: Any?) { onCancel?() }
}
