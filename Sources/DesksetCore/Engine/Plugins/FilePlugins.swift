import Darwin
import Foundation

// Clean-room implementations from the public manual only:
//   https://docs.rainmeter.net/manual/plugins/quote/
//   https://docs.rainmeter.net/manual/plugins/folderinfo/

/// Background file scans, listing reads and the Trash. Concurrent, so one huge scan does not hold up the others.
enum PluginIO {
    static let queue = DispatchQueue(label: "Deskset.PluginIO", qos: .utility, attributes: .concurrent)
    /// Bound on the number of files a scan visits (a whole disk would otherwise take minutes).
    static let maxEntries = 2_000_000
}

// MARK: - Quote

/// `Plugin=QuotePlugin`: a random line (or `Separator`-delimited part) of a text file, or a random file of a folder.
/// - `PathName` file → text parts; folder → files (`Subfolders=1` default: recursively; `FileFilter` `*.jpg;*.png`).
/// - A new random item every update (so `UpdateDivider` sets the pace); the item never repeats the previous one when
///   there is a choice (judgment).
/// - Mac: the file or folder is read on a background queue when the options change and again when the list is older
///   than a minute (so new files show up); until the first read finishes the value is empty, and the first item is
///   shown as soon as it is ready (a measure with `UpdateDivider=-1` still gets one). Windows paths and environment
///   variables (`%HOMEPATH%\Pictures`) are mapped as described in `PluginPaths`. Blank parts, hidden files and
///   Finder metadata files are skipped (judgment). The number value is 0.
public final class QuoteMeasure: Measure, PluginLifecycle {
    private var path = ""
    private var separator = "\n"
    private var subfolders = true
    private var filter = WildcardFilter("")
    private var items: [String] = []
    private var loadedKey: String?
    private var loadingKey: String?
    private var loadedAt: TimeInterval = 0
    private var current: String?
    private var closed = false
    private var reported: Set<String> = []

    /// Reload period of the list (seconds).
    static var reloadInterval: TimeInterval = 60
    static let maxItems = 100_000

    public var isLoading: Bool { loadingKey != nil }
    public var itemCount: Int { items.count }

    public func skinWillClose() { closed = true }

    public override func readMeasureOptions() {
        let raw = string("PathName")
        path = raw.trimmingCharacters(in: .whitespaces).isEmpty ? "" : PluginPaths.resolve(raw, skin: skin)
        separator = option("Separator") ?? "\n"
        subfolders = bool("Subfolders", true)
        filter = WildcardFilter(string("FileFilter"))
    }

    private var key: String { "\(path)|\(separator)|\(subfolders)|\(filter.patterns.joined(separator: ";"))" }

    public override func computeValue() -> Double {
        let k = key
        if path.isEmpty {
            rawString = ""
            return 0
        }
        let stale = skin.clock() - loadedAt > QuoteMeasure.reloadInterval
        if loadingKey != k && (loadedKey != k || stale) { load(k) }
        if loadedKey == k, !items.isEmpty { current = pick() }
        rawString = current ?? ""
        return 0
    }

    private func pick() -> String {
        guard items.count > 1 else { return items.first ?? "" }
        var choice = items[skin.random.int(in: 0..<items.count)]
        if choice == current { choice = items[skin.random.int(in: 0..<items.count)] }
        if choice == current, let other = items.first(where: { $0 != current }) { choice = other }
        return choice
    }

    private func load(_ k: String) {
        guard !closed else { return }
        loadingKey = k
        let path = self.path, separator = self.separator, subfolders = self.subfolders, filter = self.filter
        // A file the skin wrote to a recording's sandbox is read from its copy.
        let readPath = skin.readablePath(path)
        let job = BackgroundJob(.quote, subject: path, on: PluginIO.queue, fixture: true, reads: path) {
            QuoteMeasure.readItems(path: readPath, separator: separator, subfolders: subfolders, filter: filter)
        }
        skin.startBackground(job) { [weak self] result in
            guard let self, !self.closed, self.loadingKey == k else { return }
            self.loadingKey = nil
            self.loadedAt = self.skin.clock()
            switch result {
            case .success(let list):
                let first = self.loadedKey != k
                self.items = list
                self.loadedKey = k
                if first || self.current == nil || !(list.contains(self.current ?? "")) {
                    self.current = list.isEmpty ? nil : self.pick()
                    self.publishAsyncResult(number: 0, string: self.current ?? "")
                }
            case .failure(let message):
                self.items = []
                self.loadedKey = k
                self.current = nil
                self.publishAsyncResult(number: 0, string: "")
                if self.reported.insert(k).inserted {
                    self.skin.log("QuotePlugin [\(self.name)]: \(message)", level: .warning)
                }
            }
        }
    }

