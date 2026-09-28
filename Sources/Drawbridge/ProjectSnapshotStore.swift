import AppKit
import PDFKit

final class ProjectSnapshotStore: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func sidecarURL(for sourcePDFURL: URL) -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            let fallback = sourcePDFURL.deletingPathExtension()
            return fallback.appendingPathExtension("drawbridge.json")
        }
        let dir = appSupport.appendingPathComponent("Drawbridge").appendingPathComponent("ProjectSnapshots")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = Data(sourcePDFURL.standardizedFileURL.path.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        let filename = (key.isEmpty ? UUID().uuidString : key) + ".drawbridge.snapshot"
        return dir.appendingPathComponent(filename)
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
        pageScaleLocks: [Int: PageScaleLock],
        pageLabels: [Int: String] = [:],
        resolvedLineWidth: (PDFAnnotation) -> CGFloat
    ) -> SidecarSnapshot {
        var records: [SidecarAnnotationRecord] = []
        records.reserveCapacity(max(64, initialCapacity))
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                let archivedData = (try? NSKeyedArchiver.archivedData(withRootObject: annotation, requiringSecureCoding: true))
                    ?? (try? NSKeyedArchiver.archivedData(withRootObject: annotation, requiringSecureCoding: false))
                guard let data = archivedData else { continue }
                records.append(
                    SidecarAnnotationRecord(
                        pageIndex: pageIndex,
                        archivedAnnotation: data,
                        lineWidth: resolvedLineWidth(annotation)
                    )
                )
            }
        }
        return SidecarSnapshot(
            sourcePDFPath: sourcePDFURL.standardizedFileURL.path,
            pageCount: document.pageCount,
            annotations: records,
            pageScaleLocks: pageScaleLocks,
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
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func writeSnapshotOrThrow(_ snapshot: SidecarSnapshot, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    func loadSnapshotIfAvailable(
        for sourcePDFURL: URL,
        document: PDFDocument,
        applyPageScaleLocks: ([Int: PageScaleLock]) -> Void,
        applyPageLabels: ([Int: String]) -> Void = { _ in },
        assignLineWidth: (CGFloat, PDFAnnotation) -> Void
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
        guard snapshot.sourcePDFPath == sourcePDFURL.standardizedFileURL.path else { return }

        applyPageScaleLocks(snapshot.pageScaleLocks ?? [:])
        applyPageLabels(snapshot.pageLabels ?? [:])
        applySnapshot(snapshot, to: document, assignLineWidth: assignLineWidth)
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

    private func applySnapshot(
        _ snapshot: SidecarSnapshot,
        to document: PDFDocument,
        assignLineWidth: (CGFloat, PDFAnnotation) -> Void
    ) {
        guard snapshot.pageCount == document.pageCount else { return }
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                page.removeAnnotation(annotation)
            }
        }
        for record in snapshot.annotations {
            guard record.pageIndex >= 0,
                  record.pageIndex < document.pageCount,
                  let page = document.page(at: record.pageIndex),
                  let annotation = decodeAnnotation(from: record.archivedAnnotation) else {
                continue
            }
            if let lineWidth = record.lineWidth, lineWidth > 0 {
                assignLineWidth(lineWidth, annotation)
            }
            page.addAnnotation(annotation)
        }
    }

    private func decodeAnnotation(from data: Data) -> PDFAnnotation? {
        if let secure = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PDFAnnotation.self, from: data) {
            return secure
        }
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        unarchiver.requiresSecureCoding = false
        let insecure = unarchiver.decodeObject(of: PDFAnnotation.self, forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()
        return insecure
    }
}
