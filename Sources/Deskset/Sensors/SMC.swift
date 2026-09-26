import Foundation
import IOKit

// The System Management Controller (AppleSMC), read-only.
//
// An unprivileged process can open AppleSMC and send it request blocks through `IOConnectCallStructMethod`. Deskset
// only ever asks for a key's value, a key's type and size, and the name of the key at an index: `SMCCommand` lists
// exactly those three commands, a request can only be built from them, and `SMCConnection.send` checks every block
// against the list again right before it goes out. There is no code path that writes a key, so nothing here can change
// a fan, a power limit or any other setting.
//
// Layout of the 80-byte block (both directions), from observing the driver's replies:
//   0  key (UInt32, the four characters big-end first, stored in host order)
//   28 key info: data size (UInt32), data type (UInt32 four-character code), attributes (UInt8)
//   40 result (0 = success, 0x84 = no such key)      42 command
//   44 data32 (the index for "key at index")         48 up to 32 bytes of value

/// A four-character SMC key or data type ("TB0T", "flt ").
struct FourCC: Hashable, CustomStringConvertible {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Exactly four ASCII characters.
    init?(_ text: String) {
        let bytes = Array(text.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
        rawValue = bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    var description: String {
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: rawValue >> (24 - 8 * $0)) }
        return String(decoding: bytes.map { $0 >= 0x20 && $0 < 0x7f ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
    }
}

/// The only SMC commands Deskset sends. All of them read; there is deliberately no command that writes.
enum SMCCommand: UInt8, CaseIterable {
    /// The value of a key.
    case readKey = 5
    /// The name of the key at an index (0 ..< the value of `#KEY`).
    case readKeyAtIndex = 8
    /// A key's data size and type.
    case readKeyInfo = 9
}

/// Offsets in the request / reply block.
enum SMCBlock {
    static let size = 80
    /// The `IOConnectCallStructMethod` selector that takes a block.
    static let selector: UInt32 = 2
    static let key = 0, dataSize = 28, dataType = 32, attributes = 36, result = 40, command = 42, data32 = 44
    static let bytes = 48
    static let maxValueSize = 32
    /// `result` when the key does not exist.
    static let keyNotFound: UInt8 = 0x84

    /// True when `block` is a block Deskset may send: the right size and one of the read commands.
    static func isAllowed(_ block: [UInt8]) -> Bool {
        block.count == size && SMCCommand(rawValue: block[command]) != nil
    }
}

/// A request block. Built only from an `SMCCommand`, so it can only read.
struct SMCRequest {
    let bytes: [UInt8]

    init(_ command: SMCCommand, key: FourCC? = nil, index: UInt32 = 0, dataSize: Int = 0) {
        var block = [UInt8](repeating: 0, count: SMCBlock.size)
        block.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: key?.rawValue ?? 0, toByteOffset: SMCBlock.key, as: UInt32.self)
            raw.storeBytes(of: UInt32(clamping: dataSize), toByteOffset: SMCBlock.dataSize, as: UInt32.self)
            raw.storeBytes(of: index, toByteOffset: SMCBlock.data32, as: UInt32.self)
        }
        block[SMCBlock.command] = command.rawValue
        bytes = block
    }
}

/// A reply block.
struct SMCReply {
    let bytes: [UInt8]

    init?(_ bytes: [UInt8]) {
        guard bytes.count == SMCBlock.size else { return nil }
        self.bytes = bytes
    }

    private func word(_ offset: Int) -> UInt32 {
        bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    var result: UInt8 { bytes[SMCBlock.result] }
    var key: FourCC { FourCC(rawValue: word(SMCBlock.key)) }
    var dataSize: Int { Int(word(SMCBlock.dataSize)) }
    var dataType: FourCC { FourCC(rawValue: word(SMCBlock.dataType)) }

    /// The first `count` value bytes (at most 32).
    func value(count: Int) -> [UInt8] {
        Array(bytes[SMCBlock.bytes..<(SMCBlock.bytes + min(max(count, 0), SMCBlock.maxValueSize))])
    }
}

/// Numbers from SMC values. Integers and the 16-bit fixed-point types (Intel Macs) are big-endian; `flt ` (every
/// numeric key on Apple silicon) and `ioft` are little-endian.
enum SMCValue {
    /// nil for types that are not numbers (`ch8*`, `hex_`, `{…` structures) and for a size that does not match.
    static func decode(type: String, bytes d: [UInt8]) -> Double? {
        func bigEndian() -> UInt64 { d.reduce(0) { ($0 << 8) | UInt64($1) } }
        func littleEndian() -> UInt64 { d.reversed().reduce(0) { ($0 << 8) | UInt64($1) } }
        switch type {
        case "flt ":
            guard d.count == 4 else { return nil }
            let v = Double(Float(bitPattern: UInt32(littleEndian())))
            return v.isFinite ? v : nil
        case "ioft":
            guard d.count == 8 else { return nil }
            return Double(littleEndian()) / 65536
        case "ui8 ", "flag":
            return d.count == 1 ? Double(d[0]) : nil
        case "ui16":
            return d.count == 2 ? Double(bigEndian()) : nil
        case "ui32":
            return d.count == 4 ? Double(bigEndian()) : nil
        case "ui64":
            return d.count == 8 ? Double(bigEndian()) : nil
        case "si8 ":
            return d.count == 1 ? Double(Int8(bitPattern: d[0])) : nil
        case "si16":
            return d.count == 2 ? Double(Int16(bitPattern: UInt16(bigEndian()))) : nil
        case "si32":
            return d.count == 4 ? Double(Int32(bitPattern: UInt32(bigEndian()))) : nil
        case "si64":
            return d.count == 8 ? Double(Int64(bitPattern: bigEndian())) : nil
        default:
            // fpXY / spXY: 16-bit fixed point, X integer and Y fraction bits as hex digits (sp78 = signed 7.8,
            // fpe2 = unsigned 14.2).
            let c = Array(type.utf8)
            guard d.count == 2, c.count == 4,
                  let fraction = Int(String(UnicodeScalar(c[3])), radix: 16),
                  Int(String(UnicodeScalar(c[2])), radix: 16) != nil else { return nil }
            if c[0] == UInt8(ascii: "f"), c[1] == UInt8(ascii: "p") {
                return Double(bigEndian()) / Double(1 << fraction)
            }
            if c[0] == UInt8(ascii: "s"), c[1] == UInt8(ascii: "p") {
                return Double(Int16(bitPattern: UInt16(bigEndian()))) / Double(1 << fraction)
            }
            return nil
        }
    }

