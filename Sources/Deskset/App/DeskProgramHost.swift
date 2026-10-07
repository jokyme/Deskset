import AppKit
import DesksetCore
import DesksetDraw

/// Visible Desk boxes and known path geometry enclose overflow without changing layout or hit coordinates.
/// This is the preview's viewport calculation, not a generic ink-coverage guarantee.
enum DeskProgramViewport {
    enum Failure: Error { case extent }

    static func extent(_ scene: WidgetScene) throws -> CGRect {
        var result = CGRect(x: 0, y: 0, width: max(scene.size.width, 1), height: max(scene.size.height, 1))
        for element in scene.elements where element.visibility == .visible {
            let frame = element.frame
            guard [frame.x, frame.y, frame.width, frame.height, frame.x + frame.width, frame.y + frame.height].allSatisfy(\.isFinite),
                  frame.width >= 0, frame.height >= 0 else { throw Failure.extent }
            // Transparent boxes can still receive clicks or inspector selection outside the logical root.
            if frame.width > 0, frame.height > 0 {
                result = result.union(CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
            }
        }
        var pending = scene.drawingItems.map { ($0, ShapeTransform.identity) }
        while let (item, transform) = pending.popLast() {
            if case .transformed(let local, let children) = item {
                let combined = local.then(transform)
                guard [combined.a, combined.b, combined.c, combined.d, combined.tx, combined.ty].allSatisfy(\.isFinite) else {
                    throw Failure.extent
                }
                pending.append(contentsOf: children.map { ($0, combined) })
                continue
            }
            if case .antialias(_, let children) = item {
                pending.append(contentsOf: children.map { ($0, transform) })
                continue
            }
            if case .icon(let draw) = item {
                let rect = draw.contentFrame
                guard [rect.x, rect.y, rect.width, rect.height, rect.x + rect.width, rect.y + rect.height].allSatisfy(\.isFinite),
                      rect.width >= 0, rect.height >= 0 else { throw Failure.extent }
                let corners = [ShapePoint(rect.x, rect.y), ShapePoint(rect.x + rect.width, rect.y),
                               ShapePoint(rect.x, rect.y + rect.height), ShapePoint(rect.x + rect.width, rect.y + rect.height)]
                    .map(transform.apply)
                guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                      let left = corners.map(\.x).min(), let right = corners.map(\.x).max(),
                      let top = corners.map(\.y).min(), let bottom = corners.map(\.y).max() else { throw Failure.extent }
                if rect.width > 0, rect.height > 0 {
                    result = result.union(CGRect(x: left, y: top, width: right - left, height: bottom - top))
                }
                continue
            }
            guard case .shape(let draw) = item else { continue }
            for shape in draw.shapes where shape.fill.isVisible || (shape.stroke.isVisible && shape.strokePlan?.isEmpty == false) {
                let b = shape.visualBounds
                let x0 = draw.contentFrame.x + b.minX, y0 = draw.contentFrame.y + b.minY
                let x1 = draw.contentFrame.x + b.maxX, y1 = draw.contentFrame.y + b.maxY
                guard [x0, y0, x1, y1, x1 - x0, y1 - y0].allSatisfy(\.isFinite), x1 >= x0, y1 >= y0 else {
                    throw Failure.extent
                }
                let corners = [ShapePoint(x0, y0), ShapePoint(x1, y0), ShapePoint(x0, y1), ShapePoint(x1, y1)].map(transform.apply)
                guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                      let left = corners.map(\.x).min(), let right = corners.map(\.x).max(),
                      let top = corners.map(\.y).min(), let bottom = corners.map(\.y).max() else { throw Failure.extent }
                result = result.union(CGRect(x: left, y: top, width: right - left, height: bottom - top))
            }
        }
        guard [result.minX, result.minY, result.maxX, result.maxY, result.width, result.height].allSatisfy(\.isFinite) else {
            throw Failure.extent
        }
        return result
    }
}

/// Both destinations qualify images under the same transforms that the shared renderer will apply.
enum DeskProgramImageValidation {
    static func validate(_ items: [DrawItem], in destination: CGContext,
                         icon: (IconDraw, CGContext) -> Bool = { _, _ in true },
                         image: (ImageDraw, CGContext) -> Bool) -> Bool {
        for item in items {
            switch item {
            case .image(let value):
                guard image(value, destination) else { return false }
            case .icon(let value):
                guard icon(value, destination) else { return false }
            case .transformed(let transform, let children):
                guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy(\.isFinite) else { return false }
                destination.saveGState()
                destination.concatenate(CGAffineTransform(a: transform.a, b: transform.b, c: transform.c,
                                                          d: transform.d, tx: transform.tx, ty: transform.ty))
                let valid = validate(children, in: destination, icon: icon, image: image)
                destination.restoreGState()
                guard valid else { return false }
            case .antialias(let enabled, let children):
                destination.saveGState()
                destination.setShouldAntialias(enabled)
                let valid = validate(children, in: destination, icon: icon, image: image)
                destination.restoreGState()
                guard valid else { return false }
            case .container(_, let mask, let content):
                guard validate(mask, in: destination, icon: icon, image: image),
                      validate(content, in: destination, icon: icon, image: image) else { return false }
            default: break
            }
        }
        return true
    }

