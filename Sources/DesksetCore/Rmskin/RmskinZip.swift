import Foundation

// ZIP-level helpers for the .rmskin installer: a read-only scan of the ZIP central directory (to refuse
// dangerous archives *before* anything is written to disk), running /usr/bin/ditto, and a post-extraction
// sanitising pass over the extracted tree.
//
// The ZIP layout used here is the public PKWARE APPNOTE format (end-of-central-directory record, optional ZIP64
// locator/record, central directory file headers). Nothing is decompressed here; ditto does the extraction.
//
// Measured behaviour of `/usr/bin/ditto -x -k` (macOS 26) that shapes the design:
// - It is a *streaming* extractor: it follows the local file headers, not the central directory. Entries missing
//   from the central directory are still extracted, the declared uncompressed sizes are not enforced (a deflate
//   stream declared as 10 bytes was written out as 50 MB), and the local name wins over the central name. The
//   central-directory scan below is therefore only a fast first filter; the real limits are enforced on what ditto
//   actually writes (`outputMonitor` while it runs, `sanitizeExtractedTree` afterwards).
// - It strips `..` and leading `/` from names itself, and turns symlink entries into links only at the very end, so
//   nothing can be written *through* a link during extraction; links are deleted afterwards.
// - Without `--norsrc` it restores ACLs and extended attributes from `__MACOSX/._*` AppleDouble entries (even with
//   `--noacl`): a package can then make its files undeletable ("everyone deny delete"), which breaks clean-up and
//   upgrades. Extraction therefore uses `--norsrc --qtn`: no resource forks / xattrs / ACLs, but the package's
//   quarantine flag is still propagated to the extracted files (Gatekeeper keeps checking anything a skin launches).
// - Names that are not valid UTF-8 (ZIP "code page 437" names from Windows tools) are either decoded with a guessed
//   legacy encoding or written with `\\` / `\ooo` (octal byte) escapes — see `backslashComponents`.
// - Unix modes are applied as stored, so a folder may come out unreadable (0o311) or read-only (0o555); the
//   sanitising pass gives the owner full access back before anything else reads the tree.

/// One entry of a ZIP central directory.
struct RmskinZipEntry: Equatable {
    /// Entry name decoded for messages (UTF-8 when valid, else Latin-1).
    var name: String
    var isDirectory: Bool
    var isSymlink: Bool
    var uncompressedSize: UInt64
    /// The raw name bytes are valid UTF-8. Other names come from legacy Windows tools (code page 437 / OEM).
    var nameIsUTF8: Bool = true
}

enum RmskinZip {
    /// Hard limits against "zip bombs" and absurd archives. Real skin packages are a few MB with a few hundred files.
    static let maxEntries: UInt64 = 200_000
    static let maxTotalUncompressedSize: UInt64 = 4 << 30 // 4 GiB
    /// Deepest folder nesting accepted in an extracted package.
    static let maxPathDepth = 100
    /// ditto is killed after this many seconds.
    static let extractionTimeout: TimeInterval = 300
    /// Extra bytes an extraction may write beyond the sizes the archive declares before it is treated as a bomb.
    static let outputSlack: UInt64 = 64 << 20
    /// Drop of free space on the target volume (beyond the declared size) that stops an extraction. Catches output
    /// hidden in folders the watcher cannot list; generous because other programs write to the disk too.
    static let freeSpaceSlack: UInt64 = 1 << 30

    struct ScanError: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: Central directory scan

