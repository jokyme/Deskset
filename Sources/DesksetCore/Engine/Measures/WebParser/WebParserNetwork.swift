import Foundation

/// `Flags=` of a parent WebParser measure (manual: "Multiple flags are set by separating them with the | pipe
/// character"), plus the deprecated `ForceReload=1`.
struct WebParserFlags: Equatable {
    /// `ForceReload`: bypass the cache. Default (`Resync`): every read revalidates the cached copy with the server
    /// (`Cache-Control: max-age=0` on the request, see `WebParserNetwork.start`).
    var forceReload = false
    /// `NoCookies`: neither send nor store cookies.
    var noCookies = false
    /// `NoCacheWrite`: do not store the response in the cache.
    var noCacheWrite = false
    /// `PragmaNoCache`: ask proxies to revalidate with the origin (`Pragma: no-cache`, `Cache-Control: no-cache`).
    var pragmaNoCache = false
    /// `NoAuth`: do not use the `name:password@` part of the URL.
    var noAuth = false
    /// `IgnoreHTTPRedirect`: allow redirects from HTTPS to HTTP (refused by default).
    var allowHTTPSToHTTPRedirect = false
    /// Flags the manual lists that are not supported here (logged once).
    var unsupported: [String] = []

    init() {}

    /// Judgment calls: `Resync` is the default behaviour (no field needed); `Hyperlink`, `TempFile`, `Secure` and
    /// `IgnoreHTTPSRedirect` need no action (URLSession never needs temp files, and HTTP → HTTPS redirects are always
    /// followed); `IgnoreCertName` and `IgnoreCertDate` are refused — certificate checks stay on — and reported as
    /// unsupported.
    init(option: String?, forceReload: Bool) {
        self.forceReload = forceReload
        for part in (option ?? "").split(separator: "|") {
            let flag = part.trimmingCharacters(in: .whitespaces)
            switch flag.lowercased() {
            case "": continue
            case "forcereload": self.forceReload = true
            case "nocookies": noCookies = true
            case "nocachewrite": noCacheWrite = true
            case "pragmanocache": pragmaNoCache = true
            case "noauth": noAuth = true
            case "ignorehttpredirect": allowHTTPSToHTTPRedirect = true
            case "resync", "hyperlink", "tempfile", "secure", "ignorehttpsredirect": break
            default: unsupported.append(flag)
            }
        }
    }
}

/// Everything needed to fetch one resource.
struct WebParserRequest {
    var target: WebParserTarget
    var userAgent = WebParserNetwork.defaultUserAgent
    /// Extra header fields (already validated).
    var headers: [(name: String, value: String)] = []
    var flags = WebParserFlags()
    /// `ProxyServer`: `/auto` (system settings), `/none`, or `host[:port]`.
    var proxy = "/auto"
    var maxBytes = WebParserNetwork.maxPageBytes
}

struct WebParserResponse {
    var data: Data
    /// `charset` of the Content-Type header, if any.
    var charset: String?
    /// HTTP status (nil for files).
    var statusCode: Int?
}

enum WebParserFetchError: Error, Equatable, CustomStringConvertible {
    /// Could not connect / read (DNS, refused, time-out, TLS, missing file…).
    case connect(String)
    /// The resource is bigger than the size cap.
    case tooLarge(Int)
    case cancelled

    var description: String {
        switch self {
        case .connect(let message): return message
        case .tooLarge(let limit): return "the resource is larger than \(limit / 1_048_576) MB"
        case .cancelled: return "cancelled"
        }
    }
}

/// Cancels an in-flight fetch (its completion then reports `.cancelled`, or nothing if it already finished).
final class WebParserFetchHandle {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    fileprivate func attach(_ task: URLSessionTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
        return !isCancelled
    }

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}

/// Downloads for WebParser measures. Every completion runs on a background queue, never on the main thread.
///
/// - http(s) with URLSession: request time-out `requestTimeout` (the manual mentions 10–20 s before
///   OnConnectErrorAction), whole-transfer limit `resourceTimeout`, at most `maxRedirects` redirects (never to a
///   non-HTTP scheme; HTTPS → HTTP only with `IgnoreHTTPRedirect`), responses above `maxBytes` abandoned.
/// - file:// read on a background queue (regular files only, same size cap).
/// - Any HTTP status counts as connected: the body of a 404 page is returned (the manual lists "the specific page …
///   can't be found" under OnRegExpErrorAction, not OnConnectErrorAction); callers decide what a status means.
final class WebParserNetwork: NSObject, URLSessionDataDelegate {
    static let shared = WebParserNetwork()

    /// Judgment call: the product must not present itself as Rainmeter, so the default `UserAgent` differs from the
    /// manual's "Rainmeter WebParser plugin"; skins can still set their own.
    static let defaultUserAgent = "Deskset WebParser"
    static var requestTimeout: TimeInterval = 20
    static var resourceTimeout: TimeInterval = 120
    static var maxPageBytes = 16 * 1_048_576
    static var maxDownloadBytes = 64 * 1_048_576
    static let maxRedirects = 10
    static let maxSessions = 16

