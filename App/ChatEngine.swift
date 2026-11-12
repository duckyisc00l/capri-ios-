import Foundation
import SwiftUI

@MainActor
final class ChatEngine: ObservableObject {
    @Published var busy = false
    @Published var status: String?
    @Published var streamingID: UUID?
    @Published var thinkingSince: Date?

    let store: ChatStore
    let settings: Settings
    let models: ModelManager
    let voice: Voice
    private var job: Task<Void, Never>?

    init(store: ChatStore, settings: Settings, models: ModelManager, voice: Voice) {
        self.store = store
        self.settings = settings
        self.models = models
        self.voice = voice
    }

    /// The model Capri will use right now, if there is one.
    var localModel: LocalModel? {
        models.installed.first { $0.file == settings.activeModel } ?? models.installed.first
    }

    var ready: Bool {
        settings.brain == "cloud" ? (!settings.apiKey.isEmpty && !settings.cloudModel.isEmpty) : localModel != nil
    }

    func stop() {
        job?.cancel()
        LlamaRunner.shared.cancel()
        voice.stopSpeaking()
    }

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        let chatID = store.ensureCurrent()
        let reply = Msg(role: "assistant", text: "")
        store.update(chatID) {
            $0.messages.append(Msg(role: "user", text: text))
            $0.messages.append(reply)
            if $0.title.isEmpty { $0.title = Self.title(from: text) }
        }
        store.touch(chatID)
        busy = true
        streamingID = reply.id
        job = Task { await self.respond(chatID: chatID, replyID: reply.id, text: text) }
    }

    func regenerate() {
        guard !busy, let chat = store.current, let lastUser = chat.messages.last(where: { $0.role == "user" }) else { return }
        store.update(chat.id) { c in
            while let last = c.messages.last, last.role == "assistant" { c.messages.removeLast() }
            if c.messages.last?.role == "user" { c.messages.removeLast() }
        }
        send(lastUser.text)
    }

    static func title(from text: String) -> String {
        let one = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return one.count > 40 ? String(one.prefix(40)).trimmingCharacters(in: .whitespaces) + "…" : one
    }

    private func mode(for text: String) -> String {
        let t = Texts.shared
        if t.matches("CODE_TALK", text) || t.matches("HARD_TALK", text) { return "guru" }
        if text.count < 60 { return "tiny" }
        return "base"
    }

    private func buildTurns(chatID: UUID, text: String, webNotes: String) -> [ChatTurn] {
        let t = Texts.shared
        var system = t.core
        let lang = settings.lang
        if lang != "en" {
            system += "\n\nThe app language is \(t.langName(lang)); if unsure which language to use, use that one."
        }
        system += t.modeNote(mode(for: text))
        system += webNotes
        var turns = [ChatTurn(role: "system", content: system)]
        for (u, a) in t.shots {
            turns.append(ChatTurn(role: "user", content: u))
            turns.append(ChatTurn(role: "assistant", content: a))
        }
        let history = (store.chats.first { $0.id == chatID }?.messages ?? [])
            .filter { !$0.text.isEmpty && $0.failed != true }
        var budget = settings.brain == "cloud" ? 24_000 : 7_000
        var kept: [ChatTurn] = []
        for m in history.reversed() {
            let c = Self.stripThink(m.text)
            if budget - c.count < 0 && !kept.isEmpty { break }
            budget -= c.count
            kept.insert(ChatTurn(role: m.role, content: c), at: 0)
            if kept.count >= 30 { break }
        }
        return turns + kept
    }

    static func stripThink(_ s: String) -> String {
        s.replacingOccurrences(of: "<think>.*?(</think>|$)", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits "<think>…</think>answer" into thought and answer.
    static func split(_ s: String) -> (thought: String?, answer: String, thinking: Bool) {
        guard let open = s.range(of: "<think>") else { return (nil, s, false) }
        let after = s[open.upperBound...]
        if let close = after.range(of: "</think>") {
            let thought = String(after[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = String(s[..<open.lowerBound]) + String(after[close.upperBound...])
            return (thought, answer.trimmingCharacters(in: .whitespacesAndNewlines), false)
        }
        return (String(after), String(s[..<open.lowerBound]), true)
    }

    private func polish(_ s: String) -> String {
        var t = Texts.shared.replace("EMOJI", in: s, with: "")
        t = Texts.shared.replace("TAG_FIX", in: t, with: "")
        return t
    }

    private func respond(chatID: UUID, replyID: UUID, text: String) async {
        defer {
            busy = false
            status = nil
            streamingID = nil
            thinkingSince = nil
            store.save()
        }
        var notes = ""
        var sources: [Source] = []
        if settings.webSearch && WebSearch.shouldSearch(text) {
            let found = await WebSearch.gather(text, lang: settings.lang, status: { [weak self] in self?.status = $0 })
            if let found {
                notes = found.0
                sources = found.1
            }
            status = nil
        }
        if Task.isCancelled { return }

        let turns = buildTurns(chatID: chatID, text: text, webNotes: notes)
        let stream: AsyncThrowingStream<String, Error>
        if settings.brain == "cloud" {
            let p = Provider.byID(settings.provider)
            stream = CloudBrain.generate(base: p.base, key: settings.apiKey, model: settings.cloudModel, turns: turns)
        } else if let m = localModel {
            stream = LlamaRunner.shared.generate(path: m.path.path, turns: turns)
        } else {
            setReply(chatID, replyID) { $0.text = BrainError.noModel.localizedDescription; $0.failed = true }
            return
        }

        var full = ""
        var lastPush = Date.distantPast
        var thinkStart: Date?
        var thinkSecs: Int?
        do {
            for try await piece in stream {
                if Task.isCancelled { break }
                full += piece
                let parts = Self.split(full)
                if parts.thinking, thinkStart == nil { thinkStart = Date(); thinkingSince = thinkStart }
                if !parts.thinking, let st = thinkStart, thinkSecs == nil {
                    thinkSecs = max(1, Int(Date().timeIntervalSince(st)))
                    thinkingSince = nil
                }
                if Date().timeIntervalSince(lastPush) > 0.06 {
                    lastPush = Date()
                    let answer = polish(parts.answer)
                    let secs = thinkSecs
                    setReply(chatID, replyID, save: false) {
                        $0.text = answer
                        $0.thought = parts.thought
                        $0.thinkSecs = secs
                    }
                }
            }
        } catch {
            if full.isEmpty {
                setReply(chatID, replyID) { $0.text = error.localizedDescription; $0.failed = true }
                return
            }
        }
        let parts = Self.split(full)
        var answer = polish(parts.answer).trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty && !Task.isCancelled { answer = Texts.shared.emptyReply }
        let secs = thinkSecs
        let src = sources
        setReply(chatID, replyID) {
            $0.text = answer
            $0.thought = parts.thought
            $0.thinkSecs = secs
            $0.sources = src.isEmpty ? nil : src
        }
        if settings.voice && !Task.isCancelled {
            voice.speak(answer, locale: settings.language.locale)
        }
    }

    private func setReply(_ chatID: UUID, _ replyID: UUID, save: Bool = true, _ change: (inout Msg) -> Void) {
        store.update(chatID) { c in
            if let i = c.messages.firstIndex(where: { $0.id == replyID }) { change(&c.messages[i]) }
        }
        if save { store.save() }
    }
}
