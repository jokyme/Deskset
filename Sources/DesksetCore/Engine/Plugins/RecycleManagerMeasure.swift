import Darwin
import Foundation

// Clean-room implementation from the public manual only: https://docs.rainmeter.net/manual/measures/recyclemanager/

/// `Measure=RecycleManager` (also `Plugin=RecycleManager`): the Recycle Bin, i.e. the user's Trash.
/// - `RecycleType=Count` (default): items in the Trash; `Size`: their total size in bytes.
/// - Commands: `OpenBin` (shows the Trash in Finder), `EmptyBin` (after confirmation), `EmptyBinSilent`.
///
/// Mac: the Trash is `~/.Trash` plus `.Trashes/<uid>` of the other internal volumes (external and network volumes
/// are left out: reading them makes macOS ask for access). macOS protects the Trash's contents: without Full Disk
/// Access an app can count its items (a directory entry count needs no permission) but cannot list them, so `Size`
/// is 0 until the user grants Deskset Full Disk Access (logged once with that hint, and shown as a compatibility note
/// that goes away once the size can be read). Emptying goes through Finder
/// (AppleScript), exactly like choosing Finder ▸ Empty Trash: `EmptyBin` first asks in a Finder dialog (Finder's own
/// warning is suppressed so there is exactly one), `EmptyBinSilent` asks nothing, and macOS asks once whether Deskset
/// may control Finder (Info.plist `NSAppleEventsUsageDescription`). The (undocumented) `Drives=` option of old skins is ignored: every volume
/// counts. Values are read on a background queue at each update; the measure shows the latest reading.
public final class RecycleManagerMeasure: Measure, PluginLifecycle {
    private var sizeMode = false
    private var closed = false
    private var reportedSize = false

    public func skinWillClose() { closed = true }

    override var tracksValueRange: Bool { true }

    public override func readMeasureOptions() {
        sizeMode = string("RecycleType", "Count").trimmingCharacters(in: .whitespaces).lowercased() == "size"
    }

    public override func computeValue() -> Double {
        let monitor = TrashMonitor.shared
        let includeSize = sizeMode
        // Background work of the skin's (a fake can stand in for it in virtual time): a reading of the shared monitor,
        // handed back through the skin's executor.
        let job = BackgroundJob<TrashMonitor.Status>(.trash, subject: TrashMonitor.homeTrash, start: { deliver in
            monitor.refresh(includeSize: includeSize) { deliver(monitor.latest) }
        }, scripted: TrashMonitor.Status.init(scripted:))
        skin.startBackground(job) { [weak self] status in self?.received(status) }
        // The latest reading, whoever asked for it; in virtual time only what came back through the executor.
        return value(of: skin.runsInVirtualTime ? (reading ?? TrashMonitor.Status()) : monitor.latest)
    }

    /// The first reading has been applied (tests check that it waits for the skin's executor).
    private(set) var hasReading = false
    /// The last reading that came back to this measure.
    private var reading: TrashMonitor.Status?

    private func received(_ status: TrashMonitor.Status) {
        guard !closed else { return }
        reading = status
        // The first reading is shown as soon as it arrives (skins often update this measure rarely).
        guard !hasReading else { return }
        hasReading = true
        publishAsyncResult(number: value(of: skin.runsInVirtualTime ? status : TrashMonitor.shared.latest), string: nil)
    }

    /// `--render --data`'s `trash`: from now on every reading of the Trash is this one (`.none`: an empty Trash) and
    /// nothing is read from the Mac; nil: the Mac's Trash again. Readings kept so far are forgotten. Main thread,
    /// before the skins that read it load.
    public static func useGivenTrash(_ given: SkinInputData.Given<SkinInputData.Trash>?) {
        TrashMonitor.fixture = given.map { given in
            guard let trash = given.value else { return TrashMonitor.Status(count: 0, size: 0) }
            return TrashMonitor.Status(count: trash.count, size: trash.size, sizeDenied: trash.size == nil)
        }
        TrashMonitor.shared.forget()
    }

