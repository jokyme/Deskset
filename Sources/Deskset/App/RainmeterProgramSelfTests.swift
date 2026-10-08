import AppKit
import DesksetCore
import DesksetDraw

/// Native G3 for the first compatibility profile, with a fixed destination for each owner's entire timeline.
enum RainmeterProgramSelfTests {
    private enum Failure: Error { case input, clock, bitmap }
    private final class Text: RainmeterTextMeasuring {
        let context: DrawContext
        init(_ context: DrawContext = DrawContext(fonts: AppFontResolver())) { self.context = context }
        var cycles: [Int] = []
        func measure(_ text: String, style: TextStyle, wrapWidth: Double?, cycle: Int) -> SkinSize? {
            cycles.append(cycle)
            let size = context.text.layout(text, style: style, wrapWidth: wrapWidth.map { CGFloat($0) }, cycle: cycle).size
            return SkinSize(width: size.width, height: size.height)
        }
    }
    private final class Host: SkinHost {
        let text: Text
        let value: SkinEnvironment
        init(_ text: Text, _ value: SkinEnvironment) { self.text = text; self.value = value }
        func environment(for skin: Skin) -> SkinEnvironment { value }
        func textSize(_ value: String, style: TextStyle, wrapWidth: Double?, for skin: Skin) -> (width: Double, height: Double) {
            let size = text.measure(value, style: style, wrapWidth: wrapWidth, cycle: skin.updateCount)
            return (size?.width ?? 0, size?.height ?? 0)
        }
        func imageSize(atPath path: String) -> (width: Double, height: Double)? { preconditionFailure("No image resource") }
        func skinNeedsDisplay(_ skin: Skin) {}
        func skin(_ skin: Skin, handle bang: Bang) -> Bool { preconditionFailure("No action") }
        func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) { preconditionFailure("No forward") }
        func skin(_ skin: Skin, execute target: String, arguments: [String]) { preconditionFailure("No executable") }
        func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {}
    }
    private final class Environment: SceneEnvironment {
        let stamp: EnvironmentStamp
        init(_ appearance: SkinAppearance, _ scale: Int) {
            stamp = EnvironmentStamp(scale: Double(scale), fontGeneration: 0,
                                     appearance: AppearanceStamp(value: appearance, name: "fixed"), imageGeneration: 0)
        }
        func imageStamp(_ path: String) -> ImageStamp? { preconditionFailure("No image resource") }
    }
    private final class System: SystemDataSource {
        var processorCount: Int { preconditionFailure("No system input") }
        func cpuUsage(processor: Int) -> Double { preconditionFailure("No system input") }
        func memoryStatus() -> MemoryStatus { preconditionFailure("No system input") }
        func networkInterfaces() -> [String] { preconditionFailure("No system input") }
        func networkCounters(interface: String?) -> NetworkCounters { preconditionFailure("No system input") }
        func diskSpace(path: String) -> (total: Double, free: Double)? { preconditionFailure("No system input") }
        func uptime() -> TimeInterval { preconditionFailure("No system input") }
        func battery() -> BatteryStatus? { preconditionFailure("No system input") }
        func isProcessRunning(_ name: String) -> Bool { preconditionFailure("No system input") }
        func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { preconditionFailure("No system input") }
    }
    private final class SkinTick: TickTarget {
        weak var skin: Skin?
        let executor: SkinExecutor
        var isClosed: Bool { skin == nil }
        var updateMilliseconds: Int { skin?.settings.update ?? -1 }
        init(_ skin: Skin) { self.skin = skin; executor = skin.executor }
        func updateForTick() { skin?.update() }
        func notifySystemWake() {}
    }
    private static func clock() throws -> VirtualTimeExecutor {
        guard let utc = TimeZone(secondsFromGMT: 0) else { throw Failure.clock }
        let value = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 1_790_467_199), timeZone: utc)
        value.background.allowsUnfakedWork = false
        return value
    }

    static func run(_ t: AppTestRunner) {
        bitmapOwnerTests(t)
        t.suite("App: Rainmeter program: original Anchors matches native pixels after both Skin owners release") {
            guard let source = Paths.repositoryFolder("TestSkins")?.appendingPathComponent("Engine/Compat/Anchors.ini") else {
                throw Failure.input
            }
            let bytes = try Data(contentsOf: source)
            let skins = t.temporaryDirectory("rainmeter-program-native")
            let file = skins.appendingPathComponent("Engine/Compat/Anchors.ini")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
            for appearance in [SkinAppearance.light, .dark] {
                for scale in [1, 2] {
                    let environment = Environment(appearance, scale)
                    var facts = RecordingSkinHost.fixedEnvironment
                    facts.appearance = appearance
                    let effects = RecordingSideEffects(skinsDirectory: skins)
                    let conversionClock = try clock()
                    let program = try IniProgramConverter.convert(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins,
                        system: System(), environment: facts, clock: conversionClock.clock, executor: conversionClock, effects: effects)
                    t.equal(program.sourceBytes, bytes)
                    t.equal(conversionClock.pendingCount, 0)
                    var scenes: [WidgetScene] = []
                    var images: [Int: Data] = [:]
                    var cycles: [Int] = []
                    weak var oldSkin: Skin?
                    weak var oldContext: DrawContext?
                    do {
                        let text = Text(), host = Host(text, facts), time = try clock(), projector = SceneProjector()
                        oldContext = text.context
                        let skin = Skin(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins, system: System(), host: host)
                        oldSkin = skin
                        skin.runInVirtualTime(time); skin.sideEffects = effects
                        try skin.load()
                        t.equal(skin.updateCount, 0)
                        t.check(text.cycles.isEmpty)
                        let scheduler = TickScheduler(), target = SkinTick(skin)
                        skin.update(); scheduler.startTimer(for: target)
                        for index in 0...61 {
                            if index == 61 { time.setWallClock(Date(timeIntervalSince1970: 1_790_553_600)) }
                            if index > 0 { time.advance(by: 1) }
                            let scene = projector.project(skin, environment: environment)
                            scenes.append(scene)
                            if [0, 1, 60, 61].contains(index) {
                                images[index] = try pixels(scene, scale: scale, cycle: skin.updateCount, context: text.context)
                            }
                        }
                        t.equal(skin.updateCount, 62)
                        cycles = text.cycles
                        scheduler.cancel(); skin.close()
                        t.equal(time.pendingCount, 0)
                    }
                    t.check(oldSkin == nil && oldContext == nil, "original live owner and native cache released")
                    let time = try clock()
                    var text: Text? = Text()
                    weak var service = text
                    weak var context = text?.context
                    var runtime: RainmeterProgramRuntime? = try RainmeterProgramRuntime(
                        program: program, executor: time, clock: time.clock, environment: facts,
                        system: System(), effects: effects, text: text)
                    weak var owner = runtime
                    try runtime?.update(); try runtime?.startTimer()
                    var finalPixels: Data?
                    for index in 0...61 {
                        if index == 61 { time.setWallClock(Date(timeIntervalSince1970: 1_790_553_600)) }
                        if index > 0 { time.advance(by: 1) }
                        guard let runtime, let text else { throw Failure.input }
                        let scene = try runtime.project(environment: environment)
                        t.equal(scene, scenes[index], "all scene facts at tick \(index), \(scale)x")
                        if let expected = images[index] {
                            let builds = text.context.text.builds
                            let actual = try pixels(scene, scale: scale, cycle: runtime.updateCount, context: text.context)
                            t.equal(text.context.text.builds, builds, "drawing reuses the measured layouts at this cycle")
                            t.check(actual.contains { $0 != 0 }, "native output is nonempty")
                            t.equal(actual, expected, "strict active RGBA at tick \(index), \(scale)x")
                            var omitted = scene
                            omitted.elements.removeAll { $0.id.name == "word" }
                            t.equal(omitted.elements.count, scene.elements.count - 1, "the canary actually removes Word")
                            t.check(try pixels(omitted, scale: scale, cycle: runtime.updateCount,
                                               context: text.context) != actual, "omitting the visible Word is detected")
                            if index == 61 { finalPixels = actual }
                        }
                    }
                    t.equal(text?.cycles, cycles, "same native measurement order and updateCount")
                    t.equal(runtime?.failure, nil)
                    t.equal(effects.records, [])
                    t.equal(time.background.reports, [])
                    runtime?.close(); runtime = nil; text = nil
                    t.check(owner == nil && service == nil && context == nil, "owner, native service and caches have no cycle")
                    t.equal(time.pendingCount, 0)
                    if let last = scenes.last {
                        let replay = try pixels(last, scale: scale, cycle: 62, context: DrawContext(fonts: AppFontResolver()))
                        t.equal(replay, finalPixels, "the old pure scene still draws on a cold cache after owner release")
                    }
                }
            }
            t.equal(try Data(contentsOf: file), bytes, "conversion never changes the input")
        }
        for name in ["Counter", "Observer"] {
            t.suite("App: Rainmeter program: original \(name) preserves native numeric pixels without a Skin owner") {
                try qualifyNumericGraph(name, t)
            }
        }
        for (name, width, height, omitted) in [("Align", 460.0, 330.0, "multi"), ("Clip", 520.0, 360.0, "clip1h")] {
            t.suite("App: Rainmeter program: original \(name) preserves native text layout without a Skin owner") {
                try qualifyStaticText(name, width: width, height: height, omittedMeter: omitted, t)
            }
        }
    }

    private final class BitmapProvider: ContentProvider {
        let content: LayerContentProvider
        let threads = Guarded<[Bool]>([])
        init(_ view: NSView) { content = LayerContentProvider(in: view) }
        func present(_ frame: SkinFrame) {
            threads.access { $0.append(Thread.isMainThread) }
            content.present(frame)
        }
        func setVisible(_ visible: Bool) { content.setVisible(visible) }
        func setScale(_ scale: CGFloat) { content.setScale(scale) }
        func releaseContents() { content.releaseContents() }
        func teardown() { content.teardown() }
    }
    private final class ReleaseProbe {
        let executor: SkinExecutor
        let result: Guarded<[(Bool, Bool)]>
        init(_ executor: SkinExecutor, _ result: Guarded<[(Bool, Bool)]>) {
            self.executor = executor; self.result = result
        }
        deinit { result.access { $0.append((executor.isCurrent, Thread.isMainThread)) } }
    }
    private final class WeakBitmapOwner {
        weak var engine: RainmeterProgramRuntime?
        weak var context: SkinRenderContext?
    }

    private static func bitmapInput(_ t: AppTestRunner, _ name: String) throws -> (RainmeterProgram, URL, URL, Data) {
        let relative = name == "Anchors" ? "Engine/Compat/Anchors.ini" : "App/\(name)/\(name).ini"
        let config = name == "Anchors" ? "Engine\\Compat" : "App\\" + name
        guard let source = Paths.repositoryFolder("TestSkins")?.appendingPathComponent(relative) else { throw Failure.input }
        let bytes = try Data(contentsOf: source), skins = t.temporaryDirectory("bitmap-owner-" + name)
        let file = skins.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        let time = try clock(), effects = RecordingSideEffects(skinsDirectory: skins)
        let program = try IniProgramConverter.convert(config: config, fileURL: file, skinsDirectory: skins,
            system: System(), environment: RecordingSkinHost.fixedEnvironment, clock: time.clock, executor: time, effects: effects)
        return (program, skins, file, bytes)
    }

    /// Compare the actual provider's active rows, without converting through another raster destination.
    private static func bitmapBytes(_ image: CGImage) throws -> Data {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.width > 0, image.height > 0,
              image.width <= 2048, image.height <= 2048, image.width * image.height * 4 <= 16 * 1024 * 1024,
              let raw = image.dataProvider?.data else { throw Failure.bitmap }
        let bytes = raw as Data, active = image.width * 4, stride = image.bytesPerRow
        guard stride >= active, stride <= Int.max / image.height,
              bytes.count >= (image.height - 1) * stride + active else { throw Failure.bitmap }
        var output = Data(capacity: active * image.height)
        for row in 0..<image.height { output.append(bytes[row * stride..<row * stride + active]) }
        return output
    }

    private static func bitmapOwnerTests(_ t: AppTestRunner) {
        t.suite("App: Rainmeter bitmap owner: original Anchors preserves every frame through the shared provider") {
            let (program, skins, file, bytes) = try bitmapInput(t, "Anchors")
            for appearance in [SkinAppearance.light, .dark] {
                for scale in [1, 2] {
                    var environment = RecordingSkinHost.fixedEnvironment
                    environment.appearance = appearance
                    let appearanceName = (appearance == .dark ? NSAppearance.Name.darkAqua : .aqua).rawValue
                    let effects = RecordingSideEffects(skinsDirectory: skins)
                    let oldTime = try clock(), time = try clock()
                    let oldContext = SkinRenderContext(), oldText = Text(oldContext.drawing), oldHost = Host(oldText, environment)
                    let skin = Skin(config: program.config, fileURL: file, skinsDirectory: skins, system: System(), host: oldHost)
                    skin.renderContext = oldContext
                    skin.runInVirtualTime(oldTime); skin.sideEffects = effects
                    try skin.load()
                    let target = SkinTick(skin), scheduler = TickScheduler(), oldDrawing = SkinBitmapDrawing()
                    skin.update(); scheduler.startTimer(for: target)
                    let view = NSView(), provider = BitmapProvider(view)
                    var host: RainmeterProgramHost? = try RainmeterProgramHost(program: program, executor: time,
                        provider: provider, environment: environment, clock: time.clock, system: System(),
                        effects: effects, random: SkinRandom(seed: 1))
                    weak var engine = host?.engine
                    weak var cache = host?.context
                    let facts = SkinWindowFacts(frame: .zero, isVisible: true, isOrderedIn: true,
                        scale: CGFloat(scale), colorSpace: SkinFrameProducer.sRGB, appearance: appearanceName,
                        takesPointer: true, sequence: 1)
                    host?.take(facts, environment: environment)
                    try host?.start()
                    var lastScene: WidgetScene?, lastImage: Data?
                    for tick in 0...61 {
                        if tick == 61 {
                            let day = Date(timeIntervalSince1970: 1_790_553_600)
                            oldTime.setWallClock(day); time.setWallClock(day)
                        }
                        if tick > 0 { oldTime.advance(by: 1); time.advance(by: 1) }
                        guard let host else { throw Failure.input }
                        t.equal(host.engine.updateCount, skin.updateCount)
                        t.equal(host.engine.updateCount, tick + 1)
                        let builds = host.context.text.builds
                        host.frames.runLoopTurn(.beforeWaiting)
                        t.equal(host.context.text.builds, builds, "frame draw shares the measured text cache/cycle")
                        guard let actual = provider.content.shown.image else { throw Failure.bitmap }
                        var expected: CGImage?
                        SkinFrameProducer.withAppearance(appearanceName) {
                            expected = oldDrawing.picture(of: skin,
                                size: SkinRuntime.windowSize(width: skin.width, height: skin.height), scale: CGFloat(scale),
                                space: SkinFrameProducer.sRGB, appearance: appearanceName)
                        }
                        guard let expected else { throw Failure.bitmap }
                        t.equal(actual.width, expected.width); t.equal(actual.height, expected.height)
                        t.equal(actual.bitmapInfo, expected.bitmapInfo)
                        let found = try bitmapBytes(actual)
                        t.check(found.contains { $0 != 0 })
                        t.equal(found, try bitmapBytes(expected), "strict provider bytes at tick \(tick), \(scale)x")
                        t.equal(host.frames.framesDrawn, tick + 1, "one completed update produces one frame")
                        if tick == 61 {
                            let scene = try host.engine.project(environment: AppSceneEnvironment(scale: Double(scale),
                                appearance: appearance, appearanceName: appearanceName))
                            lastScene = scene; lastImage = found
                            var omitted = scene
                            omitted.elements.removeAll { $0.id.name == "word" }
                            t.equal(omitted.elements.count, scene.elements.count - 1)
                            guard let canary = SkinBitmapDrawing().picture(scene: omitted, context: SkinRenderContext(),
                                cycle: host.engine.updateCount, size: actualPointSize(actual, scale),
                                scale: CGFloat(scale), space: SkinFrameProducer.sRGB) else { throw Failure.bitmap }
                            t.check(try bitmapBytes(canary) != found, "the original visible Word is a strict negative control")
                        }
                    }
                    t.equal(time.now, 61)
                    t.equal(provider.content.state.presented, 62)
                    host?.close(); host = nil
                    scheduler.cancel(); skin.close()
                    t.check(engine == nil && cache == nil, "bundle and shared cache release while provider retains only pixels")
                    t.equal(time.pendingCount, 0)
                    t.equal(effects.records, [])
                    t.equal(time.background.reports, [])
                    guard let lastScene, let lastImage,
                          let replay = SkinBitmapDrawing().picture(scene: lastScene, context: SkinRenderContext(), cycle: 62,
                            size: CGSize(width: lastScene.size.width, height: lastScene.size.height), scale: CGFloat(scale),
                            space: SkinFrameProducer.sRGB) else { throw Failure.bitmap }
                    t.equal(try bitmapBytes(replay), lastImage, "cold frame after independent owner release")
                    provider.teardown()
                    withExtendedLifetime((view, oldHost)) {}
                }
            }
            t.equal(try Data(contentsOf: file), bytes)
        }

        t.suite("App: Rainmeter bitmap owner: C and E requests are explicitly outside this host") {
            let (program, skins, _, _) = try bitmapInput(t, "Counter")
            let effects = RecordingSideEffects(skinsDirectory: skins), view = NSView(), provider = BitmapProvider(view)
            for mode in [SkinFrameContentMode.layers(partition: .single, maximumOwnedBitmapBytes: 16 << 20),
                         .layers(partition: .single, maximumOwnedBitmapBytes: 16 << 20,
                                 backend: .nativeSingle(maximumCallbackBitmapBytes: 16 << 20)),
                         .layers(partition: .candidateComponents, maximumOwnedBitmapBytes: 16 << 20,
                                 backend: .automatic(maximumCallbackBitmapBytes: 16 << 20))] {
                do {
                    _ = try RainmeterProgramHost(program: program, executor: MainSkinExecutor.shared, provider: provider,
                        environment: RecordingSkinHost.fixedEnvironment, contentMode: mode, system: System(), effects: effects)
                    t.check(false, "layer intent must never become a successful bitmap fallback")
                } catch let error as RainmeterProgramHost.Failure { t.equal(error, .unsupportedContentMode) }
            }
            t.equal(provider.content.state.presented, 0)
            t.equal(effects.records, [])
            provider.teardown(); withExtendedLifetime(view) {}
        }
        for worker in [false, true] {
            t.suite("App: Rainmeter bitmap owner: real \(worker ? "worker" : "main") executor owns ticks frames and final release") {
                try liveBitmapOwner(t, worker: worker)
            }
        }
    }

    private static func actualPointSize(_ image: CGImage, _ scale: Int) -> CGSize {
        CGSize(width: Double(image.width) / Double(scale), height: Double(image.height) / Double(scale))
    }

    private static func liveBitmapOwner(_ t: AppTestRunner, worker: Bool) throws {
        let (program, skins, file, bytes) = try bitmapInput(t, "Counter")
        let executor: SkinExecutor = worker ? SkinThreadExecutor(name: "Rainmeter bitmap owner") : MainSkinExecutor.shared
        let effects = RecordingSideEffects(skinsDirectory: skins), view = NSView(), provider = BitmapProvider(view)
        let held = Guarded<RainmeterProgramHost?>(nil), errors = Guarded<[String]>([])
        let releases = Guarded<[(Bool, Bool)]>([]), ownership = Guarded<[Bool]>([]), weakOwner = WeakBitmapOwner()
        let dataTime = try clock()
        let fixed = SkinClock.fixed(dataTime.wallClock, timeZone: dataTime.timeZone)
        defer {
            _ = executor.exclusive(timeout: 30) { held.access { $0?.close(); $0 = nil } }
            provider.teardown()
            (executor as? SkinThreadExecutor)?.stop()
            withExtendedLifetime(view) {}
        }
        executor.async {
            do {
                let probe = ReleaseProbe(executor, releases)
                let clock = SkinClock(now: { withExtendedLifetime(probe) { fixed.now() } },
                                      uptime: fixed.uptime, timeZone: fixed.timeZone)
                let host = try RainmeterProgramHost(program: program, executor: executor, provider: provider,
                    environment: RecordingSkinHost.fixedEnvironment, clock: clock, system: System(), effects: effects,
                    random: SkinRandom(seed: 1))
                weakOwner.engine = host.engine; weakOwner.context = host.context
                host.take(SkinWindowFacts(frame: .zero, isVisible: true, isOrderedIn: true, scale: 2,
                    colorSpace: SkinFrameProducer.sRGB, takesPointer: true, sequence: 1),
                    environment: RecordingSkinHost.fixedEnvironment)
                try host.start(paused: true)
                ownership.access { $0.append(executor.isCurrent && Thread.isMainThread != worker) }
                held.access { $0 = host }
            } catch { errors.access { $0.append(String(describing: error)) } }
        }
        t.check(AppSelfTest.spin(timeout: 30) { provider.content.state.presented >= 1 || !errors.current.isEmpty })
        t.equal(errors.current, [])
        guard held.current != nil else { throw Failure.input }
        t.equal(ownership.current, [true])
        t.equal(executor.exclusive(timeout: 30) { held.current?.engine.updateCount }, 1)
        t.equal(executor.exclusive(timeout: 30) { held.current?.engine.isPaused }, true)
        // A genuine native update clock fires on both supported executors; the fixed data clock only makes pixels repeatable.
        executor.async {
            do { try held.current?.resume(updateNow: false) }
            catch { errors.access { $0.append(String(describing: error)) } }
        }
        t.check(AppSelfTest.spin(timeout: 30) { provider.content.state.presented >= 2 || !errors.current.isEmpty })
        t.equal(errors.current, [])
        _ = executor.exclusive(timeout: 30) { held.current?.pause() }
        let before = provider.content.state.presented
        executor.async {
            do { for _ in 0..<5 { try held.current?.update() } }
            catch { errors.access { $0.append(String(describing: error)) } }
        }
        t.check(AppSelfTest.spin(timeout: 30) { provider.content.state.presented > before || !errors.current.isEmpty })
        _ = executor.exclusive(timeout: 30) {}
        t.equal(provider.content.state.presented, before + 1, "five updates in one owner turn produce one frame")
        t.check(provider.threads.current.allSatisfy { $0 != worker }, "all frames came from the actual owning thread")
        guard let count = executor.exclusive(timeout: 30, { held.current?.engine.updateCount }) ?? nil,
              let image = provider.content.shown.image else { throw Failure.bitmap }
        let context = SkinRenderContext(), text = Text(context.drawing), oldHost = Host(text, RecordingSkinHost.fixedEnvironment)
        let skin = Skin(config: program.config, fileURL: file, skinsDirectory: skins, system: System(), host: oldHost)
        skin.renderContext = context; skin.skinClock = fixed; skin.sideEffects = effects
        try skin.load()
        for _ in 0..<count { skin.update() }
        guard let expected = SkinBitmapDrawing().picture(of: skin,
            size: SkinRuntime.windowSize(width: skin.width, height: skin.height), scale: 2,
            space: SkinFrameProducer.sRGB, appearance: NSAppearance.Name.aqua.rawValue) else { throw Failure.bitmap }
        t.check(try bitmapBytes(image).contains { $0 != 0 })
        t.equal(try bitmapBytes(image), try bitmapBytes(expected), "actual native provider frame matches the old Skin")
        skin.close(); withExtendedLifetime(oldHost) {}
        t.equal(executor.exclusive(timeout: 30) { () -> Int? in
            guard let host = held.current else { return nil }
            let before = host.engine.updateCount
            do { try host.wake() } catch { errors.access { $0.append(String(describing: error)) } }
            host.pause()
            return host.engine.updateCount - before
        }, 1)
        t.equal(executor.exclusive(timeout: 30) { () -> Bool? in
            guard let host = held.current else { return nil }
            host.close()
            let frames = host.frames.framesDrawn
            host.frames.setNeedsFrame(); host.drawFirstFrame(); host.frames.runLoopTurn(.beforeWaiting)
            do { try host.update(); return false }
            catch let error as RainmeterProgramError { return error == .closed && host.frames.framesDrawn == frames }
            catch { return false }
        }, true)
        // Drop the final App reference from a different thread. The owned bundle must still die on its executor.
        if worker { held.access { $0 = nil } }
        else { DispatchQueue.global().async { held.access { $0 = nil } } }
        t.check(AppSelfTest.spin(timeout: 30) {
            !releases.current.isEmpty && weakOwner.engine == nil && weakOwner.context == nil
        })
        t.equal(releases.current.count, 1)
        t.check(releases.current.allSatisfy { $0.0 && $0.1 != worker })
        t.check(weakOwner.engine == nil && weakOwner.context == nil, "no callback/cache/host cycle")
        t.equal(errors.current, [])
        t.equal(effects.records, [])
        t.equal(try Data(contentsOf: file), bytes)
    }

    private static func qualifyStaticText(_ name: String, width: Double, height: Double,
                                          omittedMeter: String, _ t: AppTestRunner) throws {
        let relative = "String/\(name)/\(name).ini", config = "String\\" + name
        guard let source = Paths.repositoryFolder("TestSkins")?.appendingPathComponent(relative) else { throw Failure.input }
        let bytes = try Data(contentsOf: source), skins = t.temporaryDirectory("rainmeter-native-" + name)
        let file = skins.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        for appearance in [SkinAppearance.light, .dark] {
            for scale in [1, 2] {
                let environment = Environment(appearance, scale)
                var facts = RecordingSkinHost.fixedEnvironment
                facts.appearance = appearance
                let effects = RecordingSideEffects(skinsDirectory: skins), conversionClock = try clock()
                let program = try IniProgramConverter.convert(config: config, fileURL: file, skinsDirectory: skins,
                    system: System(), environment: facts, clock: conversionClock.clock, executor: conversionClock, effects: effects)
                t.equal(program.sourceBytes, bytes)
                t.equal(conversionClock.pendingCount, 0)
                var scenes: [WidgetScene] = []
                var images: [Int: Data] = [:], drawBuilds: [Int: Int] = [:]
                var cycles: [Int] = []
                weak var oldSkin: Skin?
                weak var oldContext: DrawContext?
                do {
                    let text = Text(), host = Host(text, facts), time = try clock(), projector = SceneProjector()
                    oldContext = text.context
                    let skin = Skin(config: config, fileURL: file, skinsDirectory: skins, system: System(), host: host)
                    oldSkin = skin
                    skin.runInVirtualTime(time); skin.sideEffects = effects
                    try skin.load()
                    t.equal(skin.updateCount, 0)
                    t.check(text.cycles.isEmpty)
                    let scheduler = TickScheduler(), target = SkinTick(skin)
                    skin.update(); scheduler.startTimer(for: target)
                    t.equal(skin.updateCount, 1)
                    t.equal(time.now, 0)
                    for index in 0...60 {
                        if index > 0 { time.advance(by: 1) }
                        let scene = projector.project(skin, environment: environment)
                        scenes.append(scene)
                        if [0, 1, 60].contains(index) {
                            let builds = text.context.text.builds
                            images[index] = try pixels(scene, scale: scale, cycle: skin.updateCount, context: text.context)
                            drawBuilds[index] = text.context.text.builds - builds
                        }
                    }
                    t.equal(skin.updateCount, 61)
                    t.equal(time.now, 60)
                    t.equal(skin.width, width); t.equal(skin.height, height)
                    t.equal(skin.issues, [])
                    cycles = text.cycles
                    scheduler.cancel(); skin.close()
                    t.equal(time.pendingCount, 0)
                }
                t.check(oldSkin == nil && oldContext == nil, "original owner and native cache released before independent execution")
                let time = try clock()
                var text: Text? = Text()
                weak var service = text
                weak var context = text?.context
                var runtime: RainmeterProgramRuntime? = try RainmeterProgramRuntime(
                    program: program, executor: time, clock: time.clock, environment: facts,
                    system: System(), effects: effects, text: text)
                weak var owner = runtime
                t.equal(runtime?.updateCount, 0)
                t.check(text?.cycles.isEmpty == true)
                try runtime?.update(); try runtime?.startTimer()
                var finalPixels: Data?
                for index in 0...60 {
                    if index > 0 { time.advance(by: 1) }
                    guard let runtime, let text else { throw Failure.input }
                    t.equal(runtime.updateCount, index + 1)
                    let scene = try runtime.project(environment: environment)
                    t.equal(scene, scenes[index], "all scene facts at \(index)s, \(scale)x")
                    if let expected = images[index] {
                        let builds = text.context.text.builds
                        let actual = try pixels(scene, scale: scale, cycle: runtime.updateCount, context: text.context)
                        // A clipped box can need a wrapped layout after naturalSize's unwrapped measurement.
                        // Both owners must share the same cache and perform the same extra work, not force zero.
                        t.equal(text.context.text.builds - builds, drawBuilds[index])
                        t.check(actual.contains { $0 != 0 }, "native output is nonempty")
                        t.equal(actual, expected, "strict active RGBA at \(index)s, \(scale)x")
                        let after = text.context.text.builds
                        t.equal(try pixels(scene, scale: scale, cycle: runtime.updateCount, context: text.context), actual)
                        t.equal(text.context.text.builds, after, "the repeated draw reuses its layouts")
                        var omitted = scene
                        omitted.elements.removeAll { $0.id.name == omittedMeter }
                        t.equal(omitted.elements.count, scene.elements.count - 1, "the visible canary is actually removed")
                        t.check(try pixels(omitted, scale: scale, cycle: runtime.updateCount, context: text.context) != actual)
                        if index == 60 { finalPixels = actual }
                    }
                }
                t.equal(time.now, 60)
                t.equal(text?.cycles, cycles, "same measurement order and cache cycles")
                t.equal(runtime?.failure, nil)
                t.equal(effects.records, [])
                t.equal(time.background.reports, [])
                runtime?.close(); runtime = nil; text = nil
                t.check(owner == nil && service == nil && context == nil)
                t.equal(time.pendingCount, 0)
                guard let last = scenes.last, let finalPixels else { throw Failure.input }
                t.equal(try pixels(last, scale: scale, cycle: 61, context: DrawContext(fonts: AppFontResolver())), finalPixels,
                        "pure scene replays on a cold context after owner release")
            }
        }
        t.equal(try Data(contentsOf: file), bytes)
    }

    private static func qualifyNumericGraph(_ name: String, _ t: AppTestRunner) throws {
        let relative = "App/\(name)/\(name).ini", config = "App\\" + name
        guard let source = Paths.repositoryFolder("TestSkins")?.appendingPathComponent(relative) else { throw Failure.input }
        let bytes = try Data(contentsOf: source), skins = t.temporaryDirectory("rainmeter-native-" + name)
        let file = skins.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        let manual = name == "Observer", last = manual ? 62 : 60
        for appearance in [SkinAppearance.light, .dark] {
            for scale in [1, 2] {
                let environment = Environment(appearance, scale)
                var facts = RecordingSkinHost.fixedEnvironment
                facts.appearance = appearance
                let effects = RecordingSideEffects(skinsDirectory: skins), conversionTime = try clock()
                let program = try IniProgramConverter.convert(config: config, fileURL: file, skinsDirectory: skins,
                    system: System(), environment: facts, clock: conversionTime.clock, executor: conversionTime, effects: effects)
                t.equal(program.sourceBytes, bytes)
                t.equal(conversionTime.pendingCount, 0)
                var scenes: [WidgetScene] = [], cycles: [Int] = []
                var images: [Int: Data] = [:], builds: [Int: Int] = [:]
                weak var oldSkin: Skin?
                weak var oldContext: DrawContext?
                do {
                    let text = Text(), host = Host(text, facts), time = try clock(), projector = SceneProjector()
                    oldContext = text.context
                    let skin = Skin(config: config, fileURL: file, skinsDirectory: skins, system: System(), host: host)
                    oldSkin = skin
                    skin.runInVirtualTime(time); skin.sideEffects = effects; skin.random = SkinRandom(seed: 1)
                    try skin.load()
                    t.equal(skin.updateCount, 0)
                    t.check(text.cycles.isEmpty)
                    let scheduler = TickScheduler(), target = SkinTick(skin)
                    skin.update(); scheduler.startTimer(for: target)
                    for index in 0...last {
                        if index > 0 && index <= 60 { time.advance(by: 1) }
                        if index > 60 { skin.update() } // Explicit updates: Observer's Update=-1 has no timer.
                        let scene = projector.project(skin, environment: environment)
                        scenes.append(scene)
                        t.equal(skin.updateCount, manual ? max(1, index - 59) : index + 1)
                        if [0, 1, 60, last].contains(index) {
                            let before = text.context.text.builds
                            images[index] = try pixels(scene, scale: scale, cycle: skin.updateCount, context: text.context)
                            builds[index] = text.context.text.builds - before
                        }
                    }
                    t.equal(time.now, 60)
                    t.equal(skin.issues, [])
                    cycles = text.cycles
                    scheduler.cancel(); skin.close()
                    t.equal(time.pendingCount, 0)
                }
                t.check(oldSkin == nil && oldContext == nil, "old numeric owner and its native cache have released")
                let time = try clock()
                var text: Text? = Text()
                weak var service = text
                weak var context = text?.context
                var runtime: RainmeterProgramRuntime? = try RainmeterProgramRuntime(
                    program: program, executor: time, clock: time.clock, environment: facts,
                    system: System(), effects: effects, text: text)
                weak var owner = runtime
                try runtime?.update(); try runtime?.startTimer()
                var finalPixels: Data?
                for index in 0...last {
                    if index > 0 && index <= 60 { time.advance(by: 1) }
                    if index > 60 { try runtime?.update() }
                    guard let runtime, let text else { throw Failure.input }
                    let count = manual ? max(1, index - 59) : index + 1
                    t.equal(runtime.updateCount, count)
                    let scene = try runtime.project(environment: environment)
                    t.equal(scene, scenes[index], "numeric scene at \(index), \(scale)x")
                    if let expected = images[index] {
                        let before = text.context.text.builds
                        let actual = try pixels(scene, scale: scale, cycle: count, context: text.context)
                        t.equal(text.context.text.builds - before, builds[index])
                        t.check(actual.contains { $0 != 0 }, "actual native pixels, not an empty success")
                        t.equal(actual, expected, "strict numeric RGBA at \(index), \(scale)x")
                        let after = text.context.text.builds
                        t.equal(try pixels(scene, scale: scale, cycle: count, context: text.context), actual)
                        t.equal(text.context.text.builds, after)
                        var omitted = scene
                        omitted.elements.removeAll { $0.id.name == "metertext" }
                        t.equal(omitted.elements.count, scene.elements.count - 1)
                        t.check(try pixels(omitted, scale: scale, cycle: count, context: text.context) != actual,
                                "omitting the only visible numeric meter must change bytes")
                        if index == last { finalPixels = actual }
                    }
                }
                t.equal(text?.cycles, cycles)
                t.equal(time.now, 60)
                t.equal(runtime?.failure, nil)
                t.equal(runtime?.logs, [])
                t.equal(effects.records, [])
                t.equal(time.background.reports, [])
                runtime?.close(); runtime = nil; text = nil
                t.check(owner == nil && service == nil && context == nil)
                t.equal(time.pendingCount, 0)
                guard let scene = scenes.last, let finalPixels else { throw Failure.input }
                t.equal(try pixels(scene, scale: scale, cycle: manual ? 3 : 61,
                                   context: DrawContext(fonts: AppFontResolver())), finalPixels)
            }
        }
        t.equal(try Data(contentsOf: file), bytes)
    }

    private static func pixels(_ scene: WidgetScene, scale: Int, cycle: Int, context: DrawContext) throws -> Data {
        let w = ceil(scene.size.width * Double(scale)), h = ceil(scene.size.height * Double(scale))
        guard w.isFinite, h.isFinite, w > 0, h > 0, w <= 2048, h <= 2048 else { throw Failure.bitmap }
        let width = Int(w), height = Int(h)
        guard width * height * 4 <= 16 * 1024 * 1024,
              let color = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = ctx.data else { throw Failure.bitmap }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        DesksetDraw.DrawExecutor.draw(scene: scene, in: ctx, context: context, cycle: cycle,
                                     target: DrawTarget.prepareOwnedBitmap(ctx, glass: .none))
        var output = Data(capacity: width * height * 4)
        for row in 0..<height {
            output.append(bytes.advanced(by: row * ctx.bytesPerRow).assumingMemoryBound(to: UInt8.self), count: width * 4)
        }
        return output
    }
}
