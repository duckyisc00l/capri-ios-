import Foundation
import UIKit

struct LocalModel: Codable, Identifiable, Hashable {
    var name: String
    var repo: String
    var file: String
    var size: Int64
    var id: String { file }
    var path: URL { Paths.models.appendingPathComponent(file) }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

struct HubRepo: Identifiable, Hashable {
    var id: String
    var downloads: Int
    var likes: Int
    var gated: Bool
}

struct HubFile: Identifiable, Hashable {
    var path: String
    var size: Int64
    var tier: String
    var id: String { path }
}

/// Downloads GGUF models from Hugging Face and keeps track of what's installed.
@MainActor
final class ModelManager: NSObject, ObservableObject {
    static let maxModels = 5

    @Published var installed: [LocalModel] = []
    @Published var progress: [String: Double] = [:]
    @Published var errors: [String: String] = [:]

    private var pending: [String: LocalModel] = [:]
    private let registry = Paths.support.appendingPathComponent("models.json")
    private var session: URLSession!

    let defaultModel: LocalModel = {
        let d = Texts.shared.any("DEFAULT_MODEL") as? [String: Any] ?? [:]
        return LocalModel(name: d["name"] as? String ?? "Gemma 3 4B",
                          repo: d["repo"] as? String ?? "",
                          file: d["file"] as? String ?? "",
                          size: (d["size"] as? NSNumber)?.int64Value ?? 0)
    }()

