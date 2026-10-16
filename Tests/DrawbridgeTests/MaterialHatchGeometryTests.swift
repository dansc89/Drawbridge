import XCTest
@testable import Drawbridge

final class MaterialHatchGeometryTests: XCTestCase {
    let size = CGSize(width: 384, height: 384)
    func normalized(_ preset: DraftingHatch.Preset) -> [[CGPoint]] {
        DraftingHatch(preset: preset).lines(size: size).map { line in
            line.map { CGPoint(x: ($0.x - 192) / 48, y: ($0.y - 192) / 48) }
        }
    }
    func testHerringboneIsGaplessPerpendicularTwoToOnePlanks() {
        let lines = normalized(.herringbone)
        XCTAssertTrue(lines.allSatisfy { $0.count == 5 && $0.first == $0.last }, "Every plank must be a closed rectangle")
        guard lines.allSatisfy({ $0.count == 5 }) else { return }
        var horizontal = 0, vertical = 0
        for p in lines {
            let a = CGVector(dx: p[1].x-p[0].x, dy: p[1].y-p[0].y)
            let b = CGVector(dx: p[2].x-p[1].x, dy: p[2].y-p[1].y)
            XCTAssertEqual(a.dx*b.dx+a.dy*b.dy, 0, accuracy: 1e-8)
            let lengths = [hypot(a.dx,a.dy),hypot(b.dx,b.dy)].sorted()
            XCTAssertEqual(lengths[1], lengths[0]*2, accuracy: 1e-8)
            // Orientation is the long axis, not the first edge (both polygon
            // windings deliberately start with their horizontal edge).
            if abs(a.dx) > abs(b.dy) { horizontal += 1 } else { vertical += 1 }
        }
        XCTAssertGreaterThan(horizontal, 0); XCTAssertGreaterThan(vertical, 0)
        // Sample each half-unit microcell off all seams: exactly one plank covers it.
        for y in -8..<8 { for x in -8..<8 {
            let point = CGPoint(x: Double(x)*0.5+0.17, y: Double(y)*0.5+0.19)
            let count = lines.filter { p in
                let path = CGMutablePath(); path.addLines(between: p); path.closeSubpath(); return path.contains(point)
            }.count
            XCTAssertEqual(count, 1, "Gap/overlap at \(point)")
        } }
    }
    func testEnglishBondHeadersBridgeStretcherJoints() {
        let lines = normalized(.englishBond)
        func joints(_ row: Double) -> [Double] {
            lines.filter { $0.count == 2 && abs($0[0].x-$0[1].x)<1e-8 && abs($0[0].y-row)<1e-8 && abs($0[1].y-row-1)<1e-8 }.map { $0[0].x }.filter { $0 >= -2 && $0 < 2 }.sorted()
        }
        let headers = joints(0), stretchers = joints(1)
        XCTAssertEqual(headers.count, 8); XCTAssertEqual(stretchers.count, 4)
        for x in stretchers { XCTAssertFalse(headers.contains { abs($0-x)<1e-8 }, "Unbonded continuous head joint at \(x)") }
    }
    func testRockAndRubbleNetworkEndpointsConnectAcrossRepeats() {
        for preset in [DraftingHatch.Preset.rock, .rubble] {
            let lines = normalized(preset)
            let segments = lines.flatMap { p in zip(p,p.dropFirst()).map { ($0.0,$0.1) } }
            func connected(_ p: CGPoint) -> Bool {
                segments.filter { a,b in
                    let dx=b.x-a.x, dy=b.y-a.y
                    let cross=(p.x-a.x)*dy-(p.y-a.y)*dx
                    return abs(cross)<1e-7 && p.x>=min(a.x,b.x)-1e-8 && p.x<=max(a.x,b.x)+1e-8 && p.y>=min(a.y,b.y)-1e-8 && p.y<=max(a.y,b.y)+1e-8
                }.count >= 2
            }
            for line in lines { for p in [line.first!,line.last!] where abs(p.x)<2 && abs(p.y)<2 {
                XCTAssertTrue(connected(p), "Dangling \(preset) seam at \(p)")
            } }
        }
    }
}
