import Foundation

// Clean-room implementation from the public manual only:
//   https://docs.rainmeter.net/manual/measures/webparser/
//   https://docs.rainmeter.net/tips/webparser-updaterate/
//   https://docs.rainmeter.net/tips/webparser-using-stringindex2/
//   https://docs.rainmeter.net/tips/webparser-lookahead-assertions-in-regexp/
//   https://docs.rainmeter.net/tips/webparser-tutorial/ and /tips/rss-feed-tutorial/
//   https://docs.rainmeter.net/manual/measures/ (values; WebParser MinValue/MaxValue are dynamic)
//   https://docs.rainmeter.net/manual/measures/general-options/ (OnChangeAction and background measures)
//
// Model:
// - A "parent" measure has its own URL (http, https, file). It counts its updates: on the update where its counter is
//   0 it fetches the resource, then the counter goes 1, 2, … and wraps to 0 when it reaches UpdateRate (default 600),
//   so it fetches every UpdateRate updates (Update × UpdateDivider × UpdateRate ms). `!UpdateMeasure` only advances
//   the counter; `!CommandMeasure Parent "Update"` fetches right away and restarts the cycle.
// - Fetching, decoding and RegExp parsing run off the skin's thread; nothing ever blocks Skin.update. The results are
//   applied on the skin's executor (`Skin.hop()`), to the parent and all its child measures, and only then are the
//   actions run (FinishAction, OnRegExpErrorAction, OnConnectErrorAction, OnDownloadErrorAction).
// - Unloading or refreshing the skin (`skinWillClose`) cancels the transfers in flight; a result that arrives after
//   that is dropped: no values, log lines, actions or child downloads. A temporary download it saved is deleted, also
//   when the skin itself is gone by then. A skin dropped without being closed cancels them as its measures go.
// - "Child" measures (`URL=[Parent]`) do nothing on their own; the parent sets their values after each parse. A child
//   with `Download=1` then downloads its value and runs its own FinishAction / OnDownloadErrorAction.
// - A disabled or paused child still gets its values when the parent parses and shows them at its first update once
//   it runs again ("The values of child WebParser measures are a function of the parent measure, and are only updated
//   when the parent is"). A skin may enable the child in the parent's FinishAction (Monstercat Visualizer's update
//   checker does); the child must then show what the parent just parsed, not wait a whole UpdateRate for the next read.
// - Values are remembered: a failed connection or parse keeps the last good values ("only replaced when new
//   information is successfully received"); `!CommandMeasure Parent "Reset"` empties the parent and its children.
// - The string value is the parsed text; the number value is its leading number (see WebParserText.leadingNumber).
//   MinValue/MaxValue default to the smallest/largest number value seen since the skin was loaded (manual: Measures).

/// `Measure=WebParser`: reads a web page or local file and parses it with a Perl-compatible regular expression.
public final class WebParserMeasure: Measure, PluginLifecycle {
    private(set) var options = WebParserOptions()
    /// Parent WebParser measure named in `URL`, or nil for a measure that fetches its own URL.
    public private(set) var parentName: String?

    private var resultString = ""
    private var resultNumber = 0.0
    /// This measure's RegExp captures (index 0 = whole match), read by its child measures.
    public private(set) var captures: [String] = []
    private var substringCount = 0

    private var updateCounter = 0
    private var fetchGeneration = 0
    private var fetchInFlight = false
    /// The transfers in flight (tests check that unloading the skin cancels them).
    private(set) var fetchHandle: WebParserFetchHandle?
    private var downloadGeneration = 0
    private(set) var downloadHandle: WebParserFetchHandle?
    /// The skin was unloaded or refreshed (`skinWillClose`).
    private var closed = false
    private var downloadInFlight = false
    /// What the download in flight fetches and where it saves it (to recognise a repeated request).
    private var downloadKey: String?
    /// Temporary file of the last `Download=1` without `DownloadFile` (deleted when replaced or when the measure goes).
    private var temporaryDownload: String?
    private let instanceToken = String(UUID().uuidString.prefix(8))