    override init() {
        super.init()
        if let d = try? Data(contentsOf: registry), let list = try? JSONDecoder().decode([LocalModel].self, from: d) {
            installed = list.filter { FileManager.default.fileExists(atPath: $0.path.path) }
        }
        // A normal (foreground) session: background sessions don't work inside LiveContainer.
        let cfg = URLSessionConfiguration.default
        cfg.allowsCellularAccess = true
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 60 * 60 * 6
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        // Leftover half-downloaded files from a crash or a killed app.
        if let files = try? FileManager.default.contentsOfDirectory(at: Paths.models, includingPropertiesForKeys: nil) {
            for f in files where !installed.contains(where: { $0.path.lastPathComponent == f.lastPathComponent }) {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    func isInstalled(_ m: LocalModel) -> Bool { installed.contains { $0.file == m.file } }

    private func saveRegistry() {
        if let d = try? JSONEncoder().encode(installed) { try? d.write(to: registry, options: .atomic) }
    }

    static var deviceRAM: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }
    static func fits(_ size: Int64) -> Bool { size < Int64(Double(deviceRAM) * 0.6) }

    static var freeSpace: Int64 {
        let v = try? Paths.support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    /// Returns an error key from the UI strings, or nil if the download started.
    func download(_ m: LocalModel) -> String? {
        if isInstalled(m) { return "added" }
        if progress[m.file] != nil { return nil }
        if installed.count >= Self.maxModels { return "limit" }
        if !Self.fits(m.size) { return "too_big" }
        if m.size + 200_000_000 > Self.freeSpace { return "no_space" }
        let enc = m.file.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        guard let url = URL(string: "https://huggingface.co/\(m.repo)/resolve/main/\(enc)?download=true") else { return "failed" }
        let task = session.downloadTask(with: url)
        task.taskDescription = String(data: (try? JSONEncoder().encode(m)) ?? Data(), encoding: .utf8)
        pending[m.file] = m
        progress[m.file] = 0
        errors[m.file] = nil
        UIApplication.shared.isIdleTimerDisabled = true
        task.resume()
        return nil
    }

    func cancel(_ m: LocalModel) {
        session.getAllTasks { tasks in
            for t in tasks where t.taskDescription?.contains("\"\(m.file)\"") == true { t.cancel() }
        }
        progress[m.file] = nil
        pending[m.file] = nil
    }

    func delete(_ m: LocalModel) {
        LlamaRunner.shared.unload()
        try? FileManager.default.removeItem(at: m.path)
        installed.removeAll { $0.file == m.file }
        saveRegistry()
    }

    fileprivate func finished(_ m: LocalModel, ok: Bool, error: String?) {
        progress[m.file] = nil
        pending[m.file] = nil
        if progress.isEmpty { UIApplication.shared.isIdleTimerDisabled = false }
        if ok {
            if !installed.contains(where: { $0.file == m.file }) { installed.append(m) }
            saveRegistry()
        } else if let error {
            errors[m.file] = error
        }
    }

    // MARK: - Hugging Face search

    func search(_ q: String) async throws -> [HubRepo] {
        var c = URLComponents(string: "https://huggingface.co/api/models")!
        c.queryItems = [
            .init(name: "search", value: q.isEmpty ? "gguf" : q),
            .init(name: "filter", value: "gguf"),
            .init(name: "sort", value: "downloads"),
            .init(name: "direction", value: "-1"),
            .init(name: "limit", value: "40"),
        ]
        let (d, _) = try await URLSession.shared.data(from: c.url!)
        let list = (try JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? []
        let junk = Texts.shared.list("HUB_JUNK").map { $0.lowercased() }
        return list.compactMap { j in
            guard let id = j["id"] as? String else { return nil }
            let low = id.lowercased()
            if junk.contains(where: { low.contains($0) }) { return nil }
            let gated: Bool = (j["gated"] as? Bool) ?? ((j["gated"] as? String).map { $0 != "false" } ?? false)
            return HubRepo(id: id, downloads: j["downloads"] as? Int ?? 0, likes: j["likes"] as? Int ?? 0, gated: gated)
        }
    }

    func files(_ repo: String) async throws -> [HubFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main")!
        let (d, _) = try await URLSession.shared.data(from: url)
        let list = (try JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? []
        let tiers = (Texts.shared.any("HUB_TIERS") as? [[Any]]) ?? []
        func tier(_ name: String) -> (String, Int)? {
            let up = name.uppercased()
            var rank = 0
            for t in tiers {
                guard let label = t.first as? String, let quants = t.last as? [String] else { continue }
                for q in quants {
                    if up.contains(q.uppercased()) { return (label, rank) }
                    rank += 1
                }
            }
            return nil
        }
        var out: [(HubFile, Int)] = []
        for j in list {
            guard let path = j["path"] as? String, path.lowercased().hasSuffix(".gguf"),
                  !path.lowercased().contains("mmproj"), !path.contains("-of-0") else { continue }
            let size = ((j["lfs"] as? [String: Any])?["size"] as? NSNumber)?.int64Value ?? (j["size"] as? NSNumber)?.int64Value ?? 0
            let t = tier(path)
            out.append((HubFile(path: path, size: size, tier: t?.0 ?? ""), t?.1 ?? 999))
        }
        return out.sorted { $0.1 < $1.1 }.map(\.0)
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let m = Self.model(of: downloadTask) else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : max(m.size, 1)
        let p = Double(totalBytesWritten) / Double(total)
        Task { @MainActor in
            if let old = self.progress[m.file], p - old < 0.003, p < 1 { return }
            self.progress[m.file] = p
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let m = Self.model(of: downloadTask) else { return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        var err: String? = nil
        if code == 401 || code == 403 {
            err = "gated"
        } else if code != 200 && code != 0 {
            err = "failed"
        } else {
            let dest = m.path
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.moveItem(at: location, to: dest) } catch { err = "failed" }
        }
        let e = err
        Log.write("download finished \(m.file) http=\(code) err=\(e ?? "none")")
        Task { @MainActor in self.finished(m, ok: e == nil, error: e) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let m = Self.model(of: task) else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        Log.write("download error \(m.file): \(error.localizedDescription)")
        Task { @MainActor in self.finished(m, ok: false, error: cancelled ? nil : "failed") }
    }

    nonisolated private static func model(of task: URLSessionTask) -> LocalModel? {
        guard let s = task.taskDescription, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LocalModel.self, from: d)
    }
}
