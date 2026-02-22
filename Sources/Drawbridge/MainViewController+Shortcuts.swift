import AppKit

enum ShortcutAction: String, CaseIterable {
    case selectTool
    case grabTool
    case penTool
    case arrowTool
    case areaTool
    case lineTool
    case polylineTool
    case highlighterTool
    case cloudTool
    case rectangleTool
    case textTool
    case calloutTool
    case measureTool
    case calibrateTool
    case toggleGrid
    case toggleOrtho

    var displayName: String {
        switch self {
        case .selectTool: return "Select Tool"
        case .grabTool: return "Grab Tool"
        case .penTool: return "Pen Tool"
        case .arrowTool: return "Arrow Tool"
        case .areaTool: return "Area Tool"
        case .lineTool: return "Line Tool"
        case .polylineTool: return "Polyline Tool"
        case .highlighterTool: return "Highlighter Tool"
        case .cloudTool: return "Cloud Tool"
        case .rectangleTool: return "Rectangle Tool"
        case .textTool: return "Text Tool"
        case .calloutTool: return "Callout Tool"
        case .measureTool: return "Measure Tool"
        case .calibrateTool: return "Calibrate Tool"
        case .toggleGrid: return "Toggle Grid"
        case .toggleOrtho: return "Toggle Ortho"
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
        [
            .selectTool: ShortcutBinding(key: "v", requiresShift: false),
            .grabTool: ShortcutBinding(key: "g", requiresShift: false),
            .penTool: ShortcutBinding(key: "d", requiresShift: false),
            .arrowTool: ShortcutBinding(key: "a", requiresShift: false),
            .areaTool: ShortcutBinding(key: "a", requiresShift: true),
            .lineTool: ShortcutBinding(key: "l", requiresShift: false),
            .polylineTool: ShortcutBinding(key: "p", requiresShift: false),
            .highlighterTool: ShortcutBinding(key: "h", requiresShift: false),
            .cloudTool: ShortcutBinding(key: "c", requiresShift: false),
            .rectangleTool: ShortcutBinding(key: "r", requiresShift: false),
            .textTool: ShortcutBinding(key: "t", requiresShift: false),
            .calloutTool: ShortcutBinding(key: "q", requiresShift: false),
            .measureTool: ShortcutBinding(key: "m", requiresShift: false),
            .calibrateTool: ShortcutBinding(key: "k", requiresShift: false),
            .toggleGrid: ShortcutBinding(key: "x", requiresShift: false),
            .toggleOrtho: ShortcutBinding(key: "o", requiresShift: false)
        ]
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
        switch action {
        case .selectTool:
            setTool(.select)
        case .grabTool:
            setTool(.grab)
        case .penTool:
            setTool(.pen)
        case .arrowTool:
            setTool(.arrow)
        case .areaTool:
            setTool(.area)
        case .lineTool:
            setTool(.line)
        case .polylineTool:
            setTool(.polyline)
        case .highlighterTool:
            setTool(.highlighter)
        case .cloudTool:
            setTool(.cloud)
        case .rectangleTool:
            setTool(.rectangle)
        case .textTool:
            setTool(.text)
        case .calloutTool:
            setTool(.callout)
        case .measureTool:
            setTool(.measure)
        case .calibrateTool:
            setTool(.calibrate)
        case .toggleGrid:
            toggleGridVisibilityShortcut()
        case .toggleOrtho:
            setOrthoSnapEnabled(!isOrthoSnapEnabled)
        }
        return true
    }
}
