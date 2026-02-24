import AppKit

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
        case .selectTool: return ShortcutBinding(key: "v", requiresShift: false)
        case .grabTool: return ShortcutBinding(key: "g", requiresShift: false)
        case .penTool: return ShortcutBinding(key: "d", requiresShift: false)
        case .arrowTool: return ShortcutBinding(key: "a", requiresShift: false)
        case .areaTool: return ShortcutBinding(key: "a", requiresShift: true)
        case .lineTool: return ShortcutBinding(key: "l", requiresShift: false)
        case .polylineTool: return ShortcutBinding(key: "p", requiresShift: false)
        case .polygonTool: return ShortcutBinding(key: "p", requiresShift: true)
        case .highlighterTool: return ShortcutBinding(key: "h", requiresShift: false)
        case .cloudTool: return ShortcutBinding(key: "c", requiresShift: false)
        case .rectangleTool: return ShortcutBinding(key: "r", requiresShift: false)
        case .ellipseTool: return ShortcutBinding(key: "e", requiresShift: false)
        case .textTool: return ShortcutBinding(key: "t", requiresShift: false)
        case .calloutTool: return ShortcutBinding(key: "q", requiresShift: false)
        case .measureTool: return ShortcutBinding(key: "m", requiresShift: false)
        case .calibrateTool: return ShortcutBinding(key: "k", requiresShift: false)
        case .toggleGrid: return ShortcutBinding(key: "x", requiresShift: false)
        case .toggleOrtho: return ShortcutBinding(key: "o", requiresShift: false)
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
    var requiresShift: Bool

    var encoded: String {
        "\(requiresShift ? "shift" : "plain"):\(key)"
    }

    static func decode(_ encoded: String) -> ShortcutBinding? {
        let parts = encoded.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let modifier = parts[0]
        let key = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard key.count == 1 else { return nil }
        switch modifier {
        case "plain":
            return ShortcutBinding(key: key, requiresShift: false)
        case "shift":
            return ShortcutBinding(key: key, requiresShift: true)
        default:
            return nil
        }
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
        statusToolsHintLabel.stringValue = "Shortcuts customizable in Drawbridge > Keyboard Shortcuts…"
    }

    func shortcutAction(for event: NSEvent) -> ShortcutAction? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .option, .control]),
              let chars = event.charactersIgnoringModifiers?.lowercased(),
              let key = chars.first.map(String.init),
              key.count == 1 else {
            return nil
        }
        let requiresShift = modifiers.contains(.shift)
        for action in ShortcutAction.allCases {
            guard let binding = shortcutBindings[action] else { continue }
            if binding.key == key, binding.requiresShift == requiresShift {
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
