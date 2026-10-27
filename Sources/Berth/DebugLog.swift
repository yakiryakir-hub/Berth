import Foundation

/// Append-only debug log at ~/Library/Logs/Berth.log. NSLog from this app
/// has proven unqueryable via `log show`; a plain file always works.
enum DebugLog {
    /// Per-request WebDAV chatter and other noisy lines. Off by default: it
    /// cost a file write per Finder request. `BERTH_DEBUG=1` turns it on.
    static let verbose = ProcessInfo.processInfo.environment["BERTH_DEBUG"] == "1"

    /// The log is append-only, so cap it: keep the previous run's log as
    /// Berth.log.old and start fresh once it passes 1 MB.
    private static let maxBytes = 1 << 20

    private static let handle: FileHandle? = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Berth.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > maxBytes {
            let old = url.appendingPathExtension("old")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()
    private static let lock = NSLock()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.write(contentsOf: Data("\(stamp.string(from: Date())) \(line)\n".utf8))
    }

    /// Last `count` lines of the log, for the diagnostics report.
    static func tail(_ count: Int) -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Berth.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "(no log)" }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).joined(separator: "\n")
    }
}
