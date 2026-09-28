import Foundation

// The service's tree walkers recurse: into nested blocks (the outline, the options panels), up and down member chains
// and nested expressions (completion's member bases and expected types), and into types. A background queue's thread
// has 512 KiB of stack, which hostile nesting would overflow. So every request that walks the tree runs where the
// stack is large enough for the snapshot's tree, as the parser and the checker do (`StackGuard`): on the calling
// thread when it has room, otherwise on a thread with a larger stack, waited for. A request begins with
//
//     guard hasStackRoom else { return onLargeStack { request(…) } }
//
// and asks itself again there, where there is room.

extension DeskSnapshot {
    /// The stack a request on this snapshot may need: the tree's bracket nesting or its node depth (long chains nest
    /// without brackets), whichever is more, at the checker's budget per level; at most 256 MiB, which leaves the
    /// larger stack room for the request itself.
    var stackNeeded: Int {
        caches.stackNeeded.value {
            let levels = max(StackGuard.nestingEstimate(tree.lines.bytes), tree.root.depth + 4)
            return min(levels * StackGuard.bytesPerNestingLevel, 256 << 20)
        }
    }

    /// Whether the current thread's stack has room for this snapshot's requests.
    var hasStackRoom: Bool { StackGuard.remainingStackBytes() > stackNeeded + (256 << 10) }

    /// Runs a request on a thread whose stack is large enough and waits for it (when `hasStackRoom` is false).
    func onLargeStack<T>(_ request: () -> T) -> T {
        StackGuard.run(needing: stackNeeded, request)
    }
}
