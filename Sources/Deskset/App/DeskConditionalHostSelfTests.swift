import AppKit
import DeskLanguage
import DesksetCore
import DesksetDraw

/// Shared fixtures for conditional Host/Preview transactions. Colored vector documents exercise resource
/// identity and publication; native SF Symbol rendering is qualified by IconDrawingSelfTests.
enum DeskConditionalTestSupport {
    enum Failure: Error { case fixture, bitmap, preparation, compilation(String), missingRequest(Int, Int) }

    final class System: SystemDataSource {
        let processorCount = 4
        var cpu = 25.0
        var cpuCalls = 0
        var charging = false
        var batteryCalls = 0
        func cpuUsage(processor: Int) -> Double { cpuCalls += 1; return cpu }
        func battery() -> BatteryStatus? {
            batteryCalls += 1
            return BatteryStatus(percent: 50, isCharging: charging, isPluggedIn: charging)
        }
        func memoryStatus() -> MemoryStatus { MemoryStatus(physicalTotal: 16, physicalUsed: 8) }
        func networkInterfaces() -> [String] { [] }
        func networkCounters(interface: String?) -> NetworkCounters { NetworkCounters() }
        func diskSpace(path: String) -> (total: Double, free: Double)? { nil }
        func uptime() -> TimeInterval { 0 }
        func isProcessRunning(_ name: String) -> Bool { false }
        func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { nil }
        func volumeInfo(path: String) -> VolumeInfo? { nil }
        func cpuFrequency() -> Double? { nil }
        func desktopPicturePath() -> String? { nil }
    }

