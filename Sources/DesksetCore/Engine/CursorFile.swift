import Foundation

/// Custom cursor files for `MouseActionCursorName` (manual: "If a custom cursor file (i.e. .cur or .ani) is found in
/// @Resources\Cursors in the root config folder of a skin, it will be automatically loaded … No path is used in the
/// option"). Only the file structure is read here; the host decodes the images.
///
/// - `.cur` (and `.ico`): a directory of images, each with its size and, for cursors, its hot spot.
/// - `.ani`: a RIFF `ACON` file whose `LIST fram` holds `icon` chunks, each a complete `.cur` / `.ico` file; an optional
///   `seq ` chunk gives the order of the frames. Deskset shows the first frame of the sequence (no animation).
public enum CursorFile {
    /// One image of a `.cur` / `.ico` directory, in file order (the index an image decoder uses).
    public struct Entry: Equatable, Sendable {
        public var index: Int
        public var width: Int
        public var height: Int
        /// Hot spot in pixels from the top-left corner; (0, 0) for `.ico` images.
        public var hotSpotX: Int
        public var hotSpotY: Int
    }

    /// `@Resources\Cursors` of a skin's root config.
    public static func directory(skinsDirectory: URL, config: String) -> URL {
        let root = String(config.split(separator: "\\").first ?? Substring(config))
        return skinsDirectory.appendingPathComponent(root, isDirectory: true)
            .appendingPathComponent("@Resources", isDirectory: true)
            .appendingPathComponent("Cursors", isDirectory: true)
    }

    /// The file a `MouseActionCursorName` value names in `directory`, or nil: built-in names, names with a path, and
    /// other extensions than `.cur` / `.ani` name no file. The lookup ignores case, as Windows does.
    public static func file(named name: String, in directory: URL) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let ext = (trimmed as NSString).pathExtension.lowercased()
        guard ext == "cur" || ext == "ani", !trimmed.contains("/"), !trimmed.contains("\\"),
              trimmed != ".", trimmed != ".." else { return nil }
        let fm = FileManager.default
        func isFile(_ name: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
        // The listing gives the file's own spelling on case-insensitive and case-sensitive volumes alike.
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let match = names.first { $0 == trimmed && isFile($0) }
            ?? names.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame && isFile($0) }
        return match.map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    /// The image directory of a `.cur` / `.ico` file; empty when the data is not one.
    public static func entries(in data: Data) -> [Entry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 6, u16(bytes, 0) == 0 else { return [] }
        let type = u16(bytes, 2), count = Int(u16(bytes, 4))
        guard type == 1 || type == 2, count > 0, count <= 256, bytes.count >= 6 + count * 16 else { return [] }
        return (0..<count).map { i in
            let o = 6 + i * 16
            // A stored 0 means 256 pixels.
            let width = bytes[o] == 0 ? 256 : Int(bytes[o]), height = bytes[o + 1] == 0 ? 256 : Int(bytes[o + 1])
            let cursor = type == 2
            return Entry(index: i, width: width, height: height,
                         hotSpotX: cursor ? min(Int(u16(bytes, o + 4)), width - 1) : 0,
                         hotSpotY: cursor ? min(Int(u16(bytes, o + 6)), height - 1) : 0)
        }
    }

    /// The entry to show at `pointSize` points on a display with `scale` pixels per point: the smallest image at least
    /// that many pixels wide, else the largest.
    public static func bestEntry(_ entries: [Entry], pointSize: Int = 32, scale: Double = 1) -> Entry? {
        let wanted = Int((Double(pointSize) * max(scale, 1)).rounded())
        let bySize = entries.sorted { ($0.width, $0.index) < ($1.width, $1.index) }
        return bySize.first { $0.width >= wanted } ?? bySize.last
    }

    /// The first frame of an `.ani` file (following its `seq ` chunk) as a `.cur` / `.ico` file; nil when the data is
    /// not an animated cursor.
    public static func firstAnimatedFrame(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("ACON".utf8)
        else { return nil }
        var frames: [Range<Int>] = []
        var sequence: [Int] = []
        func walk(_ start: Int, _ end: Int, inFrames: Bool) {
            var o = start
            while o + 8 <= end {
                let id = String(decoding: bytes[o..<(o + 4)], as: UTF8.self)
                let size = Int(u32(bytes, o + 4))
                let body = o + 8
                guard size >= 0, body + size <= end else { return }
                switch id {
                case "LIST" where size >= 4 && String(decoding: bytes[body..<(body + 4)], as: UTF8.self) == "fram":
                    walk(body + 4, body + size, inFrames: true)
                case "icon" where inFrames:
                    frames.append(body..<(body + size))
                case "seq " where !inFrames:
                    sequence = stride(from: body, to: body + size - 3, by: 4).map { Int(u32(bytes, $0)) }
                default:
                    break
                }
                o = body + size + (size & 1)
            }
        }
        walk(12, bytes.count, inFrames: false)
        guard !frames.isEmpty else { return nil }
        let first = sequence.first.flatMap { $0 < frames.count ? $0 : nil } ?? 0
        return Data(bytes[frames[first]])
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}
