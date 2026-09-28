import Darwin
import Foundation

// Every way a skin reaches outside itself that is not a request to its host (the runtime design, "side-effect
// sandbox"): the programs its plugins start and the signals they send them, the files they write, the Mac's audio,
// media players and key events. A skin reaches them through `Skin.sideEffects`:
//
// - `LiveSideEffects` does them for real. The code is what the plugins ran before, moved here unchanged; the app does
//   its own part (audio, players, keys) in the plugins' files, behind `perform(_:live:)`.
// - `RecordingSideEffects` (RecordingSideEffects.swift) is for a run that must leave the Mac alone — the Studio's
//   instance of a widget, a verification run. It keeps a typed record of each effect (`SideEffect`), starts no
//   program, and sends the files the skin writes to a copy of the skin tree, where the skin reads them back.
//
// What stays elsewhere: the bangs a skin runs are filtered by its `SkinActionPolicy` (a policy may bring side effects
// of its own: the Studio's does), and what a skin asks of its host — its window, other skins, opening a web page, a
// file or a program, the clipboard, the wallpaper, a sound — goes through `SkinHost`, which a sandboxed run replaces
// with a `RecordingSkinHost`.

// MARK: - Values

/// One way out of a skin, as a recording keeps it.
public enum SideEffect: Equatable, Sendable, CustomStringConvertible {
    /// A program started: RunCommand's command line (`/bin/sh -c …`, in `directory`), or a plugin's helper program
    /// (`open`, `osascript`: FileView, RecycleManager; `directory` nil).
    case launch(executable: String, arguments: [String], directory: String?)
    /// A signal sent to a program the skin started (RunCommand's Close, Kill and Timeout, or the skin unloading it):
    /// the program's command line.
    case signal(Int32, command: String)
    /// A file written whole: RunCommand's `OutputFile`, WebParser's `DownloadFile` and `Debug=2` dump, a script's
    /// `io.open` for writing.
    case writeFile(path: String)
    /// A script removed a file (`os.remove`).
    case removeFile(path: String)
    /// A script renamed a file (`os.rename`).
    case renameFile(from: String, to: String)
    /// `!WriteKeyValue`: one key of an .ini file.
    case writeKeyValue(file: String, section: String, key: String, value: String)
    /// The Mac's audio (Win7Audio, AppVolume).
    case audio(AudioEffect)
    /// A media player controlled, opened or quit: the plugin (`NowPlaying`, `iTunes`, `WebNowPlaying`) and the command
    /// as the skin gave it.
    case media(plugin: String, command: String)
    /// A MediaKey key (`PlayPause`, `VolumeUp`…): a key event, or without Accessibility the player or the volume.
    case mediaKey(String)
    /// Asked of the host (`RecordingSkinHost`): a bang the engine leaves to the host (the window, the app, skin
    /// groups…), as written.
    case hostBang(String)
    /// Asked of the host: a bang for another skin (`config`; `*` for every other skin).
    case forwardBang(String, config: String)
    /// Asked of the host: a web page, a file or a program opened (`["target" arguments…]`).
    case open(target: String, arguments: [String])

    public var description: String {
        func quoted(_ s: String) -> String { s.isEmpty || s.contains(" ") ? "\"\(s)\"" : s }
        switch self {
        case .launch(let executable, let arguments, let directory):
            return "launch " + ([executable] + arguments).map(quoted).joined(separator: " ")
                + (directory.map { " (in \($0))" } ?? "")
        case .signal(let signal, let command): return "signal \(signal) to \(command)"
        case .writeFile(let path): return "write \(path)"
        case .removeFile(let path): return "os.remove \(path)"
        case .renameFile(let from, let to): return "os.rename \(from) \(to)"
        case .writeKeyValue(let file, let section, let key, let value):
            return "!WriteKeyValue \(quoted(section)) \(quoted(key)) \(quoted(value)) \(quoted(file))"
        case .audio(let effect): return "audio \(effect)"
        case .media(let plugin, let command): return "\(plugin) \(command)"
        case .mediaKey(let key): return "MediaKey \(key)"
        case .hostBang(let text): return text
        case .forwardBang(let text, let config): return "\(text) → \(config)"
        case .open(let target, let arguments): return "open " + ([target] + arguments).map(quoted).joined(separator: " ")
        }
    }
}

