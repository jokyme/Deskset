import Darwin
import Foundation

// Clean-room implementation from the public manual only: https://docs.rainmeter.net/manual/plugins/runcommand/

/// `Plugin=RunCommand`: runs a command on `!CommandMeasure M "Run"` and captures its standard output.
///
/// Values (manual): number -1 before the first run, 0 while running, 1 when it finished, or an error code — 100
/// unknown command, 101 still running, 102 not running (Close / Kill), 103 cannot start, 104 cannot save
/// OutputFile, 105 cannot terminate, 106 cannot create pipe. The string is the program's standard output.
///
/// Mac (see docs/compat/plugins.md for every case):
/// - Commands run through `/bin/sh -c` (the counterpart of `cmd.exe /C`, the default Program) with the skin folder
///   (or `StartInFolder`) as working directory, stdin from /dev/null, a PATH that also has /opt/homebrew/bin and
///   /usr/local/bin, and LANG set to the user's UTF-8 locale when the app has none. `Program` names a Mac program or
///   a shell, optionally with arguments of its own; Windows-only programs and command lines (cmd.exe built-ins such as
///   dir / del / copy, PowerShell, `.exe` / `.bat` files, `C:\` paths, `%VARIABLES%`) cannot run: error 103 without
///   starting anything. Names cmd.exe shares with POSIX commands (sort, find, date, for, if…) run unless the line uses
///   Windows syntax (`/switches`, `%x` loop variables). `start` / `explorer` targets, Windows `ping -n` and
///   `type file` (→ `cat`) are translated. Quotes, escapes and redirections (`2>&1`) reach the shell unchanged.
/// - `State` has no meaning for command-line programs (no console windows on the Mac); with `State=Hide` (default) a
///   still running program is killed when the skin is refreshed or unloaded, as the manual says. Each run is its own
///   process group, so Close / Kill / Timeout reach the programs a shell command started too. Close = SIGTERM,
///   Kill = SIGKILL. `Timeout` closes (or, with State=Hide, kills) the program and finishes the run with the output
///   received so far — FinishAction runs "even if the program does not actually terminate"; so does Close when the
///   program is still running `closeGrace` (1 s) later. Such programs are still killed on unload with State=Hide.
/// - Output is decoded as UTF-8 (Windows-1252 when it is not valid UTF-8): Mac programs write UTF-8 whatever
///   `OutputType` says. `OutputFile` is written in the `OutputType` encoding: UTF16 (default) = UTF-16 LE with BOM,
///   UTF8 = UTF-8 without BOM, ANSI = Windows-1252.
/// - Judgment: when a command cannot start (103) the FinishAction still runs, right after the current action, so a
///   skin waiting for it moves on — but not when the previous start of the same measure also failed less than one
///   second earlier (a FinishAction that runs the command again would otherwise loop).
public final class RunCommandMeasure: Measure, PluginLifecycle {
    private var program = ""
    private var parameter = ""
    private var startInFolder = ""
    private var outputFile = ""
    private var outputType = "utf16"
    private var hidden = true
    private var timeout = -1.0
    private var finishAction = ""

    private var state = -1.0
    private var output = ""
    private var job: RunCommandJob?
    private var runGeneration = 0
    private var closed = false
    private var lastStartFailure: TimeInterval?
    private var reported: Set<String> = []
    /// The output of a finished program is being decoded / saved (`finish`).
    private var finishing = false
    /// Programs the measure no longer waits for (stopped by Timeout or Close but still running); with State=Hide they
    /// are killed when the skin is unloaded, like the running one.
    private var detached: [RunCommandJob] = []
    /// Timeouts and Close grace periods waiting on the skin's executor; cancelled when the skin is unloaded.
    private var waits: [SkinScheduledWork] = []

    /// Maximum bytes of output kept.
    static let maxOutput = 16 * 1024 * 1024
    /// How long a program may take to end after Close before the run finishes without it (seconds; tests shorten it).
    static var closeGrace: TimeInterval = 1

