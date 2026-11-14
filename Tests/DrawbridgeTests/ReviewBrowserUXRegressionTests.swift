import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class ReviewBrowserUXRegressionTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testNoSelectionIsTooltipNotPersistentCapabilityError() {
        let state = ReviewCapabilityPresentation(busy: false, foldersAvailable: true,
            organizationActions: true, selectionCount: 0)
        XCTAssertNotNil(state.deleteReason)
        XCTAssertTrue(state.deleteToolTip.contains("Select"))
        XCTAssertTrue(state.explanation.isEmpty, state.explanation)
        let busy = ReviewCapabilityPresentation(busy: true, foldersAvailable: true,
            organizationActions: true, selectionCount: 1)
        XCTAssertTrue(busy.explanation.isEmpty, "Transient busy state is not a capability failure")
    }

    func testUploadUsesOriginalTemplateAndExplicitLabel() throws {
        _ = NSApplication.shared
        let controller = SharedReviewWindowController(); controller.buildWindow()
        defer { controller.window?.close() }
        let item = try XCTUnwrap(controller.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "review.upload" })
        let image = try XCTUnwrap(item.image)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual((item.view as? NSButton)?.title, "Upload PDFs…")
        XCTAssertNotEqual(image.tiffRepresentation, NSImage(systemSymbolName: "arrow.up.to.line", accessibilityDescription: nil)?.tiffRepresentation)
    }

    func testBusyBrowserRejectsSelectionAndRestoresWithoutMovingFocus() async throws {
        _ = NSApplication.shared
        let controller = SharedReviewWindowController(); controller.buildWindow()
        defer { controller.window?.close() }
        let table = try XCTUnwrap(descendants(try XCTUnwrap(controller.window?.contentView)).compactMap { $0 as? NSTableView }.first)
        var resume: CheckedContinuation<Void, Never>?
        controller.perform { await withCheckedContinuation { resume = $0 } }
        for _ in 0..<1000 { if resume != nil { break }; await Task.yield() }
        XCTAssertFalse((controller as NSTableViewDelegate).tableView?(table, shouldSelectRow: 0) ?? true)
        try XCTUnwrap(resume).resume()
        for _ in 0..<1000 { if controller.window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "review.refresh" })?.isEnabled == true { break }; await Task.yield() }
        XCTAssertTrue((controller as NSTableViewDelegate).tableView?(table, shouldSelectRow: 0) ?? true)
        XCTAssertFalse(controller.window?.isKeyWindow ?? true)
    }

    func testNavigationRefreshAndLongNames() async throws {
        _ = NSApplication.shared
        let active = SettingsWindowController.activeReviewSession
        let attempted = SettingsWindowController.attemptedSessionRestore
        let origin = URL(string: "https://browser-fixture.invalid")!
        let instance = UUID().uuidString
        SettingsWindowController.attemptedSessionRestore = true
        SettingsWindowController.activeReviewSession = (origin, .init(token: "fixture-only", instanceId: instance, displayName: "Fixture"))
        defer {
            SettingsWindowController.activeReviewSession = active
            SettingsWindowController.attemptedSessionRestore = attempted
            UserDefaults.standard.removeObject(forKey: "DrawbridgeReviewFolder|\(origin.absoluteString)|\(instance)|p")
        }
        let controller = SharedReviewWindowController(); controller.buildWindow()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.makeReviewAPI = { origin, credentials in
            var api = SharedReviewAPI(origin: origin, token: credentials.token, displayName: credentials.displayName, instanceID: credentials.instanceId)
            api.transport = { request in
                let json = request.url!.path == "/v1/projects"
                    ? #"{"projects":[{"id":"p","name":"Fixture"}]}"#
                    : #"{"organizationActions":true,"folders":[{"id":"f","name":"Folder"}],"documents":[{"id":"a","name":"An extremely long drawing coordination issue name — 日本語 — architectural floor plan.pdf","file_size":10},{"id":"b","name":"B.pdf","file_size":10}]}"#
                return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return api
        }
        try await controller.loadDocuments()
        let content = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        let open = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Open" })
        table.selectRowIndexes(IndexSet([1, 2]), byExtendingSelection: false)
        XCTAssertEqual(table.numberOfSelectedRows, 2)
        XCTAssertTrue(open.isEnabled)
        table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        XCTAssertFalse(open.isEnabled, "Mixed folder/PDF selections cannot be opened")
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await controller.loadDocuments()
        XCTAssertTrue(table.selectedRowIndexes.isEmpty, "Refresh must not transfer index-based selection to different items")
        XCTAssertFalse(open.isEnabled)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        window.makeFirstResponder(table)
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: code == 36 ? "\r" : "", charactersIgnoringModifiers: code == 36 ? "\r" : "", isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(window.performKeyEquivalent(with: try key(125, .command)))
        XCTAssertEqual(table.numberOfRows, 0)
        XCTAssertTrue(window.performKeyEquivalent(with: try key(126, .command)))
        XCTAssertEqual(table.numberOfRows, 3)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(window.performKeyEquivalent(with: try key(36, [])))
        XCTAssertEqual(table.numberOfRows, 0, "Return opens the selected folder")
        XCTAssertTrue(window.performKeyEquivalent(with: try key(126, .command)))
        let cell = try XCTUnwrap(controller.tableView(table, viewFor: table.tableColumns[0], row: 1))
        let name = try XCTUnwrap(descendants(cell).compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(name.lineBreakMode, .byTruncatingMiddle)
        XCTAssertEqual(name.maximumNumberOfLines, 1)
        XCTAssertEqual(name.toolTip, name.stringValue)
        window.setContentSize(NSSize(width: 480, height: 320))
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(table.enclosingScrollView!.frame.height, 80)
    }

    func testReviewMeasurementsRequireSupportedExistingScale() {
        for review in [false, true] {
            for editable in [false, true] {
                for scaled in [false, true] {
                    for supported in [false, true] {
                        let capability = ReviewMeasurementCapability(isReview: review, editable: editable,
                            hasPage: true, supportedPage: supported, hasScale: scaled)
                        XCTAssertEqual(capability.canMeasure, editable && supported && (!review || scaled))
                        XCTAssertEqual(capability.canSetScale, editable && !review)
                        if review && !scaled { XCTAssertTrue(capability.measurementReason?.contains("no scale") == true) }
                    }
                }
            }
        }
        XCTAssertFalse(ReviewMeasurementCapability(isReview: false, editable: true,
            hasPage: false, supportedPage: true, hasScale: true).canMeasure)
    }

    func testReadOnlyDocumentKeepsSelectToolbarAvailable() throws {
        _ = NSApplication.shared
        let editor = MainViewController(); editor.loadViewIfNeeded()
        let document = PDFDocument(); document.insert(PDFPage(), at: 0)
        editor.pdfView.document = document
        editor.pdfView.rectangleMarkup.canEdit = { false }
        editor.refreshRectangleToolbar()
        XCTAssertTrue(editor.rectangleToolbar.selectButton.isEnabled)
        XCTAssertFalse(editor.rectangleToolbar.rectangleButton.isEnabled)
        XCTAssertFalse(editor.rectangleToolbar.areaButton.isEnabled)
    }
}
