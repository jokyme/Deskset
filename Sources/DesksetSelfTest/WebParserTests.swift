import Darwin
import Foundation
@testable import DesksetCore

// WebParser measure tests. No internet: resources are local files (file://) or a tiny HTTP server on 127.0.0.1.
// Asynchronous results are awaited by spinning the main run loop (results are applied on DispatchQueue.main).

func runWebParserTests(_ t: TestRunner) {
    runWebParserUnitTests(t)
    runWebParserFileTests(t)
    runWebParserActionTests(t)
    runWebParserDisabledChildTests(t)
    runWebParserDownloadTests(t)
    runWebParserHTTPTests(t)
    runWebParserRobustnessTests(t)
    runWebParserReviewTests(t)
}

// MARK: - Helpers

/// Spins the main run loop until `condition` holds (true) or `timeout` passes (false).
@discardableResult
private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    return true
}

/// Waits until no WebParser measure of the skin is fetching or downloading, then drains the main queue.
@discardableResult
private func settle(_ skin: Skin, timeout: TimeInterval = 10) -> Bool {
    let ok = waitUntil(timeout) {
        !skin.measures.contains { m in
            guard let w = m as? WebParserMeasure else { return false }
            return w.isFetching || w.isDownloading
        }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    return ok
}

/// `skin.update()` then wait for the WebParser work it started.
private func updateAndSettle(_ skin: Skin, times: Int = 1) {
    for _ in 0..<times {
        skin.update()
        settle(skin)
    }
}

private func web(_ skin: Skin, _ name: String) -> WebParserMeasure? {
    skin.measure(named: name) as? WebParserMeasure
}

private func str(_ skin: Skin, _ name: String) -> String {
    skin.measure(named: name)?.stringValue ?? "<no measure \(name)>"
}

private func skinFolder(_ skin: Skin) -> URL { skin.directory }

private func write(_ text: String, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

/// A minimal HTTP/1.1 server on 127.0.0.1 (one request per connection) for deterministic network tests.
final class WebParserTestServer {
    struct Request {
        var method: String
        var target: String
        var headers: [String: String]  // lowercased names
    }

    struct Response {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// Wait this long before answering (time-out tests).
        var delay: TimeInterval = 0

        static func text(_ s: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers, body: Data(s.utf8))
        }
    }

    private(set) var port: UInt16 = 0
    /// Set by `stop()`; the listening thread sees it within 100 ms, closes the socket and signals `finished`.
    private let stopping = StopFlag()
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _requests: [Request] = []
    private var _handler: (Request) -> Response = { _ in .text("", status: 404) }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    var handler: (Request) -> Response {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 32) == 0 else {
            close(fd)
            return nil
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: addr.sin_port)
        // The listening thread owns the socket and closes it itself. Closing it from another thread raced with
        // `accept`: when the thread entered `accept` after the other one's `shutdown`, `close` never returned.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let stopping = self.stopping, finished = self.finished
        let thread = Thread { [weak self] in
            defer {
                close(fd)
                finished.signal()
            }
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            while !stopping.isSet {
                guard poll(&ready, 1, 100) > 0 else { continue }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                // Accepted sockets inherit O_NONBLOCK on macOS; `serve` reads and writes blocking.
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                guard let self else {
                    close(client)
                    break
                }
                DispatchQueue.global().async { self.serve(client) }
            }
        }
        thread.start()
    }

    /// Stops listening: the listening thread closes the socket within 100 ms (waited for, up to 10 s).
    func stop() {
        guard stopping.set() else { return }
        _ = finished.wait(timeout: .now() + 10)
    }

    final class StopFlag {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        /// Sets the flag; false when it was already set.
        func set() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !value else { return false }
            value = true
            return true
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 65536)
        var received: [UInt8] = []
        while received.count < 65536 {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            received += buffer[0..<n]
            if received.count >= 4, String(decoding: received, as: UTF8.self).contains("\r\n\r\n") { break }
        }
        let text = String(decoding: received, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        guard requestLine.count >= 2 else { return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = Request(method: requestLine[0], target: requestLine[1], headers: headers)
        lock.lock()
        _requests.append(request)
        let handler = _handler
        lock.unlock()
        let response = handler(request)
        if response.delay > 0 { Thread.sleep(forTimeInterval: response.delay) }
        var head = "HTTP/1.1 \(response.status) Status\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        var extra = response.headers
        if extra["Cache-Control"] == nil { extra["Cache-Control"] = "no-store" }
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        let bytes = Array(head.utf8) + Array(response.body)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { Darwin.write(client, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            sent += n
        }
    }
}

// A small original RSS-like feed used by several tests.
private let sampleFeed = """
<?xml version="1.0" encoding="utf-8"?>
<rss><channel>
  <title>Deskset Test Feed</title>
  <link>https://example.invalid/feed</link>
  <item>
    <title>First &amp; foremost</title>
    <link>https://example.invalid/1</link>
    <pubDate>Mon, 01 Jan 2024</pubDate>
  </item>
  <item>
    <title>Second &#8211; item</title>
    <link>https://example.invalid/2</link>
    <pubDate>Tue, 02 Jan 2024</pubDate>
  </item>
</channel></rss>
"""

// MARK: - Unit tests (pure helpers)

private func runWebParserUnitTests(_ t: TestRunner) {
    t.suite("WebParser: number value is the leading number") {
        t.equal(WebParserText.leadingNumber("23"), 23)
        t.equal(WebParserText.leadingNumber("  -4.5°C"), -4.5)
        t.equal(WebParserText.leadingNumber("+7 items"), 7)
        t.equal(WebParserText.leadingNumber(".5"), 0.5)
        t.equal(WebParserText.leadingNumber("5."), 5)
        t.equal(WebParserText.leadingNumber("1e3 m"), 1000)
        t.equal(WebParserText.leadingNumber("2e"), 2)
        t.equal(WebParserText.leadingNumber("1.5E-2x"), 0.015)
        t.equal(WebParserText.leadingNumber("abc 12"), 0)
        t.equal(WebParserText.leadingNumber(""), 0)
        t.equal(WebParserText.leadingNumber("-"), 0)
        t.equal(WebParserText.leadingNumber("."), 0)
        t.equal(WebParserText.leadingNumber("1e999"), 0)  // not finite → 0
        t.equal(WebParserText.leadingNumber(String(repeating: "9", count: 300)) > 9e299, true)
        t.equal(WebParserText.leadingNumber(String(repeating: "9", count: 5000)), 0)  // overflows → 0
    }

    t.suite("WebParser: DecodeCharacterReference modes") {
        let s = "&lt;b&gt; Tom &amp; Jerry &#8211; &#x263A; &quot;q&quot; &#146;"
        t.equal(WebParserText.decodeCharacterReferences(s, mode: 0), s)
        t.equal(WebParserText.decodeCharacterReferences(s, mode: 1), "<b> Tom & Jerry – ☺ \"q\" ’")
        t.equal(WebParserText.decodeCharacterReferences(s, mode: 2), "&lt;b&gt; Tom &amp; Jerry – ☺ &quot;q&quot; ’")
        t.equal(WebParserText.decodeCharacterReferences(s, mode: 3), "<b> Tom & Jerry &#8211; &#x263A; \"q\" &#146;")
        t.equal(WebParserText.decodeCharacterReferences(s, mode: 7), s)
        // One pass; unknown, unterminated and invalid references stay.
        t.equal(WebParserText.decodeCharacterReferences("&amp;lt;", mode: 1), "&lt;")
        t.equal(WebParserText.decodeCharacterReferences("&bogus; & &amp &#; &#xZZ; &#0; &#xD800; &#1114112;", mode: 1),
                "&bogus; & &amp &#; &#xZZ; &#0; &#xD800; &#1114112;")
        t.equal(WebParserText.decodeCharacterReferences("&AElig;&aelig;&nbsp;&euro;&Omega;&omega;&hellip;&apos;", mode: 1),
                "Ææ\u{A0}€Ωω…'")
        t.equal(WebParserText.decodeCharacterReferences("&AMP;", mode: 1), "&AMP;")  // names are case-sensitive
        t.equal(WebParserEntities.table.count, 253)  // HTML 4.01 (252) + apos
        t.equal(WebParserEntities.table["yuml"], "\u{FF}")
        t.equal(WebParserEntities.table["Sigma"], "\u{3A3}")
        t.equal(WebParserEntities.table["sigmaf"], "\u{3C2}")
    }

    t.suite("WebParser: DecodeCodePoints") {
        t.equal(WebParserText.decodeCodePoints(#"caf\u00e9 \u263A"#), "café ☺")
        t.equal(WebParserText.decodeCodePoints(#"\U0001F600 \uD83D\uDE00"#), "😀 😀")
        t.equal(WebParserText.decodeCodePoints(#"\u12 \uXYZW \uD83D x \u0000 \"#), #"\u12 \uXYZW \uD83D x \u0000 \"#)
        t.equal(WebParserText.decodeCodePoints("no escapes"), "no escapes")
        t.equal(WebParserText.decodeCodePoints(#"\\u0041"#), #"\A"#)
    }

    t.suite("WebParser: CodePage decoding") {
        let utf16le: [UInt8] = [0xFF, 0xFE] + Array("Größe".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        t.equal(WebParserText.decode(Data(utf16le), codePage: 1200), "Größe")
        t.equal(WebParserText.decode(Data(utf16le), codePage: 0), "Größe")  // BOM detected
        let noBOM = Array(utf16le.dropFirst(2))
        t.equal(WebParserText.decode(Data(noBOM), codePage: 1200), "Größe")
        let utf16be: [UInt8] = Array("Größe".utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        t.equal(WebParserText.decode(Data(utf16be), codePage: 1201), "Größe")
        t.equal(WebParserText.decode(Data("Größe".utf8), codePage: 0), "Größe")
        t.equal(WebParserText.decode(Data([0xEF, 0xBB, 0xBF] + Array("x".utf8)), codePage: 0), "x")
        t.equal(WebParserText.decode(Data([0xEF, 0xBB, 0xBF] + Array("x".utf8)), codePage: 65001), "x")
        let latin1: [UInt8] = [0x47, 0x72, 0xF6, 0xDF, 0x65]  // "Größe" in 1252
        t.equal(WebParserText.decode(Data(latin1), codePage: 1252), "Größe")
        t.equal(WebParserText.decode(Data(latin1), codePage: 0), "Größe")  // invalid UTF-8 → ANSI fallback
        let cyrillic: [UInt8] = [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2]  // "Привет" in 1251
        t.equal(WebParserText.decode(Data(cyrillic), codePage: 1251), "Привет")
        t.equal(WebParserText.decode(Data(cyrillic), codePage: 0, charset: "windows-1251"), "Привет")
        t.equal(WebParserText.decode(Data("Привет".utf8), codePage: 0, charset: "windows-1251"), "Привет")  // UTF-8 wins
        t.equal(WebParserText.decode(Data("ok".utf8), codePage: 99999), "ok")  // unknown code page → detection
        t.equal(WebParserText.decode(Data(), codePage: 1200), "")
        t.equal(WebParserText.decode(Data([0x41]), codePage: 1200), "")  // dangling byte dropped
    }

    t.suite("WebParser: URL targets and encoding") {
        func http(_ s: String) -> String? {
            if case .http(let url) = WebParserURL.target(for: s) { return url.absoluteString }
            return nil
        }
        // Manual example: characters after protocol://host are percent-encoded; reserved delimiters stay.
        t.equal(http("https://somesite.com?search=I live in München"),
                "https://somesite.com?search=I%20live%20in%20M%C3%BCnchen")
        t.equal(http("https://a.example/path with space/x.png"), "https://a.example/path%20with%20space/x.png")
        t.equal(http("https://a.example/q?a=1&b=%20x&c=(1);d=*!'$,+@:~"), "https://a.example/q?a=1&b=%20x&c=(1);d=*!'$,+@:~")
        t.equal(http("  http://127.0.0.1:8080/x  "), "http://127.0.0.1:8080/x")
        t.check(http("https://user:pa%20ss@host.example/") != nil)
        t.equal(http("https://a.example/a[1]?q=[x]#frag#more"), "https://a.example/a%5B1%5D?q=%5Bx%5D#frag%23more")
        t.equal(http("https://a.example/100%"), "https://a.example/100%25")
        t.equal(http("https://h.example/q?a=%20&b=[1]"), "https://h.example/q?a=%20&b=%5B1%5D")  // no double encoding
        t.equal(http("https://[::1]:8080/x"), "https://[::1]:8080/x")  // brackets in the authority stay
        t.equal(http("HTTPS://A.example/"), "HTTPS://A.example/")
        t.check(http("https://") == nil)
        t.check(http("https:///path") == nil)

        t.equal(WebParserURL.target(for: "file:///Users/me/x.txt"), .file("/Users/me/x.txt"))
        t.equal(WebParserURL.target(for: "file:///Users/me/My Files/x.txt"), .file("/Users/me/My Files/x.txt"))
        t.equal(WebParserURL.target(for: "file:////Users/me/x.txt"), .file("/Users/me/x.txt"))
        t.equal(WebParserURL.target(for: "FILE://localhost/tmp/x"), .file("/tmp/x"))
        t.equal(WebParserURL.target(for: #"file://\Users\me\x.txt"#), .file("/Users/me/x.txt"))
        t.equal(WebParserURL.target(for: "/Users/me/x.txt"), .file("/Users/me/x.txt"))
        t.equal(WebParserURL.target(for: "").isValid, false)
        t.equal(WebParserURL.target(for: "ftp://host/x").isValid, false)
        t.equal(WebParserURL.target(for: "www.example.com/x").isValid, false)
        t.equal(WebParserURL.target(for: "[MeasureName]").isValid, false)

        // Relative download sources resolve against an http base (lenient), never against file bases.
        let base = WebParserURL.target(for: "https://host.example/dir/page.html")
        if case .http(let u) = WebParserURL.target(for: "/img/flags/US.png", relativeTo: base) {
            t.equal(u.absoluteString, "https://host.example/img/flags/US.png")
        } else { t.check(false, "relative download") }
        if case .http(let u) = WebParserURL.target(for: "img/a b.png", relativeTo: base) {
            t.equal(u.absoluteString, "https://host.example/dir/img/a%20b.png")
        } else { t.check(false, "relative download 2") }
        if case .http(let u) = WebParserURL.target(for: "//cdn.example/x.png", relativeTo: base) {
            t.equal(u.absoluteString, "https://cdn.example/x.png")
        } else { t.check(false, "protocol-relative download") }
        t.equal(WebParserURL.target(for: "/abs/x.png", relativeTo: .file("/tmp/page.html")), .file("/abs/x.png"))
    }

    t.suite("WebParser: DownloadFile stays inside the skin folder") {
        let dir = URL(fileURLWithPath: "/tmp/Skins/Root/Sub")
        func dest(_ s: String) -> String? {
            WebParserURL.downloadFileDestination(skinDirectory: dir, relativePath: s)?.path
        }
        t.equal(dest("image.png"), "/tmp/Skins/Root/Sub/DownloadFile/image.png")
        t.equal(dest(#"Images\Flags\us.png"#), "/tmp/Skins/Root/Sub/DownloadFile/Images/Flags/us.png")
        t.equal(dest("../../../../etc/passwd"), "/tmp/Skins/Root/Sub/DownloadFile/etc/passwd")
        t.equal(dest("/etc/hosts"), "/tmp/Skins/Root/Sub/DownloadFile/etc/hosts")
        t.equal(dest(#"C:\Temp\x.jpg"#), "/tmp/Skins/Root/Sub/DownloadFile/Temp/x.jpg")
        t.equal(dest("a/./b/../c.txt"), "/tmp/Skins/Root/Sub/DownloadFile/a/b/c.txt")
        t.equal(dest(".hidden"), "/tmp/Skins/Root/Sub/DownloadFile/hidden")
        t.equal(dest(""), nil)
        t.equal(dest("../.."), nil)
        let temp = WebParserURL.temporaryDestination(prefix: "abc", source: WebParserURL.target(for: "https://h.example/i/US.png?x=1"))
        t.equal(temp.lastPathComponent, "abc-US.png")
        t.check(temp.path.hasPrefix(WebParserURL.temporaryDirectory.path))
        t.equal(WebParserURL.temporaryDestination(prefix: "abc", source: WebParserURL.target(for: "https://h.example/")).lastPathComponent,
                "abc-download")
        t.equal(WebParserURL.temporaryDestination(prefix: "p", source: .file("/x/My%20Pic.png")).lastPathComponent, "p-My Pic.png")
    }

    t.suite("WebParser: Header and Flags options") {
        t.check(WebParserMeasure.parseHeader("Cache-Control: no-cache")! == ("Cache-Control", "no-cache"))
        t.check(WebParserMeasure.parseHeader("X-Key:abc:def")! == ("X-Key", "abc:def"))
        t.check(WebParserMeasure.parseHeader("Bad Name: x") == nil)
        t.check(WebParserMeasure.parseHeader("NoColon") == nil)
        t.check(WebParserMeasure.parseHeader(": x") == nil)
        t.check(WebParserMeasure.parseHeader("X: a\rb") == nil)

        let f = WebParserFlags(option: "ForceReload | NoCookies|nocachewrite| PragmaNoCache|NoAuth|IgnoreHTTPRedirect|Resync",
                               forceReload: false)
        t.check(f.forceReload && f.noCookies && f.noCacheWrite && f.pragmaNoCache && f.noAuth && f.allowHTTPSToHTTPRedirect)
        t.equal(f.unsupported, [])
        t.equal(WebParserFlags(option: nil, forceReload: true).forceReload, true)
        t.equal(WebParserFlags(option: "IgnoreCertName|IgnoreCertDate|Bogus", forceReload: false).unsupported,
                ["IgnoreCertName", "IgnoreCertDate", "Bogus"])
        t.check(WebParserNetwork.proxyDictionary("/auto") == nil)
        t.equal(WebParserNetwork.proxyDictionary("proxy.example:8080")?["HTTPSPort"] as? Int, 8080)
        t.equal(WebParserNetwork.proxyDictionary("proxy.example")?["HTTPProxy"] as? String, "proxy.example")
        t.equal(WebParserNetwork.proxyDictionary("/none")?["HTTPEnable"] as? Int, 0)
        t.equal(WebParserNetwork.normalizedProxy(" /AUTO "), "/auto")
    }

    t.suite("WebParser: RegExp captures (PCRE semantics)") {
        let text = "<Item><Name>Larry</Name></Item><Item><Name>Curly</Name></Item>"
        let get = "(?(?=.*<Item>).*<Name>(.*)</Name>)"
        // Lookahead tip: the third item is missing → the match succeeds with two substrings.
        if case .matched(let caps, let count) = WebParserProcessor.match("(?siU)\(get)\(get)\(get)", in: text) {
            t.equal(Array(caps.dropFirst()), ["Larry", "Curly", ""])
            t.equal(count, 3)
        } else { t.check(false, "lookahead match") }
        t.equal(WebParserProcessor.match("(?siU)<Item>.*<Name>(.*)</Name>.*<Item>.*<Name>(.*)</Name>.*<Item>.*<Name>(.*)</Name>",
                                         in: text), .noMatch)
        t.equal(WebParserProcessor.match("(?siU)<title>(.*", in: text), .invalid)
        t.equal(WebParserProcessor.match("(?R)", in: text), .invalid)  // unsupported PCRE feature
        if case .matched(let caps, _) = WebParserProcessor.match("(?siU)<name>(.*)</name>", in: text) {
            t.equal(caps, ["<Name>Larry</Name>", "Larry"])  // ungreedy, case-insensitive
        } else { t.check(false, "siU") }
    }

    t.suite("WebParser: parent / child processing") {
        func options(_ name: String, url: String = "", regExp: String = "", index: Int = 0, index2: Int = 0,
                     download: Bool = false) -> WebParserOptions {
            var o = WebParserOptions()
            o.name = name
            o.url = url
            o.regExp = regExp
            o.stringIndex = index
            o.stringIndex2 = index2
            o.download = download
            return o
        }
        let mark = WebParserProcessor.parentMark
        var itemChild = WebParserNode(options: options("ItemTitle", url: mark, regExp: "(?siU)<title>(.*)</title>",
                                                       index: 3, index2: 1))
        itemChild.children = [WebParserNode(options: options("Grand", url: mark, index: 1))]
        let root = WebParserNode(
            options: options("Site", url: "file:///x", regExp: "(?siU)<title>(.*)</title>.*<link>(.*)</link>.*<item>(.*)</item>"),
            children: [
                WebParserNode(options: options("Title", url: mark, index: 1)),
                WebParserNode(options: options("Link", url: "prefix:" + mark + ":suffix", index: 2)),
                itemChild,
                WebParserNode(options: options("Missing", url: mark, index: 9)),
                WebParserNode(options: options("Image", url: "https://host.example" + mark, index: 1, download: true)),
            ])
        let r = WebParserProcessor.process(root, text: sampleFeed)
        t.equal(r.regExpError, nil)
        t.equal(r.substringCount, 4)
        t.equal(r.value?.hasPrefix("<title>Deskset Test Feed</title>"), true)  // StringIndex 0 = whole match
        t.equal(r.children.map { $0.name }, ["Title", "Link", "ItemTitle", "Missing", "Image"])
        t.equal(r.children[0].value, "Deskset Test Feed")
        t.equal(r.children[1].value, "prefix:https://example.invalid/feed:suffix")
        t.equal(r.children[2].value, "First &amp; foremost")
        t.equal(r.children[2].captures?.count, 2)
        t.equal(r.children[2].children.first?.value, "First &amp; foremost")
        t.equal(r.children[3].value, "")
        t.equal(r.children[3].inputMissing, true)
        t.equal(r.children[4].value, nil)
        t.equal(r.children[4].downloadSource, "https://host.exampleDeskset Test Feed")
        t.check(r.logs.contains { $0.level == .error && $0.message.contains("Not enough substrings") && $0.message.contains("Missing") })

        var quiet = root
        quiet.options.logSubstringErrors = false
        t.check(!WebParserProcessor.process(quiet, text: sampleFeed).logs.contains { $0.message.contains("Not enough") })

        // A failed RegExp leaves values alone (nil) and does not touch the children.
        var bad = root
        bad.options.regExp = "(?siU)<nothing>(.*)</nothing>"
        let failed = WebParserProcessor.process(bad, text: sampleFeed)
        t.check(failed.regExpError != nil)
        t.equal(failed.value, nil)
        t.equal(failed.captures, nil)
        t.equal(failed.children.count, 0)

        // No RegExp: the whole text is the value / capture 0.
        let plain = WebParserProcessor.process(WebParserNode(options: options("P", url: "file:///x")), text: "42 apples")
        t.equal(plain.value, "42 apples")
        t.equal(plain.captures, ["42 apples"])

        // Debug=1 logs every capture with its index.
        var debug = root
        debug.options.debug = 1
        let logs = WebParserProcessor.process(debug, text: sampleFeed).logs.filter { $0.level == .debug }
        t.check(logs.contains { $0.message == "WebParser [Site]: (Index 1) Deskset Test Feed" })
        t.check(logs.contains { $0.message == "WebParser [Site]: (Index 2) https://example.invalid/feed" })
    }
}

// MARK: - Skins reading local files

private func runWebParserFileTests(_ t: TestRunner) {
    t.suite("WebParser: manual usage example with a local file") {
        let (skin, host) = try makeSkin(t, """
        [MeasureParent]
        Measure=WebParser
        URL=file://#CURRENTPATH#feed.xml
        RegExp=(?siU)<item>.*<title>(.*)</title>.*<item>.*<title>(.*)</title>
        FinishAction=[!SetVariable Seen "[MeasureChild1]|[MeasureChild2]"]

        [MeasureChild1]
        Measure=WebParser
        URL=[MeasureParent]
        StringIndex=1

        [MeasureChild2]
        Measure=WebParser
        URL=[MeasureParent]
        StringIndex=2
        DecodeCharacterReference=1

        [MeterChild1]
        Meter=String
        MeasureName=MeasureChild1

        [MeterChild2]
        Meter=String
        MeasureName=MeasureChild2
        Text=2: %1
        """, files: ["Root/Sub/feed.xml": sampleFeed])
        t.equal(web(skin, "MeasureChild1")?.parentName, "MeasureParent")
        t.equal(web(skin, "MeasureParent")?.parentName, nil)
        t.equal(str(skin, "MeasureChild1"), "")  // empty before anything was read
        skin.update()
        t.equal(web(skin, "MeasureParent")?.isFetching, true)  // Skin.update never waits for the resource
        settle(skin)
        t.equal(str(skin, "MeasureChild1"), "First &amp; foremost")
        t.equal(str(skin, "MeasureChild2"), "Second – item")
        // FinishAction ran after the children had their values.
        t.equal(skin.variable("Seen"), "First &amp; foremost|Second – item")
        skin.update()
        t.equal(text(skin, "MeterChild1"), "First &amp; foremost")
        t.equal(text(skin, "MeterChild2"), "2: Second – item")
        t.check(!host.logs.contains { $0.hasPrefix("Error") }, "\(host.logs)")
    }

    t.suite("WebParser: lookahead assertions tip (Larry, Curly, No Moe!)") {
        let (skin, host) = try makeSkin(t, """
        [Variables]
        Get=(?(?=.*<Item>).*<Name>(.*)</Name>)

        [MeasureParent]
        Measure=WebParser
        URL=file://#CURRENTPATH#Test.html
        RegExp="(?siU)#Get##Get##Get#"
        LogSubstringErrors=0

        [MeasureChild1]
        Measure=WebParser
        URL=[MeasureParent]
        StringIndex=1
        Substitute="":"No Moe!"

        [MeasureChild2]
        Measure=WebParser
        URL=[MeasureParent]
        StringIndex=2
        Substitute="":"No Moe!"

        [MeasureChild3]
        Measure=WebParser
        URL=[MeasureParent]
        StringIndex=3
        Substitute="":"No Moe!"

        [MeterChild1]
        Meter=String
        MeasureName=MeasureChild1
        Text=Item 1: %1

        [MeterChild2]
        Meter=String
        MeasureName=MeasureChild2
        Text=Item 2: %1

        [MeterChild3]
        Meter=String
        MeasureName=MeasureChild3
        Text=Item 3: %1
        """, files: ["Root/Sub/Test.html": """
        <HTML>
        \t<BODY>
        \t\t<Item>
        \t\t\t<Name>Larry</Name>
        \t\t</Item>
        \t\t<Item>
        \t\t\t<Name>Curly</Name>
        \t\t</Item>
        \t</BODY>
        </HTML>
        """])
        updateAndSettle(skin, times: 2)
        t.equal(text(skin, "MeterChild1"), "Item 1: Larry")
        t.equal(text(skin, "MeterChild2"), "Item 2: Curly")
        t.equal(text(skin, "MeterChild3"), "Item 3: No Moe!")
        t.check(!host.logs.contains { $0.contains("Not enough substrings") })  // LogSubstringErrors=0
    }

    t.suite("WebParser: StringIndex2 tip (child measures with their own RegExp)") {
        let (skin, _) = try makeSkin(t, """
        [Variables]
        Item=.*<item>(.*)</item>
        Sub="<![CDATA[":"","]]>":""

        [MeasureSite]
        Measure=WebParser
        Url=file://#CURRENTPATH#feed.xml
        RegExp=(?siU)<channel>.*<title>(.*)</title>.*<link>(.*)</link>#Item##Item#

        [MeasureMainTitle]
        Measure=WebParser
        Url=[MeasureSite]
        StringIndex=1
        Substitute=#Sub#

        [MeasureItem1Title]
        Measure=WebParser
        Url=[MeasureSite]
        RegExp=(?siU)<title>(.*)</title>
        StringIndex=3
        StringIndex2=1
        Substitute=#Sub#
        DecodeCharacterReference=1

        [MeasureItem2Link]
        Measure=WebParser
        Url=[MeasureSite]
        RegExp=(?siU)<link>(.*)</link>
        StringIndex=4
        StringIndex2=1

        [MeasureItem2Date]
        Measure=WebParser
        Url=[MeasureItem2]
        StringIndex=1

        [MeasureItem2]
        Measure=WebParser
        Url=[MeasureSite]
        RegExp=(?siU)<pubDate>(.*)</pubDate>
        StringIndex=4
        """, files: ["Root/Sub/feed.xml": sampleFeed.replacingOccurrences(of: "<title>Deskset Test Feed</title>",
                                                                           with: "<title><![CDATA[Deskset Test Feed]]></title>")])
        updateAndSettle(skin, times: 2)
        t.equal(str(skin, "MeasureMainTitle"), "Deskset Test Feed")
        t.equal(str(skin, "MeasureItem1Title"), "First & foremost")
        t.equal(str(skin, "MeasureItem2Link"), "https://example.invalid/2")
        // A grandchild reads the captures of a child that has a RegExp (defined before its parent in the file).
        t.equal(web(skin, "MeasureItem2Date")?.parentName, "MeasureItem2")
        t.equal(str(skin, "MeasureItem2Date"), "Tue, 02 Jan 2024")
        t.equal(web(skin, "MeasureItem2")?.captures.last, "Tue, 02 Jan 2024")
    }

    t.suite("WebParser: parent value, number value and dynamic range") {
        let (skin, _) = try makeSkin(t, """
        [Parent]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        RegExp=(?siU)temp=(.*);.*label=(.*);
        StringIndex=2

        [Temp]
        Measure=WebParser
        URL=[Parent]
        StringIndex=1

        [TempFixed]
        Measure=WebParser
        URL=[Parent]
        StringIndex=1
        MinValue=-50
        MaxValue=50

        [Calc]
        Measure=Calc
        Formula=Temp * 2

        [Bar]
        Meter=Bar
        MeasureName=Temp
        W=10
        H=10
        """, files: ["Root/Sub/data.txt": "temp=23.5°C; label=Outside;"])
        updateAndSettle(skin, times: 2)
        let temp = skin.measure(named: "Temp")!
        t.equal(str(skin, "Parent"), "Outside")
        t.equal(skin.measure(named: "Parent")?.value, 0)
        t.equal(str(skin, "Temp"), "23.5°C")
        t.equal(temp.value, 23.5)
        t.equal(skin.measure(named: "Calc")?.value, 47)
        t.equal(temp.minValue, 0)
        t.equal(temp.maxValue, 23.5)
        t.equal(temp.relativeValue, 1)
        t.equal(skin.measure(named: "TempFixed")?.minValue, -50)
        t.equal(skin.measure(named: "TempFixed")?.maxValue, 50)
        t.equal(skin.measure(named: "TempFixed")?.relativeValue, 0.735)
    }

    t.suite("WebParser: UpdateRate counts measure updates") {
        let (skin, _) = try makeSkin(t, """
        [Parent]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        RegExp=(?siU)v=(.*);
        StringIndex=1
        UpdateRate=3
        """, files: ["Root/Sub/data.txt": "v=1;"])
        let parent = web(skin, "Parent")!
        let file = skinFolder(skin).appendingPathComponent("data.txt")
        updateAndSettle(skin)  // update 1: fetch
        t.equal(parent.fetchCount, 1)
        t.equal(str(skin, "Parent"), "1")
        write("v=2;", to: file)
        updateAndSettle(skin, times: 2)  // updates 2, 3: nothing
        t.equal(parent.fetchCount, 1)
        t.equal(str(skin, "Parent"), "1")
        updateAndSettle(skin)  // update 4: fetch again
        t.equal(parent.fetchCount, 2)
        t.equal(str(skin, "Parent"), "2")
        // !UpdateMeasure only advances the counter (tip: "one measure update closer").
        write("v=3;", to: file)
        skin.execute("[!UpdateMeasure Parent]", from: nil)  // counter 1 → 2
        settle(skin)
        t.equal(parent.fetchCount, 2)
        updateAndSettle(skin)  // counter 2 → wraps to 0
        t.equal(parent.fetchCount, 2)
        updateAndSettle(skin)  // fetch one update earlier than without the bang
        t.equal(parent.fetchCount, 3)
        t.equal(str(skin, "Parent"), "3")
        // !CommandMeasure Update fetches now and restarts the cycle.
        write("v=4;", to: file)
        skin.execute("[!CommandMeasure Parent \"Update\"]", from: nil)
        settle(skin)
        t.equal(parent.fetchCount, 4)
        t.equal(str(skin, "Parent"), "4")
        updateAndSettle(skin, times: 2)
        t.equal(parent.fetchCount, 4)
        updateAndSettle(skin)
        t.equal(parent.fetchCount, 5)
    }

    t.suite("WebParser: UpdateRate edge values and UpdateDivider") {
        let (skin, _) = try makeSkin(t, """
        [Once]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        UpdateRate=0

        [Negative]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        UpdateRate=-5

        [Every]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        UpdateRate=1

        [Divided]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        UpdateRate=2
        UpdateDivider=2
        """, files: ["Root/Sub/data.txt": "x"])
        updateAndSettle(skin, times: 8)
        t.equal(web(skin, "Once")?.fetchCount, 1)
        t.equal(web(skin, "Negative")?.fetchCount, 1)
        t.equal(web(skin, "Every")?.fetchCount, 8)
        t.equal(web(skin, "Divided")?.fetchCount, 2)  // measure updates 1,3,5,7 → fetches at 1 and 5
        skin.execute("[!CommandMeasure Once Update]", from: nil)
        settle(skin)
        t.equal(web(skin, "Once")?.fetchCount, 2)
    }

    t.suite("WebParser: !SetOption URL + !CommandMeasure Update (manual example)") {
        let (skin, _) = try makeSkin(t, """
        [WebMeasure]
        Measure=WebParser
        URL=file://#CURRENTPATH#a.txt
        RegExp=(?siU)^(.*)$
        StringIndex=1

        [Child]
        Measure=WebParser
        URL=[WebMeasure]
        StringIndex=1

        [MeterButton]
        Meter=String
        Text=x
        LeftMouseUpAction=[!SetOption WebMeasure URL "file://#CURRENTPATH#b.txt"][!CommandMeasure WebMeasure Update]
        """, files: ["Root/Sub/a.txt": "from a", "Root/Sub/b.txt": "from b"])
        updateAndSettle(skin)
        t.equal(str(skin, "Child"), "from a")
        skin.mouseEvent(.leftUp, x: 1, y: 1)
        settle(skin)
        t.equal(str(skin, "WebMeasure"), "from b")
        t.equal(str(skin, "Child"), "from b")
        // A changed child option is picked up when the parent is updated.
        skin.execute("[!SetOption Child StringIndex 0][!CommandMeasure WebMeasure Update]", from: nil)
        settle(skin)
        t.equal(str(skin, "Child"), "from b")
        // !CommandMeasure on a child is ignored (with a warning).
        skin.execute("[!CommandMeasure Child Update]", from: nil)
        settle(skin)
        t.equal(web(skin, "Child")?.fetchCount, 0)
    }

    t.suite("WebParser: [&Measure] in URL is a section variable, not a parent") {
        let (skin, _) = try makeSkin(t, """
        [FileName]
        Measure=String
        String=b.txt

        [Picker]
        Measure=WebParser
        URL=file://#CURRENTPATH#a.txt

        [Dynamic]
        Measure=WebParser
        URL=file://#CURRENTPATH#[&FileName]
        DynamicVariables=1

        [ViaPicker]
        Measure=WebParser
        URL=file://#CURRENTPATH#[&Picker]
        DynamicVariables=1
        UpdateRate=1
        """, files: ["Root/Sub/a.txt": "b.txt", "Root/Sub/b.txt": "B contents"])
        updateAndSettle(skin, times: 3)
        t.equal(web(skin, "Dynamic")?.parentName, nil)
        t.equal(str(skin, "Dynamic"), "B contents")
        t.equal(web(skin, "ViaPicker")?.parentName, nil)
        t.equal(str(skin, "ViaPicker"), "B contents")
    }

    t.suite("WebParser: CodePage=1200 local file and Debug=2 dump") {
        let utf16: [UInt8] = [0xFF, 0xFE] + Array("<v>Grüße ☺</v>".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let (skin, _) = try makeSkin(t, """
        [Parent]
        Measure=WebParser
        URL=file://#CURRENTPATH#u16.txt
        CodePage=1200
        RegExp=(?siU)<v>(.*)</v>
        StringIndex=1
        Debug=2

        [Custom]
        Measure=WebParser
        URL=file://#CURRENTPATH#plain.txt
        Debug=2
        Debug2File=#CURRENTPATH#Dumps\\dump.txt

        [Outside]
        Measure=WebParser
        URL=file://#CURRENTPATH#plain.txt
        Debug=2
        Debug2File=/tmp/deskset-webparser-should-not-exist.txt
        """, files: ["Root/Sub/plain.txt": "plain", "Root/Sub/Dumps/.keep": ""])
        try Data(utf16).write(to: skinFolder(skin).appendingPathComponent("u16.txt"))
        updateAndSettle(skin)
        t.equal(str(skin, "Parent"), "Grüße ☺")
        let dump = skinFolder(skin).appendingPathComponent("WebParserDump.txt")
        t.check(((try? String(contentsOf: dump, encoding: .utf8)) ?? "").contains("<v>Grüße ☺</v>")
                || ((try? String(contentsOf: dump, encoding: .utf8)) ?? "") == "plain")
        t.equal(try? String(contentsOf: skinFolder(skin).appendingPathComponent("Dumps/dump.txt"), encoding: .utf8),
                "plain")
        t.check(!FileManager.default.fileExists(atPath: "/tmp/deskset-webparser-should-not-exist.txt"))
    }
}

// MARK: - Actions and errors

private func runWebParserActionTests(_ t: TestRunner) {
    t.suite("WebParser: OnConnectErrorAction keeps the last values") {
        let (skin, host) = try makeSkin(t, """
        [Parent]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        RegExp=(?siU)v=(.*);
        StringIndex=1
        UpdateRate=1
        FinishAction=[!SetVariable Finished "[Parent]"]
        OnConnectErrorAction=[!SetVariable ConnectError "yes"]

        [Child]
        Measure=WebParser
        URL=[Parent]
        StringIndex=1
        """, files: ["Root/Sub/data.txt": "v=good;"])
        updateAndSettle(skin)
        t.equal(str(skin, "Child"), "good")
        t.equal(skin.variable("Finished"), "good")
        try FileManager.default.removeItem(at: skinFolder(skin).appendingPathComponent("data.txt"))
        skin.setVariable("Finished", "")
        updateAndSettle(skin)
        t.equal(skin.variable("ConnectError"), "yes")
        t.equal(skin.variable("Finished"), "")  // no FinishAction without a connection
        t.equal(str(skin, "Parent"), "good")
        t.equal(str(skin, "Child"), "good")
        t.check(host.logs.contains { $0.hasPrefix("Warning") && $0.contains("file not found") })
    }

    t.suite("WebParser: RegExp errors, OnRegExpErrorAction, FinishAction and ErrorString") {
        let (skin, _) = try makeSkin(t, """
        [WithHandler]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        RegExp=(?siU)<missing>(.*)</missing>
        StringIndex=1
        FinishAction=[!SetVariable A_Finish 1]
        OnRegExpErrorAction=[!SetVariable A_Error 1]

        [WithoutHandler]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        RegExp=(?siU)<missing>(.*)</missing>
        FinishAction=[!SetVariable B_Finish 1]

        [Invalid]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        RegExp=(?siU)<v>(.*</v>
        ErrorString=Parse failed
        OnRegExpErrorAction=[!SetVariable C_Error 1]

        [Child]
        Measure=WebParser
        URL=[Invalid]
        StringIndex=1
        """, files: ["Root/Sub/data.txt": "<v>1</v>"])
        updateAndSettle(skin)
        t.equal(skin.variable("A_Error"), "1")
        t.equal(skin.variable("A_Finish"), nil)
        t.equal(skin.variable("B_Finish"), "1")
        t.equal(skin.variable("C_Error"), "1")
        t.equal(str(skin, "Invalid"), "Parse failed")
        t.equal(str(skin, "Child"), "")
        t.equal(str(skin, "WithHandler"), "")
    }

    t.suite("WebParser: !CommandMeasure Reset empties parent and children") {
        let (skin, _) = try makeSkin(t, """
        [Parent]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        RegExp=(?siU)a=(.*);b=(.*);
        StringIndex=1

        [ChildB]
        Measure=WebParser
        URL=[Parent]
        StringIndex=2

        [Other]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        """, files: ["Root/Sub/data.txt": "a=12;b=34;"])
        updateAndSettle(skin)
        t.equal(str(skin, "Parent"), "12")
        t.equal(str(skin, "ChildB"), "34")
        t.equal(skin.measure(named: "ChildB")?.value, 34)
        skin.execute("[!CommandMeasure Parent Reset]", from: nil)
        t.equal(str(skin, "Parent"), "")
        t.equal(str(skin, "ChildB"), "")
        t.equal(skin.measure(named: "ChildB")?.value, 0)
        t.equal(web(skin, "Parent")?.captures, [])
        t.equal(str(skin, "Other"), "a=12;b=34;")
        skin.update()
        t.equal(str(skin, "ChildB"), "")  // stays empty until the next fetch
        skin.execute("[!CommandMeasure ChildB Reset][!CommandMeasure Parent Bogus]", from: nil)
    }

    t.suite("WebParser: OnChangeAction runs on the first completed read") {
        let (skin, _) = try makeSkin(t, """
        [Parent]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        OnChangeAction=[!SetVariable Changed "[Parent]"]
        IfMatch=^hello$
        IfMatchAction=[!SetVariable Matched 1]
        """, files: ["Root/Sub/data.txt": "hello"])
        updateAndSettle(skin, times: 2)
        t.equal(skin.variable("Changed"), "hello")
        t.equal(skin.variable("Matched"), "1")
    }

    t.suite("WebParser: file access policy hook") {
        let saved = WebParserMeasure.allowsFileAccess
        defer { WebParserMeasure.allowsFileAccess = saved }
        WebParserMeasure.allowsFileAccess = { path, skin in path.hasPrefix(skin.skinsDirectory.path) }
        let outside = t.temporaryDirectory("webparser-outside").appendingPathComponent("secret.txt")
        write("secret", to: outside)
        let (skin, _) = try makeSkin(t, """
        [Inside]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt

        [Outside]
        Measure=WebParser
        URL=file://\(outside.path)
        OnConnectErrorAction=[!SetVariable Refused 1]
        """, files: ["Root/Sub/data.txt": "inside"])
        updateAndSettle(skin)
        t.equal(str(skin, "Inside"), "inside")
        t.equal(str(skin, "Outside"), "")
        t.equal(skin.variable("Refused"), "1")
    }

    t.suite("WebParser: Disabled and Paused measures do not fetch") {
        let (skin, _) = try makeSkin(t, """
        [Off]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        Disabled=1

        [Hold]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        Paused=1
        """, files: ["Root/Sub/data.txt": "x"])
        updateAndSettle(skin, times: 2)
        t.equal(web(skin, "Off")?.fetchCount, 0)
        t.equal(web(skin, "Hold")?.fetchCount, 0)
        skin.execute("[!CommandMeasure Off Update]", from: nil)
        t.equal(web(skin, "Off")?.fetchCount, 0)
        skin.execute("[!EnableMeasure Off][!UnpauseMeasure Hold]", from: nil)
        updateAndSettle(skin)
        t.equal(str(skin, "Off"), "x")
        t.equal(str(skin, "Hold"), "x")
    }
}

// MARK: - Disabled and paused children

private let releasePage = """
<html><body>
<a href="/example/widget/releases/tag/2.1.0">Widget 2.1.0</a>
<img src="img/logo.png">
</body></html>
"""

private func runWebParserDisabledChildTests(_ t: TestRunner) {
    t.suite("WebParser: disabled and paused children get their values from the parent's read") {
        let (skin, _) = try makeSkin(t, """
        [Variables]
        Index=1

        [Parent]
        Measure=WebParser
        URL=file://#CURRENTPATH#release.html
        RegExp=(?siU)tag/(.*)">(.*)</a>.*src="(.*)"

        [Off]
        Measure=Plugin
        Plugin=WebParser
        URL=[Parent]
        StringIndex=1
        Disabled=1

        [Held]
        Measure=WebParser
        URL=[Parent]
        StringIndex=2
        Paused=1

        [Logo]
        Measure=WebParser
        URL=file://#CURRENTPATH#[Parent]
        StringIndex=3
        Download=1
        DownloadFile=logo.png
        Disabled=1

        [Dynamic]
        Measure=WebParser
        URL=[Parent]
        StringIndex=#Index#
        DynamicVariables=1
        Disabled=1

        [Forgotten]
        Measure=WebParser
        URL=[Parent]
        StringIndex=1
        Disabled=1
        """, files: ["Root/Sub/release.html": releasePage, "Root/Sub/img/logo.png": "LOGO"])
        // Known as children from the start, although they do not run.
        for name in ["Off", "Held", "Logo", "Dynamic", "Forgotten"] {
            t.equal(web(skin, name)?.parentName, "Parent", name)
        }
        updateAndSettle(skin)
        t.equal(web(skin, "Parent")?.fetchCount, 1)
        // Not shown while disabled or paused ("never updated").
        t.equal(str(skin, "Off"), "")
        t.equal(skin.measure(named: "Off")?.value, 0)
        t.equal(str(skin, "Held"), "")
        t.equal(str(skin, "Logo"), "")
        // Running again, they show what the parent read meanwhile at their first update (no new read: UpdateRate).
        skin.setVariable("Index", "2")
        skin.execute("[!EnableMeasure Off][!UnpauseMeasure Held][!EnableMeasure Logo][!EnableMeasure Dynamic]",
                     from: nil)
        skin.update()
        t.equal(web(skin, "Parent")?.fetchCount, 1)
        t.equal(str(skin, "Off"), "2.1.0")
        t.equal(skin.measure(named: "Off")?.value, 2.1)
        t.equal(str(skin, "Held"), "Widget 2.1.0")
        let logo = (skinFolder(skin).appendingPathComponent("DownloadFile/logo.png").path as NSString).standardizingPath
        t.equal(str(skin, "Logo"), logo, "downloaded while disabled")
        t.equal(try? String(contentsOfFile: logo, encoding: .utf8), "LOGO")
        // An option changed while the child was disabled counts from the parent's next read, like `!SetOption` on a
        // child ("you MUST use !CommandMeasure with Update, targeting the parent").
        t.equal(str(skin, "Dynamic"), "2.1.0")
        skin.execute("[!CommandMeasure Parent Update]", from: nil)
        settle(skin)
        t.equal(str(skin, "Dynamic"), "Widget 2.1.0")
        // Reset reaches a child that has never run.
        skin.execute("[!CommandMeasure Parent Reset][!EnableMeasure Forgotten]", from: nil)
        skin.update()
        t.equal(str(skin, "Forgotten"), "")
        t.equal(str(skin, "Off"), "")
    }

    guard let server = WebParserTestServer() else {
        t.suite("WebParser: disabled-child HTTP test server") { t.check(false, "cannot start the local HTTP server") }
        return
    }
    defer { server.stop() }
    server.handler = { request in
        request.target == "/releases/latest" ? .text(releasePage) : .text("", status: 404)
    }

    // An update checker: the version check is enabled by the page's FinishAction, which also stops the page from
    // being read again (the pattern of Monstercat Visualizer's update notice).
    func updateChecker(installed: String) -> String {
        """
        [Variables]
        Installed=\(installed)

        [ReleasePage]
        Measure=WebParser
        URL=\(server.url("/releases/latest"))
        RegExp=(?siU)"/example/widget/releases/tag/(.*)"
        FinishAction=[!EnableMeasure LatestRelease][!PauseMeasure ReleasePage][!PauseMeasure InstalledVersion]

        [InstalledVersion]
        Measure=String
        String=#Installed#
        UpdateDivider=-1

        [LatestRelease]
        Measure=Plugin
        Plugin=WebParser
        URL=[ReleasePage]
        StringIndex=1
        IfMatch=[InstalledVersion:EscapeRegExp]
        IfMatchAction=[!PauseMeasure LatestRelease][!SetVariable Outcome "current [LatestRelease]"]
        IfNotMatchAction=[!PauseMeasure LatestRelease][!SetVariable Outcome "newer [LatestRelease]"]
        DynamicVariables=1
        Disabled=1

        [MeterLatest]
        Meter=String
        MeasureName=LatestRelease
        Text=Latest: %1
        """
    }

    t.suite("WebParser: a child enabled by the parent's FinishAction reads the parsed value at its first update") {
        let before = server.requests.count
        let (skin, host) = try makeSkin(t, updateChecker(installed: "2.1.0"))
        skin.update()
        settle(skin)
        t.equal(web(skin, "LatestRelease")?.disabled, false, "enabled by FinishAction")
        t.equal(skin.variable("Outcome"), nil, "the child has not updated since")
        skin.update()
        t.equal(skin.variable("Outcome"), "current 2.1.0")
        t.equal(text(skin, "MeterLatest"), "Latest: 2.1.0")
        updateAndSettle(skin, times: 3)
        t.equal(skin.variable("Outcome"), "current 2.1.0")
        t.equal(server.requests.count - before, 1, "one read")
        t.check(!host.logs.contains { $0.hasPrefix("Error") }, "\(host.logs)")

        let (older, _) = try makeSkin(t, updateChecker(installed: "2.0.0"))
        updateAndSettle(older, times: 2)
        t.equal(older.variable("Outcome"), "newer 2.1.0")
    }
}

// MARK: - Download

private func runWebParserDownloadTests(_ t: TestRunner) {
    t.suite("WebParser: Download=1 of the resource itself (temporary file)") {
        var tempPath = ""
        do {
            let (skin, _) = try makeSkin(t, """
            [Image]
            Measure=WebParser
            URL=file://#CURRENTPATH#pic.png
            Download=1
            FinishAction=[!SetVariable Done "[Image]"]

            [MeterImage]
            Meter=Image
            MeasureName=Image
            """, files: ["Root/Sub/pic.png": "PNGDATA"])
            updateAndSettle(skin)
            tempPath = str(skin, "Image")
            t.check(tempPath.hasPrefix(WebParserURL.temporaryDirectory.path), tempPath)
            t.check(tempPath.hasSuffix("-pic.png"), tempPath)
            t.equal(try? String(contentsOfFile: tempPath, encoding: .utf8), "PNGDATA")
            t.equal(skin.variable("Done"), tempPath)
        }
        // The temporary file goes away with the measure (the skin was released above).
        t.check(!FileManager.default.fileExists(atPath: tempPath), "temporary download not deleted: \(tempPath)")
    }

    t.suite("WebParser: child Download=1 with DownloadFile and a URL prefix") {
        let (skin, _) = try makeSkin(t, """
        [Parent]
        Measure=WebParser
        URL=file://#CURRENTPATH#page.html
        RegExp=(?siU)src="(.*)".*src="(.*)"

        [Flag]
        Measure=WebParser
        URL=file://#CURRENTPATH#[Parent]
        StringIndex=1
        Download=1
        DownloadFile=Images\\flag.png
        FinishAction=[!SetVariable FlagDone 1]
        OnDownloadErrorAction=[!SetVariable FlagError 1]

        [Missing]
        Measure=WebParser
        URL=file://#CURRENTPATH#[Parent]
        StringIndex=2
        Download=1
        FinishAction=[!SetVariable MissingDone 1]
        OnDownloadErrorAction=[!SetVariable MissingError 1]
        """, files: ["Root/Sub/page.html": #"<img src="img/US.png"> <img src="img/none.png">"#,
                     "Root/Sub/img/US.png": "FLAG"])
        updateAndSettle(skin)
        let expected = skinFolder(skin).appendingPathComponent("DownloadFile/Images/flag.png").path
        t.equal(str(skin, "Flag"), (expected as NSString).standardizingPath)
        t.equal(try? String(contentsOfFile: expected, encoding: .utf8), "FLAG")
        t.equal(skin.variable("FlagDone"), "1")
        t.equal(skin.variable("FlagError"), nil)
        t.equal(skin.variable("MissingError"), "1")
        t.equal(skin.variable("MissingDone"), nil)
        t.equal(str(skin, "Missing"), "")
    }

    t.suite("WebParser: Download=1 of a missing resource runs OnConnectErrorAction") {
        let (skin, _) = try makeSkin(t, """
        [Image]
        Measure=WebParser
        URL=file://#CURRENTPATH#none.png
        Download=1
        OnConnectErrorAction=[!SetVariable Connect 1]
        OnDownloadErrorAction=[!SetVariable Download 1]
        """)
        updateAndSettle(skin)
        t.equal(skin.variable("Connect"), "1")
        t.equal(skin.variable("Download"), nil)
    }
}

// MARK: - HTTP (local server)

private func runWebParserHTTPTests(_ t: TestRunner) {
    guard let server = WebParserTestServer() else {
        t.suite("WebParser: HTTP test server") { t.check(false, "cannot start the local HTTP server") }
        return
    }
    defer { server.stop() }

    t.suite("WebParser: HTTP request headers, UserAgent and URL encoding") {
        server.handler = { request in
            .text("<title>Hello \(request.target)</title>")
        }
        let (skin, _) = try makeSkin(t, """
        [Parent]
        Measure=WebParser
        URL=\(server.url("/search?q=I live in München&x=[1]"))
        RegExp=(?siU)<title>(.*)</title>
        StringIndex=1
        UserAgent=TestAgent/1.0
        Header=X-Custom: one
        Header2=Accept-Language: de
        Header3=Broken Header
        Flags=PragmaNoCache|NoCookies
        """)
        updateAndSettle(skin)
        let request = server.requests.last
        t.check(request?.target.hasPrefix("/search?q=I%20live%20in%20M%C3%BCnchen&x=") == true, "\(request?.target ?? "-")")
        t.equal(request?.headers["user-agent"], "TestAgent/1.0")
        t.equal(request?.headers["x-custom"], "one")
        t.equal(request?.headers["accept-language"], "de")
        t.equal(request?.headers["pragma"], "no-cache")
        t.check(str(skin, "Parent").hasPrefix("Hello /search?q=I%20live%20in%20M%C3%BCnchen"), str(skin, "Parent"))
    }

    t.suite("WebParser: HTTP default UserAgent, 404 body is parsed, redirects are followed") {
        server.handler = { request in
            switch request.target {
            case "/missing": return .text("<h1>Not Found</h1>", status: 404)
            case "/old": return .text("", status: 301, headers: ["Location": "/new"])
            case "/new": return .text("<v>moved</v>")
            case "/loop": return .text("", status: 302, headers: ["Location": "/loop"])
            default: return .text("", status: 500)
            }
        }
        let (skin, _) = try makeSkin(t, """
        [NotFound]
        Measure=WebParser
        URL=\(server.url("/missing"))
        RegExp=(?siU)<v>(.*)</v>
        OnRegExpErrorAction=[!SetVariable RegErr 1]
        OnConnectErrorAction=[!SetVariable ConnErr 1]

        [NotFoundRaw]
        Measure=WebParser
        URL=\(server.url("/missing"))

        [Redirected]
        Measure=WebParser
        URL=\(server.url("/old"))
        RegExp=(?siU)<v>(.*)</v>
        StringIndex=1

        [Loop]
        Measure=WebParser
        URL=\(server.url("/loop"))
        RegExp=(?siU)<v>(.*)</v>
        OnRegExpErrorAction=[!SetVariable LoopErr 1]
        """)
        updateAndSettle(skin)
        t.equal(skin.variable("RegErr"), "1")
        t.equal(skin.variable("ConnErr"), nil)
        t.equal(str(skin, "NotFoundRaw"), "<h1>Not Found</h1>")
        t.equal(str(skin, "Redirected"), "moved")
        t.equal(skin.variable("LoopErr"), "1")
        t.check(server.requests.contains { $0.headers["user-agent"] == WebParserNetwork.defaultUserAgent })
        t.check(server.requests.filter { $0.target == "/loop" }.count <= WebParserNetwork.maxRedirects + 1)
    }

    t.suite("WebParser: HTTP basic authentication from the URL") {
        server.handler = { request in
            // "user:secret" in base64
            if request.headers["authorization"] == "Basic dXNlcjpzZWNyZXQ=" { return .text("<v>welcome</v>") }
            return .text("denied", status: 401, headers: ["WWW-Authenticate": "Basic realm=\"test\""])
        }
        let port = server.port
        let (skin, _) = try makeSkin(t, """
        [Parent]
        Measure=WebParser
        URL=http://user:secret@127.0.0.1:\(port)/private
        RegExp=(?siU)<v>(.*)</v>
        StringIndex=1

        [NoAuth]
        Measure=WebParser
        URL=http://user:secret@127.0.0.1:\(port)/private2
        Flags=NoAuth
        """)
        updateAndSettle(skin)
        t.equal(str(skin, "Parent"), "welcome")
        t.equal(str(skin, "NoAuth"), "denied")
    }

    t.suite("WebParser: HTTP downloads (status errors, relative sources)") {
        server.handler = { request in
            switch request.target {
            case "/page": return .text(#"<img src="/img/a.png"><img src="/img/gone.png">"#)
            case "/img/a.png": return WebParserTestServer.Response(status: 200, body: Data([0x89, 0x50, 0x4E, 0x47]))
            default: return .text("nope", status: 404)
            }
        }
        let (skin, _) = try makeSkin(t, """
        [Page]
        Measure=WebParser
        URL=\(server.url("/page"))
        RegExp=(?siU)src="(.*)".*src="(.*)"

        [A]
        Measure=WebParser
        URL=[Page]
        StringIndex=1
        Download=1
        FinishAction=[!SetVariable ADone 1]

        [Gone]
        Measure=WebParser
        URL=\(server.url(""))[Page]
        StringIndex=2
        Download=1
        OnDownloadErrorAction=[!SetVariable GoneError 1]

        [Direct404]
        Measure=WebParser
        URL=\(server.url("/img/none.png"))
        Download=1
        OnConnectErrorAction=[!SetVariable DirectConnect 1]
        OnDownloadErrorAction=[!SetVariable DirectDownload 1]
        """)
        updateAndSettle(skin)
        t.equal(skin.variable("ADone"), "1")
        t.equal(try? Data(contentsOf: URL(fileURLWithPath: str(skin, "A"))), Data([0x89, 0x50, 0x4E, 0x47]))
        t.equal(skin.variable("GoneError"), "1")
        t.equal(skin.variable("DirectDownload"), "1")
        t.equal(skin.variable("DirectConnect"), nil)
    }

    t.suite("WebParser: HTTP size cap and time-out are connection errors") {
        let savedMax = WebParserNetwork.maxPageBytes
        let savedTimeout = WebParserNetwork.requestTimeout
        WebParserNetwork.maxPageBytes = 1000
        WebParserNetwork.requestTimeout = 1
        defer {
            WebParserNetwork.maxPageBytes = savedMax
            WebParserNetwork.requestTimeout = savedTimeout
        }
        server.handler = { request in
            if request.target == "/slow" { return WebParserTestServer.Response(status: 200, body: Data("late".utf8), delay: 3) }
            return .text(String(repeating: "x", count: 5000))
        }
        let (skin, _) = try makeSkin(t, """
        [Big]
        Measure=WebParser
        URL=\(server.url("/big"))
        OnConnectErrorAction=[!SetVariable BigErr 1]

        [Slow]
        Measure=WebParser
        URL=\(server.url("/slow"))
        OnConnectErrorAction=[!SetVariable SlowErr 1]
        """, files: ["Root/Sub/big.txt": String(repeating: "y", count: 5000)])
        let started = Date()
        skin.update()
        t.check(Date().timeIntervalSince(started) < 0.5, "Skin.update must not wait for the network")
        settle(skin, timeout: 15)
        t.equal(skin.variable("BigErr"), "1")
        t.equal(skin.variable("SlowErr"), "1")
        t.equal(str(skin, "Big"), "")
        t.equal(WebParserNetwork.readFile(skinFolder(skin).appendingPathComponent("big.txt").path, maxBytes: 1000).isTooLarge,
                true)
    }

    t.suite("WebParser: a newer fetch supersedes one in flight") {
        server.handler = { request in
            if request.target == "/slow" { return WebParserTestServer.Response(status: 200, body: Data("<v>old</v>".utf8), delay: 0.5) }
            return .text("<v>new</v>")
        }
        let (skin, _) = try makeSkin(t, """
        [Parent]
        Measure=WebParser
        URL=\(server.url("/slow"))
        RegExp=(?siU)<v>(.*)</v>
        StringIndex=1
        """)
        skin.update()
        t.equal(web(skin, "Parent")?.isFetching, true)
        skin.execute("[!SetOption Parent URL \"\(server.url("/fast"))\"][!CommandMeasure Parent Update]", from: nil)
        settle(skin)
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        t.equal(str(skin, "Parent"), "new")
    }
}

// MARK: - Robustness

private func runWebParserRobustnessTests(_ t: TestRunner) {
    t.suite("WebParser: odd options never crash or hang") {
        let (skin, host) = try makeSkin(t, """
        [Empty]
        Measure=WebParser

        [EmptyURL]
        Measure=WebParser
        URL=

        [Self]
        Measure=WebParser
        URL=[Self]
        OnConnectErrorAction=[!SetVariable SelfErr 1]

        [CycleA]
        Measure=WebParser
        URL=[CycleB]
        StringIndex=1

        [CycleB]
        Measure=WebParser
        URL=[CycleA]
        StringIndex=1

        [Huge]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        RegExp=(?s)(.*)
        StringIndex=99999999999999999999
        StringIndex2=-5
        UpdateRate=1e300
        CodePage=-1
        DecodeCharacterReference=99
        Debug=5
        ProxyServer=:::
        Flags=|||IgnoreCertName|
        Header=
        Header2=:
        UserAgent=

        [HugeChild]
        Measure=WebParser
        URL=[Huge]
        StringIndex=1e40
        RegExp=(a+)+$
        StringIndex2=1

        [Dir]
        Measure=WebParser
        URL=file://#CURRENTPATH#
        OnConnectErrorAction=[!SetVariable DirErr 1]

        [Unsupported]
        Measure=WebParser
        URL=gopher://example
        OnConnectErrorAction=[!SetVariable SchemeErr 1]
        """, files: ["Root/Sub/data.txt": String(repeating: "a", count: 40) + "!"])
        updateAndSettle(skin, times: 3)
        t.equal(skin.variable("SelfErr"), "1")
        t.equal(skin.variable("DirErr"), "1")
        t.equal(skin.variable("SchemeErr"), "1")
        t.equal(web(skin, "Self")?.parentName, nil)
        t.equal(web(skin, "CycleA")?.parentName, "CycleB")
        t.equal(str(skin, "CycleA"), "")
        t.equal(str(skin, "Huge"), String(repeating: "a", count: 40) + "!")  // StringIndex out of range → 0
        t.equal(str(skin, "HugeChild"), "")  // catastrophic backtracking is abandoned, value kept
        t.equal(web(skin, "Empty")?.fetchCount, 0)
        t.check(skin.issues.contains { $0.contains("IgnoreCertName") })
        t.check(host.logs.contains { $0.contains("URL is empty") })
    }

    t.suite("WebParser: many children and a large file stay responsive") {
        var ini = """
        [Parent]
        Measure=WebParser
        URL=file://#CURRENTPATH#big.xml
        RegExp=(?siU)
        """
        var items = ""
        for i in 1...60 { items += "<item><title>Item \(i)</title></item>\n" }
        let padding = String(repeating: "<p>filler text</p>\n", count: 20_000)  // ~0.4 MB
        ini += String(repeating: ".*<item><title>(.*)</title>", count: 60) + "\n"
        for i in 1...60 {
            ini += """

            [Child\(i)]
            Measure=WebParser
            URL=[Parent]
            StringIndex=\(i)

            """
        }
        let (skin, _) = try makeSkin(t, ini, files: ["Root/Sub/big.xml": padding + items + padding])
        let started = Date()
        skin.update()
        t.check(Date().timeIntervalSince(started) < 0.5, "update blocked")
        settle(skin, timeout: 20)
        t.equal(str(skin, "Child1"), "Item 1")
        t.equal(str(skin, "Child60"), "Item 60")
    }
}

private extension Result where Success == WebParserResponse, Failure == WebParserFetchError {
    var isTooLarge: Bool {
        if case .failure(.tooLarge) = self { return true }
        return false
    }
}


// MARK: - Adversarial review regressions

private func runWebParserReviewTests(_ t: TestRunner) {
    t.suite("WebParser: symbolic links in DownloadFile folders are detected") {
        let base = t.temporaryDirectory("links")
        let root = base.appendingPathComponent("Skin/DownloadFile")
        let outside = base.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // Nothing exists yet: fine (folders are created as real folders).
        t.equal(WebParserURL.hasSymbolicLink(from: root, to: root.appendingPathComponent("a/b")), false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        t.equal(WebParserURL.hasSymbolicLink(from: root, to: root.appendingPathComponent("a/b")), false)
        t.equal(WebParserURL.hasSymbolicLink(from: root, to: root), false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("a/b"), withDestinationURL: outside)
        t.equal(WebParserURL.hasSymbolicLink(from: root, to: root.appendingPathComponent("a/b")), true)
        t.equal(WebParserURL.hasSymbolicLink(from: root, to: root.appendingPathComponent("a/b/c")), true)
        t.equal(WebParserURL.hasSymbolicLink(from: root, to: outside), true)  // not inside the root at all
        let linkedRoot = base.appendingPathComponent("Skin2/DownloadFile")
        try FileManager.default.createDirectory(at: linkedRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
        t.equal(WebParserURL.hasSymbolicLink(from: linkedRoot, to: linkedRoot), true)
    }

    t.suite("WebParser: DownloadFile and Debug2File never write through symbolic links") {
        let outside = t.temporaryDirectory("outside")
        let (skin, _) = try makeSkin(t, """
        [Picture]
        Measure=WebParser
        URL=file://#CURRENTPATH#img.png
        Download=1
        DownloadFile=evil.txt
        FinishAction=[!SetVariable PictureDone 1]
        OnDownloadErrorAction=[!SetVariable PictureError 1]

        [Nested]
        Measure=WebParser
        URL=file://#CURRENTPATH#img.png
        Download=1
        DownloadFile=Safe\\Deeper\\ok.txt
        FinishAction=[!SetVariable NestedDone 1]

        [Page]
        Measure=WebParser
        URL=file://#CURRENTPATH#img.png
        Debug=2
        Debug2File=#CURRENTPATH#Dump\\dump.txt
        """, files: ["Root/Sub/img.png": "PAYLOAD"])
        let fm = FileManager.default
        try fm.createSymbolicLink(at: skin.directory.appendingPathComponent("DownloadFile"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: skin.directory.appendingPathComponent("Dump"), withDestinationURL: outside)
        updateAndSettle(skin)
        t.equal((try? fm.contentsOfDirectory(atPath: outside.path)) ?? ["?"], [])  // nothing escaped
        t.equal(skin.variable("PictureError"), "1")
        t.equal(skin.variable("PictureDone"), nil)
        t.equal(str(skin, "Picture"), "")
        t.equal(skin.variable("NestedDone"), nil)
        // Debug2File behind a link falls back to WebParserDump.txt in the skin folder.
        t.equal(try? String(contentsOf: skin.directory.appendingPathComponent("WebParserDump.txt"), encoding: .utf8),
                "PAYLOAD")

        // Without links, DownloadFile works as documented (folders created under <skin>/DownloadFile).
        try fm.removeItem(at: skin.directory.appendingPathComponent("DownloadFile"))
        skin.execute("[!CommandMeasure Picture Update][!CommandMeasure Nested Update]", from: nil)
        settle(skin)
        t.equal(skin.variable("PictureDone"), "1")
        t.equal(try? String(contentsOf: skin.directory.appendingPathComponent("DownloadFile/Safe/Deeper/ok.txt"),
                            encoding: .utf8), "PAYLOAD")
    }

    t.suite("WebParser: a huge capture used as a download URL does not block the main thread") {
        let big = String(repeating: "é <x> ", count: 300_000)  // ~2.4 MB
        let (skin, _) = try makeSkin(t, """
        [Parent]
        Measure=WebParser
        URL=file://#CURRENTPATH#page.txt
        RegExp=(?s)(.*)

        [Child]
        Measure=WebParser
        URL=https://host.example/[Parent]
        Download=1
        OnDownloadErrorAction=[!SetVariable ChildError 1]
        """, files: ["Root/Sub/page.txt": big])
        skin.update()
        var longest = 0.0
        let started = Date()
        while Date().timeIntervalSince(started) < 20 {
            let s = Date()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            longest = max(longest, Date().timeIntervalSince(s))
            if web(skin, "Parent")?.isFetching == false && web(skin, "Child")?.isDownloading == false { break }
        }
        settle(skin)
        t.check(longest < 0.5, "main thread blocked for \(longest) s")
        t.equal(skin.variable("ChildError"), "1")  // the URL is refused as too long
        t.equal(WebParserURL.target(for: "https://h.example/" + String(repeating: "a", count: WebParserURL.maxURLBytes)).isValid,
                false)
        // An already percent-encoded query (as in the manual's feed example) is sent unchanged.
        let encoded = "https://feeds.example/rss.xml?q=in%3Acustomization%2Fskins%2Fclocks+sort%3Atime&type=item"
        if case .http(let url) = WebParserURL.target(for: encoded) {
            t.equal(url.absoluteString, encoded)
        } else { t.check(false, "pre-encoded URL") }
        let nearLimit = "https://h.example/" + String(repeating: "ü", count: 30_000)
        let cpu0 = PCRE.threadCPUNanoseconds()
        let s = Date()
        t.check(WebParserURL.target(for: nearLimit).isValid)
        // About 15 ms in a debug build; quadratic encoding of 180 KB takes seconds to minutes. Timed in this thread's
        // CPU time, which a busy or stalled machine does not add to (a slow CI runner is some 20 times slower); the
        // wall clock only tells "slow" from "never".
        let cpu = Double(PCRE.threadCPUNanoseconds() &- cpu0) / 1e9
        t.check(cpu < 2, "encoding a 60 KB URL took \(cpu) s of CPU time")
        t.check(Date().timeIntervalSince(s) < 60, "encoding a 60 KB URL never finished")
    }

    guard let server = WebParserTestServer() else {
        t.suite("WebParser: review HTTP test server") { t.check(false, "cannot start the local HTTP server") }
        return
    }
    defer { server.stop() }

    t.suite("WebParser: URL credentials are never sent to another host after a redirect") {
        let port = server.port
        server.handler = { request in
            switch request.target {
            case "/start":
                return .text("", status: 302, headers: ["Location": "http://localhost:\(port)/other"])
            case "/same":
                return .text("", status: 302, headers: ["Location": "/private"])
            default:
                if request.headers["authorization"] == "Basic dXNlcjpzZWNyZXQ=" { return .text("<v>welcome</v>") }
                return .text("<v>denied</v>", status: 401, headers: ["WWW-Authenticate": "Basic realm=\"r\""])
            }
        }
        let (skin, _) = try makeSkin(t, """
        [CrossHost]
        Measure=WebParser
        URL=http://user:secret@127.0.0.1:\(port)/start
        RegExp=(?siU)<v>(.*)</v>
        StringIndex=1

        [SameHost]
        Measure=WebParser
        URL=http://user:secret@127.0.0.1:\(port)/same
        RegExp=(?siU)<v>(.*)</v>
        StringIndex=1
        """)
        updateAndSettle(skin)
        t.equal(str(skin, "CrossHost"), "denied")
        t.check(!server.requests.contains { $0.headers["host"]?.hasPrefix("localhost") == true
                    && $0.headers["authorization"] != nil }, "password sent to another host")
        t.equal(str(skin, "SameHost"), "welcome")  // a redirect on the same host keeps working
    }

    t.suite("WebParser: a child download is not restarted by frequent parent reads") {
        server.handler = { request in
            switch request.target {
            case "/page": return .text(#"<img src="/img/slow.png">"#)
            case "/img/slow.png": return WebParserTestServer.Response(status: 200, body: Data([1, 2, 3]), delay: 0.6)
            default: return .text("", status: 404)
            }
        }
        let (skin, _) = try makeSkin(t, """
        [Page]
        Measure=WebParser
        URL=\(server.url("/page"))
        RegExp=(?siU)src="(.*)"
        UpdateRate=1

        [Image]
        Measure=WebParser
        URL=[Page]
        StringIndex=1
        Download=1
        """)
        // The page is read every 0.3 s while the image takes 0.6 s: the transfer in flight must be allowed to finish.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && str(skin, "Image").isEmpty {
            skin.update()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        let path = str(skin, "Image")
        t.check(!path.isEmpty, "the download never completed")
        t.equal(try? Data(contentsOf: URL(fileURLWithPath: path)), Data([1, 2, 3]))
        t.check(server.requests.filter { $0.target == "/img/slow.png" }.count <= 3,
                "\(server.requests.filter { $0.target == "/img/slow.png" }.count) image requests")
        settle(skin)
    }

    t.suite("WebParser: default Flags (Resync) revalidate cached responses") {
        let lock = NSLock()
        var version = 1
        server.handler = { request in
            lock.lock()
            let v = version
            lock.unlock()
            let etag = "\"v\(v)\""
            let headers = ["Cache-Control": "max-age=3600", "ETag": etag]
            if request.headers["if-none-match"] == etag {
                return WebParserTestServer.Response(status: 304, headers: headers)
            }
            return .text("<v>\(v)</v>", headers: headers)
        }
        let path = "/cached-\(UUID().uuidString)"
        let (skin, _) = try makeSkin(t, """
        [Parent]
        Measure=WebParser
        URL=\(server.url(path))
        RegExp=(?siU)<v>(.*)</v>
        StringIndex=1
        OnRegExpErrorAction=[!SetVariable RegErr 1]

        [OwnHeader]
        Measure=WebParser
        URL=\(server.url(path + "-own"))
        Header=Cache-Control: no-store

        [Forced]
        Measure=WebParser
        URL=\(server.url(path + "-forced"))
        Flags=ForceReload
        """)
        updateAndSettle(skin)
        t.equal(str(skin, "Parent"), "1")
        // Unchanged resource: the server answers 304 and the cached copy is parsed again.
        skin.execute("[!CommandMeasure Parent Update]", from: nil)
        settle(skin)
        t.equal(str(skin, "Parent"), "1")
        t.equal(skin.variable("RegErr"), nil)
        // Changed resource: "Update" must reach the server even though the cached copy is still fresh.
        lock.lock()
        version = 2
        lock.unlock()
        skin.execute("[!CommandMeasure Parent Update]", from: nil)
        settle(skin)
        t.equal(str(skin, "Parent"), "2")
        let parentRequests = server.requests.filter { $0.target == path }
        t.equal(parentRequests.count, 3)
        t.check(parentRequests.allSatisfy { $0.headers["cache-control"] == "max-age=0" })
        t.equal(server.requests.first { $0.target == path + "-own" }?.headers["cache-control"], "no-store")
        t.check(server.requests.first { $0.target == path + "-forced" }?.headers["cache-control"] != "max-age=0")
    }

    t.suite("WebParser: ProxyServer values cannot create unbounded sessions") {
        for i in 0..<(WebParserNetwork.maxSessions + 8) {
            var request = WebParserRequest(target: WebParserURL.target(for: server.url("/proxy-\(i)")))
            request.proxy = "127.0.0.1:\(1 + i)"  // refused at once
            WebParserNetwork.shared.start(request) { _ in }
        }
        t.check(WebParserNetwork.shared.sessionCount <= WebParserNetwork.maxSessions + 1,
                "\(WebParserNetwork.shared.sessionCount) sessions")
    }

    t.suite("WebParser: typical RegExp shapes (RSS items with lookahead, JSON, U flag)") {
        let item = "(?(?=.*<item>).*<item>.*<title>(.*)</title>.*<link>(.*)</link>.*<pubDate>(.*)</pubDate>)"
        if case .matched(let caps, let n) = WebParserProcessor.match(
            "(?siU)<title>(.*)</title>.*<link>(.*)</link>" + String(repeating: item, count: 5), in: sampleFeed) {
            t.equal(n, 9)
            t.equal(caps[3], "First &amp; foremost")
            t.equal(caps[8], "Tue, 02 Jan 2024")
            t.equal(caps.count, 18)
        } else { t.check(false, "RSS tutorial lookahead") }
        let json = #"{"current":{"temp":18.25,"feels_like":17.1,"weather":[{"main":"Rain","description":"light rain"}]}}"#
        if case .matched(let caps, _) = WebParserProcessor.match(#"(?siU)"temp":(.*),"feels_like":(.*),.*"main":"(.*)""#,
                                                                 in: json) {
            t.equal(Array(caps.dropFirst()), ["18.25", "17.1", "Rain"])
        } else { t.check(false, "JSON") }
        // With U every quantifier is inverted, so `+` is lazy (PCRE semantics).
        if case .matched(let caps, _) = WebParserProcessor.match(#"(?siU)"temp":([\d.]+)"#, in: json) {
            t.equal(caps[1], "1")
        } else { t.check(false, "U flag") }
        if case .matched(let caps, _) = WebParserProcessor.match(#"(?i)<TITLE>\s*(.+?)\s*</title>"#, in: sampleFeed) {
            t.equal(caps[1], "Deskset Test Feed")
        } else { t.check(false, "lazy without U") }
    }
}
