import AppKit

/// A drop-in color well that never activates the shared floating NSColorPanel.
/// Programmatic .color updates remain silent; committed choices use the existing action.
@MainActor
final class SwatchColorWell: NSColorWell {
    var allowsNoColor = false
    var allowsOpacity = true
    /// True only during a picker selection's synchronous target/action dispatch.
    /// Native/programmatic RGB actions do not imply an opacity edit.
    private(set) var isCommittingSelection = false
    var isNoColor = false { didSet { needsDisplay = true } }
    private(set) var swatchPopover: NSPopover?
    // Injectable presentation object keeps anchor routing testable without showing UI.
    var makeSwatchPopover: () -> NSPopover = { NSPopover() }
    override var color: NSColor { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 85, height: 26) }

    func selectColor(_ choice: NSColor, preservingOpacity: Bool = false) {
        guard isEnabled, choice.usingColorSpace(.sRGB) != nil else { return }
        color = choice.withAlphaComponent(allowsOpacity ? (preservingOpacity ? color.alphaComponent : choice.alphaComponent) : 1)
        isNoColor = false
        SwatchColorStore().remember(color)
        isCommittingSelection = true
        defer { isCommittingSelection = false }
        sendAction(action, to: target)
    }
    func selectNoColor() {
        guard isEnabled, allowsNoColor else { return }
        isNoColor = true
        sendAction(action, to: target)
    }
    override func activate(_ exclusive: Bool) { showSwatches() }
    override func deactivate() { swatchPopover?.close() }
    override func mouseDown(with event: NSEvent) { showSwatches() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { showSwatches() }
        else if event.keyCode == 53 { swatchPopover?.close() }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }; showSwatches(); return true
    }
    func showSwatches() { showSwatches(relativeTo: self) }
    func showSwatches(relativeTo anchor: NSView) {
        guard isEnabled, anchor.window != nil else { return }
        if swatchPopover?.isShown == true { swatchPopover?.close(); return }
        let popover = makeSwatchPopover()
        popover.behavior = .transient
        popover.contentViewController = SwatchPickerViewController(well: self)
        swatchPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        let chip = NSRect(x: rect.minX + 5, y: rect.minY + 5, width: max(8, rect.width - 24), height: max(8, rect.height - 10))
        drawSwatch(color, in: chip, noColor: isNoColor)
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).stroke()
        let image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        image?.draw(in: NSRect(x: rect.maxX - 15, y: rect.midY - 4, width: 9, height: 8), from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.35)
        if !isEnabled { NSColor.controlBackgroundColor.withAlphaComponent(0.5).setFill(); rect.fill() }
    }
}

@MainActor
private func drawSwatch(_ color: NSColor, in rect: NSRect, noColor: Bool = false) {
    NSColor.white.setFill(); rect.fill()
    NSColor(white: 0.78, alpha: 1).setFill()
    for y in stride(from: rect.minY, to: rect.maxY, by: 5) {
        for x in stride(from: rect.minX, to: rect.maxX, by: 5) {
            if (Int((x - rect.minX) / 5) + Int((y - rect.minY) / 5)) % 2 == 0 {
                NSRect(x: x, y: y, width: min(5, rect.maxX - x), height: min(5, rect.maxY - y)).fill()
            }
        }
    }
    if noColor {
        NSColor.systemRed.setStroke(); let line = NSBezierPath(); line.lineWidth = 2
        line.move(to: NSPoint(x: rect.minX, y: rect.minY)); line.line(to: NSPoint(x: rect.maxX, y: rect.maxY)); line.stroke()
    } else { color.setFill(); rect.fill(using: .sourceOver) }
    NSColor.separatorColor.setStroke(); rect.frame()
}

enum SwatchColorValue {
    static func parse(_ text: String) -> NSColor? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard [6, 8].contains(value.count), value.allSatisfy({ $0.isASCII && $0.isHexDigit }), let number = UInt64(value, radix: 16) else { return nil }
        let hasAlpha = value.count == 8
        let rgb = hasAlpha ? number >> 8 : number
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: hasAlpha ? CGFloat(number & 255) / 255 : 1)
    }
    static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    static func stored(_ color: NSColor) -> String {
        hex(color) + String(format: "%02X", Int((color.alphaComponent * 255).rounded()))
    }
}

