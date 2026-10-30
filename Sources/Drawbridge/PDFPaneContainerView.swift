import AppKit

@MainActor
final class PDFPaneContainerView: NSView {
    let pdfView: MarkupPDFView
    let header = NSView()
    let closeButton = NSButton()
    var onClose: (() -> Void)?
    let titleLabel = NSTextField(labelWithString: "")
    let modeLabel = NSTextField(labelWithString: "")
    private var headerHeight: NSLayoutConstraint!
    private var isActive = false

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshHeaderColors()
    }

    private func refreshHeaderColors() {
        let colors = ChromeSelectionColors(active: isActive, appearance: header.effectiveAppearance)
        titleLabel.textColor = colors.foreground
        modeLabel.textColor = colors.foreground
        closeButton.contentTintColor = colors.foreground
        header.layer?.backgroundColor = colors.background.cgColor
    }

    init(pdfView: MarkupPDFView) {
        self.pdfView = pdfView
        super.init(frame: pdfView.frame)
        autoresizingMask = [.width, .height]
        header.wantsLayer = true
        header.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close split view")
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closePane)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(closeButton)
        modeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        modeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        for label in [titleLabel, modeLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(label)
        }
        addSubview(header)
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pdfView)
        headerHeight = header.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor), headerHeight,
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: modeLabel.leadingAnchor, constant: -8),
            modeLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
            modeLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pdfView.topAnchor.constraint(equalTo: header.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        header.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func closePane() { onClose?() }

    func updateHeader(documentName: String, side: String, active: Bool, split: Bool) {
        header.isHidden = !split
        headerHeight.constant = split ? 30 : 0
        closeButton.toolTip = "Close \(side.lowercased()) view; keep the other view open"
        closeButton.setAccessibilityLabel("Close \(side.lowercased()) split view")
        titleLabel.stringValue = documentName
        titleLabel.toolTip = documentName
        modeLabel.stringValue = "Split view · \(side)\(active ? " · Active" : "")"
        isActive = active
        // Scope the override to the header: never propagate it into PDFKit.
        header.appearance = InterfaceTheme.current.nativeAppearance
        refreshHeaderColors()
        header.toolTip = "Split view: two views of the same PDF or different PDFs. Click a pane to work in it. Drag the divider to resize, or close either view to keep the other."
        header.setAccessibilityLabel("\(side) split view, \(documentName)\(active ? ", active" : "")")
    }

    override func mouseDown(with event: NSEvent) {
        pdfView.onActivatePane?()
        window?.makeFirstResponder(pdfView)
    }
}

/// Keep wheel navigation independent of whether AppKit installs a native scroller.
/// Some macOS versions ignore horizontal wheel input when that scroller is hidden.
@MainActor
final class DocumentTabsScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        guard delta.isFinite, delta != 0, let documentView else { return }
        let clip = contentView
        let distance = delta * (event.hasPreciseScrollingDeltas ? 1 : 16)
        let maximum = max(0, documentView.frame.width - clip.bounds.width)
        let x = max(0, min(maximum, clip.bounds.minX - distance))
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.minY))
        reflectScrolledClipView(clip)
    }
}

/// A bounded document tab with native button routing and an independent close target.
@MainActor
final class DocumentChromeTabButton: NSButton {
    // Native button alignment expands/clamps the cell's drawing rectangle.
    // This tab draws its own chrome and uses the complete constrained frame.
    override func alignmentRect(forFrame frame: NSRect) -> NSRect { frame }
    override func frame(forAlignmentRect alignmentRect: NSRect) -> NSRect { alignmentRect }
    let closeButton = NSButton()
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize: 12, weight: .medium)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close document")
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 240),
            heightAnchor.constraint(equalToConstant: 32),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func closeTab() { onClose?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChromeColors()
    }

    func refreshChromeColors() {
        wantsLayer = true
        (cell as? NSButtonCell)?.highlightsBy = []
        (cell as? NSButtonCell)?.showsStateBy = []
        let colors = ChromeSelectionColors(active: state == .on, appearance: effectiveAppearance)
        layer?.backgroundColor = colors.background.cgColor
        layer?.cornerRadius = 9
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer?.borderWidth = 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: title, attributes: [
            .foregroundColor: colors.foreground,
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .paragraphStyle: paragraph
        ])
        attributedTitle = text
        attributedAlternateTitle = text
        closeButton.contentTintColor = colors.foreground
        closeButton.toolTip = "Close \(title)"
        closeButton.setAccessibilityLabel("Close \(title)")
        setAccessibilityLabel(title)
        setAccessibilityValue(state == .on ? "Selected" : "")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = ChromeSelectionColors(active: state == .on, appearance: effectiveAppearance)
        if state == .on {
            colors.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: 12, y: 1, width: bounds.width - 24, height: 2), xRadius: 1, yRadius: 1).fill()
        } else {
            colors.foreground.withAlphaComponent(0.2).setFill()
            NSRect(x: bounds.width - 1, y: 8, width: 1, height: bounds.height - 16).fill()
        }
        let icon = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [colors.foreground]))
        icon?.draw(in: NSRect(x: 11, y: 9, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: 1)
        attributedTitle.draw(in: NSRect(x: 33, y: 8, width: bounds.width - 69, height: 17))
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7)
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

@MainActor
final class PDFPaneSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 10 }

    override func drawDivider(in rect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        rect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
        NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        NSColor.secondaryLabelColor.setFill()
        for offset in [-5.0, 0.0, 5.0] {
            NSRect(x: rect.midX - 2, y: rect.midY + offset - 1, width: 4, height: 2).fill()
        }
    }
}
