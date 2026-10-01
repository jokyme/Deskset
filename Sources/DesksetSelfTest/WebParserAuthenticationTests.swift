import Foundation
@testable import DesksetCore

func runWebParserAuthenticationTests(_ t: TestRunner) {
    t.suite("WebParser: NoAuth after completed URL authentication") {
        guard let server = WebParserTestServer() else {
            t.check(false, "could not bind the loopback authentication server")
            return
        }
        let credential = "user:secret"  // Synthetic fixture only; never included in failure messages.
        let authorization = "Basic " + Data(credential.utf8).base64EncodedString()
        let realm = "Deskset-authentication-\(UUID().uuidString)"
        server.handler = { request in
            if request.headers["authorization"] == authorization {
                return .text("<v>welcome</v>")
            }
            return .text("denied", status: 401,
                         headers: ["WWW-Authenticate": "Basic realm=\"\(realm)\""])
        }

        var handles: [WebParserFetchHandle] = []
        var replies: [(label: String, reply: WebParserAuthenticationReply)] = []
        defer {
            for handle in handles { handle.cancel() }
            server.stop()
            for entry in replies {
                t.equal(entry.reply.snapshot().count, 1, "\(entry.label) completion count")
            }
            let sessions = WebParserNetwork.shared.sessionCount
            t.check(sessions <= WebParserNetwork.maxSessions + 1, "\(sessions) sessions")
        }

        func fetch(_ path: String, label: String, noAuth: Bool,
                   status: Int, body: String) -> Bool {
            guard let url = URL(string: "http://\(credential)@127.0.0.1:\(server.port)\(path)") else {
                t.check(false, "could not form the synthetic \(label) URL")
                return false
            }
            var request = WebParserRequest(target: .http(url))
            request.proxy = "/none"
            request.flags.noAuth = noAuth
            let reply = WebParserAuthenticationReply()
            replies.append((label, reply))
            handles.append(WebParserNetwork.shared.start(request) { reply.receive($0) })

            // Completion is bounded by the existing network timeouts and suite watchdog.
            // Do not start the next request until the preceding completion has arrived.
            while !reply.hasCompleted {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            let received = reply.snapshot()
            guard let result = received.result else {
                t.check(false, "\(label) completed without a result")
                return false
            }
            guard case .success(let response) = result else {
                // A connection error can contain the URL; keep its userinfo out of logs.
                t.check(false, "\(label) did not return an HTTP response")
                return false
            }
            let requests = server.requests.filter { $0.target == path }
            t.check(!requests.isEmpty, "\(label) did not reach the loopback server")
            t.check(!response.data.isEmpty, "\(label) returned an empty response")
            t.equal(response.statusCode, status, "\(label) status")
            t.equal(String(decoding: response.data, as: UTF8.self), body, "\(label) body")
            let headerMatches: Bool
            if noAuth {
                headerMatches = requests.allSatisfy { $0.headers["authorization"] == nil }
                t.check(headerMatches, "\(label) sent Authorization")
            } else {
                headerMatches = requests.contains { $0.headers["authorization"] == authorization }
                t.check(headerMatches, "\(label) did not send the synthetic Authorization canary")
            }
            return received.count == 1 && !requests.isEmpty && !response.data.isEmpty
                && response.statusCode == status && response.data == Data(body.utf8) && headerMatches
        }

        guard fetch("/private2-cold", label: "cold NoAuth", noAuth: true,
                    status: 401, body: "denied") else { return }
        guard fetch("/private", label: "URL authentication", noAuth: false,
                    status: 200, body: "<v>welcome</v>") else { return }
        _ = fetch("/private2", label: "warm NoAuth", noAuth: true, status: 401, body: "denied")
    }
}

/// The network completion runs on a background queue; only this reply crosses threads.
private final class WebParserAuthenticationReply {
    private let lock = NSLock()
    private var result: Result<WebParserResponse, WebParserFetchError>?
    private var count = 0

    func receive(_ value: Result<WebParserResponse, WebParserFetchError>) {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        if result == nil { result = value }
    }

    var hasCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count > 0
    }

    func snapshot() -> (result: Result<WebParserResponse, WebParserFetchError>?, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (result, count)
    }
}
