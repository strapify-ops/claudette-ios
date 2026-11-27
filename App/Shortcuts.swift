import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers

// Searching "Claude" on the iPhone finds the app: App Shortcuts with "Claude" in their titles
// show in Spotlight under CodeBypass, and every session is indexed with "Claude" keywords.
// (Leave "Claude" out of any App Store keywords field: trademark.)

struct OpenSessionsIntent: AppIntent {
    static var title: LocalizedStringResource = "Claude sessions"
    static var description = IntentDescription("Open your Claude Code sessions.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        Store.shared.path = []
        return .result()
    }
}

struct NewSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "New Claude session"
    static var description = IntentDescription("Start a new Claude Code session on your PC.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        Store.shared.path = []
        Store.shared.showNew = true
        return .result()
    }
}

struct ReplyIntent: AppIntent {
    static var title: LocalizedStringResource = "Reply to Claude"
    static var description = IntentDescription("Open the Claude session you used last.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        let s = Store.shared
        if let latest = s.sessions.filter({ !$0.archived }).max(by: { ($0.lastMessageAt ?? $0.activity ?? 0) < ($1.lastMessageAt ?? $1.activity ?? 0) }) {
            s.open(latest.id)
        } else {
            s.openLatestWhenLoaded = true
        }
        return .result()
    }
}

struct ClaudeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenSessionsIntent(), phrases: ["Claude sessions in \(.applicationName)", "Open Claude in \(.applicationName)"],
                    shortTitle: "Claude sessions", systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(intent: NewSessionIntent(), phrases: ["New Claude session in \(.applicationName)"],
                    shortTitle: "New Claude session", systemImageName: "plus.bubble")
        AppShortcut(intent: ReplyIntent(), phrases: ["Reply to Claude in \(.applicationName)"],
                    shortTitle: "Reply to Claude", systemImageName: "arrowshape.turn.up.left")
    }
}

enum SpotlightIndex {
    private static var lastSig = ""

    // Re-indexes only when titles or the set of sessions change.
    static func update(_ sessions: [Session]) {
        let sig = sessions.map { "\($0.id)|\($0.title)|\($0.archived)" }.joined(separator: ",")
        guard sig != lastSig else { return }
        lastSig = sig
        let items = sessions.map { s -> CSSearchableItem in
            let a = CSSearchableItemAttributeSet(contentType: .text)
            a.title = s.title
            a.contentDescription = [s.archived ? "Archived Claude session" : "Claude session", s.summary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            a.keywords = ["Claude", "Claude Code", "CodeBypass", s.title] + (s.project.map { [$0] } ?? [])
            return CSSearchableItem(uniqueIdentifier: s.id, domainIdentifier: "sessions", attributeSet: a)
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: ["sessions"]) { _ in
            index.indexSearchableItems(items) { _ in }
        }
    }
}
