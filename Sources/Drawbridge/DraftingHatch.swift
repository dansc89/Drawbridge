import AppKit
import PDFKit

/// Original geometric drafting symbols; no external/proprietary pattern assets.
struct DraftingHatch: Codable, Equatable, Sendable {
    enum Preset: String, Codable, CaseIterable, Sendable {
        // Existing raw IDs and factor-based serialization are deliberately stable.
        case solid, diagonal, crosshatch, horizontal, vertical, grid, brick, concrete, sand, earth, insulation, wood
        case brickStack, flemishBond, englishBond, cmu, hollowBlock, ashlar, rubble, cutStone
        case reinforcedConcrete, lightweightConcrete, precast, steel, aluminum, expandedMetal, corrugatedMetal
        case plywood, endGrain, lumber, rigidInsulation, foam, gypsum, plaster
        case compactedEarth, gravel, rock, clay, asphalt, shingles, standingSeam, roofTile
        case ceramicTile, terrazzo, parquet, herringbone, pavers, checkerTile, grass, planting
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
            case .brickStack: "Stack Bond Brick"
            case .flemishBond: "Flemish Bond Brick"
            case .englishBond: "English Bond Brick"
            case .cmu: "CMU Running Bond"
            case .hollowBlock: "Hollow Concrete Block"
            case .ashlar: "Ashlar Stone"
            case .rubble: "Rubble Stone"
            case .cutStone: "Cut Stone"
            case .reinforcedConcrete: "Reinforced Concrete"
            case .lightweightConcrete: "Lightweight Concrete"
            case .precast: "Precast Concrete"
            case .steel: "Steel Section"
            case .aluminum: "Aluminum Section"
            case .expandedMetal: "Expanded Metal"
            case .corrugatedMetal: "Corrugated Metal"
            case .plywood: "Plywood"
            case .endGrain: "Wood End Grain"
            case .lumber: "Sawn Lumber"
            case .rigidInsulation: "Rigid Insulation"
            case .foam: "Cellular Foam"
            case .gypsum: "Gypsum Board"
            case .plaster: "Plaster"
            case .compactedEarth: "Compacted Earth"
            case .gravel: "Gravel"
            case .rock: "Bedrock"
            case .clay: "Clay"
            case .asphalt: "Asphalt"
            case .shingles: "Roof Shingles"
            case .standingSeam: "Standing Seam Roofing"
            case .roofTile: "Clay Roof Tile"
            case .ceramicTile: "Ceramic Tile"
            case .terrazzo: "Terrazzo"
            case .parquet: "Parquet Flooring"
            case .herringbone: "Herringbone Flooring"
            case .pavers: "Interlocking Pavers"
            case .checkerTile: "Checker Tile"
            case .grass: "Grass"
            case .planting: "Planting / Foliage"
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
        return color(foreground) && (background.map(color) ?? true) && scale.isFinite && (0.05...20).contains(scale) && angle.isFinite && (-360...360).contains(angle) && lineWidth.isFinite && (0.1...12).contains(lineWidth)
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
        // A material cell contains several independent features (for example two
        // block cavities), unlike a single grid interval. Giving both a 12pt cell
        // made the 25% block's 0.14-cell webs only 0.42pt wide: smaller than the
        // independent 0.5pt pen, so adjoining strokes physically consumed them.
        // Material symbols use a 48pt nominal repeat; scale still multiplies the
        // repeat exactly, and changing the pen never changes pattern geometry.
        let nominalRepeat: Double
        switch preset {
        case .solid, .diagonal, .crosshatch, .horizontal, .vertical, .grid,
             .brick, .concrete, .sand, .earth, .insulation, .wood:
            nominalRepeat = 12 // Preserve established legacy pattern geometry.
        default:
            nominalRepeat = 48
        }
        // Rubble emits five paths per cell. Reserve room for the surrounding
        // cells and a possible upward floating-point ceil: at most 117² * 5
        // paths, below the existing 70,000-path work budget. Other presets keep
        // their established cap; ordinary-size repeats remain unchanged.
        let cellRadius: Double = preset == .rubble ? 56 : 60
        let step = max(nominalRepeat * scale, radius / cellRadius)
        let count = Int(min(cellRadius + 1, ceil(radius / step))) + 1
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
                default:
                    for motif in materialTile(row: row, column: column) { add(motif, x, y) }
                }
            }
        }
        return result
    }

    /// Unit-cell symbols. Open cell boundaries intentionally meet adjacent cells;
    /// isolated aggregate/grain marks are closed, with no random rendering state.
    private func materialTile(row: Int, column: Int) -> [[(Double, Double)]] {
        func ring(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double) -> [(Double, Double)] {
            (0...16).map { i in
                let t = Double(i) * .pi / 8
                return (x + rx * cos(t), y + ry * sin(t))
            }
        }
        let offset = row.isMultiple(of: 2) ? 0.0 : 0.5
        switch preset {
        case .brickStack:
            return [[(0,0),(1,0)], [(0,0),(0,1)]]
        case .flemishBond:
            return [[(0,0),(1,0)], [(offset,0),(offset,1)], [(offset+0.3,0),(offset+0.3,1)]]
        case .englishBond:
            // Half-width headers bridge the joints of the full-width stretchers.
            return row.isMultiple(of: 2)
                ? [[(0,0),(1,0)], [(0.25,0),(0.25,1)], [(0.75,0),(0.75,1)]]
                : [[(0,0),(1,0)], [(0,0),(0,1)]]
        case .cmu:
            return [[(0,0),(1,0)], [(offset,0),(offset,1)], [(0,0.08),(1,0.08)]]
        case .hollowBlock:
            return [[(0,0),(1,0),(1,1),(0,1),(0,0)], [(0.12,0.18),(0.43,0.18),(0.43,0.82),(0.12,0.82),(0.12,0.18)], [(0.57,0.18),(0.88,0.18),(0.88,0.82),(0.57,0.82),(0.57,0.18)]]
        case .ashlar:
            return [[(0,0),(1,0)], [(offset,0),(offset,0.6),(offset+0.5,0.6),(offset+0.5,1)], [(offset+0.5,0.6),(offset+1,0.6)]]
        case .rubble:
            return [[(0,0.2),(0.3,0),(0.65,0.25),(0.55,0.6),(0.15,0.65),(0,0.2)], [(0.65,0.25),(1,0.2)], [(0.55,0.6),(0.3,1)], [(0.55,0.6),(1,0.8)], [(0.15,0.65),(0,0.8)]]
        case .cutStone:
            return [[(0,0),(1,0)], [(offset,0),(offset,1)], [(offset+0.12,0.2),(offset+0.35,0.32),(offset+0.3,0.7)]]
        case .reinforcedConcrete:
            return [[(0,0.15),(1,0.15)], [(0.15,0),(0.15,1)], ring(0.15,0.15,0.09,0.09), [(0.45,0.4),(0.8,0.5),(0.6,0.8),(0.45,0.4)]]
        case .lightweightConcrete:
            return [ring(0.25,0.25,0.13,0.13), ring(0.7,0.65,0.22,0.17), [(0.15,0.8),(0.18,0.84)]]
        case .precast:
            return [[(0,0),(1,0),(1,1)], [(0.07,0.07),(0.93,0.07),(0.93,0.93)], [(0.3,0.4),(0.5,0.3),(0.6,0.6),(0.3,0.4)]]
        case .steel:
            return [[(0,0),(1,1)], [(0.12,0),(1.12,1)]]
        case .aluminum:
            return [[(0,0),(1,1)], [(0.15,0),(0.45,0.3)], [(0.65,0.5),(0.95,0.8)]]
        case .expandedMetal:
            return [[(0,0.5),(0.5,0),(1,0.5),(0.5,1),(0,0.5)], [(0,0.4),(0.5,-0.1),(1,0.4)]]
        case .corrugatedMetal:
            return [[(0,0.2),(0.2,0.2),(0.3,0.8),(0.7,0.8),(0.8,0.2),(1,0.2)]]
        case .plywood:
            return [[(0,0),(1,0)], [(0,0.33),(1,0.33)], [(0,0.66),(1,0.66)], [(0.2,0.38),(0.4,0.6),(0.6,0.38),(0.8,0.6)]]
        case .endGrain:
            return [ring(0.5,0.5,0.15,0.12), ring(0.5,0.5,0.3,0.26), ring(0.5,0.5,0.46,0.42)]
        case .lumber:
            return [[(0,0),(1,0)], [(0,0.15),(1,0.15)], [(0.1,0.5),(0.35,0.4),(0.7,0.55),(0.9,0.5)], [(0.1,0.75),(0.6,0.68),(0.9,0.8)]]
        case .rigidInsulation:
            return [[(0,0),(1,0)], [(0,0),(0.5,1),(1,0)], [(0,1),(1,1)]]
        case .foam:
            return [ring(0.25,0.3,0.22,0.26), ring(0.75,0.8,0.22,0.26), ring(0.8,0.2,0.1,0.1)]
        case .gypsum:
            return [[(0,0),(1,0)], [(0,0.12),(1,0.12)], [(0.2,0.5),(0.24,0.5)], [(0.7,0.8),(0.74,0.8)]]
        case .plaster:
            return [[(0,0),(1,0)], [(0.1,0.3),(0.35,0.4),(0.6,0.28)], [(0.45,0.75),(0.7,0.85),(0.95,0.73)]]
        case .compactedEarth:
            return [[(0,0),(1,0)], [(0.1,0.3),(0.4,0.3)], [(0.6,0.6),(0.9,0.6)], [(0.2,0.85),(0.5,0.85)]]
        case .gravel:
            return [[(0.05,0.2),(0.25,0.08),(0.4,0.3),(0.2,0.45),(0.05,0.2)], [(0.55,0.55),(0.85,0.5),(0.95,0.8),(0.7,0.95),(0.55,0.55)], [(0.65,0.1),(0.8,0.2),(0.7,0.35),(0.65,0.1)]]
        case .rock:
            return [[(0,0.2),(0.4,0.5),(0.35,1)], [(0.4,0.5),(0.8,0.35),(1,0.2)], [(0.8,0.35),(0.35,0)]]
        case .clay:
            return [[(0.05,0.2),(0.45,0.2)], [(0.55,0.45),(0.95,0.45)], [(0.05,0.7),(0.45,0.7)], [(0.6,0.85),(0.7,0.85)]]
        case .asphalt:
            return [[(0.1,0.2),(0.3,0.25)], [(0.6,0.15),(0.75,0.3)], [(0.2,0.65),(0.4,0.8)], [(0.65,0.7),(0.9,0.65)]]
        case .shingles:
            return [[(0,0),(1,0)], [(offset,0),(offset,0.8)], [(0,0.8),(1,0.8)]]
        case .standingSeam:
            return [[(0,0),(0,1)], [(0.12,0),(0.12,1)], [(0.18,0),(0.18,1)]]
        case .roofTile:
            return [[(0,0),(1,0)], (0...16).map { i in let t = Double(i)/16; return (t,0.2 + 0.6 * sin(t * .pi)) }]
        case .ceramicTile:
            return [[(0.06,0.06),(0.94,0.06),(0.94,0.94),(0.06,0.94),(0.06,0.06)]]
        case .terrazzo:
            return [[(0.1,0.1),(0.3,0.15),(0.2,0.4),(0.1,0.1)], [(0.6,0.2),(0.8,0.1),(0.9,0.35),(0.6,0.2)], [(0.25,0.75),(0.45,0.6),(0.7,0.85),(0.25,0.75)], [(0.85,0.65),(0.9,0.7)]]
        case .parquet:
            if (row + column).isMultiple(of: 2) {
                return [[(0,0),(1,0),(1,1),(0,1),(0,0)], [(0,0.33),(1,0.33)], [(0,0.66),(1,0.66)]]
            }
            return [[(0,0),(1,0),(1,1),(0,1),(0,0)], [(0.33,0),(0.33,1)], [(0.66,0),(0.66,1)]]
        case .herringbone:
            // Domino tiling on a half-unit lattice. Origins with x+y == 0
            // (mod 4) start horizontal planks; == 2 start vertical planks.
            // Every microcell belongs to exactly one 2:1 rectangular plank,
            // with alternating end-to-side joints rather than zigzag chevrons.
            var planks = [[(Double, Double)]]()
            for j in 0...1 { for i in 0...1 {
                let phase = ((2 * column + i + 2 * row + j) % 4 + 4) % 4
                let x = Double(i) / 2, y = Double(j) / 2
                if phase == 0 { planks.append([(x,y),(x+1,y),(x+1,y+0.5),(x,y+0.5),(x,y)]) }
                if phase == 2 { planks.append([(x,y),(x+0.5,y),(x+0.5,y+1),(x,y+1),(x,y)]) }
            } }
            return planks
        case .pavers:
            return [[(0.2,0),(0.8,0),(0.8,0.2),(1,0.2),(1,0.8),(0.8,0.8),(0.8,1),(0.2,1),(0.2,0.8),(0,0.8),(0,0.2),(0.2,0.2),(0.2,0)]]
        case .checkerTile:
            return [[(0,0),(1,0),(1,1),(0,1),(0,0)]] + ((row + column).isMultiple(of: 2) ? [[(0,0),(1,1)], [(0,1),(1,0)]] : [])
        case .grass:
            return [[(0.1,0.15),(0.3,0.5),(0.35,0.1),(0.55,0.4)], [(0.6,0.65),(0.8,1),(0.85,0.6),(1.05,0.9)]]
        case .planting:
            return [[(0.5,0.1),(0.5,0.9)], [(0.5,0.4),(0.15,0.65),(0.2,0.3),(0.5,0.4)], [(0.5,0.65),(0.85,0.9),(0.8,0.55),(0.5,0.65)]]
        default: return [] // Legacy and line-family presets are emitted above.
        }
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
    // PDF numbers cannot use exponent notation. Quarter-turn geometry creates
    // near-zero values; Swift's default exponent form breaks PDFKit boundary paths.
    private static func pdfNumber(_ value: Double) -> String {
        let text = String(value)
        guard text.contains("e") || text.contains("E") else { return text }
        return String(format: "%.12f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    func pdf(path: String, size: CGSize) -> String {
        var output = "q /HatchGS gs \(path) W n [] 0 d \(Self.pdfNumber(lineWidth)) w 1 J\n"
        if let background { output += "\(Self.pdfNumber(background[0])) \(Self.pdfNumber(background[1])) \(Self.pdfNumber(background[2])) rg 0 0 \(Self.pdfNumber(Double(size.width))) \(Self.pdfNumber(Double(size.height))) re f\n" }
        output += "\(Self.pdfNumber(foreground[0])) \(Self.pdfNumber(foreground[1])) \(Self.pdfNumber(foreground[2])) RG\n"
        for line in lines(size: size) {
            output += line.enumerated().map { "\(Self.pdfNumber(Double($0.element.x))) \(Self.pdfNumber(Double($0.element.y))) \($0.offset == 0 ? "m" : "l")" }.joined(separator: " ") + " S\n"
        }
        return output + "Q\n"
    }
}
