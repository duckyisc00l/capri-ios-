import Foundation
import Darwin

/// Saves the reason for a crash to a file so the next launch can show it.
enum CrashReporter {
    static var file: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("last-crash.txt")
    }
    private static var path: [CChar] = []

    static func install() {
        path = Array(file.path.utf8CString)
        NSSetUncaughtExceptionHandler { e in
            let text = "Exception: \(e.name.rawValue)\n\(e.reason ?? "")\n\n" + e.callStackSymbols.joined(separator: "\n")
            CrashReporter.write(text)
        }
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig) { s in
                let text = "Signal \(s)\n\n" + Thread.callStackSymbols.joined(separator: "\n")
                CrashReporter.write(text)
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    static func write(_ text: String) {
        let info = Bundle.main.infoDictionary
        let header = "Capri \(info?["CFBundleShortVersionString"] ?? "") (\(info?["CFBundleVersion"] ?? ""))\n\(Date())\n\n"
        let data = Array((header + text).utf8)
        let fd = path.withUnsafeBufferPointer { open($0.baseAddress!, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
        if fd >= 0 {
            _ = data.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            close(fd)
        }
    }

    /// The saved crash, if any, removed once read.
    static func takeLast() -> String? {
        guard let s = try? String(contentsOf: file, encoding: .utf8), !s.isEmpty else { return nil }
        try? FileManager.default.removeItem(at: file)
        return s
    }
}