    enum ReadError: Error, CustomStringConvertible {
        case missing(String), unreadable(String)
        var description: String {
            switch self {
            case .missing(let p): return "\(p) does not exist"
            case .unreadable(let p): return "cannot read \(p) (no permission?)"
            }
        }
    }

    /// Items of a file or folder (runs on a background queue).
    static func readItems(path: String, separator: String, subfolders: Bool,
                          filter: WildcardFilter) -> Result<[String], ReadError> {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .failure(.missing(path))
        }
        if !isDirectory.boolValue {
            guard let data = FileManager.default.contents(atPath: path) else { return .failure(.unreadable(path)) }
            let text = TextDecoding.decode(data)
            return .success(split(text, separator: separator))
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var files: [String] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !subfolders { options.insert(.skipsSubdirectoryDescendants) }
        var failed = false
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: options,
                                                               errorHandler: { _, _ in failed = true; return true })
        else { return .failure(.unreadable(path)) }
        var visited = 0
        for case let file as URL in enumerator {
            visited += 1
            if visited > PluginIO.maxEntries || files.count >= maxItems { break }
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let name = file.lastPathComponent
            if MacSystemFiles.isSystem(name) || !filter.matches(name) { continue }
            files.append(file.path)
        }
        if files.isEmpty && failed { return .failure(.unreadable(path)) }
        return .success(files.sorted())
    }

    /// Text parts; `\n` also splits Windows line ends, blank parts are dropped.
    static func split(_ text: String, separator: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let sep = separator.isEmpty ? "\n" : separator.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.components(separatedBy: sep)
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(maxItems).map { $0 }
    }
}

// MARK: - FolderInfo

/// `Plugin=FolderInfo`: number of files, number of folders, or total size of a folder.
/// - `Folder` is a path, or `[OtherMeasure]` naming another FolderInfo measure whose scan is reused (manual: "specify
///   the name of the first measure in subsequent measures").
/// - `InfoType` FileCount / FolderCount / FolderSize (judgment: FolderSize when missing or unknown),
///   `IncludeSubFolders`, `IncludeHiddenFiles`, `IncludeSystemFiles` (default 0 each), `RegExpFilter` (PCRE on file
///   names; only matching files are counted and summed).
/// - Mac: the folder is scanned on a background queue at each update of the measure (at most one scan at a time, and
///   after a slow scan a pause of twice its duration; the value updates when the scan ends). Hidden = dot files or the "hidden" flag; system = Finder / file system
///   bookkeeping files (`.DS_Store`, `.Spotlight-V100`, …). Packages (`.app`) are folders; symbolic links are
///   counted as files and not followed; the size is the files' logical size. Private folders (Desktop, Documents,
///   Downloads) make macOS ask the user for access the first time; without it the counts are 0 (logged once).
public final class FolderInfoMeasure: Measure, PluginLifecycle {
    enum InfoType: String { case fileCount = "filecount", folderCount = "foldercount", folderSize = "foldersize" }

    struct Options: Equatable {
        var path = ""
        var subfolders = false
        var hidden = false
        var system = false
        var regExp = ""
    }

    struct Result: Equatable {
        var files = 0
        var folders = 0
        var size = 0.0
        var denied = false
    }

    private var infoType = InfoType.folderSize
    private var parentName: String?
    private var options = Options()
    private var result = Result()
    private var scanning = false
    private var closed = false
    private var reportedDenied = false
    /// No new scan before this time (monotonic seconds): see `scanPause`.
    private var nextScan: TimeInterval = 0

    /// After a scan that took `d` seconds the next one starts no sooner than `scanPause × d` later, so a huge folder
    /// scanned at every update keeps a background thread busy at most a third of the time (small folders take
    /// milliseconds and are not affected).
    static var scanPause = 2.0

    /// Finds the FolderInfo measure named in `Folder=[Name]`. Tests replace it.
    var parentResolver: (String) -> FolderInfoMeasure? = { _ in nil }

    public var isScanning: Bool { scanning }
    /// The latest scan (for children).
    var latestResult: Result { result }

