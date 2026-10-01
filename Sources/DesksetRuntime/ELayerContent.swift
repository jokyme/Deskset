import CoreFoundation
import CoreGraphics
import DesksetCore
import DesksetDraw
import Foundation
import QuartzCore

/// A fixed-plan E owner. Attach `root` under the caller's flipped content host, commit that transaction,
/// then call `display` in the next owner transaction. No window, live Skin or scheduling policy is retained.
/// This class and its layers are not Sendable; all tree mutations remain on `executor`.
package final class ELayerContent {
    package enum Failure: Error, Equatable {
        case wrongOwner
        case ownerReleased
        case unexpectedCallback(String)
        case incompatibleColorSpace
        case incompatibleBitmap(String)
        case invalidMapping
        case resourceLimit(String)
    }

    package struct Destination {
        package let layer: LayerPlan.Identity
        package let width: Int
        package let height: Int
        package let bytesPerRow: Int
        package let bitsPerComponent: Int
        package let bitsPerPixel: Int
        package let bitmapInfo: CGBitmapInfo
        package let hasBitmapData: Bool
        package let entry: DrawTarget
        /// Values captured from the real borrowed callback; rasterization and blend defaults remain unknown.
        package let target: DrawTarget?
    }

    package struct Observation {
        package let callbacks: [Int]
        package let destinations: [Destination?]
        package let failure: Failure?
    }

    /// A bounded, locked diagnostic mailbox. Retaining it retains neither an owner nor drawing caches.
    /// Off-owner and owner-released callbacks may record a failure here without accessing any frame payload.
    package final class CallbackReport {
        private let lock = NSLock()
        private var callbacks: [Int]
        private var destinations: [Destination?]
        private var failure: Failure?

        fileprivate init(count: Int) {
            callbacks = [Int](repeating: 0, count: count)
            destinations = [Destination?](repeating: nil, count: count)
        }

        package var observation: Observation {
            lock.lock()
            defer { lock.unlock() }
            return Observation(callbacks: callbacks, destinations: destinations, failure: failure)
        }

        fileprivate func entered(_ index: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard callbacks.indices.contains(index) else {
                if failure == nil { failure = .unexpectedCallback("Callback has no original layer index") }
                return
            }
            let (count, overflow) = callbacks[index].addingReportingOverflow(1)
            if overflow {
                if failure == nil { failure = .resourceLimit("Callback count overflows Int") }
            } else { callbacks[index] = count }
        }

        fileprivate func record(_ destination: Destination, at index: Int) {
            lock.lock()
            defer { lock.unlock() }
            if destinations.indices.contains(index) { destinations[index] = destination }
        }

        fileprivate func fail(_ value: Failure) {
            lock.lock()
            defer { lock.unlock() }
            if failure == nil { failure = value }
        }
    }

    private class NoActionsLayer: CALayer {
        override func action(forKey event: String) -> (any CAAction)? { NSNull() }
    }

    private final class DrawingLayer: NoActionsLayer {
        private let index: Int
        private let report: CallbackReport?
        private weak var owner: ELayerContent?

        init(index: Int, report: CallbackReport, owner: ELayerContent) {
            self.index = index
            self.report = report
            self.owner = owner
            super.init()
        }

        override init(layer: Any) {
            let source = layer as? DrawingLayer
            index = source?.index ?? -1
            report = source?.report
            owner = source?.owner
            super.init(layer: layer)
        }

        required init?(coder: NSCoder) { return nil }

        override func draw(in ctx: CGContext) {
            report?.entered(index)
            guard let owner else {
                report?.fail(.ownerReleased)
                return
            }
            owner.draw(self, at: index, in: ctx)
        }
    }

    private struct Frame {
        let recipes: LayerContentBuilder.Recipes
        let crops: [CGImage?]
        let context: DrawContext
        let cycle: Int
        let glass: GlassPaint
    }

    package let root: CALayer
    package let callbackReport: CallbackReport
    private let plan: PartitionPlan
    private let mode: LayerContentBuilder.Mode
    private let scale: CGFloat
    private let colorSpace: CGColorSpace
    private let maximumCallbackBitmapBytes: Int
    private let executor: any SkinExecutor
    private let base: Rasterizer?
    private var layers: [CALayer] = []
    private var frame: Frame?
    private var displaying = false

    /// `maximumBaseBitmapBytes` limits the one owned component-base bitmap. The callback limit is checked
    /// after CA creates its backing, so neither parameter is a total CA/process memory guarantee.
    /// Shared plan/recipe validation errors remain Rasterizer.Failure; callback failures use Failure.
    package init(plan: PartitionPlan, scale: CGFloat, colorSpace: CGColorSpace,
                 maximumBaseBitmapBytes: Int, maximumCallbackBitmapBytes: Int, executor: any SkinExecutor) throws {
        guard executor.isCurrent else { throw Failure.wrongOwner }
        guard scale.isFinite, scale > 0 else { throw Rasterizer.Failure.invalidInput("Scale must be finite and positive") }
        guard colorSpace.model == .rgb else { throw Rasterizer.Failure.incompatibleColorSpace }
        guard maximumBaseBitmapBytes > 0, maximumCallbackBitmapBytes > 0 else {
            throw Rasterizer.Failure.invalidInput("Explicit bitmap budgets must be positive")
        }
        let mode = try LayerContentBuilder.validateGeometry(plan)
        let rootBounds = CGRect(x: 0, y: 0, width: CGFloat(plan.window.width) / scale,
                                height: CGFloat(plan.window.height) / scale)
        let pointFrames = plan.layers.map { layer in
            let rect = layer.rect
            return CGRect(x: CGFloat(rect.minX) / scale, y: CGFloat(rect.minY) / scale,
                          width: CGFloat(rect.width) / scale, height: CGFloat(rect.height) / scale)
        }
        guard [rootBounds.width, rootBounds.height].allSatisfy(\.isFinite), pointFrames.allSatisfy({ rect in
            [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
        }) else { throw Rasterizer.Failure.invalidInput("Layer point geometry is not finite at this scale") }
        for layer in plan.layers {
            switch layer.content {
            case .baseSlice: break
            case .fullScene, .group:
                guard try Rasterizer.requiredBytes(width: layer.rect.width, height: layer.rect.height) <= maximumCallbackBitmapBytes else {
                    throw Failure.resourceLimit("A logical layer backing exceeds the callback bitmap budget")
                }
            }
        }
        let base: Rasterizer?
        switch mode {
        case .components:
            base = try Rasterizer(width: plan.window.width, height: plan.window.height, colorSpace: colorSpace,
                                  maximumBitmapBytes: maximumBaseBitmapBytes)
        case .empty, .single: base = nil
        }
        self.plan = plan
        self.mode = mode
        self.scale = scale
        self.colorSpace = colorSpace
        self.maximumCallbackBitmapBytes = maximumCallbackBitmapBytes
        self.executor = executor
        self.base = base
        root = NoActionsLayer()
        callbackReport = CallbackReport(count: plan.layers.count)
        root.anchorPoint = .zero
        root.bounds = rootBounds
        root.contentsFormat = .RGBA8Uint
        for (index, layerPlan) in plan.layers.enumerated() {
            let layer: CALayer
            switch layerPlan.content {
            case .baseSlice: layer = NoActionsLayer()
            case .fullScene, .group: layer = DrawingLayer(index: index, report: callbackReport, owner: self)
            }
            layer.anchorPoint = .zero
            layer.frame = pointFrames[index]
            layer.contentsScale = scale
            layer.contentsFormat = .RGBA8Uint
            layer.contentsGravity = .topLeft
            layer.needsDisplayOnBoundsChange = false
            layer.drawsAsynchronously = false
            layer.isOpaque = false
            layer.magnificationFilter = .nearest
            layer.minificationFilter = .nearest
            root.addSublayer(layer)
            layers.append(layer)
        }
    }

    /// Every call redraws every group, without dirty/caching policy. The caller owns begin/commit/flush.
    /// The drawing caches are leased only across these synchronous native displays, never a later CA callback.
    /// Any unexpected native callback latches a failure; this slice supplies no main-thread redraw fallback.
    package func display(_ scene: WidgetScene, context: DrawContext, cycle: Int, glass: GlassPaint) throws {
        guard executor.isCurrent else { throw Failure.wrongOwner }
        guard !displaying else { throw Rasterizer.Failure.invalidInput("E content display is not reentrant") }
        if let failure = callbackReport.observation.failure { throw failure }
        let recipes = try LayerContentBuilder.resolve(scene, plan: plan, scale: scale, mode: mode)
        if case .empty = mode { return }
        guard root.superlayer != nil else { throw Rasterizer.Failure.invalidInput("Attach and commit the E tree before displaying") }
        displaying = true
        defer { frame = nil; displaying = false }
        let baseImage = try base?.image(of: recipes.base, in: plan.window, scale: scale, baseCrop: nil,
                                        context: context, cycle: cycle, glass: glass)
        var crops: [CGImage?] = []
        for layer in plan.layers {
            switch layer.content {
            case .fullScene, .baseSlice: crops.append(nil)
            case .group:
                guard let baseImage else { throw Rasterizer.Failure.resourceFailure("The E component base bitmap is unavailable") }
                crops.append(try LayerContentBuilder.crop(baseImage, to: layer.rect))
            }
        }
        frame = Frame(recipes: recipes, crops: crops, context: context, cycle: cycle, glass: glass)
        for (index, layer) in layers.enumerated() {
            switch plan.layers[index].content {
            case let .baseSlice(source):
                layer.contents = baseImage
                layer.contentsRect = LayerContentBuilder.contentsRect(source: source, window: plan.window)
            case .fullScene, .group:
                let before = callbackReport.observation.callbacks[index]
                layer.setNeedsDisplay()
                layer.displayIfNeeded()
                let observation = callbackReport.observation
                if let failure = observation.failure { throw failure }
                let (expected, overflow) = before.addingReportingOverflow(1)
                guard !overflow, observation.callbacks[index] == expected, observation.destinations[index]?.target != nil else {
                    let failure = Failure.unexpectedCallback("Native display did not supply exactly one qualified draw callback")
                    callbackReport.fail(failure)
                    throw failure
                }
            }
        }
    }

    private func draw(_ layer: DrawingLayer, at index: Int, in ctx: CGContext) {
        // This check precedes all frame, drawing-cache and mutable-tree access, including model-copy validation.
        guard executor.isCurrent else { return callbackReport.fail(.wrongOwner) }
        guard layers.indices.contains(index), layers[index] === layer, displaying, let frame else {
            return callbackReport.fail(.unexpectedCallback("Callback is unarmed or comes from a model/presentation copy"))
        }
        do {
            let rect = plan.layers[index].rect
            let local = layer.bounds
            let entry = DrawTarget.capture(ctx, glass: frame.glass)
            func destination(_ target: DrawTarget?) -> Destination {
                Destination(layer: plan.layers[index].id, width: ctx.width, height: ctx.height,
                            bytesPerRow: ctx.bytesPerRow, bitsPerComponent: ctx.bitsPerComponent,
                            bitsPerPixel: ctx.bitsPerPixel, bitmapInfo: ctx.bitmapInfo,
                            hasBitmapData: ctx.data != nil, entry: entry, target: target)
            }
            callbackReport.record(destination(nil), at: index)
            guard ctx.data != nil, ctx.width == rect.width, ctx.height == rect.height,
                  ctx.bitsPerComponent == 8, ctx.bitsPerPixel == 32, ctx.alphaInfo == .premultipliedFirst,
                  ctx.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue == CGBitmapInfo.byteOrder32Little.rawValue else {
                throw Failure.incompatibleBitmap("Actual callback is not the requested size and BGRA8 premultiplied backing")
            }
            let (activeRow, rowOverflow) = ctx.width.multipliedReportingOverflow(by: 4)
            let (bytes, bytesOverflow) = ctx.bytesPerRow.multipliedReportingOverflow(by: ctx.height)
            guard !rowOverflow, !bytesOverflow, ctx.bytesPerRow >= activeRow, bytes <= maximumCallbackBitmapBytes else {
                throw Failure.resourceLimit("Actual callback row storage exceeds its explicit budget")
            }
            guard let actualSpace = ctx.colorSpace, CFEqual(actualSpace, colorSpace) else {
                throw Failure.incompatibleColorSpace
            }
            guard entry.userToDevice == CGAffineTransform(scaleX: scale, y: scale),
                  ctx.boundingBoxOfClipPath == local,
                  [ctx.ctm.a, ctx.ctm.b, ctx.ctm.c, ctx.ctm.d, ctx.ctm.tx, ctx.ctm.ty].allSatisfy(\.isFinite) else {
                throw Failure.invalidMapping
            }
            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.clear(local)
            if let crop = frame.crops[index] {
                ctx.saveGState()
                ctx.setBlendMode(.copy)
                ctx.interpolationQuality = .none
                // The inherited callback is y-down; only this raw image copy receives a local image flip.
                ctx.translateBy(x: 0, y: local.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(crop, in: local)
                ctx.restoreGState()
            }
            ctx.translateBy(x: -CGFloat(rect.minX) / scale, y: -CGFloat(rect.minY) / scale)
            let target = DrawTarget.capture(ctx, glass: frame.glass)
            let expected = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                             tx: -CGFloat(rect.minX), ty: -CGFloat(rect.minY))
            guard target.userToDevice == expected else { throw Failure.invalidMapping }
            DrawExecutor.draw(frame.recipes.layers[index], in: ctx, context: frame.context,
                              cycle: frame.cycle, target: target)
            callbackReport.record(destination(target), at: index)
        } catch let failure as Failure {
            callbackReport.fail(failure)
        } catch {
            callbackReport.fail(.unexpectedCallback("Native drawing rejected an unexpected error: \(error)"))
        }
    }
}
