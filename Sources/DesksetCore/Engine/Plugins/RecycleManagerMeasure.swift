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
        // The first reading is shown as soon as it arrives (skins often update this measure rarely).
        monitor.refresh(includeSize: sizeMode, on: skin.executor,
                        completion: hasReading ? nil : { [weak self] in self?.applyFirstReading() })
        return value(of: monitor.latest)
    }

    /// The first reading has been applied (tests check that it waits for the skin's executor).
    private(set) var hasReading = false

    private func applyFirstReading() {
        guard !closed, !hasReading else { return }
        hasReading = true
        publishAsyncResult(number: value(of: TrashMonitor.shared.latest), string: nil)
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
            PluginProcess.run("/usr/bin/open", [TrashMonitor.homeTrash])
        case "emptybin":
            PluginProcess.run("/usr/bin/osascript", RecycleManagerMeasure.emptyScript(confirm: true),
                              on: skin.executor) { _ in
                TrashMonitor.shared.refresh(includeSize: true, force: true)
            }
        case "emptybinsilent":
            PluginProcess.run("/usr/bin/osascript", RecycleManagerMeasure.emptyScript(confirm: false),
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
    }

    /// Folders to look at (background queue); tests replace it.
    static var folders: () -> [String] = { TrashMonitor.cachedDefaultFolders() }

    private static var folderCache: (time: TimeInterval, folders: [String])?
    private static let folderLock = NSLock()

    /// `defaultFolders()`, looked up again at most every 10 seconds (volumes come and go rarely).
    static func cachedDefaultFolders() -> [String] {
        let now = ProcessInfo.processInfo.systemUptime
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

    /// Size readings are reused while the folders look unchanged, but not longer than this (seconds).
    static let sizeMaxAge: TimeInterval = 30

    var latest: Status {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    /// Starts a background reading that nobody waits for (after Finder emptied the Trash); see below.
    func refresh(includeSize: Bool, force: Bool = false) {
        refresh(includeSize: includeSize, force: force, waiter: nil)
    }

    /// Starts a background reading unless one is running or one finished less than half a second ago.
    /// `completion` runs on `executor` once a reading is available — after the current work when the latest one is
    /// fresh. The executor has no default: a skin's callback must go to that skin's executor, and a default of the
    /// main thread would still be right today, so nothing would notice a caller that forgot it.
    func refresh(includeSize: Bool, force: Bool = false, on executor: SkinExecutor, completion: (() -> Void)?) {
        refresh(includeSize: includeSize, force: force, waiter: completion.map { (executor, $0) })
    }

    private func refresh(includeSize: Bool, force: Bool, waiter: (executor: SkinExecutor, callback: () -> Void)?) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if inFlight {
            if let waiter { waiters.append(waiter) }
            lock.unlock()
            return
        }
        if !force && now - lastRefresh < 0.5 && (!includeSize || status.size != nil || status.sizeDenied) {
            lock.unlock()
            if let waiter { waiter.executor.async(waiter.callback) }
            return
        }
        if let waiter { waiters.append(waiter) }
        inFlight = true
        let previousSignature = sizeSignature
        let previousSizeTime = sizeTime
        let previous = status
        lock.unlock()
        PluginIO.queue.async { [self] in
            let folders = TrashMonitor.folders()
            let count = folders.reduce(0) { $0 + (TrashMonitor.entryCount($1) ?? 0) }
            var next = Status(count: count, size: previous.size, sizeDenied: previous.sizeDenied)
            var signature = previousSignature
            var measuredAt = previousSizeTime
            if includeSize {
                let sig = TrashMonitor.signature(folders)
                let age = ProcessInfo.processInfo.systemUptime - previousSizeTime
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
                    measuredAt = ProcessInfo.processInfo.systemUptime
                }
            }
            lock.lock()
            status = next
            sizeSignature = signature
            sizeTime = measuredAt
            inFlight = false
            lastRefresh = ProcessInfo.processInfo.systemUptime
            let done = waiters
            waiters = []
            lock.unlock()
            TrashMonitor.deliver(done)
        }
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
