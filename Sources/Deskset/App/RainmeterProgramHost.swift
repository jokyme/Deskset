import AppKit
import DesksetCore

/// The admitted compatibility program on a real App executor. This first host presents through the default
/// bitmap provider only; window selection and the C/E preparation/lease state machines still belong to SkinRuntime.
/// All methods and borrowed engine/cache/frame references are owner-confined. Only final release may be off-owner.
final class RainmeterProgramHost {
    enum Failure: Error, Equatable { case unsupportedContentMode }

    private final class Text: RainmeterTextMeasuring {
        let context: SkinRenderContext
        init(_ context: SkinRenderContext) { self.context = context }
        func measure(_ text: String, style: TextStyle, wrapWidth: Double?, cycle: Int) -> SkinSize? {
            let size = context.text.layout(text, style: style, wrapWidth: wrapWidth.map { CGFloat($0) }, cycle: cycle).size
            return SkinSize(width: size.width, height: size.height)
        }
    }

    /// Transferred as one bundle on off-owner destruction: kernels, callbacks and graphics caches all die there.
    private final class Owner {
        let engine: RainmeterProgramRuntime
        let context = SkinRenderContext()
        let provider: ContentProvider?
        var environment: SkinEnvironment
        var started = false
        lazy var frames = SkinFrameProducer(provider: provider, bitmapCapture: { [weak self] scale, appearance in
            guard let self, !engine.isClosed, engine.failure == nil else { return nil }
            let sceneEnvironment = AppSceneEnvironment(scale: Double(scale), appearance: environment.appearance,
                                                       appearanceName: appearance)
            // The admitted profile has no asynchronous resources. A rejected/closed owner retains its last image.
            guard let scene = try? engine.project(environment: sceneEnvironment) else { return nil }
            return SkinBitmapDrawing.Capture(scene: scene, context: context, cycle: engine.updateCount,
                size: SkinRuntime.windowSize(width: engine.width, height: engine.height), source: engine.program.config)
        })

        init(program: RainmeterProgram, executor: SkinExecutor, provider: ContentProvider?,
             environment: SkinEnvironment, clock: SkinClock, system: SystemDataSource,
             effects: SideEffects, random: SkinRandom) throws {
            self.provider = provider
            self.environment = environment
            engine = try RainmeterProgramRuntime(program: program, executor: executor, clock: clock,
                environment: environment, system: system, effects: effects, random: random, text: Text(context))
            let frames = frames
            engine.didUpdate = { [weak frames] in frames?.setNeedsFrame() }
        }

        func close() {
            precondition(engine.executor.isCurrent)
            frames.stop()
            engine.close()
        }
    }

    let executor: SkinExecutor
    private var owner: Owner?
    private var current: Owner {
        precondition(executor.isCurrent, "RainmeterProgramHost accessed off its owner")
        return owner!
    }
    var engine: RainmeterProgramRuntime { current.engine }
    var context: SkinRenderContext { current.context }
    var frames: SkinFrameProducer { current.frames }

    init(program: RainmeterProgram, executor: SkinExecutor, provider: ContentProvider?, environment: SkinEnvironment,
         contentMode: SkinFrameContentMode = .bitmap, clock: SkinClock = .live,
         system: SystemDataSource = SystemMonitor.shared, effects: SideEffects = LiveSideEffects.shared,
         random: SkinRandom = .live()) throws {
        precondition(executor.isCurrent, "RainmeterProgramHost constructed off its owner")
        guard contentMode == .bitmap else { throw Failure.unsupportedContentMode }
        self.executor = executor
        owner = try Owner(program: program, executor: executor, provider: provider, environment: environment,
                          clock: clock, system: system, effects: effects, random: random)
    }

    /// Like a loaded SkinRuntime: even a paused load updates once, then waits for resume.
    func start(paused: Bool = false) throws {
        let owner = current
        guard !owner.started else { return }
        owner.started = true
        owner.frames.start(on: executor)
        if paused { owner.engine.pause() }
        try owner.engine.update()
        try owner.engine.startTimer()
    }
    func update() throws { try current.engine.update() }
    func pause() { current.engine.pause() }
    func resume(updateNow: Bool) throws { try current.engine.resume(updateNow: updateNow) }
    func wake() throws { try current.engine.wake() }
    func close() { current.close() }

    /// Facts already published by main; this host never reads a window from a worker.
    func take(_ facts: SkinWindowFacts, environment: SkinEnvironment) {
        let owner = current
        guard !owner.engine.isClosed else { return }
        owner.environment = environment
        owner.engine.takeEnvironment(environment)
        owner.frames.take(facts)
        owner.frames.setNeedsFrame()
    }
    func drawFirstFrame() { current.frames.drawFirstFrame() }

    deinit {
        guard let owner else { return }
        self.owner = nil
        if executor.isCurrent {
            owner.close()
        } else {
            executor.async {
                owner.close()
                withExtendedLifetime(owner) {}
            }
        }
    }
}
