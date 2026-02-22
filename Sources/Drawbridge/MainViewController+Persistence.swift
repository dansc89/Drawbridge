import AppKit
import PDFKit

@MainActor
extension MainViewController {
    func sidecarURL(for sourcePDFURL: URL) -> URL {
        snapshotStore.sidecarURL(for: sourcePDFURL)
    }

    func cleanupLegacyJSONArtifacts(for sourcePDFURL: URL) {
        snapshotStore.cleanupLegacyJSONArtifacts(for: sourcePDFURL, autosaveDirectory: autosaveDirectoryURL())
    }

    func buildSidecarSnapshot(document: PDFDocument, sourcePDFURL: URL) -> SidecarSnapshot {
        snapshotStore.buildSnapshot(
            document: document,
            sourcePDFURL: sourcePDFURL,
            initialCapacity: totalCachedAnnotationCount(),
            resolvedLineWidth: { annotation in
                self.resolvedLineWidth(for: annotation)
            }
        )
    }

    func loadSidecarSnapshotIfAvailable(for sourcePDFURL: URL, document: PDFDocument) {
        snapshotStore.loadSnapshotIfAvailable(for: sourcePDFURL, document: document) { lineWidth, annotation in
            self.assignLineWidth(lineWidth, to: annotation)
        }
    }

    func persistProjectSnapshot(document: PDFDocument, for sourcePDFURL: URL, busyMessage: String) {
        let saveSpan = PerformanceMetrics.begin(
            "save_project_snapshot",
            thresholdMs: 150,
            fields: ["file": sourcePDFURL.lastPathComponent]
        )
        let pageCount = document.pageCount
        persistenceCoordinator.beginManualSave()
        beginBusyIndicator(busyMessage, detail: "Packing markups…", lockInteraction: false)
        startSaveProgressTracking(phase: "Packing")
        let sidecar = sidecarURL(for: sourcePDFURL)
        let started = CFAbsoluteTimeGetCurrent()
        let snapshot = buildSidecarSnapshot(document: document, sourcePDFURL: sourcePDFURL)
        let snapshotStore = self.snapshotStore
        updateSaveProgressPhase("Writing")
        updateBusyIndicatorDetail("Writing project file…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let success = snapshotStore.writeSnapshot(snapshot, to: sidecar)
            let elapsed = CFAbsoluteTimeGetCurrent() - started

            DispatchQueue.main.async {
                guard let self else { return }
                defer {
                    self.stopSaveProgressTracking()
                    self.endBusyIndicator()
                    self.persistenceCoordinator.endManualSave {
                        self.scheduleAutosave()
                    }
                }
                guard success else {
                    PerformanceMetrics.end(saveSpan, extra: ["result": "failed"])
                    self.updateBusyIndicatorDetail(String(format: "Project save failed after %.2fs", elapsed))
                    let alert = NSAlert()
                    alert.messageText = "Failed to save project"
                    alert.informativeText = "Could not write \(sidecar.lastPathComponent)."
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }
                self.updateBusyIndicatorDetail(String(format: "Saved project in %.2fs", elapsed))
                PerformanceMetrics.end(
                    saveSpan,
                    extra: [
                        "result": "ok",
                        "pages": "\(pageCount)",
                        "cached_markups": "\(self.totalCachedAnnotationCount())"
                    ]
                )
                self.markupChangeVersion = 0
                self.lastAutosavedChangeVersion = 0
                self.lastMarkupEditAt = .distantPast
                self.lastUserInteractionAt = .distantPast
                self.view.window?.isDocumentEdited = false
                self.updateStatusBar()
            }
        }
    }

