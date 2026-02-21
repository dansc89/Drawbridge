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
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .hidden
        window.toolbarStyle = .expanded
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
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
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
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
        return controller.confirmDiscardUnsavedChangesIfNeeded() ? .terminateNow : .terminateCancel
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

    @objc private func toggleRestoreLastDocument(_ sender: Any?) {
        let next = !shouldRestoreLastDocumentOnLaunch()
        UserDefaults.standard.set(next, forKey: restoreLastDocumentDefaultsKey)
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

    private func shouldRestoreLastDocumentOnLaunch() -> Bool {
        if UserDefaults.standard.object(forKey: restoreLastDocumentDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: restoreLastDocumentDefaultsKey)
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
        let prefsItem = appMenu.addItem(withTitle: "Performance Settings…", action: #selector(MainViewController.commandPerformanceSettings(_:)), keyEquivalent: ",")
        prefsItem.target = controller
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Drawbridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        fileItem.title = "File"
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New...", action: #selector(MainViewController.commandNew(_:)), keyEquivalent: "n").target = controller
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
        let exportCSVItem = fileMenu.addItem(withTitle: "Export Markups CSV...", action: #selector(MainViewController.commandExportCSV(_:)), keyEquivalent: "e")
        exportCSVItem.keyEquivalentModifierMask = [.command, .shift]
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        editItem.title = "Edit"
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(withTitle: "Select All Markups On Page", action: #selector(MainViewController.commandSelectAll(_:)), keyEquivalent: "a").target = controller
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Edit Selected Markup", action: #selector(MainViewController.commandEditMarkup(_:)), keyEquivalent: "e").target = controller
        editMenu.addItem(withTitle: "Delete Selected Markup", action: #selector(MainViewController.commandDeleteMarkup(_:)), keyEquivalent: "\u{8}").target = controller
        editItem.submenu = editMenu

        let markupsItem = NSMenuItem()
        markupsItem.title = "Markups"
        mainMenu.addItem(markupsItem)
        let markupsMenu = NSMenu(title: "Markups")
        let highlightItem = markupsMenu.addItem(withTitle: "Highlight Selection", action: #selector(MainViewController.commandHighlight(_:)), keyEquivalent: "h")
        highlightItem.keyEquivalentModifierMask = [.command, .shift]
        markupsMenu.addItem(withTitle: "Auto-Generate Sheet Names/Bookmarks…", action: #selector(MainViewController.commandAutoGenerateSheetNames(_:)), keyEquivalent: "").target = controller
        markupsMenu.addItem(NSMenuItem.separator())
        markupsMenu.addItem(withTitle: "Refresh Markups", action: #selector(MainViewController.commandRefreshMarkups(_:)), keyEquivalent: "r").target = controller
        markupsMenu.addItem(withTitle: "Edit Selected Markup", action: #selector(MainViewController.commandEditMarkup(_:)), keyEquivalent: "e").target = controller
        let deleteItem = markupsMenu.addItem(withTitle: "Delete Selected Markup", action: #selector(MainViewController.commandDeleteMarkup(_:)), keyEquivalent: "\u{8}")
        deleteItem.keyEquivalentModifierMask = []
        for item in markupsMenu.items { item.target = controller }
        markupsItem.submenu = markupsMenu

        let toolsItem = NSMenuItem()
        toolsItem.title = "Tools"
        mainMenu.addItem(toolsItem)
        let toolsMenu = NSMenu(title: "Tools")
        toolsMenu.addItem(withTitle: "Selection Tool", action: #selector(MainViewController.selectSelectionTool(_:)), keyEquivalent: "0").target = controller
        toolsMenu.addItem(withTitle: "Pen Tool", action: #selector(MainViewController.selectPenTool(_:)), keyEquivalent: "1").target = controller
        toolsMenu.addItem(withTitle: "Highlighter Tool", action: #selector(MainViewController.selectHighlighterTool(_:)), keyEquivalent: "2").target = controller
        toolsMenu.addItem(withTitle: "Cloud Tool", action: #selector(MainViewController.selectCloudTool(_:)), keyEquivalent: "3").target = controller
        toolsMenu.addItem(withTitle: "Rectangle Tool", action: #selector(MainViewController.selectRectangleTool(_:)), keyEquivalent: "4").target = controller
        toolsMenu.addItem(withTitle: "Text Tool", action: #selector(MainViewController.selectTextTool(_:)), keyEquivalent: "5").target = controller
        toolsMenu.addItem(withTitle: "Callout Tool", action: #selector(MainViewController.selectCalloutTool(_:)), keyEquivalent: "6").target = controller
        toolsMenu.addItem(withTitle: "Measure Tool", action: #selector(MainViewController.selectMeasureTool(_:)), keyEquivalent: "7").target = controller
        toolsMenu.addItem(withTitle: "Calibrate Tool", action: #selector(MainViewController.selectCalibrateTool(_:)), keyEquivalent: "8").target = controller
        for item in toolsMenu.items { item.keyEquivalentModifierMask = [.command] }
        toolsItem.submenu = toolsMenu

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
        let setScaleItem = viewMenu.addItem(withTitle: "Set Drawing Scale...", action: #selector(MainViewController.commandSetScale(_:)), keyEquivalent: "k")
        setScaleItem.keyEquivalentModifierMask = [.command, .shift]
        setScaleItem.target = controller
        viewMenu.addItem(NSMenuItem.separator())
        let toggleSidebarItem = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(MainViewController.commandToggleSidebar(_:)), keyEquivalent: "s")
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .option]
        toggleSidebarItem.target = controller
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

Native macOS PDF markup and takeoff app for architects and designers.

System Requirements:
• Apple Silicon Mac (M1/M2/M3/M4)
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