    static func prepare(_ icon: IconDraw, in destination: CGContext, cache: IconCache) -> Bool {
        do { _ = try cache.prepare(icon, in: destination, pin: true); return true }
        catch { return false }
    }

    /// Qualify the complete icon raster budget before committing a candidate or exposing its click effects.
    /// The scratch surface supplies only the destination transform; symbol pixels live in the owner's cache.
    static func prepareIcons(_ items: [DrawItem], scale: Double, origin: SkinPoint, cache: IconCache) -> Bool {
        var pending = items, containsIcon = false
        while let item = pending.popLast(), !containsIcon {
            switch item {
            case .icon: containsIcon = true
            case .transformed(_, let children), .antialias(_, let children): pending += children
            case .container(_, let mask, let content): pending += mask + content
            default: break
            }
        }
        guard containsIcon else { return true }
        guard scale.isFinite, scale > 0, origin.x.isFinite, origin.y.isFinite,
              let scratch = SkinBitmapDrawing.makeContext(1, 1, SkinFrameProducer.sRGB) else { return false }
        scratch.translateBy(x: 0, y: 1)
        scratch.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        scratch.translateBy(x: -CGFloat(origin.x), y: -CGFloat(origin.y))
        cache.beginFrame()
        let ready = validate(items, in: scratch, icon: { prepare($0, in: $1, cache: cache) }, image: { _, _ in true })
        if !ready { cache.cancelFrame() }
        return ready
    }
}

/// An accepted Desk program on its executor, using the existing bitmap producer. Installing a document, the Main
/// window adapter and C/E presentation are outside this owner. No Skin or second expression evaluator is involved.
final class DeskProgramHost {
    enum Failure: Error, Equatable { case unsupportedContentMode, extent, resources, bitmap, cycleOverflow }
    enum State: Equatable { case idle, ready, unavailable(String), closed }
    typealias IconPreparation = ([DeskIconResources.Demand], @escaping (Result<DeskIconResources.Batch, Error>) -> Void) -> DeskIconResources.Ticket

    /// Captured by Main before delivery. A worker never asks AppKit for colors, locale or display appearance.
    struct Input: Equatable {
        let environment: EnvironmentStamp
        let colors: ProgramColorInput
        let locale: Locale
    }

    /// The exact scene and viewport accepted by the provider, after Main's ACK when delivery is asynchronous.
    struct Presented {
        let scene: WidgetScene
        let origin: SkinPoint
        let size: CGSize
        let scale: CGFloat
    }

    private final class Owner: TickTarget {
        private final class Projection {
            var preparationID: UUID?
            let base: ProgramRuntime
            let input: Input
            let date: ProgramDateInput
            let systemInput: ProgramSystemInput?
            let images: [String: ProgramImageResource]
            let context: SkinRenderContext
            let fontGeneration: Int
            let cycle: Int
            let click: SkinPoint?
            let event: MouseEventKind
            let completion: (([ProgramEffect]) -> Void)?
            var ticket: DeskIconResources.Ticket?
            var deferredRefresh = false

