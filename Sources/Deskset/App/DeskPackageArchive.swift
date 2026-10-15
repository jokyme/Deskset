import Foundation
import Darwin
import zlib
import DeskLanguage

/// Strict ZIP reader for Desk packages. Never hands untrusted records to a filesystem extractor.
/// Stored and raw-deflate ZIP32 entries (including data descriptors) are supported. Encryption,
/// split archives, ZIP64 and special files fail closed. Archive metadata is never applied to disk.
enum DeskPackageArchive {
    enum Failure: Error, Equatable { case corrupt, unsupported, unsafePath, conflict, limit, cancelled, io }
    static let maximumBytes = 100 * 1024 * 1024
    static let maximumFiles = 2_000
    // Independent input/metadata limits bound work even for archives containing no regular files.
    static let maximumArchiveBytes = maximumBytes + 16 * 1024 * 1024
    static let maximumEntries = 10_000

    struct Entry {
        let path: String
        let directory: Bool
        let method: Int
        let crc: UInt32
        let size: Int
        let payload: Range<Int>
    }

    /// Owns the extracted directory for precisely the lifetime of the synchronous operation.
    /// Consumers needing later freshness validation must finish staging inside this scope.
    static func withCapture<T>(archive: URL, temporaryParent: URL = FileManager.default.temporaryDirectory,
                               isCancelled: () -> Bool = { false },
                               body: (DeskPackageCapture) throws -> T) throws -> T {
        let bytes = try readArchive(archive, isCancelled: isCancelled)
        return try withCapture(bytes: bytes, temporaryParent: temporaryParent, isCancelled: isCancelled, body: body)
    }

