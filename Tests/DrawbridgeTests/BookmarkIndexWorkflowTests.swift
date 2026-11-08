import XCTest
import AppKit
import PDFKit
@testable import Drawbridge

@MainActor final class BookmarkIndexWorkflowTests: XCTestCase {
    func pump(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition())
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func input(_ dir: URL, items: [BookmarkIndexFixtures.Item] = [.init(title: "A101 Plan")]) throws -> URL {
        let url = dir.appendingPathComponent("Included.pdf")
        try BookmarkIndexFixtures.pdf(items).write(to: url)
        return url
    }
    func testDownloadsOnlyFixedNameAndReplaceCancel() throws {
        let source = try directory(), downloads = try directory()
        _ = try input(source)
        let output = downloads.appendingPathComponent("combined_bookmarks.csv")
        let old = Data("old output".utf8)
        for replace in [false, true] {
            try old.write(to: output)
            let workflow = BookmarkIndexWorkflow()
            var notices: [String] = [], confirmations = 0
            workflow.resolveDownloads = { downloads }
            workflow.confirmReplace = { url in
                confirmations += 1
                XCTAssertEqual(url, output)
                XCTAssertEqual(try? Data(contentsOf: output), old)
                return replace
            }
            workflow.notify = { notices.append($0) }
            workflow.start(folder: source)
            pump { !workflow.busy }
            XCTAssertEqual(confirmations, 1)
            XCTAssertEqual(try Data(contentsOf: output), replace ? Data("PDF,Title\nIncluded.pdf,A101 - Plan".utf8) : old)
            if replace { XCTAssertTrue(notices.first?.contains(output.path) == true) }
            else { XCTAssertEqual(notices, ["Canceled. No output was written."]) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), ["combined_bookmarks.csv"])
        }
    }
    func testUnavailableDownloadsFailsWithoutFallback() throws {
        let source = try directory(); _ = try input(source)
        let workflow = BookmarkIndexWorkflow()
        var notices: [String] = []
        workflow.resolveDownloads = { throw NSError(domain: "Downloads unavailable", code: 1) }
        workflow.notify = { notices.append($0) }
        workflow.start(folder: source)
        pump { !workflow.busy }
        XCTAssertTrue(notices.first?.contains("Downloads") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path), ["Included.pdf"])
    }
    func testFreshDownloadsWritesFixedFilenameWithoutConfirmation() throws {
        let source = try directory(), downloads = try directory(); _ = try input(source)
        let workflow = BookmarkIndexWorkflow()
        var notices: [String] = []
        workflow.resolveDownloads = { downloads }
        workflow.confirmReplace = { _ in XCTFail("No existing output"); return false }
        workflow.confirmHeaderOnly = { XCTFail("Nonempty output"); return false }
        workflow.notify = { notices.append($0) }
        workflow.start(folder: source)
        pump { !workflow.busy }
        let out = downloads.appendingPathComponent("combined_bookmarks.csv")
        XCTAssertEqual(try Data(contentsOf: out), Data("PDF,Title\nIncluded.pdf,A101 - Plan".utf8))
        XCTAssertTrue(notices.first?.contains(out.path) == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path), ["Included.pdf"])
    }
    func testMissingOrUnwritableDownloadsNeverFallsBack() throws {
        let source = try directory(), downloads = try directory(); _ = try input(source)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: downloads.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: downloads.path) }
        for target in [downloads, downloads.appendingPathComponent("missing")] {
            let workflow = BookmarkIndexWorkflow()
            var notices: [String] = []
            workflow.resolveDownloads = { target }
            workflow.notify = { notices.append($0) }
            workflow.start(folder: source)
            pump { !workflow.busy }
            XCTAssertTrue(notices.first?.contains("Downloads") == true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("combined_bookmarks.csv").path))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path), ["Included.pdf"])
    }
    func testHeaderOnlyCancellationDoesNotWrite() throws {
        let source = try directory(), downloads = try directory(); _ = try input(source, items: [])
        let workflow = BookmarkIndexWorkflow()
        var confirmations = 0
        workflow.resolveDownloads = { downloads }
        workflow.confirmHeaderOnly = { confirmations += 1; return false }
        workflow.notify = { _ in }
        workflow.start(folder: source)
        pump { !workflow.busy }
        XCTAssertEqual(confirmations, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: downloads.path).isEmpty)
    }
    func testFolderCancellationAndDuplicateAdmission() throws {
        let workflow = BookmarkIndexWorkflow()
        var completion: ((URL?) -> Void)?, picks = 0, saves = 0, notices = 0
        workflow.chooseFolder = { picks += 1; completion = $0 }
        workflow.resolveDownloads = { saves += 1; throw NSError(domain: "Unexpected destination resolution", code: 1) }
        workflow.notify = { _ in notices += 1 }
        workflow.showExtract(nil)
        XCTAssertTrue(workflow.busy)
        XCTAssertFalse(workflow.validateMenuItem(NSMenuItem()))
        workflow.showExtract(nil)
        workflow.start(folder: try directory())
        XCTAssertEqual(picks, 1)
        completion?(nil)
        XCTAssertFalse(workflow.busy)
        XCTAssertNil(workflow.result)
        XCTAssertEqual(saves, 0); XCTAssertEqual(notices, 0)
        XCTAssertTrue(workflow.validateMenuItem(NSMenuItem()))
    }
    func testProcessingCancellationDoesNotOfferSaveOrWrite() throws {
        let dir = try directory(), source = try input(dir), before = try Data(contentsOf: source)
        let workflow = BookmarkIndexWorkflow()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var notices: [String] = [], saves = 0
        workflow.onProcessingStarted = { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        workflow.resolveDownloads = { saves += 1; throw NSError(domain: "Unexpected destination resolution", code: 1) }
        workflow.notify = { notices.append($0) }
        workflow.start(folder: dir)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        workflow.cancel(nil)
        release.signal()
        pump { !workflow.busy }
        XCTAssertNil(workflow.result); XCTAssertEqual(saves, 0)
        XCTAssertEqual(notices, ["Canceled. No output was written."])
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["Included.pdf"])
    }
    func testCorruptPDFFailsWholeWorkflowWithoutSave() throws {
        let dir = try directory(), source = try input(dir)
        let before = try Data(contentsOf: source)
        try Data("corrupt".utf8).write(to: dir.appendingPathComponent("Z-Broken.pdf"))
        let workflow = BookmarkIndexWorkflow()
        var notices: [String] = [], saves = 0
        workflow.resolveDownloads = { saves += 1; throw NSError(domain: "Unexpected destination resolution", code: 1) }
        workflow.notify = { notices.append($0) }
        workflow.start(folder: dir)
        pump { !workflow.busy }
        XCTAssertNil(workflow.result); XCTAssertEqual(saves, 0)
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.contains("failed") == true)
        XCTAssertTrue(notices.first?.contains("Z-Broken.pdf") == true)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }
    func testReplaceCancellationPreservesExistingDestinationAndSources() throws {
        let dir = try directory(), source = try input(dir), before = try Data(contentsOf: source)
        let out = dir.appendingPathComponent("combined_bookmarks.csv"), sentinel = Data("existing output".utf8)
        try sentinel.write(to: out)
        let workflow = BookmarkIndexWorkflow()
        var notices: [String] = [], offers = 0
        workflow.resolveDownloads = { dir }
        workflow.confirmReplace = { destination in
            offers += 1
            XCTAssertTrue(workflow.busy)
            XCTAssertEqual(destination, out)
            return false
        }
        workflow.notify = { notices.append($0) }
        workflow.start(folder: dir)
        pump { !workflow.busy }
        XCTAssertEqual(offers, 1)
        XCTAssertEqual(notices, ["Canceled. No output was written."])
        XCTAssertEqual(try Data(contentsOf: out), sentinel)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix(".bookmark-index-") })
    }
    func testSaveFailureReportsFailureAndCleansStaging() throws {
        let dir = try directory(), source = try input(dir), before = try Data(contentsOf: source)
        let out = dir.appendingPathComponent("combined_bookmarks.csv")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let workflow = BookmarkIndexWorkflow()
        var notices: [String] = []
        workflow.resolveDownloads = { dir }
        workflow.confirmReplace = { _ in true }
        workflow.notify = { notices.append($0) }
        workflow.start(folder: dir)
        pump { !workflow.busy }
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.hasPrefix("Could not save bookmark index:") == true)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix(".bookmark-index-") })
    }
    func testNoBookmarksAllowsHeaderOnlySave() throws {
        let dir = try directory(); _ = try input(dir, items: [])
        let out = dir.appendingPathComponent("combined_bookmarks.csv"), workflow = BookmarkIndexWorkflow()
        var notices: [String] = []
        workflow.resolveDownloads = { dir }
        workflow.confirmHeaderOnly = {
            XCTAssertEqual(workflow.result?.rows, 0); XCTAssertEqual(workflow.result?.files, 1)
            return true
        }
        workflow.notify = { notices.append($0) }
        workflow.start(folder: dir)
        pump { !workflow.busy }
        XCTAssertEqual(try Data(contentsOf: out), Data("PDF,Title".utf8))
        XCTAssertTrue(notices.first?.contains("saved: 0 titles from 1 PDFs") == true)
    }
    func testMenuSuccessPreservesOpenDirtyDocumentWindowsAndRecentFiles() throws {
        _ = NSApplication.shared
        let dir = try directory(), source = try input(dir), original = try Data(contentsOf: source)
        let controller = MainViewController(); _ = controller.view
        // Hidden fixture: real loaded PDF and unsaved in-memory annotation, not visible UI qualification.
        let document = try XCTUnwrap(PDFDocument(data: original)), page = try XCTUnwrap(document.page(at: 0))
        controller.pdfView.document = document
        let annotation = PDFAnnotation(bounds: NSRect(x: 10, y: 10, width: 20, height: 20), forType: .square, withProperties: nil)
        annotation.contents = "Unsaved review note"; page.addAnnotation(annotation)
        controller.markupChangeVersion += 1
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller; window.isDocumentEdited = true
        defer { controller.pdfView.document = nil; window.contentViewController = nil; window.close() }
        XCTAssertTrue(controller.hasUnsavedChanges())
        let version = controller.markupChangeVersion, currentPage = controller.pdfView.currentPage
        let recent = NSDocumentController.shared.recentDocumentURLs
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let oldMenu = NSApp.mainMenu; defer { NSApp.mainMenu = oldMenu }
        let delegate = AppDelegate(); delegate.setupMainMenu(controller: controller)
        let item = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Extract Bookmark Index…"))
        let workflow = try XCTUnwrap(item.target as? BookmarkIndexWorkflow), out = dir.appendingPathComponent("combined_bookmarks.csv")
        try Data("excluded corrupt PDF".utf8).write(to: dir.appendingPathComponent("ARCH.pdf"))
        var notices: [String] = []
        workflow.chooseFolder = { $0(dir) }
        workflow.resolveDownloads = { dir }
        workflow.notify = { notices.append($0) }
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        pump { !workflow.busy }
        XCTAssertEqual(try Data(contentsOf: out), Data("PDF,Title\nIncluded.pdf,A101 - Plan".utf8))
        XCTAssertEqual(notices.count, 1); XCTAssertTrue(notices.first?.contains("1 excluded (ARCH)") == true)
        XCTAssertTrue(controller.pdfView.document === document)
        XCTAssertTrue(controller.pdfView.currentPage === currentPage)
        XCTAssertTrue(page.annotations.contains { $0 === annotation })
        XCTAssertEqual(annotation.contents, "Unsaved review note")
        XCTAssertEqual(controller.markupChangeVersion, version); XCTAssertTrue(controller.hasUnsavedChanges())
        XCTAssertTrue(window.isDocumentEdited); XCTAssertFalse(window.isVisible)
        XCTAssertEqual(NSDocumentController.shared.recentDocumentURLs, recent)
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windows)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testActualMenuRetainsIndependentTargetWithoutDocumentAndRebuild() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate(), controller = MainViewController()
        let old = NSApp.mainMenu
        defer { NSApp.mainMenu = old }
        delegate.setupMainMenu(controller: controller)
        let file = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "File")?.submenu)
        let item = try XCTUnwrap(file.item(withTitle: "Extract Bookmark Index…"))
        let workflow = try XCTUnwrap(item.target as? BookmarkIndexWorkflow)
        XCTAssertEqual(item.action, #selector(BookmarkIndexWorkflow.showExtract(_:)))
        XCTAssertTrue(workflow.validateMenuItem(item))
        var pickCount = 0
        workflow.chooseFolder = { completion in pickCount += 1; completion(nil) }
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(pickCount, 1)
        XCTAssertFalse(workflow.busy)
        delegate.setupMainMenu(controller: controller)
        XCTAssertTrue(NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Extract Bookmark Index…")?.target === workflow)
    }
    func testNoPDFAndAllExcludedNeverOfferSave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workflow = BookmarkIndexWorkflow()
        var notices: [String] = [], saves = 0
        workflow.notify = { notices.append($0) }
        workflow.resolveDownloads = { saves += 1; return dir }
        workflow.start(folder: dir)
        pump { !notices.isEmpty }
        XCTAssertFalse(workflow.busy)
        XCTAssertEqual(saves, 0)
        XCTAssertTrue(notices.first?.contains("No PDFs") == true)
        try Data("invalid excluded PDF".utf8).write(to: dir.appendingPathComponent("Research.pdf"))
        workflow.start(folder: dir)
        pump { notices.count == 2 }
        XCTAssertTrue(notices.last?.contains("excluded") == true)
        XCTAssertEqual(saves, 0)
    }
}
