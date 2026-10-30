import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class MultiDocumentSplitTests: XCTestCase {
    private func fixture(windowDelegate: NSWindowDelegate? = nil, _ body: (MainViewController, NSWindow, [URL]) throws -> Void) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try [6, 4, 5].enumerated().map { index, count -> URL in
            let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 600, height: 800)
            let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
            for _ in 0..<count { context.beginPDFPage(nil); context.endPDFPage() }; context.closePDF()
            let url = directory.appendingPathComponent("document-\(index).pdf")
            try (data as Data).write(to: url); return url
        }
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        // Match app construction: delegate precedes any content undo lookup.
        window.delegate = windowDelegate
        window.contentViewController = controller
        defer { withExtendedLifetime(windowDelegate) {}; window.makeFirstResponder(nil); window.contentViewController = nil }
        controller.openDocument(at: urls[1]); controller.openDocument(at: urls[0])
        window.layoutIfNeeded()
        try body(controller, window, urls)
        XCTAssertFalse(window.isVisible)
    }
    private func select(_ c: MainViewController, _ url: URL) {
        let button = NSButton(); button.identifier = NSUserInterfaceItemIdentifier(url.path)
        XCTAssertTrue(c.tryToPerform(NSSelectorFromString("selectDocumentTab:"), with: button))
    }
    private func index(_ pane: MarkupPDFView) -> Int { pane.currentPage.flatMap { pane.document?.index(for: $0) } ?? -1 }
    private func splitDifferent(_ c: MainViewController, _ w: NSWindow, _ urls: [URL]) throws -> (MarkupPDFView, MarkupPDFView) {
        let left = c.pdfView; c.commandToggleSplitView(nil); w.layoutIfNeeded()
        let right = try XCTUnwrap(c.secondaryPDFView)
        c.activatePDFPane(right); select(c, urls[1]); w.layoutIfNeeded()
        return (left, right)
    }
    private func pump(_ seconds: TimeInterval = 0.08) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    }

    func testClosingEitherDifferentDocumentPaneRetainsDirtyDocumentSession() throws {
        for closeActive in [false,true] {
            try fixture { c,w,urls in
                let (left,right)=try splitDifferent(c,w,urls)
                let rightDocument=try XCTUnwrap(right.document)
                right.rectangleMarkup.canEdit={true}
                let mark=try XCTUnwrap(right.rectangleMarkup.create(on:try XCTUnwrap(right.currentPage),bounds:CGRect(x:30,y:30,width:80,height:60),kind:.rectangle))
                c.markupChangeVersion += 1;w.isDocumentEdited=true
                let closed=closeActive ? right : left,kept=closeActive ? left : right
                let keptDocument=kept.document,keptIndex=index(kept),keptScale=kept.scaleFactor
                let container=try XCTUnwrap(closed.superview as? PDFPaneContainerView)
                container.closeButton.performClick(nil);w.layoutIfNeeded()
                XCTAssertNil(c.secondaryPDFView);XCTAssertTrue(c.pdfView === kept)
                XCTAssertTrue(c.pdfView.document === keptDocument);XCTAssertEqual(index(c.pdfView),keptIndex)
                XCTAssertEqual(c.pdfView.scaleFactor,keptScale,accuracy:0.01)
                select(c,urls[1]);w.layoutIfNeeded()
                XCTAssertTrue(c.pdfView.document === rightDocument)
                XCTAssertTrue(rightDocument.page(at:0)?.annotations.contains {$0 === mark} == true)
                XCTAssertTrue(c.hasUnsavedChanges())
            }
        }
    }

    func testSaveAsRejectsVisibleDirtyRetainedDestinationBeforeWriting() throws {
        try assertSaveAsCollisionPreservesSession(hidden: false)
    }

    func testSaveAsRejectsHiddenDirtyRetainedDestinationBeforeWriting() throws {
        try assertSaveAsCollisionPreservesSession(hidden: true)
    }

    private func assertSaveAsCollisionPreservesSession(hidden: Bool) throws {
        try fixture { c, w, urls in
            let (left, right) = try splitDifferent(c, w, urls)
            let targetDocument = try XCTUnwrap(right.document)
            let targetMarkup = right.rectangleMarkup
            let targetCoordinator = c.persistenceCoordinator
            let page = try XCTUnwrap(right.currentPage)
            targetMarkup.canEdit = { true }
            targetMarkup.undo.beginUndoGrouping()
            let annotation = try XCTUnwrap(targetMarkup.create(on: page, bounds: CGRect(x: 40, y: 40, width: 80, height: 80), kind: .rectangle))
            targetMarkup.undo.endUndoGrouping()
            c.markupChangeVersion = 7; w.isDocumentEdited = true
            let targetID = ObjectIdentifier(targetDocument)
            c.explicitScaleSetDocumentID = targetID; c.explicitScaleSetPageIndexes = [2]
            c.pendingScaleReminderSuppressionDocumentID = targetID
            c.pendingScaleReminderSuppressionPageIndex = 2; c.pendingScaleReminderSuppressionOneShot = true
            if hidden { select(c, urls[2]) }
            c.activatePDFPane(left)
            let sourceDocument = left.document
            let sourceCoordinator = c.persistenceCoordinator
            let tabs = c.sessionDocumentURLs
            let before = try urls.map { try Data(contentsOf: $0) }
            let sidecar = c.sidecarURL(for: urls[1])
            let sidecarBytes = Data("retained target sidecar".utf8)
            try sidecarBytes.write(to: sidecar)
            var errors: [String] = []
            c.saveErrorPresenter = { errors.append($0); return .alertFirstButtonReturn }
            var result: Bool?
            c.persistDocument(to: urls[1], adoptAsPrimaryDocument: true, busyMessage: "Saving", showBusyOverlay: false) { result = $0 }
            XCTAssertEqual(result, false, "Collision must be rejected synchronously, before queuing I/O")
            XCTAssertFalse(c.isSavingDocumentOperation)
            XCTAssertFalse(sourceCoordinator.isManualSaveInFlight)
            XCTAssertFalse(c.queuedFastEmbeddedSave)
            // Drain an incorrectly admitted real save too, so RED leaves no writer behind.
            let deadline = Date().addingTimeInterval(15)
            while result == nil && Date() < deadline { pump(0.01) }
            XCTAssertEqual(result, false)
            XCTAssertEqual(errors.count, 1)
            XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
            XCTAssertEqual(try Data(contentsOf: sidecar), sidecarBytes)
            XCTAssertEqual(c.sessionDocumentURLs, tabs)
            XCTAssertEqual(c.openDocumentURL, urls[0]); XCTAssertTrue(c.pdfView === left)
            XCTAssertTrue(left.document === sourceDocument)
            select(c, urls[1])
            XCTAssertTrue(c.pdfView.document === targetDocument)
            XCTAssertTrue(c.pdfView.rectangleMarkup === targetMarkup)
            XCTAssertTrue(c.persistenceCoordinator === targetCoordinator)
            XCTAssertTrue(c.hasUnsavedChanges()); XCTAssertEqual(c.markupChangeVersion, 7)
            XCTAssertEqual(c.explicitScaleSetDocumentID, targetID); XCTAssertEqual(c.explicitScaleSetPageIndexes, [2])
            XCTAssertEqual(c.pendingScaleReminderSuppressionDocumentID, targetID)
            XCTAssertEqual(c.pendingScaleReminderSuppressionPageIndex, 2)
            XCTAssertTrue(c.pendingScaleReminderSuppressionOneShot)
            XCTAssertTrue(page.annotations.contains { $0 === annotation })
            XCTAssertTrue(targetMarkup.undo.canUndo)
            targetMarkup.undo.undo(); XCTAssertFalse(page.annotations.contains { $0 === annotation })
            targetMarkup.undo.redo(); XCTAssertTrue(page.annotations.contains { $0 === annotation })
        }
    }

    func testAliasRetirementRejectsDifferentRetainedOwnerWithoutMutation() throws {
        try fixture { c, w, urls in
            let (left, right) = try splitDifferent(c, w, urls)
            let target = right.document
            c.activatePDFPane(left)
            let tabs = c.sessionDocumentURLs
            c.retireSessionAliases(for: try XCTUnwrap(left.document), adopting: urls[1], origin: urls[0])
            XCTAssertEqual(c.sessionDocumentURLs, tabs)
            select(c, urls[1])
            XCTAssertEqual(c.openDocumentURL, urls[1]); XCTAssertTrue(c.pdfView === right)
            XCTAssertTrue(c.pdfView.document === target)
        }
    }

    func testSaveAsRetiresOldSessionAliasThroughRealCompletion() throws {
        try fixture { c, w, urls in
            let (left, right) = try splitDifferent(c, w, urls)
            c.activatePDFPane(left); c.activatePDFPane(right)
            let document = right.document
            let destination = urls[1].deletingLastPathComponent().appendingPathComponent("adopted.pdf")
            var result: Bool?
            c.persistDocument(to: destination, adoptAsPrimaryDocument: true, busyMessage: "Saving", showBusyOverlay: false) { result = $0 }
            let end = Date().addingTimeInterval(15)
            while result == nil && Date() < end { pump(0.01) }
            XCTAssertEqual(result, true)
            XCTAssertFalse(c.sessionDocumentURLs.contains(urls[1]), "Save As must retire the old live-session tab")
            c.activatePDFPane(left); select(c, destination)
            XCTAssertEqual(c.openDocumentURL, destination); XCTAssertTrue(c.pdfView.document === document)
            c.openDocument(at: urls[1])
            XCTAssertFalse(c.pdfView.document === document, "Reopened original must be an independent editing session")
        }
    }

    func testAwayAndBackSerializesActualAutosaveWritesAndProtectsPostCleanEdit() throws {
        try fixture { c, w, urls in
            let (left, right) = try splitDifferent(c, w, urls)
            var work: [@Sendable () -> Void] = []
            c.autosaveWorkScheduler = { work.append($0) }
            c.hasPromptedForInitialMarkupSaveCopy = true
            c.markupChangeVersion = 9; w.isDocumentEdited = true
            c.performAutosaveNow()
            c.activatePDFPane(left); c.activatePDFPane(right)
            c.markupChangeVersion = 10; w.isDocumentEdited = true
            c.performAutosaveNow()
            XCTAssertEqual(work.count, 1, "Returning to a session must not allow a second writer")
            // Also exercise the unsafe legacy reverse-completion ordering if present.
            if work.count > 1 { work[1](); pump(); c.markupChangeVersion = 1; w.isDocumentEdited = true }
            work[0](); pump()
            XCTAssertTrue(c.hasUnsavedChanges(), "A stale completion cannot clean a newer edit")
            XCTAssertFalse(c.persistenceCoordinator.autosaveInFlight)
            var prompts = 0
            c.unsavedChangesResponse = { prompts += 1; return .alertThirdButtonReturn }
            XCTAssertFalse(c.confirmAllDocumentsForClose()); XCTAssertEqual(prompts, 1)
            c.performAutosaveNow(); XCTAssertEqual(work.count, 2)
            work[1](); pump()
            XCTAssertFalse(c.hasUnsavedChanges(), "The latest real completion may clean its own revision")
            c.markupChangeVersion = 1; w.isDocumentEdited = true
            XCTAssertTrue(c.hasUnsavedChanges())
        }
    }

    func testReturningDirtySessionRearmsDeferredAutosaveWithoutAnotherEdit() throws {
        try fixture { c, w, urls in
            let (left, right) = try splitDifferent(c, w, urls)
            c.persistenceCoordinator = DocumentPersistenceCoordinator(autosaveInterval: 0.03)
            c.hasPromptedForInitialMarkupSaveCopy = true
            c.markupChangeVersion = 1; w.isDocumentEdited = true
            c.scheduleAutosave()
            c.activatePDFPane(left); c.activatePDFPane(right)
            pump(0.2)
            XCTAssertFalse(c.hasUnsavedChanges(), "Restoration must rearm the cancelled metadata autosave")
            XCTAssertTrue(FileManager.default.fileExists(atPath: c.sidecarURL(for: urls[1]).path))
        }
    }

    func testTabReplacementKeepsOldDocumentAndIndependentEditingSessions() throws {
        try fixture { c, w, urls in
            let original = try XCTUnwrap(c.pdfView.document)
            let (left, right) = try splitDifferent(c, w, urls)
            XCTAssertNotNil(c.secondaryPDFView, "Choosing another tab must preserve the split")
            XCTAssertTrue(left.document === original, "The other pane must keep the canonical original")
            XCTAssertEqual(right.document?.pageCount, 4)
            XCTAssertFalse(left.rectangleMarkup === right.rectangleMarkup)
            c.activatePDFPane(left)
            XCTAssertEqual(c.openDocumentURL, urls[0]); XCTAssertTrue(c.pdfView.document === original)
            XCTAssertEqual(right.document?.pageCount, 4)
        }
    }
    func testClickingAlreadyVisibleTabFocusesItsPaneAndControlTabPreservesSplit() throws {
        try fixture { c, w, urls in
            let (left, right) = try splitDifferent(c, w, urls)
            select(c, urls[0]); XCTAssertTrue(c.pdfView === left)
            XCTAssertTrue(w.firstResponder === left)
            c.commandCycleNextDocument(nil)
            XCTAssertTrue(c.pdfView === right); XCTAssertNotNil(c.secondaryPDFView)
            c.commandCyclePreviousDocument(nil); XCTAssertTrue(c.pdfView === left)
        }
    }
    func testInactiveDocumentEditsAndUndoSurvivePaneActivationAndCollapse() throws {
        try fixture { c, w, urls in
            let (left, right) = try splitDifferent(c, w, urls)
            guard c.secondaryPDFView != nil else { XCTFail("Split collapsed"); return }
            let rightDocument = try XCTUnwrap(right.document)
            let session = right.rectangleMarkup
            let page = try XCTUnwrap(right.currentPage)
            session.canEdit = { true }
            session.undo.beginUndoGrouping()
            _ = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 50, y: 50, width: 80, height: 80), kind: .rectangle))
            session.undo.endUndoGrouping()
            XCTAssertTrue(session.hasUnsavedChanges)
            c.activatePDFPane(left)
            XCTAssertFalse(c.hasUnsavedChanges())
            XCTAssertFalse(left.rectangleMarkup.undo.canUndo, "Undo must not cross document ownership")
            c.activatePDFPane(right)
            XCTAssertTrue(c.hasUnsavedChanges()); XCTAssertTrue(right.document === rightDocument)
            c.collapsePDFSplit()
            XCTAssertTrue(c.pdfView.rectangleMarkup === session)
            session.undo.undo(); XCTAssertTrue(page.annotations.isEmpty)
            session.undo.redo(); XCTAssertEqual(page.annotations.count, 1)
        }
    }
    func testSyncToggleTracksPagesBothDirectionsWithOffsetAndUnequalLengths() throws {
        try fixture { c, w, urls in
            let (left, right) = try splitDifferent(c, w, urls)
            guard c.secondaryPDFView != nil else { XCTFail("Split collapsed"); return }
            c.activatePDFPane(left)
            left.go(to: left.document!.page(at: 1)!); right.go(to: right.document!.page(at: 0)!)
            XCTAssertTrue(c.tryToPerform(NSSelectorFromString("commandToggleSyncDocuments:"), with: nil))
            left.go(to: left.document!.page(at: 3)!)
            XCTAssertEqual(index(right), 2)
            right.go(to: right.document!.page(at: 1)!)
            XCTAssertEqual(index(left), 2)
            left.go(to: left.document!.page(at: 5)!)
            XCTAssertEqual(index(right), 3, "Short peer clamps at its last sheet")
            left.go(to: left.document!.page(at: 4)!)
            XCTAssertEqual(index(right), 3, "Clamping must not replace the original page offset")
            left.go(to: left.document!.page(at: 2)!)
            XCTAssertEqual(index(right), 1)
            _ = c.tryToPerform(NSSelectorFromString("commandToggleSyncDocuments:"), with: nil)
            left.go(to: left.document!.page(at: 0)!); XCTAssertEqual(index(right), 1)
        }
    }
    func testSyncZoomPanAndMenuCheckedState() throws {
        try fixture { c, w, urls in
            let (left, right) = try splitDifferent(c, w, urls)
            guard c.secondaryPDFView != nil else { XCTFail("Split collapsed"); return }
            left.autoScales = false; right.autoScales = false
            left.scaleFactor = 2; right.scaleFactor = 1
            let item = NSMenuItem(title: "Sync Documents", action: NSSelectorFromString("commandToggleSyncDocuments:"), keyEquivalent: "")
            XCTAssertTrue(c.validateMenuItem(item)); XCTAssertEqual(item.state, .off)
            XCTAssertTrue(c.tryToPerform(item.action!, with: nil))
            XCTAssertTrue(c.validateMenuItem(item)); XCTAssertEqual(item.state, .on)
            left.scaleFactor = 2.5; XCTAssertEqual(right.scaleFactor, 2.5, accuracy: 0.001)
            right.scaleFactor = 3; XCTAssertEqual(left.scaleFactor, 3, accuracy: 0.001)
            left.centerViewport(on: NSPoint(x: 300, y: 400)); left.onViewportChanged?()
            let a = try XCTUnwrap(left.captureTabViewState()).viewportCenter
            let b = try XCTUnwrap(right.captureTabViewState()).viewportCenter
            XCTAssertEqual(a.x, b.x, accuracy: 1); XCTAssertEqual(a.y, b.y, accuracy: 1)
            _ = c.tryToPerform(item.action!, with: nil)
            right.scaleFactor = 1.5; XCTAssertEqual(left.scaleFactor, 3, accuracy: 0.001)
        }
    }
    func testSyncMenuWiringAndLifecycleReset() throws {
        try fixture { c, w, urls in
            let oldMenu = NSApp.mainMenu
            defer { NSApp.mainMenu = oldMenu }
            AppDelegate().setupMainMenu(controller: c)
            let menu = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "View")?.submenu)
            let item = try XCTUnwrap(menu.item(withTitle: "Sync Documents"))
            XCTAssertTrue(item.target === c)
            XCTAssertEqual(item.action, NSSelectorFromString("commandToggleSyncDocuments:"))
            XCTAssertFalse(c.validateMenuItem(item)); XCTAssertEqual(item.state, .off)
            c.commandToggleSplitView(nil); w.layoutIfNeeded()
            let peer = try XCTUnwrap(c.secondaryPDFView)
            XCTAssertTrue(c.validateMenuItem(item))
            XCTAssertTrue(c.tryToPerform(item.action!, with: nil))
            c.pdfView.go(to: c.pdfView.document!.page(at: 2)!)
            XCTAssertEqual(index(peer), 2, "Same-document split syncs its detached presentation")
            c.activatePDFPane(peer)
            c.pdfView.go(to: c.pdfView.document!.page(at: 3)!)
            XCTAssertEqual(index(c.secondaryPDFView!), 3, "Activation must preserve synchronization")
            select(c, urls[1]); w.layoutIfNeeded()
            XCTAssertTrue(c.validateMenuItem(item)); XCTAssertEqual(item.state, .off, "New pair must not inherit old offset")
            _ = c.tryToPerform(item.action!, with: nil)
            c.collapsePDFSplit()
            XCTAssertFalse(c.validateMenuItem(item)); XCTAssertEqual(item.state, .off)
            c.commandToggleSplitView(nil)
            XCTAssertTrue(c.validateMenuItem(item)); XCTAssertEqual(item.state, .off)
        }
    }

    func testBusySaveBlocksTabSelectionCyclingAndDirectReplacement() throws {
        try fixture { c, w, urls in
            let (_, right) = try splitDifferent(c, w, urls)
            let document = right.document
            c.beginBusyIndicator("Saving", lockInteraction: false)
            defer { c.endBusyIndicator() }
            select(c, urls[2]); XCTAssertEqual(c.openDocumentURL, urls[1])
            c.commandCyclePreviousDocument(nil); XCTAssertEqual(c.openDocumentURL, urls[1])
            c.openDocument(at: urls[2]); XCTAssertEqual(c.openDocumentURL, urls[1])
            XCTAssertTrue(c.pdfView === right); XCTAssertTrue(right.document === document)
            XCTAssertNotNil(c.secondaryPDFView)
        }
    }

    func testInactiveDirtyCloseAllCancelDiscardAndFailedSaveRestoreFocus() throws {
        for response: NSApplication.ModalResponse in [.alertThirdButtonReturn, .alertSecondButtonReturn, .alertFirstButtonReturn] {
            try fixture { c, w, urls in
                let (left, right) = try splitDifferent(c, w, urls)
                w.isDocumentEdited = true
                c.activatePDFPane(left)
                var prompted: [URL] = []; var saves: [URL] = []
                c.unsavedChangesResponse = { prompted.append(c.openDocumentURL!); return response }
                c.saveForClosePrompt = { saves.append(c.openDocumentURL!); return false }
                XCTAssertEqual(c.confirmAllDocumentsForClose(), response == .alertSecondButtonReturn)
                XCTAssertEqual(prompted, [urls[1]])
                XCTAssertEqual(saves, response == .alertFirstButtonReturn ? [urls[1]] : [])
                XCTAssertTrue(c.pdfView === left); XCTAssertTrue(c.secondaryPDFView === right)
                XCTAssertEqual(c.openDocumentURL, urls[0]); XCTAssertFalse(c.hasUnsavedChanges())
                c.activatePDFPane(right); XCTAssertTrue(c.hasUnsavedChanges())
            }
        }
    }

    func testHiddenDirtyCloseCancelAndHiddenCleanClosePreserveUnrelatedSplit() throws {
        try fixture { c, w, urls in
            let (left, right) = try splitDifferent(c, w, urls)
            w.isDocumentEdited = true
            select(c, urls[2]) // B is now hidden; A/C stay visible.
            let replacement = right.document
            c.unsavedChangesResponse = { .alertThirdButtonReturn }
            c.closeDocumentTab(at: urls[1])
            XCTAssertTrue(c.pdfView === right); XCTAssertTrue(right.document === replacement)
            XCTAssertTrue(c.secondaryPDFView === left); XCTAssertTrue(c.sessionDocumentURLs.contains(urls[1]))
            select(c, urls[1]); w.isDocumentEdited = false
            select(c, urls[2])
            c.closeDocumentTab(at: urls[1])
            XCTAssertTrue(c.pdfView === right); XCTAssertTrue(right.document === replacement)
            XCTAssertTrue(c.secondaryPDFView === left); XCTAssertFalse(c.sessionDocumentURLs.contains(urls[1]))
        }
    }

    func testWindowUndoManagerFollowsActiveIndependentSession() throws {
        let delegate = AppDelegate()
        defer { withExtendedLifetime(delegate) {} }
        try fixture(windowDelegate: delegate) { c, w, urls in
            let (left, right) = try splitDifferent(c, w, urls)
            let session = right.rectangleMarkup, page = try XCTUnwrap(right.currentPage)
            session.undo.beginUndoGrouping()
            _ = session.create(on: page, bounds: CGRect(x: 40, y: 40, width: 80, height: 80), kind: .rectangle)
            session.undo.endUndoGrouping()
            XCTAssertTrue(w.undoManager === session.undo)
            c.activatePDFPane(left)
            XCTAssertTrue(w.undoManager === left.rectangleMarkup.undo)
            XCTAssertFalse(w.undoManager?.canUndo ?? true)
            c.activatePDFPane(right)
            w.undoManager?.undo(); XCTAssertTrue(page.annotations.isEmpty)
            w.undoManager?.redo(); XCTAssertEqual(page.annotations.count, 1)
        }
    }

    func testDeferredAutosaveCompletionCannotCleanAnotherDocument() throws {
        try fixture { c, w, urls in
            let (left, _) = try splitDifferent(c, w, urls)
            c.hasPromptedForInitialMarkupSaveCopy = true
            c.markupChangeVersion = 9; w.isDocumentEdited = true
            c.performAutosaveNow()
            c.activatePDFPane(left)
            c.markupChangeVersion = 1; w.isDocumentEdited = true
            let deadline = Date().addingTimeInterval(0.5)
            while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertTrue(c.hasUnsavedChanges(), "Old B autosave must not clear A's dirty bit")
            XCTAssertEqual(c.markupChangeVersion, 1)
        }
    }

    func testRetainedBookmarkAndScaleReminderMetadataDoesNotLeak() throws {
        try fixture { c, w, urls in
            let (left, right) = try splitDifferent(c, w, urls)
            let id = ObjectIdentifier(try XCTUnwrap(right.document))
            c.explicitScaleSetDocumentID = id; c.explicitScaleSetPageIndexes = [2]
            c.pendingScaleReminderSuppressionDocumentID = id
            c.pendingScaleReminderSuppressionPageIndex = 2; c.pendingScaleReminderSuppressionOneShot = true
            c.activatePDFPane(left)
            XCTAssertNotEqual(c.explicitScaleSetDocumentID, id)
            XCTAssertTrue(c.explicitScaleSetPageIndexes.isEmpty)
            XCTAssertNotEqual(c.pendingScaleReminderSuppressionDocumentID, id)
            c.activatePDFPane(right)
            XCTAssertEqual(c.explicitScaleSetDocumentID, id); XCTAssertEqual(c.explicitScaleSetPageIndexes, [2])
            XCTAssertEqual(c.pendingScaleReminderSuppressionPageIndex, 2)
            XCTAssertTrue(c.pendingScaleReminderSuppressionOneShot)
        }
    }

    func testClosingVisibleInactiveTabKeepsSurvivorAndRemovesSplit() throws {
        try fixture { c, w, urls in
            let (_, right) = try splitDifferent(c, w, urls)
            let survivor = right.document
            c.closeDocumentTab(at: urls[0])
            XCTAssertNil(c.secondaryPDFView); XCTAssertTrue(c.pdfView === right)
            XCTAssertTrue(right.document === survivor); XCTAssertEqual(c.openDocumentURL, urls[1])
        }
    }
}
