import Foundation

/// Keeps an editing session's buffers and the disk in step:
/// - `flush` writes the buffers' new text — atomically, in each file's encoding with its BOM and line endings as they
///   are in the text, under the file's lock — and remembers what it wrote, so the file-system event of its own write is
///   not taken for a change made elsewhere;
/// - `changedOnDisk` finds files whose bytes differ from what the buffers last read or wrote (another editor saved,
///   the widget ran `!WriteKeyValue`) — by the bytes, not the dates: a save of the same size within the same tick of
///   the clock, or on a volume that keeps dates to the second, is found too;
/// - `adoptChanges` puts those files' new text into buffers that have no edits of their own.
///
/// When it writes: for now the Studio writes at the end of every step (each step is "a gesture's end", so the widget on
/// the desktop reloads the files right after, as it always did); `scheduleFlush` writes after a pause (about 0.5 s) for
/// changes that do not end a gesture. Main thread (or the session's owner).
public final class DiskSync {
    public let buffers: SourceBuffers
    /// How long `scheduleFlush` waits for the edits to stop.
    public var idleDelay: TimeInterval = 0.5
    /// Where `scheduleFlush` runs its write (the main queue unless a test says otherwise).
    public var queue: DispatchQueue = .main
    /// What went wrong with the last scheduled write (nil: nothing).
    public private(set) var lastScheduledError: Error?
    private var scheduled: DispatchWorkItem?

    public init(buffers: SourceBuffers) {
        self.buffers = buffers
    }

    /// Whether some text is not written yet.
    public var hasUnwrittenChanges: Bool { !buffers.dirtyFiles.isEmpty }

    /// Writes every buffer with new text (or those of `files`). Returns the files written. A file that cannot be
    /// written keeps its new text (still dirty) and the first such error is thrown after the others were written.
    @discardableResult
    public func flush(_ files: [URL]? = nil) throws -> [URL] {
        scheduled?.cancel()
        scheduled = nil
        let wanted = files.map { Set($0.map(SourceFileID.init)) }
        var written: [URL] = []
        var failure: Error?
        for id in buffers.dirtyFiles where wanted?.contains(id) ?? true {
            guard let buffer = buffers.buffer(id.url) else { continue }
            let bytes = buffer.data
            do {
                // The same bytes on disk already (the edit was undone before it was written): only the buffer is clean.
                if let now = try? Data(contentsOf: id.url), now == bytes {
                    buffers.markWritten(id, bytes: bytes)
                    continue
                }
                try SourceDisk.write(bytes, to: id)
                buffers.markWritten(id, bytes: bytes)
                written.append(id.url)
            } catch {
                if failure == nil { failure = error }
            }
        }
        if let failure { throw failure }
        return written
    }

    /// Writes after `idleDelay` without another call (edits that do not end a gesture). A failure is kept in
    /// `lastScheduledError` (the buffers stay dirty).
    public func scheduleFlush() {
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduled = nil
            do {
                try self.flush()
                self.lastScheduledError = nil
            } catch {
                self.lastScheduledError = error
            }
        }
        scheduled = work
        queue.asyncAfter(deadline: .now() + idleDelay, execute: work)
    }

    /// Whether a write waits for its pause.
    public var hasScheduledFlush: Bool { scheduled != nil }

    /// The held files (or those of `files`) whose bytes on disk differ from what the buffers last saw: saved elsewhere,
    /// written by the widget, or gone. The same bytes written again (or a file only touched) are no change.
    public func changedOnDisk(_ files: [URL]? = nil) -> [URL] {
        let ids = files.map { $0.map(SourceFileID.init) } ?? buffers.files
        var changed: [URL] = []
        for id in ids {
            guard let buffer = buffers.buffer(id.url) else { continue }
            let bytes = try? SourceDisk.read(id, reportingAs: id.url)
            if bytes != buffer.disk { changed.append(id.url) }
        }
        return changed
    }

    /// Takes the disk's version of the changed files (`changedOnDisk`) into buffers without edits of their own; a file
    /// that is gone is forgotten (its next use reads the disk again). Buffers with edits keep them (whoever writes them
    /// decides). Returns the files whose buffers changed.
    @discardableResult
    public func adoptChanges(_ files: [URL]? = nil) -> [URL] {
        var adopted: [URL] = []
        for url in changedOnDisk(files) {
            let id = SourceFileID(url)
            guard let buffer = buffers.buffer(url), !buffer.isDirty else { continue }
            guard let bytes = try? SourceDisk.read(id, reportingAs: url) else {
                buffers.forget(url)
                adopted.append(url)
                continue
            }
            buffers.adopt(id, bytes: bytes)
            adopted.append(url)
        }
        return adopted
    }
}
