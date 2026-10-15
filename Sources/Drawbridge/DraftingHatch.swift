import AppKit
import PDFKit

/// Original geometric drafting symbols; no external/proprietary pattern assets.
struct DraftingHatch: Codable, Equatable, Sendable {
    enum Preset: String, Codable, CaseIterable, Sendable {
        case solid, diagonal, crosshatch, horizontal, vertical, grid, brick, concrete, sand, earth, insulation, wood
        var title: String {
            switch self {
            case .solid: "Solid"
            case .diagonal: "Diagonal"
            case .crosshatch: "Crosshatch"
            case .horizontal: "Horizontal"
            case .vertical: "Vertical"
            case .grid: "Grid"
            case .brick: "Brick"
            case .concrete: "Concrete"
            case .sand: "Sand"
            case .earth: "Earth"
            case .insulation: "Insulation"
            case .wood: "Wood"
            }
        }
    }
    static let key = PDFAnnotationKey(rawValue: "DrawbridgeHatchStyle")
    var preset: Preset = .solid
    var foreground: [Double] = [0, 0, 0]
    var background: [Double]? = nil
    var scale: Double = 1
    var angle: Double = 0
    var lineWidth: Double = 0.5
    var isValid: Bool {
        func color(_ c: [Double]) -> Bool { c.count == 3 && c.allSatisfy { $0.isFinite && (0...1).contains($0) } }
        return color(foreground) && (background.map(color) ?? true) && scale.isFinite && (0.25...20).contains(scale) && angle.isFinite && (-360...360).contains(angle) && lineWidth.isFinite && (0.1...12).contains(lineWidth)
    }
    var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(data: try! encoder.encode(self), encoding: .utf8)!
    }
    static func read(_ annotation: PDFAnnotation) -> Self? {
        guard let json = annotation.value(forAnnotationKey: key) as? String, json.utf8.count < 2048,
              let data = json.data(using: .utf8), let style = try? JSONDecoder().decode(Self.self, from: data), style.isValid else { return nil }
        return style
    }
    static func apply(_ style: Self?, to annotation: PDFAnnotation) {
        if let style, style.isValid { annotation.setValue(style.json, forAnnotationKey: key) }
        else { annotation.removeValue(forAnnotationKey: key) }
    }

    /// Shape-local polylines, identically consumed by live and portable PDF rendering.
    /// Density is bounded even on pathological imported page sizes.
    func lines(size: CGSize) -> [[CGPoint]] {
        // Reject unrenderable imported dimensions before derived arithmetic or Int conversion.
        // A billion points is already far beyond a practical PDF page; the finite cap
        // also keeps rotated coordinates and serialized appearance operands finite.
        guard isValid, preset != .solid,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width <= 1e9, size.height <= 1e9 else { return [] }
        let radius = hypot(size.width / 2, size.height / 2)
        let step = max(12 * scale, radius / 60)
        let count = Int(min(61, ceil(radius / step))) + 1
        let radians = angle * .pi / 180
        let cosine = cos(radians), sine = sin(radians)
        var result = [[CGPoint]]()
        func add(_ points: [(Double, Double)], _ x: Double = 0, _ y: Double = 0) {
            result.append(points.map { p in
                let u = (p.0 + x) * step, v = (p.1 + y) * step
                return CGPoint(x: size.width / 2 + u * cosine - v * sine, y: size.height / 2 + u * sine + v * cosine)
            })
        }
        let n = Double(count)
        // Unit direction/normal vectors give diagonal rows the same bounded
        // circular coverage as axis-aligned families, including after rotation.
        // Using y-x as the row offset without normalization lost corner bands.
        let diagonal = sqrt(0.5)
        for row in -count...count {
            let y = Double(row)
            switch preset {
            case .horizontal, .grid: add([(-n,y),(n,y)])
            case .vertical: add([(y,-n),(y,n)])
            case .diagonal, .crosshatch:
                add([((-n-y)*diagonal,(-n+y)*diagonal),((n-y)*diagonal,(n+y)*diagonal)])
            default: break
            }
            if preset == .grid { add([(y,-n),(y,n)]) }
            if preset == .crosshatch {
                add([((-n+y)*diagonal,(n+y)*diagonal),((n+y)*diagonal,(-n+y)*diagonal)])
            }
            if [.solid, .horizontal, .vertical, .grid, .diagonal, .crosshatch].contains(preset) { continue }
            for column in -count...count {
                let x = Double(column)
                switch preset {
                case .brick:
                    add([(0,0),(1,0)], x,y)
                    let offset = row.isMultiple(of: 2) ? 0.0 : 0.5
                    add([(offset,0),(offset,1)], x,y)
                case .concrete:
                    add([(0.12,0.15),(0.38,0.22),(0.22,0.47),(0.12,0.15)], x,y)
                    add([(0.65,0.65),(0.83,0.55),(0.9,0.87),(0.65,0.65)], x,y)
                    add([(0.55,0.15),(0.58,0.18)], x,y)
                case .sand:
                    for p in [(0.15,0.2),(0.7,0.4),(0.35,0.8)] { add([(p.0,p.1),(p.0+0.045,p.1+0.025)],x,y) }
                case .earth:
                    add([(0.1,0.1),(0.45,0.45)],x,y); add([(0.25,0.05),(0.6,0.4)],x,y)
                    add([(0.55,0.85),(0.9,0.5)],x,y); add([(0.7,0.9),(0.98,0.62)],x,y)
                case .insulation:
                    add((0...16).map { i in let t = Double(i) / 16; return (t, 0.5 + 0.4 * sin(t * 2 * .pi)) },x,y)
                case .wood:
                    add((0...12).map { i in let t = Double(i) / 12; return (t,0.25 + 0.10 * sin(t * 2 * .pi)) },x,y)
                    add((0...12).map { i in let t = Double(i) / 12; return (t,0.75 + 0.08 * sin(t * 2 * .pi + 1)) },x,y)
                    if row.isMultiple(of: 3) && column.isMultiple(of: 3) {
                        add((0...16).map { i in let t = Double(i) / 16 * 2 * .pi; return (0.5 + 0.3 * cos(t),0.5 + 0.1 * sin(t)) },x,y)
                    }
                default: break
                }
            }
        }
        return result
    }
    func draw(path: CGPath, bounds: CGRect, opacity: Double, in context: CGContext) {
        guard preset != .solid, isValid else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.addPath(path); context.clip()
        context.setAlpha(opacity)
        if let background { context.setFillColor(Self.color(background).cgColor); context.fill(bounds) }
        context.setStrokeColor(Self.color(foreground).cgColor)
        context.setLineWidth(lineWidth); context.setLineDash(phase: 0, lengths: []); context.setLineCap(.round)
        for line in lines(size: bounds.size) {
            context.beginPath()
            for (i,p) in line.enumerated() {
                let point = CGPoint(x: p.x + bounds.minX, y: p.y + bounds.minY)
                if i == 0 { context.move(to: point) } else { context.addLine(to: point) }
            }
            context.strokePath()
        }
    }
    static func color(_ values: [Double]) -> NSColor { NSColor(deviceRed: values[0], green: values[1], blue: values[2], alpha: 1) }
    func pdf(path: String, size: CGSize) -> String {
        var output = "q /HatchGS gs \(path) W n [] 0 d \(lineWidth) w 1 J\n"
        if let background { output += "\(background[0]) \(background[1]) \(background[2]) rg 0 0 \(size.width) \(size.height) re f\n" }
        output += "\(foreground[0]) \(foreground[1]) \(foreground[2]) RG\n"
        for line in lines(size: size) {
            output += line.enumerated().map { "\($0.element.x) \($0.element.y) \($0.offset == 0 ? "m" : "l")" }.joined(separator: " ") + " S\n"
        }
        return output + "Q\n"
    }
}
