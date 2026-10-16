import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class MaterialHatchCatalogTests: XCTestCase {
    func testArchitecturalCatalogHasDistinctOriginalGeometryAndLegacyIDs() throws {
        let presets = DraftingHatch.Preset.allCases
        XCTAssertGreaterThanOrEqual(presets.count, 45, "Architectural material catalog is missing")
        for id in ["solid", "diagonal", "crosshatch", "horizontal", "vertical", "grid", "brick", "concrete", "sand", "earth", "insulation", "wood", "cmu", "plywood", "gypsum", "gravel", "standingSeam", "parquet", "grass"] {
            XCTAssertNotNil(DraftingHatch.Preset(rawValue: id), "Missing material/legacy ID: \(id)")
        }
        var signatures = Set<String>()
        for preset in presets where preset != .solid {
            let style = DraftingHatch(preset: preset)
            let lines = style.lines(size: CGSize(width: 240, height: 240))
            XCTAssertFalse(lines.isEmpty, "\(preset) has no geometry")
            let signature = lines.map { $0.map { String(format: "%.3f,%.3f", $0.x, $0.y) }.joined(separator: ";") }.joined(separator: "|")
            XCTAssertTrue(signatures.insert(signature).inserted, "Duplicate geometric preset: \(preset)")
        }
    }
    func testInspectorPercentageEditsFactorAndRejectsInvalidInput() throws {
        let session = RectangleMarkupController(); session.tool = .rectangle
        session.hatchStyle = DraftingHatch(preset: .brick)
        let inspector = MarkupPropertiesViewController(); inspector.session = session; inspector.refresh()
        let field = inspector.hatchScale
        XCTAssertEqual(field.doubleValue, 100, "100% must mean the existing 1x factor")
        XCTAssertEqual((field.formatter as? NumberFormatter)?.minimum?.doubleValue, 5)
        XCTAssertEqual((field.formatter as? NumberFormatter)?.maximum?.doubleValue, 2000)
        for percent in [5.0, 25, 100, 400, 2000] {
            field.doubleValue = percent; inspector.changeHatch(field)
            XCTAssertEqual(session.hatchStyle?.scale, percent / 100)
            XCTAssertEqual(field.doubleValue, percent)
        }
        for invalid in [Double.nan, .infinity, 0, -1, 4.9, 2001] {
            field.doubleValue = invalid; inspector.changeHatch(field)
            XCTAssertEqual(session.hatchStyle?.scale, 20, "Invalid percentage must not mutate defaults")
        }
        field.stringValue = "not a number"; inspector.changeHatch(field)
        XCTAssertEqual(session.hatchStyle?.scale, 20)
    }
    func testEveryPresetAcceptsSafePercentageRangeAndBoundsGeometryWork() {
        for preset in DraftingHatch.Preset.allCases {
            for scale in [0.05, 0.25, 1, 4, 20] {
                let style = DraftingHatch(preset: preset, scale: scale, angle: 135)
                XCTAssertTrue(style.isValid, "\(preset) \(scale)")
                for size in [CGSize(width: 600, height: 600), CGSize(width: 1e9, height: 1), CGSize(width: 1, height: 1e9)] {
                    let lines = style.lines(size: size)
                    XCTAssertLessThan(lines.count, 70_000)
                    XCTAssertLessThan(lines.reduce(0) { $0 + $1.count }, 1_500_000)
                    XCTAssertTrue(lines.joined().allSatisfy { $0.x.isFinite && $0.y.isFinite })
                }
            }
        }
    }
}
