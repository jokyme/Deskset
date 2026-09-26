import Darwin
import Foundation

// Clean-room implementation from the public manual only: https://docs.rainmeter.net/manual/plugins/fileview/

/// Icon files for `Type=Icon` child measures. Extracting a file's icon needs AppKit, so the app installs `writer`:
/// it gets the file (or folder) path, the icon size in pixels (16 / 32 / 48 / 256) and the destination path, writes an
/// image file there (PNG data is fine whatever the extension; write atomically) and returns true on success. It is
/// called on a background queue. Without a writer, Icon measures are empty.
public enum FileViewIcons {
    public static var writer: ((_ source: String, _ pixelSize: Int, _ destination: String) -> Bool)?
}

/// `Plugin=FileView`: a "parent" measure lists a folder; "child" measures (`Path=[Parent]`) read one entry each.
///
/// Parent (manual): `Path` (default "This PC" → here `/Volumes/`, the mounted volumes), `Recursive` 0 / 1 (counts
/// include subfolders) / 2 (indexes every file of the tree, no folders), `Count` (items per page, default 1),
/// `ShowDotDot`, `ShowFolder`, `ShowFile`, `ShowHidden` (default 1), `ShowSystem` (default 0), `HideExtensions`,
/// `Extensions` (`jpg;png`), `SortType` Name / Size / Type / Date, `SortDateType`, `SortAscending`, `WildcardSearch`,
/// `FinishAction`. Commands: Update, PageUp, PageDown, IndexUp, IndexDown, PreviousFolder, ContextMenu [path],
/// Properties [path]. The folder is read at the first update and on Update / FollowPath / PreviousFolder only (manual:
/// not on normal updates), on a background queue; when it is read, the parent and its children get their new values
/// before FinishAction runs.
///
/// Child: `Index` (1…Count, wraps), `IgnoreCount`, `Type` FolderPath (default) / FolderSize / FileCount / FolderCount /
/// FileName / FileType / FileSize / FileDate / FilePath / PathToFile / Icon, `DateType`, `IconPath`, `IconSize`.
/// Commands: FollowPath, Open, ContextMenu, Properties.
///
/// Mac judgments (docs/compat/plugins.md): paths use `/` (folder paths end with `/`); ".." is listed first, then
/// folders, then files, each group sorted (SortAscending reverses within groups); hidden = dot files and files with
/// the hidden flag, system = Finder bookkeeping files (`.DS_Store`…); counts and size follow the hidden / system /
/// Extensions / WildcardSearch filters but not ShowFile / ShowFolder; FileDate is the short date and time of the
/// user's locale (number: seconds since 1601 like the Time measure); the parent's string is the current folder and
/// its number the number of listed items; Open / FollowPath on a file open it with its default app;
/// ContextMenu reveals the item in Finder (no Finder context menu can be shown for another app's files); Properties
/// opens Finder's Get Info window (asks once for permission to control Finder).
public final class FileViewMeasure: Measure, PluginLifecycle {
    enum ChildType: String {
        case folderPath = "folderpath", folderSize = "foldersize", fileCount = "filecount"
        case folderCount = "foldercount", fileName = "filename", fileType = "filetype", fileSize = "filesize"
        case fileDate = "filedate", filePath = "filepath", pathToFile = "pathtofile", icon = "icon"
    }

    enum DateType: String { case modified, created, accessed }

    struct Item: Equatable {
        var name: String
        var path: String
        var isFolder: Bool
        var isDotDot = false
        var size: Double = 0
        var modified: Date?
        var created: Date?
        var accessed: Date?

        var ext: String { isFolder ? "" : (name as NSString).pathExtension }

        func date(_ type: DateType) -> Date? {
            switch type {
            case .modified: return modified
            case .created: return created
            case .accessed: return accessed
            }
        }
    }