    override var tracksValueRange: Bool { true }

    public required init(name: String, section: IniSection, skin: Skin, type: String) {
        super.init(name: name, section: section, skin: skin, type: type)
        parentResolver = { [unowned skin] in skin.measure(named: $0) as? FolderInfoMeasure }
    }

    public func skinWillClose() { closed = true }

    public override func readMeasureOptions() {
        infoType = InfoType(rawValue: string("InfoType").trimmingCharacters(in: .whitespaces).lowercased()) ?? .folderSize
        let raw = (rawOption("Folder") ?? "").trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("["), raw.hasSuffix("]"), raw.count > 2 {
            let inner = String(raw.dropFirst().dropLast())
            if !inner.hasPrefix("#"), !inner.hasPrefix("&"), inner.caseInsensitiveCompare(name) != .orderedSame,
               parentResolver(inner) != nil {
                parentName = inner
                return
            }
        }
        parentName = nil
        var o = Options()
        let folder = string("Folder")
        o.path = folder.trimmingCharacters(in: .whitespaces).isEmpty ? "" : PluginPaths.resolve(folder, skin: skin)
        o.subfolders = bool("IncludeSubFolders", false)
        o.hidden = bool("IncludeHiddenFiles", false)
        o.system = bool("IncludeSystemFiles", false)
        o.regExp = string("RegExpFilter")
        options = o
    }

    public override func computeValue() -> Double {
        let r: Result
        if let parentName {
            r = parentResolver(parentName)?.latestResult ?? Result()
        } else {
            if !scanning && !options.path.isEmpty && skin.clock() >= nextScan { scan() }
            r = result
        }
        switch infoType {
        case .fileCount: return Double(r.files)
        case .folderCount: return Double(r.folders)
        case .folderSize: return r.size
        }
    }

    private func scan() {
        guard !closed else { return }
        scanning = true
        let o = options
        // What the scan cost, in real time (the pause after it grows with it); the next scan is due on the skin's clock,
        // counted from when the result reaches the skin. A fixture scan in virtual time costs nothing: no real time
        // goes into a virtual run.
        // A folder the skin removed or renamed in a recording's sandbox reads as it is there (the copies of files it
        // wrote are kept apart from the folders they belong to, so a scan does not count them).
        var scanned = o
        scanned.path = skin.readablePath(o.path)
        let job = BackgroundJob(.folderInfo, subject: o.path, start: { deliver in
            PluginIO.queue.async {
                let started = ProcessInfo.processInfo.systemUptime
                let r = FolderInfoMeasure.scan(scanned)
                deliver((r, ProcessInfo.processInfo.systemUptime - started))
            }
        }, inline: { (FolderInfoMeasure.scan(scanned), 0) }, reads: o.path)
        skin.startBackground(job) { [weak self] (r: Result, cost: TimeInterval) in
            guard let self else { return }
            self.scanning = false
            self.nextScan = self.skin.clock() + cost * FolderInfoMeasure.scanPause
            guard !self.closed, o == self.options else { return }
            self.result = r
            if r.denied && !self.reportedDenied {
                self.reportedDenied = true
                self.skin.log("FolderInfo [\(self.name)]: cannot read (all of) \(o.path) — no permission?",
                              level: .notice)
            }
        }
    }

    /// Counts a folder (background queue).
    static func scan(_ o: Options) -> Result {
        var r = Result()
        let regex = o.regExp.isEmpty ? nil : PCRE.regex(o.regExp)
        let url = URL(fileURLWithPath: o.path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey]
        var enumOptions: FileManager.DirectoryEnumerationOptions = []
        if !o.subfolders { enumOptions.insert(.skipsSubdirectoryDescendants) }
        var denied = false
        guard FileManager.default.fileExists(atPath: o.path),
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                              options: enumOptions,
                                                              errorHandler: { _, _ in denied = true; return true })
        else { return Result(denied: true) }
        var visited = 0
        for case let item as URL in enumerator {
            visited += 1
            if visited > PluginIO.maxEntries { break }
            let name = item.lastPathComponent
            let values = try? item.resourceValues(forKeys: Set(keys))
            let isSystem = MacSystemFiles.isSystem(name)
            let isHidden = isSystem || name.hasPrefix(".") || values?.isHidden == true
            let isFolder = values?.isDirectory == true && values?.isSymbolicLink != true
            if (isSystem && !o.system) || (isHidden && !isSystem && !o.hidden) {
                if isFolder { enumerator.skipDescendants() }
                continue
            }
            if isFolder {
                r.folders += 1
                continue
            }
            if let regex {
                let range = NSRange(name.startIndex..., in: name)
                if regex.firstMatch(in: name, options: [], range: range) == nil { continue }
            }
            r.files += 1
            r.size += Double(values?.fileSize ?? 0)
        }
        r.denied = denied
        return r
    }
}