    final class Preparation {
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
        func call(_ index: Int) throws -> Call {
            guard calls.indices.contains(index) else { throw Failure.missingRequest(index, calls.count) }
            return calls[index]
        }
        func succeed(_ index: Int) throws {
            let value = try call(index)
            value.completion(.success(.init(entries: try value.demands.map {
                .init(demand: $0, prepared: try vector($0.request.style.color))
            })))
        }
        func fail(_ index: Int) throws { try call(index).completion(.failure(Failure.preparation)) }
        private func vector(_ color: RGBA) throws -> DeskIconResources.Prepared {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 20, height: 20)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw Failure.fixture }
            context.beginPDFPage(nil)
            context.setFillColor(Self.cgColor(color))
            context.fill(box.insetBy(dx: 2, dy: 2))
            context.endPDFPage(); context.closePDF()
            return .init(size: SkinSize(width: 20, height: 20), pdf: data as Data)
        }
        private static func cgColor(_ value: RGBA) -> CGColor {
            CGColor(srgbRed: value.r / 255, green: value.g / 255, blue: value.b / 255, alpha: value.a / 255)
        }
    }

    final class Provider: ContentProvider {
        var frames: [SkinFrame] = []
        var releases = 0
        func present(_ frame: SkinFrame) { frames.append(frame) }
        func setVisible(_ visible: Bool) {}
        func setScale(_ scale: CGFloat) {}
        func releaseContents() { releases += 1 }
        func teardown() {}
        func image() throws -> CGImage {
            guard let image = frames.last?.image else { throw Failure.bitmap }
            return image
        }
    }

    static let red = RGBA(r: 255, g: 0, b: 0, a: 255)
    static let blue = RGBA(r: 0, g: 0, b: 255, a: 255)
    static let green = RGBA(r: 0, g: 255, b: 0, a: 255)
    static let yellow = RGBA(r: 255, g: 255, b: 0, a: 255)

    static func clock() throws -> VirtualTimeExecutor {
        guard let zone = TimeZone(secondsFromGMT: 0) else { throw Failure.fixture }
        let result = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 0.25), timeZone: zone)
        result.background.allowsUnfakedWork = false
        return result
    }
    static func program(_ source: String) throws -> WidgetProgram {
        let result = Desk.compile(Desk.check(Desk.parse(source, fileName: "Conditional.desk")))
        guard let program = result.program else {
            throw Failure.compilation(result.issues.map(\.message).joined(separator: "; ") + " " + String(describing: result.diagnostics))
        }
        return program
    }
    static func input(dark: Bool = false, scale: Double = 1) -> DeskProgramHost.Input {
        .init(environment: EnvironmentStamp(scale: scale, fontGeneration: 0,
            appearance: AppearanceStamp(value: dark ? .dark : .light,
                name: (dark ? NSAppearance.Name.darkAqua : .aqua).rawValue), imageGeneration: 0),
            colors: ProgramColorInput(colors: Dictionary(uniqueKeysWithValues: ProgramPaletteColor.allCases.map { ($0, .white) })),
            locale: Locale(identifier: "en_US_POSIX"))
    }
    static func facts(_ input: DeskProgramHost.Input) -> SkinWindowFacts {
        SkinWindowFacts(frame: .zero, isVisible: true, isOrderedIn: true,
            scale: CGFloat(input.environment.scale), colorSpace: SkinFrameProducer.sRGB,
            appearance: input.environment.appearance.name, takesPointer: true, sequence: 1)
    }
    static func element(_ scene: WidgetScene?, _ name: String) throws -> SceneElement {
        guard let value = scene?.elements.first(where: { $0.id.name == name }) else { throw Failure.fixture }
        return value
    }
    static func point(_ host: DeskProgramHost, _ name: String) throws -> SkinPoint {
        guard let presented = host.presented else { throw Failure.fixture }
        let frame = try element(presented.scene, name).frame
        return SkinPoint(x: frame.x + frame.width / 2 - presented.origin.x,
                         y: frame.y + frame.height / 2 - presented.origin.y)
    }
    static func click(_ host: DeskProgramHost, _ name: String,
                      completion: (([ProgramEffect]) -> Void)? = nil) throws -> [ProgramEffect]? {
        let point = try point(host, name)
        host.primaryPress(at: point)
        return host.primaryRelease(at: point, completion: completion)
    }
    static func flush(_ host: DeskProgramHost, _ time: VirtualTimeExecutor) {
        time.runUntilIdle(); host.frames.runLoopTurn(.beforeWaiting)
    }
    static func icons(_ scene: WidgetScene?) -> [IconDraw] { icons(scene?.drawingItems ?? []) }
    private static func icons(_ items: [DrawItem]) -> [IconDraw] {
        items.flatMap { item -> [IconDraw] in
            switch item {
            case .icon(let icon): return [icon]
            case .transformed(_, let children), .antialias(_, let children): return icons(children)
            case .container(_, let mask, let content): return icons(mask) + icons(content)
            default: return []
            }
        }
    }
    static func texts(_ scene: WidgetScene?) -> [String] {
        var pending = scene?.drawingItems ?? [], result: [String] = []
        while let item = pending.popLast() {
            switch item {
            case .text(let draw): result.append(draw.text)
            case .transformed(_, let children), .antialias(_, let children): pending += children
            default: break
            }
        }
        return Array(result.reversed())
    }
    static func bytes(_ image: CGImage) throws -> Data {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: SkinFrameProducer.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else { throw Failure.bitmap }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: data, count: context.bytesPerRow * context.height)
    }
    static func paint(_ view: NSView, scale: Int = 1) throws -> CGImage {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, bounds.width <= 512, bounds.height <= 512,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(bounds.width * Double(scale))),
                pixelsHigh: Int(ceil(bounds.height * Double(scale))), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let data = rep.bitmapData else { throw Failure.bitmap }
        rep.size = bounds.size
        data.initialize(repeating: 0, count: rep.bytesPerRow * rep.pixelsHigh)
        view.cacheDisplay(in: bounds, to: rep)
        guard let image = rep.cgImage else { throw Failure.bitmap }
        return image
    }
    static func literal(size: NSSize, scale: Int, rectangles: [(CGRect, RGBA)]) throws -> CGImage {
        guard let context = CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale,
            bitsPerComponent: 8, bytesPerRow: Int(size.width) * scale * 4, space: SkinFrameProducer.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.bitmap }
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
        for (rect, value) in rectangles {
            context.setFillColor(CGColor(srgbRed: value.r / 255, green: value.g / 255,
                                        blue: value.b / 255, alpha: value.a / 255))
            context.fill(rect)
        }
        guard let image = context.makeImage() else { throw Failure.bitmap }
        return image
    }

    static let visibilitySource = """
    widget {
        variable concealed = false
        Row(spacing: 0, align: .top) {
            Rectangle().size(20, 20).fill("#00FF00").name(switcher)
                .onClick { concealed = not concealed }
            Rectangle().size(30, 20).fill("#FF0000").hidden(if: concealed)
                .voiceOver("Target").name(target).onClick { copy("target") }
            Rectangle().size(10, 20).fill("#0000FF").name(tail)
        }
    }
    """
    static func iconSource(condition: String = "false") -> String {
        """
        widget {
            variable hot = false
            Icon("wifi").size(40).color("#FF0000").color("#0000FF", if: hot)
                .hidden(if: \(condition)).voiceOver("Signal").name(signal)
                .onClick { hot = not hot; copy("changed") }
        }
        """
    }
}