    func persistDocument(to url: URL, adoptAsPrimaryDocument: Bool, busyMessage: String, document: PDFDocument? = nil) {
        guard let document = document ?? pdfView.document else {
            NSSound.beep()
            return
        }
        guard !persistenceCoordinator.isManualSaveInFlight else {
            NSSound.beep()
            return
        }
        // Prevent expensive markup-list rebuild work from competing with save completion on main.
        pendingMarkupsRefreshWorkItem?.cancel()
        pendingMarkupsRefreshWorkItem = nil
        markupsScanGeneration += 1
        persistenceCoordinator.beginManualSave()
        isSavingDocumentOperation = true
        beginBusyIndicator(busyMessage, detail: "Generating PDF…", lockInteraction: false)
        startSaveProgressTracking(phase: "Generating")
        let targetURL = url
        let originDocumentURLForAdoption = openDocumentURL.map { canonicalDocumentURL($0) }
        let startedAt = CFAbsoluteTimeGetCurrent()
        let documentBox = PDFDocumentBox(document: document)
        let destinationAlreadyExists = FileManager.default.fileExists(atPath: targetURL.path)
        let destinationIsFileProvider = Self.isLikelyFileProviderURL(targetURL)
        let fallbackStagingURL = destinationAlreadyExists ? saveStagingFileURL(for: targetURL) : targetURL

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var success = false
            var errorDescription: String?
            var writeElapsed: Double = 0
            var commitElapsed: Double = 0

            if destinationIsFileProvider {
                // File-provider volumes (iCloud/CloudStorage/Drive) are often very slow when PDFKit writes directly.
                // Render locally first, then do a single commit to the destination path.
                let localStagingURL = Self.temporaryLocalSaveURL(for: targetURL)
                let stagedWriteStartedAt = CFAbsoluteTimeGetCurrent()
                success = Self.writePDFDocument(documentBox.document, to: localStagingURL)
                writeElapsed = CFAbsoluteTimeGetCurrent() - stagedWriteStartedAt

                if success {
                    Task { @MainActor [weak self] in
                        self?.saveGenerateElapsed = writeElapsed
                        self?.updateSaveProgressPhase("Committing")
                    }
                    let commitStartedAt = CFAbsoluteTimeGetCurrent()
                    do {
                        try Self.commitStagedSave(from: localStagingURL, to: targetURL)
                        success = true
                    } catch {
                        success = false
                        errorDescription = error.localizedDescription
                    }
                    commitElapsed = CFAbsoluteTimeGetCurrent() - commitStartedAt
                }

                if FileManager.default.fileExists(atPath: localStagingURL.path) {
                    try? FileManager.default.removeItem(at: localStagingURL)
                }
            } else if destinationAlreadyExists {
                // Fast path: overwrite directly to avoid expensive replace/copy on file-provider volumes.
                let directWriteStartedAt = CFAbsoluteTimeGetCurrent()
                success = Self.writePDFDocument(documentBox.document, to: targetURL)
                writeElapsed = CFAbsoluteTimeGetCurrent() - directWriteStartedAt

                if !success {
                    // Fallback path: stage + commit if direct overwrite fails.
                    Task { @MainActor [weak self] in
                        self?.updateSaveProgressPhase("Retrying")
                    }
                    let stagingURL = fallbackStagingURL
                    let stagedWriteStartedAt = CFAbsoluteTimeGetCurrent()
                    success = Self.writePDFDocument(documentBox.document, to: stagingURL)
                    writeElapsed = CFAbsoluteTimeGetCurrent() - stagedWriteStartedAt
                    if success {
                        Task { @MainActor [weak self] in
                            self?.saveGenerateElapsed = writeElapsed
                            self?.updateSaveProgressPhase("Committing")
                        }
                        let commitStartedAt = CFAbsoluteTimeGetCurrent()
                        do {
                            try Self.commitStagedSave(from: stagingURL, to: targetURL)
                            success = true
                        } catch {
                            success = false
                            errorDescription = error.localizedDescription
                        }
                        commitElapsed = CFAbsoluteTimeGetCurrent() - commitStartedAt
                    }
                    if FileManager.default.fileExists(atPath: stagingURL.path) {
                        try? FileManager.default.removeItem(at: stagingURL)
                    }
                }
            } else {
                let writeStartedAt = CFAbsoluteTimeGetCurrent()
                success = Self.writePDFDocument(documentBox.document, to: targetURL)
                writeElapsed = CFAbsoluteTimeGetCurrent() - writeStartedAt
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

            DispatchQueue.main.async {
                guard let self else { return }
                defer {
                    self.stopSaveProgressTracking()
                    self.endBusyIndicator()
                    self.isSavingDocumentOperation = false
                    self.persistenceCoordinator.endManualSave {
                        self.scheduleAutosave()
                    }
                }

                self.saveGenerateElapsed = writeElapsed
                guard success else {
                    if writeElapsed > 0, commitElapsed > 0 {
                        self.updateBusyIndicatorDetail(
                            String(format: "Write %.2fs • Commit %.2fs • Failed", writeElapsed, commitElapsed)
                        )
                    } else {
                        self.updateBusyIndicatorDetail(String(format: "Failed after %.2fs", elapsed))
                    }
                    let alert = NSAlert()
                    alert.messageText = "Failed to save PDF"
                    if let errorDescription, !errorDescription.isEmpty {
                        alert.informativeText = "Could not save \(targetURL.lastPathComponent).\n\n\(errorDescription)"
                    } else {
                        alert.informativeText = "Could not save \(targetURL.lastPathComponent)."
                    }
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }

                if writeElapsed > 0, commitElapsed > 0 {
                    self.updateBusyIndicatorDetail(
                        String(format: "Write %.2fs • Commit %.2fs • Done", writeElapsed, commitElapsed)
                    )
                } else {
                    self.updateBusyIndicatorDetail(String(format: "Saved in %.2fs", elapsed))
                }

                if adoptAsPrimaryDocument {
                    let newDocumentURL = self.canonicalDocumentURL(targetURL)
                    if let origin = originDocumentURLForAdoption,
                       origin != newDocumentURL {
                        self.cleanupLegacyJSONArtifacts(for: newDocumentURL)
                    }
                    self.openDocumentURL = newDocumentURL
                    self.registerSessionDocument(newDocumentURL)
                    self.configureAutosaveURL(for: newDocumentURL)
                    self.hasPromptedForInitialMarkupSaveCopy = true
                    self.isPresentingInitialMarkupSaveCopyPrompt = false
                    self.view.window?.title = "Drawbridge - \(newDocumentURL.lastPathComponent)"
                    self.onDocumentOpened?(newDocumentURL)
                }

                self.markupChangeVersion = 0
                self.lastAutosavedChangeVersion = 0
                self.lastMarkupEditAt = .distantPast
                self.lastUserInteractionAt = .distantPast
                self.view.window?.isDocumentEdited = false
                self.performRefreshMarkups(selecting: self.currentSelectedAnnotation(), forceImmediate: true)
                self.updateStatusBar()
            }
        }
    }

