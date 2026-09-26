import AppKit
import CoreText
import DesksetCore

/// Fonts: Rainmeter sizes are points at 96 DPI; Windows font names are mapped to Mac equivalents.
///
/// `FontFace` is a family name (manual: String meter, Fonts guide). Resolution order for a face:
/// 1. an installed or registered family with that name (case-insensitive);
/// 2. the Windows → Mac substitution table (Segoe UI → system font, Consolas → Menlo, CJK fonts…);
/// 3. a full or PostScript font name ("Fira Sans Bold", "Arial-BoldMT"): its family, with its weight / italic as
///    the implied style ("Rainmeter will figure out the actual family name when the font is loaded");
/// 4. the same again after removing trailing style words ("Roboto Light Italic" → "Roboto", 300, italic);
/// 5. Arial ("Arial is now the default font when FontFace is not specified or errors occur").
///
/// Weight: `FontWeight` (1–999) or StringStyle Bold (700) picks the family member with the closest weight
/// (OS/2 usWeightClass); "If the font does not support any additional weights, then 500 and below will use the
/// font's normal weight, and 600 and above will simulate a bold effect" — simulated with a fill + stroke.
/// Italic / Oblique use an italic member when the family has one, otherwise a slanted (simulated) font.
///
/// Thread-safe (docs/skin-threading.md §4.4): skins measure and draw text on threads of their own.
/// - Resolution (`resolve`, the family lookups) is guarded by one lock, `lock`. `generation`, which every text layout
///   reads, even one it has already, has a lock of its own, so reading it never waits for another skin's miss.
/// - Registration and rescans run on a serial fonts queue, `queue`: at most one at a time, in order. Skins may wait for
///   it (a layout registers its skin's font folder the first time), and it never waits for a skin. Whether a folder
///   is registered already is answered without it (`folderLock`), so a skin whose fonts are in does not wait behind
///   another skin's registration.
/// - Registering or unregistering a font clears what resolution kept, in one step with the change; `generation` then
///   moves on, and `didChangeNotification` is posted on the main thread: the app lays out its skins again
///   (`AppController.fontsChanged`).
enum Fonts {
    /// Rainmeter FontSize → macOS point size.
    static let sizeScale = 96.0 / 72.0

    /// A font request. `size` is in skin points (pixels), i.e. already multiplied by `sizeScale`.
    struct Request: Hashable {
        var face: String
        var size: CGFloat
        /// Explicit `FontWeight` / inline `Weight`.
        var weight: Int?
        /// `StringStyle=Bold` (700 unless an explicit weight is given).
        var bold = false
        var italic = false
        var oblique = false
        /// Inline `Stretch` 1…9 (5 = normal).
        var stretch: Int?
        /// Inline `Typography` features (OpenType tag, value).
        var features: [Feature] = []
    }

    struct Feature: Hashable {
        var tag: String
        var value: Int
    }

    struct Resolved {
        let font: CTFont
        /// Draw with an additional stroke to simulate bold (the family has no heavy enough member).
        let syntheticBold: Bool
        /// Characters to replace before shaping (Marlett, which has no Mac equivalent).
        let characterMap: [UInt16: UInt16]?
        /// Horizontal shear for simulated italic / oblique (0 = upright). Applied by the renderer through the text
        /// matrix, because CTRunDraw ignores a font's own matrix.
        let slant: CGFloat
        /// Line metrics (pixels) of the Windows font this one stands in for, so that line heights — and every
        /// layout stacked with `Y=0R` — match the original skin. Nil when the font is used as is.
        let lineMetrics: LineMetrics?
    }

    struct LineMetrics: Hashable {
        var ascent: CGFloat
        var descent: CGFloat
        var leading: CGFloat
    }

    /// Shear of simulated italic / oblique text (about 11°).
    static let simulatedSlant: CGFloat = 0.2

