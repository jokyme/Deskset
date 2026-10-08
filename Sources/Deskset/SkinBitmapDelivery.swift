import AppKit
import DesksetCore
import DesksetDraw

/// Bitmap requests share one Main FIFO, so destination controls, pixels and explicit clears commit together.
/// Neither request transfers a drawing context or an executor's mutable capture.
enum SkinBitmapRequest {
    case frame(SkinBitmapDelivery)
    case clear(SkinBitmapInvalidation)
}

enum SkinBitmapDeliveryState: Equatable {
    case pending, applying, finished(accepted: Bool), cancelled
}

/// A synchronous, one-use claim. A claimed Main transaction cannot be stolen by owner cancellation.
private final class SkinBitmapClaim {
    private let value = Guarded<SkinBitmapDeliveryState>(.pending)
    var state: SkinBitmapDeliveryState { value.current }

    func claimOnMain() -> Bool {
        precondition(Thread.isMainThread)
        return value.access { state in
            guard state == .pending else { return false }
            state = .applying
            return true
        }
    }

    @discardableResult
    func finishOnMain(accepted: Bool) -> Bool {
        precondition(Thread.isMainThread)
        return value.access { state in
            guard state == .applying || (state == .pending && !accepted) else { return false }
            state = .finished(accepted: accepted)
            return true
        }
    }

    @discardableResult
    func cancel() -> Bool {
        value.access { state in
            guard state == .pending else { return false }
            state = .cancelled
            return true
        }
    }
}

/// Immutable inputs to one Main bitmap transaction. The producer retains its private capture until the ACK.
final class SkinBitmapDelivery {
    let content: SkinBitmapContent
    let scene: WidgetScene
    let origin: SkinPoint
    let space: CGColorSpace
    let appearance: String
    let panelGeneration: UInt64
    let serial: UInt64
    let lifecycle: UInt64
    private let claim = SkinBitmapClaim()
    var state: SkinBitmapDeliveryState { claim.state }

    init(content: SkinBitmapContent, scene: WidgetScene, origin: SkinPoint, space: CGColorSpace, appearance: String,
         panelGeneration: UInt64, serial: UInt64, lifecycle: UInt64) {
        self.content = content; self.scene = scene; self.origin = origin; self.space = space
        self.appearance = appearance; self.panelGeneration = panelGeneration; self.serial = serial
        self.lifecycle = lifecycle
    }

    convenience init(frame: SkinFrame, scene: WidgetScene, origin: SkinPoint, space: CGColorSpace, appearance: String,
                     panelGeneration: UInt64, serial: UInt64, lifecycle: UInt64) {
        self.init(content: .bitmap(frame), scene: scene, origin: origin, space: space, appearance: appearance,
                  panelGeneration: panelGeneration, serial: serial, lifecycle: lifecycle)
    }

    func claimOnMain() -> Bool { claim.claimOnMain() }
    @discardableResult func finishOnMain(accepted: Bool) -> Bool { claim.finishOnMain(accepted: accepted) }
    @discardableResult func cancel() -> Bool { claim.cancel() }
}

/// An explicit clear uses the same serial ordering and one-use claim as a frame. Recovery cancels an unclaimed
/// old clear before exporting its next picture; a clear already applying completes before that newer picture.
final class SkinBitmapInvalidation {
    let panelGeneration: UInt64
    let serial: UInt64
    let lifecycle: UInt64
    private let claim = SkinBitmapClaim()
    var state: SkinBitmapDeliveryState { claim.state }

    init(panelGeneration: UInt64, serial: UInt64, lifecycle: UInt64) {
        self.panelGeneration = panelGeneration; self.serial = serial; self.lifecycle = lifecycle
    }

    func claimOnMain() -> Bool { claim.claimOnMain() }
    @discardableResult func finishOnMain(accepted: Bool) -> Bool { claim.finishOnMain(accepted: accepted) }
    @discardableResult func cancel() -> Bool { claim.cancel() }
}
