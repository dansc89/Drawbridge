import XCTest
import AppKit
@testable import Drawbridge

@MainActor
final class ReviewBrowserNavigationTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testCommandArrowsTraverseHistoryRatherThanParentAndSelection() async throws {
        _ = NSApplication.shared
        let previous = SettingsWindowController.activeReviewSession
        let attempted = SettingsWindowController.attemptedSessionRestore
        let origin = URL(string: "https://navigation-fixture.invalid")!
        let instance = UUID().uuidString
        SettingsWindowController.attemptedSessionRestore = true
        SettingsWindowController.activeReviewSession = (origin, .init(token: "fixture-only", instanceId: instance, displayName: "Fixture"))
        defer {
            SettingsWindowController.activeReviewSession = previous
            SettingsWindowController.attemptedSessionRestore = attempted
            for project in ["p", "other"] {
                UserDefaults.standard.removeObject(forKey: "DrawbridgeReviewFolder|\(origin.absoluteString)|\(instance)|\(project)")
            }
        }
        let controller = SharedReviewWindowController(); controller.buildWindow()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        var projectID = "p"
        var listing = #"{"organizationActions":true,"folders":[{"id":"a","name":"A"},{"id":"b","name":"B"},{"id":"nested","name":"Nested","parent_id":"a"}],"documents":[]}"#
        controller.makeReviewAPI = { origin, credentials in
            var api = SharedReviewAPI(origin: origin, token: credentials.token, displayName: credentials.displayName, instanceID: credentials.instanceId)
            api.transport = { request in
                let json = request.url!.path == "/v1/projects"
                    ? "{\"projects\":[{\"id\":\"\(projectID)\",\"name\":\"Workspace\"}]}"
                    : listing
                return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return api
        }
        try await controller.loadDocuments()
        let content = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        let path = try XCTUnwrap(descendants(content).compactMap { $0 as? NSPathControl }.first)
        XCTAssertTrue(window.makeFirstResponder(table))
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        func press(_ code: UInt16) throws { XCTAssertTrue(window.performKeyEquivalent(with: try key(code))) }
        func at(_ names: [String], file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(path.pathItems.map(\.title), names, file: file, line: line)
            XCTAssertTrue(window.firstResponder === table, file: file, line: line)
        }
        at(["Workspace"])
        try press(123); try press(124) // No history: both are harmless.
        at(["Workspace"])
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try press(125); at(["Workspace", "A"])
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try press(125); at(["Workspace", "A", "Nested"])
        try press(123); at(["Workspace", "A"])
        try press(124); at(["Workspace", "A", "Nested"])
        try press(126); at(["Workspace", "A"]) // Up visits parent and records that visit.
        try press(126); at(["Workspace"])
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try press(125); at(["Workspace", "B"])
        try press(123); at(["Workspace"])
        try press(123); at(["Workspace", "A"]) // Not the current folder's parent.
        try press(124); at(["Workspace"])
        try press(124); at(["Workspace", "B"]) // No selection required for forward.
        try press(123); at(["Workspace"])
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try press(125); at(["Workspace", "A"]) // New navigation truncates forward history.
        try press(124); at(["Workspace", "A"])
        try await controller.loadDocuments()
        try press(123); at(["Workspace"])
        try press(124); at(["Workspace", "A"]) // Refresh keeps valid history.

        let field = NSTextField(string: "Keep editing")
        content.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(window.performKeyEquivalent(with: try key(123)))
        XCTAssertFalse(window.performKeyEquivalent(with: try key(124)))
        XCTAssertEqual(path.pathItems.map(\.title), ["Workspace", "A"])
        XCTAssertEqual(field.stringValue, "Keep editing")
        window.endEditing(for: field); field.removeFromSuperview()
        XCTAssertTrue(window.makeFirstResponder(table))
        XCTAssertFalse(window.performKeyEquivalent(with: try key(123, [.command, .shift])))
        at(["Workspace", "A"])

        var confirmations = 0
        let prompted = expectation(description: "Delete confirmation")
        controller.reviewAlertPresenter = { alert in
            confirmations += 1
            XCTAssertTrue(alert.messageText.contains("Delete"))
            prompted.fulfill()
            return .alertSecondButtonReturn
        }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try press(51) // Command-Backspace asks; cancelling must not delete.
        await fulfillment(of: [prompted], timeout: 2)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(table.numberOfRows, 1)
        table.deselectAll(nil)
        try press(51)
        XCTAssertEqual(confirmations, 1, "No selection must not prompt")
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        content.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        _ = window.performKeyEquivalent(with: try key(51))
        XCTAssertEqual(confirmations, 1, "Editing must never invoke file deletion")
        window.endEditing(for: field); field.removeFromSuperview()
        XCTAssertTrue(window.makeFirstResponder(table))
        _ = window.performKeyEquivalent(with: try key(51, [.command, .shift]))
        XCTAssertEqual(confirmations, 1)

        listing = #"{"organizationActions":true,"folders":[{"id":"b","name":"B"}],"documents":[]}"#
        try await controller.loadDocuments() // A was removed by another participant.
        at(["Workspace"])
        try press(123); at(["Workspace"])
        try press(124); at(["Workspace"])
        projectID = "other"
        try await controller.loadDocuments() // Never traverse folders from a previous workspace.
        try press(123); try press(124)
        at(["Workspace"])
    }
}
