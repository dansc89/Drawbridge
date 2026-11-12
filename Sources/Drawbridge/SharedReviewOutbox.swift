import CryptoKit
import Foundation

struct SharedReviewOutbox {
    struct Edit: Codable, Equatable {
        let clientOpId: String
        let payload: SharedReviewAPI.Markup
    }

    private struct SavedEdits: Codable {
        let baseDigest: Data
        let edits: [Edit]
    }

    private let file: URL
    private let baseDigest: Data

    init(origin: URL, instanceID: String, documentID: String, basePDF: Data,
         directory: URL? = nil) throws {
        let root = try directory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Drawbridge/Review Outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let scope = try JSONEncoder().encode([origin.absoluteString, instanceID, documentID])
        let filename = SHA256.hash(data: scope).map { String(format: "%02x", $0) }.joined()
        file = root.appendingPathComponent(filename).appendingPathExtension("plist")
        baseDigest = Data(SHA256.hash(data: basePDF))
    }

    func load() throws -> [Edit] {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        let saved = try PropertyListDecoder().decode(SavedEdits.self, from: data)
        guard saved.baseDigest == baseDigest || saved.edits.isEmpty else {
            throw SharedReviewError("The shared PDF changed. Pending edits were kept on this Mac for recovery.")
        }
        return saved.edits
    }

    func save(_ edits: [Edit]) throws {
        let data = try PropertyListEncoder().encode(SavedEdits(baseDigest: baseDigest, edits: edits))
        try data.write(to: file, options: .atomic)
    }
}
