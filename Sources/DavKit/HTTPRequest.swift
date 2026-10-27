import Foundation

/// A parsed HTTP/1.1 request. Header keys lowercased.
struct HTTPRequest {
    let method: String
    let rawTarget: String
    let headers: [String: String]
    /// In-memory body. Empty when the body was spilled to `bodyFile`.
    let body: Data
    /// Where a large body was streamed instead of held in RAM. Owned by the
    /// connection loop; released by `cleanup()`.
    let bodyFile: URL?

    /// Raised when the request framing cannot be trusted. Answering 400 and
    /// closing is the only safe response: an unparsable Content-Length used to
    /// fall through to an empty body, so a malformed PUT was acknowledged
    /// 201/204 while zero bytes reached the device.
    struct FramingError: Error, CustomStringConvertible {
        let reason: String
        var description: String { "bad framing: \(reason)" }
    }

    /// Bodies above this spill to a temp file. A 4 GB video copy buffered in
    /// RAM costs ~8 GB in a menu-bar app (read buffer + temp-file copy).
    static let memoryBodyCap = 1 << 20

    /// Declared body size, for logging before/without materialising it.
    var bodyLength: Int {
        if let raw = headers["content-length"], let n = Int(raw) { return n }
        return body.count
    }

    var hasBody: Bool { body.count > 0 || bodyFile != nil }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Remove any temp file backing a spilled body. Safe to call twice.
    func cleanup() {
        if let file = bodyFile { try? FileManager.default.removeItem(at: file) }
    }

    /// Decoded path segments of the request target, query stripped.
    /// "/a%20b/c/" -> ["a b", "c"]
    var pathSegments: [String] {
        var target = rawTarget
        if let q = target.firstIndex(of: "?") { target = String(target[..<q]) }
        return target.split(separator: "/").map {
            String($0).removingPercentEncoding ?? String($0)
        }
    }

    var wantsCollection: Bool {
        var target = rawTarget
        if let q = target.firstIndex(of: "?") { target = String(target[..<q]) }
        return target.hasSuffix("/")
    }

    private static func spillTarget() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("berth-body-" + UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    /// Reads one request off the connection. Returns nil on clean EOF between
    /// requests (keep-alive connection closed by client).
    static func read(from io: SocketIO) throws -> HTTPRequest? {
        var requestLine = ""
        // Stray CRLFs between pipelined requests are skipped, but bounded: a
        // peer sending nothing but blank lines must not recurse or spin.
        for _ in 0..<8 {
            do {
                requestLine = try io.readLine()
            } catch SocketIO.IOError.closed {
                return nil
            }
            if !requestLine.isEmpty { break }
        }
        if requestLine.isEmpty { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers = [String: String]()
        while true {
            let line = try io.readLine()
            if line.isEmpty { break }
            guard headers.count < 100 else { throw FramingError(reason: "too many headers") }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // The interim response contract: client waits for 100 before sending
        // a large body (mount_webdav PUTs use this).
        if headers["expect"]?.lowercased().contains("100-continue") == true {
            try io.write("HTTP/1.1 100 Continue\r\n\r\n")
        }

        var body = Data()
        var bodyFile: URL?
        do {
            if let te = headers["transfer-encoding"], te.lowercased().contains("chunked") {
                // Size is discovered as we go, so stream straight to disk: there
                // is no moment at which a bounded in-memory buffer is provably
                // safe.
                let file = try spillTarget()
                bodyFile = file
                guard let handle = FileHandle(forWritingAtPath: file.path) else {
                    throw FramingError(reason: "cannot stage body")
                }
                defer { try? handle.close() }
                while true {
                    let sizeLine = try io.readLine()
                    guard let hex = sizeLine.split(separator: ";").first.map(String.init),
                          let size = Int(hex, radix: 16), size >= 0 else {
                        throw FramingError(reason: "unparsable chunk size \(sizeLine.prefix(40))")
                    }
                    if size == 0 {
                        // Consume trailer lines through the final blank line.
                        while !(try io.readLine()).isEmpty {}
                        break
                    }
                    // A hostile or buggy peer can declare a multi-GB chunk;
                    // pull it through in bounded slices instead of buffering it.
                    var left = size
                    while left > 0 {
                        let n = min(left, 4 << 20)
                        try handle.write(contentsOf: try io.read(exactly: n))
                        left -= n
                    }
                    _ = try io.readLine() // chunk-terminating CRLF
                }
            } else if let lengthValue = headers["content-length"] {
                guard let length = Int(lengthValue), length >= 0 else {
                    throw FramingError(reason: "malformed Content-Length \(lengthValue.prefix(40))")
                }
                if length > memoryBodyCap {
                    let file = try spillTarget()
                    bodyFile = file
                    guard let handle = FileHandle(forWritingAtPath: file.path) else {
                        throw FramingError(reason: "cannot stage body")
                    }
                    defer { try? handle.close() }
                    var remaining = length
                    while remaining > 0 {
                        let n = min(remaining, 4 << 20)
                        try handle.write(contentsOf: try io.read(exactly: n))
                        remaining -= n
                    }
                } else if length > 0 {
                    body = try io.read(exactly: length)
                }
            }
        } catch {
            // A body half-read off the wire must not leave its staging file
            // behind — the connection is about to be torn down.
            if let file = bodyFile { try? FileManager.default.removeItem(at: file) }
            throw error
        }

        return HTTPRequest(
            method: method, rawTarget: target, headers: headers,
            body: body, bodyFile: bodyFile
        )
    }
}

/// Response writer: status + headers + body, keep-alive friendly.
struct HTTPResponse {
    static let statusText: [Int: String] = [
        100: "Continue", 200: "OK", 201: "Created", 204: "No Content",
        206: "Partial Content", 207: "Multi-Status",
        301: "Moved Permanently", 304: "Not Modified",
        400: "Bad Request", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 409: "Conflict", 412: "Precondition Failed",
        415: "Unsupported Media Type", 416: "Range Not Satisfiable",
        423: "Locked", 500: "Internal Server Error", 501: "Not Implemented",
        503: "Service Unavailable", 507: "Insufficient Storage",
    ]

    static func send(_ io: SocketIO, status: Int, headers: [(String, String)] = [], body: Data = Data(), omitBody: Bool = false) throws {
        var head = "HTTP/1.1 \(status) \(statusText[status] ?? "Status")\r\n"
        head += "Server: Berth\r\n"
        head += "Connection: keep-alive\r\n"
        var hasLength = false
        for (name, value) in headers {
            if name.lowercased() == "content-length" { hasLength = true }
            head += "\(name): \(value)\r\n"
        }
        if !hasLength {
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        try io.write(head)
        if !omitBody, !body.isEmpty {
            try io.write(body)
        }
    }
}
