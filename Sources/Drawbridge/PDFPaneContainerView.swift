import AppKit

@MainActor
final class PDFPaneContainerView: NSView {
    let pdfView: MarkupPDFView
    let header = NSView()
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
            modeLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            modeLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pdfView.topAnchor.constraint(equalTo: header.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        header.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateHeader(documentName: String, side: String, active: Bool, split: Bool) {
        header.isHidden = !split
        headerHeight.constant = split ? 30 : 0
        titleLabel.stringValue = documentName
        titleLabel.toolTip = documentName
        modeLabel.stringValue = "Split view · \(side)\(active ? " · Active" : "")"
        isActive = active
        // Scope the override to the header: never propagate it into PDFKit.
        header.appearance = InterfaceTheme.current.nativeAppearance
        refreshHeaderColors()
        header.toolTip = "Split view: two independent views of the same PDF. Click a pane to work in it. Drag the divider to resize."
        header.setAccessibilityLabel("\(side) split view, \(documentName)\(active ? ", active" : "")")
    }

    override func mouseDown(with event: NSEvent) {
        pdfView.onActivatePane?()
        window?.makeFirstResponder(pdfView)
    }
}

/// Retains normal button routing/accessibility without the native toggle bezel's
/// selected white text, which is unrelated to custom palette contrast.
@MainActor
final class DocumentChromeTabButton: NSButton {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChromeColors()
    }

    func refreshChromeColors() {
        wantsLayer = true
        isBordered = false
        (cell as? NSButtonCell)?.highlightsBy = []
        (cell as? NSButtonCell)?.showsStateBy = []
        let colors = ChromeSelectionColors(active: state == .on, appearance: effectiveAppearance)
        layer?.backgroundColor = colors.background.cgColor
        layer?.cornerRadius = 5
        layer?.borderWidth = state == .on ? 2 : 0
        layer?.borderColor = colors.accent.cgColor
        let text = NSAttributedString(string: title, attributes: [.foregroundColor: colors.foreground, .font: font ?? NSFont.systemFont(ofSize: 11)])
        attributedTitle = text
        attributedAlternateTitle = text
        contentTintColor = colors.foreground
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
