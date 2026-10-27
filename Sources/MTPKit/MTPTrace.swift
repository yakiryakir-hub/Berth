import Foundation

/// Protocol-level trace for MTPKit.
///
/// MTPKit shipped with no logging at all, which makes device-specific
/// failures — like a write that times out on one vendor's implementation but
/// not another's — completely invisible from the outside. This records one
/// line per PTP transaction and per data-phase chunk.
///
/// Off unless `MTP_TRACE=1` is set in the environment or `MTPTrace.enabled`
/// is flipped by the host app, so it costs one boolean test in normal use.
public enum MTPTrace {

    /// Guarded by `lock`; `nonisolated(unsafe)` because the mutation is
    /// serialized by hand rather than by an actor.
    public nonisolated(unsafe) static var enabled: Bool = {
        let env = ProcessInfo.processInfo.environment["MTP_TRACE"]
        return env == "1" || env == "YES" || env == "true"
    }()

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handle: FileHandle?

    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Berth.mtp.log")

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Always-on one-liner into Berth.log's sibling (used by experiments).
    public static func note(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Berth.log")
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data("\(f.string(from: Date())) mtp: \(line)\n".utf8)); try? h.close()
        }
    }

    public static func log(_ line: @autoclosure () -> String) {
        guard enabled else { return }
        let text = "\(stamp.string(from: Date())) \(line())\n"
        lock.lock()
        defer { lock.unlock() }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: Data(text.utf8))
    }

    /// Hex formatting helper: `0x1f` rather than `2000000000000031`.
    public static func hex(_ v: UInt32) -> String { "0x" + String(v, radix: 16) }

    public static func hex(_ v: [UInt32]) -> String {
        "[" + v.map { hex($0) }.joined(separator: ", ") + "]"
    }

    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }
}
