import AppKit
@preconcurrency import FileProvider
import ServiceManagement
import MTPKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let watcher = DeviceWatcher()
    private let mounter = WebDAVMounter()
    private var devices = [MTPDeviceRef]()
    /// Android devices plugged in but not offering MTP (locked or Charging only).
    private var fileTransferHints = [String]()
    /// Devices that failed to mount, with the reason, for menu display.
    private var errors = [String: String]()
    /// Devices we've auto-opened a Finder window for this attach.
    private var revealed = Set<String>()
    /// A device that vanishes from the scan is not acted on immediately:
    /// during USB re-enumeration the registry transiently reports nothing,
    /// and acting on that used to force-unmount a live volume and close the
    /// MTP session seconds after a healthy mount. Only an absence that
    /// persists past this window is treated as a real unplug.
    private var goneDebounce = [String: Task<Void, Never>]()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = MenuBarIcon.image(mounted: false)
            button.image?.accessibilityDescription = "Berth"
        }
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        removeLegacyFileProviderDomains()
        cleanStaleWebDAVRecents()

        watcher.onChange = { [weak self] current in
            self?.devicesChanged(current)
        }
        watcher.onEvent = { [weak self] in
            self?.usbEvent()
        }
        watcher.onHint = { [weak self] names in
            self?.fileTransferHints = names
        }

        // Clear any orphaned mounts from a previous run before we mount
        // anything — a stale mount hangs Finder. This runs in the background
        // so a wedged volume can't stop the app from coming up: the watcher
        // starts immediately, and `mount` awaits the sweep before touching a
        // mount point, which is the ordering that actually matters.
        mounter.startOrphanSweep()
        watcher.start()

        // After sleep the USB registry settles late and the device may have
        // re-enumerated; rescan a few times so the mount returns promptly.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DebugLog.log("system woke; rescanning for devices")
            for delay in [1.0, 3.0, 8.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { self?.watcher.rescan() }
                }
            }
        }
    }

    /// Quit must not outrun the teardown.
    ///
    /// The old path spawned `umount -f` per volume and never waited, then
    /// exited: if the kernel had not released the volume by then, the in-kernel
    /// webdavfs client was left pointed at a server this process was about to
    /// kill — Finder then hangs on that path until the next launch's sweep.
    /// `.terminateLater` keeps AppKit's run loop spinning while the mounter
    /// unmounts, verifies each volume against the mount table, and only then
    /// stops its server, so we never exit with a live mount behind us.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        watcher.stop()
        guard mounter.hasActiveMounts else { return .terminateNow }
        Task { @MainActor in
            await mounter.unmountAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Last resort only: `applicationShouldTerminate` already did the
        // verified teardown for a normal quit. Anything still mounted here is
        // a volume that refused to detach; force it and let the child finish
        // after we exit, then next launch sweeps whatever remains.
        for path in mounter.mountPointPaths {
            let umount = Process()
            umount.executableURL = URL(fileURLWithPath: "/sbin/umount")
            umount.arguments = ["-f", path]
            try? umount.run()   // fire and forget; never waited on
        }
    }

    /// Earlier Berth builds used File Provider; clear any domains they left
    /// so Finder doesn't show a dead sidebar entry.
    private func removeLegacyFileProviderDomains() {
        // One-time housekeeping: once a launch has swept them, there is
        // nothing left to find, so don't ask the system again every launch.
        let key = "legacyFileProviderCleanupDone"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
            if error == nil { UserDefaults.standard.set(true, forKey: key) }
            NSLog("Berth cleanup: %d legacy domain(s), error=%@", domains.count, error.map { "\($0)" } ?? "none")
            for domain in domains {
                NSFileProviderManager.remove(domain, mode: .removeAll) { _, removeError in
                    NSLog("Berth cleanup: removed %@ error=%@", domain.identifier.rawValue, removeError.map { "\($0)" } ?? "none")
                }
            }
        }
    }

    /// Finder keeps recently-opened folders in FXRecentFolders, keyed by a
    /// bookmark. For a WebDAV mount that bookmark carries the loopback URL
    /// (http://127.0.0.1:...), so the entry shows up in Recents as an IP
    /// address instead of the device name. Drop any such stale entry on launch
    /// so the sidebar/Locations only ever shows the real device name.
    private func cleanStaleWebDAVRecents() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.finder.plist")
        guard let data = try? Data(contentsOf: url),
              var plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              var recents = plist["FXRecentFolders"] as? [[String: Any]] else { return }
        let before = recents.count
        recents.removeAll { entry in
            guard let bm = entry["file-bookmark"] as? Data else { return false }
            return String(data: bm, encoding: .utf8)?.contains("127.0.0.1") == true
                || bm.range(of: Data("127.0.0.1".utf8)) != nil
        }
        guard recents.count != before else { return }
        plist["FXRecentFolders"] = recents
        if let out = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
            try? out.write(to: url, options: .atomic)
        }
    }

    // MARK: - Device flow

    private func devicesChanged(_ current: [MTPDeviceRef]) {
        let previous = devices
        devices = current

        for gone in previous where !current.contains(gone) {
            errors.removeValue(forKey: gone.urlHost)
            scheduleGone(gone)
        }
        for arrived in current where !previous.contains(arrived) {
            cancelGone(arrived.urlHost)
            autoMount(arrived)
        }
        updateIcon()
    }

    private func scheduleGone(_ device: MTPDeviceRef) {
        guard goneDebounce[device.urlHost] == nil else { return }
        goneDebounce[device.urlHost] = Task { @MainActor in
            // The watcher has already confirmed the absence over ~1.6 s of
            // rescans; this is only a last blip check.
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            self.goneDebounce.removeValue(forKey: device.urlHost)
            // If the device re-appeared in the meantime, it was a blip.
            guard !self.devices.contains(device) else { return }
            self.revealed.remove(device.urlHost)
            await self.mounter.deviceGone(device)
            self.updateIcon()
        }
    }

    private func cancelGone(_ host: String) {
        goneDebounce[host]?.cancel()
        goneDebounce.removeValue(forKey: host)
    }

    private func autoMount(_ device: MTPDeviceRef) {
        Task {
            do {
                let mountPoint = try await mounter.mount(device)
                errors.removeValue(forKey: device.urlHost)
                watchForUnlock(device)
                // First mount for this attach: open it so the device is
                // immediately visible.
                if !revealed.contains(device.urlHost) {
                    revealed.insert(device.urlHost)
                    NSWorkspace.shared.open(mountPoint)
                }
            } catch WebDAVMounter.MountError.inProgress {
                // Another attempt for this device is already running; ignore.
            } catch {
                errors[device.urlHost] = Self.friendly(error)
            }
            updateIcon()
        }
    }

    private var unlockWatchers = [String: Task<Void, Never>]()
    private var eventChecks = Set<String>()

    /// A locked phone mounts but shares nothing. While that's the case, say so
    /// in the menu; clear the note as soon as storage appears.
    private static let lockedNote = "Phone is locked or not sharing files. Unlock it and choose File Transfer."

    /// One storage check; updates the menu note. Nil if the device isn't mounted.
    @discardableResult
    private func checkStorage(_ device: MTPDeviceRef) async -> Bool? {
        guard let ok = await mounter.hasStorages(device) else { return nil }
        let host = device.urlHost
        if ok {
            if errors[host] == Self.lockedNote { errors.removeValue(forKey: host) }
        } else {
            errors[host] = Self.lockedNote
        }
        return ok
    }

    private func watchForUnlock(_ device: MTPDeviceRef) {
        let host = device.urlHost
        unlockWatchers[host]?.cancel()
        unlockWatchers[host] = Task { @MainActor in
            // Runs for as long as the device stays mounted, so the note comes
            // back if sharing is switched off again later. USB events trigger
            // extra immediate checks (see `usbEvent`).
            while !Task.isCancelled {
                guard let ok = await self.checkStorage(device) else { break }
                try? await Task.sleep(for: .seconds(ok ? 2 : 1))
            }
            if self.errors[host] == Self.lockedNote { self.errors.removeValue(forKey: host) }
            self.unlockWatchers.removeValue(forKey: host)
        }
    }

    /// The USB bus changed (e.g. the phone's sharing mode was switched):
    /// re-check right away and again as the device settles.
    private func usbEvent() {
        for device in mounter.mountedDevices where !eventChecks.contains(device.urlHost) {
            eventChecks.insert(device.urlHost)
            Task { @MainActor in
                defer { self.eventChecks.remove(device.urlHost) }
                for delay in [0.0, 0.6, 1.5, 3.0] {
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    await self.mounter.noteDeviceEvent(device)
                    guard await self.checkStorage(device) != nil else { return }
                }
            }
        }
    }

    /// Plain-language reason for a failed mount.
    private static func friendly(_ error: Error) -> String {
        let text = "\(error)"
        if text.lowercased().contains("unavailable") || text.lowercased().contains("busy") {
            return "Couldn't read the device. Unlock it, choose File Transfer, and close other transfer apps."
        }
        return text
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        // Authoritative: reflect whether anything is actually mounted, not
        // whether the current scan happens to list a mounted device.
        button.image = MenuBarIcon.image(mounted: mounter.hasActiveMounts)
        button.image?.accessibilityDescription = "Berth"
    }

    // MARK: - Actions

    /// A device from the scan or, failing that, the current mounts.
    private func device(forHost host: String) -> MTPDeviceRef? {
        devices.first { $0.urlHost == host } ?? mounter.mountedDevices.first { $0.urlHost == host }
    }

    @objc private func toggleMount(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String,
              let device = device(forHost: host) else { return }
        Task {
            if mounter.isMounted(device) {
                await mounter.unmount(device)
                revealed.remove(device.urlHost)
            } else {
                autoMount(device)
            }
            updateIcon()
        }
    }

    @objc private func revealDevice(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String,
              let device = device(forHost: host),
              let mountPoint = mounter.mountPoint(for: device) else { return }
        NSWorkspace.shared.open(mountPoint)
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Berth: login item toggle failed: \(error)")
        }
    }

    /// Puts a redacted, pasteable report on the clipboard for bug reports.
    @objc private func copyDiagnostics(_ sender: NSMenuItem) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        var lines = [
            "Berth \(version) (build \(info?["CFBundleVersion"] as? String ?? "?"))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "",
            "Devices:",
        ]
        if devices.isEmpty { lines.append("  (none seen)") }
        for d in devices {
            let mounted = mounter.isMounted(d) ? "mounted" : "not mounted"
            lines.append(String(format: "  %@  VID:PID %04X:%04X  %@", d.name, d.vendorID, d.productID, mounted))
            if let e = errors[d.urlHost] { lines.append("    error: \(e)") }
        }
        lines += ["", "Recent log:", DebugLog.tail(60)]
        let report = lines.joined(separator: "\n")
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
            .replacingOccurrences(of: NSUserName(), with: "<user>")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}

