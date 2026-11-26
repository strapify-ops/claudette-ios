import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// One block in the transcript: a reply, a user message, or a folded run of tool steps.
enum Block: Identifiable {
    case user(Int, Message)
    case asst(Int, Message)
    case steps(Int, [Message], live: Bool)

    var date: Date? {
        switch self {
        case .user(_, let m), .asst(_, let m): return MsgTime.parse(m.ts)
        case .steps(_, let run, _): return MsgTime.parse(run.first?.ts)
        }
    }

    var id: Int {
        switch self { case .user(let i, _), .asst(let i, _), .steps(let i, _, _): return i }
    }
}

func blocks(_ msgs: [Message], working: Bool) -> [Block] {
    var out: [Block] = []
    var i = 0
    while i < msgs.count {
        let m = msgs[i]
        if m.r == "user" { out.append(.user(i, m)); i += 1; continue }
        if m.r == "asst" { out.append(.asst(i, m)); i += 1; continue }
        let start = i
        var run: [Message] = []
        while i < msgs.count, msgs[i].r != "user", msgs[i].r != "asst" { run.append(msgs[i]); i += 1 }
        out.append(.steps(start, run, live: working && i == msgs.count))
    }
    return out
}

struct SessionView: View {
    let id: String
    @EnvironmentObject var store: Store
    @State private var detail: Detail?
    @State private var error: String?
    @State private var text = ""
    @State private var files: [Attachment] = []
    @State private var suggestion = ""
    @State private var suggestKey = ""
    @State private var lastSig = ""
    @FocusState private var focused: Bool