            init(base: ProgramRuntime, input: Input, date: ProgramDateInput, systemInput: ProgramSystemInput?,
                 images: [String: ProgramImageResource], context: SkinRenderContext, cycle: Int,
                 click: SkinPoint?, event: MouseEventKind, completion: (([ProgramEffect]) -> Void)?) {
                self.base = base; self.input = input; self.date = date; self.systemInput = systemInput
                self.images = images; self.context = context; self.fontGeneration = context.drawing.icons.fontGeneration
                self.cycle = cycle; self.click = click; self.event = event; self.completion = completion
            }
        }
        private enum ProjectionResult { case completed([ProgramEffect]), waiting, failed }
        let executor: SkinExecutor
        let clock: SkinClock
        let system: SystemDataSource
        let source: String
        let provider: ContentProvider?
        let prepareIcons: IconPreparation
        let scheduler = TickScheduler()
        var sampler = ProgramSystemSampler()
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
        var destination: SkinWindowFacts?
        var projecting = false
        private var pending: Projection?
        var isPreparingIcons: Bool { pending != nil }
        var primaryPress: ElementID?
        var secondaryPress: ElementID?
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
             prepared: DeskProgramResources.Prepared?, clock: SkinClock, system: SystemDataSource, source: String,
             prepareIcons: @escaping IconPreparation) throws {
            runtime = try ProgramRuntime(program: program)
            self.executor = executor; self.provider = provider; self.input = input
            self.prepared = prepared; self.clock = clock; self.system = system; self.source = source
            self.prepareIcons = prepareIcons
            frames.bitmapResult = { [weak self] result in
                guard let self, !isClosed else { return }
                switch result {
                case .failed: if state == .ready { fail(Failure.bitmap) }
                case .presented(let capture):
                    // Projection can advance while Main holds a picture. The producer qualifies the ACK's
                    // identity and destination; retain what actually reached the screen, even if logic is newer.
                    // Pointer input still requires presented and current generations to match.
                    guard state == .ready else { return }
                    let value = Presented(scene: capture.scene, origin: capture.origin,
                        size: CGSize(width: ceil(capture.size.width * capture.scene.environment.scale) / capture.scene.environment.scale,
                                     height: ceil(capture.size.height * capture.scene.environment.scale) / capture.scene.environment.scale),
                        scale: CGFloat(capture.scene.environment.scale))
                    presented = value
                    didPresent?(value)
                }
            }
        }

        @discardableResult
        func project(click: SkinPoint? = nil, event: MouseEventKind = .leftUp,
                     completion: (([ProgramEffect]) -> Void)? = nil) -> [ProgramEffect]? {
            precondition(executor.isCurrent)
            guard !isClosed, !projecting else { return nil }
            do {
                guard destinationReady else { throw ProgramRuntimeError.invalidEnvironment }
                guard prepared?.failure == nil, prepared?.unchanged() ?? true else { throw Failure.resources }
                if let pending {
                    if click == nil {
                        pending.deferredRefresh = true
                        arm(after: clock.now())
                    }
                    return nil
                }
                scheduler.cancel()
                let nextCycle = cycle.addingReportingOverflow(1)
                guard !nextCycle.overflow else { throw Failure.cycleOverflow }
                let context = self.context ?? SkinRenderContext()
                self.context = context
                let input = self.input
                let date = ProgramDateInput(instant: clock.now(), timeZone: clock.timeZone(), locale: input.locale)
                let needed = runtime.neededSystemProperties(clickAt: click, event: event)
                let now = date.instant.timeIntervalSince1970
                let systemInput = sampler.sample(from: system, for: needed, at: now)
                let projection = Projection(base: runtime, input: input, date: date, systemInput: systemInput,
                    images: prepared?.images ?? [:], context: context, cycle: nextCycle.partialValue,
                    click: click, event: event, completion: completion)
                if case .completed(let effects) = attempt(projection, schedulingAfter: date.instant) {
                    return click == nil ? nil : effects
                }
                return nil
            } catch { fail(error); return nil }
        }

