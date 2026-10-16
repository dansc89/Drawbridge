import AppKit
import XCTest
@testable import Drawbridge

@MainActor final class MaterialHatchLegibilityTests: XCTestCase {
    func testSmallScaleMaterialVoidsRemainVisibleAtNormalAndHighResolution() throws {
        for preset in [DraftingHatch.Preset.hollowBlock, .endGrain, .plywood, .standingSeam] {
            for density in [1, 3] {
                let size = 108
                let c = try XCTUnwrap(CGContext(data: nil, width: size*density, height: size*density,
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                c.scaleBy(x: CGFloat(density), y: CGFloat(density))
                c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(x: 0, y: 0, width: size, height: size))
                let bounds = CGRect(x: 0, y: 0, width: size, height: size)
                DraftingHatch(preset: preset, foreground: [0,0,1], scale: 0.25, lineWidth: 0.5)
                    .draw(path: CGPath(rect: bounds, transform: nil), bounds: bounds, opacity: 1, in: c)
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(c.makeImage()))
                var clear = 0
                for y in 3*density..<105*density { for x in 3*density..<105*density {
                    let p = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if p.redComponent > 0.7 && p.greenComponent > 0.7 { clear += 1 }
                } }
                print("VOID EVIDENCE \(preset) density=\(density) clear=\(clear)")
                XCTAssertGreaterThan(clear, 102*102*density*density/5, "Material must have usable open area: \(preset) at \(density)x")
            }
        }
    }
}
