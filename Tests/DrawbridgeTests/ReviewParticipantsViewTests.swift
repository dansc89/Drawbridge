import AppKit
import XCTest
@testable import Drawbridge

final class ReviewParticipantsViewTests: XCTestCase {
    @MainActor
    private func labels(in view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { labels(in: $0) }
    }

    @MainActor
    func testNativeDisclosureRetainsSummaryAndActuallyCollapsesBody() {
        _ = NSApplication.shared
        let view = ReviewParticipantsView(frame: .zero)
        view.render(nil)
        XCTAssertEqual(view.disclosureButton.title, "Participants — unavailable")
        XCTAssertEqual(view.summaryField.stringValue, "Participant presence unavailable.")
        XCTAssertFalse(view.bodyStack.isHidden)
        view.disclosureButton.performClick(nil)
        XCTAssertTrue(view.bodyStack.isHidden)
        XCTAssertFalse(view.disclosureButton.isHidden)
        view.disclosureButton.performClick(nil)
        XCTAssertFalse(view.bodyStack.isHidden)
        XCTAssertEqual(view.summaryField.stringValue, "Participant presence unavailable.")
    }

    @MainActor
    func testRendersVerifiedNamesStatesCountAndExpiryWithoutInventingPeople() {
        _ = NSApplication.shared
        let now = Date(timeIntervalSince1970: 1000)
        let members = ["Ada", "Bo", "Cy"].map {
            ReviewVerifiedParticipant(workspaceID: "w", authenticatedUserID: $0, verifiedName: $0)!
        }
        let snapshot = ReviewParticipants(workspaceID: "w", members: members,
            heartbeats: [.init(workspaceID: "w", userID: "Ada", sessionID: "a", receivedAt: now, isSyncing: false),
                         .init(workspaceID: "w", userID: "Bo", sessionID: "b", receivedAt: now, isSyncing: true)],
            connection: .connected)
        let view = ReviewParticipantsView(frame: .zero)
        view.render(snapshot, at: now)
        XCTAssertEqual(view.disclosureButton.title, "Participants (3)")
        XCTAssertEqual(view.summaryField.stringValue, "2 online · 3 workspace participants")
        XCTAssertEqual(labels(in: view.rowsStack), ["Ada", "Online", "Bo", "Syncing", "Cy", "Offline"])
        view.render(snapshot, at: now.addingTimeInterval(30))
        XCTAssertEqual(labels(in: view.rowsStack), ["Ada", "Offline", "Bo", "Offline", "Cy", "Offline"])
        view.render(.init(workspaceID: "w", members: members, heartbeats: [], connection: .disconnected))
        XCTAssertEqual(view.disclosureButton.title, "Participants — disconnected")
        XCTAssertEqual(view.summaryField.stringValue, "Disconnected — participant presence unknown.")
        XCTAssertEqual(labels(in: view.rowsStack), [])
        view.render(.init(workspaceID: "w", members: [], heartbeats: [], connection: .connected))
        XCTAssertEqual(view.disclosureButton.title, "Participants (0)")
        XCTAssertEqual(view.summaryField.stringValue, "No participants in this workspace.")
    }

    @MainActor
    func testLongRosterIsScrollableAndRefreshDoesNotReopenCollapsedPanel() throws {
        _ = NSApplication.shared
        let view = ReviewParticipantsView(frame: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        let members = (0..<20).map {
            ReviewVerifiedParticipant(workspaceID: "w", authenticatedUserID: "id-\($0)",
                                      verifiedName: "Verified reviewer \($0)")!
        }
        let snapshot = ReviewParticipants(workspaceID: "w", members: members, heartbeats: [], connection: .connected)
        view.render(snapshot)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.rowsStack.arrangedSubviews.count, 20)
        let scroll = try XCTUnwrap(view.rowsStack.enclosingScrollView)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertLessThanOrEqual(scroll.frame.height, 120)
        XCTAssertGreaterThan(view.rowsStack.frame.height, scroll.contentView.bounds.height)
        XCTAssertLessThanOrEqual(view.frame.maxY, content.bounds.maxY)
        view.disclosureButton.performClick(nil)
        view.render(snapshot)
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.bodyStack.isHidden)
        XCTAssertEqual(view.disclosureButton.title, "Participants (20)")
        view.disclosureButton.performClick(nil)
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.bodyStack.isHidden)
        XCTAssertEqual(view.rowsStack.arrangedSubviews.count, 20)
    }

    @MainActor
    func testBrowserContainsUnavailableParticipantsAtBottomLeftWithoutNetwork() throws {
        _ = NSApplication.shared
        let controller = SharedReviewWindowController()
        controller.buildWindow()
        defer { controller.window?.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
        let panel = try XCTUnwrap(descendants(content).compactMap { $0 as? ReviewParticipantsView }.first)
        content.layoutSubtreeIfNeeded()
        let frame = panel.convert(panel.bounds, to: content)
        XCTAssertEqual(frame.minX, 12, accuracy: 1)
        XCTAssertEqual(frame.minY, 12, accuracy: 1)
        XCTAssertEqual(panel.disclosureButton.title, "Participants — unavailable")
        XCTAssertEqual(panel.rowsStack.arrangedSubviews.count, 0)
        let expandedHeight = frame.height
        panel.disclosureButton.performClick(nil)
        content.layoutSubtreeIfNeeded()
        XCTAssertLessThan(panel.frame.height, expandedHeight)
        XCTAssertGreaterThan(panel.frame.height, 0)
        panel.disclosureButton.performClick(nil)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame.height, expandedHeight, accuracy: 1)
    }
}
