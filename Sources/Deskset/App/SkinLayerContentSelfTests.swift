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
    }

    private static func app(_ t: AppTestRunner, threading: SkinThreading) throws -> AppController {
        guard let app = try AppSelfTest.makeApp(t, threading: threading) else { throw CocoaError(.fileNoSuchFile) }
        let folder = app.skinsDirectory.appendingPathComponent("App/LayerContent", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appendingPathComponent("Test.ini"), atomically: true, encoding: .utf8)
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

    private static func singleTree(_ content: LayerContentBuilder.Content, scale: CGFloat) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let tree = CALayer(), image = CALayer()
        tree.anchorPoint = .zero
        tree.bounds = CGRect(x: 0, y: 0, width: 48, height: 32)
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
