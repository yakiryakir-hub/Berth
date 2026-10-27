import Foundation

/// Builders for the small set of WebDAV XML documents we emit. All output,
/// no parsing: PROPFIND request bodies are ignored and we return the standard
/// property set, which is what macOS's webdavfs consumes.
enum DavXML {

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x26: out += "&amp;"
            case 0x3C: out += "&lt;"
            case 0x3E: out += "&gt;"
            case 0x22: out += "&quot;"
            // XML 1.0 forbids most control characters and U+FFFE/FFFF even
            // escaped. A single one in a device-controlled filename made the
            // whole multistatus unparsable, hiding the entire directory.
            case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
                out.unicodeScalars.append(scalar)
            default:
                continue
            }
        }
        return out
    }

    static func encodeHref(prefix: String, segments: [String], isDirectory: Bool) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?&#+")
        var href = "/" + prefix
        for segment in segments {
            href += "/" + (segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment)
        }
        if isDirectory { href += "/" }
        return href
    }

    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        return f
    }()

    private static nonisolated(unsafe) let isoDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func etag(size: UInt64, modified: Date?) -> String {
        "\"\(size)-\(Int(modified?.timeIntervalSince1970 ?? 0))\""
    }

    /// One <D:response> for an entry.
    static func response(href: String, entry: DavEntry, quota: (total: UInt64, free: UInt64)? = nil) -> String {
        var props = ""
        if entry.isDirectory {
            props += "<D:resourcetype><D:collection/></D:resourcetype>"
        } else {
            props += "<D:resourcetype/>"
            props += "<D:getcontentlength>\(entry.size)</D:getcontentlength>"
            props += "<D:getetag>\(etag(size: entry.size, modified: entry.modified))</D:getetag>"
        }
        props += "<D:displayname>\(escape(entry.name))</D:displayname>"
        if let modified = entry.modified {
            props += "<D:getlastmodified>\(httpDate.string(from: modified))</D:getlastmodified>"
        }
        if let created = entry.created {
            props += "<D:creationdate>\(isoDate.string(from: created))</D:creationdate>"
        }
        if let quota {
            props += "<D:quota-available-bytes>\(quota.free)</D:quota-available-bytes>"
            props += "<D:quota-used-bytes>\(quota.total - min(quota.total, quota.free))</D:quota-used-bytes>"
        }
        return """
        <D:response><D:href>\(href)</D:href>\
        <D:propstat><D:prop>\(props)</D:prop>\
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        """
    }

    static func multistatus(_ responses: [String]) -> Data {
        let doc = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">\(responses.joined())</D:multistatus>
        """
        return Data(doc.utf8)
    }

    /// Fake-but-valid LOCK response. We are the only writer; the lock exists
    /// so webdavfs agrees to mount read-write (it requires DAV class 2).
    static func lockResponse(token: String) -> Data {
        let doc = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock>
        <D:locktype><D:write/></D:locktype>
        <D:lockscope><D:exclusive/></D:lockscope>
        <D:depth>0</D:depth>
        <D:timeout>Second-604800</D:timeout>
        <D:locktoken><D:href>\(token)</D:href></D:locktoken>
        </D:activelock></D:lockdiscovery></D:prop>
        """
        return Data(doc.utf8)
    }

    /// PROPPATCH: acknowledge every property as set; MTP has nowhere to put
    /// them and callers (webdavfs setting dates after PUT) cope fine.
    static func proppatchResponse(href: String) -> Data {
        let doc = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:"><D:response><D:href>\(href)</D:href>\
        <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>\
        </D:response></D:multistatus>
        """
        return Data(doc.utf8)
    }
}
