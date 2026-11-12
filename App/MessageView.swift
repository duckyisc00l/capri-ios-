import SwiftUI
import UIKit

/// One piece of a reply: plain text or a fenced code block.
enum Block: Hashable {
    case text(String)
    case code(lang: String, body: String)

    static func parse(_ s: String) -> [Block] {
        var out: [Block] = []
        var rest = Substring(s)
        while let open = rest.range(of: "```") {
            let before = String(rest[..<open.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(before)) }
            var after = rest[open.upperBound...]
            let langEnd = after.firstIndex(of: "\n") ?? after.endIndex
            let lang = after[..<langEnd].trimmingCharacters(in: .whitespaces)
            after = langEnd < after.endIndex ? after[after.index(after: langEnd)...] : after[after.endIndex...]
            if let close = after.range(of: "```") {
                out.append(.code(lang: lang, body: String(after[..<close.lowerBound]).trimmingCharacters(in: .newlines)))
                rest = after[close.upperBound...]
            } else {
                out.append(.code(lang: lang, body: String(after)))
                rest = ""
            }
        }
        if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(String(rest))) }
        return out
    }
}

struct RichText: View {
    let text: String
    var body: some View {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                row(l)
            }
        }
    }

    @ViewBuilder
    private func row(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 4)
        } else if trimmed.hasPrefix("#") {
            let t = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            inline(t).font(Theme.font(16)).foregroundColor(Theme.pink)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundColor(Theme.green)
                inline(String(trimmed.dropFirst(2)))
            }
        } else {
            inline(raw)
        }
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }
}

struct CodeBlockView: View {
    let lang: String
    let code: String
    let s: Settings
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "code" : lang).font(Theme.font(11)).foregroundColor(Theme.green)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? s.ui("copied") : s.ui("copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Theme.font(11)).foregroundColor(Theme.dim)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.06))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08)))
    }
}

struct ThoughtView: View {
    let thought: String
    let secs: Int?
    let live: Bool
    let s: Settings
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").foregroundColor(Theme.purple)
                    Text(live ? s.ui("thinking") : String(format: s.ui("thought"), secs ?? 1))
                        .font(Theme.font(12)).foregroundColor(Theme.dim)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundColor(Theme.dim)
                }
            }
            if open {
                Text(thought).font(Theme.font(12)).foregroundColor(Theme.dim)
                    .padding(.leading, 10)
                    .overlay(Rectangle().fill(Theme.purple.opacity(0.5)).frame(width: 2), alignment: .leading)
            }
        }
    }
}

struct MessageView: View {
    let msg: Msg
    let streaming: Bool
    let thinkingLive: Bool
    let s: Settings
    var onRetry: (() -> Void)?
    @State private var showSources = false

    var body: some View {
        if msg.role == "user" {
            HStack {
                Spacer(minLength: 50)
                Text(msg.text)
                    .font(Theme.font(15))
                    .foregroundColor(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Theme.pink.opacity(0.22)))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.pink.opacity(0.45), lineWidth: 1))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let t = msg.thought, !t.isEmpty || thinkingLive {
                    ThoughtView(thought: t, secs: msg.thinkSecs, live: thinkingLive, s: s)
                }
                if msg.text.isEmpty && streaming && !thinkingLive {
                    TypingDots()
                }
                ForEach(Array(Block.parse(msg.text).enumerated()), id: \.offset) { _, b in
                    switch b {
                    case .text(let t):
                        RichText(text: t)
                            .font(Theme.font(15))
                            .foregroundColor(msg.failed == true ? Theme.pink : .white)
                            .textSelection(.enabled)
                    case .code(let lang, let code):
                        CodeBlockView(lang: lang, code: code, s: s)
                    }
                }
                if let src = msg.sources, !src.isEmpty, !streaming {
                    Button { withAnimation { showSources.toggle() } } label: {
                        Label(String(format: s.web("sources"), src.count), systemImage: "globe")
                            .font(Theme.font(12)).foregroundColor(Theme.green)
                    }
                    if showSources {
                        ForEach(src, id: \.self) { so in
                            if let u = URL(string: so.url) {
                                Link(destination: u) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(so.title).font(Theme.font(12)).foregroundColor(.white).lineLimit(1)
                                        Text(u.host ?? so.url).font(Theme.font(10)).foregroundColor(Theme.dim).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
                if msg.failed == true, let onRetry {
                    Button(action: onRetry) {
                        Image(systemName: "arrow.clockwise").foregroundColor(Theme.dim)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button { UIPasteboard.general.string = msg.text } label: { Label(s.ui("copy"), systemImage: "doc.on.doc") }
                if let onRetry { Button(action: onRetry) { Label("Retry", systemImage: "arrow.clockwise") } }
            }
        }
    }
}

struct TypingDots: View {
    @State private var phase = 0
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().fill(i == phase ? Theme.green : Theme.green.opacity(0.3)).frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 6)
        .onReceive(Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()) { _ in phase = (phase + 1) % 3 }
    }
}
