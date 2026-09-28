import Foundation

/// Side effects that leave the Mac alone (see SideEffects.swift): each effect is kept as a typed `SideEffect`
/// (`records`, `onRecord`), no program is started, no signal sent, and the files the skin writes go to a copy of the
/// skin tree (`files`, a `SkinFileSandbox` with the Skins and settings folders as its roots), where the skin reads them
/// back — its scripts through the sandbox, its images and downloads by the paths it is given, and a skin loaded again
/// through `sourceText(for:)` (set it as the skin's `sourceProvider`), so that a reload after `!WriteKeyValue` sees the
/// written value. The effects the app carries out (audio, players, keys) are recorded and not done.
///
/// A program "started" here exits as soon as it is resumed, with the output `programOutput` gives it (none by
/// default). A helper program's completion gets status 0 at once.
///
/// Thread-safe. `reset()` forgets the copies (a new instance starts from the real files); the records stay until
/// `clearRecords()`.
public final class RecordingSideEffects: SideEffects, SourceProvider {
    /// The copy of the skin tree the skin's writes go to.
    public let files: SkinFileSandbox
    /// Told of each effect recorded, on the thread that caused it.
    public var onRecord: ((SideEffect) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return recordHandler }
        set { lock.lock(); recordHandler = newValue; lock.unlock() }
    }
    /// What a started program writes to its standard output, by command line (tests, and scripted runs later).
    public var programOutput: (String) -> Data {
        get { lock.lock(); defer { lock.unlock() }; return outputSource }
        set { lock.lock(); outputSource = newValue; lock.unlock() }
    }
    /// How many records are kept (the last ones); nil keeps every one.
    public var limit: Int? {
        get { lock.lock(); defer { lock.unlock() }; return recordLimit }
        set { lock.lock(); recordLimit = newValue; lock.unlock() }
    }

    private let lock = NSLock()
    private var list: [SideEffect] = []
    private var recordHandler: ((SideEffect) -> Void)?
    private var outputSource: (String) -> Data = { _ in Data() }
    private var recordLimit: Int?

    /// `skinsDirectory` and `settingsDirectory`: the trees whose files keep their place in the copy (others are copied
    /// by name). `directory`: where the copies go (a new temporary folder by default, removed with this object).
    public init(skinsDirectory: URL? = nil, settingsDirectory: URL? = nil, directory: URL? = nil) {
        var roots: [(name: String, url: URL)] = []
        if let skinsDirectory { roots.append(("Skins", skinsDirectory)) }
        if let settingsDirectory { roots.append(("Settings", settingsDirectory)) }
        files = SkinFileSandbox(directory: directory, roots: roots)
        files.onRecord = { [weak self] change in
            switch change.operation {
            case "remove": self?.record(.removeFile(path: change.path))
            case "rename": self?.record(.renameFile(from: change.path, to: change.target ?? ""))
            default: self?.record(.writeFile(path: change.path))
            }
        }
    }

    /// The effects recorded, oldest first.
    public var records: [SideEffect] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }

    public func clearRecords() {
        lock.lock()
        list = []
        lock.unlock()
        files.clearRecords()
    }

    /// Forgets the copies: the real files are read again.
    public func reset() { files.reset() }

    /// Keeps `effect` (also what the recording host asks of it).
    public func record(_ effect: SideEffect) {
        lock.lock()
        list.append(effect)
        if let recordLimit, list.count > recordLimit { list.removeFirst(list.count - recordLimit) }
        let handler = recordHandler
        lock.unlock()
        handler?(effect)
    }

    // MARK: SideEffects

    public var isLive: Bool { false }
    public var fileSandbox: SkinFileSandbox? { files }

    public func startShellCommand(_ command: String, directory: String, maxOutput: Int,
                                  locale: Locale) throws -> SkinProcess {
        record(.launch(executable: "/bin/sh", arguments: ["-c", command], directory: directory))
        let output = programOutput(command)
        return RecordedProcess(command: command, output: Data(output.prefix(maxOutput)), recorder: self)
    }

    public func launch(_ executable: String, _ arguments: [String], completion: ((Int32) -> Void)?) {
        record(.launch(executable: executable, arguments: arguments, directory: nil))
        completion?(0)
    }

    public func destination(forWriting url: URL) -> URL {
        files.url(forWriting: url)
    }

    public func temporaryDestination(for url: URL) -> URL {
        files.directory.appendingPathComponent("Temporary", isDirectory: true).appendingPathComponent(url.lastPathComponent)
    }

    public func writeFile(_ data: Data, to url: URL, makingFolder: Bool) throws {
        // Only ever into this recording's own folder: a path from elsewhere is sent to its copy first.
        let target = files.contains(url.path) ? url : files.url(forWriting: url)
        try LiveSideEffects.write(data, to: target, makingFolder: makingFolder || target != url)
    }

    public func removeTemporaryFile(atPath path: String) {
        guard files.contains(path) else { return }
        LiveSideEffects.shared.removeTemporaryFile(atPath: path)
    }

    public func writeKeyValue(_ value: String, key: String, section: String, fileURL: URL) throws {
        // "The file must exist": the copy if the skin changed it here, else the file itself.
        guard FileManager.default.fileExists(atPath: files.path(for: fileURL.path, access: .read)) else {
            throw IniWriterError.fileNotFound(fileURL.path)
        }
        let copy = files.path(for: fileURL.path, access: .update, recording: false)
        try LiveSideEffects.shared.writeKeyValue(value, key: key, section: section, fileURL: URL(fileURLWithPath: copy))
        record(.writeKeyValue(file: fileURL.path, section: section, key: key, value: value))
    }

    public func perform(_ effect: SideEffect, live: () -> Void) { record(effect) }

    // MARK: SourceProvider

    /// The text of the copy of `url` when the skin wrote one here (a reload sees what it wrote), else nil (the file on
    /// disk).
    public func sourceText(for url: URL) -> String? {
        guard let copy = files.copy(of: url.path) else { return nil }
        return try? TextDecoding.readFile(at: URL(fileURLWithPath: copy))
    }
}

