import Foundation
import Darwin

/// Lossless page concatenation. No rendering or PDFKit serialization fallback.
/// Document-level outlines, forms, labels and named destinations are not merged.
enum PDFMergeService {
    struct Report: Sendable { let pageCount: Int }

    static func merge(sources: [URL], destination: URL,
                      helper: URL? = PDFTKBookmarkWriter.executableURL(),
                      cancelled: @Sendable () -> Bool = { false }) throws -> Report {
        func failure(_ message: String) -> NSError {
            NSError(domain: "DrawbridgeMerge", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        func checkCancellation() throws { if cancelled() { throw CancellationError() } }
        let fm = FileManager.default
        guard sources.count >= 2 else { throw failure("Choose at least two PDFs to merge.") }
        guard sources.allSatisfy(\.isFileURL), destination.isFileURL else { throw failure("Choose local PDF files.") }
        let originals = sources.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        let output = destination.standardizedFileURL.resolvingSymlinksInPath()
        // Compare both canonical paths and device/inode identities (hard links).
        struct Identity: Equatable {
            let device: UInt64
            let inode: UInt64
            init(_ url: URL) throws {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
                inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            }
        }
        let identities = try originals.map { try Identity($0) }
        func rejectCollision() throws {
            let resolved = destination.standardizedFileURL.resolvingSymlinksInPath()
            guard !originals.contains(resolved), !originals.contains(output) else {
                throw failure("The merged PDF must not replace any selected original. Choose another filename.")
            }
            for candidate in [resolved, output] where fm.fileExists(atPath: candidate.path) {
                let identity = try Identity(candidate)
                let currentIdentities = try originals.map { try Identity($0) }
                if identities.contains(identity) || currentIdentities.contains(identity) {
                    throw failure("The output is an alias of a selected original. Choose another filename.")
                }
            }
        }
        try rejectCollision()
        try checkCancellation()
        guard let helper, fm.isExecutableFile(atPath: helper.path) else {
            throw failure("The PDF processing helper (qpdf) is unavailable. Reinstall Drawbridge with its bundled helper.")
        }
        // Staging beside the destination guarantees same-filesystem atomic rename.
        let directory = output.deletingLastPathComponent().appendingPathComponent(".DrawbridgeMerge-\(UUID())")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: directory) }
        func run(_ arguments: [String]) throws {
            try checkCancellation()
            guard PDFTKBookmarkWriter.run(helper, arguments: arguments) else {
                throw failure("Could not merge these PDFs. An input may be invalid, encrypted or unreadable. No output was replaced.")
            }
            try checkCancellation()
        }
        func inspect(_ url: URL, name: String) throws -> Int {
            let jsonURL = directory.appendingPathComponent(name + ".json")
            try run(["--json=2", "--json-key=pages", "--json-key=encrypt", url.path, jsonURL.path])
            guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any],
                  let encrypt = json["encrypt"] as? [String: Any], let encrypted = encrypt["encrypted"] as? Bool,
                  let pages = json["pages"] as? [[String: Any]], !pages.isEmpty else {
                throw failure("\(url.lastPathComponent) is invalid or has no pages. Choose nonempty PDFs.")
            }
            guard !encrypted else { throw failure("Encrypted PDFs cannot be merged. Save an unencrypted copy first.") }
            return pages.count
        }
        var snapshots: [URL] = [], expectedPages = 0
        for (index, original) in originals.enumerated() {
            try checkCancellation()
            let snapshot = directory.appendingPathComponent("input-\(index).pdf")
            try fm.copyItem(at: original, to: snapshot)
            try run(["--check", snapshot.path])
            expectedPages += try inspect(snapshot, name: "input-\(index)")
            snapshots.append(snapshot)
        }
        let staged = directory.appendingPathComponent("merged.pdf")
        try run(["--empty", "--stream-data=preserve", "--pages"] + snapshots.flatMap { [$0.path, "1-z"] } + ["--", staged.path])
        try run(["--check", staged.path])
        guard try inspect(staged, name: "output") == expectedPages else {
            throw failure("The merged page count failed verification. No output was replaced.")
        }
        // Fail closed if a source changed while the helper was processing its snapshot.
        for (original, snapshot) in zip(originals, snapshots) {
            guard try Data(contentsOf: original, options: .mappedIfSafe) == Data(contentsOf: snapshot, options: .mappedIfSafe) else {
                throw failure("A selected PDF changed during merging. Try again. No output was replaced.")
            }
        }
        try rejectCollision()
        try checkCancellation()
        // POSIX rename either publishes the complete file or leaves the destination
        // intact. Unlike copy/move fallbacks it cannot publish a partial PDF.
        guard Darwin.rename(staged.path, output.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not publish the merged PDF. The destination was left unchanged."])
        }
        return Report(pageCount: expectedPages)
    }
}