    /// Compatibility note while the Trash's contents cannot be listed (Windows needs no permission for its size).
    public static let sizeNote = "RecycleManager: RecycleType=Size needs Full Disk Access, because macOS protects the "
        + "contents of the Trash. Allow Deskset in System Settings → Privacy & Security → Full Disk Access; until then "
        + "the size reads 0 (the item count works without it)."

    private func value(of status: TrashMonitor.Status) -> Double {
        guard sizeMode else { return Double(status.count) }
        if status.sizeDenied {
            if !reportedSize {
                reportedSize = true
                skin.log("RecycleManager [\(name)]: the Trash size needs Full Disk Access for Deskset (System Settings ▸ "
                         + "Privacy & Security ▸ Full Disk Access); showing 0", level: .notice)
            }
            skin.addIssue(RecycleManagerMeasure.sizeNote)
        } else if status.size != nil {
            // Readable now (access granted meanwhile): the note no longer applies.
            skin.removeIssue(RecycleManagerMeasure.sizeNote)
        }
        return status.size ?? 0
    }

    public override func execute(command: String) {
        guard !closed else { return }
        switch command.trimmingCharacters(in: .whitespaces).lowercased() {
        case "openbin":
            skin.sideEffects.launch("/usr/bin/open", [TrashMonitor.homeTrash], completion: nil)
        case "emptybin":
            skin.sideEffects.launch("/usr/bin/osascript", RecycleManagerMeasure.emptyScript(confirm: true),
                                    on: skin.executor) { _ in
                TrashMonitor.shared.refresh(includeSize: true, force: true)
            }
        case "emptybinsilent":
            skin.sideEffects.launch("/usr/bin/osascript", RecycleManagerMeasure.emptyScript(confirm: false),
                                    on: skin.executor) { _ in
                TrashMonitor.shared.refresh(includeSize: true, force: true)
            }
        default:
            super.execute(command: command)
        }
    }

    /// osascript arguments that empty the Trash through Finder, with exactly one confirmation dialog (ours) when
    /// `confirm` and none otherwise. Finder's own warning (its `warns before emptying` setting, on by default, which
    /// also applies to scripted emptying) is switched off just for the `empty` command and restored afterwards, even
    /// when emptying fails; without that, EmptyBin would ask twice and EmptyBinSilent would not be silent.
    static func emptyScript(confirm: Bool) -> [String] {
        var lines = ["tell application \"Finder\"", "if (count of items of trash) is 0 then return"]
        if confirm {
            lines += [
                "activate",
                "display dialog \"Are you sure you want to permanently erase the items in the Trash?\" & return & "
                    + "\"You can't undo this action.\" buttons {\"Cancel\", \"Empty Trash\"} default button "
                    + "\"Empty Trash\" cancel button \"Cancel\" with icon caution",
            ]
        }
        lines += [
            "set previousWarning to warns before emptying of trash",
            "set warns before emptying of trash to false",
            "try",
            "empty trash",
            "on error errorMessage number errorNumber",
            "set warns before emptying of trash to previousWarning",
            "error errorMessage number errorNumber",
            "end try",
            "set warns before emptying of trash to previousWarning",
            "end tell",
        ]
        return lines.flatMap { ["-e", $0] }
    }
}

/// The Trash's item count and size, read on a background queue and shared by all RecycleManager measures.
final class TrashMonitor: @unchecked Sendable {
    static let shared = TrashMonitor()
    static var homeTrash: String { NSHomeDirectory() + "/.Trash" }

    struct Status: Equatable {
        var count = 0
        /// nil while unknown.
        var size: Double?
        /// The contents cannot be listed (no Full Disk Access).
        var sizeDenied = false

        init(count: Int = 0, size: Double? = nil, sizeDenied: Bool = false) {
            self.count = count
            self.size = size
            self.sizeDenied = sizeDenied
        }

