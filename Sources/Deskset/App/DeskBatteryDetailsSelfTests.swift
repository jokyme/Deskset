import AppKit
import DeskLanguage
import DesksetCore
import DesksetDraw

enum DeskBatteryDetailsSelfTests {
    private typealias S = DeskConditionalTestSupport
    private final class System: SystemDataSource {
        let base = S.System()
        var reading = BatteryDetailsReading.pending
        var reads = 0
        var processorCount: Int { base.processorCount }
        func batteryDetails() -> BatteryDetailsReading { reads += 1; return reading }
        func cpuUsage(processor: Int) -> Double { base.cpuUsage(processor: processor) }
        func memoryStatus() -> MemoryStatus { base.memoryStatus() }
        func networkInterfaces() -> [String] { base.networkInterfaces() }
        func networkCounters(interface: String?) -> NetworkCounters { base.networkCounters(interface: interface) }
        func diskSpace(path: String) -> (total: Double, free: Double)? { base.diskSpace(path: path) }
        func uptime() -> TimeInterval { base.uptime() }
        func battery() -> BatteryStatus? { base.battery() }
        func isProcessRunning(_ name: String) -> Bool { base.isProcessRunning(name) }
        func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { base.sysInfo(type: type, data: data) }
        func set(_ health: Double?, _ cycles: Double?) { reading = .ready(BatteryDetails(health: health, cycles: cycles)) }
    }

