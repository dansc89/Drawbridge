import XCTest
@testable import Drawbridge

@MainActor
final class ReviewAtomicUploadTests: XCTestCase {
    func testFailedUploadAbortsOnlyItsStagingWithoutUsingDocumentDeletion() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("%PDF-1.4\nfixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var paths: [String] = []
        var api = SharedReviewAPI(origin: URL(string: "https://upload-fixture.invalid")!, token: "fixture", displayName: "Fixture", instanceID: "fixture")
        api.transport = { request in
            if request.httpMethod == "GET" {
                return (Data(#"{"documents":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            paths.append(request.url!.path)
            if request.url!.path.hasSuffix("/upload") { throw SharedReviewError("Upload failed", statusCode: 422) }
            let json = request.url!.path.hasSuffix("/abort-upload") ? #"{"ok":true}"# : #"{"document":{"id":"staged","name":"fixture.pdf"}}"#
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await api.upload(file, project: .init(id: "p", name: "Project"))
            XCTFail("Failure must propagate")
        } catch { XCTAssertEqual(error.localizedDescription, "Upload failed") }
        XCTAssertEqual(paths, ["/v1/projects/p/documents", "/v1/documents/staged/upload", "/v1/documents/staged/abort-upload"])
    }

    func testAbortFailurePreservesOriginalUploadErrorAndNeverDeletesPublishedDocument() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("%PDF-1.4\nfixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var paths: [String] = []
        var api = SharedReviewAPI(origin: URL(string: "https://upload-fixture.invalid")!, token: "fixture", displayName: "Fixture", instanceID: "fixture")
        api.transport = { request in
            if request.httpMethod == "GET" {
                return (Data(#"{"documents":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            paths.append(request.url!.path)
            if request.url!.path.hasSuffix("/upload") { throw URLError(.networkConnectionLost) }
            if request.url!.path.hasSuffix("/abort-upload") { throw URLError(.notConnectedToInternet) }
            return (Data(#"{"document":{"id":"staged","name":"fixture.pdf"}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await api.upload(file, project: .init(id: "p", name: "Project"))
            XCTFail("Failure must propagate")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        XCTAssertTrue(paths.contains("/v1/documents/staged/abort-upload"))
        XCTAssertFalse(paths.contains { $0.contains("remove-item") })
    }
}