// MARK: - Menu

extension AppDelegate: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Show every device the scan sees, plus any that are mounted even if
        // the scan momentarily doesn't list them (e.g. mid-replug), deduped by
        // identity. This keeps a live mount visible in the menu.
        var shown = devices
        for mounted in mounter.mountedDevices where !shown.contains(mounted) {
            shown.append(mounted)
        }

        if shown.isEmpty {
            if let name = fileTransferHints.first {
                let item = NSMenuItem(title: "\(name) is connected, but not sharing files", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                let hint = NSMenuItem(title: "Unlock it and choose File Transfer in the USB notification", action: nil, keyEquivalent: "")
                hint.isEnabled = false
                menu.addItem(hint)
            } else {
                let item = NSMenuItem(title: "No MTP device connected", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                let hint = NSMenuItem(title: "Plug in a device and choose File Transfer", action: nil, keyEquivalent: "")
                hint.isEnabled = false
                menu.addItem(hint)
            }
        }

        for device in shown {
            let mounted = mounter.isMounted(device)
            let header = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            if mounted {
                let reveal = NSMenuItem(title: "Show in Finder", action: #selector(revealDevice(_:)), keyEquivalent: "")
                reveal.target = self
                reveal.representedObject = device.urlHost
                reveal.indentationLevel = 1
                menu.addItem(reveal)
            }

            let toggle = NSMenuItem(
                title: mounted ? "Eject" : "Mount",
                action: #selector(toggleMount(_:)), keyEquivalent: ""
            )
            toggle.target = self
            toggle.representedObject = device.urlHost
            toggle.indentationLevel = 1
            menu.addItem(toggle)

            if let error = errors[device.urlHost] {
                let errorItem = NSMenuItem(title: error, action: nil, keyEquivalent: "")
                errorItem.isEnabled = false
                errorItem.indentationLevel = 1
                menu.addItem(errorItem)
            }
        }

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let diag = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics(_:)), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Berth", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
}