enum DeskConditionalHostSelfTests {
    private typealias S = DeskConditionalTestSupport

    static func run(_ t: AppTestRunner) {
        visibilityTests(t)
        iconTests(t)
        accessibilityTest(t)
    }

    private static func visibilityTests(_ t: AppTestRunner) {
        t.suite("App: Desk conditional host: hidden keeps space and changes only accepted pixels and hits") {
            let program = try S.program(S.visibilitySource)
            for dark in [false, true] {
                for scale in [1, 2] {
                    let input = S.input(dark: dark, scale: Double(scale)), time = try S.clock(), provider = S.Provider()
                    let host = try DeskProgramHost(program: program, executor: time, provider: provider, input: input, clock: time.clock)
                    defer { host.close() }
                    host.take(S.facts(input), input: input); host.start(); host.drawFirstFrame()
                    let frames = host.scene?.elements.map(\.frame), size = SkinSize(width: 60, height: 20)
                    let green = (CGRect(x: 0, y: 0, width: 20, height: 20), S.green)
                    let red = (CGRect(x: 20, y: 0, width: 30, height: 20), S.red)
                    let blue = (CGRect(x: 50, y: 0, width: 10, height: 20), S.blue)
                    let initial = try S.bytes(provider.image())
                    t.equal(initial, try S.bytes(S.literal(size: NSSize(width: 60, height: 20), scale: scale,
                                                          rectangles: [green, red, blue])))
                    t.equal(host.scene?.size, size)
                    let oldGeneration = host.presented?.scene.generation
                    t.equal(try S.click(host, "switcher"), [])
                    t.equal(try S.element(host.scene, "target").visibility, .hiddenKeepsSpace)
                    t.equal(host.scene?.elements.map(\.frame), frames)
                    t.equal(host.scene?.size, size)
                    t.check(host.scene?.hitMap.entries.contains(where: { $0.elementID?.name == "target" }) == false)
                    t.equal(host.presented?.scene.generation, oldGeneration, "the owner projection has not been presented")
                    t.equal(try S.bytes(provider.image()), initial)
                    S.flush(host, time)
                    t.equal(host.presented?.scene.generation, host.scene?.generation)
                    t.equal(try S.bytes(provider.image()), try S.bytes(S.literal(size: NSSize(width: 60, height: 20),
                        scale: scale, rectangles: [green, blue])), "the reserved target slot is transparent")
                    t.equal(try S.click(host, "target"), nil)
                    t.equal(try S.click(host, "switcher"), []); S.flush(host, time)
                    t.equal(try S.bytes(provider.image()), initial, "restoring visibility restores the exact colored bitmap")
                    t.equal(try S.click(host, "target"), [.copy("target")])
                    t.equal(time.background.reports, [])
                }
            }
        }

        t.suite("App: Desk conditional host: power hides a held target and pauses then restores its text clock") {
            let source = """
            widget { Row(spacing: 0, align: .top) {
                Text("{time.now, format: "ss"}").size(40, 20).hidden(if: battery.charging)
                    .name(target).onClick { copy("primary") }.onRightClick { copy("secondary") }
                Rectangle().size(10, 20).fill(.white)
            } }
            """
            let time = try S.clock(), system = S.System(), input = S.input(), provider = S.Provider()
            let host = try DeskProgramHost(program: S.program(source), executor: time, provider: provider,
                input: input, clock: time.clock, system: system)
            defer { host.close() }
            host.take(S.facts(input), input: input); host.start(); host.drawFirstFrame()
            let originalFrame = try S.element(host.scene, "target").frame
            t.equal(S.texts(host.scene), ["00"]); t.equal(host.clockPrecision, .second)
            t.check(host.neededSystemProperties.contains(.batteryCharging))
            for secondary in [false, true] {
                let point = try S.point(host, "target")
                if secondary { host.secondaryPress(at: point) } else { host.primaryPress(at: point) }
                system.charging = true; host.notifyPowerChange(); S.flush(host, time)
                t.equal(S.texts(host.scene), []); t.equal(host.clockPrecision, nil)
                t.equal(try S.element(host.scene, "target").frame, originalFrame)
                t.equal(host.presented?.scene.generation, host.scene?.generation, "the hidden frame has been accepted")
                let hiddenGeneration = host.scene?.generation, reads = system.batteryCalls
                time.advance(by: 3)
                t.equal(host.scene?.generation, hiddenGeneration); t.equal(system.batteryCalls, reads)
                system.charging = false; host.notifyPowerChange(); S.flush(host, time)
                t.equal(S.texts(host.scene), [secondary ? "07" : "03"]); t.equal(host.clockPrecision, .second)
                let released = secondary ? host.secondaryRelease(at: point) : host.primaryRelease(at: point)
                t.equal(released, nil, "hide then restore cannot resurrect a press from before the accepted hidden frame")
                // A normal clock repaint preserves a new press on a continuously visible target.
                if secondary { host.secondaryPress(at: point) } else { host.primaryPress(at: point) }
                time.advance(by: 1); S.flush(host, time)
                t.equal(secondary ? host.secondaryRelease(at: point) : host.primaryRelease(at: point),
                        [.copy(secondary ? "secondary" : "primary")])
                S.flush(host, time)
            }
            host.close(); let closedReads = system.batteryCalls
            host.notifyPowerChange(); time.advance(by: 3)
            t.equal(system.batteryCalls, closedReads); t.equal(time.background.reports, [])
        }
    }

