import AppKit
import PDFKit

final class ProjectSnapshotStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let snapshotDirectory: URL?

    init(fileManager: FileManager = .default, snapshotDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.snapshotDirectory = snapshotDirectory
    }

    func sidecarURL(for sourcePDFURL: URL) -> URL {
        if let snapshotDirectory {
            try? fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
            return snapshotDirectory.appendingPathComponent(snapshotFileName(for: sourcePDFURL))
        }
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            let fallback = sourcePDFURL.deletingPathExtension()
            return fallback.appendingPathExtension("drawbridge.json")
        }
        let dir = appSupport.appendingPathComponent("Drawbridge").appendingPathComponent("ProjectSnapshots")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(snapshotFileName(for: sourcePDFURL))
    }

    private func snapshotFileName(for sourcePDFURL: URL) -> String {
        let key = Data(sourcePDFURL.standardizedFileURL.path.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return (key.isEmpty ? UUID().uuidString : key) + ".drawbridge.snapshot"
    }

    func cleanupLegacyJSONArtifacts(for sourcePDFURL: URL, autosaveDirectory: URL?) {
        let legacySidecar = sourcePDFURL.deletingPathExtension().appendingPathExtension("drawbridge.json")
        if fileManager.fileExists(atPath: legacySidecar.path) {
            try? fileManager.removeItem(at: legacySidecar)
        }

        guard let autosaveDirectory else { return }
        let stem = sourcePDFURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "-")
        let autosave = autosaveDirectory.appendingPathComponent("\(stem)-autosave.drawbridge.json")
        if fileManager.fileExists(atPath: autosave.path) {
            try? fileManager.removeItem(at: autosave)
        }
    }

    func buildSnapshot(
        document: PDFDocument,
        sourcePDFURL: URL,
        initialCapacity: Int,
        pageScaleLocks _: [Int: PageScaleLock],
        pageLabels: [Int: String] = [:],
        resolvedLineWidth _: (PDFAnnotation) -> CGFloat
    ) -> SidecarSnapshot {
        // Navigation edits are written directly into the PDF. Keeping an annotation
        // archive as a second source of truth can replace or restyle a page during
        // recovery, so the sidecar deliberately contains only bookmark metadata.
        let records: [SidecarAnnotationRecord] = []
        return SidecarSnapshot(
            sourcePDFPath: sourcePDFURL.standardizedFileURL.path,
            pageCount: document.pageCount,
            annotations: records,
            pageScaleLocks: nil,
            pageLabels: pageLabels,
            bookmarks: snapshotBookmarks(in: document),
            savedAt: Date()
        )
    }

    func writeSnapshot(_ snapshot: SidecarSnapshot, to url: URL) -> Bool {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(snapshot) else {
            return false
        }
        do {
            try writeSnapshotData(data, to: url)
            return true
        } catch {
            return false
        }
    }

    func writeSnapshotOrThrow(_ snapshot: SidecarSnapshot, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(snapshot)
        try writeSnapshotData(data, to: url)
    }

    func loadSnapshotIfAvailable(
        for sourcePDFURL: URL,
        document: PDFDocument,
        applyPageScaleLocks: ([Int: PageScaleLock]) -> Void,
        applyPageLabels: ([Int: String]) -> Void = { _ in },
        assignLineWidth _: (CGFloat, PDFAnnotation) -> Void
    ) {
        let url = sidecarURL(for: sourcePDFURL)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return }

        // Apply snapshot only when it is at least as new as the PDF file on disk.
        if let pdfModifiedAt = try? sourcePDFURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           let snapshotModifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           snapshotModifiedAt < pdfModifiedAt {
            return
        }

        let plistDecoder = PropertyListDecoder()
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        guard let snapshot = (try? plistDecoder.decode(SidecarSnapshot.self, from: data))
            ?? (try? jsonDecoder.decode(SidecarSnapshot.self, from: data)) else { return }
        guard snapshot.sourcePDFPath == sourcePDFURL.standardizedFileURL.path,
              snapshot.pageCount == document.pageCount else { return }

        // Legacy snapshots may contain drawing-scale settings and archived markups.
        // Only navigation edits belong to the current app; the PDF remains authoritative
        // for all other annotation appearance, geometry, flags, and page orientation.
        applyPageScaleLocks([:])
        applyPageLabels(snapshot.pageLabels ?? [:])
        applyBookmarks(snapshot.bookmarks, to: document)
    }

    private func snapshotBookmarks(in document: PDFDocument) -> [SidecarBookmarkRecord]? {
        guard let root = document.outlineRoot else { return [] }
        var records: [SidecarBookmarkRecord] = []
        for index in 0..<root.numberOfChildren {
            guard let child = root.child(at: index),
                  let record = snapshotBookmark(child, document: document) else { return nil }
            records.append(record)
        }
        return records
    }

    private func snapshotBookmark(_ outline: PDFOutline, document: PDFDocument) -> SidecarBookmarkRecord? {
        let destination = outline.destination
        // Do not replace an existing outline when it contains an external, named, or remote
        // action that this compact recovery format cannot reproduce without changing behavior.
        guard destination != nil || outline.action == nil else { return nil }
        let pageIndex = destination?.page.map { document.index(for: $0) }
        let point = destination?.point
        var children: [SidecarBookmarkRecord] = []
        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index),
                  let record = snapshotBookmark(child, document: document) else { return nil }
            children.append(record)
        }
        return SidecarBookmarkRecord(
            label: outline.label,
            pageIndex: pageIndex.flatMap { $0 >= 0 ? $0 : nil },
            destinationX: point.map { Double($0.x) },
            destinationY: point.map { Double($0.y) },
            children: children
        )
    }

    private func applyBookmarks(_ records: [SidecarBookmarkRecord]?, to document: PDFDocument) {
        guard let records else { return }
        let root = PDFOutline()
        for record in records {
            root.insertChild(restoredBookmark(record, document: document), at: root.numberOfChildren)
        }
        document.outlineRoot = root
    }

    private func restoredBookmark(_ record: SidecarBookmarkRecord, document: PDFDocument) -> PDFOutline {
        let outline = PDFOutline()
        outline.label = record.label
        if let pageIndex = record.pageIndex,
           pageIndex >= 0, pageIndex < document.pageCount,
           let page = document.page(at: pageIndex) {
            let point = NSPoint(x: record.destinationX ?? 0, y: record.destinationY ?? 0)
            outline.destination = PDFDestination(page: page, at: point)
        }
        for child in record.children {
            outline.insertChild(restoredBookmark(child, document: document), at: outline.numberOfChildren)
        }
        return outline
    }

    private func writeSnapshotData(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Project snapshots are small, recoverable metadata. `createFile` avoids
        // Foundation's fragile replace/remove sequence on Application Support paths.
        guard fileManager.createFile(atPath: url.path, contents: data) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

}
