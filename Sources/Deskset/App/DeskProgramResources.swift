import Foundation
import Darwin
import ImageIO
import DeskLanguage
import DesksetCore
import DesksetDraw

/// Approved pictures of one explicitly opened document. Only its named assets are read, through directory FDs;
/// Draw consumes immutable private copies, never reopens the document's user paths after validation.
enum DeskProgramResources {
    enum Input {
        case pending
        case ready([String: ProgramImageResource])
        case failed(String)
    }

    struct Source: Equatable, Sendable {
        let literal: String
        let resolved: String
        let stamp: ImageStamp
    }

    /// The explicitly opened Desk file, read through the same no-follow traversal as its pictures. A caller can
    /// freeze its exact UTF-8 bytes without loading other Desk files or a package manifest from the user folder.
    struct Document: Sendable {
        let file: URL
        let source: Source
        let bytes: Data

        func unchanged(maximumBytes: Int) -> Bool {
            guard let current = try? DeskProgramResources.document(at: file, maximumBytes: maximumBytes) else { return false }
            return current.source == source && current.bytes == bytes
        }
    }

    static func document(at file: URL, maximumBytes: Int) throws -> Document {
        let opened = try openFile(in: file.deletingLastPathComponent(), literal: file.lastPathComponent)
        defer { Darwin.close(opened.fd) }
        let bytes = try read(opened, maximumBytes: maximumBytes, literal: file.lastPathComponent)
        return Document(file: file, source: Source(literal: file.lastPathComponent, resolved: opened.path, stamp: opened.stamp),
                        bytes: bytes)
    }

    /// Installation copies the owner's immutable preparation, not the original user path. The descriptor and its
    /// recorded generation stay valid for the entire copy; no encoded image is decoded or rewritten here.
    static func withPreparedImage(_ source: Source, in prepared: Prepared, _ body: (Int32, Int) throws -> Void) throws {
        guard let folder = prepared.folder, let image = prepared.images[source.literal],
              image.path == folder.appendingPathComponent((image.path as NSString).lastPathComponent).path else {
            throw Failure.changed(source.literal)
        }
        let opened = try openFile(in: folder, literal: (image.path as NSString).lastPathComponent)
        defer { Darwin.close(opened.fd) }
        guard opened.stamp == image.stamp, opened.stamp.size >= 0, opened.stamp.size <= Int64(Int.max) else {
            throw Failure.changed(source.literal)
        }
        try body(opened.fd, Int(opened.stamp.size))
        var after = stat()
        guard fstat(opened.fd, &after) == 0, stamp(after) == opened.stamp else { throw Failure.changed(source.literal) }
    }

    struct Prepared: Sendable {
        let root: URL
        let folder: URL?
        let files: [DeskPackageFile]
        let images: [String: ProgramImageResource]
        let sources: [Source]
        let failure: String?

        func removeCopies() {
            if let folder { try? FileManager.default.removeItem(at: folder) }
        }

        /// Same safe path lookup as reading: an ancestor replaced by a link is a change, not a new readable root.
        func unchanged() -> Bool {
            guard images.values.allSatisfy({ Images.imageStamp(atPath: $0.path) == $0.stamp }) else { return false }
            for source in sources {
                guard let opened = try? DeskProgramResources.openFile(in: root, literal: source.literal) else { return false }
                defer { Darwin.close(opened.fd) }
                guard DeskPackagePath.sameBytes(opened.path, source.resolved), opened.stamp == source.stamp else { return false }
            }
            return true
        }
    }

    private enum Failure: Error, CustomStringConvertible {
        case outside(String), unreadable(String), ambiguous(String), changed(String), oversized(String), invalidImage(String)
        var description: String { message(in: .english) }

        func message(in language: StudioLanguage) -> String {
            let key: StudioText.Key
            let path: String
            switch self {
            case .outside(let value): (key, path) = (.deskImageOutside, value)
            case .unreadable(let value): (key, path) = (.deskImageUnreadable, value)
            case .ambiguous(let value): (key, path) = (.deskImageAmbiguous, value)
            case .changed(let value): (key, path) = (.deskImageChanged, value)
            case .oversized(let value): (key, path) = (.deskImageTooLarge, value)
            case .invalidImage(let value): (key, path) = (.deskImageInvalid, value)
            }
            return DeskProgramResources.message(key, path, language: language)
        }
    }

