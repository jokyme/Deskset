import AppKit
import DesksetCore
import DesksetDraw
import DesksetRuntime
import Metal

/// Actual activation/provider/producer wiring, with never-ordered AppKit windows and synthetic skins only.
/// CARenderer reads the installed view tree at point resolution; this is not a display/profile-change G2' test.
enum SkinLayerContentSelfTests {
    private static let mode = SkinFrameContentMode.layers(partition: .candidateComponents, maximumOwnedBitmapBytes: 1_000_000)
    private static let text = """
    [Rainmeter]
    Update=-1
    DynamicWindowSize=1
    [Variables]
    Left=4
    [Back]
    Meter=Shape
    Shape=Rectangle 0,0,48,32 | Fill Color 31,89,151,100 | StrokeWidth 0
    [Moving]
    Meter=Shape
    Shape=Rectangle #Left#,5,12,15 | Fill Color 217,61,139,157 | StrokeWidth 0
    DynamicVariables=1
    [Mask]
    Meter=Shape
    Shape=Rectangle 24,16,20,12 | Fill Color 255,255,255,180 | StrokeWidth 0
    [Child]
    Meter=Shape
    Shape=Rectangle 20,12,20,18 | Fill Color 23,211,73,140 | StrokeWidth 0
    Container=Mask
    [Label]
    Meter=String
    X=1
    Y=0
    W=46
    H=12
    FontSize=8
    FontColor=255,255,255,220
    Text=C owner
    AntiAlias=1
    """

    static func run(_ t: AppTestRunner) {
        windowTests(t)
        handshakeTests(t)
        destinationTests(t)
        firstFrameTests(t)
        patchReclaimTests(t)
        patchClaimTests(t)
        hostValueTests(t)
    }

