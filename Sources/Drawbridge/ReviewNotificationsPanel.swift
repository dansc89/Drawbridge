import AppKit

@MainActor final class ReviewNotificationsPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let title = NSTextField(labelWithString: "Notifications")
    let table = NSTableView()
    let status = NSTextField(wrappingLabelWithString: "No alerts yet")
    let refreshButton = NSButton()
    let olderButton = NSButton(title: "Older Alerts", target: nil, action: nil)
    private weak var inbox: ReviewNotificationsInbox?
    var onSelect: ((SharedReviewAPI.ReviewNotification) -> Void)?
    var onRefresh: (() -> Void)?
    var onOlder: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("review.notificationsPanel")
        translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh notifications")
        refreshButton.isBordered = false; refreshButton.target = self; refreshButton.action = #selector(refresh)
        refreshButton.toolTip = "Refresh notifications"
        let header = NSStackView(views: [title, NSView(), refreshButton]); header.orientation = .horizontal
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("notification")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 59; table.style = .fullWidth
        table.delegate = self; table.dataSource = self; table.target = self; table.action = #selector(openSelection)
        table.allowsEmptySelection = true; table.allowsMultipleSelection = false
        table.backgroundColor = .clear; table.focusRingType = .none
        table.setAccessibilityLabel("Review notifications")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        olderButton.controlSize = .small; olderButton.target = self; olderButton.action = #selector(older)
        let footer = NSStackView(views: [status, NSView(), olderButton]); footer.orientation = .horizontal
        let divider = NSBox(); divider.boxType = .separator
        let stack = NSStackView(views: [divider, header, scroll, footer]); stack.orientation = .vertical
        stack.spacing = 5; stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for view in [divider, header, scroll, footer] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor)])
        let preferred = heightAnchor.constraint(equalToConstant: 240); preferred.priority = .defaultHigh; preferred.isActive = true
        let minimum = heightAnchor.constraint(greaterThanOrEqualToConstant: 110); minimum.priority = NSLayoutConstraint.Priority(749); minimum.isActive = true
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    func bind(_ value: ReviewNotificationsInbox?) {
        guard inbox !== value else { return }
        inbox?.removeObserver(self); inbox = value
        value?.observe(self) { [weak self] in self?.render() }
        render()
    }
    func render() {
        let count = inbox?.unreadCount ?? 0
        title.stringValue = count == 0 ? "Notifications" : "Notifications (\(count))"
        status.stringValue = inbox?.status ?? "No alerts yet"
        status.isHidden = status.stringValue.isEmpty
        olderButton.isHidden = inbox?.canLoadOlder != true
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { inbox?.items.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let items = inbox?.items, items.indices.contains(row) else { return nil }
        let alert = items[row]
        let sender = NSTextField(labelWithString: (alert.readAt == nil ? "● " : "") + alert.sender)
        sender.font = .systemFont(ofSize: 12, weight: alert.readAt == nil ? .semibold : .regular)
        sender.lineBreakMode = .byTruncatingMiddle
        let location = NSTextField(labelWithString: "\(alert.document.name) · Page \(alert.page + 1)")
        location.font = .systemFont(ofSize: 11); location.textColor = .secondaryLabelColor; location.lineBreakMode = .byTruncatingMiddle
        let date = Date(timeIntervalSince1970: alert.createdAt / 1000)
        let when = NSTextField(labelWithString: date.formatted(date: .abbreviated, time: .shortened))
        when.font = .systemFont(ofSize: 10); when.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [sender, location, when]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.toolTip = "\(alert.sender) alerted you to \(alert.kind) on page \(alert.page + 1) of \(alert.document.name)"
        stack.setAccessibilityLabel(stack.toolTip!)
        return stack
    }
    @objc private func openSelection() {
        guard let items = inbox?.items, items.indices.contains(table.selectedRow) else { return }
        onSelect?(items[table.selectedRow])
    }
    @objc private func refresh() { onRefresh?() }
    @objc private func older() { onOlder?() }
}
