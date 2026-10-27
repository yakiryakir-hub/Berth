import Foundation

/// Thrown once a response's status line and Content-Length are already on the
/// wire. The connection must be torn down: writing another status line would
/// inject ASCII into the middle of the body the client is reading, which it
/// either treats as file bytes (silent corruption, exit 0) or blocks on until
/// the socket timeout.
struct DavStreamError: Error, CustomStringConvertible {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var description: String { "stream aborted: \(reason)" }
}

/// A WebDAV class-2 server bound to 127.0.0.1 on an ephemeral port, serving
/// one DavBackend. Built for exactly one client: macOS's webdavfs via
/// mount_webdav. Thread-per-connection with blocking I/O; the backend is
/// async and bridged per call. The URL namespace is prefixed with a random
/// token so other local processes can't guess the URL.
public final class DavServer: @unchecked Sendable {

    private let backend: any DavBackend
    /// Random path prefix; the mount URL is http://127.0.0.1:port/token/
    public let token: String
    public private(set) var port: UInt16 = 0
    private var listenFD: Int32 = -1
    private let stateLock = NSLock()
    private var running = false
    private var activeConnections = 0
    /// One client (webdavfs) normally holds a handful of connections. A cap
    /// keeps a misbehaving local process from spawning unbounded threads.
    private static let maxConnections = 32

    public var url: URL {
        URL(string: "http://127.0.0.1:\(port)/\(token)/")!
    }

    /// Per-request stderr logging, for development and the demo server.
    public var debugLogging = false
    /// Optional sink for request/error lines (the app writes these to a file;
    /// NSLog from LSUIElement apps has proven unreliable to query).
    public nonisolated(unsafe) var logHandler: (@Sendable (String) -> Void)?

    public init(backend: any DavBackend) {
        self.backend = backend
        self.token = UUID().uuidString
    }

    private func logRequest(_ request: HTTPRequest) {
        guard debugLogging else { return }
        logHandler?("\(request.method) \(request.rawTarget) depth=\(request.header("depth") ?? "-") len=\(request.bodyLength)")
    }

