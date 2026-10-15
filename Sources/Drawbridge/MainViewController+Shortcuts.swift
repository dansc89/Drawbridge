import AppKit

enum ShortcutModifier: String, CaseIterable {
    case plain
    case shift
    case commandShift
    case control

    var requiresShift: Bool {
        switch self {
        case .plain, .control:
            return false
        case .shift, .commandShift:
            return true
        }
    }
}

enum ShortcutAction: String, CaseIterable {
    case selectTool
    case invert

    var toolMode: ToolMode? {
        switch self {
        case .selectTool: return .select
        case .invert: return nil
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .selectTool: return ShortcutBinding(key: "v", modifier: .plain)
        case .invert: return ShortcutBinding(key: "3", modifier: .control)
        }
    }

    var displayName: String {
        switch self {
        case .selectTool: return "Select Text"
        case .invert: return "Invert"
        }
    }

}

struct ShortcutBinding: Equatable {
    var key: String
    var modifier: ShortcutModifier

    var encoded: String {
        "\(modifier.rawValue):\(key)"
    }

    var requiresShift: Bool {
        modifier.requiresShift
    }

    var menuModifiers: NSEvent.ModifierFlags {
        switch modifier {
        case .plain: return []
        case .shift: return [.shift]
        case .commandShift: return [.command, .shift]
        case .control: return [.control]
        }
    }

    static func decode(_ encoded: String) -> ShortcutBinding? {
        let parts = encoded.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let modifier = parts[0]
        let key = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard key.count == 1 else { return nil }
        guard let parsedModifier = ShortcutModifier(rawValue: modifier) else { return nil }
        return ShortcutBinding(key: key, modifier: parsedModifier)
    }
}

@MainActor
extension MainViewController {
    private static let shortcutsDefaultsKey = "DrawbridgeShortcutBindings"

    func defaultShortcutBindings() -> [ShortcutAction: ShortcutBinding] {
        var bindings: [ShortcutAction: ShortcutBinding] = [:]
        for action in ShortcutAction.allCases {
            bindings[action] = action.defaultBinding
        }
        return bindings
    }

    func loadShortcutBindings() {
        let defaults = defaultShortcutBindings()
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.shortcutsDefaultsKey) as? [String: String] else {
            shortcutBindings = defaults
            return
        }
        var loaded = defaults
        for (rawAction, rawBinding) in raw {
            guard let action = ShortcutAction(rawValue: rawAction),
                  let binding = ShortcutBinding.decode(rawBinding) else { continue }
            loaded[action] = binding
        }
        shortcutBindings = loaded
    }

    func saveShortcutBindings() {
        var raw: [String: String] = [:]
        for (action, binding) in shortcutBindings {
            raw[action.rawValue] = binding.encoded
        }
        UserDefaults.standard.set(raw, forKey: Self.shortcutsDefaultsKey)
    }

    func resetShortcutBindingsToDefaults() {
        shortcutBindings = defaultShortcutBindings()
        saveShortcutBindings()
        updateShortcutHintLabel()
    }

    func updateShortcutHintLabel() {
        statusToolsHintLabel.stringValue = "Esc cancels current action. Shortcuts customizable in Drawbridge > Settings… > Keyboard Shortcuts"
        refreshToolbarShortcutTooltips()
        updateInvertMenuShortcut()
    }

    func updateInvertMenuShortcut() {
        func update(_ menu: NSMenu) {
            for item in menu.items {
                if item.action == #selector(commandToggleInvert(_:)), item.target === self {
                    let binding = currentShortcutBinding(for: .invert)
                    item.keyEquivalent = binding.key
                    item.keyEquivalentModifierMask = binding.menuModifiers
                }
                if let submenu = item.submenu { update(submenu) }
            }
        }
        if let menu = NSApp.mainMenu { update(menu) }
    }

    func currentShortcutBinding(for action: ShortcutAction) -> ShortcutBinding {
        shortcutBindings[action] ?? defaultShortcutBindings()[action] ?? action.defaultBinding
    }

    func shortcutDisplayString(for action: ShortcutAction) -> String {
        let binding = currentShortcutBinding(for: action)
        let key = binding.key.uppercased()
        switch binding.modifier {
        case .plain:
            return key
        case .shift:
            return "Shift+\(key)"
        case .commandShift:
            return "Cmd+Shift+\(key)"
        case .control:
            return "Ctrl+\(key)"
        }
    }

    func shortcutAction(for event: NSEvent) -> ShortcutAction? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCommandShift = modifiers == [.command, .shift]
        let isShiftOnly = modifiers == [.shift]
        let isPlain = modifiers.isDisjoint(with: [.command, .option, .control, .shift])
        let modifier: ShortcutModifier
        if modifiers.subtracting(.capsLock) == [.control] {
            modifier = .control
        } else if isCommandShift {
            modifier = .commandShift
        } else if isShiftOnly {
            modifier = .shift
        } else if isPlain {
            modifier = .plain
        } else {
            return nil
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let key = chars.first.map(String.init),
              key.count == 1 else {
            return nil
        }
        for action in ShortcutAction.allCases {
            guard let binding = shortcutBindings[action] else { continue }
            if binding.key == key, binding.modifier == modifier {
                return action
            }
        }
        return nil
    }

    @discardableResult
    func performShortcutAction(_ action: ShortcutAction) -> Bool {
        if action == .invert {
            guard pdfView.document != nil, !isPDFProcessingBusy else { return false }
            commandToggleInvert(nil)
            return true
        }
        if let mode = action.toolMode {
            setTool(mode)
            return true
        }
        return false
    }
}
