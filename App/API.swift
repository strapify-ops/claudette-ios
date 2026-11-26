import Foundation
import Security
import UIKit

// MARK: - Models (shapes come from claude-phone server.js)

struct Session: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var project: String?
    var archived: Bool
    var created: Double?
    var activity: Double?
    var model: String?
    var effort: String?
    var parent: String?
    var kind: String?
    var summary: String?
    var needsAction: String?
    var working: Bool?
    var pending: String?
    var pendingError: String?

    var isWorking: Bool { working ?? false }
    var lastActive: Date? { activity.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

struct Message: Codable, Hashable {
    let r: String          // user | asst | tool | err | shot
    var t: String?
    var imgs: [String]?
    var ts: String?
    var name: String?
    var short: String?
    var detail: String?
}

struct QueueItem: Codable, Hashable {
    var text: String?
    var ts: String?
}

struct Detail: Codable {
    var session: Session
    var total: Int
    var messages: [Message]
    var queue: [QueueItem]?
}

struct OkReply: Codable {
    var ok: Bool?
    var error: String?
    var id: String?
    var path: String?
    var queued: Bool?
}

struct Suggestion: Codable { var text: String? }

// One row of the desktop's model menu (server /api/models, read from its model catalog).
struct CatalogModel: Codable, Hashable, Identifiable {
    var id: String?
    var name: String
    var section: String?
    var notice: String?
    var efforts: [Effort]
    var defaultEffort: String?
    var fast: Bool?
    var key: String { id ?? name }
    var isMain: Bool { (section ?? "main") == "main" }

    struct Effort: Codable, Hashable { var id: String; var name: String; var badge: String? }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "au.com.strapify.claudette"

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard let value else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Client

enum APIError: LocalizedError {
    case server(String), signedOut
    var errorDescription: String? {
        switch self {
        case .server(let s): return s
        case .signedOut: return "The token was refused. Sign in again."
        }
    }
}

final class API {
    static let shared = API()

    var baseURL: URL? { Keychain.get("server").flatMap { URL(string: $0) } }
    var token: String? { Keychain.get("token") }
    var isConfigured: Bool { baseURL != nil && !(token ?? "").isEmpty }

    let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 60 * 30
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    func request(_ path: String, method: String = "GET") throws -> URLRequest {
        guard let base = baseURL, let token else { throw APIError.signedOut }
        guard let url = URL(string: path, relativeTo: base) else { throw APIError.server("Bad path") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        // The server reads the token from the cp_token cookie (or ?t=, which redirects).
        r.setValue("cp_token=\(token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token)", forHTTPHeaderField: "Cookie")
        return r
    }

    private func check(_ data: Data, _ resp: URLResponse) throws {
        guard let h = resp as? HTTPURLResponse else { return }
        if h.statusCode == 401 { throw APIError.signedOut }
        if h.statusCode >= 400 {
            let e = (try? JSONDecoder().decode(OkReply.self, from: data))?.error
            throw APIError.server(e ?? "Server said \(h.statusCode)")
        }
    }

    func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        let (d, r) = try await session.data(for: try request(path))
        try check(d, r)
        return try JSONDecoder().decode(T.self, from: d)
    }

    func post(_ path: String, json: [String: Any] = [:], timeout: TimeInterval = 60) async throws -> OkReply {
        var req = try request(path, method: "POST")
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (d, r) = try await session.data(for: req)
        let reply = (try? JSONDecoder().decode(OkReply.self, from: d)) ?? OkReply()
        if (r as? HTTPURLResponse)?.statusCode == 401 { throw APIError.signedOut }
        if reply.ok != true { throw APIError.server(reply.error ?? "Server said \((r as? HTTPURLResponse)?.statusCode ?? 0)") }
        return reply
    }

    func sessions() async throws -> [Session] { try await get("/api/sessions", as: [Session].self) }
    func detail(_ id: String) async throws -> Detail { try await get("/api/sessions/\(id)?limit=300", as: Detail.self) }
    func suggest(_ id: String) async throws -> String { try await get("/api/sessions/\(id)/suggest", as: Suggestion.self).text ?? "" }
    // Long timeout: a reply to an archived session waits on the PC while it is restored.
    func type(_ id: String, _ text: String) async throws { _ = try await post("/api/sessions/\(id)/type", json: ["text": text], timeout: 200) }
    func models() async throws -> [CatalogModel] { try await get("/api/models", as: [CatalogModel].self) }
    func archive(_ id: String, _ action: String) async throws { _ = try await post("/api/sessions/\(id)/\(action)") }
    func newSession(text: String, model: String, effort: String, fast: Bool) async throws -> String? {
        try await post("/api/new", json: ["text": text, "model": model, "effort": effort, "fast": fast], timeout: 120).id
    }
    func registerPush(_ token: String) async throws {
        _ = try await post("/api/push/apns", json: ["token": token])
    }

    func imageData(session id: String, key: String) async throws -> Data {
        let (d, r) = try await session.data(for: try request("/api/sessions/\(id)/img/\(key)"))
        try check(d, r)
        return d
    }

    // Uploads one file and returns the path it landed at on the PC.
    func upload(_ file: Attachment, progress: @escaping (Int64, Int64) -> Void) async throws -> String {
        var req = try request("/api/upload", method: "POST")
        req.setValue(file.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file", forHTTPHeaderField: "X-Filename")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let delegate = ProgressDelegate(progress)
        let (d, r) = try await session.upload(for: req, from: file.data, delegate: delegate)
        try check(d, r)
        guard let path = (try? JSONDecoder().decode(OkReply.self, from: d))?.path else { throw APIError.server("\(file.name): no path back") }
        return path
    }
}

private final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
    let cb: (Int64, Int64) -> Void
    init(_ cb: @escaping (Int64, Int64) -> Void) { self.cb = cb }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        cb(totalBytesSent, totalBytesExpectedToSend)
    }
}

// MARK: - Attachments

struct Attachment: Identifiable {
    let id = UUID()
    var name: String
    var data: Data
    var preview: UIImage?

    // Photos go up as JPEG (Claude can't read HEIC), at most 2400 px on the long side.
    static func photo(_ image: UIImage, name: String = "photo") -> Attachment? {
        let k = min(1, 2400 / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * k).rounded(), height: (image.size.height * k).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let d = img.jpegData(compressionQuality: 0.88) else { return nil }
        let stamp = Int(Date().timeIntervalSince1970) % 100000
        return Attachment(name: "\(name)-\(stamp).jpg", data: d, preview: img)
    }
}

// The message typed into Claude: the text, then the paths the files landed at on the PC.
func withPaths(_ text: String, _ paths: [String]) -> String {
    guard !paths.isEmpty else { return text }
    let lead = text.isEmpty ? "See the attached file\(paths.count > 1 ? "s" : "")." : text
    return "\(lead)\n\nAttached from my phone:\n" + paths.map { "- " + $0 }.joined(separator: "\n")
}

func normalise(_ s: String) -> String {
    s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}
