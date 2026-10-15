import CoreFoundation
import CoreGraphics
import DesksetCore
import DesksetDraw
import DesksetRuntime
import Foundation
import Metal
import QuartzCore

enum ELayerContentSelfTests {
    private typealias Rect = InkBounds.DeviceRect
    private static let width = 28, height = 20
    private static let budget = 1_000_000
    private static let baseID = ElementID(name: "EBase", index: 0)
    private static let backID = ElementID(name: "EBack", index: 4)
    private static let frontID = ElementID(name: "EFront", index: 8)
    private static let maskID = ElementID(name: "EMask", index: 12)
    private static let childID = ElementID(name: "EChild", index: 16)

    static func run(_ t: AppTestRunner) {
        nativeTests(t)
        callbackBoundaryTests(t)
        validationTests(t)
    }

    private static func nativeTests(_ t: AppTestRunner) {
        t.suite("Runtime: E layer content: real CA callbacks Single groups and C agree through A/B/A") {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: actual E callback comparison did not run")
            }
            let space = try rgb(CGColorSpace.sRGB)
            for scale in [1, 2] {
                var light: [UInt8]?
                for dark in [false, true] {
                    let window = try rect(0, 0, width * scale, height * scale)
                    let singlePlan = SinglePartition.plan(in: window)
                    let componentPlan = try components(scale)
                    let renderer = try OffscreenRenderer(width: window.width, height: window.height, device: device,
                                                         maximumReadbackBytes: window.width * window.height * 4)
                    let single = try owner(singlePlan, scale, space)
                    let grouped = try owner(componentPlan, scale, space)
                    let singleTree = host(single.root, scale)
                    let groupTree = host(grouped.root, scale)
                    let c = try LayerContentBuilder(plan: singlePlan, scale: CGFloat(scale), colorSpace: space,
                                                    maximumOwnedBitmapBytes: budget)
                    let singleContext = DrawContext(fonts: AppFontResolver())
                    let groupContext = DrawContext(fonts: AppFontResolver())
                    let cContext = DrawContext(fonts: AppFontResolver())
                    var saved: [OffscreenRenderer.Readback] = []
                    for (cycle, variant) in [0, 1, 0].enumerated() {
                        let scene = fixture(variant, scale, dark)
                        let glass = GlassPaint.placeholder(dark: dark)
                        // host() committed the first attach transaction. Native drawing starts in this next one.
                        try display(single, scene, singleContext, cycle, glass)
                        try display(grouped, scene, groupContext, cycle, glass)
                        let baseline = try c.build(scene, context: cContext, cycle: cycle, glass: glass)
                        let cPixels = try renderer.render(cTree(baseline, scale), at: 0, deadline: .now() + .seconds(30))
                        let eSingle = try renderer.render(singleTree, at: 0, deadline: .now() + .seconds(30))
                        let eGroups = try renderer.render(groupTree, at: 0, deadline: .now() + .seconds(30))
                        let note = "\(scale)x dark=\(dark) frame=\(cycle)"
                        checkFixture(cPixels.rgba, window, t, note)
                        t.equal(eSingle.rgba, cPixels.rgba, "\(note): actual E Single / C strict active-byte baseline")
                        t.equal(eGroups.rgba, eSingle.rgba, "\(note): actual E atomic groups / E Single strict active bytes")
                        checkCallbacks(single, singlePlan, scale, space, glass, cycle + 1, t)
                        checkCallbacks(grouped, componentPlan, scale, space, glass, cycle + 1, t)
                        let slices = componentPlan.layers.enumerated().compactMap { index, plan -> CALayer? in
                            if case .baseSlice = plan.content { return grouped.root.sublayers?[index] }
                            return nil
                        }
                        guard let first = imageContents(of: slices.first) else {
                            return t.check(false, "\(note): base-slice sharing control has no actual image")
                        }
                        t.check(slices.count > 1 && slices.allSatisfy { imageContents(of: $0) === first },
                                "\(note): every base slice retains the same full-window CGImage")
                        t.check(first.width == window.width && first.height == window.height &&
                                first.colorSpace.map { CFEqual($0, space) } == true,
                                "\(note): base dimensions/profile come from the same fixed destination")
                        saved.append(eGroups)
                    }
                    t.check(saved[0].rgba != saved[1].rgba, "B changes colored ink without a scene generation change")
                    t.equal(saved[2].rgba, saved[0].rgba, "A/B/A reuses the actual E layer backing without stale B")
                    if dark { t.check(light != saved[0].rgba, "the literal translucent fixture exposes dark/light glass appearance") }
                    else { light = saved[0].rgba }
                    t.check(renderer.hasVerifiedCanary, "all E readbacks follow the unchanged poisoned-image native canary")
                    // A valid tiling can deliberately omit colored members. Native pixels, not plan validation,
                    // must reject this control. No expected output is derived from the candidate recipes.
                    let omitted = try owner(components(scale, omit: true), scale, space)
                    let omittedTree = host(omitted.root, scale)
                    try display(omitted, fixture(0, scale, dark), groupContext, 3, .placeholder(dark: dark))
                    let negative = try renderer.render(omittedTree, at: 0, deadline: .now() + .seconds(30))
                    t.check(negative.rgba.contains { $0 != 0 }, "omission control remains visibly painted")
                    t.check(negative.rgba != saved[0].rgba, "the native oracle detects the skipped colored group")
                    t.equal(single.callbackReport.observation.failure, nil, "GPU/transaction processing did not cause an unarmed Single callback")
                    t.equal(grouped.callbackReport.observation.failure, nil, "GPU/transaction processing did not cause an unexpected group callback")
                    withExtendedLifetime([singleTree, groupTree, omittedTree]) {}
                }
            }
        }
    }

    private static func callbackBoundaryTests(_ t: AppTestRunner) {
        t.suite("Runtime: E layer content: actual native callback owner lifetime format and profile failures are explicit") {
            let space = try rgb(CGColorSpace.sRGB)
            let plan = SinglePartition.plan(in: try rect(0, 0, width, height))
            let scene = fixture(0, 1, false)
            let context = DrawContext(fonts: AppFontResolver())
            func leaf(_ owner: ELayerContent) throws -> CALayer {
                guard let layer = owner.root.sublayers?.first else { throw CocoaError(.coderInvalidValue) }
                return layer
            }
            let unarmed = try owner(plan, 1, space)
            let unarmedTree = host(unarmed.root, 1)
            let unarmedLeaf = try leaf(unarmed)
            unarmedLeaf.setNeedsDisplay()
            unarmedLeaf.displayIfNeeded()
            t.equal(unarmed.callbackReport.observation.callbacks, [1], "unarmed control reaches the real CA callback")
            if case .unexpectedCallback? = unarmed.callbackReport.observation.failure { t.check(true) }
            else { t.check(false, "an unarmed callback cannot silently repaint or report an empty success") }

            let denied = try owner(plan, 1, space)
            let deniedTree = host(denied.root, 1)
            let deniedLeaf = try leaf(denied)
            // Reuse the existing bounded Thread helper. This is an intentionally invalid, isolated mutation;
            // the main owner is waiting and no frame lease exists. It does not simulate profile-change timing.
            let anotherThread = SkinRuntimeSelfTests.onAnotherThread {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                deniedLeaf.setNeedsDisplay()
                deniedLeaf.displayIfNeeded()
                CATransaction.commit()
                return !Thread.isMainThread
            }
            t.equal(anotherThread, true, "off-owner control actually executes on another thread")
            t.equal(denied.callbackReport.observation.callbacks, [1], "off-owner control reaches the real callback")
            t.equal(denied.callbackReport.observation.failure, .wrongOwner, "off-owner callback cannot access frame caches")
            t.check(denied.callbackReport.observation.destinations.allSatisfy { $0 == nil },
                    "off-owner rejection precedes destination/frame access")

            let changed = try owner(plan, 1, space)
            let changedTree = host(changed.root, 1)
            try leaf(changed).contentsFormat = .RGBA16Float
            do {
                try display(changed, scene, context, 0, .none)
                t.check(false, "RGBA16Float native negative control unexpectedly qualified as BGRA8")
            } catch ELayerContent.Failure.incompatibleBitmap {
                let observation = changed.callbackReport.observation
                t.equal(observation.callbacks, [1], "wrong-format rejection came from an actual callback")
                t.check(observation.destinations[0]?.bitsPerComponent != 8,
                        "the native format hint actually produced a non-8-bit backing; otherwise this control is inconclusive")
            }

            let p3 = try rgb(CGColorSpace.displayP3)
            let mismatch = try owner(plan, 1, p3)
            let mismatchTree = host(mismatch.root, 1)
            do {
                try display(mismatch, scene, context, 0, .none)
                t.check(false, "an unattached native sRGB host did not qualify the intended P3 mismatch control")
            } catch ELayerContent.Failure.incompatibleColorSpace {
                let observation = mismatch.callbackReport.observation
                t.equal(observation.callbacks, [1], "profile rejection came from an actual callback")
                t.check(observation.destinations[0]?.entry.colorSpace.map { !CFEqual($0, p3) } == true,
                        "actual callback profile differs from the explicitly requested profile")
            }

            var released: ELayerContent? = try owner(plan, 1, space)
            weak var weakOwner = released
            let releasedTree = host(released!.root, 1)
            let retainedLeaf = try leaf(released!)
            let report = released!.callbackReport
            weak var weakContext: DrawContext?
            try autoreleasepool {
                let transient = DrawContext(fonts: AppFontResolver())
                weakContext = transient
                try display(released!, scene, transient, 0, .none)
            }
            t.check(weakContext == nil, "a completed native display does not retain the DrawContext lease")
            released = nil
            t.check(weakOwner == nil, "retained layer tree and mailbox do not retain the E owner")
            retainedLeaf.setNeedsDisplay()
            retainedLeaf.displayIfNeeded()
            t.equal(report.observation.callbacks, [2], "owner-released control reaches a later actual callback")
            t.equal(report.observation.failure, .ownerReleased, "owner-released callback has no unowned cache access")
            withExtendedLifetime([unarmedTree, deniedTree, changedTree, mismatchTree, releasedTree]) {}
        }
    }

    private static func validationTests(_ t: AppTestRunner) {
        t.suite("Runtime: E layer content: shared C plan and scene validation remain explicit before drawing") {
            let space = try rgb(CGColorSpace.sRGB)
            let window = try rect(0, 0, width, height)
            let badPlan = PartitionPlan(window: window, baseMembers: [], layers: [], skipped: [])
            do { _ = try owner(badPlan, 1, space); t.check(false, "a nonempty untiled E plan cannot be accepted") }
            catch Rasterizer.Failure.invalidPlan { t.check(true) }
            let single = try owner(SinglePartition.plan(in: window), 1, space)
            let tree = host(single.root, 1)
            var duplicate = fixture(0, 1, false)
            duplicate.elements.append(duplicate.elements[0])
            do {
                try display(single, duplicate, DrawContext(fonts: AppFontResolver()), 0, .none)
                t.check(false, "duplicate scene IDs cannot disappear in E recipes")
            } catch Rasterizer.Failure.invalidPlan { t.check(true) }
            t.equal(single.callbackReport.observation.callbacks, [0], "shared scene rejection precedes all native displays")
            withExtendedLifetime(tree) {}
        }
    }

    private static func imageContents(of layer: CALayer?) -> CGImage? {
        guard let contents = layer?.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        return (contents as! CGImage)
    }

    private static func checkCallbacks(_ owner: ELayerContent, _ plan: PartitionPlan, _ scale: Int,
                                       _ space: CGColorSpace, _ glass: GlassPaint, _ frameCount: Int, _ t: AppTestRunner) {
        let observation = owner.callbackReport.observation
        t.equal(observation.failure, nil)
        for (index, layer) in plan.layers.enumerated() {
            switch layer.content {
            case .baseSlice:
                t.equal(observation.callbacks[index], 0, "base slices never redraw the full base through E")
            case .fullScene, .group:
                t.equal(observation.callbacks[index], frameCount, "each frame includes exactly one real callback for this drawing layer")
                guard let value = observation.destinations[index], let target = value.target else {
                    t.check(false, "the native E callback lacks qualified destination metadata")
                    continue
                }
                t.check(value.hasBitmapData && value.bitsPerComponent == 8 && value.bitsPerPixel == 32,
                        "the actual E callback is an in-process 8-bit bitmap")
                t.check(value.width == layer.rect.width && value.height == layer.rect.height)
                t.check(target.colorSpace.map { CFEqual($0, space) } == true, "actual callback profile equals the base profile")
                t.equal(target.glassPaint, glass, "the real destination carries this frame's explicit glass recipe")
                t.equal(target.userToDevice, CGAffineTransform(a: CGFloat(scale), b: 0, c: 0, d: CGFloat(scale),
                                                              tx: -CGFloat(layer.rect.minX), ty: -CGFloat(layer.rect.minY)))
                t.check(target.state?.rasterization == nil && target.state?.blendMode == nil,
                        "borrowed callback flags and blend mode are not inferred as owned defaults")
            }
        }
    }

    private static func owner(_ plan: PartitionPlan, _ scale: Int, _ space: CGColorSpace) throws -> ELayerContent {
        try ELayerContent(plan: plan, scale: CGFloat(scale), colorSpace: space, maximumBaseBitmapBytes: budget,
                          maximumCallbackBitmapBytes: budget, executor: MainSkinExecutor.shared)
    }

    private static func display(_ owner: ELayerContent, _ scene: WidgetScene, _ context: DrawContext,
                                _ cycle: Int, _ glass: GlassPaint) throws {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        try owner.display(scene, context: context, cycle: cycle, glass: glass)
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
            let layer = CALayer(), rect = content.plan.rect
            layer.anchorPoint = .zero
            layer.frame = CGRect(x: CGFloat(rect.minX) / CGFloat(scale), y: CGFloat(rect.minY) / CGFloat(scale),
                                 width: CGFloat(rect.width) / CGFloat(scale), height: CGFloat(rect.height) / CGFloat(scale))
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

    private static func fixture(_ variant: Int, _ scale: Int, _ dark: Bool) -> WidgetScene {
        let color = variant == 0 ? RGBA(r: 229, g: 37, b: 19, a: 187) : RGBA(r: 17, g: 89, b: 233, a: 153)
        let regions = [GlassRegion(id: "EGlass", rect: SkinRect(x: 1, y: 1, width: 18, height: 16))]
        let base = DrawItem.fill(SkinRect(x: 0, y: 0, width: Double(width), height: Double(height)),
                                 Paint(color: RGBA(r: 31, g: 89, b: 151, a: 83),
                                       secondColor: RGBA(r: 203, g: 127, b: 47, a: 131), angle: 23))
        let mask = DrawItem.transformed(ShapeTransform(a: 1, b: 0, c: 0, d: 1, tx: 1, ty: 1),
                                        [fill(18, 3, 6, 8, RGBA(r: 255, g: 255, b: 255, a: 151))])
        let elements = [element(baseID, [base]), element(backID, [fill(2, 3, 8, 6, color)]),
                        element(frontID, [fill(6, 7, 7, 5, RGBA(r: 19, g: 107, b: 221, a: 171))]),
                        element(maskID, [mask], frame: SkinRect(x: 17, y: 2, width: 9, height: 12), isContainer: true),
                        element(childID, [fill(16, 1, 12, 16, RGBA(r: 71, g: 211, b: 113, a: 217))], container: maskID)]
        return WidgetScene(generation: 7, size: SkinSize(width: Double(width), height: Double(height)),
                           background: regions.map(DrawItem.glass) + [fill(0, 17, 4, 3, RGBA(r: 251, g: 17, b: 79, a: 233)),
                                                                    fill(24, 0, 4, 2, RGBA(r: 11, g: 181, b: 229, a: 255))],
                           backgroundImageDependencies: [], glass: regions, elements: elements, hitMap: SkinHitMap(),
                           environment: EnvironmentStamp(scale: Double(scale), fontGeneration: 3,
                               appearance: AppearanceStamp(value: dark ? .dark : .light, name: "E-layer-content"), imageGeneration: 5))
    }

    private static func components(_ scale: Int, omit: Bool = false) throws -> PartitionPlan {
        let window = try rect(0, 0, width * scale, height * scale)
        let groups = (omit ? [] : [LayerPlan(id: .group(fileIndex: backID.index),
                                            rect: try rect(2 * scale, 3 * scale, 13 * scale, 12 * scale),
                                            content: .group(members: [backID, frontID]))])
            + [LayerPlan(id: .group(fileIndex: maskID.index), rect: try rect(17 * scale, 2 * scale, 26 * scale, 14 * scale),
                         content: .group(members: [maskID]))]
        let slices = RectangleComplement.slices(in: window, excluding: groups.map(\.rect)).enumerated().map {
            LayerPlan(id: .baseSlice(index: $0.offset), rect: $0.element, content: .baseSlice(source: $0.element))
        }
        return PartitionPlan(window: window, baseMembers: [baseID], layers: slices + groups,
                             skipped: omit ? [backID, frontID] : [])
    }

    private static func element(_ id: ElementID, _ items: [DrawItem], frame: SkinRect = SkinRect(x: 0, y: 0, width: 28, height: 20),
                                container: ElementID? = nil, isContainer: Bool = false) -> SceneElement {
        SceneElement(id: id, kind: .shape, frame: frame, anchor: SkinPoint(), visibility: .visible,
                     container: container, isContainer: isContainer, items: items, glass: nil, imageDependencies: [])
    }

    private static func fill(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: RGBA) -> DrawItem {
        .fill(SkinRect(x: x, y: y, width: w, height: h), Paint(color: color))
    }

    private static func checkFixture(_ pixels: [UInt8], _ window: Rect, _ t: AppTestRunner, _ note: String) {
        t.equal(pixels.count, window.width * window.height * 4)
        t.check(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 && pixels[$0] < 255 },
                "\(note): visible translucent alpha makes equality meaningful")
        t.check(Array(pixels.prefix(window.width * 4)) != Array(pixels.suffix(window.width * 4)), "\(note): row-flip positive control")
        t.check(stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0] != pixels[$0 + 2] }, "\(note): channel-swap positive control")
    }

    private static func rect(_ x: Int, _ y: Int, _ right: Int, _ bottom: Int) throws -> Rect {
        guard let result = Rect(minX: x, minY: y, maxX: right, maxY: bottom) else { throw CocoaError(.coderInvalidValue) }
        return result
    }

    private static func rgb(_ name: CFString) throws -> CGColorSpace {
        guard let space = CGColorSpace(name: name) else { throw CocoaError(.coderInvalidValue) }
        return space
    }
}