    private static func iconTests(_ t: AppTestRunner) {
        t.suite("App: Desk conditional host: color alone prepares a new icon and returning color reuses its cache") {
            let input = S.input(), time = try S.clock(), preparations = S.Preparation(), provider = S.Provider()
            let host = try DeskProgramHost(program: S.program(S.iconSource()), executor: time, provider: provider,
                input: input, clock: time.clock, prepareIcons: preparations.submit)
            defer { host.close() }
            host.take(S.facts(input), input: input); host.start()
            try preparations.succeed(0); time.runUntilIdle()
            let redPixels = try S.bytes(provider.image()), generation = host.scene?.generation
            var effects: [[ProgramEffect]] = []
            t.equal(try S.click(host, "signal", completion: { effects.append($0) }), nil)
            t.check(host.isPreparingIcons); t.equal(preparations.calls.count, 2)
            guard let old = try preparations.call(0).demands.first?.request,
                  let new = try preparations.call(1).demands.first?.request else { throw S.Failure.fixture }
            var expected = old; expected.style.color = S.blue
            t.equal(old.style.color, S.red); t.equal(new, expected, "only foreground color changes the complete request")
            t.equal(host.scene?.generation, generation); t.equal(effects, [])
            host.frames.setNeedsFrame(); S.flush(host, time)
            t.equal(try S.bytes(provider.image()), redPixels, "committed resources remain pinned while blue is pending")
            try preparations.succeed(1); time.runUntilIdle(); S.flush(host, time)
            t.equal(effects, [[.copy("changed")]])
            t.equal(S.icons(host.scene).first?.request.style.color, S.blue)
            t.check(try S.bytes(provider.image()) != redPixels)
            t.equal(try S.click(host, "signal", completion: { effects.append($0) }), [.copy("changed")])
            S.flush(host, time)
            t.equal(preparations.calls.count, 2, "the prepared red request is reused")
            t.equal(effects.count, 1, "synchronous cache hits return effects without a duplicate callback")
            t.equal(try S.bytes(provider.image()), redPixels)
            try preparations.succeed(1); time.runUntilIdle()
            t.equal(S.icons(host.scene).first?.request.style.color, S.red); t.equal(effects.count, 1)
            t.equal(time.background.reports, [])
        }

        t.suite("App: Desk conditional host: failed and cancelled color batches cannot publish effects or revive pixels") {
            let input = S.input(), time = try S.clock(), preparations = S.Preparation(), provider = S.Provider()
            let host = try DeskProgramHost(program: S.program(S.iconSource()), executor: time, provider: provider,
                input: input, clock: time.clock, prepareIcons: preparations.submit)
            defer { host.close() }
            host.take(S.facts(input), input: input); host.start()
            try preparations.succeed(0); time.runUntilIdle()
            let redPixels = try S.bytes(provider.image())
            var effects: [[ProgramEffect]] = []
            _ = try S.click(host, "signal", completion: { effects.append($0) })
            try preparations.fail(1); time.runUntilIdle()
            if case .unavailable = host.state {} else { t.check(false, "failed color preparation is unavailable") }
            t.check(host.scene == nil && host.presented == nil); t.check(provider.releases > 0); t.equal(effects, [])
            host.refresh()
            t.equal(preparations.calls.count, 3, "recovery reconstructs the last committed red state")
            try preparations.succeed(1); time.runUntilIdle()
            t.check(host.isPreparingIcons && host.scene == nil); t.equal(effects, [])
            try preparations.succeed(2); time.runUntilIdle(); S.flush(host, time)
            t.equal(host.state, .ready); t.equal(S.icons(host.scene).first?.request.style.color, S.red)
            t.equal(try S.bytes(provider.image()), redPixels)
            _ = try S.click(host, "signal", completion: { effects.append($0) })
            let pending = try preparations.call(3), count = provider.frames.count
            host.close(); t.check(pending.ticket.isCancelled)
            try preparations.succeed(3); time.runUntilIdle()
            t.equal(host.state, .closed); t.check(host.scene == nil && host.presented == nil)
            t.equal(provider.frames.count, count); t.equal(effects, [])
        }

        t.suite("App: Desk conditional host: a pending color action freezes visibility then performs one deferred refresh") {
            let input = S.input(), time = try S.clock(), preparations = S.Preparation(), provider = S.Provider(), system = S.System()
            let host = try DeskProgramHost(program: S.program(S.iconSource(condition: "cpu.usage > 50%")), executor: time,
                provider: provider, input: input, clock: time.clock, system: system, prepareIcons: preparations.submit)
            defer { host.close() }
            host.take(S.facts(input), input: input); host.start()
            try preparations.succeed(0); time.runUntilIdle()
            let size = host.scene?.size, initial = try S.bytes(provider.image())
            var effects: [[ProgramEffect]] = [], visibleAtCompletion = false
            _ = try S.click(host, "signal", completion: {
                effects.append($0); visibleAtCompletion = S.icons(host.scene).first?.request.style.color == S.blue
            })
            let samples = system.cpuCalls
            system.cpu = 75; time.advance(by: 2); host.frames.setNeedsFrame(); S.flush(host, time)
            t.equal(system.cpuCalls, samples); t.equal(preparations.calls.count, 2)
            t.equal(try S.bytes(provider.image()), initial); t.equal(effects, [])
            try preparations.succeed(1); time.runUntilIdle(); S.flush(host, time)
            t.equal(effects, [[.copy("changed")]]); t.check(visibleAtCompletion, "effects observe the frozen visible blue candidate")
            t.equal(try S.element(host.scene, "signal").visibility, .hiddenKeepsSpace)
            t.equal(S.icons(host.scene), []); t.equal(host.scene?.size, size)
            t.equal(host.clockPrecision, .second, "the controlling condition keeps its polling clock")
            t.equal(system.cpuCalls, samples + 1); t.equal(preparations.calls.count, 2)
            t.equal(try S.bytes(provider.image()), Data(repeating: 0, count: 40 * 40 * 4))
            system.cpu = 25; time.advance(by: 1); S.flush(host, time)
            t.equal(S.icons(host.scene).first?.request.style.color, S.blue)
            t.equal(preparations.calls.count, 2, "hidden measurement preserved the real colored resource")
            host.close(); let closedReads = system.cpuCalls
            time.advance(by: 3); t.equal(system.cpuCalls, closedReads)
        }
    }