    public func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &length)
            }
        }
        port = UInt16(bigEndian: bound.sin_port)
        listenFD = fd
        stateLock.lock(); running = true; stateLock.unlock()

        let acceptFD = fd
        let thread = Thread { [weak self] in
            self?.acceptLoop(listenFD: acceptFD)
        }
        thread.name = "DavServer accept"
        thread.start()
    }

    public func stop() {
        stateLock.lock()
        running = false
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()
        if fd >= 0 {
            // shutdown() wakes a thread blocked in accept(); closing alone
            // can leave it parked (or accepting on a recycled descriptor).
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func acceptLoop(listenFD: Int32) {
        while isRunning {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                if !isRunning { break }
                // EMFILE and friends would otherwise spin a core at 100%.
                if errno != EINTR && errno != ECONNABORTED { usleep(50_000) }
                continue
            }
            stateLock.lock()
            let full = activeConnections >= Self.maxConnections
            if !full { activeConnections += 1 }
            stateLock.unlock()
            if full {
                logHandler?("connection refused: \(Self.maxConnections) already open")
                close(clientFD)
                continue
            }
            let thread = Thread { [weak self] in
                defer {
                    self?.stateLock.lock()
                    self?.activeConnections -= 1
                    self?.stateLock.unlock()
                }
                self?.serve(fd: clientFD)
            }
            thread.name = "DavServer connection"
            thread.start()
        }
    }

    // MARK: - Connection loop

    private func serve(fd: Int32) {
        let io = SocketIO(fd: fd)
        while isRunning {
            do {
                guard let request = try HTTPRequest.read(from: io) else { return }
                defer { request.cleanup() }
                logRequest(request)
                try handle(request, io: io)
                if request.header("connection")?.lowercased() == "close" { return }
            } catch let error as HTTPRequest.FramingError {
                // Nothing has been committed to this connection yet, so the
                // request can still be rejected properly instead of silently
                // turning an unparsable body into a successful empty one.
                logHandler?("\(error) -> closing connection")
                try? HTTPResponse.send(io, status: 400)
                return
            } catch {
                // DavStreamError lands here too: headers were already sent, so
                // the only correct move is to close. SocketIO deinit closes fd.
                if debugLogging { logHandler?("connection error \(error)") }
                return
            }
        }
    }

    private final class ResultBox<V>: @unchecked Sendable {
        var result: Result<V, Error>?
    }

    /// Bridges the connection thread into the async backend.
    private func call<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = Result<T, Error>.success(try await op()) }
            catch { box.result = Result<T, Error>.failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.result else { throw DavError.unavailable }
        return try result.get()
    }

    private func status(for error: Error) -> Int {
        switch error {
        case DavError.notFound: return 404
        case DavError.exists: return 405
        case DavError.forbidden: return 403
        case DavError.conflict: return 409
        case DavError.insufficientStorage: return 507
        case DavError.unavailable: return 503
        case DavError.notSupported: return 501
        default: return 500
        }
    }

    // MARK: - Routing

    private func handle(_ request: HTTPRequest, io: SocketIO) throws {
        // OPTIONS * or any path: advertise class 2 so webdavfs mounts rw.
        if request.method == "OPTIONS" {
            try HTTPResponse.send(io, status: 200, headers: [
                ("Allow", "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, MOVE, LOCK, UNLOCK"),
                ("DAV", "1, 2"),
                ("MS-Author-Via", "DAV"),
            ])
            return
        }

        // Everything else lives under /token/...
        var mutableSegments = request.pathSegments
        guard !mutableSegments.isEmpty, mutableSegments.first == token else {
            // This branch never reached the logged `catch` below, so a client
            // probing a path outside the token — which is exactly how we would
            // miss a statfs quota PROPFIND — was completely invisible.
            if debugLogging {
                logHandler?("\(request.method) \(request.rawTarget) -> 404 (outside token) len=\(request.bodyLength)")
            }
            try HTTPResponse.send(io, status: 404)
            return
        }
        mutableSegments.removeFirst()
        let segments = mutableSegments

        do {
            switch request.method {
            case "PROPFIND": try propfind(request, path: segments, io: io)
            case "GET", "HEAD": try get(request, path: segments, io: io)
            case "PUT": try put(request, path: segments, io: io)
            case "DELETE":
                try call { [backend] in try await backend.delete(path: segments) }
                try HTTPResponse.send(io, status: 204)
            case "MKCOL":
                guard !request.hasBody else {
                    try HTTPResponse.send(io, status: 415)
                    return
                }
                try call { [backend] in try await backend.makeDirectory(path: segments) }
                try HTTPResponse.send(io, status: 201)
            case "MOVE": try move(request, from: segments, io: io)
            case "LOCK":
                let lockToken = "opaquelocktoken:\(UUID().uuidString)"
                try HTTPResponse.send(io, status: 200, headers: [
                    ("Lock-Token", "<\(lockToken)>"),
                    ("Content-Type", "text/xml; charset=\"utf-8\""),
                ], body: DavXML.lockResponse(token: lockToken))
            case "UNLOCK":
                try HTTPResponse.send(io, status: 204)
            case "PROPPATCH":
                let href = DavXML.encodeHref(prefix: token, segments: segments, isDirectory: false)
                try HTTPResponse.send(io, status: 207, headers: [
                    ("Content-Type", "text/xml; charset=\"utf-8\""),
                ], body: DavXML.proppatchResponse(href: href))
            default:
                try HTTPResponse.send(io, status: 501)
            }
        } catch let error as DavStreamError {
            // Response headers are already committed. Never send a status here.
            logHandler?("\(request.method) \(request.rawTarget) -> \(error)")
            throw error
        } catch let error where !(error is SocketIO.IOError) {
            let code = status(for: error)
            if debugLogging || code >= 500 {
                logHandler?("\(request.method) \(request.rawTarget) -> \(code) (\(error))")
            }
            try HTTPResponse.send(io, status: code)
        }
    }

    // MARK: - Methods

    private func propfind(_ request: HTTPRequest, path: [String], io: SocketIO) throws {
        if ProcessInfo.processInfo.environment["DAV_TRACE"] == "1" {
            logHandler?("PROPFIND body depth=\(request.header("depth") ?? "1") -> "
                + (String(data: request.body, encoding: .utf8) ?? "<binary \(request.body.count)B>"))
        }
        let depth = request.header("depth") ?? "1"
        guard depth == "0" || depth == "1" else {
            try HTTPResponse.send(io, status: 403)
            return
        }

        let entry = try call { [backend] in try await backend.stat(path: path) }
        let quota: (total: UInt64, free: UInt64)? = path.isEmpty
            ? (try? call { [backend] in try await backend.quota() })
            : nil

        var responses = [DavXML.response(
            href: DavXML.encodeHref(prefix: token, segments: path, isDirectory: entry.isDirectory),
            entry: entry,
            quota: quota
        )]

        if depth == "1", entry.isDirectory {
            let children = try call { [backend] in try await backend.list(path: path) }
            for child in children {
                responses.append(DavXML.response(
                    href: DavXML.encodeHref(prefix: token, segments: path + [child.name], isDirectory: child.isDirectory),
                    entry: child
                ))
            }
        }

        try HTTPResponse.send(io, status: 207, headers: [
            ("Content-Type", "text/xml; charset=\"utf-8\""),
        ], body: DavXML.multistatus(responses))
    }

    private func get(_ request: HTTPRequest, path: [String], io: SocketIO) throws {
        let entry = try call { [backend] in try await backend.stat(path: path) }
        guard !entry.isDirectory else {
            try HTTPResponse.send(io, status: 403)
            return
        }

        var offsetValue: UInt64 = 0
        var lengthValue = entry.size
        var isPartial = false
        if let range = request.header("range"), range.hasPrefix("bytes=") {
            let spec = range.dropFirst(6).split(separator: ",")[0] // single range only
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            let fromString = bounds.count > 0 ? String(bounds[0]) : ""
            let toString = bounds.count > 1 ? String(bounds[1]) : ""
            if fromString.isEmpty, let suffix = UInt64(toString) {
                offsetValue = entry.size > suffix ? entry.size - suffix : 0
                lengthValue = entry.size - offsetValue
            } else if let from = UInt64(fromString) {
                guard from < max(entry.size, 1) || entry.size == 0 else {
                    try HTTPResponse.send(io, status: 416, headers: [("Content-Range", "bytes */\(entry.size)")])
                    return
                }
                offsetValue = from
                if let to = UInt64(toString), to >= from {
                    lengthValue = min(to, entry.size == 0 ? 0 : entry.size - 1) - from + 1
                } else {
                    lengthValue = entry.size - from
                }
            }
            isPartial = true
        }
        let offset = offsetValue
        let length = lengthValue

        var headers: [(String, String)] = [
            ("Content-Length", "\(length)"),
            ("Accept-Ranges", "bytes"),
            ("ETag", DavXML.etag(size: entry.size, modified: entry.modified)),
        ]
        if isPartial {
            let last = length > 0 ? offset + length - 1 : offset
            headers.append(("Content-Range", "bytes \(offset)-\(last)/\(entry.size)"))
        }
        try HTTPResponse.send(io, status: isPartial ? 206 : 200, headers: headers, omitBody: true)

        guard request.method == "GET", length > 0 else { return }

        // Past this point the status line and Content-Length are already on the
        // wire. Any failure below MUST tear the connection down rather than let
        // `handle`'s catch write a second status line into the middle of the
        // response body — the client would then either block until the socket
        // timeout or swallow those bytes as file content and exit 0 with a
        // corrupted file. Same for a short body: we promised `length` bytes.
        var sent: UInt64 = 0
        while sent < length {
            let want = Int(min(UInt64(4 << 20), length - sent))
            let readOffset = offset + sent
            let chunk: Data
            do {
                chunk = try call { [backend] in
                    try await backend.read(path: path, offset: readOffset, length: want)
                }
            } catch {
                throw DavStreamError(
                    "backend read failed after \(sent)/\(length) bytes: \(error)")
            }
            if chunk.isEmpty {
                // Backends legitimately return empty past a cached node size
                // (MTPDavBackend.read guards `offset < node.size`). That is a
                // stale-size bug upstream, but it must never truncate silently.
                throw DavStreamError(
                    "backend returned 0 bytes at offset \(readOffset) of \(length) "
                    + "(stale or wrong object size)")
            }
            if chunk.count > want {
                throw DavStreamError(
                    "backend over-delivered \(chunk.count) > \(want) at offset \(readOffset)")
            }
            do {
                try io.write(chunk)
            } catch let error as SocketIO.IOError {
                // Client hung up mid-transfer. Nothing is recoverable, but it
                // is not a server-side fault either — let `serve` tear down
                // quietly rather than logging a stream abort for every Finder
                // that reads 4 MB and closes.
                throw error
            } catch {
                throw DavStreamError("client write failed after \(sent)/\(length) bytes")
            }
            sent += UInt64(chunk.count)
        }
    }

    private func put(_ request: HTTPRequest, path: [String], io: SocketIO) throws {
        let existed = (try? call { [backend] in try await backend.stat(path: path) }) != nil
        // Backends push whole files (MTP has no partial writes) and may stream
        // from disk. A body already staged by HTTPRequest is handed over as-is;
        // only a small in-memory body needs a temp file of its own.
        let staged: URL
        var tempCopy: URL?
        defer { if let t = tempCopy { try? FileManager.default.removeItem(at: t) } }
        if let file = request.bodyFile {
            staged = file
        } else {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try request.body.write(to: temp)
            tempCopy = temp
            staged = temp
        }
        try call { [backend] in try await backend.write(path: path, contentsOf: staged) }
        try HTTPResponse.send(io, status: existed ? 204 : 201)
    }

    private func move(_ request: HTTPRequest, from: [String], io: SocketIO) throws {
        guard let destination = request.header("destination"),
              let destinationURL = URL(string: destination) else {
            try HTTPResponse.send(io, status: 400)
            return
        }
        var toSegments = destinationURL.path.split(separator: "/").map {
            String($0).removingPercentEncoding ?? String($0)
        }
        guard toSegments.first == token else {
            try HTTPResponse.send(io, status: 400)
            return
        }
        toSegments.removeFirst()
        let to = toSegments

        let overwrite = (request.header("overwrite") ?? "T").uppercased() != "F"
        let destinationExists = (try? call { [backend] in try await backend.stat(path: to) }) != nil
        // Overwriting must not destroy the old file until the new one is in
        // place: set it aside under a hidden name, move, and only then delete
        // it. Any failure puts the original back. Backends that cannot rename
        // fall back to delete-then-move (the previous behaviour).
        var aside: [String]?
        if destinationExists {
            guard overwrite else {
                try HTTPResponse.send(io, status: 412)
                return
            }
            let hidden = Array(to.dropLast()) + [".berth-replaced-" + String(UUID().uuidString.prefix(8))]
            do {
                try call { [backend] in try await backend.move(from: to, to: hidden) }
                aside = hidden
            } catch {
                try call { [backend] in try await backend.delete(path: to) }
            }
        }
        do {
            try call { [backend] in try await backend.move(from: from, to: to) }
        } catch {
            if let hidden = aside {
                _ = try? call { [backend] in try await backend.move(from: hidden, to: to) }
            }
            throw error
        }
        if let hidden = aside {
            do { try call { [backend] in try await backend.delete(path: hidden) } }
            catch { logHandler?("could not remove replaced file \(hidden.last ?? ""): \(error)") }
        }
        try HTTPResponse.send(io, status: destinationExists ? 204 : 201)
    }
}