    public var isRunning: Bool { job != nil }

    override var tracksValueRange: Bool { true }

    public required init(name: String, section: IniSection, skin: Skin, type: String) {
        super.init(name: name, section: section, skin: skin, type: type)
        rawString = ""
        value = -1
    }

    deinit {
        waits.forEach { $0.cancel() }
        guard hidden else { return }
        job?.signal(SIGKILL)
        detached.forEach { $0.signal(SIGKILL) }
    }

    public func skinWillClose() {
        closed = true
        if hidden {
            job?.signal(SIGKILL)
            detached.forEach { $0.signal(SIGKILL) }
        }
        job = nil
        detached = []
        waits.forEach { $0.cancel() }
        waits = []
    }

    /// Runs `work` on the skin's executor `seconds` from now, unless the skin is unloaded first.
    private func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) {
        waits.removeAll { !$0.isPending }
        waits.append(skin.executor.async(after: seconds, work))
    }

    /// Programs still running (the current one and detached ones); tests.
    var runningJobCount: Int { (job == nil ? 0 : 1) + detached.count }

    public override func readMeasureOptions() {
        program = string("Program").trimmingCharacters(in: .whitespaces)
        parameter = string("Parameter").trimmingCharacters(in: .whitespaces)
        startInFolder = string("StartInFolder").trimmingCharacters(in: .whitespaces)
        outputFile = string("OutputFile").trimmingCharacters(in: .whitespaces)
        outputType = string("OutputType", "UTF16").trimmingCharacters(in: .whitespaces).lowercased()
        hidden = string("State", "Hide").trimmingCharacters(in: .whitespaces).lowercased() == "hide"
        timeout = double("Timeout", -1)
        finishAction = actionOption("FinishAction")
    }

    public override func computeValue() -> Double {
        rawString = output
        return state
    }

    public override func execute(command: String) {
        switch command.trimmingCharacters(in: .whitespaces).lowercased() {
        case "run": run()
        case "close": terminate(SIGTERM)
        case "kill": terminate(SIGKILL)
        default:
            skin.log("RunCommand [\(name)]: unknown command \"\(command)\"", level: .warning)
            setState(100)
        }
    }

    private func setState(_ s: Double) {
        state = s
        publishAsyncResult(number: s, string: output)
    }

    // MARK: Run

    private func run() {
        guard !closed else { return }
        if job != nil {
            setState(101)
            return
        }
        if needsOptionRead { readOptionsIfNeeded() }
        let line: String
        switch RunCommandTranslator.shellCommand(program: program, parameter: parameter) {
        case .success(let translated):
            line = translated
        case .failure(let reason):
            report("start:\(reason)", "RunCommand [\(name)]: cannot run on macOS: \(reason)")
            startFailed()
            return
        }
        let folder = startInFolder.isEmpty ? skin.directory.path : PluginPaths.resolve(startInFolder, skin: skin)
        var isDirectory: ObjCBool = false
        let directory = FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue
            ? folder : skin.directory.path
        let newJob: RunCommandJob
        do {
            newJob = try RunCommandJob.start(shellCommand: line, directory: directory,
                                             maxOutput: RunCommandMeasure.maxOutput)
        } catch RunCommandJob.StartError.pipe {
            output = ""
            setState(106)
            return
        } catch {
            report("spawn", "RunCommand [\(name)]: cannot start /bin/sh: \(error)")
            startFailed()
            return
        }
        lastStartFailure = nil
        runGeneration += 1
        let generation = runGeneration
        job = newJob
        output = ""
        setState(0)
        let jobID = ObjectIdentifier(newJob)
        let hop = skin.hop()
        newJob.onExit = { [weak self] in
            hop.post { self?.jobExited(jobID, generation: generation) }
        }
        newJob.resume()
        if timeout > 0 {
            let seconds = min(timeout, 86_400_000) / 1000
            schedule(after: seconds) { [weak self] in
                guard let self, self.runGeneration == generation, !self.finishing, let job = self.job else { return }
                job.signal(self.hidden ? SIGKILL : SIGTERM)
                self.detach(job)
                self.finish(generation: generation, timedOut: true)
            }
        }
    }

    private func jobExited(_ id: ObjectIdentifier, generation: Int) {
        detached.removeAll { ObjectIdentifier($0) == id }
        finish(generation: generation, timedOut: false)
    }

    /// The run finishes without waiting for `job` any longer; a hidden one is still killed on unload.
    private func detach(_ job: RunCommandJob) {
        if hidden && !detached.contains(where: { $0 === job }) { detached.append(job) }
    }

    /// Error 103; FinishAction after the current action unless the last start failed less than a second ago.
    private func startFailed() {
        output = ""
        setState(103)
        let now = ProcessInfo.processInfo.systemUptime
        let repeated = lastStartFailure.map { now - $0 < 1 } ?? false
        lastStartFailure = now
        guard !repeated, !finishAction.isEmpty else { return }
        runGeneration += 1
        let generation = runGeneration
        skin.async { [weak self] in
            guard let self, !self.closed, self.runGeneration == generation, self.job == nil else { return }
            self.skin.execute(self.finishAction, from: self)
        }
    }

    /// Ends the run: the output is decoded and OutputFile written on a background queue (up to 16 MB), then the value,
    /// string and FinishAction follow on the skin's executor — so a FinishAction that reads OutputFile finds it
    /// written. Until then the run counts as running (Run → 101).
    private func finish(generation: Int, timedOut: Bool) {
        guard generation == runGeneration, let job, !finishing else { return }
        guard !closed else {
            self.job = nil
            return
        }
        if timedOut { skin.log("RunCommand [\(name)]: Timeout reached; the program was stopped", level: .notice) }
        finishing = true
        let data = job.outputSnapshot()
        let path = outputFile.isEmpty ? nil : PluginPaths.resolve(outputFile, skin: skin)
        let type = outputType
        let hop = skin.hop()
        PluginIO.queue.async { [weak self] in
            let text = RunCommandMeasure.decode(data)
            var failure: String?
            if let path {
                do {
                    let directory = (path as NSString).deletingLastPathComponent
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    try RunCommandMeasure.encode(text, type: type).write(to: URL(fileURLWithPath: path), options: .atomic)
                } catch {
                    failure = "cannot save \(path): \(error.localizedDescription)"
                }
            }
            hop.post {
                guard let self else { return }
                self.finishing = false
                guard self.runGeneration == generation, self.job === job else { return }
                self.job = nil
                guard !self.closed else { return }
                if let failure { self.report("file", "RunCommand [\(self.name)]: \(failure)") }
                self.output = text
                self.setState(failure == nil ? 1 : 104)
                if !self.finishAction.isEmpty { self.skin.execute(self.finishAction, from: self) }
            }
        }
    }

    private func terminate(_ sig: Int32) {
        guard let job else {
            setState(102)
            return
        }
        guard job.signal(sig) else {
            setState(105)
            return
        }
        guard sig == SIGTERM else { return }
        // Manual: "Any FinishAction will run even if the program does not actually terminate". A program that ignores
        // the request is no longer waited for after a moment: the run finishes with the output so far.
        let generation = runGeneration
        schedule(after: RunCommandMeasure.closeGrace) { [weak self] in
            guard let self, self.runGeneration == generation, !self.finishing, let job = self.job else { return }
            self.detach(job)
            self.finish(generation: generation, timedOut: false)
        }
    }

    // MARK: Text

    static func decode(_ data: Data) -> String {
        if data.isEmpty { return "" }
        if data.count >= 2, (data[0] == 0xFF && data[1] == 0xFE) || (data[0] == 0xFE && data[1] == 0xFF) {
            return String(data: data, encoding: .utf16) ?? ""
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    static func encode(_ text: String, type: String) -> Data {
        switch type {
        case "utf8":
            return Data(text.utf8)
        case "ansi":
            return text.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data(text.utf8)
        default:
            var data = Data([0xFF, 0xFE])
            data.append(text.data(using: .utf16LittleEndian) ?? Data())
            return data
        }
    }

    private func report(_ key: String, _ message: String) {
        guard reported.insert(key).inserted else { return }
        skin.log(message, level: .warning)
    }
}

// MARK: - Process

/// A `/bin/sh -c` child in its own process group, with stdout / stderr read on a background queue.
final class RunCommandJob: @unchecked Sendable {
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

    static func start(shellCommand: String, directory: String, maxOutput: Int) throws -> RunCommandJob {
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
            environment["LANG"] = RunCommandJob.defaultLanguage
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

    /// `ll_CC.UTF-8` of the user's locale when macOS has it (what Terminal sets), else `en_US.UTF-8`.
    static let defaultLanguage: String = {
        let identifier = Locale.current.identifier.split(separator: "@").first.map(String.init) ?? ""
        let candidate = identifier + ".UTF-8"
        if !identifier.isEmpty, FileManager.default.fileExists(atPath: "/usr/share/locale/" + candidate) { return candidate }
        return "en_US.UTF-8"
    }()

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

// MARK: - Translation

/// Turns RunCommand's `Program` / `Parameter` into a `/bin/sh -c` command line, or explains why it cannot run on the
/// Mac. Only clearly equivalent cases are translated; anything Windows-specific fails before running.
enum RunCommandTranslator {
    /// cmd.exe built-ins and Windows tools that must not reach /bin/sh (some exist on the Mac with other meanings).
    static let windowsCommands: Set<String> = [
        "assoc", "attrib", "bcdedit", "bitsadmin", "cacls", "call", "certutil", "chcp", "chkdsk", "choice", "cipher",
        "clip", "cls", "cmd", "color", "comp", "compact", "control", "convert", "copy", "cscript", "date", "del",
        "dir", "diskpart", "doskey", "driverquery", "endlocal", "erase", "fc", "find", "findstr", "for", "format",
        "ftype", "getmac", "goto", "gpresult", "icacls", "if", "ipconfig", "label", "logman", "md", "mklink", "mode",
        "more", "move", "msg", "msiexec", "mshta", "net", "netsh", "netstat", "notepad", "path", "pause", "popd",
        "powercfg", "powershell", "print", "prompt", "pushd", "pwsh", "rd", "reg", "regedit", "ren", "rename",
        "replace", "rmdir", "robocopy", "route", "runas", "rundll32", "sc", "schtasks", "set", "setlocal", "setx",
        "shutdown", "sort", "subst", "systeminfo", "takeown", "taskkill", "tasklist", "taskmgr", "time", "timeout",
        "title", "tree", "type", "typeperf", "ver", "vol", "wevtutil", "where", "wmic", "wscript", "xcopy", "calc",
        "mspaint", "write", "winget", "choco", "wsl", "del", "tracert", "pathping", "nbtstat", "arp", "chdir",
    ]
    static let windowsExtensions: Set<String> = ["exe", "bat", "cmd", "com", "ps1", "vbs", "vbe", "js", "wsf", "msc",
                                                 "msi", "lnk", "cpl", "scr", "hta", "reg"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish"]

    enum Failure: Error, Equatable, CustomStringConvertible {
        case windowsProgram(String)
        case windowsSyntax(String)

        var description: String {
            switch self {
            case .windowsProgram(let p): return "\"\(p)\" is a Windows program"
            case .windowsSyntax(let s): return "Windows-only command syntax (\(s))"
            }
        }
    }

    static func shellCommand(program rawProgram: String, parameter: String) -> Result<String, Failure> {
        let program = unquote(rawProgram.trimmingCharacters(in: .whitespaces))
        // Windows builds one command line from "Program Parameter", so Program may carry arguments of its own.
        let (path, rest) = programWord(program)
        let base = (path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent.lowercased()
        // Empty, `%ComSpec% /U /C`, `cmd.exe /C`, `C:\Windows\System32\cmd.exe /C` → the command line is the parameter.
        if program.isEmpty || path.lowercased() == "%comspec%" || base == "cmd" || base == "cmd.exe" {
            // Flags such as /U /C /Q /D /S; anything after them is part of the command.
            var flags = rest
            while flags.hasPrefix("/"), flags.count >= 2 {
                let flag = flags.prefix(2).lowercased()
                guard ["/u", "/c", "/k", "/q", "/d", "/s", "/a"].contains(flag) else { break }
                flags = String(flags.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            var commandLine = (flags.isEmpty ? parameter : flags + " " + parameter).trimmingCharacters(in: .whitespaces)
            // A Parameter that repeats the flags (`/C dir`) is accepted too.
            while commandLine.count >= 2, commandLine.hasPrefix("/"),
                  ["/u", "/c", "/k", "/q", "/d", "/s"].contains(commandLine.prefix(2).lowercased()),
                  commandLine.count == 2 || commandLine.dropFirst(2).first == " " {
                commandLine = String(commandLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            return translateCommandLine(commandLine)
        }
        // A Mac program: run `program [its arguments] parameter` through the shell.
        let ext = (base as NSString).pathExtension
        let arguments = [rest, parameter].filter { !$0.isEmpty }.joined(separator: " ")
        let stem = ext == "exe" ? (base as NSString).deletingPathExtension : base
        let bareName = !path.contains("/") && !path.contains("\\")
        // Programs with a translation (a bare macOS `ping` without `-c` would never stop, like Windows' `ping -t`).
        if bareName && (stem == "start" || stem == "explorer" || stem == "ping") {
            return translateCommandLine(stem + (arguments.isEmpty ? "" : " " + arguments))
        }
        if windowsExtensions.contains(ext) || hasDrive(path) || path.hasPrefix("\\\\") {
            return .failure(.windowsProgram(path))
        }
        if bareName {
            if sharedCommands.contains(base) {
                if looksLikeWindows(base, [path] + splitWords(arguments)) { return .failure(.windowsProgram(path)) }
            } else if windowsCommands.contains(base) {
                return .failure(.windowsProgram(path))
            }
        }
        var word = path
        if path.contains(where: { $0 == " " || $0 == "\t" }) {
            word = path.hasPrefix("~/") ? "~/" + shellQuote(String(path.dropFirst(2))) : shellQuote(path)
        }
        let line = arguments.isEmpty ? word : word + " " + arguments
        if shells.contains(base) { return .success(line) }
        if case .failure(let f) = checkSyntax(arguments) { return .failure(f) }
        return .success(line)
    }

    /// Splits Program into the program and the arguments written after it: a quoted first word; else the longest
    /// prefix that names an existing file (a Mac path may contain spaces: `/Applications/My Tool/tool --x`); else the
    /// first word (what Windows tries first as well).
    static func programWord(_ program: String) -> (path: String, rest: String) {
        let p = program.trimmingCharacters(in: .whitespaces)
        guard let first = p.first else { return ("", "") }
        if first == "\"" || first == "'", let close = p.dropFirst().firstIndex(of: first) {
            let inner = String(p[p.index(after: p.startIndex)..<close])
            return (inner, String(p[p.index(after: close)...]).trimmingCharacters(in: .whitespaces))
        }
        let blanks = p.indices.filter { p[$0] == " " || p[$0] == "\t" }
        guard !blanks.isEmpty else { return (p, "") }
        if p.contains("/") {
            for end in [p.endIndex] + blanks.reversed() {
                let candidate = String(p[..<end])
                let expanded = (candidate as NSString).expandingTildeInPath
                if expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded) {
                    return (candidate, String(p[end...]).trimmingCharacters(in: .whitespaces))
                }
            }
        }
        let firstBlank = blanks[0]
        return (String(p[..<firstBlank]), String(p[firstBlank...]).trimmingCharacters(in: .whitespaces))
    }

    /// cmd.exe built-ins / Windows tools whose names are also POSIX commands or shell keywords on the Mac: they run
    /// through the shell unless the command shows Windows syntax (`looksLikeWindows`).
    static let sharedCommands: Set<String> = ["find", "sort", "more", "date", "time", "set", "if", "for", "rmdir",
                                              "netstat", "route", "arp", "ipconfig", "type"]

    /// Windows usage of a `sharedCommands` command (`words` = the command and its arguments).
    static func looksLikeWindows(_ command: String, _ words: [String]) -> Bool {
        let arguments = words.dropFirst()
        if arguments.contains(where: isWindowsSwitch) { return true }
        switch command {
        case "if":
            // sh: `if …; then …; fi`; cmd.exe: `if exist x …`, `if errorlevel 1 …`, `if "%a%"=="b" …`.
            return words.joined(separator: " ").range(of: "(^|[\\s;])then($|[\\s;])", options: .regularExpression) == nil
        case "for":
            // cmd.exe loops use `%x` / `%%x` variables.
            return arguments.first?.hasPrefix("%") == true
        case "ipconfig":
            // Windows prints the network configuration, the Mac's ipconfig only its usage.
            return arguments.isEmpty
        default:
            return false
        }
    }

    /// `/s`, `/Q`, `/?`, `/all`, `/a:h`, `/+3`: switches of cmd.exe tools. A word such as `/tmp` or `/Users` is a Mac
    /// path when it exists (the startup volume has no one- or two-letter folders at its root).
    static func isWindowsSwitch(_ word: String) -> Bool {
        let w = unquote(word)
        guard w.hasPrefix("/"), w.count >= 2 else { return false }
        if w.range(of: "^/(\\?|[A-Za-z][A-Za-z0-9]?|[A-Za-z]+:\\S*|\\+[0-9]+)$", options: .regularExpression) != nil {
            return true
        }
        return w.range(of: "^/[A-Za-z][A-Za-z0-9]*$", options: .regularExpression) != nil
            && !FileManager.default.fileExists(atPath: w)
    }

    /// A cmd.exe command line → sh.
    static func translateCommandLine(_ line: String) -> Result<String, Failure> {
        if line.isEmpty { return .success("") }
        if case .failure(let f) = checkSyntax(line) { return .failure(f) }
        var out: [String] = []
        for segment in split(line) {
            if segment.isSeparator {
                out.append(segment.text)
                continue
            }
            switch translateSegment(segment.text) {
            case .success(let s): out.append(s)
            case .failure(let f): return .failure(f)
            }
        }
        return .success(out.joined(separator: " "))
    }

    private static func translateSegment(_ text: String) -> Result<String, Failure> {
        let words = splitWords(text)
        guard let first = words.first else { return .success(text) }
        var command = unquote(first).replacingOccurrences(of: "\\", with: "/")
        command = (command as NSString).lastPathComponent.lowercased()
        let ext = (command as NSString).pathExtension
        if ext == "exe" { command = (command as NSString).deletingPathExtension }
        switch command {
        case "start":
            // start ["title"] target [args] → open target
            var rest = Array(words.dropFirst())
            while let w = rest.first, w.hasPrefix("/") { rest.removeFirst() }   // /min, /b, /wait…
            if rest.count >= 2, rest[0].hasPrefix("\"") { rest.removeFirst() }  // window title
            guard let target = rest.first else { return .failure(.windowsSyntax("start without a target")) }
            return openCommand(unquote(target))
        case "explorer":
            guard words.count >= 2 else { return .success("/usr/bin/open ~") }
            return openCommand(unquote(words[1]))
        case "ping":
            return translatePing(Array(words.dropFirst()))
        default:
            break
        }
        if sharedCommands.contains(command) && ext.isEmpty {
            if looksLikeWindows(command, words) { return .failure(.windowsProgram(unquote(first))) }
            // `type file…` prints files (sh's `type` describes commands): the same as `cat`.
            if command == "type", words.count > 1, !words.dropFirst().contains(where: { $0.hasPrefix("-") }) {
                let files = words.dropFirst().map { $0.replacingOccurrences(of: "\\", with: "/") }
                return .success(redirectNul((["cat"] + files).joined(separator: " ")))
            }
            return .success(redirectNul(text))
        }
        if windowsCommands.contains(command) || windowsExtensions.contains(ext) {
            return .failure(.windowsProgram(unquote(first)))
        }
        return .success(redirectNul(text))
    }

    /// cmd.exe's `NUL` device in redirections (`2>nul`, `> NUL`) → `/dev/null`.
    static func redirectNul(_ text: String) -> String {
        text.replacingOccurrences(of: "([0-9]?>>?)\\s*nul(?=$|[\\s&|;)])", with: "$1/dev/null",
                                  options: [.regularExpression, .caseInsensitive])
    }

    private static func openCommand(_ target: String) -> Result<String, Failure> {
        if hasDrive(target) || target.hasPrefix("\\\\") { return .failure(.windowsSyntax(target)) }
        let lower = target.lowercased()
        if lower.hasSuffix(".exe") || lower.hasSuffix(".bat") || lower.hasSuffix(".cmd") {
            return .failure(.windowsProgram(target))
        }
        return .success("/usr/bin/open " + shellQuote(target))
    }

    /// Windows ping → macOS ping: `-n N` → `-c N` (Windows sends 4 by default, macOS pings forever), `-w ms` → `-W ms`,
    /// `-l size` → `-s size`, `-4` dropped. Other options (e.g. `-t`, ping until stopped) cannot be translated.
    /// A Mac ping line (it has `-c count`, which Windows' ping does not know) runs unchanged.
    private static func translatePing(_ args: [String]) -> Result<String, Failure> {
        if args.contains("-c") {
            return .success((["/sbin/ping"] + args).joined(separator: " "))
        }
        var out = ["/sbin/ping"]
        var count = "4"
        var i = 0
        var host: String?
        while i < args.count {
            let a = args[i].lowercased()
            func next() -> String? { i + 1 < args.count ? args[i + 1] : nil }
            switch a {
            case "-n", "/n":
                guard let v = next(), Int(v) != nil else { return .failure(.windowsSyntax("ping -n")) }
                count = v; i += 2
            case "-w", "/w":
                guard let v = next(), Int(v) != nil else { return .failure(.windowsSyntax("ping -w")) }
                out += ["-W", v]; i += 2
            case "-l", "/l":
                guard let v = next(), Int(v) != nil else { return .failure(.windowsSyntax("ping -l")) }
                out += ["-s", v]; i += 2
            case "-4", "/4":
                i += 1
            default:
                if a.hasPrefix("-") || a.hasPrefix("/") { return .failure(.windowsSyntax("ping \(args[i])")) }
                host = unquote(args[i]); i += 1
            }
        }
        guard let host else { return .failure(.windowsSyntax("ping without a host")) }
        return .success((out + ["-c", count, shellQuote(host)]).joined(separator: " "))
    }

    /// Variables cmd.exe expands (`%DATE%`, `%UserProfile%`…), lowercased. Any all-capitals `%NAME%` counts as well.
    static let windowsVariables: Set<String> = [
        "date", "time", "random", "cd", "errorlevel", "comspec", "systemroot", "windir", "userprofile", "username",
        "userdomain", "computername", "appdata", "localappdata", "temp", "tmp", "programfiles", "programfiles(x86)",
        "programw6432", "programdata", "homedrive", "homepath", "path", "pathext", "public", "os",
        "processor_architecture", "processor_identifier", "number_of_processors", "allusersprofile", "systemdrive",
        "cmdcmdline", "onedrive", "logonserver", "sessionname", "commonprogramfiles",
    ]

    private static let variablePattern = try? NSRegularExpression(pattern: "%([A-Za-z_][A-Za-z0-9_()]*)(:[^%]*)?%")

    /// Windows-only syntax anywhere in the line: `%VARIABLE%`, drive-letter or UNC paths. `date +%Y%m%d`-style format
    /// strings are not variables: a name must have two or more characters and be a known cmd.exe variable or all
    /// capitals.
    static func checkSyntax(_ line: String) -> Result<Void, Failure> {
        let ns = line as NSString
        for match in variablePattern?.matches(in: line, range: NSRange(location: 0, length: ns.length)) ?? [] {
            let name = ns.substring(with: match.range(at: 1))
            let capitals = name.contains { $0.isLetter } && name == name.uppercased()
            if name.count >= 2 && (capitals || windowsVariables.contains(name.lowercased())) {
                return .failure(.windowsSyntax(ns.substring(with: match.range)))
            }
        }
        if let range = line.range(of: "(^|[\\s\"'=])[A-Za-z]:\\\\", options: .regularExpression) {
            return .failure(.windowsSyntax(String(line[range]).trimmingCharacters(in: .whitespaces)))
        }
        if line.range(of: "(^|[\\s\"'])\\\\\\\\[A-Za-z0-9]", options: .regularExpression) != nil {
            return .failure(.windowsSyntax("UNC path"))
        }
        return .success(())
    }

    private static func hasDrive(_ s: String) -> Bool {
        let u = Array(unquote(s).utf8.prefix(3))
        return u.count >= 2 && u[1] == UInt8(ascii: ":") && (u[0] | 0x20) >= 0x61 && (u[0] | 0x20) <= 0x7A
    }

    /// Splits at `&&`, `||`, `&`, `|` (cmd.exe's command separators; the same in sh) outside quotes, the way sh reads
    /// them: `"…"` and `'…'` quote, `\x` escapes a character outside single quotes, and `&` in a redirection
    /// (`2>&1`, `>&2`, `<&0`, `&>file`) is not a separator.
    static func split(_ line: String) -> [(text: String, isSeparator: Bool)] {
        var parts: [(String, Bool)] = []
        var current = ""
        var quote: Character?
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                current.append(c)
                if c == q {
                    quote = nil
                } else if c == "\\", q == "\"", i + 1 < chars.count {
                    current.append(chars[i + 1])
                    i += 1
                }
                i += 1
                continue
            }
            if c == "\"" || c == "'" {
                quote = c
            } else if c == "\\", i + 1 < chars.count {
                current.append(c)
                current.append(chars[i + 1])
                i += 2
                continue
            } else if c == "&" || c == "|" {
                let doubled = i + 1 < chars.count && chars[i + 1] == c
                let redirection = c == "&" && !doubled
                    && (current.last == ">" || current.last == "<" || (i + 1 < chars.count && chars[i + 1] == ">"))
                if !redirection {
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { parts.append((trimmed, false)) }
                    current = ""
                    // A single `&` in cmd.exe runs the next command after the first: `;` in sh.
                    parts.append((doubled ? String([c, c]) : (c == "&" ? ";" : "|"), true))
                    i += doubled ? 2 : 1
                    continue
                }
            }
            current.append(c)
            i += 1
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { parts.append((trimmed, false)) }
        return parts.map { (text: $0.0, isSeparator: $0.1) }
    }

    /// Words separated by blanks; double-quoted words keep their quotes.
    static func splitWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inQuotes = false
        for c in text {
            if c == "\"" { inQuotes.toggle() }
            if !inQuotes, c == " " || c == "\t" {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    static func unquote(_ s: String) -> String {
        var t = s
        while t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") { t = String(t.dropFirst().dropLast()) }
        return t
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
