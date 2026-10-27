import Foundation
import DavKit
import MTPKit

/// One connected device = one DavServer + one mount_webdav volume under
/// ~/Berth/<Device>. Unprivileged: mount_webdav happily mounts a localhost
/// URL onto a user-owned directory.
@MainActor
final class WebDAVMounter {

    struct Active {
        let device: MTPDeviceRef
        let backend: MTPDavBackend
        let server: DavServer
        let mountPoint: URL
        /// The `mount_webdav` child that established the volume. It lingers
        /// ~90 s after a successful mount; keeping it alive here keeps a live
        /// reference to the process (so it is reaped rather than left as a
        /// zombie) and lets teardown terminate it deliberately.
        let mountHelper: Process?
    }

    /// True once a volume is mounted at `url`. Reads the kernel mount table
    /// (MNT_NOWAIT, no refresh) rather than stat-ing the path: stat on a path
    /// that mount_webdav is mid-mounting routes through the stalling WebDAV
    /// filesystem and blocks for the whole ~90s, freezing the caller. The mount
    /// table is populated by mount(2) as soon as the volume registers.
    static func isMountPoint(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return false }
        for i in 0..<Int(count) {
            var entry = buffer[i]
            let name = withUnsafeBytes(of: &entry.f_mntonname) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            if name == target { return true }
        }
        return false
    }

    private(set) var active = [String: Active]() // keyed by urlHost
    /// Hosts with a mount attempt in flight. MTP allows one exclusive USB
    /// claim per device, so two concurrent attempts collide and both fail —
    /// this guard admits exactly one attempt per device at a time.
    private var mounting = Set<String>()
    /// Hosts whose device was unplugged while a mount was still in flight.
    /// Without this, deviceGone() found nothing to unmount, and the mount then
    /// finished and registered a live volume for a device that no longer
    /// exists — the kind of dead webdav mount that hangs Finder.
    private var abandoned = Set<String>()
    /// In-flight unmount per host. Two ejectors (menu "Eject" and the
    /// cable-removed path) would otherwise both run `umount -f`, both poll for
    /// detach, and race each other's `removeItem(mountPoint)` — potentially
    /// deleting a directory a concurrent mount just created. Mounts wait on
    /// this too, so a mount can never return a point that is being torn down.
    private var unmounting = [String: Task<Void, Never>]()
    /// Set at launch, awaited by the first mount so orphan sweeping still
    /// precedes any mount without gating startup: a hung child must never
    /// stop the watcher (and therefore the menu bar and error reporting) from
    /// coming up.
    private var sweepTask: Task<Void, Never>?

    static let mountRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Berth", isDirectory: true)

    /// The tablet glyph served as the volume's icon. Loaded from the app
    /// bundle, generated at build time from an SF Symbol.
    static var volumeIconData: Data? {
        guard let url = Bundle.main.url(forResource: "VolumeIcon", withExtension: "icns") else { return nil }
        return try? Data(contentsOf: url)
    }

    enum MountError: Error, CustomStringConvertible {
        case failed(String)
        case inProgress
        var description: String {
            switch self {
            case .failed(let message): return message
            case .inProgress: return "mount already in progress"
            }
        }
    }

    func isMounted(_ device: MTPDeviceRef) -> Bool {
        active[device.urlHost] != nil
    }

    func isMounted(host: String) -> Bool {
        active[host] != nil
    }

    func mountPoint(for device: MTPDeviceRef) -> URL? {
        active[device.urlHost]?.mountPoint
    }

    /// Whether anything is mounted — the authoritative source for the menu bar
    /// indicator, independent of the transient device scan.
    var hasActiveMounts: Bool { !active.isEmpty }

    /// Whether the mounted device is actually sharing storage (false while the
    /// phone is locked or on "No data transfer"). Nil if it isn't mounted.
    func noteDeviceEvent(_ device: MTPDeviceRef) async {
        await active[device.urlHost]?.backend.noteDeviceEvent()
    }

    func hasStorages(_ device: MTPDeviceRef) async -> Bool? {
        guard let entry = active[device.urlHost] else { return nil }
        return await entry.backend.hasStorages()
    }

    /// The devices currently mounted, as captured at mount time.
    var mountedDevices: [MTPDeviceRef] { active.values.map(\.device) }

    /// Mount point paths, for a fast force-unmount on quit.
    var mountPointPaths: [String] { active.values.map { $0.mountPoint.path } }

    func mount(_ device: MTPDeviceRef) async throws -> URL {
        // Orphan sweeping still runs before the first mount (a stale mount
        // would stack on this path), but it no longer gates app startup.
        if let sweep = sweepTask { await sweep.value }
        // An eject may still be in flight for this host; returning a mount
        // point it is about to tear down would show the user a Finder window
        // that dies moments later.
        if let pending = unmounting[device.urlHost] { _ = await pending.value }
        if let existing = active[device.urlHost] { return existing.mountPoint }
        // Runs to the first `await` synchronously on the main actor, so this
        // check-and-insert is atomic against other concurrent mount() calls:
        // the second caller sees the flag and bails instead of racing for USB.
        guard !mounting.contains(device.urlHost) else { throw MountError.inProgress }
        mounting.insert(device.urlHost)
        abandoned.remove(device.urlHost)
        defer {
            mounting.remove(device.urlHost)
            abandoned.remove(device.urlHost)
        }

        let backend = MTPDavBackend(urlHost: device.urlHost, volumeIcon: Self.volumeIconData)
        // Eager connect, with retries: right after plug-in the device may not
        // be ready yet, and Image Capture's daemon transiently claims new MTP
        // devices before releasing them. One instant attempt would fail races
        // that resolve themselves within seconds.
        var volumeName: String?
        for attempt in 1...5 {
            do {
                DebugLog.log("mount: prepare attempt \(attempt) for \(device.name)")
                volumeName = try await backend.prepare()
                DebugLog.log("mount: prepared, volume '\(volumeName ?? "")'")
                break
            } catch {
                DebugLog.log("mount: prepare attempt \(attempt) failed: \(error)")
                await backend.shutdown()
                // macOS's camera daemon (ptpcamerad) claims MTP interfaces the
                // moment a device (re)connects and never lets go, so every open
                // fails with "Failed to create IOUSBHostInterface". It is a
                // per-user, on-demand daemon that launchd respawns, so ending
                // it is safe; the next attempt then wins the interface.
                if attempt >= 1 { await releaseCameraDaemonClaim() }
                if attempt < 5 {
                    // Short, gentle backoff: 0.5 s, 1 s, 1.5 s, 2 s.
                    try? await Task.sleep(for: .milliseconds(500 * attempt))
                }
            }
        }
        if abandoned.contains(device.urlHost) {
            await backend.shutdown()
            throw MountError.failed("The device was unplugged while it was being opened.")
        }
        guard let volumeName else {
            throw MountError.failed("Could not open the device. Unlock it, choose File Transfer mode, and make sure no other app (Image Capture, Photos, Android File Transfer) has claimed it.")
        }

        let server = DavServer(backend: backend)
        // Per-request lines only when BERTH_DEBUG=1; server faults (5xx),
        // refused connections and framing errors are always logged.
        server.debugLogging = DebugLog.verbose
        server.logHandler = { DebugLog.log("dav " + $0) }
        try server.start()

        // Use a *.localhost hostname (RFC 6761) so the server hostname shown in
        // Finder's sidebar is the device name instead of a raw IP/localhost.
        // *.localhost always resolves to 127.0.0.1, so no DNS/admin is needed.
        // The name comes from the connected device itself (its MTP friendly
        // name, falling back to the model), never from a hardcoded string.
        // Hostnames can't contain spaces, but a non-breaking space (U+00A0)
        // resolves under .localhost and renders as a space in Finder's
        // sidebar, so the label reads like the device's real name.
        let rawName = volumeName.isEmpty ? device.name : volumeName
        let cleaned = rawName
            .map { ch -> Character in
                if ch == " " { return "\u{00A0}" }
                if "/:@?#%\\".contains(ch) || ch.isNewline { return "-" }
                return ch
            }
        let hostLabel = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedHost = (hostLabel.isEmpty ? "device" : hostLabel)
            .addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? "device"
        let serverURL = server.url.absoluteString
            .replacingOccurrences(of: "127.0.0.1", with: "\(encodedHost).localhost")

        let dirName = sanitize(volumeName.isEmpty ? device.name : volumeName)
        var mountPoint = Self.mountRoot.appendingPathComponent(dirName, isDirectory: true)
        var n = 2
        while active.values.contains(where: { $0.mountPoint == mountPoint }) {
            mountPoint = Self.mountRoot.appendingPathComponent("\(dirName) \(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        // A previous run that died uncleanly can leave a dead webdav mount on
        // this path; mounting over it would stack. Sweep first.
        _ = try? await run("/sbin/umount", ["-f", mountPoint.path])
        _ = try? await run("/sbin/umount", ["-f", mountPoint.path])

        // mount_webdav establishes the volume within a second or two but then
        // lingers ~90s before it exits (a webdavfs quirk, reproducible even
        // against a trivial local server). Waiting on its exit would make every
        // mount feel like a 90-second hang, so instead launch it and poll for
        // the volume to actually appear.
        let webdav = Process()
        webdav.executableURL = URL(fileURLWithPath: "/sbin/mount_webdav")
        // -S suppresses mount_webdav's authentication and "server not
        // responding" dialogs. Without it, a background (LSUIElement) app has
        // no UI session to show those dialogs, so mount_webdav waits ~90s for
        // one before giving up and mounting anyway. Our server is local and
        // never needs auth, so suppressing is pure win — and it makes the mount
        // appear in ~1s instead of 90s.
        webdav.arguments = ["-S", "-v", dirName, serverURL, mountPoint.path]
        webdav.terminationHandler = { _ in }   // reap when it eventually exits
        do {
            try webdav.run()
        } catch {
            server.stop()
            await backend.shutdown()
            try? FileManager.default.removeItem(at: mountPoint)
            throw MountError.failed("Could not start the mount helper.")
        }

        var mounted = false
        for _ in 0..<500 {   // up to ~20s
            if Self.isMountPoint(mountPoint) { mounted = true; break }
            if !webdav.isRunning, webdav.terminationStatus != 0 { break } // failed early
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard mounted else {
            if webdav.isRunning { webdav.terminate() }
            server.stop()
            await backend.shutdown()
            try? FileManager.default.removeItem(at: mountPoint)
            throw MountError.failed("Could not mount the volume. Unplug the device and try again.")
        }
        DebugLog.log("mount: volume up at \(mountPoint.path)")

        active[device.urlHost] = Active(
            device: device, backend: backend, server: server,
            mountPoint: mountPoint, mountHelper: webdav
        )
        // Unplugged mid-mount: tear down through the normal path, which
        // unmounts, verifies against the mount table, and only then stops the
        // server.
        if abandoned.contains(device.urlHost) {
            DebugLog.log("mount: device vanished during mount; tearing down")
            await unmount(device, force: true)
            throw MountError.failed("The device was unplugged while it was being mounted.")
        }

        // Mark the volume as having a custom icon so Finder honours the
        // `.VolumeIcon.icns` we serve at its root (tablet glyph) instead of
        // the generic disk icon in the sidebar/Locations. SetFile only sticks
        // once the WebDAV mount has fully settled, hence the delay.
        let settledPath = mountPoint.path
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/SetFile")
            p.arguments = ["-a", "C", settledPath]
            try? p.run()
            p.waitUntilExit()
        }

        // Keep Spotlight off the volume as a fire-and-forget nicety. This is
        // never awaited in the mount path: `mdutil` on a WebDAV mount can hang,
        // and blocking here would leave the mount untracked (no menu bar
        // update, no auto-reveal). The volume's .metadata_never_index file is
        // the real, synchronous opt-out.
        let path = mountPoint.path
        Task.detached { [weak self] in _ = try? await self?.run("/usr/bin/mdutil", ["-i", "off", path]) }

        return mountPoint
    }

    /// Ends ptpcamerad (and Image Capture's icdd stays untouched) so it
    /// releases a freshly connected MTP interface. No-op if not running.
    private func releaseCameraDaemonClaim() async {
        let r = try? await run("/usr/bin/pkill", ["-9", "-x", "ptpcamerad"])
        DebugLog.log("mount: released ptpcamerad claim (pkill status \(r?.status ?? -1))")
    }

    /// Ejects a device. Concurrent callers (menu Eject + cable-removed) join
    /// the single in-flight unmount instead of racing it.
    func unmount(_ device: MTPDeviceRef, force: Bool = false) async {
        if let inFlight = unmounting[device.urlHost] { _ = await inFlight.value; return }
        let task = Task { await self.performUnmount(device, force: force) }
        unmounting[device.urlHost] = task
        _ = await task.value
        unmounting.removeValue(forKey: device.urlHost)
    }

    private func performUnmount(_ device: MTPDeviceRef, force: Bool) async {
        guard let entry = active[device.urlHost] else { return }
        let t0 = Date()
        defer { DebugLog.log("timing: unmount took \(Int(Date().timeIntervalSince(t0) * 1000)) ms") }
        var args = force ? ["-f"] : [String]()
        args.append(entry.mountPoint.path)
        let result = try? await run("/sbin/umount", args)
        if result?.status != 0, !force {
            // Busy volume: force it rather than leave a zombie.
            _ = try? await run("/sbin/umount", ["-f", entry.mountPoint.path])
        }

        // Never stop the server behind a live mount. webdav.fs is an in-kernel
        // client that blocks in the VFS waiting on the loopback server; killing
        // that server while the volume is still attached blocks Finder on the
        // next stat, blocks WindowServer behind Finder, and wedges the machine
        // with no panic log (a hang, not a crash). umount exiting 0 is not
        // proof the kernel released the volume, so verify against the mount
        // table before tearing the server down. If the volume refuses to go,
        // leave the server running — a leaked server degrades to a working
        // volume the user can still eject, whereas a dead server behind a live
        // mount costs them their session.
        if !(await waitUntilDetached(entry.mountPoint)) {
            _ = try? await run("/sbin/umount", ["-f", entry.mountPoint.path])
        }
        guard await waitUntilDetached(entry.mountPoint) else {
            DebugLog.log("unmount: \(entry.mountPoint.path) still mounted after force umount — "
                + "leaving the server alive rather than wedge Finder; swept on next launch")
            return
        }

        // The volume is provably gone from the mount table, so every local
        // resource behind it can go: the helper child (its work finished at
        // mount time), the loopback server, the backend's USB session.
        if let helper = entry.mountHelper, helper.isRunning { helper.terminate() }
        entry.server.stop()
        await entry.backend.shutdown()
        try? FileManager.default.removeItem(at: entry.mountPoint)
        active.removeValue(forKey: device.urlHost)
    }

    /// Poll the mount table until `url` is no longer a mount point.
    /// Returns false if it is still attached when the deadline passes.
    private func waitUntilDetached(_ url: URL, timeout: Duration = .seconds(8)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !Self.isMountPoint(url) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return !Self.isMountPoint(url)
    }

    /// Cable yanked: the volume is dead; force-clean everything.
    func deviceGone(_ device: MTPDeviceRef) async {
        if mounting.contains(device.urlHost) { abandoned.insert(device.urlHost) }
        await unmount(device, force: true)
    }

    func unmountAll() async {
        // Snapshot: `unmount` mutates `active` as it goes.
        for entry in Array(active.values) {
            await unmount(entry.device)
        }
    }

    /// Kicks off orphan sweeping at launch without blocking. Startup used to
    /// run it inline before `watcher.start()`, so one hung `umount` — exactly
    /// what a Finder-wedged volume produces — meant the app never began
    /// watching and never mounted anything, with no UI indication at all.
    /// `mount()` awaits this task, so the ordering that actually matters
    /// (no mount over an orphan) is preserved.
    func startOrphanSweep() {
        guard sweepTask == nil else { return }
        sweepTask = Task { await self.sweepOrphanMounts() }
    }

    /// Force-unmount any Berth WebDAV mounts left by a previous run. Mounts
    /// outlive the process, so an unclean exit (crash, or a dev `killall`)
    /// orphans them: their local server is dead, and Finder hangs forever on
    /// the mount point. Run this at launch, before anything else, so a stale
    /// mount never wedges the session.
    func sweepOrphanMounts() async {
        let rootPath = Self.mountRoot.path
        let listing = (try? await run("/sbin/mount", [])) ?? (status: 0, output: "")
        for line in listing.output.split(separator: "\n") {
            guard line.contains("webdav"), line.contains(rootPath),
                  let onRange = line.range(of: " on "),
                  let tag = line.range(of: " (webdav") else { continue }
            let path = String(line[onRange.upperBound..<tag.lowerBound])
            _ = try? await run("/sbin/umount", ["-f", path])
        }
        // Remove leftover empty mount-point directories.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: rootPath)) ?? []
        for name in names {
            let dir = Self.mountRoot.appendingPathComponent(name, isDirectory: true)
            if (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    private func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "MTP Device" : cleaned
    }

    /// Runs a helper with a hard deadline.
    ///
    /// Two failure modes are engineered out here. First, a hung child: `umount`
    /// on a volume Finder has wedged does not exit, and an unbounded wait once
    /// meant the launch sweep never returned and the app silently never
    /// started. Second, the post-mortem pipe read: `readDataToEndOfFile` in the
    /// termination handler only runs after the child exits, so a child that
    /// fills the 64 KB pipe buffer before exiting deadlocks — killing it at the
    /// deadline unblocks the write and lets the handler run.
    private func run(
        _ tool: String, _ args: [String], timeout: Duration = .seconds(15)
    ) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                once.resume(.success((finished.terminationStatus, output)))
            }
            do {
                try process.run()
            } catch {
                once.resume(.failure(error))
                return
            }
            let seconds = Double(timeout.components.seconds)
                + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                guard process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
                once.resume(.success((-1, "timed out after \(Int(seconds))s: \(tool)")))
            }
        }
    }

    /// Continuation wrapper that resumes exactly once, so a deadline firing
    /// after the child already exited (or vice versa) cannot resume twice.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(status: Int32, output: String), Error>?

        init(_ continuation: CheckedContinuation<(status: Int32, output: String), Error>) {
            self.continuation = continuation
        }

        func resume(_ result: Result<(status: Int32, output: String), Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }
}
