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

    func upload(_ file: URL, project: Project, folderID: String? = nil) async throws -> Document {
        let bytes = try Data(contentsOf: file)
        guard bytes.count <= 95_000_000 else {
            throw SharedReviewError("The pilot supports PDFs up to 95 MB through the public URL.")
        }
        let created: CreatedDocument = try await post("projects/\(project.id)/documents", DocumentRequest(name: file.lastPathComponent, folderId: folderID))
        let boundary = UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"review.pdf\"\r\nContent-Type: application/pdf\r\n\r\n".utf8)
        body.append(bytes)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = request("documents/\(created.document.id)/upload")
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await Self.session.upload(for: request, from: body)
        try validate(response)
        return try JSONDecoder().decode(CreatedDocument.self, from: data).document
    }

    func socket() -> URLSessionWebSocketTask {
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.scheme = origin.scheme == "https" ? "wss" : "ws"
        parts.path = "/ws"
        parts.queryItems = [URLQueryItem(name: "token", value: token)]
        return Self.session.webSocketTask(with: parts.url!)
    }
}
