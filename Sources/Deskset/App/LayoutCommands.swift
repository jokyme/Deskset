import AppKit
import Darwin
import DesksetCore

/// The documented application commands supported here; this is not a shell or an arbitrary bang evaluator.
enum LayoutCommand: Equatable {
    case loadLayout(String)
    case manageLayouts
    case about(AboutWindowController.Tab)
    case debug(DebugWindowController.Tab, config: String?)
    case restart

    enum ParseResult: Equatable { case none, command(LayoutCommand), invalid(String) }

    static func parse(_ arguments: [String]) -> ParseResult {
        let args = Array(arguments.dropFirst())
        guard let first = args.first else { return .none }
        if first.caseInsensitiveCompare("/Restart") == .orderedSame {
            guard args.count == 1 else { return .invalid("use Deskset /Restart without additional arguments") }
            return .command(.restart)
        }
        guard first.hasPrefix("!") else { return .none }
        switch first.lowercased() {
        case "!restart":
            guard args.count == 1 else { return .invalid("use Deskset '!Restart' without additional arguments") }
            return .command(.restart)
        case "!loadlayout":
            guard args.count == 2, LayoutStore.isValidName(args[1]) else {
                return .invalid("use Deskset '!LoadLayout' \"Layout name\" with one valid saved layout name")
            }
            return .command(.loadLayout(args[1]))
        case "!manage":
            guard args.count == 2, args[1].caseInsensitiveCompare("Layouts") == .orderedSame else {
                return .invalid("the supported Manage command is Deskset '!Manage' Layouts")
            }
            return .command(.manageLayouts)
        case "!about":
            guard args.count <= 2 else {
                return .invalid("use Deskset '!About' [Log|Skins|Plugins|Version]")
            }
            return .command(.about(args.count == 2 ? AboutWindowController.Tab.parse(args[1]) : .version))
        case "!debug":
            guard args.count <= 3 else {
                return .invalid("use Deskset '!Debug' [Log|Display|Network|Plugins|Skin] [Config]")
            }
            let tab = DebugWindowController.Tab.parse(args.count >= 2 ? args[1] : nil)
            let config = args.count == 3 ? SkinLibrary.normalizedConfigName(args[2]) : nil
            return .command(.debug(tab, config: config?.isEmpty == false ? config : nil))
        default:
            return .invalid("unsupported application command \(first)")
        }
    }
}

/// Reopening files is the existing duplicate-launch behavior, carried over the same same-user connection.
enum LayoutCommandRequest: Equatable {
    case command(LayoutCommand)
    case reopen([URL])

    var fields: [String: String] {
        switch self {
        case .command(.loadLayout(let name)): return ["kind": "load", "name": name]
        case .command(.manageLayouts): return ["kind": "manage"]
        case .command(.about(let tab)): return ["kind": "about", "tab": tab.rawValue]
        case .command(.debug(let tab, let config)):
            var fields = ["kind": "debug", "tab": tab.rawValue]
            if let config { fields["config"] = config }
            return fields
        case .command(.restart): return ["kind": "restart"]
        case .reopen(let urls):
            return ["kind": "reopen", "files": urls.map(\.absoluteString).joined(separator: "\n")]
        }
    }

    init?(fields: [String: String]) {
        switch fields["kind"] {
        case "restart": self = .command(.restart)
        case "load":
            guard let name = fields["name"], LayoutStore.isValidName(name) else { return nil }
            self = .command(.loadLayout(name))
        case "manage": self = .command(.manageLayouts)
        case "about":
            guard let raw = fields["tab"], let tab = AboutWindowController.Tab(rawValue: raw) else { return nil }
            self = .command(.about(tab))
        case "debug":
            guard let raw = fields["tab"], let tab = DebugWindowController.Tab(rawValue: raw) else { return nil }
            self = .command(.debug(tab, config: fields["config"]))
        case "reopen":
            let strings = (fields["files"] ?? "").split(separator: "\n").map(String.init)
            let urls = strings.compactMap(URL.init(string:))
            guard urls.count == strings.count, urls.allSatisfy(\.isFileURL) else { return nil }
            self = .reopen(urls)
        default: return nil
        }
    }
}

