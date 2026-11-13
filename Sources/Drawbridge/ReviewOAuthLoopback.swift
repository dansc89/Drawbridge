import Foundation
import Darwin

/// A single-attempt, ephemeral IPv4 loopback listener; never binds a LAN interface.
final class ReviewOAuthLoopback: @unchecked Sendable {
    let redirect: URL
    private let descriptor: Int32
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var canceled = false
    private var started = false

    init(timeout: TimeInterval = 180) throws {
        self.timeout = timeout
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SharedReviewError("Could not create Google callback listener.") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, named == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw SharedReviewError("Could not bind Google callback listener.")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        descriptor = fd
        redirect = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/oauth/callback")!
    }
    deinit { Darwin.close(descriptor) }
    func cancel() { lock.lock(); canceled = true; lock.unlock() }
    private func isCanceled() -> Bool { lock.lock(); defer { lock.unlock() }; return canceled }
    private func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return false }
        started = true
        return true
    }
    func callback() async throws -> URL {
        guard claim() else { throw SharedReviewError("Google callback already requested.") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do { continuation.resume(returning: try receive()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }
    private func receive() throws -> URL {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !isCanceled(), ProcessInfo.processInfo.systemUptime < deadline {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 50) > 0 else { continue }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { continue }
            defer { Darwin.close(client) }
            _ = fcntl(client, F_SETFL, O_NONBLOCK)
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var data = Data()
            while !isCanceled(), ProcessInfo.processInfo.systemUptime < deadline, data.count < 16384 {
                var input = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                guard poll(&input, 1, 50) > 0 else { continue }
                var bytes = [UInt8](repeating: 0, count: 2048)
                let count = recv(client, &bytes, bytes.count, 0)
                guard count > 0 else { break }
                data.append(contentsOf: bytes.prefix(count))
                guard let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n") else { continue }
                let line = text.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard line.count == 3, line[0] == "GET", line[1].hasPrefix("/oauth/callback?"),
                      let callback = URL(string: String(line[1]), relativeTo: redirect)?.absoluteURL,
                      callback.host == redirect.host, callback.port == redirect.port,
                      callback.path == redirect.path else {
                    throw SharedReviewError("Invalid Google callback request.")
                }
                let body = "Sign-in received. You can return to Drawbridge now.\n"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
                _ = response.withCString { send(client, $0, strlen($0), 0) }
                return callback
            }
        }
        throw SharedReviewError(isCanceled() ? "Google sign-in canceled." : "Google sign-in timed out. Try again.")
    }
}
