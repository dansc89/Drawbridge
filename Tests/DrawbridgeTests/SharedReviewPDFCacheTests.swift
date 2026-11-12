import Foundation
import XCTest
@testable import Drawbridge

final class SharedReviewPDFCacheTests: XCTestCase {
    func testVerifiedFileSurvivesReopenAndRejectsWrongBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = try XCTUnwrap(URL(string: "https://example.com"))
        let document = try JSONDecoder().decode(SharedReviewAPI.Document.self, from: Data("""
            {"id":"document-a","name":"Drawing.pdf","file_size":3,
             "file_sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}
            """.utf8))
        func open(_ device: String = "device-a") throws -> SharedReviewPDFCache {
            try XCTUnwrap(SharedReviewPDFCache(origin: origin, instanceID: device,
                                               document: document, directory: directory))
        }
        let original = Data("abc".utf8)
        let corrupt = Data("abd".utf8)
        let cache = try open()
        XCTAssertNil(try cache.load())
        try cache.store(original)
        XCTAssertEqual(try open().load(), original)
        XCTAssertNil(try open("device-b").load())
        XCTAssertThrowsError(try cache.store(corrupt))
        XCTAssertEqual(try cache.load(), original)
        try corrupt.write(to: cache.file, options: .atomic)
        XCTAssertNil(try cache.load())
        try cache.store(original)
        XCTAssertEqual(try open().load(), original)
    }
}