        private func attempt(_ projection: Projection, schedulingAfter instant: Date) -> ProjectionResult {
            precondition(executor.isCurrent)
            guard !isClosed, !projecting else { return .failed }
            projecting = true
            defer { projecting = false }
            let input = projection.input, context = projection.context
            var missing: [DeskIconResources.Demand] = [], seen = Set<DeskIconResources.Demand>()
            context.iconResources.beginProjection()
            do {
                guard destinationReady, self.input == input, self.context === context,
                      context.drawing.icons.fontGeneration == projection.fontGeneration,
                      prepared?.failure == nil, prepared?.unchanged() ?? true else { throw Failure.resources }
                let measure: (String, TextStyle, Double?) throws -> SkinSize = { text, style, width in
                    let pixels = style.fontSize * (96.0 / 72.0) * input.environment.scale
                    guard pixels.isFinite, pixels > 0, pixels <= Double(RenderOptions.maxPixels) else { throw Failure.extent }
                    let layout = context.text.layout(text, style: style, wrapWidth: width.map { CGFloat($0) }, cycle: projection.cycle)
                    return SkinSize(width: layout.size.width, height: layout.size.height)
                }
                let measureIcon: (IconRequest) throws -> SkinSize? = { request in
                    do { return try context.drawing.icons.measure(request) }
                    catch DeskIconResources.Failure.notPrepared(let demand) {
                        if seen.insert(demand).inserted { missing.append(demand) }
                        // Collection only: no scene, state or effect from this provisional layout can be committed.
                        return SkinSize(width: 1, height: 1)
                    }
                }
                var candidate = projection.base
                let next: WidgetScene
                var effects: [ProgramEffect] = []
                if let click = projection.click {
                    guard let value = try candidate.clickWithEffects(at: click, expectedGeneration: projection.base.generation,
                        event: projection.event, environment: input.environment, images: projection.images, dateInput: projection.date,
                        colorInput: input.colors, systemInput: projection.systemInput,
                        measureIcon: measureIcon, measure: measure) else {
                        cancelProjection(); arm(after: instant); return .failed
                    }
                    next = value.scene
                    effects = value.effects
                } else {
                    next = try candidate.project(environment: input.environment, images: projection.images,
                        dateInput: projection.date, colorInput: input.colors, systemInput: projection.systemInput,
                        measureIcon: measureIcon, measure: measure)
                }
                if !missing.isEmpty { return prepare(missing, for: projection) }
                guard next.size.width.isFinite, next.size.height.isFinite,
                      next.size.width >= 0, next.size.height >= 0 else { throw Failure.extent }
                let extent = try DeskProgramViewport.extent(next)
                let side = max(extent.width, extent.height) * input.environment.scale
                guard side.isFinite, side <= Double(RenderOptions.maxPixels) else { throw Failure.extent }
                guard DeskProgramImageValidation.prepareIcons(next.drawingItems, scale: input.environment.scale,
                    origin: SkinPoint(x: extent.minX, y: extent.minY), cache: context.drawing.icons) else { throw Failure.bitmap }
                // The font registry may advance on its own queue while this owner prepares the raster batch.
                guard context.drawing.icons.fontGeneration == projection.fontGeneration else { throw Failure.resources }
                let nextClockDelay: TimeInterval?
                if visible, let precision = candidate.clockPrecision {
                    nextClockDelay = try precision.delayToNextBoundary(after: instant)
                } else { nextClockDelay = nil }
                context.iconResources.commitProjection()
                pending = nil
                runtime = candidate
                scene = next; viewport = extent; cycle = projection.cycle; state = .ready
                frames.setNeedsFrame()
                if let nextClockDelay { scheduler.startClockBoundary(after: nextClockDelay, for: self) }
                // The source hit was already presented. A later coalesced redraw is not an action replay or ACK.
                return .completed(effects)
            } catch {
                // An unknown symbol eventually measures as zero, so even an overflow caused by provisional
                // 1x1 boxes must wait for real resources before deciding whether the program is invalid.
                if !missing.isEmpty { return prepare(missing, for: projection) }
                fail(error); return .failed
            }
        }

        private func prepare(_ demands: [DeskIconResources.Demand], for projection: Projection) -> ProjectionResult {
            guard demands.allSatisfy({ $0.fontGeneration == projection.fontGeneration }),
                  projection.context.drawing.icons.fontGeneration == projection.fontGeneration else {
                fail(Failure.resources); return .failed
            }
            pending = projection
            primaryPress = nil; secondaryPress = nil
            let id = UUID(), executor = self.executor
            projection.preparationID = id
            projection.ticket = prepareIcons(demands) { [weak self, executor] result in
                // Main never obtains a strong Owner reference. Resolve the weak capture only after the hop.
                executor.async { [weak self] in self?.finishPreparation(id, demands: demands, result: result) }
            }
            arm(after: clock.now())
            return .waiting
        }