    static func withCapture<T>(bytes: Data, temporaryParent: URL,
                               isCancelled: () -> Bool = { false },
                               body: (DeskPackageCapture) throws -> T) throws -> T {
        let entries = try scan(bytes, isCancelled: isCancelled)
        let root = temporaryParent.appendingPathComponent("desk-archive-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            for entry in entries {
                try check(isCancelled)
                let target = root.appendingPathComponent(entry.path, isDirectory: entry.directory)
                // Every component was validated, collisions rejected, and this private tree contains
                // only directories/files we create. No archive link, mode, ACL or xattr is restored.
                try FileManager.default.createDirectory(at: entry.directory ? target : target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let content = try decode(bytes, entry: entry, isCancelled: isCancelled)
                if !entry.directory { try content.write(to: target, options: .withoutOverwriting) }
            }
            let capture = try DeskPackageCapture.read(root: root, isCancelled: isCancelled)
            try check(isCancelled)
            let result = try body(capture)
            try check(isCancelled)
            try FileManager.default.removeItem(at: root)
            return result
        } catch {
            // Do not conceal a cleanup failure behind a successful result.
            try FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private static func check(_ cancelled: () -> Bool) throws {
        if cancelled() { throw Failure.cancelled }
    }

    private static func readArchive(_ url: URL, isCancelled: () -> Bool) throws -> Data {
        guard url.isFileURL, !url.path.contains("\0") else { throw Failure.unsafePath }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.io }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw Failure.unsupported }
        guard before.st_size >= 0, before.st_size <= maximumArchiveBytes else { throw Failure.limit }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try check(isCancelled)
            let count = Darwin.read(fd, &buffer, min(buffer.count, maximumArchiveBytes - result.count + 1))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure.io }
            if count == 0 { break }
            guard count <= maximumArchiveBytes - result.count else { throw Failure.limit }
            result.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, result.count == before.st_size,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.corrupt }
        return result
    }

    static func scan(_ data: Data, isCancelled: () -> Bool = { false }) throws -> [Entry] {
        try check(isCancelled)
        guard data.count <= maximumArchiveBytes else { throw Failure.limit }
        let b = [UInt8](data), n = b.count
        func u16(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 }
        func u32(_ p: Int) -> Int { u16(p) | u16(p + 2) << 16 }
        guard n >= 22 else { throw Failure.corrupt }
        guard let end = stride(from: n - 22, through: max(0, n - 65_557), by: -1).first(where: {
            u32($0) == 0x06054b50 && $0 + 22 + u16($0 + 20) == n
        }) else { throw Failure.corrupt }
        guard u16(end + 4) == 0, u16(end + 6) == 0,
              u16(end + 8) == u16(end + 10) else { throw Failure.unsupported }
        let count = u16(end + 10), directory = u32(end + 16)
        guard count <= maximumEntries else { throw Failure.limit }
        guard directory <= end, u32(end + 12) == end - directory else { throw Failure.corrupt }
        var cursor = directory, entries: [Entry] = [], spans: [Range<Int>] = []
        var total = 0, files = 0
        var nodes: [String: (spelling: [UInt8], directory: Bool)] = [:]
        var explicit = Set<String>()
        for _ in 0..<count {
            try check(isCancelled)
            guard cursor + 46 <= end, u32(cursor) == 0x02014b50 else { throw Failure.corrupt }
            let flags = u16(cursor + 8), method = u16(cursor + 10)
            guard flags & ~0x080e == 0, method == 0 || method == 8,
                  method == 8 || flags & 6 == 0, u16(cursor + 34) == 0 else { throw Failure.unsupported }
            let crc = u32(cursor + 16), compressed = u32(cursor + 20), size = u32(cursor + 24)
            let nameLength = u16(cursor + 28), extraLength = u16(cursor + 30), commentLength = u16(cursor + 32)
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= end else { throw Failure.corrupt }
            let nameBytes = Array(b[(cursor + 46)..<(cursor + 46 + nameLength)])
            guard let name = String(bytes: nameBytes, encoding: .utf8), !name.isEmpty,
                  !name.contains("\\"), !name.contains(":"), !name.contains("\0"), !name.hasPrefix("/") else { throw Failure.unsafePath }
            let isDirectory = name.hasSuffix("/")
            let path = isDirectory ? String(name.dropLast()) : name
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 100,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { throw Failure.unsafePath }
            let mode = (u32(cursor + 38) >> 16) & 0o170000
            guard mode == 0 || mode == (isDirectory ? 0o040000 : 0o100000),
                  u32(cursor + 38) & 0x10 == 0 || isDirectory else { throw Failure.unsupported }
            guard !isDirectory || size == 0 else { throw Failure.corrupt }
            total += size
            if !isDirectory { files += 1 }
            guard total <= maximumBytes, files <= maximumFiles else { throw Failure.limit }
            var prefix = ""
            for (index, part) in parts.enumerated() {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                let key = DeskPackagePath.foldedKey(prefix)
                let dir = index < parts.count - 1 || isDirectory
                if let prior = nodes[key] {
                    guard prior.spelling == Array(prefix.utf8), prior.directory, dir else { throw Failure.conflict }
                } else { nodes[key] = (Array(prefix.utf8), dir) }
            }
            guard explicit.insert(DeskPackagePath.foldedKey(path)).inserted else { throw Failure.conflict }
            guard nodes.count <= maximumEntries else { throw Failure.limit }
            let local = u32(cursor + 42)
            guard local + 30 <= directory, u32(local) == 0x04034b50,
                  u16(local + 6) == flags, u16(local + 8) == method else { throw Failure.corrupt }
            let localName = u16(local + 26), localExtra = u16(local + 28)
            let start = local + 30 + localName + localExtra
            guard start <= directory, compressed <= directory - start,
                  Array(b[(local + 30)..<(local + 30 + localName)]) == nameBytes else { throw Failure.corrupt }
            var finish = start + compressed
            if flags & 8 == 0 {
                guard u32(local + 14) == crc, u32(local + 18) == compressed, u32(local + 22) == size else { throw Failure.corrupt }
            } else {
                guard (u32(local + 14) == 0 || u32(local + 14) == crc),
                      (u32(local + 18) == 0 || u32(local + 18) == compressed),
                      (u32(local + 22) == 0 || u32(local + 22) == size) else { throw Failure.corrupt }
                if finish + 4 <= directory, u32(finish) == 0x08074b50 { finish += 4 }
                guard finish + 12 <= directory, u32(finish) == crc,
                      u32(finish + 4) == compressed, u32(finish + 8) == size else { throw Failure.corrupt }
                finish += 12
            }
            // Extra fields may not introduce alternate sizes, names or link semantics; this reader
            // intentionally ignores metadata but rejects ZIP64, whose layout differs.
            for range in [(cursor + 46 + nameLength)..<(cursor + 46 + nameLength + extraLength),
                          (local + 30 + localName)..<start] {
                var p = range.lowerBound
                while p < range.upperBound {
                    guard p + 4 <= range.upperBound else { throw Failure.corrupt }
                    guard u16(p) != 1 else { throw Failure.unsupported }
                    let length = u16(p + 2)
                    guard length <= range.upperBound - p - 4 else { throw Failure.corrupt }
                    p += 4 + length
                }
            }
            entries.append(Entry(path: path, directory: isDirectory, method: method, crc: UInt32(crc),
                                 size: size, payload: start..<(start + compressed)))
            spans.append(local..<finish)
            cursor = next
        }
        guard cursor == end else { throw Failure.corrupt }
        var localEnd = 0
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard span.lowerBound == localEnd else { throw Failure.corrupt }
            localEnd = span.upperBound
        }
        guard localEnd == directory else { throw Failure.corrupt }
        return entries
    }

    static func decode(_ data: Data, entry: Entry, isCancelled: () -> Bool = { false }) throws -> Data {
        try check(isCancelled)
        var output = Data(), crc: uLong = 0
        func append(_ chunk: UnsafeBufferPointer<UInt8>) throws {
            guard chunk.count <= entry.size - output.count else { throw Failure.limit }
            crc = crc32(crc, chunk.baseAddress, uInt(chunk.count))
            output.append(chunk.baseAddress!, count: chunk.count)
        }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let input = raw.bindMemory(to: UInt8.self)
            if entry.method == 0 {
                guard entry.payload.count == entry.size else { throw Failure.corrupt }
                var offset = entry.payload.lowerBound
                while offset < entry.payload.upperBound {
                    try check(isCancelled)
                    let count = min(65_536, entry.payload.upperBound - offset)
                    try append(UnsafeBufferPointer(start: input.baseAddress!.advanced(by: offset), count: count))
                    offset += count
                }
            } else {
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.corrupt }
                defer { inflateEnd(&stream) }
                stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress!.advanced(by: entry.payload.lowerBound))
                stream.avail_in = uInt(entry.payload.count)
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    try check(isCancelled)
                    let prior = stream.avail_in
                    let status = try buffer.withUnsafeMutableBufferPointer { out -> Int32 in
                        stream.next_out = out.baseAddress
                        stream.avail_out = uInt(out.count)
                        let status = inflate(&stream, Z_NO_FLUSH)
                        try append(UnsafeBufferPointer(start: out.baseAddress, count: out.count - Int(stream.avail_out)))
                        return status
                    }
                    if status == Z_STREAM_END {
                        guard stream.avail_in == 0 else { throw Failure.corrupt }
                        break
                    }
                    guard status == Z_OK, prior != stream.avail_in || stream.avail_out == 0 else { throw Failure.corrupt }
                }
            }
        }
        guard output.count == entry.size, UInt32(crc) == entry.crc else { throw Failure.corrupt }
        return output
    }
}
