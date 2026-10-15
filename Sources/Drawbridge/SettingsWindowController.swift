import AppKit

/// Resolve dynamic colors again when macOS changes appearance while Settings is open.
@MainActor private final class SettingsSidebarStack: NSStackView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackground()
    }
    func refreshBackground() {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = AppAppearance.sidebar.cgColor
        }
    }
}

/// A single retained, nonmodal native settings surface. Edits apply only within their section.
@MainActor final class SettingsWindowController: NSWindowController {
    enum Section: String, CaseIterable {
        case general = "General", shortcuts = "Keyboard Shortcuts", performance = "Performance", interface = "Interface"
    }
    private weak var editor: MainViewController?
    private let content = NSStackView()
    private let navigation = SettingsSidebarStack()
    private var panes: [Section: NSView] = [:]
    private var author = NSTextField()
    private var keys: [ShortcutAction: NSTextField] = [:]
    private var modifiers: [ShortcutAction: NSPopUpButton] = [:]
    private let validation = NSTextField(labelWithString: "")
    private let adaptive = NSButton(checkboxWithTitle: "Adaptive index cap for very large PDFs", target: nil, action: nil)
    private let cap = NSTextField()
    private let watchdog = NSButton(checkboxWithTitle: "Enable main-thread stall watchdog logging", target: nil, action: nil)
    private let threshold = NSTextField()
    private let mode = NSPopUpButton()
    private let preset = NSPopUpButton()
    private var primaryLabels: [NSTextField] = []

