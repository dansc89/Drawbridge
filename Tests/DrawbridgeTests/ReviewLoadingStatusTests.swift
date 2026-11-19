import AppKit
import XCTest
@testable import Drawbridge

@MainActor final class ReviewLoadingStatusTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testPerformShowsExactLoadingTextBeforeAndDuringWork() async throws {
        let suiteName = "ReviewLoadingStatusTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let previousDefaults = SettingsWindowController.reviewSessionDefaults
        let previousSession = SettingsWindowController.activeReviewSession
        let previousRestore = SettingsWindowController.attemptedSessionRestore
        let previousRead = SettingsWindowController.reviewSessionRead
        let previousWrite = SettingsWindowController.reviewSessionWrite
        let previousDelete = SettingsWindowController.reviewSessionDelete
        SettingsWindowController.reviewSessionDefaults = defaults
        SettingsWindowController.activeReviewSession = nil
        SettingsWindowController.attemptedSessionRestore = true
        SettingsWindowController.reviewSessionRead = { XCTFail("Must not read Keychain"); return nil }
        SettingsWindowController.reviewSessionWrite = { _ in XCTFail("Must not write Keychain"); return false }
        SettingsWindowController.reviewSessionDelete = { XCTFail("Must not delete Keychain") }
        defer {
            SettingsWindowController.reviewSessionDefaults = previousDefaults
            SettingsWindowController.activeReviewSession = previousSession
            SettingsWindowController.attemptedSessionRestore = previousRestore
            SettingsWindowController.reviewSessionRead = previousRead
            SettingsWindowController.reviewSessionWrite = previousWrite
            SettingsWindowController.reviewSessionDelete = previousDelete
            defaults.removePersistentDomain(forName: suiteName)
        }

        _ = NSApplication.shared
        let controller = SharedReviewWindowController()
        controller.buildWindow() // Construct only: never show or activate a window.
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let status = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Choose a shared PDF." })
        let refresh = try XCTUnwrap(window.toolbar?.items.first {
            $0.itemIdentifier.rawValue == "review.refresh"
        })
        let workRan = expectation(description: "Local operation ran without a server")
        controller.perform {
            XCTAssertEqual(status.stringValue, "Loading...", "Keep three ASCII periods, not a Unicode ellipsis")
            XCTAssertFalse(refresh.isEnabled)
            workRan.fulfill()
        }
        XCTAssertEqual(status.stringValue, "Loading...", "Loading must be set synchronously before work starts")
        XCTAssertFalse(refresh.isEnabled)
        await fulfillment(of: [workRan], timeout: 2)
        XCTAssertTrue(refresh.isEnabled, "Operation cleanup restores browser controls")
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}
