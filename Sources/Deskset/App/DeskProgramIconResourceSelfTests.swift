import AppKit
import DesksetCore
import DesksetDraw

/// Deterministic owner transactions: Main preparation is a manually delivered immutable vector PDF batch.
/// These cases do not invoke the native symbol service, run a window, or wait for wall-clock callbacks.
enum DeskProgramIconResourceSelfTests {
    private enum Failure: Error { case fixture, producer }

    private final class Preparation {
        struct Call {
            let demands: [DeskIconResources.Demand]
            let completion: (Result<DeskIconResources.Batch, Error>) -> Void
            let ticket: DeskIconResources.Ticket
        }
        var calls: [Call] = []
        func submit(_ demands: [DeskIconResources.Demand],
                    completion: @escaping (Result<DeskIconResources.Batch, Error>) -> Void) -> DeskIconResources.Ticket {
            let ticket = DeskIconResources.Ticket()
            calls.append(Call(demands: demands, completion: completion, ticket: ticket))
            return ticket
        }
        func succeed(_ index: Int, images: [String: DeskIconResources.Prepared] = [:]) {
            let call = calls[index]
            call.completion(.success(.init(entries: call.demands.map {
                .init(demand: $0, prepared: images[$0.request.name])
            })))
        }
    }

    private final class Provider: ContentProvider {
        var frames: [SkinFrame] = []
        var releases = 0
        func present(_ frame: SkinFrame) { frames.append(frame) }
        func setVisible(_ visible: Bool) {}
        func setScale(_ scale: CGFloat) {}
        func releaseContents() { releases += 1 }
        func teardown() {}
    }

    private final class System: SystemDataSource {
        let processorCount = 4
        var cpu = 25.0
        var cpuCalls = 0
        func cpuUsage(processor: Int) -> Double { cpuCalls += 1; return cpu }
        func memoryStatus() -> MemoryStatus { MemoryStatus(physicalTotal: 16, physicalUsed: 8) }
        func networkInterfaces() -> [String] { [] }
        func networkCounters(interface: String?) -> NetworkCounters { NetworkCounters() }
        func diskSpace(path: String) -> (total: Double, free: Double)? { nil }
        func uptime() -> TimeInterval { 0 }
        func battery() -> BatteryStatus? { nil }
        func isProcessRunning(_ name: String) -> Bool { false }
        func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { nil }
        func volumeInfo(path: String) -> VolumeInfo? { nil }
        func cpuFrequency() -> Double? { nil }
        func desktopPicturePath() -> String? { nil }
    }

    static func run(_ t: AppTestRunner) {
        initialTests(t)
        actionTests(t)
        cancellationTests(t)
        failureTests(t)
        rasterBudgetTests(t)
    }

    private static let rootID = ElementID(name: "icon", index: 0)
    private static let point = SkinPoint(x: 10, y: 10)

    private static func input(dark: Bool = false, scale: Double = 1) -> DeskProgramHost.Input {
        DeskProgramHost.Input(environment: EnvironmentStamp(scale: scale, fontGeneration: 0,
            appearance: AppearanceStamp(value: dark ? .dark : .light,
                name: (dark ? NSAppearance.Name.darkAqua : .aqua).rawValue), imageGeneration: 0),
            colors: ProgramColorInput(colors: Dictionary(uniqueKeysWithValues: ProgramPaletteColor.allCases.map { ($0, .white) })),
            locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func facts(_ input: DeskProgramHost.Input, ordered: Bool = true,
                              panel: UInt64 = 0) -> SkinWindowFacts {
        SkinWindowFacts(frame: .zero, isVisible: true, isOrderedIn: ordered,
            scale: CGFloat(input.environment.scale), colorSpace: SkinFrameProducer.sRGB,
            appearance: input.environment.appearance.name, takesPointer: true, sequence: 1, panelGeneration: panel)
    }

    private static func clock() throws -> VirtualTimeExecutor {
        guard let zone = TimeZone(secondsFromGMT: 0) else { throw Failure.fixture }
        let time = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 0.25), timeZone: zone)
        time.background.allowsUnfakedWork = false
        return time
    }

    private static func icons(_ items: [DrawItem]) -> [IconDraw] {
        items.flatMap { item -> [IconDraw] in
            switch item {
            case .icon(let value): return [value]
            case .transformed(_, let children), .antialias(_, let children): return icons(children)
            case .container(_, let mask, let content): return icons(mask) + icons(content)
            default: return []
            }
        }
    }

    private static func label(_ host: DeskProgramHost) -> String? {
        host.scene?.elements.first(where: { $0.id == rootID })?.accessibilityLabel
    }

