import CoreFoundation
import CoreGraphics
import DesksetCore
import DesksetDraw
import DesksetRuntime
import Dispatch
import Foundation
import Metal
import QuartzCore

enum LayerContentSelfTests {
    private typealias Rect = InkBounds.DeviceRect
    private typealias Content = LayerContentBuilder.Content
    private enum FailureKind { case invalidInput, invalidPlan, resourceLimit, incompatibleColorSpace }
    private static let width = 40, height = 28
    private static let budget = 1_000_000
    private static let baseID = ElementID(name: "Base", index: 0)
    private static let backID = ElementID(name: "Back", index: 1)
    private static let frontID = ElementID(name: "Front", index: 2)
    private static let maskID = ElementID(name: "Mask", index: 3)
    private static let childID = ElementID(name: "Child", index: 4)
    private static let hiddenID = ElementID(name: "Hidden", index: 6)
    private static let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    static func run(_ t: AppTestRunner) {
        compositionTests(t)
        partitionTests(t)
        structureTests(t)
        membershipTests(t)
        rasterizerTests(t)
    }

    private struct Frame {
        let single: [Content]
        let groups: [Content]
        let singleTree: CALayer
        let groupTree: CALayer
        let oracleImage: CGImage
        let expected: [UInt8]
        let readback: OffscreenRenderer.Readback
    }

