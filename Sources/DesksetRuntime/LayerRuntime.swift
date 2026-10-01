import CoreFoundation
import CoreGraphics
import DesksetCore
import DesksetDraw
import Foundation
import QuartzCore

/// C content and a small lifecycle on one SkinExecutor. This mutable owner is not Sendable.
/// The caller attaches root on main. Its writer is this owner, or an explicitly claimed ScenePatch until ack.
/// Candidate Components remain geometry, not certified raster coverage or a default window presentation policy.
package final class LayerRuntime {
    package enum State: Equatable { case loading, live, hidden, refreshing, closing, closed }
    package enum Partition: Equatable { case single, candidateComponents }
    package enum Failure: Error, Equatable {
        case wrongOwner
        case invalidLifecycle(State)
        case reentrant
        case sequenceOverflow
        case stalePreparation
        case transferredWriter
    }
    package enum Fallback: Equatable {
        case unresolvedInk(ElementID, InkBounds.Unknown)
    }
    package enum Reason: Equatable {
        case initial, refresh, released, previousFailure, destination, partition, cycle, scene, preparation
        case drawingContext, unversionedRecipe
        case discardedPreparation, hostPresentation
        case missingImageStamp(String)
    }
    package enum Change: Equatable { case all(Reason), unchanged }
    package struct Frame {
        package let sequence: UInt64
        package let plan: PartitionPlan
        package let contents: [LayerContentBuilder.Content]
        package let scale: CGFloat
        package let colorSpace: CGColorSpace
        package let fallback: Fallback?
        package let change: Change
    }
    package enum Update { case submitted(Frame), unchanged(Frame), suppressed }

    /// Finished immutable contents, not a committed frame or a cross-thread ownership lease. The proposed sequence
    /// can occur again after cancellation; only commit advances the owner's sequence. No owner/context is retained.
    package final class PreparedFrame {
        package let frame: Frame
        fileprivate init(_ frame: Frame) { self.frame = frame }
    }
    package enum Preparation { case ready(PreparedFrame), unchanged(Frame), suppressed }

    private final class NoActionsLayer: CALayer {
        override func action(forKey event: String) -> CAAction? { nil }
    }

    /// Only a weak context identity is retained. Its drawing services have no common public version,
    /// so identity alone never authorizes reuse for recipes that consult those services.
    private final class Key {
        let prepared: SceneInkCandidates
        let window: InkBounds.DeviceRect
        let scale: CGFloat
        let colorSpace: CGColorSpace
        let partition: Partition
        let cycle: Int
        let glass: GlassPaint
        weak var context: DrawContext?

        init(_ prepared: SceneInkCandidates, window: InkBounds.DeviceRect, scale: CGFloat,
             colorSpace: CGColorSpace, partition: Partition, context: DrawContext, cycle: Int, glass: GlassPaint) {
            self.prepared = prepared
            self.window = window
            self.scale = scale
            self.colorSpace = colorSpace
            self.partition = partition
            self.context = context
            self.cycle = cycle
            self.glass = glass
        }
    }

    private struct Configuration {
        let plan: PartitionPlan
        let scale: CGFloat
        let colorSpace: CGColorSpace
        func matches(_ plan: PartitionPlan, _ scale: CGFloat, _ colorSpace: CGColorSpace) -> Bool {
            self.plan == plan && self.scale == scale && CFEqual(self.colorSpace, colorSpace)
        }
    }

    private struct Pending {
        let presentation: PreparedFrame
        let builder: LayerContentBuilder
        let key: Key
        let bounds: CGRect
        let layerFrames: [CGRect]
        let retainedBase: [ElementID]?
    }

    package let root: CALayer
    /// These mutable observations are read only on the executor. Finished images do not retain this owner.
    package private(set) var state = State.loading
    package private(set) var currentFrame: Frame?
    private let executor: any SkinExecutor
    private let maximumOwnedBitmapBytes: Int
    private var builder: LayerContentBuilder?
    private var configuration: Configuration?
    private var pending: Pending?
    private var transferred: ScenePatch?
    private var key: Key?
    private var sequence: UInt64 = 0
    private var updating = false
    private var forcedReason: Reason? = .initial
    private var frozenBase: [ElementID]?
    private var baseWindow: InkBounds.DeviceRect?
    private var baseScale: CGFloat?
    private var basePartition: Partition?

    /// The C builder's bitmap budget excludes retained snapshots, old/new builder overlap and CA storage.
    /// It is not a total runtime/process cap; no 4x policy is inferred here.
    package init(executor: any SkinExecutor, maximumOwnedBitmapBytes: Int) throws {
        guard executor.isCurrent else { throw Failure.wrongOwner }
        guard maximumOwnedBitmapBytes > 0 else { throw Rasterizer.Failure.invalidInput("Owned bitmap budget must be positive") }
        self.executor = executor
        self.maximumOwnedBitmapBytes = maximumOwnedBitmapBytes
        root = NoActionsLayer()
        root.anchorPoint = .zero
        root.position = .zero
        root.bounds = .zero
        root.contentsFormat = .RGBA8Uint
    }

    /// The original synchronous operation: prepare complete images, then commit them on the same owner.
    package func update(_ prepared: SceneInkCandidates, in window: InkBounds.DeviceRect,
                        scale: CGFloat, colorSpace: CGColorSpace, partition: Partition,
                        context: DrawContext, cycle: Int, glass: GlassPaint) throws -> Update {
        switch try prepare(prepared, in: window, scale: scale, colorSpace: colorSpace, partition: partition,
                           context: context, cycle: cycle, glass: glass) {
        case .ready(let presentation): return .submitted(try commit(presentation))
        case .unchanged(let reused):
            currentFrame = reused
            return .unchanged(reused)
        case .suppressed: return .suppressed
        }
    }

    /// Preparation must come from this scene's owner and the same actual destination mapping/profile.
    /// SceneInkCandidates cannot prove that provenance, or native ink coverage, retrospectively.
    /// No visible tree, current frame, committed sequence or frozen base is changed, even after successful drawing.
    /// One pending preparation is retained: a new call supersedes it. A hidden call does no validation or drawing;
    /// closing/closed and wrong-owner calls are rejected first. This is not the App's ScenePatch handoff protocol.
    package func prepare(_ prepared: SceneInkCandidates, in window: InkBounds.DeviceRect,
                        scale: CGFloat, colorSpace: CGColorSpace, partition: Partition,
                        context: DrawContext, cycle: Int, glass: GlassPaint,
                        forcePresentation: Bool = false) throws -> Preparation {
        try checkOwner()
        guard !updating else { throw Failure.reentrant }
        guard transferred == nil else { throw Failure.transferredWriter }
        switch state {
        case .hidden: return .suppressed
        case .closing, .closed: throw Failure.invalidLifecycle(state)
        case .loading, .live, .refreshing: break
        }
        discardPending()
        updating = true
        defer { updating = false }
        do {
            guard scale.isFinite, scale > 0 else { throw Rasterizer.Failure.invalidInput("Scale must be finite and positive") }
            guard colorSpace.model == .rgb else { throw Rasterizer.Failure.incompatibleColorSpace }
            let scene = prepared.scene
            guard prepared.elementInk.count == scene.elements.count,
                  prepared.runInk.count == scene.topLevelElements.count + 1 else {
                throw Rasterizer.Failure.invalidPlan("Preparation must retain the complete scene order")
            }
            guard Set(scene.elements.map(\.id)).count == scene.elements.count,
                  Set(scene.elements.map { $0.id.index }).count == scene.elements.count else {
                throw Rasterizer.Failure.invalidPlan("Scene IDs and file occurrences must be unique")
            }
            // Base membership is reconsidered for a new strategy, device window or scale, and on refresh/reveal.
            let retainedBase = baseWindow == window && baseScale == scale && basePartition == partition ? frozenBase : nil
            let plan: PartitionPlan
            let fallback: Fallback?
            switch partition {
            case .single:
                plan = SinglePartition.plan(in: window)
                fallback = nil
            case .candidateComponents:
                do {
                    plan = try ComponentPartition.candidatePlan(prepared, in: window, baseMembers: retainedBase)
                    fallback = nil
                } catch let ComponentPartition.Failure.unresolvedInk(id, reason) {
                    plan = SinglePartition.plan(in: window)
                    fallback = .unresolvedInk(id, reason)
                }
            }
            let mode = try LayerContentBuilder.validateGeometry(plan)
            _ = try LayerContentBuilder.resolve(scene, plan: plan, scale: scale, mode: mode)
            let rootBounds = CGRect(x: 0, y: 0, width: CGFloat(window.width) / scale, height: CGFloat(window.height) / scale)
            let frames = plan.layers.map { layer in
                CGRect(x: CGFloat(layer.rect.minX) / scale, y: CGFloat(layer.rect.minY) / scale,
                       width: CGFloat(layer.rect.width) / scale, height: CGFloat(layer.rect.height) / scale)
            }
            guard Self.finite(rootBounds), frames.allSatisfy(Self.finite) else {
                throw Rasterizer.Failure.invalidInput("Layer point geometry is not finite at this scale")
            }
            let incoming = Key(prepared, window: window, scale: scale, colorSpace: colorSpace,
                               partition: partition, context: context, cycle: cycle, glass: glass)
            if !forcePresentation, let old = currentFrame, let key, self.reason(from: key, to: incoming, plan: plan) == nil {
                let reused = Frame(sequence: old.sequence, plan: old.plan, contents: old.contents,
                                   scale: old.scale, colorSpace: old.colorSpace, fallback: old.fallback, change: .unchanged)
                return .unchanged(reused)
            }
            let invalidation = key.flatMap { self.reason(from: $0, to: incoming, plan: plan) } ?? forcedReason ?? (forcePresentation ? .hostPresentation : .initial)
            let (nextSequence, overflow) = sequence.addingReportingOverflow(1)
            guard !overflow else { throw Failure.sequenceOverflow }
            // Drawing may warm caches even if a later allocation fails. An attempt invalidates reuse first.
            key = nil
            let nextBuilder: LayerContentBuilder
            if let builder, configuration?.matches(plan, scale, colorSpace) == true {
                nextBuilder = builder
            } else {
                nextBuilder = try LayerContentBuilder(plan: plan, scale: scale, colorSpace: colorSpace,
                                                       maximumOwnedBitmapBytes: maximumOwnedBitmapBytes)
            }
            let contents = try nextBuilder.build(scene, context: context, cycle: cycle, glass: glass)
            let frame = Frame(sequence: nextSequence, plan: plan, contents: contents, scale: scale,
                              colorSpace: colorSpace, fallback: fallback, change: .all(invalidation))
            let presentation = PreparedFrame(frame)
            pending = Pending(presentation: presentation, builder: nextBuilder, key: incoming, bounds: rootBounds,
                              layerFrames: frames, retainedBase: retainedBase)
            return .ready(presentation)
        } catch {
            pending = nil
            key = nil
            builder = nil
            configuration = nil
            forcedReason = .previousFailure
            throw error
        }
    }

    /// Only the actual owner may install the current candidate. Stale/foreign/repeated tokens are rejected before
    /// tree/cache changes; this does not confer permission to commit from main while a worker owns the runtime.
    package func commit(_ presentation: PreparedFrame) throws -> Frame {
        try checkOwner()
        guard !updating else { throw Failure.reentrant }
        guard transferred == nil else { throw Failure.transferredWriter }
        switch state {
        case .hidden, .closing, .closed: throw Failure.invalidLifecycle(state)
        case .loading, .live, .refreshing: break
        }
        guard let pending, pending.presentation === presentation else { throw Failure.stalePreparation }
        updating = true
        defer { updating = false }
        let frame = presentation.frame
        let layers = makeLayers(frame, frames: pending.layerFrames)
        transaction {
            root.bounds = pending.bounds
            root.sublayers = layers
        }
        accept(pending)
        return frame
    }

    /// Only the owner may export its exact pending token. PreparedFrame itself never grants tree access.
    package func transfer(_ presentation: PreparedFrame) throws -> ScenePatch {
        try checkMutable()
        guard let pending, pending.presentation === presentation else { throw Failure.stalePreparation }
        let patch = ScenePatch(frame: presentation.frame, root: root, bounds: pending.bounds,
                               layers: makeLayers(presentation.frame, frames: pending.layerFrames))
        transferred = patch
        return patch
    }

    /// Owner-only metadata acknowledgment. Applying keeps the preparation and its caches intact, without waiting.
    /// A timeout may use the original ordinary commit; an invalidation (or closing) only discards its candidate.
    package func finish(_ patch: ScenePatch, commitReclaimed: Bool) throws -> Update? {
        try checkOwner()
        guard !updating else { throw Failure.reentrant }
        guard transferred === patch, let pending else { throw Failure.stalePreparation }
        switch patch.state {
        case .pending, .applying: return nil
        case .appliedByMain:
            transferred = nil
            accept(pending)
            return .submitted(patch.frame)
        case .reclaimedBySkin:
            transferred = nil
            if commitReclaimed && patch.reclamation == .timeout {
                return .submitted(try commit(pending.presentation))
            }
            discardPending()
            return .suppressed
        }
    }

    /// A currently transferred tree cannot be cleared, re-prepared or acquired through an ordinary executor park.
    package var hasTransferredWriter: Bool {
        precondition(executor.isCurrent)
        return transferred != nil
    }

    private func makeLayers(_ frame: Frame, frames: [CGRect]) -> [CALayer] {
        frame.contents.enumerated().map { index, content in
            let layer = NoActionsLayer()
            layer.anchorPoint = .zero
            layer.frame = frames[index]
            layer.contents = content.image
            layer.contentsRect = content.contentsRect
            layer.contentsScale = frame.scale
            layer.contentsFormat = .RGBA8Uint
            layer.contentsGravity = .resize
            layer.needsDisplayOnBoundsChange = false
            layer.drawsAsynchronously = false
            layer.isOpaque = false
            layer.magnificationFilter = .nearest
            layer.minificationFilter = .nearest
            return layer
        }
    }

    private func accept(_ pending: Pending) {
        let frame = pending.presentation.frame
        builder = pending.builder
        configuration = Configuration(plan: frame.plan, scale: frame.scale, colorSpace: frame.colorSpace)
        key = pending.key
        sequence = frame.sequence
        currentFrame = frame
        state = .live
        forcedReason = nil
        if pending.key.partition == .candidateComponents {
            if frame.fallback == nil { frozenBase = frame.plan.baseMembers }
            else { frozenBase = pending.retainedBase }
            baseWindow = pending.key.window
            baseScale = pending.key.scale
            basePartition = pending.key.partition
        } else {
            clearBase()
        }
        self.pending = nil
    }

    /// Explicit cancellation keeps the displayed frame. Drawing may already have warmed caches, so reuse is
    /// conservatively invalidated. A stale caller cannot discard the newer candidate retained by this owner.
    package func discard(_ presentation: PreparedFrame) throws {
        try checkMutable()
        guard pending?.presentation === presentation else { throw Failure.stalePreparation }
        discardPending()
    }

    private func discardPending() {
        guard pending != nil else { return }
        pending = nil
        key = nil
        builder = nil
        configuration = nil
        forcedReason = .discardedPreparation
    }

    /// Retain the successful old frame while the replacement is prepared. A failed update stays refreshing.
    package func beginRefresh() throws {
        try checkMutable()
        guard state == .live || state == .refreshing || state == .hidden else { throw Failure.invalidLifecycle(state) }
        if state != .hidden { state = .refreshing }
        pending = nil
        key = nil
        forcedReason = .refresh
        clearBase()
    }

    /// Visibility comes from the caller. Revealing has no frame until a full successful owner update.
    package func setVisible(_ visible: Bool) throws {
        try checkMutable()
        if visible {
            if state == .hidden { state = .loading; forcedReason = .released }
        } else if state != .hidden {
            clearContents()
            state = .hidden
            forcedReason = .released
        }
    }

    /// Stop drawing while keeping the final immutable images for the caller's fade-out.
    package func beginClose() throws {
        try checkOwner()
        guard !updating else { throw Failure.reentrant }
        guard transferred == nil else { throw Failure.transferredWriter }
        guard state != .closed else { throw Failure.invalidLifecycle(state) }
        state = .closing
        pending = nil
        key = nil
        builder = nil
        configuration = nil
        clearBase()
    }

    /// The main host removes root after this owner-side cleanup; the runtime does not mutate the view's layer.
    package func close() throws {
        try checkOwner()
        guard !updating else { throw Failure.reentrant }
        guard transferred == nil else { throw Failure.transferredWriter }
        if state == .closed { return }
        clearContents()
        state = .closed
    }

    private func checkOwner() throws {
        guard executor.isCurrent else { throw Failure.wrongOwner }
    }

    private func checkMutable() throws {
        try checkOwner()
        guard !updating else { throw Failure.reentrant }
        guard transferred == nil else { throw Failure.transferredWriter }
        guard state != .closing, state != .closed else { throw Failure.invalidLifecycle(state) }
    }

    private func clearContents() {
        pending = nil
        transaction {
            for layer in root.sublayers ?? [] { layer.contents = nil }
            root.sublayers = []
        }
        currentFrame = nil
        builder = nil
        configuration = nil
        key = nil
        clearBase()
    }

    private func clearBase() {
        frozenBase = nil
        baseWindow = nil
        baseScale = nil
        basePartition = nil
    }

    private func reason(from old: Key, to next: Key, plan: PartitionPlan) -> Reason? {
        if let forcedReason { return forcedReason }
        let dependencies = next.prepared.scene.backgroundImageDependencies + next.prepared.scene.elements.flatMap(\.imageDependencies)
        if let unknown = dependencies.first(where: { $0.stamp == nil }) { return .missingImageStamp(unknown.path) }
        if old.window != next.window || old.scale != next.scale || !CFEqual(old.colorSpace, next.colorSpace) { return .destination }
        if old.partition != next.partition || currentFrame?.plan != plan { return .partition }
        if old.cycle != next.cycle { return .cycle }
        if old.glass != next.glass || old.prepared.scene != next.prepared.scene { return .scene }
        if old.prepared != next.prepared { return .preparation }
        if old.context == nil || old.context !== next.context { return .drawingContext }
        // No public generation describes the context's font, shape, histogram or rotator services. Even stable
        // stamps/context identity are not enough for those recipes. Gradients also remain full redraw in this slice.
        if !next.prepared.scene.drawingItems.allSatisfy(Self.contextIndependent) { return .unversionedRecipe }
        return nil
    }

    private static func contextIndependent(_ item: DrawItem) -> Bool {
        switch item {
        case let .fill(_, paint): return paint.secondColor == nil
        case .glass: return true
        case let .transformed(_, items), let .antialias(_, items): return items.allSatisfy(contextIndependent)
        case let .container(_, mask, contents):
            return mask.allSatisfy(contextIndependent) && contents.allSatisfy(contextIndependent)
        default: return false
        }
    }

    private static func finite(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
    }

    private func transaction(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
        if !Thread.isMainThread { CATransaction.flush() }
    }
}
