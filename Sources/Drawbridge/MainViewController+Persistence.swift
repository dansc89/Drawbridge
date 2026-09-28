import AppKit
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
        deferEmbeddedWrite: Bool = true,
        embeddedSaveToken: Int = 0,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        guard let document = document ?? pdfView.document else {
            beep()
            completion?(false)
            return
        }
        applyPageLabelOverridesToDocumentIfNeeded(document)
        if deferEmbeddedWrite && !adoptAsPrimaryDocument && !showBusyOverlay {
            let saved = persistFastSnapshotThenDeferredEmbeddedSave(to: url, document: document)
            completion?(saved)
            return
        }
        if persistenceCoordinator.isManualSaveInFlight {
            // Keep Save instant: coalesce repeated Cmd+S requests while a save is in flight.
            if !adoptAsPrimaryDocument {
                queuedFastEmbeddedSave = true
            }
            completion?(false)
            return
        }
        let startedMarkupVersion = markupChangeVersion
        let savingDocumentID = ObjectIdentifier(document)
        let canonicalTargetURL = canonicalDocumentURL(url)
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
        let targetURL = url
        let originDocumentURLForAdoption = openDocumentURL.map { canonicalDocumentURL($0) }
        let startedAt = CFAbsoluteTimeGetCurrent()
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
            var writeElapsed: Double = 0
            var commitElapsed: Double = 0

            if destinationIsFileProvider {
                // File-provider volumes (iCloud/CloudStorage/Drive) are often very slow when PDFKit writes directly.
                // Render locally first, then do a single commit to the destination path.
                let localStagingURL = Self.temporaryLocalSaveURL(for: targetURL)
                let stagedWriteStartedAt = CFAbsoluteTimeGetCurrent()
                success = Self.writePDFDocument(
                    documentBox.document,
                    to: localStagingURL,
                    pageLabels: pageLabelsForEmbeddedSave
                )
                writeElapsed = CFAbsoluteTimeGetCurrent() - stagedWriteStartedAt

                if success {
                    if showBusyOverlay {
                        Task { @MainActor [weak self] in
                            self?.saveGenerateElapsed = writeElapsed
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
                    pageLabels: pageLabelsForEmbeddedSave
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
                        pageLabels: pageLabelsForEmbeddedSave
                    )
                    writeElapsed = CFAbsoluteTimeGetCurrent() - stagedWriteStartedAt
                    if success {
                        if showBusyOverlay {
                            Task { @MainActor [weak self] in
                                self?.saveGenerateElapsed = writeElapsed
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
                    pageLabels: pageLabelsForEmbeddedSave
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
                    pageLabels: pageLabelsForEmbeddedSave
                )
                writeElapsed = CFAbsoluteTimeGetCurrent() - writeStartedAt
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

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
                    if showBusyOverlay {
                        self.stopSaveProgressTracking()
                        self.endBusyIndicator()
                    }
                    self.isSavingDocumentOperation = false
                    self.persistenceCoordinator.endManualSave {
                        self.scheduleAutosave()
                        self.runQueuedFastEmbeddedSaveIfNeeded()
                    }
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
                    if let errorDescription, !errorDescription.isEmpty {
                        informativeText = "Could not save \(targetURL.lastPathComponent).\n\n\(errorDescription)"
                    } else {
                        informativeText = "Could not save \(targetURL.lastPathComponent)."
                    }
                    self.runAlert(
                        title: "Failed to save PDF",
                        informativeText: informativeText,
                        style: .warning
                    )
                    completion?(false)
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
                    if embeddedSaveToken > 0 {
                        self.lastEmbeddedSaveCompletedVersion = max(self.lastEmbeddedSaveCompletedVersion, embeddedSaveToken)
                    } else {
                        self.lastEmbeddedSaveCompletedVersion = max(self.lastEmbeddedSaveCompletedVersion, startedMarkupVersion)
                    }
                    if self.markupChangeVersion <= startedMarkupVersion {
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

    private func persistFastSnapshotThenDeferredEmbeddedSave(to url: URL, document: PDFDocument) -> Bool {
        persistFastSnapshot(to: url, document: document, scheduleEmbeddedWrite: true)
    }

    private func persistFastSnapshot(
        to url: URL,
        document: PDFDocument,
        scheduleEmbeddedWrite: Bool
    ) -> Bool {
        let sourceURL = canonicalDocumentURL(url)
        let currentDocumentID = ObjectIdentifier(document)
        let snapshotVersion = markupChangeVersion
        deferredEmbeddedSaveRequestedVersion += 1
        let saveToken = deferredEmbeddedSaveRequestedVersion
        let snapshot = buildSidecarSnapshot(document: document, sourcePDFURL: sourceURL)
        let snapshotSaved = snapshotStore.writeSnapshot(snapshot, to: sidecarURL(for: sourceURL))
        guard snapshotSaved else {
            runAlert(
                title: "Failed to save PDF",
                informativeText: "Could not save the recovery data for \(sourceURL.lastPathComponent).",
                style: .warning
            )
            return false
        }
        let activeDocumentID = pdfView.document.map(ObjectIdentifier.init)
        let activeURL = openDocumentURL.map { canonicalDocumentURL($0) }
        let saveContextStillActive = (activeDocumentID == currentDocumentID) && (activeURL == sourceURL)
        if saveContextStillActive {
            lastAutosavedChangeVersion = max(lastAutosavedChangeVersion, snapshotVersion)
            if markupChangeVersion <= snapshotVersion {
                markDocumentClean(updateStatusBarValue: true)
            }
        }
        if scheduleEmbeddedWrite {
            scheduleDeferredEmbeddedSave(to: sourceURL, documentID: currentDocumentID, requestedVersion: saveToken)
        }
        return true
    }

    private func scheduleDeferredEmbeddedSave(to url: URL, documentID: ObjectIdentifier, requestedVersion: Int) {
        deferredEmbeddedSaveRequestedVersion = max(deferredEmbeddedSaveRequestedVersion, requestedVersion)
        deferredEmbeddedSaveWorkItem?.cancel()
        let canonicalURL = canonicalDocumentURL(url)
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.deferredEmbeddedSaveWorkItem = nil
                guard self.deferredEmbeddedSaveRequestedVersion > self.lastEmbeddedSaveCompletedVersion else { return }
                guard let liveDocument = self.pdfView.document,
                      ObjectIdentifier(liveDocument) == documentID else { return }
                guard let activeURL = self.openDocumentURL.map({ self.canonicalDocumentURL($0) }),
                      activeURL == canonicalURL else { return }
                self.persistDocument(
                    to: canonicalURL,
                    adoptAsPrimaryDocument: false,
                    busyMessage: "Saving PDF…",
                    document: liveDocument,
                    showBusyOverlay: false,
                    deferEmbeddedWrite: false,
                    embeddedSaveToken: requestedVersion
                )
            }
        }
        deferredEmbeddedSaveWorkItem = workItem
        // Coalesce rapid saves/edits before PDFKit starts its unavoidable full-document rewrite.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
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
        options: [PDFDocumentWriteOption: Any]? = nil
    ) -> Bool {
        let preservedPageRotations = pageRotations(in: document)
        // `write(to:withOptions:)` is materially faster than `write(to:)` on large drawing sets.
        guard document.write(to: url, withOptions: options) else {
            return false
        }
        restorePageRotations(preservedPageRotations, to: document)
        if !pageLabels.isEmpty {
            do {
                try PDFPageLabelsEmbedder.embedPageLabels(pageLabels, in: url)
            } catch {
                return false
            }
        }
        do {
            try PDFAutoSheetLinkFitDestinationRewriter.rewriteAutoSheetLinksToFit(in: url)
            guard writtenPageRotationsMatch(preservedPageRotations, at: url) else {
                return false
            }
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

    func waitForInFlightSaveToSettle(timeout: TimeInterval = 90) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while (isSavingDocumentOperation || persistenceCoordinator.isManualSaveInFlight), Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return !(isSavingDocumentOperation || persistenceCoordinator.isManualSaveInFlight)
    }

    private func flushEmbeddedSaveBeforeClose(to sourceURL: URL, document: PDFDocument) -> Bool {
        deferredEmbeddedSaveWorkItem?.cancel()
        deferredEmbeddedSaveWorkItem = nil
        // Closing must be immediate. The durable snapshot now includes markups, page labels,
        // and the full bookmark tree, so Drawbridge can restore every edit without rebuilding
        // a large PDF while the user waits.
        return persistFastSnapshot(to: sourceURL, document: document, scheduleEmbeddedWrite: false)
    }

    private func runQueuedFastEmbeddedSaveIfNeeded() {
        guard queuedFastEmbeddedSave else { return }
        queuedFastEmbeddedSave = false
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
