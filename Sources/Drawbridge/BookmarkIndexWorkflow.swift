import AppKit


/// Retained by AppDelegate, independent of every viewer/document/session.
@MainActor final class BookmarkIndexWorkflow: NSObject, NSMenuItemValidation {
    private(set) var busy = false
    private(set) var result: BookmarkIndexResult?
    private(set) var message = ""
    // Panel/presentation seams exercise the SAME production state machine without
    // modal automation. Nil uses real native panels and completion alerts.
    var chooseFolder: ((@escaping (URL?) -> Void) -> Void)?
    var resolveDownloads: () throws -> URL = {
        try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    }
    var confirmReplace: ((URL) -> Bool)?
    var confirmHeaderOnly: (() -> Bool)?
    var notify: ((String) -> Void)?
    var onProcessingStarted: (@Sendable () -> Void)?
    private var cancellation: PDFProcessingCancellation?
    private var progressWindow: NSPanel?
    private var progressLabel: NSTextField?
    private var folderPanel: NSOpenPanel?

    private var generation = UUID()

    func validateMenuItem(_ item: NSMenuItem) -> Bool { !busy }
    @objc func showExtract(_ sender: Any?) {
        guard !busy else { return }
        busy = true
        result = nil
        let completion: (URL?) -> Void = { [weak self] url in
            guard let self else { return }
            self.folderPanel = nil
            self.busy = false
            if let url { self.start(folder: url) }
        }
        if let chooseFolder { chooseFolder(completion); return }
        let panel = NSOpenPanel()
        folderPanel = panel
        panel.title = "Extract Bookmark Index"
        panel.message = "Choose a folder. PDFs are read privately; files containing ARCH in their name are excluded."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in completion(response == .OK ? panel.url : nil) }
    }
    func start(folder: URL) {
        guard !busy else { return }
        busy = true
        result = nil
        let token = PDFProcessingCancellation(), id = UUID()
        generation = id
        cancellation = token
        message = "Discovering PDFs…"
        if notify == nil { showProgress() }
        let started = onProcessingStarted
        // The security scope covers discovery and all child reads, then closes
        // on the same worker after extraction. No persistent bookmarks needed.
        DispatchQueue.global(qos: .userInitiated).async {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            started?()
            let outcome = Result {
                try BookmarkIndexExport.extract(folder, cancelled: { token.cancelled }) { done, total, excluded in
                    DispatchQueue.main.async {
                        guard self.generation == id else { return }
                        self.message = "Reading PDFs: \(done)/\(total) • \(excluded) excluded (ARCH)"
                        self.progressLabel?.stringValue = self.message
                    }
                }
            }
            DispatchQueue.main.async {
                guard self.generation == id else { return }
                self.hideProgress()
                if token.cancelled { self.finish("Canceled. No output was written."); return }
                switch outcome {
                case .failure(let error):
                    self.finish(error is CancellationError ? "Canceled. No output was written." : "Extract Bookmark Index failed: \(error.localizedDescription)")
                case .success(let value):
                    self.result = value
                    guard value.files > 0 else {
                        self.finish(value.excluded > 0 ? "No eligible PDFs remain: \(value.excluded) PDFs excluded (ARCH)." : "No PDFs found in the selected folder.")
                        return
                    }
                    self.save(value, id: id, token: token)
                }
            }
        }
    }
    private func save(_ value: BookmarkIndexResult, id: UUID, token: PDFProcessingCancellation) {
        let destination: URL
        do {
            let downloads = try resolveDownloads()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: downloads.path, isDirectory: &isDirectory),
                  isDirectory.boolValue, FileManager.default.isWritableFile(atPath: downloads.path) else {
                throw NSError(domain: "BookmarkIndex", code: 1, userInfo: [NSLocalizedDescriptionKey: "Downloads is unavailable or not writable: \(downloads.path)"])
            }
            destination = downloads.appendingPathComponent("combined_bookmarks.csv")
        } catch {
            finish("Could not save bookmark index to Downloads: \(error.localizedDescription)")
            return
        }
        guard !token.cancelled else { finish("Canceled. No output was written."); return }
        if value.rows == 0 {
            let accepted = confirmHeaderOnly?() ?? confirm(title: "Save header-only bookmark index?", text: "No nonempty bookmark titles found. Save a header-only CSV to \(destination.path)?", action: "Save")
            guard accepted else { finish("Canceled. No output was written."); return }
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            let accepted = confirmReplace?(destination) ?? confirm(title: "Replace combined_bookmarks.csv?", text: "A file already exists at \(destination.path). Replacing it cannot be undone.", action: "Replace")
            guard accepted else { finish("Canceled. No output was written."); return }
        }
        let completion: (URL?) -> Void = { [weak self] destination in
            guard let self, self.generation == id else { return }
            guard let destination, !token.cancelled else { self.finish("Canceled. No output was written."); return }
            self.message = "Saving bookmark index…"
            if self.notify == nil { self.showProgress() }
            DispatchQueue.global(qos: .userInitiated).async {
                let scoped = destination.startAccessingSecurityScopedResource()
                defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
                let outcome = Result { try BookmarkIndexExport.write(value, to: destination, cancelled: { token.cancelled }) }
                DispatchQueue.main.async {
                    guard self.generation == id else { return }
                    self.hideProgress()
                    switch outcome {
                    case .success: self.finish("Bookmark index saved: \(value.rows) titles from \(value.files) PDFs • \(value.excluded) excluded (ARCH).\n\(destination.path)")
                    case .failure(let error): self.finish(error is CancellationError ? "Canceled. No output was written." : "Could not save bookmark index: \(error.localizedDescription)")
                    }
                }
            }
        }
        completion(destination)
    }
    private func confirm(title: String, text: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
    @objc func cancel(_ sender: Any?) {
        cancellation?.cancel()
        message = "Canceling after the current PDF read…"
        progressLabel?.stringValue = message
    }
    private func finish(_ text: String) {
        busy = false
        cancellation = nil
        message = text
        if let notify { notify(text); return }
        let alert = NSAlert()
        alert.messageText = "Extract Bookmark Index"
        alert.informativeText = text
        alert.runModal()
    }
    private func showProgress() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 490, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Extract Bookmark Index"
        let label = NSTextField(wrappingLabelWithString: message)
        label.frame = NSRect(x: 20, y: 76, width: 450, height: 40)
        panel.contentView?.addSubview(label)
        progressLabel = label
        let indicator = NSProgressIndicator(frame: NSRect(x: 20, y: 50, width: 450, height: 16))
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        panel.contentView?.addSubview(indicator)
        let button = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        button.frame = NSRect(x: 370, y: 10, width: 100, height: 30)
        button.keyEquivalent = "\u{1b}"
        panel.contentView?.addSubview(button)
        progressWindow = panel
        panel.center()
        panel.orderFront(nil)
    }
    private func hideProgress() {
        progressWindow?.orderOut(nil)
        progressWindow = nil
        progressLabel = nil
    }
}
