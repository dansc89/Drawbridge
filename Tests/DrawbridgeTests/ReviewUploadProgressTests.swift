import Foundation
import CryptoKit
import XCTest
@testable import Drawbridge

/// Real TCP/HTTP, not URLProtocol or the API's offline transport seam. The server
/// reads slowly and cannot send the upload response until the test opens a gate.
@MainActor final class ReviewUploadProgressTests: XCTestCase {
    private final class Fixture {
        let directory: URL
        let process = Process()
        var origin: URL!
        var file: URL { directory.appendingPathComponent("sample.pdf") }
        var responseSent: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("responded").path) }
        var redirected: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("redirected").path) }
        init(mode: String) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewUploadProgress-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // A genuine one-page PDF with a large comment in its content stream.
            let content = "q\n%" + String(repeating: "A", count: 4 * 1024 * 1024) + "\nQ\n"
            let objects = [
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 72 72] /Contents 4 0 R >>",
                "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream"
            ]
            var pdf = Data("%PDF-1.4\n".utf8)
            var offsets = [Int]()
            for (index, object) in objects.enumerated() {
                offsets.append(pdf.count)
                pdf.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
            }
            let xref = pdf.count
            pdf.append(Data("xref\n0 5\n0000000000 65535 f \n".utf8))
            for offset in offsets { pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
            pdf.append(Data("trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
            try pdf.write(to: file)
            if mode == "chunks" {
                let handle = try FileHandle(forWritingTo: file)
                try handle.truncate(atOffset: 96_000_000)
                try handle.close()
            }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-u", "-c", Self.server, directory.path, mode]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
        func start() async throws {
            let portFile = directory.appendingPathComponent("port")
            for _ in 0..<500 {
                if let text = try? String(contentsOf: portFile, encoding: .utf8), let port = Int(text) {
                    origin = URL(string: "http://127.0.0.1:\(port)")!
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Loopback server failed to start")
            throw URLError(.cannotConnectToHost)
        }
        func releaseResponse() throws { try Data().write(to: directory.appendingPathComponent("release")) }
        func stop() {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
        static let server = #"""
import http.server, json, pathlib, sys, time
root, mode = pathlib.Path(sys.argv[1]), sys.argv[2]
attempts = []
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def reply(self, value, status=200, headers={}):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Content-Type', 'application/json')
        for key, value in headers.items(): self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path == '/v1/projects/p/documents': self.reply({'documents': []})
        elif self.path == '/v1/documents/d/upload-parts': self.reply({'parts': [1, 3, 11]})
        else:
            (root / 'redirected').touch()
            self.reply({})
    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0'))
        if '/upload-parts/' in self.path:
            index = int(self.path.rsplit('/', 1)[1])
            attempts.append(index)
            (root / 'attempts').write_text(json.dumps(attempts))
            while length:
                chunk = self.rfile.read(min(length, 16384))
                if not chunk: return
                length -= len(chunk)
                if index == 0: time.sleep(.001)
            if index == 0 and attempts.count(0) == 1: self.reply({}, 500)
            else: self.reply({'index': index})
        elif self.path.endswith('/complete-upload'):
            self.rfile.read(length)
            self.reply({'document': {'id': 'd', 'name': 'sample.pdf'}})
        elif self.path.endswith('/upload'):
            if mode == 'redirect':
                self.rfile.read(length)
                self.reply({}, 307, {'Location': '/redirect-target'})
                return
            while length:
                chunk = self.rfile.read(min(length, 16384))
                if not chunk: return
                length -= len(chunk)
                time.sleep(.004)
            deadline = time.monotonic() + 12
            while not (root / 'release').exists() and time.monotonic() < deadline:
                time.sleep(.01)
            (root / 'responded').touch()
            self.reply({'document': {'id': 'd', 'name': 'sample.pdf'}})
        elif self.path == '/v1/projects/p/documents':
            self.rfile.read(length)
            self.reply({'document': {'id': 'd', 'name': 'sample.pdf'}})
        else:
            (root / 'redirected').touch()
            self.rfile.read(length)
            self.reply({})
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
"""#
    }

    func testSmallPDFReportsPayloadBytesBeforeServerResponds() async throws {
        let fixture = try Fixture(mode: "upload")
        defer { fixture.stop() }
        try await fixture.start()
        let api = SharedReviewAPI(origin: fixture.origin, token: "loopback-only", displayName: nil, instanceID: "test")
        defer { api.invalidate() }
        let intermediate = expectation(description: "actual intermediate payload bytes before HTTP response")
        var samples: [Int] = []
        var observedIntermediate = false
        let size = try Data(contentsOf: fixture.file).count
        let upload = Task {
            try await api.upload(fixture.file, project: .init(id: "p", name: "Project")) { sent, total in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(total, size, "multipart envelope must not count toward PDF bytes")
                XCTAssertTrue((0...size).contains(sent))
                if let last = samples.last { XCTAssertGreaterThanOrEqual(sent, last) }
                samples.append(sent)
                if sent > 0 && sent < total && !observedIntermediate {
                    observedIntermediate = true
                    XCTAssertFalse(fixture.responseSent)
                    intermediate.fulfill()
                }
            }
        }
        await fulfillment(of: [intermediate], timeout: 5)
        XCTAssertFalse(fixture.responseSent, "server's response gate is still closed")
        try fixture.releaseResponse()
        let document = try await upload.value
        XCTAssertEqual(document.id, "d")
        XCTAssertEqual(samples.last, size)
        XCTAssertTrue(observedIntermediate)
    }

    func testPerTaskUploadDelegateRejectsRedirects() async throws {
        let fixture = try Fixture(mode: "redirect")
        defer { fixture.stop() }
        try await fixture.start()
        let api = SharedReviewAPI(origin: fixture.origin, token: "loopback-only", displayName: nil, instanceID: "test")
        defer { api.invalidate() }
        do {
            _ = try await api.upload(fixture.file, project: .init(id: "p", name: "Project")) { _, _ in }
            XCTFail("redirect must not be followed")
        } catch let error as SharedReviewError { XCTAssertEqual(error.statusCode, 307) }
        XCTAssertFalse(fixture.redirected, "authenticated upload must never follow a redirect")
    }

    func testChunkProgressIncludesNoncontiguousResumeAndDoesNotDoubleCountRetry() async throws {
        let fixture = try Fixture(mode: "chunks")
        defer { fixture.stop() }
        try await fixture.start()
        let api = SharedReviewAPI(origin: fixture.origin, token: "loopback-only", displayName: nil, instanceID: "test")
        defer { api.invalidate() }
        let bytes = try Data(contentsOf: fixture.file, options: .mappedIfSafe)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let key = "ReviewUpload|\(fixture.origin.absoluteString)|test|p||sample.pdf|\(digest)"
        UserDefaults.standard.set("d", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let partSize = 8 * 1024 * 1024
        let resumed = 2 * partSize + (bytes.count - 11 * partSize)
        var samples: [Int] = []
        let document = try await api.upload(fixture.file, project: .init(id: "p", name: "Project")) { sent, total in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(total, bytes.count)
            XCTAssertTrue((resumed...total).contains(sent))
            if let last = samples.last { XCTAssertGreaterThanOrEqual(sent, last) }
            samples.append(sent)
        }
        XCTAssertEqual(document.id, "d")
        XCTAssertEqual(samples.first, resumed)
        XCTAssertEqual(samples.last, bytes.count)
        XCTAssertTrue(samples.contains { $0 > resumed && $0 < resumed + partSize }, "real bytes within first missing part")
        let attempts = try JSONDecoder().decode([Int].self, from: Data(contentsOf: fixture.directory.appendingPathComponent("attempts")))
        XCTAssertEqual(attempts.filter { $0 == 0 }.count, 2, "500 retries the same part")
        XCTAssertTrue(Set(attempts).isDisjoint(with: [1, 3, 11]), "resumed parts must not be resent")
        XCTAssertEqual(Set(attempts), Set(0..<12).subtracting([1, 3, 11]))
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }

    func testInvalidationStopsInFlightUploadAndQueuedProgress() async throws {
        try await assertCancellation(invalidate: true)
    }
    func testCancellationStopsInFlightUploadAndQueuedProgress() async throws {
        try await assertCancellation(invalidate: false)
    }
    private func assertCancellation(invalidate: Bool) async throws {
        let fixture = try Fixture(mode: "upload")
        defer { fixture.stop() }
        try await fixture.start()
        let api = SharedReviewAPI(origin: fixture.origin, token: "loopback-only", displayName: nil, instanceID: "test")
        defer { api.invalidate() }
        let intermediate = expectation(description: "in-flight progress")
        var count = 0
        let upload = Task {
            try await api.upload(fixture.file, project: .init(id: "p", name: "Project")) { sent, total in
                count += 1
                if count == 1 && sent > 0 && sent < total { intermediate.fulfill() }
            }
        }
        await fulfillment(of: [intermediate], timeout: 5)
        if invalidate { api.invalidate() } else { upload.cancel() }
        do { _ = try await upload.value; XCTFail("revoked upload succeeded") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        let stoppedCount = count
        try fixture.releaseResponse()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(count, stoppedCount, "late delegate callbacks must not escape cancellation")
    }
}
