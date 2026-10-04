import AppKit
import PDFKit

struct SheetNavigationEntry: Equatable {
    let pageIndex: Int
    let label: String
    let titles: [String]

    static func matching(_ entries: [Self], query: String) -> [Self] {
        let terms = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return entries }
        func normalized(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        return entries.filter { entry in
            let text = normalized("\(entry.label) \(entry.titles.joined(separator: " ")) page \(entry.pageIndex + 1)")
            return terms.allSatisfy { text.contains($0) }
        }.sorted { lhs, rhs in
            // Exact labels win, then prefixes. Preserve page order for other matches.
            let query = terms.joined(separator: " ")
            func rank(_ entry: Self) -> Int {
                let label = normalized(entry.label)
                if label == query { return 0 }
                if label.hasPrefix(query) { return 1 }
                return 2
            }
            let a = rank(lhs), b = rank(rhs)
            return a == b ? lhs.pageIndex < rhs.pageIndex : a < b
        }
    }

    @MainActor
    static func build(document: PDFDocument, label: (Int) -> String) -> [Self] {
        var titles: [Int: [String]] = [:]
        var pending = document.outlineRoot.map { [$0] } ?? []
        var visited = Set<ObjectIdentifier>()
        while let outline = pending.popLast() {
            guard visited.insert(ObjectIdentifier(outline)).inserted else { continue }
            let page = outline.destination?.page ?? (outline.action as? PDFActionGoTo)?.destination.page
            if let page {
                let index = document.index(for: page)
                if index >= 0, index < document.pageCount, let title = outline.label, !title.isEmpty {
                    if !titles[index, default: []].contains(title) { titles[index, default: []].append(title) }
                }
            }
            for index in (0..<outline.numberOfChildren).reversed() {
                if let child = outline.child(at: index) { pending.append(child) }
            }
        }
        return (0..<document.pageCount).map { Self(pageIndex: $0, label: label($0), titles: titles[$0] ?? []) }
    }
}

/// A read-only sheet picker. No OCR, PDF rewriting or page-label mutation.
@MainActor
final class SheetNavigator: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let entries: [SheetNavigationEntry]
    private var filtered: [SheetNavigationEntry]
    private let search = NSSearchField()
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private var chosenPage: Int?

    init(entries: [SheetNavigationEntry], currentPage: Int) {
        self.entries = entries; filtered = entries
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Go to Sheet"
        panel.minSize = NSSize(width: 440, height: 300)
        super.init(window: panel)
        panel.delegate = self
        search.placeholderString = "Sheet number, title, or page number"
        search.delegate = self
        search.setAccessibilityLabel("Find a sheet")
        search.maximumRecents = 0
        for (name, width) in [("Page", 50.0), ("Sheet", 130.0), ("Title", 460.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            column.title = name; column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self
        table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 28
        table.allowsMultipleSelection = false
        table.target = self; table.doubleAction = #selector(choose)
        table.setAccessibilityLabel("Sheets in page order")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.documentView = table
        scroll.borderType = .bezelBorder
        let go = NSButton(title: "Go to Sheet", target: self, action: #selector(choose))
        go.bezelStyle = .rounded; go.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        summary.font = .systemFont(ofSize: 11); summary.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [summary, NSView(), cancel, go])
        footer.orientation = .horizontal
        let stack = NSStackView(views: [search, scroll, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        table.reloadData()
        if let row = entries.firstIndex(where: { $0.pageIndex == currentPage }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
        updateSummary()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func runModal(parent: NSWindow?) -> Int? {
        if let parent { window?.setFrameOrigin(NSPoint(x: parent.frame.midX - 340, y: parent.frame.midY - 210)) }
        else { window?.center() }
        window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(search)
        if let window { NSApp.runModal(for: window) }
        window?.orderOut(nil)
        return chosenPage
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard filtered.indices.contains(row) else { return nil }
        let entry = filtered[row]
        switch tableColumn?.identifier.rawValue {
        case "Page": return entry.pageIndex + 1
        case "Sheet": return entry.label
        default: return entry.titles.joined(separator: " • ")
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        filtered = SheetNavigationEntry.matching(entries, query: search.stringValue)
        table.reloadData()
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); table.scrollRowToVisible(0) }
        updateSummary()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch NSStringFromSelector(commandSelector) {
        case "moveDown:", "moveUp:":
            guard !filtered.isEmpty else { return true }
            let delta = NSStringFromSelector(commandSelector) == "moveDown:" ? 1 : -1
            let row = min(max(table.selectedRow + delta, 0), filtered.count - 1)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
            return true
        case "insertNewline:": choose(); return true
        case "cancelOperation:": cancel(); return true
        default: return false
        }
    }
    private func updateSummary() { summary.stringValue = filtered.isEmpty ? "No matching sheets" : "\(filtered.count) of \(entries.count) sheets • ↑↓ select • Return opens" }
    @objc private func choose() {
        guard filtered.indices.contains(table.selectedRow) else { NSSound.beep(); return }
        chosenPage = filtered[table.selectedRow].pageIndex
        NSApp.stopModal()
    }
    @objc private func cancel() { NSApp.stopModal() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return true }
}