    private static let textSource = #"widget { Text("{battery.health}% / {battery.cycles}").font(16).size(170, 40).name(status).voiceOver("{battery.health}% / {battery.cycles}") }"#
    private static let actionSource = #"""
    widget {
        variable hot = false
        Column {
            Icon("wifi").size(40).color("#FF0000").color("#0000FF", if: hot)
                .hidden(if: battery.health > 95%).name(signal)
                .onClick { hot = not hot; copy(battery.health) }
            Text("{battery.health}% / {battery.cycles}").size(170, 40).name(status)
        }
    }
    """#

    static func run(_ t: AppTestRunner) {
        host(t)
        heldHost(t)
        preview(t)
        window(t)
    }

    private static func host(_ t: AppTestRunner) {
        t.suite("Desk: battery details: host ready refresh and hourly demand preserve power and close boundaries") {
            let input = S.input(), time = try S.clock(), system = System(), provider = S.Provider()
            let host = try DeskProgramHost(program: S.program(textSource), executor: time, provider: provider,
                input: input, clock: time.clock, system: system)
            defer { host.close() }
            host.take(S.facts(input), input: input); host.start(); host.drawFirstFrame(); S.flush(host, time)
            t.equal(S.texts(host.scene), ["–% / –"])
            let oldPixels = try S.bytes(provider.image()), oldReads = system.reads
            system.set(94, 231); host.notifyBatteryDetailsReady(); S.flush(host, time)
            t.equal(system.reads, oldReads + 1)
            t.equal(S.texts(host.presented?.scene), ["94% / 231"])
            t.equal(try S.element(host.scene, "status").accessibilityLabel, "94% / 231")
            t.check(try S.bytes(provider.image()) != oldPixels)
            let readyReads = system.reads, readyGeneration = host.scene?.generation
            host.notifyPowerChange(); S.flush(host, time)
            t.equal(system.reads, readyReads); t.equal(host.scene?.generation, readyGeneration)
            t.equal(system.base.batteryCalls, 0, "details do not consume or invalidate the IOPS battery cache")
            system.set(0, 0); host.notifyBatteryDetailsReady(); S.flush(host, time)
            t.equal(S.texts(host.scene), ["0% / 0"])
            system.set(nil, nil); host.notifyBatteryDetailsReady(); S.flush(host, time)
            t.equal(S.texts(host.scene), ["–% / –"], "completed missing remains a successful scene")
            let beforeBoundary = system.reads
            system.set(95, 232); time.advance(by: 3599.5); S.flush(host, time)
            t.equal(system.reads, beforeBoundary)
            time.advance(by: 0.25); S.flush(host, time)
            t.equal(system.reads, beforeBoundary + 1); t.equal(S.texts(host.scene), ["95% / 232"])
            let hidden = SkinWindowFacts(frame: .zero, isVisible: false, isOrderedIn: false, scale: 1,
                colorSpace: SkinFrameProducer.sRGB, appearance: input.environment.appearance.name,
                takesPointer: false, sequence: 2)
            host.take(hidden, input: input)
            let hiddenReads = system.reads
            host.notifyBatteryDetailsReady(); time.advance(by: 3600); S.flush(host, time)
            t.equal(system.reads, hiddenReads)
            host.close(); let closedReads = system.reads
            host.notifyBatteryDetailsReady(); time.advance(by: 3600)
            t.equal(system.reads, closedReads)

            let ordinary = try DeskProgramHost(program: S.program(#"widget { Text("Plain") }"#), executor: time,
                provider: S.Provider(), input: input, clock: time.clock, system: system)
            defer { ordinary.close() }
            ordinary.take(S.facts(input), input: input); ordinary.start()
            let generation = ordinary.scene?.generation
            ordinary.notifyBatteryDetailsReady(); S.flush(ordinary, time)
            t.equal(ordinary.scene?.generation, generation); t.equal(system.reads, closedReads)
        }
    }

    private static func heldHost(_ t: AppTestRunner) {
        t.suite("Desk: battery details: host readiness defers behind an action with frozen sampled values") {
            let input = S.input(), time = try S.clock(), system = System(), provider = S.Provider(), preparation = S.Preparation()
            system.set(90, 200)
            let host = try DeskProgramHost(program: S.program(actionSource), executor: time, provider: provider,
                input: input, clock: time.clock, system: system, prepareIcons: preparation.submit)
            defer { host.close() }
            host.take(S.facts(input), input: input); host.start()
            try preparation.succeed(0); S.flush(host, time)
            let pixels = try S.bytes(provider.image())
            var effects: [[ProgramEffect]] = [], textAtCompletion: [String] = []
            _ = try S.click(host, "signal", completion: {
                effects.append($0); textAtCompletion = S.texts(host.scene)
            })
            let reads = system.reads
            system.set(98, 201)
            host.notifyBatteryDetailsReady(); host.notifyBatteryDetailsReady(); S.flush(host, time)
            t.equal(system.reads, reads); t.equal(effects, []); t.equal(preparation.calls.count, 2)
            t.equal(try S.bytes(provider.image()), pixels)
            try preparation.succeed(1); S.flush(host, time)
            t.equal(effects, [[.copy("90")]], "completion consumes the action's captured input once")
            t.equal(textAtCompletion, ["90% / 200"])
            t.equal(S.texts(host.scene), ["98% / 201"])
            t.equal(try S.element(host.scene, "signal").visibility, .hiddenKeepsSpace)
            t.equal(system.reads, reads + 1, "ready notifications coalesce into one ordinary refresh")
            t.equal(preparation.calls.count, 2)
            host.close(); host.notifyBatteryDetailsReady(); time.runUntilIdle()
            t.equal(effects.count, 1)
        }
    }

    private static func preview(_ t: AppTestRunner) {
        t.suite("Desk: battery details: preview readiness preserves a pending action and closes without late effects") {
            let file = DeskFileID(path: "BatteryDetails.desk")
            let service = DeskLanguageService(openFile: file, files: [file: actionSource])
            let time = try S.clock(), system = System(), preparation = S.Preparation()
            system.set(90, 200)
            let preview = DeskProgramPreviewController(clock: time.clock, executor: time,
                dateLocale: { Locale(identifier: "en_US_POSIX") }, system: system,
                prepareIcons: preparation.submit, presentsTooltips: false, presentsMenus: false) {
                    $0.file == file && $0.generation == service.snapshot.generation && service.snapshot.isChecked
                }
            let window = NSWindow(contentViewController: preview)
            window.appearance = NSAppearance(named: .aqua); window.contentView?.layoutSubtreeIfNeeded()
            t.atSuiteEnd { preview.close(); window.close(); time.runUntilIdle() }
            preview.show(service.snapshot, readError: nil)
            try preparation.succeed(0); time.runUntilIdle(); preview.setVisible(true)
            t.equal(preview.state, .ready); t.equal(preview.updateMilliseconds, 3_600_000)
            let pixels = try S.bytes(S.paint(preview.canvas))
            var textAtCompletion: [String] = []
            preview.onRecordedEffects = { _ in textAtCompletion = S.texts(preview.scene) }
            let frame = try S.element(preview.scene, "signal").frame
            let point = NSPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: preview.canvas.convert(point, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1) else { throw S.Failure.fixture }
                if type == .leftMouseDown { preview.canvas.mouseDown(with: event) }
                else { preview.canvas.mouseUp(with: event) }
            }
            let reads = system.reads
            system.set(98, 201); preview.notifyBatteryDetailsReady(); preview.notifyBatteryDetailsReady()
            t.equal(system.reads, reads); t.equal(preview.recordedEffects, [])
            t.equal(try S.bytes(S.paint(preview.canvas)), pixels)
            try preparation.succeed(1); time.runUntilIdle()
            t.equal(preview.recordedEffects, [.copy("90")]); t.equal(textAtCompletion, ["90% / 200"])
            t.equal(S.texts(preview.scene), ["98% / 201"]); t.equal(system.reads, reads + 1)
            t.equal(try S.element(preview.scene, "signal").visibility, .hiddenKeepsSpace)
            preview.setVisible(false); let hiddenReads = system.reads
            preview.notifyBatteryDetailsReady(); time.advance(by: 3600)
            t.equal(system.reads, hiddenReads)
            preview.close(); preview.notifyBatteryDetailsReady(); time.advance(by: 3600)
            t.equal(system.reads, hiddenReads); t.equal(preview.recordedEffects, [], "closed previews clear their action records")
        }
    }

    private static func window(_ t: AppTestRunner) {
        t.suite("Desk: battery details: window notification reaches its owner before coherent desktop publication") {
            let root = t.temporaryDirectory("battery-details-window"), system = System(), time = try S.clock()
            let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                skinsDirectory: root.appendingPathComponent("Skins"), layoutsDirectory: root.appendingPathComponent("Layouts"),
                backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
                settingsDirectory: root.appendingPathComponent("Settings"), widgetsDirectory: root.appendingPathComponent("Widgets"),
                presentsWindows: false)
            let sourceID = UUID(), instanceID = UUID(), name = sourceID.uuidString.lowercased()
            let source = DeskWidgetSourceState(id: sourceID, entry: name + "/Main.desk")
            let instance = DeskWidgetInstanceState(id: instanceID, sourceID: sourceID)
            let directory = root.appendingPathComponent("Widgets").appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(textSource.utf8).write(to: directory.appendingPathComponent("Main.desk"))
            try app.state.registerDeskInstallation(source: source, instance: instance)
            let widget = try DeskWidgetWindowController(source: source, instance: instance, directory: directory,
                program: S.program(textSource), prepared: nil, app: app, executor: time, clock: time.clock,
                preferredLanguages: { ["en"] }, dateLocale: { Locale(identifier: "en_US_POSIX") }, system: system)
            t.atSuiteEnd {
                widget.close(deactivate: false)
                _ = AppSelfTest.spin(timeout: 5) { time.runUntilIdle(); return widget.isClosed }
                _ = app.stopAllForTermination(); app.endEngineThread()
            }
            func delivered(_ text: String) -> Bool {
                time.runUntilIdle()
                widget.owner.host?.frames.runLoopTurn(.beforeWaiting)
                return S.texts(widget.latestPresented?.scene) == [text]
            }
            t.check(AppSelfTest.spin(timeout: 10) { delivered("–% / –") })
            let input = try DeskWidgetWindowController.makeInput(for: widget.window.effectiveAppearance,
                scale: widget.window.backingScaleFactor, program: widget.program,
                preferredLanguages: ["en"], locale: Locale(identifier: "en_US_POSIX"))
            guard let space = widget.window.colorSpace?.cgColorSpace else { throw S.Failure.fixture }
            let facts = SkinWindowFacts(frame: widget.window.frame, isVisible: true, isOrderedIn: true,
                scale: widget.window.backingScaleFactor, colorSpace: space, appearance: input.environment.appearance.name,
                takesPointer: true, sequence: 100, panelGeneration: widget.destinationEpoch)
            time.async { widget.owner.take(facts, input: input) }
            t.check(AppSelfTest.spin(timeout: 10) { delivered("–% / –") })
            time.runUntilIdle()
            let reads = system.reads, generation = widget.latestPresented?.scene.generation
            system.set(94, 231)
            NotificationCenter.default.post(name: .desksetBatteryDetailsDidChange, object: nil)
            t.equal(system.reads, reads, "Main posts an owner request instead of sampling on Main")
            t.check(AppSelfTest.spin(timeout: 10) { delivered("94% / 231") })
            time.runUntilIdle()
            t.equal(system.reads, reads + 1)
            t.check(widget.latestPresented?.scene.generation != generation)
            t.equal(widget.owner.host?.presented?.scene.generation, widget.latestPresented?.scene.generation)
            t.equal(widget.lastUnavailableMessage, nil)
            widget.close(deactivate: false)
            t.check(AppSelfTest.spin(timeout: 5) { time.runUntilIdle(); return widget.isClosed })
            let closedReads = system.reads
            NotificationCenter.default.post(name: .desksetBatteryDetailsDidChange, object: nil); time.runUntilIdle()
            t.equal(system.reads, closedReads)
        }
    }
}