/// The transport is replaceable, so tests use a private memory channel and never signal the user's running app.
protocol LayoutCommandChannel: AnyObject {
    func observe(_ name: String, receive: @escaping ([String: String]) -> Void) -> () -> Void
    func post(_ name: String, fields: [String: String])
}

final class DistributedLayoutCommandChannel: LayoutCommandChannel {
    private let center = DistributedNotificationCenter.default()
    private let user = String(getuid())

    func observe(_ name: String, receive: @escaping ([String: String]) -> Void) -> () -> Void {
        let token = center.addObserver(forName: Notification.Name(name), object: user, queue: .main) { notification in
            guard let fields = notification.userInfo as? [String: String] else { return }
            receive(fields)
        }
        return { [center] in center.removeObserver(token) }
    }

    func post(_ name: String, fields: [String: String]) {
        center.postNotificationName(Notification.Name(name), object: user, userInfo: fields, deliverImmediately: true)
    }
}

/// An advisory lock prevents concurrent launches (including unbundled command-line launches) from loading twice.
/// The file remains after release: unlinking an occupied lock could let a third process lock a different inode.
final class LayoutInstanceLock {
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { release() }

    func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    static func acquire(at url: URL) throws -> LayoutInstanceLock? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw POSIXError(.EACCES)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(fd)
            if error == EWOULDBLOCK || error == EAGAIN { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        let data = Data(String(getpid()).utf8)
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0, ftruncate(fd, 0) == 0,
              data.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == data.count else {
            let error = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        return LayoutInstanceLock(descriptor: fd)
    }

    static func owner(at url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8), let pid = pid_t(text), pid > 0,
              kill(pid, 0) == 0 || errno == EPERM else { return nil }
        return pid
    }
}

final class LayoutCommandServer {
    static let namespace = "app.deskset.Deskset.layouts.v1"
    private let channel: LayoutCommandChannel
    private let namespace: String
    private let pid: pid_t
    private let handler: (LayoutCommandRequest, @escaping (Bool) -> Void) -> Void
    private var cancelObservation: (() -> Void)?
    private var terminationObserver: NSObjectProtocol?
    private var instanceLock: LayoutInstanceLock?
    private var inFlight = Set<String>()
    private var results: [String: Bool] = [:]
    private var resultOrder: [String] = []

    init(channel: LayoutCommandChannel = DistributedLayoutCommandChannel(), namespace: String = LayoutCommandServer.namespace,
         pid: pid_t = getpid(), instanceLock: LayoutInstanceLock? = nil,
         handler: @escaping (LayoutCommandRequest, @escaping (Bool) -> Void) -> Void) {
        self.channel = channel
        self.namespace = namespace
        self.pid = pid
        self.instanceLock = instanceLock
        self.handler = handler
        cancelObservation = channel.observe(namespace + ".request") { [weak self] in self?.receive($0) }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in self?.stop() }
    }

    deinit { stop() }

    func stop() {
        cancelObservation?()
        cancelObservation = nil
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        terminationObserver = nil
        instanceLock?.release()
        instanceLock = nil
    }

    private func reply(id: String, success: Bool) {
        channel.post(namespace + ".reply", fields: ["id": id, "pid": String(pid), "ok": success ? "1" : "0"])
    }

    private func receive(_ fields: [String: String]) {
        guard let id = fields["id"], UUID(uuidString: id) != nil else { return }
        if fields["kind"] == "probe" {
            reply(id: id, success: true)
            return
        }
        guard fields["pid"] == String(pid) else { return }
        if let result = results[id] { reply(id: id, success: result); return }
        guard !inFlight.contains(id) else { return }
        guard let request = LayoutCommandRequest(fields: fields) else { reply(id: id, success: false); return }
        inFlight.insert(id)
        handler(request) { [weak self] success in
            guard let self else { return }
            self.inFlight.remove(id)
            self.results[id] = success
            self.resultOrder.append(id)
            if self.resultOrder.count > 128 { self.results.removeValue(forKey: self.resultOrder.removeFirst()) }
            self.reply(id: id, success: success)
        }
    }
}