// MARK: - DragDrop

/// `Measure=DragDrop` (and `Plugin=Drag&Drop` / `Plugin=DragDrop`): reacts to files and folders dragged and dropped
/// onto the skin (`https://docs-v5.rainmeter.net/manual/measures/dragdrop/`).
public final class DragDropMeasure: Measure, PluginLifecycle {
    public enum DropAction: String {
        case path = "path"
        case move = "move"
        case copy = "copy"
        case shortcut = "shortcut"
        case delete = "delete"
    }

    private var dropAction: DropAction = .path
    private var targetPath = ""
    private var silent = false
    private var replaceIfExists = false
    private var processAllFiles = false
    private(set) var parentName: String?
    private var boundsSpec = ""
    private var onDropAction = ""
    private var onEnterAction = ""
    private var onLeaveAction = ""
    private var onOverAction = ""
    private var lastDroppedPath = ""
    private var isHovering = false
    private var closed = false

    public required init(name: String, section: IniSection, skin: Skin, type: String) {
        super.init(name: name, section: section, skin: skin, type: type)
        rawString = ""
    }

    public func skinWillClose() { closed = true }

    public override func readMeasureOptions() {
        if option("FancyRenderer") != nil {
            skin.logOnce("[\(name)] FancyRenderer is deprecated and ignored in Rainmeter 5.0", level: .warning)
        }
        let rawParent = string("Parent").trimmingCharacters(in: .whitespaces)
        if !rawParent.isEmpty {
            let stripped: String
            if rawParent.hasPrefix("["), rawParent.hasSuffix("]"), rawParent.count > 2 {
                stripped = String(rawParent.dropFirst().dropLast())
            } else {
                stripped = rawParent
            }
            parentName = stripped.isEmpty ? nil : stripped
        } else {
            parentName = nil
        }
        let parent = parentName.flatMap { skin.measure(named: $0) as? DragDropMeasure }
        let rawAction = string("Action", parent?.dropAction.rawValue ?? "Path")
            .trimmingCharacters(in: .whitespaces).lowercased()
        dropAction = DropAction(rawValue: rawAction) ?? .path
        let rawPath = string("Path").trimmingCharacters(in: .whitespaces)
        if !rawPath.isEmpty {
            targetPath = PluginPaths.resolve(rawPath, skin: skin)
        } else {
            targetPath = parent?.targetPath ?? ""
        }
        silent = bool("Silent", parent?.silent ?? false)
        replaceIfExists = bool("ReplaceIfExists", parent?.replaceIfExists ?? false)
        processAllFiles = bool("ProcessAllFiles", parent?.processAllFiles ?? false)
        boundsSpec = string("Bounds").trimmingCharacters(in: .whitespaces)
        onDropAction = actionOption("OnDropAction")
        onEnterAction = actionOption("OnEnterAction")
        onLeaveAction = actionOption("OnLeaveAction")
        onOverAction = actionOption("OnOverAction")
    }

    public override func computeValue() -> Double {
        rawString = lastDroppedPath
        return 0
    }

    private var isActive: Bool {
        guard !closed && !disabled && !paused else { return false }
        if let parentName, let parent = skin.measure(named: parentName) as? DragDropMeasure {
            return !parent.disabled && !parent.paused
        }
        return true
    }

    /// True when skin-local point `(x, y)` lies inside this measure's `Bounds` (or anywhere on the skin when `Bounds`
    /// is empty).
    public func contains(x: Double, y: Double) -> Bool {
        if boundsSpec.isEmpty { return true }
        let parts = boundsSpec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 4,
           let bx = Double(parts[0]), let by = Double(parts[1]),
           let bw = Double(parts[2]), let bh = Double(parts[3]) {
            return x >= bx && x <= bx + bw && y >= by && y <= by + bh
        }
        if let meter = skin.meter(named: boundsSpec) {
            guard !meter.hidden else { return false }
            let r = meter.frame
            return x >= r.x && x <= r.x + r.width && y >= r.y && y <= r.y + r.height
        }
        return false
    }