    private var finishAction = ""
    private var onConnectErrorAction = ""
    private var onRegExpErrorAction = ""
    private var onDownloadErrorAction = ""

    private var hasMinOption = false
    private var hasMaxOption = false
    private var observedMin = 0.0
    private var observedMax = 0.0
    private var reported: Set<String> = []
    /// Set once `readMeasureOptions` has run (see `readOptions`).
    private var measureOptionsRead = false

    /// True while a fetch of this parent is running (for tests and diagnostics).
    public var isFetching: Bool { fetchInFlight }
    /// True while a `Download=1` transfer of this measure is running.
    public var isDownloading: Bool { downloadInFlight }
    /// Number of fetches started so far.
    public private(set) var fetchCount = 0

    /// Decides whether a `file://` resource may be read (called on the skin's thread with the absolute path, before
    /// reading). The manual allows any fully qualified path, so everything is allowed by default; the app may narrow
    /// this (e.g. to the Skins folder) so that a skin cannot read private files and send them elsewhere in a URL.
    public static var allowsFileAccess: (_ path: String, _ skin: Skin) -> Bool = { _, _ in true }

    public required init(name: String, section: IniSection, skin: Skin, type: String) {
        super.init(name: name, section: section, skin: skin, type: type)
        rawString = ""
    }

    deinit {
        fetchHandle?.cancel()
        downloadHandle?.cancel()
        if let temporaryDownload { try? FileManager.default.removeItem(atPath: temporaryDownload) }
    }

    /// The skin is unloaded or refreshed: transfers in flight are cancelled, and results that still arrive are dropped.
    public func skinWillClose() {
        closed = true
        fetchHandle?.cancel()
        downloadHandle?.cancel()
    }

    // MARK: Options

    public override var automaticMinValue: Double { observedMin }
    public override var automaticMaxValue: Double { observedMax > observedMin ? observedMax : observedMin + 1 }

    /// A measure that is disabled or paused when the skin loads reads only the common options (see `Measure`), so a
    /// child would not know its parent, and the parent would not set its values, until it runs. Judgment call: a
    /// WebParser measure reads its own options once even then, so that its parent sets its values from the first
    /// parse on; later changes to them wait until it runs again, like the options of other measures.
    public override func readOptions() {
        super.readOptions()
        if !measureOptionsRead { readMeasureOptions() }
    }

    public override func readMeasureOptions() {
        measureOptionsRead = true
        var o = WebParserOptions()
        o.name = name
        readURL(into: &o)
        o.regExp = string("RegExp")
        o.stringIndex = index("StringIndex")
        o.stringIndex2 = index("StringIndex2")
        o.updateRate = int("UpdateRate", 600)
        o.decodeCharacterReference = int("DecodeCharacterReference", 0)
        o.decodeCodePoints = bool("DecodeCodePoints", false)
        o.debug = int("Debug", 0)
        o.debug2File = string("Debug2File").trimmingCharacters(in: .whitespaces)
        o.download = bool("Download", false)
        o.downloadFile = string("DownloadFile").trimmingCharacters(in: .whitespaces)
        o.errorString = option("ErrorString")
        o.logSubstringErrors = bool("LogSubstringErrors", true)
        o.codePage = int("CodePage", 0)
        o.proxy = string("ProxyServer", "/auto")
        let agent = string("UserAgent").trimmingCharacters(in: .whitespaces)
        o.userAgent = agent.isEmpty || agent.contains("\n") || agent.contains("\r")
            ? WebParserNetwork.defaultUserAgent : agent
        o.headers = numberedOptions("Header").compactMap { entry in
            if entry.value.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            let header = Self.parseHeader(entry.value)
            if header == nil { report("header", "WebParser [\(name)]: ignoring invalid Header: \(entry.value)") }
            return header
        }
        o.flags = WebParserFlags(option: option("Flags"), forceReload: bool("ForceReload", false))
        for flag in o.flags.unsupported {
            skin.addIssue("WebParser Flags=\(flag) is not supported")
        }
        options = o

        finishAction = actionOption("FinishAction")
        onConnectErrorAction = actionOption("OnConnectErrorAction")
        onRegExpErrorAction = actionOption("OnRegExpErrorAction")
        onDownloadErrorAction = actionOption("OnDownloadErrorAction")
        hasMinOption = optionalDouble("MinValue") != nil
        hasMaxOption = optionalDouble("MaxValue") != nil
    }

