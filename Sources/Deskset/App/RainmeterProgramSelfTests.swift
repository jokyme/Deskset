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
        for worker in [false, true] {
            t.suite("App: Rainmeter Power: real \(worker ? "worker" : "main") owns battery projection and retirement") {
                try livePowerOwner(t, worker: worker)
            }
            t.suite("App: Rainmeter SysInfo: real \(worker ? "worker" : "main") owns sampling projection and retirement") {
                try liveSysInfoOwner(t, worker: worker)
            }
        }
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
        t.suite("App: Rainmeter bitmap owner: real worker exclusive ownership is not physical thread identity") {
            let executor = SkinThreadExecutor(name: "Native ownership negative control")
            defer { executor.stop() }
            let held = Guarded<ReleaseProbe?>(nil), ready = Guarded(false)
            let releases = Guarded<[(Bool, Bool)]>([])
            executor.async {
                held.access { $0 = ReleaseProbe(executor, releases) }
                ready.access { $0 = true }
            }
            guard AppSelfTest.spin(timeout: 30, until: { ready.current }) else { throw Failure.clock }
            let owned = executor.exclusive(timeout: 30) {
                held.access { $0 = nil }
                return executor.isCurrent
            }
            t.equal(owned, true)
            t.equal(releases.current.count, 1)
            t.check(releases.current.allSatisfy { $0.0 && $0.1 },
                    "a parked worker explicitly authorizes release on main; physical-thread tests must use async")
        }
        t.suite("App: Rainmeter bitmap owner: real fast worker consumes retirement before posting returns") {
            let (program, skins, _, _) = try bitmapInput(t, "Counter")
            let base = SkinThreadExecutor(name: "Fast retirement worker")
            defer { base.stop() }
            let executor = FastRetirementExecutor(base)
            let held = Guarded<RainmeterProgramHost?>(nil), ready = Guarded(false)
            let releases = Guarded<[(Bool, Bool)]>([]), errors = Guarded<[String]>([])
            base.async {
                do {
                    let probe = ReleaseProbe(executor, releases)
                    let clock = SkinClock(now: { withExtendedLifetime(probe) { Date(timeIntervalSince1970: 0) } },
                        uptime: { 0 }, timeZone: { TimeZone(secondsFromGMT: 0)! })
                    held.access { value in
                        do {
                            value = try RainmeterProgramHost(program: program, executor: executor, provider: nil,
                                environment: RecordingSkinHost.fixedEnvironment, clock: clock, system: System(),
                                effects: RecordingSideEffects(skinsDirectory: skins))
                        } catch { errors.access { $0.append(String(describing: error)) } }
                    }
                }
                ready.access { $0 = true }
            }
            t.check(AppSelfTest.spin(timeout: 30) { ready.current })
            t.equal(errors.current, [])
            executor.beforeReturn = { releases.current }
            executor.armed = true
            held.access { $0 = nil }
            t.equal(executor.completed.current, true)
            t.equal(executor.observed.current.count, 1)
            t.check(executor.observed.current.allSatisfy { $0.0 && !$0.1 }, "release must precede posting return")
            t.equal(releases.current.count, 1)
            t.check(releases.current.allSatisfy { $0.0 && !$0.1 },
                    "fast-worker final release: \(releases.current)")
        }
        for worker in [false, true] {
            t.suite("App: Rainmeter bitmap owner: real \(worker ? "worker" : "main") executor owns ticks frames and final release") {
                try liveBitmapOwner(t, worker: worker)
            }
            t.suite("App: Rainmeter bitmap owner: real \(worker ? "worker" : "main") Quote IO returns and retires on its owner") {
                try liveQuoteOwner(t, worker: worker)
            }
        }
    }

    /// Only the return hop is held. Quote still constructs its real BackgroundJob and reads the
    /// real file on PluginIO.queue; this is neither VirtualTimeExecutor nor a background fake.
    /// All released work runs on the actual main/worker executor, never a parked exclusive loan.
    private final class FastRetirementExecutor: SkinExecutor {
        let base: SkinThreadExecutor
        let completed = Guarded(false)
        let observed = Guarded<[(Bool, Bool)]>([])
        var armed = false // only the posting main thread arms and consumes this handshake
        var beforeReturn: (() -> [(Bool, Bool)])?
        init(_ base: SkinThreadExecutor) { self.base = base }
        var isCurrent: Bool { base.isCurrent }
        func async(_ work: @escaping () -> Void) {
            if base.isCurrent || !armed { base.async(work); return }
            armed = false
            let done = DispatchSemaphore(value: 0)
            base.async(work)
            base.async { done.signal() }
            completed.access { $0 = done.wait(timeout: .now() + 30) == .success }
            observed.access { $0 = beforeReturn?() ?? [] }
            withExtendedLifetime(work) {}
        }
        func async(after delay: TimeInterval, _ work: @escaping () -> Void) -> SkinScheduledWork {
            base.async(after: delay, work)
        }
        func timer(interval: TimeInterval, leeway: TimeInterval, repeats: Bool,
                   _ fire: @escaping () -> Void) -> SkinScheduledWork {
            base.timer(interval: interval, leeway: leeway, repeats: repeats, fire)
        }
    }

    private final class QuoteDeliveryGate: SkinExecutor {
        let base: SkinExecutor
        let pending = Guarded<[() -> Void]>([])
        let posts = Guarded<[(Bool, Bool)]>([])
        init(_ base: SkinExecutor) { self.base = base }
        var isCurrent: Bool { base.isCurrent }
        func async(_ work: @escaping () -> Void) {
            posts.access { $0.append((base.isCurrent, Thread.isMainThread)) }
            pending.access { $0.append(work) }
        }
        func async(after delay: TimeInterval, _ work: @escaping () -> Void) -> SkinScheduledWork {
            base.async(after: delay, work)
        }
        func timer(interval: TimeInterval, leeway: TimeInterval, repeats: Bool,
                   _ fire: @escaping () -> Void) -> SkinScheduledWork {
            base.timer(interval: interval, leeway: leeway, repeats: repeats, fire)
        }
        func deliverOnOwner() {
            precondition(base.isCurrent)
            let work = pending.access { value -> [() -> Void] in
                let result = value; value.removeAll(); return result
            }
            for body in work { body() }
        }
    }

    private static func quoteTexts(_ items: [DrawItem]) -> [String] {
        items.flatMap { item -> [String] in
            switch item {
            case .text(let value): return [value.text]
            case .transformed(_, let children), .antialias(_, let children): return quoteTexts(children)
            case .container(_, let mask, let content): return quoteTexts(mask) + quoteTexts(content)
            default: return []
            }
        }
    }

    private static func liveQuoteOwner(_ t: AppTestRunner, worker: Bool) throws {
        for retirement in ["live", "close", "release"] {
            let skins = t.temporaryDirectory("native-quote-" + retirement)
            let file = skins.appendingPathComponent("Quote/Main.ini")
            let asset = skins.appendingPathComponent("Quote/@Resources/quotes.txt")
            try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "Native Quote payload\n".write(to: asset, atomically: true, encoding: .utf8)
            try """
            [Rainmeter]
            Update=1000
            [Q]
            Measure=Plugin
            Plugin=QuotePlugin
            PathName=#@#quotes.txt
            UpdateDivider=-1
            [Text]
            Meter=String
            MeasureName=Q
            Text=%1
            W=240
            H=30
            """.write(to: file, atomically: true, encoding: .utf8)
            let conversion = try clock(), effects = RecordingSideEffects(skinsDirectory: skins)
            let program = try IniProgramConverter.convert(config: "Quote", fileURL: file, skinsDirectory: skins,
                system: System(), environment: RecordingSkinHost.fixedEnvironment, clock: conversion.clock,
                executor: conversion, effects: effects)
            t.equal(conversion.pendingCount, 0)
            t.equal(conversion.background.reports, [])
            let base: SkinExecutor = worker ? SkinThreadExecutor(name: "Native Quote owner") : MainSkinExecutor.shared
            let gate = QuoteDeliveryGate(base), held = Guarded<RainmeterProgramRuntime?>(nil)
            let weakOwner = WeakBitmapOwner(), errors = Guarded<[String]>([])
            let reads = Guarded<[(Bool, Bool)]>([]), updates = Guarded(0)
            let releases = Guarded<[(Bool, Bool)]>([])
            let scenes = Guarded<[WidgetScene]>([])
            let counts = Guarded<[Int]>([])
            let environment = Environment(.light, 1)
            func onOwner(_ body: @escaping () throws -> Void) throws {
                let done = Guarded(false)
                base.async {
                    do { try body() } catch { errors.access { $0.append(String(describing: error)) } }
                    done.access { $0 = true }
                }
                guard AppSelfTest.spin(timeout: 30, until: { done.current }) else { throw Failure.clock }
                t.equal(errors.current, [])
                guard errors.current.isEmpty else { throw Failure.input }
            }
            defer {
                try? onOwner { held.access { $0?.close(); $0 = nil }; gate.deliverOnOwner() }
                (base as? SkinThreadExecutor)?.stop()
            }
            try onOwner {
                let probe = ReleaseProbe(base, releases)
                let fixed = conversion.clock
                let dataClock = SkinClock(now: fixed.now, uptime: {
                    withExtendedLifetime(probe) {
                        reads.access { $0.append((base.isCurrent, Thread.isMainThread)) }
                        return 86_400
                    }
                }, timeZone: fixed.timeZone)
                let runtime = try RainmeterProgramRuntime(program: program, executor: gate, clock: dataClock,
                    environment: RecordingSkinHost.fixedEnvironment, system: System(), effects: effects,
                    random: SkinRandom(seed: 1), text: Text())
                weakOwner.engine = runtime
                runtime.didUpdate = { updates.access { $0 += 1 } }
                held.access { $0 = runtime }
                try runtime.update()
                let scene = try runtime.project(environment: environment)
                scenes.access { $0.append(scene) }
            }
            guard AppSelfTest.spin(timeout: 30, until: { gate.pending.current.count == 1 }) else { throw Failure.clock }
            t.equal(gate.posts.current.count, 1, "one real PluginIO result, not a synthetic Counter fixture")
            t.check(gate.posts.current.allSatisfy { !$0.0 && !$0.1 }, "file production returns from a background thread")
            t.equal(updates.current, 1)
            let readsBefore = reads.current.count
            t.check(readsBefore > 0)
            t.check(!quoteTexts(scenes.current[0].drawingItems).contains("Native Quote payload"))
            // The job has already produced its result. Removing the file proves delivery is not another read.
            try FileManager.default.removeItem(at: asset)
            try onOwner {
                if retirement != "live" { held.current?.close() }
                if retirement == "release" { held.access { $0 = nil } }
            }
            if retirement == "release" {
                t.check(weakOwner.engine == nil, "a produced but undelivered result does not retain the owner")
                t.equal(releases.current.count, 1)
            }
            try onOwner {
                gate.deliverOnOwner()
                if let runtime = held.current {
                    counts.access { $0.append(runtime.updateCount) }
                    if retirement == "live" {
                        let scene = try runtime.project(environment: environment)
                        scenes.access { $0.append(scene) }
                    }
                }
            }
            t.equal(gate.pending.current.count, 0)
            t.equal(updates.current, 1, "completion never invents an engine/meter tick")
            t.equal(reads.current.count, readsBefore + (retirement == "live" ? 1 : 0),
                    "only a live Quote completion reads loadedAt; retired results are dropped")
            t.check(reads.current.allSatisfy { $0.0 && $0.1 != worker }, "Quote completion runs on its physical owner")
            if retirement == "live" {
                t.equal(counts.current, [1])
                t.equal(scenes.current[1].drawingItems, scenes.current[0].drawingItems,
                        "the completed measure must not update its meter early")
                try onOwner {
                    guard let runtime = held.current else { throw Failure.input }
                    runtime.updateForTick() // the normal TickTarget entry, not an async completion update
                    let scene = try runtime.project(environment: environment)
                    scenes.access { $0.append(scene) }
                    counts.access { $0.append(runtime.updateCount) }
                }
                t.equal(counts.current, [1, 2])
                t.equal(updates.current, 2)
                t.check(quoteTexts(scenes.current[2].drawingItems).contains("Native Quote payload"),
                        "the next ordinary tick sees the actual file result even with UpdateDivider=-1")
                t.equal(gate.posts.current.count, 1, "no second read was needed after the file disappeared")
                t.check(try pixels(scenes.current[2], scale: 1, cycle: 2,
                                   context: DrawContext(fonts: AppFontResolver())).contains { $0 != 0 })
            } else if retirement == "close" {
                t.equal(counts.current, [1])
                t.check(weakOwner.engine != nil, "close/drop is tested separately from owner destruction")
            }
            try onOwner { held.access { $0?.close(); $0 = nil } }
            t.check(weakOwner.engine == nil)
            t.equal(releases.current.count, 1)
            t.check(releases.current.allSatisfy { $0.0 && $0.1 != worker })
            t.equal(effects.records, [])
        }
    }

    /// Deliberately separate from System: unrelated suites must still trap on every system read.
    private final class PowerSystem: SystemDataSource, HardwareSensorSource {
        let forbidden = System()
        let executor: SkinExecutor
        let reads: Guarded<[(Bool, Bool)]>
        let forbiddenReads: Guarded<[String]>
        var answer = BatteryStatus(percent: 75, isCharging: false, isPluggedIn: false, minutesRemaining: 90)
        init(_ executor: SkinExecutor, _ reads: Guarded<[(Bool, Bool)]>, _ forbiddenReads: Guarded<[String]>) {
            self.executor = executor; self.reads = reads; self.forbiddenReads = forbiddenReads
        }
        var processorCount: Int { forbidden.processorCount }
        func cpuUsage(processor: Int) -> Double { forbidden.cpuUsage(processor: processor) }
        func memoryStatus() -> MemoryStatus { forbidden.memoryStatus() }
        func networkInterfaces() -> [String] { forbiddenReads.access { $0.append("interfaces") }; return [] }
        func networkCounters(interface: String?) -> NetworkCounters {
            forbiddenReads.access { $0.append("network") }; return NetworkCounters()
        }
        func diskSpace(path: String) -> (total: Double, free: Double)? { forbidden.diskSpace(path: path) }
        func uptime() -> TimeInterval { forbidden.uptime() }
        func isProcessRunning(_ name: String) -> Bool { forbidden.isProcessRunning(name) }
        func sysInfo(type: String, data: String) -> (number: Double, string: String?)? {
            forbidden.sysInfo(type: type, data: data)
        }
        func battery() -> BatteryStatus? {
            reads.access { $0.append((executor.isCurrent, Thread.isMainThread)) }; return answer
        }
        func batteryDetails() -> BatteryDetailsReading {
            forbiddenReads.access { $0.append("details") }; return .ready(BatteryDetails())
        }
        func cpuFrequency() -> Double? { forbiddenReads.access { $0.append("frequency") }; return nil }
        func sensorValue(_ key: String) -> Double? { forbiddenReads.access { $0.append("sensor:" + key) }; return nil }
    }

    /// Explicit normal ticks qualify owner confinement and projection, not hardware acquisition or timer delivery.
    private static func livePowerOwner(_ t: AppTestRunner, worker: Bool) throws {
        let skins = t.temporaryDirectory("native-power-" + (worker ? "worker" : "main"))
        let file = skins.appendingPathComponent("Power.ini")
        let source = """
        [Rainmeter]
        Update=-1
        [Percent]
        Measure=Plugin
        Plugin=PowerPlugin
        PowerState=Percent
        [ACLine]
        Measure=Plugin
        Plugin=PowerPlugin
        PowerState=ACLine
        [Status]
        Measure=Plugin
        Plugin=PowerPlugin
        PowerState=Status
        [Status2]
        Measure=Plugin
        Plugin=PowerPlugin
        PowerState=Status2
        [Lifetime]
        Measure=Plugin
        Plugin=PowerPlugin
        PowerState=Lifetime
        [Disabled]
        Measure=Plugin
        Plugin=PowerPlugin
        PowerState=Percent
        Disabled=1
        [Paused]
        Measure=Plugin
        Plugin=PowerPlugin
        PowerState=Percent
        Paused=1
        [Display]
        Meter=String
        MeasureName=Percent
        MeasureName2=ACLine
        MeasureName3=Status
        MeasureName4=Status2
        MeasureName5=Lifetime
        Text=%1|%2|%3|%4|%5
        FontSize=14
        FontColor=255,255,255,255
        W=500
        H=40
        """
        try source.write(to: file, atomically: true, encoding: .utf8)
        let effects = RecordingSideEffects(skinsDirectory: skins), conversion = try clock()
        var initial = RecordingSkinHost.fixedEnvironment
        initial.locale = Locale(identifier: "en_US_POSIX")
        let executor: SkinExecutor = worker ? SkinThreadExecutor(name: "Native Power owner") : MainSkinExecutor.shared
        let held = Guarded<RainmeterProgramHost?>(nil), errors = Guarded<[String]>([])
        let reads = Guarded<[(Bool, Bool)]>([]), forbiddenReads = Guarded<[String]>([])
        let releases = Guarded<[(Bool, Bool)]>([]), ownership = Guarded<[Bool]>([])
        let scenes = Guarded<[WidgetScene]>([]), weakOwner = WeakBitmapOwner()
        let system = PowerSystem(executor, reads, forbiddenReads)
        let environment = Environment(.light, 1)
        func onOwner(_ body: @escaping () throws -> Void) throws {
            let done = Guarded(false)
            executor.async {
                do { try body() } catch { errors.access { $0.append(String(describing: error)) } }
                done.access { $0 = true }
            }
            guard AppSelfTest.spin(timeout: 30, until: { done.current }) else { throw Failure.clock }
            t.equal(errors.current, [])
            guard errors.current.isEmpty else { throw Failure.input }
        }
        defer {
            try? onOwner { held.access { $0?.close(); $0 = nil } }
            (executor as? SkinThreadExecutor)?.stop()
        }
        let program = try IniProgramConverter.convert(config: "Power", fileURL: file, skinsDirectory: skins,
            system: system, environment: initial, clock: conversion.clock, executor: conversion, effects: effects)
        t.equal(reads.current.count, 0, "conversion does not sample battery")
        t.equal(conversion.pendingCount, 0)
        t.equal(conversion.background.reports, [])
        try onOwner {
            let probe = ReleaseProbe(executor, releases)
            let fixed = conversion.clock
            let dataClock = SkinClock(now: { withExtendedLifetime(probe) { fixed.now() } },
                uptime: fixed.uptime, timeZone: fixed.timeZone)
            let host = try RainmeterProgramHost(program: program, executor: executor, provider: nil,
                environment: initial, clock: dataClock, system: system, effects: effects)
            weakOwner.engine = host.engine; weakOwner.context = host.context
            held.access { $0 = host }
            t.equal(host.engine.updateCount, 0)
            t.equal(reads.current.count, 0, "initialization does not sample battery")
            try host.start()
            ownership.access { $0.append(executor.isCurrent && Thread.isMainThread != worker) }
            t.equal(host.engine.updateCount, 1)
            t.equal(reads.current.count, 5, "exactly one battery read per active Power node")
            let scene = try host.engine.project(environment: environment)
            scenes.access { $0.append(scene) }
        }
        t.equal(ownership.current, [true])
        t.equal(quoteTexts(scenes.current[0].drawingItems), ["75|0|4|1|01:30"])
        try onOwner {
            guard let host = held.current else { throw Failure.input }
            system.answer = BatteryStatus(percent: 4, isCharging: true, isPluggedIn: true, minutesRemaining: 90)
            t.equal(host.engine.updateCount, 1)
            t.equal(try host.engine.project(environment: environment).drawingItems, scenes.current[0].drawingItems,
                    "provider changes and projection do not sample or invent a tick")
            t.equal(reads.current.count, 5)
            host.engine.updateForTick()
            t.equal(host.engine.updateCount, 2)
            t.equal(host.engine.failure, nil)
            let scene = try host.engine.project(environment: environment)
            scenes.access { $0.append(scene) }
            t.equal(quoteTexts(scene.drawingItems), ["4|1|1|14|Unknown"])
            t.equal(reads.current.count, 10)
            // Static inactive nodes remain unread; state reactivation is covered by Core tests.
            host.pause()
            t.equal(reads.current.count, 10)
            try host.resume(updateNow: false)
            t.equal(reads.current.count, 10, "resume without update must not sample")
            host.engine.updateForTick()
            t.equal(reads.current.count, 15, "only the five active nodes sample on the next normal tick")
            host.close()
            host.engine.updateForTick()
            do { try host.update(); t.check(false, "closed host cannot sample") }
            catch let error as RainmeterProgramError { t.equal(error, .closed) }
            t.equal(reads.current.count, 15)
        }
        t.check(reads.current.allSatisfy { $0.0 && $0.1 != worker }, "every battery read uses its physical owner")
        let first = try pixels(scenes.current[0], scale: 1, cycle: 1, context: DrawContext(fonts: AppFontResolver()))
        let second = try pixels(scenes.current[1], scale: 1, cycle: 2, context: DrawContext(fonts: AppFontResolver()))
        t.check(first.contains { $0 != 0 } && second.contains { $0 != 0 })
        t.check(first != second, "the ordinary tick changes native visible Power text pixels")
        // Exercise Host.Retirement with the final host release off its owner thread.
        if worker { held.access { $0 = nil } }
        else { DispatchQueue.global().async { held.access { $0 = nil } } }
        t.check(AppSelfTest.spin(timeout: 30) {
            !releases.current.isEmpty && weakOwner.engine == nil && weakOwner.context == nil
        })
        t.equal(releases.current.count, 1)
        t.check(releases.current.allSatisfy { $0.0 && $0.1 != worker }, "Power bundle releases on its physical owner")
        t.check(weakOwner.engine == nil && weakOwner.context == nil)
        t.equal(reads.current.count, 15)
        t.equal(forbiddenReads.current, [], "no sensor, frequency, details or network reads")
        t.equal(effects.records, [], "no actions")
        t.equal(errors.current, [])
        t.equal(try String(contentsOf: file, encoding: .utf8), source)
    }

    private final class SysInfoSystem: SystemDataSource {
        let forbidden = System()
        let executor: SkinExecutor
        let reads: Guarded<[(String, String, Bool, Bool)]>
        let networkReads: Guarded<Int>
        var user = "native-user"
        var idle = 42.0
        init(_ executor: SkinExecutor, _ reads: Guarded<[(String, String, Bool, Bool)]>, _ networkReads: Guarded<Int>) {
            self.executor = executor; self.reads = reads; self.networkReads = networkReads
        }
        var processorCount: Int { forbidden.processorCount }
        func cpuUsage(processor: Int) -> Double { forbidden.cpuUsage(processor: processor) }
        func memoryStatus() -> MemoryStatus { forbidden.memoryStatus() }
        func networkInterfaces() -> [String] { networkReads.access { $0 += 1 }; return [] }
        func networkCounters(interface: String?) -> NetworkCounters {
            networkReads.access { $0 += 1 }; return NetworkCounters()
        }
        func diskSpace(path: String) -> (total: Double, free: Double)? { forbidden.diskSpace(path: path) }
        func uptime() -> TimeInterval { forbidden.uptime() }
        func battery() -> BatteryStatus? { forbidden.battery() }
        func isProcessRunning(_ name: String) -> Bool { forbidden.isProcessRunning(name) }
        func sysInfo(type: String, data: String) -> (number: Double, string: String?)? {
            reads.access { $0.append((type, data, executor.isCurrent, Thread.isMainThread)) }
            switch type {
            case "USER_NAME": return (0, user)
            case "IDLE_TIME": return (idle, nil)
            default: preconditionFailure("Unexpected SysInfo source query: \(type):\(data)")
            }
        }
    }

    private static func liveSysInfoOwner(_ t: AppTestRunner, worker: Bool) throws {
        let skins = t.temporaryDirectory("native-sysinfo-" + (worker ? "worker" : "main"))
        let file = skins.appendingPathComponent("SysInfo.ini")
        let source = """
        [Rainmeter]
        Update=-1
        [Width]
        Measure=SysInfo
        SysInfoType=SCREEN_WIDTH
        [Zone]
        Measure=SysInfo
        SysInfoType=TIMEZONE_BIAS
        [User]
        Measure=SysInfo
        SysInfoType=USER_NAME
        SysInfoData=en0
        [Idle]
        Measure=SysInfo
        SysInfoType=IDLE_TIME
        [Disabled]
        Measure=SysInfo
        SysInfoType=IDLE_TIME
        Disabled=1
        [Paused]
        Measure=SysInfo
        SysInfoType=IDLE_TIME
        Paused=1
        [Display]
        Meter=String
        MeasureName=Width
        MeasureName2=Zone
        MeasureName3=User
        MeasureName4=Idle
        Text=%1|%2|%3|%4
        FontSize=14
        FontColor=255,255,255,255
        W=500
        H=40
        """
        try source.write(to: file, atomically: true, encoding: .utf8)
        let effects = RecordingSideEffects(skinsDirectory: skins), conversion = try clock()
        var initial = RecordingSkinHost.fixedEnvironment
        initial.locale = Locale(identifier: "en_US_POSIX")
        initial.screens = [SkinScreen(area: SkinRect(width: 1234, height: 800), workArea: SkinRect(width: 1234, height: 780))]
        let program = try IniProgramConverter.convert(config: "SysInfo", fileURL: file, skinsDirectory: skins,
            system: System(), environment: initial, clock: conversion.clock, executor: conversion, effects: effects)
        t.equal(conversion.pendingCount, 0)
        t.equal(conversion.background.reports, [])
        let executor: SkinExecutor = worker ? SkinThreadExecutor(name: "Native SysInfo owner") : MainSkinExecutor.shared
        let held = Guarded<RainmeterProgramHost?>(nil), errors = Guarded<[String]>([])
        let reads = Guarded<[(String, String, Bool, Bool)]>([]), networkReads = Guarded(0)
        let releases = Guarded<[(Bool, Bool)]>([]), ownership = Guarded<[Bool]>([])
        let scenes = Guarded<[WidgetScene]>([]), weakOwner = WeakBitmapOwner()
        let system = SysInfoSystem(executor, reads, networkReads)
        let environment = Environment(.light, 1)
        func onOwner(_ body: @escaping () throws -> Void) throws {
            let done = Guarded(false)
            executor.async {
                do { try body() } catch { errors.access { $0.append(String(describing: error)) } }
                done.access { $0 = true }
            }
            guard AppSelfTest.spin(timeout: 30, until: { done.current }) else { throw Failure.clock }
            t.equal(errors.current, [])
            guard errors.current.isEmpty else { throw Failure.input }
        }
        defer {
            try? onOwner { held.access { $0?.close(); $0 = nil } }
            (executor as? SkinThreadExecutor)?.stop()
        }
        try onOwner {
            let probe = ReleaseProbe(executor, releases)
            let fixed = conversion.clock
            let dataClock = SkinClock(now: { withExtendedLifetime(probe) { fixed.now() } },
                uptime: fixed.uptime, timeZone: fixed.timeZone)
            let host = try RainmeterProgramHost(program: program, executor: executor, provider: nil,
                environment: initial, clock: dataClock, system: system, effects: effects)
            weakOwner.engine = host.engine; weakOwner.context = host.context
            held.access { $0 = host }
            try host.start()
            ownership.access { $0.append(executor.isCurrent && Thread.isMainThread != worker) }
            t.equal(host.engine.updateCount, 1)
            let scene = try host.engine.project(environment: environment)
            scenes.access { $0.append(scene) }
        }
        t.equal(ownership.current, [true])
        t.equal(reads.current.map { $0.0 + ":" + $0.1 }, ["USER_NAME:en0", "IDLE_TIME:"])
        t.equal(quoteTexts(scenes.current[0].drawingItems), ["1234|0|native-user|42"])
        try onOwner {
            guard let host = held.current else { throw Failure.input }
            var changed = initial
            changed.screens = [SkinScreen(area: SkinRect(width: 2345, height: 900), workArea: SkinRect(width: 2345, height: 880))]
            system.user = "next-user"; system.idle = 84
            host.take(SkinWindowFacts(frame: .zero, isVisible: true, isOrderedIn: true, scale: 1,
                colorSpace: SkinFrameProducer.sRGB, takesPointer: true, sequence: 1), environment: changed)
            t.equal(host.engine.updateCount, 1)
            t.equal(try host.engine.project(environment: environment).drawingItems, scenes.current[0].drawingItems,
                    "publishing environment and projecting do not sample or invent a tick")
            t.equal(reads.current.count, 2)
            host.engine.updateForTick()
            t.equal(host.engine.updateCount, 2)
            t.equal(host.engine.failure, nil)
            let scene = try host.engine.project(environment: environment)
            scenes.access { $0.append(scene) }
            t.equal(quoteTexts(scene.drawingItems), ["2345|0|next-user|84"])
            t.equal(reads.current.count, 4)
            // Static inactive measures remain unread on every real owner tick; Core tests cover reactivation.
            host.pause()
            t.equal(reads.current.count, 4)
            try host.resume(updateNow: false)
            t.equal(reads.current.count, 4, "resume without update must not sample")
            host.engine.updateForTick()
            t.equal(reads.current.count, 6, "only the two active provider-backed measures sample")
            host.close()
            do { try host.update(); t.check(false, "closed host cannot sample") }
            catch let error as RainmeterProgramError { t.equal(error, .closed) }
            t.equal(reads.current.count, 6)
        }
        t.check(reads.current.allSatisfy { $0.2 && $0.3 != worker }, "every SysInfo read uses its physical owner")
        let first = try pixels(scenes.current[0], scale: 1, cycle: 1, context: DrawContext(fonts: AppFontResolver()))
        let second = try pixels(scenes.current[1], scale: 1, cycle: 2, context: DrawContext(fonts: AppFontResolver()))
        t.check(first.contains { $0 != 0 } && second.contains { $0 != 0 })
        t.check(first != second, "the ordinary tick changes native visible text pixels")
        // Exercise Host.Retirement, not an exclusive loan or an on-owner final release.
        if worker { held.access { $0 = nil } }
        else { DispatchQueue.global().async { held.access { $0 = nil } } }
        t.check(AppSelfTest.spin(timeout: 30) {
            !releases.current.isEmpty && weakOwner.engine == nil && weakOwner.context == nil
        })
        t.equal(releases.current.count, 1)
        t.check(releases.current.allSatisfy { $0.0 && $0.1 != worker }, "SysInfo bundle releases on its physical owner")
        t.check(weakOwner.engine == nil && weakOwner.context == nil)
        t.equal(reads.current.count, 6)
        t.equal(networkReads.current, 0)
        t.equal(effects.records, [])
        t.equal(errors.current, [])
        t.equal(try String(contentsOf: file, encoding: .utf8), source)
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
        // exclusive parks the worker and lends ownership to main; it is not a native-thread hop.
        // In particular, releasing callbacks/caches there cannot prove physical worker confinement.
        func onOwner<T>(_ body: @escaping () -> T) -> T? {
            let result = Guarded<T?>(nil), done = Guarded(false)
            executor.async {
                result.access { $0 = body() }
                done.access { $0 = true }
            }
            guard AppSelfTest.spin(timeout: 30, until: { done.current }) else { return nil }
            return result.current
        }
        defer {
            _ = onOwner { held.access { $0?.close(); $0 = nil } }
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
        t.equal(onOwner { held.current?.engine.updateCount }, 1)
        t.equal(onOwner { held.current?.engine.isPaused }, true)
        // A genuine native update clock fires on both supported executors; the fixed data clock only makes pixels repeatable.
        executor.async {
            do { try held.current?.resume(updateNow: false) }
            catch { errors.access { $0.append(String(describing: error)) } }
        }
        t.check(AppSelfTest.spin(timeout: 30) { provider.content.state.presented >= 2 || !errors.current.isEmpty })
        t.equal(errors.current, [])
        _ = onOwner { held.current?.pause() }
        let before = provider.content.state.presented
        executor.async {
            do { for _ in 0..<5 { try held.current?.update() } }
            catch { errors.access { $0.append(String(describing: error)) } }
        }
        t.check(AppSelfTest.spin(timeout: 30) { provider.content.state.presented > before || !errors.current.isEmpty })
        _ = onOwner {}
        t.equal(provider.content.state.presented, before + 1, "five updates in one owner turn produce one frame")
        t.check(provider.threads.current.allSatisfy { $0 != worker }, "all frames came from the actual owning thread")
        guard let count = onOwner({ held.current?.engine.updateCount }) ?? nil,
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
        t.equal(onOwner { () -> Int? in
            guard let host = held.current else { return nil }
            let before = host.engine.updateCount
            do { try host.wake() } catch { errors.access { $0.append(String(describing: error)) } }
            host.pause()
            return host.engine.updateCount - before
        }, 1)
        t.equal(onOwner { () -> Bool? in
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
        t.check(releases.current.allSatisfy { $0.0 && $0.1 != worker },
                "release (isCurrent, isMainThread): \(releases.current)")
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