        /// A scripted reading (virtual time): a number is the item count of an empty Trash; text or lines give the
        /// count and then the size in bytes; a failure is a Trash whose size cannot be read.
        init(scripted value: BackgroundFakeValue) {
            if let message = value.failureMessage {
                self.init(count: Int(message) ?? 0, size: nil, sizeDenied: true)
                return
            }
            if case .number(let n) = value {
                self.init(count: Int(n.isFinite ? min(max(n, 0), 1e9) : 0), size: 0)
                return
            }
            let numbers = (value.lines ?? []).flatMap { $0.split(whereSeparator: { $0 == " " || $0 == "," }) }
                .compactMap { Double($0) }.filter(\.isFinite)
            self.init(count: Int(min(max(numbers.first ?? 0, 0), 1e9)), size: max(numbers.dropFirst().first ?? 0, 0))
        }
    }

    /// A Trash given as data (`--render --data`'s `trash`): every reading is this one, and nothing is read from the
    /// Mac. nil: the Mac's Trash. Set on the main thread before skins load; the readings in flight finish as they were.
    static var fixture: Status? {
        get {
            fixtureLock.lock()
            defer { fixtureLock.unlock() }
            return fixtureValue
        }
        set {
            fixtureLock.lock()
            fixtureValue = newValue
            fixtureLock.unlock()
        }
    }
    private static let fixtureLock = NSLock()
    private static var fixtureValue: Status?

    /// Folders to look at (background queue); tests replace it.
    static var folders: () -> [String] = { TrashMonitor.cachedDefaultFolders() }
    /// The monitor's clock (seconds, monotonic; any thread): shared by every skin, so not a skin's clock. Tests and a
    /// verifier replace it with the rest of the service.
    static var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private static var folderCache: (time: TimeInterval, folders: [String])?
    private static let folderLock = NSLock()

    /// `defaultFolders()`, looked up again at most every 10 seconds (volumes come and go rarely).
    static func cachedDefaultFolders() -> [String] {
        let now = TrashMonitor.clock()
        folderLock.lock()
        let cached = folderCache
        folderLock.unlock()
        if let cached, now - cached.time < 10 { return cached.folders }
        let folders = defaultFolders()
        folderLock.lock()
        folderCache = (now, folders)
        folderLock.unlock()
        return folders
    }

    private let lock = NSLock()
    private var status = Status()
    private var inFlight = false
    private var lastRefresh: TimeInterval = -1
    private var sizeSignature: String?
    private var sizeTime: TimeInterval = -1
    /// Callbacks waiting for the reading in flight, each with the executor of the skin that asked.
    private var waiters: [(executor: SkinExecutor, callback: () -> Void)] = []
    /// Skins' background work waiting for the reading in flight (called on the reading's queue).
    private var listeners: [() -> Void] = []
    /// Whether the reading in flight measures the size.
    private var inFlightIncludesSize = false
    /// The size was asked for while a reading without it was in flight (a skin's `RecycleType=Count` measure started
    /// it, and its `Size` measure came next in the same update): another reading, with the size, follows as soon as
    /// that one is done, and these wait for it.
    private var sizeFollowUp: SizeFollowUp?

    private struct SizeFollowUp {
        var force = false
        var waiters: [(executor: SkinExecutor, callback: () -> Void)] = []
        var listeners: [() -> Void] = []
    }
    /// Changes when the readings are forgotten (`forget`).
    private var generation = 0

    /// Size readings are reused while the folders look unchanged, but not longer than this (seconds).
    static let sizeMaxAge: TimeInterval = 30

