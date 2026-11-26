import SwiftUI

// Claude's replies: headings, lists, quotes, code blocks and tables, with inline Markdown
// (bold, italics, code, links) done by AttributedString.
struct MarkdownView: View {
    let text: String

    enum Part: Hashable {
        case para(String), heading(String, Int), bullet(String, String), quote(String), code(String), table([[String]]), rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, p in view(p) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(_ p: Part) -> some View {
        switch p {
        case .para(let s): Text(Self.inline(s))
        case .heading(let s, let level):
            Text(Self.inline(s)).font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
        case .bullet(let mark, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(mark).foregroundStyle(.secondary)
                Text(Self.inline(s))
            }.padding(.leading, 4)
        case .quote(let s):
            Text(Self.inline(s)).foregroundStyle(.secondary).padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.secondary).frame(width: 3) }
        case .code(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s).font(.system(.footnote, design: .monospaced)).padding(10)
            }
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(Self.inline(cell)).font(i == 0 ? .footnote.bold() : .footnote)
                                    .frame(maxWidth: 220, alignment: .leading)
                            }
                        }
                        if i == 0 { Divider() }
                    }
                }.padding(10)
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        case .rule: Divider()
        }
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    static func parse(_ text: String) -> [Part] {
        var out: [Part] = []
        var para: [String] = []
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]
        func flush() { if !para.isEmpty { out.append(.para(para.joined(separator: "\n"))); para = [] } }

        while let raw = lines.first {
            lines = lines.dropFirst()
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flush()
                var code: [String] = []
                while let l = lines.first {
                    lines = lines.dropFirst()
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    code.append(l)
                }
                out.append(.code(code.joined(separator: "\n")))
            } else if line.isEmpty {
                flush()
            } else if line.hasPrefix("|") {
                flush()
                var rows: [[String]] = [cells(line)]
                while let l = lines.first, l.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    lines = lines.dropFirst()
                    let c = cells(l)
                    if c.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
                    rows.append(c)
                }
                out.append(.table(rows))
            } else if let h = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"), line[h] == " " {
                flush()
                out.append(.heading(String(line[h...]).trimmingCharacters(in: .whitespaces), line.distance(from: line.startIndex, to: h)))
            } else if line == "---" || line == "***" {
                flush(); out.append(.rule)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush()
                let indent = raw.prefix { $0 == " " }.count
                out.append(.bullet(indent >= 2 ? "◦" : "•", String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                flush()
                out.append(.bullet(String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...])))
            } else if line.hasPrefix(">") {
                flush()
                out.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                para.append(raw)
            }
        }
        flush()
        return out
    }

    private static func cells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
