import Foundation

/// One MTP session over one USB connection. Actor isolation supplies the
/// protocol's hard rule: a single command in flight at a time. Every public
/// method is one complete command/data/response transaction.
public actor MTPDevice {

    /// Priority lanes so a Finder-blocking metadata call never queues behind a
    /// multi-gigabyte transfer's next chunk. Chunked transfers re-enter the
    /// actor between chunks, giving waiters a gap to slot into.
    private let transport: USBTransport
    private var transactionID: UInt32 = 0
    private var sessionOpen = false
    public private(set) var info: MTPDeviceInfo?

    private let commandTimeout: TimeInterval = 10
    private let dataTimeout: TimeInterval = 30
    /// Per-call ceiling on data-phase transfer size, keeping any single actor
    /// occupancy short. 4 MiB ≈ 100 ms on MTP's realistic wire speed.
    public static let transferChunk = 4 << 20
    /// Upper bound on a device-declared data-in phase.
    private static let maxDataIn = 64 << 20

    public init(transport: USBTransport) {
        self.transport = transport
    }

    // MARK: - Session

    public func connect() async throws -> MTPDeviceInfo {
        // Session setup is several transactions; hold the bus for all of them
        // so a concurrent caller can't interleave mid-handshake.
        await lockBus()
        defer { unlockBus() }
        // Experiments (read from /tmp/berth_exp): nodrain, status, reset
        let exp = (try? String(contentsOfFile: "/tmp/berth_exp", encoding: .utf8)) ?? ""
        MTPTrace.note("connect experiments: '\(exp.trimmingCharacters(in: .whitespacesAndNewlines))'")
        if exp.contains("reset") { transport.ptpClassRequest(reset: true) }
        if exp.contains("status") { transport.ptpClassRequest(reset: false) }
        // A previous client may have died mid-transaction; start clean.
        if exp.contains("drain") { await transport.drainStale() }
        // GetDeviceInfo is legal outside a session. Some devices (notably the
        // Pixel on SuperSpeed) don't answer the very first command right after
        // enumeration; a short retry beats failing the whole mount. We do NOT
        // issue a USB/PTP reset between tries — on Pixels a reset wedges the
        // MTP server until a physical replug (mtp-rs, verified on Pixel 9/10).
        var deviceInfoData = Data()
        var lastError: Error?
        for attempt in 1...4 {
            do {
                deviceInfoData = try await performTransaction(.getDeviceInfo, params: []).data
                lastError = nil
                break
            } catch {
                lastError = error
                MTPTrace.note("GetDeviceInfo attempt \(attempt) failed: \(error)")
                await transport.drainStale()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        if let lastError { throw lastError }
        let parsed = try MTPDeviceInfo.parse(deviceInfoData)
        self.info = parsed

        do {
            _ = try await performTransaction(.openSession, params: [1])
            sessionOpen = true
        } catch let error as MTPError {
            if case .response(.sessionAlreadyOpen) = error.kind {
                // A previous client died without closing. Close and reopen.
                _ = try? await performTransaction(.closeSession, params: [])
                _ = try await performTransaction(.openSession, params: [1])
                sessionOpen = true
            } else {
                throw error
            }
        }
        return parsed
    }

    public func disconnect() async {
        await lockBus()
        defer { unlockBus() }
        if sessionOpen {
            _ = try? await performTransaction(.closeSession, params: [])
            sessionOpen = false
        }
        transport.abortEventPipe()
    }

    // MARK: - Device properties

    /// Samsung (and most Android) devices expose a human-readable name under
    /// MTP device property 0xD402 (DeviceFriendlyName) — e.g. "Galaxy Tab A9"
    /// — while the GetDeviceInfo `Model` field is only the model code
    /// ("SM-X133"). Returns nil when the device does not advertise the op or
    /// the property is absent/unreadable, so callers can fall back to `model`.
    public func deviceFriendlyName() async -> String? {
        guard let info, info.supports(.getDevicePropValue) else { return nil }
        do {
            let reply = try await transact(.getDevicePropValue, params: [0xD402])
            var r = PTPReader(reply.data)
            let value = try r.string()
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            MTPTrace.log("deviceFriendlyName failed: \(error)")
            return nil
        }
    }

    public func storageIDs() async throws -> [UInt32] {
        let data = try await transact(.getStorageIDs, params: []).data
        var r = PTPReader(data)
        return try r.u32Array()
    }

    public func storageInfo(_ storageID: UInt32) async throws -> MTPStorageInfo {
        let data = try await transact(.getStorageInfo, params: [storageID]).data
        return try MTPStorageInfo.parse(data, storageID: storageID)
    }

    // MARK: - Object tree

    public func objectHandles(storageID: UInt32, parentHandle: UInt32) async throws -> [UInt32] {
        let data = try await transact(
            .getObjectHandles,
            params: [storageID, PTP.allFormats, parentHandle]
        ).data
        var r = PTPReader(data)
        return try r.u32Array()
    }

    public func objectInfo(_ handle: UInt32) async throws -> MTPObjectInfo {
        let data = try await transact(.getObjectInfo, params: [handle]).data
        return try MTPObjectInfo.parse(data, handle: handle)
    }

    /// 64-bit size via object property, for files whose ObjectInfo size
    /// overflowed 32 bits.
    public func objectSize64(_ handle: UInt32) async throws -> UInt64 {
        let data = try await transact(
            .getObjectPropValue,
            params: [handle, UInt32(PTP.ObjectProp.objectSize)]
        ).data
        var r = PTPReader(data)
        switch data.count {
        case 8...: return try r.u64()
        case 4...: return UInt64(try r.u32())
        default: throw MTPError(.protocolViolation("ObjectSize property too short"))
        }
    }

    // MARK: - Read

    /// Reads up to `length` bytes at `offset`. Uses GetPartialObject, capped to
    /// `transferChunk` per call.
    public func readObject(handle: UInt32, offset: UInt64, length: Int) async throws -> Data {
        guard let info, info.supports(.getPartialObject) else {
            throw MTPError(.notSupported("device lacks GetPartialObject"))
        }
        guard offset <= UInt64(UInt32.max) else {
            // 32-bit offset limit of GetPartialObject. The 64-bit variant
            // (0x95C1 GetPartialObject64) joins the quirk table when needed.
            throw MTPError(.notSupported("read beyond 4 GiB offset needs GetPartialObject64"))
        }
        let want = min(length, Self.transferChunk)
        let reply = try await transact(
            .getPartialObject,
            params: [handle, UInt32(offset), UInt32(want)]
        )
        return reply.data
    }

    // MARK: - Write

    /// Creates a folder. Returns the new object handle.
    public func createFolder(storageID: UInt32, parentHandle: UInt32, name: String) async throws -> UInt32 {
        let dataset = MTPObjectInfo.makeDataset(
            storageID: storageID, parentHandle: parentHandle,
            filename: name, size: 0, isFolder: true, modified: Date()
        )
        let response = try await transact(
            .sendObjectInfo,
            params: [storageID, parentHandle],
            dataOut: dataset
        )
        guard response.params.count >= 3 else {
            throw MTPError(.protocolViolation("SendObjectInfo returned no handle"))
        }
        return response.params[2]
    }

    /// Uploads a complete file from a local staging URL. MTP has no partial
    /// writes: this is the only way content gets onto the device.
    /// Returns the new object handle.
    public func sendObject(
        storageID: UInt32, parentHandle: UInt32, name: String,
        fileURL: URL, size: UInt64, modified: Date?,
        progress: (@Sendable (UInt64) -> Void)? = nil
    ) async throws -> UInt32 {
        let dataset = MTPObjectInfo.makeDataset(
            storageID: storageID, parentHandle: parentHandle,
            filename: name, size: size, isFolder: false, modified: modified
        )
        await lockBus()
        defer { unlockBus() }
        MTPTrace.log("sendObject begin name=\(name) size=\(size) storage=\(MTPTrace.hex(storageID)) parent=\(MTPTrace.hex(parentHandle))")
        let infoResponse = try await performTransaction(
            .sendObjectInfo,
            params: [storageID, parentHandle],
            dataOut: dataset
        )
        guard infoResponse.params.count >= 3 else {
            throw MTPError(.protocolViolation("SendObjectInfo returned no handle"))
        }
        let handle = infoResponse.params[2]
        MTPTrace.log("sendObject SOI ok -> handle=\(MTPTrace.hex(handle)) returned=\(MTPTrace.hex(infoResponse.params))")

        // SendObject data phase, streamed from disk in chunks.
        let file = try FileHandle(forReadingFrom: fileURL)
        defer { try? file.close() }

        let tid = nextTransactionID(for: .sendObject)
        MTPTrace.log("sendObject cmd tid=\(tid) payloadSize=\(size) containerLen=\(UInt32(PTPContainer.headerSize) + UInt32(truncatingIfNeeded: size))")
        try await transport.write(
            PTPContainer.command(.sendObject, transactionID: tid).encoded(),
            timeout: commandTimeout
        )
        let header = PTPContainer.header(type: .data, code: PTP.Op.sendObject.rawValue, transactionID: tid, payloadSize: size)

        var sent: UInt64 = 0
        var first = true
        // A USB bulk transfer ends at a SHORT packet (one smaller than
        // maxPacketSize) as well as at the requested length. The first chunk
        // carries the 12-byte PTP container header on top of its payload, so a
        // naive `transferChunk` payload puts header+payload 12 bytes past a
        // packet boundary. The device reads that short final packet as "data
        // phase complete", stops reading the endpoint, and every subsequent
        // chunk blocks until the USB timeout fires.
        //
        // Measured on a Samsung SM-X133: a 4 MB file (one chunk) wrote at
        // 15 MB/s; a 50 MB file stalled on chunk 2 for 60.93 s, returned
        // kIOReturnTimeout, and left a 0-byte file behind. Align every
        // mid-phase chunk to a packet boundary so only the final chunk may
        // run short.
        let packet = max(transport.maxPacketSize, 1)
        let firstPayload = max(
            ((Self.transferChunk + PTPContainer.headerSize) / packet) * packet - PTPContainer.headerSize,
            packet
        )
        let restPayload = max((Self.transferChunk / packet) * packet, packet)
        MTPTrace.log("sendObject align packet=\(packet) firstPayload=\(firstPayload) restPayload=\(restPayload)")

        while sent < size || first {
            let budget = first ? firstPayload : restPayload
            let chunkSize = Int(min(UInt64(budget), size - sent))
            var chunk = first ? header : Data()
            if chunkSize > 0 {
                guard let bytes = try file.read(upToCount: chunkSize), bytes.count == chunkSize else {
                    throw MTPError(.protocolViolation("staging file shrank during upload"))
                }
                chunk.append(bytes)
            }
            let t0 = Date()
            do {
                try await transport.write(chunk, timeout: dataTimeout)
            } catch {
                MTPTrace.log("sendObject chunk FAILED after \(String(format: "%.2f", Date().timeIntervalSince(t0)))s "
                    + "bytes=\(chunk.count) sent=\(sent)/\(size) error=\(error)")
                throw error
            }
            MTPTrace.log("sendObject chunk ok \(chunk.count)B in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s "
                + "(sent \(sent + UInt64(chunkSize))/\(size))")
            sent += UInt64(chunkSize)
            first = false
            progress?(sent)
        }
        // Terminate an exact-multiple data phase.
        if (UInt64(PTPContainer.headerSize) + size) % UInt64(transport.maxPacketSize) == 0 {
            try await transport.writeZeroLengthPacket(timeout: commandTimeout)
        }

        let response = try await readResponse(expectedTID: tid)
        MTPTrace.log("sendObject response tid=\(tid) code=0x\(String(response.code, radix: 16)) (\(PTP.Response(code: response.code)))")
        guard PTP.Response(code: response.code) == .ok else {
            throw MTPError(.response(PTP.Response(code: response.code)))
        }
        return handle
    }

    public func deleteObject(_ handle: UInt32) async throws {
        _ = try await transact(.deleteObject, params: [handle])
    }

    public func moveObject(_ handle: UInt32, toStorage storageID: UInt32, parentHandle: UInt32) async throws {
        // MoveObject's parent parameter: 0 means storage root.
        let parent = parentHandle == PTP.rootParentHandle ? 0 : parentHandle
        _ = try await transact(.moveObject, params: [handle, storageID, parent])
    }

    /// Renames in place via the ObjectFileName property. Not all devices allow
    /// it; callers surface ENOTSUP.
    public func renameObject(_ handle: UInt32, to newName: String) async throws {
        guard let info, info.supports(.setObjectPropValue) else {
            throw MTPError(.notSupported("device lacks SetObjectPropValue"))
        }
        var w = PTPWriter()
        w.string(newName)
        _ = try await transact(
            .setObjectPropValue,
            params: [handle, UInt32(PTP.ObjectProp.objectFileName)],
            dataOut: w.data
        )
    }

    // MARK: - Events

    /// Waits for one device event (ObjectAdded, StoreRemoved, ...). Runs on the
    /// interrupt pipe so it never contends with bulk transactions.
    public func nextEvent() async throws -> (event: PTP.Event, params: [UInt32])? {
        let raw = try await transport.readEvent()
        guard raw.count >= PTPContainer.headerSize else { return nil }
        let container = try PTPContainer.parse(raw)
        guard container.type == .event, let event = PTP.Event(rawValue: container.code) else { return nil }
        return (event, container.responseParams())
    }

    // MARK: - Bus lock

    // Actor isolation alone is NOT enough: every await inside a multi-phase
    // operation (SendObjectInfo + SendObject) is a reentrancy point where a
    // concurrent caller's transaction can interleave on the wire and desync
    // the session. This FIFO gate makes each full transaction atomic.
    private var busBusy = false
    private var busWaiters: [CheckedContinuation<Void, Never>] = []

    private func lockBus() async {
        if !busBusy {
            busBusy = true
            return
        }
        await withCheckedContinuation { busWaiters.append($0) }
    }

    private func unlockBus() {
        if busWaiters.isEmpty {
            busBusy = false
        } else {
            busWaiters.removeFirst().resume() // hand the lock to the next waiter
        }
    }

    // MARK: - Transaction plumbing

    private struct TransactionReply {
        let data: Data
        let params: [UInt32]
    }

    private func nextTransactionID(for op: PTP.Op) -> UInt32 {
        // PIMA 15740: commands issued outside a session (GetDeviceInfo before
        // OpenSession, and OpenSession itself) carry transaction ID 0. Strict
        // devices (Kindle) reject anything else with ParameterNotSupported.
        if op == .openSession || (op == .getDeviceInfo && !sessionOpen) {
            transactionID = 0
            return 0
        }
        transactionID &+= 1
        if transactionID == 0 { transactionID = 1 }
        return transactionID
    }

    /// One full transaction: command, optional single-direction data phase,
    /// response. `dataOut` sends a data phase; otherwise any data phase the
    /// device sends is collected and returned.
    private func transact(_ op: PTP.Op, params: [UInt32], dataOut: Data? = nil) async throws -> TransactionReply {
        await lockBus()
        defer { unlockBus() }
        return try await performTransaction(op, params: params, dataOut: dataOut)
    }

    private func performTransaction(_ op: PTP.Op, params: [UInt32], dataOut: Data? = nil) async throws -> TransactionReply {
        let tid = nextTransactionID(for: op)
        MTPTrace.log("-> \(op) tid=\(tid) params=\(MTPTrace.hex(params)) dataOut=\(dataOut?.count ?? 0)B")
        try await transport.write(
            PTPContainer.command(op, transactionID: tid, params: params).encoded(),
            timeout: commandTimeout
        )

        if let dataOut {
            let container = PTPContainer(type: .data, code: op.rawValue, transactionID: tid, payload: dataOut)
            try await transport.write(container.encoded(), timeout: dataTimeout)
            if container.encoded().count % transport.maxPacketSize == 0 {
                try await transport.writeZeroLengthPacket(timeout: commandTimeout)
            }
            let response = try await readResponse(expectedTID: tid)
            let code = PTP.Response(code: response.code)
            MTPTrace.log("<- \(op) tid=\(tid) code=0x\(String(response.code, radix: 16)) (\(code)) params=\(MTPTrace.hex(response.responseParams()))")
            guard code == .ok else { throw MTPError(.response(code)) }
            return TransactionReply(data: Data(), params: response.responseParams())
        }

        // Data-in (or straight response) path. Discard stale containers from a
        // prior transaction instead of failing the whole session.
        var dataPayload = Data()
        var container: PTPContainer
        var attempts = 0
        repeat {
            let firstRead = try await transport.read(maxLength: Self.transferChunk + PTPContainer.headerSize, timeout: dataTimeout)
            container = try PTPContainer.parse(firstRead)
            attempts += 1
        } while container.transactionID != tid && tid != 0 && attempts < 4

        // A leftover container from an earlier transaction must never be
        // mistaken for this one's answer.
        if tid != 0, container.transactionID != tid {
            throw MTPError(.protocolViolation("stale container tid \(container.transactionID), expected \(tid)"))
        }

        if container.type == .data {
            guard container.transactionID == tid else {
                throw MTPError(.protocolViolation("data phase transaction ID mismatch"))
            }
            dataPayload = container.payload
            // Container length tells us how much data phase remains beyond the
            // first transfer (a transfer ends at a short packet OR full buffer).
            if container.length != PTP.lengthOverflow {
                let total = Int(container.length) - PTPContainer.headerSize
                // The device declares this length. Metadata replies are tiny
                // and file reads are requested in <= 4 MB pieces, so anything
                // beyond this is a broken or hostile device, not data.
                guard total <= Self.maxDataIn else {
                    throw MTPError(.protocolViolation("data phase of \(total) bytes exceeds limit"))
                }
                while dataPayload.count < total {
                    let more = try await transport.read(
                        maxLength: min(total - dataPayload.count, Self.transferChunk),
                        timeout: dataTimeout
                    )
                    if more.isEmpty { break }
                    dataPayload.append(more)
                }
            }
            let responseRaw = try await transport.read(maxLength: 1024, timeout: commandTimeout)
            container = try PTPContainer.parse(responseRaw)
        }

        guard container.type == .response else {
            throw MTPError(.protocolViolation("expected response container, got \(container.type)"))
        }
        let code = PTP.Response(code: container.code)
        MTPTrace.log("<- \(op) tid=\(tid) code=0x\(String(container.code, radix: 16)) (\(code)) "
            + "params=\(MTPTrace.hex(container.responseParams())) dataBytes=\(dataPayload.count)")
        guard code == .ok else {
            transport.clearStalls()
            throw MTPError(.response(code))
        }
        return TransactionReply(data: dataPayload, params: container.responseParams())
    }

    private func readResponse(expectedTID: UInt32) async throws -> PTPContainer {
        var attempts = 0
        while true {
            let raw = try await transport.read(maxLength: 1024, timeout: dataTimeout)
            let container = try PTPContainer.parse(raw)
            attempts += 1
            // Skip a stale response left over from a previous transaction.
            if expectedTID != 0, container.transactionID != expectedTID {
                if attempts < 4 { continue }
                throw MTPError(.protocolViolation(
                    "response tid \(container.transactionID), expected \(expectedTID)"))
            }
            guard container.type == .response else {
                throw MTPError(.protocolViolation("expected response container, got \(container.type)"))
            }
            return container
        }
    }
}