/// A change of the Mac's audio a skin asked for.
public enum AudioEffect: Equatable, Sendable {
    /// Win7Audio: the default output's volume set to a percentage (as the skin gave it).
    case setVolume(Double)
    /// Win7Audio: the default output's volume changed by percentage points.
    case changeVolume(Double)
    /// Win7Audio: the default output muted, unmuted, or the other way round.
    case mute
    case unmute
    case toggleMute
    /// Win7Audio: the next or previous output device made the default, or the nth (1 = first).
    case nextOutput
    case previousOutput
    case selectOutput(Int)
    /// AppVolume: an app muted, unmuted, or the other way round (the app as the measure names it: its `AppName`, or
    /// `Index n`).
    case muteApp(String)
    case unmuteApp(String)
    case toggleMuteApp(String)
}

// MARK: - Protocol

/// A program a skin started (`SideEffects.startShellCommand`). Thread-safe.
public protocol SkinProcess: AnyObject {
    /// Called once, on any thread, when the program has exited and its output has been read. Set before `resume()`.
    var onExit: (() -> Void)? { get set }
    /// Starts reading its output and watching for its exit.
    func resume()
    /// Sends `signal` to the program and the programs it started. False when that failed.
    @discardableResult
    func signal(_ signal: Int32) -> Bool
    /// Its standard output so far.
    func outputSnapshot() -> Data
}

/// The ways out of a skin that do not go through its host (see the top of this file). Thread-safe: plugins reach it
/// from the skin's thread and from their background work (capture `skin.sideEffects` on the skin's thread first).
public protocol SideEffects: AnyObject {
    /// True when the effects happen (`LiveSideEffects`); false for a recording.
    var isLive: Bool { get }

    /// RunCommand: starts `/bin/sh -c command` in `directory`, in a process group of its own, with its standard output
    /// kept (up to `maxOutput` bytes); `locale` (the user's) sets `LANG` when the app has none.
    func startShellCommand(_ command: String, directory: String, maxOutput: Int, locale: Locale) throws -> SkinProcess
    /// A plugin's helper program (`open`, `osascript`), which nothing waits for: `completion` (if any) gets its exit
    /// status, on any thread.
    func launch(_ executable: String, _ arguments: [String], completion: ((Int32) -> Void)?)

    /// Where a file the skin writes whole goes (a DownloadFile, a Debug=2 dump, an OutputFile): `url` itself, or a
    /// recording's copy (the write is recorded now). Asked on the skin's thread, before the write.
    func destination(forWriting url: URL) -> URL
    /// Where a file of the app's own goes that the skin sees but that is none of the skin's files (a WebParser download
    /// without DownloadFile, in the temporary folder): `url` itself, or a recording's scratch folder (not recorded).
    func temporaryDestination(for url: URL) -> URL
    /// Writes `data` to `url` (from `destination(forWriting:)` or `temporaryDestination(for:)`) atomically, making its
    /// folder first when `makingFolder`.
    func writeFile(_ data: Data, to url: URL, makingFolder: Bool) throws
    /// Removes a file from `temporaryDestination(for:)`.
    func removeTemporaryFile(atPath path: String)
    /// `!WriteKeyValue`: `key` of `[section]` in `fileURL` becomes `value` (`IniWriter.writeValue`).
    func writeKeyValue(_ value: String, key: String, section: String, fileURL: URL) throws
    /// Where the files the skin's scripts write go (`io.open` for writing, `io.output`, `os.remove`, `os.rename`): nil
    /// for the files themselves, or a recording's copy.
    var fileSandbox: SkinFileSandbox? { get }

    /// An effect the app carries out in the plugins' own files (the Mac's audio, a media player, a key event): `live`
    /// does it and runs at once; a recording keeps `effect` and never calls `live`.
    func perform(_ effect: SideEffect, live: () -> Void)
}

extension SideEffects {
    /// `launch`, with the exit status handed to `executor` (the skin that asked), never inline.
    public func launch(_ executable: String, _ arguments: [String], on executor: SkinExecutor,
                       completion: @escaping (Int32) -> Void) {
        launch(executable, arguments) { status in executor.async { completion(status) } }
    }
}

// MARK: - Live

/// The effects done for real: what the engine and its plugins did before there was a seam, moved here unchanged.
public final class LiveSideEffects: SideEffects {
    /// The one every skin uses unless it is given a recording.
    public static let shared = LiveSideEffects()

    private init() {}

    public var isLive: Bool { true }
    public var fileSandbox: SkinFileSandbox? { nil }