/// A program a recording "started": it runs nothing, exits as soon as it is resumed with the output it was given, and
/// records each signal sent to it.
final class RecordedProcess: SkinProcess, @unchecked Sendable {
    private let command: String
    private let output: Data
    private weak var recorder: RecordingSideEffects?
    private let lock = NSLock()
    private var exitHandler: (() -> Void)?

    init(command: String, output: Data, recorder: RecordingSideEffects) {
        self.command = command
        self.output = output
        self.recorder = recorder
    }

    var onExit: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return exitHandler }
        set { lock.lock(); exitHandler = newValue; lock.unlock() }
    }

    func resume() {
        lock.lock()
        let handler = exitHandler
        exitHandler = nil
        lock.unlock()
        handler?()
    }

    @discardableResult
    func signal(_ signal: Int32) -> Bool {
        recorder?.record(.signal(signal, command: command))
        return true
    }

    func outputSnapshot() -> Data { output }
}

// MARK: - Host

/// A host for a sandboxed run: what the skin asks of its host that reaches outside it — the bangs the engine leaves to
/// the host (the window, the app, skin groups, other skins' configs), bangs for other skins, web pages, files and
/// programs to open — is recorded in `effects` (`SideEffect.hostBang`, `.forwardBang`, `.open`) and not done. Drawing,
/// the log, text and image measurement and the environment are the `inner` host's; without one nothing is drawn, the
/// log is kept (`log`), text is measured roughly (0.6 of the font size per character, 1.2 per line) and the environment
/// is the default one with a fixed locale and languages (`fixedEnvironment`), never the Mac's.
public final class RecordingSkinHost: SkinHost {
    public let effects: RecordingSideEffects
    public let inner: SkinHost?
    /// The skin's log when there is no inner host.
    public private(set) var log: [(level: SkinLogLevel, message: String)] = []
    private let lock = NSLock()

    public init(effects: RecordingSideEffects, inner: SkinHost? = nil) {
        self.effects = effects
        self.inner = inner
    }

    public func skinNeedsDisplay(_ skin: Skin) { inner?.skinNeedsDisplay(skin) }

    public func skin(_ skin: Skin, handle bang: Bang) -> Bool {
        effects.record(.hostBang(StudioActionPolicy.text(of: bang)))
        return true
    }

    public func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {
        effects.record(.forwardBang(StudioActionPolicy.text(of: bang), config: config))
    }

    public func skin(_ skin: Skin, execute target: String, arguments: [String]) {
        effects.record(.open(target: target, arguments: arguments))
    }

    public func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {
        if let inner {
            inner.skin(skin, log: message, level: level)
            return
        }
        lock.lock()
        if log.count < 1000 { log.append((level, message)) }
        lock.unlock()
    }

    public func textSize(_ text: String, style: TextStyle, wrapWidth: Double?,
                         for skin: Skin) -> (width: Double, height: Double) {
        if let inner { return inner.textSize(text, style: style, wrapWidth: wrapWidth, for: skin) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let widest = lines.map { Double($0.count) }.max() ?? 0
        return (widest * style.fontSize * 0.6, Double(max(lines.count, 1)) * style.fontSize * 1.2)
    }

    public func imageSize(atPath path: String) -> (width: Double, height: Double)? {
        inner?.imageSize(atPath: path)
    }

    public func environment(for skin: Skin) -> SkinEnvironment {
        inner?.environment(for: skin) ?? RecordingSkinHost.fixedEnvironment
    }

    /// The environment without an inner host: `SkinEnvironment`'s defaults (one 1920×1080 screen, the light
    /// appearance with macOS's blue), the en_US_POSIX locale and English — the same on every Mac.
    public static let fixedEnvironment = SkinEnvironment(locale: Locale(identifier: "en_US_POSIX"),
                                                          preferredLanguages: ["en"])

    public func skin(_ skin: Skin, fadeWindowFrom from: Int, to: Int) -> Bool {
        inner?.skin(skin, fadeWindowFrom: from, to: to) ?? false
    }

    public func skinOutsidePointerNeedsChanged(_ skin: Skin) { inner?.skinOutsidePointerNeedsChanged(skin) }

    public func skinWindowTakesPointer(_ skin: Skin) -> Bool { inner?.skinWindowTakesPointer(skin) ?? true }

    public func skinGlassRegionsChanged(_ skin: Skin, regions: [GlassRegion]) {
        inner?.skinGlassRegionsChanged(skin, regions: regions)
    }
}
