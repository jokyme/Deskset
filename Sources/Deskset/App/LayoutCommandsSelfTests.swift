import AppKit
import Darwin
import DesksetCore

enum LayoutCommandsSelfTests {
    final class MemoryChannel: LayoutCommandChannel {
        var observers: [String: [UUID: ([String: String]) -> Void]] = [:]
        var sent: [(String, [String: String])] = []

        func observe(_ name: String, receive: @escaping ([String: String]) -> Void) -> () -> Void {
            let id = UUID()
            observers[name, default: [:]][id] = receive
            return { [weak self] in self?.observers[name]?[id] = nil }
        }

        func post(_ name: String, fields: [String: String]) {
            sent.append((name, fields))
            let callbacks = Array(observers[name]?.values ?? Dictionary<UUID, ([String: String]) -> Void>().values)
            for callback in callbacks { callback(fields) }
        }

        var observerCount: Int { observers.values.reduce(0) { $0 + $1.count } }
    }

    static func run(_ t: AppTestRunner) {
        t.suite("App: Layout commands: strict parsing and request encoding") {
            t.equal(LayoutCommand.parse(["Deskset"]), .none)
            for command in ["!Restart", "!restart", "/Restart", "/RESTART"] {
                t.equal(LayoutCommand.parse(["Deskset", command]), .command(.restart))
            }
            t.equal(LayoutCommand.parse(["Deskset", "--self-test", "!LoadLayout"]), .none)
            t.equal(LayoutCommand.parse(["Deskset", "!LoadLayout", "My Desktop"]), .command(.loadLayout("My Desktop")))
            t.equal(LayoutCommand.parse(["Deskset", "!loadlayout", "@Backup"]), .command(.loadLayout("@Backup")))
            t.equal(LayoutCommand.parse(["Deskset", "!MANAGE", "layouts"]), .command(.manageLayouts))
            t.equal(LayoutCommand.parse(["Deskset", "!About"]), .command(.about(.version)))
            t.equal(LayoutCommand.parse(["Deskset", "!about", "Log"]), .command(.about(.log)))
            t.equal(LayoutCommand.parse(["Deskset", "!About", "Skins"]), .command(.about(.skins)))
            t.equal(LayoutCommand.parse(["Deskset", "!About", "Measures"]), .command(.about(.skins)))
            t.equal(LayoutCommand.parse(["Deskset", "!About", "Plugins"]), .command(.about(.plugins)))
            t.equal(LayoutCommand.parse(["Deskset", "!About", "Version"]), .command(.about(.version)))
            t.equal(LayoutCommand.parse(["Deskset", "!About", "UnknownTab"]), .command(.about(.version)))
            t.equal(LayoutCommand.parse(["Deskset", "!Debug"]), .command(.debug(.log, config: nil)))
            t.equal(LayoutCommand.parse(["Deskset", "!DEBUG", "display"]), .command(.debug(.display, config: nil)))
            t.equal(LayoutCommand.parse(["Deskset", "!Debug", "Network"]), .command(.debug(.network, config: nil)))
            t.equal(LayoutCommand.parse(["Deskset", "!Debug", "Plugins"]), .command(.debug(.plugins, config: nil)))
            t.equal(LayoutCommand.parse(["Deskset", "!Debug", "Skin", "App/Focus/"]),
                    .command(.debug(.skins, config: "App\\Focus")))
            t.equal(LayoutCommand.parse(["Deskset", "!Debug", "Skin"]), .command(.debug(.skins, config: nil)))
            t.equal(LayoutCommand.parse(["Deskset", "!Debug", "UnknownTab"]), .command(.debug(.log, config: nil)))
            for args in [["!Restart", "extra"], ["/Restart", "extra"], ["!LoadLayout"], ["!LoadLayout", ""], ["!LoadLayout", "../outside"],
                         ["!LoadLayout", "one", "two"], ["!Manage"], ["!Manage", "Skins"],
                         ["!Manage", "Layouts", "config"], ["!About", "Skins", "extra"],
                         ["!Debug", "Skin", "App\\Focus", "extra"],
                         ["!Execute", "rm -rf /"], ["!RefreshApp"]] {
                if case .invalid = LayoutCommand.parse(["Deskset"] + args) { t.check(true) }
                else { t.check(false, "rejects \(args)") }
            }
            let requests: [LayoutCommandRequest] = [
                .command(.loadLayout("My Desktop")), .command(.manageLayouts),
                .command(.restart),
                .command(.about(.log)), .command(.about(.skins)),
                .command(.about(.plugins)), .command(.about(.version)),
                .command(.debug(.log, config: nil)), .command(.debug(.display, config: nil)),
                .command(.debug(.network, config: nil)), .command(.debug(.plugins, config: nil)),
                .command(.debug(.skins, config: "App\\Focus")),
                .reopen([]), .reopen([URL(fileURLWithPath: "/tmp/a file.rmskin"), URL(fileURLWithPath: "/tmp/line\nbreak.ini")]),
            ]
            for request in requests { t.equal(LayoutCommandRequest(fields: request.fields), request) }
            for invalidTab in ["Measures", "skins", "UnknownTab", ""] {
                t.equal(LayoutCommandRequest(fields: ["kind": "about", "tab": invalidTab]), nil)
            }
            t.equal(LayoutCommandRequest(fields: ["kind": "about"]), nil)
            for invalidTab in ["Skin", "skins", "UnknownTab", ""] {
                t.equal(LayoutCommandRequest(fields: ["kind": "debug", "tab": invalidTab]), nil)
            }
            t.equal(LayoutCommandRequest(fields: ["kind": "debug"]), nil)
            t.equal(LayoutCommandRequest(fields: ["kind": "load", "name": "../outside"]), nil)
            t.equal(LayoutCommandRequest(fields: ["kind": "reopen", "files": "https://example.com/x.ini"]), nil)
            t.equal(LayoutCommandRequest(fields: ["kind": "execute", "name": "!Quit"]), nil)
        }

        t.suite("App: Layout commands: discovery, PID routing and failed completion") {
            let channel = MemoryChannel()
            let namespace = "DesksetTests.\(UUID().uuidString)"
            var requests: [LayoutCommandRequest] = []
            let server = LayoutCommandServer(channel: channel, namespace: namespace, pid: 121) { request, completion in
                requests.append(request)
                completion(request != .command(.loadLayout("Missing")))
            }
            defer { server.stop() }
            let client = LayoutCommandClient(channel: channel, namespace: namespace)
            t.equal(client.discover(timeout: 0.01), 121)
            t.equal(requests, [], "discovery does not execute commands")
            t.equal(client.forwardIfRunning(.command(.loadLayout("Desktop")), timeout: 0.01), .succeeded)
            t.equal(requests, [.command(.loadLayout("Desktop"))])
            t.equal(client.send(.command(.manageLayouts), to: 121, timeout: 0.01), .succeeded)
            t.equal(requests.last, .command(.manageLayouts))
            t.equal(client.send(.command(.debug(.skins, config: "App\\Focus")), to: 121, timeout: 0.01), .succeeded)
            t.equal(requests.last, .command(.debug(.skins, config: "App\\Focus")))
            if case .failed(let message) = client.send(.command(.loadLayout("Missing")), to: 121, timeout: 0.01) {
                t.check(message.contains("could not complete"))
            } else { t.check(false, "reports a failed layout load") }
            let count = requests.count
            if case .failed = client.send(.command(.manageLayouts), to: 999, timeout: 0.01) { t.check(true) }
            else { t.check(false, "a different PID never accepts the request") }
            t.equal(requests.count, count)
            t.equal(channel.observerCount, 1, "clients remove their response observers")
            server.stop()
            t.equal(channel.observerCount, 0)
            t.equal(client.discover(timeout: 0.01), nil)
            t.equal(client.forwardIfRunning(.command(.manageLayouts), timeout: 0.01), .noListener)
            if case .failed(let message) = client.send(.command(.manageLayouts), to: 121, timeout: 0.01) {
                t.check(message.contains("No second desktop"))
            } else { t.check(false, "no listener is a diagnosed timeout") }
        }

        t.suite("App: Layout commands: retries never execute one request twice") {
            let channel = MemoryChannel()
            let namespace = "DesksetTests.\(UUID().uuidString)"
            var calls = 0
            var complete: ((Bool) -> Void)?
            let server = LayoutCommandServer(channel: channel, namespace: namespace, pid: 42) { _, completion in
                calls += 1
                complete = completion
            }
            defer { server.stop() }
            let id = UUID().uuidString
            let fields = ["id": id, "pid": "42", "kind": "load", "name": "Desktop"]
            channel.post(namespace + ".request", fields: fields)
            channel.post(namespace + ".request", fields: fields)
            t.equal(calls, 1, "pending duplicate is ignored")
            complete?(true)
            channel.post(namespace + ".request", fields: fields)
            t.equal(calls, 1, "completed duplicate repeats its acknowledgement")
            t.equal(channel.sent.filter { $0.0 == namespace + ".reply" && $0.1["id"] == id }.count, 2)
            channel.post(namespace + ".request", fields: ["id": "not-a-uuid", "pid": "42", "kind": "manage"])
            channel.post(namespace + ".request", fields: ["id": UUID().uuidString, "pid": "7", "kind": "manage"])
            t.equal(calls, 1)
        }

        t.suite("App: Layout commands: instance lock and listener-not-ready safety") {
            let directory = t.temporaryDirectory("layout-command-lock")
            let file = directory.appendingPathComponent("instance.lock")
            let first = try LayoutInstanceLock.acquire(at: file)
            defer { first?.release() }
            t.check(first != nil)
            t.equal(LayoutInstanceLock.owner(at: file), getpid())
            t.equal(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
            let second = try LayoutInstanceLock.acquire(at: file)
            t.check(second == nil, "an occupied lock cannot start another desktop")
            let channel = MemoryChannel()
            let client = LayoutCommandClient(channel: channel, namespace: "DesksetTests.\(UUID().uuidString)")
            t.equal(client.discover(timeout: 0.01), nil, "the first launch can own its lock before listening")
            if case .failed = client.send(.command(.manageLayouts), to: getpid(), timeout: 0.01) { t.check(true) }
            else { t.check(false, "an unready owner times out instead of authorizing a duplicate") }
            first?.release()
            t.check(FileManager.default.fileExists(atPath: file.path), "releasing never unlinks the lock file")
            let next = try LayoutInstanceLock.acquire(at: file)
            t.check(next != nil, "a stale file is reusable")
            next?.release()
            let linked = directory.appendingPathComponent("linked.lock")
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: file)
            do {
                let unexpected = try LayoutInstanceLock.acquire(at: linked)
                unexpected?.release()
                t.check(false, "a symlink cannot redirect the lock write")
            } catch { t.check(true) }
        }

        t.suite("App: Layout commands: requests wait for startup and preserve load results") {
            guard let app = try AppSelfTest.makeApp(t), app.activate(config: "App\\Focus", file: "Focus.ini") != nil else { return }
            try app.saveLayout(named: "Empty", options: LayoutSaveOptions(empty: true))
            var result: Bool?
            app.receiveLayoutCommand(.command(.loadLayout("Empty"))) { result = $0 }
            t.equal(result, nil)
            t.equal(app.pendingLayoutCommands.count, 1)
            t.equal(app.controllers.count, 1, "a startup request does not race initial skin loading")
            app.finishLayoutCommandStartup()
            t.check(AppSelfTest.spin { result != nil })
            t.equal(result, true)
            t.equal(app.controllers.count, 0)
            t.equal(app.pendingLayoutCommands.count, 0)
            result = nil
            app.receiveLayoutCommand(.command(.loadLayout("Missing"))) { result = $0 }
            t.check(AppSelfTest.spin { result != nil })
            t.equal(result, false, "a failed load reaches the command caller")
            t.equal(app.controllers.count, 0)
        }

        // This opt-in check uses the system notification service but a unique channel, never the real app channel.
        // Headless CI does not necessarily have a per-user distributed notification session.
        if ProcessInfo.processInfo.environment["DESKSET_TEST_LAYOUT_IPC"] == "1" {
            t.suite("App: Layout commands: private distributed notification transport") {
                let namespace = "DesksetTests.\(UUID().uuidString)"
                var requests: [LayoutCommandRequest] = []
                let server = LayoutCommandServer(namespace: namespace) { request, completion in
                    requests.append(request)
                    completion(true)
                }
                defer { server.stop() }
                let client = LayoutCommandClient(namespace: namespace)
                t.equal(client.discover(timeout: 2), getpid(), "private discovery crosses the system notification service")
                t.equal(client.send(.command(.loadLayout("An isolated test layout")), to: getpid(), timeout: 2), .succeeded)
                t.equal(requests, [.command(.loadLayout("An isolated test layout"))])
            }
        }
    }
}