    /// Incremented whenever the set of available fonts changes (layout caches key on it). Any thread; it never waits
    /// for a resolution under way.
    static var generation: Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return currentGeneration
    }

    /// Posted on the main thread, after the fact, whenever `generation` moves on: whoever registered the fonts (a skin
    /// loading, a layout reading its skin's font folder the first time, an installation, Refresh All), skins laid out
    /// before measured their text with a fallback font. Posted asynchronously, so that no skin is laid out again in the
    /// middle of the layout that registered the fonts.
    static let didChangeNotification = Notification.Name("DesksetFontsDidChange")

    /// Guards what resolution keeps (`cache`, `faceCache`, `memberCache`, `familyIndex`). A miss is resolved with the
    /// lock held, and the fonts queue holds it while it registers or unregisters fonts with Core Text and clears the
    /// caches in the same step (`changingFonts`): a resolution sees the fonts either before or after a change, never
    /// half of each, and nothing resolved before a change is kept after it. Misses are rare (every skin keeps its
    /// layouts, `TextLayoutCache`), and so are registrations. Nothing waits for anything else while holding it, apart
    /// from Core Text's registration and `generationLock`, a leaf.
    ///
    /// The AppKit lookups of resolution (`NSFont(name:size:)`, the system font) are kept under it rather than replaced
    /// with Core Text's: `CTFontCreateWithName` falls back to Helvetica for an unknown name, matches PostScript names
    /// in any case and picks another default member of some families, and a system font built from traits snaps
    /// weights and widths differently, so skins would get other fonts. Main Thread Checker reports nothing for them.
    private static let lock = NSLock()
    /// Guards `currentGeneration`, which moves on while `lock` is held (a leaf: taken inside `lock`, never around it).
    private static let generationLock = NSLock()
    private static var currentGeneration = 0
    private static var cache: [Request: Resolved] = [:]
    private static var faceCache: [String: FaceMatch] = [:]
    private static var memberCache: [String: [Member]] = [:]
    private static var familyIndex: [String: String]?

    /// The serial fonts queue: registration and rescans, one at a time. `registered` and `copyCounter` are touched
    /// only on it; `registeredFolders` is changed on it, under `folderLock`, and so is `missingFolders`, apart from a
    /// missing folder found missing again (`noteStillMissing`).
    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "app.deskset.fonts")
        queue.setSpecific(key: onFontsQueue, value: true)
        return queue
    }()
    private static let onFontsQueue = DispatchSpecificKey<Bool>()
    /// Guards `registeredFolders` and `missingFolders`, so that `registerFolder` can tell a folder already read without
    /// waiting for the queue. A leaf lock.
    private static let folderLock = NSLock()

    /// A registered font file.
    private struct Registration {
        /// Modification date of the file when it was registered (a replaced file is registered again).
        var modified: Date
        /// The private copy registered with Core Text (nil when registration failed). Core Text can only unregister
        /// a file that still exists with the content it registered, and skin fonts get replaced or deleted under it
        /// (an installation moves the old root config to Backups, a user edits @Resources/Fonts): so the copy is
        /// what is registered, and it is unregistered and removed when the original changes or goes away.
        var copy: URL?
    }

    /// Registered font files (original paths) → their registration.
    private static var registered: [String: Registration] = [:]
    /// `@Resources/Fonts` folders read at least once (they exist; `rescanFolder` reads them again).
    private static var registeredFolders: Set<String> = []
    /// Folders that did not exist when last looked for, with the time (system uptime) of that look. They are looked
    /// for again after `missingFolderRecheck` seconds — a skin installed or a folder created later gets its fonts —
    /// and at once by `rescanFolder` (skin load / refresh, installation, Refresh All).
    private static var missingFolders: [String: TimeInterval] = [:]
    static let missingFolderRecheck: TimeInterval = 5
    /// Font file extensions loaded from `@Resources/Fonts` (TrueType, OpenType and their collections).
    static let fontFileExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]

    // MARK: Registration

    /// Runs `body` on the fonts queue and waits for it (at once when already there).
    private static func onQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: onFontsQueue) == true { return body() }
        return queue.sync(execute: body)
    }

    /// Registers font files for this process (`LocalFont…` options, `@Resources/Fonts`). A file registered before is
    /// skipped unless it changed on disk since then (it is then registered again, so an edited font shows up). The
    /// same font in two skins is registered from both files (Core Text accepts that; unregistering one copy leaves
    /// the other). Any thread; it waits for the fonts queue.
    static func registerLocalFonts(_ paths: [String]) {
        onQueue { registerFiles(paths) }
    }

    /// `registerLocalFonts`. Runs on the fonts queue.
    private static func registerFiles(_ paths: [String]) {
        var changed = false
        for path in paths {
            let modified = modificationDate(path)
            if let known = registered[path] {
                guard let modified else { continue }
                guard modified != known.modified else {
                    restoreCopyIfMissing(known, of: path)
                    continue
                }
                if unregister(known) { changed = true }
            }
            // Recorded even when registration fails, so a broken file is not retried on every layout.
            var registration = Registration(modified: modified ?? .distantPast, copy: nil)
            if let copy = privateCopy(of: path) {
                var error: Unmanaged<CFError>?
                if changingFonts({ CTFontManagerRegisterFontsForURL(copy as CFURL, .process, &error) }) {
                    registration.copy = copy
                    changed = true
                } else {
                    try? FileManager.default.removeItem(at: copy)
                    let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
                    // 105 already registered, 305 duplicated name (the same font in two skins).
                    if code != 105 && code != 305 { Log.write("Could not register font \(path)", level: .warning) }
                }
            }
            registered[path] = registration
        }
        if changed { invalidate() }
    }

    /// Unregisters a registration's copy and deletes it; true when something was registered. Runs on the fonts queue.
    @discardableResult
    private static func unregister(_ registration: Registration) -> Bool {
        guard let copy = registration.copy else { return false }
        changingFonts { _ = CTFontManagerUnregisterFontsForURL(copy as CFURL, .process, nil) }
        try? FileManager.default.removeItem(at: copy)
        return true
    }

    /// Registers or unregisters fonts with Core Text (`body`) and forgets what resolution kept, in one step under
    /// `lock`. A resolution that overlapped the change would put together fonts from before it and after it (the
    /// family list read before a skin's font went away, the family's members after: the system font rather than the
    /// skin's font or the fallback). `generation` moves on once the whole batch is done (`invalidate`). Runs on the
    /// fonts queue.
    private static func changingFonts<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        let result = body()
        forgetResolutions()
        return result
    }

    /// A registered copy deleted behind Deskset's back (a cleaning utility emptied the caches) is made again from the
    /// unchanged original, so Core Text can still read the font and unregister it later. When that fails, the copy is
    /// forgotten (logged once; nothing more can be done for it until the app restarts). Runs on the fonts queue.
    private static func restoreCopyIfMissing(_ registration: Registration, of path: String) {
        guard let copy = registration.copy, !FileManager.default.fileExists(atPath: copy.path) else { return }
        do {
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
        } catch {
            registered[path]?.copy = nil
            Log.write("Could not restore the copy of font \(path): \(error.localizedDescription)", level: .warning)
        }
    }

    /// Where the per-process copy folders live. In the app: `~/Library/Caches/Deskset/Fonts`, not the temporary
    /// folder — macOS deletes files older than three days from it every night, and a copy keeps the original's
    /// dates, so the copy of an old font would disappear during the first night the app runs (Core Text could then
    /// neither read it again nor unregister it). Command-line runs and self-tests use the temporary folder.
    static func copiesBase(appBundle: Bool = Paths.isAppBundle) -> URL {
        let fm = FileManager.default
        if appBundle, let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return caches.appendingPathComponent("Deskset/Fonts", isDirectory: true)
        }
        return fm.temporaryDirectory.appendingPathComponent("Deskset Fonts", isDirectory: true)
    }

    /// Folder of this process's font copies (under `copiesBase`; folders of processes that no longer run are removed
    /// the first time it is needed).
    private static let copiesFolder: URL? = {
        let fm = FileManager.default
        let base = copiesBase()
        for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
            guard let pid = Int32(name), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? fm.removeItem(at: base.appendingPathComponent(name))
        }
        let folder = base.appendingPathComponent(String(getpid()), isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            Log.write("Cannot create a folder for skin fonts: \(error.localizedDescription)", level: .warning)
            return nil
        }
    }()
    private static var copyCounter = 0

    /// Deletes this process's font copies (the app quits; command-line runs leave them to the next start).
    static func removePrivateCopies() {
        onQueue {
            guard copyCounter > 0, let folder = copiesFolder else { return }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// A copy of the font file to register (a clone on APFS: no extra space), nil when it cannot be made. It is named
    /// by a counter and the original's extension (a long original name plus a prefix could exceed 255 bytes). Runs on
    /// the fonts queue.
    private static func privateCopy(of path: String) -> URL? {
        guard let folder = copiesFolder else { return nil }
        copyCounter += 1
        let ext = (path as NSString).pathExtension.lowercased()
        let name = "\(copyCounter)" + (ext.isEmpty || ext.utf8.count > 8 ? "" : "." + ext)
        let copy = folder.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
            return copy
        } catch {
            return nil
        }
    }

    private static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Registers a skin's fonts: `LocalFont…` options and every .ttf / .otf / .ttc / .otc file in the root config's
    /// `@Resources/Fonts` folder ("automatically loaded and can be used with the FontFace option"). The folder is
    /// read again every time (the app calls this whenever a skin is loaded or refreshed), so fonts added to it or
    /// replaced since the last load are picked up by a refresh. Call it where the skin is owned (it reads the skin's
    /// settings); it waits for the fonts queue. True when this changed the fonts (`generation` moved on).
    @discardableResult
    static func registerFonts(for skin: Skin) -> Bool {
        let files = skin.settings.localFonts
        let folder = skin.resourcesDirectory.appendingPathComponent("Fonts", isDirectory: true).path
        return onQueue {
            let before = generation
            registerFiles(files)
            if !folder.isEmpty { _ = rescan(folder) }
            return generation != before
        }
    }

    /// Registers the fonts in a `@Resources/Fonts` folder once (cheap to call for every layout — `TextLayoutCache`
    /// does, from `TextStyle.fontFolder`). A missing folder is looked for again after `missingFolderRecheck`
    /// seconds, not remembered for good. Any thread: a folder already read, or still missing, is answered without the
    /// fonts queue; otherwise the caller waits for the queue, and returns once the folder's fonts are registered.
    static func registerFolder(_ folder: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !folder.isEmpty, needsReading(folder, now: now) else { return }
        // Most skins have no font folder and look for it again every few seconds: a folder still missing is noted
        // without the queue, so a layout never waits behind another skin's registration or a rescan just to learn that.
        guard FileManager.default.fileExists(atPath: folder) else { return noteStillMissing(folder, now: now) }
        onQueue {
            // Another skin may have read it while this one waited for the queue.
            guard needsReading(folder, now: now) else { return }
            guard let files = fontFiles(in: folder) else {
                noteMissing(folder, now: now)
                return
            }
            registerFiles(files)
            // Only now: a skin that finds the folder read must also find its fonts registered.
            noteRead(folder)
        }
    }

    /// Whether `registerFolder` has to read `folder`: it was not read yet, and was not found missing in the last
    /// `missingFolderRecheck` seconds.
    private static func needsReading(_ folder: String, now: TimeInterval) -> Bool {
        folderLock.lock()
        defer { folderLock.unlock() }
        if registeredFolders.contains(folder) { return false }
        if let checked = missingFolders[folder], now - checked < missingFolderRecheck { return false }
        return true
    }

    /// Runs on the fonts queue.
    private static func noteRead(_ folder: String) {
        folderLock.lock()
        missingFolders[folder] = nil
        registeredFolders.insert(folder)
        folderLock.unlock()
    }

    /// Off the fonts queue: `registerFolder` did not find `folder`. A folder the queue has read meanwhile stays read.
    private static func noteStillMissing(_ folder: String, now: TimeInterval) {
        folderLock.lock()
        defer { folderLock.unlock() }
        guard !registeredFolders.contains(folder) else { return }
        if missingFolders.count >= 1024 { missingFolders.removeAll() }
        missingFolders[folder] = now
    }

    /// Runs on the fonts queue.
    private static func noteMissing(_ folder: String, now: TimeInterval) {
        folderLock.lock()
        registeredFolders.remove(folder)
        // Bounded: skins can name many folders over a long session.
        if missingFolders.count >= 1024 { missingFolders.removeAll() }
        missingFolders[folder] = now
        folderLock.unlock()
    }

    /// Reads a `@Resources/Fonts` folder again: fonts added or replaced since the last scan are registered, fonts
    /// whose file was removed (or whose folder is gone) are unregistered. Returns true when the set of fonts changed
    /// (`generation` moved on; skins already laid out should then be laid out again, see `Skin.fontsDidChange()`).
    /// Any thread; it waits for the fonts queue.
    @discardableResult
    static func rescanFolder(_ folder: String) -> Bool {
        guard !folder.isEmpty else { return false }
        return onQueue { rescan(folder) }
    }

    /// `rescanFolder`. Runs on the fonts queue.
    private static func rescan(_ folder: String) -> Bool {
        let before = generation
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        var removed = false
        for (path, registration) in registered
        where path.hasPrefix(prefix) && !FileManager.default.fileExists(atPath: path) {
            if unregister(registration) { removed = true }
            registered[path] = nil
        }
        if let files = fontFiles(in: folder) {
            registerFiles(files)
            noteRead(folder)
        } else {
            noteMissing(folder, now: ProcessInfo.processInfo.systemUptime)
        }
        if removed && generation == before { invalidate() }
        return generation != before
    }

    /// `rescanFolder` for several folders, in one go on the fonts queue; true when any of them changed the fonts.
    @discardableResult
    static func rescanFolders(_ folders: [String]) -> Bool {
        onQueue {
            var changed = false
            for folder in Set(folders) where !folder.isEmpty && rescan(folder) { changed = true }
            return changed
        }
    }

    /// Refresh All: every font folder seen so far is read again, and folders that were missing are looked for again
    /// the next time a skin uses them.
    @discardableResult
    static func rescanAllFolders() -> Bool {
        onQueue {
            folderLock.lock()
            let known = registeredFolders
            missingFolders.removeAll()
            folderLock.unlock()
            var changed = false
            for folder in known where rescan(folder) { changed = true }
            return changed
        }
    }

    /// Font files in a folder (sorted, at most 256), or nil when the folder cannot be read (missing).
    static func fontFiles(in folder: String) -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return nil }
        return names.sorted()
            .filter { !$0.hasPrefix(".") && fontFileExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .prefix(256)
            .map { (folder as NSString).appendingPathComponent($0) }
    }

    /// Whether `folder` is known to be missing right now (tests).
    static func isRememberedAsMissing(_ folder: String) -> Bool {
        folderLock.lock()
        defer { folderLock.unlock() }
        return missingFolders[folder] != nil
    }

    /// Runs `body` on the fonts queue and waits for it, as a registration does (tests hold the queue with it).
    static func runOnQueue(_ body: () -> Void) { onQueue(body) }

    /// The private copy registered for the font file at `path`, nil when none is (tests).
    static func registeredCopy(ofFile path: String) -> URL? { onQueue { registered[path]?.copy } }

    /// Forgets what resolution kept (again: every change already did) and moves `generation` on, then tells the app
    /// (`didChangeNotification`). Runs on the fonts queue, once Core Text has the new set of fonts.
    private static func invalidate() {
        lock.lock()
        forgetResolutions()
        generationLock.lock()
        currentGeneration += 1
        generationLock.unlock()
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChangeNotification, object: nil) }
    }

    /// Call with `lock` held.
    private static func forgetResolutions() {
        cache.removeAll()
        faceCache.removeAll()
        memberCache.removeAll()
        familyIndex = nil
    }

    // MARK: Resolution

    /// The base font of a String meter (compatibility helper).
    static func font(for style: TextStyle) -> NSFont {
        resolve(request(for: style)).font as NSFont
    }

    static func request(for style: TextStyle) -> Request {
        Request(face: style.fontFace, size: CGFloat(max(TextStyle.pixelSize(points: style.fontSize), 0.01)),
                weight: style.fontWeight, bold: style.bold, italic: style.italic)
    }

    /// The font for `request`, cached until the fonts change. Any thread.
    static func resolve(_ request: Request) -> Resolved {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[request] { return hit }
        if cache.count > 512 { cache.removeAll() }
        let match = faceMatch(request.face)
        let weight = request.weight ?? (request.bold ? 700 : match.weight ?? 400)
        let italic = request.italic || match.italic
        let size = min(max(request.size, 0.01), 4000)

        var font: CTFont
        var syntheticBold = false
        var slant = false
        if let family = match.family, let chosen = bestMember(family, weight: weight, italic: italic || request.oblique,
                                                             oblique: request.oblique, stretch: request.stretch) {
            font = CTFontCreateWithFontDescriptor(chosen.member.descriptor, size, nil)
            syntheticBold = weight >= 600 && chosen.member.weight < 600
            slant = chosen.needsSlant
        } else {
            font = systemFont(size: size, weight: weight, italic: italic && !request.oblique, stretch: request.stretch)
            slant = request.oblique || (italic && !CTFontGetSymbolicTraits(font).contains(.traitItalic))
        }
        if !request.features.isEmpty {
            let settings = request.features.map {
                [kCTFontOpenTypeFeatureTag: $0.tag, kCTFontOpenTypeFeatureValue: $0.value] as [CFString: Any]
            }
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: settings] as CFDictionary)
            font = CTFontCreateCopyWithAttributes(font, size, nil, descriptor)
        }
        let metrics = match.emMetrics.map {
            LineMetrics(ascent: $0.ascent * size, descent: $0.descent * size, leading: $0.leading * size)
        }
        let resolved = Resolved(font: font, syntheticBold: syntheticBold, characterMap: match.characterMap,
                                slant: slant ? simulatedSlant : 0, lineMetrics: metrics)
        cache[request] = resolved
        return resolved
    }

    // MARK: Face names

    private struct FaceMatch {
        /// Actual family name; nil = the system font.
        var family: String?
        var weight: Int?
        var italic = false
        var characterMap: [UInt16: UInt16]?
        /// Vertical metrics in em of the substituted Windows font.
        var emMetrics: LineMetrics?
    }

    /// Call with `lock` held (so for everything below that keeps or reads what resolution keeps).
    private static func faceMatch(_ face: String) -> FaceMatch {
        let key = face.lowercased()
        if let hit = faceCache[key] { return hit }
        let result = computeFaceMatch(face)
        if faceCache.count > 512 { faceCache.removeAll() }
        faceCache[key] = result
        return result
    }

    private static func computeFaceMatch(_ face: String) -> FaceMatch {
        var words = face.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var impliedWeight: Int?
        var impliedItalic = false
        for _ in 0..<4 {
            guard !words.isEmpty else { break }
            let name = words.joined(separator: " ")
            let lower = name.lowercased()
            if let family = installedFamily(lower) {
                return FaceMatch(family: family, weight: impliedWeight, italic: impliedItalic)
            }
            if let sub = substitutes[lower] {
                var match = FaceMatch(family: nil, weight: impliedWeight ?? sub.weight, italic: impliedItalic,
                                      characterMap: sub.characterMap, emMetrics: sub.emMetrics)
                if let target = sub.family { match.family = installedFamily(target.lowercased()) }
                return match
            }
            if let font = NSFont(name: name, size: 12), let family = font.familyName {
                let ct = font as CTFont
                let italic = CTFontGetSymbolicTraits(ct).contains(.traitItalic)
                let weight = impliedWeight ?? os2(ct)?.weight
                return FaceMatch(family: family.hasPrefix(".") ? nil : family, weight: weight,
                                 italic: impliedItalic || italic)
            }
            // Strip trailing style words ("Semibold", "Extra Light", "Italic"…) and try again.
            guard let (count, weight, italic) = styleSuffix(words) else { break }
            words.removeLast(count)
            if let weight, impliedWeight == nil { impliedWeight = weight }
            if italic { impliedItalic = true }
        }
        return FaceMatch(family: installedFamily("arial"), weight: impliedWeight, italic: impliedItalic)
    }

    /// The installed family called `name` (in any case), spelled as the font system spells it; nil when no such family
    /// is installed (hidden families, whose names start with a dot, count as not installed).
    static func installedFamily(named name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return installedFamily(name.lowercased())
    }

    /// The installed families (hidden ones left out), in no particular order.
    static var installedFamilyNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        _ = installedFamily("")
        return familyIndex.map { Array($0.values) } ?? []
    }

    /// Call with `lock` held.
    private static func installedFamily(_ lowercased: String) -> String? {
        if familyIndex == nil {
            var index: [String: String] = [:]
            let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
            for name in names where !name.hasPrefix(".") { index[name.lowercased()] = name }
            familyIndex = index
        }
        return familyIndex?[lowercased]
    }

    private static let styleWords: [String: (weight: Int?, italic: Bool)] = [
        "thin": (100, false), "hairline": (100, false), "extralight": (200, false), "ultralight": (200, false),
        "light": (300, false), "semilight": (350, false), "demilight": (350, false), "regular": (400, false),
        "normal": (400, false), "book": (400, false), "medium": (500, false), "semibold": (600, false),
        "demibold": (600, false), "bold": (700, false), "extrabold": (800, false), "ultrabold": (800, false),
        "heavy": (900, false), "black": (900, false), "extrablack": (950, false), "ultrablack": (950, false),
        "italic": (nil, true), "oblique": (nil, true),
    ]

    /// Trailing style words: (number of words, weight, italic).
    private static func styleSuffix(_ words: [String]) -> (Int, Int?, Bool)? {
        guard words.count >= 2 else { return nil }
        if words.count >= 3 {
            let two = (words[words.count - 2] + words[words.count - 1]).lowercased()
            if let style = styleWords[two] { return (2, style.weight, style.italic) }
        }
        if let style = styleWords[words[words.count - 1].lowercased()] { return (1, style.weight, style.italic) }
        return nil
    }

    /// How a FontFace name is shown on the Mac, for the editor: nil when no substitution applies (an installed
    /// family, or an unknown name); otherwise the family used instead, "System Font" for the system font.
    static func substitution(for name: String) -> String? {
        guard let sub = substitutes[name.trimmingCharacters(in: .whitespaces).lowercased()] else { return nil }
        return sub.family ?? "System Font"
    }

    private struct Substitute {
        /// Mac family; nil = the system font.
        var family: String?
        var weight: Int?
        var characterMap: [UInt16: UInt16]?
        var emMetrics: LineMetrics?
    }

    /// Segoe UI's published vertical metrics (2048 units per em: ascent 2210, descent 514, line gap 0).
    private static let segoeMetrics = LineMetrics(ascent: 2210.0 / 2048, descent: 514.0 / 2048, leading: 0)

    /// Windows fonts that macOS does not ship (fonts that macOS does ship, such as Arial, Tahoma, Verdana,
    /// Trebuchet MS, Courier New, Georgia, Impact, Webdings and Wingdings, are used directly).
    private static let substitutes: [String: Substitute] = {
        var t: [String: Substitute] = [:]
        func add(_ names: [String], _ family: String?, weight: Int? = nil, metrics: LineMetrics? = nil) {
            for n in names { t[n] = Substitute(family: family, weight: weight, emMetrics: metrics) }
        }
        // Segoe UI family (GDI names include the weight) → San Francisco, keeping Segoe UI's line height.
        add(["segoe ui", "segoe ui variable", "segoe ui variable display", "segoe ui variable text",
             "segoe ui variable small", "segoe", "selawik"], nil, metrics: segoeMetrics)
        add(["segoe ui historic", "segoe ui symbol", "segoe mdl2 assets", "segoe fluent icons"], nil)
        // Names Mac skin authors use for the system font.
        add(["system font", "system-ui", "-apple-system", "san francisco", "sf pro", "sf pro text",
             "sf pro display", "sf pro rounded", ".sf ns"], nil)
        add(["segoe ui light", "segoe ui variable light"], nil, weight: 300, metrics: segoeMetrics)
        add(["segoe ui semilight", "segoe ui variable semilight"], nil, weight: 350, metrics: segoeMetrics)
        add(["segoe ui semibold", "segoe ui variable semibold"], nil, weight: 600, metrics: segoeMetrics)
        add(["segoe ui bold"], nil, weight: 700, metrics: segoeMetrics)
        add(["segoe ui black"], nil, weight: 900, metrics: segoeMetrics)
        add(["segoe ui emoji"], "Apple Color Emoji")
        add(["segoe print", "mv boli"], "Chalkboard SE")
        add(["segoe script", "ink free"], "Bradley Hand")
        add(["gabriola"], "Snell Roundhand")
        // ClearType collection and other Office / Windows fonts.
        add(["calibri", "candara", "corbel", "microsoft sans serif", "ms sans serif", "ms shell dlg",
             "ms shell dlg 2", "arial nova", "leelawadee ui", "nirmala ui", "ebrima", "gadugi", "sylfaen",
             "javanese text", "myanmar text", "mongolian baiti", "microsoft yi baiti", "microsoft tai le",
             "microsoft new tai lue", "microsoft phagspa", "microsoft himalaya"], nil)
        t["microsoft sans serif"] = Substitute(family: "Microsoft Sans Serif")
        t["ms sans serif"] = Substitute(family: "Microsoft Sans Serif")
        t["arial nova"] = Substitute(family: "Arial")
        add(["calibri light"], nil, weight: 300)
        add(["cambria", "cambria math", "constantia", "sitka", "sitka text", "sitka display", "sitka small",
             "sitka heading", "sitka subheading", "sitka banner", "georgia pro"], "Georgia")
        add(["consolas", "lucida console", "lucida sans typewriter", "cascadia code", "cascadia mono",
             "fixedsys", "terminal", "courier"], "Menlo")
        add(["lucida sans unicode", "lucida sans"], "Lucida Grande")
        add(["tahoma"], "Verdana")
        add(["verdana pro"], "Verdana")
        add(["trebuchet"], "Trebuchet MS")
        add(["ms serif", "times"], "Times New Roman")
        add(["century gothic"], "Futura")
        add(["franklin gothic medium", "franklin gothic"], "Avenir Next", weight: 500)
        add(["franklin gothic book"], "Avenir Next")
        add(["bahnschrift"], "DIN Alternate")
        add(["palatino linotype", "book antiqua"], "Palatino")
        add(["garamond"], "Baskerville")
        add(["gill sans nova"], "Gill Sans")
        add(["arial unicode ms"], "Arial")
        // CJK Windows fonts (Latin and native names).
        add(["microsoft yahei", "microsoft yahei ui", "微软雅黑", "dengxian", "等线"], "PingFang SC")
        add(["microsoft jhenghei", "microsoft jhenghei ui", "微軟正黑體"], "PingFang TC")
        add(["simsun", "nsimsun", "simsun-extb", "宋体", "新宋体"], "Songti SC")
        add(["simhei", "黑体"], "Heiti SC")
        add(["kaiti", "kaiti_gb2312", "楷体"], "Kaiti SC")
        add(["fangsong", "fangsong_gb2312", "仿宋"], "STFangsong")
        add(["mingliu", "pmingliu", "mingliu_hkscs", "細明體", "新細明體"], "Songti TC")
        add(["dfkai-sb", "標楷體"], "Kaiti TC")
        add(["meiryo", "meiryo ui", "yu gothic", "yu gothic ui", "ms gothic", "ms pgothic", "ms ui gothic",
             "メイリオ", "游ゴシック", "ｍｓ ゴシック", "ｍｓ ｐゴシック"], "Hiragino Sans")
        add(["ms mincho", "ms pmincho", "yu mincho", "游明朝", "ｍｓ 明朝"], "Hiragino Mincho ProN")
        add(["malgun gothic", "맑은 고딕", "gulim", "굴림", "dotum", "돋움", "gulimche", "dotumche"],
            "Apple SD Gothic Neo")
        add(["batang", "바탕", "batangche", "gungsuh", "궁서"], "AppleMyungjo")
        // Marlett (window-control glyphs) has no Mac equivalent: map its common letters to Unicode symbols.
        let marlett: [Character: Character] = [
            "0": "\u{2581}", "1": "\u{25A1}", "2": "\u{2750}", "r": "\u{2715}",
            "3": "\u{25C0}", "4": "\u{25B6}", "5": "\u{25B2}", "6": "\u{25BC}", "a": "\u{2713}",
        ]
        var map: [UInt16: UInt16] = [:]
        for (k, v) in marlett {
            if let a = k.utf16.first, let b = v.utf16.first { map[a] = b }
        }
        t["marlett"] = Substitute(family: nil, characterMap: map)
        return t
    }()

    // MARK: Family members

    private struct Member {
        var descriptor: CTFontDescriptor
        var weight: Int
        var width: Int
        var italic: Bool
        var oblique: Bool
    }

    /// Call with `lock` held.
    private static func members(_ family: String) -> [Member] {
        if let hit = memberCache[family] { return hit }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let collection = CTFontCollectionCreateWithFontDescriptors([descriptor] as CFArray, nil)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        var result: [Member] = []
        for d in descriptors.prefix(200) {
            let font = CTFontCreateWithFontDescriptor(d, 12, nil)
            let traits = CTFontGetSymbolicTraits(font)
            let style = (CTFontDescriptorCopyAttribute(d, kCTFontStyleNameAttribute) as? String ?? "").lowercased()
            // Named instances of a variable font share one OS/2 table; their traits carry the real weight.
            let variable = CTFontCopyVariationAxes(font) != nil
            let metrics = variable ? nil : os2(font)
            result.append(Member(descriptor: d, weight: metrics?.weight ?? cssWeight(traitsOf: font),
                                 width: metrics?.width ?? 5, italic: traits.contains(.traitItalic),
                                 oblique: style.contains("oblique")))
        }
        memberCache[family] = result
        return result
    }

    /// Picks the member closest to the request; `needsSlant` when italic was asked for but no italic member exists.
    private static func bestMember(_ family: String, weight: Int, italic: Bool, oblique: Bool,
                                   stretch: Int?) -> (member: Member, needsSlant: Bool)? {
        var candidates = members(family)
        guard !candidates.isEmpty else { return nil }
        let wantedWidth = stretch ?? 5
        if let best = candidates.map({ abs($0.width - wantedWidth) }).min() {
            candidates = candidates.filter { abs($0.width - wantedWidth) == best }
        }
        var needsSlant = false
        if oblique {
            let obliques = candidates.filter(\.oblique)
            if !obliques.isEmpty {
                candidates = obliques
            } else {
                candidates = candidates.filter { !$0.italic }.isEmpty ? candidates : candidates.filter { !$0.italic }
                needsSlant = true
            }
        } else if italic {
            let italics = candidates.filter(\.italic)
            if italics.isEmpty { needsSlant = true } else { candidates = italics }
        } else {
            let uprights = candidates.filter { !$0.italic }
            if !uprights.isEmpty { candidates = uprights }
        }
        let heavierFirst = weight >= 500
        let chosen = candidates.min { a, b in
            let da = abs(a.weight - weight), db = abs(b.weight - weight)
            if da != db { return da < db }
            return heavierFirst ? a.weight > b.weight : a.weight < b.weight
        }
        return chosen.map { ($0, needsSlant) }
    }

    /// Call with `lock` held (see `lock` for why these stay AppKit calls).
    private static func systemFont(size: CGFloat, weight: Int, italic: Bool, stretch: Int?) -> CTFont {
        let w = NSFont.Weight(rawValue: nsWeight(css: weight))
        var font: NSFont
        if let stretch, stretch != 5 {
            let width: NSFont.Width
            switch stretch {
            case ...2: width = .compressed
            case 3...4: width = .condensed
            default: width = .expanded
            }
            font = NSFont.systemFont(ofSize: size, weight: w, width: width)
        } else {
            font = NSFont.systemFont(ofSize: size, weight: w)
        }
        if italic {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        return font as CTFont
    }

    /// CSS-style weight (100…950) → NSFont.Weight / kCTFontWeightTrait, piecewise linear.
    private static let weightTable: [(css: Double, trait: Double)] = [
        (100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56),
        (900, 0.62), (1000, 0.7),
    ]

    static func nsWeight(css: Int) -> CGFloat {
        let v = Double(min(max(css, 1), 999))
        guard let first = weightTable.first, v > first.css else { return CGFloat(weightTable[0].trait) }
        for (a, b) in zip(weightTable, weightTable.dropFirst()) where v <= b.css {
            return CGFloat(a.trait + (b.trait - a.trait) * (v - a.css) / (b.css - a.css))
        }
        return CGFloat(weightTable[weightTable.count - 1].trait)
    }

    private static func cssWeight(traitsOf font: CTFont) -> Int {
        let traits = CTFontCopyTraits(font) as? [CFString: Any]
        let trait = (traits?[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        for (a, b) in zip(weightTable, weightTable.dropFirst()) where trait <= b.trait {
            let t = (trait - a.trait) / max(b.trait - a.trait, 0.0001)
            return Int((a.css + (b.css - a.css) * min(max(t, 0), 1)).rounded())
        }
        return 900
    }

    /// OS/2 usWeightClass (1…1000) and usWidthClass (1…9).
    private static func os2(_ font: CTFont) -> (weight: Int, width: Int)? {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, table.count >= 8
        else { return nil }
        let bytes = [UInt8](table.prefix(8))
        let weight = Int(bytes[4]) << 8 | Int(bytes[5])
        let width = Int(bytes[6]) << 8 | Int(bytes[7])
        guard (1...1000).contains(weight) else { return nil }
        return (weight, (1...9).contains(width) ? width : 5)
    }
}
