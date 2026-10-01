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
        case localizedAntialiasedLine(group: LayerPlan.Identity)
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

    /// An attachment identity, not a prepared presentation, reusable ready token or executor lease. It retains
    /// no owner or drawing context. Main may attach it only inside the real owner's exclusive scope, then the
    /// physical worker performs one native display. The caller detaches it after owner-side release.
    package final class NativeStage {
        package let root: CALayer
        package let fallbackRoot: CALayer
        package let sourceSequence: UInt64
        package let scale: CGFloat
        package let colorSpace: CGColorSpace
        package let callbackReport: ELayerContent.CallbackReport

        fileprivate init(_ content: ELayerContent, fallbackRoot: CALayer, sequence: UInt64, scale: CGFloat, colorSpace: CGColorSpace) {
            root = content.root
            self.fallbackRoot = fallbackRoot
            sourceSequence = sequence
            self.scale = scale
            self.colorSpace = colorSpace
            callbackReport = content.callbackReport
        }
    }
    package enum NativeStageFailure: Error, Equatable { case notReady, busy, staleSource, notAttached, awaitingRollback }

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

    private final class NativeCandidate {
        enum Publication: Equatable { case scoped, publishing, published }
        let attachment: NativeStage
        let content: ELayerContent
        // Share the existing captured immutable recipe; never project or deep-copy another scene for staging.
        let source: Key
        var attached = false
        var displayed = false
        var publication = Publication.scoped

        init(_ content: ELayerContent, fallbackRoot: CALayer, source: Key, sequence: UInt64) {
            self.content = content
            self.source = source
            attachment = NativeStage(content, fallbackRoot: fallbackRoot, sequence: sequence, scale: source.scale, colorSpace: source.colorSpace)
        }
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
    private var nativeCandidate: NativeCandidate?
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
        guard !nativePublicationHoldsWriter else { throw Failure.transferredWriter }
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
            var plan: PartitionPlan
            var fallback: Fallback?
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
            let recipes = try LayerContentBuilder.resolve(scene, plan: plan, scale: scale, mode: mode)
            // A localized AA butt-cap segment can differ from the full-window raster before composition.
            // Validate the complete candidate first: choosing Single must not hide malformed geometry/recipes.
            for (layer, items) in zip(plan.layers, recipes.layers) {
                guard case .group = layer.content, layer.rect != window,
                      Self.containsAntialiasedLine(items) else { continue }
                fallback = .localizedAntialiasedLine(group: layer.id)
                plan = SinglePartition.plan(in: window)
                let singleMode = try LayerContentBuilder.validateGeometry(plan)
                _ = try LayerContentBuilder.resolve(scene, plan: plan, scale: scale, mode: singleMode)
                break
            }
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
        guard !nativePublicationHoldsWriter else { throw Failure.transferredWriter }
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

    /// Explicit, one-shot Single staging from an already accepted C frame. There is no automatic call from update,
    /// no ready cache and no C tree/sequence mutation. App must additionally require a physical worker and validate
    /// its current actual-window epoch; this package operation cannot establish those AppKit facts by itself.
    package func prepareNativeStage(maximumCallbackBitmapBytes: Int, cycle: Int) throws -> NativeStage {
        try checkMutable()
        guard nativeCandidate == nil else { throw NativeStageFailure.busy }
        guard state == .live, pending == nil, let key, key.context != nil, key.cycle == cycle,
              let frame = currentFrame else { throw NativeStageFailure.notReady }
        let content = try ELayerContent(plan: SinglePartition.plan(in: key.window), scale: key.scale,
            colorSpace: key.colorSpace, maximumBaseBitmapBytes: maximumOwnedBitmapBytes,
            maximumCallbackBitmapBytes: maximumCallbackBitmapBytes, executor: executor)
        let candidate = NativeCandidate(content, fallbackRoot: root, source: key, sequence: frame.sequence)
        nativeCandidate = candidate
        return candidate.attachment
    }

    /// Called after the main attachment transaction, while main holds actual exclusive owner access.
    package func attachedNativeStage(_ stage: NativeStage) throws {
        try checkMutable()
        let candidate = try currentNativeCandidate(stage)
        guard !candidate.attached, stage.root.superlayer != nil else { throw NativeStageFailure.notAttached }
        candidate.attached = true
    }

    package func nativeStageIsCurrent(_ stage: NativeStage, cycle: Int) -> Bool {
        precondition(executor.isCurrent)
        guard let candidate = try? currentNativeCandidate(stage) else { return false }
        return candidate.source.cycle == cycle
    }

    /// Exactly one synchronous native display. Borrowed callback state is captured by ELayerContent's original
    /// guards; it is never configured as an owned bitmap. The caches are leased only within this call.
    package func displayNativeStage(_ stage: NativeStage, cycle: Int) throws -> ELayerContent.Observation {
        try checkMutable()
        let candidate = try currentNativeCandidate(stage)
        guard candidate.attached, !candidate.displayed else { throw NativeStageFailure.notAttached }
        guard candidate.source.cycle == cycle, let context = candidate.source.context else {
            throw NativeStageFailure.staleSource
        }
        candidate.displayed = true
        var failure: Error?
        transaction {
            do {
                try candidate.content.display(candidate.source.prepared.scene, context: context,
                    cycle: candidate.source.cycle, glass: candidate.source.glass)
            } catch { failure = error }
        }
        if let failure { throw failure }
        return candidate.content.callbackReport.observation
    }

    /// Freeze the accepted C root before main changes its host. This is actual owner access, not a PreparedFrame
    /// lease. New C preparation/commit stays blocked until main has acknowledged the matching rollback.
    package func beginNativePublication(_ stage: NativeStage) throws {
        try checkMutable()
        let candidate = try currentNativeCandidate(stage)
        guard candidate.attached, candidate.displayed else { throw NativeStageFailure.notAttached }
        if let failure = stage.callbackReport.observation.failure { throw failure }
        candidate.publication = .publishing
    }

    package func acknowledgeNativePublication(_ stage: NativeStage) throws {
        try checkOwner()
        guard let candidate = nativeCandidate, candidate.attachment === stage,
              candidate.publication == .publishing else { throw NativeStageFailure.staleSource }
        candidate.publication = .published
    }

    package var nativePublicationHoldsWriter: Bool {
        precondition(executor.isCurrent)
        return nativeCandidate.map { $0.publication != .scoped } ?? false
    }

    /// Owner cleanup precedes main detachment. A late/foreign release cannot clear a newer candidate.
    @discardableResult
    package func releaseNativeStage(_ stage: NativeStage, rollbackAcknowledged: Bool = false,
                                    permanentStop: Bool = false) throws -> Bool {
        try checkOwner()
        guard let candidate = nativeCandidate, candidate.attachment === stage else { return false }
        guard candidate.publication == .scoped || rollbackAcknowledged || permanentStop else {
            throw NativeStageFailure.awaitingRollback
        }
        nativeCandidate = nil
        return true
    }

    private func currentNativeCandidate(_ stage: NativeStage) throws -> NativeCandidate {
        guard state == .live, pending == nil, transferred == nil, let candidate = nativeCandidate,
              candidate.attachment === stage, key === candidate.source, candidate.source.context != nil,
              currentFrame?.sequence == stage.sourceSequence else { throw NativeStageFailure.staleSource }
        return candidate
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
        guard !nativePublicationHoldsWriter else { throw Failure.transferredWriter }
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

    /// Inspect the resolved atomic recipe without adding recursive call depth. Roundline sets its own AA flag,
    /// so an enclosing antialias wrapper cannot exempt the line. Both executed container branches matter.
    private static func containsAntialiasedLine(_ items: [DrawItem]) -> Bool {
        var pending = [items.makeIterator()]
        while !pending.isEmpty {
            guard let item = pending[pending.count - 1].next() else {
                pending.removeLast()
                continue
            }
            switch item {
            case let .roundline(draw):
                if draw.antiAlias, draw.color.a > 0, case .line = draw.shape { return true }
            case let .transformed(_, children), let .antialias(_, children):
                pending.append(children.makeIterator())
            case let .container(clip, mask, content):
                let rect = CGRect(x: clip.x, y: clip.y, width: clip.width, height: clip.height)
                guard !content.isEmpty, rect.width > 0, rect.height > 0,
                      rect.minX.isFinite, rect.minY.isFinite else { continue }
                pending.append(mask.makeIterator())
                pending.append(content.makeIterator())
            case .fill, .bevel, .text, .image, .shape, .bar, .graph, .rotator, .sprite, .glass:
                break
            }
        }
        return false
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