    private static func app(_ t: AppTestRunner, threading: SkinThreading, source: String = text) throws -> AppController {
        guard let app = try AppSelfTest.makeApp(t, threading: threading) else { throw CocoaError(.fileNoSuchFile) }
        let folder = app.skinsDirectory.appendingPathComponent("App/LayerContent", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try source.write(to: folder.appendingPathComponent("Test.ini"), atomically: true, encoding: .utf8)
        app.rescanLibrary()
        return app
    }

    private static func activate(_ app: AppController, _ t: AppTestRunner,
                                 selection: SkinFrameContentMode? = mode,
                                 beforeStart: ((SkinWindowController) -> Void)? = nil) throws -> SkinWindowController {
        guard let window = app.activate(config: "App\\LayerContent", file: "Test.ini", contentMode: selection) else {
            throw CocoaError(.coderReadCorrupt)
        }
        window.window.colorSpace = .sRGB
        window.publishFacts(force: true)
        beforeStart?(window)
        t.check(AppSelfTest.spin(timeout: 30) { window.isStarted }, "actual asynchronous activation starts")
        t.check(!window.loadFailed)
        window.pauseUpdates()
        return window
    }

    private static func prepareWindow(_ window: SkinWindowController, _ t: AppTestRunner) {
        // An explicit synthetic window profile, read back through the same real facts path as production.
        window.window.colorSpace = .sRGB
        window.publishFacts(force: true)
        window.visibilityForTesting = true
        window.runtime.send(.firstFrame)
        window.runtime.send(.frameWanted)
        t.check(AppSelfTest.spin(timeout: 30) { window.content.installedLayerRoot != nil }, "main installs the actual finished owner root")
    }

    private static func windowTests(_ t: AppTestRunner) {
        t.suite("App: layer window content: actual activation builds on the worker, installs on main and matches fresh Single") {
            let app = try app(t, threading: .engine)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try activate(app, t)
            prepareWindow(window, t)
            guard let executor = window.runtime.executor as? SkinThreadExecutor,
                  let device = MTLCreateSystemDefaultDevice() else { return t.check(false, "real worker and Metal are required") }
            let renderer = try OffscreenRenderer(width: 48, height: 32, device: device, maximumReadbackBytes: 48 * 32 * 4)
            var saved: [[UInt8]] = []
            for left in [4, 12, 4] {
                let done = Guarded<Result<LayerContentBuilder.Content, Error>?>(nil)
                executor.async {
                    done.access { value in
                        value = Result {
                            window.runtime.skin.execute("[!SetVariable Left \(left)][!UpdateMeter *][!Redraw]", from: nil)
                            window.runtime.frames.runLoopTurn(.beforeWaiting)
                            let frames = window.runtime.frames
                            guard let owner = frames.layerRuntime, let frame = owner.currentFrame else { throw CocoaError(.coderReadCorrupt) }
                            let space = frame.colorSpace
                            let skin = window.runtime.skin!, context = SkinRenderContext.of(skin)
                            let environment = AppSceneEnvironment(scale: Double(frames.scale),
                                appearance: skin.host?.environment(for: skin).appearance ?? .light,
                                appearanceName: frames.appearance)
                            let scene = context.sceneProjector.project(skin, environment: environment, glassSource: .published)
                            let builder = try LayerContentBuilder(plan: SinglePartition.plan(in: frame.plan.window),
                                scale: frame.scale, colorSpace: space, maximumOwnedBitmapBytes: 1_000_000)
                            guard let reference = try builder.build(scene, context: context.drawing, cycle: skin.updateCount,
                                                                     glass: .hitArea).first else { throw CocoaError(.coderReadCorrupt) }
                            return reference
                        }
                    }
                }
                t.check(AppSelfTest.spin(timeout: 30) { done.current != nil }, "worker drawing and independent Single complete")
                guard let result = done.current else { return }
                let reference = try result.get()
                let comparison = executor.exclusive(timeout: 30) { Result<([UInt8], [UInt8]), Error> {
                    t.check(Thread.isMainThread && executor.isCurrent && !executor.isOnThread, "real park grants main the owner lease")
                    let frames = window.runtime.frames
                    t.check(frames.lastLayerDrawWasOnSkinThread, "actual producer rasterization ran on the physical skin thread")
                    t.check(frames.layerInstalled && frames.layerFailure == nil)
                    t.check(frames.layerRuntime?.root === window.content.installedLayerRoot)
                    t.check(frames.layerRuntime?.root.superlayer.map(window.content.isContentLayer) == true)
                    t.check(window.content.shown.superlayer === window.view.layer, "actual provider stays under AppKit's real view layer")
                    t.check(window.content.shown.image == nil, "legacy bitmap is absent while the owner root is installed")
                    guard let frame = frames.layerRuntime?.currentFrame, let profile = window.window.colorSpace?.cgColorSpace,
                          let tree = window.view.layer else { throw CocoaError(.coderReadCorrupt) }
                    t.equal(frame.scale, window.window.backingScaleFactor, "actual window backing scale is used")
                    t.check(CFEqual(frame.colorSpace, profile), "actual window profile is retained")
                    t.check(frame.contents.allSatisfy { $0.image.colorSpace.map { CFEqual($0, profile) } == true })
                    t.check(frame.fallback != nil, "native text is unknown ink and explicitly selects Single")
                    t.equal(frame.plan, SinglePartition.plan(in: frame.plan.window))
                    t.equal(window.view.layer?.sublayers?.count, 1, "only the real provider wraps the C root")
                    let actual = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30))
                    let expected = try renderer.render(singleTree(reference, scale: frame.scale), at: 0,
                                                       deadline: .now() + .seconds(30))
                    return (actual.rgba, expected.rgba)
                } }
                guard let comparison else { return t.check(false, "exclusive native observation completes") }
                let (actual, expected) = try comparison.get()
                t.check(stride(from: 3, to: actual.count, by: 4).contains { actual[$0] > 0 }, "installed view composition has actual nonempty alpha")
                t.equal(actual, expected, "installed AppKit provider tree / fresh Single strict RGBA bytes")
                saved.append(actual)
            }
            t.check(saved[0] != saved[1], "B changes actual pixels")
            t.equal(saved[0], saved[2], "A returns byte for byte after B")
            t.check(renderer.hasVerifiedCanary, "native rendering used the unchanged canary and fence")
            let provider = window.content, oldPanel = window.window
            window.runtime.send(.run("[!ClickThrough 1][!ClickThrough 0]"))
            t.check(AppSelfTest.spin(timeout: 30) { window.window !== oldPanel }, "real window bang replaces the panel")
            t.check(window.content === provider && provider.shown.superlayer === window.view.layer,
                    "the same provider and content view move intact")
            let replaced = try activate(app, t, selection: nil)
            t.equal(replaced.contentMode, mode, "refresh inherits the actual controller selection")
            prepareWindow(replaced, t)
            t.check(AppSelfTest.spin(timeout: 30) { provider.state.tornDown }, "replacement retires the old owner and attachment")
            replaced.stop()
            t.check(AppSelfTest.spin(timeout: 30) { replaced.content.state.tornDown }, "actual stop waits for owner cleanup before main teardown")
            t.check(replaced.content.installedLayerRoot == nil)
            t.equal(replaced.runtime.exclusive { _ in replaced.runtime.frames.layerRuntime == nil }, true)

            let bitmap = try activate(app, t, selection: .bitmap)
            t.equal(bitmap.contentMode, .bitmap, "explicit bitmap selection returns to the original default path")
            bitmap.window.colorSpace = .sRGB
            bitmap.publishFacts(force: true)
            bitmap.runtime.send(.firstFrame)
            t.check(AppSelfTest.spin(timeout: 30) { bitmap.content.shown.image != nil }, "original bitmap presentation still works")
            t.check(bitmap.content.installedLayerRoot == nil)
        }
    }

    /// This proxy controls scheduling, not ownership: its real runtime/window still draw, park, retry and install.
    private final class InstallGate: SkinRuntimeWindow {
        let window: SkinWindowController
        let executor: SkinThreadExecutor
        let release = DispatchSemaphore(value: 0)
        private let entered = DispatchSemaphore(value: 0)
        var used = false, held = false, declined = false
        var beforeInstall: (() -> Void)?
        init(_ window: SkinWindowController, _ executor: SkinThreadExecutor) { self.window = window; self.executor = executor }
        func apply(_ request: SkinRequest, from runtime: SkinRuntime) {
            if case .scenePatch = request, !used {
                // Exercise the still-supported ordinary-install fallback through a REAL unclaimed 50ms deadline.
                let deadlinePassed = DispatchSemaphore(value: 0)
                executor.async { deadlinePassed.signal() }
                _ = deadlinePassed.wait(timeout: .now() + .seconds(30))
                window.apply(request, from: runtime)
                return
            }
            if case .installLayerContent = request, !used {
                used = true
                executor.async { [self] in entered.signal(); release.wait() }
                held = entered.wait(timeout: .now() + .seconds(30)) == .success
                beforeInstall?()
                window.apply(request, from: runtime)
                declined = window.content.installedLayerRoot == nil
                release.signal()
                return
            }
            window.apply(request, from: runtime)
        }
        func batchingWindowChanges(_ body: () -> Void) { window.batchingWindowChanges(body) }
        func liveEnvironment(for skin: Skin) -> SkinEnvironment? { window.liveEnvironment(for: skin) }
        var liveTakesPointer: Bool? { window.liveTakesPointer }
    }

    private static func handshakeTests(_ t: AppTestRunner) {
        t.suite("App: layer window content: actual exclusive timeout retries and late teardown cannot install") {
            let app = try app(t, threading: .engine)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            var stagedGate: InstallGate?
            var orders = 0
            let window = try activate(app, t, beforeStart: { window in
                guard let executor = window.runtime.executor as? SkinThreadExecutor else { return }
                let gate = InstallGate(window, executor)
                stagedGate = gate
                window.runtime.window = gate
                window.willOrderIn = { orders += 1 }
                gate.beforeInstall = {
                    t.check(!window.orderIn(alpha: 1), "first showing is deferred until actual installation")
                    window.setHidden(true, fade: false)
                }
            })
            guard let gate = stagedGate else { return t.check(false, "real worker") }
            defer { gate.release.signal(); window.runtime.window = window }
            window.runtime.window = gate
            prepareWindow(window, t)
            t.check(gate.used && gate.held, "the worker is synchronously known to be held before the actual main install attempt")
            t.check(gate.declined, "the original 0.25s lease failed rather than pretending ownership")
            t.check(window.content.installedLayerRoot != nil, "the production retry installs after the worker is released")
            t.check(window.isHiddenByBang && orders == 0, "Hide before installation prevents late automatic showing")
            window.willOrderIn = nil
            // Direct invalidation must not suppress the subsequent runtime cleanup acknowledgment.
            window.content.teardown()
            t.check(!window.content.state.tornDown && window.content.installedLayerRoot != nil)
            window.runtime.teardownContent()
            window.apply(.installLayerContent, from: window.runtime)
            t.check(AppSelfTest.spin(timeout: 30) { window.content.state.tornDown }, "direct teardown followed by runtime retirement drains")
            t.check(window.content.installedLayerRoot == nil)
            t.equal(window.runtime.exclusive { _ in window.runtime.frames.layerRuntime == nil }, true)
            window.apply(.installLayerContent, from: window.runtime)
            t.check(window.content.installedLayerRoot == nil, "late readiness cannot resurrect a retired provider")
        }
    }

    private static func destinationTests(_ t: AppTestRunner) {
        t.suite("App: layer window content: missing profile and failed C update preserve the frame until closing cleanup") {
            let app = try app(t, threading: .engine)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try activate(app, t)
            prepareWindow(window, t)
            guard let executor = window.runtime.executor as? SkinThreadExecutor,
                  let root = window.content.installedLayerRoot else { return t.check(false, "installed worker root") }
            let original: [CGImage]? = executor.exclusive(timeout: 30) { window.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image) } ?? nil
            t.check(original != nil)
            // Explicit malformed facts are a negative fixture, not a claim that this real window lacks a profile.
            var missing = window.facts
            missing.colorSpace = nil
            missing.sequence += 10
            window.runtime.send(.windowFacts(missing))
            window.runtime.send(.redraw)
            let done = Guarded(false)
            executor.async { window.runtime.frames.runLoopTurn(.beforeWaiting); done.access { $0 = true } }
            t.check(AppSelfTest.spin(timeout: 30) { done.current })
            let missingFailure: SkinFrameProducer.LayerFailure? = executor.exclusive(timeout: 30) { window.runtime.frames.layerFailure } ?? nil
            t.equal(missingFailure, .missingProfile)
            let retained: [CGImage]? = executor.exclusive(timeout: 30) { window.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image) } ?? nil
            t.check(sameImages(original, retained), "nil facts do not substitute sRGB or clear the last actual frame")
            t.check(window.content.installedLayerRoot === root)
            window.publishFacts(force: true)
            // The explicit negative fixture's sequence is superseded with another explicit fact, not a fake host ack.
            var valid = window.facts
            valid.sequence = missing.sequence + 1
            window.runtime.send(.windowFacts(valid))
            window.runtime.send(.redraw)
            done.access { $0 = false }
            executor.async { window.runtime.frames.runLoopTurn(.beforeWaiting); done.access { $0 = true } }
            t.check(AppSelfTest.spin(timeout: 30) { done.current })
            let recoveredFailure: SkinFrameProducer.LayerFailure? = executor.exclusive(timeout: 30) { window.runtime.frames.layerFailure } ?? nil
            t.equal(recoveredFailure, nil)
            let beforeBudget: [CGImage]? = executor.exclusive(timeout: 30) { window.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image) } ?? nil
            // A genuine scene resize exceeds the explicitly selected C budget. The owned builder rejects before
            // allocating the large backing; the successful old root/images remain, rather than an empty success.
            window.runtime.send(.run("[!SetOption Back Shape \"Rectangle 0,0,1024,1024 | Fill Color 31,89,151,100 | StrokeWidth 0\"][!UpdateMeter Back][!Redraw]"))
            done.access { $0 = false }
            executor.async { window.runtime.frames.runLoopTurn(.beforeWaiting); done.access { $0 = true } }
            t.check(AppSelfTest.spin(timeout: 30) { done.current })
            t.equal(executor.exclusive(timeout: 30) { window.runtime.skin.width }, 1024,
                    "the original dynamic-window-size contract delivers the large scene to C")
            t.equal(executor.exclusive(timeout: 30) { window.runtime.skin.height }, 1024)
            let allocationFailure = executor.exclusive(timeout: 30) { () -> Bool in
                guard case .some(.rendering(_)) = window.runtime.frames.layerFailure else { return false }
                return sameImages(window.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image), beforeBudget)
            }
            t.equal(allocationFailure, true, "actual C allocation failure retains every old immutable image")
            t.check(window.content.installedLayerRoot === root)
            window.runtime.send(.run("[!SetOption Back Shape \"Rectangle 0,0,48,32 | Fill Color 31,89,151,100 | StrokeWidth 0\"][!UpdateMeter Back][!Redraw]"))
            done.access { $0 = false }
            executor.async { window.runtime.frames.runLoopTurn(.beforeWaiting); done.access { $0 = true } }
            t.check(AppSelfTest.spin(timeout: 30) { done.current })
            t.equal(executor.exclusive(timeout: 30) { window.runtime.skin.width }, 48)
            t.equal(executor.exclusive(timeout: 30) { window.runtime.skin.height }, 32)
            let finalFailure: SkinFrameProducer.LayerFailure? = executor.exclusive(timeout: 30) { window.runtime.frames.layerFailure } ?? nil
            t.equal(finalFailure, nil,
                    "a later valid scene recovers without resetting or replacing the live skin")
            let beforeClose: [CGImage]? = executor.exclusive(timeout: 30) { window.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image) } ?? nil
            window.runtime.send(.close(fadeOut: true))
            t.check(AppSelfTest.spin(timeout: 30) { window.runtime.didClose })
            let closing = executor.exclusive(timeout: 30) { () -> Bool in
                let owner = window.runtime.frames.layerRuntime
                return owner?.state == .closing && sameImages(owner?.currentFrame?.contents.map(\.image), beforeClose)
            }
            // Compare the now-current images as well: the recovery above may legitimately redraw the old picture.
            let state: LayerRuntime.State? = executor.exclusive(timeout: 30) { window.runtime.frames.layerRuntime?.state } ?? nil
            t.equal(state, .closing)
            t.check(closing == true && window.content.installedLayerRoot === root,
                    "owner beginClose retains its last tree while main still needs the fade/replacement picture")
            window.runtime.teardownContent()
            t.check(AppSelfTest.spin(timeout: 30) { window.content.state.tornDown }, "cleanup begins only after main finishes displaying it")
            t.check(window.content.installedLayerRoot == nil)
            t.equal(executor.exclusive(timeout: 30) { window.runtime.frames.layerRuntime == nil }, true)
        }
    }

    private static func firstFrameTests(_ t: AppTestRunner) {
        t.suite("App: layer window content: failed first C frame retains the replaced window until actual recovery and installation") {
            let app = try app(t, threading: .engine)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let old = try activate(app, t)
            prepareWindow(old, t)
            let oldRoot = old.content.installedLayerRoot
            t.check(oldRoot != nil && old.content.hasLayerFrame)
            let oversized = text.replacingOccurrences(of: "Rectangle 0,0,48,32", with: "Rectangle 0,0,1024,1024")
            try oversized.write(to: old.fileURL, atomically: true, encoding: .utf8)
            guard let replacement = app.activate(config: "App\\LayerContent", file: "Test.ini") else {
                return t.check(false, "actual asynchronous replacement is created")
            }
            replacement.window.colorSpace = .sRGB
            replacement.publishFacts(force: true)
            t.check(AppSelfTest.spin(timeout: 30) {
                replacement.isLoaded && replacement.runtime.exclusive { _ -> Bool in
                    if case .some(.rendering(_)) = replacement.runtime.frames.layerFailure { return true }
                    return false
                } == true
            }, "first native C preparation/build actually fails within the explicit byte budget")
            t.check(replacement.isStarting && !replacement.isStarted, "loaded does not report started before a finished root installs")
            t.check(replacement.content.installedLayerRoot == nil)
            t.check(old.isKeptForReplacement && !old.content.state.tornDown && old.content.installedLayerRoot === oldRoot,
                    "actual AppController refresh retains the old window and provider")
            t.check(old.runtime.didClose, "the old owner's close acknowledgment is complete before freezing its last frame")
            let oldImages: [CGImage]? = old.runtime.exclusive(timeout: 30) { _ in old.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image) } ?? nil
            let oldState: LayerRuntime.State? = old.runtime.exclusive(timeout: 30) { _ in old.runtime.frames.layerRuntime?.state } ?? nil
            t.equal(oldState, .closing)
            t.check(oldImages?.isEmpty == false, "the actual last closing frame is nonempty")
            // A frame requested before stop may finish before beginClose. The frozen reference is the acknowledged
            // LAST frame, not an earlier main-thread observation. Another failed replacement draw must retain it.
            let attempted = Guarded(false)
            replacement.runtime.executor.async {
                replacement.runtime.frames.drawFirstFrame()
                attempted.access { $0 = true }
            }
            t.check(AppSelfTest.spin(timeout: 30) { attempted.current }, "another failed first-frame attempt completed on the owner")
            t.equal(old.runtime.exclusive(timeout: 30) { _ in
                sameImages(old.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image), oldImages)
            }, true, "beginClose retains every old immutable image until the replacement is actually ready")
            replacement.runtime.send(.run("[!SetOption Back Shape \"Rectangle 0,0,48,32 | Fill Color 31,89,151,100 | StrokeWidth 0\"][!UpdateMeter Back][!Redraw]"))
            t.check(AppSelfTest.spin(timeout: 30) { replacement.isStarted && replacement.content.hasLayerFrame },
                    "a later valid scene obtains the real main install acknowledgment and completes the start")
            t.equal(replacement.view.bounds.size, CGSize(width: 48, height: 32), "the obsolete load size is not restored after recovery")
            t.equal(replacement.contentMode, mode, "the actual replacement inherited the selection")
            t.check(AppSelfTest.spin(timeout: 30) { old.content.state.tornDown }, "only successful installation retires the old provider")
            t.check(old.content.installedLayerRoot == nil)
        }
    }

    private static func sameImages(_ a: [CGImage]?, _ b: [CGImage]?) -> Bool {
        guard let a, let b, a.count == b.count else { return false }
        return zip(a, b).allSatisfy { $0.0 === $0.1 }
    }

    /// Only delivery is held. The production runtime still prepares, waits/reclaims and applies on real threads.
    private final class PatchGate: SkinRuntimeWindow {
        let window: SkinWindowController
        var withheld: [SkinScenePatch] = []
        var holds = true
        var callbacksOnMain = true
        var ordinaryGenerations: [UInt64] = []
        init(_ window: SkinWindowController) { self.window = window }
        func apply(_ request: SkinRequest, from runtime: SkinRuntime) {
            if case .layerHitMap(_, let generation, _) = request { ordinaryGenerations.append(generation) }
            if case .scenePatch(let patch) = request, holds {
                callbacksOnMain = callbacksOnMain && Thread.isMainThread
                withheld.append(patch)
                return
            }
            window.apply(request, from: runtime)
        }
        func batchingWindowChanges(_ body: () -> Void) { window.batchingWindowChanges(body) }
        func liveEnvironment(for skin: Skin) -> SkinEnvironment? { window.liveEnvironment(for: skin) }
        var liveTakesPointer: Bool? { window.liveTakesPointer }
    }

    private static func ownerWork(_ executor: SkinThreadExecutor, _ t: AppTestRunner,
                                  _ body: @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        executor.async { body(); done.signal() }
        t.check(done.wait(timeout: .now() + .seconds(30)) == .success, "real owner work reaches its completion fence")
    }

    private static func resizeRecipe(_ window: SkinWindowController, _ width: Int, _ left: Int) {
        window.runtime.skin.execute("[!SetOption Back Shape \"Rectangle 0,0,\(width),32 | Fill Color 31,89,151,100 | StrokeWidth 0\"][!SetVariable Left \(left)][!UpdateMeter *][!Redraw]", from: nil)
        window.runtime.frames.runLoopTurn(.beforeWaiting)
    }

    private static func checkCurrentTree(_ window: SkinWindowController, _ width: Int, _ t: AppTestRunner) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return t.check(false, "native Metal qualification is required") }
        let renderer = try OffscreenRenderer(width: width, height: 32, device: device,
                                            maximumReadbackBytes: width * 32 * 4)
        let comparison = window.runtime.exclusive(timeout: 30) { skin -> Result<Bool, Error> in
            Result {
                guard let frame = window.runtime.frames.layerRuntime?.currentFrame, let tree = window.view.layer else {
                    throw CocoaError(.coderReadCorrupt)
                }
                let context = SkinRenderContext.of(skin), frames = window.runtime.frames
                let environment = AppSceneEnvironment(scale: Double(frames.scale), appearance: .light,
                                                       appearanceName: frames.appearance)
                let scene = context.sceneProjector.project(skin, environment: environment, glassSource: .published)
                let builder = try LayerContentBuilder(plan: SinglePartition.plan(in: frame.plan.window),
                    scale: frame.scale, colorSpace: frame.colorSpace, maximumOwnedBitmapBytes: 1_000_000)
                guard let reference = try builder.build(scene, context: context.drawing, cycle: skin.updateCount,
                                                        glass: .hitArea).first else { throw CocoaError(.coderReadCorrupt) }
                let single = singleTree(reference, scale: frame.scale, size: CGSize(width: width, height: 32))
                let expected = try renderer.render(single, at: 0, deadline: .now() + .seconds(30))
                let actual = try renderer.render(tree, at: 0, deadline: .now() + .seconds(30))
                return actual.rgba == expected.rgba && stride(from: 3, to: actual.rgba.count, by: 4).contains { actual.rgba[$0] > 0 }
            }
        }
        t.check(comparison != nil, "native readback holds the real owner lease after ack")
        if let comparison { t.check(try comparison.get(), "installed actual tree equals independent fresh Single bytes with nonempty alpha") }
        t.check(renderer.hasVerifiedCanary, "native readback retains the original canary and fence")
    }

    private static func patchReclaimTests(_ t: AppTestRunner) {
        t.suite("App: layer window content: real pending reclaim keeps host debt until latest apply and rejects old panels") {
            let app = try app(t, threading: .engine)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try activate(app, t)
            prepareWindow(window, t)
            guard let executor = window.runtime.executor as? SkinThreadExecutor else { return t.check(false, "real worker required") }
            let gate = PatchGate(window)
            window.runtime.window = gate
            defer {
                gate.holds = false
                for patch in gate.withheld { _ = patch.content.reclaim(.invalidated); window.apply(.scenePatch(patch), from: window.runtime) }
                window.runtime.window = window
            }
            ownerWork(executor, t) { resizeRecipe(window, 60, 12) }
            t.check(AppSelfTest.spin(timeout: 30) { gate.withheld.count >= 1 }, "real main delivery reaches the held patch")
            guard let old = gate.withheld.first else { return }
            t.equal(old.content.state, .reclaimedBySkin)
            t.equal(old.content.reclamation, .timeout, "actual unclaimed deadline, not a scripted discard")
            t.equal(window.view.bounds.size, CGSize(width: 48, height: 32), "owner fallback has not pretended to resize the host")
            let progressed = window.runtime.exclusive(timeout: 30) { _ in
                window.runtime.frames.layerRuntime?.currentFrame?.plan.window.width == Int(60 * window.runtime.frames.scale)
            }
            t.equal(progressed, true, "owner submits completed native content and continues after pending reclaim")
            ownerWork(executor, t) { resizeRecipe(window, 48, 4) }
            t.check(AppSelfTest.spin(timeout: 30) { gate.ordinaryGenerations.contains { $0 > old.generation } },
                    "a REAL newer ordinary frame publishes the already-correct host size")
            t.equal(gate.withheld.count, 1, "returning to acknowledged host geometry does not request another main frame")
            window.apply(.scenePatch(old), from: window.runtime)
            t.equal(old.hostAcknowledgment, .none, "late main delivery cannot roll a newer ordinary frame back to old geometry")
            t.equal(window.view.bounds.size, CGSize(width: 48, height: 32))
            ownerWork(executor, t) {}
            try checkCurrentTree(window, 48, t)
            gate.withheld.removeAll()
            ownerWork(executor, t) { resizeRecipe(window, 60, 12) }
            t.check(AppSelfTest.spin(timeout: 30) { gate.withheld.count == 1 }, "a new host debt really reaches main")
            ownerWork(executor, t) { resizeRecipe(window, 60, 4) }
            t.check(AppSelfTest.spin(timeout: 30) { gate.withheld.count >= 2 }, "latest content still carries the unacknowledged host size")
            guard gate.withheld.count >= 2 else { return }
            let latest = gate.withheld.last!
            t.check(latest.generation > old.generation)
            // Reverse delivery is intentional: an old, reclaimed packet must not roll back the latest host.
            window.apply(.scenePatch(latest), from: window.runtime)
            window.apply(.scenePatch(old), from: window.runtime)
            t.equal(window.view.bounds.size, CGSize(width: 60, height: 32))
            ownerWork(executor, t) {}
            try checkCurrentTree(window, 60, t)
            gate.withheld.removeAll()

            ownerWork(executor, t) { resizeRecipe(window, 70, 12) }
            t.check(AppSelfTest.spin(timeout: 30) { !gate.withheld.isEmpty }, "old-panel patch really arrived")
            guard let stale = gate.withheld.first else { return }
            let panel = window.window, generation = window.panelGeneration
            ownerWork(executor, t) { window.runtime.skin.execute("[!ClickThrough 1][!ClickThrough 0]", from: nil) }
            t.check(AppSelfTest.spin(timeout: 30) { window.panelGeneration > generation }, "actual ClickThrough replaces the panel at an owner safe point")
            t.check(window.window !== panel)
            window.window.colorSpace = .sRGB
            window.publishFacts(force: true)
            window.apply(.scenePatch(stale), from: window.runtime)
            t.equal(stale.hostAcknowledgment, .none, "stale panel does not acknowledge or mutate the new host")
            gate.holds = false
            for patch in gate.withheld { window.apply(.scenePatch(patch), from: window.runtime) }
            gate.withheld.removeAll()
            window.runtime.send(.frameWanted)
            t.check(AppSelfTest.spin(timeout: 30) { window.view.bounds.size.width == 70 }, "new panel receives a qualified current scene")
            ownerWork(executor, t) {}
            try checkCurrentTree(window, 70, t)
            t.check(gate.callbacksOnMain)
        }
    }

    private static func patchClaimTests(_ t: AppTestRunner) {
        t.suite("App: layer window content: claimed main writer survives deadline while owner logic coalesces then closes") {
            let app = try app(t, threading: .engine)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try activate(app, t)
            prepareWindow(window, t)
            guard let executor = window.runtime.executor as? SkinThreadExecutor else { return t.check(false, "real worker required") }
            var claimed: SkinScenePatch?
            var sawMain = false, sawWriter = false, sawOwnerProgress = false, guardRejected = false
            let result = Guarded<(Bool, Bool, Bool)?>(nil)
            window.willApplyScenePatch = { patch in
                guard claimed == nil else { return }
                claimed = patch
                sawMain = Thread.isMainThread && !executor.isCurrent && !executor.isOnThread
                let oldChildren = patch.content.root.sublayers ?? []
                let progressed = DispatchSemaphore(value: 0)
                executor.async {
                    let frames = window.runtime.frames
                    let writer = frames.hasLayerWriter && frames.layerRuntime?.hasTransferredWriter == true
                    var rejected = false
                    do { try frames.layerRuntime?.close() }
                    catch LayerRuntime.Failure.transferredWriter { rejected = true }
                    catch {}
                    window.runtime.skin.execute("[!SetVariable Left 4][!UpdateMeter *][!Redraw]", from: nil)
                    frames.runLoopTurn(.beforeWaiting)
                    result.access { $0 = (writer, frames.needsFrame, rejected) }
                    progressed.signal()
                }
                t.check(progressed.wait(timeout: .now() + .seconds(30)) == .success,
                        "actual worker leaves its 50ms wait and executes a canary while main retains the claim")
                if let observed = result.current { sawWriter = observed.0; sawOwnerProgress = observed.1; guardRejected = observed.2 }
                t.equal(patch.content.state, .applying)
                t.check(!patch.content.reclaim(.timeout), "deadline cannot steal an applying writer")
                t.check(zip(oldChildren, patch.content.root.sublayers ?? []).allSatisfy { $0.0 === $0.1 }
                        && oldChildren.count == patch.content.root.sublayers?.count,
                        "owner progress has not cleared, replaced or redrawn the shared tree")
            }
            defer { window.willApplyScenePatch = nil }
            window.runtime.send(.run("[!SetOption Back Shape \"Rectangle 0,0,60,32 | Fill Color 31,89,151,100 | StrokeWidth 0\"][!SetVariable Left 12][!UpdateMeter *][!Redraw]"))
            t.check(AppSelfTest.spin(timeout: 30) { claimed?.content.state == .appliedByMain }, "real main callback completes and releases the writer")
            t.check(sawMain && sawWriter && sawOwnerProgress && guardRejected,
                    "tree-only claim leaves executor ownership on worker, and owner mutations remain guarded")
            window.willApplyScenePatch = nil
            ownerWork(executor, t) {}
            t.check(AppSelfTest.spin(timeout: 30) { window.runtime.exclusive(timeout: 0.25) { _ in !window.runtime.frames.hasLayerWriter } == true }, "late ack returns the writer and drains coalesced latest content")
            ownerWork(executor, t) {}
            try checkCurrentTree(window, 60, t)
            t.equal(window.runtime.exclusive(timeout: 30) { skin in skin.variable("Left") }, "4", "latest logical value survives the main claim")

            var closeClaimed = false
            window.willApplyScenePatch = { patch in
                guard !closeClaimed else { return }
                closeClaimed = true
                window.stop(fadeOut: false)
                let reached = DispatchSemaphore(value: 0)
                executor.async { reached.signal() }
                t.check(reached.wait(timeout: .now() + .seconds(30)) == .success, "owner close/cleanup work continues while main owns writer")
                t.equal(patch.content.state, .applying)
                t.check(window.content.installedLayerRoot != nil, "main teardown has not detached an applying root")
            }
            window.runtime.send(.run("[!SetOption Back Shape \"Rectangle 0,0,70,32 | Fill Color 31,89,151,100 | StrokeWidth 0\"][!UpdateMeter *][!Redraw]"))
            t.check(AppSelfTest.spin(timeout: 30) { closeClaimed && window.content.state.tornDown }, "released writer ack completes deferred close and actual main removal")
            t.check(window.content.installedLayerRoot == nil)
            t.equal(window.runtime.exclusive(timeout: 30) { _ in window.runtime.frames.layerRuntime == nil }, true)
            window.willApplyScenePatch = nil
        }
    }

    /// Actual host values, including nonempty glass and tooltip regions. The native readback observes only C hit
    /// content under SkinView, not NSGlassEffectView/NSVisualEffectView pixels or a live desktop background.
    private static func hostValueTests(_ t: AppTestRunner) {
        let card = """

        [GlassCard]
        Meter=Image
        X=#Left#
        Y=18
        W=10
        H=10
        DynamicVariables=1
        MacGlass=Regular
        MacGlassCornerRadius=2
        ToolTipTitle=Frame
        ToolTipText=Card #Left#
        LeftMouseUpAction=[!SetVariable Selected 1]
        """
        for (threading, label) in [(SkinThreading.main, "MainSkinExecutor"), (.engine, "SkinThreadExecutor")] {
            t.suite("App: layer window host values: \(label) presents glass tooltips and C content through A/B/A") {
                let app = try app(t, threading: threading, source: text + "\n" + card)
                defer { app.stopAllForTermination(); app.endEngineThread() }
                let window = try activate(app, t)
                prepareWindow(window, t)
                let executor = window.runtime.executor
                if threading == .main {
                    t.check(executor === MainSkinExecutor.shared && executor.isCurrent && Thread.isMainThread,
                            "the real main executor owns this opt-in skin")
                } else {
                    t.check(executor is SkinThreadExecutor && !executor.isCurrent,
                            "the actual worker owns this opt-in skin outside a lease")
                }
                var patches: [SkinScenePatch] = []
                var insideMainDraw = false, inlineClaims = 0, auditedResizes = 0
                window.willApplyScenePatch = { patch in
                    t.check(Thread.isMainThread && patch.content.state == .applying,
                            "the actual native callback claims before host or tree mutation")
                    t.check(patch.content.isMainWriter(for: patch.content.root))
                    t.equal(executor.isCurrent, threading == .main,
                            "a tree writer never changes the executor's actual ownership")
                    if threading == .main, insideMainDraw { inlineClaims += 1 }
                    #if DEBUG
                    if threading == .main {
                        t.check(window.runtime.model.frame?.size != window.window.frame.size,
                                "the real main claim observes the logical resize before host acknowledgment")
                        let skin = window.runtime.skin!
                        var reported: [String] = []
                        SnapshotAudit.capturing({ reported.append($0) }) {
                            let env = window.runtime.environment(for: skin)
                            t.equal(env.windowFrame.width, Double(patch.size.width), "the returned logical environment keeps the new size")
                        }
                        t.equal(reported, [], "only the known pending resize is reconciled for comparison")
                        let z = app.state.skin(window.config)?.alwaysOnTop ?? 0
                        app.state.update(window.config) { $0.alwaysOnTop = z == 0 ? 1 : 0 }
                        defer { app.state.update(window.config) { $0.alwaysOnTop = z } }
                        SnapshotAudit.capturing({ reported.append($0) }) {
                            t.equal(window.runtime.environment(for: skin).zPosition, z,
                                    "an unrelated live-state discrepancy cannot alter the returned model")
                        }
                        t.check(reported.count == 1 && reported[0].contains("environment") && reported[0].contains("zPosition"),
                                "the pending resize still reports a real Z-position discrepancy: \(reported)")
                        auditedResizes += 1
                    }
                    #endif
                    patches.append(patch)
                }
                defer { window.willApplyScenePatch = nil }

                for (index, state) in [(48, 4, GlassStyle.regular), (60, 12, .clear), (48, 4, .regular)].enumerated() {
                    let (width, left, style) = state
                    if index > 0 {
                        let count = patches.count, inlineBefore = inlineClaims
                        let update = {
                            window.runtime.skin.execute("[!SetOption GlassCard MacGlass \(style == .clear ? "Clear" : "Regular")]", from: nil)
                            resizeRecipe(window, width, left)
                        }
                        if threading == .main {
                            insideMainDraw = true
                            let completed = window.runtime.exclusive(timeout: 30) { _ -> Bool in
                                update()
                                return !window.runtime.frames.hasLayerWriter
                            }
                            insideMainDraw = false
                            t.equal(completed, true, "the real main draw completes its writer ack before returning")
                            t.equal(inlineClaims, inlineBefore + 1, "the main opt-in callback applied inline, without a worker wait")
                        } else {
                            let done = Guarded(false)
                            executor.async { update(); done.access { $0 = true } }
                            t.check(AppSelfTest.spin(timeout: 30) { done.current && patches.count > count },
                                    "real worker drawing and main claim complete while the run loop is served")
                        }
                        t.equal(patches.count, count + 1, "one coherent host patch presents each changed frame")
                        t.check(AppSelfTest.spin(timeout: 30) {
                            window.runtime.exclusive(timeout: 0.25) { _ in !window.runtime.frames.hasLayerWriter } == true
                        }, "the actual owner receives the completed main ack")
                        guard let patch = patches.last else { return t.check(false, "a real captured patch is required") }
                        t.equal(patch.content.state, .appliedByMain, "this is a main-claimed positive control, not reclaimed fallback")
                        t.equal(patch.hostAcknowledgment, .complete)
                        t.equal(patch.size, CGSize(width: width, height: 32))
                        t.equal(patch.hitMap.toolTipAreas, [SkinRect(x: Double(left), y: 18, width: 10, height: 10)])
                    }
                    let rect = SkinRect(x: Double(left), y: 18, width: 10, height: 10)
                    let expectedGlass = [GlassRegion(id: "GlassCard", rect: rect, cornerRadius: 2, style: style)]
                    t.equal(window.glass.regions, expectedGlass, "literal nonempty glass values match the presented frame")
                    t.equal(window.glass.shownPieces.map { $0.frameView.frame }, [rect.cgRect], "real AppKit glass frames follow A/B/A")
                    t.equal(window.contentView.subviews, window.glass.shownPieces.map(\.frameView) + [window.view],
                            "the actual glass stays behind the C view")
                    t.equal(window.view.bounds.size, CGSize(width: width, height: 32))
                    t.equal(window.window.frame.size, CGSize(width: width, height: 32))
                    t.equal(window.content.installedLayerRoot?.bounds, CGRect(x: 0, y: 0, width: width, height: 32))
                    t.equal(window.view.toolTipRects, [rect.cgRect], "nonempty registered tooltip areas follow the presented frame")
                    t.equal(window.view.toolTipText(x: Double(left + 5), y: 23), "Frame\nCard \(left)")
                    let outside = left == 4 ? 17.0 : 5.0
                    t.equal(window.view.toolTipText(x: outside, y: 23), nil, "old or outside card coordinates have no presented tooltip")
                    t.check(SkinView.hasAction(window, .leftUp, x: Double(left + 5), y: 23), "presented glass has its captured action")
                    t.check(!SkinView.hasAction(window, .leftUp, x: outside, y: 23), "captured hit map rejects the old or outside coordinates")
                    t.equal(window.runtime.snapshot.glass, expectedGlass)
                    t.equal(window.runtime.snapshot.toolTipAreas, [rect.cgRect])
                    let submitted = window.runtime.exclusive(timeout: 30) { _ -> Bool in
                        let frames = window.runtime.frames
                        return frames.layerInstalled && frames.layerFailure == nil && !frames.hasLayerWriter
                            && frames.lastLayerDrawWasOnSkinThread == (threading != .main)
                    }
                    t.equal(submitted, true, "the appropriate real drawing owner has submitted the same C frame")
                    if index > 0 { t.equal(patches.last?.glass, expectedGlass) }
                    try checkCurrentTree(window, width, t)
                }
                #if DEBUG
                if threading == .main {
                    t.equal(auditedResizes, 2, "both actual main resize claims exercised the audit controls")
                    auditResizeMapping(t)
                    let frame = window.window.frame, delegate = window.window.delegate
                    let facts = window.runtime.model.facts
                    var reported: [String] = []
                    SnapshotAudit.capturing({ reported.append($0) }) {
                        // The existing window-model negative control: a real move with no facts publication.
                        window.window.delegate = nil
                        defer { window.window.setFrame(frame, display: false); window.window.delegate = delegate }
                        window.window.setFrameOrigin(CGPoint(x: frame.minX + 33, y: frame.minY))
                        _ = window.runtime.environment(for: window.runtime.skin)
                    }
                    t.equal(window.runtime.model.facts, facts, "the unannounced move did not replace the acknowledged facts")
                    t.check(reported.count == 1 && reported[0].contains("environment") && reported[0].contains("window model"),
                            "after acknowledgment, a real geometry mismatch remains audited: \(reported)")
                    t.equal(window.runtime.environment(for: window.runtime.skin), window.environment,
                            "restoring the actual panel restores full environment equality")
                }
                #endif
                let root = window.content.installedLayerRoot
                t.check(root != nil)
                window.stop(fadeOut: false)
                t.check(AppSelfTest.spin(timeout: 30) { window.content.state.tornDown }, "actual close receives owner cleanup and main removal")
                t.check(window.content.installedLayerRoot == nil && root?.superlayer == nil)
                t.check(root?.sublayers?.isEmpty != false, "closed owner releases all C image children")
                t.equal(window.runtime.exclusive(timeout: 30) { _ in window.runtime.frames.layerRuntime == nil }, true)
                t.check(!window.window.isVisible)
                t.equal(window.view.toolTipText(x: 9, y: 23), nil, "the closed host cannot expose its last tooltip")
            }
        }
    }

    #if DEBUG
    private static func auditResizeMapping(_ t: AppTestRunner) {
        // A controlled two-screen geometry check, separate from the real one-window native controls above.
        let screens = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 100, y: 0, width: 100, height: 100)]
            .map { WindowGeometry.Screen(frame: $0, visibleFrame: $0) }
        var settings = SkinWindowSettings()
        settings.keepOnScreen = false
        settings.autoSelectScreen = true
        let old = CGRect(x: 90, y: 68, width: 20, height: 32), new = CGRect(x: 90, y: 68, width: 60, height: 32)
        let facts = SkinWindowFacts(frame: old, isVisible: true, isOrderedIn: true, scale: 2,
                                    takesPointer: true, settings: settings, sequence: 1)
        var model = SkinWindowModel()
        model.take(facts)
        model.resize(to: new.size, screens: screens)
        t.equal(model.frame, new)
        t.equal(WindowGeometry.screenIndex(for: old, screens: screens), 0, "the equal-overlap tie initially selects primary")
        t.equal(WindowGeometry.screenIndex(for: new, screens: screens), 1, "the actual resize selects the second screen")
        func env(_ frame: CGRect, _ selected: Int) -> SkinEnvironment {
            var value = EnvironmentStore.environment(windowFrame: frame, screens: screens, settingsPath: "test/",
                programPath: "test/", configEditor: "test", appearance: .light)
            value.currentScreen = selected
            return value
        }
        let before = env(old, 0), after = env(new, 1)
        func compared(_ live: SkinEnvironment, _ snapshot: SkinEnvironment = after,
                      _ current: SkinWindowModel = model, _ size: CGSize? = new.size,
                      _ layers: Bool = true) -> SkinEnvironment {
            SkinRuntime.environmentForAudit(live, snapshot: snapshot, model: current,
                requestedSize: size, usesLayers: layers, screens: screens)
        }
        t.equal(compared(before), after, "only the derived frame and selected screen are reconciled")
        var z = before
        z.zPosition = 1
        var expected = after
        expected.zPosition = 1
        t.equal(compared(z), expected, "Z-position discrepancies survive the comparison adjustment")
        var moved = before
        moved.windowFrame.x += 1
        t.equal(compared(moved), moved, "unannounced geometry is never reconciled")
        var wrongScreen = before
        wrongScreen.currentScreen = 1
        t.equal(compared(wrongScreen), wrongScreen, "an unexpected live screen is never reconciled")
        var wrongSnapshot = after
        wrongSnapshot.currentScreen = 0
        t.equal(compared(before, wrongSnapshot), before, "an incorrect future selection is not concealed")
        t.equal(compared(before, after, model, new.size, false), before, "the bitmap audit is unchanged")
        t.equal(compared(before, after, model, nil), before, "no requested resize means no known comparison debt")
        t.equal(compared(before, after, model, CGSize(width: 80, height: 32)), before, "the model must match the exact requested resize")
        var changed = model
        changed.settings.zPosition = 1
        t.equal(compared(before, after, changed), before, "unacknowledged settings are not resize-only debt")
        var acknowledged = model
        var ack = facts
        ack.frame = new
        ack.sequence = 2
        acknowledged.take(ack)
        t.equal(compared(before, after, acknowledged), before, "acknowledged geometry is fully audited")
    }
    #endif

    private static func singleTree(_ content: LayerContentBuilder.Content, scale: CGFloat,
                                   size: CGSize = CGSize(width: 48, height: 32)) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let tree = CALayer(), image = CALayer()
        tree.anchorPoint = .zero
        tree.bounds = CGRect(origin: .zero, size: size)
        tree.isGeometryFlipped = true
        image.anchorPoint = .zero
        image.frame = tree.bounds
        image.contents = content.image
        image.contentsScale = scale
        image.contentsGravity = .resize
        image.minificationFilter = .nearest
        image.magnificationFilter = .nearest
        tree.addSublayer(image)
        return tree
    }
}
