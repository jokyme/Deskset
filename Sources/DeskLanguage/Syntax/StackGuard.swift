import Foundation

/// Runs deep recursive work where the stack is large enough (§2.11 rule 7: hostile input must not overflow the
/// stack). The parser nests at most 64 blocks and 128 expression levels, but in a debug build one expression level
/// takes tens of kilobytes of stack, and threads other than the main thread have only 512 KiB. Work whose estimated
/// need does not fit in what is left of the current thread's stack runs on a thread of its own with a larger one.
/// Tree walkers that recurse (the checker, lowering) can use the same guard; syntax trees can be several hundred
/// levels deep.
public enum StackGuard {
    /// Stack a caller should budget per nesting level (a block, a bracket, an interpolation) of a Desk file.
    public static var bytesPerNestingLevel: Int {
        #if DEBUG
        return 96 * 1024
        #else
        return 24 * 1024
        #endif
    }

    /// The stack size of the helper thread: enough for the deepest file the limits allow.
    public static var largeStackSize: Int {
        let levels = SyntaxLimits.maxBlockDepth + SyntaxLimits.maxExpressionDepth + 64
        return max(16 << 20, (levels * bytesPerNestingLevel + (1 << 20)) & ~0xFFF)
    }

    /// Bytes left between the current stack pointer and the end of the current thread's stack.
    public static func remainingStackBytes() -> Int {
        let thread = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        let size = UInt(pthread_get_stacksize_np(thread))
        var marker: UInt8 = 0
        let here = withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
        let bottom = top &- size
        return here > bottom ? Int(here - bottom) : 0
    }

    /// Runs `body` here when `neededBytes` (plus a margin) fit in the current stack, otherwise on a thread with
    /// `largeStackSize` of stack, waiting for it.
    public static func run<T>(needing neededBytes: Int, _ body: () -> T) -> T {
        if remainingStackBytes() > neededBytes + (256 << 10) { return body() }
        return withoutActuallyEscaping(body) { escapable in
            // The thread holds only the box; the box lets go of the closure before the waiter wakes up, so the
            // closure never outlives this call.
            let work = Work<T>(escapable)
            let done = DispatchSemaphore(value: 0)
            let thread = Thread { [work] in
                work.result = work.job?()
                work.job = nil
                done.signal()
            }
            thread.stackSize = largeStackSize
            thread.name = "Desk large stack"
            thread.start()
            done.wait()
            return work.result!
        }
    }

    /// An upper bound on how deeply `bytes` nest: the deepest nesting of `(`, `[` and `{` (braces of blocks and
    /// interpolations alike), plus the number of `?` (a chain of ternaries nests on its last branch).
    static func nestingEstimate(_ bytes: [UInt8]) -> Int {
        var depth = 0
        var deepest = 0
        var questions = 0
        var k = 0
        let n = bytes.count
        while k < n {
            var b = bytes[k]
            var length = 1
            if b >= 0x80 {
                // Full-width brackets, 「」 and the like count as the brackets they stand for.
                let lead = b
                length = lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4
                var value = UInt32(lead & (lead < 0xE0 ? 0x1F : lead < 0xF0 ? 0x0F : 0x07))
                var m = 1
                while m < length, k + m < n { value = (value << 6) | UInt32(bytes[k + m] & 0x3F); m += 1 }
                switch value {
                case 0x300C, 0x300E: b = 0x7B
                case 0x300D, 0x300F: b = 0x7D
                default: b = Chars.mappedPunctuation(value) ?? 0
                }
            }
            switch b {
            case 0x28, 0x5B, 0x7B:
                depth += 1
                if depth > deepest { deepest = depth }
            case 0x29, 0x5D, 0x7D:
                if depth > 0 { depth -= 1 }
            case 0x3F:
                questions += 1
            default:
                break
            }
            k += length
        }
        let levels = SyntaxLimits.maxBlockDepth + SyntaxLimits.maxExpressionDepth
        return min(deepest + questions, levels) + 4
    }

    private final class Work<T>: @unchecked Sendable {
        var job: (() -> T)?
        var result: T?
        init(_ job: @escaping () -> T) { self.job = job }
    }
}
