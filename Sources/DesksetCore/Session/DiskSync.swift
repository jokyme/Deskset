import Foundation

/// Keeps an editing session's buffers and the disk in step:
/// - `flush` writes the buffers' new text — atomically, in each file's encoding with its BOM and line endings as they
///   are in the text, under the file's lock — and remembers what it wrote, so the file-system event of its own write is
///   not taken for a change made elsewhere;
/// - `changedOnDisk` finds files whose bytes differ from what the buffers last read or wrote (another editor saved,
///   the widget ran `!WriteKeyValue`) — by the bytes, not the dates: a save of the same size within the same tick of
///   the clock, or on a volume that keeps dates to the second, is found too;
/// - `touchedOnDisk` finds files saved again with the same bytes, or only touched (their modification date moved):
///   the Studio reloads the widget for such a save too, as it did when it looked at the dates (an image or a font the
///   widget uses may have changed);
/// - `adoptChanges` puts those files' new text into buffers that have no edits of their own.
///
/// When it writes: for now the Studio writes at the end of every step (each step is "a gesture's end", so the widget on
/// the desktop reloads the files right after, as it always did); `scheduleFlush` writes after a pause (about 0.5 s) for
/// changes that do not end a gesture. The writes themselves go through one serial queue (`writer`), shared by every
/// session, one file at a time; `flush` waits for them, since what comes next reads the files. Main thread (or the
/// session's owner).
public final class DiskSync {
    /// Where every session's files are written, one write at a time (under each file's lock as well, which skins
    /// writing with `!WriteKeyValue` take too).
    public static let writer = DispatchQueue(label: "app.deskset.session.disk", qos: .userInitiated)

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
            let outcome = Self.writer.sync {
                Result { () throws -> (wrote: Bool, date: Date?) in
                    // The same bytes on disk already (the edit was undone before it was written): nothing to write.
                    if let now = try? Data(contentsOf: id.url), now == bytes {
                        return (false, SourceDisk.modificationDate(id))
                    }
                    return (true, try SourceDisk.write(bytes, to: id))
                }
            }
            switch outcome {
            case .success(let result):
                buffers.markWritten(id, bytes: bytes, date: result.date)
                if result.wrote { written.append(id.url) }
            case .failure(let error):
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
    /// written by the widget, or gone (a file that was not there and still is not: no change). The same bytes written
    /// again (or a file only touched) are no change: `touchedOnDisk`.
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

    /// The held files (or those of `files`) saved again with the bytes the buffers last saw, or only touched: their
    /// modification date moved. Each is reported once (the date is taken as seen). Files whose bytes changed are left
    /// to `changedOnDisk`.
    public func touchedOnDisk(_ files: [URL]? = nil) -> [URL] {
        let ids = files.map { $0.map(SourceFileID.init) } ?? buffers.files
        var touched: [URL] = []
        for id in ids {
            guard let buffer = buffers.buffer(id.url), let disk = buffer.disk else { continue }
            let date = SourceDisk.modificationDate(id)
            guard date != buffer.diskDate else { continue }
            guard (try? SourceDisk.read(id, reportingAs: id.url)) == disk else { continue }
            buffers.markSeen(id, date: date)
            touched.append(id.url)
        }
        return touched
    }

    /// The modification dates of the held files (or of `files`) as they are now: what a skin writes while it runs
    /// is found by comparing two of these (`restamp`: taken as seen).
    public func modificationDates(_ files: [URL]? = nil) -> [SourceFileID: Date] {
        let ids = files.map { $0.map(SourceFileID.init) } ?? buffers.files
        var dates: [SourceFileID: Date] = [:]
        for id in ids { dates[id] = SourceDisk.modificationDate(id) }
        return dates
    }

    /// The held files' modification dates are taken as seen: saves of the same bytes made until now are not reported
    /// by `touchedOnDisk` (a widget's own writes, which the session took as they came).
    public func restamp() {
        for id in buffers.files {
            guard buffers.buffer(id.url)?.disk != nil else { continue }
            buffers.markSeen(id, date: SourceDisk.modificationDate(id))
        }
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
            buffers.adopt(id, bytes: bytes, date: SourceDisk.modificationDate(id))
            adopted.append(url)
        }
        return adopted
    }
}