enum PDFMergeSort: String, CaseIterable {
    case manual = "Manual order"
    case nameAscending = "Name A–Z", nameDescending = "Name Z–A"
    case sizeAscending = "Size smallest first", sizeDescending = "Size largest first"
    case dateAscending = "Modified oldest first", dateDescending = "Modified newest first"
}

struct PDFMergeMetadata: Sendable {
    var size: Int?
    var modified: Date?
    // Called only by the metadata worker, never by cell rendering or sorting.
    static func read(_ url: URL) -> Self {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return Self(size: values?.fileSize, modified: values?.contentModificationDate)
    }
}

struct PDFMergeList {
    struct Entry: Sendable {
        let id = UUID() // Duplicate paths are independent selected inputs.
        let url: URL
        var metadata = PDFMergeMetadata()
    }
    private(set) var entries: [Entry] = []
    var urls: [URL] { entries.map(\.url) }
    var canMerge: Bool { entries.count >= 2 }
    mutating func add(_ urls: [URL]) { entries.append(contentsOf: urls.map { Entry(url: $0) }) }
    mutating func remove(index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
    }
    mutating func move(index: Int, offset: Int) {
        let destination = index + offset
        guard entries.indices.contains(index), entries.indices.contains(destination) else { return }
        entries.insert(entries.remove(at: index), at: destination)
    }
    mutating func updateMetadata(_ values: [UUID: PDFMergeMetadata]) {
        for index in entries.indices {
            if let value = values[entries[index].id] { entries[index].metadata = value }
        }
    }
    mutating func sort(_ order: PDFMergeSort) {
        guard order != .manual else { return } // Manual keeps the order currently shown.
        func compare<T: Comparable>(_ a: T?, _ b: T?, descending: Bool) -> ComparisonResult {
            switch (a, b) {
            case (nil, nil): return .orderedSame
            case (nil, _): return .orderedDescending // Unknown always last, in both directions.
            case (_, nil): return .orderedAscending
            case let (a?, b?):
                if a == b { return .orderedSame }
                return (descending ? a > b : a < b) ? .orderedAscending : .orderedDescending
            }
        }
        entries = entries.enumerated().sorted { a, b in
            let result: ComparisonResult
            switch order {
            case .manual: result = .orderedSame
            case .nameAscending, .nameDescending:
                let name = a.element.url.lastPathComponent.localizedStandardCompare(b.element.url.lastPathComponent)
                result = order == .nameDescending ? (name == .orderedAscending ? .orderedDescending : name == .orderedDescending ? .orderedAscending : .orderedSame) : name
            case .sizeAscending, .sizeDescending:
                result = compare(a.element.metadata.size, b.element.metadata.size, descending: order == .sizeDescending)
            case .dateAscending, .dateDescending:
                result = compare(a.element.metadata.modified, b.element.metadata.modified, descending: order == .dateDescending)
            }
            return result == .orderedSame ? a.offset < b.offset : result == .orderedAscending
        }.map(\.element)
    }
}
