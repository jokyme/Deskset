import CoreServices
import DesksetCore
import Foundation

/// Watches a widget's source files with FSEvents, instead of looking at their dates every half second: the folders
/// that hold them are watched, and `onChange` hears — on the main thread, shortly after a save — which of the files
/// were touched (created, written, renamed over, removed). It only says where to look: the session's `DiskSync`
/// compares the files with what it last read or wrote, so its own writes are not changes.
final class SourceWatcher {
    /// The watched files' comparison keys (`SourceFileID.key`) that the file system reported, and their URLs.
    var onChange: (([URL]) -> Void)?
    /// How long FSEvents gathers events before it reports them.
    let latency: CFTimeInterval
    private var stream: FSEventStreamRef?
    private(set) var watched: [String: URL] = [:]

    init(latency: CFTimeInterval = 0.05) {
        self.latency = latency
    }

    deinit { stop() }

    /// Watches `files` (their folders; the same list again changes nothing).
    func watch(_ files: [URL]) {
        var wanted: [String: URL] = [:]
        for url in files {
            let id = SourceFileID(url)
            wanted[id.key] = id.url
        }
        guard Set(wanted.keys) != Set(watched.keys) || stream == nil else { return }
        stop()
        watched = wanted
        let folders = Array(Set(wanted.values.map { $0.deletingLastPathComponent().path })).sorted()
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil,
                                           release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, sourceWatcherCallback, &context, folders as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(flags)) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    /// Stops watching.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    var isWatching: Bool { stream != nil }

    /// The paths FSEvents reported: the watched files among them go to `onChange`.
    fileprivate func received(_ paths: [String]) {
        var touched: [URL] = []
        var seen: Set<String> = []
        for path in paths {
            let key = SourceFileID(URL(fileURLWithPath: path)).key
            guard let url = watched[key], seen.insert(key).inserted else { continue }
            touched.append(url)
        }
        if !touched.isEmpty { onChange?(touched) }
    }
}

/// FSEvents' callback (a C function): hands the paths to the watcher named by the context.
private func sourceWatcherCallback(_ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
                                   _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>,
                                   _ ids: UnsafePointer<FSEventStreamEventId>) {
    guard let info else { return }
    let watcher = Unmanaged<SourceWatcher>.fromOpaque(info).takeUnretainedValue()
    let list = unsafeBitCast(paths, to: NSArray.self)
    watcher.received(list.compactMap { $0 as? String })
}
