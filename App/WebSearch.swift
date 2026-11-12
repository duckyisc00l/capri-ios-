import Foundation

/// Decides when Capri should look something up, then searches DuckDuckGo and reads a few pages.
enum WebSearch {
    static let agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static func shouldSearch(_ text: String) -> Bool {
        let t = Texts.shared
        if t.matches("WEB_EXPLICIT", text) || t.matches("WEB_SHORT_EXPLICIT", text) { return true }
        if t.matches("WEB_CREATIVE", text) { return false }
        if t.matches("CODE_TALK", text) { return false }
        let fresh = t.matches("WEB_FRESH", text)
        if t.matches("WEB_SELF", text) && !fresh { return false }
        if fresh && (t.matches("WEB_ASK", text) || text.count < 80) { return true }
        if t.matches("WEB_FACT", text) && text.count < 160 { return true }
        return false
    }

    static func query(_ text: String) -> String {
        var q = Texts.shared.replace("WEB_CUT", in: text, with: " ")
        q = q.replacingOccurrences(of: "[?!.,;:«»\"“”]", with: " ", options: .regularExpression)
        q = q.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return q.isEmpty ? text : String(q.prefix(200))
    }

    struct Hit { var title: String; var url: String; var snippet: String }

    static func search(_ q: String, lang: String) async throws -> [Hit] {
        let region = Texts.shared.dict("WEB_REGIONS")[lang] ?? "wt-wt"
        var c = URLComponents(string: "https://html.duckduckgo.com/html/")!
        c.queryItems = [.init(name: "q", value: q), .init(name: "kl", value: region)]
        var req = URLRequest(url: c.url!)
        req.setValue(agent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        let (d, _) = try await URLSession.shared.data(for: req)
        let html = String(decoding: d, as: UTF8.self)
        let skip = Texts.shared.list("WEB_SKIP_HOSTS")

        let linkRe = try NSRegularExpression(pattern: "<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators])
        let snipRe = try NSRegularExpression(pattern: "class=\"result__snippet\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators])
        let ns = html as NSString
        let links = linkRe.matches(in: html, range: NSRange(location: 0, length: ns.length))
        let snips = snipRe.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var hits: [Hit] = []
        for (i, m) in links.enumerated() {
            var href = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            if href.hasPrefix("//") { href = "https:" + href }
            if let comps = URLComponents(string: href), let u = comps.queryItems?.first(where: { $0.name == "uddg" })?.value {
                href = u
            }
            if href.contains("duckduckgo.com/y.js") || skip.contains(where: { href.contains($0) }) { continue }
            let title = clean(ns.substring(with: m.range(at: 2)))
            let snip = i < snips.count ? clean(ns.substring(with: snips[i].range(at: 1))) : ""
            hits.append(Hit(title: title, url: href, snippet: snip))
            if hits.count >= 5 { break }
        }
        return hits
    }

    static func read(_ url: String) async -> String {
        guard let u = URL(string: url) else { return "" }
        var req = URLRequest(url: u)
        req.setValue(agent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 7
        guard let (d, r) = try? await URLSession.shared.data(for: req),
              (r as? HTTPURLResponse)?.statusCode == 200,
              d.count < 4_000_000 else { return "" }
        var html = String(decoding: d, as: UTF8.self)
        for tag in ["script", "style", "noscript", "svg", "header", "footer", "nav", "form"] {
            html = html.replacingOccurrences(of: "<\(tag)[^>]*>.*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return String(clean(html).prefix(1800))
    }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let ents = ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (k, v) in ents { t = t.replacingOccurrences(of: k, with: v) }
        t = t.replacingOccurrences(of: "&#[0-9]+;", with: " ", options: .regularExpression)
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Returns notes to add to Capri's prompt, plus the sources to show under her reply.
    static func gather(_ text: String, lang: String, status: @escaping @MainActor (String) -> Void) async -> (String, [Source])? {
        await status(Texts.shared.web("search", lang))
        guard let hits = try? await search(query(text), lang: lang), !hits.isEmpty else { return nil }
        let top = Array(hits.prefix(3))
        await status(String(format: Texts.shared.web("read", lang), top.count))
        let pages = await withTaskGroup(of: (Int, String).self) { g -> [Int: String] in
            for (i, h) in top.enumerated() { g.addTask { (i, await read(h.url)) } }
            var r: [Int: String] = [:]
            for await (i, s) in g { r[i] = s }
            return r
        }
        var notes = "\n\n[Web results for the user's message. Use them for facts, answer in your own words and style, don't paste links or mention searching.]\n"
        for (i, h) in hits.enumerated() {
            let body = (i < 3 ? pages[i] : nil).flatMap { $0.isEmpty ? nil : $0 } ?? h.snippet
            notes += "\n(\(i + 1)) \(h.title)\n\(body)\n"
        }
        return (notes, hits.map { Source(title: $0.title, url: $0.url) })
    }
}
