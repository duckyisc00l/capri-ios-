import Foundation

/// Talks to any OpenAI-compatible provider with the user's own API key.
enum CloudBrain {
    static func generate(base: String, key: String, model: String, turns: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    guard !key.isEmpty else { throw BrainError.noKey }
                    var req = URLRequest(url: URL(string: base + "/chat/completions")!)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 120
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    req.setValue(key, forHTTPHeaderField: "x-api-key")
                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "max_tokens": 2048,
                        "messages": turns.map { ["role": $0.role, "content": $0.content] },
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code != 200 {
                        var text = ""
                        for try await line in bytes.lines { text += line; if text.count > 600 { break } }
                        throw BrainError.http(code, errorMessage(text))
                    }
                    var inThink = false
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let d = payload.data(using: .utf8),
                              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let choice = (j["choices"] as? [[String: Any]])?.first,
                              let delta = choice["delta"] as? [String: Any] else { continue }
                        let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String) ?? ""
                        let content = delta["content"] as? String ?? ""
                        if !reasoning.isEmpty {
                            if !inThink { cont.yield("<think>"); inThink = true }
                            cont.yield(reasoning)
                        }
                        if !content.isEmpty {
                            if inThink { cont.yield("</think>"); inThink = false }
                            cont.yield(content)
                        }
                    }
                    if inThink { cont.yield("</think>") }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    static func errorMessage(_ body: String) -> String {
        if let d = body.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let e = j["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let m = j["error"] as? String { return m }
            if let m = j["message"] as? String { return m }
        }
        return String(body.prefix(200))
    }

    static func models(base: String, key: String) async -> [String] {
        guard let url = URL(string: base + "/models") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let list = j["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }.map { $0.replacingOccurrences(of: "models/", with: "") }.sorted()
    }
}