    struct ParentOptions: Equatable {
        var recursive = 0
        var count = 1
        var showDotDot = true
        var showFolder = true
        var showFile = true
        var showHidden = true
        var showSystem = false
        var hideExtensions = false
        var extensions: [String] = []
        var sortType = "name"
        var sortDateType = DateType.modified
        var sortAscending = true
        var wildcard = "*"
    }

    struct Listing: Equatable {
        var folder = ""
        var items: [Item] = []
        var fileCount = 0
        var folderCount = 0
        var folderSize = 0.0
    }

    // Parent state
    private var parentOptions = ParentOptions()
    private var pathOption = ""
    private var currentFolder: String?
    private var listing = Listing()
    private var offset = 0
    private var reading = false
    private var readGeneration = 0
    private var hasRead = false
    /// The configured folder (`Path`) when it was last read from the options.
    private var configuredAtRead: String?
    private var finishAction = ""
    private var children = NSHashTable<FileViewMeasure>.weakObjects()

    // Child state
    private(set) var parentName: String?
    private var childType = ChildType.folderPath
    private var index = 1
    private var ignoreCount = false
    private var dateType = DateType.modified
    private var iconPath = ""
    private var iconSize = 32
    private var lastIcon: (source: String, size: Int, destination: String)?
    private var iconGeneration = 0

    private var closed = false
    private var reported: Set<String> = []

    /// Finds the parent named in a child's `Path=[Name]`. Tests replace it.
    var parentResolver: (String) -> FileViewMeasure? = { _ in nil }

    public var isReading: Bool { reading }
    public var isChild: Bool { parentName != nil }

    override var tracksValueRange: Bool { true }

    public required init(name: String, section: IniSection, skin: Skin, type: String) {
        super.init(name: name, section: section, skin: skin, type: type)
        parentResolver = { [unowned skin] in skin.measure(named: $0) as? FileViewMeasure }
        rawString = ""
    }

    public func skinWillClose() { closed = true }

    // MARK: Options

    public override func readMeasureOptions() {
        let raw = (rawOption("Path") ?? "").trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("["), raw.hasSuffix("]"), raw.count > 2 {
            let inner = String(raw.dropFirst().dropLast())
            if inner.caseInsensitiveCompare(name) != .orderedSame, let parent = parentResolver(inner), !parent.isChild {
                parentName = parent.name
                parent.children.add(self)
                readChildOptions()
                return
            }
        }
        parentName = nil
        readParentOptions(raw)
    }

