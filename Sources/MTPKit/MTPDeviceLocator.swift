import Foundation
import IOKit
import IOKit.usb

/// A connected MTP-capable device, discovered from the IO registry without
/// opening anything. Safe to build from any process; opening the interface
/// (USBTransport) is what takes exclusive access.
public struct MTPDeviceRef: Sendable, Equatable, Hashable {
    public let serial: String
    public let name: String
    public let vendorID: Int
    public let productID: Int
    public let locationID: UInt32

    public init(serial: String, name: String, vendorID: Int, productID: Int, locationID: UInt32) {
        self.serial = serial
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
    }

    /// Stable identity for mount URLs: serial when the device provides one,
    /// otherwise vid/pid/port location.
    public var urlHost: String {
        if !serial.isEmpty { return serial }
        return String(format: "%04x.%04x.%08x", vendorID, productID, locationID)
    }

    /// Identity is the mount host: the same physical device keeps the same
    /// identity across replugs, even though its USB locationID changes. Without
    /// this, a replug looks like one device leaving and a different one
    /// arriving, desyncing mount state from the device list.
    public static func == (lhs: MTPDeviceRef, rhs: MTPDeviceRef) -> Bool {
        lhs.urlHost == rhs.urlHost
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(urlHost)
    }

    public var mtpURL: URL {
        URL(string: "mtp://\(urlHost)")!
    }
}

public enum MTPDeviceLocator {

    /// Still Image class / PTP subclass / PTP protocol — the standard MTP
    /// interface triple.
    private static let mtpClassTriples: [(UInt8, UInt8, UInt8)] = [
        (6, 1, 1)
    ]

    /// Many devices (Kindle Paperwhite: 255/255/0) expose MTP as a
    /// vendor-specific interface instead, marked only by the interface name
    /// string "MTP".
    private static func isVendorMTP(class cls: UInt8, interfaceName: String?) -> Bool {
        cls == 0xFF && interfaceName?.uppercased() == "MTP"
    }

    /// All MTP-capable interfaces currently in the IO registry.
    ///
    /// A failed scan (IOServiceGetMatchingServices returning non-success) is
    /// reported distinctly from "no devices present". The caller must not treat
    /// a failed scan as an empty device list: during USB re-enumeration the
    /// registry transiently fails to enumerate, and acting on that as "the
    /// device is gone" used to force-unmount a live volume and close the MTP
    /// session seconds after a healthy mount.
    public static func scan() -> (devices: [MTPDeviceRef], failed: Bool) {
        var found = [MTPDeviceRef]()
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOUSBHostInterface")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return ([], true)
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let ref = deviceRef(forInterfaceService: service) {
                if !found.contains(ref) { found.append(ref) }
            }
        }
        return (found, false)
    }

    public static func connectedDevices() -> [MTPDeviceRef] {
        scan().devices
    }

    /// The io_service_t for the MTP interface of the device with the given URL
    /// host identity. Caller owns the returned reference (IOObjectRelease).
    public static func findInterfaceService(urlHost: String) -> io_service_t? {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOUSBHostInterface")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            if let ref = deviceRef(forInterfaceService: service), ref.urlHost == urlHost {
                return service // transfer ownership
            }
            IOObjectRelease(service)
        }
        return nil
    }

    private static func deviceRef(forInterfaceService service: io_service_t) -> MTPDeviceRef? {
        guard let cls: Int = property(service, "bInterfaceClass"),
              let sub: Int = property(service, "bInterfaceSubClass"),
              let proto: Int = property(service, "bInterfaceProtocol") else {
            return nil
        }
        let interfaceName: String? = property(service, "kUSBString") ?? property(service, "USB Interface Name")
        let standardMTP = mtpClassTriples.contains(where: { $0 == (UInt8(cls), UInt8(sub), UInt8(proto)) })
        guard standardMTP || isVendorMTP(class: UInt8(cls), interfaceName: interfaceName) else {
            return nil
        }

        // Identity lives on the parent IOUSBHostDevice node.
        var device: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &device) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(device) }

        let serial: String = property(device, "USB Serial Number") ?? ""
        let product: String = property(device, "USB Product Name") ?? "MTP Device"
        let vendorID: Int = property(device, "idVendor") ?? 0
        let productID: Int = property(device, "idProduct") ?? 0
        let locationID: Int = property(device, "locationID") ?? 0

        return MTPDeviceRef(
            serial: serial, name: product,
            vendorID: vendorID, productID: productID,
            locationID: UInt32(truncatingIfNeeded: locationID)
        )
    }

    // MARK: - Android devices that aren't offering MTP

    /// USB vendor IDs of common Android makers.
    private static let androidVendorIDs: Set<Int> = [
        0x18D1, // Google
        0x04E8, // Samsung
        0x2717, // Xiaomi
        0x2A70, // OnePlus
        0x22B8, // Motorola
        0x054C, // Sony
        0x1004, // LG
        0x12D1, // Huawei
        0x0BB4, // HTC
        0x0B05, // ASUS
        0x22D9, // OPPO
        0x2D95, // vivo
        0x29A9, // Nothing
    ]

    /// Names of Android devices that are plugged in but expose neither MTP nor
    /// mass storage: phone locked, or USB set to "Charging only". Lets the app
    /// say "choose File transfer" instead of silently showing nothing.
    /// Samsung's external SSDs share the vendor ID, so anything with a
    /// mass-storage interface is skipped.
    public static func androidDevicesWithoutMTP() -> [String] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var names = [String]()
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            guard let vendor: Int = property(device, "idVendor"), androidVendorIDs.contains(vendor) else { continue }

            var hasMTPOrStorage = false
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) == KERN_SUCCESS {
                while case let child = IOIteratorNext(children), child != 0 {
                    defer { IOObjectRelease(child) }
                    if let cls: Int = property(child, "bInterfaceClass") {
                        if cls == 8 { hasMTPOrStorage = true } // mass storage
                        if let ref = deviceRef(forInterfaceService: child), !ref.name.isEmpty { hasMTPOrStorage = true }
                    }
                }
                IOObjectRelease(children)
            }
            if hasMTPOrStorage { continue }
            let name: String = property(device, "USB Product Name") ?? "Android device"
            names.append(name)
        }
        return names
    }

    private static func property<T>(_ entry: io_registry_entry_t, _ key: String) -> T? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return value.takeRetainedValue() as? T
    }
}
