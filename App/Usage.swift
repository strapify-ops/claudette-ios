import SwiftUI

// Plan usage, like the desktop's usage rings: a small ring in the top bar showing the most-used
// limit; tap it for every limit with its reset time (Melbourne).
struct UsageLimit: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var pct: Double
    var resetsAt: String?
}
struct UsageReply: Codable { var limits: [UsageLimit]?; var error: String? }

extension API {
    func usage() async throws -> UsageReply {
        let (d, _) = try await session.data(for: try request("/api/usage"))
        return try JSONDecoder().decode(UsageReply.self, from: d)
    }
}

struct UsageRing: View {
    var pct: Double
    var size: CGFloat = 26
    var line: CGFloat = 3.5
    var color: Color { pct >= 90 ? .red : pct >= 70 ? .orange : Theme.accent }
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: line)
            Circle().trim(from: 0, to: min(1, pct / 100))
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

struct UsageButton: View {
    @State private var reply: UsageReply?
    @State private var show = false

    private var top: UsageLimit? { reply?.limits?.max { $0.pct < $1.pct } }

    var body: some View {
        Button { show = true } label: {
            HStack(spacing: 5) {
                UsageRing(pct: top?.pct ?? 0, size: 20, line: 3)
                if let t = top { Text("\(Int(t.pct.rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
        }
        .accessibilityLabel("Plan usage")
        .task {
            while !Task.isCancelled {
                reply = try? await API.shared.usage()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .sheet(isPresented: $show) {
            UsageSheet(reply: reply) { reply = try? await API.shared.usage() }
                .presentationDetents([.medium])
        }
    }
}

struct UsageSheet: View {
    var reply: UsageReply?
    var refresh: () async -> Void

    var body: some View {
        NavigationStack {
            List {
                if let e = reply?.error { Text(e).foregroundStyle(.orange) }
                ForEach(reply?.limits ?? []) { l in
                    HStack(spacing: 14) {
                        ZStack {
                            UsageRing(pct: l.pct, size: 44, line: 5)
                            Text("\(Int(l.pct.rounded()))%").font(.caption2.bold().monospacedDigit())
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(l.name).font(.body.weight(.medium))
                            if let r = l.resetsAt, let d = MsgTime.parse(r) ?? ISO8601DateFormatter().date(from: String(r.prefix(19)) + "Z") {
                                Text("Resets \(Self.when(d))").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowBackground(Theme.card)
                }
                if reply == nil { ProgressView() }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Plan usage")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await refresh() }
        }
    }

    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU")
        f.timeZone = MsgTime.tz
        f.dateFormat = "EEE h:mm a"
        return f.string(from: d).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
    }
}
