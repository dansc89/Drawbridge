import AppKit

enum ShortcutModifier: String, CaseIterable {
    case plain
    case shift
    case commandShift

    var requiresShift: Bool {
        switch self {
        case .plain:
            return false
        case .shift, .commandShift:
            return true
        }
    }
}

enum ShortcutAction: String, CaseIterable {
    case selectTool
    case grabTool
    case penTool
    case arrowTool
    case areaTool
    case lineTool
    case polylineTool
    case polygonTool
    case highlighterTool
    case cloudTool
    case rectangleTool
    case ellipseTool
    case textTool
    case calloutTool
    case measureTool
    case calibrateTool
    case toggleGrid
    case toggleOrtho

    var toolMode: ToolMode? {
        switch self {
        case .selectTool: return .select
        case .grabTool: return .grab
        case .penTool: return .pen
        case .arrowTool: return .arrow
        case .areaTool: return .area
        case .lineTool: return .line
        case .polylineTool: return .polyline
        case .polygonTool: return .polygon
        case .highlighterTool: return .highlighter
        case .cloudTool: return .cloud
        case .rectangleTool: return .rectangle
        case .ellipseTool: return .circle
        case .textTool: return .text
        case .calloutTool: return .callout
        case .measureTool: return .measure
        case .calibrateTool: return .calibrate
        case .toggleGrid, .toggleOrtho: return nil
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .selectTool: return ShortcutBinding(key: "v", modifier: .plain)
        case .grabTool: return ShortcutBinding(key: "g", modifier: .plain)
        case .penTool: return ShortcutBinding(key: "d", modifier: .plain)
        case .arrowTool: return ShortcutBinding(key: "a", modifier: .plain)
        case .areaTool: return ShortcutBinding(key: "a", modifier: .shift)
        case .lineTool: return ShortcutBinding(key: "l", modifier: .plain)
        case .polylineTool: return ShortcutBinding(key: "p", modifier: .plain)
        case .polygonTool: return ShortcutBinding(key: "p", modifier: .commandShift)
        case .highlighterTool: return ShortcutBinding(key: "h", modifier: .plain)
        case .cloudTool: return ShortcutBinding(key: "c", modifier: .plain)
        case .rectangleTool: return ShortcutBinding(key: "r", modifier: .plain)
        case .ellipseTool: return ShortcutBinding(key: "e", modifier: .plain)
        case .textTool: return ShortcutBinding(key: "t", modifier: .plain)
        case .calloutTool: return ShortcutBinding(key: "q", modifier: .plain)
        case .measureTool: return ShortcutBinding(key: "m", modifier: .plain)
        case .calibrateTool: return ShortcutBinding(key: "k", modifier: .plain)
        case .toggleGrid: return ShortcutBinding(key: "x", modifier: .plain)
        case .toggleOrtho: return ShortcutBinding(key: "o", modifier: .plain)
        }
    }

    var displayName: String {
        if let mode = toolMode {
            return "\(mode.shortcutDisplayName) Tool"
        }
        switch self {
        case .toggleGrid: return "Toggle Grid"
        case .toggleOrtho: return "Toggle Ortho"
        default: return "Shortcut"
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
        // Migrate legacy Shift+P binding to Cmd+Shift+P.
        if loaded[.polygonTool] == ShortcutBinding(key: "p", modifier: .shift) {
            loaded[.polygonTool] = ShortcutBinding(key: "p", modifier: .commandShift)
        }
        // Keep Cmd+Shift+A reserved for sheet-name/bookmark auto-generation.
        if loaded[.areaTool] == ShortcutBinding(key: "a", modifier: .commandShift) {
            loaded[.areaTool] = ShortcutBinding(key: "a", modifier: .shift)
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
        statusToolsHintLabel.stringValue = "Shortcuts customizable in Drawbridge > Keyboard Shortcuts…"
    }

    func shortcutAction(for event: NSEvent) -> ShortcutAction? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCommandShift = modifiers == [.command, .shift]
        let isShiftOnly = modifiers == [.shift]
        let isPlain = modifiers.isDisjoint(with: [.command, .option, .control, .shift])
        let modifier: ShortcutModifier
        if isCommandShift {
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
        if let mode = action.toolMode {
            setTool(mode)
            return true
        }
        switch action {
        case .toggleGrid:
            toggleGridVisibilityShortcut()
        case .toggleOrtho:
            setOrthoSnapEnabled(!isOrthoSnapEnabled)
        default:
            return false
        }
        return true
    }
}
