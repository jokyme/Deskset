import CoreGraphics
import Foundation
import QuartzCore

/// A one-frame, contentRoot-only writer transfer. It never transfers the SkinExecutor, drawing context or caches.
/// The main host must finish its transaction before acknowledging. This mutable capability is not Sendable.
package final class ScenePatch {
    package enum State: Equatable { case pending, applying, appliedByMain, reclaimedBySkin }
    package enum Reclamation: Equatable { case timeout, invalidated }
    package let frame: LayerRuntime.Frame
    package let root: CALayer
    package let bounds: CGRect
    private let layers: [CALayer]
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var stateValue = State.pending
    private var reclamationValue: Reclamation?
    private var contentApplied = false

    // Only LayerRuntime exports a capability for its current pending preparation.
    init(frame: LayerRuntime.Frame, root: CALayer, bounds: CGRect, layers: [CALayer]) {
        self.frame = frame
        self.root = root
        self.bounds = bounds
        self.layers = layers
    }

    package var state: State {
        lock.lock()
        defer { lock.unlock() }
        return stateValue
    }

    package var reclamation: Reclamation? {
        lock.lock()
        defer { lock.unlock() }
        return reclamationValue
    }

    /// Claim BEFORE touching either the root or its host. No leaf lock is held across AppKit or CA calls.
    package func claimOnMain() -> Bool {
        precondition(Thread.isMainThread)
        lock.lock()
        defer { lock.unlock() }
        guard stateValue == .pending else { return false }
        stateValue = .applying
        return true
    }

    /// An authentic, currently claimed writer, not an executor ownership assertion.
    package func isMainWriter(for root: CALayer) -> Bool {
        Thread.isMainThread && self.root === root && state == .applying
    }

    /// The host supplies the surrounding disabled-actions transaction. No drawing or owner metadata runs here.
    @discardableResult
    package func applyContentOnMain() -> Bool {
        precondition(Thread.isMainThread)
        guard isMainWriter(for: root), !contentApplied else { return false }
        root.bounds = bounds
        root.sublayers = layers
        contentApplied = true
        return true
    }

    /// Release the writer only AFTER the host's transaction commits. A rejected claim has not touched the root.
    package func finishOnMain() {
        precondition(Thread.isMainThread)
        lock.lock()
        precondition(stateValue == .applying)
        if contentApplied { stateValue = .appliedByMain }
        else { stateValue = .reclaimedBySkin; reclamationValue = .invalidated }
        lock.unlock()
        completion.signal()
    }

    /// Exactly one side may reclaim an unclaimed patch. Applying cannot be stolen, even at the deadline.
    @discardableResult
    package func reclaim(_ reason: Reclamation) -> Bool {
        lock.lock()
        guard stateValue == .pending else { lock.unlock(); return false }
        stateValue = .reclaimedBySkin
        reclamationValue = reason
        lock.unlock()
        completion.signal()
        return true
    }

    /// The worker stops waiting at 50 ms. If main already claimed, logic resumes but tree mutation must await ack.
    /// Scheduling can overshoot this deadline; this is not a bound on a claimed AppKit transaction's duration.
    package func waitForMain() -> State {
        precondition(!Thread.isMainThread)
        _ = completion.wait(timeout: .now() + 0.050)
        _ = reclaim(.timeout)
        return state
    }
}