    init(editor: MainViewController) {
        self.editor = editor
        super.init(window: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepare(section: Section = .general) {
        if window == nil { buildWindow() }
        for pane in content.arrangedSubviews { content.removeArrangedSubview(pane); pane.removeFromSuperview() }
        if let pane = panes[section] { content.addArrangedSubview(pane) }
        for case let button as NSButton in navigation.arrangedSubviews {
            button.state = button.title == section.rawValue ? .on : .off
        }
        window?.title = "Settings — \(section.rawValue)"
        applyTheme()
    }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 460)
        self.window = window
        navigation.orientation = .vertical
        navigation.alignment = .leading
        navigation.spacing = 8
        navigation.edgeInsets = NSEdgeInsets(top: 24, left: 16, bottom: 24, right: 16)
        for section in Section.allCases {
            let button = NSButton(title: section.rawValue, target: self, action: #selector(selectSection(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            button.alignment = .left
            navigation.addArrangedSubview(button)
        }
        content.orientation = .vertical
        content.alignment = .leading
        content.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        let root = NSStackView(views: [navigation, NSBox(), content])
        root.orientation = .horizontal
        root.alignment = .top
        root.spacing = 0
        if let divider = root.arrangedSubviews[1] as? NSBox { divider.boxType = .separator }
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            navigation.widthAnchor.constraint(equalToConstant: 200), content.widthAnchor.constraint(greaterThanOrEqualToConstant: 540)
        ])
        buildGeneral(); buildShortcuts(); buildPerformance(); buildInterface()
    }

    private func pane(_ section: Section, _ views: [NSView]) {
        let title = NSTextField(labelWithString: section.rawValue)
        primaryLabels.append(title)
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let stack = NSStackView(views: [title] + views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        panes[section] = stack
    }
    private func help(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = .secondaryLabelColor
        field.widthAnchor.constraint(equalToConstant: 480).isActive = true
        return field
    }
    private func field(_ field: NSTextField, id: String, value: String) -> NSTextField {
        field.identifier = NSUserInterfaceItemIdentifier(id); field.stringValue = value
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        return field
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private func row(_ title: String, _ control: NSView) -> NSView {
        control.setAccessibilityLabel(title)
        let label = NSTextField(labelWithString: title)
        primaryLabels.append(label)
        return NSStackView(views: [label, control])
    }
    private func buildGeneral() {
        pane(.general, [row("Markup author", field(author, id: "markupAuthor", value: MarkupAuthorPreference.currentName)), help("Used for new markups. Existing author names are preserved. Leave blank to use your macOS account name."), button("Save General", #selector(saveGeneral))])
    }
    @objc private func saveGeneral() {
        window?.makeFirstResponder(nil)
        UserDefaults.standard.set(author.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: MarkupAuthorPreference.defaultsKey)
    }
    private func buildShortcuts() {
        guard let editor else { return }
        var views: [NSView] = [help("Customize the Select Text binding. All other tool shortcuts remain unchanged. Use one letter, number, or supported punctuation character.")]
        for action in ShortcutAction.allCases {
            let binding = editor.currentShortcutBinding(for: action)
            let key = field(NSTextField(), id: "shortcut.\(action.rawValue)", value: binding.key.uppercased())
            let modifier = NSPopUpButton(); modifier.addItems(withTitles: ["None", "Shift", "Cmd+Shift"])
            modifier.selectItem(at: ShortcutModifier.allCases.firstIndex(of: binding.modifier) ?? 0)
            keys[action] = key; modifiers[action] = modifier
            views.append(row(action.displayName, NSStackView(views: [modifier, key])))
        }
        validation.textColor = .systemRed
        views += [validation, NSStackView(views: [button("Save Shortcuts", #selector(saveShortcuts)), button("Restore Defaults", #selector(restoreShortcuts))])]
        pane(.shortcuts, views)
    }
    @objc private func saveShortcuts() {
        window?.makeFirstResponder(nil)
        guard let editor else { return }
        var updated: [ShortcutAction: ShortcutBinding] = [:]; var seen = Set<String>()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "[]\\;',./`-="))
        for action in ShortcutAction.allCases {
            let key = keys[action]!.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key.count == 1, key.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { validation.stringValue = "Each shortcut must use a single supported character."; return }
            let binding = ShortcutBinding(key: key, modifier: ShortcutModifier.allCases[modifiers[action]!.indexOfSelectedItem])
            guard seen.insert(binding.encoded).inserted else { validation.stringValue = "Each shortcut combination can only be assigned once."; return }
            updated[action] = binding
        }
        editor.shortcutBindings = updated; editor.saveShortcutBindings(); editor.updateShortcutHintLabel()
        validation.stringValue = "Shortcuts saved."
    }
    @objc private func restoreShortcuts() {
        editor?.resetShortcutBindingsToDefaults()
        for action in ShortcutAction.allCases {
            keys[action]?.stringValue = action.defaultBinding.key.uppercased()
            modifiers[action]?.selectItem(at: ShortcutModifier.allCases.firstIndex(of: action.defaultBinding.modifier)!)
        }
        validation.stringValue = "Defaults restored."
    }
    private func buildPerformance() {
        guard let editor else { return }
        let defaults = UserDefaults.standard
        adaptive.state = defaults.bool(forKey: MainViewController.defaultsAdaptiveIndexCapEnabledKey) ? .on : .off
        watchdog.state = defaults.bool(forKey: MainViewController.defaultsWatchdogEnabledKey) ? .on : .off
        pane(.performance, [adaptive, row("Max indexed markups", field(cap, id: "indexCap", value: "\(editor.configuredIndexCap())")), watchdog, row("Stall threshold (seconds)", field(threshold, id: "watchdogThreshold", value: "\(max(0.5, defaults.double(forKey: MainViewController.defaultsWatchdogThresholdSecondsKey)))")), help("Watchdog logs: ~/Library/Application Support/Drawbridge/Logs/watchdog.log"), button("Apply Performance", #selector(savePerformance))])
    }
    @objc private func savePerformance() {
        window?.makeFirstResponder(nil)
        guard let editor else { return }
        let defaults = UserDefaults.standard
        defaults.set(adaptive.state == .on, forKey: MainViewController.defaultsAdaptiveIndexCapEnabledKey)
        defaults.set(min(max(cap.integerValue, editor.minimumIndexedMarkupItems), editor.maximumIndexedMarkupItems), forKey: MainViewController.defaultsIndexCapKey)
        defaults.set(watchdog.state == .on, forKey: MainViewController.defaultsWatchdogEnabledKey)
        defaults.set(min(max(threshold.doubleValue, 0.5), 30), forKey: MainViewController.defaultsWatchdogThresholdSecondsKey)
        editor.configureWatchdogFromDefaults()
        editor.scheduleMarkupsRefresh(selecting: editor.currentSelectedAnnotation())
        cap.integerValue = defaults.integer(forKey: MainViewController.defaultsIndexCapKey)
        threshold.doubleValue = defaults.double(forKey: MainViewController.defaultsWatchdogThresholdSecondsKey)
    }
    private func buildInterface() {
        mode.addItems(withTitles: ["Follow macOS", "Custom Colors"])
        preset.addItems(withTitles: InterfaceTheme.presets.map(\.title))
        let theme = InterfaceTheme.current
        mode.selectItem(at: theme == .system ? 0 : 1)
        preset.selectItem(at: InterfaceTheme.presets.firstIndex(of: theme) ?? 0)
        preset.isEnabled = theme != .system
        mode.target = self; mode.action = #selector(changeTheme)
        preset.target = self; preset.action = #selector(changeTheme)
        mode.identifier = NSUserInterfaceItemIdentifier("interfaceMode")
        preset.identifier = NSUserInterfaceItemIdentifier("interfacePreset")
        pane(.interface, [row("Appearance", mode), row("Palette", preset), help("Follow macOS keeps automatic light and dark appearance. Custom Colors changes only the interface, never PDF pages, markup colors, or PDF inversion. Native selection, focus rings, and accessibility contrast remain enabled.")])
    }
    @objc private func changeTheme() {
        preset.isEnabled = mode.indexOfSelectedItem == 1
        InterfaceTheme.select(mode.indexOfSelectedItem == 0 ? .system : InterfaceTheme.presets[preset.indexOfSelectedItem])
        applyTheme()
    }
    @objc private func selectSection(_ sender: NSButton) {
        if let section = Section(rawValue: sender.title) { prepare(section: section) }
    }
    private func applyTheme() {
        let theme = InterfaceTheme.current
        AppAppearance.applyInterface(to: window)
        navigation.refreshBackground()
        for label in primaryLabels { label.textColor = theme.color(for: "foreground") ?? .labelColor }
        for case let button as NSButton in navigation.arrangedSubviews {
            button.bezelColor = theme.color(for: "accent")
        }
    }
}
