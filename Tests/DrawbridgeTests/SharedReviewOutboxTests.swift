import Foundation
import XCTest
@testable import Drawbridge

final class SharedReviewOutboxTests: XCTestCase {
    func testReopenPreservesUnacknowledgedEditsAndTheirOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = try XCTUnwrap(URL(string: "https://example.com"))
        let basePDF = Data("base PDF bytes".utf8)
        func open(instanceID: String = "device-a", bytes: Data = basePDF) throws -> SharedReviewOutbox {
            try SharedReviewOutbox(origin: origin, instanceID: instanceID, documentID: "document-a",
                                   basePDF: bytes, directory: directory)
        }

        let first = SharedReviewOutbox.Edit(clientOpId: "first", payload: .init(id: "a", page: 0, record: nil))
        let second = SharedReviewOutbox.Edit(clientOpId: "second", payload: .init(id: "b", page: 1, record: nil))
        XCTAssertEqual(try open().load(), [])
        try open().save([first, second])
        XCTAssertEqual(try open().load(), [first, second])
        XCTAssertEqual(try open(instanceID: "device-b").load(), [])
        XCTAssertThrowsError(try open(bytes: Data("different base".utf8)).load())
        XCTAssertEqual(try open().load(), [first, second])
        try open().save([second])
        XCTAssertEqual(try open().load(), [second])
        try open().save([])
        XCTAssertEqual(try open().load(), [])
    }
}
