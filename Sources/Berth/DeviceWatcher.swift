import Foundation
import IOKit
import IOKit.usb
import MTPKit

/// Watches the IO registry for MTP interfaces coming and going. Callbacks
/// arrive on the main queue with a full current-device snapshot; diffing is
/// the caller's job.
@MainActor
final class DeviceWatcher {
    var onChange: (@MainActor ([MTPDeviceRef]) -> Void)?
    /// Android devices present but not offering MTP (locked / Charging only).
    /// Fires for every USB interface arrival/departure, before any debouncing.
    var onEvent: (@MainActor () -> Void)?
    var onHint: (@MainActor ([String]) -> Void)?

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    /// Last snapshot we published. A scan that fails (registry mid-
    /// re-enumeration) must not be published as "no devices" — we keep the
    /// previous snapshot and wait for a scan that actually completes. This
    /// is the first line of defence against a transient scan miss turning
    /// into a force-unmount.
    private var lastPublished: [MTPDeviceRef]?

    func start() {
        let port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            // Drain or the notification never re-arms.
            while case let service = IOIteratorNext(iterator), service != 0 {
                IOObjectRelease(service)
            }
            guard let context else { return }
            let watcher = Unmanaged<DeviceWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                watcher.publish()
            }
        }

        // Two registrations, same callback: any USB interface arriving or
        // departing triggers a rescan. Filtering to MTP happens in the scan.
        IOServiceAddMatchingNotification(
            port, kIOMatchedNotification,
            IOServiceMatching("IOUSBHostInterface"),
            callback, context, &addedIterator
        )
        IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification,
            IOServiceMatching("IOUSBHostInterface"),
            callback, context, &removedIterator
        )
        // Prime both iterators (required to arm) and publish the initial state.
        drain(addedIterator)
        drain(removedIterator)
        publish()
    }

    /// Force a fresh scan (after wake from sleep the registry can settle late).
    func rescan() { publish() }

    func stop() {
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    private func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    private func publish() {
        onEvent?()
        let result = MTPDeviceLocator.scan()
        guard !result.failed else {
            DebugLog.log("DeviceWatcher: scan failed; keeping last snapshot")
            return
        }
        // If the registry reports an empty set but we had devices moments ago,
        // treat it as a failed scan: a single transient miss must not look like
        // "device unplugged". The next successful scan wins.
        if result.devices.isEmpty, let last = lastPublished, !last.isEmpty {
            // Don't trust one empty scan, but don't trust it forever either:
            // nothing re-fires after a device's interfaces silently vanish
            // (e.g. the tablet falls back to "Charging only"), which used to
            // leave a ghost device in the menu with a dead mount. Re-scan a
            // few times; if the registry stays empty, accept it.
            // Time-based, not count-based: bursts of USB events must not
            // shorten the wait. Re-enumeration normally returns within a
            // fraction of a second; a real unplug stays gone.
            let since = emptySince ?? Date()
            emptySince = since
            let waited = Date().timeIntervalSince(since)
            if waited < Self.absenceConfirm {
                DebugLog.log("DeviceWatcher: device absent \(Int(waited * 1000)) ms; confirming")
                recheck?.cancel()
                let remaining = Self.absenceConfirm - waited
                recheck = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(remaining + 0.02))
                    guard !Task.isCancelled else { return }
                    self?.publish()
                }
                return
            }
            DebugLog.log("DeviceWatcher: registry stayed empty; accepting device removal")
        }
        emptySince = nil
        recheck?.cancel()
        recheck = nil
        lastPublished = result.devices
        onHint?(MTPDeviceLocator.androidDevicesWithoutMTP())
        onChange?(result.devices)
    }

    /// How long a device must stay absent before "no devices" is believed over
    /// the last snapshot.
    private static let absenceConfirm: TimeInterval = 0.6
    private var emptySince: Date?
    private var recheck: Task<Void, Never>?
}
