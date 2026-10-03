import AppKit
import DesksetCore
import DesksetDraw

/// The known Desk path geometry encloses centered strokes without changing layout or hit coordinates.
/// This is the preview's viewport calculation, not a generic ink-coverage guarantee.
enum DeskProgramViewport {
    enum Failure: Error { case extent }

    static func extent(_ scene: WidgetScene) throws -> CGRect {
        var result = CGRect(x: 0, y: 0, width: max(scene.size.width, 1), height: max(scene.size.height, 1))
        for item in scene.drawingItems {
            guard case .shape(let draw) = item else { continue }
            for shape in draw.shapes where shape.fill.isVisible || (shape.stroke.isVisible && shape.strokePlan?.isEmpty == false) {
                let b = shape.visualBounds
                let x0 = draw.contentFrame.x + b.minX, y0 = draw.contentFrame.y + b.minY
                let x1 = draw.contentFrame.x + b.maxX, y1 = draw.contentFrame.y + b.maxY
                guard [x0, y0, x1, y1, x1 - x0, y1 - y0].allSatisfy(\.isFinite), x1 >= x0, y1 >= y0 else {
                    throw Failure.extent
                }
                result = result.union(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            }
        }
        guard [result.minX, result.minY, result.maxX, result.maxY, result.width, result.height].allSatisfy(\.isFinite) else {
            throw Failure.extent
        }
        return result
    }
}

/// An accepted Desk program on its executor, using the existing bitmap producer. Installing a document, the Main
/// window adapter and C/E presentation are outside this owner. No Skin or second expression evaluator is involved.
final class DeskProgramHost {
    enum Failure: Error, Equatable { case unsupportedContentMode, extent, resources, bitmap, cycleOverflow }
    enum State: Equatable { case idle, ready, unavailable(String), closed }

    /// Captured by Main before delivery. A worker never asks AppKit for colors, locale or display appearance.
    struct Input: Equatable {
        let environment: EnvironmentStamp
        let colors: ProgramColorInput
        let locale: Locale
    }

    /// The exact scene and viewport handed to the provider, not an unpresented projection or a window resize.
    struct Presented {
        let scene: WidgetScene
        let origin: SkinPoint
        let size: CGSize
        let scale: CGFloat
    }

    private final class Owner: TickTarget {
        let executor: SkinExecutor
        let clock: SkinClock
        let source: String
        let provider: ContentProvider?
        let scheduler = TickScheduler()
        var runtime: ProgramRuntime
        var input: Input
        var prepared: DeskProgramResources.Prepared?
        var context: SkinRenderContext? = SkinRenderContext()
        var scene: WidgetScene?
        var viewport: CGRect?
        var presented: Presented?
        var state: State = .idle
        var cycle = 0
        var started = false
        var visible = false
        var pointerEligible = false
        var destinationReady = false
        var projecting = false
        var primaryPress: ElementID?
        var didPresent: ((Presented) -> Void)?
        var didBecomeUnavailable: ((String) -> Void)?
        var isClosed: Bool { state == .closed }
        var updateMilliseconds: Int { -1 } // Only startClockBoundary is used; never the Rainmeter periodic clock.
        lazy var frames = SkinFrameProducer(provider: provider, bitmapCapture: { [weak self] scale, appearance in
            self?.capture(scale: scale, appearance: appearance)
        }, bitmapValidation: { [weak self] capture, destination in
            self?.validate(capture, in: destination) ?? false
        })

        init(program: WidgetProgram, executor: SkinExecutor, provider: ContentProvider?, input: Input,
             prepared: DeskProgramResources.Prepared?, clock: SkinClock, source: String) throws {
            runtime = try ProgramRuntime(program: program)
            self.executor = executor; self.provider = provider; self.input = input
            self.prepared = prepared; self.clock = clock; self.source = source
            frames.bitmapResult = { [weak self] result in
                guard let self, !isClosed else { return }
                switch result {
                case .failed: if state == .ready { fail(Failure.bitmap) }
                case .presented(let capture):
                    guard state == .ready, capture.scene.generation == scene?.generation else { return }
                    let value = Presented(scene: capture.scene, origin: capture.origin,
                        size: CGSize(width: ceil(capture.size.width * capture.scene.environment.scale) / capture.scene.environment.scale,
                                     height: ceil(capture.size.height * capture.scene.environment.scale) / capture.scene.environment.scale),
                        scale: CGFloat(capture.scene.environment.scale))
                    presented = value
                    didPresent?(value)
                }
            }
        }

