import Foundation

/// Where a skin takes its random numbers (`Skin.random`): Calc's `Random` and `UniqueRandom`, QuotePlugin's pick, the
/// name of a WebParser download without `DownloadFile`, and Lua's `math.random` (the runtime design, "same inputs on
/// both sides").
///
/// `live()` is the system's generator, exactly what the engine used before (`Int.random(in:)`, `shuffled()`,
/// `UUID()`; Lua keeps the C library's `rand()`, one generator for the whole app). A seeded one (`init(seed:)`) gives
/// the same numbers on every run and every Mac: a stream of its own for each skin, and one for the skin's Lua scripts
/// that `math.randomseed` reseeds without touching other skins.
///
/// A `RandomNumberGenerator`, so `Int.random(in:using:)` and `shuffled(using:)` take it. Used on the skin's owner.
public final class SkinRandom: RandomNumberGenerator {
    /// The seed of a seeded generator; nil for the system's (`live()`).
    public let seed: UInt64?
    private var state: Xoshiro256?
    /// The Lua scripts' stream (seeded generators only), made at first use.
    private var luaState: Xoshiro256?

    /// The system's generator (a new object for every skin; they all draw from the system).
    public static func live() -> SkinRandom { SkinRandom(live: ()) }

    private init(live: Void) {
        seed = nil
        state = nil
    }

    /// A generator that gives the same numbers for the same seed.
    public init(seed: UInt64) {
        self.seed = seed
        state = Xoshiro256(seed: seed)
    }

    /// A seeded generator for one of several streams from one seed (a skin among several, by its config name): the
    /// streams do not depend on each other, nor on the order in which they are made.
    public convenience init(seed: UInt64, stream: String) {
        self.init(seed: SkinRandom.mix(seed, stream))
    }

    /// The system's generator.
    public var isLive: Bool { state == nil }

    public func next() -> UInt64 {
        guard state != nil else {
            var system = SystemRandomNumberGenerator()
            return system.next()
        }
        return state!.next()
    }

    /// An integer in `range` (Calc's `Random`, QuotePlugin): `Int.random(in:)` for the system's generator.
    public func int(in range: ClosedRange<Int>) -> Int {
        guard !isLive else { return Int.random(in: range) }
        var generator = self
        return Int.random(in: range, using: &generator)
    }

    /// An integer in `range`, which must not be empty.
    public func int(in range: Range<Int>) -> Int {
        guard !isLive else { return Int.random(in: range) }
        var generator = self
        return Int.random(in: range, using: &generator)
    }

    /// `values` in random order (Calc's `UniqueRandom` pool): `shuffled()` for the system's generator.
    public func shuffled<T>(_ values: [T]) -> [T] {
        guard !isLive else { return values.shuffled() }
        var generator = self
        return values.shuffled(using: &generator)
    }

    /// A random UUID string (`UUID().uuidString` for the system's generator; a version 4 UUID from the stream
    /// otherwise).
    public func uuidString() -> String {
        guard !isLive else { return UUID().uuidString }
        var bytes = [UInt8](repeating: 0, count: 16)
        for half in 0..<2 {
            var word = next()
            for i in 0..<8 {
                bytes[half * 8 + i] = UInt8(truncatingIfNeeded: word)
                word >>= 8
            }
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString
    }

    // MARK: Lua

    /// Lua's `math.random` source for a seeded generator: a number in [0, 1) from the skin's Lua stream (the system's
    /// generator never gets here: Lua keeps the C library's `rand()`).
    func luaUnit() -> Double {
        if luaState == nil { luaState = Xoshiro256(seed: SkinRandom.mix(seed ?? 0, "lua")) }
        return Double(luaState!.next() >> 11) * 0x1.0p-53
    }

    /// Lua's `math.randomseed(n)` for a seeded generator: the skin's Lua stream starts again from `n` (the same `n`
    /// gives the same numbers, as with C's `srand`), without touching other skins or the skin's own stream.
    func luaSeed(_ n: Int32) {
        luaState = Xoshiro256(seed: SkinRandom.mix(UInt64(bitPattern: Int64(n)), "lua.randomseed"))
    }

    // MARK: Streams

    /// A seed for stream `name` of `seed`: FNV-1a of the name's UTF-8 bytes, mixed with the seed (stable across
    /// runs and Macs, unlike Swift's hashing).
    static func mix(_ seed: UInt64, _ name: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        var s = SplitMix64(state: seed ^ hash)
        return s.next()
    }
}

/// SplitMix64 (Steele, Lea and Flood): seeds xoshiro256** from one 64-bit number.
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &+ 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// xoshiro256** (Blackman and Vigna, public domain): a small, fast generator with the same output on every platform.
struct Xoshiro256 {
    private var s0: UInt64, s1: UInt64, s2: UInt64, s3: UInt64

    init(seed: UInt64) {
        var mixer = SplitMix64(state: seed)
        s0 = mixer.next()
        s1 = mixer.next()
        s2 = mixer.next()
        s3 = mixer.next()
    }

    mutating func next() -> UInt64 {
        let result = rotl(s1 &* 5, 7) &* 9
        let t = s1 << 17
        s2 ^= s0
        s3 ^= s1
        s1 ^= s2
        s0 ^= s3
        s2 ^= t
        s3 = rotl(s3, 45)
        return result
    }

    private func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 { (x << k) | (x >> (64 - k)) }
}
