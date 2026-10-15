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
        #if DEBUG
        patchClaimTests(t)
        hostValueTests(t)
        #endif
        eWindowQualificationTests(t)
        nativeStagingTests(t)
        nativeStagingControlTests(t)
        nativeStagingStopTests(t)
        nativeStagingUnexpectedCallbackTests(t)
        nativePublicationTests(t)
        nativeFrameTests(t)
        nativeComponentTests(t)
        automaticBackendTests(t)
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
            // Explicit malformed facts are a negative fixture, not a claim that this real window lacks a profile.
            var missing = window.facts
            missing.colorSpace = nil
            missing.sequence += 10
            let observed = Guarded<(before: [CGImage]?, after: [CGImage]?, failure: SkinFrameProducer.LayerFailure?)>((nil, nil, nil))
            let done = Guarded(false)
            executor.async {
                // Finish any requested normal frame before sampling. Keep this observation and the nil-profile
                // attempt in one physical worker task: a normal redraw between separate parks may change identity.
                window.runtime.frames.runLoopTurn(.beforeWaiting)
                let before = window.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image)
                window.runtime.send(.windowFacts(missing))
                window.runtime.send(.redraw)
                window.runtime.frames.runLoopTurn(.beforeWaiting)
                observed.access {
                    $0 = (before, window.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image),
                          window.runtime.frames.layerFailure)
                }
                done.access { $0 = true }
            }
            t.check(AppSelfTest.spin(timeout: 30) { done.current })
            let (original, retained, missingFailure) = observed.current
            t.check(original != nil)
            t.equal(missingFailure, .missingProfile)
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

    #if DEBUG
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

    #endif

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

    /// Native qualification only: a separate E subtree is attached to an actual, never-ordered window.
    /// The window's C provider remains installed; this does not select E as its production delivery mode.
    private static func eWindowQualificationTests(_ t: AppTestRunner) {
        t.suite("App: layer window E qualification: actual window profile and worker CA callbacks agree with C Single") {
            let app = try app(t, threading: .engine)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            // The usual activate helper intentionally sets sRGB. Here the actual window supplies its profile.
            guard let window = app.activate(config: "App\\LayerContent", file: "Test.ini", contentMode: mode),
                  let executor = window.runtime.executor as? SkinThreadExecutor else {
                return t.check(false, "actual window and physical worker are required")
            }
            t.check(AppSelfTest.spin(timeout: 30) { window.isStarted }, "actual C activation finishes before E qualification")
            window.pauseUpdates()
            window.visibilityForTesting = true
            window.publishFacts(force: true)
            window.runtime.send(.firstFrame)
            window.runtime.send(.frameWanted)
            t.check(AppSelfTest.spin(timeout: 30) { window.content.installedLayerRoot != nil }, "the existing C frame is installed")
            let facts = window.facts, size = window.view.bounds.size
            guard let space = facts.colorSpace, space.model == .rgb, let viewLayer = window.view.layer,
                  let device = MTLCreateSystemDefaultDevice(), size == CGSize(width: 48, height: 32) else {
                return t.check(false, "actual RGB profile, known logical size and native Metal are required")
            }
            let scale = facts.scale
            let w = (size.width * scale).rounded(.up), h = (size.height * scale).rounded(.up)
            guard scale.isFinite, scale > 0, w.isFinite, h.isFinite,
                  w > 0, h > 0, w <= CGFloat(Rasterizer.maximumDimension), h <= CGFloat(Rasterizer.maximumDimension),
                  let rect = InkBounds.DeviceRect(minX: 0, minY: 0, maxX: Int(w), maxY: Int(h)) else {
                return t.check(false, "actual window device geometry qualifies without inventing a scale")
            }
            let plan = SinglePartition.plan(in: rect)
            var owner: ELayerContent?
            let created = Guarded<Result<(CALayer, ELayerContent.CallbackReport, Bool), Error>?>(nil)
            executor.async {
                created.access { value in value = Result {
                    let e = try ELayerContent(plan: plan, scale: scale, colorSpace: space,
                        maximumBaseBitmapBytes: 1_000_000, maximumCallbackBitmapBytes: 1_000_000, executor: executor)
                    owner = e
                    return (e.root, e.callbackReport, executor.isOnThread && SkinThreadExecutor.isSkinThread && !Thread.isMainThread)
                } }
            }
            t.check(AppSelfTest.spin(timeout: 30) { created.current != nil }, "the real worker creates the E owner")
            guard let creation = created.current else { return }
            let (root, report, createdOnWorker) = try creation.get()
            t.check(createdOnWorker)
            let host = CALayer()
            defer {
                let cleaned = executor.exclusive(timeout: 30) { () -> Bool in
                    t.check(Thread.isMainThread && executor.isCurrent && !executor.isOnThread,
                            "actual owner lease fences E cleanup before main detachment")
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    host.removeFromSuperlayer()
                    root.removeFromSuperlayer()
                    owner = nil
                    CATransaction.commit()
                    return true
                }
                t.equal(cleaned, true, "bounded real owner cleanup and main detach complete")
            }
            let attached = executor.exclusive(timeout: 30) { () -> Bool in
                guard !window.runtime.frames.hasLayerWriter, owner?.root === root else { return false }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                host.anchorPoint = .zero
                host.position = .zero
                host.bounds = CGRect(origin: .zero, size: size)
                // SkinView already supplies an implicit flip. Unlike C's image wrapper, a native-drawing
                // subtree must inherit that flip once; another explicit flip cancels the callback's y-down map.
                host.isGeometryFlipped = false
                host.contentsFormat = .RGBA8Uint
                host.addSublayer(root)
                viewLayer.addSublayer(host)
                CATransaction.commit()
                let c = window.content.installedLayerRoot
                let leaf = root.sublayers?.first
                print("E-WINDOW hierarchy viewFlipped=\(window.view.isFlipped)")
                let hierarchy: [(String, CALayer?)] = [("viewLayer", viewLayer), ("provider", c?.superlayer),
                    ("Croot", c), ("host", host), ("Eroot", root), ("leaf", leaf)]
                for (name, layer) in hierarchy {
                    print("E-WINDOW hierarchy \(name) geometryFlipped=\(String(describing: layer?.isGeometryFlipped)) contentsFlipped=\(String(describing: layer?.contentsAreFlipped()))")
                }
                return root.superlayer === host && host.superlayer === window.view.layer && window.view.window === window.window
            }
            t.equal(attached, true, "main mounts and commits the candidate under the real window's view layer")
            guard attached == true else { return }
            t.check(!window.window.isVisible, "this test never orders the actual window on screen")
            print("E-WINDOW scale=\(scale) device=\(rect) profilePresent=true profileName=\(String(describing: space.name)) windowSpace=\(String(describing: window.window.colorSpace?.localizedName)) panel=\(facts.panelGeneration)")
            let renderer = try OffscreenRenderer(width: 48, height: 32, device: device,
                                                 maximumReadbackBytes: 48 * 32 * 4, colorSpace: space)
            var saved: [[UInt8]] = []
            typealias Sample = (Result<LayerContentBuilder.Content, Error>, Bool, Bool, Bool)
            for (cycle, left) in [4, 12, 4].enumerated() {
                let sampled = Guarded<Sample?>(nil)
                executor.async {
                    let physicalBefore = executor.isOnThread && SkinThreadExecutor.isSkinThread && !Thread.isMainThread
                    let before = window.runtime.frames.layerRuntime?.currentFrame
                    let result = Result<LayerContentBuilder.Content, Error> {
                        guard let owner else { throw CocoaError(.coderReadCorrupt) }
                        let skin = window.runtime.skin!
                        skin.execute("[!SetVariable Left \(left)][!UpdateMeter *]", from: nil)
                        let context = SkinRenderContext.of(skin)
                        let scene = context.sceneProjector.project(skin,
                            environment: AppSceneEnvironment(scale: Double(scale),
                                appearance: skin.host?.environment(for: skin).appearance ?? .light,
                                appearanceName: facts.appearance), glassSource: .published)
                        // The main attach transaction has already committed; drawing is the next worker transaction.
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        do { try owner.display(scene, context: context.drawing, cycle: skin.updateCount, glass: .hitArea) }
                        catch { CATransaction.commit(); throw error }
                        CATransaction.commit()
                        CATransaction.flush()
                        let c = try LayerContentBuilder(plan: plan, scale: scale, colorSpace: space,
                                                       maximumOwnedBitmapBytes: 1_000_000)
                        guard let content = try c.build(scene, context: context.drawing, cycle: skin.updateCount,
                                                        glass: .hitArea).first else { throw CocoaError(.coderReadCorrupt) }
                        return content
                    }
                    let after = window.runtime.frames.layerRuntime?.currentFrame
                    let preserved = before?.sequence == after?.sequence &&
                        sameImages(before?.contents.map(\.image), after?.contents.map(\.image))
                    let physicalAfter = executor.isOnThread && SkinThreadExecutor.isSkinThread && !Thread.isMainThread
                    sampled.access { $0 = (result, physicalBefore, physicalAfter, preserved) }
                }
                t.check(AppSelfTest.spin(timeout: 30) { sampled.current != nil }, "real next-transaction worker display reaches its completion fence")
                guard let sample = sampled.current else { return }
                t.check(sample.1 && sample.2, "the synchronous E display was bracketed on the physical owner")
                t.check(sample.3, "native E qualification does not mutate the existing C frame, including on rejection")
                let observation = report.observation
                print("E-WINDOW cycle=\(cycle) callbacks=\(observation.callbacks) failure=\(String(describing: observation.failure))")
                if let destination = observation.destinations.first ?? nil {
                    print("E-WINDOW bitmap=\(destination.width)x\(destination.height) row=\(destination.bytesPerRow) bpc=\(destination.bitsPerComponent) bpp=\(destination.bitsPerPixel) info=\(destination.bitmapInfo.rawValue) profilePresent=\(destination.entry.colorSpace != nil) matchesWindow=\(destination.entry.colorSpace.map { CFEqual($0, space) } == true) spaceName=\(String(describing: destination.entry.colorSpace?.name)) ctm=\(destination.entry.ctm) device=\(destination.entry.userToDevice)")
                }
                t.equal(observation.callbacks, [cycle + 1], "one actual CA callback occurs per worker display")
                t.equal(observation.failure, nil, "native callback qualification cannot fall back to an empty success")
                let reference = try sample.0.get()
                guard let destination = observation.destinations.first ?? nil, let target = destination.target else {
                    return t.check(false, "actual callback metadata and qualified target are required")
                }
                t.check(destination.hasBitmapData && destination.width == rect.width && destination.height == rect.height)
                t.check(destination.bitsPerComponent == 8 && destination.bitsPerPixel == 32 &&
                        destination.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue == CGBitmapInfo.byteOrder32Little.rawValue)
                t.check(destination.entry.colorSpace.map { CFEqual($0, space) } == true && target.colorSpace.map { CFEqual($0, space) } == true,
                        "the borrowed native callback retains the actual window profile")
                t.equal(destination.entry.userToDevice, CGAffineTransform(scaleX: scale, y: scale))
                t.equal(target.userToDevice, CGAffineTransform(scaleX: scale, y: scale))
                t.check(target.state?.rasterization == nil && target.state?.blendMode == nil,
                        "borrowed native state is observed, never inferred as owned defaults")
                t.check(reference.image.width == rect.width && reference.image.height == rect.height &&
                        reference.image.colorSpace.map { CFEqual($0, space) } == true)
                let readback = executor.exclusive(timeout: 30) { () -> Result<([UInt8], [UInt8]), Error> in
                    Result {
                        t.check(Thread.isMainThread && executor.isCurrent && !executor.isOnThread,
                                "native observation parks the real owner after display")
                        guard let parent = host.superlayer,
                              let index = parent.sublayers?.firstIndex(where: { $0 === host }),
                              let slot = UInt32(exactly: index), let leaf = root.sublayers?.first else {
                            throw CocoaError(.coderReadCorrupt)
                        }
                        let beforeFlips = [host, root, leaf].map { $0.contentsAreFlipped() }
                        print("E-WINDOW cycle=\(cycle) observerBefore index=\(index) flips=\(beforeFlips)")
                        let single = singleTree(reference, scale: scale, size: size)
                        let actual = try renderer.render(host, at: 0, deadline: .now() + .seconds(30))
                        let expected = try renderer.render(single, at: 0, deadline: .now() + .seconds(30))
                        print("E-WINDOW cycle=\(cycle) observerDetached flips=\([host, root, leaf].map { $0.contentsAreFlipped() })")
                        // CARenderer assigns its own implicit container. Restore the exact actual-window
                        // tree membership after its completed GPU fence; the next worker must requalify.
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        host.removeFromSuperlayer()
                        parent.insertSublayer(host, at: slot)
                        CATransaction.commit()
                        let afterFlips = [host, root, leaf].map { $0.contentsAreFlipped() }
                        print("E-WINDOW cycle=\(cycle) observerRestored parent=\(host.superlayer === parent) index=\(String(describing: parent.sublayers?.firstIndex(where: { $0 === host }))) flips=\(afterFlips)")
                        t.check(host.superlayer === parent)
                        t.equal(parent.sublayers?.firstIndex(where: { $0 === host }), Optional(index))
                        t.equal(afterFlips, beforeFlips, "the actual inherited flip is restored through tree membership")
                        return (actual.rgba, expected.rgba)
                    }
                }
                t.check(readback != nil, "bounded native readback completes")
                guard let readback else { return }
                let (actual, expected) = try readback.get()
                let difference = try PixelComparison.compare(reference: expected, candidate: actual, width: 48, height: 32)
                print("E-WINDOW cycle=\(cycle) difference=\(difference)")
                t.check(difference.isExact, "actual attached E / independent C Single strict point-resolution active bytes: \(difference)")
                t.check(stride(from: 3, to: actual.count, by: 4).contains { actual[$0] > 0 && actual[$0] < 255 }, "actual nonempty translucent ink is required")
                t.equal(report.observation.failure, nil, "native readback cannot trigger a silent unexpected callback")
                t.equal(report.observation.callbacks, [cycle + 1], "readback uses the completed backing, not another draw")
                saved.append(actual)
            }
            t.check(saved[0] != saved[1], "B changes actual E pixels")
            t.equal(saved[0], saved[2], "actual E A/B/A returns byte for byte")
            t.check(renderer.hasVerifiedCanary, "unchanged native canary, fence and 30-second deadline qualify the readback")
        }
    }

    /// Uses the real production staging entry; observation remains finite and never publishes E as window content.
    private static func nativeStagingTests(_ t: AppTestRunner) {
        t.suite("App: layer window native staging: scoped actual worker backing preserves C through A/B/A") {
            let app = try app(t, threading: .engine)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            guard let window = app.activate(config: "App\\LayerContent", file: "Test.ini", contentMode: mode),
                  let executor = window.runtime.executor as? SkinThreadExecutor else {
                return t.check(false, "actual opt-in window and physical worker are required")
            }
            t.check(AppSelfTest.spin(timeout: 30) { window.isStarted }, "actual C startup completes")
            window.pauseUpdates()
            window.visibilityForTesting = true
            window.publishFacts(force: true)
            window.runtime.send(.firstFrame)
            t.check(AppSelfTest.spin(timeout: 30) { window.content.installedLayerRoot != nil })
            let size = window.view.bounds.size
            guard let space = window.facts.colorSpace, space.model == .rgb, let device = MTLCreateSystemDefaultDevice(),
                  size == CGSize(width: 48, height: 32), let cRoot = window.content.installedLayerRoot else {
                return t.check(false, "actual RGB profile, C root, fixture geometry and native Metal are required")
            }
            let renderer = try OffscreenRenderer(width: 48, height: 32, device: device,
                maximumReadbackBytes: 48 * 32 * 4, colorSpace: space)
            var saved: [[UInt8]] = []
            for left in [4, 12, 4] {
                window.visibilityForTesting = true
                window.publishFacts(force: true)
                let reference = Guarded<Result<LayerContentBuilder.Content, Error>?>(nil)
                executor.async {
                    reference.access { result in result = Result {
                        let skin = window.runtime.skin!, frames = window.runtime.frames
                        skin.execute("[!SetVariable Left \(left)][!UpdateMeter *][!Redraw]", from: nil)
                        frames.runLoopTurn(.beforeWaiting)
                        guard let frame = frames.layerRuntime?.currentFrame else { throw CocoaError(.coderReadCorrupt) }
                        let context = SkinRenderContext.of(skin)
                        let scene = context.sceneProjector.project(skin, environment: AppSceneEnvironment(scale: Double(frame.scale),
                            appearance: skin.host?.environment(for: skin).appearance ?? .light,
                            appearanceName: frames.appearance), glassSource: .published)
                        let builder = try LayerContentBuilder(plan: SinglePartition.plan(in: frame.plan.window),
                            scale: frame.scale, colorSpace: frame.colorSpace, maximumOwnedBitmapBytes: 1_000_000)
                        guard let image = try builder.build(scene, context: context.drawing, cycle: skin.updateCount,
                                                            glass: .hitArea).first else { throw CocoaError(.coderReadCorrupt) }
                        return image
                    } }
                }
                t.check(AppSelfTest.spin(timeout: 30) { reference.current != nil }, "C accepts the recipe and independent fresh Single completes")
                guard let referenceResult = reference.current else { return }
                let expectedContent = try referenceResult.get()
                // Return to the actual never-ordered window state. The production C frame stays in place, with no
                // visibility override scheduling another frame while its accepted scene is qualified.
                window.visibilityForTesting = nil
                window.publishFacts(force: true)
                ownerWork(executor, t) {}
                guard let before = executor.exclusive(timeout: 30, {
                    window.runtime.frames.layerRuntime?.currentFrame
                }) ?? nil else { return t.check(false, "accepted C source frame") }
                let presented = window.content.state.presented
                let drawn = window.runtime.exclusive { _ in window.runtime.frames.framesDrawn }
                var completed = false, completions = 0
                var readback: Result<([UInt8], [UInt8]), Error>?
                window.requestNativeStage(maximumCallbackBitmapBytes: 1_000_000) { result in
                    defer { completed = true }
                    completions += 1
                    readback = Result {
                        let ready = try result.get()
                        t.check(Thread.isMainThread && executor.isCurrent && !executor.isOnThread,
                                "scoped completion holds the actual owner lease on main")
                        t.check(ready.drewOnPhysicalOwner, "native creation/display ran on the physical worker")
                        t.equal(ready.sourceSequence, before.sequence)
                        t.equal(ready.native.callbacks, [1])
                        t.equal(ready.native.failure, nil)
                        guard let destination = ready.native.destinations.first ?? nil, let target = destination.target,
                              let host = window.content.stagedNativeHost, let root = host.sublayers?.first,
                              let leaf = root.sublayers?.first, let parent = host.superlayer,
                              let index = parent.sublayers?.firstIndex(where: { $0 === host }),
                              let slot = UInt32(exactly: index) else { throw CocoaError(.coderReadCorrupt) }
                        t.equal(host.opacity, Float(0), "production staging remains invisible until cleanup")
                        t.check(parent === window.view.layer && !host.isGeometryFlipped)
                        t.check(destination.hasBitmapData && destination.bitsPerComponent == 8 && destination.bitsPerPixel == 32)
                        t.check(destination.width == expectedContent.image.width && destination.height == expectedContent.image.height)
                        t.check(destination.entry.colorSpace.map { CFEqual($0, space) } == true &&
                                target.colorSpace.map { CFEqual($0, space) } == true, "actual window profile qualifies the borrowed callback")
                        t.equal(target.userToDevice, CGAffineTransform(scaleX: before.scale, y: before.scale))
                        t.check(target.state?.rasterization == nil && target.state?.blendMode == nil)
                        t.check(window.content.installedLayerRoot === cRoot)
                        let flips = [host, root, leaf].map { $0.contentsAreFlipped() }
                        // Test-only GPU observation of the completed E backing, never a C copy claimed as E.
                        // Restore original parent/index/opacity even on observer failure before returning the lease.
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        host.opacity = 1
                        CATransaction.commit()
                        defer {
                            CATransaction.begin(); CATransaction.setDisableActions(true)
                            host.removeFromSuperlayer()
                            parent.insertSublayer(host, at: slot)
                            host.opacity = 0
                            CATransaction.commit()
                            t.equal([host, root, leaf].map { $0.contentsAreFlipped() }, flips)
                            t.equal(parent.sublayers?.firstIndex(where: { $0 === host }), Optional(index))
                        }
                        let actual = try renderer.render(host, at: 0, deadline: .now() + .seconds(30))
                        let expected = try renderer.render(singleTree(expectedContent, scale: before.scale, size: size),
                            at: 0, deadline: .now() + .seconds(30))
                        t.equal(ready.native.failure, nil)
                        return (actual.rgba, expected.rgba)
                    }
                }
                t.check(AppSelfTest.spin(timeout: 30) { completed }, "actual worker draw and scoped main completion arrive")
                guard let result = readback else { return t.check(false, "finite observation returned") }
                let (actual, expected) = try result.get()
                t.equal(completions, 1)
                let difference = try PixelComparison.compare(reference: expected, candidate: actual, width: 48, height: 32)
                t.check(difference.isExact, "real staged E / independent fresh C Single exact pixels: \(difference)")
                t.check(stride(from: 3, to: actual.count, by: 4).contains { actual[$0] > 0 && actual[$0] < 255 },
                        "real translucent nonempty native ink")
                t.check(AppSelfTest.spin(timeout: 30) { window.content.stagedNativeHost == nil }, "owner release precedes main detach")
                ownerWork(executor, t) {
                    let frames = window.runtime.frames, after = frames.layerRuntime?.currentFrame
                    t.check(!frames.hasNativeStage, "main detach acknowledgment empties the bounded owner slot")
                    t.equal(after?.sequence, before.sequence)
                    t.check(sameImages(after?.contents.map(\.image), before.contents.map(\.image)))
                    t.equal(frames.framesDrawn, drawn)
                }
                t.equal(window.content.state.presented, presented, "staging never publishes or counts an E/C frame")
                t.check(window.content.installedLayerRoot === cRoot)
                t.equal(window.view.layer?.sublayers?.count, 1, "no hidden native cache remains after completion")
                saved.append(actual)
            }
            t.check(saved[0] != saved[1], "B changes actual native bytes")
            t.equal(saved[0], saved[2], "A returns byte for byte")
            t.check(renderer.hasVerifiedCanary)
            window.stop()
            t.check(AppSelfTest.spin(timeout: 30) { window.content.state.tornDown })
        }
    }

    /// Scheduling controls use the actual window/runtime/executor. No fake owner or host version is introduced.
    private final class NativeStageGate: SkinRuntimeWindow {
        let window: SkinWindowController
        var held: SkinNativeStage?
        var holdsCompletion = false
        var ready: (SkinNativeStage, SkinNativeStageResult)?
        init(_ window: SkinWindowController) { self.window = window }
        func apply(_ request: SkinRequest, from runtime: SkinRuntime) {
            if case .nativeStageCompleted(let stage, let result) = request, holdsCompletion { ready = (stage, result) }
            else if case .attachNativeStage(let stage) = request, !holdsCompletion { held = stage }
            else { window.apply(request, from: runtime) }
        }
        func release() {
            guard let held else { return }
            self.held = nil
            window.apply(.attachNativeStage(held), from: window.runtime)
        }
        func releaseCompletion() {
            guard let ready else { return }
            self.ready = nil
            window.apply(.nativeStageCompleted(ready.0, ready.1), from: window.runtime)
        }
        func batchingWindowChanges(_ body: () -> Void) { window.batchingWindowChanges(body) }
        func liveEnvironment(for skin: Skin) -> SkinEnvironment? { window.liveEnvironment(for: skin) }
        var liveTakesPointer: Bool? { window.liveTakesPointer }
    }

    private static func nativeStagingControlTests(_ t: AppTestRunner) {
        t.suite("App: layer window native staging: bitmap and Main refuse without E work") {
            for (threading, selection, expected) in [(SkinThreading.engine, SkinFrameContentMode.bitmap, SkinNativeStageFailure.unsupportedMode),
                                                     (.main, mode, .unsupportedExecutor)] {
                let app = try app(t, threading: threading)
                defer { app.stopAllForTermination(); app.endEngineThread() }
                let window = try activate(app, t, selection: selection)
                var completionCount = 0, failure: SkinNativeStageFailure?
                window.requestNativeStage(maximumCallbackBitmapBytes: 1_000_000) { result in
                    completionCount += 1
                    if case .failure(let value) = result { failure = value }
                    else { t.check(false, "unsupported path cannot qualify") }
                }
                t.equal(completionCount, 1, "unsupported result is immediate on main")
                t.equal(failure, expected)
                t.check(window.content.stagedNativeHost == nil)
                t.equal(window.runtime.exclusive { _ in window.runtime.frames.hasNativeStage }, false)
                t.equal(window.runtime.exclusive { _ in window.runtime.frames.requestNativeCompletion == nil &&
                    window.runtime.frames.requestNativeStopRelease == nil }, true,
                    "unsupported bitmap/Main modes do not even allocate native scheduling closures")
                if selection == .bitmap { t.equal(window.runtime.exclusive { _ in window.runtime.frames.layerRuntime == nil }, true) }
            }
        }
        t.suite("App: layer window native staging: bounded slot cancels stale panels and late acks before close") {
            let app = try app(t, threading: .engine)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try activate(app, t)
            prepareWindow(window, t)
            guard let executor = window.runtime.executor as? SkinThreadExecutor else { return t.check(false, "physical worker") }
            settleCForNativeStage(window, t)
            let gate = NativeStageGate(window)
            window.runtime.window = gate
            defer {
                gate.release()
                window.runtime.window = window
            }
            var first: SkinNativeStageResult?, firstCount = 0, busy: SkinNativeStageResult?
            window.requestNativeStage(maximumCallbackBitmapBytes: 1_000_000) { first = $0; firstCount += 1 }
            t.check(AppSelfTest.spin(timeout: 30) { gate.held != nil || first != nil } && gate.held != nil,
                    "actual owner stage reaches the main attachment gate")
            guard let old = gate.held else { return }
            t.equal(old.attachment.callbackReport.observation.callbacks, [0], "unattached staging does no native draw")
            t.check(window.content.stagedNativeHost == nil)
            window.requestNativeStage(maximumCallbackBitmapBytes: 1_000_000) { busy = $0 }
            t.check(AppSelfTest.spin(timeout: 30) { busy != nil })
            if case .failure(.busy)? = busy {} else { t.check(false, "second request must reject before another E allocation") }
            t.check(first == nil)
            let panel = window.window
            window.runtime.send(.run("[!ClickThrough 1][!ClickThrough 0]"))
            t.check(AppSelfTest.spin(timeout: 30) { window.window !== panel && first != nil }, "real panel replacement invalidates the old epoch")
            if case .failure(.cancelled)? = first {} else { t.check(false, "stale source remains cancelled") }
            t.equal(firstCount, 1)
            t.check(AppSelfTest.spin(timeout: 30) {
                window.runtime.exclusive { _ in !window.runtime.frames.hasNativeStage } == true
            }, "cancelled owner cleanup and detach ack complete")
            gate.release() // Old attachment arrives after cleanup, and cannot regain a slot or bind the new panel.
            window.runtime.send(.nativeStageAttached(old))
            window.runtime.send(.nativeStageRelease(old))
            ownerWork(executor, t) {}
            t.equal(firstCount, 1)
            t.equal(old.attachment.callbackReport.observation.callbacks, [0])
            t.check(window.content.stagedNativeHost == nil)

            // The existing C path recovers after replacement; a new stage can be queued, then cancelled by close.
            window.visibilityForTesting = true
            window.publishFacts(force: true)
            window.runtime.send(.frameWanted)
            t.check(AppSelfTest.spin(timeout: 30) {
                window.runtime.exclusive { _ in !window.runtime.frames.needsFrame } == true
            })
            var closing: SkinNativeStageResult?, closeCount = 0
            window.requestNativeStage(maximumCallbackBitmapBytes: 1_000_000) { closing = $0; closeCount += 1 }
            t.check(AppSelfTest.spin(timeout: 30) { gate.held != nil }, "later request obtains its own bounded identity")
            guard let current = gate.held else { return }
            t.check(current !== old)
            window.runtime.send(.nativeStageRelease(old))
            ownerWork(executor, t) { t.check(window.runtime.frames.hasNativeStage, "old release cannot clear the newer slot") }
            window.stop()
            t.check(AppSelfTest.spin(timeout: 30) { closing != nil && window.content.state.tornDown },
                    "close processes native cancellation, owner release, detach and C teardown")
            if case .failure(.cancelled)? = closing {} else { t.check(false, "close cannot complete a native observation") }
            t.equal(closeCount, 1)
            t.equal(current.attachment.callbackReport.observation.callbacks, [0])
            gate.release()
            ownerWork(executor, t) { t.check(!window.runtime.frames.hasNativeStage) }
            t.check(window.content.stagedNativeHost == nil && window.content.installedLayerRoot == nil)
        }
    }

    private static func nativeStagingStopTests(_ t: AppTestRunner) {
        t.suite("App: layer window native staging: permanent worker stop precedes late main completion") {
            let app = try app(t, threading: .engine)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try activate(app, t)
            prepareWindow(window, t)
            settleCForNativeStage(window, t)
            guard let executor = window.runtime.executor as? SkinThreadExecutor,
                  let cRoot = window.content.installedLayerRoot,
                  let before = executor.exclusive(timeout: 30, { window.runtime.frames.layerRuntime?.currentFrame }) ?? nil else {
                return t.check(false, "accepted C source and physical worker")
            }
            let gate = NativeStageGate(window)
            gate.holdsCompletion = true
            window.runtime.window = gate
            defer { window.runtime.window = window }
            var completed: SkinNativeStageResult?, completions = 0
            window.requestNativeStage(maximumCallbackBitmapBytes: 1_000_000) { completed = $0; completions += 1 }
            t.check(AppSelfTest.spin(timeout: 30) { gate.ready != nil }, "actual native display reaches a held main ready message")
            guard let ready = gate.ready, let host = window.content.stagedNativeHost,
                  let leaf = ready.0.attachment.root.sublayers?.first else { return t.check(false, "real attached E backing") }
            if case .success(let observation) = ready.1 {
                t.check(observation.drewOnPhysicalOwner)
                t.equal(observation.native.callbacks, [1])
                t.equal(observation.native.failure, nil)
                t.check((observation.native.destinations.first ?? nil)?.target != nil)
            } else { return t.check(false, "qualified native callback is the positive control") }
            t.equal(host.opacity, Float(0))
            t.check(completed == nil)
            let drawn = window.runtime.exclusive { _ in window.runtime.frames.framesDrawn }
            ownerWork(executor, t) {
                let frame = window.runtime.frames.layerRuntime?.currentFrame
                t.equal(frame?.sequence, before.sequence)
                t.check(sameImages(frame?.contents.map(\.image), before.contents.map(\.image)))
            }
            // The real app synchronously waits for skin close without serving main completion. Fence the owner
            // after close, then actually stop it before releasing the queued native success on main.
            t.equal(app.stopAllForTermination(), [])
            let stopped = Guarded<(Bool, UInt64?, [CGImage]?, Int)?>(nil)
            ownerWork(executor, t) {
                let frames = window.runtime.frames, frame = frames.layerRuntime?.currentFrame
                stopped.access { $0 = (frames.hasNativeStage, frame?.sequence, frame?.contents.map(\.image), frames.framesDrawn) }
            }
            guard let snapshot = stopped.current else { return t.check(false, "actual closed-owner fence") }
            t.check(!snapshot.0, "permanent stop must release the owner pending slot before main runs")
            t.equal(snapshot.3, drawn)
            t.check(window.content.installedLayerRoot === cRoot, "C final frame remains available before main teardown")
            app.endEngineThread()
            t.check(AppSelfTest.spin(timeout: 30) { executor.hasExited }, "actual physical worker exits before late main success")
            gate.releaseCompletion()
            window.apply(.attachNativeStage(ready.0), from: window.runtime)
            t.equal(completions, 1, "late success/attach cannot complete a second time or require the stopped owner")
            if case .failure(.cancelled)? = completed {} else { t.check(false, "permanent stop reports cancellation") }
            t.check(window.content.stagedNativeHost == nil && host.superlayer == nil,
                    "released owner permits main detach without a stopped-executor lease")
            t.check(ready.0.attachment.root.superlayer == nil)
            // Retaining the attachment/report must not retain its drawing owner or live caches. This real late CA
            // callback can record ownerReleased without reaching DrawContext, even though the worker has ended.
            leaf.setNeedsDisplay()
            leaf.displayIfNeeded()
            t.equal(ready.0.attachment.callbackReport.observation.failure, .ownerReleased)
            var refused: SkinNativeStageResult?
            window.runtime.requestNativeStage(maximumCallbackBitmapBytes: 1_000_000) { refused = $0 }
            if case .failure(.cancelled)? = refused {} else { t.check(false, "closed runtime rejects immediately without queuing to its stopped worker") }
        }
    }

    /// prepareWindow requests a C frame but returning an already attached root is not that new frame's ack.
    /// Wait for actual owner acceptance before staging, without asking E to fix or redraw a not-ready C frame.
    private static func settleCForNativeStage(_ window: SkinWindowController, _ t: AppTestRunner) {
        t.check(AppSelfTest.spin(timeout: 30) {
            window.runtime.exclusive { _ in
                let frames = window.runtime.frames
                return frames.layerInstalled && !frames.needsFrame && !frames.hasLayerWriter &&
                    frames.layerRuntime?.state == .live && window.content.hasLayerFrame
            } == true
        }, "actual C acceptance settles before native allocation or source sampling")
    }

    private static func nativeStagingUnexpectedCallbackTests(_ t: AppTestRunner) {
        t.suite("App: layer window native staging: unexpected main callback rejects queued worker success") {
            let app = try app(t, threading: .engine)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try activate(app, t)
            prepareWindow(window, t)
            settleCForNativeStage(window, t)
            guard let executor = window.runtime.executor as? SkinThreadExecutor,
                  let root = window.content.installedLayerRoot,
                  let before = executor.exclusive(timeout: 30, { window.runtime.frames.layerRuntime?.currentFrame }) ?? nil else {
                return t.check(false, "accepted physical-owner C frame")
            }
            let gate = NativeStageGate(window)
            gate.holdsCompletion = true
            window.runtime.window = gate
            defer { gate.releaseCompletion(); window.runtime.window = window }
            var result: SkinNativeStageResult?, completions = 0
            let presented = window.content.state.presented
            window.requestNativeStage(maximumCallbackBitmapBytes: 1_000_000) { result = $0; completions += 1 }
            t.check(AppSelfTest.spin(timeout: 30) { gate.ready != nil }, "actual worker supplies a qualified success before the negative control")
            guard let ready = gate.ready, let leaf = ready.0.attachment.root.sublayers?.first else { return }
            if case .success(let observation) = ready.1 {
                t.check(observation.drewOnPhysicalOwner)
                t.equal(observation.native.callbacks, [1])
                t.equal(observation.native.failure, nil)
                t.check((observation.native.destinations.first ?? nil)?.target != nil)
            } else { return t.check(false, "worker success is required") }
            t.check(Thread.isMainThread && !executor.isCurrent && !executor.isOnThread,
                    "the actual unexpected native callback has no owner lease")
            leaf.setNeedsDisplay()
            leaf.displayIfNeeded()
            let afterCallback = ready.0.attachment.callbackReport.observation
            t.equal(afterCallback.callbacks, [2])
            t.equal(afterCallback.failure, .wrongOwner, "the original native owner guard actually latches failure")
            gate.releaseCompletion()
            t.equal(completions, 1)
            if case .failure(.rendering("wrongOwner"))? = result {} else {
                t.check(false, "current callback failure must reject the older successful observation")
            }
            t.check(AppSelfTest.spin(timeout: 30) { window.content.stagedNativeHost == nil })
            ownerWork(executor, t) {
                let frames = window.runtime.frames
                t.check(!frames.hasNativeStage)
                t.equal(frames.layerRuntime?.currentFrame?.sequence, before.sequence)
                t.check(sameImages(frames.layerRuntime?.currentFrame?.contents.map(\.image), before.contents.map(\.image)))
            }
            t.equal(window.content.state.presented, presented)
            t.check(window.content.installedLayerRoot === root, "callback rejection keeps the visible C root")
            window.apply(.nativeStageCompleted(ready.0, ready.1), from: window.runtime)
            t.equal(completions, 1, "replayed stale success remains inert")
        }
    }

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

    /// These fixtures publish the real Single backing, then select the same accepted C generation on rollback.
    /// They remain never-ordered native window observations, not WindowServer/profile-change G2' certification.
    private final class NativePublicationGate: SkinRuntimeWindow {
        let window: SkinWindowController
        var stage: SkinNativeStage?
        var holdsFinished = false
        var finished: (SkinNativeStage, SkinNativeStageResult)?
        init(_ window: SkinWindowController) { self.window = window }
        func apply(_ request: SkinRequest, from runtime: SkinRuntime) {
            if case .attachNativeStage(let stage) = request { self.stage = stage }
            if case .nativeStagePublicationFinished(let stage, let result) = request, holdsFinished {
                finished = (stage, result)
            } else { window.apply(request, from: runtime) }
        }
        func releaseFinished() {
            guard let finished else { return }
            self.finished = nil
            window.apply(.nativeStagePublicationFinished(finished.0, finished.1), from: window.runtime)
        }
        func batchingWindowChanges(_ body: () -> Void) { window.batchingWindowChanges(body) }
        func liveEnvironment(for skin: Skin) -> SkinEnvironment? { window.liveEnvironment(for: skin) }
        var liveTakesPointer: Bool? { window.liveTakesPointer }
    }

    private static let publicationCard = """

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

    private static func publicationWindow(_ app: AppController, _ t: AppTestRunner) throws -> SkinWindowController {
        guard let window = app.activate(config: "App\\LayerContent", file: "Test.ini", contentMode: mode) else {
            throw CocoaError(.coderReadCorrupt)
        }
        t.check(AppSelfTest.spin(timeout: 30) { window.isStarted }, "actual worker startup completes before publication")
        window.pauseUpdates()
        window.visibilityForTesting = true
        window.publishFacts(force: true)
        window.runtime.send(.firstFrame)
        settleCForNativeStage(window, t)
        t.check(window.facts.colorSpace?.model == .rgb, "actual optional window RGB profile must be present")
        t.equal(window.view.bounds.size, CGSize(width: 48, height: 32))
        return window
    }

    @discardableResult
    private static func publishSingle(_ window: SkinWindowController, _ t: AppTestRunner) -> SkinNativeStageObservation? {
        var result: SkinNativeStageResult?, completions = 0
        window.publishNativeSingle(maximumCallbackBitmapBytes: 1_000_000) { result = $0; completions += 1 }
        t.check(AppSelfTest.spin(timeout: 30) { result != nil }, "physical draw, Main commit and owner publication ack complete")
        t.equal(completions, 1)
        guard case .success(let observation)? = result else {
            t.check(false, "actual publication succeeds: \(String(describing: result))")
            return nil
        }
        t.check(observation.published && observation.drewOnPhysicalOwner)
        t.equal(observation.native.callbacks, [1])
        t.equal(observation.native.failure, nil)
        guard let attachment = window.content.visibleNativeStage, let host = window.content.stagedNativeHost else {
            t.check(false, "a real visible native attachment is required")
            return nil
        }
        t.equal(attachment.sourceSequence, observation.sourceSequence)
        t.equal(host.opacity, Float(1), "production publishes E, not a test-only opacity override")
        t.equal(window.content.contentOpacity, Float(0), "the saved C wrapper is hidden without losing images")
        t.check(host.superlayer === window.view.layer && !host.isGeometryFlipped)
        t.equal(window.runtime.exclusive { _ in window.runtime.frames.layerRuntime?.nativePublicationHoldsWriter }, true)
        return observation
    }

    private static func waitForNativeRetirement(_ window: SkinWindowController, _ t: AppTestRunner) {
        t.check(AppSelfTest.spin(timeout: 30) {
            window.content.stagedNativeHost == nil &&
                window.runtime.exclusive { _ in !window.runtime.frames.hasNativeStage } == true
        }, "real owner release, Main detach and owner detach acknowledgment drain the bounded slot")
        t.check(window.content.visibleNativeStage == nil)
        t.equal(window.content.contentOpacity, Float(1))
    }

    private static func publicationReference(_ window: SkinWindowController, _ executor: SkinThreadExecutor,
                                              _ t: AppTestRunner) throws -> (LayerRuntime.Frame, LayerContentBuilder.Content) {
        let answer = Guarded<Result<(LayerRuntime.Frame, LayerContentBuilder.Content), Error>?>(nil)
        ownerWork(executor, t) {
            answer.access { value in value = Result {
                let skin = window.runtime.skin!, frames = window.runtime.frames
                guard let frame = frames.layerRuntime?.currentFrame else { throw CocoaError(.coderReadCorrupt) }
                let context = SkinRenderContext.of(skin)
                let scene = context.sceneProjector.project(skin, environment: AppSceneEnvironment(scale: Double(frame.scale),
                    appearance: skin.host?.environment(for: skin).appearance ?? .light, appearanceName: frames.appearance),
                    glassSource: .published)
                let builder = try LayerContentBuilder(plan: SinglePartition.plan(in: frame.plan.window), scale: frame.scale,
                    colorSpace: frame.colorSpace, maximumOwnedBitmapBytes: 1_000_000)
                guard let image = try builder.build(scene, context: context.drawing, cycle: skin.updateCount,
                    glass: .hitArea).first else { throw CocoaError(.coderReadCorrupt) }
                return (frame, image)
            } }
        }
        guard let answer = answer.current else { throw CocoaError(.coderReadCorrupt) }
        return try answer.get()
    }

    private static func readPublishedNative(_ window: SkinWindowController, _ expected: LayerContentBuilder.Content,
                                           _ renderer: OffscreenRenderer, _ t: AppTestRunner, callbacks: Int = 1,
                                           componentCallbacks: [Int]? = nil) throws -> [UInt8] {
        if let componentCallbacks {
            return try readPublishedComponents(window, expected, renderer, t, callbacks: componentCallbacks)
        }
        let readback = window.runtime.exclusive(timeout: 30) { _ -> Result<[UInt8], Error> in
            Result {
                guard let host = window.content.stagedNativeHost, let root = host.sublayers?.first,
                      let leaf = root.sublayers?.first, let parent = host.superlayer,
                      let index = parent.sublayers?.firstIndex(where: { $0 === host }), let slot = UInt32(exactly: index),
                      let attachment = window.content.visibleNativeStage else { throw CocoaError(.coderReadCorrupt) }
                let flips = [host, root, leaf].map { $0.contentsAreFlipped() }
                t.equal(host.opacity, Float(1))
                t.equal(window.content.contentOpacity, Float(0))
                defer {
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    host.removeFromSuperlayer()
                    parent.insertSublayer(host, at: slot)
                    CATransaction.commit()
                    t.equal([host, root, leaf].map { $0.contentsAreFlipped() }, flips)
                    t.equal(parent.sublayers?.firstIndex(where: { $0 === host }), Optional(index))
                    t.equal(host.opacity, Float(1))
                }
                let actual = try renderer.render(host, at: 0, deadline: .now() + .seconds(30))
                let reference = try renderer.render(singleTree(expected, scale: attachment.scale, size: window.view.bounds.size),
                    at: 0, deadline: .now() + .seconds(30))
                let difference = try PixelComparison.compare(reference: reference.rgba, candidate: actual.rgba, width: 48, height: 32)
                t.check(difference.isExact, "visible real E backing / independent Single exact bytes: \(difference)")
                t.check(stride(from: 3, to: actual.rgba.count, by: 4).contains { actual.rgba[$0] > 0 && actual.rgba[$0] < 255 },
                        "published E contains actual nonempty translucent ink")
                t.equal(attachment.callbackReport.observation.callbacks, [callbacks])
                t.equal(attachment.callbackReport.observation.failure, nil)
                return actual.rgba
            }
        }
        guard let readback else { throw CocoaError(.coderReadCorrupt) }
        return try readback.get()
    }

    private static func nativePublicationTests(_ t: AppTestRunner) {
        t.suite("App: layer window E publication: real visible Single preserves its C frame through A/B/A") {
            let app = try app(t, threading: .engine)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try publicationWindow(app, t)
            guard let executor = window.runtime.executor as? SkinThreadExecutor, let space = window.facts.colorSpace,
                  let device = MTLCreateSystemDefaultDevice(), let cRoot = window.content.installedLayerRoot else {
                return t.check(false, "actual window, worker, profile and Metal controls")
            }
            let renderer = try OffscreenRenderer(width: 48, height: 32, device: device,
                maximumReadbackBytes: 48 * 32 * 4, colorSpace: space)
            var saved: [[UInt8]] = []
            for left in [4, 12, 4] {
                ownerWork(executor, t) {
                    window.runtime.skin.execute("[!SetVariable Left \(left)][!UpdateMeter *][!Redraw]", from: nil)
                    window.runtime.frames.runLoopTurn(.beforeWaiting)
                }
                settleCForNativeStage(window, t)
                let (before, reference) = try publicationReference(window, executor, t)
                let presented = window.content.state.presented
                let drawn = window.runtime.exclusive { _ in window.runtime.frames.framesDrawn }
                guard let observation = publishSingle(window, t) else { return }
                t.equal(observation.sourceSequence, before.sequence)
                t.check(window.content.installedLayerRoot === cRoot)
                saved.append(try readPublishedNative(window, reference, renderer, t))
                ownerWork(executor, t) {
                    let frame = window.runtime.frames.layerRuntime?.currentFrame
                    t.equal(frame?.sequence, before.sequence)
                    t.check(sameImages(frame?.contents.map(\.image), before.contents.map(\.image)))
                    t.equal(window.runtime.frames.framesDrawn, drawn)
                }
                t.equal(window.content.state.presented, presented, "same-generation backend switch is not a second C frame")
                window.rollbackNativeSingle()
                t.equal(window.content.contentOpacity, Float(1), "Main selects the saved C frame before owner release")
                waitForNativeRetirement(window, t)
                ownerWork(executor, t) {
                    t.equal(window.runtime.frames.layerRuntime?.currentFrame?.sequence, before.sequence)
                    t.check(sameImages(window.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image), before.contents.map(\.image)))
                }
            }
            t.check(saved[0] != saved[1], "B changes actual published native bytes")
            t.equal(saved[0], saved[2], "published A returns byte for byte")
            t.check(renderer.hasVerifiedCanary, "unchanged native canary/fence qualifies these finite observations")
            try checkCurrentTree(window, 48, t)
        }
        t.suite("App: layer window E publication: actual Main native failure rolls back once without drawing caches") {
            let app = try app(t, threading: .engine)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try publicationWindow(app, t)
            guard let executor = window.runtime.executor as? SkinThreadExecutor else { return }
            let (before, _) = try publicationReference(window, executor, t)
            let rollbacks = Guarded(0)
            window.runtime.messageObserver = { message in
                if case .nativeStageRolledBack = message { rollbacks.access { $0 += 1 } }
            }
            defer { window.runtime.messageObserver = nil }
            guard publishSingle(window, t) != nil, let attachment = window.content.visibleNativeStage,
                  let leaf = attachment.root.sublayers?.first else { return }
            let drawn = window.runtime.exclusive { _ in window.runtime.frames.framesDrawn }
            t.check(Thread.isMainThread && !executor.isCurrent && !executor.isOnThread)
            for _ in 0..<2 { leaf.setNeedsDisplay(); leaf.displayIfNeeded() }
            t.equal(attachment.callbackReport.observation.failure, .wrongOwner, "actual unexpected CA entries retain the strict guard")
            t.equal(attachment.callbackReport.observation.callbacks, [3])
            waitForNativeRetirement(window, t)
            t.equal(rollbacks.current, 1, "first failure notification produces exactly one owner rollback acknowledgment")
            ownerWork(executor, t) {
                t.equal(window.runtime.frames.layerRuntime?.currentFrame?.sequence, before.sequence)
                t.check(sameImages(window.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image), before.contents.map(\.image)))
                t.equal(window.runtime.frames.framesDrawn, drawn)
            }
            try checkCurrentTree(window, 48, t)
        }
        #if DEBUG
        t.suite("App: layer window E publication: dirty coalesces glass size and hit map before the C writer resumes") {
            let app = try app(t, threading: .engine, source: text + publicationCard)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try publicationWindow(app, t)
            guard let executor = window.runtime.executor as? SkinThreadExecutor else { return }
            let before = window.runtime.exclusive { _ in window.runtime.frames.layerRuntime?.currentFrame } ?? nil
            let oldGlass = window.glass.regions, oldTips = window.view.toolTipRects
            t.check(!oldGlass.isEmpty && !oldTips.isEmpty)
            guard publishSingle(window, t) != nil else { return }
            var patches: [SkinScenePatch] = []
            window.willApplyScenePatch = { patches.append($0) }
            defer { window.willApplyScenePatch = nil }
            ownerWork(executor, t) {
                // Main is synchronously fenced here; its rollback notification cannot run until this returns.
                for (width, left, style) in [(54, 8, "Regular"), (60, 12, "Clear")] {
                    window.runtime.skin.execute("[!SetOption GlassCard MacGlass \(style)]", from: nil)
                    resizeRecipe(window, width, left)
                    t.check(window.runtime.frames.needsFrame, "dirty remains pending while the E/C writer is frozen")
                    t.check(!window.runtime.frames.hasLayerWriter, "no second C ScenePatch can be exported before rollback ack")
                    t.equal(window.runtime.frames.layerRuntime?.currentFrame?.sequence, before?.sequence)
                    t.check(sameImages(window.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image), before?.contents.map(\.image)))
                    t.check(window.runtime.frames.layerRuntime?.nativePublicationHoldsWriter == true)
                }
            }
            t.equal(window.glass.regions, oldGlass, "host debt does not pretend a queued dirty frame has been presented")
            t.equal(window.view.toolTipRects, oldTips)
            t.equal(window.view.bounds.size, CGSize(width: 48, height: 32))
            t.check(AppSelfTest.spin(timeout: 30) {
                window.view.bounds.size == CGSize(width: 60, height: 32) && window.content.stagedNativeHost == nil &&
                    window.runtime.exclusive { _ in !window.runtime.frames.needsFrame && !window.runtime.frames.hasLayerWriter } == true
            }, "Main rollback ack permits one complete latest C host patch")
            t.equal(patches.count, 1, "intermediate dirty scene is coalesced, without losing host values")
            let rect = SkinRect(x: 12, y: 18, width: 10, height: 10)
            let expectedGlass = [GlassRegion(id: "GlassCard", rect: rect, cornerRadius: 2, style: .clear)]
            t.equal(patches.first?.content.state, .appliedByMain)
            t.equal(patches.first?.hostAcknowledgment, .complete)
            t.equal(patches.first?.size, CGSize(width: 60, height: 32))
            t.equal(patches.first?.glass, expectedGlass)
            t.equal(patches.first?.hitMap.toolTipAreas, [rect])
            t.equal(window.window.frame.size, CGSize(width: 60, height: 32))
            t.equal(window.glass.regions, expectedGlass)
            t.equal(window.view.toolTipRects, [rect.cgRect])
            t.equal(window.view.toolTipText(x: 17, y: 23), "Frame\nCard 12")
            t.equal(window.view.toolTipText(x: 5, y: 23), nil)
            t.check(SkinView.hasAction(window, .leftUp, x: 17, y: 23))
            t.check(!SkinView.hasAction(window, .leftUp, x: 5, y: 23))
            t.equal(window.content.contentOpacity, Float(1))
            try checkCurrentTree(window, 60, t)
        }
        #endif
        t.suite("App: layer window E publication: actual profile and panel epochs reject old rollback and success") {
            let app = try app(t, threading: .engine)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try publicationWindow(app, t)
            guard let executor = window.runtime.executor as? SkinThreadExecutor else { return }
            let gate = NativePublicationGate(window)
            window.runtime.window = gate
            defer { gate.releaseFinished(); window.runtime.window = window }
            guard publishSingle(window, t) != nil, let old = gate.stage else { return }
            window.window.colorSpace = .displayP3
            window.publishFacts(force: true)
            t.check(window.content.visibleNativeStage == nil)
            t.equal(window.content.contentOpacity, Float(1), "real profile invalidation selects the last-good C image immediately")
            waitForNativeRetirement(window, t)
            t.check(AppSelfTest.spin(timeout: 30) {
                window.runtime.exclusive { _ in
                    guard let frame = window.runtime.frames.layerRuntime?.currentFrame, let space = window.facts.colorSpace else { return false }
                    return CFEqual(frame.colorSpace, space) && !window.runtime.frames.needsFrame
                } == true
            }, "C redraw acknowledges the current actual profile, not a relabeled old image")
            guard publishSingle(window, t) != nil, let p3 = gate.stage else { return }
            t.check(p3 !== old && p3.epoch.colorSpace.model == .rgb)
            let panel = window.window
            window.runtime.send(.run("[!ClickThrough 1][!ClickThrough 0]"))
            t.check(AppSelfTest.spin(timeout: 30) { window.window !== panel && window.content.visibleNativeStage == nil })
            waitForNativeRetirement(window, t)
            settleCForNativeStage(window, t)
            guard publishSingle(window, t) != nil, let current = gate.stage else { return }
            t.check(current !== old && current !== p3)
            t.check(current.epoch.panelGeneration > old.epoch.panelGeneration)
            window.runtime.rollbackNativePublication(old, failure: .staleDestination)
            window.apply(.nativeStageCompleted(old, .success(SkinNativeStageObservation(sourceSequence: old.attachment.sourceSequence,
                native: old.attachment.callbackReport.observation, drewOnPhysicalOwner: true))), from: window.runtime)
            window.runtime.send(.nativeStageRolledBack(old))
            var fenced = false
            window.runtime.whenCaughtUp { fenced = true }
            t.check(AppSelfTest.spin(timeout: 30) { fenced }, "actual owner/Main fences drain the stale messages")
            t.check(window.content.visibleNativeStage === current.attachment, "old rollback cannot hide the new panel/generation")
            t.equal(window.content.stagedNativeHost?.opacity, Float(1))
            t.equal(current.attachment.callbackReport.observation.failure, nil)
            ownerWork(executor, t) { t.check(window.runtime.frames.hasNativeStage) }
            window.rollbackNativeSingle()
            waitForNativeRetirement(window, t)
        }
        t.suite("App: layer window E publication: physical stop releases before held Main success without losing the C fallback") {
            let app = try app(t, threading: .engine)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try publicationWindow(app, t)
            guard let executor = window.runtime.executor as? SkinThreadExecutor else { return }
            let gate = NativePublicationGate(window)
            gate.holdsFinished = true
            window.runtime.window = gate
            defer { gate.releaseFinished(); window.runtime.window = window }
            var result: SkinNativeStageResult?, completions = 0
            window.publishNativeSingle(maximumCallbackBitmapBytes: 1_000_000) { result = $0; completions += 1 }
            t.check(AppSelfTest.spin(timeout: 30) { gate.finished != nil }, "actual Main publish and owner ack precede the held completion")
            guard let stage = gate.stage, let root = window.content.installedLayerRoot,
                  let leaf = stage.attachment.root.sublayers?.first else { return }
            t.check(stage.wasPublished && window.content.visibleNativeStage === stage.attachment)
            t.equal(window.content.stagedNativeHost?.opacity, Float(1))
            t.check(result == nil)
            let frame = window.runtime.exclusive { _ in window.runtime.frames.layerRuntime?.currentFrame } ?? nil
            t.check(frame != nil && root.sublayers?.isEmpty == false)
            window.stop(fadeOut: true, keepsWindow: true)
            t.equal(window.content.contentOpacity, Float(1), "Main selects the exact saved C frame before close/fade or worker release")
            t.check(window.content.visibleNativeStage == nil)
            t.check(root.sublayers?.isEmpty == false, "kept replacement window retains its actual C last frame")
            ownerWork(executor, t) {
                let frames = window.runtime.frames
                t.check(!frames.hasNativeStage, "permanent owner stop clears the slot before Main processes release")
                t.equal(frames.layerRuntime?.currentFrame?.sequence, frame?.sequence)
                t.check(sameImages(frames.layerRuntime?.currentFrame?.contents.map(\.image), frame?.contents.map(\.image)))
            }
            // The actual Main host no longer needs the kept frame. Queue real C retirement before stopping its
            // executor; the native release fact remains usable after physical exit and held success stays queued.
            leaf.setNeedsDisplay(); leaf.displayIfNeeded()
            t.equal(stage.attachment.callbackReport.observation.failure, .ownerReleased)
            t.check(window.content.installedLayerRoot === root && root.sublayers?.isEmpty == false)
            window.window.orderOut(nil)
            window.window.close()
            window.runtime.teardownContent()
            ownerWork(executor, t) {}
            app.endEngineThread()
            t.check(AppSelfTest.spin(timeout: 30) { executor.hasExited }, "physical worker actually exits")
            t.check(stage.hasStoppedOwnerRelease && stage.hasOwnerRelease)
            gate.releaseFinished()
            window.apply(.attachNativeStage(stage), from: window.runtime)
            t.equal(completions, 1)
            if case .failure(.cancelled)? = result {} else { t.check(false, "late success cannot revive a stopped publication") }
            t.check(window.content.stagedNativeHost == nil)
            leaf.setNeedsDisplay(); leaf.displayIfNeeded()
            t.equal(stage.attachment.callbackReport.observation.failure, .ownerReleased, "attachment/report retain no stopped E owner or caches")
            t.check(window.content.installedLayerRoot == nil && root.sublayers?.isEmpty != false,
                    "actual Main teardown and owner cleanup release the C tree after its last frame was kept")
            var denied: SkinNativeStageResult?
            window.publishNativeSingle(maximumCallbackBitmapBytes: 1_000_000) { denied = $0 }
            if case .failure(.cancelled)? = denied {} else { t.check(false, "closed publication entry never schedules a stopped worker") }
        }
        t.suite("App: layer window E publication: bitmap and Main refuse without native owners or scheduling") {
            for (threading, selection, expected) in [(SkinThreading.engine, SkinFrameContentMode.bitmap, SkinNativeStageFailure.unsupportedMode),
                                                    (.main, mode, .unsupportedExecutor)] {
                let app = try app(t, threading: threading)
                defer { app.stopAllForTermination(); app.endEngineThread() }
                let window = try activate(app, t, selection: selection)
                var result: SkinNativeStageResult?, completions = 0
                window.publishNativeSingle(maximumCallbackBitmapBytes: 1_000_000) { result = $0; completions += 1 }
                if case .failure(let failure)? = result { t.equal(failure, expected) } else { t.check(false, "unsupported mode fails synchronously") }
                t.equal(completions, 1)
                t.check(window.content.stagedNativeHost == nil && window.content.visibleNativeStage == nil)
                t.equal(window.runtime.exclusive { _ in !window.runtime.frames.hasNativeStage }, true)
                t.equal(window.runtime.exclusive { _ in window.runtime.frames.requestNativeCompletion == nil &&
                    window.runtime.frames.requestNativeStopRelease == nil && window.runtime.frames.requestNativePublicationFinished == nil &&
                    window.runtime.frames.requestNativeRollback == nil }, true, "default bitmap/Main allocate no native scheduling closures")
            }
        }
    }
    private static let nativeFrameMode = SkinFrameContentMode.layers(partition: .single,
        maximumOwnedBitmapBytes: 1_000_000, backend: .nativeSingle(maximumCallbackBitmapBytes: 1_000_000))
    private static let nativeFrameText = text.replacingOccurrences(of: "Left=4", with: "Left=4\nTint=217,61,139,157")
        .replacingOccurrences(of: """
        [Moving]
        Meter=Shape
        Shape=Rectangle #Left#,5,12,15 | Fill Color 217,61,139,157 | StrokeWidth 0
        DynamicVariables=1
        """, with: """
        [Moving]
        Meter=Image
        X=4
        Y=5
        W=12
        H=15
        SolidColor=#Tint#
        DynamicVariables=1
        """)

    private static func nativeFrameWindow(_ app: AppController, _ t: AppTestRunner,
                                          gate: ((SkinWindowController) -> Void)? = nil,
                                          selection: SkinFrameContentMode = nativeFrameMode) throws -> SkinWindowController {
        guard let window = app.activate(config: "App\\LayerContent", file: "Test.ini", contentMode: selection) else {
            throw CocoaError(.coderReadCorrupt)
        }
        // The visible fact is part of startup, before automatic qualification. Making an already ready E visible
        // afterwards legitimately draws an ordinary frame, which is not this fixture's initial callback control.
        window.visibilityForTesting = true
        gate?(window)
        t.check(AppSelfTest.spin(timeout: 30) { window.isStarted }, "real C startup reaches the actual window")
        window.pauseUpdates()
        window.publishFacts(force: true)
        window.runtime.send(.firstFrame)
        return window
    }

    private static func readyNativeFrames(_ window: SkinWindowController, _ t: AppTestRunner) -> Bool {
        let ready = AppSelfTest.spin(timeout: 30) {
            window.content.visibleNativeStage != nil && window.runtime.exclusive { _ in
                window.runtime.frames.hasNativeFrameOwner && !window.runtime.frames.needsFrame
            } == true
        }
        t.check(ready, "actual worker qualification, Main publication and owner frame activation complete")
        return ready
    }

    private static func nativeFrameTests(_ t: AppTestRunner) {
        t.suite("App: layer window native frames: persistent Single draws ordinary A/B/A without rebuilding C") {
            let app = try app(t, threading: .engine, source: nativeFrameText)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try nativeFrameWindow(app, t)
            guard readyNativeFrames(window, t), let worker = window.runtime.executor as? SkinThreadExecutor,
                  let attachment = window.content.visibleNativeStage, let space = window.facts.colorSpace,
                  let device = MTLCreateSystemDefaultDevice() else { return t.check(false, "physical native controls") }
            let renderer = try OffscreenRenderer(width: 48, height: 32, device: device,
                maximumReadbackBytes: 48 * 32 * 4, colorSpace: space)
            let (anchor, reference) = try publicationReference(window, worker, t)
            let presented = window.content.state.presented
            let logicalFrames = window.runtime.exclusive { _ in window.runtime.frames.framesDrawn }
            var pixels = [try readPublishedNative(window, reference, renderer, t)]
            let sourceHitMap = attachment.sourceHitMap
            t.check(attachment.supportsFrames)
            for (index, tint) in ["17,89,233,153", "217,61,139,157"].enumerated() {
                ownerWork(worker, t) {
                    let skin = window.runtime.skin!
                    skin.execute("[!SetVariable Tint \(tint)]", from: nil)
                    skin.update()
                    window.runtime.frames.runLoopTurn(.beforeWaiting)
                    let frame = window.runtime.frames.layerRuntime?.nativeFrame(attachment)
                    t.equal(frame?.sequence, anchor.sequence + UInt64(index + 1))
                    t.equal(frame?.cycle, skin.updateCount, "new native scene cycle differs from the immutable C anchor")
                    t.equal(frame?.observation.callbacks, [index + 2])
                    t.equal(window.runtime.frames.layerRuntime?.currentFrame?.sequence, anchor.sequence)
                    t.check(sameImages(window.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image), anchor.contents.map(\.image)))
                    t.equal(window.runtime.frames.framesDrawn, (logicalFrames ?? -10) + index + 1)
                    t.check(!window.runtime.frames.needsFrame && !window.runtime.frames.hasLayerWriter)
                }
                let (_, fresh) = try publicationReference(window, worker, t)
                pixels.append(try readPublishedNative(window, fresh, renderer, t, callbacks: index + 2))
                t.check(window.content.visibleNativeStage === attachment, "ordinary frames keep the same real E owner")
                t.equal(window.content.state.presented, presented, "ordinary E frames do not republish C contents")
                t.equal(window.glass.regions, attachment.sourceGlass)
                t.equal(attachment.sourceHitMap, sourceHitMap)
            }
            t.check(pixels[0] != pixels[1], "B really changes native pixels")
            t.equal(pixels[0], pixels[2], "ordinary A/B/A returns exactly with the same native attachment")
            t.check(renderer.hasVerifiedCanary)
            window.rollbackNativeSingle()
            t.equal(window.content.contentOpacity, Float(1), "Main restores the C anchor before permitting its next owner write")
        }
        t.suite("App: layer window native frames: native failure restores C and retries latest values without E churn") {
            let app = try app(t, threading: .engine, source: nativeFrameText)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try nativeFrameWindow(app, t)
            guard readyNativeFrames(window, t), let worker = window.runtime.executor as? SkinThreadExecutor,
                  let old = window.content.visibleNativeStage, let leaf = old.root.sublayers?.first else { return }
            let anchor = window.runtime.exclusive { _ in window.runtime.frames.layerRuntime?.currentFrame } ?? nil
            ownerWork(worker, t) {
                window.runtime.skin.execute("[!SetVariable Tint 17,89,233,153]", from: nil)
                window.runtime.skin.update()
                window.runtime.frames.runLoopTurn(.beforeWaiting)
                t.equal(window.runtime.frames.layerRuntime?.currentFrame?.sequence, anchor?.sequence)
                t.equal(old.callbackReport.observation.callbacks, [2])
            }
            leaf.setNeedsDisplay()
            leaf.displayIfNeeded() // Real unarmed/off-owner native callback, no manual CGContext or changed guard.
            t.equal(old.callbackReport.observation.failure, .wrongOwner)
            t.check(AppSelfTest.spin(timeout: 30) {
                window.content.stagedNativeHost == nil && window.content.visibleNativeStage == nil &&
                    window.runtime.exclusive { _ in
                        !window.runtime.frames.hasNativeStage && !window.runtime.frames.needsFrame &&
                            window.runtime.frames.layerRuntime?.currentFrame?.sequence == (anchor?.sequence ?? 0) + 1
                    } == true
            }, "rollback ack, real E release, detach and latest C redraw drain even for Update=-1")
            t.equal(window.content.contentOpacity, Float(1))
            t.check(window.runtime.exclusive { _ in window.runtime.frames.nativeFrameFailure != nil } == true)
            for _ in 0..<2 {
                ownerWork(worker, t) {
                    window.runtime.skin.update()
                    window.runtime.frames.runLoopTurn(.beforeWaiting)
                    t.check(!window.runtime.frames.hasNativeStage, "same failed epoch never recreates an E owner on every tick")
                }
            }
            t.check(window.content.stagedNativeHost == nil)
            try checkCurrentTree(window, 48, t)
        }
        #if DEBUG
        t.suite("App: layer window native frames: host changes keep C frozen until rollback and coalesce latest patch") {
            let app = try app(t, threading: .engine, source: nativeFrameText + publicationCard)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try nativeFrameWindow(app, t)
            guard readyNativeFrames(window, t), let worker = window.runtime.executor as? SkinThreadExecutor,
                  let old = window.content.visibleNativeStage else { return }
            let anchor = window.runtime.exclusive { _ in window.runtime.frames.layerRuntime?.currentFrame } ?? nil
            let glass = window.glass.regions, tips = window.view.toolTipRects
            t.check(!glass.isEmpty && !tips.isEmpty)
            var patches: [SkinScenePatch] = []
            window.willApplyScenePatch = { patches.append($0) }
            defer { window.willApplyScenePatch = nil }
            ownerWork(worker, t) {
                for (width, left) in [(54, 8), (60, 12)] {
                    resizeRecipe(window, width, left)
                    t.check(window.runtime.frames.needsFrame)
                    t.check(!window.runtime.frames.hasLayerWriter)
                    t.check(window.runtime.frames.layerRuntime?.nativePublicationHoldsWriter == true)
                    t.equal(window.runtime.frames.layerRuntime?.currentFrame?.sequence, anchor?.sequence)
                    t.check(sameImages(window.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image), anchor?.contents.map(\.image)))
                }
            }
            t.equal(window.glass.regions, glass)
            t.equal(window.view.toolTipRects, tips)
            t.check(AppSelfTest.spin(timeout: 30) {
                window.view.bounds.size == CGSize(width: 60, height: 32) &&
                    window.runtime.exclusive { _ in !window.runtime.frames.needsFrame && !window.runtime.frames.hasLayerWriter } == true
            })
            t.equal(patches.count, 1)
            t.equal(patches.first?.hostAcknowledgment, .complete)
            let rect = SkinRect(x: 12, y: 18, width: 10, height: 10)
            t.equal(window.glass.regions, [GlassRegion(id: "GlassCard", rect: rect, cornerRadius: 2, style: .regular)])
            t.equal(window.view.toolTipRects, [rect.cgRect])
            t.equal(window.window.frame.size, CGSize(width: 60, height: 32))
            guard readyNativeFrames(window, t), let replacement = window.content.visibleNativeStage else { return }
            t.check(replacement !== old)
            window.content.rollbackNativeStage(old)
            window.content.detachNativeStage(old)
            t.check(window.content.visibleNativeStage === replacement, "stale rollback/release cannot hide the newer destination")
        }
        #endif
        t.suite("App: layer window native frames: late readiness panel replacement and physical stop retire only their owner") {
            let app = try app(t, threading: .engine, source: nativeFrameText)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            var gate: NativePublicationGate?
            let window = try nativeFrameWindow(app, t, gate: { window in
                let pending = NativePublicationGate(window)
                pending.holdsFinished = true
                gate = pending
                window.runtime.window = pending
            })
            guard let gate, let worker = window.runtime.executor as? SkinThreadExecutor else {
                return t.check(false, "real worker and Main publication gate")
            }
            defer { gate.releaseFinished(); window.runtime.window = window }
            t.check(AppSelfTest.spin(timeout: 30) { gate.finished != nil }, "Main really holds the initial ready delivery")
            guard let held = gate.finished, let root = window.content.installedLayerRoot else { return }
            let anchor = window.runtime.exclusive { _ in window.runtime.frames.layerRuntime?.currentFrame } ?? nil
            t.check(window.content.visibleNativeStage === held.0.attachment)
            ownerWork(worker, t) {
                t.check(!window.runtime.frames.hasNativeFrameOwner, "published is distinct from consumed readiness")
                window.runtime.skin.execute("[!SetVariable Tint 17,89,233,153]", from: nil)
                window.runtime.skin.update()
                window.runtime.frames.runLoopTurn(.beforeWaiting)
                t.check(window.runtime.frames.needsFrame && !window.runtime.frames.hasLayerWriter)
                t.equal(window.runtime.frames.layerRuntime?.currentFrame?.sequence, anchor?.sequence)
                t.equal(held.0.attachment.callbackReport.observation.callbacks, [1])
            }
            gate.holdsFinished = false
            guard readyNativeFrames(window, t), let replacement = window.content.visibleNativeStage else { return }
            t.check(replacement !== held.0.attachment)
            t.check(held.0.hasOwnerRelease && held.0.request.isCompleted)
            gate.releaseFinished()
            window.runtime.send(.nativeFramesReady(held.0))
            window.runtime.send(.nativeStageDetached(held.0))
            ownerWork(worker, t) { t.check(window.runtime.frames.hasNativeFrameOwner) }
            t.check(window.content.visibleNativeStage === replacement, "old Main readiness cannot cancel the newer writer")

            let panel = window.window
            window.runtime.send(.run("[!ClickThrough 1][!ClickThrough 0]"))
            t.check(AppSelfTest.spin(timeout: 30) { window.window !== panel }, "actual panel replacement changes destination identity")
            guard readyNativeFrames(window, t), let current = window.content.visibleNativeStage,
                  let envelope = gate.stage, let leaf = current.root.sublayers?.first else { return }
            t.check(current !== replacement && envelope.attachment === current)
            window.content.rollbackNativeStage(replacement)
            window.content.detachNativeStage(replacement)
            t.check(window.content.visibleNativeStage === current, "late old-panel cleanup does not hide the current panel")
            var oldObserver: ((SkinMessage) -> Void)?
            var observerInstalled = false
            var stopMessages: [String] = []
            defer {
                if observerInstalled {
                    _ = window.runtime.exclusive(timeout: 30) { _ in window.runtime.messageObserver = oldObserver }
                }
            }
            let currentAnchor = window.runtime.exclusive { _ in
                oldObserver = window.runtime.messageObserver
                window.runtime.messageObserver = { message in
                    oldObserver?(message)
                    switch message {
                    case .nativeStageRolledBack(let stage) where stage === envelope: stopMessages.append("rollback")
                    case .close: stopMessages.append("close")
                    default: break
                    }
                }
                observerInstalled = true
                return window.runtime.frames.layerRuntime?.currentFrame
            } ?? nil
            let callbacks = current.callbackReport.observation.callbacks
            ownerWork(worker, t) {
                window.runtime.skin.execute("[!SetVariable Tint 217,61,139,157]", from: nil)
                window.runtime.skin.update()
                window.runtime.frames.runLoopTurn(.beforeWaiting)
                t.equal(current.callbackReport.observation.callbacks, callbacks.map { $0 + 1 })
                t.equal(window.runtime.frames.layerRuntime?.currentFrame?.sequence, currentAnchor?.sequence)
                t.check(window.runtime.frames.layerRuntime?.nativeFrame(current) != nil)
            }
            guard let space = window.facts.colorSpace, let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "actual destination and Metal")
            }
            let (_, reference) = try publicationReference(window, worker, t)
            let renderer = try OffscreenRenderer(width: 48, height: 32, device: device,
                maximumReadbackBytes: 48 * 32 * 4, colorSpace: space)
            _ = try readPublishedNative(window, reference, renderer, t, callbacks: (callbacks.first ?? -2) + 1)

            window.stop(fadeOut: true, keepsWindow: true)
            t.equal(window.content.contentOpacity, Float(1))
            t.check(window.content.visibleNativeStage == nil && root.sublayers?.isEmpty == false)
            ownerWork(worker, t) {
                t.check(!window.runtime.frames.hasNativeStage && envelope.hasStoppedOwnerRelease && envelope.hasOwnerRelease)
                t.equal(window.runtime.frames.layerRuntime?.currentFrame?.sequence, currentAnchor?.sequence)
                t.check(stopMessages.first == "close", "terminal close precedes the current stage rollback: \(stopMessages)")
                window.runtime.messageObserver = oldObserver
                observerInstalled = false
            }
            window.window.orderOut(nil)
            window.window.close()
            window.runtime.teardownContent()
            ownerWork(worker, t) {}
            app.endEngineThread()
            t.check(AppSelfTest.spin(timeout: 30) { worker.hasExited }, "physical worker stops before late Main delivery")
            window.apply(.attachNativeStage(envelope), from: window.runtime)
            window.apply(.nativeStagePublicationFinished(held.0, held.1), from: window.runtime)
            leaf.setNeedsDisplay(); leaf.displayIfNeeded()
            t.equal(current.callbackReport.observation.failure, .ownerReleased)
            t.check(AppSelfTest.spin(timeout: 30) { window.content.installedLayerRoot == nil && window.content.stagedNativeHost == nil })
            t.check(root.sublayers?.isEmpty != false, "retired roots retain no stopped E owner or C children")
        }
        t.suite("App: layer window native frames: unsupported and callback budgets never allocate shadow owners") {
            for (threading, selection) in [(SkinThreading.main, nativeFrameMode), (.engine, mode), (.engine, .bitmap),
                (.engine, .layers(partition: .single, maximumOwnedBitmapBytes: 1_000_000,
                                  backend: .nativeSingle(maximumCallbackBitmapBytes: 1)))] {
                let app = try app(t, threading: threading, source: nativeFrameText)
                defer { app.stopAllForTermination(); app.endEngineThread() }
                let window = try nativeFrameWindow(app, t, selection: selection)
                t.check(AppSelfTest.spin(timeout: 30) { window.runtime.exclusive { _ in !window.runtime.frames.needsFrame } == true })
                // Drain an actual owner fence before asserting absence; no sleep-based negative observation.
                window.runtime.whenCaughtUp {}
                if let worker = window.runtime.executor as? SkinThreadExecutor { ownerWork(worker, t) {} }
                t.check(window.content.stagedNativeHost == nil && window.content.visibleNativeStage == nil)
                t.equal(window.runtime.exclusive { _ in !window.runtime.frames.hasNativeStage }, true)
                if threading == .main {
                    // Main's whenCaughtUp is inline; process the actual queued request before reading its result.
                    t.check(AppSelfTest.spin(timeout: 30) { window.runtime.frames.nativeFrameFailure != nil })
                    t.equal(window.runtime.exclusive { _ in window.runtime.frames.nativeFrameFailure }, .unsupportedExecutor)
                } else if selection.nativeFrameBudget == 1 {
                    t.check(window.runtime.exclusive { _ in window.runtime.frames.nativeFrameFailure != nil } == true)
                    t.check(window.content.installedLayerRoot != nil && window.content.contentOpacity == 1)
                }
            }
        }
    }
    private static let nativeComponentMode = SkinFrameContentMode.layers(partition: .candidateComponents,
        maximumOwnedBitmapBytes: 1_000_000, backend: .nativeComponents(maximumCallbackBitmapBytes: 1_000_000))
    private static let nativeMergedComponentText = """
    [Rainmeter]
    Update=-1
    DynamicWindowSize=1
    [Variables]
    Left=4
    Tint=217,61,139,157
    [Back]
    Meter=Shape
    Shape=Rectangle 0,0,48,32 | Fill Color 31,89,151,100 | StrokeWidth 0
    [Moving]
    Meter=Shape
    Shape=Rectangle #Left#,5,12,15 | Fill Color #Tint# | StrokeWidth 0
    DynamicVariables=1
    [Mask]
    Meter=Shape
    Shape=Rectangle 24,16,20,12 | Fill Color 255,255,255,180 | StrokeWidth 0
    [Child]
    Meter=Shape
    Shape=Rectangle 20,12,20,18 | Fill Color 23,211,73,140 | StrokeWidth 0
    Container=Mask
    """

    private static let nativeComponentText = nativeMergedComponentText.replacingOccurrences(of: """
    [Mask]
    Meter=Shape
    Shape=Rectangle 24,16,20,12 | Fill Color 255,255,255,180 | StrokeWidth 0
    """, with: """
    [Mask]
    Meter=Shape
    X=24
    Y=16
    W=20
    H=12
    Shape=Rectangle 0,0,20,12 | Fill Color 255,255,255,180 | StrokeWidth 0
    """).replacingOccurrences(of: """
    [Child]
    Meter=Shape
    Shape=Rectangle 20,12,20,18 | Fill Color 23,211,73,140 | StrokeWidth 0
    """, with: """
    [Child]
    Meter=Shape
    X=-4
    Y=-4
    Shape=Rectangle 0,0,20,18 | Fill Color 23,211,73,140 | StrokeWidth 0
    """)

    /// CARenderer detaches its input layer. Read the actual flipped ancestor of this private window;
    /// a neutral host or its immediate unflipped parent loses the native ancestor's geometry convention.
    /// This is an observer only. Its original hierarchy and every leaf's inherited flip are restored.
    private static func readPublishedComponents(_ window: SkinWindowController, _ expected: LayerContentBuilder.Content,
                                                _ renderer: OffscreenRenderer, _ t: AppTestRunner,
                                                callbacks: [Int]) throws -> [UInt8] {
        let readback = window.runtime.exclusive(timeout: 30) { _ -> Result<[UInt8], Error> in
            Result {
                guard let host = window.content.stagedNativeHost, let root = host.sublayers?.first,
                      let parent = host.superlayer, let index = parent.sublayers?.firstIndex(where: { $0 === host }),
                      UInt32(exactly: index) != nil, let attachment = window.content.visibleNativeStage else {
                    throw CocoaError(.coderReadCorrupt)
                }
                let observed = [host, root] + (root.sublayers ?? [])
                let flips = observed.map { $0.contentsAreFlipped() }
                let hostFrame = host.frame, hostPosition = host.position
                t.equal(host.opacity, Float(1))
                t.equal(window.content.contentOpacity, Float(0))
                guard let observationRoot = parent.superlayer, observationRoot.isGeometryFlipped,
                      observationRoot.contentsAreFlipped() == parent.contentsAreFlipped(),
                      observationRoot.bounds == parent.bounds, observationRoot.frame == parent.frame,
                      CATransform3DIsIdentity(parent.transform), CATransform3DIsIdentity(parent.sublayerTransform),
                      CATransform3DIsIdentity(observationRoot.transform), CATransform3DIsIdentity(observationRoot.sublayerTransform) else {
                    throw CocoaError(.coderReadCorrupt)
                }
                let originalSuper = observationRoot.superlayer
                let originalIndex = originalSuper?.sublayers?.firstIndex(where: { $0 === observationRoot })
                let originalBounds = observationRoot.bounds, originalPosition = observationRoot.position
                let originalTransform = observationRoot.transform
                if originalSuper != nil, originalIndex == nil { throw CocoaError(.coderReadCorrupt) }
                print("COMPONENT OBSERVER actual ancestor bounds=\(observationRoot.bounds) geometryFlip=\(observationRoot.isGeometryFlipped) scale=\(observationRoot.contentsScale) transform=\(observationRoot.transform) hostFrame=\(hostFrame) hostPosition=\(hostPosition) before=\(flips)")
                defer {
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    if let originalSuper, let originalIndex, let slot = UInt32(exactly: originalIndex) {
                        observationRoot.removeFromSuperlayer()
                        originalSuper.insertSublayer(observationRoot, at: slot)
                    }
                    CATransaction.commit()
                    let after = observed.map { $0.contentsAreFlipped() }
                    print("COMPONENT OBSERVER restored hostFrame=\(host.frame) hostPosition=\(host.position) after=\(after)")
                    t.equal(after, flips)
                    t.equal(observationRoot.bounds, originalBounds)
                    t.equal(observationRoot.position, originalPosition)
                    t.check(CATransform3DEqualToTransform(observationRoot.transform, originalTransform))
                    t.equal(originalSuper?.sublayers?.firstIndex(where: { $0 === observationRoot }), originalIndex)
                    t.check(parent.superlayer === observationRoot && host.superlayer === parent)
                    t.equal(host.frame, hostFrame)
                    t.equal(host.position, hostPosition)
                    t.equal(parent.sublayers?.firstIndex(where: { $0 === host }), Optional(index))
                    t.equal(host.opacity, Float(1))
                }
                let actual = try renderer.render(observationRoot, at: 0, deadline: .now() + .seconds(30))
                let during = observed.map { $0.contentsAreFlipped() }
                print("COMPONENT OBSERVER during=\(during)")
                t.equal(during, flips)
                let reference = try renderer.render(singleTree(expected, scale: attachment.scale, size: window.view.bounds.size),
                    at: 0, deadline: .now() + .seconds(30))
                let difference = try PixelComparison.compare(reference: reference.rgba, candidate: actual.rgba, width: 48, height: 32)
                t.check(difference.isExact, "actual parent geometry / independent C Single exact active bytes: \(difference)")
                t.check(stride(from: 3, to: actual.rgba.count, by: 4).contains { actual.rgba[$0] > 0 && actual.rgba[$0] < 255 },
                    "real grouped native pixels retain nonempty translucent ink")
                let blank = [UInt8](repeating: 0, count: reference.rgba.count)
                t.check(!(try PixelComparison.compare(reference: reference.rgba, candidate: blank, width: 48, height: 32)).isExact)
                var wrong = reference.rgba
                wrong[(5 * 48 + 4) * 4] ^= 1
                t.check(!(try PixelComparison.compare(reference: reference.rgba, candidate: wrong, width: 48, height: 32)).isExact)
                t.equal(attachment.callbackReport.observation.callbacks, callbacks)
                t.equal(attachment.callbackReport.observation.failure, nil)
                return actual.rgba
            }
        }
        guard let readback else { throw CocoaError(.coderReadCorrupt) }
        return try readback.get()
    }

    private static func componentCallbacks(_ plan: PartitionPlan, _ count: Int) -> [Int] {
        plan.layers.map { if case .baseSlice = $0.content { return 0 }; return count }
    }

    private static func checkComponentDestinations(_ attachment: LayerRuntime.NativeStage, _ count: Int,
                                                    _ t: AppTestRunner) {
        let observation = attachment.callbackReport.observation
        t.equal(attachment.partition, .acceptedComponents)
        t.equal(observation.callbacks, componentCallbacks(attachment.plan, count))
        t.equal(observation.failure, nil)
        var slices: [CGImage] = []
        for (index, layer) in attachment.plan.layers.enumerated() {
            if case .group = layer.content {
                let destination = observation.destinations[index]
                t.equal(destination?.layer, layer.id)
                t.equal(destination?.width, layer.rect.width)
                t.equal(destination?.height, layer.rect.height)
                t.check(destination?.target?.colorSpace.map { CFEqual($0, attachment.colorSpace) } == true)
                let map = CGAffineTransform(a: attachment.scale, b: 0, c: 0, d: attachment.scale,
                    tx: -CGFloat(layer.rect.minX), ty: -CGFloat(layer.rect.minY))
                t.equal(destination?.target?.userToDevice, map)
            } else if case .baseSlice = layer.content {
                t.check(observation.destinations[index] == nil, "base pieces copy one owned image without a native draw")
                let contents = attachment.root.sublayers?[index].contents
                if let contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID { slices.append(contents as! CGImage) }
                else { t.check(false, "a base slice must retain actual image bytes") }
            } else { t.check(false, "component qualification cannot quietly select a full-scene leaf") }
        }
        t.check(slices.count > 1)
        if let first = slices.first {
            t.check(slices.allSatisfy { $0 === first }, "one full-window base bitmap is shared by all complement pieces")
            t.equal(first.width, attachment.plan.window.width)
            t.equal(first.height, attachment.plan.window.height)
            t.check(first.colorSpace.map { CFEqual($0, attachment.colorSpace) } == true)
        }
    }

    private static func nativeComponentFrames(_ source: String, groupIDs: [LayerPlan.Identity],
                                               lastMembers: [String], _ t: AppTestRunner) throws {
        let app = try app(t, threading: .engine, source: source)
        defer { app.stopAllForTermination(); app.endEngineThread() }
        let window = try nativeFrameWindow(app, t, selection: nativeComponentMode)
        guard readyNativeFrames(window, t), let worker = window.runtime.executor as? SkinThreadExecutor,
              let attachment = window.content.visibleNativeStage, let space = window.facts.colorSpace,
              let device = MTLCreateSystemDefaultDevice() else { return t.check(false, "actual group owner and profile are required") }
        let renderer = try OffscreenRenderer(width: 48, height: 32, device: device,
            maximumReadbackBytes: 48 * 32 * 4, colorSpace: space)
        let (anchor, reference) = try publicationReference(window, worker, t)
        t.equal(anchor.fallback, nil)
        t.equal(attachment.plan, anchor.plan)
        let groups = attachment.plan.layers.filter { if case .group = $0.content { return true }; return false }
        t.equal(groups.count, groupIDs.count, "the literal layout determines component count")
        t.equal(groups.map(\.id), groupIDs)
        t.equal(attachment.plan.baseMembers.map(\.name), ["back"])
        if case let .group(members)? = groups.last?.content { t.equal(members.map(\.name), lastMembers) }
        else { t.check(false, "the container remains one top-level atomic recipe") }
        let layers = attachment.root.sublayers ?? [], presented = window.content.state.presented
        let logical = window.runtime.exclusive { _ in window.runtime.frames.framesDrawn }
        checkComponentDestinations(attachment, 1, t)
        var pixels = [try readPublishedNative(window, reference, renderer, t,
            componentCallbacks: componentCallbacks(attachment.plan, 1))]
        for (index, tint) in ["17,89,233,153", "217,61,139,157"].enumerated() {
            ownerWork(worker, t) {
                t.check(worker.isOnThread && SkinThreadExecutor.isSkinThread && !Thread.isMainThread)
                window.runtime.skin.execute("[!SetVariable Tint \(tint)]", from: nil)
                window.runtime.skin.update()
                window.runtime.frames.runLoopTurn(.beforeWaiting)
                let frame = window.runtime.frames.layerRuntime?.nativeFrame(attachment)
                t.equal(frame?.sequence, anchor.sequence + UInt64(index + 1))
                t.equal(frame?.observation.callbacks, componentCallbacks(attachment.plan, index + 2))
                t.equal(window.runtime.frames.layerRuntime?.currentFrame?.sequence, anchor.sequence)
                t.check(sameImages(window.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image), anchor.contents.map(\.image)))
                t.equal(window.runtime.frames.framesDrawn, (logical ?? -10) + index + 1)
                t.check(!window.runtime.frames.needsFrame && !window.runtime.frames.hasLayerWriter)
            }
            let (_, fresh) = try publicationReference(window, worker, t)
            pixels.append(try readPublishedNative(window, fresh, renderer, t,
                componentCallbacks: componentCallbacks(attachment.plan, index + 2)))
            checkComponentDestinations(attachment, index + 2, t)
            t.check(window.content.visibleNativeStage === attachment)
            t.check(layers.count == attachment.root.sublayers?.count &&
                zip(layers, attachment.root.sublayers ?? []).allSatisfy { $0.0 === $0.1 })
            t.equal(window.content.state.presented, presented, "native frames do not republish C images")
        }
        t.check(pixels[0] != pixels[1], "the colored B foreground is a nonempty native positive control")
        t.equal(pixels[0], pixels[2])
        t.check(renderer.hasVerifiedCanary)
        window.rollbackNativeSingle() // Existing Main rollback applies to the visible attachment, not a plan name.
        t.equal(window.content.contentOpacity, Float(1))
    }

    private static func nativeComponentTests(_ t: AppTestRunner) {
        t.suite("App: layer window native components: physical group backing stays exact through A/B/A") {
            try nativeComponentFrames(nativeComponentText, groupIDs: [.group(fileIndex: 1), .group(fileIndex: 2)],
                lastMembers: ["mask"], t)
        }
        t.suite("App: layer window native components: merged atomic original layout stays exact through A/B/A") {
            try nativeComponentFrames(nativeMergedComponentText, groupIDs: [.group(fileIndex: 1)],
                lastMembers: ["moving", "mask"], t)
        }
        t.suite("App: layer window native components: changed geometry waits for rollback before latest C and replacement") {
            let app = try app(t, threading: .engine, source: nativeComponentText)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try nativeFrameWindow(app, t, selection: nativeComponentMode)
            guard readyNativeFrames(window, t), let worker = window.runtime.executor as? SkinThreadExecutor,
                  let old = window.content.visibleNativeStage else { return t.check(false, "actual initial components") }
            let anchor = window.runtime.exclusive { _ in window.runtime.frames.layerRuntime?.currentFrame } ?? nil
            let callbacks = old.callbackReport.observation.callbacks
            var held: (SkinNativeStage, SkinNativeStageFailure)?
            var deliver: ((SkinNativeStage, SkinNativeStageFailure) -> Void)?
            var deliveries = 0
            ownerWork(worker, t) {
                deliver = window.runtime.frames.requestNativeRollback
                window.runtime.frames.requestNativeRollback = { stage, failure in
                    deliveries += 1
                    held = (stage, failure)
                }
            }
            defer {
                ownerWork(worker, t) { window.runtime.frames.requestNativeRollback = deliver }
                if let held { deliver?(held.0, held.1) }
            }
            ownerWork(worker, t) {
                for left in [28, 36] {
                    window.runtime.skin.execute("[!SetVariable Left \(left)][!SetVariable Tint 17,89,233,153]", from: nil)
                    window.runtime.skin.update()
                    window.runtime.frames.runLoopTurn(.beforeWaiting)
                    t.equal(old.callbackReport.observation.callbacks, callbacks, "new group bounds decline before live paint")
                    t.equal(window.runtime.frames.layerRuntime?.currentFrame?.sequence, anchor?.sequence)
                    t.check(sameImages(window.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image), anchor?.contents.map(\.image)))
                    t.check(window.runtime.frames.needsFrame && !window.runtime.frames.hasLayerWriter)
                    t.check(window.runtime.frames.layerRuntime?.nativePublicationHoldsWriter == true)
                }
            }
            t.equal(deliveries, 1, "dirty coalesces behind one real Main rollback delivery")
            guard let pending = held, let deliver else { return t.check(false, "actual rollback request was held") }
            t.check(pending.0.attachment === old && !pending.0.hasPublicationRollback && !pending.0.hasOwnerRelease)
            t.check(window.content.visibleNativeStage === old)
            t.equal(window.content.contentOpacity, Float(0))
            ownerWork(worker, t) { window.runtime.frames.requestNativeRollback = deliver }
            held = nil
            deliver(pending.0, pending.1) // Calls the original Main rollback path, not a synthetic ack.
            t.equal(window.content.contentOpacity, Float(1))
            guard readyNativeFrames(window, t), let replacement = window.content.visibleNativeStage else { return }
            t.check(replacement !== old)
            t.check(pending.0.hasPublicationRollback && pending.0.hasOwnerRelease)
            t.check(old.root.superlayer == nil)
            let next = window.runtime.exclusive { _ in window.runtime.frames.layerRuntime?.currentFrame } ?? nil
            t.equal(next?.sequence, (anchor?.sequence ?? 0) + 1)
            t.equal(replacement.plan, next?.plan)
            t.check(replacement.plan != old.plan)
            t.equal(replacement.plan.layers.filter { if case .group = $0.content { return true }; return false }.count, 1)
            window.content.rollbackNativeStage(old)
            window.content.detachNativeStage(old)
            window.runtime.send(.nativeFramesReady(pending.0))
            window.runtime.send(.nativeStageDetached(pending.0))
            t.check(window.content.visibleNativeStage === replacement, "old identities never release a newer component writer")
            guard let space = window.facts.colorSpace, let device = MTLCreateSystemDefaultDevice() else { return t.check(false, "native oracle") }
            let renderer = try OffscreenRenderer(width: 48, height: 32, device: device,
                maximumReadbackBytes: 48 * 32 * 4, colorSpace: space)
            let (_, reference) = try publicationReference(window, worker, t)
            _ = try readPublishedNative(window, reference, renderer, t,
                componentCallbacks: replacement.callbackReport.observation.callbacks)
        }
        t.suite("App: layer window native components: real failed group restores C without owner churn") {
            let app = try app(t, threading: .engine, source: nativeComponentText)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try nativeFrameWindow(app, t, selection: nativeComponentMode)
            guard readyNativeFrames(window, t), let worker = window.runtime.executor as? SkinThreadExecutor,
                  let old = window.content.visibleNativeStage,
                  let index = old.plan.layers.firstIndex(where: { if case .group = $0.content { return true }; return false }),
                  let leaf = old.root.sublayers?[index] else { return t.check(false, "a real group leaf is required") }
            let anchor = window.runtime.exclusive { _ in window.runtime.frames.layerRuntime?.currentFrame } ?? nil
            ownerWork(worker, t) {
                window.runtime.skin.execute("[!SetVariable Tint 17,89,233,153]", from: nil)
                window.runtime.skin.update()
                window.runtime.frames.runLoopTurn(.beforeWaiting)
                t.equal(old.callbackReport.observation.callbacks, componentCallbacks(old.plan, 2))
            }
            leaf.setNeedsDisplay(); leaf.displayIfNeeded()
            t.equal(old.callbackReport.observation.failure, .wrongOwner)
            t.equal(old.callbackReport.observation.callbacks[index], 3, "the actual off-owner entry is counted")
            t.check(AppSelfTest.spin(timeout: 30) {
                window.content.visibleNativeStage == nil && window.content.stagedNativeHost == nil &&
                    window.runtime.exclusive { _ in
                        !window.runtime.frames.hasNativeStage && !window.runtime.frames.needsFrame &&
                        window.runtime.frames.layerRuntime?.currentFrame?.sequence == (anchor?.sequence ?? 0) + 1
                    } == true
            }, "Main restores C, acknowledges rollback, releases E and redraws latest values")
            t.equal(window.content.contentOpacity, Float(1))
            for _ in 0..<2 {
                ownerWork(worker, t) {
                    window.runtime.skin.update(); window.runtime.frames.runLoopTurn(.beforeWaiting)
                    t.check(!window.runtime.frames.hasNativeStage)
                }
            }
            try checkCurrentTree(window, 48, t)
        }
        t.suite("App: layer window native components: held ready profile panel and physical stop keep exact owner identities") {
            let app = try app(t, threading: .engine, source: nativeComponentText)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            var gate: NativePublicationGate?
            let window = try nativeFrameWindow(app, t, gate: { window in
                let pending = NativePublicationGate(window)
                pending.holdsFinished = true
                gate = pending
                window.runtime.window = pending
            }, selection: nativeComponentMode)
            guard let gate, let worker = window.runtime.executor as? SkinThreadExecutor else { return t.check(false, "actual gate/worker") }
            defer { gate.releaseFinished(); window.runtime.window = window }
            t.check(AppSelfTest.spin(timeout: 30) { gate.finished != nil })
            guard let held = gate.finished else { return t.check(false, "actual publication result is held") }
            ownerWork(worker, t) {
                t.check(!window.runtime.frames.hasNativeFrameOwner)
                window.runtime.skin.execute("[!SetVariable Tint 17,89,233,153]", from: nil)
                window.runtime.skin.update(); window.runtime.frames.runLoopTurn(.beforeWaiting)
                t.check(window.runtime.frames.needsFrame)
                t.equal(held.0.attachment.callbackReport.observation.callbacks, componentCallbacks(held.0.attachment.plan, 1))
            }
            gate.holdsFinished = false
            guard readyNativeFrames(window, t), let old = window.content.visibleNativeStage else { return }
            t.check(old !== held.0.attachment && held.0.hasOwnerRelease)
            gate.releaseFinished()
            window.runtime.send(.nativeFramesReady(held.0))
            t.check(window.content.visibleNativeStage === old)
            // Change the actual private fixture window's profile, never the display's or user's profile.
            guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return t.check(false, "named RGB profile is required") }
            let previous = window.facts.colorSpace
            window.window.colorSpace = .sRGB
            window.publishFacts(force: true)
            guard readyNativeFrames(window, t), let afterProfile = window.content.visibleNativeStage else { return }
            if previous.map({ CFEqual($0, sRGB) }) == false { t.check(afterProfile !== old) }
            t.check(CFEqual(afterProfile.colorSpace, sRGB))
            let panel = window.window
            window.runtime.send(.run("[!ClickThrough 1][!ClickThrough 0]"))
            t.check(AppSelfTest.spin(timeout: 30) { window.window !== panel })
            guard readyNativeFrames(window, t), let current = window.content.visibleNativeStage,
                  let envelope = gate.stage,
                  let index = current.plan.layers.firstIndex(where: { if case .group = $0.content { return true }; return false }),
                  let leaf = current.root.sublayers?[index], let root = window.content.installedLayerRoot else { return }
            t.check(current !== afterProfile && envelope.attachment === current)
            window.content.rollbackNativeStage(afterProfile)
            window.content.detachNativeStage(afterProfile)
            t.check(window.content.visibleNativeStage === current)
            window.stop(fadeOut: true, keepsWindow: true)
            t.equal(window.content.contentOpacity, Float(1))
            ownerWork(worker, t) {
                t.check(!window.runtime.frames.hasNativeStage && envelope.hasStoppedOwnerRelease && envelope.hasOwnerRelease)
            }
            window.window.orderOut(nil); window.window.close(); window.runtime.teardownContent()
            ownerWork(worker, t) {}
            app.endEngineThread()
            t.check(AppSelfTest.spin(timeout: 30) { worker.hasExited })
            window.apply(.attachNativeStage(envelope), from: window.runtime)
            window.apply(.nativeStagePublicationFinished(held.0, held.1), from: window.runtime)
            leaf.setNeedsDisplay(); leaf.displayIfNeeded()
            t.equal(current.callbackReport.observation.failure, .ownerReleased)
            t.check(AppSelfTest.spin(timeout: 30) { window.content.installedLayerRoot == nil && window.content.stagedNativeHost == nil })
            t.check(root.sublayers?.isEmpty != false)
        }
        t.suite("App: layer window native components: fallback Main and explicit budgets allocate no shadow owner") {
            let tiny = SkinFrameContentMode.layers(partition: .candidateComponents, maximumOwnedBitmapBytes: 1_000_000,
                backend: .nativeComponents(maximumCallbackBitmapBytes: 1))
            for (threading, source, selection) in [(SkinThreading.engine, text, nativeComponentMode),
                (.main, nativeComponentText, nativeComponentMode), (.engine, nativeComponentText, tiny)] {
                let app = try app(t, threading: threading, source: source)
                defer { app.stopAllForTermination(); app.endEngineThread() }
                let window = try nativeFrameWindow(app, t, selection: selection)
                t.check(AppSelfTest.spin(timeout: 30) { window.runtime.exclusive { _ in !window.runtime.frames.needsFrame } == true })
                if let worker = window.runtime.executor as? SkinThreadExecutor { ownerWork(worker, t) {} }
                else { t.check(AppSelfTest.spin(timeout: 30) { window.runtime.frames.nativeFrameFailure != nil }) }
                t.check(window.content.stagedNativeHost == nil && window.content.visibleNativeStage == nil)
                t.equal(window.runtime.exclusive { _ in !window.runtime.frames.hasNativeStage }, true)
                t.equal(window.content.contentOpacity, Float(1))
                t.check(window.content.installedLayerRoot != nil)
                if source == text {
                    t.check(window.runtime.exclusive { _ in
                        if case .unresolvedInk? = window.runtime.frames.layerRuntime?.currentFrame?.fallback { return true }
                        return false
                    } == true, "original unknown String is a real typed C Single fallback")
                    t.equal(window.runtime.exclusive { _ in window.runtime.frames.nativeFrameFailure }, .notReady)
                } else if threading == .main {
                    t.equal(window.runtime.exclusive { _ in window.runtime.frames.nativeFrameFailure }, .unsupportedExecutor)
                } else {
                    t.check(window.runtime.exclusive { _ in window.runtime.frames.nativeFrameFailure != nil } == true)
                }
            }
        }
    }
    private static let automaticMode = SkinFrameContentMode.layers(partition: .candidateComponents,
        maximumOwnedBitmapBytes: 1_000_000, backend: .automatic(maximumCallbackBitmapBytes: 1_000_000))

    private static func automaticBackendTests(_ t: AppTestRunner) {
        t.suite("App: layer window automatic backend: normalized loaded intervals choose once on the actual owner") {
            for (raw, normalized, native) in [(0, 16, false), (16, 16, false), (99, 99, false),
                                              (100, 100, true), (1_000, 1_000, true), (-1, -1, true), (-7, -1, true)] {
                let source = nativeComponentText.replacingOccurrences(of: "Update=-1", with: "Update=\(raw)")
                let app = try app(t, threading: .engine, source: source)
                defer { app.stopAllForTermination(); app.endEngineThread() }
                // Pause the real clock through its existing message before waiting for startup; the first update
                // still happens. These are loaded-interval controls, not a timed sampling/performance fixture.
                let window = try nativeFrameWindow(app, t, gate: { $0.pauseUpdates() }, selection: automaticMode)
                guard let worker = window.runtime.executor as? SkinThreadExecutor else {
                    return t.check(false, "a real physical executor is required")
                }
                if native { guard readyNativeFrames(window, t) else { return } }
                else { settleCForNativeStage(window, t) }
                t.equal(window.contentMode, automaticMode)
                ownerWork(worker, t) {
                    t.check(worker.isOnThread && SkinThreadExecutor.isSkinThread && !Thread.isMainThread)
                    t.equal(window.runtime.skin.settings.update, normalized, "actual SkinSettings normalization precedes backend selection")
                    t.equal(window.runtime.frames.loadedAutomaticBackend, native
                        ? .nativeComponents(maximumCallbackBitmapBytes: 1_000_000) : .c)
                    t.check(window.runtime.frames.layerRuntime?.currentFrame?.contents.isEmpty == false)
                    t.equal(window.runtime.frames.hasNativeFrameOwner, native)
                    if !native {
                        t.check(window.runtime.frames.automaticNativeFrameRequest() == nil)
                        t.check(!window.runtime.frames.hasNativeStage)
                        t.equal(window.runtime.frames.nativeFrameFailure, nil)
                    }
                }
                if native {
                    guard let stage = window.content.visibleNativeStage else { return t.check(false, "qualified actual E is published") }
                    t.equal(stage.partition, .acceptedComponents)
                    t.equal(stage.callbackReport.observation.failure, nil)
                    t.check(stage.callbackReport.observation.callbacks.contains { $0 > 0 })
                    t.check(window.facts.colorSpace.map { CFEqual(stage.colorSpace, $0) } == true)
                } else {
                    t.check(window.content.visibleNativeStage == nil && window.content.stagedNativeHost == nil)
                    t.equal(window.content.contentOpacity, Float(1))
                }
                let provider = window.content
                window.stop()
                t.check(AppSelfTest.spin(timeout: 30) { provider.state.tornDown })
                t.check(provider.installedLayerRoot == nil && provider.stagedNativeHost == nil)
            }
        }
        t.suite("App: layer window automatic backend: accepted unknown text stays typed Single and exact through A/B/A") {
            let app = try app(t, threading: .engine, source: nativeFrameText)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try nativeFrameWindow(app, t, gate: { $0.pauseUpdates() }, selection: automaticMode)
            guard readyNativeFrames(window, t), let worker = window.runtime.executor as? SkinThreadExecutor,
                  let stage = window.content.visibleNativeStage, let space = window.facts.colorSpace,
                  let device = MTLCreateSystemDefaultDevice() else { return t.check(false, "qualified physical Single E and actual RGB profile are required") }
            let (anchor, first) = try publicationReference(window, worker, t)
            let cause = LayerRuntime.Fallback.unresolvedInk(ElementID(name: "label", index: 4), .unresolvedRasterization)
            t.equal(anchor.fallback, cause)
            t.equal(anchor.plan, SinglePartition.plan(in: anchor.plan.window))
            t.equal(stage.plan, anchor.plan)
            t.equal(stage.partition, .single, "unknown text never becomes approved component ink")
            t.equal(stage.sourceSequence, anchor.sequence)
            let renderer = try OffscreenRenderer(width: 48, height: 32, device: device,
                maximumReadbackBytes: 48 * 32 * 4, colorSpace: space)
            let layers = stage.root.sublayers ?? [], presented = window.content.state.presented
            var pixels = [try readPublishedNative(window, first, renderer, t)]
            for (index, tint) in ["17,89,233,153", "217,61,139,157"].enumerated() {
                ownerWork(worker, t) {
                    window.runtime.skin.execute("[!SetVariable Tint \(tint)]", from: nil)
                    window.runtime.skin.update(); window.runtime.frames.runLoopTurn(.beforeWaiting)
                    let owner = window.runtime.frames.layerRuntime
                    t.equal(owner?.currentFrame?.sequence, anchor.sequence)
                    t.equal(owner?.currentFrame?.fallback, cause)
                    t.check(sameImages(owner?.currentFrame?.contents.map(\.image), anchor.contents.map(\.image)))
                    t.equal(owner?.nativeFrame(stage)?.sequence, anchor.sequence + UInt64(index + 1))
                    t.check(window.runtime.frames.hasNativeFrameOwner && !window.runtime.frames.needsFrame)
                }
                let (_, reference) = try publicationReference(window, worker, t)
                pixels.append(try readPublishedNative(window, reference, renderer, t, callbacks: index + 2))
                t.check(window.content.visibleNativeStage === stage)
                t.check(layers.count == stage.root.sublayers?.count && zip(layers, stage.root.sublayers ?? []).allSatisfy { $0.0 === $0.1 })
                t.equal(window.content.state.presented, presented)
                t.equal(stage.callbackReport.observation.destinations[0]?.target?.userToDevice,
                    CGAffineTransform(scaleX: stage.scale, y: stage.scale))
            }
            t.check(pixels[0] != pixels[1], "actual translucent B is different")
            t.equal(pixels[0], pixels[2])
            t.check(renderer.hasVerifiedCanary)
            window.stop()
            t.check(AppSelfTest.spin(timeout: 30) { window.content.state.tornDown })
            t.check(window.content.installedLayerRoot == nil && window.content.stagedNativeHost == nil)
        }
        t.suite("App: layer window automatic backend: refresh keeps intent and resolves new loaded settings") {
            let initial = nativeComponentText.replacingOccurrences(of: "Update=-1", with: "Update=1000")
            let app = try app(t, threading: .engine, source: initial)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let first = try nativeFrameWindow(app, t, gate: { $0.pauseUpdates() }, selection: automaticMode)
            guard readyNativeFrames(first, t), let worker = first.runtime.executor as? SkinThreadExecutor,
                  let old = first.content.visibleNativeStage else { return }
            ownerWork(worker, t) {
                // The real engine keeps Update loaded-only, as the existing tick-scheduler controls establish.
                // An attempted option change cannot introduce a sampled mid-frame backend switch.
                first.runtime.skin.execute("[!SetOption Rainmeter Update 16]", from: nil)
                t.equal(first.runtime.skin.settings.update, 1_000)
                first.runtime.skin.update(); first.runtime.frames.runLoopTurn(.beforeWaiting)
                t.equal(first.runtime.frames.loadedAutomaticBackend, .nativeComponents(maximumCallbackBitmapBytes: 1_000_000))
                t.check(first.runtime.frames.hasNativeFrameOwner)
            }
            t.check(first.content.visibleNativeStage === old)
            let file = app.skinsDirectory.appendingPathComponent("App/LayerContent/Test.ini")
            try initial.replacingOccurrences(of: "Update=1000", with: "Update=16").write(to: file, atomically: true, encoding: .utf8)
            let fast = try activate(app, t, selection: nil, beforeStart: { $0.visibilityForTesting = true; $0.pauseUpdates() })
            settleCForNativeStage(fast, t)
            t.equal(fast.contentMode, automaticMode, "replacement inherits intent rather than its old resolved E backend")
            t.check(fast.runtime.executor === worker)
            ownerWork(worker, t) {
                t.equal(fast.runtime.skin.settings.update, 16)
                t.equal(fast.runtime.frames.loadedAutomaticBackend, .c)
                t.check(!fast.runtime.frames.hasNativeStage && fast.runtime.frames.automaticNativeFrameRequest() == nil)
            }
            t.check(fast.content.visibleNativeStage == nil && fast.content.stagedNativeHost == nil)
            t.check(AppSelfTest.spin(timeout: 30) { first.content.state.tornDown })
            t.check(first.content.installedLayerRoot == nil && first.content.stagedNativeHost == nil)
            try initial.write(to: file, atomically: true, encoding: .utf8)
            let slow = try activate(app, t, selection: nil, beforeStart: { $0.visibilityForTesting = true; $0.pauseUpdates() })
            guard readyNativeFrames(slow, t) else { return }
            t.equal(slow.contentMode, automaticMode)
            t.check(slow.runtime.executor === worker)
            t.equal(slow.runtime.exclusive { _ in slow.runtime.frames.loadedAutomaticBackend }, .nativeComponents(maximumCallbackBitmapBytes: 1_000_000))
            t.check(AppSelfTest.spin(timeout: 30) { fast.content.state.tornDown })
            slow.content.rollbackNativeStage(old)
            slow.content.detachNativeStage(old)
            t.check(slow.content.visibleNativeStage !== old && slow.content.visibleNativeStage != nil)
            slow.stop()
            t.check(AppSelfTest.spin(timeout: 30) { slow.content.state.tornDown })
            t.check(slow.content.installedLayerRoot == nil && slow.content.stagedNativeHost == nil)
        }
        t.suite("App: layer window automatic backend: held rollback freezes C until latest host values and physical cleanup") {
            let app = try app(t, threading: .engine, source: nativeFrameText + publicationCard)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            var gate: NativePublicationGate?
            let window = try nativeFrameWindow(app, t, gate: { window in
                window.pauseUpdates()
                let pending = NativePublicationGate(window); gate = pending; window.runtime.window = pending
            }, selection: automaticMode)
            guard readyNativeFrames(window, t), let worker = window.runtime.executor as? SkinThreadExecutor,
                  let old = window.content.visibleNativeStage, let oldEnvelope = gate?.stage else { return }
            defer { window.runtime.window = window }
            let anchor = window.runtime.exclusive { _ in window.runtime.frames.layerRuntime?.currentFrame } ?? nil
            let glass = window.glass.regions, tips = window.view.toolTipRects
            t.check(!glass.isEmpty && !tips.isEmpty)
            var held: (SkinNativeStage, SkinNativeStageFailure)?, deliver: ((SkinNativeStage, SkinNativeStageFailure) -> Void)?
            var deliveries = 0
            ownerWork(worker, t) {
                deliver = window.runtime.frames.requestNativeRollback
                window.runtime.frames.requestNativeRollback = { stage, failure in deliveries += 1; held = (stage, failure) }
            }
            defer {
                ownerWork(worker, t) { window.runtime.frames.requestNativeRollback = deliver }
                if let held { deliver?(held.0, held.1) }
            }
            ownerWork(worker, t) {
                for left in [10, 12] {
                    window.runtime.skin.execute("[!SetVariable Left \(left)][!SetVariable Tint 17,89,233,153]", from: nil)
                    window.runtime.skin.update(); window.runtime.frames.runLoopTurn(.beforeWaiting)
                    t.equal(window.runtime.frames.layerRuntime?.currentFrame?.sequence, anchor?.sequence)
                    t.check(sameImages(window.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image), anchor?.contents.map(\.image)))
                    t.check(window.runtime.frames.needsFrame && !window.runtime.frames.hasLayerWriter)
                    t.check(window.runtime.frames.layerRuntime?.nativePublicationHoldsWriter == true)
                    t.equal(old.callbackReport.observation.callbacks, [1], "host mismatch is rejected before live native paint")
                }
            }
            t.equal(deliveries, 1)
            t.equal(window.glass.regions, glass)
            t.equal(window.view.toolTipRects, tips)
            t.check(window.content.visibleNativeStage === old)
            guard let pending = held, let deliver else { return t.check(false, "matching real Main rollback was held") }
            t.check(pending.0 === oldEnvelope && !pending.0.hasPublicationRollback && !pending.0.hasOwnerRelease)
            ownerWork(worker, t) { window.runtime.frames.requestNativeRollback = deliver }
            held = nil; deliver(pending.0, pending.1)
            guard readyNativeFrames(window, t), let replacement = window.content.visibleNativeStage,
                  let currentEnvelope = gate?.stage else { return }
            t.check(replacement !== old && currentEnvelope.attachment === replacement)
            t.check(pending.0.hasPublicationRollback && pending.0.hasOwnerRelease)
            let next = window.runtime.exclusive { _ in window.runtime.frames.layerRuntime?.currentFrame } ?? nil
            t.equal(next?.sequence, (anchor?.sequence ?? 0) + 1)
            t.equal(next?.fallback, anchor?.fallback)
            let rect = SkinRect(x: 12, y: 18, width: 10, height: 10)
            t.equal(window.glass.regions, [GlassRegion(id: "GlassCard", rect: rect, cornerRadius: 2, style: .regular)])
            t.equal(window.view.toolTipRects, [rect.cgRect])
            t.equal(window.view.bounds.size, CGSize(width: 48, height: 32))
            window.content.rollbackNativeStage(old); window.content.detachNativeStage(old)
            window.apply(.attachNativeStage(oldEnvelope), from: window.runtime)
            window.runtime.send(.nativeFramesReady(oldEnvelope))
            t.check(window.content.visibleNativeStage === replacement)
            window.stop(fadeOut: true, keepsWindow: true)
            t.equal(window.content.contentOpacity, Float(1))
            ownerWork(worker, t) {
                t.check(currentEnvelope.hasStoppedOwnerRelease && currentEnvelope.hasOwnerRelease)
                t.check(!window.runtime.frames.hasNativeStage)
            }
            window.window.orderOut(nil); window.window.close(); window.runtime.teardownContent()
            t.check(AppSelfTest.spin(timeout: 30) { window.content.installedLayerRoot == nil && window.content.stagedNativeHost == nil })
            window.apply(.attachNativeStage(currentEnvelope), from: window.runtime)
            t.check(window.content.stagedNativeHost == nil)
        }
        t.suite("App: layer window automatic backend: native failure missing profile Main and budgets retain qualified C") {
            let app = try app(t, threading: .engine, source: nativeFrameText)
            defer { app.stopAllForTermination(); app.endEngineThread() }
            let window = try nativeFrameWindow(app, t, gate: { $0.pauseUpdates() }, selection: automaticMode)
            guard readyNativeFrames(window, t), let worker = window.runtime.executor as? SkinThreadExecutor,
                  let stage = window.content.visibleNativeStage, let leaf = stage.root.sublayers?.first else { return }
            let anchor = window.runtime.exclusive { _ in window.runtime.frames.layerRuntime?.currentFrame } ?? nil
            leaf.setNeedsDisplay(); leaf.displayIfNeeded()
            t.equal(stage.callbackReport.observation.failure, .wrongOwner)
            t.check(AppSelfTest.spin(timeout: 30) {
                window.content.visibleNativeStage == nil && window.content.stagedNativeHost == nil && window.runtime.exclusive { _ in
                    !window.runtime.frames.hasNativeStage && !window.runtime.frames.needsFrame &&
                    window.runtime.frames.layerRuntime?.currentFrame?.sequence == (anchor?.sequence ?? 0) + 1
                } == true
            }, "actual unexpected native callback rolls back before latest C drawing")
            t.equal(window.content.contentOpacity, Float(1))
            var missing = window.facts; missing.colorSpace = nil; missing.sequence += 10
            ownerWork(worker, t) {
                let original = window.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image)
                window.runtime.send(.windowFacts(missing)); window.runtime.send(.redraw)
                window.runtime.frames.runLoopTurn(.beforeWaiting)
                t.check(original != nil)
                t.check(sameImages(original, window.runtime.frames.layerRuntime?.currentFrame?.contents.map(\.image)))
                t.equal(window.runtime.frames.layerFailure, .missingProfile)
                t.check(!window.runtime.frames.hasNativeStage && window.runtime.frames.automaticNativeFrameRequest() == nil)
            }
            var valid = window.facts; valid.sequence = missing.sequence + 1
            ownerWork(worker, t) {
                window.runtime.send(.windowFacts(valid)); window.runtime.skin.update(); window.runtime.frames.runLoopTurn(.beforeWaiting)
                t.equal(window.runtime.frames.layerFailure, nil)
                t.check(!window.runtime.frames.hasNativeStage, "the failed epoch does not churn a new E owner")
            }
            window.stop()
            t.check(AppSelfTest.spin(timeout: 30) { window.content.state.tornDown })
            let tiny = SkinFrameContentMode.layers(partition: .candidateComponents, maximumOwnedBitmapBytes: 1_000_000,
                backend: .automatic(maximumCallbackBitmapBytes: 1))
            for (threading, selection) in [(SkinThreading.main, automaticMode), (.engine, tiny), (.engine, .bitmap)] {
                let controlApp = try Self.app(t, threading: threading, source: nativeFrameText)
                defer { controlApp.stopAllForTermination(); controlApp.endEngineThread() }
                let control = try nativeFrameWindow(controlApp, t, gate: { $0.pauseUpdates() }, selection: selection)
                if selection == .bitmap {
                    t.check(AppSelfTest.spin(timeout: 30) { control.content.shown.image != nil })
                    t.equal(control.runtime.exclusive { _ in control.runtime.frames.layerRuntime == nil }, true)
                    t.equal(control.runtime.exclusive { _ in control.runtime.frames.loadedAutomaticBackend == nil }, true)
                } else {
                    settleCForNativeStage(control, t)
                    t.check(AppSelfTest.spin(timeout: 30) { control.runtime.exclusive { _ in control.runtime.frames.nativeFrameFailure != nil } == true })
                    if threading == .main {
                        t.equal(control.runtime.exclusive { _ in control.runtime.frames.nativeFrameFailure }, .unsupportedExecutor)
                    }
                    t.check(control.content.installedLayerRoot != nil)
                }
                t.check(control.content.visibleNativeStage == nil && control.content.stagedNativeHost == nil)
                t.equal(control.runtime.exclusive { _ in control.runtime.frames.hasNativeStage }, false)
                t.equal(control.content.contentOpacity, Float(1))
            }
        }
    }
}