    private func index(_ key: String) -> Int {
        min(max(int(key, 0), 0), 1000)
    }

    /// `Header=Name: Value` → (name, value); nil when the name is not an HTTP token or the value has line breaks.
    static func parseHeader(_ text: String) -> (name: String, value: String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let name = text[..<colon].trimmingCharacters(in: .whitespaces)
        let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        let tokenPunctuation = "!#$%&'*+-.^_`|~"
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ c in
            c.isASCII && (CharacterSet.alphanumerics.contains(c) || tokenPunctuation.unicodeScalars.contains(c))
        }), !value.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" }) else { return nil }
        return (name, value)
    }

    /// Reads `URL`. A `[Name]` naming another WebParser measure makes this a child of that measure: every such
    /// reference is replaced by `WebParserProcessor.parentMark` before the rest of the value is resolved (so it is
    /// neither left as text nor replaced by the section variable). `[&Name]` is an ordinary section variable, as the
    /// manual says. Judgment call: the reference is looked for in the option as written and, failing that, after
    /// `#Variables#` are replaced (`URL=#Feed#` with `Feed=[MeasureSite]`); the first WebParser name found wins.
    private func readURL(into o: inout WebParserOptions) {
        guard let raw = rawOption("URL") else {
            o.url = ""
            o.parentName = nil
            parentName = nil
            return
        }
        var text = raw
        var marked = markParent(in: raw)
        if marked == nil {
            let standard = skin.resolveStandardVariables(raw, in: self)
            if standard != raw, let m = markParent(in: standard) {
                marked = m
                text = standard
            }
        }
        if let marked {
            text = marked.text
            parentName = marked.parent
        } else {
            parentName = nil
        }
        o.parentName = parentName
        o.url = skin.resolve(text, in: self, sectionVariables: dynamicVariables)
    }

    private func markParent(in text: String) -> (text: String, parent: String)? {
        var searchStart = text.startIndex
        var steps = 0
        while let open = text[searchStart...].firstIndex(of: "["), steps < 1000 {
            steps += 1
            let afterOpen = text.index(after: open)
            guard let close = text[afterOpen...].firstIndex(where: { $0 == "]" || $0 == "[" }) else { return nil }
            if text[close] == "[" {
                searchStart = close
                continue
            }
            let name = String(text[afterOpen..<close])
            if let first = name.first, !"&#\\$*!".contains(first),
               let parent = skin.measure(named: name) as? WebParserMeasure, parent !== self {
                let replaced = text.replacingOccurrences(of: "[\(name)]", with: WebParserProcessor.parentMark,
                                                         options: .caseInsensitive)
                return (replaced, parent.name)
            }
            searchStart = text.index(after: close)
        }
        return nil
    }

    // MARK: Update

    public override func computeValue() -> Double {
        if parentName == nil {
            if updateCounter == 0 { startFetch(force: false) }
            advanceCounter()
        }
        rawString = resultString
        return resultNumber
    }

    /// UpdateRate cycle (tip "How UpdateRate Works"). Judgment calls: UpdateRate ≤ 0 never wraps (fetch once, then
    /// only on `!CommandMeasure … Update`, which is what the documented counter does); a counter already past a newly
    /// lowered UpdateRate wraps at once.
    private func advanceCounter() {
        if updateCounter < Int.max - 1 { updateCounter += 1 }
        if options.updateRate > 0 && updateCounter >= options.updateRate { updateCounter = 0 }
    }

    public override func execute(command: String) {
        switch command.trimmingCharacters(in: .whitespaces).lowercased() {
        case "update":
            readOptionsIfNeeded()
            guard parentName == nil else {
                skin.log("WebParser [\(name)]: !CommandMeasure Update is only valid on a parent measure", level: .warning)
                return
            }
            // Judgment call: a disabled measure is "never updated", so it does not fetch either.
            guard !disabled else { return }
            startFetch(force: true)
            updateCounter = 0
            advanceCounter()
        case "reset":
            guard parentName == nil else {
                skin.log("WebParser [\(name)]: !CommandMeasure Reset is only valid on a parent measure", level: .warning)
                return
            }
            reset()
        default:
            super.execute(command: command)
        }
    }

    /// "Reset all values for the parent and any related child measures to their initial empty values."
    private func reset() {
        for m in [self] + descendants() {
            m.captures = []
            m.substringCount = 0
            m.setResult("")
        }
    }

    /// All WebParser measures below this one (children, grandchildren…), in skin order per level.
    private func descendants() -> [WebParserMeasure] {
        let all = skin.measures.compactMap { $0 as? WebParserMeasure }
        var result: [WebParserMeasure] = []
        var visited: Set<String> = [name.lowercased()]
        var level = [self]
        var depth = 0
        while !level.isEmpty && depth < WebParserProcessor.maxDepth {
            depth += 1
            var next: [WebParserMeasure] = []
            for parent in level {
                let key = parent.name.lowercased()
                for m in all where m.parentName?.lowercased() == key && !visited.contains(m.name.lowercased()) {
                    visited.insert(m.name.lowercased())
                    next.append(m)
                }
            }
            result += next
            level = next
        }
        return result
    }

    private func setResult(_ text: String) {
        resultString = text
        let number = WebParserText.leadingNumber(text)
        resultNumber = number
        observedMin = min(observedMin, number)
        observedMax = max(observedMax, number)
        if !hasMinOption { minValue = automaticMinValue }
        if !hasMaxOption { maxValue = automaticMaxValue }
        // Visible at once (FinishAction usually redraws), except while Disabled / Paused: those keep what they had
        // until the next regular update.
        if !disabled && !paused {
            rawString = text
            value = invert ? maxValue - (number - minValue) : number
        }
    }

    // MARK: Fetching

    private func startFetch(force: Bool) {
        guard !closed else { return }
        let target = checkedFileAccess(WebParserURL.target(for: options.url))
        if options.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            report("empty-url", "WebParser [\(name)]: URL is empty")
            return
        }
        let resourceIsDownload = options.download && !options.hasRegExp
        if (resourceIsDownload ? downloadInFlight : fetchInFlight) && !force { return }
        fetchHandle?.cancel()
        fetchGeneration &+= 1
        fetchCount += 1
        let generation = fetchGeneration

        if resourceIsDownload {
            // The resource itself is the file to download.
            fetchInFlight = false
            fetchHandle = nil
            startDownload(source: options.url, base: nil, request: requestSettings(), isResource: true)
            return
        }

        let tree = snapshotTree()
        let codePage = options.codePage
        let dumpPath = options.debug == 2 ? debugDumpPath() : nil
        var request = requestSettings()
        request.target = target
        request.maxBytes = WebParserNetwork.maxPageBytes
        if options.debug == 1 {
            skin.log("WebParser [\(name)]: fetching \(target.displayString)", level: .debug)
        }
        fetchInFlight = true
        let hop = skin.hop()
        // Weak, like every closure that runs off the skin's thread: the transfer does not keep the measure alive (its
        // deinit cancels the transfer when the skin is dropped), and the measure is never released on the background
        // queue. The results find the measure again on the skin's executor.
        fetchHandle = WebParserNetwork.shared.start(request) { [weak self] result in
            // Background queue: decode and parse, then hand the results to the skin's executor.
            let outcome: Result<WebParserNodeResult, WebParserFetchError>
            switch result {
            case .failure(let error):
                outcome = .failure(error)
            case .success(let response):
                let text = WebParserText.decode(response.data, codePage: codePage, charset: response.charset)
                var parsed = WebParserProcessor.process(tree, text: text)
                if let dumpPath {
                    do {
                        try text.write(toFile: dumpPath, atomically: true, encoding: .utf8)
                    } catch {
                        parsed.logs.append(WebParserLogLine(level: .warning,
                                                            message: "WebParser [\(tree.options.name)]: cannot write \(dumpPath)"))
                    }
                }
                outcome = .success(parsed)
            }
            hop.post {
                self?.finishFetch(outcome, generation: generation, base: target)
            }
        }
    }

    /// Request settings of this (parent) measure. Downloads of child measures use their parent's settings: the
    /// manual defines UserAgent / Header / Flags / ProxyServer for "when the parent WebParser measure connects".
    private func requestSettings() -> WebParserRequest {
        var r = WebParserRequest(target: .invalid("none"))
        r.userAgent = options.userAgent
        r.headers = options.headers
        r.flags = options.flags
        r.proxy = options.proxy
        return r
    }

    /// Options of this measure and its descendants, read now on the skin's thread. Options changed with `!SetOption`
    /// on a child are picked up here (manual: change the child, then `!CommandMeasure Parent Update`).
    private func snapshotTree() -> WebParserNode {
        let all = skin.measures.compactMap { $0 as? WebParserMeasure }
        for m in all where m !== self { m.readOptionsIfNeeded() }
        var visited: Set<String> = [name.lowercased()]
        func build(_ m: WebParserMeasure, depth: Int) -> WebParserNode {
            var node = WebParserNode(options: m.options)
            guard depth < WebParserProcessor.maxDepth else { return node }
            let key = m.name.lowercased()
            for child in all where child.parentName?.lowercased() == key && !visited.contains(child.name.lowercased()) {
                visited.insert(child.name.lowercased())
                node.children.append(build(child, depth: depth + 1))
            }
            return node
        }
        return build(self, depth: 0)
    }

    /// `Debug=2`: `WebParserDump.txt` in the skin folder, or `Debug2File` ("The folder for the file must already
    /// exist"). Judgment call: Debug2File must lie inside the Skins folder — a skin may not overwrite arbitrary files.
    private func debugDumpPath() -> String? {
        let fallback = skin.directory.appendingPathComponent("WebParserDump.txt").path
        guard !options.debug2File.isEmpty else { return fallback }
        let path = skin.absolutePath(options.debug2File)
        let root = (skin.skinsDirectory.standardizedFileURL.path as NSString).standardizingPath
        // Also after following symbolic links: a link inside the Skins folder must not lead the dump elsewhere.
        let realRoot = (root as NSString).resolvingSymlinksInPath
        let realFolder = ((path as NSString).deletingLastPathComponent as NSString).resolvingSymlinksInPath
        guard path.hasPrefix(root + "/"), realFolder == realRoot || realFolder.hasPrefix(realRoot + "/") else {
            report("debug2file", "WebParser [\(name)]: Debug2File must be inside the Skins folder; using \(fallback)")
            return fallback
        }
        return path
    }

    private func finishFetch(_ outcome: Result<WebParserNodeResult, WebParserFetchError>, generation: Int,
                             base: WebParserTarget) {
        guard generation == fetchGeneration else { return }
        fetchInFlight = false
        fetchHandle = nil
        guard !closed else { return }
        let skin = self.skin  // keep the skin alive while actions run
        switch outcome {
        case .failure(.cancelled):
            return
        case .failure(let error):
            skin.log("WebParser [\(name)]: unable to get \(base.displayString): \(error)", level: .warning)
            if !onConnectErrorAction.isEmpty { skin.execute(onConnectErrorAction, from: self) }
        case .success(let result):
            let settings = requestSettings()
            apply(result, to: self, in: skin)
            runActions(result, measure: self, isRoot: true, base: base, settings: settings, in: skin)
        }
    }

    /// Sets the values of this measure and its children (before any action runs).
    private func apply(_ result: WebParserNodeResult, to measure: WebParserMeasure, in skin: Skin) {
        for line in result.logs { skin.log(line.message, level: line.level) }
        if let captures = result.captures {
            measure.captures = captures
            measure.substringCount = result.substringCount
        }
        if result.regExpError != nil {
            // ErrorString: "The value of the measure will be set to the string defined in this option if the RegExp
            // results in a regular expression parsing error."
            if let errorString = measure.options.errorString { measure.setResult(errorString) }
        } else if let value = result.value {
            measure.setResult(value)
        }
        for child in result.children {
            if let m = skin.measure(named: child.name) as? WebParserMeasure { apply(child, to: m, in: skin) }
        }
    }

    /// Actions after a parse (manual, Action Options):
    /// - FinishAction runs when the resource was read and parsed, "whether the parsing … succeeds or fails", except
    ///   that a failed parse runs OnRegExpErrorAction instead when one is set.
    /// - Download=1: FinishAction when the download succeeds, OnDownloadErrorAction when it fails.
    /// - Plain child measures have no actions; a child with its own RegExp or Download=1 acts like a parent for those.
    private func runActions(_ result: WebParserNodeResult, measure: WebParserMeasure, isRoot: Bool,
                            base: WebParserTarget, settings: WebParserRequest, in skin: Skin) {
        guard !result.inputMissing else { return }
        if result.regExpError != nil {
            if !measure.onRegExpErrorAction.isEmpty {
                skin.execute(measure.onRegExpErrorAction, from: measure)
            } else if !measure.finishAction.isEmpty {
                skin.execute(measure.finishAction, from: measure)
            }
            return
        }
        if let source = result.downloadSource {
            measure.startDownload(source: source, base: base, request: settings, isResource: false)
        } else if (isRoot || result.hasRegExp) && !measure.finishAction.isEmpty {
            skin.execute(measure.finishAction, from: measure)
        }
        for child in result.children {
            if let m = skin.measure(named: child.name) as? WebParserMeasure {
                runActions(child, measure: m, isRoot: false, base: base, settings: settings, in: skin)
            }
        }
    }

    // MARK: Download

    /// `Download=1`: saves `source` (relative URLs resolved against `base`) to `DownloadFile` or a temporary file; the
    /// measure's value becomes the local path.
    /// `isResource`: the measure's own URL is the download (no RegExp) — then a failure to connect runs
    /// OnConnectErrorAction, while an HTTP error status or a failure to save the file runs OnDownloadErrorAction.
    private func startDownload(source: String, base: WebParserTarget?, request settings: WebParserRequest,
                               isResource: Bool) {
        guard !closed else { return }
        let target = checkedFileAccess(WebParserURL.target(for: source, relativeTo: base))
        let destination: URL?
        let isTemporary = options.downloadFile.isEmpty
        if isTemporary {
            destination = WebParserURL.temporaryDestination(prefix: instanceToken, source: target)
        } else {
            destination = WebParserURL.downloadFileDestination(skinDirectory: skin.directory,
                                                               relativePath: options.downloadFile)
        }
        // The same file is already on its way: let that transfer finish (it runs this measure's actions). Restarting
        // it would starve the download whenever the parent re-reads its resource faster than the file arrives
        // (e.g. UpdateRate=1 and a slow image) — the value would never be set.
        let key = "\(isResource)|\(target.displayString)|\(destination?.path ?? "-")"
        if downloadInFlight, key == downloadKey, target.isValid, destination != nil { return }
        downloadHandle?.cancel()
        downloadHandle = nil
        downloadGeneration &+= 1
        downloadInFlight = true
        downloadKey = key
        let generation = downloadGeneration
        // DownloadFile must not be written through a symbolic link (see WebParserURL.hasSymbolicLink).
        let linkGuardRoot = isTemporary ? nil : skin.directory.appendingPathComponent("DownloadFile", isDirectory: true)
        guard target.isValid, let destination else {
            // An unusable URL is a connection failure for the measure's own resource; a bad DownloadFile is a
            // download failure.
            let badURL = !target.isValid
            let reason = badURL ? target.displayString : "invalid DownloadFile \(options.downloadFile)"
            // After the current action, like a transfer that fails.
            skin.async { [weak self] in
                self?.finishDownload(.failure(.connect(reason)), generation: generation, isResource: isResource && badURL,
                                     isTemporary: isTemporary)
            }
            return
        }
        var request = settings
        request.target = target
        request.maxBytes = WebParserNetwork.maxDownloadBytes
        if options.debug == 1 { skin.log("WebParser [\(name)]: downloading \(target.displayString)", level: .debug) }
        let hop = skin.hop()
        // Weak, as for the page (see `startFetch`).
        downloadHandle = WebParserNetwork.shared.start(request) { [weak self] result in
            let outcome: Result<String, WebParserFetchError>
            var saveFailure: String?
            switch result {
            case .failure(let error):
                outcome = .failure(error)
            case .success(let response):
                if let status = response.statusCode, !(200..<300).contains(status) {
                    saveFailure = "HTTP status \(status)"
                } else if let linkGuardRoot,
                          WebParserURL.hasSymbolicLink(from: linkGuardRoot, to: destination.deletingLastPathComponent()) {
                    saveFailure = "cannot save \(destination.path): the DownloadFile folder contains a symbolic link"
                } else {
                    do {
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                                withIntermediateDirectories: true)
                        try response.data.write(to: destination, options: .atomic)
                    } catch {
                        saveFailure = "cannot save \(destination.path): \(error.localizedDescription)"
                    }
                }
                outcome = saveFailure.map { .failure(.connect($0)) } ?? .success(destination.path)
            }
            let transportFailure = saveFailure == nil
            // A temporary file that nobody takes — the skin or the measure is gone by the time the result gets back —
            // is deleted: nothing else would ever delete it. (A DownloadFile stays, as the skin asked.)
            let saved: String? = isTemporary ? (try? outcome.get()) : nil
            let discard = { if let saved { try? FileManager.default.removeItem(atPath: saved) } }
            hop.post({
                guard let self else { return discard() }
                self.finishDownload(outcome, generation: generation, isResource: isResource && transportFailure,
                                    isTemporary: isTemporary)
            }, orElse: discard)
        }
    }

    private func finishDownload(_ outcome: Result<String, WebParserFetchError>, generation: Int, isResource: Bool,
                                isTemporary: Bool) {
        guard generation == downloadGeneration else { return }
        downloadHandle = nil
        downloadInFlight = false
        guard !closed else {
            // Saved before the unload could cancel it: nothing is applied or run, and a temporary file goes now (the
            // measure would never delete it).
            if case .success(let path) = outcome, isTemporary, path != temporaryDownload {
                try? FileManager.default.removeItem(atPath: path)
            }
            return
        }
        let skin = self.skin
        switch outcome {
        case .failure(.cancelled):
            return
        case .failure(let error):
            skin.log("WebParser [\(name)]: download failed: \(error)", level: .warning)
            let action = isResource ? onConnectErrorAction : onDownloadErrorAction
            if !action.isEmpty { skin.execute(action, from: self) }
        case .success(let path):
            if let previous = temporaryDownload, previous != path {
                try? FileManager.default.removeItem(atPath: previous)
            }
            temporaryDownload = isTemporary ? path : nil
            setResult(path)
            if !finishAction.isEmpty { skin.execute(finishAction, from: self) }
        }
    }

    /// Applies `allowsFileAccess` to a file target (a refused file behaves like a missing one).
    private func checkedFileAccess(_ target: WebParserTarget) -> WebParserTarget {
        guard case .file(let path) = target else { return target }
        let standardized = (path as NSString).standardizingPath
        return Self.allowsFileAccess(standardized, skin) ? target : .invalid("reading \(standardized) is not allowed")
    }

    // MARK: Logging

    /// Logs a warning once per kind (options are re-read every update with DynamicVariables=1).
    private func report(_ kind: String, _ message: String) {
        guard reported.insert(kind).inserted else { return }
        skin.log(message, level: .warning)
    }
}
