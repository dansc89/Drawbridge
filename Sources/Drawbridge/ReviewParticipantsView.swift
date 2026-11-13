import AppKit

/// Workspace-wide presentation only; no network calls or locally fabricated membership.
@MainActor
final class ReviewParticipantsView: NSView {
    let disclosureButton = NSButton(title: "Participants", target: nil, action: nil)
    let summaryField = NSTextField(labelWithString: "")
    let rowsStack = NSStackView()
    let bodyStack = NSStackView()
    private let scrollView = NSScrollView()
    private var rowsHeight: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        disclosureButton.bezelStyle = .inline
        disclosureButton.setButtonType(.pushOnPushOff)
        disclosureButton.state = .on
        disclosureButton.imagePosition = .imageLeading
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleParticipants)
        disclosureButton.setAccessibilityHelp("Show or hide workspace participants")
        summaryField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryField.textColor = .secondaryLabelColor
        summaryField.lineBreakMode = .byTruncatingTail
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 4
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = rowsStack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        rowsHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
        rowsHeight.isActive = true
        rowsStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 4
        bodyStack.addArrangedSubview(summaryField)
        bodyStack.addArrangedSubview(scrollView)
        let stack = NSStackView(views: [disclosureButton, bodyStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bodyStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summaryField.widthAnchor.constraint(equalTo: bodyStack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: bodyStack.widthAnchor)
        ])
        render(nil)
        updateDisclosure()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Future transport owner must call again on snapshot changes and expiry ticks.
    // An unavailable connection is not an authoritative empty roster.
    func render(_ snapshot: ReviewParticipants?, at now: Date = Date()) {
        if let count = snapshot?.participantCount {
            disclosureButton.title = "Participants (\(count))"
        } else if snapshot?.connection == .disconnected {
            disclosureButton.title = "Participants — disconnected"
        } else {
            disclosureButton.title = "Participants — unavailable"
        }
        disclosureButton.setAccessibilityLabel(disclosureButton.title)
        summaryField.stringValue = snapshot?.summary(at: now) ?? "Participant presence unavailable."
        summaryField.toolTip = summaryField.stringValue
        for row in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        let rows = snapshot?.rows(at: now) ?? []
        for row in rows {
            let name = NSTextField(labelWithString: row.participant.verifiedName)
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let state = NSTextField(labelWithString: row.state.rawValue)
            state.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            state.textColor = .secondaryLabelColor
            let line = NSStackView(views: [name, NSView(), state])
            line.alignment = .centerY
            line.spacing = 8
            line.setAccessibilityLabel("\(row.participant.verifiedName), \(row.state.rawValue)")
            rowsStack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            line.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }
        scrollView.isHidden = rows.isEmpty
        rowsHeight.constant = CGFloat(min(rows.count, 5)) * 24
    }

    @objc private func toggleParticipants() {
        bodyStack.isHidden = disclosureButton.state != .on
        updateDisclosure()
    }

    private func updateDisclosure() {
        disclosureButton.image = NSImage(systemSymbolName: bodyStack.isHidden ? "chevron.right" : "chevron.down",
                                        accessibilityDescription: nil)
    }
}
