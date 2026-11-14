import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Presentation only; server capabilities and mutation authorization remain authoritative.
struct ReviewCapabilityPresentation {
    static let browserTitle = "Drawbridge Review — Server Documents"
    static func subtitle(workspace: String?) -> String {
        workspace.map { "Workspace: " + $0 } ?? ""
    }
    let newFolderReason: String?
    let deleteReason: String?
    var newFolderToolTip: String { newFolderReason ?? "Create a folder" }
    var deleteToolTip: String { deleteReason ?? "Delete selected items after confirming." }
    var explanation: String {
        [newFolderReason.map { "New Folder unavailable: " + $0 },
         deleteReason.map { "Delete unavailable: " + $0 }].compactMap { $0 }.joined(separator: "\n")
    }

    init(busy: Bool, foldersAvailable: Bool, organizationActions: Bool, selectionCount: Int,
         documentDeletion: Bool = false, selectionContainsFolders: Bool = false) {
        let wait = "Wait for the current operation to finish."
        var folderReasons: [String] = []
        var deleteReasons: [String] = []
        if !foldersAvailable {
            folderReasons.append("This server response has not advertised folder support. Refresh; if this persists, ask the server administrator to check service capabilities.")
        }
        if foldersAvailable && !organizationActions {
            folderReasons.append("This server response has not advertised folder creation support for your account.")
        }
        let canDelete = organizationActions || documentDeletion
        if !canDelete {
            deleteReasons.append("This server response has not advertised deletion support. Refresh; if this persists, ask the server administrator to check service capabilities.")
        }
        if selectionContainsFolders && !organizationActions {
            deleteReasons.append("Folder deletion is not available for your account. Select only PDFs.")
        }
        if busy { folderReasons.append(wait); deleteReasons.append(wait) }
        if canDelete && selectionCount == 0 {
            deleteReasons.append("Select one or more folders or PDFs first.")
        }
        newFolderReason = folderReasons.isEmpty ? nil : folderReasons.joined(separator: " ")
        deleteReason = deleteReasons.isEmpty ? nil : deleteReasons.joined(separator: " ")
    }
}

/// Transport evidence only: neither a local outbox save nor a socket is a server acknowledgement.
/// Use monotonic time so wall-clock changes cannot prolong an Online indication.
struct ReviewSyncConnection {
    static let freshness: TimeInterval = 5
    private var lastResponse: TimeInterval?

    mutating func receivedResponse(at time: TimeInterval) { lastResponse = time }
    mutating func disconnect() { lastResponse = nil }
    func isOnline(at time: TimeInterval) -> Bool {
        guard let lastResponse else { return false }
        let age = time - lastResponse
        return age >= 0 && age < Self.freshness
    }
}

