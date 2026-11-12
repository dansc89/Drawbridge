import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class SharedReviewWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    weak var editor: MainViewController?
    private(set) var tabURL: URL?
    private(set) var reviewPDF: PDFDocument?
    private(set) var basePDF: Data?
    private(set) var syncStatus = ""
    var canEdit: Bool { ready }
    var hasPendingChanges: Bool { !invalidPages.isEmpty || outboxNeedsSave }
    private let outboxDirectory: URL?
    private let cacheDirectory: URL?
    private var outbox: SharedReviewOutbox?
    private var outboxNeedsSave = false
    private var invalidPages = Set<Int>()
    private var retiredIDs = Set<String>()
    private let documentsTable = NSTableView()
    private let workspaceLabel = NSTextField(labelWithString: "Server Documents")
    private lazy var openButton = button("Open", #selector(openSelected))
    private lazy var uploadButton = button("Upload PDF…", #selector(uploadPDF))
    private lazy var refreshButton = button("Refresh", #selector(refreshDocuments(_:)))
    private let status = NSTextField(labelWithString: "Choose a shared PDF.")
    private lazy var backButton = button("Back", #selector(goBack))
    private lazy var newFolderButton = button("New Folder…", #selector(createFolder))
    private lazy var deleteButton = button("Delete…", #selector(deleteSelectedItem))
    private static let reviewDocumentDrag = NSPasteboard.PasteboardType("com.drawbridge.review.document-id")
    private var organizationActions = false
    private var deleteConfirmationUsername: String?
    private weak var confirmDeleteButton: NSButton?
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

    init(outboxDirectory: URL? = nil, cacheDirectory: URL? = nil) {
        self.outboxDirectory = outboxDirectory
        self.cacheDirectory = cacheDirectory
        super.init(window: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func showReviews(_ sender: Any?) {
        if window == nil { buildWindow() }
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        refreshDocuments(nil)
    }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 390),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Drawbridge Review — Server Documents"
        window.minSize = NSSize(width: 400, height: 240)
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.resizingMask = .autoresizingMask
        documentsTable.addTableColumn(nameColumn)
        documentsTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        documentsTable.usesAlternatingRowBackgroundColors = true
        documentsTable.delegate = self
        documentsTable.dataSource = self
        documentsTable.target = self
        documentsTable.doubleAction = #selector(openClickedDocument)
        documentsTable.registerForDraggedTypes([Self.reviewDocumentDrag, .fileURL])
        documentsTable.setDraggingSourceOperationMask(.move, forLocal: true)
        documentsTable.setAccessibilityLabel("Server Documents")
        documentsTable.rowHeight = 24

        let list = NSScrollView()
        list.hasVerticalScroller = true
        list.borderType = .bezelBorder
        list.documentView = documentsTable
        list.translatesAutoresizingMaskIntoConstraints = false

        workspaceLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        workspaceLabel.lineBreakMode = .byTruncatingMiddle
        status.maximumNumberOfLines = 2
        openButton.keyEquivalent = "\r"
        let controls = NSStackView(views: [backButton, newFolderButton, uploadButton, refreshButton, deleteButton, NSView(), openButton])
        controls.spacing = 8
        let stack = NSStackView(views: [workspaceLabel, list, status, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let content = window.contentView {
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                list.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
                controls.widthAnchor.constraint(equalTo: list.widthAnchor)
            ])
        }
        window.initialFirstResponder = documentsTable
        updateBrowserControls()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entries = visibleFolders
        let name = entries.indices.contains(row)
            ? "▸  " + entries[row].name : visibleDocuments[row - entries.count].name
        let field = NSTextField(labelWithString: name)
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateBrowserControls() }

    private func updateBrowserControls() {
        openButton.isEnabled = !busy && (0..<rowCount).contains(documentsTable.selectedRow)
        uploadButton.isEnabled = !busy && project != nil
        refreshButton.isEnabled = !busy
        newFolderButton.isEnabled = !busy && folders != nil
        backButton.isEnabled = !busy && folderID != nil
        deleteButton.isEnabled = !busy && organizationActions && (0..<rowCount).contains(documentsTable.selectedRow)
    }

    @objc private func openClickedDocument() {
        guard (0..<rowCount).contains(documentsTable.clickedRow) else { return }
        openSelected()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    @objc private func refreshDocuments(_ sender: Any?) {
        perform { try await self.loadDocuments() }
    }

    private func loadDocuments() async throws {
        let (origin, credentials) = try SettingsWindowController.sharedReviewCredentials()
        let api = SharedReviewAPI(origin: origin, token: credentials.token, displayName: credentials.displayName, instanceID: credentials.instanceId)
        let projects: SharedReviewAPI.ProjectList = try await api.get("projects")
        guard let project = projects.projects.first(where: { $0.name == "AERO Collective" }) ?? projects.projects.first else {
            throw SharedReviewError("Your account has no shared projects.")
        }
        let list: SharedReviewAPI.DocumentList = try await api.get("projects/\(project.id)/documents")
        let key = "DrawbridgeReviewFolder|\(origin.absoluteString)|\(api.instanceID)|\(project.id)"
        if workspaceKey != key {
            workspaceKey = key
            folderID = UserDefaults.standard.string(forKey: key)
        }
        self.project = project
        self.api = api
        organizationActions = list.organizationActions == true
        folders = list.folders?.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        documents = list.documents.filter { $0.file_size != nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !(folders ?? []).contains(where: { $0.id == folderID }) { folderID = nil }
        showFolder()
    }

    private func showFolder() {
        if let workspaceKey { UserDefaults.standard.set(folderID, forKey: workspaceKey) }
        var names: [String] = []
        var cursor = folderID
        var visited = Set<String>()
        while let id = cursor, visited.insert(id).inserted,
              let folder = folders?.first(where: { $0.id == id }) {
            names.append(folder.name)
            cursor = folder.parent_id
        }
        workspaceLabel.stringValue = ([project?.name ?? "Server Documents"] + names.reversed()).joined(separator: "  /  ")
        documentsTable.reloadData()
        documentsTable.deselectAll(nil)
        status.stringValue = rowCount == 0 ? "This folder is empty." : "\(rowCount) items"
        updateBrowserControls()
    }

    @objc private func goBack() {
        guard !busy, let folderID else { return }
        self.folderID = folders?.first(where: { $0.id == folderID })?.parent_id
        showFolder()
    }

    @objc private func createFolder() {
        guard !busy, let window, let project, let api, folders != nil else { return }
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        name.placeholderString = "Folder name"
        alert.accessoryView = name
        alert.window.initialFirstResponder = name
        let parent = folderID
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            self.perform {
                _ = try await self.requireReviewUsername(using: api, saveToSettings: true)
                let _: SharedReviewAPI.CreatedFolder = try await api.post("projects/\(project.id)/folders",
                    SharedReviewAPI.FolderRequest(name: title, parentId: parent))
                try await self.loadDocuments()
            }
        }
    }

    @objc private func openSelected() {
        let index = documentsTable.selectedRow
        guard !busy, (0..<rowCount).contains(index) else { return }
        let entries = visibleFolders
        if entries.indices.contains(index) {
            folderID = entries[index].id
            showFolder()
            return
        }
        let document = visibleDocuments[index - entries.count]
        perform { try await self.open(document) }
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
        guard !busy, !hasPendingChanges, api != nil, project != nil else { return [] }
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
        guard !busy, !hasPendingChanges, let api, let project else { return false }
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
            perform {
                for file in files { try self.validateUpload(file) }
                _ = try await self.requireReviewUsername(using: api, saveToSettings: true)
                var uploaded = 0
                do {
                    for file in files {
                        _ = try await api.upload(file, project: project, folderID: destination)
                        uploaded += 1
                    }
                } catch {
                    if uploaded > 0 { try? await self.loadDocuments() }
                    throw SharedReviewError("Uploaded \(uploaded) of \(files.count) PDFs. \(error.localizedDescription)")
                }
                try await self.loadDocuments()
                self.status.stringValue = "Uploaded \(uploaded) \(uploaded == 1 ? "PDF" : "PDFs")."
            }
        }
        return true
    }

    private func validateUpload(_ file: URL) throws {
        guard let pdf = PDFDocument(url: file), pdf.pageCount > 0, !pdf.isLocked else {
            throw SharedReviewError("Choose a readable, unlocked PDF.")
        }
    }

    @objc private func deleteSelectedItem() {
        let row = documentsTable.selectedRow
        guard !busy, organizationActions, let api, let project, let window,
              (0..<rowCount).contains(row) else { return }
        let entries = visibleFolders
        let folder = entries.indices.contains(row) ? entries[row] : nil
        let document = folder == nil ? visibleDocuments[row - entries.count] : nil
        guard let id = folder?.id ?? document?.id, let name = folder?.name ?? document?.name else { return }
        if documentID == id && !pending.isEmpty {
            status.stringValue = "Wait for this PDF’s pending edits to sync before deleting it."
            return
        }
        perform {
            let username = try await self.requireReviewUsername(using: api, saveToSettings: true)
            let warning = NSAlert()
            warning.alertStyle = .warning
            warning.messageText = "Delete “\(name)”?"
            warning.informativeText = folder == nil
                ? "This PDF will be removed from the workspace for everyone. Recovery requires a server administrator."
                : "Only empty folders can be deleted. Move or delete its contents first."
            warning.addButton(withTitle: "Continue")
            warning.addButton(withTitle: "Cancel")
            let response = await withCheckedContinuation { continuation in
                warning.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            guard response == .alertFirstButtonReturn else { self.showFolder(); return }

            let confirm = NSAlert()
            confirm.messageText = "Confirm deletion"
            confirm.informativeText = "Enter your Review username exactly as shown: \(username)"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 270, height: 24))
            field.delegate = self
            confirm.accessoryView = field
            let submit = confirm.addButton(withTitle: "Delete")
            confirm.addButton(withTitle: "Cancel")
            submit.isEnabled = false
            confirm.window.initialFirstResponder = field
            self.deleteConfirmationUsername = username
            self.confirmDeleteButton = submit
            let finalResponse = await withCheckedContinuation { continuation in
                confirm.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            self.deleteConfirmationUsername = nil
            self.confirmDeleteButton = nil
            guard finalResponse == .alertFirstButtonReturn, field.stringValue == username else {
                self.showFolder()
                return
            }
            do {
                let _: SharedReviewAPI.OrganizationReceipt = try await api.post("projects/\(project.id)/remove-item",
                    SharedReviewAPI.RemoveRequest(kind: folder == nil ? "document" : "folder", id: id, confirmation: username))
            } catch let error as SharedReviewError where error.statusCode == 409 && folder != nil {
                throw SharedReviewError("Move or delete the folder’s contents first.")
            }
            if self.documentID == id {
                self.ready = false
                self.updateReviewStatus("Removed from workspace")
                self.editor?.refreshRectangleToolbar()
            }
            try await self.loadDocuments()
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        confirmDeleteButton?.isEnabled = field.stringValue == deleteConfirmationUsername
    }

    @objc private func uploadPDF() {
        guard !busy, let window, let project, let api else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let file = panel.url, let self else { return }
            self.perform {
                try self.validateUpload(file)
                _ = try await self.requireReviewUsername(using: api, saveToSettings: true)
                let document = try await api.upload(file, project: project, folderID: self.folderID)
                try await self.loadDocuments()
                try await self.open(document)
            }
        }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy, !hasPendingChanges else {
            status.stringValue = "Wait for pending markup revisions to sync."
            return
        }
        busy = true
        updateBrowserControls()
        status.stringValue = "Contacting server…"
        Task {
            defer {
                busy = false
                updateBrowserControls()
            }
            do { try await work() }
            catch { status.stringValue = error.localizedDescription }
        }
    }

    func open(_ document: SharedReviewAPI.Document, using connection: SharedReviewAPI? = nil) async throws {
        guard let api = connection ?? api, let editor else { return }
        if window == nil { buildWindow() }
        guard !hasPendingChanges else { throw SharedReviewError("Wait for the current review to sync before opening another.") }
        if documentID == document.id, let tabURL, reviewAPI?.origin == api.origin, reviewAPI?.instanceID == api.instanceID {
            guard editor.confirmDiscardUnsavedChangesIfNeeded() else { return }
            editor.openDocument(at: tabURL)
            showEditor(editor)
            return
        }
        let username = try await requireReviewUsername(using: api, saveToSettings: connection == nil)
        // Recheck access before serving locally retained drawing bytes.
        let response: SharedReviewAPI.CreatedSession = try await api.post("documents/\(document.id)/sessions", ["name": "Drawbridge Review"])
        let cache = try SharedReviewPDFCache(origin: api.origin, instanceID: api.instanceID,
                                             document: document, directory: cacheDirectory)
        let bytes: Data
        let cached = try cache?.load()
        if let cached {
            bytes = cached
        } else {
            bytes = try await api.download(document)
        }
        guard let pdf = PDFDocument(data: bytes), pdf.pageCount > 0, !pdf.isLocked else {
            throw SharedReviewError("The shared PDF could not be opened.")
        }
        if cached == nil { try cache?.store(bytes) }
        let outbox = try SharedReviewOutbox(origin: api.origin, instanceID: api.instanceID,
                                            documentID: document.id, basePDF: bytes, directory: outboxDirectory)
        let recoveredEdits = try outbox.load()
        guard editor.confirmDiscardUnsavedChangesIfNeeded(), !hasPendingChanges, !editor.isPDFProcessingBusy else { return }
        if editor.secondaryPDFView != nil { editor.collapsePDFSplit() }
        if let tabURL { editor.unregisterSessionDocument(tabURL) }
        stopSync()
        self.outbox = outbox
        pending = recoveredEdits
        reviewAPI = api
        reviewUsername = username
        documentID = document.id
        sessionID = response.session.id
        revision = 0
        records.removeAll()
        invalidPages.removeAll()
        retiredIDs.removeAll()
        for index in 0..<pdf.pageCount {
            for annotation in pdf.page(at: index)?.annotations ?? [] where annotation.type != "Link" {
                annotation.isReadOnly = true
            }
        }
        let filename = URL(fileURLWithPath: document.name).lastPathComponent
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(filename.lowercased().hasSuffix(".pdf") ? filename : filename + ".pdf")
        tabURL = editor.canonicalDocumentURL(url)
        reviewPDF = pdf
        basePDF = bytes
        syncStatus = "Connecting…"
        editor.openDocument(at: url)
        showEditor(editor)
        startSync(api: api, document: document.id, session: response.session.id)
    }

    private func showEditor(_ editor: MainViewController) {
        window?.orderOut(nil)
        editor.view.window?.makeKeyAndOrderFront(nil)
    }

    func closeTab(at url: URL) {
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
        let capabilities: SharedReviewAPI.Capabilities = try await api.get("auth/me")
        guard capabilities.reviewUsernames == true else {
            throw SharedReviewError("This server needs the Drawbridge Review username update.")
        }
        guard capabilities.creatorOnlyMarkups == true else {
            throw SharedReviewError("Sign in again in General settings to use Drawbridge Review.")
        }
        let username: String
        if let existing = capabilities.reviewUsername {
            username = existing
        } else {
            username = try await chooseReviewUsername(using: api)
        }
        if saveToSettings { UserDefaults.standard.set(username, forKey: "drawbridgeReviewUsername") }
        return username
    }

    private func chooseReviewUsername(using api: SharedReviewAPI) async throws -> String {
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
            let response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            alert.accessoryView = nil
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
        let socket = api.socket()
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
            } catch { /* Periodic replay keeps the review usable if the socket disconnects. */ }
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
        syncTask?.cancel()
        listenTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        syncTask = nil
        listenTask = nil
        socket = nil
        sessionID = nil
        syncRequested = false
    }

    func recordChanges(on page: PDFPage) {
        guard let sessionID, let outbox, let pdf = reviewPDF, page.document === pdf else { return }
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
        if outboxNeedsSave {
            do {
                try outbox.save(pending)
                outboxNeedsSave = false
            } catch {
                updateReviewStatus("Review · Edits could not be saved on this Mac")
                return
            }
        }
        if !pending.isEmpty { updateReviewStatus("Saving… · \(pending.count) pending") }
        if let api = reviewAPI, let documentID {
            Task { await sync(api: api, document: documentID, session: sessionID) }
        }
    }

    private func sync(api: SharedReviewAPI, document: String, session: String) async {
        guard sessionID == session, let outbox, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            repeat {
                syncRequested = false
                while let next = pending.first {
                    if outboxNeedsSave {
                        try outbox.save(pending)
                        outboxNeedsSave = false
                    }
                    let append = SharedReviewAPI.Append(sessionId: session, clientOpId: next.clientOpId,
                                                         payload: next.payload)
                    let receipt: SharedReviewAPI.Receipt = try await api.post("documents/\(document)/ops", append)
                    guard sessionID == session else { return }
                    guard receipt.op.payload?.id == next.payload.id, receipt.op.payload?.page == next.payload.page else {
                        throw SharedReviewError("The server returned an unexpected revision receipt.")
                    }
                    let remaining = Array(pending.dropFirst())
                    try outbox.save(remaining)
                    pending = remaining
                    outboxNeedsSave = false
                }
                let response: SharedReviewAPI.Operations = try await api.get("documents/\(document)/ops", query: [
                    URLQueryItem(name: "afterSeq", value: String(revision))
                ])
                guard sessionID == session else { return }
                for operation in response.ops {
                    if operation.op_type == "drawbridge.markup.v1", let markup = operation.payload,
                       !pending.contains(where: { $0.payload.id == markup.id }) {
                        try apply(markup, owned: markup.ownerInstanceId == api.instanceID)
                    }
                    revision = operation.seq
                }
                if response.ops.count == 500 { syncRequested = true }
            } while syncRequested || !pending.isEmpty
            let wasReady = ready
            ready = true
            if invalidPages.isEmpty { updateReviewStatus("Synced · Revision \(revision)") }
            if !wasReady, editor?.isActiveReview == true { editor?.refreshRectangleToolbar() }
        } catch {
            guard sessionID == session else { return }
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
        if editor?.isActiveReview == true { editor?.updateStatusBar() }
    }

    private func apply(_ markup: SharedReviewAPI.Markup, owned: Bool) throws {
        let viewer = editor?.pdfView
        let visibleViewer = viewer?.document === reviewPDF ? viewer : nil
        guard let page = reviewPDF?.page(at: markup.page) else {
            throw SharedReviewError("A revision refers to a missing page.")
        }
        if owned, markup.record == nil { retiredIDs.insert(markup.id) }
        if owned, records[markup.page]?[markup.id] == markup.record { return }
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
        visibleViewer?.refreshAnnotationRendering(on: page, importedAppearanceChanged: true)
        visibleViewer?.rectangleMarkup.refresh()
        if visibleViewer != nil {
            editor?.markPageMarkupCacheDirty(page)
            editor?.scheduleMarkupsRefresh(selecting: visibleViewer?.rectangleMarkup.selected)
        }
    }

    func canQuit() -> Bool {
        guard !hasPendingChanges, !busy else {
            NSSound.beep()
            return false
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
}
