import AppKit
import XCTest
@testable import Drawbridge

private actor ReviewDeletionRequests {
    var authCount = 0
    func recordAuth() { authCount += 1 }
}

final class ReviewNativeBrowserTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor func testDecodedDocumentDeletionCapabilityKeepsViewerWritesClosed() async throws {
        _ = NSApplication.shared
        let active = SettingsWindowController.activeReviewSession
        let attempted = SettingsWindowController.attemptedSessionRestore
        let origin = URL(string: "https://fixture.invalid")!
        let instance = UUID().uuidString
        SettingsWindowController.attemptedSessionRestore = true
        SettingsWindowController.activeReviewSession = (origin, .init(token: "fixture-only", instanceId: instance, displayName: "Fixture User"))
        defer {
            SettingsWindowController.activeReviewSession = active
            SettingsWindowController.attemptedSessionRestore = attempted
            UserDefaults.standard.removeObject(forKey: "DrawbridgeReviewFolder|\(origin.absoluteString)|\(instance)|p")
        }
        let controller = SharedReviewWindowController()
        controller.buildWindow()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let table = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSTableView }.first)
        let items = try XCTUnwrap(window.toolbar).items
        let delete = try XCTUnwrap(items.first { $0.itemIdentifier.rawValue == "review.delete" })
        let folder = try XCTUnwrap(items.first { $0.itemIdentifier.rawValue == "review.newFolder" })
        let upload = try XCTUnwrap(items.first { $0.itemIdentifier.rawValue == "review.upload" })
        for (capabilities, allowed, writer) in [
            (#""organizationActions":false,"documentDeletion":true"#, true, false),
            (#""organizationActions":false,"documentDeletion":false"#, false, false),
            (#""organizationActions":false,"documentDeletion":null"#, false, false),
            (#""organizationActions":false"#, false, false),
            (#""organizationActions":true"#, true, true)
        ] {
            let requests = ReviewDeletionRequests()
            controller.makeReviewAPI = { origin, credentials in
                var api = SharedReviewAPI(origin: origin, token: credentials.token, displayName: credentials.displayName, instanceID: credentials.instanceId)
                api.transport = { request in
                    if request.url!.path == "/v1/auth/me" {
                        await requests.recordAuth()
                        // Stop before native sheets: this exercises actual action admission, not confirmation UI.
                        throw SharedReviewError("Fixture stops before confirmation")
                    }
                    let json = request.url!.path == "/v1/projects"
                        ? #"{"projects":[{"id":"p","name":"Fixture Workspace"}]}"#
                        : "{" + capabilities + #", "folders":[{"id":"f","name":"Folder"}],"documents":[{"id":"d","name":"Drawing.pdf","file_size":100}]}"#
                    return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                return api
            }
            try await controller.loadDocuments()
            XCTAssertFalse(delete.isEnabled)
            XCTAssertEqual(folder.isEnabled, writer)
            XCTAssertEqual(upload.isEnabled, writer)
            XCTAssertFalse(controller.canEdit)
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            XCTAssertEqual(delete.isEnabled, allowed, capabilities)
            if allowed { XCTAssertTrue(delete.toolTip?.contains("exact Review username") == true) }
            XCTAssertEqual(controller.tableView(table, pasteboardWriterForRow: 1) != nil, writer)
            controller.perform(NSSelectorFromString("deleteSelectedItems"))
            // Let the real operation finish (or prove the denied action stayed idle).
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(2))
                if allowed, await requests.authCount == 1,
                   items.first(where: { $0.itemIdentifier.rawValue == "review.refresh" })?.isEnabled == true { break }
            }
            let authCount = await requests.authCount
            XCTAssertEqual(authCount, allowed ? 1 : 0, "Actual document-delete action admission")
            XCTAssertNil(window.attachedSheet)
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            XCTAssertEqual(delete.isEnabled, writer)
            table.selectRowIndexes(IndexSet(integersIn: 0...1), byExtendingSelection: false)
            XCTAssertEqual(delete.isEnabled, writer, "Mixed selections must not grant viewer folder deletion")
            if !writer {
                // Invoke retained actions directly too: disabled controls are not authorization guards.
                controller.perform(NSSelectorFromString("deleteSelectedItems"))
                XCTAssertNil(window.attachedSheet)
            }
        }
        NotificationCenter.default.post(name: SettingsWindowController.reviewSessionDidChange, object: nil)
        XCTAssertFalse(delete.isEnabled)
        XCTAssertFalse(folder.isEnabled)
        XCTAssertFalse(upload.isEnabled)
    }

    @MainActor func testNativeToolbarAndRoomyEdgeToEdgeList() throws {
        _ = NSApplication.shared
        let controller = SharedReviewWindowController()
        controller.buildWindow()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let toolbar = try XCTUnwrap(window.toolbar)
        XCTAssertEqual(toolbar.items.compactMap { $0.itemIdentifier.rawValue }.filter { $0.hasPrefix("review.") },
                       ["review.back", "review.upload", "review.newFolder", "review.refresh", "review.delete"])
        for item in toolbar.items where item.itemIdentifier.rawValue.hasPrefix("review.") {
            XCTAssertNotNil(item.image)
            XCTAssertFalse(item.toolTip?.isEmpty ?? true)
            XCTAssertTrue(item.target === controller)
            XCTAssertNotNil(item.action)
        }
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.style, .inset)
        XCTAssertGreaterThanOrEqual(table.rowHeight, 30)
        XCTAssertNil(table.headerView)
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        XCTAssertEqual(scroll.borderType, .noBorder)
        XCTAssertEqual(scroll.convert(scroll.bounds, to: content).minX, 0, accuracy: 1)
        XCTAssertEqual(scroll.frame.width, content.bounds.width, accuracy: 1)
        XCTAssertEqual(window.title, "Drawbridge Review — Server Documents")
        XCTAssertNotNil(table.doubleAction)
        XCTAssertTrue(table.target === controller)
        XCTAssertTrue(descendants(content).compactMap { $0 as? NSButton }.contains { $0.keyEquivalent == "\r" })
        window.setContentSize(NSSize(width: 960, height: 600))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.frame.width, content.bounds.width, accuracy: 1)
        XCTAssertGreaterThan(table.tableColumns[0].width, 600)
    }
    @MainActor func testLiveThemeChangesRefreshDarkToDarkAndRestoreNativeFallback() throws {
        _ = NSApplication.shared
        let original = UserDefaults.standard.object(forKey: InterfaceTheme.defaultsKey)
        defer {
            UserDefaults.standard.set(original, forKey: InterfaceTheme.defaultsKey)
            NotificationCenter.default.post(name: InterfaceTheme.didChange, object: nil)
        }
        InterfaceTheme.select(.dracula)
        let controller = SharedReviewWindowController()
        controller.buildWindow()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        for theme in [InterfaceTheme.dracula, .nord, .absolutelyLight] {
            InterfaceTheme.select(theme)
            XCTAssertEqual(window.appearance?.name, theme.nativeAppearance?.name)
            XCTAssertEqual(window.backgroundColor, AppAppearance.chrome)
            XCTAssertEqual(table.backgroundColor, AppAppearance.panel)
            XCTAssertTrue(window.titlebarAppearsTransparent)
            let status = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Choose a shared PDF." })
            XCTAssertEqual(status.textColor, theme.color(for: "foreground"))
        }
        InterfaceTheme.select(.system)
        XCTAssertNil(window.appearance)
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertEqual(table.backgroundColor, .controlBackgroundColor)
    }
    @MainActor func testActualProgressControlPreparingBytesVerifyingAndReset() throws {
        _ = NSApplication.shared
        let controller = SharedReviewWindowController()
        controller.buildWindow()
        defer { controller.window?.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        let bar = try XCTUnwrap(descendants(content).compactMap { $0 as? NSProgressIndicator }.first)
        XCTAssertTrue(bar.isHidden)
        controller.presentUploadProgress(file: "Long drawing.pdf", index: 2, count: 3)
        XCTAssertFalse(bar.isHidden)
        XCTAssertTrue(bar.isIndeterminate)
        controller.presentUploadProgress(file: "Long drawing.pdf", index: 2, count: 3, sent: 25, total: 100)
        XCTAssertFalse(bar.isIndeterminate)
        XCTAssertEqual(bar.doubleValue, 25, accuracy: 0.001)
        let labels = descendants(content).compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(labels.contains { $0.contains("2 of 3") && $0.contains("25%") && $0.contains("25 bytes") })
        controller.presentUploadProgress(file: "Long drawing.pdf", index: 2, count: 3, sent: 100, total: 100)
        XCTAssertTrue(bar.isIndeterminate)
        XCTAssertTrue(descendants(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Verifying") })
        controller.resetUploadProgress()
        XCTAssertTrue(bar.isHidden)
        XCTAssertEqual(bar.doubleValue, 0)
        controller.presentUploadProgress(file: "Other.pdf", index: 1, count: 1, sent: 0, total: 0)
        XCTAssertTrue(bar.isIndeterminate)
        NotificationCenter.default.post(name: SettingsWindowController.reviewSessionDidChange, object: nil)
        XCTAssertTrue(bar.isHidden)
        XCTAssertEqual(bar.doubleValue, 0)
    }
}
