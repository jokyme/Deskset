import AppKit
import DeskLanguage
import DesksetCore

enum DeskMenuIntegrationSelfTests {
    private typealias S = DeskConditionalTestSupport

    private static func item(_ menu: DeskProgramMenuSession, title: String) throws -> ProgramMenuItemID {
        var pending = menu.items
        while let node = pending.popLast() {
            switch node {
            case .item(let id, let value, _, _): if value == title { return id }
            case .submenu(_, let items): pending += items
            case .divider: break
            }
        }
        throw S.Failure.fixture
    }

    private static func open(_ host: DeskProgramHost, name: String) throws -> DeskProgramMenuSession {
        guard let generation = host.presented?.scene.generation,
              let menu = try host.openMenu(at: S.point(host, name), expectedGeneration: generation, id: UUID()) else {
            throw S.Failure.fixture
        }
        return menu
    }

    static func run(_ t: AppTestRunner) {
        t.suite("App: Desk menu integration: opening is read only and selection uses current state exactly once") {
            let source = """
            widget { variable count = 0
                Column(spacing: 0, align: .left) {
                    Text("{count}").size(80, 20).name(label).menu {
                        Item("Child {count}").onClick { count = count + 1; copy("{count}") }
                    }
                    Rectangle().size(80, 20).fill(.red).name(change).onClick { count = count + 1 }
                }.name(root).menu { Item("Root").onClick { copy("root") } }
            }
            """
            let time = try S.clock(), input = S.input(), provider = S.Provider(), system = S.System()
            let host = try DeskProgramHost(program: S.program(source), executor: time, provider: provider,
                input: input, clock: time.clock, system: system)
            defer { host.close() }
            host.take(S.facts(input), input: input); host.start(); host.drawFirstFrame()
            let before = host.scene, pixels = try S.bytes(provider.image()), timers = time.pendingCount
            let menu = try open(host, name: "label"), child = try item(menu, title: "Child 0")
            t.equal(menu.owners.map(\.name), ["label", "root"])
            t.equal(host.scene?.generation, before?.generation); t.equal(time.pendingCount, timers)
            t.equal(system.cpuCalls, 0); t.equal(system.batteryCalls, 0)
            t.equal(try S.bytes(provider.image()), pixels)
            t.equal(try S.click(host, "change"), []); S.flush(host, time)
            t.equal(S.texts(host.scene), ["1"])
            t.equal(host.activateMenuItem(child, menuID: menu.id, expectedGeneration: host.scene!.generation), [.copy("2")])
            S.flush(host, time)
            t.equal(S.texts(host.scene), ["2"], "opening runtime cannot overwrite later assignments")
            t.check(host.activateMenuItem(child, menuID: menu.id, expectedGeneration: host.scene!.generation) == nil)
            let next = try open(host, name: "label")
            t.check(host.activateMenuItem(child, menuID: UUID(), expectedGeneration: host.scene!.generation) == nil)
            host.cancelMenu(menu.id)
            t.equal(host.activateMenuItem(try item(next, title: "Root"), menuID: next.id,
                expectedGeneration: host.scene!.generation), [.copy("root")], "old cancellation cannot revoke a replacement menu")
            t.equal(time.background.reports, [])
        }

        t.suite("App: Desk menu integration: branch enabled visibility and occlusion qualify live selection") {
            let source = """
            widget { Rectangle().size(80, 40).fill(.red).name(root).menu {
                Item("Enabled", enabled: cpu.usage < 50%).onClick { copy("enabled") }
                if cpu.usage < 50% { Item("Cool").onClick { copy("cool") } }
                else { Item("Hot").onClick { copy("hot") } }
            } }
            """
            let time = try S.clock(), input = S.input(), provider = S.Provider(), system = S.System()
            let host = try DeskProgramHost(program: S.program(source), executor: time, provider: provider,
                input: input, clock: time.clock, system: system)
            defer { host.close() }
            host.take(S.facts(input), input: input); host.start(); host.drawFirstFrame()
            t.equal(system.cpuCalls, 0); t.equal(host.clockPrecision, nil)
            for title in ["Enabled", "Cool"] {
                system.cpu = 25; time.advance(by: 2)
                let menu = try open(host, name: "root"), selected = try item(menu, title: title)
                let generation = host.scene!.generation, calls = system.cpuCalls
                system.cpu = 75; time.advance(by: 2)
                t.check(host.activateMenuItem(selected, menuID: menu.id, expectedGeneration: generation) == nil)
                t.equal(system.cpuCalls, calls + 1)
                t.equal(host.scene?.generation, generation, "changed guard rejects without projecting or effects")
                t.equal(host.state, .ready)
            }
            let menu = try open(host, name: "root"), hot = try item(menu, title: "Hot")
            var covered = S.facts(input); covered.isVisible = false; covered.takesPointer = false
            host.take(covered, input: input, menuAllowed: true)
            t.equal(host.activateMenuItem(hot, menuID: menu.id, expectedGeneration: host.scene!.generation), [.copy("hot")],
                    "native menu occlusion does not revoke its own selection")
            host.take(S.facts(input), input: input); S.flush(host, time)
            for ending in ["cancel", "pointer", "epoch"] {
                let next = try open(host, name: "root"), selected = try item(next, title: "Hot")
                var facts = S.facts(input)
                if ending == "cancel" { host.cancelMenu(next.id) }
                else if ending == "pointer" { facts.takesPointer = false; host.take(facts, input: input) }
                else { facts.panelGeneration += 1; host.take(facts, input: input) }
                t.check(host.activateMenuItem(selected, menuID: next.id, expectedGeneration: host.scene!.generation) == nil)
                host.take(S.facts(input), input: input); S.flush(host, time)
            }

            let conditional = """
            widget { Freeform {
                if battery.charging { Rectangle().size(40).fill(.red).name(child).menu { Item("Child") } }
            }.size(80).name(root).menu { Item("Root").onClick { copy("root") } } }
            """
            system.charging = true
            let other = try DeskProgramHost(program: S.program(conditional), executor: time, provider: S.Provider(),
                input: input, clock: time.clock, system: system)
            defer { other.close() }
            other.take(S.facts(input), input: input); other.start(); other.drawFirstFrame()
            let opened = try open(other, name: "child"), held = try item(opened, title: "Root")
            system.charging = false; other.notifyPowerChange(); S.flush(other, time)
            system.charging = true; other.notifyPowerChange(); S.flush(other, time)
            t.check(other.activateMenuItem(held, menuID: opened.id, expectedGeneration: other.scene!.generation) == nil,
                    "disappearing then restoring an owner cannot revive its old menu")

            let ticking = try DeskProgramHost(program: S.program(#"widget { Text(cpu.usage).size(80, 40).name(root).menu { Item("Current").onClick { copy("current") } } }"#),
                executor: time, provider: S.Provider(), input: input, clock: time.clock, system: system)
            defer { ticking.close() }
            ticking.take(S.facts(input), input: input); ticking.start(); ticking.drawFirstFrame()
            let tickingMenu = try open(ticking, name: "root"), accepted = ticking.presented!.scene.generation
            var heldFrame: SkinBitmapRequest?
            ticking.frames.requestBitmapDelivery = { heldFrame = $0 }
            ticking.take(covered, input: input, menuAllowed: true)
            system.cpu = 25; time.advance(by: 2); S.flush(ticking, time)
            t.equal(ticking.presented?.scene.generation, accepted)
            t.check(heldFrame != nil, "Main has not acknowledged the next picture")
            t.check(ticking.scene!.generation > accepted, "the display clock advances while presentation is held")
            let current = ticking.scene!.generation
            t.equal(ticking.activateMenuItem(try item(tickingMenu, title: "Current"), menuID: tickingMenu.id,
                expectedGeneration: accepted), [.copy("current")])
            t.equal(ticking.scene?.generation, current + 1, "selection commits from the current runtime, never the held bitmap")
        }

        t.suite("App: Desk menu integration: selected pending icon transaction survives menu close with frozen input") {
            let time = try S.clock(), input = S.input(), provider = S.Provider(), system = S.System(), preparation = S.Preparation()
            let host = try pendingHost(time, input, provider, system, preparation)
            defer { host.close() }
            try preparation.succeed(0); time.runUntilIdle()
            let menu = try open(host, name: "root"), selected = try item(menu, title: "Change")
            let pixels = try S.bytes(provider.image()), generation = host.scene?.generation
            var effects: [[ProgramEffect]] = [], committed: String?
            t.check(host.activateMenuItem(selected, menuID: menu.id, expectedGeneration: generation!, completion: {
                effects.append($0); committed = S.icons(host.scene).first?.request.name
            }) == nil)
            t.check(host.isPreparingIcons); t.equal(preparation.calls.count, 2)
            host.cancelMenu(menu.id)
            var covered = S.facts(input); covered.isVisible = false; covered.takesPointer = false
            host.take(covered, input: input, menuAllowed: true)
            t.check(!((try preparation.call(1)).ticket.isCancelled))
            let reads = system.cpuCalls
            system.cpu = 75; time.advance(by: 2); S.flush(host, time)
            t.equal(system.cpuCalls, reads); t.equal(effects, [])
            t.equal(host.scene?.generation, generation); t.equal(try S.bytes(provider.image()), pixels)
            try preparation.succeed(1); time.runUntilIdle()
            t.equal(effects, [[.copy("cool")]]); t.equal(committed, "sun.max.fill")
            host.take(S.facts(input), input: input); S.flush(host, time)
            t.equal(S.icons(host.scene).first?.request.name, "wifi")
            try preparation.succeed(1); time.runUntilIdle()
            t.equal(effects.count, 1); t.equal(time.background.reports, [])
        }

        t.suite("App: Desk menu integration: failed revoked or replaced pending actions cannot publish effects") {
            for ending in ["failure", "epoch", "pointer", "close"] {
                let time = try S.clock(), input = S.input(), provider = S.Provider(), system = S.System(), preparation = S.Preparation()
                let host = try pendingHost(time, input, provider, system, preparation)
                defer { host.close() }
                try preparation.succeed(0); time.runUntilIdle()
                let menu = try open(host, name: "root"), selected = try item(menu, title: "Change")
                var effects: [[ProgramEffect]] = []
                t.check(host.activateMenuItem(selected, menuID: menu.id, expectedGeneration: host.scene!.generation,
                    completion: { effects.append($0) }) == nil)
                let pending = try preparation.call(1)
                if ending == "failure" { try preparation.fail(1); time.runUntilIdle() }
                else if ending == "close" { host.close() }
                else {
                    var facts = S.facts(input)
                    if ending == "epoch" { facts.panelGeneration += 1 } else { facts.takesPointer = false }
                    host.take(facts, input: input)
                }
                if ending != "failure" { t.check(pending.ticket.isCancelled) }
                let generation = host.scene?.generation, state = host.state
                try preparation.succeed(1); time.runUntilIdle(); S.flush(host, time)
                t.equal(effects, []); t.equal(host.scene?.generation, generation); t.equal(host.state, state)
            }
        }

        t.suite("App: Desk menu integration: preview selects current variables and never performs external effects") {
            let source = """
            widget { variable count = 0
                Rectangle().size(80, 40).fill(.red).name(root).onClick { count = count + 1 }.menu {
                    Item("Copy {count}").onClick { count = count + 1; copy("{count}"); open("Calendar") }
                }
            }
            """
            let f = try preview(t, source), p = f.preview, point = NSPoint(x: 40, y: 20)
            try mouse(.rightMouseDown, at: point, in: f)
            let held = try nativeItem(p, title: "Copy 0")
            let generation = p.scene?.generation
            t.equal(p.recordedEffects, []); t.check(!f.window.isVisible)
            p.updateForTick()
            t.check(p.scene?.generation != generation)
            choose(held)
            t.equal(p.recordedEffects, [.copy("1"), .open("Calendar")]); choose(held)
            t.equal(p.recordedEffects.count, 2)
            try mouse(.rightMouseDown, at: point, in: f)
            let beforeHide = try nativeItem(p, title: "Copy 1")
            p.setVisible(false); p.setVisible(true); choose(beforeHide)
            t.equal(p.recordedEffects.count, 2)
            try mouse(.leftMouseDown, at: point, in: f); try mouse(.leftMouseUp, at: point, in: f)
            try mouse(.rightMouseDown, at: point, in: f)
            let beforeSource = try nativeItem(p, title: "Copy 2")
            p.show(f.service.snapshot, readError: nil); choose(beforeSource)
            t.equal(p.recordedEffects, [], "new checked source session has no inherited menu or effect history")
            try mouse(.rightMouseDown, at: point, in: f, flags: [.option])
            t.check(p.canvas.programMenus?.menu == nil); t.equal(p.recordedEffects, [])
        }

        t.suite("App: Desk menu integration: preview maps scrolled zoomed overflow and defers selected icon actions") {
            let geometry = """
            widget { Freeform {
                Rectangle().size(80, 40).position(x: -40, y: -20).fill(.red).rounded(8).name(child)
                    .menu { Item("Child").onClick { copy("child") } }
            }.name(root).menu { Item("Root").onClick { copy("root") } }
            }
            """
            let f = try preview(t, geometry), p = f.preview
            p.setZoom(2)
            t.equal(try S.element(p.scene, "child").frame, SkinRect(x: -40, y: -20, width: 80, height: 40))
            try mouse(.rightMouseDown, at: .zero, in: f)
            choose(try nativeItem(p, title: "Child")); t.equal(p.recordedEffects, [.copy("child")])
            let preparation = S.Preparation(), pending = try preview(t, pendingSource, preparation: preparation)
            try preparation.succeed(0); pending.time.runUntilIdle()
            try mouse(.rightMouseDown, at: NSPoint(x: 30, y: 30), in: pending)
            choose(try nativeItem(pending.preview, title: "Change"))
            t.check(pending.preview.isPreparingIcons); t.equal(pending.preview.recordedEffects, [])
            pending.preview.canvas.programMenus?.cancel()
            pending.system.cpu = 75; pending.time.advance(by: 2)
            try preparation.succeed(1); pending.time.runUntilIdle()
            t.equal(pending.preview.recordedEffects, [.copy("cool")])
            t.equal(S.icons(pending.preview.scene).first?.request.name, "wifi")
            try preparation.succeed(1); pending.time.runUntilIdle()
            t.equal(pending.preview.recordedEffects.count, 1)
        }
    }

    private static let pendingSource = """
    widget { variable alternate = false
        Icon(cpu.usage < 50% and alternate ? "sun.max.fill" : "wifi").size(60).color("#FF0000").name(root)
            .menu { Item("Change").onClick { alternate = true; copy(cpu.usage < 50% ? "cool" : "hot") } }
    }
    """

    private static func pendingHost(_ time: VirtualTimeExecutor, _ input: DeskProgramHost.Input,
                                    _ provider: S.Provider, _ system: S.System, _ preparation: S.Preparation) throws -> DeskProgramHost {
        let host = try DeskProgramHost(program: S.program(pendingSource), executor: time, provider: provider,
            input: input, clock: time.clock, system: system, prepareIcons: preparation.submit)
        host.take(S.facts(input), input: input); host.start()
        return host
    }

    private struct PreviewFixture {
        let service: DeskLanguageService
        let preview: DeskProgramPreviewController
        let window: NSWindow
        let time: VirtualTimeExecutor
        let system: S.System
    }

    private static func preview(_ t: AppTestRunner, _ source: String,
                                preparation: S.Preparation? = nil) throws -> PreviewFixture {
        let file = DeskFileID(path: "Menus.desk"), service = DeskLanguageService(openFile: DeskFileID(path: "Menus.desk"),
            files: [file: source])
        _ = try S.program(source)
        let time = try S.clock(), system = S.System()
        let prepare: DeskProgramPreviewController.IconPreparation = preparation.map { value in value.submit } ?? DeskIconResources.prepare
        let preview = DeskProgramPreviewController(clock: time.clock, executor: time,
            dateLocale: { Locale(identifier: "en_US_POSIX") }, system: system, prepareIcons: prepare,
            presentsTooltips: false, presentsMenus: false) {
                $0.file == file && $0.generation == service.snapshot.generation &&
                    $0.tree.version == service.snapshot.tree.version && service.snapshot.isChecked
            }
        let window = NSWindow(contentViewController: preview)
        window.contentView?.layoutSubtreeIfNeeded()
        t.atSuiteEnd { preview.close(); window.close(); time.runUntilIdle() }
        preview.show(service.snapshot, readError: nil); preview.setVisible(true)
        return PreviewFixture(service: service, preview: preview, window: window, time: time, system: system)
    }

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in fixture: PreviewFixture,
                              flags: NSEvent.ModifierFlags = []) throws {
        guard let event = NSEvent.mouseEvent(with: type, location: fixture.preview.canvas.convert(point, to: nil),
            modifierFlags: flags, timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1) else { throw S.Failure.fixture }
        switch type {
        case .leftMouseDown: fixture.preview.canvas.mouseDown(with: event)
        case .leftMouseUp: fixture.preview.canvas.mouseUp(with: event)
        case .rightMouseDown: fixture.preview.canvas.rightMouseDown(with: event)
        default: throw S.Failure.fixture
        }
    }

    private static func nativeItem(_ preview: DeskProgramPreviewController, title: String) throws -> NSMenuItem {
        guard let item = preview.canvas.programMenus?.menu?.items.first(where: { $0.title == title }) else {
            throw S.Failure.fixture
        }
        return item
    }

    private static func choose(_ item: NSMenuItem) {
        if let action = item.action { NSApplication.shared.sendAction(action, to: item.target, from: item) }
    }
}
