import Foundation

/// A plain-text log in Documents/capri-log.txt (visible in the Files app).
enum Log {
    static var file: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("capri-log.txt")
    }
    private static let queue = DispatchQueue(label: "capri.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    /// Writes one line right away (synchronously, so it survives a crash right after).
    static func write(_ msg: String) {
        queue.sync {
            let line = "\(stamp.string(from: Date()))  \(msg)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: file)
            }
            trim()
        }
    }

    private static func trim() {
        guard let a = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = a[.size] as? Int, size > 400_000,
              let s = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? String(s.suffix(200_000)).write(to: file, atomically: true, encoding: .utf8)
    }

    static func read() -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? "(empty)"
    }

    static func clear() { try? FileManager.default.removeItem(at: file) }

    static func device() -> String {
        var sys = utsname(); uname(&sys)
        let model = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let p = ProcessInfo.processInfo
        let info = Bundle.main.infoDictionary
        return "Capri \(info?["CFBundleShortVersionString"] ?? "") build \(info?["CFBundleVersion"] ?? "") · \(model) · iOS \(p.operatingSystemVersionString) · RAM \(p.physicalMemory / 1_048_576) MB · bundle \(Bundle.main.bundlePath)"
    }
}
