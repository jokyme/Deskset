import AppKit
import DesksetCore
import DesksetDraw

/// Native G3 for the first compatibility profile, with a fixed destination for each owner's entire timeline.
enum RainmeterProgramSelfTests {
    private enum Failure: Error { case input, clock, bitmap }
    private final class Text: RainmeterTextMeasuring {
        let context = DrawContext(fonts: AppFontResolver())
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
        for (name, width, height, omitted) in [("Align", 460.0, 330.0, "multi"), ("Clip", 520.0, 360.0, "clip1h")] {
            t.suite("App: Rainmeter program: original \(name) preserves native text layout without a Skin owner") {
                try qualifyStaticText(name, width: width, height: height, omittedMeter: omitted, t)
            }
        }
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
