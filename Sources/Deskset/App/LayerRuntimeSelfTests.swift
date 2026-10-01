import CoreFoundation
import CoreGraphics
import CoreText
import DesksetCore
import DesksetDraw
import DesksetRuntime
import Foundation
import Metal
import QuartzCore

enum LayerRuntimeSelfTests {
    private typealias Rect = InkBounds.DeviceRect
    private static let width = 28, height = 20, budget = 1_000_000
    private static let baseID = ElementID(name: "RuntimeBase", index: 0)
    private static let backID = ElementID(name: "RuntimeBack", index: 4)
    private static let frontID = ElementID(name: "RuntimeFront", index: 8)
    private static let maskID = ElementID(name: "RuntimeMask", index: 12)
    private static let childID = ElementID(name: "RuntimeChild", index: 16)

    static func run(_ t: AppTestRunner) {
        nativeTests(t)
        frozenSelectionTests(t)
        fallbackTests(t)
        antialiasedLineTests(t)
        antialiasedFullCircleTests(t)
        elementCountTests(t)
        lifecycleTests(t)
        workerOwnerTests(t)
        transferTests(t)
        preparationTests(t)
        preparationLifecycleTests(t)
    }

    private static func preparationTests(_ t: AppTestRunner) {
        t.suite("Runtime: layer runtime: preparation keeps visible frames until one explicit commit") {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: prepare/commit native qualification did not run")
            }
            let space = try rgb(CGColorSpace.sRGB)
            for scale in [1, 2] {
                let window = try rect(0, 0, width * scale, height * scale)
                let context = DrawContext(fonts: AppFontResolver()), owner = try runtime(), tree = host(owner.root, scale)
                let renderer = try OffscreenRenderer(width: window.width, height: window.height, device: device,
                                                     maximumReadbackBytes: window.width * window.height * 4)
                let a = fixture(0, scale, false, gradient: false), b = fixture(1, scale, false, gradient: false)
                let pa = try prepare(a, context, scale, space, .none), pb = try prepare(b, context, scale, space, .none)
                let first = try ready(owner.prepare(pa, in: window, scale: CGFloat(scale), colorSpace: space,
                    partition: .candidateComponents, context: context, cycle: 0, glass: .none))
                t.equal(owner.state, .loading)
                t.check(owner.currentFrame == nil && (owner.root.sublayers ?? []).isEmpty)
                t.equal(owner.root.bounds, .zero, "a complete first preparation does not install any geometry")
                t.equal(first.frame.sequence, 1)
                t.check(!first.frame.contents.isEmpty)
                t.check(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba.allSatisfy { $0 == 0 })
                let expectedA = try renderer.render(cTree(baseline(a, context, 0, scale, space, .none), scale),
                                                    at: 0, deadline: .now() + .seconds(30)).rgba
                checkFixture(expectedA, window, t)
                t.equal(try renderer.render(cTree(first.frame.contents, scale), at: 0,
                                            deadline: .now() + .seconds(30)).rgba, expectedA,
                        "prepared images are complete and independently comparable before installation")
                let committedA = try owner.commit(first)
                t.equal(committedA.sequence, 1)
                t.equal(owner.currentFrame?.sequence, 1)
                t.equal(owner.state, .live)
                let aLayers = owner.root.sublayers ?? [], aBounds = owner.root.bounds
                try checkRetained(owner, committedA, aLayers, aBounds, tree, renderer, expectedA, t)

                // A genuinely different proposed root size catches premature bounds installation as well as pixels.
                var larger = b
                larger.size = SkinSize(width: Double(width + 1), height: Double(height))
                let largerWindow = try rect(0, 0, (width + 1) * scale, height * scale)
                let resized = try ready(owner.prepare(prepare(larger, context, scale, space, .none), in: largerWindow,
                    scale: CGFloat(scale), colorSpace: space, partition: .single, context: context, cycle: 1, glass: .none))
                t.equal(resized.frame.sequence, 2)
                t.equal(resized.frame.plan.window, largerWindow)
                t.equal(resized.frame.contents.first?.image.width, largerWindow.width)
                try checkRetained(owner, committedA, aLayers, aBounds, tree, renderer, expectedA, t)
                try owner.discard(resized)
                try expectRuntime(.stalePreparation, t) { _ = try owner.commit(resized) }
                try checkRetained(owner, committedA, aLayers, aBounds, tree, renderer, expectedA, t)

                let superseded = try ready(owner.prepare(pb, in: window, scale: CGFloat(scale), colorSpace: space,
                    partition: .candidateComponents, context: context, cycle: 1, glass: .none))
                let winner = try ready(owner.prepare(pb, in: window, scale: CGFloat(scale), colorSpace: space,
                    partition: .candidateComponents, context: context, cycle: 1, glass: .none))
                t.equal(winner.frame.sequence, 2, "discard/supersede never advances the committed sequence")
                t.equal(winner.frame.change, .all(.discardedPreparation))
                try expectRuntime(.stalePreparation, t) { _ = try owner.commit(superseded) }
                try expectRuntime(.stalePreparation, t) { try owner.discard(superseded) }
                t.equal(SkinRuntimeSelfTests.onAnotherThread {
                    do { _ = try owner.commit(winner); return false }
                    catch LayerRuntime.Failure.wrongOwner { return !Thread.isMainThread }
                    catch { return false }
                }, true, "a finished image token confers no off-owner commit permission")
                t.equal(SkinRuntimeSelfTests.onAnotherThread {
                    do { try owner.discard(winner); return false }
                    catch LayerRuntime.Failure.wrongOwner { return !Thread.isMainThread }
                    catch { return false }
                }, true)
                try checkRetained(owner, committedA, aLayers, aBounds, tree, renderer, expectedA, t)
                let committedB = try owner.commit(winner)
                t.equal(committedB.sequence, 2)
                let expectedB = try renderer.render(cTree(baseline(b, context, 1, scale, space, .none), scale),
                                                    at: 0, deadline: .now() + .seconds(30)).rgba
                let bPixels = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba
                t.equal(bPixels, expectedB)
                t.check(bPixels != expectedA, "B is a visible independent native change")
                let bLayers = owner.root.sublayers ?? [], bBounds = owner.root.bounds
                try expectRuntime(.stalePreparation, t) { _ = try owner.commit(winner) }
                try expectRuntime(.stalePreparation, t) { try owner.discard(winner) }
                try checkRetained(owner, committedB, bLayers, bBounds, tree, renderer, bPixels, t)

                let abandoned = try ready(owner.prepare(pa, in: window, scale: CGFloat(scale), colorSpace: space,
                    partition: .candidateComponents, context: context, cycle: 2, glass: .none))
                let incomplete = SceneInkCandidates(scene: a, elementInk: [], runInk: [])
                try expectRasterizer(.invalidPlan, t) {
                    _ = try owner.prepare(incomplete, in: window, scale: CGFloat(scale), colorSpace: space,
                        partition: .candidateComponents, context: context, cycle: 2, glass: .none)
                }
                try expectRuntime(.stalePreparation, t) { _ = try owner.commit(abandoned) }
                try expectRuntime(.stalePreparation, t) { try owner.discard(abandoned) }
                try checkRetained(owner, committedB, bLayers, bBounds, tree, renderer, bPixels, t)
                let recovered = try ready(owner.prepare(pa, in: window, scale: CGFloat(scale), colorSpace: space,
                    partition: .candidateComponents, context: context, cycle: 2, glass: .none))
                t.equal(recovered.frame.change, .all(.previousFailure))
                t.equal(recovered.frame.sequence, 3)
                let returnedA = try owner.commit(recovered)
                t.equal(returnedA.sequence, 3)
                t.equal(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba, expectedA)
                if case .unchanged(let reused) = try owner.prepare(pa, in: window, scale: CGFloat(scale), colorSpace: space,
                    partition: .candidateComponents, context: context, cycle: 2, glass: .none) {
                    t.equal(reused.sequence, 3)
                    t.equal(owner.currentFrame?.change, returnedA.change, "unchanged prepare still changes no committed metadata")
                } else { t.check(false, "the original context-independent reuse rule remains observable") }
                let reused = try unchanged(owner.update(pa, in: window, scale: CGFloat(scale), colorSpace: space,
                    partition: .candidateComponents, context: context, cycle: 2, glass: .none))
                t.equal(reused.change, .unchanged)
                t.equal(owner.currentFrame?.change, .unchanged, "legacy update preserves its synchronous unchanged observation")

                let compatible = try runtime(), compatibleTree = host(compatible.root, scale)
                for (cycle, prepared) in [pa, pb, pa].enumerated() {
                    _ = try submitted(compatible.update(prepared, in: window, scale: CGFloat(scale), colorSpace: space,
                        partition: .candidateComponents, context: context, cycle: cycle, glass: .none))
                }
                t.equal(compatible.currentFrame?.sequence, returnedA.sequence)
                t.equal(try renderer.render(compatibleTree, at: 0, deadline: .now() + .seconds(30)).rgba, expectedA,
                        "the legacy synchronous wrapper and explicit commit produce the same strict native A return")
                let pendingB = try ready(owner.prepare(pb, in: window, scale: CGFloat(scale), colorSpace: space,
                    partition: .candidateComponents, context: context, cycle: 3, glass: .none))
                let foreign = try ready(compatible.prepare(pb, in: window, scale: CGFloat(scale), colorSpace: space,
                    partition: .candidateComponents, context: context, cycle: 3, glass: .none))
                try expectRuntime(.stalePreparation, t) { _ = try owner.commit(foreign) }
                try expectRuntime(.stalePreparation, t) { try owner.discard(foreign) }
                t.equal(try owner.commit(pendingB).sequence, 4, "a foreign token cannot clear the current valid candidate")
                t.equal(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba, expectedB)
                try compatible.discard(foreign)
                t.check(renderer.hasVerifiedCanary)
                withExtendedLifetime([tree, compatibleTree]) {}
            }
        }
    }

    private static func preparationLifecycleTests(_ t: AppTestRunner) {
        t.suite("Runtime: layer runtime: pending content obeys owner lifecycle and does not retain drawing owners") {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: pending lifecycle native qualification did not run")
            }
            let space = try rgb(CGColorSpace.sRGB), window = try rect(0, 0, width, height)
            let context = DrawContext(fonts: AppFontResolver()), owner = try runtime(), tree = host(owner.root, 1)
            let renderer = try OffscreenRenderer(width: width, height: height, device: device,
                                                 maximumReadbackBytes: width * height * 4)
            let a = fixture(0, 1, false, gradient: false), b = fixture(1, 1, false, gradient: false)
            let pa = try prepare(a, context, 1, space, .none), pb = try prepare(b, context, 1, space, .none)
            let first = try submitted(owner.update(pa, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 0, glass: .none))
            let original = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba
            checkFixture(original, window, t)
            let layers = owner.root.sublayers ?? [], bounds = owner.root.bounds
            let staleRefresh = try ready(owner.prepare(pb, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 1, glass: .none))
            try owner.beginRefresh()
            t.equal(owner.state, .refreshing)
            try expectRuntime(.stalePreparation, t) { _ = try owner.commit(staleRefresh) }
            try expectRuntime(.stalePreparation, t) { try owner.discard(staleRefresh) }
            try checkRetained(owner, first, layers, bounds, tree, renderer, original, t)
            let refreshed = try ready(owner.prepare(pb, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 1, glass: .none))
            t.equal(refreshed.frame.change, .all(.refresh))
            let changed = try owner.commit(refreshed)
            t.equal(changed.sequence, 2)
            let changedPixels = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba
            t.equal(changedPixels, try renderer.render(cTree(baseline(b, context, 1, 1, space, .none), 1),
                                                       at: 0, deadline: .now() + .seconds(30)).rgba)
            t.check(changedPixels != original)
            let closeToken = try ready(owner.prepare(pa, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 2, glass: .none))
            try owner.beginClose()
            try expectRuntime(.invalidLifecycle(.closing), t) { _ = try owner.commit(closeToken) }
            try expectRuntime(.invalidLifecycle(.closing), t) { try owner.discard(closeToken) }
            t.equal(owner.currentFrame?.sequence, 2)
            t.equal(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba, changedPixels,
                    "beginClose keeps actual final pixels even with an uncommitted preparation")
            try owner.close()
            try expectRuntime(.invalidLifecycle(.closed), t) { _ = try owner.commit(closeToken) }
            t.check(owner.currentFrame == nil && (owner.root.sublayers ?? []).isEmpty)
            t.check(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba.allSatisfy { $0 == 0 })

            let hidden = try runtime(), hiddenTree = host(hidden.root, 1)
            _ = try submitted(hidden.update(pa, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 0, glass: .none))
            let hiddenToken = try ready(hidden.prepare(pb, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 1, glass: .none))
            try hidden.setVisible(false)
            try expectRuntime(.invalidLifecycle(.hidden), t) { _ = try hidden.commit(hiddenToken) }
            t.check(hidden.currentFrame == nil && (hidden.root.sublayers ?? []).isEmpty)
            let malformed = SceneInkCandidates(scene: a, elementInk: [], runInk: [])
            if case .suppressed = try hidden.prepare(malformed, in: window, scale: 0, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 1, glass: .none) { t.check(true) }
            else { t.check(false, "hidden prepare suppresses validation and drawing just like update") }
            t.check(try renderer.render(hiddenTree, at: 0, deadline: .now() + .seconds(30)).rgba.allSatisfy { $0 == 0 })
            try hidden.setVisible(true)
            try expectRuntime(.stalePreparation, t) { _ = try hidden.commit(hiddenToken) }
            let revealed = try ready(hidden.prepare(pb, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 1, glass: .none))
            t.equal(revealed.frame.change, .all(.released))
            let visible = try hidden.commit(revealed)
            t.equal(visible.sequence, 2)
            let visibleLayers = hidden.root.sublayers ?? [], visibleBounds = hidden.root.bounds
            try checkRetained(hidden, visible, visibleLayers, visibleBounds, hiddenTree, renderer, changedPixels, t)

            let prior = try ready(hidden.prepare(pa, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 2, glass: .none))
            let fonts = CallbackFonts(), textContext = DrawContext(fonts: fonts)
            var textScene = b
            textScene.elements[1].items = [text()]
            let textInput = try prepare(textScene, textContext, 1, space, .none)
            fonts.onResolve = {
                do { _ = try hidden.prepare(pa, in: window, scale: 1, colorSpace: space,
                    partition: .single, context: context, cycle: 2, glass: .none); t.check(false) }
                catch LayerRuntime.Failure.reentrant { t.check(true) }
                catch { t.check(false, "unexpected nested prepare failure") }
                for work in [{ _ = try hidden.commit(prior) }, { try hidden.discard(prior) },
                             { try hidden.beginRefresh() }, { try hidden.beginClose() },
                             { try hidden.setVisible(false) }, { try hidden.close() }] {
                    do { try work(); t.check(false, "native drawing must not reenter a tree mutation") }
                    catch LayerRuntime.Failure.reentrant { t.check(true) }
                    catch { t.check(false, "unexpected reentrant failure") }
                }
            }
            let textToken = try ready(hidden.prepare(textInput, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: textContext, cycle: 2, glass: .none))
            fonts.onResolve = nil
            t.check(fonts.requests > 0, "the reentrant guard ran inside real named-font native rendering")
            try checkRetained(hidden, visible, visibleLayers, visibleBounds, hiddenTree, renderer, changedPixels, t)
            _ = try hidden.commit(textToken)
            let textPixels = try renderer.render(hiddenTree, at: 0, deadline: .now() + .seconds(30)).rgba
            checkFixture(textPixels, window, t)
            t.equal(textPixels, try renderer.render(cTree(baseline(textScene, textContext, 2, 1, space, .none), 1),
                                                    at: 0, deadline: .now() + .seconds(30)).rgba)

            // Canceled loading candidates must not freeze the future base membership.
            let uncommitted = try runtime()
            let full = try ready(uncommitted.prepare(pa, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 0, glass: .none))
            t.equal(full.frame.plan.baseMembers, [baseID])
            try uncommitted.discard(full)
            var small = a
            small.elements[0].items = [fill(0, 0, 3, 2, RGBA(r: 31, g: 89, b: 151, a: 83))]
            let smallToken = try ready(uncommitted.prepare(prepare(small, context, 1, space, .none), in: window,
                scale: 1, colorSpace: space, partition: .candidateComponents, context: context, cycle: 0, glass: .none))
            t.equal(smallToken.frame.plan.baseMembers, [])
            t.equal(try uncommitted.commit(smallToken).sequence, 1)

            var escaped: LayerRuntime.PreparedFrame?
            weak var weakContext: DrawContext?
            var transientOwner: LayerRuntime? = try runtime()
            weak var weakOwner = transientOwner
            try autoreleasepool {
                let transientContext = DrawContext(fonts: AppFontResolver())
                weakContext = transientContext
                escaped = try ready(transientOwner!.prepare(prepare(a, transientContext, 1, space, .none), in: window,
                    scale: 1, colorSpace: space, partition: .single, context: transientContext, cycle: 0, glass: .none))
            }
            t.check(weakContext == nil, "pending keys and the exported token do not retain a DrawContext")
            transientOwner = nil
            t.check(weakOwner == nil, "an externally retained preparation cannot keep its mutable owner alive")
            guard let escaped else { throw CocoaError(.coderInvalidValue) }
            t.equal(try renderer.render(cTree(escaped.frame.contents, 1), at: 0, deadline: .now() + .seconds(30)).rgba, original,
                    "released owners leave only complete immutable images in the token")
            t.check(renderer.hasVerifiedCanary)
            withExtendedLifetime([tree, hiddenTree]) {}
        }
    }

    private static func ready(_ prepared: LayerRuntime.Preparation) throws -> LayerRuntime.PreparedFrame {
        guard case let .ready(value) = prepared else { throw CocoaError(.coderInvalidValue) }
        return value
    }

    private static func expectRuntime(_ expected: LayerRuntime.Failure, _ t: AppTestRunner, _ body: () throws -> Void) throws {
        do { try body(); t.check(false, "expected a typed LayerRuntime failure") }
        catch let failure as LayerRuntime.Failure { t.equal(failure, expected) }
    }

    private final class CallbackFonts: FontResolving {
        var requests = 0
        var onResolve: (() -> Void)?
        var generation: Int { 0 }
        func registerFolder(_ folder: String) {}
        func resolve(_ request: FontRequest) -> ResolvedFont {
            requests += 1
            onResolve?()
            return ResolvedFont(font: CTFontCreateWithName("Helvetica" as CFString, request.size, nil),
                                syntheticBold: false, characterMap: nil, slant: 0, lineMetrics: nil)
        }
    }

    private static func nativeTests(_ t: AppTestRunner) {
        t.suite("Runtime: layer runtime: full redraw and safe unchanged decisions match fresh Single through A/B/A") {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: actual LayerRuntime composition did not run")
            }
            let space = try rgb(CGColorSpace.sRGB)
            for scale in [1, 2] {
                var light: [UInt8]?
                for dark in [false, true] {
                    let window = try rect(0, 0, width * scale, height * scale)
                    let owner = try runtime()
                    let tree = host(owner.root, scale)
                    let context = DrawContext(fonts: AppFontResolver())
                    let renderer = try OffscreenRenderer(width: window.width, height: window.height, device: device,
                                                         maximumReadbackBytes: window.width * window.height * 4)
                    var saved: [[UInt8]] = []
                    for (cycle, variant) in [0, 1, 0].enumerated() {
                        let scene = fixture(variant, scale, dark)
                        let glass = GlassPaint.placeholder(dark: dark)
                        let prepared = try prepare(scene, context, scale, space, glass)
                        let frame = try submitted(owner.update(prepared, in: window, scale: CGFloat(scale), colorSpace: space,
                            partition: .candidateComponents, context: context, cycle: cycle, glass: glass))
                        t.equal(frame.sequence, UInt64(cycle + 1))
                        t.equal(frame.fallback, nil)
                        t.equal(frame.plan.baseMembers, [baseID], "leading base is frozen, preserving original occurrence gaps")
                        t.equal(frame.plan.layers.compactMap { layer -> [ElementID]? in
                            if case let .group(members) = layer.content { return members }; return nil
                        }, [[backID, frontID], [maskID]], "overlap order and container atomic recipe stay complete")
                        t.equal(owner.state, .live)
                        let reference = try baseline(scene, context, cycle, scale, space, glass)
                        let expected = try renderer.render(cTree(reference, scale), at: 0, deadline: .now() + .seconds(30))
                        let actual = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30))
                        checkFixture(expected.rgba, window, t)
                        t.equal(actual.rgba, expected.rgba, "actual C runtime / fresh Single strict active RGBA bytes")
                        t.check(frame.contents.allSatisfy { $0.image.colorSpace.map { CFEqual($0, space) } == true })
                        let slices = frame.contents.filter { if case .baseSlice = $0.plan.content { return true }; return false }
                        t.check(slices.count > 1 && slices.allSatisfy { $0.image === slices[0].image },
                                "every slice shares one full-window base image")
                        saved.append(actual.rgba)
                    }
                    t.check(saved[0] != saved[1], "B visibly changes the fixture")
                    t.equal(saved[0], saved[2], "strict A return after B with the same scene generation")
                    if dark { t.check(light != saved[0], "glass appearance changes actual native pixels") }
                    else { light = saved[0] }
                    t.check(renderer.hasVerifiedCanary, "all actual readbacks follow the unchanged native canary")

                    // This solid-only scene consults no mutable drawing service. Both safe reuse and forced redraw
                    // are compared with independently built Single pixels, without a manufactured host version.
                    let solid = fixture(0, scale, dark, gradient: false)
                    let prepared = try prepare(solid, context, scale, space, .none)
                    let first = try submitted(owner.update(prepared, in: window, scale: CGFloat(scale), colorSpace: space,
                        partition: .candidateComponents, context: context, cycle: 3, glass: .none))
                    let oldLayers = owner.root.sublayers ?? []
                    let repeatFrame = try unchanged(owner.update(prepared, in: window, scale: CGFloat(scale), colorSpace: space,
                        partition: .candidateComponents, context: context, cycle: 3, glass: .none))
                    t.equal(repeatFrame.sequence, first.sequence)
                    t.equal(repeatFrame.change, .unchanged)
                    t.check(first.contents.count == repeatFrame.contents.count &&
                            zip(first.contents, repeatFrame.contents).allSatisfy { $0.0.image === $0.1.image },
                            "safe unchanged retains the exact immutable images")
                    t.check(oldLayers.count == (owner.root.sublayers ?? []).count &&
                            zip(oldLayers, owner.root.sublayers ?? []).allSatisfy { $0.0 === $0.1 }, "safe unchanged does not rebuild layers")
                    let reference = try baseline(solid, context, 3, scale, space, .none)
                    let expected = try renderer.render(cTree(reference, scale), at: 0, deadline: .now() + .seconds(30))
                    t.equal(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba, expected.rgba)
                    let changedCycle = try submitted(owner.update(prepared, in: window, scale: CGFloat(scale), colorSpace: space,
                        partition: .candidateComponents, context: context, cycle: 4, glass: .none))
                    t.equal(changedCycle.change, .all(.cycle), "cycle is an input even when scene values did not move")
                    t.equal(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba, expected.rgba)
                    var missing = solid
                    missing.backgroundImageDependencies = [ImageDependency(path: "synthetic:missing-base", stamp: nil)]
                    let unresolved = try prepare(missing, context, scale, space, .none)
                    _ = try submitted(owner.update(unresolved, in: window, scale: CGFloat(scale), colorSpace: space,
                        partition: .candidateComponents, context: context, cycle: 4, glass: .none))
                    let redraw = try submitted(owner.update(unresolved, in: window, scale: CGFloat(scale), colorSpace: space,
                        partition: .candidateComponents, context: context, cycle: 4, glass: .none))
                    t.equal(redraw.change, .all(.missingImageStamp("synthetic:missing-base")))
                    t.equal(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba, expected.rgba)
                    withExtendedLifetime(tree) {}
                }
            }
            try decisionInputTests(t, device, space)
        }
    }

    /// These are literal owner inputs, not a fabricated host acknowledgment or an external resource revision.
    /// An identical scene generation cannot hide changed scene values, a context, glass, scale or strategy.
    private static func frozenSelectionTests(_ t: AppTestRunner) {
        t.suite("Runtime: layer runtime: frozen base selection survives hidden empty and restored content") {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: frozen-selection native qualification did not run")
            }
            let space = try rgb(CGColorSpace.sRGB)
            for scale in [1, 2] {
                for dark in [false, true] {
                    let window = try rect(0, 0, width * scale, height * scale)
                    let glass = GlassPaint.placeholder(dark: dark)
                    let context = DrawContext(fonts: AppFontResolver()), owner = try runtime(), tree = host(owner.root, scale)
                    let renderer = try OffscreenRenderer(width: window.width, height: window.height, device: device,
                                                         maximumReadbackBytes: window.width * window.height * 4)
                    let selected = [baseID, backID]
                    var a = fixture(0, scale, dark, gradient: false)
                    a.elements[1].items = [fill(0, 0, Double(width), Double(height), RGBA(r: 191, g: 71, b: 43, a: 113))]
                    func draw(_ scene: WidgetScene, active: [ElementID], cycle: Int) throws -> (LayerRuntime.Frame, [UInt8]) {
                        let frame = try submitted(owner.update(prepare(scene, context, scale, space, glass), in: window,
                            scale: CGFloat(scale), colorSpace: space, partition: .candidateComponents,
                            context: context, cycle: cycle, glass: glass))
                        t.equal(frame.fallback, nil)
                        t.equal(frame.plan.baseMembers, active)
                        let single = try baseline(scene, DrawContext(fonts: AppFontResolver()), cycle, scale, space, glass)
                        let expected = try renderer.render(cTree(single, scale), at: 0, deadline: .now() + .seconds(30)).rgba
                        let actual = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba
                        checkFixture(actual, window, t)
                        t.equal(actual, expected, "active frozen-base contents match an independent fresh Single strictly")
                        return (frame, actual)
                    }
                    let (first, aPixels) = try draw(a, active: selected, cycle: 0)
                    let firstImageTree = cTree(first.contents, scale)
                    var hidden = a
                    hidden.elements[1].visibility = .collapsed
                    hidden.elements[1].frame = SkinRect(x: 0, y: 0, width: 0, height: 0)
                    let (hiddenFrame, hiddenPixels) = try draw(hidden, active: [baseID], cycle: 1)
                    t.equal(hiddenFrame.change, .all(.partition))
                    t.check(hiddenPixels != aPixels, "omitting the real colored base member changes nonempty native pixels")
                    let (_, restoredPixels) = try draw(a, active: selected, cycle: 2)
                    t.equal(restoredPixels, aPixels, "A returns exactly after a selected member was hidden")

                    var smaller = a
                    smaller.elements[1].items = [fill(1, 1, 2, 2, RGBA(r: 17, g: 83, b: 199, a: 255))]
                    smaller.elements[1].frame = SkinRect(x: 1, y: 1, width: 2, height: 2)
                    let (_, smallerPixels) = try draw(smaller, active: selected, cycle: 3)
                    t.check(smallerPixels != aPixels && smallerPixels != hiddenPixels)
                    t.equal(try ComponentPartition.candidatePlan(prepare(smaller, context, scale, space, glass),
                                                                in: window).baseMembers, [baseID],
                            "the small returning member stays selected only because the owner retained its original identity")
                    var empty = a
                    empty.elements[1].items = []
                    let (emptyFrame, emptyPixels) = try draw(empty, active: [baseID], cycle: 4)
                    t.equal(emptyFrame.plan.skipped, [backID])
                    t.equal(emptyPixels, hiddenPixels, "visible empty content contributes exactly no pixels")
                    var outside = a
                    outside.elements[1].items = [fill(Double(width + 1), 0, 2, 2, RGBA(r: 17, g: 83, b: 199, a: 255))]
                    let (outsideFrame, outsidePixels) = try draw(outside, active: [baseID], cycle: 5)
                    t.equal(outsideFrame.plan.skipped, [backID])
                    t.equal(outsidePixels, hiddenPixels, "off-window selected content contributes exactly no pixels")
                    let (_, afterEmptyPixels) = try draw(a, active: selected, cycle: 6)
                    t.equal(afterEmptyPixels, aPixels)
                    var changed = a
                    changed.elements[1].items = [fill(0, 0, Double(width), Double(height), RGBA(r: 19, g: 173, b: 211, a: 147))]
                    let (changedFrame, changedPixels) = try draw(changed, active: selected, cycle: 7)
                    t.check(changedPixels != aPixels, "retained identity cannot suppress changed base paint")
                    t.equal(try renderer.render(firstImageTree, at: 0, deadline: .now() + .seconds(30)).rgba, aPixels,
                            "old immutable base/group images survive hidden, restored and changed content")

                    // Reordering an inactive member is still invalid: complete source order, not only drawn order,
                    // proves that the retained identity list belongs to this scene.
                    var reordered = hidden
                    reordered.elements.swapAt(0, 1)
                    let oldLayers = owner.root.sublayers ?? [], oldBounds = owner.root.bounds
                    do {
                        _ = try owner.update(prepare(reordered, context, scale, space, glass), in: window,
                            scale: CGFloat(scale), colorSpace: space, partition: .candidateComponents,
                            context: context, cycle: 8, glass: glass)
                        t.check(false, "a reordered frozen selection must fail before painting")
                    } catch let error as ComponentPartition.Failure {
                        t.equal(error, .invalidPlan("Frozen base members must be the drawn scene's leading content prefix"))
                    }
                    try checkRetained(owner, changedFrame, oldLayers, oldBounds, tree, renderer, changedPixels, t)
                    let (recovered, recoveredPixels) = try draw(a, active: selected, cycle: 8)
                    t.equal(recovered.change, .all(.previousFailure))
                    t.equal(recoveredPixels, aPixels)
                    let beforeDiscardLayers = owner.root.sublayers ?? [], beforeDiscardBounds = owner.root.bounds
                    let discarded = try ready(owner.prepare(prepare(hidden, context, scale, space, glass), in: window,
                        scale: CGFloat(scale), colorSpace: space, partition: .candidateComponents,
                        context: context, cycle: 9, glass: glass))
                    t.equal(discarded.frame.plan.baseMembers, [baseID])
                    try owner.discard(discarded)
                    try checkRetained(owner, recovered, beforeDiscardLayers, beforeDiscardBounds, tree, renderer, aPixels, t)
                    _ = try draw(smaller, active: selected, cycle: 9)

                    // The initial small foreground fits below two full-window buffers. Enlarging that foreground
                    // while hiding the selected overlay needs a full-window group pair and exceeds the same budget.
                    let bytes = try Rasterizer.requiredBytes(width: window.width, height: window.height)
                    let limited = try LayerRuntime(executor: MainSkinExecutor.shared, maximumOwnedBitmapBytes: bytes * 2 - 1)
                    let limitedTree = host(limited.root, scale)
                    let limitedFrame = try submitted(limited.update(prepare(a, context, scale, space, glass), in: window,
                        scale: CGFloat(scale), colorSpace: space, partition: .candidateComponents,
                        context: context, cycle: 0, glass: glass))
                    t.equal(limitedFrame.plan.baseMembers, selected)
                    let limitedPixels = try renderer.render(limitedTree, at: 0, deadline: .now() + .seconds(30)).rgba
                    t.equal(limitedPixels, aPixels)
                    let limitedLayers = limited.root.sublayers ?? [], limitedBounds = limited.root.bounds
                    var expensive = hidden
                    expensive.elements[2].items = [fill(0, 0, Double(width), Double(height), RGBA(r: 181, g: 31, b: 233, a: 231))]
                    try expectRasterizer(.resourceLimit, t) {
                        _ = try limited.update(prepare(expensive, context, scale, space, glass), in: window,
                            scale: CGFloat(scale), colorSpace: space, partition: .candidateComponents,
                            context: context, cycle: 1, glass: glass)
                    }
                    try checkRetained(limited, limitedFrame, limitedLayers, limitedBounds, limitedTree, renderer, limitedPixels, t)
                    let affordable = try submitted(limited.update(prepare(smaller, context, scale, space, glass), in: window,
                        scale: CGFloat(scale), colorSpace: space, partition: .candidateComponents,
                        context: context, cycle: 1, glass: glass))
                    t.equal(affordable.plan.baseMembers, selected, "a failed hidden transition cannot replace selected identities")
                    t.equal(try renderer.render(limitedTree, at: 0, deadline: .now() + .seconds(30)).rgba, smallerPixels)
                    t.check(renderer.hasVerifiedCanary)
                    withExtendedLifetime([tree, limitedTree, firstImageTree]) {}
                }
            }
        }
    }

    private static func decisionInputTests(_ t: AppTestRunner, _ device: any MTLDevice, _ space: CGColorSpace) throws {
        let window = try rect(0, 0, width, height), context = DrawContext(fonts: AppFontResolver())
        let owner = try runtime(), tree = host(owner.root, 1), scene = fixture(0, 1, false, gradient: false)
        let renderer = try OffscreenRenderer(width: width, height: height, device: device, maximumReadbackBytes: width * height * 4)
        let prepared = try prepare(scene, context, 1, space, .none)
        _ = try submitted(owner.update(prepared, in: window, scale: 1, colorSpace: space,
            partition: .single, context: context, cycle: 7, glass: .none))
        let original = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba
        let paddedPreparation = try prepare(scene, context, 1, space, .none, padding: 1)
        let preparationChange = try submitted(owner.update(paddedPreparation, in: window, scale: 1, colorSpace: space,
            partition: .single, context: context, cycle: 7, glass: .none))
        t.equal(preparationChange.change, .all(.preparation), "a changed candidate table is not silently ignored for reuse")
        t.equal(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba, original)
        var environmental = scene
        environmental.environment = EnvironmentStamp(scale: 1, fontGeneration: 31,
            appearance: AppearanceStamp(value: .dark, name: "changed-captured-appearance"), imageGeneration: 53)
        var revision = scene
        revision.elements[4].drawGeneration = 101
        var dependency = scene
        dependency.backgroundImageDependencies = [ImageDependency(path: "synthetic:versioned-base",
            stamp: ImageStamp(seconds: 11, nanoseconds: 13, size: 17, inode: 19))]
        dependency.elements[4].imageDependencies = [ImageDependency(path: "synthetic:versioned-child",
            stamp: ImageStamp(seconds: 23, nanoseconds: 29, size: 31, inode: 37))]
        var changedStamp = dependency
        changedStamp.elements[4].imageDependencies = [ImageDependency(path: "synthetic:versioned-child",
            stamp: ImageStamp(seconds: 23, nanoseconds: 29, size: 41, inode: 37))]
        var child = scene
        child.elements[4].items = [fill(16, 1, 12, 16, RGBA(r: 217, g: 61, b: 139, a: 157))]
        var hidden = scene
        hidden.elements[4].visibility = .collapsed
        let changes = [("environment", environmental), ("drawing revision", revision),
                       ("known resource dependencies", dependency), ("known resource revision", changedStamp),
                       ("atomic child content", child), ("child visibility", hidden)]
        for (name, changed) in changes {
            let frame = try submitted(owner.update(prepare(changed, context, 1, space, .none), in: window, scale: 1,
                colorSpace: space, partition: .single, context: context, cycle: 7, glass: .none))
            t.equal(changed.generation, scene.generation, "the \(name) control keeps the scene generation fixed")
            t.equal(frame.change, .all(.scene), "full scene values include \(name)")
            let expected = try baseline(changed, context, 7, 1, space, .none)
            let expectedPixels = try renderer.render(cTree(expected, 1), at: 0, deadline: .now() + .seconds(30)).rgba
            let actual = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba
            t.equal(actual, expectedPixels, "\(name) agrees with independent fresh Single native pixels")
            if name == "atomic child content" || name == "child visibility" {
                t.check(actual != original, "\(name) is an actual nonempty pixel change")
            }
        }
        _ = try submitted(owner.update(prepared, in: window, scale: 1, colorSpace: space,
            partition: .single, context: context, cycle: 7, glass: .none))
        let replacementContext = DrawContext(fonts: AppFontResolver())
        let otherPrepared = try prepare(scene, replacementContext, 1, space, .none)
        let other = try submitted(owner.update(otherPrepared, in: window, scale: 1, colorSpace: space,
            partition: .single, context: replacementContext, cycle: 7, glass: .none))
        t.equal(other.change, .all(.drawingContext))
        t.equal(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba, original)

        let glass = GlassPaint.placeholder(dark: true)
        let glassFrame = try submitted(owner.update(prepare(scene, replacementContext, 1, space, glass), in: window,
            scale: 1, colorSpace: space, partition: .single, context: replacementContext, cycle: 7, glass: glass))
        t.equal(glassFrame.change, .all(.scene))
        let glassReference = try baseline(scene, replacementContext, 7, 1, space, glass)
        let glassPixels = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba
        t.equal(glassPixels, try renderer.render(cTree(glassReference, 1), at: 0, deadline: .now() + .seconds(30)).rgba)
        t.check(glassPixels != original, "GlassPaint alone changes real pixels at the same captured appearance/cycle")
        let strategy = try submitted(owner.update(prepare(scene, replacementContext, 1, space, glass), in: window,
            scale: 1, colorSpace: space, partition: .candidateComponents, context: replacementContext, cycle: 7, glass: glass))
        t.equal(strategy.change, .all(.partition))
        t.equal(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba, glassPixels)

        var smallerBase = scene
        smallerBase.elements[0].items = [fill(0, 0, 3, 2, RGBA(r: 31, g: 89, b: 151, a: 83))]
        let smallerPrepared = try prepare(smallerBase, replacementContext, 1, space, glass)
        let frozen = try submitted(owner.update(smallerPrepared, in: window, scale: 1, colorSpace: space,
            partition: .candidateComponents, context: replacementContext, cycle: 7, glass: glass))
        t.equal(frozen.plan.baseMembers, [baseID], "later geometry cannot silently reselect the original base prefix")
        t.equal(frozen.change, .all(.scene))
        let smallerReference = try baseline(smallerBase, replacementContext, 7, 1, space, glass)
        let smallerPixels = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba
        t.equal(smallerPixels, try renderer.render(cTree(smallerReference, 1), at: 0, deadline: .now() + .seconds(30)).rgba)
        t.check(smallerPixels != glassPixels, "the retained base member actually changed pixels")
        try owner.beginRefresh()
        let reselected = try submitted(owner.update(smallerPrepared, in: window, scale: 1, colorSpace: space,
            partition: .candidateComponents, context: replacementContext, cycle: 7, glass: glass))
        t.equal(reselected.plan.baseMembers, [], "refresh selects a new base from current complete recipes")
        t.equal(reselected.change, .all(.refresh))
        t.equal(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba, smallerPixels)

        let scaled = fixture(0, 2, false, gradient: false), scaledWindow = try rect(0, 0, width * 2, height * 2)
        let scaledPrepared = try prepare(scaled, replacementContext, 2, space, glass)
        let scaledFrame = try submitted(owner.update(scaledPrepared, in: scaledWindow, scale: 2, colorSpace: space,
            partition: .candidateComponents, context: replacementContext, cycle: 7, glass: glass))
        t.equal(scaledFrame.change, .all(.destination))
        t.equal(scaledFrame.plan.baseMembers, [baseID])
        let scaledTree = host(owner.root, 2)
        let scaledRenderer = try OffscreenRenderer(width: scaledWindow.width, height: scaledWindow.height, device: device,
            maximumReadbackBytes: scaledWindow.width * scaledWindow.height * 4)
        let scaledReference = try baseline(scaled, replacementContext, 7, 2, space, glass)
        let scaledPixels = try scaledRenderer.render(scaledTree, at: 0, deadline: .now() + .seconds(30)).rgba
        t.equal(scaledPixels, try scaledRenderer.render(cTree(scaledReference, 2), at: 0, deadline: .now() + .seconds(30)).rgba)
        checkFixture(scaledPixels, scaledWindow, t)

        // A gradient has no admitted deterministic native history contract for reuse in this first slice.
        let gradient = fixture(0, 1, false)
        let gradientOwner = try runtime(), gradientTree = host(gradientOwner.root, 1)
        let gradientPrepared = try prepare(gradient, context, 1, space, .none)
        _ = try submitted(gradientOwner.update(gradientPrepared, in: window, scale: 1, colorSpace: space,
            partition: .single, context: context, cycle: 7, glass: .none))
        let gradientAgain = try submitted(gradientOwner.update(gradientPrepared, in: window, scale: 1, colorSpace: space,
            partition: .single, context: context, cycle: 7, glass: .none))
        t.equal(gradientAgain.change, .all(.unversionedRecipe))
        let gradientReference = try baseline(gradient, context, 7, 1, space, .none)
        t.equal(try renderer.render(gradientTree, at: 0, deadline: .now() + .seconds(30)).rgba,
                try renderer.render(cTree(gradientReference, 1), at: 0, deadline: .now() + .seconds(30)).rgba)
        t.check(renderer.hasVerifiedCanary && scaledRenderer.hasVerifiedCanary)
        withExtendedLifetime([tree, scaledTree, gradientTree]) {}
    }

    private static func fallbackTests(_ t: AppTestRunner) {
        t.suite("Runtime: layer runtime: unresolved ink selects Single and malformed inputs preserve the last visible frame") {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: actual old-frame and fallback comparison did not run")
            }
            let space = try rgb(CGColorSpace.sRGB), window = try rect(0, 0, width, height)
            let fonts = CountingFonts(), context = DrawContext(fonts: fonts)
            let owner = try runtime(), tree = host(owner.root, 1)
            let renderer = try OffscreenRenderer(width: width, height: height, device: device, maximumReadbackBytes: width * height * 4)
            var scene = fixture(0, 1, false, gradient: false)
            scene.elements[1].items = [text()]
            let prepared = try prepare(scene, context, 1, space, .none)
            let first = try submitted(owner.update(prepared, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 0, glass: .none))
            t.equal(first.fallback, .unresolvedInk(backID, .unresolvedRasterization), "unknown text is Single, never empty ink")
            t.equal(first.plan, SinglePartition.plan(in: window))
            t.check(fonts.requests > 0, "the unknown text was actually drawn through the font capability")
            let firstPixels = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba
            let reference = try baseline(scene, context, 0, 1, space, .none)
            t.equal(firstPixels, try renderer.render(cTree(reference, 1), at: 0, deadline: .now() + .seconds(30)).rgba)
            checkFixture(firstPixels, window, t)
            let oldLayers = owner.root.sublayers ?? [], oldBounds = owner.root.bounds
            var duplicate = scene
            duplicate.elements.append(scene.elements[1])
            try expectRasterizer(.invalidPlan, t) {
                _ = try owner.update(prepare(duplicate, context, 1, space, .none), in: window, scale: 1,
                    colorSpace: space, partition: .candidateComponents, context: context, cycle: 1, glass: .none)
            }
            try checkRetained(owner, first, oldLayers, oldBounds, tree, renderer, firstPixels, t)
            var repeatedOccurrence = scene
            repeatedOccurrence.elements[2].id = ElementID(name: "DifferentNameSameOccurrence", index: backID.index)
            try expectRasterizer(.invalidPlan, t) {
                _ = try owner.update(prepare(repeatedOccurrence, context, 1, space, .none), in: window, scale: 1,
                    colorSpace: space, partition: .single, context: context, cycle: 1, glass: .none)
            }
            try checkRetained(owner, first, oldLayers, oldBounds, tree, renderer, firstPixels, t)
            try expectRasterizer(.invalidPlan, t) {
                _ = try owner.update(prepared, in: rect(1, 0, width + 1, height), scale: 1, colorSpace: space,
                    partition: .single, context: context, cycle: 1, glass: .none)
            }
            try checkRetained(owner, first, oldLayers, oldBounds, tree, renderer, firstPixels, t)
            var tooLarge = scene
            tooLarge.size = SkinSize(width: 3_000, height: 2_000)
            try expectRasterizer(.resourceLimit, t) {
                _ = try owner.update(prepare(tooLarge, context, 1, space, .none), in: rect(0, 0, 3_000, 2_000), scale: 1,
                    colorSpace: space, partition: .single, context: context, cycle: 1, glass: .none)
            }
            try checkRetained(owner, first, oldLayers, oldBounds, tree, renderer, firstPixels, t)
            try expectRasterizer(.incompatibleColorSpace, t) {
                _ = try owner.update(prepared, in: window, scale: 1, colorSpace: CGColorSpaceCreateDeviceGray(),
                    partition: .single, context: context, cycle: 1, glass: .none)
            }
            try checkRetained(owner, first, oldLayers, oldBounds, tree, renderer, firstPixels, t)
            let recovered = try submitted(owner.update(prepared, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 0, glass: .none))
            t.equal(recovered.change, .all(.previousFailure))
            t.equal(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba, firstPixels)
            let same = try submitted(owner.update(prepared, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 0, glass: .none))
            t.equal(same.change, .all(.unversionedRecipe), "font cache identity has no reusable pixel revision")
            let calls = fonts.requests
            fonts.changeToCourier()
            let changedFont = try submitted(owner.update(prepared, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 0, glass: .none))
            t.equal(changedFont.change, .all(.unversionedRecipe), "unchanged scene stamps cannot hide a live font capability change")
            t.check(fonts.requests > calls, "the changed capability was consulted")
            let newPixels = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba
            t.check(newPixels != firstPixels, "named Helvetica/Courier canary changes real glyph pixels")
            t.check(renderer.hasVerifiedCanary)

            // A valid but false ideal candidate is not native coverage. The deliberate omitted colored unit must
            // remain nonempty and disagree with an independent complete Single, not silently certify itself.
            let solid = fixture(0, 1, false, gradient: false)
            let correct = try prepare(solid, context, 1, space, .none)
            var runInk = correct.runInk
            runInk[2] = .empty
            let falseCandidate = SceneInkCandidates(scene: solid, elementInk: correct.elementInk, runInk: runInk)
            let negative = try runtime(), negativeTree = host(negative.root, 1)
            _ = try submitted(negative.update(falseCandidate, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 0, glass: .none))
            let negativePixels = try renderer.render(negativeTree, at: 0, deadline: .now() + .seconds(30)).rgba
            let full = try baseline(solid, context, 0, 1, space, .none)
            let fullPixels = try renderer.render(cTree(full, 1), at: 0, deadline: .now() + .seconds(30)).rgba
            t.check(negativePixels.contains { $0 != 0 })
            t.check(negativePixels != fullPixels, "native oracle rejects the forged empty ink candidate")
            withExtendedLifetime([tree, negativeTree]) {}
        }
    }

    private static func antialiasedLineTests(_ t: AppTestRunner) {
        t.suite("Runtime: layer runtime: local antialiased segments use exact Single without changing curve rules") {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: actual local-stroke fallback comparison did not run")
            }
            let space = try rgb(CGColorSpace.sRGB)
            func segment(_ aa: Bool, alpha: Double = 187) -> DrawItem {
                .roundline(RoundlineDraw(shape: .line(x1: 3.25, y1: 4.5, x2: 9.75, y2: 8.25, width: 1),
                    color: RGBA(r: 239, g: 173, b: 29, a: alpha), antiAlias: aa))
            }
            let fallback = LayerRuntime.Fallback.localizedAntialiasedLine(group: .group(fileIndex: backID.index))
            for scale in [1, 2] {
                let window = try rect(0, 0, width * scale, height * scale)
                let context = DrawContext(fonts: AppFontResolver()), owner = try runtime()
                let tree = host(owner.root, scale)
                let renderer = try OffscreenRenderer(width: window.width, height: window.height, device: device,
                                                     maximumReadbackBytes: window.width * window.height * 4)
                let plain = fixture(0, scale, false, gradient: false)
                var line = plain
                line.elements[1].items = [.antialias(false, [.transformed(
                    ShapeTransform(a: 1, b: 0, c: 0, d: 1, tx: 0.5, ty: 0.25), [segment(true)])])]

                func checkNative(_ scene: WidgetScene, _ runtime: LayerRuntime, _ host: CALayer,
                                 _ expectedFallback: LayerRuntime.Fallback?) throws -> (LayerRuntime.Frame, [UInt8]) {
                    let prepared = try prepare(scene, context, scale, space, .none)
                    // Same scene generation, cycle and context: a changed line/plan must still invalidate reuse.
                    let frame = try submitted(runtime.update(prepared, in: window, scale: CGFloat(scale), colorSpace: space,
                        partition: .candidateComponents, context: context, cycle: 0, glass: .none))
                    t.equal(frame.fallback, expectedFallback)
                    let actual = try renderer.render(host, at: 0, deadline: .now() + .seconds(30)).rgba
                    let coldContext = DrawContext(fonts: AppFontResolver())
                    let reference = try baseline(scene, coldContext, 0, scale, space, .none)
                    let expected = try renderer.render(cTree(reference, scale), at: 0, deadline: .now() + .seconds(30)).rgba
                    t.check(stride(from: 3, to: actual.count, by: 4).contains { actual[$0] > 0 })
                    t.equal(actual, expected, "fallback/native Single uses strict active RGBA bytes")
                    let fresh = try self.runtime()
                    let cold = try submitted(fresh.update(prepared, in: window, scale: CGFloat(scale), colorSpace: space,
                        partition: .candidateComponents, context: coldContext, cycle: 0, glass: .none))
                    t.equal(try renderer.render(cTree(cold.contents, scale), at: 0,
                                               deadline: .now() + .seconds(30)).rgba, actual,
                            "fresh/incremental remains exact across fallback decisions")
                    return (frame, actual)
                }

                var samples: [[UInt8]] = [], saved: [LayerContentBuilder.Content] = []
                for (index, scene) in [plain, line, plain].enumerated() {
                    let (frame, pixels) = try checkNative(scene, owner, tree, index == 1 ? fallback : nil)
                    t.equal(frame.sequence, UInt64(index + 1))
                    if index == 1 { t.equal(frame.plan, SinglePartition.plan(in: window)) }
                    else { t.equal(frame.plan.baseMembers, [baseID]) }
                    if index == 0 { saved = frame.contents }
                    samples.append(pixels)
                }
                t.check(samples[0] != samples[1], "B really changes visible pixels")
                t.equal(samples[0], samples[2], "A returns exactly after the local-stroke Single frame")
                t.equal(try renderer.render(cTree(saved, scale), at: 0, deadline: .now() + .seconds(30)).rgba, samples[0],
                        "saved component images remain unchanged after the builder switches twice")

                // Shrink a frozen base below the initial size threshold while Single is active, then return to
                // components. A fallback must not replace the retained base prefix with Single's empty prefix.
                var smallBaseLine = line
                smallBaseLine.elements[0].items = [fill(0, 0, 8, 5, RGBA(r: 31, g: 89, b: 151, a: 83))]
                _ = try checkNative(smallBaseLine, owner, tree, fallback)
                let (repeated, _) = try checkNative(smallBaseLine, owner, tree, fallback)
                t.equal(repeated.change, .all(.unversionedRecipe), "a line recipe does not gain an unsafe reuse shortcut")
                var smallBasePlain = smallBaseLine
                smallBasePlain.elements[1].items = plain.elements[1].items
                let (returned, _) = try checkNative(smallBasePlain, owner, tree, nil)
                t.equal(returned.plan.baseMembers, [baseID], "fallback preserves the last component base membership")

                let noPaint = DrawItem.roundline(RoundlineDraw(shape: .none, color: .white, antiAlias: true))
                let curve = DrawItem.roundline(RoundlineDraw(shape: .sector(centerX: 7, centerY: 7, innerRadius: 2,
                    outerRadius: 3, startAngle: 0, sweep: Double.pi), color: .white, antiAlias: true))
                let clip = SkinRect(x: 2, y: 2, width: 10, height: 10)
                let controls: [(String, [DrawItem])] = [
                    ("the leaf's disabled AA overrides the outer true flag", [.antialias(true, [segment(false)])]),
                    ("a transparent line grants no fallback", [segment(true, alpha: 0)]),
                    ("none is not a stroke", [noPaint]),
                    ("a partial sector keeps the existing curve rule", [curve]),
                    ("a container without content never executes its mask", [.container(clip: clip, mask: [segment(true)], content: [])]),
                    ("a zero-width clip does not execute its content", [.container(clip: SkinRect(x: 2, y: 2, width: 0, height: 10),
                        mask: [fill(2, 2, 10, 10, .white)], content: [segment(true)])])
                ]
                for (label, items) in controls {
                    var scene = plain
                    scene.elements[1].items += items
                    let control = try runtime()
                    let frame = try submitted(control.update(prepare(scene, context, scale, space, .none), in: window,
                        scale: CGFloat(scale), colorSpace: space, partition: .candidateComponents, context: context,
                        cycle: 0, glass: .none))
                    t.equal(frame.fallback, nil, label)
                    t.check(frame.plan.layers.contains { if case .group = $0.content { return true }; return false }, label)
                }

                for inMask in [true, false] {
                    var scene = plain
                    let placed = DrawItem.transformed(ShapeTransform(a: 1, b: 0, c: 0, d: 1, tx: 16, ty: 0), [segment(true)])
                    scene.elements[inMask ? 3 : 4].items = [placed]
                    let containerOwner = try runtime(), containerTree = host(containerOwner.root, scale)
                    _ = try checkNative(scene, containerOwner, containerTree,
                        .localizedAntialiasedLine(group: .group(fileIndex: maskID.index)))
                }

                var baseOnly = plain
                baseOnly.elements[0].items.append(segment(true))
                var hidden = plain
                var hiddenElement = element(ElementID(name: "HiddenLine", index: 20), [segment(true)])
                hiddenElement.visibility = .hiddenKeepsSpace
                hidden.elements.append(hiddenElement)
                var fullGroup = plain
                fullGroup.elements = [element(baseID, [fill(0, 0, 2, 2, .white)]),
                    element(backID, [fill(0, 0, Double(width), Double(height), RGBA(r: 31, g: 89, b: 151)), segment(true)])]
                for scene in [baseOnly, hidden, fullGroup] {
                    let control = try runtime(), controlTree = host(control.root, scale)
                    _ = try checkNative(scene, control, controlTree, nil)
                }

                // A local bitmap may start at zero but still have a different height/CTM from the window.
                var atOrigin = plain
                atOrigin.elements = [element(backID, [fill(0, 0, 12, 10, .white), segment(true)])]
                let originOwner = try runtime(), originTree = host(originOwner.root, scale)
                _ = try checkNative(atOrigin, originOwner, originTree, fallback)

                // A component plan can fit while the two full-window Single buffers cannot. No budget is raised,
                // and neither that failure nor invalid scene geometry is allowed to replace the visible frame.
                let limited = try LayerRuntime(executor: MainSkinExecutor.shared,
                    maximumOwnedBitmapBytes: window.width * window.height * 8 - 1)
                let limitedTree = host(limited.root, scale)
                var cheap = plain
                cheap.elements = [plain.elements[0], element(backID, [segment(false)])]
                let old = try submitted(limited.update(prepare(cheap, context, scale, space, .none), in: window,
                    scale: CGFloat(scale), colorSpace: space, partition: .candidateComponents, context: context,
                    cycle: 0, glass: .none))
                t.equal(old.fallback, nil)
                let oldPixels = try renderer.render(limitedTree, at: 0, deadline: .now() + .seconds(30)).rgba
                let oldLayers = limited.root.sublayers ?? [], oldBounds = limited.root.bounds
                var expensive = cheap
                expensive.elements[1].items = [segment(true)]
                try expectRasterizer(.resourceLimit, t) {
                    _ = try limited.update(prepare(expensive, context, scale, space, .none), in: window,
                        scale: CGFloat(scale), colorSpace: space, partition: .candidateComponents, context: context,
                        cycle: 0, glass: .none)
                }
                try checkRetained(limited, old, oldLayers, oldBounds, limitedTree, renderer, oldPixels, t)
                var malformed = expensive
                malformed.size.width -= 1
                try expectRasterizer(.invalidInput, t) {
                    _ = try limited.update(prepare(malformed, context, scale, space, .none), in: window,
                        scale: CGFloat(scale), colorSpace: space, partition: .candidateComponents, context: context,
                        cycle: 0, glass: .none)
                }
                try checkRetained(limited, old, oldLayers, oldBounds, limitedTree, renderer, oldPixels, t)
                t.check(renderer.hasVerifiedCanary)
                withExtendedLifetime([tree, limitedTree]) {}
            }
        }
    }

    private static func antialiasedFullCircleTests(_ t: AppTestRunner) {
        t.suite("Runtime: layer runtime: localized full circles preserve exact Single and allocation failures") {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: actual full-circle fallback comparison did not run")
            }
            let space = try rgb(CGColorSpace.sRGB), turn = RoundMeterMath.fullCircle
            func circle(_ sweep: Double, aa: Bool = true, alpha: Double = 187, inner: Double = 2.25) -> DrawItem {
                .roundline(RoundlineDraw(shape: .sector(centerX: 7.25, centerY: 7.75, innerRadius: inner,
                    outerRadius: 3.5, startAngle: 0.3, sweep: sweep),
                    color: RGBA(r: 239, g: 173, b: 29, a: alpha), antiAlias: aa))
            }
            let segment = DrawItem.roundline(RoundlineDraw(shape: .line(x1: 3.25, y1: 4.5,
                x2: 9.75, y2: 8.25, width: 1), color: .white, antiAlias: true))
            let fallback = LayerRuntime.Fallback.localizedAntialiasedFullCircle(group: .group(fileIndex: backID.index))
            for scale in [1, 2] {
                let window = try rect(0, 0, width * scale, height * scale)
                let context = DrawContext(fonts: AppFontResolver()), owner = try runtime(), tree = host(owner.root, scale)
                let renderer = try OffscreenRenderer(width: window.width, height: window.height, device: device,
                                                     maximumReadbackBytes: window.width * window.height * 4)
                let plain = fixture(0, scale, false, gradient: false)
                var ring = plain
                ring.elements[1].items = [.antialias(false, [.transformed(
                    ShapeTransform(a: 1, b: 0, c: 0, d: 1, tx: 0.5, ty: 0.25), [circle(turn)])])]

                func checkNative(_ scene: WidgetScene, _ runtime: LayerRuntime, _ host: CALayer,
                                 _ expected: LayerRuntime.Fallback?) throws -> (LayerRuntime.Frame, [UInt8]) {
                    let prepared = try prepare(scene, context, scale, space, .none)
                    let frame = try submitted(runtime.update(prepared, in: window, scale: CGFloat(scale), colorSpace: space,
                        partition: .candidateComponents, context: context, cycle: 0, glass: .none))
                    t.equal(frame.fallback, expected)
                    let pixels = try renderer.render(host, at: 0, deadline: .now() + .seconds(30)).rgba
                    let coldContext = DrawContext(fonts: AppFontResolver())
                    let reference = try baseline(scene, coldContext, 0, scale, space, .none)
                    t.check(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 })
                    t.equal(pixels, try renderer.render(cTree(reference, scale), at: 0,
                        deadline: .now() + .seconds(30)).rgba, "full-circle fallback uses exact native Single bytes")
                    let fresh = try self.runtime()
                    let cold = try submitted(fresh.update(prepare(scene, coldContext, scale, space, .none), in: window,
                        scale: CGFloat(scale), colorSpace: space, partition: .candidateComponents, context: coldContext,
                        cycle: 0, glass: .none))
                    t.equal(try renderer.render(cTree(cold.contents, scale), at: 0,
                        deadline: .now() + .seconds(30)).rgba, pixels, "fresh/incremental remains exact")
                    return (frame, pixels)
                }

                var samples: [[UInt8]] = [], saved: [LayerContentBuilder.Content] = []
                for (index, scene) in [plain, ring, plain].enumerated() {
                    let (frame, pixels) = try checkNative(scene, owner, tree, index == 1 ? fallback : nil)
                    t.equal(frame.sequence, UInt64(index + 1))
                    if index == 1 { t.equal(frame.plan, SinglePartition.plan(in: window)) }
                    else { t.equal(frame.plan.baseMembers, [baseID]) }
                    if index == 0 { saved = frame.contents }
                    samples.append(pixels)
                }
                t.check(samples[0] != samples[1], "the circle changes visible pixels")
                t.equal(samples[0], samples[2], "A returns exactly after the full-circle Single frame")
                t.equal(try renderer.render(cTree(saved, scale), at: 0,
                    deadline: .now() + .seconds(30)).rgba, samples[0], "retained images survive both builder switches")

                // Exact signed threshold and the renderer's disc branch share the same full-circle rule.
                for sweep in [turn, -turn, turn.nextUp, -turn.nextUp, 6.28318531] {
                    var scene = plain
                    scene.elements[1].items = [circle(sweep)]
                    _ = try checkNative(scene, owner, tree, fallback)
                }
                var disc = plain
                disc.elements[1].items = [circle(turn, inner: 0)]
                _ = try checkNative(disc, owner, tree, fallback)

                // An unchanged scene/cycle must not reuse a context-dependent circle, and switching back must
                // keep the original frozen base prefix even after that base has shrunk below half the window.
                var smallBase = ring
                smallBase.elements[0].items = [fill(0, 0, 8, 5, RGBA(r: 31, g: 89, b: 151, a: 83))]
                _ = try checkNative(smallBase, owner, tree, fallback)
                let (repeated, _) = try checkNative(smallBase, owner, tree, fallback)
                t.equal(repeated.change, .all(.unversionedRecipe))
                smallBase.elements[1].items = plain.elements[1].items
                let (returned, _) = try checkNative(smallBase, owner, tree, nil)
                t.equal(returned.plan.baseMembers, [baseID])

                let clip = SkinRect(x: 2, y: 2, width: 10, height: 10)
                let controls: [(String, [DrawItem])] = [
                    ("positive nextDown is a partial sector", [circle(turn.nextDown)]),
                    ("negative nextDown magnitude is a partial sector", [circle(-turn.nextDown)]),
                    ("the leaf's AA flag overrides an enclosing true flag", [.antialias(true, [circle(turn, aa: false)])]),
                    ("transparent full circles do not request fallback", [circle(turn, alpha: 0)]),
                    ("none does not request fallback", [.roundline(RoundlineDraw(shape: .none, color: .white, antiAlias: true))]),
                    ("a container without content never executes its mask", [.container(clip: clip, mask: [circle(turn)], content: [])]),
                    ("a zero-width clip never executes its content", [.container(clip: SkinRect(x: 2, y: 2, width: 0, height: 10),
                        mask: [fill(2, 2, 10, 10, .white)], content: [circle(turn)])])
                ]
                for (label, items) in controls {
                    var scene = plain
                    scene.elements[1].items += items
                    let control = try runtime()
                    let frame = try submitted(control.update(prepare(scene, context, scale, space, .none), in: window,
                        scale: CGFloat(scale), colorSpace: space, partition: .candidateComponents, context: context,
                        cycle: 0, glass: .none))
                    t.equal(frame.fallback, nil, label)
                    t.check(frame.plan.layers.contains { if case .group = $0.content { return true }; return false }, label)
                }

                for inMask in [true, false] {
                    var scene = plain
                    scene.elements[inMask ? 3 : 4].items = [.transformed(
                        ShapeTransform(a: 1, b: 0, c: 0, d: 1, tx: 16, ty: 0), [circle(-turn)])]
                    let containerOwner = try runtime(), containerTree = host(containerOwner.root, scale)
                    _ = try checkNative(scene, containerOwner, containerTree,
                        .localizedAntialiasedFullCircle(group: .group(fileIndex: maskID.index)))
                }
                // Adding a circle before a line must preserve the existing line reason, within one recipe
                // and when the line is in a later, separate container group.
                for laterGroup in [false, true] {
                    var scene = ring
                    if laterGroup {
                        scene.elements[3].items = [.transformed(
                            ShapeTransform(a: 1, b: 0, c: 0, d: 1, tx: 16, ty: 0), [segment])]
                    } else { scene.elements[1].items.append(segment) }
                    let mixed = try runtime(), mixedTree = host(mixed.root, scale)
                    _ = try checkNative(scene, mixed, mixedTree,
                        .localizedAntialiasedLine(group: .group(fileIndex: laterGroup ? maskID.index : backID.index)))
                }

                var baseOnly = plain
                baseOnly.elements[0].items.append(circle(turn))
                var hidden = plain
                var hiddenElement = element(ElementID(name: "HiddenCircle", index: 20), [circle(turn)])
                hiddenElement.visibility = .hiddenKeepsSpace
                hidden.elements.append(hiddenElement)
                var fullGroup = plain
                fullGroup.elements = [element(baseID, [fill(0, 0, 2, 2, .white)]), element(backID,
                    [fill(0, 0, Double(width), Double(height), RGBA(r: 31, g: 89, b: 151)), circle(turn)])]
                for scene in [baseOnly, hidden, fullGroup] {
                    let control = try runtime(), controlTree = host(control.root, scale)
                    _ = try checkNative(scene, control, controlTree, nil)
                }
                var atOrigin = plain
                atOrigin.elements = [element(backID, [fill(0, 0, 12, 12, .white), circle(turn)])]
                let originOwner = try runtime(), originTree = host(originOwner.root, scale)
                _ = try checkNative(atOrigin, originOwner, originTree, fallback)

                let limited = try LayerRuntime(executor: MainSkinExecutor.shared,
                    maximumOwnedBitmapBytes: window.width * window.height * 8 - 1)
                let limitedTree = host(limited.root, scale)
                var cheap = plain
                cheap.elements = [plain.elements[0], element(backID, [circle(turn, aa: false)])]
                let old = try submitted(limited.update(prepare(cheap, context, scale, space, .none), in: window,
                    scale: CGFloat(scale), colorSpace: space, partition: .candidateComponents, context: context,
                    cycle: 0, glass: .none))
                t.equal(old.fallback, nil)
                let oldPixels = try renderer.render(limitedTree, at: 0, deadline: .now() + .seconds(30)).rgba
                let oldLayers = limited.root.sublayers ?? [], oldBounds = limited.root.bounds
                var expensive = cheap
                expensive.elements[1].items = [circle(turn)]
                try expectRasterizer(.resourceLimit, t) {
                    _ = try limited.update(prepare(expensive, context, scale, space, .none), in: window,
                        scale: CGFloat(scale), colorSpace: space, partition: .candidateComponents, context: context,
                        cycle: 0, glass: .none)
                }
                try checkRetained(limited, old, oldLayers, oldBounds, limitedTree, renderer, oldPixels, t)
                var malformed = expensive
                malformed.size.width -= 1
                try expectRasterizer(.invalidInput, t) {
                    _ = try limited.update(prepare(malformed, context, scale, space, .none), in: window,
                        scale: CGFloat(scale), colorSpace: space, partition: .candidateComponents, context: context,
                        cycle: 0, glass: .none)
                }
                try checkRetained(limited, old, oldLayers, oldBounds, limitedTree, renderer, oldPixels, t)
                t.check(renderer.hasVerifiedCanary)
                withExtendedLifetime([tree, limitedTree, originTree]) {}
            }
        }
    }

    private static func elementCountTests(_ t: AppTestRunner) {
        t.suite("Runtime: layer runtime: element count guard retains exact Single for the current load") {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: element-count native comparison did not run")
            }
            let space = try rgb(CGColorSpace.sRGB)
            let fallback = LayerRuntime.Fallback.elementCountExceeded(actual: 5_001, limit: 5_000)
            for scale in [1, 2] {
                let window = try rect(0, 0, width * scale, height * scale)
                let context = DrawContext(fonts: AppFontResolver()), owner = try runtime(), tree = host(owner.root, scale)
                let renderer = try OffscreenRenderer(width: window.width, height: window.height, device: device,
                                                     maximumReadbackBytes: window.width * window.height * 4)
                let small = fixture(0, scale, false, gradient: false)
                let atLimit = paddingElements(small, to: 5_000)
                var hiddenExtra = paddingElements(atLimit, to: 5_001)
                hiddenExtra.elements[5_000].visibility = .hiddenKeepsSpace
                var overlay = hiddenExtra
                overlay.elements[5_000].visibility = .visible
                overlay.elements[5_000].items = [fill(23, 16, 4, 3, RGBA(r: 247, g: 5, b: 193, a: 255))]

                func checkNative(_ scene: WidgetScene, _ expectedFallback: LayerRuntime.Fallback?,
                                 partition: LayerRuntime.Partition = .candidateComponents) throws -> (LayerRuntime.Frame, [UInt8]) {
                    let update = try owner.update(prepare(scene, context, scale, space, .none), in: window,
                        scale: CGFloat(scale), colorSpace: space, partition: partition, context: context, cycle: 0, glass: .none)
                    let frame: LayerRuntime.Frame
                    switch update {
                    case .submitted(let value), .unchanged(let value): frame = value
                    case .suppressed: throw CocoaError(.coderInvalidValue)
                    }
                    t.equal(frame.fallback, expectedFallback)
                    let actual = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba
                    let cold = DrawContext(fonts: AppFontResolver())
                    let reference = try baseline(scene, cold, 0, scale, space, .none)
                    let expected = try renderer.render(cTree(reference, scale), at: 0, deadline: .now() + .seconds(30)).rgba
                    checkFixture(actual, window, t)
                    t.equal(actual, expected, "every retained element draws exactly as independent fresh Single")
                    return (frame, actual)
                }

                let (first, a) = try checkNative(atLimit, nil)
                t.check(first.plan.layers.contains { if case .group = $0.content { return true }; return false },
                        "exactly 5000 elements still permits real components")
                t.equal(first.plan.baseMembers, [baseID])
                let saved = first.contents
                let (hidden, hiddenPixels) = try checkNative(hiddenExtra, fallback)
                t.equal(hidden.plan, SinglePartition.plan(in: window))
                t.equal(hiddenPixels, a, "a hidden extra still counts, but adds no painted content")
                let (last, b) = try checkNative(overlay, fallback)
                t.equal(last.plan, SinglePartition.plan(in: window))
                let pixel = (17 * scale * window.width + 24 * scale) * 4
                t.equal(Array(b[pixel..<pixel + 4]), [247, 5, 193, 255],
                        "the last visible occurrence beyond the limit is actually opaque and painted")
                t.check(b != a, "omitting that last colored occurrence is detected by native pixels")
                let (returned, again) = try checkNative(atLimit, fallback)
                t.equal(returned.plan, SinglePartition.plan(in: window), "the committed guard lasts for this load")
                t.equal(again, a, "A/B/A is exact while the load remains Single")
                let (same, _) = try checkNative(atLimit, fallback)
                t.equal(same.change, .unchanged, "reuse preserves the committed count reason")
                t.equal(try renderer.render(cTree(saved, scale), at: 0, deadline: .now() + .seconds(30)).rgba, a,
                        "older component images remain unchanged")

                let (explicit, _) = try checkNative(atLimit, nil, partition: .single)
                t.equal(explicit.plan, SinglePartition.plan(in: window))
                let (guardedAgain, _) = try checkNative(atLimit, fallback)
                t.equal(guardedAgain.change, .all(.partition), "explicit Single cannot erase the prior guard or reuse its nil reason")
                try owner.setVisible(false)
                t.check(owner.currentFrame == nil && (owner.root.sublayers ?? []).isEmpty)
                try owner.setVisible(true)
                _ = try checkNative(atLimit, fallback)
                try owner.beginRefresh()
                let (refreshed, _) = try checkNative(atLimit, nil)
                t.equal(refreshed.change, .all(.refresh))
                t.equal(refreshed.plan.baseMembers, [baseID])
                t.check(refreshed.plan.layers.contains { if case .group = $0.content { return true }; return false },
                        "a new load retries components")
                t.check(renderer.hasVerifiedCanary)
                withExtendedLifetime(tree) {}
            }
        }
        t.suite("Runtime: layer runtime: element count errors and discarded preparation preserve the committed frame") {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: element-count error and old-frame comparison did not run")
            }
            let space = try rgb(CGColorSpace.sRGB), window = try rect(0, 0, width, height)
            let context = DrawContext(fonts: AppFontResolver()), owner = try runtime(), tree = host(owner.root, 1)
            let renderer = try OffscreenRenderer(width: width, height: height, device: device,
                                                 maximumReadbackBytes: width * height * 4)
            let small = fixture(0, 1, false, gradient: false), large = paddingElements(small, to: 5_001)
            let smallPrepared = try prepare(small, context, 1, space, .none)
            let largePrepared = try prepare(large, context, 1, space, .none)
            let first = try submitted(owner.update(smallPrepared, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 0, glass: .none))
            let pixels = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba
            checkFixture(pixels, window, t)
            let layers = owner.root.sublayers ?? [], bounds = owner.root.bounds
            guard case .ready(let discarded) = try owner.prepare(largePrepared, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 0, glass: .none) else { throw CocoaError(.coderInvalidValue) }
            t.equal(discarded.frame.fallback, .elementCountExceeded(actual: 5_001, limit: 5_000))
            try checkRetained(owner, first, layers, bounds, tree, renderer, pixels, t)
            try owner.discard(discarded)
            let old = try submitted(owner.update(smallPrepared, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 0, glass: .none))
            t.equal(old.fallback, nil, "discarding a ready Single cannot latch its guard")
            let oldLayers = owner.root.sublayers ?? [], oldBounds = owner.root.bounds

            func reject(_ prepared: SceneInkCandidates, _ expected: RasterizerKind,
                        in destination: Rect, colorSpace: CGColorSpace) throws {
                try expectRasterizer(expected, t) {
                    _ = try owner.update(prepared, in: destination, scale: 1, colorSpace: colorSpace,
                        partition: .candidateComponents, context: context, cycle: 0, glass: .none)
                }
                try checkRetained(owner, old, oldLayers, oldBounds, tree, renderer, pixels, t)
            }
            try reject(SceneInkCandidates(scene: large, elementInk: [], runInk: largePrepared.runInk),
                       .invalidPlan, in: window, colorSpace: space)
            var duplicate = large
            duplicate.elements[5_000].id = large.elements[0].id
            try reject(prepare(duplicate, context, 1, space, .none), .invalidPlan, in: window, colorSpace: space)
            duplicate.elements[5_000].id = ElementID(name: "UniqueNameSameOccurrence", index: large.elements[0].id.index)
            try reject(prepare(duplicate, context, 1, space, .none), .invalidPlan, in: window, colorSpace: space)
            try reject(largePrepared, .invalidPlan, in: rect(1, 0, width + 1, height), colorSpace: space)
            for badWidth in [Double(width - 1), .nan] {
                var malformed = large
                malformed.size.width = badWidth
                try reject(prepare(malformed, context, 1, space, .none), .invalidInput, in: window, colorSpace: space)
            }
            try reject(largePrepared, .incompatibleColorSpace, in: window, colorSpace: CGColorSpaceCreateDeviceGray())
            let recovered = try submitted(owner.update(smallPrepared, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 0, glass: .none))
            t.equal(recovered.fallback, nil, "invalid over-limit attempts never latch")
            t.equal(recovered.change, .all(.previousFailure))
            guard case .ready(let accepted) = try owner.prepare(largePrepared, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 0, glass: .none) else { throw CocoaError(.coderInvalidValue) }
            t.equal(owner.currentFrame?.sequence, recovered.sequence)
            t.equal(try owner.commit(accepted).fallback, .elementCountExceeded(actual: 5_001, limit: 5_000))

            let explicit = try runtime()
            t.equal(try submitted(explicit.update(largePrepared, in: window, scale: 1, colorSpace: space,
                partition: .single, context: context, cycle: 0, glass: .none)).fallback, nil)
            t.equal(try submitted(explicit.update(smallPrepared, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 0, glass: .none)).fallback, nil,
                    "an intentional Single above the cap does not trigger the component guard")

            let bytes = try Rasterizer.requiredBytes(width: width, height: height)
            let limited = try LayerRuntime(executor: MainSkinExecutor.shared, maximumOwnedBitmapBytes: bytes * 2 - 1)
            let limitedTree = host(limited.root, 1)
            var cheap = small
            cheap.elements = [small.elements[0]]
            let cheapPrepared = try prepare(cheap, context, 1, space, .none)
            let cheapOld = try submitted(limited.update(cheapPrepared, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 0, glass: .none))
            let cheapPixels = try renderer.render(limitedTree, at: 0, deadline: .now() + .seconds(30)).rgba
            checkFixture(cheapPixels, window, t)
            let cheapLayers = limited.root.sublayers ?? [], cheapBounds = limited.root.bounds
            let oversized = paddingElements(cheap, to: 5_001)
            for malformed in [false, true] {
                var attempt = oversized
                if malformed { attempt.size.width -= 1 }
                try expectRasterizer(malformed ? .invalidInput : .resourceLimit, t) {
                    _ = try limited.update(prepare(attempt, context, 1, space, .none), in: window, scale: 1, colorSpace: space,
                        partition: .candidateComponents, context: context, cycle: 0, glass: .none)
                }
                try checkRetained(limited, cheapOld, cheapLayers, cheapBounds, limitedTree, renderer, cheapPixels, t)
            }
            let cheapAgain = try submitted(limited.update(cheapPrepared, in: window, scale: 1, colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 0, glass: .none))
            t.equal(cheapAgain.fallback, nil, "failed Single allocation cannot lock the owner into an unaffordable mode")
            t.equal(cheapAgain.change, .all(.previousFailure))

            var empty = large
            empty.size = SkinSize(width: 0, height: 0)
            empty.background = []
            for i in empty.elements.indices { empty.elements[i].items = [] }
            let emptyOwner = try runtime()
            let emptyFrame = try submitted(emptyOwner.update(prepare(empty, context, 1, space, .none), in: rect(0, 0, 0, 0),
                scale: 1, colorSpace: space, partition: .candidateComponents, context: context, cycle: 0, glass: .none))
            t.equal(emptyFrame.fallback, .elementCountExceeded(actual: 5_001, limit: 5_000))
            t.check(emptyFrame.contents.isEmpty && emptyFrame.plan.layers.isEmpty,
                    "an empty destination has no fictitious bitmap success")
            t.check(renderer.hasVerifiedCanary)
            withExtendedLifetime([tree, limitedTree]) {}
        }
    }

    /// Fixture padding keeps the original visible recipe and adds unique, empty file occurrences.
    private static func paddingElements(_ original: WidgetScene, to count: Int) -> WidgetScene {
        var scene = original
        for i in scene.elements.count..<count {
            scene.elements.append(element(ElementID(name: "EmptyUnit\(i)", index: 100 + i), []))
        }
        return scene
    }

    private static func lifecycleTests(_ t: AppTestRunner) {
        t.suite("Runtime: layer runtime: hidden refresh closing and released owners keep explicit lifecycle rules") {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: actual lifecycle readback did not run")
            }
            let space = try rgb(CGColorSpace.sRGB), p3 = try rgb(CGColorSpace.displayP3)
            let window = try rect(0, 0, width, height), fonts = CountingFonts()
            let context = DrawContext(fonts: fonts), owner = try runtime(), tree = host(owner.root, 1)
            let scene = fixture(0, 1, false, gradient: false)
            let prepared = try prepare(scene, context, 1, space, .none)
            let renderer = try OffscreenRenderer(width: width, height: height, device: device, maximumReadbackBytes: width * height * 4)
            t.equal(owner.state, .loading)
            let incomplete = SceneInkCandidates(scene: scene, elementInk: [], runInk: [])
            try expectRasterizer(.invalidPlan, t) {
                _ = try owner.update(incomplete, in: window, scale: 1, colorSpace: space,
                    partition: .single, context: context, cycle: 0, glass: .none)
            }
            t.equal(owner.state, .loading, "a first-frame failure cannot transition into a presented state")
            t.check(owner.currentFrame == nil && (owner.root.sublayers ?? []).isEmpty)
            t.check(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba.allSatisfy { $0 == 0 })
            let first = try submitted(owner.update(prepared, in: window, scale: 1, colorSpace: space,
                partition: .single, context: context, cycle: 0, glass: .none))
            let pixels = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba
            checkFixture(pixels, window, t)
            try owner.beginRefresh()
            t.equal(owner.state, .refreshing)
            t.equal(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba, pixels)
            var invalid = prepared.scene
            invalid.size = SkinSize(width: 29, height: 20)
            try expectRasterizer(.invalidInput, t) {
                _ = try owner.update(prepare(invalid, context, 1, space, .none), in: window, scale: 1,
                    colorSpace: space, partition: .single, context: context, cycle: 0, glass: .none)
            }
            t.equal(owner.state, .refreshing)
            t.equal(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba, pixels)
            let replacement = try submitted(owner.update(prepared, in: window, scale: 1, colorSpace: space,
                partition: .single, context: context, cycle: 0, glass: .none))
            t.equal(replacement.sequence, first.sequence + 1)
            t.equal(replacement.change, .all(.previousFailure))
            try owner.beginRefresh()
            let refreshed = try submitted(owner.update(prepared, in: window, scale: 1, colorSpace: space,
                partition: .single, context: context, cycle: 0, glass: .none))
            t.equal(refreshed.change, .all(.refresh), "a refresh without failure also requires a complete redraw")
            t.equal(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba, pixels)
            try owner.setVisible(false)
            t.equal(owner.state, .hidden)
            t.check(owner.currentFrame == nil && (owner.root.sublayers ?? []).isEmpty)
            if case .suppressed = try owner.update(prepared, in: window, scale: 1, colorSpace: space,
                partition: .single, context: context, cycle: 0, glass: .none) { t.check(true) }
            else { t.check(false, "a hidden call cannot draw or silently present") }
            t.check(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba.allSatisfy { $0 == 0 },
                    "hidden contents are actually released from the current tree")
            try owner.setVisible(true)
            t.equal(owner.state, .loading)
            let revealed = try submitted(owner.update(prepared, in: window, scale: 1, colorSpace: space,
                partition: .single, context: context, cycle: 0, glass: .none))
            t.equal(revealed.change, .all(.released))
            t.equal(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba, pixels)

            // No host/panel generation is fabricated: destination changes are explicit method inputs.
            let p3Prepared = try prepare(scene, context, 1, p3, .none)
            let changedProfile = try submitted(owner.update(p3Prepared, in: window, scale: 1, colorSpace: p3,
                partition: .single, context: context, cycle: 0, glass: .none))
            t.equal(changedProfile.change, .all(.destination))
            t.check(changedProfile.contents.allSatisfy { $0.image.colorSpace.map { CFEqual($0, p3) } == true })
            let p3Reference = try baseline(scene, context, 0, 1, p3, .none)
            let p3Pixels = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba
            t.equal(p3Pixels, try renderer.render(cTree(p3Reference, 1), at: 0, deadline: .now() + .seconds(30)).rgba)
            checkFixture(p3Pixels, window, t)
            _ = try submitted(owner.update(prepared, in: window, scale: 1, colorSpace: space,
                partition: .single, context: context, cycle: 0, glass: .none))
            var nilChild = scene
            nilChild.elements[4].imageDependencies = [ImageDependency(path: "synthetic:missing-child", stamp: nil)]
            let childPrepared = try prepare(nilChild, context, 1, space, .none)
            _ = try submitted(owner.update(childPrepared, in: window, scale: 1, colorSpace: space,
                partition: .single, context: context, cycle: 0, glass: .none))
            let childRedraw = try submitted(owner.update(childPrepared, in: window, scale: 1, colorSpace: space,
                partition: .single, context: context, cycle: 0, glass: .none))
            t.equal(childRedraw.change, .all(.missingImageStamp("synthetic:missing-child")))
            let requests = fonts.requests
            var withText = scene
            withText.elements[1].items = [text()]
            let offOwnerInput = try prepare(withText, context, 1, space, .none)
            let beforeLayers = owner.root.sublayers ?? [], beforeSequence = owner.currentFrame?.sequence
            t.equal(SkinRuntimeSelfTests.onAnotherThread {
                do {
                    _ = try owner.update(offOwnerInput, in: window, scale: 1, colorSpace: space,
                        partition: .single, context: context, cycle: 0, glass: .none)
                    return false
                } catch LayerRuntime.Failure.wrongOwner { return !Thread.isMainThread }
                catch { return false }
            }, true, "a real separate-thread attempt rejects before drawing capabilities")
            t.equal(fonts.requests, requests)
            t.equal(owner.currentFrame?.sequence, beforeSequence)
            t.check(beforeLayers.count == (owner.root.sublayers ?? []).count &&
                    zip(beforeLayers, owner.root.sublayers ?? []).allSatisfy { $0.0 === $0.1 })

            let beforeClose = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba
            try owner.beginClose()
            t.equal(owner.state, .closing)
            do {
                _ = try owner.update(offOwnerInput, in: window, scale: 1, colorSpace: space,
                    partition: .single, context: context, cycle: 0, glass: .none)
                t.check(false, "closing cannot submit")
            } catch LayerRuntime.Failure.invalidLifecycle(.closing) { t.check(true) }
            t.equal(fonts.requests, requests)
            t.equal(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba, beforeClose)
            try owner.close()
            t.equal(owner.state, .closed)
            t.check(owner.currentFrame == nil && (owner.root.sublayers ?? []).isEmpty)
            t.check(owner.root.superlayer != nil, "owner cleanup does not mutate the main host's layer")
            t.check(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba.allSatisfy { $0 == 0 })
            do { try owner.beginRefresh(); t.check(false, "closed cannot restart without a new owner") }
            catch LayerRuntime.Failure.invalidLifecycle(.closed) { t.check(true) }
            do {
                _ = try owner.update(offOwnerInput, in: window, scale: 1, colorSpace: space,
                    partition: .single, context: context, cycle: 0, glass: .none)
                t.check(false, "closed cannot call the drawing service")
            } catch LayerRuntime.Failure.invalidLifecycle(.closed) { t.check(true) }
            t.equal(fonts.requests, requests)
            try owner.close()
            t.equal(owner.state, .closed, "closed cleanup is idempotent on the owner")

            weak var releasedContext: DrawContext?
            var released: LayerRuntime? = try runtime()
            weak var weakOwner = released
            let retainedTree = host(released!.root, 1)
            try autoreleasepool {
                let transient = DrawContext(fonts: AppFontResolver())
                releasedContext = transient
                _ = try submitted(released!.update(prepare(scene, transient, 1, space, .none), in: window, scale: 1,
                    colorSpace: space, partition: .single, context: transient, cycle: 0, glass: .none))
            }
            t.check(releasedContext == nil, "successful reuse metadata does not retain the DrawContext")
            released = nil
            t.check(weakOwner == nil, "retained C tree has no owner callback or unowned closure")
            t.equal(try renderer.render(retainedTree, at: 0, deadline: .now() + .seconds(30)).rgba, pixels)

            let emptyOwner = try runtime(), empty = try rect(0, 0, 0, 0)
            var emptyScene = scene
            emptyScene.size = SkinSize(width: 0, height: 0)
            let emptyFrame = try submitted(emptyOwner.update(prepare(emptyScene, context, 1, space, .none), in: empty,
                scale: 1, colorSpace: space, partition: .single, context: context, cycle: 0, glass: .none))
            t.check(emptyFrame.contents.isEmpty && emptyFrame.plan.window.isEmpty, "only a valid literal empty window is empty")
            t.check(renderer.hasVerifiedCanary)
            withExtendedLifetime([tree, retainedTree]) {}
        }
    }

    /// Success runs through async on the physical skin thread. Main only attaches and observes the C tree while
    /// exclusive has actually parked that thread; the lease is not mistaken for worker-side drawing.
    private static func workerOwnerTests(_ t: AppTestRunner) {
        t.suite("Runtime: layer runtime: real skin worker builds C frames before main attachment and strict Single A/B/A") {
            t.check(Thread.isMainThread && !SkinThreadExecutor.isSkinThread, "the fixture host runs on main")
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: real worker C composition did not run")
            }
            let space = try rgb(CGColorSpace.sRGB)
            for scale in [1, 2] {
                let executor = SkinThreadExecutor(name: "LayerRuntime C owner test \(scale)x")
                let worker = WorkerFixture(executor: executor)
                var tree: CALayer?
                defer {
                    var released = false, detached = false
                    do {
                        if let retirement = try workerResult(executor, t, { try worker.retire() }) {
                            t.check(retirement.onWorker, "close and release actually run on the physical worker")
                            t.equal(retirement.sequence, UInt64(3), "all three successful work items preceded cleanup")
                            t.equal(retirement.closing, LayerRuntime.State.closing)
                            t.check(retirement.keptFrame, "beginClose keeps the final immutable frame")
                            t.equal(retirement.closed, LayerRuntime.State.closed)
                            t.check(retirement.cleared, "owner cleanup clears only its own contents")
                            t.check(retirement.attached, "owner cleanup leaves main's attachment in place")
                            t.check(retirement.runtimeReleased, "the root has no callback retaining the owner")
                            t.check(retirement.contextReleased, "immutable C images retain no drawing context")
                            released = retirement.runtimeReleased && retirement.contextReleased && retirement.cleared
                            if released {
                                let removed = executor.exclusive(timeout: 30) {
                                    guard Thread.isMainThread && executor.isCurrent && !executor.isOnThread else { return false }
                                    CATransaction.begin()
                                    CATransaction.setDisableActions(true)
                                    for layer in tree?.sublayers ?? [] { layer.removeFromSuperlayer() }
                                    CATransaction.commit()
                                    return true
                                }
                                t.equal(removed, true, "main removal follows the completed owner cleanup and a real park")
                                detached = removed == true
                                if detached { t.check(tree != nil && (tree?.sublayers ?? []).isEmpty, "main's fixture host is empty") }
                            }
                        }
                    } catch {
                        t.check(false, "worker cleanup failed: \(error)")
                    }
                    executor.stop()
                    let exited = AppSelfTest.spin(timeout: 30) { executor.hasExited }
                    t.check(exited, "stop runs after the cleanup work and the physical thread exits")
                    if !released || !detached || !exited {
                        // A failed drain has no lifetime qualification. Retain its finite fixture until process exit
                        // instead of tearing down a potentially live owner/context or main attachment from this caller.
                        failedWorkerFixtures.append(FailedWorkerFixture(worker: worker, tree: tree))
                    }
                }
                t.check(!executor.isCurrent && !executor.isOnThread, "main is not this worker's owner outside a lease")
                let window = try rect(0, 0, width * scale, height * scale)
                let renderer = try OffscreenRenderer(width: window.width, height: window.height, device: device,
                                                     maximumReadbackBytes: window.width * window.height * 4)
                var saved: [[UInt8]] = []
                for (cycle, variant) in [0, 1, 0].enumerated() {
                    guard let completed = try workerResult(executor, t, {
                        try worker.draw(variant: variant, cycle: cycle, scale: scale, space: space)
                    }) else { return }
                    t.check(completed.onWorker, "preparation, C bitmap generation and fresh Single finish on the physical worker")
                    let frame = completed.frame
                    t.equal(frame.sequence, UInt64(cycle + 1))
                    t.equal(frame.fallback, nil)
                    t.equal(frame.plan.baseMembers, [baseID])
                    t.equal(frame.plan.layers.compactMap { layer -> [ElementID]? in
                        if case let .group(members) = layer.content { return members }; return nil
                    }, [[backID, frontID], [maskID]], "ordered overlap and the complete atomic container are retained")
                    t.check(completed.live)
                    if case .all = frame.change { t.check(true, "this gradient recipe actually redraws") }
                    else { t.check(false, "a worker update cannot silently reuse this unversioned recipe") }
                    t.check(frame.contents.allSatisfy { $0.image.colorSpace.map { CFEqual($0, space) } == true })
                    let slices = frame.contents.filter { if case .baseSlice = $0.plan.content { return true }; return false }
                    t.check(slices.count > 1 && slices.allSatisfy { $0.image === slices[0].image })
                    t.equal(completed.reference.count, 1, "the independent fresh builder has literal Single content")

                    let observation = executor.exclusive(timeout: 30) {
                        Result<WorkerComparison, Error> {
                            let mainLease = Thread.isMainThread && executor.isCurrent && !executor.isOnThread && !SkinThreadExecutor.isSkinThread
                            guard mainLease else { throw CocoaError(.coderInvalidValue) }
                            let root = try worker.rootForMainAttachment()
                            if tree == nil { tree = host(root, scale) }
                            guard let tree else { throw CocoaError(.coderInvalidValue) }
                            let referenceTree = cTree(completed.reference, scale)
                            let expected = try renderer.render(referenceTree, at: 0, deadline: .now() + .seconds(30))
                            let actual = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30))
                            let attached = tree.sublayers?.count == 1 && tree.sublayers?.first === root && root.superlayer === tree
                            return WorkerComparison(expected: expected, actual: actual, mainLease: mainLease, attached: attached)
                        }
                    }
                    t.check(observation != nil, "a completed worker update is followed by an actual synchronous park")
                    guard let observation else { return }
                    let compared = try observation.get()
                    t.check(compared.mainLease, "only main assembles the fixture host and observes the parked root")
                    t.check(compared.attached, "the real owner root, not a second manufactured C tree, is attached")
                    t.equal(compared.actual.width, window.width)
                    t.equal(compared.actual.height, window.height)
                    checkFixture(compared.expected.rgba, window, t)
                    t.check(stride(from: 3, to: compared.actual.rgba.count, by: 4).contains { compared.actual.rgba[$0] > 0 },
                            "actual worker content has nonempty native alpha")
                    t.equal(compared.actual.rgba, compared.expected.rgba, "worker C / worker fresh Single strict active RGBA bytes")
                    saved.append(compared.actual.rgba)
                }
                t.check(saved[0] != saved[1], "B changes native pixels on the same worker and destination")
                t.equal(saved[0], saved[2], "A returns strictly after B at \(scale)x")
                t.check(renderer.hasVerifiedCanary, "every worker readback follows the original native canary and fence")
            }
        }
    }

    private static func transferTests(_ t: AppTestRunner) {
        t.suite("Runtime: layer runtime: exported tree writers retain values without retaining drawing owners") {
            guard let device = MTLCreateSystemDefaultDevice() else { return t.check(false, "native qualification required") }
            let space = try rgb(CGColorSpace.sRGB)
            for scale in [1, 2] {
                let executor = SkinThreadExecutor(name: "LayerRuntime tree writer test \(scale)x")
                let worker = WorkerFixture(executor: executor)
                defer { executor.stop() }
                guard let initial = try workerResult(executor, t, { try worker.draw(variant: 0, cycle: 0, scale: scale, space: space) }),
                      let exported = try workerResult(executor, t, { try worker.export(variant: 1, scale: scale, space: space) }) else { return }
                let patch = exported.patch
                t.equal(patch.state, .pending)
                t.equal(patch.frame.sequence, initial.frame.sequence + 1)
                t.check(!executor.isCurrent, "export never grants main executor ownership")
                let before = patch.root.sublayers ?? []
                t.check(patch.reclaim(.invalidated))
                t.check(!patch.claimOnMain(), "invalidated pending cannot grant a late main writer")
                guard let rejected = try workerResult(executor, t, { try worker.finish(patch, commitReclaimed: false) }) else { return }
                t.equal(rejected, initial.frame.sequence, "invalidated content does not advance committed metadata")
                t.check(before.count == (patch.root.sublayers ?? []).count &&
                        zip(before, patch.root.sublayers ?? []).allSatisfy { $0.0 === $0.1 })
                guard let next = try workerResult(executor, t, { try worker.export(variant: 1, scale: scale, space: space) }) else { return }
                t.equal(next.patch.frame.sequence, patch.frame.sequence, "uncommitted sequence alone is not a lease identity")
                // Manual protocol negative/positive control; actual main callback handoff is covered by the window suite.
                t.check(next.patch.claimOnMain())
                t.check(next.patch.isMainWriter(for: next.patch.root))
                t.check(!next.patch.reclaim(.timeout))
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                t.check(next.patch.applyContentOnMain())
                CATransaction.commit()
                next.patch.finishOnMain()
                t.equal(next.patch.state, .appliedByMain)
                guard let accepted = try workerResult(executor, t, { try worker.finish(next.patch, commitReclaimed: true) }) else { return }
                t.equal(accepted, initial.frame.sequence + 1, "only owner ack advances the completed frame once")
                let renderer = try OffscreenRenderer(width: width * scale, height: height * scale, device: device,
                    maximumReadbackBytes: width * height * scale * scale * 4)
                let compare = executor.exclusive(timeout: 30) { () -> Result<Bool, Error> in
                    Result {
                        let actual = try renderer.render(host(next.patch.root, scale), at: 0, deadline: .now() + .seconds(30))
                        let expected = try renderer.render(cTree(next.reference, scale), at: 0, deadline: .now() + .seconds(30))
                        return actual.rgba == expected.rgba && stride(from: 3, to: actual.rgba.count, by: 4).contains { actual.rgba[$0] > 0 }
                    }
                }
                t.check(compare != nil)
                if let compare { t.check(try compare.get(), "transferred native contents strictly equal independently rasterized fresh Single") }
                t.check(renderer.hasVerifiedCanary)
                guard let retired = try workerResult(executor, t, { try worker.retire() }) else { return }
                t.check(retired.runtimeReleased && retired.contextReleased, "retained patches do not hold a runtime or drawing context")
                t.check(next.patch.frame.contents.allSatisfy { $0.image.width > 0 && $0.image.height > 0 },
                        "finished image values remain valid after the true owner is released")
                withExtendedLifetime([patch, next.patch]) {}
            }
        }
    }

    private struct WorkerCompletion {
        let frame: LayerRuntime.Frame
        let reference: [LayerContentBuilder.Content]
        let onWorker: Bool
        let live: Bool
    }

    private struct WorkerComparison {
        let expected: OffscreenRenderer.Readback
        let actual: OffscreenRenderer.Readback
        let mainLease: Bool
        let attached: Bool
    }

    private struct WorkerRetirement {
        let onWorker: Bool
        let sequence: UInt64?
        let closing: LayerRuntime.State?
        let keptFrame: Bool
        let closed: LayerRuntime.State?
        let cleared: Bool
        let attached: Bool
        let runtimeReleased: Bool
        let contextReleased: Bool
    }

    /// A test-only, non-Sendable owner capsule. Mutable owner/context fields are touched only by actual worker work.
    /// Main's one root access is guarded by the real executor's temporary exclusive lease, never a weak object hop.
    private final class WorkerFixture {
        let executor: SkinThreadExecutor
        private var owner: LayerRuntime?
        private var context: DrawContext?
        private weak var weakOwner: LayerRuntime?
        private weak var weakContext: DrawContext?

        init(executor: SkinThreadExecutor) { self.executor = executor }

        private var onWorker: Bool {
            executor.isCurrent && executor.isOnThread && SkinThreadExecutor.isSkinThread && !Thread.isMainThread
        }

        func draw(variant: Int, cycle: Int, scale: Int, space: CGColorSpace) throws -> WorkerCompletion {
            guard onWorker else { throw CocoaError(.coderInvalidValue) }
            if owner == nil {
                owner = try LayerRuntime(executor: executor, maximumOwnedBitmapBytes: LayerRuntimeSelfTests.budget)
                context = DrawContext(fonts: AppFontResolver())
                weakOwner = owner
                weakContext = context
            }
            guard let owner, let context else { throw CocoaError(.coderInvalidValue) }
            let scene = LayerRuntimeSelfTests.fixture(variant, scale, false), glass = GlassPaint.placeholder(dark: false)
            let window = try LayerRuntimeSelfTests.rect(0, 0, LayerRuntimeSelfTests.width * scale, LayerRuntimeSelfTests.height * scale)
            let prepared = try LayerRuntimeSelfTests.prepare(scene, context, scale, space, glass)
            let frame = try LayerRuntimeSelfTests.submitted(owner.update(prepared, in: window, scale: CGFloat(scale), colorSpace: space,
                partition: .candidateComponents, context: context, cycle: cycle, glass: glass))
            let reference = try LayerRuntimeSelfTests.baseline(scene, context, cycle, scale, space, glass)
            return WorkerCompletion(frame: frame, reference: reference, onWorker: onWorker, live: owner.state == .live)
        }

        func export(variant: Int, scale: Int, space: CGColorSpace) throws -> (patch: ScenePatch, reference: [LayerContentBuilder.Content]) {
            guard onWorker, let owner, let context else { throw CocoaError(.coderInvalidValue) }
            let scene = LayerRuntimeSelfTests.fixture(variant, scale, false), glass = GlassPaint.placeholder(dark: false)
            let window = try LayerRuntimeSelfTests.rect(0, 0, LayerRuntimeSelfTests.width * scale, LayerRuntimeSelfTests.height * scale)
            let prepared = try LayerRuntimeSelfTests.prepare(scene, context, scale, space, glass)
            guard case .ready(let token) = try owner.prepare(prepared, in: window, scale: CGFloat(scale), colorSpace: space,
                partition: .candidateComponents, context: context, cycle: 1, glass: glass) else { throw CocoaError(.coderInvalidValue) }
            let reference = try LayerRuntimeSelfTests.baseline(scene, context, 1, scale, space, glass)
            return (try owner.transfer(token), reference)
        }

        func finish(_ patch: ScenePatch, commitReclaimed: Bool) throws -> UInt64? {
            guard onWorker, let owner else { throw CocoaError(.coderInvalidValue) }
            _ = try owner.finish(patch, commitReclaimed: commitReclaimed)
            return owner.currentFrame?.sequence
        }

        func rootForMainAttachment() throws -> CALayer {
            guard executor.isCurrent && Thread.isMainThread && !executor.isOnThread, let owner else {
                throw CocoaError(.coderInvalidValue)
            }
            return owner.root
        }

        func retire() throws -> WorkerRetirement {
            guard onWorker else { throw CocoaError(.coderInvalidValue) }
            let sequence = owner?.currentFrame?.sequence
            try owner?.beginClose()
            let closing = owner?.state, keptFrame = owner?.currentFrame != nil
            try owner?.close()
            let closed = owner?.state
            let cleared = owner?.currentFrame == nil && (owner?.root.sublayers ?? []).isEmpty
            let attached = owner?.root.superlayer != nil
            autoreleasepool { owner = nil; context = nil }
            return WorkerRetirement(onWorker: onWorker, sequence: sequence, closing: closing, keptFrame: keptFrame,
                closed: closed, cleared: cleared, attached: attached, runtimeReleased: weakOwner == nil, contextReleased: weakContext == nil)
        }
    }

    /// Only the completed value/image snapshot crosses this mailbox. The worker never waits for main.
    private static func workerResult<Value>(_ executor: SkinThreadExecutor, _ t: AppTestRunner,
                                             _ work: @escaping () throws -> Value) throws -> Value? {
        let result = Guarded<Result<Value, Error>?>(nil)
        executor.async {
            let completed = Result(catching: work)
            result.access { $0 = completed }
        }
        let completed = AppSelfTest.spin(timeout: 30) { result.current != nil }
        t.check(completed, "the real worker work item posts its completion before main continues")
        guard let answer = result.current else { return nil }
        return try answer.get()
    }

    private struct FailedWorkerFixture {
        let worker: WorkerFixture
        let tree: CALayer?
    }
    private static var failedWorkerFixtures: [FailedWorkerFixture] = []


    private enum RasterizerKind { case invalidInput, invalidPlan, resourceLimit, incompatibleColorSpace }
    private static func expectRasterizer(_ expected: RasterizerKind, _ t: AppTestRunner, _ body: () throws -> Void) throws {
        do { try body(); t.check(false, "expected a typed Rasterizer failure") }
        catch let error as Rasterizer.Failure {
            let matches: Bool
            switch (expected, error) {
            case (.invalidInput, .invalidInput), (.invalidPlan, .invalidPlan), (.resourceLimit, .resourceLimit),
                 (.incompatibleColorSpace, .incompatibleColorSpace): matches = true
            default: matches = false
            }
            t.check(matches, "wrong failure: \(error)")
        }
    }

    private static func checkRetained(_ owner: LayerRuntime, _ old: LayerRuntime.Frame, _ layers: [CALayer],
                                      _ bounds: CGRect, _ tree: CALayer, _ renderer: OffscreenRenderer,
                                      _ pixels: [UInt8], _ t: AppTestRunner) throws {
        t.equal(owner.currentFrame?.sequence, old.sequence)
        t.equal(owner.root.bounds, bounds)
        t.check((owner.root.sublayers ?? []).count == layers.count && zip(layers, owner.root.sublayers ?? []).allSatisfy { $0.0 === $0.1 })
        t.check(old.contents.count == (owner.currentFrame?.contents ?? []).count &&
                zip(old.contents, owner.currentFrame?.contents ?? []).allSatisfy { $0.0.image === $0.1.image })
        t.equal(try renderer.render(tree, at: 0, deadline: .now() + .seconds(30)).rgba, pixels)
    }

    private static func runtime() throws -> LayerRuntime {
        try LayerRuntime(executor: MainSkinExecutor.shared, maximumOwnedBitmapBytes: budget)
    }

    private static func submitted(_ update: LayerRuntime.Update) throws -> LayerRuntime.Frame {
        guard case let .submitted(frame) = update else { throw CocoaError(.coderInvalidValue) }
        return frame
    }

    private static func unchanged(_ update: LayerRuntime.Update) throws -> LayerRuntime.Frame {
        guard case let .unchanged(frame) = update else { throw CocoaError(.coderInvalidValue) }
        return frame
    }

    /// Actual owned BGRA target used only to query candidates. Query never supplies expected pixels.
    private static func prepare(_ scene: WidgetScene, _ context: DrawContext, _ scale: Int,
                                _ space: CGColorSpace, _ glass: GlassPaint, padding: Int = 0) throws -> SceneInkCandidates {
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let bitmap = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8,
                                     bytesPerRow: width * scale * 4, space: space, bitmapInfo: info) else {
            throw CocoaError(.coderInvalidValue)
        }
        bitmap.translateBy(x: 0, y: CGFloat(bitmap.height))
        bitmap.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        return ScenePreparer.prepare(scene, context: context, target: .prepareOwnedBitmap(bitmap, glass: glass), padding: padding)
    }

    private static func baseline(_ scene: WidgetScene, _ context: DrawContext, _ cycle: Int, _ scale: Int,
                                 _ space: CGColorSpace, _ glass: GlassPaint) throws -> [LayerContentBuilder.Content] {
        let window = try rect(0, 0, width * scale, height * scale)
        let builder = try LayerContentBuilder(plan: SinglePartition.plan(in: window), scale: CGFloat(scale),
                                              colorSpace: space, maximumOwnedBitmapBytes: budget)
        return try builder.build(scene, context: context, cycle: cycle, glass: glass)
    }

    private static func host(_ root: CALayer, _ scale: Int) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let top = CALayer()
        top.anchorPoint = .zero
        top.bounds = CGRect(x: 0, y: 0, width: width * scale, height: height * scale)
        top.isGeometryFlipped = true
        top.contentsFormat = .RGBA8Uint
        root.setAffineTransform(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        top.addSublayer(root)
        return top
    }

    private static func cTree(_ contents: [LayerContentBuilder.Content], _ scale: Int) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let root = CALayer()
        root.anchorPoint = .zero
        root.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        root.contentsFormat = .RGBA8Uint
        for content in contents {
            let layer = CALayer(), rectangle = content.plan.rect
            layer.anchorPoint = .zero
            layer.frame = CGRect(x: CGFloat(rectangle.minX) / CGFloat(scale), y: CGFloat(rectangle.minY) / CGFloat(scale),
                                 width: CGFloat(rectangle.width) / CGFloat(scale), height: CGFloat(rectangle.height) / CGFloat(scale))
            layer.contents = content.image
            layer.contentsRect = content.contentsRect
            layer.contentsScale = CGFloat(scale)
            layer.contentsFormat = .RGBA8Uint
            layer.contentsGravity = .resize
            layer.magnificationFilter = .nearest
            layer.minificationFilter = .nearest
            root.addSublayer(layer)
        }
        return host(root, scale)
    }

    private static func fixture(_ variant: Int, _ scale: Int, _ dark: Bool, gradient: Bool = true) -> WidgetScene {
        let regions = [GlassRegion(id: "RuntimeGlass", rect: SkinRect(x: 1, y: 1, width: 18, height: 16))]
        let paint = Paint(color: RGBA(r: 31, g: 89, b: 151, a: 83),
                          secondColor: gradient ? RGBA(r: 203, g: 127, b: 47, a: 131) : nil, angle: 23)
        let base = DrawItem.fill(SkinRect(x: 0, y: 0, width: Double(width), height: Double(height)), paint)
        let color = variant == 0 ? RGBA(r: 229, g: 37, b: 19, a: 187) : RGBA(r: 17, g: 89, b: 233, a: 153)
        let mask = DrawItem.transformed(ShapeTransform(a: 1, b: 0, c: 0, d: 1, tx: 1, ty: 1),
                                        [fill(18, 3, 6, 8, RGBA(r: 255, g: 255, b: 255, a: 151))])
        return WidgetScene(generation: 7, size: SkinSize(width: Double(width), height: Double(height)),
            background: regions.map(DrawItem.glass) + [fill(0, 17, 4, 3, RGBA(r: 251, g: 17, b: 79, a: 233)),
                                                       fill(24, 0, 4, 2, RGBA(r: 11, g: 181, b: 229, a: 255))],
            backgroundImageDependencies: [], glass: regions,
            elements: [element(baseID, [base]), element(backID, [fill(2, 3, 8, 6, color)]),
                       element(frontID, [fill(6, 7, 7, 5, RGBA(r: 19, g: 107, b: 221, a: 171))]),
                       element(maskID, [mask], frame: SkinRect(x: 17, y: 2, width: 9, height: 12), isContainer: true),
                       element(childID, [fill(16, 1, 12, 16, RGBA(r: 71, g: 211, b: 113, a: 217))], container: maskID)],
            hitMap: SkinHitMap(), environment: EnvironmentStamp(scale: Double(scale), fontGeneration: 3,
                appearance: AppearanceStamp(value: dark ? .dark : .light, name: "layer-runtime"), imageGeneration: 5))
    }

    private static func element(_ id: ElementID, _ items: [DrawItem], frame: SkinRect = SkinRect(x: 0, y: 0, width: 28, height: 20),
                                container: ElementID? = nil, isContainer: Bool = false) -> SceneElement {
        SceneElement(id: id, kind: .shape, frame: frame, anchor: SkinPoint(), visibility: .visible,
                     container: container, isContainer: isContainer, items: items, glass: nil, imageDependencies: [])
    }

    private static func fill(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ color: RGBA) -> DrawItem {
        .fill(SkinRect(x: x, y: y, width: width, height: height), Paint(color: color))
    }

    private static func text() -> DrawItem {
        var style = TextStyle()
        style.fontFace = "Helvetica"
        style.fontSize = 11
        style.antiAlias = true
        style.color = RGBA(r: 241, g: 211, b: 37, a: 233)
        let frame = SkinRect(x: 2, y: 3, width: 24, height: 15)
        return .text(TextDraw(text: "WWW", style: style, frame: frame, contentFrame: frame, anchor: SkinPoint(x: 2, y: 3)))
    }

    private static func checkFixture(_ pixels: [UInt8], _ window: Rect, _ t: AppTestRunner) {
        t.equal(pixels.count, window.width * window.height * 4)
        t.check(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 && pixels[$0] < 255 })
        t.check(Array(pixels.prefix(window.width * 4)) != Array(pixels.suffix(window.width * 4)))
        t.check(stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0] != pixels[$0 + 2] })
    }

    private static func rect(_ x: Int, _ y: Int, _ right: Int, _ bottom: Int) throws -> Rect {
        guard let value = Rect(minX: x, minY: y, maxX: right, maxY: bottom) else { throw CocoaError(.coderInvalidValue) }
        return value
    }

    private static func rgb(_ name: CFString) throws -> CGColorSpace {
        guard let value = CGColorSpace(name: name) else { throw CocoaError(.coderInvalidValue) }
        return value
    }

    /// Only named local system fonts. No files, registration, user fonts or external font enumeration.
    private final class CountingFonts: FontResolving {
        private let lock = NSLock()
        private var version = 0
        private var count = 0
        private var courier = false
        var generation: Int { lock.lock(); defer { lock.unlock() }; return version }
        var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
        func registerFolder(_ folder: String) {}
        func resolve(_ request: FontRequest) -> ResolvedFont {
            lock.lock()
            count += 1
            let name = courier ? "Courier" : "Helvetica"
            lock.unlock()
            return ResolvedFont(font: CTFontCreateWithName(name as CFString, request.size, nil),
                                syntheticBold: false, characterMap: nil, slant: 0, lineMetrics: nil)
        }
        func changeToCourier() { lock.lock(); defer { lock.unlock() }; courier = true; version += 1 }
    }
}