    /// Lists the central directory of `data` (a complete ZIP archive). Throws `ScanError` for corrupt archives,
    /// archives over the size limits, entries whose path could escape the extraction folder (absolute paths,
    /// drive letters, `..` components, NUL bytes) and symbolic-link entries (a symlink followed by an entry
    /// written "through" it is the classic zip-slip; skins never need symlinks).
    static func scanCentralDirectory(_ data: Data) throws -> [RmskinZipEntry] {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [RmskinZipEntry] in
            try scan(raw)
        }
    }

    private static func u16(_ b: UnsafeRawBufferPointer, _ o: Int) -> UInt64 {
        UInt64(b[o]) | UInt64(b[o + 1]) << 8
    }

    private static func u32(_ b: UnsafeRawBufferPointer, _ o: Int) -> UInt64 {
        UInt64(b[o]) | UInt64(b[o + 1]) << 8 | UInt64(b[o + 2]) << 16 | UInt64(b[o + 3]) << 24
    }

    private static func u64(_ b: UnsafeRawBufferPointer, _ o: Int) -> UInt64 {
        u32(b, o) | u32(b, o + 4) << 32
    }

    private static func hasSignature(_ b: UnsafeRawBufferPointer, _ o: Int, _ signature: UInt64) -> Bool {
        o >= 0 && o + 4 <= b.count && u32(b, o) == signature
    }

    private static func scan(_ b: UnsafeRawBufferPointer) throws -> [RmskinZipEntry] {
        let n = b.count
        guard n >= 22 else { throw ScanError("the archive is too small to be a ZIP file") }

        // End of central directory: 22 bytes + comment (≤ 65535), searched backwards from the end.
        var eocd = -1
        var i = n - 22
        let lowest = max(0, n - 22 - 0xFFFF)
        while i >= lowest {
            if hasSignature(b, i, 0x0605_4B50) {
                let commentLength = Int(u16(b, i + 20))
                if i + 22 + commentLength <= n {
                    eocd = i
                    break
                }
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ScanError("the ZIP directory was not found (truncated or corrupt file)") }

        var entryCount = u16(b, eocd + 10)
        var directorySize = u32(b, eocd + 12)
        var directoryOffset = u32(b, eocd + 16)

        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // ZIP64: locator (20 bytes) right before the EOCD points at the ZIP64 EOCD record (56 bytes).
            let locator = eocd - 20
            if hasSignature(b, locator, 0x0706_4B50) {
                let recordOffset = u64(b, locator + 8)
                guard n >= 56, recordOffset <= UInt64(n - 56), hasSignature(b, Int(recordOffset), 0x0606_4B50) else {
                    throw ScanError("corrupt ZIP64 directory record")
                }
                let r = Int(recordOffset)
                entryCount = u64(b, r + 32)
                directorySize = u64(b, r + 40)
                directoryOffset = u64(b, r + 48)
            }
        }

        guard entryCount <= maxEntries else { throw ScanError("the archive has too many entries (\(entryCount))") }
        guard directoryOffset <= UInt64(n), directorySize <= UInt64(n) - directoryOffset else {
            throw ScanError("the ZIP directory lies outside the file (truncated or corrupt file)")
        }

        var entries: [RmskinZipEntry] = []
        entries.reserveCapacity(Int(entryCount))
        var position = Int(directoryOffset)
        let end = Int(directoryOffset + directorySize)
        var totalSize: UInt64 = 0

        for _ in 0..<Int(entryCount) {
            guard position + 46 <= end, hasSignature(b, position, 0x0201_4B50) else {
                throw ScanError("corrupt ZIP directory entry")
            }
            let madeBy = u16(b, position + 4)
            var uncompressedSize = u32(b, position + 24)
            let nameLength = Int(u16(b, position + 28))
            let extraLength = Int(u16(b, position + 30))
            let commentLength = Int(u16(b, position + 32))
            let externalAttributes = u32(b, position + 38)
            let nameStart = position + 46
            let extraStart = nameStart + nameLength
            let recordEnd = extraStart + extraLength + commentLength
            guard recordEnd <= end else { throw ScanError("corrupt ZIP directory entry") }

            let nameBytes = Array(b[nameStart..<extraStart])

            if uncompressedSize == 0xFFFF_FFFF {
                // ZIP64 extended information extra field (tag 0x0001): original size comes first.
                var e = extraStart
                let extraEnd = extraStart + extraLength
                while e + 4 <= extraEnd {
                    let tag = u16(b, e)
                    let size = Int(u16(b, e + 2))
                    if tag == 0x0001, size >= 8, e + 4 + 8 <= extraEnd {
                        uncompressedSize = u64(b, e + 4)
                        break
                    }
                    e += 4 + size
                }
            }
            let utf8Name = String(bytes: nameBytes, encoding: .utf8)
            let name = utf8Name ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? "?"
            // (Flag bit 11 marks UTF-8 names; the safety checks work on raw bytes, so the encoding does not matter.)

            if let reason = unsafePathReason(nameBytes) {
                throw ScanError("unsafe entry \"\(name)\" (\(reason))")
            }

            let host = madeBy >> 8
            let unixMode = (externalAttributes >> 16) & 0o170000
            let unixLike = host == 3 || host == 19 // Unix, OS X (Darwin)
            // Checked whatever the "made by" host says: an extractor that honours Unix modes would still create it.
            let isSymlink = unixMode == 0o120000
            if isSymlink {
                throw ScanError("the archive contains a symbolic link (\"\(name)\"), which is not allowed in a skin package")
            }
            let lastByte = nameBytes.last
            let isDirectory = lastByte == 0x2F || lastByte == 0x5C || (unixLike && unixMode == 0o040000)
                || (externalAttributes & 0x10) != 0

            let (sum, overflow) = totalSize.addingReportingOverflow(uncompressedSize)
            guard !overflow, sum <= maxTotalUncompressedSize else {
                throw ScanError("the archive expands to more than \(maxTotalUncompressedSize >> 30) GB")
            }
            totalSize = sum

            entries.append(RmskinZipEntry(name: name, isDirectory: isDirectory, isSymlink: isSymlink,
                                          uncompressedSize: uncompressedSize, nameIsUTF8: utf8Name != nil))
            position = recordEnd
        }
        return entries
    }

    /// Why an entry name could escape the extraction directory, or nil when it is safe. Works on raw bytes:
    /// `/`, `\`, `.` and `:` are ASCII in every encoding a ZIP name may use. Backslashes count as separators because
    /// Windows tools sometimes write them, and the installer later turns them into folders.
    static func unsafePathReason(_ bytes: [UInt8]) -> String? {
        guard let first = bytes.first else { return "empty name" }
        if bytes.contains(0) { return "NUL byte in name" }
        if first == 0x2F || first == 0x5C { return "absolute path" }
        if bytes.count >= 2, bytes[1] == 0x3A, (0x41...0x5A).contains(first) || (0x61...0x7A).contains(first) {
            return "drive letter"
        }
        var componentStart = 0
        var depth = 0
        for index in 0...bytes.count {
            if index == bytes.count || bytes[index] == 0x2F || bytes[index] == 0x5C {
                let length = index - componentStart
                if length == 2, bytes[componentStart] == 0x2E, bytes[componentStart + 1] == 0x2E {
                    return "parent-directory reference"
                }
                if length > 0 { depth += 1 }
                componentStart = index + 1
            }
        }
        if depth > maxPathDepth { return "path too deep" }
        return nil
    }

    // MARK: ditto

    private final class OutputBox {
        var data = Data()
    }

    /// Runs `/usr/bin/ditto` with `arguments`, returning (exit status, stderr text). Never hangs: ditto is terminated
    /// after `timeout` seconds. While it runs, `monitor` (if any) is called every `pollInterval` seconds; when it
    /// returns a reason, ditto is stopped and `.extractionFailed(reason)` is thrown.
    static func runDitto(_ arguments: [String], timeout: TimeInterval = extractionTimeout,
                         pollInterval: TimeInterval = 0.2,
                         monitor: (() -> String?)? = nil) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw RmskinError.extractionFailed("cannot run /usr/bin/ditto: \(error.localizedDescription)")
        }

        // Drain stderr concurrently so a chatty ditto can never block on a full pipe.
        let box = OutputBox()
        let reading = DispatchGroup()
        reading.enter()
        let handle = errorPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            box.data = handle.readDataToEndOfFile()
            reading.leave()
        }

        func stop(_ reason: String) -> RmskinError {
            process.terminate()
            if finished.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 5)
            }
            _ = reading.wait(timeout: .now() + 2)
            return RmskinError.extractionFailed(reason)
        }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        let interval = max(0.01, pollInterval)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            let slice = monitor == nil ? max(0, remaining) : min(interval, max(0, remaining))
            if finished.wait(timeout: .now() + slice) == .success { break }
            if deadline.timeIntervalSinceNow <= 0 {
                throw stop("ditto did not finish within \(Int(timeout)) seconds")
            }
            if let reason = monitor?() { throw stop(reason) }
        }
        _ = reading.wait(timeout: .now() + 5)
        let message = String(decoding: box.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, message)
    }

    // MARK: Watching what ditto writes

    /// Bytes in regular files and number of items below `directory` (not following links). Stops counting once either
    /// limit is exceeded. Folders it cannot list are skipped (the free-space check covers them).
    static func measureOutput(_ directory: URL, byteLimit: UInt64 = .max, itemLimit: Int = .max)
        -> (bytes: UInt64, items: Int) {
        guard let enumerator = FileManager.default.enumerator(at: directory.resolvingSymlinksInPath(),
                                                              includingPropertiesForKeys: nil,
                                                              options: [], errorHandler: { _, _ in true }) else {
            return (0, 0)
        }
        var bytes: UInt64 = 0
        var items = 0
        while let url = enumerator.nextObject() as? URL {
            items += 1
            var info = stat()
            if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 {
                bytes &+= UInt64(info.st_size)
            }
            if bytes > byteLimit || items > itemLimit { break }
        }
        return (bytes, items)
    }

    /// Free bytes on the volume holding `url` (nil when unknown).
    static func availableBytes(at url: URL) -> UInt64? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        let (product, overflow) = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize))
        return overflow ? .max : product
    }

    /// A watcher for `runDitto` that stops extractions writing more than the archive declared (`declaredBytes`, plus
    /// `outputSlack`) or more than `2 × maxEntries` items into `directory`, whatever the ZIP headers claim.
    static func outputMonitor(for directory: URL, declaredBytes: UInt64) -> () -> String? {
        let before = FileManager.default.fileExists(atPath: directory.path)
            ? measureOutput(directory) : (bytes: UInt64(0), items: 0)
        let byteLimit = before.bytes &+ min(declaredBytes, maxTotalUncompressedSize) &+ outputSlack
        let itemLimit = before.items + Int(maxEntries) * 2
        let freeBefore = availableBytes(at: directory)
        let freeDropLimit = min(declaredBytes, maxTotalUncompressedSize) &+ freeSpaceSlack
        return {
            if let start = freeBefore, let now = availableBytes(at: directory), start > now, start - now > freeDropLimit {
                return "the archive writes far more data than it declares (possible ZIP bomb)"
            }
            let usage = measureOutput(directory, byteLimit: byteLimit, itemLimit: itemLimit)
            if usage.bytes > byteLimit {
                return "the archive writes more data than it declares (possible ZIP bomb)"
            }
            if usage.items > itemLimit { return "the archive contains too many files" }
            return nil
        }
    }

    /// Copies the `com.apple.quarantine` flag of `source` (a downloaded package) to `destination`, so ditto
    /// propagates it to every extracted file. Missing flag or failures are ignored.
    static func copyQuarantine(from source: URL, to destination: URL) {
        let name = "com.apple.quarantine"
        let size = getxattr(source.path, name, nil, 0, 0, 0)
        guard size > 0, size <= 4096 else { return }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(source.path, name, &buffer, size, 0, 0)
        guard read > 0, read <= size else { return }
        _ = setxattr(destination.path, name, buffer, read, 0, 0)
    }

    // MARK: Post-extraction sanitising

    /// Makes an extracted tree safe to copy from:
    /// - gives the owner read/write (and folder search) access to everything and drops set-uid/set-gid/sticky bits,
    ///   so no folder is silently skipped and the temporary tree can always be deleted,
    /// - removes every symbolic link and special file (the scan already refuses links; this is defence in depth),
    ///   and `__MACOSX` metadata folders,
    /// - enforces the depth, item-count and `maxBytes` limits on what was really written,
    /// - turns items whose names contain `\` into real folders: Windows tools sometimes write `\` instead of `/`, and
    ///   when `decodeEscapes` is set (the archive has non-UTF-8 names) ditto's `\\` / `\ooo` escapes are decoded and
    ///   the name is read as code page 437, the ZIP default.
    /// The walk never follows links, so every item it touches lies inside `root` by construction.
    /// Returns warnings for anything that was dropped.
    static func sanitizeExtractedTree(at root: URL, decodeEscapes: Bool = false,
                                      maxBytes: UInt64 = maxTotalUncompressedSize &+ outputSlack) throws -> [String] {
        let fm = FileManager.default
        var warnings: [String] = []
        var rootInfo = stat()
        // The root itself may be a link to a folder (the caller's choice); everything below it is never followed.
        guard stat(root.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw RmskinError.extractionFailed("cannot read the extracted files")
        }
        _ = chmod(root.path, (rootInfo.st_mode & 0o777) | 0o700)

        var backslashItems: [(url: URL, depth: Int)] = []
        var metadataFolders: [URL] = []
        var visited: UInt64 = 0
        var totalBytes: UInt64 = 0
        var pending: [(url: URL, depth: Int)] = [(root, 0)] // explicit stack: no recursion
        while let (folder, depth) = pending.popLast() {
            let names: [String]
            do {
                names = try fm.contentsOfDirectory(atPath: folder.path)
            } catch {
                throw RmskinError.extractionFailed("cannot read the extracted folder \"\(folder.lastPathComponent)\"")
            }
            for name in names {
                visited += 1
                if visited > maxEntries * 2 { throw RmskinError.extractionFailed("the package contains too many files") }
                let url = folder.appendingPathComponent(name)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    if depth + 1 > maxPathDepth { throw RmskinError.extractionFailed("folders are nested too deeply") }
                    _ = chmod(url.path, (info.st_mode & 0o777) | 0o700)
                    pending.append((url, depth + 1))
                    if name.caseInsensitiveCompare("__MACOSX") == .orderedSame {
                        metadataFolders.append(url)
                        continue
                    }
                case S_IFREG:
                    _ = chmod(url.path, (info.st_mode & 0o777) | 0o600)
                    totalBytes &+= UInt64(max(0, info.st_size))
                    if totalBytes > maxBytes {
                        throw RmskinError.extractionFailed("the package expands to more data than it declares")
                    }
                case S_IFLNK:
                    try? fm.removeItem(at: url)
                    warnings.append("Ignored symbolic link \(name)")
                    continue
                default: // FIFOs, sockets, devices: never part of a skin
                    try? fm.removeItem(at: url)
                    warnings.append("Ignored special file \(name)")
                    continue
                }
                if name.contains("\\") { backslashItems.append((url, depth + 1)) }
            }
        }
        // Metadata folders go last: their contents had their permissions fixed by the walk.
        for folder in metadataFolders {
            try? fm.removeItem(at: folder)
            backslashItems.removeAll { $0.url.path.hasPrefix(folder.path + "/") }
        }

        // Deepest first, so moving a folder never invalidates a path collected inside it.
        backslashItems.sort { $0.depth > $1.depth }
        for (url, _) in backslashItems {
            let parent = url.deletingLastPathComponent()
            let parts = backslashComponents(url.lastPathComponent, decodeEscapes: decodeEscapes)
            if parts.isEmpty || parts.contains(where: { $0 == ".." || $0.contains("/") || $0.contains("\0") }) {
                try? fm.removeItem(at: url)
                warnings.append("Ignored invalid file name \(url.lastPathComponent)")
                continue
            }
            if parts == [url.lastPathComponent] { continue }
            var target = parent
            for part in parts { target.appendPathComponent(part) }
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try RmskinFiles.mergeMove(from: url, to: target)
            } catch {
                try? fm.removeItem(at: url)
                warnings.append("Could not place \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return warnings
    }

    /// Code page 437, the ZIP default for names without the UTF-8 flag (PKWARE APPNOTE, appendix D).
    static let codePage437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))

    /// Splits an extracted name at `\` and returns the folder/file components (empty and `.` parts dropped).
    /// With `decodeEscapes`, ditto's escapes for names it could not decode are undone first — `\\` is a literal
    /// backslash byte and `\ooo` an octal byte — and each component is decoded as UTF-8 when valid, else as code
    /// page 437. (A Windows path whose component starts with three octal digits ≥ 200, in an archive that also has
    /// non-UTF-8 names, would be misread; that combination is not worth more machinery.)
    static func backslashComponents(_ name: String, decodeEscapes: Bool) -> [String] {
        let source = Array(name.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(source.count)
        var i = 0
        while i < source.count {
            if decodeEscapes, source[i] == 0x5C, i + 1 < source.count {
                if source[i + 1] == 0x5C {
                    bytes.append(0x5C)
                    i += 2
                    continue
                }
                if i + 3 < source.count, (0x30...0x33).contains(source[i + 1]), (0x30...0x37).contains(source[i + 2]),
                   (0x30...0x37).contains(source[i + 3]) {
                    bytes.append((source[i + 1] - 0x30) << 6 | (source[i + 2] - 0x30) << 3 | (source[i + 3] - 0x30))
                    i += 4
                    continue
                }
            }
            bytes.append(source[i])
            i += 1
        }
        return bytes.split(separator: 0x5C, omittingEmptySubsequences: true).compactMap { part -> String? in
            let text = String(bytes: part, encoding: .utf8)
                ?? String(bytes: part, encoding: codePage437)
                ?? String(decoding: part, as: UTF8.self)
            return text == "." ? nil : text
        }
    }
}
