import Foundation
import CryptoKit

/// Repackages PDF objects without changing decoded drawing or image data.
/// Never enables JPEG optimization, image resampling, or page rendering.
enum PDFLosslessReducer {
    struct Report { let originalBytes: Int; let reducedBytes: Int; let saved: Bool }
    static func reduce(source: URL, progress: @Sendable (String) -> Void = { _ in }, cancelled: @Sendable () -> Bool = { false }) throws -> Report {
        func failure(_ message: String) -> NSError { NSError(domain: "DrawbridgeReduce", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        guard let executable = PDFTKBookmarkWriter.executableURL() else { throw failure("The PDF processing helper is unavailable.") }
        let destination = source.standardizedFileURL.resolvingSymlinksInPath()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeReduce-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.pdf")
        try FileManager.default.copyItem(at: destination, to: input)
        func run(_ arguments: [String]) throws {
            if cancelled() { throw CancellationError() }
            guard PDFTKBookmarkWriter.run(executable, arguments: arguments) else { throw failure("Could not reduce this PDF safely. The original file was left unchanged.") }
            if cancelled() { throw CancellationError() }
        }
        func read(_ url: URL, decoded: Bool, name: String) throws -> [String: Any] {
            let json = directory.appendingPathComponent(name)
            try run(["--json=2", "--json-stream-data=inline", "--decode-level=\(decoded ? "generalized" : "none")", url.path, json.path])
            guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any] else { throw failure("Could not inspect PDF objects. No changes were saved.") }
            return result
        }
        progress("Checking PDF content and Unflatten recovery…")
        let original = try read(input, decoded: false, name: "original.json")
        if (original["encrypt"] as? [String: Any])?["encrypted"] as? Bool == true { throw failure("Reduce an unlocked copy of this PDF first.") }
        let table = try objects(original)
        guard !table.values.contains(where: { entry in
            let value = (entry as? [String: Any])?["value"] as? [String: Any]
            return value?["/FT"] as? String == "/Sig" || value?["/Type"] as? String == "/Sig"
        }) else { throw failure("This PDF contains a signature field. Reduce an unsigned copy instead.") }
        let beforeHash = try semanticHash(read(input, decoded: true, name: "decoded-before.json"))
        let output = directory.appendingPathComponent("reduced.pdf")
        progress("Compressing PDF streams without changing image resolution…")
        try run([input.path, "--object-streams=generate", "--stream-data=compress", "--recompress-flate", "--compression-level=9", output.path])
        progress("Verifying image data, drawings, links and page geometry…")
        guard try semanticHash(read(output, decoded: true, name: "decoded-after.json")) == beforeHash else {
            throw failure("Content verification failed. The original PDF was left unchanged.")
        }
        var after = try read(output, decoded: false, name: "after.json")
        if try PDFAnnotationFlattener.refreshRecoveryAfterLosslessCompression(before: original, after: &after) {
            let metadata = directory.appendingPathComponent("recovery.json")
            try PDFJSONPatchEncoder.data(withJSONObject: PDFAnnotationFlattener.metadataJSON(after), options: [.sortedKeys, .withoutEscapingSlashes]).write(to: metadata)
            let recovered = directory.appendingPathComponent("with-recovery.pdf")
            try run([output.path, "--stream-data=preserve", "--update-from-json=\(metadata.path)", recovered.path])
            try FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: recovered, to: output)
            guard try semanticHash(read(output, decoded: true, name: "decoded-final.json")) == beforeHash else { throw failure("Recovery verification failed. The original file was left unchanged.") }
        }
        try run(["--check", output.path])
        let originalData = try Data(contentsOf: input, options: .mappedIfSafe)
        let bytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0 else { throw failure("The output was empty; no changes were saved.") }
        guard bytes < originalData.count else { return Report(originalBytes: originalData.count, reducedBytes: originalData.count, saved: false) }
        guard try Data(contentsOf: destination, options: .mappedIfSafe) == originalData else { throw failure("This file changed during processing. Reopen it and try again.") }
        if cancelled() { throw CancellationError() }
        progress("Saving verified smaller PDF…")
        try MainViewController.commitStagedSave(from: output, to: destination)
        return Report(originalBytes: originalData.count, reducedBytes: bytes, saved: true)
    }

    private static func objects(_ json: [String: Any]) throws -> [String: Any] {
        guard let qpdf = json["qpdf"] as? [[String: Any]], qpdf.count > 1 else { throw CocoaError(.fileReadCorruptFile) }
        return qpdf[1]
    }

