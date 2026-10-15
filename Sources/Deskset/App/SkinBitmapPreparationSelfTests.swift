import AppKit
import DesksetCore
import DesksetDraw

enum SkinBitmapPreparationSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: bitmap preparation: one preparation exports the same pixels once and legacy stays direct") {
            let f = Fixture()
            defer { f.close() }
            let prepared = try f.prepare()
            let original = images(prepared.composition)
            t.check(!original.isEmpty)
            t.equal(f.validations, 1)
            t.equal(f.requests.count, 0, "preparation publishes nothing")
            t.equal(f.frames.framesDrawn, 0)
            f.frames.commitPreparedBitmap(prepared)
            f.draw()
            let delivery = try f.takeFrame()
            let exported = try composition(delivery)
            t.equal(f.validations, 1, "export reuses successful qualification and drawing")
            checkIdentity(t, images(exported), original)
            t.equal(delivery.origin, f.capture.origin)
            t.equal(exported.size, f.capture.size)
            t.equal(exported.scale, f.facts.scale)
            t.check(CFEqual(delivery.space, f.facts.colorSpace!))
            t.equal(f.frames.framesDrawn, 0, "prepared pixels still wait for the owner ACK")
            t.check(f.accept(delivery))
            t.equal(f.frames.framesDrawn, 0)
            f.executor.runUntilIdle()
            t.equal(f.presented, [1])
            f.draw()
            let redraw = try f.takeFrame()
            t.equal(redraw.scene.generation, delivery.scene.generation)
            t.equal(f.validations, 2, "the consumed preparation is not a persistent same-generation cache")
            t.check(f.accept(redraw)); f.executor.runUntilIdle()
            t.equal(f.frames.framesDrawn, 2)

            let legacy = Fixture(optIn: false)
            defer { legacy.close() }
            t.check(try legacy.frames.prepareBitmapContent(legacy.capture) == nil)
            t.equal(legacy.validations, 0)
            legacy.draw()
            t.equal(legacy.provider.presents, 1)
            t.equal(legacy.validations, 1)
            t.check(legacy.requests.isEmpty && !legacy.frames.hasBitmapDelivery)
        }

        t.suite("App: bitmap preparation: changed capture and destination never reuse stale pixels") {
            let changes: [(String, (Fixture) -> Void)] = [
                ("scale", { f in
                    f.facts.scale = 2
                    f.capture = replacing(f.capture) {
                        let old = $0.environment
                        $0.environment = EnvironmentStamp(scale: 2, fontGeneration: old.fontGeneration,
                            appearance: old.appearance, imageGeneration: old.imageGeneration)
                    }
                    f.frames.take(f.facts)
                }),
                ("profile", { f in
                    f.facts.colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
                    f.frames.take(f.facts)
                }),
                ("appearance", { f in
                    f.facts.appearance = NSAppearance.Name.darkAqua.rawValue
                    f.capture = replacing(f.capture) {
                        let old = $0.environment
                        $0.environment = EnvironmentStamp(scale: old.scale, fontGeneration: old.fontGeneration,
                            appearance: AppearanceStamp(value: .dark, name: f.facts.appearance),
                            imageGeneration: old.imageGeneration)
                    }
                    f.frames.take(f.facts)
                }),
                ("panel", { f in f.facts.panelGeneration += 1; f.frames.take(f.facts) }),
                ("glass capability", { $0.frames.bitmapCompositionSupportsSystemGlass = true }),
                ("origin", { f in f.capture = replacing(f.capture, origin: SkinPoint(x: -2, y: -1)) }),
                ("size", { f in f.capture = replacing(f.capture, size: CGSize(width: 18, height: 14)) }),
                ("context", { f in f.capture = replacing(f.capture, context: SkinRenderContext()) }),
                ("cycle", { f in f.capture = replacing(f.capture, cycle: f.capture.cycle + 1) }),
                ("same-generation scene", { f in
                    f.capture = replacing(f.capture) {
                        $0.background = [.fill(SkinRect(x: 1, y: 1, width: 2, height: 2),
                                               Paint(color: RGBA(r: 0, g: 0, b: 255)))]
                    }
                })
            ]
            for (name, change) in changes {
                let f = Fixture()
                defer { f.close() }
                let prepared = try f.prepare()
                let original = images(prepared.composition)
                f.frames.commitPreparedBitmap(prepared)
                change(f)
                f.draw()
                let delivery = try f.takeFrame()
                let rebuilt = try composition(delivery)
                t.equal(f.validations, 2, name)
                t.check(!images(rebuilt).contains { next in original.contains { $0 === next } }, name)
                t.equal(delivery.scene, f.capture.scene, name)
                t.equal(delivery.origin, f.capture.origin, name)
                t.equal(rebuilt.size, f.capture.size, name)
                t.equal(rebuilt.scale, f.facts.scale, name)
                t.equal(delivery.appearance, f.facts.appearance, name)
                t.equal(delivery.panelGeneration, f.facts.panelGeneration, name)
                t.check(CFEqual(delivery.space, f.facts.colorSpace!), name)
                t.equal(rebuilt.systemGlass, f.frames.bitmapCompositionSupportsSystemGlass, name)
                t.check(f.accept(delivery), name); f.executor.runUntilIdle()
                t.equal(f.frames.framesDrawn, 1, name)
            }
        }

        t.suite("App: bitmap preparation: held A keeps immutable pixels while B is replaced by latest C") {
            let f = Fixture()
            defer { f.close() }
            try autoreleasepool {
                f.frames.commitPreparedBitmap(try f.prepare())
            }
            f.draw()
            let first = try f.takeFrame()
            let firstImages = images(try composition(first))
            let firstBytes = firstImages.map { $0.dataProvider?.data.map { $0 as Data } }
            weak var discarded: SkinFrameProducer.PreparedBitmap?
            try autoreleasepool {
                f.capture = replacing(f.capture, cycle: 2) { $0.generation = 2 }
                let prepared = try f.prepare()
                discarded = prepared
                f.frames.commitPreparedBitmap(prepared)
            }
            t.check(discarded != nil, "only the latest owner slot retains B")
            f.draw()
            t.check(f.requests.isEmpty && f.frames.hasBitmapDelivery)
            weak var latest: SkinFrameProducer.PreparedBitmap?
            var latestImages: [CGImage] = []
            try autoreleasepool {
                f.capture = replacing(f.capture, cycle: 3) { $0.generation = 3 }
                let prepared = try f.prepare()
                latest = prepared
                latestImages = images(prepared.composition)
                f.frames.commitPreparedBitmap(prepared)
            }
            t.check(discarded == nil, "C replaces B; preparations do not form a generation cache")
            t.check(latest != nil)
            f.draw()
            t.equal(f.validations, 3, "only A, B and C preparation draw; a held delivery blocks export")
            t.check(f.requests.isEmpty)
            t.equal(first.scene.generation, 1)
            t.equal(firstImages.map { $0.dataProvider?.data.map { $0 as Data } }, firstBytes)
            t.check(f.accept(first))
            t.equal(f.presented, [])
            f.executor.runUntilIdle()
            t.equal(f.presented, [1])
            let last = try f.takeFrame()
            t.equal(last.scene.generation, 3)
            t.check(last.serial > first.serial)
            t.check(latest == nil, "export consumes the wrapper; the delivery now retains its images")
            checkIdentity(t, images(try composition(last)), latestImages)
            t.equal(f.validations, 3, "the ACK-triggered draw consumes C without drawing it again")
            t.check(f.accept(last)); f.executor.runUntilIdle()
            t.equal(f.presented, [1, 3])
            t.check(!f.frames.hasBitmapDelivery && f.requests.isEmpty)
        }

        t.suite("App: bitmap preparation: close releases the latest slot and a claimed late ACK stays stale") {
            let f = Fixture()
            defer { f.close() }
            f.frames.commitPreparedBitmap(try f.prepare())
            f.draw()
            let first = try f.takeFrame()
            t.check(first.claimOnMain())
            weak var prepared: SkinFrameProducer.PreparedBitmap?
            try autoreleasepool {
                f.capture = replacing(f.capture, cycle: 2) { $0.generation = 2 }
                let value = try f.prepare()
                prepared = value
                f.frames.commitPreparedBitmap(value)
            }
            t.check(prepared != nil)
            f.draw()
            f.frames.stop()
            f.frames.clearBitmapContents()
            t.check(prepared == nil, "close releases unexported preparation immediately")
            t.equal(first.state, .applying)
            t.check(f.frames.hasBitmapDelivery, "an already claimed Main payload lives until its owner ACK")
            let clear = try f.takeClear()
            t.check(first.finishOnMain(accepted: true))
            f.executor.async { f.frames.finishBitmapDelivery(first) }
            t.check(clear.claimOnMain() && clear.finishOnMain(accepted: true))
            f.executor.async { f.frames.finishBitmapInvalidation(clear) }
            f.executor.runUntilIdle()
            t.equal(f.frames.framesDrawn, 0)
            t.equal(f.presented, [])
            t.check(!f.frames.hasBitmapDelivery && !f.frames.needsFrame && f.requests.isEmpty)
            t.check(!first.claimOnMain() && !first.finishOnMain(accepted: true))
            f.frames.finishBitmapDelivery(first)
            t.equal(f.frames.framesDrawn, 0)
            // This test still holds `first`; its immutable images may correctly outlive the stopped producer.
            t.check(!images(try composition(first)).isEmpty)
            expect(t, .invalidDestination) { try f.frames.prepareBitmapContent(f.capture) }
        }

        t.suite("App: bitmap preparation: failure preserves the committed slot and bitmap or unseen releases it") {
            let f = Fixture()
            defer { f.close() }
            let prepared = try f.prepare()
            let original = images(prepared.composition)
            f.frames.commitPreparedBitmap(prepared)
            let overlap = replacing(f.capture) {
                $0.background = [.fill(SkinRect(x: 8, y: 5, width: 3, height: 3),
                                       Paint(color: RGBA(r: 255, g: 0, b: 0)))]
            }
            expect(t, .unsupportedFallbackOverlap) { try f.frames.prepareBitmapContent(overlap) }
            t.equal(f.frames.bitmapCompositionFailure, .unsupportedFallbackOverlap)
            f.validationSucceeds = false
            expect(t, .qualificationFailed) { try f.frames.prepareBitmapContent(f.capture) }
            f.validationSucceeds = true
            t.check(f.requests.isEmpty, "failed candidates publish neither a frame nor a clear")
            t.equal(f.failures, 0, "preparation reports its error to the candidate transaction")
            t.equal(f.validations, 3)
            f.draw()
            let accepted = try f.takeFrame()
            checkIdentity(t, images(try composition(accepted)), original)
            t.equal(f.validations, 3, "a failed uncommitted candidate does not replace the earlier preparation")
            t.check(f.accept(accepted)); f.executor.runUntilIdle()

            weak var replaced: SkinFrameProducer.PreparedBitmap?
            try autoreleasepool {
                let value = try f.prepare()
                replaced = value
                f.frames.commitPreparedBitmap(value)
            }
            t.check(replaced != nil)
            f.capture = replacing(f.capture, cycle: 2) { $0.generation = 2; $0.elements = [] }
            t.check(try f.frames.prepareBitmapContent(f.capture) == nil)
            f.frames.commitPreparedBitmap(nil)
            t.check(replaced == nil, "a successful ordinary bitmap candidate clears the glass slot")
            f.draw()
            let bitmap = try f.takeFrame()
            if case .bitmap = bitmap.content { t.check(true) }
            else { t.check(false, "ordinary scenes keep the direct bitmap path") }
            t.check(f.frames.drawing.keepsPictures)
            t.check(f.accept(bitmap)); f.executor.runUntilIdle()

            weak var unseen: SkinFrameProducer.PreparedBitmap?
            try autoreleasepool {
                f.capture = capture(generation: 3, context: f.capture.context)
                let value = try f.prepare()
                unseen = value
                f.frames.commitPreparedBitmap(value)
            }
            t.check(!f.frames.drawing.keepsPictures, "new composition scratch does not coexist with kept bitmap runs")
            t.check(unseen != nil)
            f.facts.isOrderedIn = false; f.facts.isVisible = false
            f.frames.take(f.facts)
            f.frames.releaseUnseen()
            t.check(unseen == nil, "ordered-out release also drops an unexported preparation")
            let clear = try f.takeClear()
            t.check(clear.claimOnMain() && clear.finishOnMain(accepted: true))
            f.executor.async { f.frames.finishBitmapInvalidation(clear) }
            f.executor.runUntilIdle()
            t.check(f.requests.isEmpty)
        }
    }

    /// Only the producer handoff is under test. The real composer supplies the pixels; Main claim/finish and the
    /// owner ACK are stepped separately without waiting on AppKit or retaining historical request arrays.
    private final class Fixture {
        let provider = Provider()
        let executor = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
        var capture = SkinBitmapPreparationSelfTests.capture()
        var facts = SkinWindowFacts(frame: CGRect(x: 0, y: 0, width: 16, height: 12), isVisible: true,
            isOrderedIn: true, scale: 1, colorSpace: SkinFrameProducer.sRGB, takesPointer: true, sequence: 0,
            panelGeneration: 1)
        var requests: [SkinBitmapRequest] = []
        var validations = 0
        var validationSucceeds = true
        var presented: [UInt64] = []
        var failures = 0
        lazy var frames = SkinFrameProducer(provider: provider, bitmapCapture: { [weak self] _, _ in self?.capture },
            bitmapValidation: { [weak self] _, _ in
                guard let self else { return false }
                validations += 1
                return validationSucceeds
            })

        init(optIn: Bool = true) {
            if optIn { frames.requestBitmapDelivery = { [weak self] in self?.requests.append($0) } }
            frames.bitmapResult = { [weak self] result in
                switch result {
                case .presented(let capture): self?.presented.append(capture.scene.generation)
                case .failed: self?.failures += 1
                }
            }
            frames.start(on: executor)
            executor.runUntilIdle()
            frames.take(facts)
        }

        func prepare() throws -> SkinFrameProducer.PreparedBitmap {
            guard let value = try frames.prepareBitmapContent(capture) else { throw FixtureError.noPreparation }
            return value
        }
        func draw() { frames.setNeedsFrame(); frames.runLoopTurn(.beforeWaiting) }
        func takeFrame() throws -> SkinBitmapDelivery {
            guard !requests.isEmpty, case .frame(let frame) = requests.removeFirst() else { throw FixtureError.noFrame }
            return frame
        }
        func takeClear() throws -> SkinBitmapInvalidation {
            guard !requests.isEmpty, case .clear(let clear) = requests.removeFirst() else { throw FixtureError.noClear }
            return clear
        }
        func accept(_ delivery: SkinBitmapDelivery) -> Bool {
            guard delivery.claimOnMain(), delivery.finishOnMain(accepted: true) else { return false }
            executor.async { [frames] in frames.finishBitmapDelivery(delivery) }
            return true
        }
        func close() {
            frames.stop()
            requests.removeAll()
            executor.runUntilIdle()
            provider.teardown()
        }
    }

    private final class Provider: ContentProvider {
        private(set) var presents = 0
        private var frame: SkinFrame?
        func present(_ frame: SkinFrame) { self.frame = frame; presents += 1 }
        func setVisible(_ visible: Bool) {}
        func setScale(_ scale: CGFloat) {}
        func releaseContents() { frame = nil }
        func teardown() { frame = nil }
    }

    private enum FixtureError: Error { case noPreparation, noFrame, noClear, notComposition }

    private static func capture(generation: UInt64 = 1, context: SkinRenderContext = SkinRenderContext())
        -> SkinBitmapDrawing.Capture {
        let region = GlassRegion(id: "prepared-glass", rect: SkinRect(x: 8, y: 5, width: 3, height: 3))
        let element = SceneElement(id: ElementID(name: region.id, index: 0), kind: .shape, frame: region.rect,
            anchor: SkinPoint(x: region.rect.x, y: region.rect.y), visibility: .visible, container: nil,
            isContainer: false, items: [], glass: region, imageDependencies: [], backing: .native(.glass))
        let scene = WidgetScene(generation: generation, size: SkinSize(width: 16, height: 12),
            background: [.fill(SkinRect(x: 1, y: 1, width: 2, height: 2), Paint(color: RGBA(r: 255, g: 0, b: 0)))],
            backgroundImageDependencies: [], glass: [], elements: [element], hitMap: SkinHitMap(),
            environment: EnvironmentStamp(scale: 1, fontGeneration: 0,
                appearance: AppearanceStamp(value: .light, name: NSAppearance.Name.aqua.rawValue), imageGeneration: 0))
        return SkinBitmapDrawing.Capture(scene: scene, context: context, cycle: Int(generation),
            size: CGSize(width: 16, height: 12), source: "Bitmap preparation test")
    }

    private static func replacing(_ value: SkinBitmapDrawing.Capture, context: SkinRenderContext? = nil,
                                  cycle: Int? = nil, size: CGSize? = nil, origin: SkinPoint? = nil,
                                  update: (inout WidgetScene) -> Void = { _ in }) -> SkinBitmapDrawing.Capture {
        var scene = value.scene
        update(&scene)
        return SkinBitmapDrawing.Capture(scene: scene, context: context ?? value.context, cycle: cycle ?? value.cycle,
            size: size ?? value.size, source: value.source, origin: origin ?? value.origin)
    }

    private static func composition(_ delivery: SkinBitmapDelivery) throws -> SkinBitmapComposition {
        guard case .composition(let value) = delivery.content else { throw FixtureError.notComposition }
        return value
    }

    private static func images(_ value: SkinBitmapComposition) -> [CGImage] {
        value.items.compactMap { if case .pixels(let slice) = $0 { return slice.image }; return nil }
    }

    private static func checkIdentity(_ t: AppTestRunner, _ actual: [CGImage], _ expected: [CGImage]) {
        t.equal(actual.count, expected.count)
        for (actual, expected) in zip(actual, expected) { t.check(actual === expected, "prepared crop identity is preserved") }
    }

    private static func expect<T>(_ t: AppTestRunner, _ failure: SkinBitmapComposer.Failure,
                                  _ body: () throws -> T) {
        do { _ = try body(); t.check(false, "expected \(failure)") }
        catch let error as SkinBitmapComposer.Failure { t.equal(error, failure) }
        catch { t.check(false, "unexpected error: \(error)") }
    }
}