@MainActor
private final class ReviewBrowserWindow: NSWindow {
    var navigate: ((Bool) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command, let navigate, [125, 126].contains(event.keyCode) {
            navigate(event.keyCode == 125)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class SharedReviewWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate {
    weak var editor: MainViewController?
    private(set) var tabURL: URL?
    private(set) var reviewPDF: PDFDocument?
    private(set) var basePDF: Data?
    private(set) var syncStatus = ""
    private var reviewConnection = ReviewSyncConnection()
    private var connectionExpiryTask: Task<Void, Never>?
    var reviewIsOnline: Bool {
        !sessionInvalidated && sessionID != nil && reviewConnection.isOnline(at: ProcessInfo.processInfo.systemUptime)
    }
    var canEdit: Bool { ready }
    var hasPendingChanges: Bool { !invalidPages.isEmpty || outboxNeedsSave }
    private let outboxDirectory: URL?
    private let cacheDirectory: URL?
    private var additionalReviews: [URL: SharedReviewWindowController] = [:]
    private var outbox: SharedReviewOutbox?
    private var outboxNeedsSave = false
    // Disk may retain this acknowledged prefix after a crash. Replay keeps the
    // original clientOpIds, deduplicated by the backend's durable unique key.
    private var uncheckpointedAcknowledgements = 0
    private static let acknowledgementBatchSize = 16
    private var invalidPages = Set<Int>()
    private var retiredIDs = Set<String>()
    private let documentsTable = NSTableView()
    private let folderPath = NSPathControl()
    private var pathFolderIDs: [String?] = []
    private lazy var openButton = button("Open", #selector(openSelected))
    private lazy var uploadButton = button("Upload PDFs…", #selector(uploadPDF))
    private lazy var refreshButton = button("Refresh", #selector(refreshDocuments(_:)))
    private let status = NSTextField(labelWithString: "Choose a shared PDF.")
    private let capabilityExplanation = NSTextField(wrappingLabelWithString: "")
    private let uploadProgress = NSProgressIndicator()
    private let uploadDetail = NSTextField(labelWithString: "")
    private let uploadPresentation = NSStackView()
    private var toolbarItems: [String: NSToolbarItem] = [:]
    private lazy var backButton = button("Back", #selector(goBack))
    private lazy var newFolderButton = button("New Folder…", #selector(createFolder))
    private lazy var deleteButton = button("Delete…", #selector(deleteSelectedItems))
    private static let reviewDocumentDrag = NSPasteboard.PasteboardType("com.drawbridge.review.document-id")
    private var organizationActions = false
    private var documentDeletion = false
    private weak var reviewAlertSheet: NSWindow?
    private var folderID: String?
    private var workspaceKey: String?
    private var folders: [SharedReviewAPI.Folder]?
    private var documents: [SharedReviewAPI.Document] = []
    private var visibleFolders: [SharedReviewAPI.Folder] { (folders ?? []).filter { $0.parent_id == folderID } }
    private var visibleDocuments: [SharedReviewAPI.Document] { documents.filter { $0.folder_id == folderID } }
    private var rowCount: Int { visibleFolders.count + visibleDocuments.count }
    private var api: SharedReviewAPI?
    private var reviewAPI: SharedReviewAPI?
    private var reviewUsername: String?
    private var project: SharedReviewAPI.Project?
    private var documentID: String?
    private var sessionID: String?
    private(set) var revision = 0
    private var pending: [SharedReviewOutbox.Edit] = []
    private var records: [Int: [String: RectangleMarkupRecord]] = [:]
    private var syncTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var busy = false
    private var syncing = false
    private var ready = false
    private var syncRequested = false
    private var lifecycle = UUID()
    private var sessionInvalidated = false
    private var capturedAPIs: [SharedReviewAPI] = []
    private var operationTask: Task<Void, Never>?
    private var editSyncTask: Task<Void, Never>?

    init(outboxDirectory: URL? = nil, cacheDirectory: URL? = nil) {
        self.outboxDirectory = outboxDirectory
        self.cacheDirectory = cacheDirectory
        super.init(window: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reviewSessionChanged),
            name: SettingsWindowController.reviewSessionDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshBrowserTheme),
            name: InterfaceTheme.didChange, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func reviewSessionChanged() {
        lifecycle = UUID()
        sessionInvalidated = true
        // Pending edits (including failed local saves) and PDF/cache bytes are
        // retained, never replayed by this invalidated review. Reopening requires
        // fresh server authorization and the existing origin/device outbox scope.
        stopSync()
        operationTask?.cancel()
        operationTask = nil
        capturedAPIs.forEach { $0.invalidate() }
        capturedAPIs.removeAll()
        api?.invalidate()
        reviewAPI?.invalidate()
        api = nil
        reviewAPI = nil
        reviewUsername = nil
        documentID = nil
        project = nil
        workspaceKey = nil
        folderID = nil
        folders = nil
        documents.removeAll()
        organizationActions = false
        documentDeletion = false
        if let sheet = reviewAlertSheet {
            reviewAlertSheet = nil
            sheet.sheetParent?.endSheet(sheet, returnCode: .cancel)
        }
        busy = false
        resetUploadProgress()
        if !retryPendingEditsSave() {
            updateReviewStatus("Signed out · Pending edits are only in memory")
            status.stringValue = "Pending edits could not be saved locally. Keep this tab open to retain them."
        } else {
            updateReviewStatus("Signed out · Local pending edits retained")
            status.stringValue = "Sign in and reopen Review to continue. Local edits and cached PDFs are retained."
        }
        documentsTable.reloadData()
        updateBrowserControls()
        editor?.refreshRectangleToolbar()
    }

    private func checkLifecycle(_ generation: UUID, api: SharedReviewAPI) throws {
        try api.checkActive()
        guard lifecycle == generation, !sessionInvalidated else { throw CancellationError() }
    }

    private func presentReviewAlert(_ alert: NSAlert, in window: NSWindow,
                                    generation: UUID, api: SharedReviewAPI) async throws -> NSApplication.ModalResponse {
        try checkLifecycle(generation, api: api)
        let sheet = alert.window
        reviewAlertSheet = sheet
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        try checkLifecycle(generation, api: api)
        reviewAlertSheet = nil
        return response
    }

    @objc func showReviews(_ sender: Any?) {
        if (try? SettingsWindowController.sharedReviewCredentials()) == nil, let editor {
            editor.settingsWindowController.prepare(section: .review)
            editor.settingsWindowController.showWindow(sender)
            return
        }
        if window == nil { buildWindow() }
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        refreshDocuments(nil)
    }

    func buildWindow() {
        let window = ReviewBrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 480),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = ReviewCapabilityPresentation.browserTitle
        window.minSize = NSSize(width: 480, height: 320)
        window.toolbarStyle = .unified
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window
        window.navigate = { [weak self] down in
            if down { self?.openSelected() } else { self?.goBack() }
        }

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.resizingMask = .autoresizingMask
        documentsTable.addTableColumn(nameColumn)
        documentsTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        documentsTable.style = .inset
        documentsTable.headerView = nil
        documentsTable.usesAlternatingRowBackgroundColors = false
        documentsTable.allowsMultipleSelection = true
        documentsTable.delegate = self
        documentsTable.dataSource = self
        documentsTable.target = self
        documentsTable.doubleAction = #selector(openClickedDocument)
        documentsTable.registerForDraggedTypes([Self.reviewDocumentDrag, .fileURL])
        documentsTable.setDraggingSourceOperationMask(.move, forLocal: true)
        documentsTable.setAccessibilityLabel("Server Documents")
        documentsTable.rowHeight = 34
        documentsTable.intercellSpacing = NSSize(width: 8, height: 2)

        let list = NSScrollView()
        list.hasVerticalScroller = true
        list.borderType = .noBorder
        list.documentView = documentsTable
        list.translatesAutoresizingMaskIntoConstraints = false

        backButton.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading
        backButton.keyEquivalent = "["
        backButton.keyEquivalentModifierMask = .command
        backButton.toolTip = "Go to the parent folder (⌘↑)"
        folderPath.pathStyle = .standard
        folderPath.target = self
        folderPath.action = #selector(openPathFolder)
        folderPath.setAccessibilityLabel("Current Review folder")
        folderPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateFolderPath()
        let navigation = NSStackView(views: [backButton, folderPath])
        navigation.spacing = 10
        navigation.alignment = .centerY
        // The toolbar owns navigation; retain the key-equivalent button in the
        // responder hierarchy for existing keyboard and path-control behavior.
        backButton.isHidden = true
        status.maximumNumberOfLines = 2
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        openButton.keyEquivalent = "\r"
        openButton.bezelStyle = .rounded
        openButton.toolTip = "Open the selected folder or PDF (Return)"
        let footer = NSStackView(views: [status, NSView(), openButton])
        footer.spacing = 12
        footer.alignment = .centerY
        uploadProgress.style = .bar
        uploadProgress.minValue = 0
        uploadProgress.maxValue = 100
        uploadProgress.isDisplayedWhenStopped = true
        uploadProgress.setAccessibilityLabel("PDF upload progress")
        uploadDetail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        uploadDetail.lineBreakMode = .byTruncatingMiddle
        uploadDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        uploadPresentation.orientation = .vertical
        uploadPresentation.alignment = .leading
        uploadPresentation.spacing = 5
        uploadPresentation.addArrangedSubview(uploadDetail)
        uploadPresentation.addArrangedSubview(uploadProgress)
        resetUploadProgress()
        // No supported workspace-presence transport: preserve honest unavailable
        // state and disclosure, compact by default at the bottom-left.
        let participants = ReviewParticipantsView(frame: .zero)
        participants.disclosureButton.performClick(nil)
        capabilityExplanation.identifier = NSUserInterfaceItemIdentifier("review.capabilityExplanation")
        capabilityExplanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        capabilityExplanation.setContentCompressionResistancePriority(.required, for: .vertical)
        let stack = NSStackView(views: [navigation, list, uploadPresentation, footer, capabilityExplanation, participants])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let content = window.contentView {
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                list.widthAnchor.constraint(equalTo: stack.widthAnchor),
                list.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
                folderPath.widthAnchor.constraint(equalTo: navigation.widthAnchor),
                uploadProgress.widthAnchor.constraint(equalTo: uploadPresentation.widthAnchor),
                uploadDetail.widthAnchor.constraint(equalTo: uploadPresentation.widthAnchor)
            ])
            for insetView in [navigation, uploadPresentation, footer, capabilityExplanation, participants] {
                insetView.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16).isActive = true
                insetView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
            }
        }
        let toolbar = NSToolbar(identifier: "ReviewBrowser")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.delegate = self
        window.toolbar = toolbar
        window.initialFirstResponder = documentsTable
        refreshBrowserTheme()
        updateBrowserControls()
    }

    private var toolbarDefinitions: [(String, String, String, Selector, String)] {
        [("back", "Back", "chevron.backward", #selector(goBack), "Go to the parent folder (⌘↑)"),
         ("upload", "Upload PDFs…", "arrow.up.to.line", #selector(uploadPDF), "Upload PDFs to this folder"),
         ("newFolder", "New Folder…", "folder.badge.plus", #selector(createFolder), "Create a folder"),
         ("refresh", "Refresh", "arrow.clockwise", #selector(refreshDocuments(_:)), "Refresh server documents"),
         ("delete", "Delete…", "trash", #selector(deleteSelectedItems), "Delete the selected items…")]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("review.back"), .flexibleSpace, .init("review.upload"), .init("review.newFolder"),
         .init("review.refresh"), .init("review.delete")]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let definition = toolbarDefinitions.first(where: { "review." + $0.0 == identifier.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = definition.1
        item.paletteLabel = definition.1
        item.image = NSImage(systemSymbolName: definition.2, accessibilityDescription: definition.1)
        if definition.0 == "upload" {
            let upload = NSButton(title: definition.1, target: self, action: definition.3)
            upload.image = item.image
            upload.imagePosition = .imageLeading
            upload.bezelStyle = .rounded
            upload.toolTip = definition.4
            item.view = upload
        }
        item.target = self
        item.action = definition.3
        item.toolTip = definition.4
        item.autovalidates = false
        toolbarItems[definition.0] = item
        return item
    }

    @objc private func refreshBrowserTheme() {
        guard let window else { return }
        let theme = InterfaceTheme.current
        window.appearance = theme.nativeAppearance
        window.backgroundColor = theme == .system ? .windowBackgroundColor : AppAppearance.chrome
        window.titlebarAppearsTransparent = theme != .system
        documentsTable.backgroundColor = theme == .system ? .controlBackgroundColor : AppAppearance.panel
        if let scroll = documentsTable.enclosingScrollView {
            scroll.backgroundColor = documentsTable.backgroundColor
            scroll.contentView.backgroundColor = documentsTable.backgroundColor
        }
        func refresh(_ view: NSView) {
            if let field = view as? NSTextField {
                field.textColor = theme.color(for: "foreground") ?? .labelColor
            }
            view.needsDisplay = true
            for child in view.subviews { refresh(child) }
        }
        if let content = window.contentView { refresh(content) }
        documentsTable.reloadData()
        window.displayIfNeeded()
    }

    // Shared by actual API callbacks and constructed-window tests; never timer driven.
    func presentUploadProgress(file: String, index: Int, count: Int, sent: Int? = nil, total: Int? = nil) {
        guard !sessionInvalidated else { return }
        uploadPresentation.isHidden = false
        uploadProgress.isHidden = false
        let prefix = "File \(index) of \(count) · "
        if let sent, let total, total > 0 {
            let fraction = min(1, max(0, Double(sent) / Double(total)))
            uploadProgress.isIndeterminate = fraction >= 1
            uploadProgress.doubleValue = fraction * 100
            let bytes = ByteCountFormatter.string(fromByteCount: Int64(max(0, sent)), countStyle: .file)
            let size = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
            uploadDetail.stringValue = prefix + (fraction >= 1 ? "Verifying " : "Uploading ") + file + " · \(bytes) of \(size) · \(Int(fraction * 100))%"
        } else {
            uploadProgress.isIndeterminate = true
            uploadProgress.doubleValue = 0
            uploadDetail.stringValue = prefix + "Preparing " + file + "…"
        }
        uploadDetail.toolTip = uploadDetail.stringValue
        if uploadProgress.isIndeterminate { uploadProgress.startAnimation(nil) }
        else { uploadProgress.stopAnimation(nil) }
    }
    func resetUploadProgress() {
        uploadProgress.stopAnimation(nil)
        uploadProgress.doubleValue = 0
        uploadProgress.isIndeterminate = true
        uploadProgress.isHidden = true
        uploadDetail.stringValue = ""
        uploadDetail.toolTip = nil
        uploadPresentation.isHidden = true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entries = visibleFolders
        let isFolder = entries.indices.contains(row)
        let name = isFolder ? entries[row].name : visibleDocuments[row - entries.count].name
        let icon = NSImageView(image: NSImage(systemSymbolName: isFolder ? "folder.fill" : "doc", accessibilityDescription: nil) ?? NSImage())
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = isFolder ? .controlAccentColor : .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let field = NSTextField(labelWithString: name)
        field.lineBreakMode = .byTruncatingMiddle
        field.textColor = InterfaceTheme.current.color(for: "foreground") ?? .labelColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.toolTip = name
        let cell = NSStackView(views: [icon, field])
        cell.alignment = .centerY
        cell.spacing = 6
        cell.setAccessibilityLabel(isFolder ? "Folder, " + name : name)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateBrowserControls() }

    private func updateBrowserControls() {
        openButton.isEnabled = !busy && !documentsTable.selectedRowIndexes.isEmpty
        uploadButton.isEnabled = !busy && organizationActions && project != nil
        refreshButton.isEnabled = !busy
        newFolderButton.isEnabled = !busy && organizationActions && folders != nil
        backButton.isEnabled = !busy && folderID != nil
        folderPath.isEnabled = !busy
        let presentation = ReviewCapabilityPresentation(busy: busy, foldersAvailable: folders != nil,
                                                       organizationActions: organizationActions,
                                                       selectionCount: documentsTable.numberOfSelectedRows,
                                                       documentDeletion: documentDeletion,
                                                       selectionContainsFolders: documentsTable.selectedRowIndexes.contains { $0 < visibleFolders.count })
        deleteButton.isEnabled = presentation.deleteReason == nil
        newFolderButton.toolTip = presentation.newFolderToolTip
        deleteButton.toolTip = presentation.deleteToolTip
        capabilityExplanation.stringValue = presentation.explanation
        capabilityExplanation.toolTip = presentation.explanation
        capabilityExplanation.setAccessibilityLabel(presentation.explanation)
        capabilityExplanation.isHidden = presentation.explanation.isEmpty
        for (key, button) in [("back", backButton), ("upload", uploadButton), ("newFolder", newFolderButton),
                              ("refresh", refreshButton), ("delete", deleteButton)] {
            toolbarItems[key]?.isEnabled = button.isEnabled
            (toolbarItems[key]?.view as? NSButton)?.isEnabled = button.isEnabled
            if key == "newFolder" || key == "delete" { toolbarItems[key]?.toolTip = button.toolTip }
        }
    }

    @objc private func openClickedDocument() {
        guard (0..<rowCount).contains(documentsTable.clickedRow) else { return }
        openRows(IndexSet(integer: documentsTable.clickedRow))
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    @objc private func refreshDocuments(_ sender: Any?) {
        if sessionInvalidated, SettingsWindowController.activeReviewSession != nil {
            sessionInvalidated = false
        }
        perform { try await self.loadDocuments() }
    }

    var makeReviewAPI: (URL, SettingsWindowController.ServerSession) -> SharedReviewAPI = { origin, credentials in
        SharedReviewAPI(origin: origin, token: credentials.token, displayName: credentials.displayName, instanceID: credentials.instanceId)
    }

    func loadDocuments() async throws {
        // Cleanup reloads may outlive logout; only explicit browser refresh can reauthorize.
        try Task.checkCancellation()
        guard !sessionInvalidated else { throw CancellationError() }
        let (origin, credentials) = try SettingsWindowController.sharedReviewCredentials()
        let generation = lifecycle
        let api = makeReviewAPI(origin, credentials)
        capturedAPIs.append(api)
        let projects: SharedReviewAPI.ProjectList = try await api.get("projects")
        try checkLifecycle(generation, api: api)
        guard let project = projects.projects.first(where: { $0.name == "AERO Collective" }) ?? projects.projects.first else {
            throw SharedReviewError("Your account has no shared projects.")
        }
        let list: SharedReviewAPI.DocumentList = try await api.get("projects/\(project.id)/documents")
        try checkLifecycle(generation, api: api)
        let key = "DrawbridgeReviewFolder|\(origin.absoluteString)|\(api.instanceID)|\(project.id)"
        if workspaceKey != key {
            workspaceKey = key
            folderID = UserDefaults.standard.string(forKey: key)
        }
        self.project = project
        self.api = api
        organizationActions = list.organizationActions == true
        documentDeletion = list.documentDeletion == true || organizationActions
        folders = list.folders?.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        documents = list.documents.filter { $0.file_size != nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !(folders ?? []).contains(where: { $0.id == folderID }) { folderID = nil }
        showFolder()
    }

    private func showFolder() {
        if let workspaceKey { UserDefaults.standard.set(folderID, forKey: workspaceKey) }
        updateFolderPath()
        documentsTable.reloadData()
        documentsTable.deselectAll(nil)
        status.stringValue = rowCount == 0 ? "This folder is empty." : "\(rowCount) items"
        updateBrowserControls()
    }

    private func updateFolderPath() {
        var entries: [(name: String, id: String?)] = []
        var cursor = folderID
        var visited = Set<String>()
        while let id = cursor, visited.insert(id).inserted,
              let folder = folders?.first(where: { $0.id == id }) {
            entries.append((folder.name, folder.id))
            cursor = folder.parent_id
        }
        entries.append((project?.name ?? "Server Documents", nil))
        entries.reverse()
        pathFolderIDs = entries.map(\.id)
        folderPath.pathItems = entries.map { entry in
            let item = NSPathControlItem()
            item.title = entry.name
            return item
        }
        folderPath.toolTip = entries.map(\.name).joined(separator: " › ")
        window?.title = ReviewCapabilityPresentation.browserTitle
        window?.subtitle = ReviewCapabilityPresentation.subtitle(workspace: project?.name)
    }

    @objc private func openPathFolder() {
        guard !busy, let clicked = folderPath.clickedPathItem,
              let index = folderPath.pathItems.firstIndex(of: clicked),
              pathFolderIDs.indices.contains(index), pathFolderIDs[index] != folderID else { return }
        folderID = pathFolderIDs[index]
        showFolder()
    }

    @objc private func goBack() {
        guard !busy, let folderID else { return }
        self.folderID = folders?.first(where: { $0.id == folderID })?.parent_id
        showFolder()
    }

    @objc private func createFolder() {
        guard !busy, organizationActions, let window, let project, let api, folders != nil else { return }
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        name.placeholderString = "Folder name"
        alert.accessoryView = name
        alert.window.initialFirstResponder = name
        let parent = folderID
        let generation = lifecycle
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  (try? self.checkLifecycle(generation, api: api)) != nil else { return }
            let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            self.perform {
                _ = try await self.requireReviewUsername(using: api, saveToSettings: true)
                _ = try await api.createFolder(name: title, parentID: parent, projectID: project.id)
                try await self.loadDocuments()
            }
        }
    }

    @objc private func openSelected() {
        openRows(documentsTable.selectedRowIndexes)
    }

    private func openRows(_ rows: IndexSet) {
        guard !busy, !rows.isEmpty else { return }
        let entries = visibleFolders
        if rows.count == 1, let index = rows.first, entries.indices.contains(index) {
            folderID = entries[index].id
            showFolder()
            return
        }
        let available = visibleDocuments
        let selected = rows.map { $0 - entries.count }
        guard selected.allSatisfy(available.indices.contains) else {
            status.stringValue = "Select one folder or one or more PDFs."
            return
        }
        perform {
            for index in selected {
                guard try await self.open(available[index], focusEditor: false) else { return }
            }
            if let editor = self.editor { self.showEditor(editor) }
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let index = row - visibleFolders.count
        guard !busy, organizationActions, visibleDocuments.indices.contains(index) else { return nil }
        let item = NSPasteboardItem()
        item.setString(visibleDocuments[index].id, forType: Self.reviewDocumentDrag)
        return item
    }

    private func droppedPDFs(_ pasteboard: NSPasteboard) -> [URL] {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard files.allSatisfy({ $0.pathExtension.lowercased() == "pdf" }) else { return [] }
        return files
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard !busy, organizationActions, !hasPendingChanges, api != nil, project != nil else { return [] }
        let folderRow = operation == .on && visibleFolders.indices.contains(row)
        if (info.draggingSource as? NSTableView) === documentsTable {
            return organizationActions && folderRow ? .move : []
        }
        guard !droppedPDFs(info.draggingPasteboard).isEmpty else { return [] }
        if !folderRow { tableView.setDropRow(-1, dropOperation: .on) }
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard !busy, organizationActions, !hasPendingChanges, let api, let project else { return false }
        let folder = dropOperation == .on && visibleFolders.indices.contains(row) ? visibleFolders[row] : nil
        if (info.draggingSource as? NSTableView) === documentsTable {
            guard organizationActions, let folder else { return false }
            let ids = info.draggingPasteboard.pasteboardItems?.compactMap {
                $0.string(forType: Self.reviewDocumentDrag)
            } ?? []
            guard !ids.isEmpty, ids.allSatisfy({ id in visibleDocuments.contains { $0.id == id } }) else { return false }
            perform {
                _ = try await self.requireReviewUsername(using: api, saveToSettings: true)
                let _: SharedReviewAPI.OrganizationReceipt = try await api.post("projects/\(project.id)/move-documents",
                    SharedReviewAPI.MoveRequest(ids: ids, folderId: folder.id))
                try await self.loadDocuments()
            }
        } else {
            let files = droppedPDFs(info.draggingPasteboard)
            guard !files.isEmpty else { return false }
            let destination = folder?.id ?? folderID
            uploadPDFs(files, to: destination, project: project, using: api)
        }
        return true
    }

    private func validateUpload(_ file: URL) throws {
        guard let pdf = PDFDocument(url: file), pdf.pageCount > 0, !pdf.isLocked else {
            throw SharedReviewError("Choose a readable, unlocked PDF.")
        }
    }

    @objc private func deleteSelectedItems() {
        guard !busy, documentDeletion || organizationActions, let api, let project, let window else { return }
        let folders = visibleFolders
        let documents = visibleDocuments
        let selected = documentsTable.selectedRowIndexes
        guard !selected.isEmpty, selected.allSatisfy({ $0 < folders.count + documents.count }) else { return }
        guard organizationActions || selected.allSatisfy({ $0 >= folders.count }) else { return }
        let items = selected.map { row -> (id: String, name: String, kind: String) in
            if row < folders.count {
                let folder = folders[row]
                return (folder.id, folder.name, "folder")
            }
            let document = documents[row - folders.count]
            return (document.id, document.name, "document")
        }
        let selectedPDFs = selected.compactMap { row in row >= folders.count ? documents[row - folders.count] : nil }
        let ids = Set(selectedPDFs.map(\.id))
        let affectedReviews = ([self] + Array(additionalReviews.values)).filter { review in
            review.reviewAPI?.origin == api.origin && review.documentID.map(ids.contains) == true
        }
        if affectedReviews.contains(where: { $0.hasPendingChanges || !$0.pending.isEmpty }) {
            status.stringValue = "Wait for the selected PDFs’ pending edits to sync before deleting them."
            return
        }
        let generation = lifecycle
        perform {
            let warning = NSAlert()
            warning.alertStyle = .warning
            warning.messageText = items.count == 1 ? "Delete “\(items[0].name)”?" : "Delete \(items.count) selected items?"
            warning.informativeText = items.contains { $0.kind == "document" }
                ? "Selected PDFs will be removed from the workspace for everyone. Recovery requires a server administrator."
                : "Only empty folders can be deleted. Move or delete their contents first."
            if items.contains(where: { $0.kind == "folder" }) && items.contains(where: { $0.kind == "document" }) {
                warning.informativeText += " Only empty folders can be deleted."
            }
            let delete = warning.addButton(withTitle: "Delete")
            delete.keyEquivalent = ""
            warning.addButton(withTitle: "Cancel")
            let response = try await self.presentReviewAlert(warning, in: window, generation: generation, api: api)
            guard response == .alertFirstButtonReturn else { self.showFolder(); return }

            if !selectedPDFs.isEmpty {
                let backup = NSAlert()
                backup.messageText = selectedPDFs.count == 1 ? "Save a local copy before deleting?" : "Save local copies before deleting?"
                backup.informativeText = "Local copies include the synced Review markups."
                backup.addButton(withTitle: selectedPDFs.count == 1 ? "Save Copy…" : "Save Copies…")
                backup.addButton(withTitle: "Delete Without Saving").keyEquivalent = ""
                backup.addButton(withTitle: "Cancel")
                let choice = try await self.presentReviewAlert(backup, in: window, generation: generation, api: api)
                switch choice {
                case .alertFirstButtonReturn:
                    var destinations = Set<URL>()
                    for document in selectedPDFs {
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [.pdf]
                        panel.nameFieldStringValue = URL(fileURLWithPath: document.name).lastPathComponent
                        self.reviewAlertSheet = panel
                        let result = await withCheckedContinuation { continuation in
                            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                        }
                        try self.checkLifecycle(generation, api: api)
                        self.reviewAlertSheet = nil
                        guard result == .OK, let destination = panel.url else { self.showFolder(); return }
                        let canonicalDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
                        guard destinations.insert(canonicalDestination).inserted else {
                            throw SharedReviewError("Choose a different filename for each copy. Nothing was deleted.")
                        }
                        if let editor = self.editor, editor.sessionDocumentURLs.contains(where: {
                            editor.canonicalDocumentURL($0) == editor.canonicalDocumentURL(destination)
                        }) {
                            throw SharedReviewError("Choose a destination that isn’t open in Drawbridge. Nothing was deleted.")
                        }
                        self.status.stringValue = "Saving a local copy…"
                        try await self.saveDeletionCopy(document, to: destination, api: api, generation: generation)
                    }
                case .alertSecondButtonReturn: break
                default: self.showFolder(); return
                }
            }
            let username = try await self.requireReviewUsername(using: api, saveToSettings: true)
            for (index, item) in items.enumerated() {
                let reviews = affectedReviews.filter { $0.documentID == item.id }
                do {
                    guard !reviews.contains(where: { $0.hasPendingChanges || !$0.pending.isEmpty }) else {
                        throw SharedReviewError("Wait for pending edits to sync.")
                    }
                    let _: SharedReviewAPI.OrganizationReceipt = try await api.post("projects/\(project.id)/remove-item",
                        SharedReviewAPI.RemoveRequest(kind: item.kind, id: item.id, confirmation: username))
                } catch {
                    try self.checkLifecycle(generation, api: api)
                    if index > 0 { try? await self.loadDocuments() }
                    try self.checkLifecycle(generation, api: api)
                    let reason = item.kind == "folder" && (error as? SharedReviewError)?.statusCode == 409
                        ? "Move or delete the folder’s contents first." : error.localizedDescription
                    throw SharedReviewError("Deleted \(index) of \(items.count) selected items. Couldn’t delete “\(item.name)”. \(reason)")
                }
                try self.checkLifecycle(generation, api: api)
                for review in reviews {
                    review.ready = false
                    review.updateReviewStatus("Removed from workspace")
                }
                self.editor?.refreshRectangleToolbar()
            }
            try await self.loadDocuments()
            try self.checkLifecycle(generation, api: api)
            self.status.stringValue = items.count == 1 ? "Deleted 1 item." : "Deleted \(items.count) items."
        }
    }

    private func saveDeletionCopy(_ document: SharedReviewAPI.Document, to destination: URL,
                                  api: SharedReviewAPI, generation: UUID) async throws {
        let base = try await api.download(document)
        try checkLifecycle(generation, api: api)
        var revision = 0
        var records: [String: RectangleMarkupRecord] = [:]
        while true {
            let response: SharedReviewAPI.Operations = try await api.get("documents/\(document.id)/ops", query: [
                URLQueryItem(name: "afterSeq", value: String(revision))
            ])
            try checkLifecycle(generation, api: api)
            for operation in response.ops {
                guard operation.seq > revision else { throw SharedReviewError("The server returned revisions out of order.") }
                if let markup = operation.payload { records[markup.id] = markup.record }
                revision = operation.seq
            }
            if response.ops.count < 500 { break }
        }
        let markups = records.values.sorted { $0.id < $1.id }
        try await Task.detached(priority: .userInitiated) {
            try SharedReviewPDFExport.write(basePDF: base, records: markups, to: destination)
        }.value
        try checkLifecycle(generation, api: api)
    }

    @objc private func uploadPDF() {
        guard !busy, organizationActions, let window, let project, let api else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        let generation = lifecycle
        let destination = folderID
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty, let self,
                  (try? self.checkLifecycle(generation, api: api)) != nil else { return }
            self.uploadPDFs(panel.urls, to: destination, project: project, using: api)
        }
    }

    private func uploadPDFs(_ files: [URL], to destination: String?,
                            project: SharedReviewAPI.Project, using api: SharedReviewAPI) {
        let generation = lifecycle
        perform {
            for file in files {
                do { try self.validateUpload(file) }
                catch { throw SharedReviewError("Can’t upload \(file.lastPathComponent). \(error.localizedDescription)") }
            }
            _ = try await self.requireReviewUsername(using: api, saveToSettings: true)
            for (index, file) in files.enumerated() {
                do {
                    self.presentUploadProgress(file: file.lastPathComponent, index: index + 1, count: files.count)
                    _ = try await api.upload(file, project: project, folderID: destination) { sent, size in
                        guard (try? self.checkLifecycle(generation, api: api)) != nil else { return }
                        self.presentUploadProgress(file: file.lastPathComponent, index: index + 1,
                                                   count: files.count, sent: sent, total: size)
                    }
                    try self.checkLifecycle(generation, api: api)
                } catch {
                    try self.checkLifecycle(generation, api: api)
                    if index > 0 { try? await self.loadDocuments() }
                    try self.checkLifecycle(generation, api: api)
                    throw SharedReviewError("Uploaded \(index) of \(files.count) PDFs. \(file.lastPathComponent) failed. \(error.localizedDescription)")
                }
            }
            try await self.loadDocuments()
            try self.checkLifecycle(generation, api: api)
            self.status.stringValue = "Uploaded \(files.count) \(files.count == 1 ? "PDF" : "PDFs")."
        }
    }

    // Internal so constructed-window tests can exercise completion and error cleanup
    // through exactly the same operation boundary as toolbar actions.
    func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !sessionInvalidated else { return }
        guard !busy else {
            status.stringValue = "Wait for the current server operation to finish."
            return
        }
        busy = true
        updateBrowserControls()
        status.stringValue = "Contacting server…"
        let generation = lifecycle
        operationTask = Task {
            defer {
                if lifecycle == generation {
                    busy = false
                    resetUploadProgress()
                    operationTask = nil
                    updateBrowserControls()
                }
            }
            do { try Task.checkCancellation(); try await work() }
            catch { if lifecycle == generation { status.stringValue = error.localizedDescription } }
        }
    }

    @discardableResult
    func open(_ document: SharedReviewAPI.Document, using connection: SharedReviewAPI? = nil,
              focusEditor: Bool = true) async throws -> Bool {
        guard !sessionInvalidated else { throw CancellationError() }
        let generation = lifecycle
        guard let api = connection ?? api, let editor else { return false }
        try checkLifecycle(generation, api: api)
        capturedAPIs.append(api)
        if window == nil { buildWindow() }
        let existing = ([self] + Array(additionalReviews.values)).first {
            $0.documentID == document.id && $0.reviewAPI?.origin == api.origin && $0.reviewAPI?.instanceID == api.instanceID
        }
        if let url = existing?.tabURL {
            guard editor.confirmDiscardUnsavedChangesIfNeeded() else { return false }
            editor.openDocument(at: url)
            if focusEditor { showEditor(editor) }
            return true
        }
        let username = try await requireReviewUsername(using: api, saveToSettings: connection == nil)
        try checkLifecycle(generation, api: api)
        // Recheck access before serving locally retained drawing bytes.
        let response: SharedReviewAPI.CreatedSession = try await api.post("documents/\(document.id)/sessions", ["name": "Drawbridge Review"])
        try checkLifecycle(generation, api: api)
        let cache = try SharedReviewPDFCache(origin: api.origin, instanceID: api.instanceID,
                                             document: document, directory: cacheDirectory)
        let bytes: Data
        let cached = try cache?.load()
        if let cached {
            bytes = cached
        } else {
            bytes = try await api.download(document)
        }
        try checkLifecycle(generation, api: api)
        guard let pdf = PDFDocument(data: bytes), pdf.pageCount > 0, !pdf.isLocked else {
            throw SharedReviewError("The shared PDF could not be opened.")
        }
        if cached == nil { try cache?.store(bytes) }
        let outbox = try SharedReviewOutbox(origin: api.origin, instanceID: api.instanceID,
                                            documentID: document.id, basePDF: bytes, directory: outboxDirectory)
        let recoveredEdits = try outbox.load()
        guard editor.confirmDiscardUnsavedChangesIfNeeded(), !editor.isPDFProcessingBusy else { return false }
        if editor.secondaryPDFView != nil { editor.collapsePDFSplit() }
        let review = tabURL == nil ? self : SharedReviewWindowController(outboxDirectory: outboxDirectory, cacheDirectory: cacheDirectory)
        review.editor = editor
        review.outbox = outbox
        review.pending = recoveredEdits
        review.reviewAPI = api
        review.reviewUsername = username
        review.documentID = document.id
        review.sessionID = response.session.id
        review.revision = 0
        review.records.removeAll()
        review.invalidPages.removeAll()
        review.retiredIDs.removeAll()
        for index in 0..<pdf.pageCount {
            for annotation in pdf.page(at: index)?.annotations ?? [] where annotation.type != "Link" {
                annotation.isReadOnly = true
            }
        }
        let filename = URL(fileURLWithPath: document.name).lastPathComponent
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(filename.lowercased().hasSuffix(".pdf") ? filename : filename + ".pdf")
        let tab = editor.canonicalDocumentURL(url)
        review.tabURL = tab
        review.reviewPDF = pdf
        review.basePDF = bytes
        review.syncStatus = "Connecting…"
        if review !== self { additionalReviews[tab] = review }
        editor.openDocument(at: url)
        if focusEditor { showEditor(editor) }
        review.startSync(api: api, document: document.id, session: response.session.id)
        return true
    }

    func review(for url: URL) -> SharedReviewWindowController? {
        url == tabURL ? self : additionalReviews[url]
    }

    func review(for document: PDFDocument) -> SharedReviewWindowController? {
        if reviewPDF === document { return self }
        return additionalReviews.values.first { $0.reviewPDF === document }
    }

    private func showEditor(_ editor: MainViewController) {
        window?.orderOut(nil)
        editor.view.window?.makeKeyAndOrderFront(nil)
    }

    func closeTab(at url: URL) {
        if let review = additionalReviews.removeValue(forKey: url) {
            review.closeTab(at: url)
            return
        }
        guard url == tabURL else { return }
        stopSync()
        documentID = nil
        tabURL = nil
        reviewPDF = nil
        basePDF = nil
        reviewAPI = nil
        outbox = nil
        pending.removeAll()
    }

    private func requireReviewUsername(using api: SharedReviewAPI, saveToSettings: Bool) async throws -> String {
        let generation = lifecycle
        try checkLifecycle(generation, api: api)
        let capabilities: SharedReviewAPI.Capabilities = try await api.get("auth/me")
        try checkLifecycle(generation, api: api)
        guard capabilities.reviewUsernames == true else {
            throw SharedReviewError("This server needs the Drawbridge Review username update.")
        }
        guard capabilities.creatorOnlyMarkups == true else {
            throw SharedReviewError("Sign in again under Settings → Drawbridge Review to use Drawbridge Review.")
        }
        let username: String
        if let existing = capabilities.reviewUsername {
            username = existing
        } else {
            username = try await chooseReviewUsername(using: api)
        }
        try checkLifecycle(generation, api: api)
        if saveToSettings { UserDefaults.standard.set(username, forKey: "drawbridgeReviewUsername") }
        return username
    }

    private func chooseReviewUsername(using api: SharedReviewAPI) async throws -> String {
        let generation = lifecycle
        guard let window else { throw SharedReviewError("Open Drawbridge Review to choose a username.") }
        let field = NSTextField(string: (api.displayName ?? "").replacingOccurrences(
            of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression
        ))
        field.frame.size.width = 280
        var message = "This username will appear on markups you add to Drawbridge Review."
        while true {
            let alert = NSAlert()
            alert.messageText = "Choose a Drawbridge Review username"
            alert.informativeText = message
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            let response = try await presentReviewAlert(alert, in: window, generation: generation, api: api)
            alert.accessoryView = nil
            try checkLifecycle(generation, api: api)
            guard response == .alertFirstButtonReturn else { throw SharedReviewError("Review canceled.") }
            do {
                return try await api.claimUsername(field.stringValue).username
            } catch let error as SharedReviewError where error.statusCode == 409 {
                message = "That username is already taken. Choose another one."
            } catch let error as SharedReviewError where error.statusCode == 400 {
                message = "Use 3–40 letters, numbers, periods, underscores, or hyphens. Start with a letter or number."
            }
        }
    }

    private func startSync(api: SharedReviewAPI, document: String, session: String) {
        guard !sessionInvalidated else { return }
        // The socket only nudges replay; allocating/receiving from it proves neither
        // authorization nor successful sync. HTTP polling must work without it.
        // Injected offline transports must not escape to a real WebSocket.
        if api.transport == nil, let socket = try? api.socket() {
            self.socket = socket
            socket.resume()
            listenTask = Task { [weak self] in
                do {
                    let data = try JSONEncoder().encode(["type": "subscribe", "documentId": document, "sessionId": session])
                    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
                    while !Task.isCancelled {
                        _ = try await socket.receive()
                        guard let self, self.sessionID == session else { return }
                        self.syncRequested = true
                        await self.sync(api: api, document: document, session: session)
                    }
                } catch { /* Authenticated HTTP replay remains authoritative if the hint socket disconnects. */ }
            }
        }
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.sessionID == session else { return }
                await self.sync(api: api, document: document, session: session)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopSync() {
        ready = false
        updateReviewConnection(online: false)
        editSyncTask?.cancel()
        editSyncTask = nil
        syncTask?.cancel()
        listenTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        syncTask = nil
        listenTask = nil
        socket = nil
        sessionID = nil
        syncRequested = false
        // Teardown leaves a safe replay superset; never flush an old session.
        uncheckpointedAcknowledgements = 0
    }

    func recordChanges(on page: PDFPage) {
        guard !sessionInvalidated else { return }
        guard let sessionID, outbox != nil, let pdf = reviewPDF, page.document === pdf else { return }
        let index = pdf.index(for: page)
        let previous = records[index] ?? [:]
        let current = page.annotations.reduce(into: [String: RectangleMarkupRecord]()) { result, annotation in
            guard !annotation.isReadOnly, !MeasurementMetadata.isPageScaleMetadata(annotation),
                  !MarkupLayers.isMetadata(annotation) else { return }
            // A deleted server ID stays retired. Undo restores the annotation as a new revision.
            if let id = RectangleMarkupRecord.identity(annotation), retiredIDs.contains(id) {
                annotation.setValue(RectangleMarkupRecord.prefix + UUID().uuidString, forAnnotationKey: RectangleMarkupRecord.identityKey)
            }
            guard var record = RectangleMarkupRecord.capture(annotation: annotation, pageIndex: index) else { return }
            if previous[record.id] == nil, let name = reviewUsername {
                record.author = name
                annotation.setValue(name, forAnnotationKey: PDFAnnotationKey(rawValue: "/T"))
            }
            result[record.id] = record
        }
        let ids = Set(previous.keys).union(current.keys)
        for id in ids where previous[id] != current[id] {
            if let record = current[id], (!record.isValid || (try? JSONEncoder().encode(record).count) ?? Int.max > 1_500_000) {
                invalidPages.insert(index)
                updateReviewStatus("Markup can’t sync. Remove or undo it to continue.")
                return
            }
        }
        for id in ids.sorted() where previous[id] != current[id] {
            if current[id] == nil { retiredIDs.insert(id) }
            outboxNeedsSave = true
            pending.append(.init(clientOpId: UUID().uuidString,
                                 payload: .init(id: id, page: index, record: current[id])))
        }
        invalidPages.remove(index)
        records[index] = current
        guard retryPendingEditsSave() else { return }
        if !pending.isEmpty { updateReviewStatus("Saving… · \(pending.count) pending") }
        if let api = reviewAPI, let documentID, editSyncTask == nil {
            let generation = lifecycle
            editSyncTask = Task {
                defer { if lifecycle == generation { editSyncTask = nil } }
                await sync(api: api, document: documentID, session: sessionID)
            }
        }
    }

    @discardableResult
    func retryPendingEditsSave() -> Bool {
        // Signing out stops transport, not local recovery. Failed new edits
        // must remain saveable if the disk becomes writable later. Teardown
        // clears ACK-only dirtiness; late network completions fail lifecycle checks.
        guard outboxNeedsSave || uncheckpointedAcknowledgements > 0 else { return true }
        do {
            try savePendingEdits()
            return true
        } catch {
            updateReviewStatus("Review · Edits could not be saved on this Mac")
            return false
        }
    }

    private func savePendingEdits() throws {
        guard let outbox else { throw CancellationError() }
        // Atomic replacement leaves the previous replayable queue on failure.
        // Local edits call this immediately, regardless of the ack batch size.
        outboxNeedsSave = true
        try outbox.save(pending)
        outboxNeedsSave = false
        uncheckpointedAcknowledgements = 0
    }

    private func sync(api: SharedReviewAPI, document: String, session: String) async {
        let generation = lifecycle
        guard !sessionInvalidated, sessionID == session, outbox != nil, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            repeat {
                syncRequested = false
                while let next = pending.first {
                    if outboxNeedsSave {
                        try savePendingEdits()
                    }
                    let append = SharedReviewAPI.Append(sessionId: session, clientOpId: next.clientOpId,
                                                         payload: next.payload)
                    let receipt: SharedReviewAPI.Receipt = try await authenticatedSyncResponse(api: api, generation: generation, session: session) {
                        try await api.post("documents/\(document)/ops", append)
                    }
                    try checkLifecycle(generation, api: api)
                    guard sessionID == session else { return }
                    guard receipt.op.payload?.id == next.payload.id, receipt.op.payload?.page == next.payload.page else {
                        updateReviewConnection(online: false)
                        throw SharedReviewError("The server returned an unexpected revision receipt.")
                    }
                    updateReviewConnection(online: true)
                    pending.removeFirst()
                    uncheckpointedAcknowledgements += 1
                    if uncheckpointedAcknowledgements >= Self.acknowledgementBatchSize {
                        try savePendingEdits()
                    }
                }
                if uncheckpointedAcknowledgements > 0 { try savePendingEdits() }
                let response: SharedReviewAPI.Operations = try await authenticatedSyncResponse(api: api, generation: generation, session: session) {
                    try await api.get("documents/\(document)/ops", query: [
                        URLQueryItem(name: "afterSeq", value: String(revision))
                    ])
                }
                try checkLifecycle(generation, api: api)
                guard sessionID == session else { return }
                updateReviewConnection(online: true)
                try replayOperations(response.ops, instanceID: api.instanceID)
                if response.ops.count == 500 { syncRequested = true }
            } while syncRequested || !pending.isEmpty
            let wasReady = ready
            ready = true
            if invalidPages.isEmpty { updateReviewStatus("Synced · Revision \(revision)") }
            if !wasReady, editor?.pdfView.document === reviewPDF { editor?.refreshRectangleToolbar() }
        } catch {
            guard lifecycle == generation, !sessionInvalidated, sessionID == session else { return }
            // Flush a partial batch on ordinary transport failure. A failed disk
            // checkpoint is not retried here: stop and keep the old disk snapshot.
            if uncheckpointedAcknowledgements > 0, !outboxNeedsSave {
                do { try savePendingEdits() }
                catch { /* outboxNeedsSave retains the actionable persistence error. */ }
            }
            if outboxNeedsSave {
                updateReviewStatus("Review · Edits could not be saved on this Mac")
            } else if (error as? SharedReviewError)?.statusCode == 403 {
                ready = false
                updateReviewStatus("Review access ended · \(pending.count) pending")
                editor?.refreshRectangleToolbar()
            } else if let error = error as? URLError, error.code != .cancelled {
                updateReviewStatus("Offline · \(pending.count) pending")
            } else {
                updateReviewStatus("Review · \(pending.count) pending · \(error.localizedDescription)")
            }
        }
    }

    private func updateReviewStatus(_ message: String) {
        guard syncStatus != message else { return }
        syncStatus = message
        // updateStatusBar refreshes all pane headers, including an inactive Review.
        editor?.updateStatusBar()
    }

    private func authenticatedSyncResponse<Value>(api: SharedReviewAPI, generation: UUID, session: String,
                                                   request: () async throws -> Value) async throws -> Value {
        do {
            let response = try await request()
            try checkLifecycle(generation, api: api)
            guard sessionID == session else { throw CancellationError() }
            return response
        } catch {
            // Late completions from a closed/signed-out review cannot revive it or
            // overwrite the transport state of a replacement session.
            if lifecycle == generation, sessionID == session, !sessionInvalidated {
                updateReviewConnection(online: false)
            }
            throw error
        }
    }

    private func updateReviewConnection(online: Bool) {
        let wasOnline = reviewIsOnline
        connectionExpiryTask?.cancel()
        connectionExpiryTask = nil
        if online {
            reviewConnection.receivedResponse(at: ProcessInfo.processInfo.systemUptime)
            let generation = lifecycle
            let session = sessionID
            // Independent of the poll task: a hung request must not stay Online.
            connectionExpiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(ReviewSyncConnection.freshness)) }
                catch { return }
                guard !Task.isCancelled, let self, self.lifecycle == generation, self.sessionID == session else { return }
                self.updateReviewConnection(online: false)
            }
        } else {
            reviewConnection.disconnect()
        }
        // Do not gate on syncStatus changing: repeated empty polls keep the same
        // revision, and connection failures/recovery are independent of the outbox.
        // A healthy repeated poll need not run the editor's expensive status refresh.
        if !online || !wasOnline { editor?.updateStatusBar() }
    }

    // Internal observation of actual replay UI invalidations for controller regression tests.
    enum ReplayRefresh: Equatable { case page(Int), selectionAndList }
    var replayRefreshObserver: ((ReplayRefresh) -> Void)?

    func replayOperations(_ operations: [SharedReviewAPI.Operation], instanceID: String) throws {
        guard !sessionInvalidated else { throw CancellationError() }
        // Scoped to one fetched response, including a partially applied response.
        // No suspension: revision/order and local-edit shielding remain sequential.
        var touchedPages = Set<Int>()
        defer { refreshReplayPages(touchedPages) }
        for operation in operations {
            if operation.op_type == "drawbridge.markup.v1", let markup = operation.payload,
               !pending.contains(where: { $0.payload.id == markup.id }) {
                if try apply(markup, owned: markup.ownerInstanceId == instanceID) {
                    touchedPages.insert(markup.page)
                }
            }
            revision = operation.seq
        }
    }

    private func refreshReplayPages(_ indices: Set<Int>) {
        guard !indices.isEmpty, let pdf = reviewPDF, let editor,
              editor.pdfView.document === pdf else { return }
        let viewer = editor.pdfView
        for index in indices.sorted() {
            guard let page = pdf.page(at: index) else { continue }
            viewer.refreshAnnotationRendering(on: page, importedAppearanceChanged: true)
            editor.markPageMarkupCacheDirty(page)
            replayRefreshObserver?(.page(index))
        }
        viewer.rectangleMarkup.refresh()
        editor.scheduleMarkupsRefresh(selecting: viewer.rectangleMarkup.selected)
        replayRefreshObserver?(.selectionAndList)
    }

    private func apply(_ markup: SharedReviewAPI.Markup, owned: Bool) throws -> Bool {
        let viewer = editor?.pdfView
        let visibleViewer = viewer?.document === reviewPDF ? viewer : nil
        guard let page = reviewPDF?.page(at: markup.page) else {
            throw SharedReviewError("A revision refers to a missing page.")
        }
        if owned, markup.record == nil { retiredIDs.insert(markup.id) }
        if owned, records[markup.page]?[markup.id] == markup.record { return false }
        let replacement = try markup.record.map { record -> PDFAnnotation in
            guard record.id == markup.id, record.pageIndex == markup.page else {
                throw SharedReviewError("A revision contains an invalid markup ID.")
            }
            let annotation = try record.clipboardAnnotation(contents: record.text, rotation: page.rotation)
            annotation.setValue(record.id, forAnnotationKey: RectangleMarkupRecord.identityKey)
            annotation.isReadOnly = !owned
            return annotation
        }
        if let existing = page.annotations.first(where: { RectangleMarkupRecord.identity($0) == markup.id }) {
            if visibleViewer?.rectangleMarkup.isEditingTextAnnotation(existing) == true {
                throw SharedReviewError("Finish editing text to receive the latest revision.")
            }
            if visibleViewer?.rectangleMarkup.selectedItems.contains(where: { $0 === existing }) == true {
                visibleViewer?.rectangleMarkup.selected = nil
            }
            page.removeAnnotation(existing)
        }
        if let replacement { page.addAnnotation(replacement) }
        records[markup.page, default: [:]][markup.id] = owned ? markup.record : nil
        return true
    }

    func canQuit() -> Bool {
        guard !busy else { return false }
        let reviews = [self] + Array(additionalReviews.values)
        for review in reviews { review.retryPendingEditsSave() }
        guard reviews.allSatisfy({ !$0.hasPendingChanges }) else {
            NSSound.beep()
            return false
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
}
