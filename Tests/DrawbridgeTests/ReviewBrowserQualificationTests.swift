import AppKit
import XCTest
@testable import Drawbridge

@MainActor final class ReviewBrowserQualificationTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    func testOperationCompletionAndErrorClearProgressAndRestoreToolbar() async throws {
        _ = NSApplication.shared
        let controller = SharedReviewWindowController()
        controller.buildWindow()
        defer { controller.window?.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        let bar = try XCTUnwrap(descendants(content).compactMap { $0 as? NSProgressIndicator }.first)
        let refresh = try XCTUnwrap(controller.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "review.refresh" })
        for fail in [false, true] {
            var resume: CheckedContinuation<Void, Never>?
            controller.perform {
                controller.presentUploadProgress(file: "Fixture.pdf", index: 1, count: 1, sent: 50, total: 100)
                await withCheckedContinuation { resume = $0 }
                if fail { throw SharedReviewError("Fixture upload rejected") }
            }
            for _ in 0..<1000 { if resume != nil { break }; await Task.yield() }
            let continuation = try XCTUnwrap(resume)
            XCTAssertFalse(bar.isHidden)
            XCTAssertFalse(refresh.isEnabled)
            continuation.resume()
            for _ in 0..<1000 { if bar.isHidden { break }; await Task.yield() }
            XCTAssertTrue(bar.isHidden)
            XCTAssertTrue(refresh.isEnabled)
            if fail {
                XCTAssertTrue(descendants(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Fixture upload rejected" })
            }
        }
    }

    func testRenderedBrowserThemesAndMinimumSize() async throws {
        guard let directory = ProcessInfo.processInfo.environment["DRAWBRIDGE_REVIEW_CAPTURE_DIR"] else {
            throw XCTSkip("Opt-in WindowServer capture of isolated fixture window")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let theme = UserDefaults.standard.object(forKey: InterfaceTheme.defaultsKey)
        let active = SettingsWindowController.activeReviewSession
        let attempted = SettingsWindowController.attemptedSessionRestore
        let suite = "ReviewBrowserCapture." + UUID().uuidString
        let oldDefaults = SettingsWindowController.reviewSessionDefaults
        SettingsWindowController.reviewSessionDefaults = UserDefaults(suiteName: suite)!
        SettingsWindowController.attemptedSessionRestore = true
        let origin = URL(string: "https://fixture.invalid")!
        let instance = UUID().uuidString
        SettingsWindowController.activeReviewSession = (origin, .init(token: "fixture-only", instanceId: instance, displayName: "Fixture User"))
        defer {
            UserDefaults.standard.set(theme, forKey: InterfaceTheme.defaultsKey)
            NotificationCenter.default.post(name: InterfaceTheme.didChange, object: nil)
            SettingsWindowController.activeReviewSession = active
            SettingsWindowController.attemptedSessionRestore = attempted
            SettingsWindowController.reviewSessionDefaults.removePersistentDomain(forName: suite)
            SettingsWindowController.reviewSessionDefaults = oldDefaults
            UserDefaults.standard.removeObject(forKey: "DrawbridgeReviewFolder|\(origin.absoluteString)|\(instance)|p")
        }
        let controller = SharedReviewWindowController()
        controller.buildWindow()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.makeReviewAPI = { origin, credentials in
            var api = SharedReviewAPI(origin: origin, token: credentials.token, displayName: credentials.displayName, instanceID: credentials.instanceId)
            api.transport = { request in
                let text = request.url!.path == "/v1/projects"
                    ? #"{"projects":[{"id":"p","name":"AERO Collective"}]}"#
                    : #"{"organizationActions":true,"folders":[{"id":"f","name":"Architectural Drawings"}],"documents":[{"id":"d1","name":"A101 — Floor Plans — Coordination Issue 2026-11-13.pdf","file_size":52428800},{"id":"d2","name":"A201 — Exterior Elevations.pdf","file_size":73400320},{"id":"d3","name":"S001 — Structural General Notes.pdf","file_size":104857600}]}"#
                return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return api
        }
        try await controller.loadDocuments()
        let content = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        window.setFrameOrigin(NSPoint(x: 80, y: 100))
        window.orderBack(nil)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, selectedTheme, size, upload) in [
            ("native", InterfaceTheme.system, NSSize(width: 740, height: 480), false),
            ("dracula-upload", .dracula, NSSize(width: 740, height: 480), true),
            ("nord-upload", .nord, NSSize(width: 740, height: 480), true),
            ("light-minimum", .absolutelyLight, NSSize(width: 480, height: 320), true)
        ] {
            InterfaceTheme.select(selectedTheme)
            window.setContentSize(size)
            if upload { controller.presentUploadProgress(file: "A101 — Floor Plans — Coordination Issue 2026-11-13.pdf", index: 2, count: 3, sent: 28_000_000, total: 80_000_000) }
            else { controller.resetUploadProgress() }
            content.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(table.enclosingScrollView!.frame.height, 80)
            for view in content.subviews.flatMap({ descendants($0) }).filter({ !$0.isHidden && ($0 is NSPathControl || $0 is NSProgressIndicator || $0 is ReviewParticipantsView) }) {
                let rect = view.convert(view.bounds, to: content)
                XCTAssertGreaterThanOrEqual(rect.minX, -1)
                XCTAssertLessThanOrEqual(rect.maxX, content.bounds.width + 1)
                XCTAssertGreaterThanOrEqual(rect.minY, -1)
            }
            try await Task.sleep(for: .milliseconds(250))
            window.displayIfNeeded()
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), directory + "/" + name + ".png"]
            try capture.run()
            capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
            print("REVIEW_CAPTURE \(name) \(directory)/\(name).png")
        }
    }
}
