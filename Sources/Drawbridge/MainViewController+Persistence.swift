import AppKit
import Darwin
import PDFKit

@MainActor
extension MainViewController {
    func markDocumentClean(updateStatusBarValue: Bool = true) {
        markupChangeVersion = 0
        lastAutosavedChangeVersion = 0
        lastMarkupEditAt = .distantPast
        lastUserInteractionAt = .distantPast
        view.window?.isDocumentEdited = false
        if updateStatusBarValue {
            updateStatusBar()
        }
    }

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
            pageScaleLocks: pageScaleLocks,
            pageLabels: embeddedPageLabelsForSave(in: document),
            resolvedLineWidth: { annotation in
                self.resolvedLineWidth(for: annotation)
            }
        )
    }

    func loadSidecarSnapshotIfAvailable(for sourcePDFURL: URL, document: PDFDocument) {
        snapshotStore.loadSnapshotIfAvailable(
            for: sourcePDFURL,
            document: document,
            applyPageScaleLocks: { locks in
                self.pageScaleLocks = locks
                self.lastScaleLockAppliedPageIndex = -1
            },
            applyPageLabels: { labels in
                self.pageLabelOverrides = labels
            },
            assignLineWidth: { lineWidth, annotation in
                self.assignLineWidth(lineWidth, to: annotation)
            }
        )
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
                    self.runAlert(
                        title: "Failed to save project",
                        informativeText: "Could not write \(sidecar.lastPathComponent).",
                        style: .warning
                    )
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
                self.markDocumentClean()
            }
        }
    }

    func persistDocument(
        to url: URL,
        adoptAsPrimaryDocument: Bool,
        busyMessage: String,
        document: PDFDocument? = nil,
        showBusyOverlay: Bool = true,
        deferEmbeddedWrite _: Bool = false,
        embeddedSaveToken: Int = 0,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        guard !isPDFFileProcessingOperation else { completion?(false); return }
        guard let document = document ?? pdfView.document else {
            beep()
            completion?(false)
            return
        }
        if persistenceCoordinator.isManualSaveInFlight {
            // Coalesce before resolving paths or showing recovery dialogs: an
            // active save owns its source snapshot and may relocate the file.
            if !adoptAsPrimaryDocument { queuedFastEmbeddedSave = true }
            completion?(false)
            return
        }
        var resolvedTargetURL = url
        var recoverySourceURL: URL?
        // Save As represents the version being edited, even if another app
        // replaced the original. Build the new copy from its frozen snapshot.
        if adoptAsPrimaryDocument, let openedURL = openDocumentURL,
           canonicalDocumentURL(url) != canonicalDocumentURL(openedURL) {
            recoverySourceURL = pdfView.rectangleMarkup.sourceStamp?.recoverySourceURL
        }
        if let openedURL = openDocumentURL,
           !FileManager.default.fileExists(atPath: openedURL.path) {
            if let relocated = pdfView.rectangleMarkup.sourceStamp?.resolvedSourceURL(preferred: openedURL) {
                if canonicalDocumentURL(url) == canonicalDocumentURL(openedURL) { resolvedTargetURL = relocated }
                unregisterSessionDocument(openedURL)
                openDocumentURL = relocated
                registerSessionDocument(relocated)
                configureAutosaveURL(for: relocated)
                onDocumentOpened?(relocated)
            } else if adoptAsPrimaryDocument, canonicalDocumentURL(url) != canonicalDocumentURL(openedURL),
                      let frozenSource = pdfView.rectangleMarkup.sourceStamp?.recoverySourceURL,
                      !FileManager.default.fileExists(atPath: url.path) {
                // Recover into a NEW file from the opening snapshot. Never
                // overwrite another version of the user's missing original.
                recoverySourceURL = frozenSource
            } else {
                let canRecover = pdfView.rectangleMarkup.sourceStamp?.recoverySourceURL != nil
                let response = runAlert(title: "PDF source file is unavailable",
                         informativeText: canRecover
                            ? "The original file was moved or removed outside Drawbridge. Your markups remain open. Save a recovered copy using a new filename to keep your work."
                            : "The original file was moved or removed outside Drawbridge, and its recovery snapshot is unavailable. Your markups remain open. Restore the original file to its previous location before saving.", style: .warning,
                         buttons: canRecover ? ["Save Recovered Copy…", "Cancel"] : ["OK"])
                completion?(false)
                if canRecover, response == .alertFirstButtonReturn { saveDocumentAsProject(document: document) }
                return
            }
        }
        applyPageLabelOverridesToDocumentIfNeeded(document)
        let saveSpan = PerformanceMetrics.begin("save_pdf", thresholdMs: 150)
        pdfView.rectangleMarkup.finishTextEditing()
        let startedMarkupVersion = markupChangeVersion
        let savingDocumentID = ObjectIdentifier(document)
        let canonicalTargetURL = canonicalDocumentURL(resolvedTargetURL)
        // Prevent expensive markup-list rebuild work from competing with save completion on main.
        pendingMarkupsRefreshWorkItem?.cancel()
        pendingMarkupsRefreshWorkItem = nil
        markupsScanGeneration += 1
        persistenceCoordinator.beginManualSave()
        isSavingDocumentOperation = true
        if showBusyOverlay {
            beginBusyIndicator(busyMessage, detail: "Generating PDF…", lockInteraction: false)
            startSaveProgressTracking(phase: "Generating")
        }
        let targetURL = resolvedTargetURL
        let originDocumentURLForAdoption = openDocumentURL.map { canonicalDocumentURL($0) }
        // PDFKit can report an opaque temporary URL for a document opened from a
        // file-provider volume.  That URL is often gone by the time Save runs,
        // which used to force the slow, full-PDFKit rewrite.  The opened file is
        // the authoritative pre-edit source for a metadata-only navigation save.
        let navigationSourceURL: URL? = {
            if let recoverySourceURL { return recoverySourceURL }
            if let originDocumentURLForAdoption,
               FileManager.default.fileExists(atPath: originDocumentURLForAdoption.path) {
                return originDocumentURLForAdoption
            }
            if let documentURL = document.documentURL,
               FileManager.default.fileExists(atPath: documentURL.path) {
                return documentURL
            }
            return nil
        }()
        let startedAt = CFAbsoluteTimeGetCurrent()
        let rectangleSourceStamp = recoverySourceURL.flatMap(PDFMarkupSourceStamp.capture) ?? pdfView.rectangleMarkup.sourceStamp
        let captureStartedAt = CFAbsoluteTimeGetCurrent()
        let capturedRectangles = RectangleMarkupRecord.capture(document)
        let structureState = pageStructureState?.document === document ? pageStructureState : nil
        let importedPlan = pdfView.rectangleMarkup.importedPlan()
        let structurePlan = structureState?.plan(for: document, forceOriginal: importedPlan != nil)
        let savedPageIdentities = (0..<document.pageCount).compactMap(document.page(at:)).map(ObjectIdentifier.init)
        // Freeze navigation beside markups on the UI thread. Saving must not
        // enumerate the live PDFKit annotation arrays while the user edits.
        let navigationSnapshot = PDFTKBookmarkWriter.captureNavigation(in: document)
        let captureElapsed = CFAbsoluteTimeGetCurrent() - captureStartedAt
        let rectangleRecords: [RectangleMarkupRecord]? = (pdfView.rectangleMarkup.hasUnsavedChanges || !capturedRectangles.isEmpty) ? capturedRectangles : nil
        pdfView.rectangleMarkup.cancelGesture()
        refreshRectangleToolbar()
        let documentBox = PDFDocumentBox(document: document)
        let pageLabelsForEmbeddedSave = embeddedPageLabelsForSave(in: document)
        let destinationAlreadyExists = FileManager.default.fileExists(atPath: targetURL.path)
        let destinationIsFileProvider = Self.isLikelyFileProviderURL(targetURL)
        let fallbackStagingURL = destinationAlreadyExists ? saveStagingFileURL(for: targetURL) : targetURL
        let sidecarForTarget = sidecarURL(for: canonicalTargetURL)
        let saveQoS: DispatchQoS.QoSClass = showBusyOverlay ? .userInitiated : .utility

        DispatchQueue.global(qos: saveQoS).async { [weak self] in
            var success = false
            var errorDescription: String?
            var markupSaveFailure: PDFRectangleWriter.SaveFailure?
            var committedMarkupStamp: PDFMarkupSourceStamp?
            var writeElapsed: Double = 0
            var commitElapsed: Double = 0

            if let structurePlan, let navigationSourceURL {
                let writeStartedAt = CFAbsoluteTimeGetCurrent()
                success = structurePlan.write(document: documentBox.document, currentSource: navigationSourceURL, destination: targetURL, expectedStamp: rectangleSourceStamp, labels: pageLabelsForEmbeddedSave, records: capturedRectangles, navigation: navigationSnapshot, importedPlan: importedPlan, onCommitted: { committedMarkupStamp = $0 })
                if !success { errorDescription = "The page deletion could not be verified. Your original PDF is unchanged and your edits remain open." }
                writeElapsed = CFAbsoluteTimeGetCurrent() - writeStartedAt
            } else if rectangleRecords != nil {
                // The annotation writer already creates and verifies a local
                // candidate, then atomically commits it. A second outer stage
                // duplicated that work and cached inspection under a deleted
                // temporary URL, making subsequent provider saves cold again.
                let writeStartedAt = CFAbsoluteTimeGetCurrent()
                success = Self.writePDFDocument(
                    documentBox.document,
                    to: targetURL,
                    pageLabels: pageLabelsForEmbeddedSave,
                    navigationSourceURL: navigationSourceURL,
                    rectangleRecords: rectangleRecords,
                    rectangleSourceStamp: rectangleSourceStamp,
                    navigationSnapshot: navigationSnapshot,
                    importedPlan: importedPlan,
                    onMarkupCommitted: { committedMarkupStamp = $0 },
                    onMarkupSaveFailure: { markupSaveFailure = $0 }
                )
                writeElapsed = CFAbsoluteTimeGetCurrent() - writeStartedAt
            } else if destinationIsFileProvider {
                // File-provider volumes (iCloud/CloudStorage/Drive) are often very slow when PDFKit writes directly.
                // Render locally first, then do a single commit to the destination path.
                let localStagingURL = Self.temporaryLocalSaveURL(for: targetURL)
                let stagedWriteStartedAt = CFAbsoluteTimeGetCurrent()
                success = Self.writePDFDocument(
                    documentBox.document,
                    to: localStagingURL,
                    pageLabels: pageLabelsForEmbeddedSave,
                    navigationSourceURL: navigationSourceURL,
                    rectangleRecords: rectangleRecords,
                    rectangleSourceStamp: rectangleSourceStamp
                )
                writeElapsed = CFAbsoluteTimeGetCurrent() - stagedWriteStartedAt

                if success {
                    if showBusyOverlay {
                        let completedWriteElapsed = writeElapsed
                        Task { @MainActor [weak self] in
                            self?.saveGenerateElapsed = completedWriteElapsed
                            self?.updateSaveProgressPhase("Committing")
                        }
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
            } else if destinationAlreadyExists && showBusyOverlay {
                // Fast path: overwrite directly to avoid expensive replace/copy on file-provider volumes.
                let directWriteStartedAt = CFAbsoluteTimeGetCurrent()
                success = Self.writePDFDocument(
                    documentBox.document,
                    to: targetURL,
                    pageLabels: pageLabelsForEmbeddedSave,
                    navigationSourceURL: navigationSourceURL,
                    rectangleRecords: rectangleRecords,
                    rectangleSourceStamp: rectangleSourceStamp
                )
                writeElapsed = CFAbsoluteTimeGetCurrent() - directWriteStartedAt

                if !success {
                    // Fallback path: stage + commit if direct overwrite fails.
                    if showBusyOverlay {
                        Task { @MainActor [weak self] in
                            self?.updateSaveProgressPhase("Retrying")
                        }
                    }
                    let stagingURL = fallbackStagingURL
                    let stagedWriteStartedAt = CFAbsoluteTimeGetCurrent()
                    success = Self.writePDFDocument(
                        documentBox.document,
                        to: stagingURL,
                        pageLabels: pageLabelsForEmbeddedSave,
                        navigationSourceURL: navigationSourceURL,
                        rectangleRecords: rectangleRecords,
                        rectangleSourceStamp: rectangleSourceStamp
                    )
                    writeElapsed = CFAbsoluteTimeGetCurrent() - stagedWriteStartedAt
                    if success {
                        if showBusyOverlay {
                            let completedWriteElapsed = writeElapsed
                            Task { @MainActor [weak self] in
                                self?.saveGenerateElapsed = completedWriteElapsed
                                self?.updateSaveProgressPhase("Committing")
                            }
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
            } else if destinationAlreadyExists {
                // Background saves must never leave the user's PDF half-written if the app closes.
                // Generate beside the original, then atomically replace it when complete.
                let stagingURL = fallbackStagingURL
                let stagedWriteStartedAt = CFAbsoluteTimeGetCurrent()
                success = Self.writePDFDocument(
                    documentBox.document,
                    to: stagingURL,
                    pageLabels: pageLabelsForEmbeddedSave,
                    navigationSourceURL: navigationSourceURL,
                    rectangleRecords: rectangleRecords,
                    rectangleSourceStamp: rectangleSourceStamp
                )
                writeElapsed = CFAbsoluteTimeGetCurrent() - stagedWriteStartedAt
                if success {
                    let commitStartedAt = CFAbsoluteTimeGetCurrent()
                    do {
                        try Self.commitStagedSave(from: stagingURL, to: targetURL)
                    } catch {
                        success = false
                        errorDescription = error.localizedDescription
                    }
                    commitElapsed = CFAbsoluteTimeGetCurrent() - commitStartedAt
                }
                if FileManager.default.fileExists(atPath: stagingURL.path) {
                    try? FileManager.default.removeItem(at: stagingURL)
                }
            } else {
                let writeStartedAt = CFAbsoluteTimeGetCurrent()
                success = Self.writePDFDocument(
                    documentBox.document,
                    to: targetURL,
                    pageLabels: pageLabelsForEmbeddedSave,
                    navigationSourceURL: navigationSourceURL,
                    rectangleRecords: rectangleRecords,
                    rectangleSourceStamp: rectangleSourceStamp
                )
                writeElapsed = CFAbsoluteTimeGetCurrent() - writeStartedAt
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            let completedMarkupFailure = markupSaveFailure
            let completedMarkupStamp = committedMarkupStamp

            // The sidecar may contain edits made after this background PDF generation began.
            // Keep it authoritative on the next open even though the PDF was modified later.
            if success {
                if FileManager.default.fileExists(atPath: sidecarForTarget.path) {
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: sidecarForTarget.path)
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                let currentDocumentID = self.pdfView.document.map(ObjectIdentifier.init)
                let currentURL = self.openDocumentURL.map { self.canonicalDocumentURL($0) }
                let saveContextStillActive = (currentDocumentID == savingDocumentID) && (currentURL == canonicalTargetURL)
                defer {
                    PerformanceMetrics.end(saveSpan, extra: [
                        "result": success ? "ok" : "failed",
                        "capture_ms": String(format: "%.2f", captureElapsed * 1000),
                        "write_ms": String(format: "%.2f", writeElapsed * 1000),
                        "commit_ms": String(format: "%.2f", commitElapsed * 1000),
                        "markups": "\(capturedRectangles.count)",
                        "file_provider": destinationIsFileProvider ? "1" : "0"
                    ])
                    if showBusyOverlay {
                        self.stopSaveProgressTracking()
                        self.endBusyIndicator()
                    }
                    self.isSavingDocumentOperation = false
                    self.updateStatusBar()
                    self.persistenceCoordinator.endManualSave {
                        self.scheduleAutosave()
                    }
                    // Explicit Save requests must drain even when no sidecar
                    // autosave was queued (new vector markup skips sidecars).
                    self.runQueuedFastEmbeddedSaveIfNeeded()
                }

                self.saveGenerateElapsed = writeElapsed
                guard success else {
                    if showBusyOverlay {
                        if writeElapsed > 0, commitElapsed > 0 {
                            self.updateBusyIndicatorDetail(
                                String(format: "Write %.2fs • Commit %.2fs • Failed", writeElapsed, commitElapsed)
                            )
                        } else {
                            self.updateBusyIndicatorDetail(String(format: "Failed after %.2fs", elapsed))
                        }
                    }
                    let informativeText: String
                    if let completedMarkupFailure {
                        informativeText = "Could not save \(targetURL.lastPathComponent).\n\n\(completedMarkupFailure.explanation)"
                    } else if let errorDescription, !errorDescription.isEmpty {
                        informativeText = "Could not save \(targetURL.lastPathComponent).\n\n\(errorDescription)"
                    } else {
                        informativeText = "Could not save \(targetURL.lastPathComponent)." + (rectangleRecords == nil ? "" : "\n\nThe annotation-only save could not be verified. No full-page rewrite was attempted; your edits remain open.")
                    }
                    let canRecover = completedMarkupFailure?.isSourceConflict == true && self.pdfView.rectangleMarkup.sourceStamp?.recoverySourceURL != nil && saveContextStillActive
                    self.queuedFastEmbeddedSave = false
                    let response = self.runAlert(
                        title: "Failed to save PDF",
                        informativeText: informativeText,
                        style: .warning,
                        buttons: canRecover ? ["Save Recovered Copy…", "Cancel"] : ["OK"]
                    )
                    completion?(false)
                    if canRecover, response == .alertFirstButtonReturn {
                        DispatchQueue.main.async { [weak self] in self?.saveDocumentAsProject(document: documentBox.document) }
                    }
                    return
                }

                if showBusyOverlay {
                    if writeElapsed > 0, commitElapsed > 0 {
                        self.updateBusyIndicatorDetail(
                            String(format: "Write %.2fs • Commit %.2fs • Done", writeElapsed, commitElapsed)
                        )
                    } else {
                        self.updateBusyIndicatorDetail(String(format: "Saved in %.2fs", elapsed))
                    }
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

                if saveContextStillActive || adoptAsPrimaryDocument {
                    if structurePlan != nil { structureState?.savedPages = savedPageIdentities }
                    self.pdfView.rectangleMarkup.acceptPersistedSource(at: targetURL, stamp: completedMarkupStamp)
                    if embeddedSaveToken > 0 {
                        self.lastEmbeddedSaveCompletedVersion = max(self.lastEmbeddedSaveCompletedVersion, embeddedSaveToken)
                    } else {
                        self.lastEmbeddedSaveCompletedVersion = max(self.lastEmbeddedSaveCompletedVersion, startedMarkupVersion)
                    }
                    if self.markupChangeVersion <= startedMarkupVersion {
                        self.pdfView.rectangleMarkup.markSaved(at: targetURL, stamp: completedMarkupStamp)
                        self.markDocumentClean(updateStatusBarValue: false)
                    } else {
                        self.lastAutosavedChangeVersion = max(self.lastAutosavedChangeVersion, startedMarkupVersion)
                    }
                    if adoptAsPrimaryDocument {
                        // Save As/open-document transitions may need a model refresh.
                        self.performRefreshMarkups(selecting: self.currentSelectedAnnotation(), forceImmediate: true)
                    }
                    self.updateStatusBar()
                }
                completion?(true)
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
        } else {
            do {
                try fm.moveItem(at: stagingURL, to: destinationURL)
            } catch {
                try fm.copyItem(at: stagingURL, to: destinationURL)
                try? fm.removeItem(at: stagingURL)
            }
        }
        try synchronizePersistedFile(at: destinationURL)
        // Flush the committed file without reopening its parent directory.
        // Opening protected folders from the app can block on macOS privacy
        // checks even after the replacement and file flush have succeeded.
    }

    nonisolated static func synchronizePersistedFile(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    nonisolated static func pageRotations(in document: PDFDocument) -> [Int: Int] {
        var rotations: [Int: Int] = [:]
        rotations.reserveCapacity(document.pageCount)
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            rotations[pageIndex] = page.rotation
        }
        return rotations
    }

    nonisolated static func restorePageRotations(_ rotations: [Int: Int], to document: PDFDocument) {
        guard !rotations.isEmpty else { return }
        for (pageIndex, rotation) in rotations {
            guard pageIndex >= 0,
                  pageIndex < document.pageCount,
                  let page = document.page(at: pageIndex),
                  page.rotation != rotation else { continue }
            page.rotation = rotation
        }
    }

    nonisolated static func writtenPageRotationsMatch(_ rotations: [Int: Int], at url: URL) -> Bool {
        guard !rotations.isEmpty,
              let writtenDocument = PDFDocument(url: url),
              writtenDocument.pageCount >= rotations.count else {
            return rotations.isEmpty
        }
        for (pageIndex, rotation) in rotations {
            guard pageIndex >= 0,
                  pageIndex < writtenDocument.pageCount,
                  let page = writtenDocument.page(at: pageIndex),
                  page.rotation == rotation else {
                return false
            }
        }
        return true
    }

    nonisolated static func writePDFDocument(
        _ document: PDFDocument,
        to url: URL,
        pageLabels: [Int: String],
        navigationSourceURL: URL? = nil,
        rectangleRecords: [RectangleMarkupRecord]? = nil,
        rectangleSourceStamp: PDFMarkupSourceStamp? = nil,
        navigationSnapshot: PDFTKBookmarkWriter.NavigationSnapshot? = nil,
        importedPlan: ImportedMarkupPlan? = nil,
        onMarkupCommitted: ((PDFMarkupSourceStamp) -> Void)? = nil,
        onMarkupSaveFailure: ((PDFRectangleWriter.SaveFailure) -> Void)? = nil,
        options: [PDFDocumentWriteOption: Any]? = nil
    ) -> Bool {
        if let rectangleRecords {
            guard let source = navigationSourceURL ?? document.documentURL else { return false }
            return PDFRectangleWriter.write(document: document, source: source, destination: url, pageLabels: pageLabels, records: rectangleRecords, expectedSourceStamp: rectangleSourceStamp, navigationSnapshot: navigationSnapshot, importedPlan: importedPlan, onCommitted: onMarkupCommitted, onFailure: onMarkupSaveFailure)
        }
        switch PDFTKBookmarkWriter.writeNavigation(
            in: document,
            sourceURL: navigationSourceURL,
            to: url,
            pageLabels: pageLabels,
            navigationSnapshot: navigationSnapshot
        ) {
        case .saved:
            return true
        case .rejectedSizeGrowth:
            // Do not let the PDFKit fallback silently replace a compact source with
            // a much larger full-document rewrite.
            return false
        case .unavailable:
            break
        }
        let preservedPageRotations = pageRotations(in: document)
        // `write(to:withOptions:)` is materially faster than `write(to:)` on large drawing sets.
        guard document.write(to: url, withOptions: options) else {
            return false
        }
        restorePageRotations(preservedPageRotations, to: document)
        do {
            guard writtenPageRotationsMatch(preservedPageRotations, at: url) else {
                return false
            }
            try synchronizePersistedFile(at: url)
            return true
        } catch {
            return false
        }
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
        // A sidecar is not a saved PDF. New markup stays dirty until the verified PDF commit.
        guard !pdfView.rectangleMarkup.hasUnsavedChanges else { return }
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
        guard !pdfView.rectangleMarkup.hasUnsavedChanges else { return }
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
                        self.markDocumentClean()
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
            return flushEmbeddedSaveBeforeClose(to: sourceURL, document: document)
        }
        // Unsaved new document path still requires Save As flow.
        saveDocumentAsProject(document: document)
        return false
    }

    /// Navigation commands own their save: when their completion alert appears, the PDF on disk
    /// already contains the generated bookmarks or links.
    func saveNavigationCommandChanges(
        in document: PDFDocument,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let sourceURL = openDocumentURL else {
            completion(true)
            return
        }
        persistDocument(
            to: sourceURL,
            adoptAsPrimaryDocument: false,
            busyMessage: "Saving Navigation Changes…",
            document: document,
            showBusyOverlay: true,
            deferEmbeddedWrite: false,
            completion: completion
        )
    }

    func waitForInFlightSaveToSettle(timeout: TimeInterval = 90) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while (isSavingDocumentOperation || persistenceCoordinator.isManualSaveInFlight), Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return !(isSavingDocumentOperation || persistenceCoordinator.isManualSaveInFlight)
    }

    private func flushEmbeddedSaveBeforeClose(to sourceURL: URL, document: PDFDocument) -> Bool {
        var completed: Bool?
        persistDocument(
            to: sourceURL,
            adoptAsPrimaryDocument: false,
            busyMessage: "Saving PDF…",
            document: document,
            showBusyOverlay: true,
            deferEmbeddedWrite: false
        ) { success in
            completed = success
        }
        let deadline = Date().addingTimeInterval(120)
        while completed == nil, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return completed ?? false
    }

    func hasPendingPDFWriteForTermination() -> Bool {
        isSavingDocumentOperation
            || isPDFFileProcessingOperation
            || persistenceCoordinator.isManualSaveInFlight
    }

    private func runQueuedFastEmbeddedSaveIfNeeded() {
        guard queuedFastEmbeddedSave else { return }
        queuedFastEmbeddedSave = false
        // Repeated Cmd+S with no later edits needs no second PDF write.
        guard pdfView.rectangleMarkup.hasUnsavedChanges || markupChangeVersion > 0 else { return }
        guard let document = pdfView.document,
              let sourceURL = openDocumentURL else { return }
        persistDocument(
            to: sourceURL,
            adoptAsPrimaryDocument: false,
            busyMessage: "Saving PDF…",
            document: document,
            showBusyOverlay: false,
            deferEmbeddedWrite: false
        )
    }
}
