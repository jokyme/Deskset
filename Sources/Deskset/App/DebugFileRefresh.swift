import DesksetCore
import Foundation

/// Coalesces source-file changes and stops a refresh loop before it can keep reloading a skin.
final class DebugFileRefresh {
    var onRefresh: (() -> Void)?
    var onDisabled: ((String) -> Void)?
    private(set) var isEnabled = false

    private struct Contents: Equatable { let data: Data? }
    private struct Stamp: Equatable {
        let modified: Date?
        let size: UInt64?
        let inode: UInt64?
    }
    private struct Source {
        let url: URL
        let identity = UUID()
        let startingStamp: Stamp
    }
    private let watcher = SourceWatcher()
    private let reader = DispatchQueue(label: "com.deskset.debug-file-refresh", qos: .utility)
    private let readFile: (URL) -> Data?
    private let maximumRefreshes: Int
    private let stormInterval: TimeInterval
    private let debounceInterval: TimeInterval
    // Scheduling and baseline state are owned by the main thread.
    private var files: [String: Source] = [:]
    private var contents: [String: Contents] = [:]
    private var pending: Set<String> = []
    private var debounce: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var refreshTimes: [TimeInterval] = []
    private var isReading = false

    init(maximumRefreshes: Int = 5, stormInterval: TimeInterval = 3, debounceInterval: TimeInterval = 0.15,
         readFile: @escaping (URL) -> Data? = { try? Data(contentsOf: $0) }) {
        self.maximumRefreshes = maximumRefreshes
        self.stormInterval = stormInterval
        self.debounceInterval = debounceInterval
        self.readFile = readFile
        watcher.onChange = { [weak self] files in self?.filesChanged(files) }
    }

    deinit { debounce?.cancel(); watcher.stop() }

    func start(files: [URL]) {
        stop()
        isEnabled = true
        update(files: files)
    }

    /// Keep existing baselines across a refresh, including writes caused by OnRefreshAction.
    func update(files urls: [URL]) {
        guard isEnabled else { return }
        var wanted: [String: URL] = [:]
        for url in urls {
            let id = SourceFileID(url)
            wanted[id.key] = id.url
        }
        guard Set(wanted.keys) != Set(files.keys) else { return }
        let added = wanted.filter { files[$0.key] == nil }
        // Capture lightweight metadata before queueing a baseline read, so an immediate save is not lost.
        files = wanted.mapValues { url in
            let key = SourceFileID(url).key
            return files[key] ?? Source(url: url, startingStamp: Self.stamp(url))
        }
        contents = contents.filter { wanted[$0.key] != nil }
        pending.formIntersection(wanted.keys)
        pending.formUnion(added.keys)
        watcher.watch(Array(wanted.values))
        launchReadIfPossible()
    }

    func stop() {
        isEnabled = false
        generation &+= 1
        debounce?.cancel()
        debounce = nil
        pending.removeAll()
        files.removeAll()
        contents.removeAll()
        refreshTimes.removeAll()
        watcher.stop()
    }

    private func filesChanged(_ urls: [URL]) {
        guard isEnabled else { return }
        for url in urls {
            let key = SourceFileID(url).key
            if files[key] != nil { pending.insert(key) }
        }
        guard !pending.isEmpty else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readPendingChanges() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func readPendingChanges() {
        guard isEnabled else { return }
        debounce = nil
        launchReadIfPossible()
    }

    private func launchReadIfPossible() {
        guard isEnabled, !isReading, !pending.isEmpty else { return }
        debounce?.cancel()
        debounce = nil
        let requestedFiles = files.filter { pending.contains($0.key) }
        pending.removeAll()
        let requestedGeneration = generation
        let readFile = readFile
        isReading = true
        reader.async { [weak self] in
            let latest = requestedFiles.mapValues { Contents(data: readFile($0.url)) }
            let readStamps = requestedFiles.mapValues { Self.stamp($0.url) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isReading = false
                defer {
                    // Notifications during a read coalesce into one follow-up; stop/restart never queues old reads.
                    if self.debounce == nil { self.launchReadIfPossible() }
                }
                guard self.isEnabled, self.generation == requestedGeneration else { return }
                var changed = false
                for (key, value) in latest {
                    guard let source = self.files[key],
                          source.identity == requestedFiles[key]?.identity else { continue }
                    if let previous = self.contents[key] {
                        if previous != value { changed = true }
                    } else if source.startingStamp != readStamps[key] {
                        changed = true
                    }
                    self.contents[key] = value
                }
                guard changed else { return }
                self.didFindChange()
            }
        }
    }

    private static func stamp(_ url: URL) -> Stamp {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Stamp(modified: attributes?[.modificationDate] as? Date,
                     size: (attributes?[.size] as? NSNumber)?.uint64Value,
                     inode: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    private func didFindChange() {
        let now = ProcessInfo.processInfo.systemUptime
        refreshTimes.removeAll { now - $0 > stormInterval }
        refreshTimes.append(now)
        guard refreshTimes.count <= maximumRefreshes else {
            stop()
            onDisabled?("Automatic refresh stopped because the skin files changed too frequently.")
            return
        }
        onRefresh?()
    }

    func checkForChanges() { filesChanged(files.values.map(\.url)) }
    var testBaselineCount: Int { contents.count }
    var testIsWatching: Bool { watcher.isWatching }
    var testIsReading: Bool { isReading }
    var testPendingCount: Int { pending.count }
    var testIsDebouncing: Bool { debounce != nil }
}
