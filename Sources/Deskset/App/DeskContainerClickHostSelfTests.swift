import AppKit
import DesksetCore

enum DeskContainerClickHostSelfTests {
    private typealias S = DeskConditionalTestSupport
    private static let settings = "x-apple.systempreferences:com.apple.Battery-Settings.extension"

    static func run(_ t: AppTestRunner) {
        t.suite("App: Desk container clicks: parent identity and per-event pointer routes preserve pixels and empty handlers") {
            for constructor in ["Row(spacing: 0, align: .top)", "Column(spacing: 0, align: .left)", "Freeform(align: .topLeft)"] {
                let source = """
                widget { \(constructor) {
                    Rectangle().size(20, 20).fill("#FF0000").name(child)
                        .onClick {}.onRightClick { copy("child-right") }
                }.size(60, 40).padding(10).background("#0000FF").name(card)
                    .onClick { open("\(settings)") }.onRightClick { copy("parent-right") } }
                """
                for scale in [1, 2] {
                    let time = try S.clock(), input = S.input(scale: Double(scale)), provider = S.Provider()
                    let host = try DeskProgramHost(program: S.program(source), executor: time, provider: provider,
                        input: input, clock: time.clock)
                    defer { host.close() }
                    host.take(S.facts(input), input: input); host.start(); host.drawFirstFrame()
                    t.equal(host.state, .ready)
                    t.equal(try S.element(host.scene, "child").frame, SkinRect(x: 10, y: 10, width: 20, height: 20))
                    let pixels = try S.bytes(provider.image())
                    t.equal(pixels, try S.bytes(S.literal(size: NSSize(width: 60, height: 40), scale: scale,
                        rectangles: [(CGRect(x: 0, y: 0, width: 60, height: 40), S.blue),
                                     (CGRect(x: 10, y: 10, width: 20, height: 20), S.red)])))
                    t.equal(try S.click(host, "child"), []); S.flush(host, time)
                    let childPoint = try S.point(host, "child")
                    host.secondaryPress(at: childPoint)
                    t.equal(host.secondaryRelease(at: childPoint), [.copy("child-right")]); S.flush(host, time)
                    let padding = SkinPoint(x: 5, y: 20)
                    host.primaryPress(at: padding)
                    t.equal(host.primaryRelease(at: padding), [.open(settings)]); S.flush(host, time)
                    host.secondaryPress(at: padding)
                    t.equal(host.secondaryRelease(at: padding), [.copy("parent-right")]); S.flush(host, time)
                    let card = try S.element(host.scene, "card").id
                    t.equal(host.activateContainer(card, expectedGeneration: host.scene!.generation), [.open(settings)])
                    S.flush(host, time)
                    t.equal(try S.bytes(provider.image()), pixels, "event dispatch cannot repaint different geometry")
                    t.equal(time.background.reports, [])
                }
                let time = try S.clock(), input = S.input(), provider = S.Provider()
                let empty = try DeskProgramHost(program: S.program("widget { \(constructor) {}.size(40, 20).name(card).onClick {} }"),
                    executor: time, provider: provider, input: input, clock: time.clock)
                defer { empty.close() }
                empty.take(S.facts(input), input: input); empty.start(); empty.drawFirstFrame()
                t.equal(empty.state, .ready)
                t.equal(try S.bytes(provider.image()), Data(repeating: 0, count: 40 * 20 * 4))
                let card = try S.element(empty.scene, "card").id
                t.equal(empty.activateContainer(card, expectedGeneration: empty.scene!.generation), [])
            }
        }

        t.suite("App: Desk container clicks: identity activation samples only its handler and rejects leaf and stale targets") {
            let source = """
            widget { Freeform {
                Rectangle().size(40).fill(.red).name(child)
                    .onClick { copy(battery.charging ? "charging" : "draining") }
            }.size(40).name(card).onClick { copy(cpu.usage < 50% ? "cool" : "hot") } }
            """
            let time = try S.clock(), input = S.input(), provider = S.Provider(), system = S.System()
            let host = try DeskProgramHost(program: S.program(source), executor: time, provider: provider,
                input: input, clock: time.clock, system: system)
            defer { host.close() }
            host.take(S.facts(input), input: input); host.start(); host.drawFirstFrame()
            let card = try S.element(host.scene, "card").id, child = try S.element(host.scene, "child").id
            let generation = host.scene!.generation
            t.equal(system.cpuCalls, 0); t.equal(system.batteryCalls, 0)
            t.check(host.activateContainer(child, expectedGeneration: generation) == nil)
            t.equal(system.cpuCalls, 0); t.equal(system.batteryCalls, 0)
            t.equal(host.activateContainer(card, expectedGeneration: generation), [.copy("cool")])
            t.equal(system.cpuCalls, 1); t.equal(system.batteryCalls, 0)
            t.check(host.activateContainer(card, expectedGeneration: generation) == nil)
            S.flush(host, time)
            t.check(host.activateContainer(card, expectedGeneration: generation) == nil)
            t.equal(try S.click(host, "child"), [.copy("draining")])
            t.equal(system.cpuCalls, 1); t.equal(system.batteryCalls, 1)
            t.equal(host.clockPrecision, nil, "action-only data does not keep a periodic clock")
        }

        t.suite("App: Desk container clicks: pending identity action preserves old frame and frozen effects through one deferred refresh") {
            let time = try S.clock(), input = S.input(), provider = S.Provider(), system = S.System(), preparation = S.Preparation()
            let host = try makePendingHost(time, input, provider, system, preparation)
            defer { host.close() }
            try preparation.succeed(0); time.runUntilIdle()
            let original = try S.bytes(provider.image()), generation = host.presented?.scene.generation
            let card = try S.element(host.scene, "card").id
            var effects: [[ProgramEffect]] = [], committedName: String?
            t.check(host.activateContainer(card, expectedGeneration: host.scene!.generation, completion: {
                effects.append($0); committedName = S.icons(host.scene).first?.request.name
            }) == nil)
            t.check(host.isPreparingIcons); t.equal(preparation.calls.count, 2)
            t.equal(try preparation.call(1).demands.map { $0.request.name }, ["sun.max.fill"])
            let reads = system.cpuCalls
            system.cpu = 75; time.advance(by: 2); host.frames.setNeedsFrame(); S.flush(host, time)
            t.equal(system.cpuCalls, reads); t.equal(host.presented?.scene.generation, generation)
            t.equal(try S.bytes(provider.image()), original); t.equal(effects, [])
            t.check(host.activateContainer(card, expectedGeneration: generation!) == nil)
            try preparation.succeed(1); time.runUntilIdle(); S.flush(host, time)
            t.equal(effects, [[.copy("frozen-cool")]])
            t.equal(committedName, "sun.max.fill", "completion observes the frozen successful candidate before deferred data")
            t.equal(S.icons(host.scene).first?.request.name, "wifi")
            t.equal(system.cpuCalls, reads + 1); t.equal(preparation.calls.count, 2)
            t.equal(try S.bytes(provider.image()), original)
            try preparation.succeed(1); time.runUntilIdle()
            t.equal(effects, [[.copy("frozen-cool")]], "a duplicate resource result cannot replay the parent action")
            t.equal(time.background.reports, [])
        }

        t.suite("App: Desk container clicks: failure destination pointer loss and close discard pending identity effects") {
            for ending in ["failure", "epoch", "pointer", "close"] {
                let time = try S.clock(), input = S.input(), provider = S.Provider(), system = S.System(), preparation = S.Preparation()
                let host = try makePendingHost(time, input, provider, system, preparation)
                defer { host.close() }
                try preparation.succeed(0); time.runUntilIdle()
                let card = try S.element(host.scene, "card").id
                var effects: [[ProgramEffect]] = []
                t.check(host.activateContainer(card, expectedGeneration: host.scene!.generation,
                    completion: { effects.append($0) }) == nil)
                let pending = try preparation.call(1)
                switch ending {
                case "failure": try preparation.fail(1); time.runUntilIdle()
                case "epoch":
                    var facts = S.facts(input); facts.panelGeneration += 1
                    host.take(facts, input: input)
                case "pointer":
                    var facts = S.facts(input); facts.takesPointer = false
                    host.take(facts, input: input)
                default: host.close()
                }
                if ending != "failure" { t.check(pending.ticket.isCancelled) }
                let state = host.state, generation = host.scene?.generation
                try preparation.succeed(1); time.runUntilIdle(); S.flush(host, time)
                t.equal(effects, []); t.equal(host.state, state); t.equal(host.scene?.generation, generation)
                if ending == "failure" {
                    if case .unavailable = host.state {} else { t.check(false, "preparation failure clears the host") }
                    t.check(host.presented == nil); t.check(provider.releases > 0)
                } else if ending == "close" { t.equal(host.state, .closed) }
                else { t.equal(S.icons(host.scene).first?.request.name, "wifi", "cancellation cannot commit the pending variable") }
            }
        }

        t.suite("App: Desk container clicks: branch replacement keeps parent gestures and retires removed child gestures per event") {
            let source = """
            widget { Freeform {
                if battery.charging {
                    Rectangle().size(40, 20).fill(.red).name(child)
                        .onClick { copy("child-left") }.onRightClick { copy("child-right") }
                }
            }.size(80, 40).name(card).onClick { copy("parent-left") }.onRightClick { copy("parent-right") } }
            """
            for event in [MouseEventKind.leftUp, .rightUp] {
                let time = try S.clock(), input = S.input(), provider = S.Provider(), system = S.System()
                let host = try DeskProgramHost(program: S.program(source), executor: time, provider: provider,
                    input: input, clock: time.clock, system: system)
                defer { host.close() }
                host.take(S.facts(input), input: input); host.start(); host.drawFirstFrame()
                let card = try S.element(host.scene, "card").id, padding = SkinPoint(x: 2, y: 20)
                func press(_ point: SkinPoint) { if event == .leftUp { host.primaryPress(at: point) } else { host.secondaryPress(at: point) } }
                func release(_ point: SkinPoint) -> [ProgramEffect]? {
                    event == .leftUp ? host.primaryRelease(at: point) : host.secondaryRelease(at: point)
                }
                press(padding); system.charging = true; host.notifyPowerChange(); S.flush(host, time)
                t.equal(try S.element(host.scene, "card").id, card)
                t.equal(release(padding), [.copy(event == .leftUp ? "parent-left" : "parent-right")]); S.flush(host, time)
                let child = try S.element(host.scene, "child").id, center = try S.point(host, "child")
                press(center); system.charging = false; host.notifyPowerChange(); S.flush(host, time)
                t.check(host.scene?.elements.contains(where: { $0.id == child }) == false)
                system.charging = true; host.notifyPowerChange(); S.flush(host, time)
                t.equal(try S.element(host.scene, "child").id, child); t.check(release(center) == nil)
                press(center); t.equal(release(center), [.copy(event == .leftUp ? "child-left" : "child-right")])
            }
        }
    }

    private static func makePendingHost(_ time: VirtualTimeExecutor, _ input: DeskProgramHost.Input,
                                        _ provider: S.Provider, _ system: S.System, _ preparation: S.Preparation) throws -> DeskProgramHost {
        let source = """
        widget { variable alternate = false
            Freeform {
                Icon(cpu.usage < 50% and alternate ? "sun.max.fill" : "wifi").size(40).color("#FF0000").name(icon)
                    .onClick { copy("child") }
            }.size(60).name(card).onClick { alternate = true; copy(cpu.usage < 50% ? "frozen-cool" : "hot") }
        }
        """
        let host = try DeskProgramHost(program: S.program(source), executor: time, provider: provider,
            input: input, clock: time.clock, system: system, prepareIcons: preparation.submit)
        host.take(S.facts(input), input: input); host.start()
        return host
    }
}