    private func readParentOptions(_ raw: String) {
        // "#Variables# can be used in the parent Path option, [SectionVariables] cannot".
        pathOption = skin.resolveStandardVariables(raw, in: self)
        var o = ParentOptions()
        o.recursive = min(max(int("Recursive", 0), 0), 2)
        o.count = min(max(int("Count", 1), 1), 10_000)
        o.showDotDot = bool("ShowDotDot", true)
        o.showFolder = bool("ShowFolder", true)
        o.showFile = bool("ShowFile", true)
        o.showHidden = bool("ShowHidden", true)
        o.showSystem = bool("ShowSystem", false)
        o.hideExtensions = bool("HideExtensions", false)
        o.extensions = string("Extensions").split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".*")).lowercased()
        }.filter { !$0.isEmpty }
        o.sortType = string("SortType", "Name").trimmingCharacters(in: .whitespaces).lowercased()
        o.sortDateType = DateType(rawValue: string("SortDateType", "Modified").trimmingCharacters(in: .whitespaces)
            .lowercased()) ?? .modified
        o.sortAscending = bool("SortAscending", true)
        let wildcard = string("WildcardSearch", "*").trimmingCharacters(in: .whitespaces)
        o.wildcard = wildcard.isEmpty ? "*" : wildcard
        parentOptions = o
        finishAction = actionOption("FinishAction")
    }

    private func readChildOptions() {
        childType = ChildType(rawValue: string("Type", "FolderPath").trimmingCharacters(in: .whitespaces).lowercased())
            ?? .folderPath
        index = max(int("Index", 1), 1)
        ignoreCount = bool("IgnoreCount", false)
        dateType = DateType(rawValue: string("DateType", "Modified").trimmingCharacters(in: .whitespaces).lowercased())
            ?? .modified
        iconPath = string("IconPath").trimmingCharacters(in: .whitespaces)
        switch string("IconSize", "Medium").trimmingCharacters(in: .whitespaces).lowercased() {
        case "small": iconSize = 16
        case "large": iconSize = 48
        case "extralarge": iconSize = 256
        default: iconSize = 32
        }
    }

    /// The folder `Path` names (default: the mounted volumes, the Mac's "This PC").
    private func configuredFolder() -> String {
        let p = pathOption.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return "/Volumes/" }
        return folderPath(PluginPaths.resolve(p, skin: skin))
    }

    private func folderPath(_ p: String) -> String { p.hasSuffix("/") ? p : p + "/" }

    // MARK: Values

    public override func computeValue() -> Double {
        if parentName != nil { return childValue() }
        if !hasRead && !reading {
            configuredAtRead = configuredFolder()
            read(folder: configuredAtRead ?? "/Volumes/")
        }
        rawString = listing.folder
        return Double(listing.items.count)
    }

    /// Recomputes a child's values from its parent now (the parent calls it after reading or scrolling).
    private func refreshFromParent() {
        guard parentName != nil, !disabled, !paused else { return }
        let v = childValue()
        publishAsyncResult(number: v, string: rawString)
    }

    private var parent: FileViewMeasure? { parentName.flatMap(parentResolver) }

    /// The parent's item for this child, or nil.
    private func item(in parent: FileViewMeasure) -> Item? {
        let items = parent.listing.items
        let position: Int
        if ignoreCount {
            position = index - 1
        } else {
            let count = max(parent.parentOptions.count, 1)
            position = parent.offset + (index - 1) % count
        }
        return position >= 0 && position < items.count ? items[position] : nil
    }

    private func childValue() -> Double {
        guard let parent else {
            rawString = ""
            return 0
        }
        let listing = parent.listing
        switch childType {
        case .folderPath:
            rawString = listing.folder
            return 0
        case .folderSize:
            rawString = nil
            return listing.folderSize
        case .fileCount:
            rawString = nil
            return Double(listing.fileCount)
        case .folderCount:
            rawString = nil
            return Double(listing.folderCount)
        default:
            break
        }
        guard let item = item(in: parent) else {
            rawString = ""
            return 0
        }
        switch childType {
        case .fileName:
            rawString = parent.parentOptions.hideExtensions && !item.isFolder
                ? (item.name as NSString).deletingPathExtension : item.name
            return 0
        case .fileType:
            rawString = item.ext
            return 0
        case .fileSize:
            if item.isFolder {
                rawString = ""
                return 0
            }
            rawString = nil
            return item.size
        case .fileDate:
            guard let date = item.date(dateType) else {
                rawString = ""
                return 0
            }
            rawString = FileViewMeasure.dateFormatter.string(from: date)
            return TimeFormatting.measureValue(for: date)
        case .filePath:
            rawString = item.isDotDot ? parentFolder(of: listing.folder) ?? item.path : item.path
            return 0
        case .pathToFile:
            rawString = folderPath((item.path as NSString).deletingLastPathComponent)
            return 0
        case .icon:
            rawString = icon(for: item)
            return 0
        default:
            rawString = ""
            return 0
        }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    // MARK: Icons

    private func iconDestination() -> String {
        if iconPath.isEmpty { return skin.directory.appendingPathComponent("icon\(index).ico").path }
        return PluginPaths.resolve(iconPath, skin: skin)
    }

    /// The icon file path once it is written (written on a background queue; the value updates when done).
    private func icon(for item: Item) -> String {
        guard let writer = FileViewIcons.writer else {
            report("icon", "FileView [\(name)]: file icons are not available")
            return ""
        }
        let destination = iconDestination()
        let source = item.isDotDot ? (parentFolder(of: parent?.listing.folder ?? "") ?? item.path) : item.path
        if let last = lastIcon, last.source == source, last.size == iconSize, last.destination == destination {
            return destination
        }
        iconGeneration += 1
        let generation = iconGeneration
        let size = iconSize
        let hop = skin.hop()
        PluginIO.queue.async { [weak self] in
            let ok = writer(source, size, destination)
            hop.post {
                guard let self, !self.closed, self.iconGeneration == generation else { return }
                if ok {
                    self.lastIcon = (source, size, destination)
                    if self.childType == .icon { self.publishAsyncResult(number: 0, string: destination) }
                }
            }
        }
        return lastIcon?.destination == destination ? destination : ""
    }

    // MARK: Reading

    private func read(folder: String) {
        guard !closed else { return }
        hasRead = true
        reading = true
        readGeneration += 1
        let generation = readGeneration
        let options = parentOptions
        let hop = skin.hop()
        PluginIO.queue.async { [weak self] in
            let result = FileViewMeasure.list(folder: folder, options: options)
            hop.post {
                guard let self, self.readGeneration == generation else { return }
                self.reading = false
                guard !self.closed else { return }
                self.finishRead(result)
            }
        }
    }

    private func finishRead(_ result: Result<Listing, FileViewError>) {
        switch result {
        case .success(let l):
            listing = l
            currentFolder = l.folder
        case .failure(let error):
            report("read:\(error)", "FileView [\(name)]: \(error)")
            listing = Listing(folder: currentFolder ?? configuredFolder())
        }
        offset = min(offset, max(listing.items.count - 1, 0))
        publishAsyncResult(number: Double(listing.items.count), string: listing.folder)
        refreshChildren()
        if !finishAction.isEmpty { skin.execute(finishAction, from: self) }
    }

    private func refreshChildren() {
        for child in children.allObjects where child.parentName?.caseInsensitiveCompare(name) == .orderedSame {
            child.refreshFromParent()
        }
    }

    enum FileViewError: Error, CustomStringConvertible, Equatable {
        case missing(String), unreadable(String)
        var description: String {
            switch self {
            case .missing(let p): return "\(p) does not exist"
            case .unreadable(let p): return "cannot read \(p) (no permission?)"
            }
        }
    }

    /// Bound on the files `Recursive=2` indexes (a whole disk would need gigabytes); the counts and size still cover
    /// every file.
    static let maxIndexed = 200_000

    /// Reads and sorts a folder (background queue).
    static func list(folder: String, options o: ParentOptions) -> Result<Listing, FileViewError> {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.missing(folder))
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey,
                                      .contentModificationDateKey, .creationDateKey, .contentAccessDateKey]
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        let wildcard = WildcardFilter(o.wildcard)
        var listing = Listing(folder: folder)

        func makeItem(_ u: URL, _ v: URLResourceValues?, followLinks: Bool) -> Item {
            var isDir = v?.isDirectory == true && v?.isSymbolicLink != true
            if followLinks, v?.isSymbolicLink == true {
                // A link to a folder (e.g. /Volumes/Macintosh HD) is listed as a folder one can open.
                var linkedDirectory: ObjCBool = false
                isDir = fm.fileExists(atPath: u.path, isDirectory: &linkedDirectory) && linkedDirectory.boolValue
            }
            return Item(name: u.lastPathComponent, path: isDir ? u.path + "/" : u.path, isFolder: isDir,
                        size: Double(v?.fileSize ?? 0), modified: v?.contentModificationDate, created: v?.creationDate,
                        accessed: v?.contentAccessDate)
        }
        /// nil → skip; the item passes the hidden / system / type filters.
        func accepted(_ u: URL, _ v: URLResourceValues?, followLinks: Bool = false) -> Item? {
            let name = u.lastPathComponent
            let system = MacSystemFiles.isSystem(name)
            let hidden = system || name.hasPrefix(".") || v?.isHidden == true
            if system && !o.showSystem { return nil }
            if hidden && !system && !o.showHidden { return nil }
            let item = makeItem(u, v, followLinks: followLinks)
            if !item.isFolder {
                if !o.extensions.isEmpty && !o.extensions.contains(item.ext.lowercased()) { return nil }
                if !wildcard.matches(name) { return nil }
            } else if o.wildcard != "*" && o.wildcard != "*.*" && !wildcard.matches(name) && o.recursive == 0 {
                return nil
            }
            return item
        }

        var files: [Item] = [], folders: [Item] = []
        guard let top = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: []) else {
            return .failure(.unreadable(folder))
        }
        for u in top {
            guard let item = accepted(u, try? u.resourceValues(forKeys: Set(keys)), followLinks: true) else { continue }
            if item.isFolder { folders.append(item) } else { files.append(item) }
        }
        listing.fileCount = files.count
        listing.folderCount = folders.count
        listing.folderSize = files.reduce(0) { $0 + $1.size }

        var treeFiles: [Item] = []
        if o.recursive > 0 {
            var fileCount = 0, folderCount = 0, size = 0.0, visited = 0
            if let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
                for case let u as URL in e {
                    visited += 1
                    if visited > PluginIO.maxEntries { break }
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    guard let item = accepted(u, v) else {
                        if v?.isDirectory == true { e.skipDescendants() }
                        continue
                    }
                    if item.isFolder {
                        folderCount += 1
                    } else {
                        fileCount += 1
                        size += item.size
                        if o.recursive == 2 && treeFiles.count < maxIndexed { treeFiles.append(item) }
                    }
                }
            }
            listing.fileCount = fileCount
            listing.folderCount = folderCount
            listing.folderSize = size
        }

        var items: [Item] = []
        if o.recursive == 2 {
            items = sorted(treeFiles, o)
        } else {
            if o.showDotDot, folder != "/" {
                let up = ((folder as NSString).deletingLastPathComponent as NSString).standardizingPath
                items.append(Item(name: "..", path: up.hasSuffix("/") ? up : up + "/", isFolder: true, isDotDot: true))
            }
            if o.showFolder { items += sorted(folders, o) }
            if o.showFile { items += sorted(files, o) }
        }
        listing.items = items
        return .success(listing)
    }

    static func sorted(_ items: [Item], _ o: ParentOptions) -> [Item] {
        let ordered = items.sorted { a, b in
            let byName = a.name.localizedStandardCompare(b.name)
            switch o.sortType {
            case "size":
                if a.size != b.size { return a.size < b.size }
            case "type":
                let t = a.ext.localizedCaseInsensitiveCompare(b.ext)
                if t != .orderedSame { return t == .orderedAscending }
            case "date":
                let da = a.date(o.sortDateType) ?? .distantPast, db = b.date(o.sortDateType) ?? .distantPast
                if da != db { return da < db }
            default:
                break
            }
            return byName == .orderedAscending
        }
        return o.sortAscending ? ordered : ordered.reversed()
    }

    private func parentFolder(of folder: String) -> String? {
        let trimmed = folder.hasSuffix("/") && folder.count > 1 ? String(folder.dropLast()) : folder
        guard trimmed != "/" && !trimmed.isEmpty else { return nil }
        let up = (trimmed as NSString).deletingLastPathComponent
        return folderPath(up.isEmpty ? "/" : up)
    }

    // MARK: Commands

    public override func execute(command: String) {
        let text = command.trimmingCharacters(in: .whitespaces)
        let lower = text.lowercased()
        let verb = lower.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let argument = text.count > verb.count ? String(text.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces) : ""
        if parentName != nil {
            switch verb {
            case "followpath": followPath()
            case "open": if let target = childTarget() { open(target) }
            case "contextmenu": if let target = childTarget() { reveal(target) }
            case "properties": if let target = childTarget() { showInfo(target) }
            default: super.execute(command: command)
            }
            return
        }
        let count = max(parentOptions.count, 1)
        let total = listing.items.count
        switch verb {
        case "update":
            if needsOptionRead { readOptionsIfNeeded() }
            // The manual's "!CommandMeasure … Update after changing options": `#Variables#` of Path are resolved again,
            // so `[!SetVariable Dir …][!CommandMeasure Parent Update]` works without DynamicVariables.
            if parentName == nil {
                pathOption = skin.resolveStandardVariables((rawOption("Path") ?? "").trimmingCharacters(in: .whitespaces),
                                                           in: self)
            }
            // A Path changed with !SetOption / !SetVariable is read; otherwise the folder navigated to is re-read.
            let configured = configuredFolder()
            if configured != configuredAtRead {
                configuredAtRead = configured
                offset = 0
                read(folder: configured)
            } else {
                read(folder: currentFolder ?? configured)
            }
        case "pageup":
            offset = max(0, offset - count)
            refreshChildren()
        case "pagedown":
            if offset + count < total { offset += count }
            refreshChildren()
        case "indexup":
            if offset > 0 { offset -= 1 }
            refreshChildren()
        case "indexdown":
            if offset + count < total { offset += 1 }
            refreshChildren()
        case "previousfolder":
            guard parentOptions.recursive != 2 else { return }
            let current = currentFolder ?? configuredFolder()
            guard let up = parentFolder(of: current) else { return }
            navigate(to: up)
        case "contextmenu":
            reveal(argument.isEmpty ? (currentFolder ?? configuredFolder()) : PluginPaths.resolve(argument, skin: skin))
        case "properties":
            showInfo(argument.isEmpty ? (currentFolder ?? configuredFolder()) : PluginPaths.resolve(argument, skin: skin))
        default:
            super.execute(command: command)
        }
    }

    private func navigate(to folder: String) {
        offset = 0
        read(folder: folderPath(folder))
    }

    private func childTarget() -> Item? {
        guard let parent, let item = item(in: parent) else { return nil }
        return item
    }

    private func followPath() {
        guard let parent, let item = item(in: parent) else { return }
        if item.isFolder {
            guard parent.parentOptions.recursive != 2 else { return }
            if item.isDotDot {
                parent.execute(command: "PreviousFolder")
            } else {
                parent.navigate(to: item.path)
            }
        } else {
            open(item)
        }
    }

    private func open(_ item: Item) {
        let path = item.isDotDot ? (parentFolder(of: parent?.listing.folder ?? "") ?? item.path) : item.path
        skin.host?.skin(skin, execute: path, arguments: [])
    }

    private func reveal(_ item: Item) { reveal(item.path) }
    private func showInfo(_ item: Item) { showInfo(item.path) }

    private func reveal(_ path: String) {
        PluginProcess.run("/usr/bin/open", ["-R", path])
    }

    private func showInfo(_ path: String) {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        PluginProcess.run("/usr/bin/osascript", ["-e", "tell application \"Finder\"",
                                                 "-e", "activate",
                                                 "-e", "open information window of (POSIX file \"\(escaped)\" as alias)",
                                                 "-e", "end tell"])
    }

    private func report(_ key: String, _ message: String) {
        guard reported.insert(key).inserted else { return }
        skin.log(message, level: .notice)
    }
}

/// Helper programs (`open`, `osascript`), started off the main thread; nothing waits for them.
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

    /// Starts a helper program without waiting for it.
    static func run(_ executable: String, _ arguments: [String]) {
        launcher(executable, arguments, nil)
    }

    /// Starts a helper program; `completion` gets its exit status on `executor` (the skin that asked), never inline.
    static func run(_ executable: String, _ arguments: [String], on executor: SkinExecutor,
                    completion: @escaping (Int32) -> Void) {
        launcher(executable, arguments) { status in executor.async { completion(status) } }
    }
}