    /// Types `decode` reads.
    static func isNumeric(_ type: String) -> Bool {
        if ["flt ", "ioft", "ui8 ", "ui16", "ui32", "ui64", "si8 ", "si16", "si32", "si64", "flag"].contains(type) {
            return true
        }
        let c = Array(type.utf8)
        return c.count == 4 && (type.hasPrefix("fp") || type.hasPrefix("sp"))
            && Int(String(UnicodeScalar(c[2])), radix: 16) != nil && Int(String(UnicodeScalar(c[3])), radix: 16) != nil
    }
}

/// A key's size and type.
struct SMCKeyInfo: Equatable, Codable {
    var size: Int
    var type: String
}

/// An open connection to AppleSMC. Not thread-safe: the sensor service uses it on its queue only.
final class SMCConnection {
    private var connection: io_connect_t = 0
    private var infos: [FourCC: SMCKeyInfo?] = [:]
    /// Blocks sent (tests of the allow-list count them).
    private(set) var sent = 0

    /// nil when there is no AppleSMC (a virtual machine may have none) or it cannot be opened.
    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connect) == KERN_SUCCESS, connect != 0 else { return nil }
        connection = connect
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// Sends one block; nil when the call fails or the block is not an allowed read (then nothing is sent).
    func send(_ request: SMCRequest) -> SMCReply? {
        guard SMCBlock.isAllowed(request.bytes) else { return nil }
        var input = request.bytes
        var output = [UInt8](repeating: 0, count: SMCBlock.size)
        var outputSize = SMCBlock.size
        sent += 1
        let status = input.withUnsafeMutableBytes { inBuffer in
            output.withUnsafeMutableBytes { outBuffer in
                IOConnectCallStructMethod(connection, SMCBlock.selector, inBuffer.baseAddress, SMCBlock.size,
                                          outBuffer.baseAddress, &outputSize)
            }
        }
        guard status == KERN_SUCCESS, outputSize == SMCBlock.size else { return nil }
        return SMCReply(output)
    }

    /// Size and type of `key` (cached); nil when the key does not exist.
    func info(_ key: FourCC) -> SMCKeyInfo? {
        if let cached = infos[key] { return cached }
        var result: SMCKeyInfo?
        if let reply = send(SMCRequest(.readKeyInfo, key: key)), reply.result == 0 {
            result = SMCKeyInfo(size: reply.dataSize, type: reply.dataType.description)
        }
        if infos.count < 8192 { infos[key] = result }
        return result
    }

    /// Adds known key infos (from the key list saved on disk), so reading them needs no info request.
    func remember(_ known: [String: SMCKeyInfo]) {
        for (name, info) in known {
            if let key = FourCC(name), infos.count < 8192 { infos[key] = info }
        }
    }

    /// The raw value of `key`.
    func read(_ key: FourCC) -> (info: SMCKeyInfo, bytes: [UInt8])? {
        guard let info = info(key), info.size > 0, info.size <= SMCBlock.maxValueSize,
              let reply = send(SMCRequest(.readKey, key: key, dataSize: info.size)), reply.result == 0 else { return nil }
        return (info, reply.value(count: info.size))
    }

    /// The number a key holds; nil when it does not exist or is not a number.
    func number(_ key: String) -> Double? {
        guard let fourCC = FourCC(key), let raw = read(fourCC) else { return nil }
        return SMCValue.decode(type: raw.info.type, bytes: raw.bytes)
    }

    /// How many keys the SMC has (`#KEY`).
    func keyCount() -> Int {
        guard let raw = FourCC("#KEY").flatMap(read), raw.bytes.count == 4 else { return 0 }
        return Int(raw.bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
    }

    /// The name of the key at `index`.
    func key(at index: Int) -> FourCC? {
        guard index >= 0, let reply = send(SMCRequest(.readKeyAtIndex, index: UInt32(index))), reply.result == 0
        else { return nil }
        return reply.key
    }
}