        func project(click: SkinPoint? = nil) {
            precondition(executor.isCurrent)
            guard !isClosed, !projecting else { return }
            projecting = true
            defer { projecting = false }
            scheduler.cancel()
            do {
                guard destinationReady else { throw ProgramRuntimeError.invalidEnvironment }
                guard prepared?.failure == nil, prepared?.unchanged() ?? true else { throw Failure.resources }
                let nextCycle = cycle.addingReportingOverflow(1)
                guard !nextCycle.overflow else { throw Failure.cycleOverflow }
                let context = self.context ?? SkinRenderContext()
                self.context = context
                let input = self.input
                let date = ProgramDateInput(instant: clock.now(), timeZone: clock.timeZone(), locale: input.locale)
                let measure: (String, TextStyle, Double?) throws -> SkinSize = { text, style, width in
                    let pixels = style.fontSize * (96.0 / 72.0) * input.environment.scale
                    guard pixels.isFinite, pixels > 0, pixels <= Double(RenderOptions.maxPixels) else { throw Failure.extent }
                    let layout = context.text.layout(text, style: style, wrapWidth: width.map { CGFloat($0) }, cycle: nextCycle.partialValue)
                    return SkinSize(width: layout.size.width, height: layout.size.height)
                }
                var candidate = runtime
                let next: WidgetScene
                if let click {
                    guard let current = scene, let value = try candidate.click(at: click, expectedGeneration: current.generation,
                        environment: input.environment, images: prepared?.images ?? [:], dateInput: date,
                        colorInput: input.colors, measure: measure) else { arm(after: date.instant); return }
                    next = value
                } else {
                    next = try candidate.project(environment: input.environment, images: prepared?.images ?? [:],
                        dateInput: date, colorInput: input.colors, measure: measure)
                }
                guard next.size.width.isFinite, next.size.height.isFinite,
                      next.size.width >= 0, next.size.height >= 0 else { throw Failure.extent }
                let extent = try DeskProgramViewport.extent(next)
                let side = max(extent.width, extent.height) * input.environment.scale
                guard side.isFinite, side <= Double(RenderOptions.maxPixels) else { throw Failure.extent }
                runtime = candidate
                scene = next; viewport = extent; cycle = nextCycle.partialValue; state = .ready
                frames.setNeedsFrame()
                arm(after: date.instant)
            } catch { fail(error) }
        }

        func arm(after instant: Date) {
            guard visible, !isClosed, state == .ready, let precision = runtime.clockPrecision else { return }
            do { scheduler.startClockBoundary(after: try precision.delayToNextBoundary(after: instant), for: self) }
            catch { fail(error) }
        }

        func updateForTick() {
            guard visible, !scheduler.isPaused, !isClosed else { return }
            project()
        }
        func notifySystemWake() { updateForTick() }

        func capture(scale: CGFloat, appearance: String) -> SkinBitmapDrawing.Capture? {
            guard !isClosed, state == .ready, let scene, let context, let viewport else { return nil }
            guard scene.environment.scale == Double(scale), scene.environment.appearance.name == appearance,
                  prepared?.unchanged() ?? true else { fail(Failure.resources); return nil }
            return SkinBitmapDrawing.Capture(scene: scene, context: context, cycle: cycle, size: viewport.size,
                source: source, origin: SkinPoint(x: viewport.minX, y: viewport.minY))
        }

        func validate(_ capture: SkinBitmapDrawing.Capture, in ctx: CGContext) -> Bool {
            guard !isClosed, prepared?.unchanged() ?? true else { return false }
            for item in capture.scene.drawingItems {
                guard case .image(let image) = item else { continue }
                // Desk's actual renderer qualifies orientation and drawn-size decoding on this destination.
                guard DesksetDraw.ImageRenderer.preparedNaturalImage(image, in: ctx) != nil else { return false }
            }
            return true
        }

        func fail(_ error: Error) {
            guard !isClosed else { return }
            let message = String(describing: error)
            let changed = state != .unavailable(message)
            scheduler.cancel(); primaryPress = nil
            scene = nil; viewport = nil; presented = nil; context = nil
            state = .unavailable(message)
            frames.clearBitmapContents()
            if changed { didBecomeUnavailable?(message) }
        }

        func close() {
            precondition(executor.isCurrent)
            guard !isClosed else { return }
            scheduler.cancel(); primaryPress = nil; didPresent = nil; didBecomeUnavailable = nil
            state = .closed
            frames.stop(); frames.clearBitmapContents(); frames.bitmapResult = nil
            scene = nil; viewport = nil; presented = nil; context = nil
            prepared?.removeCopies(); prepared = nil
        }
    }