        private func finishPreparation(_ id: UUID, demands: [DeskIconResources.Demand],
                                       result: Result<DeskIconResources.Batch, Error>) {
            precondition(executor.isCurrent)
            guard !isClosed, let projection = pending, projection.preparationID == id else { return }
            projection.preparationID = nil
            projection.ticket = nil
            do {
                guard input == projection.input, destinationReady,
                      projection.context.drawing.icons.fontGeneration == projection.fontGeneration,
                      prepared?.failure == nil, prepared?.unchanged() ?? true else { throw Failure.resources }
                let batch = try result.get()
                guard batch.entries.count == demands.count,
                      Set(batch.entries.map(\.demand)) == Set(demands) else { throw Failure.resources }
                try projection.context.iconResources.install(batch)
                for demand in demands {
                    if case .missing = projection.context.iconResources.lookup(demand) { throw Failure.resources }
                }
                let firstFrame = presented == nil
                let outcome = attempt(projection, schedulingAfter: clock.now())
                guard case .completed(let effects) = outcome else { return }
                if projection.click != nil { projection.completion?(effects) }
                guard !isClosed, state == .ready, pending == nil else { return }
                if firstFrame { frames.drawFirstFrame() }
                if projection.deferredRefresh, !isClosed, state == .ready { project() }
            } catch { fail(error) }
        }