    /// Hash the reachable semantic graph, independently of object numbering and
    /// compressed stream lengths. Generalized decoding preserves JPEG/JPX bytes,
    /// while comparing the exact decoded bytes for losslessly compressed streams.
    static func semanticHash(_ json: [String: Any]) throws -> String {
        let table = try objects(json)
        let trailer = (table["trailer"] as? [String: Any])?["value"] as? [String: Any] ?? [:]
        var cache: [String: String] = [:]
        let hex = Array("0123456789abcdef".utf8)
        func digest(_ value: Any, visiting: Set<String>) throws -> String {
            if let ref = value as? String, let entry = table["obj:\(ref)"] as? [String: Any] {
                if visiting.contains(ref) { return "cycle" }
                if let hash = cache[ref] { return hash }
                var next = visiting; next.insert(ref)
                let hash = try digest(entry["value"] ?? entry["stream"] ?? NSNull(), visiting: next)
                cache[ref] = hash
                return hash
            }
            let normalized: Any
            if let dict = value as? [String: Any] {
                var result: [String: String] = [:]
                for key in dict.keys.sorted() where key != "/Length" && key != "/FlattenedDrawingHash" {
                    result[key] = try digest(dict[key]!, visiting: visiting)
                }
                normalized = result
            } else if let array = value as? [Any] { normalized = try array.map { try digest($0, visiting: visiting) } }
            else { normalized = value }
            let bytes = SHA256.hash(data: try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys, .fragmentsAllowed]))
            // Avoid 32 locale-aware format calls for every value in the PDF graph.
            var encoded = [UInt8](); encoded.reserveCapacity(64)
            for byte in bytes { encoded.append(hex[Int(byte >> 4)]); encoded.append(hex[Int(byte & 15)]) }
            return String(decoding: encoded, as: UTF8.self)
        }
        return try digest(["root": trailer["/Root"] ?? NSNull(), "info": trailer["/Info"] ?? NSNull()], visiting: [])
    }

    /// Compare reachable objects directly, allowing qpdf to renumber references.
    /// Streams stay encoded: exact byte comparison avoids serializing and hashing
    /// large base64 image strings twice on every annotation save.
    static func semanticGraphsMatch(_ before: [String: Any], _ after: [String: Any]) throws -> Bool {
        let left = try objects(before), right = try objects(after)
        struct Pair: Hashable { let left: String; let right: String }
        var visited = Set<Pair>()
        let a = (left["trailer"] as? [String: Any])?["value"] as? [String: Any] ?? [:]
        let b = (right["trailer"] as? [String: Any])?["value"] as? [String: Any] ?? [:]
        var pending: [(Any, Any)] = [(a["/Root"] ?? NSNull(), b["/Root"] ?? NSNull()),
                                      (a["/Info"] ?? NSNull(), b["/Info"] ?? NSNull())]
        let ignored = Set(["/Length", "/FlattenedDrawingHash"])
        // PDF parent/child and annotation links form deep cyclic graphs. Keep
        // traversal on an explicit work list rather than the worker thread stack.
        while let (a, b) = pending.popLast() {
            if let a = a as? String, let b = b as? String {
                let first = left["obj:\(a)"] as? [String: Any]
                let second = right["obj:\(b)"] as? [String: Any]
                if let first, let second {
                    if visited.insert(Pair(left: a, right: b)).inserted {
                        pending.append((first["value"] ?? first["stream"] ?? NSNull(), second["value"] ?? second["stream"] ?? NSNull()))
                    }
                } else if first != nil || second != nil || a != b { return false }
            } else if let a = a as? [String: Any], let b = b as? [String: Any] {
                let keys = Set(a.keys).subtracting(ignored)
                guard keys == Set(b.keys).subtracting(ignored) else { return false }
                for key in keys { pending.append((a[key]!, b[key]!)) }
            } else if let a = a as? [Any], let b = b as? [Any] {
                guard a.count == b.count else { return false }
                pending.append(contentsOf: zip(a, b))
            } else if let a = a as? NSNumber, let b = b as? NSNumber {
                // JSON booleans must not compare equal to numeric 0 or 1.
                guard (CFGetTypeID(a) == CFBooleanGetTypeID()) == (CFGetTypeID(b) == CFBooleanGetTypeID()) else { return false }
                if a != b {
                    // Foundation may parse the same JSON number as a decimal or
                    // binary NSNumber. Compare their canonical JSON spelling;
                    // do not use a tolerance that could conceal a content change.
                    guard try JSONSerialization.data(withJSONObject: a, options: .fragmentsAllowed) == JSONSerialization.data(withJSONObject: b, options: .fragmentsAllowed) else { return false }
                }
            } else if !(a is NSNull && b is NSNull) { return false }
        }
        return true
    }
}

/// Cross-thread cancellation without reading AppKit state from worker queues.
final class PDFProcessingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
