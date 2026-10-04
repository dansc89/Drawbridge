import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var mainViewController: MainViewController?
    private var pendingOpenURLs: [URL] = []
    private var recentFiles: [URL] = []
    private let recentFilesDefaultsKey = "DrawbridgeRecentFiles"
    private let restoreLastDocumentDefaultsKey = "DrawbridgeRestoreLastDocument"
    private let maxRecentFiles = 10
    private let minimumSupportedMacOSVersion = "13.0"
    private var isWaitingForPDFWriteBeforeTermination = false
    private var terminationWaitStartedAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let launchWidth = min(max(1420, visibleFrame.width * 0.94), visibleFrame.width * 0.99)
        let launchHeight = min(max(820, visibleFrame.height * 0.88), visibleFrame.height * 0.96)
        let launchRect = NSRect(
            x: visibleFrame.midX - launchWidth * 0.5,
            y: visibleFrame.midY - launchHeight * 0.5,
            width: launchWidth,
            height: launchHeight
        ).integral
        let window = NSWindow(
            contentRect: launchRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Drawbridge"
        window.styleMask.remove(.fullSizeContentView)
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = true
        window.alphaValue = 1.0
        window.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        window.isMovableByWindowBackground = false
        let mainViewController = MainViewController()
        loadRecentFiles()
        mainViewController.onDocumentOpened = { [weak self] url in
            guard let self else { return }
            self.recordRecentFile(url)
            if let controller = self.mainViewController {
                self.setupMainMenu(controller: controller)
            }
        }
        window.contentViewController = mainViewController
        window.toolbar = mainViewController.makeToolbar()
        window.toolbar?.showsBaselineSeparator = true
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor
        window.contentView?.superview?.wantsLayer = true
        window.contentView?.superview?.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor
        window.delegate = self
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.minSize = NSSize(width: 1360, height: 700)
        window.maxSize = NSSize(width: 20000, height: 20000)
        window.setFrame(launchRect, display: true)
        window.makeKeyAndOrderFront(nil)
        window.center()

        self.window = window
        self.mainViewController = mainViewController
        setupMainMenu(controller: mainViewController)
        NSApp.activate(ignoringOtherApps: true)
        flushPendingOpenURLs()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = mainViewController else { return .terminateNow }
        guard controller.confirmDiscardUnsavedChangesIfNeeded() else { return .terminateCancel }
        guard controller.hasPendingPDFWriteForTermination() else { return .terminateNow }
        beginWaitingForPDFWriteBeforeTermination(controller: controller)
        return .terminateLater
    }

    private func beginWaitingForPDFWriteBeforeTermination(controller: MainViewController) {
        guard !isWaitingForPDFWriteBeforeTermination else { return }
        isWaitingForPDFWriteBeforeTermination = true
        terminationWaitStartedAt = Date()
        pollPDFWriteBeforeTermination(controller: controller)
    }

    private func pollPDFWriteBeforeTermination(controller: MainViewController) {
        let timedOut = terminationWaitStartedAt.map { Date().timeIntervalSince($0) >= 120 } ?? false
        guard controller.hasPendingPDFWriteForTermination(), !timedOut else {
            isWaitingForPDFWriteBeforeTermination = false
            terminationWaitStartedAt = nil
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak controller] in
            guard let self, let controller else {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            self.pollPDFWriteBeforeTermination(controller: controller)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let controller = mainViewController else { return true }
        return controller.confirmDiscardUnsavedChangesIfNeeded()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handleOpenRequests(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        handleOpenRequests(filenames.map(URL.init(fileURLWithPath:)))
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        handleOpenRequests([URL(fileURLWithPath: filename)])
        return true
    }

    @objc private func openRecentFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              let controller = mainViewController else { return }
        controller.openDocumentFromExternalURL(url)
    }

    @objc private func clearRecentFiles(_ sender: Any?) {
        recentFiles = []
        saveRecentFiles()
        if let controller = mainViewController {
            setupMainMenu(controller: controller)
        }
    }

    private func recordRecentFile(_ url: URL) {
        let normalized = url.standardizedFileURL
        recentFiles.removeAll { $0.standardizedFileURL == normalized }
        recentFiles.insert(normalized, at: 0)
        if recentFiles.count > maxRecentFiles {
            recentFiles = Array(recentFiles.prefix(maxRecentFiles))
        }
        saveRecentFiles()
    }

    private func loadRecentFiles() {
        let paths = UserDefaults.standard.stringArray(forKey: recentFilesDefaultsKey) ?? []
        recentFiles = paths.map(URL.init(fileURLWithPath:)).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func saveRecentFiles() {
        UserDefaults.standard.set(recentFiles.map(\.path), forKey: recentFilesDefaultsKey)
    }

    private func setupMainMenu(controller: MainViewController) {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        appItem.title = "Drawbridge"
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let aboutItem = appMenu.addItem(withTitle: "About Drawbridge", action: #selector(showAboutPanel(_:)), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        let shortcutItem = appMenu.addItem(withTitle: "Keyboard Shortcuts…", action: #selector(MainViewController.commandKeyboardShortcuts(_:)), keyEquivalent: ",")
        shortcutItem.target = controller
        let prefsItem = appMenu.addItem(withTitle: "Performance Settings…", action: #selector(MainViewController.commandPerformanceSettings(_:)), keyEquivalent: "")
        prefsItem.target = controller
        appMenu.addItem(NSMenuItem.separator())
        let hideItem = appMenu.addItem(withTitle: "Hide Drawbridge", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        let hideOthersItem = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        let showAllItem = appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        showAllItem.target = NSApp
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Drawbridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        fileItem.title = "File"
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open PDF...", action: #selector(MainViewController.commandOpen(_:)), keyEquivalent: "o").target = controller
        fileMenu.addItem(withTitle: "Close", action: #selector(MainViewController.commandCloseDocument(_:)), keyEquivalent: "w").target = controller
        let openRecentRoot = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let openRecentMenu = NSMenu(title: "Open Recent")
        if recentFiles.isEmpty {
            let emptyItem = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            openRecentMenu.addItem(emptyItem)
        } else {
            for url in recentFiles {
                let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentFile(_:)), keyEquivalent: "")
                item.representedObject = url
                item.target = self
                openRecentMenu.addItem(item)
            }
            openRecentMenu.addItem(NSMenuItem.separator())
            let clearItem = NSMenuItem(title: "Clear Menu", action: #selector(clearRecentFiles(_:)), keyEquivalent: "")
            clearItem.target = self
            openRecentMenu.addItem(clearItem)
        }
        openRecentRoot.submenu = openRecentMenu
        fileMenu.addItem(openRecentRoot)
        fileMenu.addItem(withTitle: "Save", action: #selector(MainViewController.commandSave(_:)), keyEquivalent: "s").target = controller
        let saveCopyItem = fileMenu.addItem(withTitle: "Save As PDF...", action: #selector(MainViewController.commandSaveCopy(_:)), keyEquivalent: "S")
        saveCopyItem.keyEquivalentModifierMask = [.command, .shift]
        saveCopyItem.target = controller
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Flatten PDF…", action: #selector(MainViewController.commandFlattenPDF(_:)), keyEquivalent: "").target = controller
        fileMenu.addItem(withTitle: "Reduce File Size…", action: #selector(MainViewController.commandReduceFileSize(_:)), keyEquivalent: "").target = controller
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        editItem.title = "Edit"
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Copy", action: #selector(MainViewController.commandCopy(_:)), keyEquivalent: "c").target = controller
        editMenu.addItem(withTitle: "Paste", action: #selector(MainViewController.commandPaste(_:)), keyEquivalent: "v").target = controller
        editMenu.addItem(withTitle: "Select All Text", action: #selector(MainViewController.commandSelectAll(_:)), keyEquivalent: "a").target = controller
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Find…", action: #selector(MainViewController.commandFocusSearch(_:)), keyEquivalent: "f").target = controller
        editItem.submenu = editMenu

        let bookmarksItem = NSMenuItem()
        bookmarksItem.title = "Bookmarks"
        mainMenu.addItem(bookmarksItem)
        let bookmarksMenu = NSMenu(title: "Bookmarks")
        let autoNamesItem = bookmarksMenu.addItem(withTitle: "Auto-Generate Sheet Names/Bookmarks…", action: #selector(MainViewController.commandAutoGenerateSheetNames(_:)), keyEquivalent: "a")
        autoNamesItem.keyEquivalentModifierMask = [.command, .shift]
        autoNamesItem.target = controller
        bookmarksMenu.addItem(NSMenuItem.separator())
        bookmarksMenu.addItem(withTitle: "Delete Selected Bookmark(s)…", action: #selector(MainViewController.deleteBookmarkFromSidebar), keyEquivalent: "").target = controller
        bookmarksItem.submenu = bookmarksMenu

        let hyperlinksItem = NSMenuItem()
        hyperlinksItem.title = "Hyperlinks"
        mainMenu.addItem(hyperlinksItem)
        let hyperlinksMenu = NSMenu(title: "Hyperlinks")
        let batchLinkItem = hyperlinksMenu.addItem(withTitle: "Batch Link Sheet Numbers…", action: #selector(MainViewController.commandBatchLinkSheetNumbers(_:)), keyEquivalent: "h")
        batchLinkItem.keyEquivalentModifierMask = [.command, .shift]
        batchLinkItem.target = controller
        hyperlinksItem.submenu = hyperlinksMenu

        let viewItem = NSMenuItem()
        viewItem.title = "View"
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(MainViewController.commandZoomIn(_:)), keyEquivalent: "+").target = controller
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(MainViewController.commandZoomOut(_:)), keyEquivalent: "-").target = controller
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(MainViewController.commandActualSize(_:)), keyEquivalent: "0").target = controller
        let fitWidthItem = viewMenu.addItem(withTitle: "Fit Width", action: #selector(MainViewController.commandFitWidth(_:)), keyEquivalent: "9")
        fitWidthItem.keyEquivalentModifierMask = [.command, .option]
        fitWidthItem.target = controller
        viewMenu.addItem(NSMenuItem.separator())
        let previousPageItem = viewMenu.addItem(withTitle: "Previous Page", action: #selector(MainViewController.commandPreviousPage(_:)), keyEquivalent: "")
        previousPageItem.keyEquivalentModifierMask = []
        previousPageItem.target = controller
        let nextPageItem = viewMenu.addItem(withTitle: "Next Page", action: #selector(MainViewController.commandNextPage(_:)), keyEquivalent: "")
        nextPageItem.keyEquivalentModifierMask = []
        nextPageItem.target = controller
        let backItem = viewMenu.addItem(withTitle: "Back", action: #selector(MainViewController.commandNavigateBack(_:)), keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        backItem.keyEquivalentModifierMask = [.option]
        backItem.target = controller
        let forwardItem = viewMenu.addItem(withTitle: "Forward", action: #selector(MainViewController.commandNavigateForward(_:)), keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        forwardItem.keyEquivalentModifierMask = [.option]
        forwardItem.target = controller
        viewMenu.addItem(NSMenuItem.separator())
        let linkHighlightsItem = viewMenu.addItem(withTitle: "Show Hyperlink Highlights", action: #selector(MainViewController.commandToggleHyperlinkHighlights(_:)), keyEquivalent: "h")
        linkHighlightsItem.keyEquivalentModifierMask = [.command, .option, .shift]
        linkHighlightsItem.target = controller
        linkHighlightsItem.state = controller.isHyperlinkHighlightsVisible ? .on : .off
        viewItem.submenu = viewMenu

        let helpItem = NSMenuItem()
        helpItem.title = "Help"
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        let quickStartItem = helpMenu.addItem(withTitle: "Drawbridge Quick Start", action: #selector(MainViewController.commandQuickStart(_:)), keyEquivalent: "/")
        quickStartItem.keyEquivalentModifierMask = [.command, .shift]
        quickStartItem.target = controller
        helpItem.submenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAboutPanel(_ sender: Any?) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        let alert = NSAlert()
        alert.messageText = "About Drawbridge"
        alert.informativeText = """
Drawbridge
Version \(version) (\(build))

Drawbridge is a native macOS PDF viewer for architects, designers, and engineers, focused on sheet bookmarks and hyperlinks.

System Requirements:
• Apple Silicon Mac (M1 or newer)
• macOS \(minimumSupportedMacOSVersion) or newer
"""
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func handleOpenRequests(_ urls: [URL]) {
        let candidates = urls.filter { url in
            if url.pathExtension.lowercased() == "pdf" { return true }
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .pdf) {
                return true
            }
            return false
        }
        guard !candidates.isEmpty else { return }
        if mainViewController == nil {
            pendingOpenURLs.append(contentsOf: candidates)
            return
        }
        pendingOpenURLs.append(contentsOf: candidates)
        flushPendingOpenURLs()
    }

    private func flushPendingOpenURLs() {
        guard let controller = mainViewController else { return }
        while !pendingOpenURLs.isEmpty {
            let url = pendingOpenURLs.removeFirst()
            controller.openDocumentFromExternalURL(url)
        }
    }
}
