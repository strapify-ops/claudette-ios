import SwiftUI
import UserNotifications

// A message sent from the phone that the transcript hasn't shown yet.
struct Outgoing: Identifiable, Hashable {
    let id = UUID()
    var text: String
    var sentText: String?
    var state: State
    var progress: Double = 0
    var error: String?
    var at = Date()

    enum State: Hashable { case uploading, sending, sent, failed }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var configured = API.shared.isConfigured
    @Published var sessions: [Session] = []
    @Published var listError: String?
    @Published var path: [String] = []
    @Published var outgoing: [String: [Outgoing]] = [:]
    @Published var pushNote: String?
    @Published var lastLoad: Date?

    private var poll: Task<Void, Never>?

    func session(_ id: String) -> Session? { sessions.first { $0.id == id } }

    func open(_ id: String) {
        if path.last != id { path = [id] }
    }

    func foreground() {
        guard configured else { return }
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.loadList()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        askForPush()
    }

    func background() { poll?.cancel() }

    func loadList() async {
        do {
            sessions = try await API.shared.sessions()
            listError = nil
            lastLoad = Date()
        } catch APIError.signedOut {
            listError = APIError.signedOut.localizedDescription
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            listError = "Can't reach your PC: \(error.localizedDescription)"
        }
    }

    func signIn(server: String, token: String) {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        Keychain.set("server", s)
        Keychain.set("token", token.trimmingCharacters(in: .whitespacesAndNewlines))
        configured = API.shared.isConfigured
        foreground()
    }

    func signOut() {
        Keychain.set("token", nil)
        poll?.cancel()
        sessions = []
        path = []
        configured = false
    }

    // MARK: push

    private func askForPush() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            guard ok else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func sendPushToken(_ hex: String) async {
        do {
            try await API.shared.registerPush(hex)
            pushNote = nil
        } catch {
            pushNote = "Push not set up on your PC: \(error.localizedDescription)"
        }
    }

    // MARK: sending

    func send(to id: String, text: String, files: [Attachment]) {
        let item = Outgoing(text: text, state: files.isEmpty ? .sending : .uploading)
        outgoing[id, default: []].append(item)
        let itemID = item.id
        // Keep running for a while if the app is put away mid-upload.
        let bg = UIApplication.shared.beginBackgroundTask(withName: "send") {}
        Task {
            defer { UIApplication.shared.endBackgroundTask(bg) }
            do {
                let paths = try await uploadAll(files) { frac in self.update(id, itemID) { $0.progress = frac } }
                let full = withPaths(text, paths)
                update(id, itemID) { $0.state = .sending; $0.sentText = full }
                try await API.shared.type(id, full)
                update(id, itemID) { $0.state = .sent; $0.at = Date() }
            } catch {
                update(id, itemID) { $0.state = .failed; $0.error = error.localizedDescription }
            }
        }
    }

    func update(_ id: String, _ itemID: UUID, _ f: (inout Outgoing) -> Void) {
        guard var list = outgoing[id], let i = list.firstIndex(where: { $0.id == itemID }) else { return }
        f(&list[i])
        outgoing[id] = list
    }

    func dismiss(_ id: String, _ itemID: UUID) {
        outgoing[id]?.removeAll { $0.id == itemID }
    }

    // Sent messages leave once their text shows in the transcript (or after 10 minutes).
    func reconcile(_ id: String, with messages: [Message]) {
        guard let list = outgoing[id], !list.isEmpty else { return }
        let users = Set(messages.suffix(60).filter { $0.r == "user" }.map { normalise($0.t ?? "") })
        let keep = list.filter { o in
            guard o.state == .sent else { return true }
            if Date().timeIntervalSince(o.at) > 600 { return false }
            return !users.contains(normalise(o.sentText ?? o.text))
        }
        if keep.count != list.count { outgoing[id] = keep }
    }

    func uploadAll(_ files: [Attachment], report: @escaping @MainActor (Double) -> Void) async throws -> [String] {
        guard !files.isEmpty else { return [] }
        let tally = Tally(files.map { Int64(max(1, $0.data.count)) })
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (i, f) in files.enumerated() {
                group.addTask {
                    let p = try await API.shared.upload(f) { s, t in
                        let frac = tally.set(i, s, t)
                        Task { @MainActor in report(frac) }
                    }
                    return (i, p)
                }
            }
            var out = Array(repeating: "", count: files.count)
            for try await (i, p) in group { out[i] = p }
            return out
        }
    }
}

final class Tally: @unchecked Sendable {
    private var sent: [Int64]
    private var total: [Int64]
    private let lock = NSLock()
    init(_ total: [Int64]) { self.total = total; sent = total.map { _ in 0 } }
    func set(_ i: Int, _ s: Int64, _ t: Int64) -> Double {
        lock.lock(); defer { lock.unlock() }
        sent[i] = s
        if t > 0 { total[i] = t }
        return Double(sent.reduce(0, +)) / Double(max(1, total.reduce(0, +)))
    }
}
