import Foundation
import SwiftUI
import CoreText

enum Res {
    static var dir: URL { Bundle.main.resourceURL!.appendingPathComponent("Resources") }
    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    static func registerFont() {
        CTFontManagerRegisterFontsForURL(url("CapriMono-Regular.ttf") as CFURL, .process, nil)
    }
}

enum Theme {
    static let bg = Color(red: 0.04, green: 0.035, blue: 0.06)
    static let panel = Color(red: 0.09, green: 0.08, blue: 0.12)
    static let pink = Color(red: 1.0, green: 0.08, blue: 0.33)
    static let green = Color(red: 0.11, green: 0.94, blue: 0.55)
    static let purple = Color(red: 0.48, green: 0.24, blue: 1.0)
    static let dim = Color.white.opacity(0.55)
    static func font(_ size: CGFloat) -> Font { .custom("Capri Mono", size: size) }
}

struct Language: Identifiable, Hashable {
    let code: String, native: String, english: String, locale: String
    var id: String { code }
}

/// All of Capri's text, read from the app's own strings.json (same file as the Android app).
final class Texts {
    static let shared = Texts()
    private let raw: [String: Any]
    let languages: [Language]

    private init() {
        let data = (try? Data(contentsOf: Res.url("strings.json"))) ?? Data()
        raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        languages = (raw["LANGUAGES"] as? [[String]] ?? []).compactMap {
            $0.count >= 4 ? Language(code: $0[0], native: $0[1], english: $0[2], locale: $0[3]) : nil
        }
    }

    func any(_ key: String) -> Any? { raw[key] }
    func string(_ key: String) -> String { raw[key] as? String ?? "" }

    private func row(_ keysKey: String, _ rowsKey: String, _ key: String, _ lang: String) -> String {
        guard let keys = raw[keysKey] as? [String], let i = keys.firstIndex(of: key),
              let rows = raw[rowsKey] as? [String: [String]] else { return key }
        if let r = rows[lang], i < r.count { return r[i] }
        if let r = rows["en"], i < r.count { return r[i] }
        return key
    }

    /// Main screen strings (placeholder, new_chat, chats, settings, ...)
    func s(_ key: String, _ lang: String) -> String { row("STRING_KEYS", "STRINGS", key, lang) }
    /// Model / misc UI strings (models, search, install, thinking, ...)
    func ui(_ key: String, _ lang: String) -> String { row("UI_KEYS", "UI_ROWS", key, lang) }
    /// Web search strings
    func web(_ key: String, _ lang: String) -> String { row("WEB_KEYS", "WEB_ROWS", key, lang) }

    func greeting(_ lang: String) -> String {
        let g = raw["GREETINGS"] as? [String: String] ?? [:]
        return g[lang] ?? g["en"] ?? "Hey, choom."
    }

    func look(_ i: Int, _ lang: String) -> String {
        let l = raw["LOOK_TEXT"] as? [String: [String]] ?? [:]
        let r = l[lang] ?? l["en"] ?? []
        return i < r.count ? r[i] : ""
    }

    var core: String { string("CAPRI_CORE") }
    func modeNote(_ mode: String) -> String { (raw["MODE_NOTES"] as? [String: String])?[mode] ?? "" }
    var emptyReply: String { string("EMPTY_REPLY") }
    var liveLines: [String] { raw["LIVE_LINES"] as? [String] ?? [] }
    var shots: [(String, String)] {
        (raw["BRAIN_SHOTS"] as? [[String]] ?? []).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }
    func langName(_ code: String) -> String { (raw["LANG_NAMES"] as? [String: String])?[code] ?? "English" }
    func list(_ key: String) -> [String] { raw[key] as? [String] ?? [] }
    func dict(_ key: String) -> [String: String] { raw[key] as? [String: String] ?? [:] }

    private var cache: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    /// Compiles one of the app's regex patterns. `<KEY>_F` holds the Java flags (2 = ignore case, 32 = dot-all, 8 = multiline).
    func regex(_ key: String) -> NSRegularExpression? {
        lock.lock(); defer { lock.unlock() }
        if let r = cache[key] { return r }
        guard let p = raw[key] as? String else { return nil }
        let f = (raw[key + "_F"] as? Int) ?? 2
        var o: NSRegularExpression.Options = []
        if f & 2 != 0 { o.insert(.caseInsensitive) }
        if f & 32 != 0 { o.insert(.dotMatchesLineSeparators) }
        if f & 8 != 0 { o.insert(.anchorsMatchLines) }
        let r = try? NSRegularExpression(pattern: p, options: o)
        cache[key] = r
        return r
    }

    func matches(_ key: String, _ text: String) -> Bool {
        guard let r = regex(key) else { return false }
        return r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    func replace(_ key: String, in text: String, with: String) -> String {
        guard let r = regex(key) else { return text }
        return r.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: with)
    }
}
