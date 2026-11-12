import CryptoKit
import Foundation

struct SharedReviewPDFCache {
    let file: URL
    private let expectedHash: String
    private let expectedSize: Int?

    init?(origin: URL, instanceID: String, document: SharedReviewAPI.Document, directory: URL? = nil) throws {
        guard let hash = document.file_sha256?.lowercased(), hash.utf8.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        expectedHash = hash
        expectedSize = document.file_size
        let root = try directory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Drawbridge/Review PDFs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let scope = try JSONEncoder().encode([origin.absoluteString, instanceID, document.id])
        file = root.appendingPathComponent(Self.hexDigest(scope)).appendingPathExtension("pdf")
    }

    func load() throws -> Data? {
        do {
            let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
            return matches(bytes) ? bytes : nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func store(_ bytes: Data) throws {
        guard matches(bytes) else {
            throw SharedReviewError("The downloaded PDF did not match the server’s file checksum.")
        }
        try bytes.write(to: file, options: .atomic)
    }

    private func matches(_ bytes: Data) -> Bool {
        (expectedSize == nil || expectedSize == bytes.count) && Self.hexDigest(bytes) == expectedHash
    }

    private static func hexDigest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