        func cancelProjection() {
            let retiring = pending
            pending = nil
            retiring?.ticket?.cancel()
            context?.iconResources.cancelProjection()
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
        func notifySystemWake() {
            sampler.invalidateTimeBased()
            updateForTick()
        }

        func capture(scale: CGFloat, appearance: String) -> SkinBitmapDrawing.Capture? {
            guard !isClosed, state == .ready, let scene, let context, let viewport else { return nil }
            guard scene.environment.scale == Double(scale), scene.environment.appearance.name == appearance,
                  prepared?.unchanged() ?? true else { fail(Failure.resources); return nil }
            return SkinBitmapDrawing.Capture(scene: scene, context: context, cycle: cycle, size: viewport.size,
                source: source, origin: SkinPoint(x: viewport.minX, y: viewport.minY))
        }

        func validate(_ capture: SkinBitmapDrawing.Capture, in ctx: CGContext) -> Bool {
            guard !isClosed, prepared?.unchanged() ?? true else { return false }
            let icons = capture.context.drawing.icons
            icons.beginFrame()
            let ready = DeskProgramImageValidation.validate(capture.scene.drawingItems, in: ctx,
                icon: { DeskProgramImageValidation.prepare($0, in: $1, cache: icons) }) { image, destination in
                DesksetDraw.ImageRenderer.preparedNaturalImage(image, in: destination) != nil
            }
            if !ready { icons.cancelFrame() }
            return ready
        }

        func fail(_ error: Error) {
            guard !isClosed else { return }
            cancelProjection()
            let message = String(describing: error)
            let changed = state != .unavailable(message)
            scheduler.cancel(); primaryPress = nil; secondaryPress = nil
            scene = nil; viewport = nil; presented = nil; context = nil
            state = .unavailable(message)
            frames.clearBitmapContents()
            if changed { didBecomeUnavailable?(message) }
        }

        func close() {
            precondition(executor.isCurrent)
            guard !isClosed else { return }
            cancelProjection()
            scheduler.cancel(); primaryPress = nil; secondaryPress = nil; didPresent = nil; didBecomeUnavailable = nil
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
    var clockPrecision: ProgramClockPrecision? { current.runtime.clockPrecision }
    var neededSystemProperties: Set<ProgramSystemProperty> { current.runtime.neededSystemProperties }
    var isPreparingIcons: Bool { current.isPreparingIcons }
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
         prepared: DeskProgramResources.Prepared? = nil, clock: SkinClock = .live,
         system: SystemDataSource = SystemMonitor.shared, source: String = "Desk",
         contentMode: SkinFrameContentMode = .bitmap,
         prepareIcons: @escaping IconPreparation = DeskIconResources.prepare) throws {
        precondition(executor.isCurrent, "DeskProgramHost constructed off its owner")
        guard contentMode == .bitmap else { throw Failure.unsupportedContentMode }
        self.executor = executor
        owner = try Owner(program: program, executor: executor, provider: provider, input: input,
                          prepared: prepared, clock: clock, system: system, source: source, prepareIcons: prepareIcons)
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
        let destinationChanged = owner.destination.map {
            $0.panelGeneration != facts.panelGeneration || $0.colorSpace != facts.colorSpace ||
            $0.scale != facts.scale || $0.appearance != facts.appearance
        } ?? true
        let eligible = facts.isOrderedIn && !facts.settings.hidden && facts.isVisible && facts.takesPointer
        let cancelled = owner.isPreparingIcons && (changed || destinationChanged || (owner.pointerEligible && !eligible))
        if cancelled { owner.cancelProjection() }
        owner.destination = facts
        owner.input = input
        owner.visible = facts.isOrderedIn && !facts.settings.hidden
        owner.pointerEligible = owner.visible && facts.isVisible && facts.takesPointer
        if !owner.pointerEligible { owner.primaryPress = nil; owner.secondaryPress = nil }
        owner.destinationReady = false
        owner.frames.take(facts)
        if !owner.visible { owner.primaryPress = nil; owner.secondaryPress = nil; owner.scheduler.cancel() }
        guard facts.colorSpace?.model == .rgb, input.environment.scale == Double(facts.scale),
              input.environment.appearance.name == facts.appearance else {
            owner.fail(ProgramRuntimeError.invalidEnvironment); return
        }
        owner.destinationReady = true
        if owner.started && (changed || destinationChanged || !hadDestination || (!wasVisible && owner.visible)) { owner.project() }
        else if cancelled { owner.arm(after: owner.clock.now()) }
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
    func notifyPowerChange() {
        let owner = current
        guard !owner.isClosed else { return }
        owner.sampler.invalidateBattery()
        guard owner.visible else { return }
        let batteryProps: Set<ProgramSystemProperty> = [.batteryLevel, .batteryCharging, .batteryPluggedIn]
        guard !owner.runtime.neededSystemProperties().isDisjoint(with: batteryProps) else { return }
        owner.project()
    }
    func drawFirstFrame() { current.frames.drawFirstFrame() }

    /// Points are relative to the presented bitmap's top-left corner, already in points rather than pixels.
    func primaryPress(at point: SkinPoint) { press(at: point, event: .leftUp) }
    func secondaryPress(at point: SkinPoint) { press(at: point, event: .rightUp) }

    private func press(at point: SkinPoint, event: MouseEventKind) {
        let owner = current
        if event == .leftUp { owner.primaryPress = nil } else { owner.secondaryPress = nil }
        guard !owner.isPreparingIcons, owner.pointerEligible, point.x.isFinite, point.y.isFinite,
              let value = owner.presented, value.scene.generation == owner.scene?.generation else { return }
        let id = value.scene.hitMap.entry(at: point.x + value.origin.x, point.y + value.origin.y,
            handling: event, images: nil)?.elementID
        if event == .leftUp { owner.primaryPress = id } else { owner.secondaryPress = id }
    }

    /// Returns frozen requests only after the entire click and host extent/resource preflight succeed.
    /// The Main adapter owns external execution; a future bitmap failure cannot undo an executed request.
    /// A synchronous success returns its effects without invoking completion. Pending resource work returns nil;
    /// only a later successful transaction invokes completion once. Cancellation and failure discard completion.
    @discardableResult
    func primaryRelease(at point: SkinPoint?, completion: (([ProgramEffect]) -> Void)? = nil) -> [ProgramEffect]? {
        release(at: point, event: .leftUp, completion: completion)
    }
    @discardableResult
    func secondaryRelease(at point: SkinPoint?, completion: (([ProgramEffect]) -> Void)? = nil) -> [ProgramEffect]? {
        release(at: point, event: .rightUp, completion: completion)
    }

    private func release(at point: SkinPoint?, event: MouseEventKind, completion: (([ProgramEffect]) -> Void)?) -> [ProgramEffect]? {
        let owner = current
        let press = event == .leftUp ? owner.primaryPress : owner.secondaryPress
        if event == .leftUp { owner.primaryPress = nil } else { owner.secondaryPress = nil }
        guard !owner.isPreparingIcons, owner.pointerEligible, let point, point.x.isFinite, point.y.isFinite, let press, let value = owner.presented,
              value.scene.generation == owner.scene?.generation else { return nil }
        let mapped = SkinPoint(x: point.x + value.origin.x, y: point.y + value.origin.y)
        guard value.scene.hitMap.entry(at: mapped.x, mapped.y, handling: event, images: nil)?.elementID == press else { return nil }
        return owner.project(click: mapped, event: event, completion: completion)
    }

    /// Completes synchronously on the executor. Main may then tear down its provider/window; the executor is shared.
    func close() { current.close() }

    deinit {
        guard owner != nil else { return }
        if executor.isCurrent {
            owner?.close()
            owner = nil
        } else {
            // Main may finish before the submitting stack resumes. Transfer through a box so that stack never
            // holds the last Owner reference; detach under the lock, then close and release on the executor.
            let transfer = Guarded(owner)
            owner = nil
            executor.async {
                let retiring = transfer.access { value -> Owner? in
                    defer { value = nil }
                    return value
                }
                retiring?.close()
            }
        }
    }
}