    /// Resource work receives the document language; it never queries AppKit's language policy off the main thread.
    private static func message(_ key: StudioText.Key, _ detail: String, language: StudioLanguage) -> String {
        let template = StudioText.string(key, in: language)
        return language == .chinese ? StudioText.spacedFormat(template, [detail]) : String(format: template, detail)
    }

    private struct Opened {
        let fd: Int32
        let path: String
        let stamp: ImageStamp
    }

    private static func stamp(_ info: stat) -> ImageStamp {
        ImageStamp(seconds: Int(info.st_mtimespec.tv_sec), nanoseconds: Int(info.st_mtimespec.tv_nsec),
                   size: Int64(info.st_size), inode: UInt64(info.st_ino))
    }

    private static func spelling(_ wanted: String, in directory: Int32, literal: String) throws -> String {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw Failure.unreadable(literal) }
        guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); throw Failure.unreadable(literal) }
        defer { closedir(stream) }
        let key = DeskPackagePath.foldedKey(wanted)
        var found: String?
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Failure.unreadable(literal) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingUTF8: $0) }
            }
            guard let name, name != ".", name != "..", DeskPackagePath.foldedKey(name) == key else { continue }
            guard found == nil else { throw Failure.ambiguous(literal) }
            found = name
        }
        guard let found else { throw Failure.unreadable(literal) }
        return found
    }

    /// A root descriptor anchors the permitted folder. Every subsequent component is opened without following
    /// links, not just the final file; a concurrent ancestor swap cannot redirect this traversal elsewhere.
    private static func openFile(in root: URL, literal: String) throws -> Opened {
        guard !literal.contains("\0"), !literal.hasPrefix("/"), !literal.hasPrefix("~"), !literal.contains("://"),
              !literal.split(separator: "/").contains(".."),
              let normalized = PackageResources(package: DeskPackage()).resolve(literal),
              let components = DeskPackagePath.safeComponents(normalized) else { throw Failure.outside(literal) }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw Failure.unreadable(literal) }
        defer { Darwin.close(directory) }
        var actual: [String] = []
        for index in components.indices {
            let name = try spelling(components[index], in: directory, literal: literal)
            actual.append(name)
            let last = index == components.count - 1
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (last ? 0 : O_DIRECTORY)
            let next = openat(directory, name, flags)
            guard next >= 0 else { throw Failure.unreadable(literal) }
            if last {
                var info = stat()
                guard fstat(next, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
                    Darwin.close(next); throw Failure.unreadable(literal)
                }
                return Opened(fd: next, path: actual.joined(separator: "/"), stamp: stamp(info))
            }
            Darwin.close(directory)
            directory = next
        }
        throw Failure.outside(literal)
    }

    private static func read(_ file: Opened, maximumBytes: Int, literal: String) throws -> Data {
        guard maximumBytes >= 0, file.stamp.size >= 0, file.stamp.size <= Int64(maximumBytes) else {
            throw Failure.oversized(literal)
        }
        let count = Int(file.stamp.size)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= count {
            let remaining = count - data.count
            let want = remaining >= buffer.count ? buffer.count : remaining + 1
            let got = buffer.withUnsafeMutableBytes { Darwin.read(file.fd, $0.baseAddress, want) }
            if got < 0 && errno == EINTR { continue }
            guard got >= 0 else { throw Failure.unreadable(literal) }
            if got == 0 { break }
            data.append(contentsOf: buffer.prefix(got))
        }
        var after = stat()
        guard data.count == count, fstat(file.fd, &after) == 0, stamp(after) == file.stamp else { throw Failure.changed(literal) }
        return data
    }

    /// File count/bytes are the referenced collection's package budget, not the separate web image limits.
    /// A failed collection retains existence metadata for DK4029, but publishes no partial render inputs.
    static func prepare(root: URL, literals: [String], maximumBytes: Int, maximumFiles: Int,
                        language: StudioLanguage = .english) -> Prepared {
        var folder: URL?
        var files: [String: DeskPackageFile] = [:], images: [String: ProgramImageResource] = [:]
        var sourceRecords: [Source] = [], resolved: [String: ProgramImageResource] = [:]
        var total = 0, failure: String?
        let byteLimit = min(maximumBytes, DeskCatalog.current.limits.maximumPackageBytes)
        do {
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("desk-program-images-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            folder = destination
        } catch { failure = message(.deskImagePreparationFailed, error.localizedDescription, language: language) }
        for literal in literals {
            do {
                let file = try openFile(in: root, literal: literal)
                defer { Darwin.close(file.fd) }
                sourceRecords.append(Source(literal: literal, resolved: file.path, stamp: file.stamp))
                if let previous = resolved[file.path] { images[literal] = previous; continue }
                // Register existence even if its bytes prove not to be a valid image. Decode failures have their
                // own explicit preview error; they must not mislabel another successfully found file as missing.
                files[file.path] = DeskPackageFile(path: file.path, kind: .image, size: Int(clamping: file.stamp.size))
                guard byteLimit >= 0, maximumFiles >= 0, files.count <= maximumFiles,
                      file.stamp.size <= Int64(byteLimit - total), let folder else { throw Failure.oversized(literal) }
                let count = Int(file.stamp.size)
                let data = try read(file, maximumBytes: byteLimit - total, literal: literal)
                total += count
                let suffix = (file.path as NSString).pathExtension
                let copy = folder.appendingPathComponent("image-\(resolved.count)." + suffix)
                // Metadata is bounded before invoking the existing decoder, including every icon frame the
                // decoder can choose. This also prevents unchecked products inside that legacy cache path.
                let natural = try naturalSize(data, literal: literal)
                try data.write(to: copy, options: .withoutOverwriting)
                guard let stamp = Images.imageStamp(atPath: copy.path) else { throw Failure.invalidImage(literal) }
                let value = ProgramImageResource(path: copy.path, naturalSize: natural, stamp: stamp)
                resolved[file.path] = value
                images[literal] = value
                files[file.path]?.pixelSize = DeskPixelSize(width: Int(natural.width), height: Int(natural.height))
            } catch {
                if failure == nil {
                    failure = (error as? Failure)?.message(in: language)
                        ?? message(.deskImagePreparationFailed, error.localizedDescription, language: language)
                }
            }
        }
        if failure != nil {
            if let folder { try? FileManager.default.removeItem(at: folder) }
            folder = nil; images = [:]
        }
        return Prepared(root: root, folder: folder, files: files.values.sorted { DeskPackagePath.precedes($0.path, $1.path) },
                        images: images, sources: sourceRecords, failure: failure)
    }

    private static func naturalSize(_ data: Data, literal: String) throws -> SkinSize {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw Failure.invalidImage(literal) }
        let type = (CGImageSourceGetType(source) as String?) ?? ""
        let icon = ["com.microsoft.ico", "com.microsoft.cur", "com.apple.icns"].contains(type)
        var largest = 0, chosen = SkinSize(), selected = 0
        for index in 0..<(icon ? min(CGImageSourceGetCount(source), 64) : 1) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
                throw Failure.invalidImage(literal)
            }
            let area = width.multipliedReportingOverflow(by: height)
            guard !area.overflow, area.partialValue <= 1 << 28 else { throw Failure.invalidImage(literal) }
            if index == 0 || area.partialValue > largest {
                largest = area.partialValue
                selected = index
                let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
                chosen = (5...8).contains(orientation) ? SkinSize(width: Double(height), height: Double(width))
                    : SkinSize(width: Double(width), height: Double(height))
            }
        }
        guard CGImageSourceGetStatus(source) == .statusComplete,
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, selected, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary), decoded.width > 0, decoded.height > 0 else { throw Failure.invalidImage(literal) }
        // This temporary real decode proves more than a header while retaining no full-size entries for all assets.
        return chosen
    }
}
