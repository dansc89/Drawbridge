import XCTest
import AppKit
@testable import Drawbridge

final class BookmarkIndexExportTests: XCTestCase {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testGoldenFormattingTraversalAndBytes() throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("References/bookmark-export/golden-cases.json"))) as! [String: Any]
        for c in json["titleCases"] as! [[String: String]] { XCTAssertEqual(BookmarkIndexExport.format(c["input"]!), c["expected"]!) }
        func nodes(_ value: Any?) -> [BookmarkIndexNode] {
            guard let array = value as? [Any] else { return [] }
            return array.flatMap { item -> [BookmarkIndexNode] in
                if item is [Any] { return nodes(item) }
                let dict = item as! [String: Any]
                return [BookmarkIndexNode(title: dict["title"] as? String ?? "", children: nodes(dict["items"]))]
            }
        }
        var rows = [["PDF", "Title"]]
        for file in json["files"] as! [[String: Any]] { rows += BookmarkIndexExport.rows(nodes(file["outline"]), filename: file["name"] as! String) }
        XCTAssertEqual(rows, json["expectedRows"] as! [[String]])
        XCTAssertEqual(BookmarkIndexExport.csv(rows), Data((json["expectedCSV"] as! String).utf8))
        XCTAssertEqual(BookmarkIndexExport.csv([["PDF","Title"]]), Data("PDF,Title".utf8))
        XCTAssertEqual(BookmarkIndexExport.csv([["x\ry","a\nb"],["x\"y","z,w"]]), Data("x\ry,\"a\nb\"\n\"x\"\"y\",\"z,w\"".utf8))
        let whitespace: [UInt32] = Array(9...13) + [32,160,5760] + Array(8192...8202) + [8232,8233,8239,8287,12288,65279]
        for scalar in whitespace { XCTAssertEqual(BookmarkIndexExport.format("A1" + String(UnicodeScalar(scalar)!) + "Plan"), "A1 - Plan") }
        XCTAssertEqual(BookmarkIndexExport.format("\u{85}A1\u{200B}"), "\u{85}A1\u{200B}")
    }
    func testASCIIARCHPredicate() {
        for name in ["ARCH.pdf","Project_ARCH.pdf","ARCHITECTURAL.pdf","set_arch.PDF","aRcH-set.pdf","Research.pdf"] { XCTAssertTrue(BookmarkIndexExport.excludes(name), name) }
        for name in ["STRUCT.pdf","MECH.pdf","A101.pdf","Electrical.pdf","ＡＲＣＨ.pdf"] { XCTAssertFalse(BookmarkIndexExport.excludes(name), name) }
    }
    func testDiscoveryDeterministicBasenameFilterAndSkippedEntries() throws {
        let dir = try temporary()
        for path in ["z.PDF","a/same.pdf","b/same.pdf","ARCH folder/STRUCT.pdf","Research.pdf","ARCH-corrupt.pdf",".hidden.pdf",".hidden/x.pdf","Box.app/x.pdf","not.txt","é.pdf","B.pdf"] {
            let file = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("corrupt".utf8).write(to: file)
        }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.pdf"), withDestinationURL: dir.appendingPathComponent("z.PDF"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("linked"), withDestinationURL: dir.appendingPathComponent("a"))
        let result = try BookmarkIndexExport.discover(dir)
        let prefix = dir.resolvingSymlinksInPath().path + "/"
        let paths = result.files.map { String($0.resolvingSymlinksInPath().path.dropFirst(prefix.count)) }
        XCTAssertEqual(paths.map { $0.precomposedStringWithCanonicalMapping }.sorted(), ["ARCH folder/STRUCT.pdf","B.pdf","a/same.pdf","b/same.pdf","z.PDF","é.pdf"].sorted())
        XCTAssertEqual(paths, paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        XCTAssertEqual(result.excluded, 2)
    }
    func testCancellationFailureAndAtomicOutput() throws {
        let dir = try temporary(), output = dir.appendingPathComponent("out.csv")
        let old = Data("existing output".utf8)
        try old.write(to: output)
        XCTAssertThrowsError(try BookmarkIndexExport.discover(dir, cancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try BookmarkIndexExport.extract(dir, cancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        let result = BookmarkIndexResult(data: Data("PDF,Title".utf8), files: 1, excluded: 0, rows: 0)
        XCTAssertThrowsError(try BookmarkIndexExport.write(result, to: output, cancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: output), old)
        try BookmarkIndexExport.write(result, to: output)
        XCTAssertEqual(try Data(contentsOf: output), result.data)
        XCTAssertThrowsError(try BookmarkIndexExport.write(result, to: dir.appendingPathComponent("missing/out.csv")))
        XCTAssertEqual(try Data(contentsOf: output), result.data)
        let bad = dir.appendingPathComponent("Broken.pdf")
        try Data("not a PDF".utf8).write(to: bad)
        XCTAssertThrowsError(try BookmarkIndexExport.extract(dir)) { XCTAssertTrue($0.localizedDescription.contains("Broken.pdf")) }
        XCTAssertEqual(try Data(contentsOf: bad), Data("not a PDF".utf8))
    }
    func testRealPDFPostorderDestinationsDuplicatesAndReadOnly() throws {
        let dir = try temporary(), file = dir.appendingPathComponent("Set, \"A\".pdf")
        let original = BookmarkIndexFixtures.pdf(BookmarkIndexFixtures.items)
        try original.write(to: file)
        let nodes = try BookmarkIndexExport.outline(file)
        let titles = BookmarkIndexExport.rows(nodes, filename: file.lastPathComponent).map { $0[1] }
        XCTAssertEqual(titles, ["A101 - FLOOR PLAN", "A102 - Detail, \"East\"", "Group", "a103 café", "GENERAL - NOTES", "A101 - Plan", "A101 - Plan", "B200 - Schedule", "É101 café", "A101 - - FLOOR PLAN", "A101\u{85}Plan", "A101\u{200B}Plan", "No destination"])
        let result = try BookmarkIndexExport.extract(dir)
        XCTAssertEqual(result.rows, 13)
        XCTAssertEqual(try Data(contentsOf: file), original)
        var checks = 0
        XCTAssertThrowsError(try BookmarkIndexExport.outline(file, cancelled: { checks += 1; return checks > 4 })) { XCTAssertTrue($0 is CancellationError) }
    }
    func testRealPDFNoBookmarksUnreadableAndCancelledPublication() throws {
        let dir = try temporary(), file = dir.appendingPathComponent("Empty.pdf")
        try BookmarkIndexFixtures.pdf([]).write(to: file)
        let result = try BookmarkIndexExport.extract(dir)
        XCTAssertEqual(result.files, 1)
        XCTAssertEqual(result.rows, 0)
        XCTAssertEqual(result.data, Data("PDF,Title".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        XCTAssertThrowsError(try BookmarkIndexExport.outline(file)) { XCTAssertTrue($0.localizedDescription.contains("Empty.pdf")) }
        let output = dir.appendingPathComponent("out.csv")
        try Data("old".utf8).write(to: output)
        var checks = 0
        XCTAssertThrowsError(try BookmarkIndexExport.write(result, to: output, cancelled: { checks += 1; return checks == 2 })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: output), Data("old".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix(".bookmark-index-") })
    }
    func testGenerateDurableParityFixtures() throws {
        let dir = root.appendingPathComponent(".build/bookmark-export-evidence/parity/fixtures")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for path in ["Set, \"A\".pdf", "空.pdf", "a/same.pdf", "b/same.pdf", "ARCH folder/STRUCT.PDF", "Research.pdf", "ARCH-corrupt.pdf", ".hidden.pdf", "Box.app/x.pdf"] {
            let file = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = path.contains("ARCH-corrupt") ? Data("invalid excluded PDF".utf8) : BookmarkIndexFixtures.pdf(path == "空.pdf" ? [] : BookmarkIndexFixtures.items)
            try bytes.write(to: file)
        }
        let discovery = try BookmarkIndexExport.discover(dir)
        let order = discovery.files.map(\.path)
        try JSONSerialization.data(withJSONObject: order, options: [.prettyPrinted, .withoutEscapingSlashes]).write(to: dir.deletingLastPathComponent().appendingPathComponent("order.json"))
        let result = try BookmarkIndexExport.extract(dir)
        XCTAssertEqual(result.files, 5)
        XCTAssertEqual(result.excluded, 2)
        XCTAssertEqual(result.rows, 52)
        try BookmarkIndexExport.write(result, to: dir.deletingLastPathComponent().appendingPathComponent("native.csv"))
    }
    func testWriterRejectsSourcePDFAndAliases() throws {
        let dir = try temporary(), source = dir.appendingPathComponent("Source.pdf")
        let original = BookmarkIndexFixtures.pdf(BookmarkIndexFixtures.items)
        try original.write(to: source)
        let result = try BookmarkIndexExport.extract(dir)
        let symbolic = dir.appendingPathComponent("alias.csv")
        let hard = dir.appendingPathComponent("hard.csv")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: source)
        try FileManager.default.linkItem(at: source, to: hard)
        for destination in [symbolic, hard, source, dir.appendingPathComponent("other.pdf")] {
            XCTAssertThrowsError(try BookmarkIndexExport.write(result, to: destination))
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: symbolic), original)
        XCTAssertEqual(try Data(contentsOf: hard), original)
    }
    func testLockedPDFRejectsWithoutChangingBytes() throws {
        let dir = try temporary(), source = dir.appendingPathComponent("Original.pdf"), locked = dir.appendingPathComponent("Locked.pdf")
        try BookmarkIndexFixtures.pdf(BookmarkIndexFixtures.items).write(to: source)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/qpdf")
        task.arguments = ["--encrypt", "fixture-password", "fixture-owner", "256", "--", source.path, locked.path]
        try task.run(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        let bytes = try Data(contentsOf: locked)
        XCTAssertThrowsError(try BookmarkIndexExport.outline(locked)) { XCTAssertTrue($0.localizedDescription.contains("Locked.pdf")); XCTAssertTrue($0.localizedDescription.contains("password")) }
        XCTAssertEqual(try Data(contentsOf: locked), bytes)
        let evidence = root.appendingPathComponent(".build/bookmark-export-evidence/parity")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try bytes.write(to: evidence.appendingPathComponent("Locked.pdf"))
        try Data("not a PDF".utf8).write(to: evidence.appendingPathComponent("Corrupt.pdf"))
    }
    func testEmptyAndAllExcluded() throws {
        let dir = try temporary()
        let empty = try BookmarkIndexExport.extract(dir)
        XCTAssertEqual(empty.files, 0)
        XCTAssertEqual(empty.data, Data("PDF,Title".utf8))
        try Data("invalid".utf8).write(to: dir.appendingPathComponent("ARCH.pdf"))
        let excluded = try BookmarkIndexExport.extract(dir)
        XCTAssertEqual(excluded.excluded, 1)
        XCTAssertEqual(excluded.files, 0)
    }
}