    private static func compositionTests(_ t: AppTestRunner) {
        t.suite("Runtime: layer content: original bitmap Single and tiled native composition agree through A/B/A reuse") {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: the native content comparison did not run")
            }
            let space = try rgb()
            var lightPixels: [Int: [UInt8]] = [:]
            for scale in [1, 2] {
                for dark in [false, true] {
                    let note = "\(scale)x \(dark ? "dark" : "light")"
                    let viewport = try rect(0, 0, width * scale, height * scale)
                    let plan = try components(scale: scale)
                    let renderer = try OffscreenRenderer(width: viewport.width, height: viewport.height, device: device,
                                                         maximumReadbackBytes: viewport.width * viewport.height * 4)
                    weak var releasedBuilder: LayerContentBuilder?
                    weak var releasedContext: DrawContext?
                    let frames = try autoreleasepool { () throws -> [Frame] in
                        let single = try builder(SinglePartition.plan(in: viewport), scale: scale, space: space)
                        let grouped = try builder(plan, scale: scale, space: space)
                        let singleContext = DrawContext(fonts: AppFontResolver())
                        let groupContext = DrawContext(fonts: AppFontResolver())
                        let oracle = try RawOracle(scale: scale, space: space)
                        releasedBuilder = grouped
                        releasedContext = groupContext
                        var frames: [Frame] = []
                        for (cycle, variant) in [0, 1, 0].enumerated() {
                            let scene = fixture(variant: variant, scale: scale, dark: dark)
                            let glass = GlassPaint.placeholder(dark: dark)
                            let original = try oracle.draw(scene, cycle: cycle, glass: glass, t)
                            let expected = try pixels(original)
                            checkFixture(expected, scale: scale, t, note)
                            let reference = try single.build(scene, context: singleContext, cycle: cycle, glass: glass)
                            let content = try grouped.build(scene, context: groupContext, cycle: cycle, glass: glass)
                            guard let whole = reference.first else { throw CocoaError(.coderInvalidValue) }
                            t.check(try pixels(whole.image) == expected, "\(note) frame \(cycle): Single matches the raw CGContext oracle")
                            checkSlices(content, plan: plan, space: space, t, note)
                            let singleTree = tree(reference, scale: scale)
                            let groupTree = tree(content, scale: scale)
                            let singleReadback = try renderer.render(singleTree, at: 0, deadline: .now() + .seconds(30))
                            let actual = try renderer.render(groupTree, at: 0, deadline: .now() + .seconds(30))
                            check(singleReadback, expected, t, "\(note) frame \(cycle): native Single / original")
                            check(actual, singleReadback.rgba, t, "\(note) frame \(cycle): native tiled / Single")
                            frames.append(Frame(single: reference, groups: content, singleTree: singleTree,
                                                groupTree: groupTree, oracleImage: original, expected: expected,
                                                readback: actual))
                        }
                        t.check(frames[0].expected != frames[1].expected, "\(note): B changes visible colors despite unchanged scene generation")
                        t.equal(frames[2].expected, frames[0].expected, "\(note): A returns after B with the same raw bitmap history")
                        t.check(renderer.hasVerifiedCanary, "\(note): comparisons ran after the automatic poisoned-image canary")

                        // This deliberately wrong plan still tiles every pixel. Structural validation cannot certify
                        // that skipped content has no ink; the independent Single must catch the missing colored group.
                        let omitted = try builder(components(scale: scale, omitColoredGroup: true), scale: scale, space: space)
                        let wrong = try omitted.build(fixture(variant: 0, scale: scale, dark: dark), context: groupContext,
                                                      cycle: 3, glass: .placeholder(dark: dark))
                        let negative = try renderer.render(tree(wrong, scale: scale), at: 0, deadline: .now() + .seconds(30))
                        t.check(negative.rgba.contains { $0 != 0 }, "\(note): the omission control remains visibly painted")
                        t.check(negative.rgba != frames[0].expected, "\(note): skipped colored units are detected, not accepted as coverage")
                        return frames
                    }
                    t.check(releasedBuilder == nil && releasedContext == nil,
                            "\(note): retained CGImages and trees do not retain the builder or drawing caches")
                    for index in [0, 1] {
                        let frame = frames[index]
                        let replay = try renderer.render(frame.groupTree, at: 0, deadline: .now() + .seconds(30))
                        check(replay, frame.expected, t, "\(note): retained frame \(index) after slot reuse and owner release")
                        t.equal(frame.readback.rgba, frame.expected, "\(note): later frames do not mutate old Readback storage")
                        t.check(try pixels(frame.oracleImage) == frame.expected, "\(note): raw oracle snapshots also remain immutable")
                    }
                    let oldSingle = try renderer.render(frames[0].singleTree, at: 0, deadline: .now() + .seconds(30))
                    check(oldSingle, frames[0].expected, t, "\(note): retained Single after its first slot is reused")
                    if dark {
                        guard let light = lightPixels[scale] else { throw CocoaError(.coderInvalidValue) }
                        t.check(light != frames[0].expected,
                                "\(note): translucent base leaves glass appearance visible to the oracle")
                    } else {
                        lightPixels[scale] = frames[0].expected
                    }
                    withExtendedLifetime(frames) {}
                }
            }
        }
    }

    private static func partitionTests(_ t: AppTestRunner) {
        t.suite("Runtime: component partition: prepared recipes generate native Single-equivalent plans and preserve a frozen base") {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: the automatic-plan comparison did not run")
            }
            let space = try rgb()
            for scale in [1, 2] {
                for dark in [false, true] {
                    let note = "\(scale)x \(dark ? "dark" : "light") automatic plan"
                    let window = try rect(0, 0, width * scale, height * scale)
                    guard let queryBitmap = CGContext(data: nil, width: window.width, height: window.height,
                                                       bitsPerComponent: 8, bytesPerRow: window.width * 4,
                                                       space: space, bitmapInfo: info) else {
                        return t.check(false, "the independent preparation target is unavailable")
                    }
                    queryBitmap.translateBy(x: 0, y: CGFloat(window.height))
                    queryBitmap.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
                    let glass = GlassPaint.placeholder(dark: dark)
                    let target = DrawTarget.prepareOwnedBitmap(queryBitmap, glass: glass)
                    let queryContext = DrawContext(fonts: AppFontResolver())
                    func prepare(_ scene: WidgetScene) -> SceneInkCandidates {
                        ScenePreparer.prepare(scene, context: queryContext, target: target)
                    }
                    let scene = fixture(variant: 0, scale: scale, dark: dark)
                    let prepared = prepare(scene)
                    let plan = try ComponentPartition.candidatePlan(prepared, in: window)
                    t.equal(plan, try components(scale: scale), "\(note): the independent literal plan includes only complete visible recipes")
                    let renderer = try OffscreenRenderer(width: window.width, height: window.height, device: device,
                                                         maximumReadbackBytes: window.width * window.height * 4)
                    let reference = try builder(SinglePartition.plan(in: window), scale: scale, space: space)
                    let context = DrawContext(fonts: AppFontResolver())
                    let oracle = try RawOracle(scale: scale, space: space)
                    func compare(_ value: WidgetScene, _ valuePlan: PartitionPlan, cycle: Int) throws -> [UInt8] {
                        let original = try pixels(oracle.draw(value, cycle: cycle, glass: glass, t))
                        let single = try reference.build(value, context: context, cycle: cycle, glass: glass)
                        let grouped = try builder(valuePlan, scale: scale, space: space)
                            .build(value, context: context, cycle: cycle, glass: glass)
                        let expected = try renderer.render(tree(single, scale: scale), at: 0, deadline: .now() + .seconds(30))
                        let actual = try renderer.render(tree(grouped, scale: scale), at: 0, deadline: .now() + .seconds(30))
                        check(expected, original, t, "\(note): Single / raw oracle")
                        check(actual, expected.rgba, t, "\(note): generated components / Single")
                        t.check(actual.rgba.contains { $0 != 0 }, "\(note): native output is not an empty pass")
                        return expected.rgba
                    }
                    let expected = try compare(scene, plan, cycle: 0)
                    var smaller = fixture(variant: 1, scale: scale, dark: dark)
                    smaller.elements[0].items = [fill(0, 0, 1, Double(height), RGBA(r: 37, g: 137, b: 241, a: 123))]
                    let frozen = try ComponentPartition.candidatePlan(prepare(smaller), in: window, baseMembers: plan.baseMembers)
                    t.equal(frozen.baseMembers, [baseID], "the base is not reclassified when its current area shrinks")
                    t.equal(try ComponentPartition.candidatePlan(prepare(smaller), in: window).baseMembers, [],
                            "a new classification sees the smaller area; it is not silently used for the frozen plan")
                    t.check(try compare(smaller, frozen, cycle: 1) != expected, "the new frame changes real pixels")

                    var corrupted = prepared.runInk
                    corrupted[2] = .rectangle(try rect(10 * scale, 10 * scale, 12 * scale, 11 * scale))
                    let wrong = SceneInkCandidates(scene: scene, elementInk: prepared.elementInk, runInk: corrupted)
                    let wrongPlan = try ComponentPartition.candidatePlan(wrong, in: window)
                    let content = try builder(wrongPlan, scale: scale, space: space)
                        .build(scene, context: context, cycle: 2, glass: glass)
                    let negative = try renderer.render(tree(content, scale: scale), at: 0, deadline: .now() + .seconds(30))
                    t.check(negative.rgba.contains { $0 != 0 } && negative.rgba != expected,
                            "a complete tiling with false ink metadata is detected by the independent reference")
                    t.check(renderer.hasVerifiedCanary, "the native comparisons ran after the poisoned-image canary")

                    func rejects(_ input: SceneInkCandidates, base: [ElementID]? = nil,
                                 expected: ComponentPartition.Failure) {
                        do {
                            _ = try ComponentPartition.candidatePlan(input, in: window, baseMembers: base)
                            t.check(false, "invalid partition metadata unexpectedly succeeded")
                        } catch let failure as ComponentPartition.Failure { t.equal(failure, expected) }
                        catch { t.check(false, "unexpected partition failure: \(error)") }
                    }
                    var unknown = prepared.runInk
                    unknown[2] = .unknown(.unresolvedRasterization)
                    rejects(SceneInkCandidates(scene: scene, elementInk: prepared.elementInk, runInk: unknown),
                            expected: .unresolvedInk(backID, .unresolvedRasterization))
                    rejects(prepared, base: [frontID],
                            expected: .invalidPlan("Frozen base members must be the drawn scene's leading content prefix"))
                    rejects(SceneInkCandidates(scene: scene, elementInk: [], runInk: prepared.runInk),
                            expected: .invalidPlan("Preparation must retain the complete element and drawing-run order"))
                    var duplicate = scene
                    duplicate.elements[1].id = baseID
                    rejects(SceneInkCandidates(scene: duplicate, elementInk: prepared.elementInk, runInk: prepared.runInk),
                            expected: .invalidPlan("Scene identities and file occurrences must be unique"))

                    // A frozen selection is a historical identity list, not a promise to keep hidden ink drawing.
                    var pair = scene
                    pair.elements[1].items = [fill(0, 0, Double(width), Double(height), RGBA(r: 191, g: 71, b: 43, a: 113))]
                    let selected = [baseID, backID]
                    t.equal(try ComponentPartition.candidatePlan(prepare(pair), in: window).baseMembers, selected)
                    for visibility in [Visibility.collapsed, .hiddenKeepsSpace] {
                        var hidden = pair
                        hidden.elements[1].visibility = visibility
                        let active = try ComponentPartition.candidatePlan(prepare(hidden), in: window, baseMembers: selected)
                        t.equal(active.baseMembers, [baseID], "a hidden selected member leaves only the active plan")
                        t.equal(active.skipped, [], "hidden units are not visible empty units")
                        t.equal(active.layers.compactMap { layer -> [ElementID]? in
                            if case let .group(ids) = layer.content { return ids }; return nil
                        }, [[frontID], [maskID]], "remaining foreground keeps complete file-order recipes")
                    }
                    for items in [[DrawItem](), [fill(Double(width + 1), 0, 2, 2, RGBA(r: 17, g: 83, b: 199, a: 255))]] {
                        var absent = pair
                        absent.elements[1].items = items
                        let active = try ComponentPartition.candidatePlan(prepare(absent), in: window, baseMembers: selected)
                        t.equal(active.baseMembers, [baseID])
                        t.equal(active.skipped, [backID], "visible empty or off-window selected ink keeps its original occurrence")
                    }
                    var smallerPair = pair
                    smallerPair.elements[1].items = [fill(1, 1, 2, 2, RGBA(r: 17, g: 83, b: 199, a: 255))]
                    t.equal(try ComponentPartition.candidatePlan(prepare(smallerPair), in: window,
                                                                baseMembers: selected).baseMembers, selected,
                            "a returning selected member is not reclassified by its now-small area")
                    t.equal(try ComponentPartition.candidatePlan(prepare(smallerPair), in: window).baseMembers, [baseID],
                            "the fresh classification control would not select that small member")
                    var allHidden = pair
                    allHidden.elements[0].visibility = .collapsed
                    allHidden.elements[1].visibility = .collapsed
                    t.equal(try ComponentPartition.candidatePlan(prepare(allHidden), in: window,
                                                                baseMembers: selected).baseMembers, [])

                    let invalidBase = ComponentPartition.Failure.invalidPlan("Frozen base members must be the drawn scene's leading content prefix")
                    let pairPrepared = prepare(pair)
                    for invalid in [[baseID, baseID], [backID, baseID], [baseID, ElementID(name: "Missing", index: 99)]] {
                        rejects(pairPrepared, base: invalid, expected: invalidBase)
                    }
                    var missing = pair
                    missing.elements.remove(at: 1)
                    rejects(prepare(missing), base: selected, expected: invalidBase)
                    var reordered = pair
                    reordered.elements.swapAt(0, 1)
                    rejects(prepare(reordered), base: selected, expected: invalidBase)
                    var interposed = pair
                    interposed.elements.swapAt(1, 2)
                    rejects(prepare(interposed), base: selected, expected: invalidBase)
                    var native = pair
                    native.elements[1].backing = .native(.control)
                    rejects(prepare(native), base: selected, expected: invalidBase)
                    var child = pair
                    child.elements[1].container = maskID
                    rejects(prepare(child), base: selected, expected: invalidBase)
                    rejects(SceneInkCandidates(scene: scene, elementInk: prepared.elementInk, runInk: unknown),
                            base: [ElementID(name: "Missing", index: 99)], expected: .unresolvedInk(backID, .unresolvedRasterization))
                }
            }
        }
        t.suite("Runtime: component partition: clipping gaps, exact element limits and empty windows retain explicit roles") {
            let window = try rect(0, 0, width, height)
            var scene = fixture(variant: 0, scale: 1, dark: false)
            scene.elements[0].items = [fill(50, 0, 40, 28, RGBA(r: 97, g: 13, b: 219, a: 255))]
            let run: [InkBounds.Candidate] = [
                .unknown(.unresolvedRasterization), // Whole-window background needs no component ink admission.
                .rectangle(try rect(50, 0, 90, 28)), .rectangle(try rect(3, 4, 12, 11)),
                .rectangle(try rect(7, 8, 16, 15)), .rectangle(try rect(24, 3, 36, 16)),
            ]
            let prepared = SceneInkCandidates(scene: scene, elementInk: Array(repeating: .empty, count: scene.elements.count), runInk: run)
            let plan = try ComponentPartition.candidatePlan(prepared, in: window)
            t.equal(plan.baseMembers, [])
            t.equal(plan.skipped, [baseID], "the fully clipped first occurrence leaves a real file-order gap")
            let groups = plan.layers.filter { if case .group = $0.content { return true }; return false }
            t.equal(groups.map(\.id), [.group(fileIndex: 1), .group(fileIndex: 3)], "group identity uses original file occurrences")
            t.equal(groups.map(\.content), [.group(members: [backID, frontID]), .group(members: [maskID])],
                    "a container child is never independently classified")
            scene.elements = (0..<5_000).map { element(ElementID(name: "Unit\($0)", index: $0), items: []) }
            scene.background = []
            scene.glass = []
            let atLimit = SceneInkCandidates(scene: scene, elementInk: Array(repeating: .empty, count: 5_000),
                                            runInk: Array(repeating: .empty, count: 5_001))
            let accepted = try ComponentPartition.candidatePlan(atLimit, in: window)
            t.equal(accepted.skipped.count, 5_000, "the exact element cap is accepted without raster work")
            t.equal(accepted.layers, [LayerPlan(id: .baseSlice(index: 0), rect: window, content: .baseSlice(source: window))])
            scene.elements.append(element(ElementID(name: "OverLimit", index: 5_000), items: []))
            do {
                _ = try ComponentPartition.candidatePlan(SceneInkCandidates(scene: scene, elementInk: [], runInk: []), in: window)
                t.check(false, "a scene over the fixed cap was accepted")
            } catch let failure as ComponentPartition.Failure {
                t.equal(failure, .resourceLimit("Scene exceeds 5000 elements"))
            } catch { t.check(false, "unexpected cap failure: \(error)") }
            var emptyScene = atLimit.scene
            emptyScene.size = SkinSize(width: 0, height: 0)
            let empty = try rect(0, 0, 0, 0)
            let emptyPrepared = SceneInkCandidates(scene: emptyScene, elementInk: atLimit.elementInk, runInk: atLimit.runInk)
            t.equal(try ComponentPartition.candidatePlan(emptyPrepared, in: empty), SinglePartition.plan(in: empty),
                    "an empty canonical viewport produces no drawing roles or bitmap allocation")
        }
    }

    private static func structureTests(_ t: AppTestRunner) {
        t.suite("Runtime: layer content: invalid geometry and checked total bitmap budgets fail explicitly") {
            let space = try rgb(), plan = try components(scale: 1)
            for scale in [CGFloat.zero, -1, .nan, .infinity] {
                expect(.invalidInput, t, "invalid scale") {
                    _ = try LayerContentBuilder(plan: plan, scale: scale, colorSpace: space, maximumOwnedBitmapBytes: budget)
                }
            }
            for bytes in [0, -1] {
                expect(.invalidInput, t, "invalid total budget") {
                    _ = try LayerContentBuilder(plan: plan, scale: 1, colorSpace: space, maximumOwnedBitmapBytes: bytes)
                }
            }
            expect(.incompatibleColorSpace, t, "an explicit gray destination is not silently changed to RGB") {
                _ = try builder(plan, scale: 1, space: CGColorSpaceCreateDeviceGray())
            }
            // One 40x28 base and two slots for 13x11 and 12x13 groups: 4,480 + 2*(572 + 624).
            expect(.resourceLimit, t, "the total budget includes every group slot and the whole base") {
                _ = try LayerContentBuilder(plan: plan, scale: 1, colorSpace: space, maximumOwnedBitmapBytes: 6_871)
            }
            expect(.resourceLimit, t, "Single has two full-window slots and no separate base") {
                _ = try LayerContentBuilder(plan: SinglePartition.plan(in: plan.window), scale: 1,
                                           colorSpace: space, maximumOwnedBitmapBytes: 8_959)
            }
            for (w, h) in [(Int.max, 1), (Int.max / 4, 2), (16_385, 1)] {
                expect(.resourceLimit, t, "checked dimensions and multiplication") {
                    _ = try Rasterizer.requiredBytes(width: w, height: h)
                }
            }
            let single = LayerPlan(id: .single, rect: plan.window, content: .fullScene)
            let badPlans = [
                PartitionPlan(window: try rect(1, 0, 41, 28), baseMembers: [], layers: [], skipped: []),
                PartitionPlan(window: plan.window, baseMembers: [], layers: [], skipped: []),
                PartitionPlan(window: plan.window, baseMembers: [baseID], layers: [single], skipped: []),
                replace(plan, layers: plan.layers + [single]),
                replace(plan, layers: Array(plan.layers.dropLast())),
                replace(plan, layers: plan.layers + [plan.layers[0]]),
                replace(plan, layers: [LayerPlan(id: .baseSlice(index: 0), rect: plan.window,
                                                content: .baseSlice(source: plan.window)),
                                      LayerPlan(id: .baseSlice(index: 1), rect: try rect(1, 1, 2, 2),
                                                content: .baseSlice(source: try rect(1, 1, 2, 2)))]),
                replace(plan, layers: [LayerPlan(id: .baseSlice(index: 0), rect: plan.window,
                                                content: .baseSlice(source: try rect(0, 0, 39, 28)))]),
                replace(plan, layers: [LayerPlan(id: .group(fileIndex: 1), rect: plan.window, content: .group(members: []))]),
                replace(plan, layers: [LayerPlan(id: .group(fileIndex: 99), rect: plan.window, content: .group(members: [backID]))]),
                replace(plan, layers: [LayerPlan(id: .baseSlice(index: 0), rect: try rect(0, 0, 41, 28),
                                                content: .baseSlice(source: try rect(0, 0, 41, 28)))]),
            ]
            for (index, invalid) in badPlans.enumerated() {
                expect(.invalidPlan, t, "malformed tiling \(index)") { _ = try builder(invalid, scale: 1, space: space) }
            }
            let empty = try builder(SinglePartition.plan(in: rect(0, 0, 0, 0)), scale: 1, space: space)
            var emptyScene = fixture(variant: 0, scale: 1, dark: false)
            emptyScene.size = SkinSize(width: 0, height: 0)
            let context = DrawContext(fonts: AppFontResolver())
            t.check(try empty.build(emptyScene, context: context, cycle: 0, glass: .none).isEmpty,
                    "only an explicitly empty viewport produces no content records")
        }
    }

    private static func membershipTests(_ t: AppTestRunner) {
        t.suite("Runtime: layer content: scene IDs order visibility and container membership cannot be silently omitted") {
            let space = try rgb(), plan = try components(scale: 1)
            let scene = fixture(variant: 0, scale: 1, dark: false)
            let context = DrawContext(fonts: AppFontResolver())
            func rejected(_ candidate: PartitionPlan, _ note: String, source: WidgetScene? = nil) throws {
                let subject = try builder(candidate, scale: 1, space: space)
                expect(.invalidPlan, t, note) { _ = try subject.build(source ?? scene, context: context, cycle: 0, glass: .none) }
            }
            func replacingColoredGroup(_ ids: [ElementID]) -> PartitionPlan {
                let layers = plan.layers.map { layer -> LayerPlan in
                    if layer.id == .group(fileIndex: 1) {
                        return LayerPlan(id: .group(fileIndex: ids.map(\.index).min() ?? 1), rect: layer.rect,
                                         content: .group(members: ids))
                    }
                    return layer
                }
                return replace(plan, layers: layers)
            }
            try rejected(replacingColoredGroup([frontID, backID]), "overlapping group members must keep file order")
            try rejected(replacingColoredGroup([backID]), "an unclassified visible unit is an error")
            try rejected(replacingColoredGroup([ElementID(name: "Missing", index: 1), frontID]), "unknown IDs are not compactMapped away")
            try rejected(replacingColoredGroup([childID, hiddenID]), "container children and hidden top-level elements are not drawing units")
            try rejected(replacingColoredGroup([hiddenID]), "a hidden top-level element is not a complete-scene group")
            let reorderedBase = replace(plan, baseMembers: [frontID], layers: plan.layers.map { layer in
                layer.id == .group(fileIndex: 1)
                    ? LayerPlan(id: .group(fileIndex: 0), rect: layer.rect, content: .group(members: [baseID, backID])) : layer
            })
            try rejected(reorderedBase, "base members cannot move later content behind earlier units")
            var duplicated = scene
            duplicated.elements.append(scene.elements[0])
            try rejected(plan, "duplicate scene occurrence IDs are rejected before painting", source: duplicated)
            expect(.invalidPlan, t, "the same unit cannot occur in two plan roles") {
                _ = try builder(replace(plan, skipped: [backID]), scale: 1, space: space)
            }
            let subject = try builder(plan, scale: 1, space: space)
            for size in [SkinSize(width: 41, height: 28), SkinSize(width: .nan, height: 28),
                         SkinSize(width: 40, height: -.infinity), SkinSize(width: -1, height: 28)] {
                var changed = scene
                changed.size = size
                expect(.invalidInput, t, "scene and canonical viewport must agree") {
                    _ = try subject.build(changed, context: context, cycle: 0, glass: .none)
                }
            }
        }
    }

    private static func rasterizerTests(_ t: AppTestRunner) {
        t.suite("Runtime: layer content: raw integer copies preserve padded-row bytes and actual RGB profiles") {
            let space = try rgb(), source = try paddedImage(space: space)
            let expected = try pixels(source)
            t.equal(source.bytesPerRow, 64, "the source deliberately has 36 non-pixel bytes after each seven-pixel row")
            t.equal(expected.count, 7 * 5 * 4, "only active bytes are compared")
            t.equal(Array(expected.prefix(4)), [227, 31, 71, 255], "the first pixel has literal independent RGBA values")
            t.check(!expected.contains(0xD7), "the row-padding poison is not a pixel")
            let rasterizer = try Rasterizer(width: 7, height: 5, colorSpace: space, maximumBitmapBytes: 4096)
            let context = DrawContext(fonts: AppFontResolver())
            let bounds = try rect(9, 11, 16, 16)
            let first = try rasterizer.image(of: [], in: bounds, scale: 1, baseCrop: source,
                                              context: context, cycle: 0, glass: .none)
            t.check(try pixels(first) == expected, "raw copy keeps asymmetric top rows, channels and premultiplied alpha exactly")
            let second = try rasterizer.image(of: [fill(9, 11, 7, 5, RGBA(r: 13, g: 129, b: 231, a: 255))],
                                               in: bounds, scale: 1, baseCrop: nil, context: context, cycle: 1, glass: .none)
            t.check(try pixels(second) != expected, "the translated drawing reaches this local bitmap")
            t.check(try pixels(first) == expected, "a later clear and draw do not mutate a retained snapshot")
            let copiedAgain = try rasterizer.image(of: [], in: bounds, scale: 2, baseCrop: source,
                                                    context: context, cycle: 2, glass: .none)
            t.check(try pixels(copiedAgain) == expected, "base copies occur before scale and device-origin transforms")
            guard let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { throw CocoaError(.coderInvalidValue) }
            let otherProfile = try paddedImage(space: p3)
            expect(.incompatibleColorSpace, t, "equal dimensions and format do not make different profiles interchangeable") {
                _ = try rasterizer.image(of: [], in: bounds, scale: 1, baseCrop: otherProfile,
                                          context: context, cycle: 3, glass: .none)
            }
            let p3Rasterizer = try Rasterizer(width: 7, height: 5, colorSpace: p3, maximumBitmapBytes: 4096)
            let p3Image = try p3Rasterizer.image(of: [], in: bounds, scale: 1, baseCrop: otherProfile,
                                                 context: context, cycle: 0, glass: .none)
            t.check(p3Image.colorSpace.map { CFEqual($0, p3) } == true, "a supported RGB profile is kept, not replaced by sRGB")
            t.check(try pixels(p3Image) == expected, "same-profile copying needs no RGB conversion")
            expect(.invalidInput, t, "the device rectangle must match the allocated bitmap") {
                _ = try rasterizer.image(of: [], in: rect(9, 11, 15, 16), scale: 1, baseCrop: nil,
                                          context: context, cycle: 4, glass: .none)
            }
        }
    }

    /// This reference uses no Rasterizer or LayerContentBuilder. The same pair/snapshot lifetime is retained
    /// as Single, so the comparison does not mix fresh and reused CGContext image histories.
    private final class RawOracle {
        private let bitmaps: [CGContext]
        private let context = DrawContext(fonts: AppFontResolver())
        private let scale: Int
        private var next = 0

        init(scale: Int, space: CGColorSpace) throws {
            self.scale = scale
            var bitmaps: [CGContext] = []
            for _ in 0..<2 {
                guard let bitmap = CGContext(data: nil, width: width * scale, height: height * scale,
                                             bitsPerComponent: 8, bytesPerRow: width * scale * 4,
                                             space: space, bitmapInfo: info) else { throw CocoaError(.coderInvalidValue) }
                bitmaps.append(bitmap)
            }
            self.bitmaps = bitmaps
        }

        func draw(_ scene: WidgetScene, cycle: Int, glass: GlassPaint, _ t: AppTestRunner) throws -> CGImage {
            let bitmap = bitmaps[next]
            bitmap.saveGState()
            defer { bitmap.restoreGState() }
            bitmap.clear(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
            bitmap.translateBy(x: 0, y: CGFloat(bitmap.height))
            bitmap.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
            let target = DrawTarget.prepareOwnedBitmap(bitmap, glass: glass)
            t.equal(target.userToDevice, CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)),
                    "the independent full-window oracle has an explicit canonical y-down mapping")
            DesksetDraw.DrawExecutor.draw(scene: scene, in: bitmap, context: context, cycle: cycle, target: target)
            guard let image = bitmap.makeImage() else { throw CocoaError(.coderInvalidValue) }
            next = 1 - next
            return image
        }
    }

    private static func fixture(variant: Int, scale: Int, dark: Bool) -> WidgetScene {
        let regions = [GlassRegion(id: "PublishedA", rect: SkinRect(x: 1, y: 1, width: 20, height: 17)),
                       GlassRegion(id: "PublishedB", rect: SkinRect(x: 12, y: 10, width: 20, height: 16))]
        let selectionOnly = GlassRegion(id: "CurrentSelection", rect: SkinRect(x: 4, y: 5, width: 3, height: 3))
        let back = variant == 0 ? RGBA(r: 231, g: 43, b: 17, a: 189) : RGBA(r: 17, g: 73, b: 237, a: 151)
        let front = variant == 0 ? RGBA(r: 19, g: 103, b: 223, a: 173) : RGBA(r: 223, g: 97, b: 31, a: 207)
        let base = DrawItem.fill(SkinRect(x: 0, y: 0, width: Double(width), height: Double(height)),
                                 Paint(color: RGBA(r: 31, g: 89, b: 151, a: 83),
                                       secondColor: RGBA(r: 203, g: 127, b: 47, a: 131), angle: 23))
        let mask = DrawItem.transformed(ShapeTransform(a: 1, b: 0, c: 0, d: 1, tx: 1, ty: 1),
                                        [fill(25, 4, 9, 9, RGBA(r: 255, g: 255, b: 255, a: 151))])
        let elements = [
            element(baseID, items: [base]),
            element(backID, items: [fill(3, 4, 9, 7, back)], glass: selectionOnly),
            element(frontID, items: [fill(7, 8, 9, 7, front)]),
            element(maskID, items: [mask], frame: SkinRect(x: 24, y: 3, width: 12, height: 13), isContainer: true),
            element(childID, items: [fill(22, 1, 16, 17, RGBA(r: 71, g: 213, b: 113, a: 219))], container: maskID),
            element(ElementID(name: "HiddenChild", index: 5),
                    items: [fill(24, 3, 12, 13, RGBA(r: 249, g: 1, b: 181, a: 255))],
                    visibility: .hiddenKeepsSpace, container: maskID),
            element(hiddenID, items: [fill(0, 0, 40, 28, RGBA(r: 0, g: 0, b: 0, a: 255))], visibility: .collapsed),
        ]
        // The generation deliberately stays fixed through A/B/A. No version token authorizes content reuse.
        return WidgetScene(generation: 7, size: SkinSize(width: Double(width), height: Double(height)),
                           background: regions.map(DrawItem.glass)
                               + [fill(0, 23, 5, 5, RGBA(r: 251, g: 17, b: 79, a: 233)),
                                  fill(35, 0, 5, 2, RGBA(r: 11, g: 181, b: 229, a: 255))],
                           backgroundImageDependencies: [], glass: regions, elements: elements, hitMap: SkinHitMap(),
                           environment: EnvironmentStamp(scale: Double(scale), fontGeneration: 3,
                               appearance: AppearanceStamp(value: dark ? .dark : .light, name: "layer-content"),
                               imageGeneration: 5))
    }

    private static func components(scale: Int, omitColoredGroup: Bool = false) throws -> PartitionPlan {
        let window = try rect(0, 0, width * scale, height * scale)
        let colored = try rect(3 * scale, 4 * scale, 16 * scale, 15 * scale)
        let masked = try rect(24 * scale, 3 * scale, 36 * scale, 16 * scale)
        let groups = (omitColoredGroup ? [] : [LayerPlan(id: .group(fileIndex: 1), rect: colored,
                                                         content: .group(members: [backID, frontID]))])
            + [LayerPlan(id: .group(fileIndex: 3), rect: masked, content: .group(members: [maskID]))]
        let slices = RectangleComplement.slices(in: window, excluding: groups.map(\.rect)).enumerated().map {
            LayerPlan(id: .baseSlice(index: $0.offset), rect: $0.element, content: .baseSlice(source: $0.element))
        }
        return PartitionPlan(window: window, baseMembers: [baseID], layers: slices + groups,
                             skipped: omitColoredGroup ? [backID, frontID] : [])
    }

    private static func tree(_ contents: [Content], scale: Int) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let top = CALayer()
        top.anchorPoint = .zero
        top.bounds = CGRect(x: 0, y: 0, width: width * scale, height: height * scale)
        top.isGeometryFlipped = true
        top.contentsFormat = .RGBA8Uint
        let root = CALayer()
        root.anchorPoint = .zero
        root.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        root.setAffineTransform(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        root.contentsFormat = .RGBA8Uint
        top.addSublayer(root)
        for content in contents {
            let rectangle = content.plan.rect
            let layer = CALayer()
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
        return top
    }

    private static func paddedImage(space: CGColorSpace) throws -> CGImage {
        let colors: [[UInt8]] = [[227, 31, 71, 255], [12, 73, 103, 128], [0, 0, 0, 0],
                                 [7, 22, 3, 37], [17, 139, 61, 200], [9, 43, 231, 255]]
        var bytes = [UInt8](repeating: 0xD7, count: 64 * 5)
        for y in 0..<5 {
            for x in 0..<7 {
                let color = colors[(x * 3 + y * 2 + x * y) % colors.count], offset = y * 64 + x * 4
                bytes[offset] = color[2]
                bytes[offset + 1] = color[1]
                bytes[offset + 2] = color[0]
                bytes[offset + 3] = color[3]
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: 7, height: 5, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CocoaError(.coderInvalidValue)
        }
        return image
    }

    private static func pixels(_ image: CGImage) throws -> [UInt8] {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.alphaInfo == .premultipliedFirst,
              image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue == CGBitmapInfo.byteOrder32Little.rawValue,
              image.bytesPerRow >= image.width * 4, let data = image.dataProvider?.data,
              CFDataGetLength(data) >= image.bytesPerRow * image.height, let bytes = CFDataGetBytePtr(data) else {
            throw CocoaError(.coderInvalidValue)
        }
        var rgba: [UInt8] = []
        rgba.reserveCapacity(image.width * image.height * 4)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * image.bytesPerRow + x * 4
                rgba.append(contentsOf: [bytes[offset + 2], bytes[offset + 1], bytes[offset], bytes[offset + 3]])
            }
        }
        return rgba
    }

    private static func checkSlices(_ contents: [Content], plan: PartitionPlan, space: CGColorSpace,
                                    _ t: AppTestRunner, _ note: String) {
        t.equal(contents.map(\.plan), plan.layers, "\(note): complete output preserves every requested layer and its order")
        let slices = contents.filter { if case .baseSlice = $0.plan.content { return true }; return false }
        guard let first = slices.first else { return t.check(false, "\(note): shared-base control has no slices") }
        t.check(slices.count > 1 && slices.allSatisfy { $0.image === first.image },
                "\(note): all slices share one full-window CGImage snapshot")
        t.check(first.image.width == plan.window.width && first.image.height == plan.window.height,
                "\(note): slices reference the complete base bitmap")
        t.check(contents.allSatisfy { $0.image.colorSpace.map { CFEqual($0, space) } == true },
                "\(note): every output retains the actual requested profile")
        t.check(contents.allSatisfy { content in
            switch content.plan.content {
            case .baseSlice: return true
            case .group, .fullScene:
                return content.image.width == content.plan.rect.width && content.image.height == content.plan.rect.height
            }
        }, "\(note): group bitmap dimensions equal their integer device boxes")
    }

    private static func checkFixture(_ bytes: [UInt8], scale: Int, _ t: AppTestRunner, _ note: String) {
        t.equal(bytes.count, width * height * scale * scale * 4, "\(note): original bitmap active byte count")
        let alpha = stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
        t.check(alpha.contains { $0 > 0 } && alpha.contains { $0 > 0 && $0 < 255 }, "\(note): visible translucent pixels make equality meaningful")
        let row = width * scale * 4
        t.check(Array(bytes.prefix(row)) != Array(bytes.suffix(row)), "\(note): the original bitmap detects a vertical flip")
        t.check(stride(from: 0, to: bytes.count, by: 4).contains { bytes[$0] != bytes[$0 + 2] },
                "\(note): the original bitmap detects a red/blue channel swap")
    }

    private static func check(_ actual: OffscreenRenderer.Readback, _ expected: [UInt8], _ t: AppTestRunner, _ note: String) {
        t.check(actual.rgba.contains { $0 != 0 }, "\(note): native result is nonempty")
        let difference = actual.rgba.count == expected.count
            ? actual.rgba.indices.first { actual.rgba[$0] != expected[$0] }.map { "first byte \($0): \(actual.rgba[$0]) != \(expected[$0])" } ?? "equal"
            : "byte count \(actual.rgba.count) != \(expected.count)"
        t.check(actual.rgba == expected, "\(note): strict active RGBA equality; \(difference)")
    }

    private static func element(_ id: ElementID, items: [DrawItem], frame: SkinRect = SkinRect(x: 0, y: 0, width: 40, height: 28),
                                visibility: Visibility = .visible, container: ElementID? = nil,
                                isContainer: Bool = false, glass: GlassRegion? = nil) -> SceneElement {
        SceneElement(id: id, kind: .shape, frame: frame, anchor: SkinPoint(), visibility: visibility,
                     container: container, isContainer: isContainer, items: items, glass: glass, imageDependencies: [])
    }

    private static func fill(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: RGBA) -> DrawItem {
        .fill(SkinRect(x: x, y: y, width: w, height: h), Paint(color: color))
    }

    private static func builder(_ plan: PartitionPlan, scale: Int, space: CGColorSpace) throws -> LayerContentBuilder {
        try LayerContentBuilder(plan: plan, scale: CGFloat(scale), colorSpace: space, maximumOwnedBitmapBytes: budget)
    }

    private static func replace(_ plan: PartitionPlan, baseMembers: [ElementID]? = nil,
                                layers: [LayerPlan]? = nil, skipped: [ElementID]? = nil) -> PartitionPlan {
        PartitionPlan(window: plan.window, baseMembers: baseMembers ?? plan.baseMembers,
                      layers: layers ?? plan.layers, skipped: skipped ?? plan.skipped)
    }

    private static func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) throws -> Rect {
        guard let value = Rect(minX: x0, minY: y0, maxX: x1, maxY: y1) else { throw CocoaError(.coderInvalidValue) }
        return value
    }

    private static func rgb() throws -> CGColorSpace {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw CocoaError(.coderInvalidValue) }
        return space
    }

    private static func expect(_ kind: FailureKind, _ t: AppTestRunner, _ note: String,
                               line: UInt = #line, _ body: () throws -> Void) {
        do {
            try body()
            t.check(false, "\(note): expected a typed failure", line: line)
        } catch let error as Rasterizer.Failure {
            let matches: Bool
            switch (kind, error) {
            case (.invalidInput, .invalidInput), (.invalidPlan, .invalidPlan),
                 (.resourceLimit, .resourceLimit), (.incompatibleColorSpace, .incompatibleColorSpace): matches = true
            default: matches = false
            }
            t.check(matches, "\(note): unexpected failure \(error)", line: line)
        } catch {
            t.check(false, "\(note): untyped failure \(error)", line: line)
        }
    }
}