    public func handleDragEnter(files: [String], x: Double, y: Double) {
        if needsOptionRead { readOptionsIfNeeded() }
        guard isActive else { return }
        if contains(x: x, y: y) {
            if !isHovering {
                isHovering = true
                runDragAction(onEnterAction, file: files.first ?? "", fileNr: 1, x: x, y: y)
            }
            runDragAction(onOverAction, file: files.first ?? "", fileNr: 1, x: x, y: y)
        }
    }

    public func handleDragMove(files: [String], x: Double, y: Double) {
        if needsOptionRead { readOptionsIfNeeded() }
        guard isActive else { return }
        if contains(x: x, y: y) {
            if !isHovering {
                isHovering = true
                runDragAction(onEnterAction, file: files.first ?? "", fileNr: 1, x: x, y: y)
            }
            runDragAction(onOverAction, file: files.first ?? "", fileNr: 1, x: x, y: y)
        } else if isHovering {
            isHovering = false
            runDragAction(onLeaveAction, file: files.first ?? "", fileNr: 1, x: x, y: y)
        }
    }

    public func handleDragLeave(files: [String], x: Double, y: Double) {
        if needsOptionRead { readOptionsIfNeeded() }
        guard isHovering else { return }
        isHovering = false
        guard isActive else { return }
        runDragAction(onLeaveAction, file: files.first ?? "", fileNr: 1, x: x, y: y)
    }

    @discardableResult
    public func handleDrop(files: [String], x: Double, y: Double) -> Bool {
        if needsOptionRead { readOptionsIfNeeded() }
        isHovering = false
        guard isActive, !files.isEmpty, contains(x: x, y: y) else { return false }
        let list = processAllFiles ? files : [files[0]]
        for (idx, file) in list.enumerated() {
            performFileOperation(on: file)
            lastDroppedPath = file
            rawString = file
            if let parentName, let parent = skin.measure(named: parentName) as? DragDropMeasure {
                parent.lastDroppedPath = file
                parent.rawString = file
            }
            runDragAction(onDropAction, file: file, fileNr: idx + 1, x: x, y: y)
        }
        return true
    }

    private func performFileOperation(on file: String) {
        switch dropAction {
        case .path:
            break
        case .copy, .move, .shortcut:
            guard !targetPath.isEmpty else { return }
            let srcURL = URL(fileURLWithPath: file)
            let folderURL = URL(fileURLWithPath: targetPath, isDirectory: true)
            let dstURL = folderURL.appendingPathComponent(srcURL.lastPathComponent)
            let action = dropAction
            let replace = replaceIfExists
            let effect: SideEffect = (action == .move)
                ? .renameFile(from: srcURL.path, to: dstURL.path)
                : .writeFile(path: dstURL.path)
            skin.sideEffects.perform(effect) {
                LiveSideEffects.performDragDropWrite(from: srcURL, to: dstURL, folder: folderURL,
                                                     mode: action, replaceIfExists: replace)
            }
        case .delete:
            let srcURL = URL(fileURLWithPath: file)
            skin.sideEffects.perform(.removeFile(path: srcURL.path)) {
                LiveSideEffects.performDragDropTrash(at: srcURL)
            }
        }
    }

    private func runDragAction(_ action: String, file: String, fileNr: Int, x: Double, y: Double) {
        guard !action.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let trimmedFile = file.hasSuffix("/") && file.count > 1 ? String(file.dropLast()) : file
        let ns = trimmedFile as NSString
        let fullName = ns.lastPathComponent
        let ext = ns.pathExtension
        let baseName = ext.isEmpty ? fullName : (fullName as NSString).deletingPathExtension
        let directory = ns.deletingLastPathComponent
        let replacements: [(String, String)] = [
            ("$Name$", baseName),
            ("$Directory$", directory),
            ("$Type$", ext),
            ("$File$", file),
            ("$FileNr$", "\(fileNr)"),
            ("$MouseX$", "\(Int(x.rounded()))"),
            ("$MouseY$", "\(Int(y.rounded()))"),
        ]
        var expanded = action
        for (token, value) in replacements {
            expanded = expanded.replacingOccurrences(of: token, with: value, options: .caseInsensitive)
        }
        skin.execute(expanded, from: self)
    }
}

