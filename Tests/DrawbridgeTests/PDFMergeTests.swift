import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

final class PDFMergeTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MergeTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func fixture(_ name: String, rotations: [Int]) throws -> URL {
        // Literal streams let us verify concatenation without PDFKit re-encoding.
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", ""]
        var kids: [String] = []
        for (index, rotation) in rotations.enumerated() {
            let pageID = objects.count + 1
            kids.append("\(pageID) 0 R")
            let stream = "q 0 0 m \(index + 10) 40 l S Q\n% \(name)-\(index)\n"
            objects += [
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Rotate \(rotation) /Resources << >> /Contents \(pageID + 1) 0 R /Annots [\(pageID + 2) 0 R] >>",
                "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream",
                "<< /Type /Annot /Subtype /Square /Rect [10 20 50 60] /Contents (\(name)-\(index)) /C [1 0 0] /F 4 >>"
            ]
        }
        objects[1] = "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(rotations.count) >>"
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (i, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(i + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let url = directory.appendingPathComponent(name + ".pdf")
        try data.write(to: url)
        return url
    }
    func testConcatenatesInChosenOrderPreservingStreamsRotationsEditableAnnotationsAndOriginals() throws {
        let a = try fixture("A", rotations: [0, 90]), b = try fixture("B", rotations: [180, 270])
        let before = try [b, a].map { try Data(contentsOf: $0) }
        let output = directory.appendingPathComponent("merged.pdf")
        let report = try PDFMergeService.merge(sources: [b, a], destination: output)
        XCTAssertEqual(report.pageCount, 4)
        guard let document = PDFDocument(url: output) else { XCTFail("Merge must publish a readable PDF"); return }
        XCTAssertEqual(document.pageCount, 4)
        for (i, rotation) in [180, 270, 0, 90].enumerated() {
            let page = try XCTUnwrap(document.page(at: i))
            XCTAssertEqual(page.rotation, rotation)
            XCTAssertEqual(page.annotations.first?.contents, ["B-0", "B-1", "A-0", "A-1"][i])
            XCTAssertEqual(page.annotations.first?.type, "Square")
            XCTAssertFalse(try XCTUnwrap(page.annotations.first).isReadOnly)
        }
        let helper = try XCTUnwrap(PDFTKBookmarkWriter.executableURL())
        let jsonURL = directory.appendingPathComponent("streams.json")
        XCTAssertTrue(PDFTKBookmarkWriter.run(helper, arguments: ["--json=2", "--json-stream-data=inline", "--decode-level=generalized", output.path, jsonURL.path]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        let pages = try XCTUnwrap(json["pages"] as? [[String: Any]])
        let table = try XCTUnwrap((json["qpdf"] as? [[String: Any]])?[1])
        let streams = try pages.map { page -> Data in
            let reference = try XCTUnwrap((page["contents"] as? [String])?.first)
            let object = try XCTUnwrap(table["obj:" + reference] as? [String: Any])
            let stream = try XCTUnwrap(object["stream"] as? [String: Any])
            return try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(stream["data"] as? String)))
        }
        XCTAssertEqual(streams, ["B", "A"].flatMap { name in (0..<2).map { i in Data("q 0 0 m \(i + 10) 40 l S Q\n% \(name)-\(i)\n".utf8) } })
        XCTAssertEqual(try [b, a].map { try Data(contentsOf: $0) }, before)
    }
    func testRejectsInvalidEmptyEncryptedAndTooFewInputsWithoutChangingDestination() throws {
        let a = try fixture("A", rotations: [0]), empty = try fixture("empty", rotations: [])
        let invalid = directory.appendingPathComponent("bad.pdf"); try Data("not PDF".utf8).write(to: invalid)
        let encrypted = directory.appendingPathComponent("encrypted.pdf")
        let helper = try XCTUnwrap(PDFTKBookmarkWriter.executableURL())
        XCTAssertTrue(PDFTKBookmarkWriter.run(helper, arguments: [a.path, "--encrypt", "", "owner", "256", "--", encrypted.path]))
        let destination = directory.appendingPathComponent("existing.pdf"), sentinel = Data("existing destination".utf8)
        try sentinel.write(to: destination)
        for sources in [[a], [a, invalid], [a, empty], [a, encrypted]] {
            XCTAssertThrowsError(try PDFMergeService.merge(sources: sources, destination: destination))
            XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        }
    }
    func testRejectsOutputEqualToOriginalIncludingSymlinkAndHardlinkAliases() throws {
        let a = try fixture("A", rotations: [0]), b = try fixture("B", rotations: [90])
        let symlink = directory.appendingPathComponent("symlink.pdf"), hardlink = directory.appendingPathComponent("hardlink.pdf")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: a)
        try FileManager.default.linkItem(at: a, to: hardlink)
        let original = try Data(contentsOf: a)
        for destination in [a, symlink, hardlink] {
            XCTAssertThrowsError(try PDFMergeService.merge(sources: [a, b], destination: destination))
            XCTAssertEqual(try Data(contentsOf: a), original)
            XCTAssertEqual(try Data(contentsOf: destination), original)
        }
    }
    func testMissingHelperAndCancellationLeaveDestinationUnchanged() throws {
        let a = try fixture("A", rotations: [0]), b = try fixture("B", rotations: [90])
        let destination = directory.appendingPathComponent("existing.pdf"), sentinel = Data("existing".utf8)
        try sentinel.write(to: destination)
        XCTAssertThrowsError(try PDFMergeService.merge(sources: [a, b], destination: destination, helper: nil))
        XCTAssertThrowsError(try PDFMergeService.merge(sources: [a, b], destination: destination, cancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
    }
    func testOrderedListAddsRemovesMovesAndRequiresTwoPDFs() {
        let a = directory.appendingPathComponent("a.pdf"), b = directory.appendingPathComponent("b.pdf"), c = directory.appendingPathComponent("c.pdf")
        var list = PDFMergeList()
        XCTAssertFalse(list.canMerge)
        list.add([a]); XCTAssertFalse(list.canMerge)
        list.add([b, c]); XCTAssertTrue(list.canMerge)
        list.move(index: 2, offset: -1); XCTAssertEqual(list.urls, [a, c, b])
        list.move(index: 0, offset: 1); XCTAssertEqual(list.urls, [c, a, b])
        list.move(index: 0, offset: -1); XCTAssertEqual(list.urls, [c, a, b])
        list.remove(index: 1); XCTAssertEqual(list.urls, [c, b])
        list.remove(index: 0); XCTAssertFalse(list.canMerge)
    }
    @MainActor func testActualFileMenuContainsAlwaysAvailableMergeNextToOpen() throws {
        _ = NSApplication.shared
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let delegate = AppDelegate(), controller = MainViewController()
        delegate.setupMainMenu(controller: controller)
        let file = try XCTUnwrap(NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu)
        let item = try XCTUnwrap(file.items.first(where: { $0.title == "Merge PDFs…" }), "Built-in File menu command is required")
        XCTAssertEqual(file.index(of: item), 1)
        let target = try XCTUnwrap(item.target as? PDFMergeWorkflow)
        XCTAssertEqual(item.action, #selector(PDFMergeWorkflow.showMerge(_:)))
        XCTAssertTrue(target.validateMenuItem(item))
    }
    @MainActor func testWorkflowMergesOffMainThreadAndOpensOutputInDrawbridgeTab() throws {
        _ = NSApplication.shared
        let a = try fixture("A", rotations: [0]), b = try fixture("B", rotations: [90])
        let output = directory.appendingPathComponent("workflow.pdf")
        let controller = MainViewController()
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        parent.contentViewController = controller
        controller.openDocument(at: a)
        let opened = expectation(description: "Merged output opens in Drawbridge"), worker = expectation(description: "Merge runs off the main thread")
        controller.onDocumentOpened = { url in
            if url == output { opened.fulfill() }
        }
        let workflow = PDFMergeWorkflow()
        workflow.controller = controller
        workflow.onProcessingStarted = {
            XCTAssertFalse(Thread.isMainThread)
            worker.fulfill()
        }
        workflow.showMerge(nil)
        XCTAssertNotNil(parent.attachedSheet)
        workflow.startMerge(sources: [b, a], destination: output)
        wait(for: [worker, opened], timeout: 8)
        XCTAssertNil(parent.attachedSheet)
        XCTAssertEqual(controller.openDocumentURL, output)
        XCTAssertEqual(controller.pdfView.document?.pageCount, 2)
        XCTAssertTrue(controller.sessionDocumentURLs.contains(controller.canonicalDocumentURL(a)))
        XCTAssertTrue(controller.sessionDocumentURLs.contains(controller.canonicalDocumentURL(output)))
        // Return to the original tab so its deferred workers no longer reference
        // the output fixture when tearDown removes the temporary directory.
        controller.openDocument(at: a)
        parent.orderOut(nil)
    }
    @MainActor func testBusyControllerRetainsSavedMergeAndRetriesOpenWithoutRewriting() throws {
        try exerciseSavedMergeRecovery(closeWithoutOpening: false)
    }
    @MainActor func testClosingSavedMergeRecoveryPreservesOutput() throws {
        try exerciseSavedMergeRecovery(closeWithoutOpening: true)
    }
    @MainActor private func exerciseSavedMergeRecovery(closeWithoutOpening: Bool) throws {
        _ = NSApplication.shared
        let a = try fixture("A", rotations: [0]), b = try fixture("B", rotations: [90])
        let output = directory.appendingPathComponent("recovery.pdf")
        let controller = MainViewController()
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        parent.contentViewController = controller
        controller.openDocument(at: a)
        controller.beginBusyIndicator("Test background operation")
        defer { controller.endBusyIndicator(); parent.orderOut(nil) }
        XCTAssertTrue(controller.isPDFProcessingBusy)
        let worker = expectation(description: "Exactly one merge operation")
        worker.assertForOverFulfill = true
        let workflow = PDFMergeWorkflow()
        workflow.controller = controller
        workflow.onProcessingStarted = { worker.fulfill() }
        workflow.showMerge(nil)
        let window = try XCTUnwrap(parent.attachedSheet)
        let content = try XCTUnwrap(window.contentView)
        workflow.startMerge(sources: [a, b], destination: output)
        wait(for: [worker], timeout: 8)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let saved = content.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(output.path) }
            if saved || parent.attachedSheet == nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(parent.attachedSheet === window, "Saved success must remain visible when opening is blocked")
        let retry = try XCTUnwrap(content.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Open Merged PDF" }, "Saved success must offer opening the existing output, not another merge")
        XCTAssertTrue(content.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(output.path) }, "Saved destination must be visible")
        XCTAssertEqual(controller.openDocumentURL, a)
        let savedBytes = try Data(contentsOf: output)
        let savedAttributes = try FileManager.default.attributesOfItem(atPath: output.path)
        // Opening must not need either merge input or publish the output again.
        try FileManager.default.removeItem(at: b)
        workflow.startMerge(sources: [a, b], destination: output)
        XCTAssertFalse(content.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Add PDFs…" }?.isEnabled ?? true)
        retry.performClick(nil)
        XCTAssertTrue(parent.attachedSheet === window)
        XCTAssertEqual(controller.openDocumentURL, a)
        if closeWithoutOpening {
            let close = try XCTUnwrap(content.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Close" || $0.title == "Cancel" })
            close.performClick(nil)
            XCTAssertNil(parent.attachedSheet)
            XCTAssertEqual(controller.openDocumentURL, a)
        } else {
            controller.endBusyIndicator()
            XCTAssertFalse(controller.isPDFProcessingBusy)
            retry.performClick(nil)
            XCTAssertNil(parent.attachedSheet)
            XCTAssertEqual(controller.openDocumentURL, output)
            XCTAssertEqual(controller.pdfView.document?.pageCount, 2)
            controller.openDocument(at: a)
        }
        XCTAssertEqual(try Data(contentsOf: output), savedBytes)
        let after = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual(after[.modificationDate] as? Date, savedAttributes[.modificationDate] as? Date)
        XCTAssertEqual(after[.systemFileNumber] as? NSNumber, savedAttributes[.systemFileNumber] as? NSNumber)
    }
    @MainActor func testResizableMergeSheetKeepsTableAndRecoveryControlsInsideContent() throws {
        _ = NSApplication.shared
        let sheet = PDFMergeSheetController()
        let window = try XCTUnwrap(sheet.window)
        XCTAssertTrue(window.styleMask.contains(.resizable), "Merge sheet must be expandable")
        let content = try XCTUnwrap(window.contentView)
        let scroll = try XCTUnwrap(sheet.table.enclosingScrollView)
        let before = scroll.frame.size
        window.setContentSize(NSSize(width: 1100, height: 700))
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(scroll.frame.width, before.width)
        XCTAssertGreaterThan(scroll.frame.height, before.height)
        XCTAssertTrue(scroll.hasHorizontalScroller)
        XCTAssertEqual(sheet.table.tableColumns.map(\.title), ["Order", "Name", "Size", "Location"])
        for column in sheet.table.tableColumns { XCTAssertTrue(column.resizingMask.contains(.userResizingMask)) }
        sheet.setSavedDestination(directory.appendingPathComponent("a very long output filename.pdf"))
        window.setContentSize(NSSize(width: 800, height: 520))
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.bounds.contains(sheet.mergeButton.frame))
        XCTAssertTrue(content.bounds.contains(sheet.countLabel.frame))
        XCTAssertGreaterThanOrEqual(sheet.mergeButton.frame.width, 175)
    }

    @MainActor func testRealSortControlUsesNaturalNamesMetadataStableTiesAndPreservesSelection() throws {
        _ = NSApplication.shared
        let sheet = PDFMergeSheetController()
        let ten = directory.appendingPathComponent("Sheet10.pdf")
        let two = directory.appendingPathComponent("Sheet2.pdf")
        let equal = directory.appendingPathComponent("Sheet3.pdf")
        let missing = directory.appendingPathComponent("missing.pdf")
        try Data(repeating: 0, count: 10).write(to: ten)
        try Data(repeating: 0, count: 2).write(to: two)
        try Data(repeating: 0, count: 2).write(to: equal)
        let old = Date(timeIntervalSince1970: 1000), new = Date(timeIntervalSince1970: 2000)
        for (url, date) in [(ten, new), (two, old), (equal, old)] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        sheet.addURLs([ten, two, equal, missing])
        sheet.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        sheet.setProcessing(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(sheet.list.urls, [ten, two, equal, missing])
        XCTAssertTrue(sheet.list.entries.allSatisfy { $0.metadata.size == nil }, "Metadata completion cannot mutate processing inputs")
        sheet.setProcessing(false)
        let popup = try XCTUnwrap(sheet.window?.contentView?.subviews.compactMap { $0 as? NSPopUpButton }.first, "Real Merge sheet needs a sort control")
        func sort(_ title: String, expected: [URL]) {
            popup.selectItem(withTitle: title)
            _ = popup.target?.perform(popup.action, with: popup)
            XCTAssertEqual(sheet.list.urls, expected, title)
            XCTAssertTrue(sheet.list.urls.indices.contains(sheet.table.selectedRow), "Selection remains present")
            if sheet.list.urls.indices.contains(sheet.table.selectedRow) {
                XCTAssertEqual(sheet.list.urls[sheet.table.selectedRow], ten, "Selection follows file identity")
            }
        }
        sort("Name A–Z", expected: [missing, two, equal, ten])
        sort("Name Z–A", expected: [ten, equal, two, missing])
        // Wait for real asynchronous file metadata, bounded without timing assertions.
        let deadline = Date().addingTimeInterval(3)
        repeat { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) } while Date() < deadline && !((sheet.tableView(sheet.table, viewFor: sheet.table.tableColumns[2], row: 0) as? NSTextField)?.stringValue.contains("10") ?? false)
        sort("Size smallest first", expected: [equal, two, ten, missing])
        sort("Size largest first", expected: [ten, equal, two, missing])
        sort("Modified oldest first", expected: [equal, two, ten, missing])
        sort("Modified newest first", expected: [ten, equal, two, missing])
        sheet.setProcessing(true)
        sort("Name A–Z", expected: [ten, equal, two, missing])
        XCTAssertFalse(popup.isEnabled)
        sheet.setProcessing(false)
        sort("Manual order", expected: [ten, equal, two, missing])
        let up = try XCTUnwrap(sheet.window?.contentView?.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Move Down" })
        up.performClick(nil)
        XCTAssertEqual(sheet.list.urls, [equal, ten, two, missing])
        sheet.setSavedDestination(directory.appendingPathComponent("saved.pdf"))
        sort("Name A–Z", expected: [equal, ten, two, missing])
        XCTAssertFalse(popup.isEnabled)
        let name = try XCTUnwrap(sheet.tableView(sheet.table, viewFor: sheet.table.tableColumns[1], row: 1) as? NSTextField)
        XCTAssertEqual(name.stringValue, ten.lastPathComponent)
        XCTAssertEqual(name.toolTip, ten.path)
    }

    @MainActor func testMergeSheetControlsReflectListAndBusyState() {
        _ = NSApplication.shared
        let sheet = PDFMergeSheetController()
        _ = sheet.window
        XCTAssertFalse(sheet.mergeButton.isEnabled)
        sheet.addURLs([directory.appendingPathComponent("a.pdf"), directory.appendingPathComponent("b.pdf")])
        XCTAssertEqual(sheet.table.numberOfRows, 2)
        XCTAssertTrue(sheet.mergeButton.isEnabled)
        XCTAssertEqual(sheet.countLabel.stringValue, "2 PDFs • merged in the order shown")
        sheet.setProcessing(true)
        XCTAssertFalse(sheet.mergeButton.isEnabled)
        XCTAssertFalse(sheet.addButton.isEnabled)
        sheet.setProcessing(false)
        XCTAssertTrue(sheet.mergeButton.isEnabled)
    }
}