@MainActor
final class SwatchColorStore {
    private let defaults: UserDefaults
    private let recentKey = "Drawbridge.colorPicker.recents.v1"
    private let favoriteKey = "Drawbridge.colorPicker.favorites.v1"
    var recents: [NSColor] { (defaults.stringArray(forKey: recentKey) ?? []).prefix(12).compactMap(SwatchColorValue.parse) }
    var favorites: [NSColor] { (defaults.stringArray(forKey: favoriteKey) ?? []).prefix(24).compactMap(SwatchColorValue.parse) }
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func remember(_ color: NSColor) {
        let key = SwatchColorValue.stored(color)
        defaults.set(Array(([key] + recents.map(SwatchColorValue.stored).filter { $0 != key }).prefix(12)), forKey: recentKey)
    }
    func toggleFavorite(_ color: NSColor) {
        let key = SwatchColorValue.stored(color)
        var values = favorites.map(SwatchColorValue.stored)
        if values.contains(key) { values.removeAll { $0 == key } }
        else { values.append(key) }
        defaults.set(Array(values.suffix(24)), forKey: favoriteKey)
    }
}

@MainActor
private final class SwatchButton: NSButton {
    let swatch: NSColor
    init(_ color: NSColor, target: AnyObject, action: Selector) {
        swatch = color
        super.init(frame: .zero)
        self.target = target; self.action = action; isBordered = false
        toolTip = SwatchColorValue.hex(color)
        setAccessibilityLabel("\(toolTip!) color, \(Int(color.alphaComponent * 100)) percent opacity")
        widthAnchor.constraint(equalToConstant: 21).isActive = true
        heightAnchor.constraint(equalToConstant: 21).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { drawSwatch(swatch, in: bounds.insetBy(dx: 1, dy: 1)) }
}

@MainActor
final class SwatchPickerViewController: NSViewController {
    weak var well: SwatchColorWell?
    let hexField = NSTextField()
    let redField = NSTextField(), greenField = NSTextField(), blueField = NSTextField(), opacityField = NSTextField()
    private let store = SwatchColorStore()
    private let savedRows = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private var sampler: NSColorSampler?
    init(well: SwatchColorWell) { self.well = well; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: "Swatches")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let favorite = NSButton(title: "☆ Save / remove", target: self, action: #selector(toggleFavorite))
        favorite.bezelStyle = .inline; favorite.setAccessibilityLabel("Toggle favorite color")
        let header = NSStackView(views: [title, favorite]); header.spacing = 30
        let presets = ["FFFFFF","D9D9D9","999999","666666","333333","000000",
                       "FF3B30","FF9500","FFCC00","34C759","00C7BE","007AFF",
                       "AF52DE","FF2D55","A2845E","804000","003366","006633",
                       "FFD6D3","FFE4BE","FFF3B0","C8EFD1","C6E7FF","E5D4F4"]
        let grid = makeGrid(presets.compactMap(SwatchColorValue.parse))
        savedRows.orientation = .vertical; savedRows.alignment = .leading; savedRows.spacing = 6
        for (field, label) in [(hexField,"HEX"), (redField,"R"), (greenField,"G"), (blueField,"B"), (opacityField,"Opacity %")] {
            field.setAccessibilityLabel(label); field.toolTip = label
            field.widthAnchor.constraint(equalToConstant: field === hexField ? 100 : 48).isActive = true
            field.target = self; field.action = #selector(commitFields(_:))
            field.cell?.sendsActionOnEndEditing = false
        }
        let hexRow = NSStackView(views: [NSTextField(labelWithString: "HEX"), hexField]); hexRow.spacing = 8
        let rgbRow = NSStackView(views: [NSTextField(labelWithString: "RGB"), redField, greenField, blueField]); rgbRow.spacing = 5
        let opacityRow = NSStackView(views: [NSTextField(labelWithString: "Opacity %"), opacityField]); opacityRow.spacing = 8
        opacityRow.isHidden = well?.allowsOpacity == false
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyRGB))
        apply.bezelStyle = .rounded
        let eye = NSButton(title: "Eyedropper", target: self, action: #selector(sampleColor))
        eye.bezelStyle = .rounded
        let actions = NSStackView(views: [eye, apply]); actions.spacing = 8
        status.font = .systemFont(ofSize: 10); status.textColor = .secondaryLabelColor
        status.stringValue = "Enter HEX or RGB, then Apply."
        let stack = NSStackView(views: [header, grid, savedRows, NSBox(), hexRow, rgbRow, opacityRow, actions, status])
        (stack.arrangedSubviews[3] as? NSBox)?.boxType = .separator
        if well?.allowsNoColor == true {
            let none = NSButton(title: "None", target: self, action: #selector(noColor)); none.bezelStyle = .rounded
            stack.insertArrangedSubview(none, at: 1)
        }
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)])
        syncFields(); refreshSaved()
    }
    private func makeGrid(_ colors: [NSColor]) -> NSStackView {
        let grid = NSStackView(); grid.orientation = .vertical; grid.alignment = .leading; grid.spacing = 3
        for start in stride(from: 0, to: colors.count, by: 8) {
            let row = NSStackView(views: colors[start..<min(start + 8, colors.count)].map { SwatchButton($0, target: self, action: #selector(pick(_:))) })
            row.spacing = 3; grid.addArrangedSubview(row)
        }
        return grid
    }
    private func refreshSaved() {
        for child in savedRows.arrangedSubviews { savedRows.removeArrangedSubview(child); child.removeFromSuperview() }
        for (title, colors) in [("Favorites", store.favorites), ("Recent", store.recents)] {
            let label = NSTextField(labelWithString: colors.isEmpty ? "\(title) — none yet" : title)
            label.font = .systemFont(ofSize: 10); label.textColor = .secondaryLabelColor
            savedRows.addArrangedSubview(label)
            if !colors.isEmpty { savedRows.addArrangedSubview(makeGrid(colors)) }
        }
        preferredContentSize = view.fittingSize
    }
    private func syncFields() {
        guard let rgb = well?.color.usingColorSpace(.sRGB) else { return }
        hexField.stringValue = SwatchColorValue.hex(rgb)
        redField.integerValue = Int((rgb.redComponent * 255).rounded())
        greenField.integerValue = Int((rgb.greenComponent * 255).rounded())
        blueField.integerValue = Int((rgb.blueComponent * 255).rounded())
        opacityField.doubleValue = Double(rgb.alphaComponent * 100)
    }
    @objc private func pick(_ sender: SwatchButton) {
        well?.selectColor(sender.swatch, preservingOpacity: true); syncFields(); refreshSaved()
    }
    @objc private func toggleFavorite() {
        guard let well else { return }; store.toggleFavorite(well.color); refreshSaved()
    }
    @objc private func noColor() { well?.selectNoColor(); well?.swatchPopover?.close() }
    @objc func commitFields(_ sender: NSTextField) {
        if sender === hexField { applyHex() } else { applyRGB() }
    }
    func applyHex() {
        guard let color = SwatchColorValue.parse(hexField.stringValue) else { status.stringValue = "Use #RGB, #RRGGBB or #RRGGBBAA."; return }
        let count = hexField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).filter { $0 != "#" }.count
        well?.selectColor(color, preservingOpacity: count != 8); syncFields(); refreshSaved()
        status.stringValue = "Color applied."
    }
    @objc func applyRGB() {
        // Apply also honors a HEX draft if it differs from the currently synchronized value.
        if let well, hexField.stringValue != SwatchColorValue.hex(well.color) { applyHex(); return }
        guard let r = Double(redField.stringValue), let g = Double(greenField.stringValue), let b = Double(blueField.stringValue),
              let a = Double(opacityField.stringValue), [r,g,b,a].allSatisfy(\.isFinite),
              [r,g,b].allSatisfy({ (0...255).contains($0) }), (0...100).contains(a) else {
            status.stringValue = "RGB: 0–255; opacity: 0–100%."; return
        }
        well?.selectColor(NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a / 100))
        syncFields(); refreshSaved(); status.stringValue = "Color applied."
    }
    @objc private func sampleColor() {
        guard let well else { return }
        let sampler = NSColorSampler(); self.sampler = sampler
        well.swatchPopover?.close()
        sampler.show { [weak well, self] color in
            Task { @MainActor in
                if let color { well?.selectColor(color, preservingOpacity: true) }
                self.sampler = nil
            }
        }
    }
}
