import AppKit
import DesksetCore

/// What the main thread reads of a running skin (docs/skin-threading.md §5.5): one immutable value that the skin's
/// runtime builds on the skin's executor after a piece of work and swaps in under a lock (`SkinRuntime.snapshot`). The
/// window answers AppKit's questions from it — can this press drag the window, which cursor goes here, which tooltip,
/// does the panel need to become key — and the menus, the Manage window and the app's lookups read it, without waiting
/// for a skin that may be busy on a thread of its own.
///
/// It describes the skin as of its last piece of work, which is the frame on screen (or the one about to be): a click
/// is tested against what the user sees.
struct SkinSnapshot {
    /// The window size for the skin's size (points).
    var size = CGSize(width: 1, height: 1)
    /// Where the mouse finds the meters and what it does there, the `[Rainmeter]` actions, `DragMargins`, the tooltips.
    var hitMap = SkinHitMap()
    /// Where the glass goes (`MacGlass`), back to front, in skin points.
    var glass: [GlassRegion] = []
    /// The skin has OnFocusAction or OnUnfocusAction: its panel becomes key when clicked.
    var wantsFocus = false
    /// The custom context menu items (`ContextTitle`…), the menu's fallback while the skin is busy (it reads them
    /// afresh when it can): read again when the skin's variables or its context menu options changed
    /// (`Skin.variablesGeneration`), not after every update or layout — reading them can take longer than a small
    /// skin's update, and a title that shows a measure (`[Measure]`) waits for the next such change.
    var contextItems: [ContextMenuItem] = []
    /// `Skin.variablesGeneration` when `contextItems` were read.
    var contextVariables = -1
    /// Compatibility notes (`Skin.issues`).
    var issues: [String] = []
    /// `[Metadata]`.
    var metadata: [String: String] = [:]
    /// The skin groups of `[Rainmeter]` (`Group=`), as written.
    var groups: [String] = []
    /// The skin's file and the files it includes.
    var sourceFiles: [URL] = []
    /// How many `!WriteKeyValue` writes the skin made.
    var keyValueWrites = 0
    /// What the skin wants of the mouse outside its window (`Plugin=Slider`).
    var outsidePointerNeeds = OutsidePointerNeeds()
    /// The Calc `Counter` and the number of updates since the skin loaded.
    var counter = 0
    var updateCount = 0
    /// `Skin.snapshotGeneration` when the hit map and the other rebuilt parts were built.
    var generation = -1

    /// The snapshot after a piece of the skin's work, nil when nothing in it changed since `old`. It is built again when
    /// the skin's snapshot generation moved since `builtGeneration` (the hit map and what else the engine counts:
    /// `rebuild`); the values that change with every update (the counter, the context menu items) are taken each time.
    /// On the skin's owner.
    static func next(after old: SkinSnapshot, of skin: Skin, builtGeneration: inout Int?) -> SkinSnapshot? {
        var next = old
        var rebuilt = false
        let generation = skin.snapshotGeneration
        // "Variable values are read at the time the context menu is opened": the menu reads them then when it can; the
        // snapshot keeps them for when it cannot (see `contextItems`).
        if skin.variablesGeneration != old.contextVariables, skin.rainmeterSection?.rawOption("ContextTitle") != nil {
            next.contextVariables = skin.variablesGeneration
            next.contextItems = skin.contextMenuItems()
            rebuilt = next.contextItems != old.contextItems
        }
        if builtGeneration != generation {
            // Taken first: reading the skin to build the snapshot may move the generation again (a missing image noted
            // as a compatibility note), and the next one is built once more.
            builtGeneration = generation
            next.rebuild(from: skin, generation: generation)
            rebuilt = true
        }
        let counted = skin.updateCount != old.updateCount || skin.counter != old.counter
            || skin.keyValueWrites != old.keyValueWrites
        guard rebuilt || counted else { return nil }
        next.updateCount = skin.updateCount
        next.counter = skin.counter
        next.keyValueWrites = skin.keyValueWrites
        return next
    }

    /// Builds again what `Skin.snapshotGeneration` counts: the hit map, the size, the glass, the compatibility notes and
    /// what loading read. On the skin's owner. (The counter, the updates, the `!WriteKeyValue` writes and the context
    /// menu items are taken by the runtime after every piece of work.)
    mutating func rebuild(from skin: Skin, generation: Int) {
        hitMap = skin.makeHitMap()
        size = SkinRuntime.windowSize(width: skin.width, height: skin.height)
        glass = skin.glassRegions
        wantsFocus = !skin.settings.onFocusAction.isEmpty || !skin.settings.onUnfocusAction.isEmpty
        issues = skin.issues
        metadata = skin.metadata
        groups = skin.settings.groups
        sourceFiles = skin.sourceFiles
        outsidePointerNeeds = skin.outsidePointerNeeds
        self.generation = generation
    }

    /// The tooltip areas (skin coordinates, the view's).
    var toolTipAreas: [CGRect] { hitMap.toolTipAreas.map(\.cgRect) }

