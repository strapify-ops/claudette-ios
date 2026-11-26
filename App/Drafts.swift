import Foundation
import UIKit

// Drafts, strictly one per session (key = session id, "new" for the New session sheet), kept on
// disk so nothing is lost when switching sessions, opening a notification, backgrounding or a
// relaunch. Layout: Application Support/drafts/<key>/draft.json + one file per attachment.
// Messages being sent are kept the same way under inflight/<item id> until the PC confirms them.
enum Drafts {
    struct Manifest: Codable {
        var text: String
        var files: [Item]
        var session: String?
        var item: String?
        struct Item: Codable { var name: String; var file: String }
    }

    private static let root: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    private static func dir(_ key: String) -> URL {
        root.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    static func load(_ key: String) -> (String, [Attachment]) {
        let d = dir(key)
        guard let data = try? Data(contentsOf: d.appendingPathComponent("draft.json")),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return ("", []) }
        let files = m.files.compactMap { it -> Attachment? in
            guard let bytes = try? Data(contentsOf: d.appendingPathComponent(it.file)) else { return nil }
            return Attachment(name: it.name, data: bytes, preview: UIImage(data: bytes))
        }
        return (m.text, files)
    }

    static func save(_ key: String, text: String, files: [Attachment], session: String? = nil, item: String? = nil) {
        let d = dir(key)
        if text.isEmpty && files.isEmpty && item == nil { clear(key); return }
        try? FileManager.default.removeItem(at: d)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var items: [Manifest.Item] = []
        for (i, f) in files.enumerated() {
            let name = "f\(i)"
            if (try? f.data.write(to: d.appendingPathComponent(name), options: .atomic)) != nil {
                items.append(.init(name: f.name, file: name))
            }
        }
        let m = Manifest(text: text, files: items, session: session, item: item)
        if let data = try? JSONEncoder().encode(m) { try? data.write(to: d.appendingPathComponent("draft.json"), options: .atomic) }
    }

    static func clear(_ key: String) { try? FileManager.default.removeItem(at: dir(key)) }

    // MARK: messages on their way to the PC

    static func saveInflight(_ itemID: UUID, session: String, text: String, files: [Attachment]) {
        save("inflight/" + itemID.uuidString, text: text, files: files, session: session, item: itemID.uuidString)
    }
    static func clearInflight(_ itemID: UUID) { clear("inflight/" + itemID.uuidString) }

    // Sends the app never heard back about (killed mid-send): (session, text, files).
    static func leftoverInflight() -> [(String, String, [Attachment], String)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { $0.hasPrefix("inflight_") }.compactMap { n in
            guard let data = try? Data(contentsOf: root.appendingPathComponent(n).appendingPathComponent("draft.json")),
                  let m = try? JSONDecoder().decode(Manifest.self, from: data), let s = m.session else { return nil }
            let (text, files) = load(n.replacingOccurrences(of: "inflight_", with: "inflight/"))
            return (s, text, files, n)
        }
    }
    static func clearRaw(_ dirName: String) { try? FileManager.default.removeItem(at: root.appendingPathComponent(dirName)) }
}
