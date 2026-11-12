import CryptoKit
import Foundation

struct SharedReviewError: LocalizedError {
    let errorDescription: String?
    let statusCode: Int?
    init(_ message: String, statusCode: Int? = nil) {
        errorDescription = message
        self.statusCode = statusCode
    }
}

struct SharedReviewAPI {
    struct Project: Decodable { let id: String; let name: String }
    struct Document: Decodable {
        let id: String
        let name: String
        let file_size: Int?
        let file_sha256: String?
        let folder_id: String?
    }
    struct Markup: Codable, Equatable {
        let id: String
        let page: Int
        let record: RectangleMarkupRecord?
        var ownerInstanceId: String? = nil
    }
    struct Operation: Decodable {
        let seq: Int
        let op_type: String
        let payload: Markup?
        private enum CodingKeys: String, CodingKey { case seq, op_type, payload }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            seq = try values.decode(Int.self, forKey: .seq)
            op_type = try values.decode(String.self, forKey: .op_type)
            payload = op_type == "drawbridge.markup.v1"
                ? try values.decode(Markup.self, forKey: .payload) : nil
        }
    }
    struct ProjectList: Decodable { let projects: [Project] }
    struct Folder: Decodable { let id: String; let parent_id: String?; let name: String }
    struct DocumentList: Decodable { let documents: [Document]; let folders: [Folder]?; let organizationActions: Bool? }
    struct MoveRequest: Encodable { let ids: [String]; let folderId: String }
    struct RemoveRequest: Encodable { let kind: String; let id: String; let confirmation: String }
    struct OrganizationReceipt: Decodable { let ok: Bool }
    struct CreatedFolder: Decodable { let folder: Folder }
    struct FolderRequest: Encodable { let name: String; let parentId: String? }
    struct DocumentRequest: Encodable { let name: String; let folderId: String? }
    struct CreatedDocument: Decodable { let document: Document }
    struct CreatedSession: Decodable {
        struct Session: Decodable { let id: String }
        let session: Session
    }
    struct Operations: Decodable { let ops: [Operation] }
    struct Receipt: Decodable { let op: Operation }
    struct Append: Encodable {
        let sessionId: String
        let opType = "drawbridge.markup.v1"
        let clientOpId: String
        let payload: Markup
    }

    let origin: URL
    let token: String
    let displayName: String?
    let instanceID: String

    struct Capabilities: Decodable {
        let creatorOnlyMarkups: Bool?
        let reviewUsernames: Bool?
        let reviewUsername: String?
    }
    struct Identity: Decodable { let username: String }

    func claimUsername(_ username: String) async throws -> Identity {
        try await post("auth/review-username", ["username": username])
    }
    func createFolder(name: String, parentID: String?, projectID: String) async throws -> CreatedFolder {
        do {
            return try await post("projects/\(projectID)/folders", FolderRequest(name: name, parentId: parentID))
        } catch let error as SharedReviewError where error.statusCode == 409 {
            throw SharedReviewError("A folder with this name already exists here. Choose a unique folder name.",
                                    statusCode: 409)
        }
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    private func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.path = "/v1/" + path
        parts.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: parts.url!, timeoutInterval: 30)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 401 { throw SharedReviewError("Session expired. Sign in again in General settings.") }
            if code == 413 { throw SharedReviewError("The server rejected this PDF because it exceeds the upload limit.") }
            throw SharedReviewError("Drawbridge Review request failed (HTTP \(code)).", statusCode: code)
        }
    }

    func get<Value: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Value {
        let (data, response) = try await Self.session.data(for: request(path, query: query))
        try validate(response)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func post<Value: Decodable>(_ path: String, _ body: some Encodable) async throws -> Value {
        var request = request(path)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await Self.session.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func download(_ document: Document) async throws -> Data {
        let (file, response) = try await Self.session.download(for: request("documents/\(document.id)/download"))
        defer { try? FileManager.default.removeItem(at: file) }
        try validate(response)
        return try Data(contentsOf: file, options: .mappedIfSafe)
    }

    static let duplicateUploadMessage = "This PDF or a PDF with the same name is already in this folder. Open the existing PDF to continue the review."

    private func rejectDuplicateUpload(name: String, digest: String, projectID: String,
                                       folderID: String?) async throws {
        let list: DocumentList = try await get("projects/\(projectID)/documents")
        if list.documents.contains(where: {
            $0.file_size != nil && $0.folder_id == folderID && ($0.file_sha256 == digest ||
                $0.name.compare(name.trimmingCharacters(in: .whitespacesAndNewlines),
                                options: [.caseInsensitive, .widthInsensitive]) == .orderedSame)
        }) {
            throw SharedReviewError(Self.duplicateUploadMessage, statusCode: 409)
        }
    }

    private static let uploadPartSize = 8 * 1024 * 1024
    private struct UploadStatus: Decodable { let parts: [Int]; let document: Document? }
    private struct UploadPart: Decodable { let index: Int }
    private struct CompleteUpload: Encodable { let size: Int; let sha256: String }

    func upload(_ file: URL, project: Project, folderID: String? = nil,
                progress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> Document {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (5...(1024 * 1024 * 1024)).contains(size) else {
            throw SharedReviewError("Choose a PDF up to 1 GiB.")
        }
        if size <= 95_000_000 {
            let bytes = try Data(contentsOf: file)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try await rejectDuplicateUpload(name: file.lastPathComponent, digest: digest,
                                            projectID: project.id, folderID: folderID)
            let created: CreatedDocument = try await post("projects/\(project.id)/documents",
                DocumentRequest(name: file.lastPathComponent, folderId: folderID))
            let result: CreatedDocument = try await uploadPart(bytes, to: "documents/\(created.document.id)/upload")
            await progress?(size, size)
            return result.document
        }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: Self.uploadPartSize), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let key = "ReviewUpload|\(origin.absoluteString)|\(instanceID)|\(project.id)|\(folderID ?? "")|\(file.lastPathComponent)|\(digest)"
        let defaults = UserDefaults.standard
        let savedID = defaults.string(forKey: key)
        var documentID: String
        var status = UploadStatus(parts: [], document: nil)
        if let savedID {
            do {
                status = try await get("documents/\(savedID)/upload-parts")
                documentID = savedID
            } catch let error as SharedReviewError where error.statusCode == 403 || error.statusCode == 404 {
                defaults.removeObject(forKey: key)
                try await rejectDuplicateUpload(name: file.lastPathComponent, digest: digest,
                                                projectID: project.id, folderID: folderID)
                documentID = try await createUpload(file, project: project, folderID: folderID, key: key)
            }
        } else {
            try await rejectDuplicateUpload(name: file.lastPathComponent, digest: digest,
                                            projectID: project.id, folderID: folderID)
            documentID = try await createUpload(file, project: project, folderID: folderID, key: key)
        }
        if let document = status.document {
            defaults.removeObject(forKey: key)
            await progress?(size, size)
            return document
        }
        let path = "documents/\(documentID)"
        let uploadedParts = Set(status.parts)
        let partCount = (size + Self.uploadPartSize - 1) / Self.uploadPartSize
        var uploadedBytes = 0
        for index in 0..<partCount {
            let offset = index * Self.uploadPartSize
            let length = min(Self.uploadPartSize, size - offset)
            if uploadedParts.contains(index) {
                uploadedBytes += length
                continue
            }
            try handle.seek(toOffset: UInt64(offset))
            guard let bytes = try handle.read(upToCount: length), bytes.count == length else {
                throw SharedReviewError("The PDF changed during upload. Select it again to retry.")
            }
            try await sendUploadPart(bytes, path: path, index: index)
            uploadedBytes += length
            await progress?(uploadedBytes, size)
        }
        await progress?(size, size)
        let result: CreatedDocument = try await post(path + "/complete-upload", CompleteUpload(size: size, sha256: digest))
        defaults.removeObject(forKey: key)
        return result.document
    }

    private func createUpload(_ file: URL, project: Project, folderID: String?, key: String) async throws -> String {
        let created: CreatedDocument = try await post("projects/\(project.id)/documents",
            DocumentRequest(name: file.lastPathComponent, folderId: folderID))
        UserDefaults.standard.set(created.document.id, forKey: key)
        return created.document.id
    }

    private func sendUploadPart(_ bytes: Data, path: String, index: Int) async throws {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let receipt: UploadPart = try await uploadPart(bytes, to: path + "/upload-parts/\(index)")
                guard receipt.index == index else { throw SharedReviewError("The server confirmed the wrong upload part.") }
                return
            } catch let error as URLError where error.code != .cancelled && attempt < 2 {
                try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            } catch let error as SharedReviewError where (500..<600).contains(error.statusCode ?? 0) && attempt < 2 {
                try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
    }

    private func uploadPart<Value: Decodable>(_ bytes: Data, to path: String) async throws -> Value {
        let boundary = UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"review.pdf\"\r\nContent-Type: application/pdf\r\n\r\n".utf8)
        body.append(bytes)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = request(path)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await Self.session.upload(for: request, from: body)
        try validate(response)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func socket() -> URLSessionWebSocketTask {
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.scheme = origin.scheme == "https" ? "wss" : "ws"
        parts.path = "/ws"
        parts.queryItems = [URLQueryItem(name: "token", value: token)]
        return Self.session.webSocketTask(with: parts.url!)
    }
}
