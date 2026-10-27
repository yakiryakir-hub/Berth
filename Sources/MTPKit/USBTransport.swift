import Foundation
import IOKit
import IOKit.usb
import CBerthUSB

/// Raw bulk/interrupt USB plumbing for one MTP interface. Owns the exclusive
/// open on the interface; creating a second transport for the same device fails.
///
/// Built on Apple's IOUSBLib (IOUSBInterfaceInterface) through a small C shim,
/// the same user-space API libusb uses on macOS. The IOUSBHostInterface path
/// this replaced never delivered bulk-out data to the Pixel 10 Pro, while the
/// libusb path did; see HANDOFF.md section 22.
///
/// The shim's calls block, so each runs on a dedicated queue: bulk transfers
/// on one serial queue, the interrupt (event) pipe on another so a long event
/// wait never delays a bulk transaction. Serialization of whole MTP
/// transactions is the caller's job (MTPDevice actor).
public final class USBTransport: @unchecked Sendable {

    /// Sendable box for the C handle. Access is serialized by the queues.
    private struct Handle: @unchecked Sendable { let raw: OpaquePointer }

    private let handle: Handle
    private let bulkQueue = DispatchQueue(label: "berth.usb.bulk", qos: .userInitiated)
    private let eventQueue = DispatchQueue(label: "berth.usb.event", qos: .utility)
    private let hasInterrupt: Bool
    public let maxPacketSize: Int

    /// Opens the MTP interface for the given IOKit service. The service must be
    /// an IOUSBHostInterface registry entry. Exclusive-access failure here means
    /// another process (ptpcamera, Android File Transfer) holds the device.
    public init(interfaceService: io_service_t) throws {
        // macOS starts ptpcamerad / mscamerad-xpc on demand for any device
        // exposing a Still Image (MTP/PTP) interface; release them before we
        // claim it. They are respawned later, so this is non-destructive.
        USBTransport.releaseImageCaptureDaemons()

        // Experiment flags (read from /tmp/berth_exp): nodevopen, seize
        let exp = (try? String(contentsOfFile: "/tmp/berth_exp", encoding: .utf8)) ?? ""
        var flags: Int32 = exp.contains("nodevopen") ? 0 : Int32(BERTH_USB_OPEN_DEVICE)
        if exp.contains("seize") { flags |= Int32(BERTH_USB_SEIZE_DEVICE) }

        var raw: OpaquePointer?
        let kr = berth_usb_open(interfaceService, flags, &raw)
        guard kr == kIOReturnSuccess, let raw else {
            if kr == kIOReturnExclusiveAccess {
                throw MTPError(.deviceBusy("another process has claimed the device (Image Capture, Photos, or Android File Transfer)"))
            }
            throw MTPError(.usb("open interface failed: IOReturn 0x\(String(UInt32(bitPattern: kr), radix: 16))"))
        }
        self.handle = Handle(raw: raw)

        let inAddr = berth_usb_bulk_in_address(raw)
        let outAddr = berth_usb_bulk_out_address(raw)
        let intAddr = berth_usb_interrupt_in_address(raw)
        let devStatus = berth_usb_device_status(raw)
        MTPTrace.log("iousblib open: iface=\(berth_usb_interface_number(raw)) bulkIn=0x\(String(inAddr, radix: 16)) "
            + "bulkOut=0x\(String(outAddr, radix: 16)) int=0x\(String(intAddr, radix: 16)) "
            + "maxPacketIn=\(berth_usb_max_packet_in(raw)) speed=\(berth_usb_device_speed(raw)) "
            + "deviceOpen=\(flags & 1 != 0 ? (devStatus == kIOReturnSuccess ? "ok" : "0x\(String(UInt32(bitPattern: devStatus), radix: 16))") : "off")")
        MTPTrace.note("iousblib open ok (deviceOpen status 0x\(String(UInt32(bitPattern: devStatus), radix: 16)), flags \(flags))")

        guard inAddr != 0, outAddr != 0 else {
            berth_usb_close(raw)
            throw MTPError(.usb("interface has no bulk endpoints; not an MTP data interface"))
        }
        self.hasInterrupt = intAddr != 0
        let mps = Int(berth_usb_max_packet_in(raw))
        self.maxPacketSize = mps > 0 ? mps : 512
    }

    deinit {
        berth_usb_close(handle.raw)
    }

    /// Kills macOS' on-demand Image Capture daemons so they release the MTP
    /// interface before we claim it. Safe: macOS respawns them on demand.
    static func releaseImageCaptureDaemons() {
        // One pkill with an alternation (-x matches the whole name) instead of
        // three process spawns, and a short settle instead of 300 ms.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-9", "-x", "ptpcamerad|mscamerad-xpc|mscamerad"]
        do { try p.run(); p.waitUntilExit() } catch { /* not running */ }
        usleep(100_000)
    }

    // MARK: - Bulk I/O

    /// Writes the whole buffer to bulk-out.
    public func write(_ data: Data, timeout: TimeInterval) async throws {
        try await transferOut(Array(data), timeout: timeout)
    }

    /// Sends a zero-length packet on bulk-out (data phase whose size is an
    /// exact multiple of the packet size needs one as terminator).
    public func writeZeroLengthPacket(timeout: TimeInterval) async throws {
        try await transferOut([], timeout: timeout)
    }

