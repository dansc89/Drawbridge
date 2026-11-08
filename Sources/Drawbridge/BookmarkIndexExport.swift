import Foundation
import CoreGraphics
import Darwin

struct BookmarkIndexNode {
    var title: String
    var children: [BookmarkIndexNode] = []
}
struct BookmarkIndexDiscovery {
    var files: [URL]
    var excluded: Int
}
struct BookmarkIndexResult: Sendable {
    var data: Data
    var files: Int
    var excluded: Int
    var rows: Int
    var sources: [URL] = []
}
struct BookmarkIndexError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

/// A private, read-only job. Never constructs a PDFView/PDFKit document or uses
/// editor navigation/recent-file machinery. PDF objects never cross threads.
enum BookmarkIndexExport {
    static func check(_ cancelled: () -> Bool) throws {
        if cancelled() { throw CancellationError() }
    }
    static func format(_ title: String) -> String {
        func whitespace(_ v: UInt32) -> Bool {
            (9...13).contains(v) || v == 32 || v == 160 || v == 5760 ||
            (8192...8202).contains(v) || [8232,8233,8239,8287,12288,65279].contains(v)
        }
        var cleaned = "", pendingSpace = false
        for scalar in title.unicodeScalars {
            if whitespace(scalar.value) { pendingSpace = !cleaned.isEmpty }
            else {
                if pendingSpace { cleaned += " "; pendingSpace = false }
                cleaned.unicodeScalars.append(scalar)
            }
        }
        if let space = cleaned.firstIndex(of: " ") {
            let token = cleaned[..<space]
            if token.unicodeScalars.allSatisfy({ (65...90).contains($0.value) || (48...57).contains($0.value) || $0.value == 46 || $0.value == 45 }) {
                return String(token) + " - " + cleaned[cleaned.index(after: space)...]
            }
        }
        return cleaned
    }
    static func csv(_ rows: [[String]]) -> Data {
        Data(rows.map { row in
            row.map { value in
                if value.contains("\"") || value.contains(",") || value.contains("\n") {
                    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return value
            }.joined(separator: ",")
        }.joined(separator: "\n").utf8)
    }
    static func rows(_ nodes: [BookmarkIndexNode], filename: String) -> [[String]] {
        var result: [[String]] = []
        for node in nodes {
            result += rows(node.children, filename: filename)
            let title = format(node.title)
            if !title.isEmpty { result.append([filename, title]) }
        }
        return result
    }
    static func excludes(_ basename: String) -> Bool {
        let bytes = basename.utf8.map { (97...122).contains($0) ? $0 - 32 : $0 }
        guard bytes.count >= 4 else { return false }
        return (0...(bytes.count - 4)).contains { Array(bytes[$0..<($0 + 4)]) == [65,82,67,72] }
    }
    /// Lexicographic unsigned UTF-8 relative-path order, no locale/case folding
    /// or Unicode normalization. Symlinks (files AND directories) are skipped.
    static func discover(_ folder: URL, cancelled: () -> Bool = { false }) throws -> BookmarkIndexDiscovery {
        try check(cancelled)
        let fm = FileManager.default
        let rootValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw BookmarkIndexError(reason: "Select a regular folder, not a symbolic link.")
        }
        var files: [(String, URL)] = [], excluded = 0
        func visit(_ directory: URL, relative: String) throws {
            try check(cancelled)
            let entries: [URL]
            do { entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isHiddenKey,.isPackageKey,.isSymbolicLinkKey,.isDirectoryKey,.isRegularFileKey], options: [.skipsHiddenFiles]) }
            catch { throw BookmarkIndexError(reason: "Could not read folder \(directory.lastPathComponent): \(error.localizedDescription)") }
            for entry in entries {
                try check(cancelled)
                let values = try entry.resourceValues(forKeys: [.isHiddenKey,.isPackageKey,.isSymbolicLinkKey,.isDirectoryKey,.isRegularFileKey])
                if values.isHidden == true || values.isSymbolicLink == true || entry.lastPathComponent.hasPrefix(".") { continue }
                let path = relative + entry.lastPathComponent
                if values.isDirectory == true {
                    if values.isPackage != true { try visit(entry, relative: path + "/") }
                } else if values.isRegularFile == true, entry.pathExtension.lowercased() == "pdf" {
                    if excludes(entry.lastPathComponent) { excluded += 1 }
                    else { files.append((path, entry)) }
                }
            }
        }
        try visit(folder, relative: "")
        files.sort { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
        return BookmarkIndexDiscovery(files: files.map(\.1), excluded: excluded)
    }
    static func outline(_ url: URL, cancelled: () -> Bool = { false }) throws -> [BookmarkIndexNode] {
        try check(cancelled)
        func failure(_ reason: String) -> BookmarkIndexError { BookmarkIndexError(reason: "\(url.lastPathComponent): \(reason)") }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw failure("The PDF is unreadable. Check file permissions.") }
        guard let document = CGPDFDocument(url as CFURL) else { throw failure("Could not parse the PDF. Check that it is a valid, undamaged PDF.") }
        guard !document.isEncrypted || document.isUnlocked else { throw failure("The PDF is password-protected. Export an unlocked copy first.") }
        guard document.numberOfPages > 0, let catalog = document.catalog else { throw failure("The PDF has no readable pages/catalog.") }
        // Traverse the raw outline dictionary: PDFKit's sidebar adapter can drop
        // titled destinationless nodes. Dest/A are intentionally not inspected.
        func dictionary(_ owner: CGPDFDictionaryRef, _ key: String) throws -> CGPDFDictionaryRef? {
            var object: CGPDFObjectRef?
            guard CGPDFDictionaryGetObject(owner, key, &object), let object else { return nil }
            if CGPDFObjectGetType(object) == .null { return nil }
            var value: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &value), let value else { throw failure("Malformed bookmark \(key) dictionary.") }
            return value
        }
        guard let outline = try dictionary(catalog, "Outlines") else { return [] }
        var visited = Set<UInt>()
        func siblings(_ first: CGPDFDictionaryRef?, depth: Int) throws -> [BookmarkIndexNode] {
            guard depth < 512 else { throw failure("Bookmark nesting exceeds the safe limit (512).") }
            var next = first, result: [BookmarkIndexNode] = []
            while let item = next {
                try check(cancelled)
                guard visited.insert(UInt(bitPattern: unsafeBitCast(item, to: UnsafeRawPointer.self))).inserted else { throw failure("Cyclic or repeated bookmark object.") }
                var string: CGPDFStringRef?
                var title = ""
                if CGPDFDictionaryGetString(item, "Title", &string), let string, let text = CGPDFStringCopyTextString(string) { title = text as String }
                let children = try siblings(dictionary(item, "First"), depth: depth + 1)
                result.append(BookmarkIndexNode(title: title, children: children))
                next = try dictionary(item, "Next")
            }
            return result
        }
        return try siblings(dictionary(outline, "First"), depth: 0)
    }
    static func extract(_ folder: URL, cancelled: () -> Bool = { false }, progress: (Int, Int, Int) -> Void = { _,_,_ in }) throws -> BookmarkIndexResult {
        let discovery = try discover(folder, cancelled: cancelled)
        var allRows = [["PDF", "Title"]]
        progress(0, discovery.files.count, discovery.excluded)
        for (index, file) in discovery.files.enumerated() {
            try check(cancelled)
            let fileRows = try autoreleasepool { try rows(outline(file, cancelled: cancelled), filename: file.lastPathComponent) }
            try check(cancelled)
            allRows += fileRows
            progress(index + 1, discovery.files.count, discovery.excluded)
        }
        try check(cancelled)
        return BookmarkIndexResult(data: csv(allRows), files: discovery.files.count, excluded: discovery.excluded, rows: allRows.count - 1, sources: discovery.files)
    }
    static func write(_ result: BookmarkIndexResult, to url: URL, cancelled: () -> Bool = { false }) throws {
        try check(cancelled)
        // Stage beside destination so rename is atomic even across volumes.
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let destinationAttributes = try? FileManager.default.attributesOfItem(atPath: canonical.path)
        guard canonical.pathExtension.lowercased() != "pdf", !result.sources.contains(where: { source in
            let resolved = source.resolvingSymlinksInPath().standardizedFileURL
            if resolved == canonical { return true }
            guard let a = try? FileManager.default.attributesOfItem(atPath: resolved.path), let b = destinationAttributes else { return false }
            return (a[.systemNumber] as? NSNumber) == (b[.systemNumber] as? NSNumber) && (a[.systemFileNumber] as? NSNumber) == (b[.systemFileNumber] as? NSNumber)
        }) else { throw BookmarkIndexError(reason: "Choose a CSV destination that is not a source PDF or an alias to one.") }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".bookmark-index-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try result.data.write(to: temporary, options: [.withoutOverwriting])
        try check(cancelled)
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