    private static func accessibilityTest(_ t: AppTestRunner) {
        t.suite("App: Desk conditional host: Main accepts hidden glass pixels hit map and accessibility together") {
            let sourceText = """
            widget { variable concealed = false
                Row(spacing: 0, align: .top) {
                    Rectangle().size(20, 20).fill(.white).name(switcher)
                        .onClick { concealed = not concealed }
                    Rectangle().size(30, 20).fill(.clear).background(.glass).hidden(if: concealed)
                        .voiceOver("Panel").name(panel).onClick { copy("panel") }
                }
            }
            """
            let root = t.temporaryDirectory("desk-conditional-window"), time = try S.clock()
            let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                skinsDirectory: root.appendingPathComponent("Skins"), layoutsDirectory: root.appendingPathComponent("Layouts"),
                backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
                settingsDirectory: root.appendingPathComponent("Settings"), widgetsDirectory: root.appendingPathComponent("Widgets"),
                presentsWindows: false)
            let sourceID = UUID(), instanceID = UUID()
            let source = DeskWidgetSourceState(id: sourceID, entry: sourceID.uuidString.lowercased() + "/Main.desk")
            let instance = DeskWidgetInstanceState(id: instanceID, sourceID: sourceID)
            let directory = root.appendingPathComponent("Widgets").appendingPathComponent(sourceID.uuidString.lowercased())
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(sourceText.utf8).write(to: directory.appendingPathComponent("Main.desk"))
            try app.state.registerDeskInstallation(source: source, instance: instance)
            var copies: [String] = []
            let services = DeskProgramActionServices(resolver: DeskProgramOpenResolver(application: { _ in nil },
                applicationNamed: { _ in nil }, exists: { _ in false }), copy: { copies.append($0); return true }, open: { _ in false })
            let widget = DeskWidgetWindowController(source: source, instance: instance, directory: directory,
                program: try S.program(sourceText), prepared: nil, app: app, executor: time, clock: time.clock, actionServices: services)
            t.atSuiteEnd {
                widget.close(deactivate: false)
                _ = AppSelfTest.spin(timeout: 10) { time.runUntilIdle(); return widget.isClosed }
                _ = app.stopAllForTermination(); app.endEngineThread()
            }
            t.check(AppSelfTest.spin(timeout: 10) { time.runUntilIdle(); return widget.isStarted && widget.latestPresented != nil })
            guard let host = widget.owner.host else { throw S.Failure.fixture }
            let input = try DeskWidgetWindowController.makeInput(for: widget.window.effectiveAppearance,
                                                                 scale: widget.window.backingScaleFactor)
            guard let space = widget.window.colorSpace?.cgColorSpace else { throw S.Failure.fixture }
            let facts = SkinWindowFacts(frame: widget.window.frame, isVisible: true, isOrderedIn: true,
                scale: widget.window.backingScaleFactor, colorSpace: space, appearance: input.environment.appearance.name,
                takesPointer: true, sequence: 100, panelGeneration: widget.destinationEpoch)
            widget.owner.take(facts, input: input); S.flush(host, time)
            t.check(AppSelfTest.spin(timeout: 10) {
                time.runUntilIdle()
                return widget.latestPresented != nil && host.presented?.scene.generation == widget.latestPresented?.scene.generation
                    && !host.frames.hasBitmapDelivery
            })
            guard let old = widget.view.accessibilityParts.first(where: { $0.id.name == "panel" }),
                  let presented = widget.latestPresented else { throw S.Failure.fixture }
            let frame = widget.window.frame
            t.equal(old.accessibilityLabel(), "Panel"); t.equal(old.accessibilityRole(), .button)
            t.equal(widget.nativeComposition.shownPieces.count, 1)
            t.equal(try S.click(host, "switcher"), []); host.frames.runLoopTurn(.beforeWaiting)
            let hiddenGeneration = host.scene?.generation
            t.check(host.frames.hasBitmapDelivery)
            t.equal(widget.latestPresented?.scene.generation, presented.scene.generation)
            t.check(widget.view.accessibilityParts.contains(where: { $0 === old }))
            t.equal(widget.nativeComposition.shownPieces.count, 1, "owner projection cannot remove Main glass early")
            var mainAccepted = false
            DispatchQueue.main.async {
                t.equal(widget.latestPresented?.scene.generation, hiddenGeneration)
                t.check(widget.view.accessibilityParts.contains(where: { $0.id.name == "panel" }) == false)
                t.check(widget.nativeComposition.shownPieces.isEmpty)
                t.equal(widget.window.frame, frame, "hidden preserves reserved layout and window geometry")
                t.equal(old.accessibilityFrame(), .zero); t.check(!old.accessibilityPerformPress())
                t.equal(host.presented?.scene.generation, presented.scene.generation, "Main commit precedes owner ACK")
                mainAccepted = true
            }
            t.check(AppSelfTest.spin(timeout: 10) { time.runUntilIdle(); return mainAccepted && !host.frames.hasBitmapDelivery })
            t.equal(try S.click(host, "panel"), nil)
            t.equal(try S.click(host, "switcher"), []); host.frames.runLoopTurn(.beforeWaiting)
            t.check(AppSelfTest.spin(timeout: 10) {
                time.runUntilIdle()
                return widget.nativeComposition.shownPieces.count == 1 && !host.frames.hasBitmapDelivery
            })
            guard let restored = widget.view.accessibilityParts.first(where: { $0.id.name == "panel" }) else { throw S.Failure.fixture }
            t.check(restored !== old); t.check(!old.accessibilityPerformPress())
            t.check(restored.accessibilityPerformPress())
            t.check(AppSelfTest.spin(timeout: 10) { time.runUntilIdle(); return copies == ["panel"] })
        }
    }
}