    let executor: SkinExecutor
    private var owner: Owner?
    private var current: Owner {
        precondition(executor.isCurrent, "DeskProgramHost accessed off its owner")
        return owner!
    }
    var state: State { current.state }
    var scene: WidgetScene? { current.scene }
    var viewport: CGRect? { current.viewport }
    var presented: Presented? { current.presented }
    var context: SkinRenderContext? { current.context }
    var frames: SkinFrameProducer { current.frames }
    var isPaused: Bool { current.scheduler.isPaused }
    /// Synchronous owner callback. The window adapter must capture itself weakly and deliver Main work itself.
    var didPresent: ((Presented) -> Void)? {
        get { current.didPresent }
        set { current.didPresent = newValue }
    }
    /// Delivered after the failed picture, clock and hit state are cleared. Repeating the same failure is quiet.
    /// Like didPresent, this runs on the owner; callers capture weakly and perform their own Main delivery.
    var didBecomeUnavailable: ((String) -> Void)? {
        get { current.didBecomeUnavailable }
        set { current.didBecomeUnavailable = newValue }
    }

    /// On successful construction the owner exclusively owns `prepared`'s copies; never pass preview's generation.
    /// The caller retains cleanup responsibility if construction throws. Nil admits only programs without images.
    init(program: WidgetProgram, executor: SkinExecutor, provider: ContentProvider?, input: Input,
         prepared: DeskProgramResources.Prepared? = nil, clock: SkinClock = .live, source: String = "Desk",
         contentMode: SkinFrameContentMode = .bitmap) throws {
        precondition(executor.isCurrent, "DeskProgramHost constructed off its owner")
        guard contentMode == .bitmap else { throw Failure.unsupportedContentMode }
        self.executor = executor
        owner = try Owner(program: program, executor: executor, provider: provider, input: input,
                          prepared: prepared, clock: clock, source: source)
    }

    func start(paused: Bool = false) {
        let owner = current
        guard !owner.isClosed, !owner.started else { return }
        owner.started = true
        owner.frames.start(on: executor)
        owner.scheduler.isPaused = paused
        owner.project()
    }

    func take(_ facts: SkinWindowFacts, input: Input) {
        let owner = current
        guard !owner.isClosed else { return }
        let changed = owner.input != input
        let wasVisible = owner.visible
        let hadDestination = owner.destinationReady
        owner.input = input
        owner.visible = facts.isOrderedIn && !facts.settings.hidden
        owner.pointerEligible = owner.visible && facts.isVisible && facts.takesPointer
        if !owner.pointerEligible { owner.primaryPress = nil }
        owner.destinationReady = false
        owner.frames.take(facts)
        if !owner.visible { owner.primaryPress = nil; owner.scheduler.cancel() }
        guard facts.colorSpace?.model == .rgb, input.environment.scale == Double(facts.scale),
              input.environment.appearance.name == facts.appearance else {
            owner.fail(ProgramRuntimeError.invalidEnvironment); return
        }
        owner.destinationReady = true
        if owner.started && (changed || !hadDestination || (!wasVisible && owner.visible)) { owner.project() }
    }

    /// An explicit owner input refresh can recover a failed font/environment projection without replaying onLoad.
    func refresh() { current.project() }
    func pause() { current.scheduler.pause() }
    func resume(updateNow: Bool) {
        let owner = current
        guard !owner.isClosed, owner.scheduler.isPaused else { return }
        owner.scheduler.isPaused = false
        if updateNow { owner.project() } else { owner.arm(after: owner.clock.now()) }
    }
    func wake() { current.notifySystemWake() }
    func drawFirstFrame() { current.frames.drawFirstFrame() }

    /// Points are relative to the presented bitmap's top-left corner, already in points rather than pixels.
    func primaryPress(at point: SkinPoint) {
        let owner = current
        owner.primaryPress = nil
        guard owner.pointerEligible, point.x.isFinite, point.y.isFinite,
              let value = owner.presented, value.scene.generation == owner.scene?.generation else { return }
        owner.primaryPress = value.scene.hitMap.entry(at: point.x + value.origin.x, point.y + value.origin.y,
            handling: .leftUp, images: nil)?.elementID
    }

    func primaryRelease(at point: SkinPoint?) {
        let owner = current
        let press = owner.primaryPress
        owner.primaryPress = nil
        guard owner.pointerEligible, let point, point.x.isFinite, point.y.isFinite, let press, let value = owner.presented,
              value.scene.generation == owner.scene?.generation else { return }
        let mapped = SkinPoint(x: point.x + value.origin.x, y: point.y + value.origin.y)
        guard value.scene.hitMap.entry(at: mapped.x, mapped.y, handling: .leftUp, images: nil)?.elementID == press else { return }
        owner.project(click: mapped)
    }

    /// Completes synchronously on the executor. Main may then tear down its provider/window; the executor is shared.
    func close() { current.close() }

    deinit {
        guard let owner else { return }
        self.owner = nil
        if executor.isCurrent { owner.close() }
        else { executor.async { owner.close(); withExtendedLifetime(owner) {} } }
    }
}
