import Foundation

/// Why a request got no HTTP response.
public enum WeatherTransportError: Error, Equatable {
    /// No connection, DNS failure, time-out.
    case network(String)
    /// Refused by Deskset's own rules: not HTTPS, a redirect off HTTPS or off `*.met.no`, a body over the limit.
    case refused(String)
}

/// How the weather service reaches MET Norway. The app installs `URLSessionWeatherTransport`; the core default is no
/// transport at all (no network), and tests install fakes or a loopback-only transport.
public protocol WeatherTransport: AnyObject {
    /// Sends one GET; `completion` runs once, on any thread.
    func get(_ request: WeatherHTTPRequest, completion: @escaping (Result<WeatherHTTPResponse, WeatherTransportError>) -> Void)
}

/// The real transport: its own ephemeral `URLSession` without a URL cache (so 304 responses reach the service),
/// without cookies, 20 s per request and 60 s in all, no waiting for connectivity. HTTPS only (plain HTTP only to
/// the loopback address, for tests); a redirect must stay on HTTPS and on `*.met.no`; bodies over `maxBytes` are
/// refused.
public final class URLSessionWeatherTransport: NSObject, WeatherTransport, URLSessionDataDelegate {
    public let allowsLoopbackHTTP: Bool
    public let maxBytes: Int
    private var session: URLSession!
    private let lock = NSLock()
    private var tasks: [Int: Pending] = [:]

    private final class Pending {
        var data = Data()
        var response: HTTPURLResponse?
        var refusal: String?
        let completion: (Result<WeatherHTTPResponse, WeatherTransportError>) -> Void
        init(_ completion: @escaping (Result<WeatherHTTPResponse, WeatherTransportError>) -> Void) {
            self.completion = completion
        }
    }

    public init(allowsLoopbackHTTP: Bool = false, maxBytes: Int = 4 * 1024 * 1024) {
        self.allowsLoopbackHTTP = allowsLoopbackHTTP
        self.maxBytes = maxBytes
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "app.deskset.weather.transport"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Whether Deskset may send a request to `url`.
    public func allows(_ url: URL, redirect: Bool = false) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let loopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
        if scheme == "https" {
            return !redirect || host == "met.no" || host.hasSuffix(".met.no") || (allowsLoopbackHTTP && loopback)
        }
        if scheme == "http" { return allowsLoopbackHTTP && loopback && !redirect }
        return false
    }

    public func get(_ request: WeatherHTTPRequest,
                    completion: @escaping (Result<WeatherHTTPResponse, WeatherTransportError>) -> Void) {
        guard allows(request.url) else {
            completion(.failure(.refused("not an HTTPS address")))
            return
        }
        var r = URLRequest(url: request.url)
        r.httpMethod = "GET"
        r.httpShouldHandleCookies = false
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let task = session.dataTask(with: r)
        lock.lock()
        tasks[task.taskIdentifier] = Pending(completion)
        lock.unlock()
        task.resume()
    }

    private func pending(_ task: URLSessionTask) -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[task.taskIdentifier]
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, allows(url, redirect: true) else {
            pending(task)?.refusal = "a redirect left HTTPS or api.met.no"
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let p = pending(dataTask)
        p?.response = response as? HTTPURLResponse
        if response.expectedContentLength > Int64(maxBytes) {
            p?.refusal = "the response is too large"
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let p = pending(dataTask) else { return }
        p.data.append(data)
        if p.data.count > maxBytes {
            p.refusal = "the response is too large"
            dataTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let p = tasks.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let p else { return }
        if let refusal = p.refusal {
            p.completion(.failure(.refused(refusal)))
        } else if let error {
            p.completion(.failure(.network((error as NSError).localizedDescription)))
        } else if let http = p.response {
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
            }
            p.completion(.success(WeatherHTTPResponse(status: http.statusCode, headers: headers, body: p.data)))
        } else {
            p.completion(.failure(.network("no response")))
        }
    }
}