    private var session: Session? { detail?.session ?? store.session(id) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let d = detail {
                        if d.total > d.messages.count {
                            Text("Showing the last \(d.messages.count) of \(d.total)").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                        let bs = blocks(d.messages, working: d.session.isWorking)
                        ForEach(Array(bs.enumerated()), id: \.element.id) { n, b in
                            if let day = MsgTime.dayChange(b.date, n > 0 ? bs[n - 1].date : nil) {
                                Text(day).font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity).padding(.vertical, 4)
                            }
                            BlockView(block: b, sessionID: id)
                        }
                        ForEach(store.outgoing[id] ?? []) { o in OutgoingView(o: o, sessionID: id) }
                        if let q = d.queue, !q.isEmpty {
                            Label("\(q.count) message\(q.count == 1 ? "" : "s") waiting in the desktop's queue for Claude", systemImage: "hourglass")
                                .font(.footnote).foregroundStyle(.yellow)
                        }
                        if let p = d.session.pending {
                            PendingNote(action: p, error: d.session.pendingError)
                        }
                        if d.session.isWorking {
                            HStack(spacing: 8) { ProgressView(); Text("Claude is working…").foregroundStyle(.secondary) }.font(.footnote)
                        } else if let n = d.session.needsAction, !n.isEmpty {
                            Text("Needs you: \(n)").font(.footnote).foregroundStyle(.yellow)
                        }
                    } else if let error {
                        Text(error).foregroundStyle(.orange)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(40)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .background(Theme.bg)
            .safeAreaInset(edge: .bottom) {
                Composer(text: $text, files: $files, suggestion: suggestion) {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty || !files.isEmpty else { return }
                    store.send(to: id, text: t, files: files)
                    text = ""
                    files = []
                    suggestion = ""
                    withAnimation { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            .onChange(of: lastSig) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .navigationTitle(session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let s = session {
                        Text([s.model, s.effort].compactMap { $0 }.joined(separator: " · "))
                        if let p = s.pending, s.pendingError != nil {
                            Button("Try \(p == "archive" ? "archiving" : "restoring") again") { Task { try? await API.shared.archive(id, "cancel"); act(p) } }
                            Button("Dismiss the error") { act("cancel") }
                        } else if let p = s.pending {
                            Button("Cancel \(p == "archive" ? "archiving" : "restoring")") { act("cancel") }
                        } else {
                            Button(s.archived ? "Restore" : "Archive") { act(s.archived ? "unarchive" : "archive") }
                        }
                        let cur = store.catalog.first { $0.id == s.model || (s.model ?? "").hasPrefix($0.id ?? "~") }
                        Section("Model") {
                            ForEach(store.catalog.filter(\.isMain)) { m in modelButton(m, cur) }
                            Menu("More models") {
                                ForEach(store.catalog.filter { !$0.isMain }) { m in modelButton(m, cur) }
                            }
                        }
                        if let efforts = cur?.efforts, !efforts.isEmpty {
                            Section("Effort") {
                                ForEach(efforts, id: \.id) { e in
                                    Button { store.send(to: id, text: "/effort \(e.id)", files: []) } label: {
                                        if s.effort == e.id { Label(e.name, systemImage: "checkmark") } else { Text(e.badge.map { "\(e.name)  (\($0))" } ?? e.name) }
                                    }
                                }
                            }
                        }
                        if cur?.fast == true {
                            Button { store.send(to: id, text: "/fast", files: []) } label: { Label("Fast mode (toggle)", systemImage: "hare") }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task(id: id) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    @ViewBuilder private func modelButton(_ m: CatalogModel, _ cur: CatalogModel?) -> some View {
        Button { if let mid = m.id { store.send(to: id, text: "/model \(mid)", files: []) } } label: {
            if m.key == cur?.key { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
        }
    }

    private func act(_ action: String) {
        Task { try? await API.shared.archive(id, action); await store.loadList(); await load() }
    }

    private func load() async {
        do {
            let d = try await API.shared.detail(id)
            detail = d
            error = nil
            store.reconcile(id, with: d.messages)
            let sig = "\(d.total)|\(d.messages.last?.ts ?? "")|\(d.session.isWorking)|\(store.outgoing[id]?.count ?? 0)"
            if sig != lastSig { lastSig = sig }
            await loadSuggestion(d)
        } catch {
            if (error as? URLError)?.code == .cancelled || error is CancellationError { return }
            self.error = error.localizedDescription
        }
    }

    private func loadSuggestion(_ d: Detail) async {
        guard !d.session.isWorking, d.messages.last(where: { $0.r == "user" || $0.r == "asst" })?.r == "asst" else {
            suggestion = ""; return
        }
        let key = "\(d.total)|\(d.messages.last?.ts ?? "")"
        guard key != suggestKey else { return }
        suggestKey = key
        suggestion = (try? await API.shared.suggest(id)) ?? ""
    }
}

struct BlockView: View {
    let block: Block
    let sessionID: String
    @State private var open = false

    var body: some View {
        switch block {
        case .user(_, let m):
            VStack(alignment: .trailing, spacing: 6) {
                ImageStrip(keys: m.imgs ?? [], sessionID: sessionID)
                if let t = m.t, !t.isEmpty {
                    Text(t).textSelection(.enabled)
                        .padding(10).background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 14))
                }
                TimeLabel(ts: m.ts)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
        case .asst(_, let m):
            VStack(alignment: .leading, spacing: 4) {
                MarkdownView(text: m.t ?? "")
                TimeLabel(ts: m.ts)
            }
        case .steps(_, let run, let live):
            let tools = run.filter { $0.r == "tool" }
            let errs = run.filter { $0.r == "err" }.count
            let shots = run.filter { $0.r == "shot" }.flatMap { $0.imgs ?? [] }
            VStack(alignment: .leading, spacing: 6) {
                if !tools.isEmpty || errs > 0 {
                    DisclosureGroup(isExpanded: $open) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(run.enumerated()), id: \.offset) { _, x in
                                if x.r == "tool" {
                                    (Text(x.short ?? x.name ?? "tool").bold() + Text((x.detail ?? "").isEmpty ? "" : " · \(x.detail!)"))
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if x.r == "err" {
                                    Text(x.t ?? "").font(.caption.monospaced()).foregroundStyle(.red)
                                } else if x.r == "shot" {
                                    // Tool-result images belong to their step, like the desktop: only seen when expanded.
                                    ImageStrip(keys: x.imgs ?? [], sessionID: sessionID)
                                }
                            }
                        }.padding(.top, 4)
                    } label: {
                        HStack(spacing: 4) {
                            Text(live ? "Working · \(tools.last?.short ?? tools.last?.name ?? "")" : "\(tools.count) step\(tools.count == 1 ? "" : "s")")
                            if errs > 0 { Text("· \(errs) error\(errs == 1 ? "" : "s")").foregroundStyle(.red) }
                            if !shots.isEmpty { Image(systemName: "photo").font(.caption2) }
                        }.font(.footnote).foregroundStyle(.secondary)
                    }
                } else if !shots.isEmpty {
                    DisclosureGroup(isExpanded: $open) { ImageStrip(keys: shots, sessionID: sessionID) } label: {
                        Text("\(shots.count) tool image\(shots.count == 1 ? "" : "s")").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct OutgoingView: View {
    let o: Outgoing
    let sessionID: String
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(o.text.isEmpty ? "(attachments)" : o.text)
                .padding(10).background(Theme.userBubble.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            switch o.state {
            case .uploading:
                ProgressView(value: o.progress).frame(width: 160)
                Text("Uploading \(Int(o.progress * 100))%. Keep Claudette open.").font(.caption).foregroundStyle(.orange)
            case .sending:
                Text("Sending…").font(.caption).foregroundStyle(.secondary)
            case .sent:
                Text("Sent. Waiting for it to show in the session.").font(.caption).foregroundStyle(.secondary)
            case .failed:
                HStack {
                    Text("Not sent: \(o.error ?? "")").font(.caption).foregroundStyle(.red)
                    Button("Retry") { store.retry(sessionID, o.id) }.font(.caption.weight(.semibold))
                    Button("Dismiss") { store.dismiss(sessionID, o.id) }.font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
    }
}

// MARK: - Composer

struct Composer: View {
    @Binding var text: String
    @Binding var files: [Attachment]
    let suggestion: String
    let send: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !suggestion.isEmpty && text.isEmpty {
                HStack {
                    Text(suggestion).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Paste") { text = suggestion }.font(.footnote.weight(.semibold))
                }
            }
            AttachmentBar(files: $files)
            HStack(alignment: .bottom, spacing: 8) {
                AttachMenu(files: $files)
                PasteTextView(text: $text, placeholder: suggestion.isEmpty ? "Reply to Claude" : suggestion) { files.append(contentsOf: $0) }
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.bar)
    }
}

struct AttachMenu: View {
    @Binding var files: [Attachment]
    @State private var picks: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false

    var body: some View {
        Menu {
            Button { showPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
            }
            Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
            Button { pasteClipboard() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
        } label: {
            Image(systemName: "plus.circle").font(.system(size: 28)).foregroundStyle(.secondary)
        }
        .photosPicker(isPresented: $showPhotos, selection: $picks, maxSelectionCount: 10, matching: .images)
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d), let a = Attachment.photo(img) {
                        files.append(a)
                    }
                }
                picks = []
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r else { return }
            for u in urls {
                let ok = u.startAccessingSecurityScopedResource()
                defer { if ok { u.stopAccessingSecurityScopedResource() } }
                if let d = try? Data(contentsOf: u) {
                    files.append(Attachment(name: u.lastPathComponent, data: d, preview: nil))
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in if let img, let a = Attachment.photo(img) { files.append(a) } }.ignoresSafeArea()
        }
    }

    private func pasteClipboard() {
        let pb = UIPasteboard.general
        if let imgs = pb.images, !imgs.isEmpty {
            for img in imgs { if let a = Attachment.photo(img, name: "pasted") { files.append(a) } }
        } else if let u = pb.url, u.isFileURL, let d = try? Data(contentsOf: u) {
            files.append(Attachment(name: u.lastPathComponent, data: d, preview: nil))
        }
    }
}

struct AttachmentBar: View {
    @Binding var files: [Attachment]

    var body: some View {
        if !files.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(files) { f in
                        ZStack(alignment: .topTrailing) {
                            Group {
                                if let p = f.preview {
                                    Image(uiImage: p).resizable().scaledToFill()
                                } else {
                                    VStack { Image(systemName: "doc"); Text(f.name).font(.caption2).lineLimit(2) }.padding(4)
                                }
                            }
                            .frame(width: 64, height: 64).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 8))
                            Button { files.removeAll { $0.id == f.id } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                            }.offset(x: 4, y: -4)
                        }
                    }
                }.padding(.top, 4)
            }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(_ done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage); picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil); picker.dismiss(animated: true) }
    }
}

// MARK: - Images from the transcript

final class ImageCache {
    static let shared = NSCache<NSString, UIImage>()
}

struct ImageStrip: View {
    let keys: [String]
    let sessionID: String
    var body: some View {
        if !keys.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(keys, id: \.self) { RemoteImage(sessionID: sessionID, key: $0) }
            }
        }
    }
}

struct RemoteImage: View {
    let sessionID: String
    let key: String
    @State private var image: UIImage?
    @State private var full = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 320, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { full = true }
            } else {
                RoundedRectangle(cornerRadius: 10).fill(Theme.card).frame(width: 160, height: 100)
                    .overlay(ProgressView())
            }
        }
        .task(id: key) {
            let ck = "\(sessionID)/\(key)" as NSString
            if let c = ImageCache.shared.object(forKey: ck) { image = c; return }
            if let d = try? await API.shared.imageData(session: sessionID, key: key), let img = UIImage(data: d) {
                ImageCache.shared.setObject(img, forKey: ck)
                image = img
            }
        }
        .fullScreenCover(isPresented: $full) {
            ZoomImage(image: image) { full = false }
        }
    }
}

struct ZoomImage: View {
    let image: UIImage?
    let close: () -> Void
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: UIScreen.main.bounds.width * scale * pinch)
                }
                .gesture(MagnificationGesture().updating($pinch) { v, s, _ in s = v }.onEnded { scale = max(1, min(6, scale * $0)) })
                .onTapGesture(count: 2) { scale = scale > 1 ? 1 : 2.5 }
            }
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 30)).foregroundStyle(.white, .gray.opacity(0.5))
            }.padding()
        }
    }
}