    var latest: Status {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    /// Forgets the readings so far: the next refresh reads again (the source of readings changed), and a reading in
    /// flight keeps its result to itself (it only answers those waiting for it).
    func forget() {
        lock.lock()
        status = Status()
        lastRefresh = -1
        sizeSignature = nil
        sizeTime = -1
        generation &+= 1
        lock.unlock()
    }

    /// Starts a background reading that nobody waits for (after Finder emptied the Trash); see below.
    func refresh(includeSize: Bool, force: Bool = false) {
        refresh(includeSize: includeSize, force: force, waiter: nil, listener: nil)
    }

    /// Starts a background reading unless one is running or one finished less than half a second ago.
    /// `completion` runs on `executor` once a reading is available — after the current work when the latest one is
    /// fresh. The executor has no default: a skin's callback must go to that skin's executor, and a default of the
    /// main thread would still be right today, so nothing would notice a caller that forgot it.
    func refresh(includeSize: Bool, force: Bool = false, on executor: SkinExecutor, completion: (() -> Void)?) {
        refresh(includeSize: includeSize, force: force, waiter: completion.map { (executor, $0) }, listener: nil)
    }

    /// The same for a skin's background work (`Skin.startBackground`, which hands the result back through the skin's
    /// executor): `listener` runs once a reading is available, on the reading's queue — or at once, on the caller's
    /// thread, when the latest one is fresh.
    func refresh(includeSize: Bool, force: Bool = false, then listener: @escaping () -> Void) {
        refresh(includeSize: includeSize, force: force, waiter: nil, listener: listener)
    }

    private func refresh(includeSize: Bool, force: Bool, waiter: (executor: SkinExecutor, callback: () -> Void)?,
                         listener: (() -> Void)?) {
        refresh(includeSize: includeSize, force: force, throttled: true, waiters: waiter.map { [$0] } ?? [],
                listeners: listener.map { [$0] } ?? [])
    }

    /// `throttled`: a reading that finished less than half a second ago is reused (not for a size follow-up, which
    /// comes right after a reading that left the size out, and must look at the Trash again).
    private func refresh(includeSize: Bool, force: Bool, throttled: Bool,
                         waiters asking: [(executor: SkinExecutor, callback: () -> Void)],
                         listeners hearing: [() -> Void]) {
        let now = TrashMonitor.clock()
        lock.lock()
        if inFlight {
            if includeSize && !inFlightIncludesSize {
                var followUp = sizeFollowUp ?? SizeFollowUp()
                followUp.force = followUp.force || force
                followUp.waiters += asking
                followUp.listeners += hearing
                sizeFollowUp = followUp
            } else {
                waiters += asking
                listeners += hearing
            }
            lock.unlock()
            return
        }
        if throttled && !force && now - lastRefresh < 0.5
            && (!includeSize || status.size != nil || status.sizeDenied) {
            lock.unlock()
            for waiter in asking { waiter.executor.async(waiter.callback) }
            hearing.forEach { $0() }
            return
        }
        waiters += asking
        listeners += hearing
        inFlight = true
        inFlightIncludesSize = includeSize
        let previousSignature = sizeSignature
        let previousSizeTime = sizeTime
        let previous = status
        let startedIn = generation
        lock.unlock()
        PluginIO.queue.async { [self] in
            if let given = TrashMonitor.fixture {
                // A Trash given as data: nothing is read.
                lock.lock()
                status = given
                inFlight = false
                lastRefresh = TrashMonitor.clock()
                let done = waiters, heard = listeners
                waiters = []
                listeners = []
                let followUp = sizeFollowUp
                sizeFollowUp = nil
                lock.unlock()
                TrashMonitor.deliver(done)
                heard.forEach { $0() }
                startSizeFollowUp(followUp)
                return
            }
            let folders = TrashMonitor.folders()
            let count = folders.reduce(0) { $0 + (TrashMonitor.entryCount($1) ?? 0) }
            var next = Status(count: count, size: previous.size, sizeDenied: previous.sizeDenied)
            var signature = previousSignature
            var measuredAt = previousSizeTime
            if includeSize {
                let sig = TrashMonitor.signature(folders)
                let age = TrashMonitor.clock() - previousSizeTime
                if force || sig != previousSignature || previous.size == nil && !previous.sizeDenied
                    || age > TrashMonitor.sizeMaxAge {
                    var total = 0.0
                    var denied = false
                    for folder in folders {
                        if let s = TrashMonitor.size(of: folder) { total += s } else { denied = true }
                    }
                    next.size = denied && total == 0 ? nil : total
                    next.sizeDenied = denied
                    signature = sig
                    measuredAt = TrashMonitor.clock()
                }
            }
            lock.lock()
            if generation == startedIn {
                status = next
                sizeSignature = signature
                sizeTime = measuredAt
                lastRefresh = TrashMonitor.clock()
            }
            inFlight = false
            let done = waiters, heard = listeners
            waiters = []
            listeners = []
            let followUp = sizeFollowUp
            sizeFollowUp = nil
            lock.unlock()
            TrashMonitor.deliver(done)
            heard.forEach { $0() }
            startSizeFollowUp(followUp)
        }
    }

    /// The reading with the size that was asked for while one without it ran (see `sizeFollowUp`).
    private func startSizeFollowUp(_ followUp: SizeFollowUp?) {
        guard let followUp else { return }
        refresh(includeSize: true, force: followUp.force, throttled: false, waiters: followUp.waiters,
                listeners: followUp.listeners)
    }

    /// Runs the waiters' callbacks, in the order they asked, with one block per executor: all the skins on the main
    /// thread get theirs in one main-queue block, as they always did.
    static func deliver(_ waiters: [(executor: SkinExecutor, callback: () -> Void)]) {
        var groups: [(executor: SkinExecutor, callbacks: [() -> Void])] = []
        for waiter in waiters {
            if let i = groups.firstIndex(where: { $0.executor === waiter.executor }) {
                groups[i].callbacks.append(waiter.callback)
            } else {
                groups.append((waiter.executor, [waiter.callback]))
            }
        }
        for group in groups {
            let callbacks = group.callbacks
            group.executor.async { callbacks.forEach { $0() } }
        }
    }

    /// `~/.Trash` and `.Trashes/<uid>` of the other internal, local volumes that have one.
    static func defaultFolders() -> [String] {
        var list = [homeTrash]
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                            options: [.skipHiddenVolumes]) ?? []
        for volume in volumes {
            guard let v = try? volume.resourceValues(forKeys: Set(keys)), v.volumeIsInternal == true,
                  v.volumeIsLocal == true, v.volumeIsRootFileSystem != true, volume.path != "/" else { continue }
            let trash = volume.appendingPathComponent(".Trashes/\(getuid())").path
            var st = stat()
            if stat(trash, &st) == 0 { list.append(trash) }
        }
        return list
    }

