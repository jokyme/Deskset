import Foundation
import DesksetCore

/// Which skins run, as the skins see it (docs/skin-threading.md §5.4, §8.2): each running config's runtime in load
/// order, and the configs a bang is loading. It is an immutable value that the app replaces as a whole on every load
/// and unload, when a bang schedules a load and when that load has run (`AppController.publishDirectory`). A skin
/// resolves the config names, `*` and the skin groups of its bangs against the directory current at that moment and
/// hands each bang to its target's runtime itself (`SkinRuntime`), without asking the main thread: at once when the
/// target runs on the sender's thread, queued in order otherwise.
struct SkinDirectory {
    /// A running skin.
    struct Entry {
        /// Its config, as the app names it.
        let config: String
        let runtime: SkinRuntime
    }

    /// The running skins, in load order (then by name).
    let entries: [Entry]
    /// Lowercased config → index in `entries`.
    private let index: [String: Int]
    /// The configs a bang is loading and whose load has not run yet (lowercased).
    let pendingLoads: Set<String>
    /// Counts the directories the app published.
    let generation: Int

    init(entries: [Entry] = [], pendingLoads: Set<String> = [], generation: Int = 0) {
        self.entries = entries
        var index: [String: Int] = [:]
        for (i, entry) in entries.enumerated() { index[entry.config.lowercased()] = i }
        self.index = index
        self.pendingLoads = pendingLoads
        self.generation = generation
    }

    /// The runtime of a running config (the name in any case, with `/` or `\`), nil when it does not run.
    func runtime(for config: String) -> SkinRuntime? {
        index[SkinLibrary.normalizedConfigName(config).lowercased()].map { entries[$0].runtime }
    }

    /// A bang has asked to load `config` and the load has not run yet: a bang for it goes behind the load.
    func isLoadPending(_ config: String) -> Bool {
        pendingLoads.contains(SkinLibrary.normalizedConfigName(config).lowercased())
    }

    /// Every running skin, in load order (`*`).
    var runtimes: [SkinRuntime] { entries.map(\.runtime) }

    /// The running skins of the skin group `group` (`Group=` in `[Rainmeter]`, case-insensitive), in load order: their
    /// snapshots say (debug builds compare with the live skins of the main executor).
    func runtimes(inGroup group: String) -> [SkinRuntime] {
        guard !group.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return entries.map(\.runtime).filter { runtime in
            SnapshotAudit.check("isInSkinGroup(\(group))", runtime, snapshot: runtime.snapshot.isInSkinGroup(group),
                                live: { $0.isInSkinGroup(group) })
        }
    }
}

/// Where an app keeps its current `SkinDirectory`: the main thread publishes, the skins read it from any thread.
final class SkinDirectoryStore {
    private let current = Guarded(SkinDirectory())
    /// Counts the publishes (main thread).
    private var generation = 0

    /// The directory as last published. Any thread.
    var directory: SkinDirectory { current.current }

    /// Replaces the directory (main thread).
    func publish(entries: [SkinDirectory.Entry], pendingLoads: Set<String>) {
        generation += 1
        let directory = SkinDirectory(entries: entries, pendingLoads: pendingLoads, generation: generation)
        current.access { $0 = directory }
    }
}