    private final class TaskState {
        let completion: (Result<WebParserResponse, WebParserFetchError>) -> Void
        let maxBytes: Int
        let credential: URLCredential?
        /// Lowercased host of the URL that carried `name:password@`: the credential is only ever given to that host
        /// (never to another host a redirect leads to, and never to a proxy).
        let credentialHost: String?
        let allowDowngrade: Bool
        var data = Data()
        var redirects = 0
        var failure: WebParserFetchError?
        var response: HTTPURLResponse?

        init(completion: @escaping (Result<WebParserResponse, WebParserFetchError>) -> Void, maxBytes: Int,
             credential: URLCredential?, credentialHost: String?, allowDowngrade: Bool) {
            self.completion = completion
            self.maxBytes = maxBytes
            self.credential = credential
            self.credentialHost = credentialHost
            self.allowDowngrade = allowDowngrade
        }
    }

    private let lock = NSLock()
    private var sessions: [String: URLSession] = [:]
    private var states: [ObjectIdentifier: TaskState] = [:]
    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "Deskset.WebParser.network"
        return q
    }()
    private static let workQueue = DispatchQueue(label: "Deskset.WebParser.work", qos: .utility, attributes: .concurrent)

    /// Starts a fetch. `completion` is called exactly once, on a background queue.
    @discardableResult
    func start(_ request: WebParserRequest,
               completion: @escaping (Result<WebParserResponse, WebParserFetchError>) -> Void) -> WebParserFetchHandle {
        let handle = WebParserFetchHandle()
        let finish: (Result<WebParserResponse, WebParserFetchError>) -> Void = { result in
            Self.workQueue.async { completion(result) }
        }
        switch request.target {
        case .invalid(let reason):
            finish(.failure(.connect(reason)))
        case .file(let path):
            Self.workQueue.async {
                completion(handle.cancelled ? .failure(.cancelled) : Self.readFile(path, maxBytes: request.maxBytes))
            }
        case .http(var url):
            if request.flags.noAuth, url.user != nil || url.password != nil,
               var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.user = nil
                components.password = nil
                url = components.url ?? url
            }
            var urlRequest = URLRequest(url: url,
                                        cachePolicy: request.flags.forceReload ? .reloadIgnoringLocalCacheData
                                            : .useProtocolCachePolicy,
                                        timeoutInterval: Self.requestTimeout)
            urlRequest.httpShouldHandleCookies = !request.flags.noCookies
            urlRequest.setValue(request.userAgent, forHTTPHeaderField: "User-Agent")
            if request.flags.pragmaNoCache {
                urlRequest.setValue("no-cache", forHTTPHeaderField: "Pragma")
                urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            } else if !request.flags.forceReload {
                // Flags=Resync (the default): "Only downloads if the resource has been modified since the last time it
                // was downloaded. Otherwise the cache is used." URLSession's protocol cache policy would reuse a
                // response that is still fresh (Cache-Control: max-age) without asking the server at all, so even
                // `!CommandMeasure … Update` returned stale data. `max-age=0` makes it revalidate every time
                // (If-None-Match / If-Modified-Since; a 304 answer uses the cached body). A skin's own
                // `Header=Cache-Control: …` below still wins.
                urlRequest.setValue("max-age=0", forHTTPHeaderField: "Cache-Control")
            }
            for header in request.headers { urlRequest.setValue(header.value, forHTTPHeaderField: header.name) }
            var credential: URLCredential?
            if !request.flags.noAuth, let user = url.user?.removingPercentEncoding ?? url.user {
                let password = url.password.map { $0.removingPercentEncoding ?? $0 } ?? ""
                credential = URLCredential(user: user, password: password, persistence: .none)
            }
            let session = self.session(proxy: request.proxy, noCacheWrite: request.flags.noCacheWrite)
            let task = session.dataTask(with: urlRequest)
            let state = TaskState(completion: finish, maxBytes: request.maxBytes, credential: credential,
                                  credentialHost: url.host?.lowercased(),
                                  allowDowngrade: request.flags.allowHTTPSToHTTPRedirect)
            lock.lock()
            states[ObjectIdentifier(task)] = state
            lock.unlock()
            if handle.attach(task) {
                task.resume()
            } else {
                lock.lock()
                states[ObjectIdentifier(task)] = nil
                lock.unlock()
                finish(.failure(.cancelled))
            }
        }
        return handle
    }

    // MARK: Files

    static func readFile(_ path: String, maxBytes: Int) -> Result<WebParserResponse, WebParserFetchError> {
        var candidates = [path]
        if let decoded = path.removingPercentEncoding, decoded != path { candidates.append(decoded) }
        for candidate in candidates {
            let resolved = (candidate as NSString).resolvingSymlinksInPath
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved) else { continue }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                return .failure(.connect("\(candidate) is not a regular file"))
            }
            if let size = attributes[.size] as? NSNumber, size.int64Value > Int64(maxBytes) {
                return .failure(.tooLarge(maxBytes))
            }
            guard let handle = FileHandle(forReadingAtPath: resolved) else {
                return .failure(.connect("cannot open \(candidate)"))
            }
            defer { try? handle.close() }
            do {
                let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
                if data.count > maxBytes { return .failure(.tooLarge(maxBytes)) }
                return .success(WebParserResponse(data: data, charset: nil, statusCode: nil))
            } catch {
                return .failure(.connect("cannot read \(candidate): \(error.localizedDescription)"))
            }
        }
        return .failure(.connect("file not found: \(path)"))
    }

    // MARK: Sessions

    /// One session per proxy setting (and cache mode); a bounded number, then the default session is shared.
    private func session(proxy rawProxy: String, noCacheWrite requestedNoCacheWrite: Bool) -> URLSession {
        var proxy = Self.normalizedProxy(rawProxy)
        var noCacheWrite = requestedNoCacheWrite
        var key = proxy + (noCacheWrite ? "|nocache" : "")
        lock.lock()
        defer { lock.unlock() }
        if let s = sessions[key] { return s }
        if sessions.count >= Self.maxSessions {
            // Bounded even when the default session does not exist yet (e.g. a skin that changes ProxyServer on
            // every fetch): past the limit everything shares the default one, created here if needed.
            proxy = "/auto"
            noCacheWrite = false
            key = "/auto"
            if let fallback = sessions[key] { return fallback }
        }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        configuration.waitsForConnectivity = false
        if noCacheWrite { configuration.urlCache = nil }
        if let dictionary = Self.proxyDictionary(proxy) { configuration.connectionProxyDictionary = dictionary }
        let s = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        sessions[key] = s
        return s
    }

    static func normalizedProxy(_ raw: String) -> String {
        let p = raw.trimmingCharacters(in: .whitespaces)
        if p.isEmpty || p.lowercased() == "/auto" { return "/auto" }
        if p.lowercased() == "/none" { return "/none" }
        return p
    }

    /// `ProxyServer` (manual): `/auto` = system settings, `/none` = direct connection, `ServerName:Port` = that proxy
    /// for HTTP and HTTPS. Judgment call: a missing port means 80.
    static func proxyDictionary(_ proxy: String) -> [AnyHashable: Any]? {
        switch proxy {
        case "/auto":
            return nil
        case "/none":
            return ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0]
        default:
            var host = proxy
            var port = 80
            if let colon = proxy.lastIndex(of: ":"), let p = Int(proxy[proxy.index(after: colon)...]),
               p > 0, p < 65536 {
                host = String(proxy[..<colon])
                port = p
            }
            if host.lowercased().hasPrefix("http://") { host = String(host.dropFirst(7)) }
            guard !host.isEmpty else { return nil }
            return ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                    "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
        }
    }

    /// Number of URLSessions created so far (bounded by `maxSessions` + 1; for tests).
    var sessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    private func state(for task: URLSessionTask) -> TaskState? {
        lock.lock()
        defer { lock.unlock() }
        return states[ObjectIdentifier(task)]
    }

    // MARK: URLSessionDataDelegate (serial delegate queue)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let state = state(for: dataTask) else { return completionHandler(.cancel) }
        state.response = response as? HTTPURLResponse
        if response.expectedContentLength > Int64(state.maxBytes) {
            state.failure = .tooLarge(state.maxBytes)
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = state(for: dataTask), state.failure == nil else { return }
        if state.data.count + data.count > state.maxBytes {
            state.failure = .tooLarge(state.maxBytes)
            state.data = Data()
            dataTask.cancel()
            return
        }
        state.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let state = state(for: task) else { return completionHandler(nil) }
        state.redirects += 1
        let from = task.currentRequest?.url?.scheme?.lowercased() ?? response.url?.scheme?.lowercased()
        let to = request.url?.scheme?.lowercased()
        guard state.redirects <= Self.maxRedirects, to == "http" || to == "https",
              !(from == "https" && to == "http" && !state.allowDowngrade) else {
            return completionHandler(nil)  // the redirect response itself becomes the result
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest
            || method == NSURLAuthenticationMethodNTLM {
            // `https://name:password@host` authenticates with that host only: a redirect to another host (or a
            // proxy asking for credentials) must not receive the skin's password.
            if let state = state(for: task), let credential = state.credential, challenge.previousFailureCount == 0,
               !challenge.protectionSpace.isProxy(),
               challenge.protectionSpace.host.lowercased() == state.credentialHost {
                return completionHandler(.useCredential, credential)
            }
            return completionHandler(.rejectProtectionSpace, nil)
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let state = states.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()
        guard let state else { return }
        if let failure = state.failure {
            state.completion(.failure(failure))
        } else if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                state.completion(.failure(.cancelled))
            } else {
                state.completion(.failure(.connect(error.localizedDescription)))
            }
        } else {
            let http = state.response ?? task.response as? HTTPURLResponse
            state.completion(.success(WebParserResponse(data: state.data, charset: http?.textEncodingName,
                                                        statusCode: http?.statusCode)))
        }
    }
}