    nonisolated static func temporaryLocalSaveURL(for destinationURL: URL) -> URL {
        let name = destinationURL.lastPathComponent
        let token = UUID().uuidString
        return FileManager.default.temporaryDirectory.appendingPathComponent("\(token)-\(name)")
    }

    nonisolated static func isLikelyFileProviderURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path.lowercased()
        return path.contains("/mobile documents/")
            || path.contains("/icloud drive/")
            || path.contains("/cloudstorage/")
            || path.contains("/google drive/")
            || path.contains("/onedrive/")
            || path.contains("/dropbox/")
            || path.contains("/box/")
    }

    nonisolated static func commitStagedSave(from stagingURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            _ = try fm.replaceItemAt(destinationURL, withItemAt: stagingURL, backupItemName: nil, options: [])
            return
        }
        do {
            try fm.moveItem(at: stagingURL, to: destinationURL)
        } catch {
            try fm.copyItem(at: stagingURL, to: destinationURL)
            try? fm.removeItem(at: stagingURL)
        }
    }

    nonisolated static func writePDFDocument(_ document: PDFDocument, to url: URL) -> Bool {
        // `write(to:withOptions:)` is materially faster than `write(to:)` on large drawing sets.
        return document.write(to: url, withOptions: nil)
    }

    func autosaveDirectoryURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("Drawbridge").appendingPathComponent("Autosave")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    func configureAutosaveURL(for url: URL?) {
        autosaveURL = url
    }

    func scheduleAutosave() {
        persistenceCoordinator.scheduleAutosaveIfNeeded(
            canAutosave: hasPromptedForInitialMarkupSaveCopy
                && (autosaveURL ?? openDocumentURL) != nil
                && pdfView.document != nil,
            hasChanges: markupChangeVersion > 0
        ) { [weak self] in
            self?.performAutosaveNow()
        }
    }

    func performAutosaveNow() {
        guard let document = pdfView.document,
              let targetURL = autosaveURL ?? openDocumentURL,
              persistenceCoordinator.beginAutosaveRun(
                canRun: hasPromptedForInitialMarkupSaveCopy && markupChangeVersion > 0
              ) else {
            return
        }
        let autosaveSpan = PerformanceMetrics.begin(
            "autosave_project_snapshot",
            thresholdMs: 120,
            fields: [
                "file": targetURL.lastPathComponent,
                "snapshot_version": "\(markupChangeVersion)"
            ]
        )
        let snapshotVersion = markupChangeVersion
        let sidecar = sidecarURL(for: targetURL)
        let snapshot = buildSidecarSnapshot(document: document, sourcePDFURL: targetURL)
        let snapshotStore = self.snapshotStore

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let success = snapshotStore.writeSnapshot(snapshot, to: sidecar)

            DispatchQueue.main.async {
                guard let self else { return }

                if success {
                    self.lastAutosaveAt = Date()
                    if self.markupChangeVersion <= snapshotVersion {
                        self.markupChangeVersion = 0
                        self.lastAutosavedChangeVersion = 0
                        self.lastMarkupEditAt = .distantPast
                        self.lastUserInteractionAt = .distantPast
                        self.view.window?.isDocumentEdited = false
                        self.updateStatusBar()
                    } else {
                        self.lastAutosavedChangeVersion = snapshotVersion
                    }
                }
                PerformanceMetrics.end(
                    autosaveSpan,
                    extra: [
                        "result": success ? "ok" : "failed",
                        "current_version": "\(self.markupChangeVersion)",
                        "snapshot_version": "\(snapshotVersion)"
                    ]
                )

                self.persistenceCoordinator.finishAutosaveRun(stillHasChanges: self.markupChangeVersion > 0) {
                    self.scheduleAutosave()
                }
            }
        }
    }

    func saveCurrentDocumentForClosePrompt() -> Bool {
        guard let document = pdfView.document else { return true }
        if let sourceURL = openDocumentURL {
            return persistProjectSnapshotSynchronously(document: document, for: sourceURL, busyMessage: "Saving Changes…")
        }
        // Unsaved new document path still requires Save As flow.
        saveDocumentAsProject(document: document)
        return false
    }

    func persistProjectSnapshotSynchronously(document: PDFDocument, for sourcePDFURL: URL, busyMessage: String) -> Bool {
        persistenceCoordinator.beginManualSave()
        beginBusyIndicator(busyMessage, detail: "Saving…", lockInteraction: true)
        defer {
            endBusyIndicator()
            persistenceCoordinator.endManualSave {
                scheduleAutosave()
            }
        }

        let sidecar = sidecarURL(for: sourcePDFURL)
        let snapshot = buildSidecarSnapshot(document: document, sourcePDFURL: sourcePDFURL)
        do {
            try snapshotStore.writeSnapshotOrThrow(snapshot, to: sidecar)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to save changes"
            alert.informativeText = "Could not write changes to disk.\n\n\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
            return false
        }

        markupChangeVersion = 0
        lastAutosavedChangeVersion = 0
        lastMarkupEditAt = .distantPast
        lastUserInteractionAt = .distantPast
        view.window?.isDocumentEdited = false
        updateStatusBar()
        return true
    }
}
