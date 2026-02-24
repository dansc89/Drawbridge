import Foundation

enum ToolMode {
    case select
    case grab
    case pen
    case arrow
    case line
    case polyline
    case polygon
    case area
    case highlighter
    case cloud
    case rectangle
    case circle
    case text
    case callout
    case measure
    case calibrate
}

extension ToolMode {
    static let primaryToolbarModes: [ToolMode] = [
        .select, .grab, .pen, .arrow, .line, .polyline, .polygon, .highlighter, .cloud, .rectangle, .circle, .text, .callout
    ]

    static let takeoffToolbarModes: [ToolMode] = [
        .area, .measure
    ]

    static func fromPrimaryToolbarSegment(_ segment: Int) -> ToolMode? {
        guard segment >= 0, segment < primaryToolbarModes.count else { return nil }
        return primaryToolbarModes[segment]
    }

    static func fromTakeoffToolbarSegment(_ segment: Int) -> ToolMode? {
        guard segment >= 0, segment < takeoffToolbarModes.count else { return nil }
        return takeoffToolbarModes[segment]
    }

    var primaryToolbarSegmentIndex: Int? {
        Self.primaryToolbarModes.firstIndex(of: self)
    }

    var takeoffToolbarSegmentIndex: Int? {
        Self.takeoffToolbarModes.firstIndex(of: self)
    }

    var statusDisplayName: String {
        switch self {
        case .select: return "Selection"
        case .grab: return "Grab"
        case .pen: return "Draw"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .polyline: return "Polyline"
        case .polygon: return "Polygon"
        case .area: return "Area"
        case .highlighter: return "Highlighter"
        case .cloud: return "Cloud"
        case .rectangle: return "Rectangle"
        case .circle: return "Ellipse"
        case .text: return "Text"
        case .callout: return "Callout"
        case .measure: return "Measure"
        case .calibrate: return "Calibrate"
        }
    }

    var shortcutDisplayName: String {
        switch self {
        case .pen: return "Pen"
        default: return statusDisplayName
        }
    }

    var symbolCandidates: [String] {
        switch self {
        case .select: return ["cursorarrow"]
        case .grab: return ["camera.viewfinder", "camera"]
        case .pen: return ["pencil.tip", "pencil"]
        case .arrow: return ["arrow.up.right"]
        case .line: return ["line.diagonal"]
        case .polyline: return ["point.3.filled.connected.trianglepath.dotted"]
        case .polygon: return ["polygon", "triangle"]
        case .highlighter: return ["highlighter", "pencil.and.scribble", "scribble"]
        case .cloud: return ["cloud"]
        case .rectangle: return ["square"]
        case .circle: return ["circle"]
        case .text: return ["textformat"]
        case .callout: return ["text.bubble", "text.bubble.fill"]
        case .area: return ["polygon", "square.dashed", "square.on.square"]
        case .measure: return ["ruler"]
        case .calibrate: return []
        }
    }

    var symbolDescription: String {
        switch self {
        case .pen:
            return "Pen"
        case .circle:
            return "Ellipse"
        default:
            return statusDisplayName
        }
    }
}