    /// `Skin.isInSkinGroup`: in the skin group (`Group=` in `[Rainmeter]`, case-insensitive).
    func isInSkinGroup(_ group: String) -> Bool {
        let g = group.trimmingCharacters(in: .whitespaces)
        return groups.contains { $0.caseInsensitiveCompare(g) == .orderedSame }
    }

    /// What changed since `old` that the main thread acts on when it changes (rather than reading it when it needs it):
    /// see `SkinSnapshotChanges`.
    func changes(from old: SkinSnapshot) -> SkinSnapshotChanges {
        var changes: SkinSnapshotChanges = []
        if size != old.size { changes.insert(.size) }
        if hitMap.toolTipAreas != old.hitMap.toolTipAreas { changes.insert(.toolTips) }
        if glass != old.glass { changes.insert(.glass) }
        if issues != old.issues { changes.insert(.issues) }
        if metadata != old.metadata { changes.insert(.metadata) }
        if groups != old.groups { changes.insert(.groups) }
        if outsidePointerNeeds != old.outsidePointerNeeds { changes.insert(.outsidePointerNeeds) }
        if wantsFocus != old.wantsFocus { changes.insert(.focus) }
        return changes
    }
}

/// What changed in a skin's snapshot that the main thread acts on (`SkinRequest.snapshotChanged`). The rest — the hit
/// map, the cursor, tooltip texts, the context menu items, the counter — it reads when it needs them, so a skin that
/// redraws 60 times a second with a stable layout posts nothing.
struct SkinSnapshotChanges: OptionSet {
    let rawValue: Int

    /// The window size.
    static let size = SkinSnapshotChanges(rawValue: 1 << 0)
    /// The tooltip areas: the window registers them again.
    static let toolTips = SkinSnapshotChanges(rawValue: 1 << 1)
    /// The glass regions.
    static let glass = SkinSnapshotChanges(rawValue: 1 << 2)
    /// The compatibility notes: the Manage window and the status menu show them.
    static let issues = SkinSnapshotChanges(rawValue: 1 << 3)
    /// `[Metadata]`.
    static let metadata = SkinSnapshotChanges(rawValue: 1 << 4)
    /// The skin groups.
    static let groups = SkinSnapshotChanges(rawValue: 1 << 5)
    /// What the skin wants of the mouse outside its window: the app watches it (`OutsidePointerMonitor`).
    static let outsidePointerNeeds = SkinSnapshotChanges(rawValue: 1 << 6)
    /// Whether the skin wants focus.
    static let focus = SkinSnapshotChanges(rawValue: 1 << 7)
}

/// Debug builds: every answer the window takes from a snapshot is also asked of the live skin when the skin runs on the
/// main executor, and a difference is reported (the self-tests fail the suite that ran into it). The existing suites
/// thus check the snapshot wherever they click, hover or ask for a tooltip. Release builds only return the snapshot's
/// answer. Main thread.
enum SnapshotAudit {
    /// Told of each difference (the self-tests record a failure).
    static var onDifference: ((String) -> Void)?
    /// How many answers were compared and how many differed, in this process.
    private(set) static var comparisons = 0
    private(set) static var differences = 0
    /// Differences go only to a test's own handler (`capturing`).
    private static var captured: ((String) -> Void)?

    /// Runs `body` with the differences told to `handler` instead, and not counted: a self-test of the comparison.
    static func capturing(_ handler: @escaping (String) -> Void, _ body: () -> Void) {
        let saved = captured
        captured = handler
        defer { captured = saved }
        body()
    }

    /// Whether answers from `runtime`'s snapshot are compared with its live skin: debug builds, a skin on the main
    /// executor, on the main thread.
    static func isActive(_ runtime: SkinRuntime) -> Bool {
        #if DEBUG
        return Thread.isMainThread && runtime.executor === MainSkinExecutor.shared && !runtime.isClosed
        #else
        return false
        #endif
    }

    /// The snapshot's `answer`; in debug builds the live skin's `live` answer is compared with it.
    @discardableResult
    static func check<T: Equatable>(_ what: @autoclosure () -> String, _ runtime: SkinRuntime, snapshot answer: T,
                                    live: (Skin) -> T) -> T {
        #if DEBUG
        if isActive(runtime), let liveAnswer = runtime.exclusive(live) {
            compare(what(), runtime, snapshot: answer, live: liveAnswer)
        }
        #endif
        return answer
    }

    /// Compares an answer the snapshot predicted with the one the live skin gave (debug builds).
    static func compare<T: Equatable>(_ what: @autoclosure () -> String, _ runtime: SkinRuntime, snapshot answer: T,
                                      live liveAnswer: T) {
        #if DEBUG
        guard isActive(runtime) else { return }
        comparisons += 1
        guard answer != liveAnswer else { return }
        let message = "\(runtime.config): \(what()): the snapshot says \(String(describing: answer)), "
            + "the skin \(String(describing: liveAnswer))"
        if let captured {
            captured(message)
            return
        }
        differences += 1
        Log.write("Snapshot answer differs from the skin: " + message, level: .error)
        onDifference?(message)
        #endif
    }
}