// Message times, always in Melbourne time, small and muted like the desktop app.
enum MsgTime {
    static let tz = TimeZone(identifier: "Australia/Melbourne") ?? .current
    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let isoPlain = ISO8601DateFormatter()
    static func parse(_ s: String?) -> Date? { guard let s else { return nil }; return iso.date(from: s) ?? isoPlain.date(from: s) }
    private static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c }
    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_AU"); f.timeZone = tz; f.dateFormat = "h:mm a"
        return f.string(from: d).lowercased()
    }
    // Session list: time if today, "Yesterday", weekday within a week, else "26 Nov".
    static func listStamp(_ d: Date) -> String {
        if cal.isDateInToday(d) { return time(d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_AU"); f.timeZone = tz
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 99
        f.dateFormat = days < 7 ? "EEEE" : (cal.component(.year, from: d) == cal.component(.year, from: Date()) ? "d MMM" : "d MMM yyyy")
        return f.string(from: d)
    }

    // "Today", "Yesterday" or "Thu 26 Nov" when this block starts a new day.
    static func dayChange(_ d: Date?, _ prev: Date?) -> String? {
        guard let d else { return nil }
        if let prev, cal.isDate(d, inSameDayAs: prev) { return nil }
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_AU"); f.timeZone = tz
        f.dateFormat = cal.component(.year, from: d) == cal.component(.year, from: Date()) ? "EEE d MMM" : "EEE d MMM yyyy"
        return f.string(from: d)
    }
}

struct TimeLabel: View {
    let ts: String?
    var body: some View {
        if let d = MsgTime.parse(ts) { Text(MsgTime.time(d)).font(.caption2).foregroundStyle(.tertiary) }
    }
}

// "Archiving on your PC…" while the desktop carries it out, or why it failed.
struct PendingNote: View {
    let action: String
    let error: String?
    var body: some View {
        let archive = action == "archive"
        if let error {
            Text((archive ? "Archive failed: " : "Restore failed: ") + error).font(.footnote).foregroundStyle(.red)
        } else {
            Text(archive ? "Archiving on your PC…" : "Restoring on your PC…").font(.footnote).foregroundStyle(.secondary)
        }
    }
}
