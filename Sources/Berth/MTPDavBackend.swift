import Foundation
import DavKit
import IOKit
import MTPKit

/// Serves an MTP device as a DavBackend tree: storages are top-level folders,
/// objects beneath them. Owns the USB session (actor isolation = MTP's
/// one-command rule) and a path/handle cache so browsing doesn't re-walk the
/// device.
actor MTPDavBackend: DavBackend {

    private let urlHost: String
    private var device: MTPDevice?
    private(set) var deviceName = "MTP Device"

    private struct Node {
        var handle: UInt32
        var storageID: UInt32
        var isDirectory: Bool
        var size: UInt64
        var modified: Date?
        var created: Date?
    }

    private var storagesByName = [String: MTPStorageInfo]()
    /// Single-storage devices (Kindles, most phones without SD cards) skip the
    /// storage folder level entirely: the storage IS the volume root. Multi-
    /// storage devices keep one folder per storage.
    private var soleStorageName: String?
    private enum Container: Hashable {
        case storageRoot(UInt32)
        case folder(UInt32)
    }
    /// Loaded directory listings: container -> child name -> node.
    private var childrenCache = [Container: [String: Node]]()
    /// Last time a miss forced a re-enumeration of a container. Rate-limits the
    /// "cache may be stale, ask the device again" path in `resolve`.
    private var lastRefresh = [Container: Date]()
    /// Finder junk (.DS_Store, ._AppleDouble) swallowed into RAM, keyed by
    /// joined path; never sent to the device.
    private var shadow = [String: Data]()
    private static let shadowFileCap = 1 << 20
    private static let shadowTotalCap = 64 << 20

    /// Optional volume icon served synthetically at the volume root as
    /// `.VolumeIcon.icns`. Finder looks for this file to label the volume
    /// (and therefore the sidebar entry) instead of the generic disk glyph.
    let volumeIcon: Data?

    /// Prefix for the temporary objects an overwrite stages through. Hidden
    /// from Finder (leading dot) and unique per attempt, so a crashed run can
    /// never collide with a later one.
    private static let stagingPrefix = ".berth-tmp-"
    /// Prefix used by builds before the rename; still hidden from listings.
    private static let legacyStagingPrefix = ".moorage-tmp-"
    /// Staging names owned by a write currently in flight in this actor.
    /// Listings may not touch those — only names nobody owns are stale.
    private var staging = Set<String>()

    init(urlHost: String, volumeIcon: Data? = nil) {
        self.urlHost = urlHost
        self.volumeIcon = volumeIcon
    }

    // MARK: - Device session

    /// Set by `shutdown()`, cleared only by an explicit `prepare()`.
    ///
    /// `shutdown()` drops `device`, so without this flag the next request to
    /// arrive after an unmount quietly re-opens the *exclusive* MTP interface
    /// behind a volume that no longer exists — and the following mount then
    /// fails with "device busy" until the cable is replugged.
    private var closed = false

    /// Registry entry ID of the USB interface the current session was opened on.
    /// A device that re-enumerates (tablet finishing its USB mode switch,
    /// Charging -> File transfer, a cable bump) comes back as a NEW registry
    /// entry; the old handle is dead even though the volume is still mounted.
    private var sessionEntryID: UInt64 = 0
    private var lastLivenessCheck = Date.distantPast
    /// In-flight connect, shared by every request that arrives meanwhile.
    /// Finder fires bursts of simultaneous requests; without this, each would
    /// open its own USB transport and fight for the exclusive claim.
    private var connecting: Task<MTPDevice, Error>?

    private func connectedDevice() async throws -> MTPDevice {
        if let device {
            // At most once a second, check the session still sits on the live
            // interface. Only a *different* entry counts as stale: a registry
            // that is momentarily empty mid re-enumeration proves nothing, and
            // dropping a healthy session then would orphan an open transport.
            if Date().timeIntervalSince(lastLivenessCheck) < 1 { return device }
            lastLivenessCheck = Date()
            if sessionIsCurrent() { return device }
            DebugLog.log("session: USB interface was re-enumerated; reconnecting")
            invalidateSession()
        }
        guard !closed else { throw DavError.unavailable }
        if let connecting {
            let dev = try await connecting.value
            if closed { throw DavError.unavailable }
            return dev
        }
        let task = Task { try await self.openDevice() }
        connecting = task
        defer { connecting = nil }
        let dev = try await task.value
        if closed {
            // Unmounted while connecting: don't keep the exclusive interface.
            await dev.disconnect()
            device = nil
            throw DavError.unavailable
        }
        return dev
    }

    private func openDevice() async throws -> MTPDevice {
        guard let service = MTPDeviceLocator.findInterfaceService(urlHost: urlHost) else {
            throw DavError.unavailable
        }
        defer { IOObjectRelease(service) }
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entryID)
        let t0 = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
        do {
            let transport = try USBTransport(interfaceService: service)
            let dev = MTPDevice(transport: transport)
            DebugLog.log("timing: usb open \(ms()) ms")
            let info = try await dev.connect()
            DebugLog.log("timing: connect \(ms()) ms")
            if !info.model.isEmpty { deviceName = info.model }
            // Prefer the human-readable name (e.g. "Galaxy Tab A9") over the
            // raw model code ("SM-X133") that GetDeviceInfo.Model carries.
            if let friendly = await dev.deviceFriendlyName() {
                deviceName = friendly
            }
            // A device that has just been plugged in (or is still locked) can
            // answer with no storages yet. Give it a few seconds, then carry on
            // anyway: list() re-reads the storages whenever they are missing.
            DebugLog.log("timing: name \(ms()) ms")
            try await loadStorages(from: dev, attempts: 4)
            DebugLog.log("timing: storages \(ms()) ms")
            device = dev
            sessionEntryID = entryID
            lastLivenessCheck = Date()
            return dev
        } catch let error as MTPError {
            throw mapError(error)
        }
    }

    /// True unless the device's MTP interface is now a different registry entry
    /// than the one this session was opened on.
    private func sessionIsCurrent() -> Bool {
        guard let service = MTPDeviceLocator.findInterfaceService(urlHost: urlHost) else { return true }
        defer { IOObjectRelease(service) }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { return true }
        return id == sessionEntryID
    }

    /// Drops the USB session and everything derived from it (object handles
    /// and storage IDs are only valid within one session), so the next request
    /// reconnects from scratch.
    private func invalidateSession() {
        device = nil
        childrenCache.removeAll()
        lastRefresh.removeAll()
        storagesByName = [:]
        soleStorageName = nil
    }

    /// Reads the device's storages into `storagesByName`. Retries while the
    /// list is empty, because Android publishes storage only once unlocked.
    private func loadStorages(from dev: MTPDevice, attempts: Int) async throws {
        var names = [String: MTPStorageInfo]()
        for attempt in 0..<max(attempts, 1) {
            names = [:]
            for id in try await dev.storageIDs() {
                let storage = try await dev.storageInfo(id)
                var name = storage.description
                var n = 2
                while names[name] != nil {
                    name = "\(storage.description) \(n)"
                    n += 1
                }
                names[name] = storage
            }
            if !names.isEmpty || attempt == attempts - 1 { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        storagesByName = names
        soleStorageName = names.count == 1 ? names.keys.first : nil
        if names.isEmpty { childrenCache.removeAll() }
    }

    /// Last time a liveness-driven reconnect failed; used to back off so a phone
    /// that is switched to "No data transfer" isn't hammered with connects.
    private var lastReconnectFailure = Date.distantPast

    /// A USB event just happened: forget reconnect back-off and liveness
    /// throttling so the next check reacts immediately.
    func noteDeviceEvent() {
        lastReconnectFailure = .distantPast
        lastLivenessCheck = .distantPast
    }

    /// Whether the device is currently sharing storage. False while the phone
    /// is locked or set to "No data transfer". Re-reads the storage list every
    /// call (one cheap MTP command) so a mode switch is noticed, and
    /// reconnects when the USB interface has been replaced.
    func hasStorages() async -> Bool {
        guard !closed else { return false }
        if device == nil, Date().timeIntervalSince(lastReconnectFailure) < 3 { return false }
        do {
            let dev = try await connectedDevice()
            if try await dev.storageIDs().isEmpty {
                storagesByName = [:]
                soleStorageName = nil
                return false
            }
            if storagesByName.isEmpty { try await loadStorages(from: dev, attempts: 1) }
            return !storagesByName.isEmpty
        } catch {
            if device == nil { lastReconnectFailure = Date() }
            // Only a missing/dead session means "not sharing". A one-off
            // transfer error mid-copy must not flash a false "locked" note.
            if let mtpError = error as? MTPError {
                if case .unavailable = mapError(mtpError), device == nil { return false }
                return true
            }
            return false
        }
    }

    /// Connects eagerly so the app can surface busy/locked errors at attach
    /// time and name the volume; returns the device's model name.
    func prepare() async throws -> String {
        // The explicit re-entry point: clears a prior shutdown so the mount
        // retry loop can reconnect, while late requests after an unmount stay
        // locked out.
        closed = false
        _ = try await connectedDevice()
        return deviceName
    }

    func shutdown() async {
        closed = true
        await device?.disconnect()
        device = nil
        childrenCache.removeAll()
        lastRefresh.removeAll()
    }

    private func mapError(_ error: MTPError) -> DavError {
        DebugLog.log("mtp error: \(error)")
        switch error.kind {
        case .deviceGone:
            // The handle is dead (unplugged, or re-enumerated underneath us).
            // Forget it so the next request reconnects instead of failing
            // forever against a volume that still looks mounted.
            invalidateSession()
            return .unavailable
        case .deviceBusy:
            return .unavailable
        // A USB failure (timeout, pipe error, stalled endpoint) means the link
        // is unhealthy — "unplugged or wedged, retry". Reporting 403 here made
        // Finder tell the user they lacked *permission* to their own tablet,
        // which is both wrong and undiagnosable: the app could never tell
        // "replug your cable" from "you may not write here".
        case .usb, .protocolViolation:
            return .unavailable
        case .notSupported:
            return .notSupported
        case .response(let code):
            switch code {
            case .storeFull:
                return .insufficientStorage
            case .objectWriteProtected, .storeReadOnly, .accessDenied:
                return .forbidden
            case .invalidObjectHandle, .invalidParentObject, .invalidStorageID:
                return .notFound
            case .deviceBusy, .sessionAlreadyOpen, .sessionNotOpen,
                 .transactionCancelled, .incompleteTransfer, .generalError:
                return .unavailable
            case .operationNotSupported, .objectPropNotSupported, .parameterNotSupported:
                return .notSupported
            default:
                // Unknown device verdict: a retryable server-side failure, not
                // an authorisation one.
                return .unavailable
            }
        }
    }

    // MARK: - Tree resolution

    private func isJunkName(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == ".Trashes"
            || name == ".Spotlight-V100" || name == ".fseventsd"
            || name == ".TemporaryItems" || name == ".metadata_never_index"
    }

    private func children(of container: Container) async throws -> [String: Node] {
        if let cached = childrenCache[container] { return cached }
        let device = try await connectedDevice()
        let storageID: UInt32
        let parentHandle: UInt32
        switch container {
        case .storageRoot(let id):
            storageID = id
            parentHandle = PTP.rootParentHandle
        case .folder(let handle):
            // Find the folder's storage from any cached node; fall back to
            // asking the device.
            let info = try await device.objectInfo(handle)
            storageID = info.storageID
            parentHandle = handle
        }
        let handles = try await device.objectHandles(storageID: storageID, parentHandle: parentHandle)
        var out = [String: Node]()
        // One failed per-object query must not be baked into a cached listing.
        // `try? ... else { continue }` below would otherwise record a folder as
        // "does not contain Download" for the rest of the session — a permanent
        // 404 for a folder that is plainly on the device.
        var incomplete = false
        for handle in handles {
            guard let info = try? await device.objectInfo(handle) else {
                incomplete = true
                continue
            }
            var size = UInt64(info.compressedSize)
            if info.sizeNeedsPropQuery, !info.isFolder {
                size = (try? await device.objectSize64(handle)) ?? size
            }
            var name = info.filename.isEmpty ? "object-\(handle)" : info.filename
            while out[name] != nil { name = "_" + name }
            out[name] = Node(
                handle: handle, storageID: info.storageID, isDirectory: info.isFolder,
                size: size, modified: info.dateModified, created: info.dateCreated
            )
        }
        // Staging leftovers: a crash between "stage" and "swap" leaves a
        // hidden object on the device that no Finder window shows and no user
        // will ever delete. Anything under the staging prefix that no
        // in-flight write owns is by definition stale — sweep it while we are
        // already paying for a listing. Owned names are skipped: they belong
        // to a write running concurrently in this actor.
        var staleKeys = [String]()
        for (name, _) in out where (name.hasPrefix(Self.stagingPrefix) || name.hasPrefix(Self.legacyStagingPrefix)) && !staging.contains(name) {
            staleKeys.append(name)
        }
        for name in staleKeys {
            guard let node = out[name] else { continue }
            do {
                try await device.deleteObject(node.handle)
                out.removeValue(forKey: name)
                DebugLog.log("children: swept stale staging object \(name)")
            } catch {
                // Keep it listed so a later listing retries the sweep.
                DebugLog.log("children: stale staging object \(name) not removable: \(error)")
            }
        }
        if !incomplete {
            childrenCache[container] = out
        } else {
            DebugLog.log("children: \(handles.count) handles but \(out.count) resolved — "
                + "not caching partial listing for \(container)")
        }
        return out
    }

    /// Case- and normalization-insensitive child lookup.
    ///
    /// macOS sends NFD and resolves names case-insensitively (APFS semantics);
    /// MTP devices commonly report NFC and keep the device's own casing. A raw
    /// `Dictionary` lookup 404s files that exist — an independent cause of
    /// "folder not found" for e.g. `Download` vs `download`. Exact match stays
    /// the fast path; only a miss pays for the scan.
    private func lookupKey(_ name: String, in siblings: [String: Node]) -> String? {
        if siblings[name] != nil { return name }
        let target = name.precomposedStringWithCanonicalMapping
        if siblings[target] != nil { return target }
        let folded = target.folding(options: [.caseInsensitive], locale: nil)
        for key in siblings.keys {
            let candidate = key.precomposedStringWithCanonicalMapping
                .folding(options: [.caseInsensitive], locale: nil)
            if candidate == folded { return key }
        }
        return nil
    }

    private func lookupChild(_ name: String, in siblings: [String: Node]) -> Node? {
        guard let key = lookupKey(name, in: siblings) else { return nil }
        return siblings[key]
    }

    /// Sibling lookup that trusts the cache only when it can rule out a
    /// collision. A PUT to a name the cache has never seen must confirm the
    /// device really lacks that name — otherwise a case- or timing-differing
    /// existing file gets a second object instead of an overwrite.
    /// `confirmMiss` is set by callers that only care about the miss case, so
    /// a hit costs nothing and a miss re-enumerates at most once per 5 s.
    private func freshChildren(of container: Container, confirmMiss: Bool) async throws -> [String: Node] {
        var siblings = try await children(of: container)
        if confirmMiss, Date().timeIntervalSince(lastRefresh[container] ?? .distantPast) > 5 {
            lastRefresh[container] = Date()
            childrenCache.removeValue(forKey: container)
            siblings = try await children(of: container)
        }
        return siblings
    }

    private enum Resolved {
        case root
        case storage(String, MTPStorageInfo)
        case node(Node)
    }

    private func resolve(_ path: [String]) async throws -> Resolved {
        if path.isEmpty { return .root }
        let dev = try await connectedDevice()
        if storagesByName.isEmpty { try await loadStorages(from: dev, attempts: 1) }
        guard let storage = storagesByName[path[0]] else { throw DavError.notFound }
        if path.count == 1 { return .storage(path[0], storage) }

        var container = Container.storageRoot(storage.storageID)
        var node: Node?
        for segment in path.dropFirst() {
            var siblings = try await children(of: container)
            var found = lookupChild(segment, in: siblings)
            // The cache may predate the device publishing this entry — Android
            // publishes Download/DCIM asynchronously, often after the first
            // listing at mount time. Drop it and ask once more before
            // declaring the path missing. Bounded on both axes: junk probes
            // (.DS_Store, ._*) are constant, and Finder fires them constantly,
            // so they never trigger a re-enumeration; everything else retries
            // at most once per container per short window, because each
            // re-enumeration costs one MTP round-trip per object.
            if found == nil, !isJunkName(segment),
               Date().timeIntervalSince(lastRefresh[container] ?? .distantPast) > 5 {
                lastRefresh[container] = Date()
                childrenCache.removeValue(forKey: container)
                siblings = try await children(of: container)
                found = lookupChild(segment, in: siblings)
            }
            guard let hit = found else { throw DavError.notFound }
            node = hit
            container = .folder(hit.handle)
        }
        return .node(node!)
    }

    /// Parent container + final name for a path (for create/delete/move).
    private func resolveParent(_ path: [String]) async throws -> (Container, String) {
        guard let name = path.last else { throw DavError.forbidden }
        let parentPath = Array(path.dropLast())
        switch try await resolve(parentPath) {
        case .root:
            throw DavError.forbidden // nothing real lives beside the storages
        case .storage(_, let info):
            return (.storageRoot(info.storageID), name)
        case .node(let node):
            guard node.isDirectory else { throw DavError.conflict }
            return (.folder(node.handle), name)
        }
    }

    private func storageID(of container: Container) -> UInt32? {
        switch container {
        case .storageRoot(let id): return id
        case .folder(let handle):
            for nodes in childrenCache.values {
                for node in nodes.values where node.handle == handle {
                    return node.storageID
                }
            }
            return nil
        }
    }

    private func parentHandle(of container: Container) -> UInt32 {
        switch container {
        case .storageRoot: return PTP.rootParentHandle
        case .folder(let handle): return handle
        }
    }

    private func shadowKey(_ path: [String]) -> String {
        path.joined(separator: "/")
    }

    /// Maps a client-visible path to the internal storage-prefixed path.
    private func internalPath(_ path: [String]) async throws -> [String] {
        _ = try await connectedDevice()
        if let sole = soleStorageName {
            return [sole] + path
        }
        return path
    }

    // MARK: - DavBackend

    /// A zero-byte file at the volume root that tells Spotlight never to index
    /// this volume. Without it, Spotlight recursively walks the whole device
    /// over MTP, and since MTP serves one command at a time, that background
    /// index starves all foreground browsing — the volume looks frozen.
    static let neverIndexFile = ".metadata_never_index"

    func stat(path clientPath: [String]) async throws -> DavEntry {
        // Answer this synthetically and instantly, before touching the device.
        if clientPath == [Self.neverIndexFile] {
            return DavEntry(name: Self.neverIndexFile, isDirectory: false, size: 0)
        }
        if clientPath == [".VolumeIcon.icns"], let icon = volumeIcon {
            return DavEntry(name: ".VolumeIcon.icns", isDirectory: false, size: UInt64(icon.count), modified: Date(), created: Date())
        }
        do {
            _ = try await connectedDevice()
            // The flattened root is the device itself.
            if clientPath.isEmpty, soleStorageName != nil {
                return DavEntry(name: deviceName, isDirectory: true, size: 0)
            }
            let path = try await internalPath(clientPath)
            return try await statInternal(path: path)
        } catch let error as MTPError {
            throw mapError(error)
        }
    }

    private func statInternal(path: [String]) async throws -> DavEntry {
        if let name = path.last {
            if let data = shadow[shadowKey(path)] {
                return DavEntry(name: name, isDirectory: false, size: UInt64(data.count), modified: Date())
            }
            if isJunkName(name) { throw DavError.notFound }
        }
        switch try await resolve(path) {
        case .root:
            return DavEntry(name: deviceName, isDirectory: true, size: 0)
        case .storage(let name, _):
            return DavEntry(name: name, isDirectory: true, size: 0)
        case .node(let node):
            return DavEntry(
                name: path.last ?? "", isDirectory: node.isDirectory,
                size: node.size, modified: node.modified, created: node.created
            )
        }
    }

    func list(path clientPath: [String]) async throws -> [DavEntry] {
        do {
            let dev = try await connectedDevice()
            if storagesByName.isEmpty { try await loadStorages(from: dev, attempts: 3) }
            let path = try await internalPath(clientPath)
            switch try await resolve(path) {
            case .root:
                var entries = storagesByName.keys.sorted().map {
                    DavEntry(name: $0, isDirectory: true, size: 0)
                }
                if let icon = volumeIcon {
                    entries.append(DavEntry(name: ".VolumeIcon.icns", isDirectory: false,
                                            size: UInt64(icon.count), modified: Date(), created: Date()))
                }
                return entries
            case .storage(_, let info):
                let nodes = try await children(of: .storageRoot(info.storageID))
                var entries = entries(from: nodes)
                if let icon = volumeIcon {
                    entries.append(DavEntry(name: ".VolumeIcon.icns", isDirectory: false,
                                            size: UInt64(icon.count), modified: Date(), created: Date()))
                }
                return entries
            case .node(let node):
                guard node.isDirectory else { throw DavError.notFound }
                let nodes = try await children(of: .folder(node.handle))
                return entries(from: nodes)
            }
        } catch let error as MTPError {
            throw mapError(error)
        }
    }

    private func entries(from nodes: [String: Node]) -> [DavEntry] {
        nodes.map { name, node in
            DavEntry(name: name, isDirectory: node.isDirectory, size: node.size, modified: node.modified, created: node.created)
        }.sorted { $0.name < $1.name }
    }

    func read(path clientPath: [String], offset: UInt64, length: Int) async throws -> Data {
        if clientPath == [Self.neverIndexFile] { return Data() }
        if clientPath == [".VolumeIcon.icns"], let icon = volumeIcon {
            guard offset < UInt64(icon.count) else { return Data() }
            let start = Int(offset)
            let end = min(start + length, icon.count)
            return icon.subdata(in: start..<end)
        }
        let path = try await internalPath(clientPath)
        if let data = shadow[shadowKey(path)] {
            guard offset < UInt64(data.count) else { return Data() }
            let start = Int(offset)
            return data.subdata(in: start..<min(start + length, data.count))
        }
        guard case .node(let node) = try await resolve(path), !node.isDirectory else {
            throw DavError.notFound
        }
        guard offset < node.size else { return Data() }
        let device = try await connectedDevice()
        do {
            let want = Int(min(UInt64(length), node.size - offset))
            return try await device.readObject(handle: node.handle, offset: offset, length: want)
        } catch let error as MTPError {
            throw mapError(error)
        }
    }

    func write(path clientPath: [String], contentsOf url: URL) async throws {
        let path = try await internalPath(clientPath)
        guard let name = path.last else { throw DavError.forbidden }

        // The volume icon is served synthetically; never let a client replace
        // or delete it (it would only confuse Finder's icon cache).
        if name == ".VolumeIcon.icns" { throw DavError.forbidden }

        // Junk never reaches the device.
        if isJunkName(name) {
            let data = (try? Data(contentsOf: url)) ?? Data()
            guard data.count <= Self.shadowFileCap,
                  shadow.values.reduce(0, { $0 + $1.count }) + data.count <= Self.shadowTotalCap else {
                throw DavError.insufficientStorage
            }
            shadow[shadowKey(path)] = data
            return
        }

        let (container, filename) = try await resolveParent(path)
        guard let storageID = storageID(of: container) else { throw DavError.conflict }
        let device = try await connectedDevice()
        // A failed size lookup must never be read as 0: `sendObject` would
        // then upload only the 12-byte PTP header and report success for a
        // file that is empty on the device.
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 else {
            throw DavError.unavailable
        }

        do {
            let siblings = try await freshChildren(of: container, confirmMiss: true)
            if let key = lookupKey(filename, in: siblings), let existing = siblings[key] {
                guard !existing.isDirectory else { throw DavError.exists }
                try await replace(
                    existing, key: key, container: container, filename: filename,
                    storageID: storageID, device: device, url: url, size: size
                )
            } else {
                let handle = try await device.sendObject(
                    storageID: storageID, parentHandle: parentHandle(of: container),
                    name: filename, fileURL: url, size: size, modified: Date()
                )
                childrenCache[container]?[filename] = Node(
                    handle: handle, storageID: storageID, isDirectory: false,
                    size: size, modified: Date(), created: Date()
                )
            }
        } catch let error as MTPError {
            // The cached listing no longer describes the device: a staging
            // object may exist, or the original may have been renamed.
            childrenCache.removeValue(forKey: container)
            throw mapError(error)
        }
    }

    /// Overwrite with no data-loss window.
    ///
    /// MTP has no overwrite primitive, so replacing a file used to mean
    /// *delete the old object, then send the new one*. Any failure in
    /// `sendObject` — USB timeout, store full, the wedged state this device
    /// reaches after a failed write — destroyed the user's original file
    /// while writing nothing in its place: permanent loss, acknowledged only
    /// by an HTTP error.
    ///
    /// Instead: stage the new bytes under a temporary name, move the original
    /// aside (still on the device, only renamed), swap the names, and delete
    /// the original last. Every failure point either leaves the original
    /// exactly where it was or restores it by rename, so a failed overwrite
    /// can no longer cost the user their file.
    private func replace(
        _ existing: Node, key: String, container: Container, filename: String,
        storageID: UInt32, device: MTPDevice, url: URL, size: UInt64
    ) async throws {
        let sendNew = { (name: String) async throws -> UInt32 in
            try await device.sendObject(
                storageID: storageID, parentHandle: self.parentHandle(of: container),
                name: name, fileURL: url, size: size, modified: Date()
            )
        }

        // Devices that do not advertise SetObjectPropValue cannot rename
        // (MTPDevice.renameObject checks exactly this), so the staged sequence
        // is unavailable and the legacy order is the only one they support.
        guard await device.info?.supports(.setObjectPropValue) == true else {
            try await device.deleteObject(existing.handle)
            let handle = try await sendNew(filename)
            childrenCache[container]?[key] = Node(
                handle: handle, storageID: storageID, isDirectory: false,
                size: size, modified: Date(), created: Date()
            )
            return
        }

        let tag = Self.stagingPrefix + UUID().uuidString.prefix(8)
        let stagedName = tag + "-" + filename
        let asideName = tag + "-old"
        staging.insert(stagedName)
        staging.insert(asideName)
        defer { staging.remove(stagedName); staging.remove(asideName) }

        // 1. New bytes land on the device under a temporary name. The
        //    original is untouched, so a failed upload costs a partial
        //    staging object (swept by the next listing) and nothing else.
        let staged = try await sendNew(stagedName)

        // 2. Move the original aside — it stays on the device, recoverable.
        try await device.renameObject(existing.handle, to: asideName)

        do {
            // 3. The real name is free now; give the new copy its name.
            try await device.renameObject(staged, to: filename)
        } catch {
            // Roll back: the user's original file returns to its own name and
            // the staging copy is dropped. Nothing is lost either way.
            _ = try? await device.renameObject(existing.handle, to: key)
            _ = try? await device.deleteObject(staged)
            childrenCache.removeValue(forKey: container)
            throw error
        }

        // 4. Only now is destroying the original safe. If this line fails the
        //    user's file is already correct at the right name; the leftover is
        //    hidden and swept by a later listing.
        do {
            try await device.deleteObject(existing.handle)
        } catch {
            DebugLog.log("write: new copy in place but old object \(key) not removed: \(error)")
        }
        childrenCache[container]?[key] = Node(
            handle: staged, storageID: storageID, isDirectory: false,
            size: size, modified: Date(), created: Date()
        )
    }

    func delete(path clientPath: [String]) async throws {
        let path = try await internalPath(clientPath)
        if shadow.removeValue(forKey: shadowKey(path)) != nil { return }
        let (container, name) = try await resolveParent(path)
        guard let node = try await children(of: container)[name] else { throw DavError.notFound }
        let device = try await connectedDevice()
        do {
            try await device.deleteObject(node.handle)
        } catch let error as MTPError {
            throw mapError(error)
        }
        childrenCache[container]?.removeValue(forKey: name)
        if node.isDirectory {
            childrenCache.removeValue(forKey: .folder(node.handle))
        }
    }

    func makeDirectory(path clientPath: [String]) async throws {
        let path = try await internalPath(clientPath)
        let (container, name) = try await resolveParent(path)
        guard let storageID = storageID(of: container) else { throw DavError.conflict }
        guard try await children(of: container)[name] == nil else { throw DavError.exists }
        let device = try await connectedDevice()
        do {
            let handle = try await device.createFolder(
                storageID: storageID, parentHandle: parentHandle(of: container), name: name
            )
            childrenCache[container]?[name] = Node(
                handle: handle, storageID: storageID, isDirectory: true,
                size: 0, modified: Date(), created: Date()
            )
            childrenCache[.folder(handle)] = [:]
        } catch let error as MTPError {
            throw mapError(error)
        }
    }

    func move(from clientFrom: [String], to clientTo: [String]) async throws {
        let from = try await internalPath(clientFrom)
        let to = try await internalPath(clientTo)
        // Shadow entries just move in RAM.
        if let data = shadow.removeValue(forKey: shadowKey(from)) {
            shadow[shadowKey(to)] = data
            return
        }
        let (fromContainer, fromName) = try await resolveParent(from)
        let (toContainer, toName) = try await resolveParent(to)
        guard let node = try await children(of: fromContainer)[fromName] else { throw DavError.notFound }
        guard let toStorage = storageID(of: toContainer), toStorage == node.storageID else {
            // Cross-storage moves would need copy+delete; the kernel client
            // falls back to that itself when MOVE fails.
            throw DavError.forbidden
        }
        let device = try await connectedDevice()
        var reparented = false
        do {
            if fromContainer != toContainer {
                try await device.moveObject(node.handle, toStorage: toStorage, parentHandle: parentHandle(of: toContainer))
                reparented = true
            }
            if fromName != toName {
                try await device.renameObject(node.handle, to: toName)
            }
        } catch let error as MTPError {
            // A move is two device operations (re-parent, then rename). If the
            // second fails, don't leave the file stranded in the wrong folder.
            if reparented {
                try? await device.moveObject(node.handle, toStorage: toStorage, parentHandle: parentHandle(of: fromContainer))
            }
            childrenCache[fromContainer] = nil
            childrenCache[toContainer] = nil
            throw mapError(error)
        }
        childrenCache[fromContainer]?.removeValue(forKey: fromName)
        var moved = node
        moved.modified = Date()
        childrenCache[toContainer]?[toName] = moved
    }

    func quota() async throws -> (total: UInt64, free: UInt64) {
        do {
            _ = try await connectedDevice()
            var total: UInt64 = 0
            var free: UInt64 = 0
            for storage in storagesByName.values {
                total += storage.maxCapacity
                free += storage.freeSpace
            }
            return (total, free)
        } catch let error as MTPError {
            throw mapError(error)
        }
    }
}
