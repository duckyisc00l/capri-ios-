import Foundation
import SwiftUI

struct Source: Codable, Hashable {
    var title: String
    var url: String
}

struct Msg: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: String              // "user" or "assistant"
    var text: String
    var thought: String? = nil
    var thinkSecs: Int? = nil
    var sources: [Source]? = nil
    var failed: Bool? = nil
}

struct Chat: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String = ""
    var updated = Date()
    var messages: [Msg] = []
}

enum Paths {
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var models: URL {
        let u = support.appendingPathComponent("models", isDirectory: true)
        if !FileManager.default.fileExists(atPath: u.path) {
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            var v = URLResourceValues(); v.isExcludedFromBackup = true
            var m = u; try? m.setResourceValues(v)
        }
        return u
    }
}

@MainActor
final class ChatStore: ObservableObject {
    @Published var chats: [Chat] = []
    @Published var currentID: UUID?

    private let file = Paths.support.appendingPathComponent("chats.json")

    init() {
        if let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode([Chat].self, from: d) {
            chats = c.sorted { $0.updated > $1.updated }
        }
        currentID = chats.first?.id
    }

    var current: Chat? { chats.first { $0.id == currentID } }

    func save() {
        let snapshot = chats
        let f = file
        DispatchQueue.global(qos: .utility).async {
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: f, options: .atomic) }
        }
    }

    /// Starts a fresh chat (reuses the current one if it's still empty).
    func newChat() {
        if let c = current, c.messages.isEmpty { return }
        chats.removeAll { $0.messages.isEmpty }
        let c = Chat()
        chats.insert(c, at: 0)
        currentID = c.id
    }

    func ensureCurrent() -> UUID {
        if let id = currentID, chats.contains(where: { $0.id == id }) { return id }
        let c = Chat()
        chats.insert(c, at: 0)
        currentID = c.id
        return c.id
    }

    func delete(_ id: UUID) {
        chats.removeAll { $0.id == id }
        if currentID == id { currentID = chats.first?.id }
        save()
    }

    func update(_ id: UUID, _ change: (inout Chat) -> Void) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        change(&chats[i])
    }

    func touch(_ id: UUID) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[i].updated = Date()
        let c = chats.remove(at: i)
        chats.insert(c, at: 0)
        save()
    }
}

struct Provider: Identifiable, Hashable {
    let id: String, name: String, base: String
    static let all: [Provider] = [
        Provider(id: "openrouter", name: "OpenRouter", base: "https://openrouter.ai/api/v1"),
        Provider(id: "openai", name: "OpenAI", base: "https://api.openai.com/v1"),
        Provider(id: "anthropic", name: "Anthropic", base: "https://api.anthropic.com/v1"),
        Provider(id: "gemini", name: "Google Gemini", base: "https://generativelanguage.googleapis.com/v1beta/openai"),
        Provider(id: "groq", name: "Groq", base: "https://api.groq.com/openai/v1"),
        Provider(id: "cerebras", name: "Cerebras", base: "https://api.cerebras.ai/v1"),
        Provider(id: "mistral", name: "Mistral", base: "https://api.mistral.ai/v1"),
        Provider(id: "together", name: "Together", base: "https://api.together.xyz/v1"),
        Provider(id: "deepinfra", name: "DeepInfra", base: "https://api.deepinfra.com/v1/openai"),
        Provider(id: "nvidia", name: "NVIDIA", base: "https://integrate.api.nvidia.com/v1"),
        Provider(id: "huggingface", name: "Hugging Face", base: "https://router.huggingface.co/v1"),
        Provider(id: "xai", name: "xAI", base: "https://api.x.ai/v1"),
        Provider(id: "moonshot", name: "Moonshot", base: "https://api.moonshot.ai/v1"),
        Provider(id: "sambanova", name: "SambaNova", base: "https://api.sambanova.ai/v1"),
        Provider(id: "siliconflow", name: "SiliconFlow", base: "https://api.siliconflow.cn/v1"),
    ]
    static func byID(_ id: String) -> Provider { all.first { $0.id == id } ?? all[0] }
}

@MainActor
final class Settings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var lang: String { didSet { d.set(lang, forKey: "lang") } }
    @Published var voice: Bool { didSet { d.set(voice, forKey: "voice") } }
    /// "local" = model on this phone, "cloud" = provider with your API key
    @Published var brain: String { didSet { d.set(brain, forKey: "brain") } }
    @Published var activeModel: String { didSet { d.set(activeModel, forKey: "activeModel") } }
    @Published var provider: String { didSet { d.set(provider, forKey: "provider") } }
    @Published var cloudModel: String { didSet { d.set(cloudModel, forKey: "cloudModel") } }
    @Published var apiKeys: [String: String] { didSet { d.set(apiKeys, forKey: "apiKeys") } }
    @Published var size: Double { didSet { d.set(size, forKey: "size") } }
    @Published var hue: Double { didSet { d.set(hue, forKey: "hue") } }
    @Published var webSearch: Bool { didSet { d.set(webSearch, forKey: "web") } }

    init() {
        let codes = Texts.shared.languages.map(\.code)
        let sys = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        lang = d.string(forKey: "lang") ?? (codes.contains(sys) ? sys : "en")
        voice = d.object(forKey: "voice") as? Bool ?? false
        brain = d.string(forKey: "brain") ?? "local"
        activeModel = d.string(forKey: "activeModel") ?? ""
        provider = d.string(forKey: "provider") ?? "openrouter"
        cloudModel = d.string(forKey: "cloudModel") ?? ""
        apiKeys = d.dictionary(forKey: "apiKeys") as? [String: String] ?? [:]
        size = d.object(forKey: "size") as? Double ?? 1.0
        hue = d.object(forKey: "hue") as? Double ?? 0
        webSearch = d.object(forKey: "web") as? Bool ?? true
    }

    var apiKey: String {
        get { apiKeys[provider] ?? "" }
        set { apiKeys[provider] = newValue }
    }

    var language: Language {
        Texts.shared.languages.first { $0.code == lang } ?? Language(code: "en", native: "English", english: "English", locale: "en_US")
    }

    func s(_ k: String) -> String { Texts.shared.s(k, lang) }
    func ui(_ k: String) -> String { Texts.shared.ui(k, lang) }
    func web(_ k: String) -> String { Texts.shared.web(k, lang) }
}