    private static func pdf(_ width: Double = 24, _ height: Double = 12) throws -> DeskIconResources.Prepared {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw Failure.fixture }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(box.insetBy(dx: width / 8, dy: height / 8))
        context.endPDFPage(); context.closePDF()
        return DeskIconResources.Prepared(size: SkinSize(width: width, height: height), pdf: data as Data)
    }

    private static func program(actions: [ProgramAction]? = nil, secondary: Bool = false,
                                ownFont: Bool = false, size: ProgramWidgetSize = .fit) -> WidgetProgram {
        let actions = actions ?? [.assign(.init(declaration: 0, value: .string("new"))), .copy(.string("accepted"))]
        let root = ProgramElement(id: rootID, content: .icon(ProgramIcon(name: .declaration(0), hasOwnFont: ownFont)),
            width: .fixed(40), height: .fixed(30), onClickActions: secondary ? nil : actions,
            onRightClickActions: secondary ? actions : nil, background: .color(.literal(.white)), voiceOver: .declaration(0))
        return WidgetProgram(name: "Async icon", root: root,
            declarations: [.init(name: "name", kind: .variable, initial: .string("old"))], size: size)
    }

    private static func click(_ host: DeskProgramHost, secondary: Bool = false,
                              completion: @escaping ([ProgramEffect]) -> Void) -> [ProgramEffect]? {
        if secondary {
            host.secondaryPress(at: point)
            return host.secondaryRelease(at: point, completion: completion)
        }
        host.primaryPress(at: point)
        return host.primaryRelease(at: point, completion: completion)
    }

    private static func initialTests(_ t: AppTestRunner) {
        t.suite("App: Desk icon resources: initial batch never publishes placeholder geometry and supplies the first frame") {
            let input = Self.input(), time = try clock(), preparation = Preparation(), provider = Provider()
            let children = ["wide", "tall", "wide"].enumerated().map { index, name in
                ProgramElement(id: ElementID(name: name, index: index + 1),
                    content: .icon(ProgramIcon(name: .string(name), hasOwnFont: true)),
                    width: .fixed(40), height: .fixed(30))
            }
            let program = WidgetProgram(name: "Batch", root: ProgramElement(id: rootID,
                content: .column(spacing: 0, align: .left, children: children), background: .color(.literal(.white))))
            let host = try DeskProgramHost(program: program, executor: time, provider: provider, input: input,
                clock: time.clock, prepareIcons: preparation.submit)
            defer { host.close() }
            host.take(facts(input, ordered: false), input: input); host.start(); host.drawFirstFrame()
            t.equal(preparation.calls.count, 1)
            t.equal(Set(preparation.calls[0].demands.map { $0.request.name }), ["wide", "tall"])
            t.equal(preparation.calls[0].demands.count, 2, "equal requests share one Main preparation")
            t.equal(host.state, .idle); t.check(host.isPreparingIcons)
            t.check(host.scene == nil && host.presented == nil); t.equal(provider.frames.count, 0)
            let images = ["wide": try pdf(), "tall": try pdf(12, 24)]
            preparation.succeed(0, images: images)
            t.check(host.scene == nil, "a Main reply cannot mutate the owner inline")
            time.runUntilIdle()
            t.equal(host.state, .ready); t.check(!host.isPreparingIcons)
            t.equal(host.scene?.size, SkinSize(width: 40, height: 90))
            t.equal(icons(host.scene?.drawingItems ?? []).map(\.naturalSize),
                [SkinSize(width: 24, height: 12), SkinSize(width: 12, height: 24), SkinSize(width: 24, height: 12)])
            t.equal(host.presented?.scene.generation, host.scene?.generation)
            t.equal(provider.frames.count, 1, "initial asynchronous readiness draws before the panel is ordered in")
            let generation = host.scene?.generation
            preparation.succeed(0, images: images); time.runUntilIdle()
            t.equal(host.scene?.generation, generation); t.equal(provider.frames.count, 1)
            t.equal(time.background.reports, [])
        }

        t.suite("App: Desk icon resources: provisional overflow waits for an unknown symbol's real zero size") {
            let input = Self.input(), time = try clock(), preparation = Preparation()
            let icon = ProgramElement(id: ElementID(name: "unknown", index: 1),
                content: .icon(ProgramIcon(name: .string("unknown"))))
            let program = WidgetProgram(name: "Unknown in zero row", root: ProgramElement(id: rootID,
                content: .row(spacing: 0, align: .top, children: [icon]), width: .fixed(0), height: .fixed(0)))
            let host = try DeskProgramHost(program: program, executor: time, provider: nil, input: input,
                clock: time.clock, prepareIcons: preparation.submit)
            defer { host.close() }
            host.take(facts(input), input: input); host.start()
            t.check(host.isPreparingIcons); t.equal(host.state, .idle)
            preparation.succeed(0); time.runUntilIdle()
            t.equal(host.state, .ready); t.equal(host.scene?.size, SkinSize())
            t.check(host.scene?.drawingItems.isEmpty == true)
        }
    }

    private static func actionTests(_ t: AppTestRunner) {
        t.suite("App: Desk icon resources: pending primary and secondary actions freeze inputs and coalesce clock refresh") {
            for secondary in [false, true] {
                let input = Self.input(), time = try clock(), preparation = Preparation(), provider = Provider(), system = System()
                let format = ProgramNumberFormat(decimals: 0)
                let effects = ProgramExpression.concatenate([
                    .formatNumber(.declaration(1), format), .string("|"), .formatNumber(.declaration(2), format),
                    .string("|"), .formatDate(.declaration(3), .pattern("HH:mm:ss"))])
                let actions: [ProgramAction] = [
                    .assign(.init(declaration: 0, value: .string("new"))),
                    .assign(.init(declaration: 1, value: .add(.declaration(1), .number(1)))),
                    .assign(.init(declaration: 2, value: .systemProperty(.cpuUsage))),
                    .assign(.init(declaration: 3, value: .timeNow)), .copy(effects)]
                let root = ProgramElement(id: rootID, content: .icon(ProgramIcon(name: .declaration(0))),
                    width: .fixed(40), height: .fixed(30), onClickActions: secondary ? nil : actions,
                    onRightClickActions: secondary ? actions : nil, background: .color(.literal(.white)),
                    voiceOver: .concatenate([.declaration(0), .string(" "), .formatDate(.timeNow, .pattern("HH:mm:ss"))]))
                let program = WidgetProgram(name: "Frozen action", root: root, declarations: [
                    .init(name: "name", kind: .variable, initial: .string("old")),
                    .init(name: "count", kind: .variable, initial: .number(0)),
                    .init(name: "sample", kind: .variable, initial: .quantity(ProgramNumber(0, dimension: .percent))),
                    .init(name: "instant", kind: .variable, initial: .timeNow)])
                let host = try DeskProgramHost(program: program, executor: time, provider: provider, input: input,
                    clock: time.clock, system: system, prepareIcons: preparation.submit)
                defer { host.close() }
                host.take(facts(input), input: input); host.start(); preparation.succeed(0); time.runUntilIdle()
                t.equal(label(host), "old 00:00:00"); t.equal(host.clockPrecision, .second)
                let generation = host.scene?.generation
                var delivered: [[ProgramEffect]] = [], labelAtCompletion: String?
                let direct = click(host, secondary: secondary) {
                    delivered.append($0); labelAtCompletion = label(host)
                }
                t.equal(direct, nil); t.check(host.isPreparingIcons)
                t.equal(preparation.calls.count, 2); t.equal(system.cpuCalls, 1)
                t.equal(host.scene?.generation, generation); t.equal(delivered, [])
                system.cpu = 99
                time.advance(by: 2)
                host.frames.setNeedsFrame(); host.frames.runLoopTurn(.beforeWaiting)
                t.equal(host.state, .ready); t.equal(host.scene?.generation, generation)
                t.equal(system.cpuCalls, 1, "ordinary ticks do not recapture the pending click's system snapshot")
                t.equal(preparation.calls.count, 2); t.equal(delivered, [])
                t.equal(click(host, secondary: secondary) { delivered.append($0) }, nil)
                t.equal(preparation.calls.count, 2, "a pending action cannot queue another press on the old generation")
                preparation.succeed(1)
                t.equal(delivered, [])
                time.runUntilIdle()
                t.equal(delivered, [[.copy("1|25|00:00:00")]])
                t.equal(labelAtCompletion, "new 00:00:00", "effects observe the action's committed captured projection")
                t.equal(label(host), "new 00:00:02", "one deferred refresh follows the completed action")
                t.equal(system.cpuCalls, 1); t.check(!host.isPreparingIcons)
                let settled = host.scene?.generation
                preparation.succeed(1); time.runUntilIdle()
                t.equal(delivered.count, 1); t.equal(host.scene?.generation, settled)
                t.equal(time.background.reports, [])
            }
        }

        t.suite("App: Desk icon resources: prepared synchronous actions return directly without invoking completion") {
            let input = Self.input(), time = try clock(), preparation = Preparation(), provider = Provider()
            let host = try DeskProgramHost(program: program(actions: [.copy(.string("direct"))]), executor: time,
                provider: provider, input: input, clock: time.clock, prepareIcons: preparation.submit)
            defer { host.close() }
            host.take(facts(input), input: input); host.start(); preparation.succeed(0); time.runUntilIdle()
            var callbacks = 0
            t.equal(click(host) { _ in callbacks += 1 }, [.copy("direct")])
            t.equal(callbacks, 0); t.equal(preparation.calls.count, 1); t.check(!host.isPreparingIcons)
        }
    }

    private static func cancellationTests(_ t: AppTestRunner) {
        t.suite("App: Desk icon resources: new input destination and close discard pending actions and late replies") {
            for reason in ["input", "destination", "close"] {
                let input = Self.input(), time = try clock(), preparation = Preparation(), provider = Provider()
                let host = try DeskProgramHost(program: program(), executor: time, provider: provider, input: input,
                    clock: time.clock, prepareIcons: preparation.submit)
                defer { host.close() }
                host.take(facts(input), input: input); host.start(); preparation.succeed(0); time.runUntilIdle()
                var delivered: [[ProgramEffect]] = []
                t.equal(click(host) { delivered.append($0) }, nil); t.check(host.isPreparingIcons)
                switch reason {
                case "input":
                    let changed = Self.input(dark: true)
                    host.take(facts(changed), input: changed)
                    t.equal(preparation.calls.count, 3)
                    t.equal(preparation.calls[2].demands.first?.request.name, "old", "cancelled assignments are not adopted")
                    t.check(preparation.calls[2].demands.first?.request.appearance.value.isDark == true)
                case "destination": host.take(facts(input, panel: 2), input: input)
                default: host.close()
                }
                t.check(preparation.calls[1].ticket.isCancelled)
                preparation.succeed(1); time.runUntilIdle()
                t.equal(delivered, [], reason)
                if reason == "input" { preparation.succeed(2); time.runUntilIdle() }
                if reason == "close" {
                    t.equal(host.state, .closed); t.check(host.scene == nil && host.presented == nil)
                } else {
                    t.equal(host.state, .ready); t.equal(label(host), "old")
                    t.check(!host.isPreparingIcons)
                }
            }
        }
    }

    private static func failureTests(_ t: AppTestRunner) {
        t.suite("App: Desk icon resources: failed malformed and changed-file replies clear without committing effects") {
            for reason in ["producer", "batch", "file"] {
                let input = Self.input(), time = try clock(), preparation = Preparation(), provider = Provider()
                let folder = t.temporaryDirectory("icon-owner-\(reason)")
                let file = folder.appendingPathComponent("resource.dat")
                var resources: DeskProgramResources.Prepared?
                if reason == "file" {
                    try Data([1, 2, 3]).write(to: file)
                    guard let stamp = Images.imageStamp(atPath: file.path) else { throw Failure.fixture }
                    resources = .init(root: folder, folder: nil, files: [],
                        images: ["unused": ProgramImageResource(path: file.path, naturalSize: SkinSize(width: 1, height: 1), stamp: stamp)],
                        sources: [], failure: nil)
                }
                let host = try DeskProgramHost(program: program(), executor: time, provider: provider, input: input,
                    prepared: resources, clock: time.clock, prepareIcons: preparation.submit)
                defer { host.close() }
                host.take(facts(input), input: input); host.start(); preparation.succeed(0); time.runUntilIdle()
                var delivered: [[ProgramEffect]] = []
                t.equal(click(host) { delivered.append($0) }, nil)
                switch reason {
                case "producer": preparation.calls[1].completion(.failure(Failure.producer))
                case "batch": preparation.calls[1].completion(.success(.init(entries: [])))
                default: try FileManager.default.removeItem(at: file); preparation.succeed(1)
                }
                time.runUntilIdle()
                if case .unavailable = host.state { t.check(true) } else { t.check(false, reason) }
                t.check(host.scene == nil && host.presented == nil); t.check(!host.isPreparingIcons)
                t.equal(delivered, []); t.check(provider.releases > 0)
                preparation.succeed(1); time.runUntilIdle(); t.equal(delivered, [])
                if reason != "file" {
                    host.refresh()
                    t.equal(preparation.calls.count, 3)
                    t.equal(preparation.calls[2].demands.first?.request.name, "old", "failure rolled back the candidate runtime")
                    preparation.succeed(2); time.runUntilIdle()
                    t.equal(host.state, .ready); t.equal(label(host), "old")
                }
            }
        }
    }

    private static func rasterBudgetTests(_ t: AppTestRunner) {
        t.suite("App: Desk icon resources: actual-density raster budget rejects click effects before runtime commit") {
            for scale in [1.0, 2.0] {
                let input = Self.input(scale: scale), time = try clock(), preparation = Preparation(), provider = Provider()
                let host = try DeskProgramHost(program: program(ownFont: true), executor: time, provider: provider,
                    input: input, clock: time.clock, prepareIcons: preparation.submit)
                defer { host.close() }
                host.take(facts(input), input: input); host.start()
                preparation.succeed(0, images: ["old": try pdf()]); time.runUntilIdle()
                t.equal(host.state, .ready)
                var delivered: [[ProgramEffect]] = []
                t.equal(click(host) { delivered.append($0) }, nil)
                // Both logical sides pass the host's 16,384-pixel extent limit; the individual raster exceeds 16 MiB.
                preparation.succeed(1, images: ["new": try pdf(3_000 / scale, 3_000 / scale)])
                time.runUntilIdle()
                if case .unavailable = host.state { t.check(true) } else { t.check(false) }
                t.equal(delivered, []); t.check(host.scene == nil && host.presented == nil)
                host.refresh()
                t.equal(preparation.calls.last?.demands.first?.request.name, "old")
                preparation.succeed(2, images: ["old": try pdf()]); time.runUntilIdle()
                t.equal(host.state, .ready); t.equal(label(host), "old")
            }
        }

        t.suite("App: Desk icon resources: overlapping icon rasters share one frame budget and preset scaling reduces density") {
            for preset in [false, true] {
                let input = Self.input(), time = try clock(), preparation = Preparation(), provider = Provider()
                let actions: [ProgramAction] = [.assign(.init(declaration: 0, value: .string("large-a"))),
                    .assign(.init(declaration: 1, value: .string("large-b"))), .copy(.string("accepted"))]
                let children = (0..<2).map { index in
                    ProgramElement(id: ElementID(name: "layer", index: index + 1),
                        content: .icon(ProgramIcon(name: .declaration(index), hasOwnFont: true)),
                        width: .fixed(40), height: .fixed(30), position: ProgramPosition(x: -20, y: -10))
                }
                let root = ProgramElement(id: rootID, content: .freeform(align: .topLeft, children: children),
                    width: .fixed(40), height: .fixed(30), onClickActions: actions,
                    background: .color(.literal(.white)), voiceOver: .declaration(0))
                let program = WidgetProgram(name: "Overlapping rasters", root: root, declarations: [
                    .init(name: "a", kind: .variable, initial: .string("old-a")),
                    .init(name: "b", kind: .variable, initial: .string("old-b"))],
                    size: preset ? .preset(.small, size: SkinSize(width: 100, height: 100)) : .fit)
                let host = try DeskProgramHost(program: program, executor: time, provider: provider, input: input,
                    clock: time.clock, prepareIcons: preparation.submit)
                defer { host.close() }
                host.take(facts(input), input: input); host.start()
                preparation.succeed(0, images: ["old-a": try pdf(), "old-b": try pdf()]); time.runUntilIdle()
                t.equal(host.state, .ready)
                guard let presented = host.presented,
                      let frame = presented.scene.elements.first(where: { $0.id == rootID })?.frame else { throw Failure.fixture }
                let point = SkinPoint(x: frame.x + frame.width / 2 - presented.origin.x,
                                      y: frame.y + frame.height / 2 - presented.origin.y)
                var delivered: [[ProgramEffect]] = []
                host.primaryPress(at: point)
                t.equal(host.primaryRelease(at: point) { delivered.append($0) }, nil)
                t.equal(preparation.calls.count, 2)
                // Two distinct overlapping 1,600² RGBA images fit separately but cannot both be pinned in 16 MiB.
                preparation.succeed(1, images: ["large-a": try pdf(1_600, 1_600), "large-b": try pdf(1_600, 1_600)])
                time.runUntilIdle()
                if preset {
                    t.equal(host.state, .ready); t.equal(delivered, [[.copy("accepted")]])
                    t.equal(label(host), "large-a")
                    t.check((host.context?.drawing.icons.bitmapBytes ?? Int.max) < 1 << 20,
                            "the preflight uses the final preset transform rather than unscaled native size")
                    host.frames.runLoopTurn(.beforeWaiting)
                    t.equal(host.presented?.scene.generation, host.scene?.generation)
                } else {
                    if case .unavailable = host.state { t.check(true) } else { t.check(false) }
                    t.equal(delivered, []); t.check(host.scene == nil)
                }
            }
        }
    }
}