    /// Reads up to `maxLength` from bulk-in. Returns whatever one transfer
    /// yields: a bulk read completes on a short packet or a full buffer.
    public func read(maxLength: Int, timeout: TimeInterval) async throws -> Data {
        // IOUSBLib wants the buffer sized to whole packets, or a full final
        // packet overruns it.
        let packet = max(maxPacketSize, 1)
        let size = ((max(maxLength, 1) + packet - 1) / packet) * packet
        let bytes = try await transferIn(size: size, timeout: timeout)
        return Data(bytes)
    }

    /// Reads one interrupt-in event transfer, if the device has an event pipe.
    /// Blocks until an event arrives; run from a dedicated task.
    public func readEvent(maxLength: Int = 64) async throws -> Data {
        guard hasInterrupt else {
            throw MTPError(.notSupported("device has no interrupt endpoint"))
        }
        let h = handle
        let (kr, bytes): (IOReturn, [UInt8]) = await withCheckedContinuation { cont in
            eventQueue.async {
                var buffer = [UInt8](repeating: 0, count: max(maxLength, 8))
                var done: UInt32 = 0
                let kr = buffer.withUnsafeMutableBytes {
                    berth_usb_read_interrupt(h.raw, $0.baseAddress, UInt32($0.count), &done)
                }
                cont.resume(returning: (kr, Array(buffer.prefix(Int(done)))))
            }
        }
        if kr != kIOReturnSuccess { throw Self.mapError(kr, pipe: "interrupt", bytes: bytes.count) }
        return Data(bytes)
    }

    /// Discards any bytes left in the bulk-in pipe by a previous client that
    /// died mid-transaction, then clears endpoint stalls. Run before opening
    /// a session or stale containers masquerade as replies.
    public func drainStale() async {
        while true {
            guard let leftover = try? await read(maxLength: 64 << 10, timeout: 0.25), !leftover.isEmpty else { break }
        }
        clearStalls()
    }

    public func clearStalls() {
        let h = handle
        bulkQueue.sync {
            _ = berth_usb_abort_bulk(h.raw)
            _ = berth_usb_clear_stalls(h.raw)
        }
    }

    /// Experimental: PTP class requests (0x66 Device Reset, 0x67 Get Device Status).
    public func ptpClassRequest(reset: Bool) {
        let h = handle
        let index = UInt16(berth_usb_interface_number(h.raw))
        var buffer = [UInt8](repeating: 0, count: 4)
        var done: UInt32 = 0
        let kr = buffer.withUnsafeMutableBytes {
            berth_usb_control(h.raw, reset ? 0x21 : 0xA1, reset ? 0x66 : 0x67, 0, index,
                              reset ? nil : $0.baseAddress, reset ? 0 : 4, 2000, &done)
        }
        MTPTrace.note("class request \(reset ? "reset" : "status") \(kr == kIOReturnSuccess ? "ok (\(done) bytes)" : "failed: IOReturn 0x\(String(UInt32(bitPattern: kr), radix: 16))")")
    }

    public func abortEventPipe() {
        _ = berth_usb_abort_interrupt(handle.raw)
    }

    // MARK: - Plumbing

    private func transferOut(_ payload: [UInt8], timeout: TimeInterval) async throws {
        let ms = UInt32(max(timeout, 0) * 1000)
        var attempt = 0
        while true {
            let h = handle
            let kr: IOReturn = await withCheckedContinuation { cont in
                bulkQueue.async {
                    var done: UInt32 = 0
                    let kr = payload.withUnsafeBytes {
                        berth_usb_write(h.raw, $0.baseAddress, UInt32($0.count), ms, &done)
                    }
                    cont.resume(returning: kr)
                }
            }
            if kr == kIOReturnSuccess { return }
            // A stalled pipe (left by a client that died mid-transfer) is
            // cleared and retried once rather than forcing a replug.
            if Self.isStall(kr), attempt == 0 {
                attempt += 1
                clearStalls()
                continue
            }
            throw Self.mapError(kr, pipe: "bulk-out", bytes: 0)
        }
    }

    private func transferIn(size: Int, timeout: TimeInterval) async throws -> [UInt8] {
        let ms = UInt32(max(timeout, 0) * 1000)
        var attempt = 0
        while true {
            let h = handle
            let (kr, bytes): (IOReturn, [UInt8]) = await withCheckedContinuation { cont in
                bulkQueue.async {
                    var buffer = [UInt8](repeating: 0, count: size)
                    var done: UInt32 = 0
                    let kr = buffer.withUnsafeMutableBytes {
                        berth_usb_read_bulk(h.raw, $0.baseAddress, UInt32($0.count), ms, &done)
                    }
                    cont.resume(returning: (kr, Array(buffer.prefix(Int(done)))))
                }
            }
            if kr == kIOReturnSuccess { return bytes }
            if Self.isStall(kr), attempt == 0 {
                attempt += 1
                clearStalls()
                continue
            }
            throw Self.mapError(kr, pipe: "bulk-in", bytes: bytes.count)
        }
    }

    private static func isStall(_ kr: IOReturn) -> Bool {
        UInt32(bitPattern: kr) == 0xE000_404F // kIOUSBPipeStalled
    }

    private static func mapError(_ kr: IOReturn, pipe: String, bytes: Int) -> MTPError {
        if kr == kIOReturnAborted || kr == kIOReturnNotResponding || kr == kIOReturnNoDevice || UInt32(bitPattern: kr) == 0xe00002d9 {
            return MTPError(.deviceGone)
        }
        return MTPError(.usb("transfer failed: IOReturn 0x\(String(UInt32(bitPattern: kr), radix: 16)) on \(pipe) (\(bytes) bytes done)"))
    }
}
