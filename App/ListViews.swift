import SwiftUI

struct SetupView: View {
    @EnvironmentObject var store: Store
    @State private var server = Keychain.get("server") ?? ""
    @State private var token = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://100.x.x.x:8787", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Access token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Your PC") } footer: {
                    Text("The Claude Phone server address over Tailscale, and the token from its config.json. Both are kept in this phone's Keychain.")
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button(checking ? "Checking…" : "Sign in") { Task { await check() } }
                    .disabled(checking || server.isEmpty || token.isEmpty)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Claudette")
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        store.signIn(server: server, token: token)
        do {
            _ = try await API.shared.sessions()
            error = nil
        } catch {
            self.error = error.localizedDescription
            store.signOut()
        }
    }
}

struct SessionListView: View {
    @EnvironmentObject var store: Store
    @State private var tab = 0
    @State private var query = ""
    @State private var showNew = false

    private var rows: [Session] {
        store.sessions
            .filter { tab == 0 ? !$0.archived : $0.archived }
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || ($0.summary ?? "").localizedCaseInsensitiveContains(query) }
            .sorted { ($0.activity ?? 0) > ($1.activity ?? 0) }
    }

    var body: some View {
        List {
            if let e = store.listError {
                Text(e).font(.footnote).foregroundStyle(.orange).listRowBackground(Theme.card)
            }
            if let n = store.pushNote {
                Text(n).font(.footnote).foregroundStyle(.secondary).listRowBackground(Theme.card)
            }
            ForEach(rows) { s in
                NavigationLink(value: s.id) { SessionRow(s: s) }
                    .listRowBackground(Theme.card)
                    .swipeActions {
                        Button(s.archived ? "Restore" : "Archive") {
                            Task { try? await API.shared.archive(s.id, s.archived ? "unarchive" : "archive"); await store.loadList() }
                        }.tint(s.archived ? .blue : .gray)
                    }
            }
            if rows.isEmpty && store.lastLoad != nil {
                Text(query.isEmpty ? "No sessions" : "Nothing matches").foregroundStyle(.secondary).listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .searchable(text: $query, prompt: "Search sessions")
        .refreshable { await store.loadList() }
        .safeAreaInset(edge: .top) {
            Picker("", selection: $tab) { Text("Active").tag(0); Text("Archived").tag(1) }
                .pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 6).background(Theme.bg)
        }
        .overlay(alignment: .bottomTrailing) {
            Button { showNew = true } label: {
                Label("New", systemImage: "plus").font(.headline)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Theme.accent, in: Capsule()).foregroundStyle(.white)
            }
            .padding(20)
        }
        .navigationTitle("Claudette")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Text("Claudette \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    Button("Sign out", role: .destructive) { store.signOut() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showNew) { NewSessionView() }
    }
}

struct SessionRow: View {
    let s: Session

    private var status: (String, Color)? {
        if let p = s.pending { return (s.pendingError.map { "Archive failed: \($0)" } ?? (p == "archive" ? "Archiving…" : "Restoring…"), s.pendingError == nil ? .secondary : .red) }
        if s.isWorking { return ("Working…", Theme.accent) }
        if let n = s.needsAction, !n.isEmpty { return ("Needs you: \(n)", .yellow) }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(s.isWorking ? Theme.accent : (s.needsAction ?? "").isEmpty ? Color.clear : .yellow)
                .frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    if s.kind != nil { Image(systemName: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary) }
                    Text(s.title).font(.body.weight(.medium)).lineLimit(2)
                }
                if let st = status {
                    Text(st.0).font(.footnote).foregroundStyle(st.1).lineLimit(2)
                } else if let sum = s.summary, !sum.isEmpty {
                    Text(sum).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let d = s.lastActive { Text(d, style: .relative) }
                    if let p = s.project, !p.isEmpty { Text("· \(p)") }
                }.font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct NewSessionView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    static let models = ["Opus 5.5", "Fable 5.1", "Sonnet 5.5", "Haiku 5.5"]
    static let efforts = ["Low", "Medium", "High", "Extra", "Max"]
    @AppStorage("newModel") private var model = "Opus 5.5"
    @AppStorage("newEffort") private var effort = "Medium"
    @AppStorage("newDraft") private var text = ""
    @State private var files: [Attachment] = []
    @State private var phase: String?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Model").font(.subheadline.weight(.semibold))
                    Pills(options: Self.models, selection: $model)
                    Text("Effort").font(.subheadline.weight(.semibold))
                    Pills(options: Self.efforts, selection: $effort)
                    TextField("What should Claude do?", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    AttachmentBar(files: $files)
                    if let phase { Text(phase).font(.footnote).foregroundStyle(.secondary) }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { Task { await start() } }
                        .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func start() async {
        busy = true
        error = nil
        let bg = UIApplication.shared.beginBackgroundTask(withName: "new") {}
        defer { busy = false; UIApplication.shared.endBackgroundTask(bg) }
        do {
            var paths: [String] = []
            if !files.isEmpty {
                phase = "Uploading 0%. Keep Claudette open."
                paths = try await store.uploadAll(files) { phase = "Uploading \(Int($0 * 100))%. Keep Claudette open." }
            }
            phase = "Starting on your PC…"
            let id = try await API.shared.newSession(text: withPaths(text.trimmingCharacters(in: .whitespacesAndNewlines), paths), model: model, effort: effort)
            text = ""
            files = []
            await store.loadList()
            dismiss()
            if let id { store.open(id) }
        } catch {
            phase = nil
            self.error = "Not started: \(error.localizedDescription)"
        }
    }
}

struct Pills: View {
    let options: [String]
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(options, id: \.self) { o in
                    Button(o) { selection = o }
                        .font(.subheadline)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(selection == o ? Theme.accent : Theme.card, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
    }
}
