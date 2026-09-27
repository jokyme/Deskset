import Foundation

/// A source file's identity: the file itself (standardized, symlinks resolved — where it is read and written, as
/// `IniWriter` and `CodeDocument.writeTarget` do) compared the way the default, case-insensitive Mac file system compares
/// names. `Variables.inc`, `variables.inc` and a symlink to it are one file.
public struct SourceFileID: Hashable, CustomStringConvertible {
    public let url: URL
    /// The comparison key: the resolved path, lowercased.
    public let key: String

    public init(_ url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        self.url = resolved
        key = resolved.path.lowercased()
    }

    public static func == (a: SourceFileID, b: SourceFileID) -> Bool { a.key == b.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
    public var description: String { url.lastPathComponent }
}

/// The text of a widget's source files in memory, the Studio's truth while it edits them: every edit changes this text
/// first (`IniBackend`), the files are written after it (`DiskSync`), and the Studio's own instance of the widget loads
/// from it (`SourceProvider`). A file comes in the first time it is asked for, in the encoding it was read with
/// (`TextDecoding`), and its text is kept exactly as decoded — line endings and all — so writing it back unchanged gives
/// the same bytes. Main thread (or the one owner of the session).
public final class SourceBuffers: SourceProvider {
    /// One file in memory.
    public struct Buffer {
        public let id: SourceFileID
        /// The text as decoded (line endings untouched).
        public internal(set) var text: String
        /// How it is written: the file's own encoding and BOM, unless an edit it could not hold made it UTF-16 LE with a
        /// BOM (what `IniWriter` does to an ANSI file).
        public internal(set) var encoding: TextFileEncoding
        /// The file's bytes as the buffer last saw them on disk (read, adopted or written).
        public internal(set) var disk: Data
        /// The text or encoding differs from what the buffer last read from or wrote to the file.
        public internal(set) var isDirty = false

        /// The bytes the text is written as.
        public var data: Data { TextDecoding.encodeForWriting(text, preferring: encoding) }
    }

    private var buffers: [SourceFileID: Buffer] = [:]
    /// The order files came in (for listing them).
    private var order: [SourceFileID] = []

    public init() {}

    /// The files held, in the order they came in.
    public var files: [SourceFileID] { order.filter { buffers[$0] != nil } }

    /// The file's buffer if it is held (nil: never asked for, or forgotten).
    public func buffer(_ url: URL) -> Buffer? { buffers[SourceFileID(url)] }

    public func contains(_ url: URL) -> Bool { buffers[SourceFileID(url)] != nil }

    /// The file's buffer, read from disk the first time. Throws `IniWriterError.fileNotFound` when the file is not there
    /// (or is not a regular file), the read's own error when it cannot be read.
    @discardableResult
    public func load(_ url: URL) throws -> Buffer {
        let id = SourceFileID(url)
        if let held = buffers[id] { return held }
        let bytes = try SourceDisk.read(id, reportingAs: url)
        let decoded = TextDecoding.decodeDetectingEncoding(bytes)
        let buffer = Buffer(id: id, text: decoded.text, encoding: decoded.encoding, disk: bytes)
        buffers[id] = buffer
        order.append(id)
        return buffer
    }

    /// The text of the file (read from disk the first time).
    public func text(of url: URL) throws -> String { try load(url).text }

    /// Lets go of a file (its next use reads it again).
    public func forget(_ url: URL) {
        let id = SourceFileID(url)
        buffers[id] = nil
        order.removeAll { $0 == id }
    }

    /// The files whose text is not written yet.
    public var dirtyFiles: [SourceFileID] { files.filter { buffers[$0]?.isDirty == true } }

    // MARK: SourceProvider

    public func sourceText(for url: URL) -> String? { buffers[SourceFileID(url)]?.text }

    // MARK: Changes

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The file holds other text than the step left in it (changed since, in another app or by the widget).
        case changedElsewhere(URL)
        /// The file cannot be read (gone, or not a file any more).
        case unreadable(URL)

        public var description: String {
            switch self {
            case .changedElsewhere(let url): return "\(url.lastPathComponent) was changed in another app"
            case .unreadable(let url): return "cannot read \(url.lastPathComponent)"
            }
        }
    }

    /// Makes `changes` (or takes them back: `reverse`) in the buffers, all or none: every file must hold the text the
    /// changes start from (`Failure.changedElsewhere` otherwise; `Failure.unreadable` when it cannot be read). The
    /// buffers become dirty.
    public func apply(_ changes: [SourceChange], reverse: Bool = false) throws {
        let steps = reverse ? changes.reversed().map(\.reversed) : changes
        // Checked in order, on the text each step leaves for the next (a file may appear twice).
        var texts: [SourceFileID: (text: String, encoding: TextFileEncoding)] = [:]
        for change in steps {
            let current: (text: String, encoding: TextFileEncoding)
            if let pending = texts[change.file] {
                current = pending
            } else {
                guard let buffer = try? load(change.file.url) else { throw Failure.unreadable(change.file.url) }
                current = (buffer.text, buffer.encoding)
            }
            guard TextDigest(current.text) == change.digestBefore else { throw Failure.changedElsewhere(change.file.url) }
            texts[change.file] = (change.edit.applied(to: current.text), change.encodingAfter)
        }
        for (id, result) in texts { replace(id, text: result.text, encoding: result.encoding) }
    }

    /// Replaces a held file's text and encoding (the buffer becomes dirty unless nothing changes).
    func replace(_ id: SourceFileID, text: String, encoding: TextFileEncoding) {
        guard var buffer = buffers[id] else { return }
        guard !buffer.text.utf8.elementsEqual(text.utf8) || buffer.encoding != encoding else { return }
        buffer.text = text
        buffer.encoding = encoding
        buffer.isDirty = true
        buffers[id] = buffer
    }

    /// The buffer's text was written: `bytes` is what the file holds now.
    func markWritten(_ id: SourceFileID, bytes: Data) {
        guard var buffer = buffers[id] else { return }
        buffer.disk = bytes
        buffer.isDirty = false
        buffers[id] = buffer
    }

    /// The file changed on disk: the buffer takes its bytes (text, encoding) and is clean.
    func adopt(_ id: SourceFileID, bytes: Data) {
        guard var buffer = buffers[id] else { return }
        let decoded = TextDecoding.decodeDetectingEncoding(bytes)
        buffer.text = decoded.text
        buffer.encoding = decoded.encoding
        buffer.disk = bytes
        buffer.isDirty = false
        buffers[id] = buffer
    }
}

/// Reading and writing source files (the one place the session touches the disk).
enum SourceDisk {
    /// The file's bytes. `IniWriterError.fileNotFound` (with the path as given) when it is not a regular file.
    static func read(_ id: SourceFileID, reportingAs url: URL) throws -> Data {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: id.url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw IniWriterError.fileNotFound(url.path)
        }
        return try Data(contentsOf: id.url)
    }

    /// Writes `bytes` atomically (a temporary file renamed over it), under the file's lock (`IniWriter.withFileLock`: a
    /// skin on another thread writing the same file with `!WriteKeyValue` waits).
    static func write(_ bytes: Data, to id: SourceFileID) throws {
        try IniWriter.withFileLock(id.url) {
            try bytes.write(to: id.url, options: .atomic)
        }
    }
}