    public func startShellCommand(_ command: String, directory: String, maxOutput: Int,
                                  locale: Locale) throws -> SkinProcess {
        try RunCommandJob.start(shellCommand: command, directory: directory, maxOutput: maxOutput, locale: locale)
    }

    public func launch(_ executable: String, _ arguments: [String], completion: ((Int32) -> Void)?) {
        PluginProcess.launcher(executable, arguments, completion)
    }

    public func destination(forWriting url: URL) -> URL { url }
    public func temporaryDestination(for url: URL) -> URL { url }

    public func writeFile(_ data: Data, to url: URL, makingFolder: Bool) throws {
        try LiveSideEffects.write(data, to: url, makingFolder: makingFolder)
    }

    public func removeTemporaryFile(atPath path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    public func writeKeyValue(_ value: String, key: String, section: String, fileURL: URL) throws {
        try IniWriter.writeValue(value, key: key, section: section, fileURL: fileURL)
    }

    public func perform(_ effect: SideEffect, live: () -> Void) { live() }

    /// Writes `data` to `url` atomically, making its folder first when `makingFolder` (a recording writes its copies
    /// with it too).
    static func write(_ data: Data, to url: URL, makingFolder: Bool) throws {
        if makingFolder {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Helper programs

/// Helper programs of the plugins (`open`, `osascript`), started off the main thread; nothing waits for them. Skins
/// start them through `Skin.sideEffects`; the live side effects use `launcher`.
enum PluginProcess {
    /// Starts `executable` with `arguments`; `completion` (if any) gets the exit status, on any thread (`run` hands it
    /// to the caller's executor). Tests replace it so that nothing is launched.
    static var launcher: (_ executable: String, _ arguments: [String], _ completion: ((Int32) -> Void)?) -> Void = {
        executable, arguments, completion in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in completion?(p.terminationStatus) }
            do {
                try process.run()
            } catch {
                completion?(-1)
            }
        }
    }

    /// Starts a helper program for real; `completion` gets its exit status on `executor`, never inline.
    static func run(_ executable: String, _ arguments: [String], on executor: SkinExecutor,
                    completion: @escaping (Int32) -> Void) {
        LiveSideEffects.shared.launch(executable, arguments, on: executor, completion: completion)
    }
}

// MARK: - RunCommand's programs

/// A `/bin/sh -c` child in its own process group, with stdout / stderr read on a background queue.
final class RunCommandJob: SkinProcess, @unchecked Sendable {
    enum StartError: Error { case pipe, spawn(Int32) }

    let pid: pid_t
    private let queue = DispatchQueue(label: "Deskset.RunCommand")
    private let lock = NSLock()
    private var output = Data()
    private var errors = Data()
    private let maxOutput: Int
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var exited = false
    private var stdoutClosed = false
    private var reaped = false
    private var stdoutFD: Int32 = -1
    var onExit: (() -> Void)?

    private init(pid: pid_t, stdout: Int32, stderr: Int32, maxOutput: Int) {
        self.pid = pid
        self.maxOutput = maxOutput
        let out = DispatchSource.makeReadSource(fileDescriptor: stdout, queue: queue)
        let err = DispatchSource.makeReadSource(fileDescriptor: stderr, queue: queue)
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        stdoutFD = stdout
        // The handlers keep the job alive until its sources are cancelled (end of file / exit).
        out.setEventHandler { [self] in self.drain(stdout, isOutput: true) }
        out.setCancelHandler { close(stdout) }
        err.setEventHandler { [self] in self.drain(stderr, isOutput: false) }
        err.setCancelHandler { close(stderr) }
        exit.setEventHandler { [self] in self.processExited() }
        stdoutSource = out
        stderrSource = err
        exitSource = exit
    }

    /// `locale`: the user's (`SkinEnvironment.locale`), for `LANG` when the app has none.
    static func start(shellCommand: String, directory: String, maxOutput: Int, locale: Locale) throws -> RunCommandJob {
        var outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw StartError.pipe }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw StartError.pipe
        }
        // Not inherited by programs other code starts meanwhile (that would keep the pipe open after our child exits).
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group (Close / Kill reach the whole command), default signal handlers, and no inherited file
        // descriptors except 0-2.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF
                                                    | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        var environment = ProcessInfo.processInfo.environment
        var path = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for extra in ["/usr/local/bin", "/opt/homebrew/bin"] where !path.contains(extra) { path.insert(extra, at: 0) }
        environment["PATH"] = path.joined(separator: ":")
        // Apps started from Finder have no locale variables: programs would then write non-ASCII text as `?`.
        if environment["LANG"] == nil && environment["LC_ALL"] == nil && environment["LC_CTYPE"] == nil {
            environment["LANG"] = RunCommandJob.defaultLanguage(for: locale)
        }
        let envStrings = environment.map { "\($0.key)=\($0.value)" }
        let args = ["/bin/sh", "-c", shellCommand]
        var pid: pid_t = 0
        let result = withCStrings(args) { argv in
            withCStrings(envStrings) { envp in
                posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
            }
        }
        close(outPipe[1])
        close(errPipe[1])
        guard result == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw StartError.spawn(result)
        }
        _ = fcntl(outPipe[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(errPipe[0], F_SETFL, O_NONBLOCK)
        return RunCommandJob(pid: pid, stdout: outPipe[0], stderr: errPipe[0], maxOutput: maxOutput)
    }

    /// `ll_CC.UTF-8` of `locale` (the user's) when macOS has it (what Terminal sets), else `en_US.UTF-8`. Looked up
    /// once per locale.
    static func defaultLanguage(for locale: Locale) -> String {
        let identifier = locale.identifier.split(separator: "@").first.map(String.init) ?? ""
        languageLock.lock()
        defer { languageLock.unlock() }
        if let known = languages[identifier] { return known }
        let candidate = identifier + ".UTF-8"
        let language = !identifier.isEmpty && FileManager.default.fileExists(atPath: "/usr/share/locale/" + candidate)
            ? candidate : "en_US.UTF-8"
        if languages.count < 64 { languages[identifier] = language }
        return language
    }
    private static let languageLock = NSLock()
    private static var languages: [String: String] = [:]

    /// Starts reading and watching for the exit (set `onExit` first).
    func resume() {
        stdoutSource?.resume()
        stderrSource?.resume()
        exitSource?.resume()
        // The child may have exited before the process source was armed.
        queue.async { [self] in
            var status: Int32 = 0
            lock.lock()
            let exitedNow = !reaped && waitpid(pid, &status, WNOHANG) == pid
            if exitedNow { reaped = true }
            lock.unlock()
            if exitedNow { processExited() }
        }
    }

    /// Sends `sig` to the process group (falls back to the process). False when that failed. Nothing is sent once the
    /// program has been reaped: its process id may belong to another program by then.
    @discardableResult
    func signal(_ sig: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if reaped { return true }
        if kill(-pid, sig) == 0 { return true }
        return kill(pid, sig) == 0 || errno == ESRCH
    }

    func outputSnapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return output
    }