    /// Items in a folder without listing it (works in the protected Trash): the directory's entry count, minus Finder's
    /// bookkeeping files.
    static func entryCount(_ path: String) -> Int? {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.dirattr = attrgroup_t(ATTR_DIR_ENTRYCOUNT)
        var buffer = [UInt8](repeating: 0, count: 64)
        guard getattrlist(path, &attributes, &buffer, buffer.count, 0) == 0 else { return nil }
        let count = buffer.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        var result = Int(count)
        for hidden in [".DS_Store", ".localized"] {
            var st = stat()
            if lstat(path + "/" + hidden, &st) == 0 { result -= 1 }
        }
        return max(result, 0)
    }

    /// Total size of the files in `path` (recursive), nil when it cannot be listed.
    static func size(of path: String) -> Double? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        if names.isEmpty { return 0 }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
                                      .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                     errorHandler: { _, _ in true }) else { return nil }
        var total = 0.0
        var visited = 0
        for case let item as URL in e {
            visited += 1
            if visited > PluginIO.maxEntries { break }
            guard let v = try? item.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Double(v.fileSize ?? v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Changes when items are added to or removed from a Trash folder.
    static func signature(_ folders: [String]) -> String {
        folders.map { folder -> String in
            var st = stat()
            guard stat(folder, &st) == 0 else { return "-" }
            return "\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec).\(st.st_nlink)"
        }.joined(separator: "|")
    }
}
