import Foundation

/// What a WebParser `URL` (or a value to download) designates.
enum WebParserTarget: Equatable {
    case http(URL)
    /// Absolute POSIX path as written (not percent-decoded; the loader also tries the decoded form).
    case file(String)
    case invalid(String)

    var isValid: Bool {
        if case .invalid = self { return false }
        return true
    }

    var displayString: String {
        switch self {
        case .http(let url): return url.absoluteString
        case .file(let path): return "file://" + path
        case .invalid(let reason): return "<\(reason)>"
        }
    }
}

// URL rules from the manual (WebParser → URL):
// - http:// and https://, including HTTP authentication `https://name:password@host`.
// - Local files with the file:// scheme and a fully qualified path, e.g. `file://#CURRENTPATH#SomeFile.txt`.
// - "WebParser will automatically URL-Encode … any characters after the protocol://host/path/ portion of the URL that
//   are not one of the following: Unreserved … A-Z a-z 0-9 -_.~  Reserved URL-delimiter characters: !*'();:@&=+$,/?%#[]"
//   (e.g. `?search=I live in München` → `?search=I%20live%20in%20M%C3%BCnchen`). "This is not done when the protocol
//   is file://."
enum WebParserURL {
    /// Parses a URL option / download source. `base` resolves relative references (downloads only).
    ///
    /// Judgment calls:
    /// - Encoding is applied to everything after `scheme://authority` (path, query and fragment): the manual's wording
    ///   is ambiguous, and a literal space in a path is as invalid as one in a query. `%` is kept, so an already
    ///   encoded URL is sent unchanged.
    /// - `file://`, `file:///`, `file://localhost/` and Windows `\` separators are accepted; the path is used as written
    ///   (so `#CURRENTPATH#` with spaces works) and, if no such file exists, percent-decoded.
    /// - A plain absolute path (`/Users/…`) is read as a file, and `//host/…` or `/path` relative to an http `base`
    ///   are resolved against it (lenient: the tutorial shows prefixing the host explicitly, which also works).
    /// - Other schemes (ftp:, …) are not supported.
    static func target(for raw: String, relativeTo base: WebParserTarget? = nil) -> WebParserTarget {
        // Judgment call (the manual sets no limit): a URL longer than `maxURLBytes` is refused before any work. This
        // runs on the skin's thread, and a child with Download=1 whose StringIndex picks a big capture (e.g. the
        // default StringIndex 0 = the whole match) would otherwise encode megabytes there.
        guard raw.utf8.count <= maxURLBytes else { return .invalid("URL longer than \(maxURLBytes / 1024) KB") }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .invalid("empty URL") }
        let lower = text.lowercased()
        if lower.hasPrefix("file:") {
            return .file(filePath(fromFileURL: String(text.dropFirst(5))))
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return httpTarget(text)
        }
        if case .http(let baseURL)? = base, !hasScheme(text) {
            if text.hasPrefix("//") { return httpTarget((baseURL.scheme ?? "https") + ":" + text) }
            let encoded = foundationSafe(encode(text, from: text.startIndex))
            if let url = URL(string: encoded, relativeTo: baseURL)?.absoluteURL,
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return .http(url)
            }
            return .invalid("invalid URL \(text)")
        }
        if text.hasPrefix("/") && !text.hasPrefix("//") { return .file(text) }
        if hasScheme(text) { return .invalid("unsupported URL scheme in \(text)") }
        return .invalid("not a URL: \(text)")
    }

    private static func hasScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let scheme = text[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter, scheme.count >= 2 else { return false }
        return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }
    }

    private static func filePath(fromFileURL rest: String) -> String {
        var p = rest.replacingOccurrences(of: "\\", with: "/")
        while p.hasPrefix("/") { p.removeFirst() }
        if p.lowercased().hasPrefix("localhost/") { p = String(p.dropFirst("localhost".count)) }
        while p.hasPrefix("/") { p.removeFirst() }
        return "/" + p
    }

    private static func httpTarget(_ text: String) -> WebParserTarget {
        guard let schemeEnd = text.range(of: "://") else { return .invalid("invalid URL \(text)") }
        let authorityStart = schemeEnd.upperBound
        let rest = text[authorityStart...]
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? text.endIndex
        let encoded = foundationSafe(encode(text, from: authorityEnd))
        guard let url = URL(string: encoded), let host = url.host, !host.isEmpty else {
            return .invalid("invalid URL \(text)")
        }
        return .http(url)
    }

    /// Characters WebParser leaves alone (manual: unreserved and reserved delimiter characters).
    private static let allowed: Set<UInt8> = {
        var set = Set<UInt8>()
        for b in UInt8(ascii: "A")...UInt8(ascii: "Z") { set.insert(b) }
        for b in UInt8(ascii: "a")...UInt8(ascii: "z") { set.insert(b) }
        for b in UInt8(ascii: "0")...UInt8(ascii: "9") { set.insert(b) }
        for c in "-_.~!*'();:@&=+$,/?%#[]".utf8 { set.insert(c) }
        return set
    }()

    /// Longest URL (in UTF-8 bytes) that is fetched or downloaded.
    static let maxURLBytes = 65_536

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    /// Percent-encodes (UTF-8) every character from `start` on that is not in `allowed`.
    static func encode(_ text: String, from start: String.Index) -> String {
        var out = Array(text[..<start].utf8)
        out.reserveCapacity(text.utf8.count + 16)
        for b in text[start...].utf8 {
            if allowed.contains(b) {
                out.append(b)
            } else {
                out.append(UInt8(ascii: "%"))
                out.append(hexDigits[Int(b >> 4)])
                out.append(hexDigits[Int(b & 0x0F)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Foundation only accepts RFC 3986 URLs: after the authority, `[`, `]`, a `%` not followed by two hex digits and
    /// every `#` after the first are encoded too (servers decode `%5B` like `[`). Judgment call: this goes beyond the
    /// manual's list, but otherwise macOS 14+ `URL(string:)` re-encodes the *whole* string, turning `%20` into `%2520`.
    static func foundationSafe(_ text: String) -> String {
        let b = Array(text.utf8)
        var start = 0
        if let range = text.range(of: "://") {
            start = text.utf8.distance(from: text.startIndex, to: range.upperBound)
            while start < b.count, b[start] != UInt8(ascii: "/"), b[start] != UInt8(ascii: "?"),
                  b[start] != UInt8(ascii: "#") {
                start += 1
            }
        }
        func isHex(_ c: UInt8) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
        }
        var out = Array(b[..<start])
        var seenHash = false
        var i = start
        while i < b.count {
            let c = b[i]
            switch c {
            case UInt8(ascii: "["), UInt8(ascii: "]"):
                out += Array(String(format: "%%%02X", c).utf8)
            case UInt8(ascii: "%") where !(i + 2 < b.count && isHex(b[i + 1]) && isHex(b[i + 2])):
                out += Array("%25".utf8)
            case UInt8(ascii: "#"):
                if seenHash { out += Array("%23".utf8) } else { out.append(c) }
                seenHash = true
            default:
                out.append(c)
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Download destinations

    /// `DownloadFile`: "A folder DownloadFile will be created in the current folder, and the defined relative path
    /// and file name will be created under that. It is not possible to specify an absolute path."
    /// `\` becomes `/`; a drive letter, leading slashes, `.` and `..` components are dropped, so the result always
    /// stays inside `<skin folder>/DownloadFile/`. Nil when nothing usable remains.
    static func downloadFileDestination(skinDirectory: URL, relativePath: String) -> URL? {
        var components: [String] = []
        for part in relativePath.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            var name = String(part).trimmingCharacters(in: .whitespaces)
            if components.isEmpty, name.count == 2, name.hasSuffix(":") { continue }  // C:
            name = sanitizeFileName(name)
            if name.isEmpty || name == "." || name == ".." { continue }
            components.append(name)
        }
        guard !components.isEmpty, components.count <= 32 else { return nil }
        let root = skinDirectory.appendingPathComponent("DownloadFile", isDirectory: true).standardizedFileURL
        var url = root
        for c in components { url.appendPathComponent(c) }
        url = url.standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { return nil }
        return url
    }

    /// True when `root` or any folder from `root` down to `directory` is a symbolic link (or `directory` is not
    /// inside `root`). A skin (or an .rmskin package) could otherwise ship `DownloadFile` as a link to any folder and
    /// have downloads written there. Folders that do not exist yet are fine (they are created as real folders).
    /// Judgment call: the manual only says the path is relative to the DownloadFile folder.
    static func hasSymbolicLink(from root: URL, to directory: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let dirPath = directory.standardizedFileURL.path
        guard dirPath == rootPath || dirPath.hasPrefix(rootPath + "/") else { return true }
        var components = [rootPath]
        var current = rootPath
        for part in dirPath.dropFirst(rootPath.count).split(separator: "/") {
            current += "/" + part
            components.append(current)
        }
        for path in components {
            // attributesOfItem does not follow a link in the last path component (lstat).
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return true }
        }
        return false
    }

    /// Folder for `Download=1` files without `DownloadFile` (the manual's "Windows TEMP folder").
    static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Deskset-WebParser", isDirectory: true)
    }

    /// Temporary file for a download: `<prefix>-<file name of the source URL>`; `prefix` identifies the measure.
    static func temporaryDestination(prefix: String, source: WebParserTarget) -> URL {
        var name = ""
        switch source {
        case .http(let url): name = url.lastPathComponent
        case .file(let path): name = (path as NSString).lastPathComponent
        case .invalid: break
        }
        name = sanitizeFileName(name.removingPercentEncoding ?? name)
        if name.isEmpty || name == "/" || name == "." || name == ".." { name = "download" }
        if name.count > 80 { name = String(name.suffix(80)) }
        return temporaryDirectory.appendingPathComponent(prefix + "-" + name)
    }

    /// Removes path separators, `:` and control characters from one path component.
    static func sanitizeFileName(_ name: String) -> String {
        var out = String.UnicodeScalarView()
        for c in name.unicodeScalars {
            if c == "/" || c == ":" || c == "\\" || c.value < 0x20 || c.value == 0x7F { continue }
            out.append(c)
        }
        var s = String(out)
        while s.hasPrefix(".") && s.count > 2 && s != ".." { s.removeFirst() }  // no hidden files
        if s.utf8.count > 200 { s = String(s.prefix(100)) }
        return s
    }
}