    private func drain(_ fd: Int32, isOutput: Bool) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                lock.lock()
                if isOutput {
                    if output.count < maxOutput { output.append(contentsOf: buffer.prefix(min(n, maxOutput - output.count))) }
                } else if errors.count < 65_536 {
                    errors.append(contentsOf: buffer.prefix(n))
                }
                lock.unlock()
                continue
            }
            if n == 0 {
                // End of file.
                if isOutput {
                    stdoutSource?.cancel()
                    stdoutSource = nil
                    stdoutClosed = true
                    finishIfDone()
                } else {
                    stderrSource?.cancel()
                    stderrSource = nil
                }
            }
            return   // EAGAIN / error: wait for the next event
        }
    }

    private func processExited() {
        lock.lock()
        if !reaped {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == 0 {
                // The exit was reported, so the child is about to become reapable.
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            }
            reaped = true
        }
        lock.unlock()
        exited = true
        exitSource?.cancel()
        exitSource = nil
        // A program that left a background child holding the pipe open still counts as finished: read what is there.
        if stdoutSource != nil, !stdoutClosed {
            queue.asyncAfter(deadline: .now() + 0.05) { [self] in
                if !stdoutClosed { drain(stdoutFD, isOutput: true) }
                if !stdoutClosed {
                    stdoutSource?.cancel()
                    stdoutSource = nil
                    stderrSource?.cancel()
                    stderrSource = nil
                    stdoutClosed = true
                }
                finishIfDone()
            }
            return
        }
        finishIfDone()
    }

    private func finishIfDone() {
        guard exited, stdoutClosed, let callback = onExit else { return }
        onExit = nil
        callback()
    }

    deinit {
        stdoutSource?.cancel()
        stderrSource?.cancel()
        exitSource?.cancel()
    }
}

/// Calls `body` with a NULL-terminated C string array.
private func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for p in pointers where p != nil { free(p) } }
    return body(pointers)
}
