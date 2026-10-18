import Foundation

/// Offline checks: URLProtocol intercepts every request, including an accidentally changed endpoint.
enum AppUpdateServiceSelfTests {
    static func run(_ t: AppTestRunner) {
        versionTests(t)
        responseTests(t)
        cancellationTests(t)
    }

    private static func versionTests(_ t: AppTestRunner) {
        t.suite("App: app update: semantic versions compare numbers and prereleases") {
            t.equal(ReleaseVersion("v1.2.3+build.42")?.description, "1.2.3")
            t.equal(ReleaseVersion("1.2.3+build.42"), ReleaseVersion("v1.2.3+other"))
            t.equal(ReleaseVersion("1.2.3-rc.1+build")?.description, "1.2.3-rc.1")
            t.check(ReleaseVersion(AppVersion.current) != nil, "the app has a comparable current version")
            let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
                           "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.9.0",
                           "1.10.0", "2.0.0", "999999999999999999999999999999.0.0"]
            for (left, right) in zip(ordered, ordered.dropFirst()) {
                guard let lhs = ReleaseVersion(left), let rhs = ReleaseVersion(right) else {
                    t.check(false, "valid versions: \(left), \(right)")
                    continue
                }
                t.check(lhs < rhs, "\(left) precedes \(right)")
                t.check(!(rhs < lhs), "precedence is not reversed")
                t.check(lhs != rhs)
            }
            for invalid in ["", "v", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "-1.2.3",
                            "1.2.3-", "1.2.3-01", "1.2.3-a..b", "1.2.3+a..b", "1.2.3+", "1.2.3+a+b",
                            "1.2.3 hello", "1.2.3-β", "1.2.3/foo", " 1.2.3"] {
                t.check(ReleaseVersion(invalid) == nil, "refuses malformed version \(invalid)")
            }
            t.check(ReleaseVersion("1.2.3+01") != nil, "build identifiers allow leading zeroes")
            t.check(ReleaseVersion("1.2.3-0")?.isPrerelease == true)
            t.check(ReleaseVersion("1.2.3")?.isPrerelease == false)
        }
    }

    private static func responseTests(_ t: AppTestRunner) {
        t.suite("App: app update: GitHub success is validated and delivered on the main thread") {
            let result = fetch(t, .http(200, releaseBody()))
            guard case .success(let release) = result else { return t.check(false, "a valid release succeeds") }
            t.equal(release?.version, ReleaseVersion("0.3.0"))
            t.equal(release?.url.absoluteString, "https://github.com/jokyme/Deskset/releases/tag/v0.3.0")
            let requests = StubURLProtocol.requests.current
            t.equal(requests.count, 1)
            t.equal(requests.first?.url?.absoluteString,
                    "https://api.github.com/repos/jokyme/Deskset/releases/latest")
            t.equal(requests.first?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            t.equal(requests.first?.value(forHTTPHeaderField: "User-Agent"), "Deskset/\(AppVersion.current)")
            t.equal(requests.first?.timeoutInterval, 20)
        }

        t.suite("App: app update: no release and prereleases do not become update offers") {
            for response in [Response.http(404, Data()), .http(200, releaseBody(draft: true)),
                             .http(200, releaseBody(prerelease: true)),
                             .http(200, releaseBody(tag: "v0.3.0-rc.1"))] {
                guard case .success(let release) = fetch(t, response) else {
                    t.check(false, "absence of a stable release is not a transport error")
                    continue
                }
                t.check(release == nil)
            }
        }

        t.suite("App: app update: server errors, malformed responses and network failures stay errors") {
            for status in [403, 429] {
                t.equal(updateError(fetch(t, .http(status, Data()))), .rateLimited)
            }
            for status in [401, 500, 503] {
                t.equal(updateError(fetch(t, .http(status, Data()))), .httpStatus(status))
            }
            for body in [Data(), Data("not json".utf8), Data("{}".utf8)] {
                t.equal(updateError(fetch(t, .http(200, body))), .invalidResponse)
            }
            t.equal(updateError(fetch(t, .nonHTTP)), .invalidResponse)
            t.equal(updateError(fetch(t, .http(200, releaseBody(tag: "not-a-version")))), .invalidRelease)
            for code in [URLError.notConnectedToInternet, .timedOut] {
                guard case .failure(let error) = fetch(t, .failure(URLError(code))) else {
                    t.check(false, "network errors are reported")
                    continue
                }
                t.equal((error as? URLError)?.code, code)
            }
        }

        t.suite("App: app update: release links remain on the expected GitHub release") {
            for url in ["http://github.com/jokyme/Deskset/releases/tag/v0.3.0",
                        "https://github.com.example.org/jokyme/Deskset/releases/tag/v0.3.0",
                        "https://example.org/jokyme/Deskset/releases/tag/v0.3.0",
                        "https://github.com/other/Deskset/releases/tag/v0.3.0",
                        "https://github.com/jokyme/Deskset/releases/tag/v0.4.0",
                        "https://github.com/jokyme/Deskset/releases/tag/v0.3.0/extra",
                        "https://github.com/jokyme/Deskset/releases/tag/v0.3.0?redirect=elsewhere",
                        "https://github.com/jokyme/Deskset/releases/tag/v0.3.0#fragment",
                        "https://name@github.com/jokyme/Deskset/releases/tag/v0.3.0",
                        "https://github.com:8443/jokyme/Deskset/releases/tag/v0.3.0",
                        "file:///jokyme/Deskset/releases/tag/v0.3.0"] {
                t.equal(updateError(fetch(t, .http(200, releaseBody(url: url)))), .invalidRelease, url)
            }
        }
    }

    private static func cancellationTests(_ t: AppTestRunner) {
        t.suite("App: app update: cancelling a pending request suppresses its completion") {
            let session = makeSession(.hold)
            defer { session.invalidateAndCancel() }
            let service = GitHubAppUpdateService(session: session)
            var completions = 0
            let cancel = service.fetch { _ in completions += 1 }
            t.check(AppSelfTest.spin(timeout: 3) { !StubURLProtocol.requests.current.isEmpty }, "request started")
            cancel()
            cancel()
            t.check(AppSelfTest.spin(timeout: 3) { StubURLProtocol.stopped.current > 0 }, "request was cancelled")
            RenderCommand.wait(milliseconds: 60)
            t.equal(completions, 0, "cancelled checks never change the UI")
        }

        t.suite("App: app update: cancellation also suppresses a response queued for the main thread") {
            let session = makeSession(.http(200, releaseBody()))
            defer { session.invalidateAndCancel() }
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            // A serial URLSession delegate queue lets the test wait for its completion work without draining main.
            let queuedSession = URLSession(configuration: session.configuration, delegate: nil, delegateQueue: queue)
            defer { queuedSession.invalidateAndCancel() }
            let service = GitHubAppUpdateService(session: queuedSession)
            var completions = 0
            let cancel = service.fetch { _ in completions += 1 }
            let end = Date().addingTimeInterval(3)
            while StubURLProtocol.finished.current == 0 && Date() < end { Thread.sleep(forTimeInterval: 0.005) }
            t.check(StubURLProtocol.finished.current > 0, "the stub supplied its response")
            queue.waitUntilAllOperationsAreFinished()
            cancel()
            RenderCommand.wait(milliseconds: 60)
            t.equal(completions, 0, "a result awaiting main-thread delivery is discarded")
        }
    }

    private enum Response {
        case http(Int, Data)
        case nonHTTP
        case failure(URLError)
        case hold
    }

    private static func releaseBody(tag: String = "v0.3.0", url: String? = nil,
                                    draft: Bool = false, prerelease: Bool = false) -> Data {
        struct Body: Encodable {
            let tag_name: String
            let html_url: String
            let draft: Bool
            let prerelease: Bool
        }
        return (try? JSONEncoder().encode(Body(tag_name: tag,
            html_url: url ?? "https://github.com/jokyme/Deskset/releases/tag/\(tag)",
            draft: draft, prerelease: prerelease))) ?? Data()
    }

    private static func updateError(_ result: Result<AppRelease?, Error>?) -> AppUpdateError? {
        guard case .failure(let error) = result else { return nil }
        return error as? AppUpdateError
    }

    private static func makeSession(_ response: Response) -> URLSession {
        StubURLProtocol.response.access { $0 = response }
        StubURLProtocol.requests.access { $0 = [] }
        StubURLProtocol.stopped.access { $0 = 0 }
        StubURLProtocol.finished.access { $0 = 0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func fetch(_ t: AppTestRunner, _ response: Response) -> Result<AppRelease?, Error>? {
        let session = makeSession(response)
        defer { session.invalidateAndCancel() }
        let service = GitHubAppUpdateService(session: session)
        var result: Result<AppRelease?, Error>?
        var onMain = false
        let cancel = service.fetch {
            onMain = Thread.isMainThread
            result = $0
        }
        defer { cancel() }
        t.check(AppSelfTest.spin(timeout: 3) { result != nil }, "the request completes")
        t.check(onMain, "completion arrives on the main thread")
        return result
    }

    private final class StubURLProtocol: URLProtocol {
        static let response = Guarded<Response>(.failure(URLError(.unsupportedURL)))
        static let requests = Guarded<[URLRequest]>([])
        static let stopped = Guarded(0)
        static let finished = Guarded(0)

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.access { $0.append(request) }
            guard let url = request.url else { return }
            switch Self.response.current {
            case .http(let status, let body):
                guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                     headerFields: ["Content-Type": "application/json"]) else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            case .nonHTTP:
                client?.urlProtocol(self, didReceive: URLResponse(url: url, mimeType: nil,
                    expectedContentLength: 0, textEncodingName: nil), cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            case .hold:
                return
            }
            Self.finished.access { $0 += 1 }
        }

        override func stopLoading() {
            Self.stopped.access { $0 += 1 }
        }
    }
}
