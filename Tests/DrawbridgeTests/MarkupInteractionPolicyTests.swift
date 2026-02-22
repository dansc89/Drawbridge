import AppKit
import XCTest
@testable import Drawbridge

final class MarkupInteractionPolicyTests: XCTestCase {
    func testGroupedDragAllowedOnlyForPasteGroupOnSamePage() {
        let selected: Set<String> = ["a", "b"]
        let grouped: Set<String> = ["a", "b", "c"]
        let allowed = MarkupInteractionPolicy.shouldDragGroupedPasteSelection(
            selectedAnnotationIDs: selected,
            anchorAnnotationID: "a",
            currentPageID: "page-1",
            groupedPastePageID: "page-1",
            groupedPasteAnnotationIDs: grouped
        )
        XCTAssertTrue(allowed)
    }

    func testGroupedDragDeniedForSingleSelection() {
        let allowed = MarkupInteractionPolicy.shouldDragGroupedPasteSelection(
            selectedAnnotationIDs: ["a"],
            anchorAnnotationID: "a",
            currentPageID: "page-1",
            groupedPastePageID: "page-1",
            groupedPasteAnnotationIDs: ["a", "b"]
        )
        XCTAssertFalse(allowed)
    }

    func testGroupedDragDeniedForDifferentPage() {
        let allowed = MarkupInteractionPolicy.shouldDragGroupedPasteSelection(
            selectedAnnotationIDs: ["a", "b"],
            anchorAnnotationID: "a",
            currentPageID: "page-2",
            groupedPastePageID: "page-1",
            groupedPasteAnnotationIDs: ["a", "b"]
        )
        XCTAssertFalse(allowed)
    }

    func testGroupedDragDeniedWhenAnchorOutsideGroupedSet() {
        let allowed = MarkupInteractionPolicy.shouldDragGroupedPasteSelection(
            selectedAnnotationIDs: ["a", "b"],
            anchorAnnotationID: "z",
            currentPageID: "page-1",
            groupedPastePageID: "page-1",
            groupedPasteAnnotationIDs: ["a", "b", "c"]
        )
        XCTAssertFalse(allowed)
    }

    func testGroupedDragDeniedWhenSelectionNotSubsetOfGroupedSet() {
        let allowed = MarkupInteractionPolicy.shouldDragGroupedPasteSelection(
            selectedAnnotationIDs: ["a", "x"],
            anchorAnnotationID: "a",
            currentPageID: "page-1",
            groupedPastePageID: "page-1",
            groupedPasteAnnotationIDs: ["a", "b", "c"]
        )
        XCTAssertFalse(allowed)
    }
}

final class EscapePressTrackerTests: XCTestCase {
    func testSecondPressInsideThresholdTriggersDoubleEscape() {
        var tracker = EscapePressTracker(doublePressInterval: 0.65)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(tracker.registerPress(at: t0))
        XCTAssertTrue(tracker.registerPress(at: t0.addingTimeInterval(0.30)))
    }

    func testSecondPressOutsideThresholdDoesNotTriggerDoubleEscape() {
        var tracker = EscapePressTracker(doublePressInterval: 0.65)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(tracker.registerPress(at: t0))
        XCTAssertFalse(tracker.registerPress(at: t0.addingTimeInterval(0.80)))
    }
}

final class MarkupStyleDefaultsTests: XCTestCase {
    func testTextOutlineWidthDefaultIsThree() {
        XCTAssertEqual(MarkupStyleDefaults.textOutlineWidth, 3.0, accuracy: 0.0001)
    }

    func testTextOutlineColorDefaultIsBlack() {
        let expected = NSColor.black.usingColorSpace(.deviceRGB) ?? .black
        let actual = MarkupStyleDefaults.textOutlineColor.usingColorSpace(.deviceRGB) ?? .black
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.0001)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.0001)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.0001)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.0001)
    }
}