enum LayoutCommandDelivery: Equatable {
    case noListener
    case succeeded
    case failed(String)
}

struct LayoutCommandClient {
    var channel: LayoutCommandChannel = DistributedLayoutCommandChannel()
    var namespace = LayoutCommandServer.namespace

    /// A probe has no side effects. Only a request addressed to the responding PID can run a command.
    func discover(timeout: TimeInterval = 0.2) -> pid_t? {
        let id = UUID().uuidString
        var found: pid_t?
        let cancel = channel.observe(namespace + ".reply") { fields in
            guard fields["id"] == id, let raw = fields["pid"], let pid = pid_t(raw), pid > 0 else { return }
            found = pid
        }
        defer { cancel() }
        poll(timeout: timeout, done: { found != nil }) {
            channel.post(namespace + ".request", fields: ["id": id, "kind": "probe"])
        }
        return found
    }

    func forwardIfRunning(_ request: LayoutCommandRequest, timeout: TimeInterval = 45) -> LayoutCommandDelivery {
        guard let pid = discover() else { return .noListener }
        return send(request, to: pid, timeout: timeout)
    }

    func send(_ request: LayoutCommandRequest, to pid: pid_t, timeout: TimeInterval = 45) -> LayoutCommandDelivery {
        guard pid > 0 else { return .failed("The running instance has no valid process identifier.") }
        let id = UUID().uuidString
        var response: Bool?
        let cancel = channel.observe(namespace + ".reply") { fields in
            guard fields["id"] == id, fields["pid"] == String(pid) else { return }
            if fields["ok"] == "1" { response = true }
            else if fields["ok"] == "0" { response = false }
        }
        defer { cancel() }
        var fields = request.fields
        fields["id"] = id
        fields["pid"] = String(pid)
        poll(timeout: timeout, done: { response != nil }) { channel.post(namespace + ".request", fields: fields) }
        switch response {
        case true: return .succeeded
        case false: return .failed("The running Deskset instance could not complete the request. See its log for details.")
        case nil: return .failed("The running Deskset instance did not answer. No second desktop was started.")
        }
    }

    private func poll(timeout: TimeInterval, done: () -> Bool, send: () -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var nextSend = -Double.infinity
        repeat {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextSend { send(); nextSend = now + 0.2 }
            if done() { return }
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        } while ProcessInfo.processInfo.systemUptime < deadline
    }
}

extension AppController {
    func receiveLayoutCommand(_ request: LayoutCommandRequest, completion: @escaping (Bool) -> Void) {
        guard !isTerminating else { completion(false); return }
        guard layoutCommandsReady else { pendingLayoutCommands.append((request, completion)); return }
        executeLayoutCommand(request, completion: completion)
    }

    func finishLayoutCommandStartup() {
        layoutCommandsReady = true
        let pending = pendingLayoutCommands
        pendingLayoutCommands.removeAll()
        for (request, completion) in pending { executeLayoutCommand(request, completion: completion) }
    }

    func executeLayoutCommand(_ request: LayoutCommandRequest, completion: @escaping (Bool) -> Void) {
        switch request {
        case .command(.restart): requestRestart(completion: completion)
        case .command(.loadLayout(let name)): loadLayout(named: name, completion: completion)
        case .command(.manageLayouts):
            showManageWindow(selecting: nil, file: nil, tab: .layouts)
            completion(true)
        case .command(.about(let tab)):
            showAbout(tab: tab)
            completion(true)
        case .command(.debug(let tab, let config)):
            showDebug(tab: tab, config: config)
            completion(true)
        case .reopen(let urls):
            if urls.isEmpty { _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) }
            else { application(NSApp, open: urls) }
            completion(true)
        }
    }
}
