import AppKit
import DeskLanguage
import DesksetCore
import DesksetDraw

/// Shared source and independent geometry for branch tests. The condition itself contributes no box.
enum DeskViewIfTestSupport {
    private typealias S = DeskConditionalTestSupport

    static let rowSource = """
    widget { variable stage = 0
        Row(spacing: 2, align: .top) {
            Rectangle().size(10, 20).fill("#00FF00").name(switcher)
                .onClick { stage = stage == 2 ? 0 : stage + 1 }
            if stage == 0 {
                Rectangle().size(20, 20).fill("#FF0000").name(first).onClick { copy("first") }
                Rectangle().size(10, 20).fill("#0000FF").name(second).onClick { copy("second") }
            } else if stage == 1 {
                Rectangle().size(40, 20).fill("#0000FF").name(alternate).onClick { copy("alternate") }
            }
            Rectangle().size(10, 20).fill("#FFFF00").name(tail).onClick { copy("tail") }
        }
    }
    """

    static func row(_ stage: Int) -> (size: NSSize, rectangles: [(CGRect, RGBA)], names: [String]) {
        let first = (CGRect(x: 0, y: 0, width: 10, height: 20), S.green)
        switch stage {
        case 0:
            return (NSSize(width: 56, height: 20), [first,
                (CGRect(x: 12, y: 0, width: 20, height: 20), S.red),
                (CGRect(x: 34, y: 0, width: 10, height: 20), S.blue),
                (CGRect(x: 46, y: 0, width: 10, height: 20), S.yellow)], ["first", "second"])
        case 1:
            return (NSSize(width: 64, height: 20), [first,
                (CGRect(x: 12, y: 0, width: 40, height: 20), S.blue),
                (CGRect(x: 54, y: 0, width: 10, height: 20), S.yellow)], ["alternate"])
        default:
            return (NSSize(width: 22, height: 20), [first,
                (CGRect(x: 12, y: 0, width: 10, height: 20), S.yellow)], [])
        }
    }

    static func branchNames(_ scene: WidgetScene?) -> [String] {
        scene?.elements.map(\.id.name).filter { ["first", "second", "alternate"].contains($0) } ?? []
    }

    static let pressSource = """
    widget {
        if battery.charging {
            Rectangle().size(40, 20).fill("#0000FF").name(replacement)
                .onClick { copy("replacement-left") }.onRightClick { copy("replacement-right") }
        } else {
            Text("{time.now, format: "ss"}").size(40, 20).name(clocktarget)
                .onClick { copy("primary-left") }.onRightClick { copy("primary-right") }
        }
    }
    """

    // Evaluate the periodic input before the variable so the old committed arm retains its clock while
    // a click's resource transaction is pending. A later sample may select the old arm again.
    static let iconSource = """
    widget { variable alternate = false
        if cpu.usage < 50% and alternate {
            Icon("sun.max.fill").size(40).color("#0000FF").name(newicon)
                .onClick { alternate = false; copy("back") }
        } else {
            Icon("wifi").size(40).color("#FF0000").name(oldicon)
                .onClick { alternate = true; copy("next") }
        }
    }
    """
}

enum DeskViewIfHostSelfTests {
    private typealias S = DeskConditionalTestSupport
    private typealias V = DeskViewIfTestSupport

    static func run(_ t: AppTestRunner) {
        layoutTests(t)
        resourceTests(t)
        pressTest(t)
        accessibilityTest(t)
        imagePreflightTest(t)
    }

    private static func layoutTests(_ t: AppTestRunner) {
        t.suite("App: Desk view if host: selected row children own spacing pixels hits and stable identities") {
            let program = try S.program(V.rowSource)
            for dark in [false, true] {
                for scale in [1, 2] {
                    let input = S.input(dark: dark, scale: Double(scale)), time = try S.clock(), provider = S.Provider()
                    let host = try DeskProgramHost(program: program, executor: time, provider: provider, input: input, clock: time.clock)
                    defer { host.close() }
                    host.take(S.facts(input), input: input); host.start(); host.drawFirstFrame()
                    let switcher = try S.element(host.scene, "switcher").id
                    let tail = try S.element(host.scene, "tail").id
                    let first = try S.element(host.scene, "first").id
                    let second = try S.element(host.scene, "second").id
                    let initial = try S.bytes(provider.image())
                    for (index, stage) in [0, 1, 2, 0].enumerated() {
                        if index > 0 {
                            let generation = host.presented?.scene.generation, oldPixels = try S.bytes(provider.image())
                            t.equal(try S.click(host, "switcher"), [])
                            t.equal(host.presented?.scene.generation, generation)
                            t.equal(try S.bytes(provider.image()), oldPixels, "unpresented branch geometry cannot replace accepted pixels")
                            S.flush(host, time)
                        }
                        let expected = V.row(stage)
                        t.equal(host.scene?.size, SkinSize(width: expected.size.width, height: expected.size.height))
                        t.equal(host.viewport, CGRect(origin: .zero, size: expected.size))
                        let image = try provider.image()
                        t.equal(image.width, Int(expected.size.width) * scale); t.equal(image.height, 20 * scale)
                        t.equal(try S.bytes(image), try S.bytes(S.literal(size: expected.size, scale: scale,
                            rectangles: expected.rectangles)), "independent branch pixel oracle at \(scale)x")
                        t.equal(V.branchNames(host.scene), expected.names)
                        t.equal(try S.element(host.scene, "switcher").id, switcher)
                        t.equal(try S.element(host.scene, "tail").id, tail)
                        t.equal(host.presented?.scene.generation, host.scene?.generation)
                        t.check(host.scene?.elements.contains(where: { $0.id.name.hasPrefix("if#") }) == false)
                        if stage == 0 {
                            t.equal(try S.element(host.scene, "first").id, first)
                            t.equal(try S.element(host.scene, "second").id, second)
                        } else {
                            t.check(host.scene?.hitMap.entries.contains(where: { $0.elementID == first || $0.elementID == second }) == false)
                            if stage == 1 {
                                let alternate = try S.element(host.scene, "alternate").id
                                t.check(alternate != first && alternate != second)
                            }
                        }
                    }
                    t.equal(try S.bytes(provider.image()), initial)
                    t.equal(try S.click(host, "tail"), [.copy("tail")]); t.equal(time.background.reports, [])
                }
            }
        }

        t.suite("App: Desk view if host: Freeform branch extents change origin without stale cropped pixels or hits") {
            let source = """
            widget { variable alternate = false
                Freeform {
                    Rectangle().size(20, 20).fill("#00FF00").position(x: 0, y: 0).name(switcher)
                        .onClick { alternate = not alternate }
                    if alternate {
                        Rectangle().size(30, 20).fill("#0000FF").position(x: 50, y: 20).name(positive)
                            .onClick { copy("positive") }
                    } else {
                        Rectangle().size(20, 20).fill("#FF0000").position(x: -40, y: -10).name(negative)
                            .onClick { copy("negative") }
                    }
                }.size(100, 60)
            }
            """
            let program = try S.program(source)
            for scale in [1, 2] {
                let input = S.input(scale: Double(scale)), time = try S.clock(), provider = S.Provider()
                let host = try DeskProgramHost(program: program, executor: time, provider: provider, input: input, clock: time.clock)
                defer { host.close() }
                host.take(S.facts(input), input: input); host.start(); host.drawFirstFrame()
                let originalID = try S.element(host.scene, "negative").id
                let first = try S.bytes(provider.image())
                for (index, positive) in [false, true, false].enumerated() {
                    if index > 0 { t.equal(try S.click(host, "switcher"), []); S.flush(host, time) }
                    let size = positive ? NSSize(width: 100, height: 60) : NSSize(width: 140, height: 70)
                    let origin = positive ? SkinPoint() : SkinPoint(x: -40, y: -10)
                    let rectangles: [(CGRect, RGBA)] = positive ? [
                        (CGRect(x: 0, y: 0, width: 20, height: 20), S.green),
                        (CGRect(x: 50, y: 20, width: 30, height: 20), S.blue)] : [
                        (CGRect(x: 40, y: 10, width: 20, height: 20), S.green),
                        (CGRect(x: 0, y: 0, width: 20, height: 20), S.red)]
                    t.equal(host.scene?.size, SkinSize(width: 100, height: 60))
                    t.equal(host.presented?.origin, origin)
                    t.equal(host.viewport, CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height))
                    t.equal(try S.bytes(provider.image()), try S.bytes(S.literal(size: size, scale: scale, rectangles: rectangles)))
                    let name = positive ? "positive" : "negative"
                    if !positive { t.equal(try S.element(host.scene, name).id, originalID) }
                    t.equal(try S.click(host, name), [.copy(name)]); S.flush(host, time)
                }
                t.equal(try S.bytes(provider.image()), first, "returning viewport origin restores the full retained picture")
            }
        }
    }

    private static func resourceTests(_ t: AppTestRunner) {
        t.suite("App: Desk view if host: pending branch icons pin the old frame and commit frozen effects before one refresh") {
            let input = S.input(), time = try S.clock(), preparations = S.Preparation(), provider = S.Provider(), system = S.System()
            let host = try DeskProgramHost(program: S.program(V.iconSource), executor: time, provider: provider,
                input: input, clock: time.clock, system: system, prepareIcons: preparations.submit)
            defer { host.close() }
            host.take(S.facts(input), input: input); host.start()
            t.equal(try preparations.call(0).demands.map { $0.request.name }, ["wifi"], "inactive arms have no Icon demands")
            try preparations.succeed(0); time.runUntilIdle()
            let initial = try S.bytes(provider.image()), oldID = try S.element(host.scene, "oldicon").id
            var effects: [[ProgramEffect]] = [], committedAtEffect = false
            t.equal(try S.click(host, "oldicon", completion: {
                effects.append($0)
                committedAtEffect = S.icons(host.scene).map { $0.request.name } == ["sun.max.fill"]
                    && host.scene?.elements.contains(where: { $0.id == oldID }) == false
            }), nil)
            t.check(host.isPreparingIcons); t.equal(preparations.calls.count, 2); t.equal(effects, [])
            t.equal(try preparations.call(1).demands.map { $0.request.name }, ["sun.max.fill"])
            let samples = system.cpuCalls, generation = host.scene?.generation
            system.cpu = 75; time.advance(by: 2); host.frames.setNeedsFrame(); S.flush(host, time)
            t.equal(system.cpuCalls, samples); t.equal(host.scene?.generation, generation)
            t.equal(try S.bytes(provider.image()), initial, "old committed PDFs remain pinned for independent redraws")
            try preparations.succeed(1); time.runUntilIdle(); S.flush(host, time)
            t.check(committedAtEffect); t.equal(effects, [[.copy("next")]])
            t.equal(try S.element(host.scene, "oldicon").id, oldID)
            t.equal(S.icons(host.scene).map { $0.request.name }, ["wifi"])
            t.equal(try S.bytes(provider.image()), initial)
            t.equal(system.cpuCalls, samples + 1); t.equal(preparations.calls.count, 2)
            system.cpu = 25; time.advance(by: 1); S.flush(host, time)
            t.equal(S.icons(host.scene).map { $0.request.name }, ["sun.max.fill"])
            t.equal(preparations.calls.count, 2); t.check(try S.bytes(provider.image()) != initial)
            try preparations.succeed(1); time.runUntilIdle(); t.equal(effects.count, 1)
            t.equal(try S.click(host, "newicon"), [.copy("back")]); S.flush(host, time)
            t.equal(try S.bytes(provider.image()), initial); t.equal(preparations.calls.count, 2)
            host.close(); let reads = system.cpuCalls
            time.advance(by: 3); t.equal(system.cpuCalls, reads); t.equal(time.background.reports, [])
        }

        t.suite("App: Desk view if host: failed branch requests and replies after close cannot publish action state") {
            let input = S.input(), time = try S.clock(), preparations = S.Preparation(), provider = S.Provider(), system = S.System()
            let host = try DeskProgramHost(program: S.program(V.iconSource), executor: time, provider: provider,
                input: input, clock: time.clock, system: system, prepareIcons: preparations.submit)
            defer { host.close() }
            host.take(S.facts(input), input: input); host.start()
            try preparations.succeed(0); time.runUntilIdle()
            let initial = try S.bytes(provider.image()), oldID = try S.element(host.scene, "oldicon").id
            var effects: [[ProgramEffect]] = []
            _ = try S.click(host, "oldicon", completion: { effects.append($0) })
            try preparations.fail(1); time.runUntilIdle()
            if case .unavailable = host.state {} else { t.check(false, "failed branch preparation reports unavailable") }
            t.check(host.scene == nil && host.presented == nil); t.check(provider.releases > 0); t.equal(effects, [])
            host.refresh(); t.equal(preparations.calls.count, 3)
            t.equal(try preparations.call(2).demands.map { $0.request.name }, ["wifi"], "failure did not commit alternate = true")
            try preparations.succeed(1); time.runUntilIdle()
            t.check(host.isPreparingIcons && host.scene == nil); t.equal(effects, [])
            try preparations.succeed(2); time.runUntilIdle(); S.flush(host, time)
            t.equal(host.state, .ready); t.equal(try S.element(host.scene, "oldicon").id, oldID)
            t.equal(try S.bytes(provider.image()), initial)
            _ = try S.click(host, "oldicon", completion: { effects.append($0) })
            let pending = try preparations.call(3), count = provider.frames.count
            host.close(); t.check(pending.ticket.isCancelled)
            try preparations.succeed(3); time.runUntilIdle()
            t.equal(host.state, .closed); t.check(host.scene == nil && host.presented == nil)
            t.equal(provider.frames.count, count); t.equal(effects, [])
        }
    }

    private static func pressTest(_ t: AppTestRunner) {
        t.suite("App: Desk view if host: removing then restoring an arm retires primary and secondary presses") {
            let input = S.input(), time = try S.clock(), system = S.System(), provider = S.Provider()
            let host = try DeskProgramHost(program: S.program(V.pressSource), executor: time, provider: provider,
                input: input, clock: time.clock, system: system)
            defer { host.close() }
            host.take(S.facts(input), input: input); host.start(); host.drawFirstFrame()
            let original = try S.element(host.scene, "clocktarget").id
            t.equal(host.clockPrecision, .second)
            t.check(host.neededSystemProperties.contains(.batteryCharging), "system dependency collection remains conservative")
            for secondary in [false, true] {
                let point = try S.point(host, "clocktarget")
                if secondary { host.secondaryPress(at: point) } else { host.primaryPress(at: point) }
                system.charging = true; host.notifyPowerChange(); S.flush(host, time)
                t.check(host.scene?.elements.contains(where: { $0.id == original }) == false)
                let replacement = try S.element(host.scene, "replacement")
                t.check(replacement.id != original); t.equal(replacement.frame, SkinRect(width: 40, height: 20))
                t.equal(S.texts(host.scene), []); t.equal(host.clockPrecision, nil)
                t.equal(host.presented?.scene.generation, host.scene?.generation)
                let generation = host.scene?.generation, reads = system.batteryCalls
                time.advance(by: 3)
                t.equal(host.scene?.generation, generation); t.equal(system.batteryCalls, reads)
                system.charging = false; host.notifyPowerChange(); S.flush(host, time)
                t.equal(try S.element(host.scene, "clocktarget").id, original)
                t.equal(host.clockPrecision, .second)
                t.equal(secondary ? host.secondaryRelease(at: point) : host.primaryRelease(at: point), nil,
                        "stable identity does not revive a press after the target's accepted absence")
                if secondary { host.secondaryPress(at: point) } else { host.primaryPress(at: point) }
                time.advance(by: 1); S.flush(host, time)
                t.equal(secondary ? host.secondaryRelease(at: point) : host.primaryRelease(at: point),
                        [.copy(secondary ? "primary-right" : "primary-left")], "an ordinary clock repaint keeps a live gesture")
                S.flush(host, time)
            }
            host.close(); let reads = system.batteryCalls
            host.notifyPowerChange(); time.advance(by: 3); t.equal(system.batteryCalls, reads)
        }
    }

    private static func accessibilityTest(_ t: AppTestRunner) {
        t.suite("App: Desk view if host: Main replaces branch glass geometry pixels and accessibility before owner ACK") {
            let sourceText = """
            widget { variable stage = 0
                Row(spacing: 0, align: .top) {
                    Rectangle().size(20, 20).fill(.white).name(switcher)
                        .onClick { stage = stage == 2 ? 0 : stage + 1 }
                    if stage == 0 {
                        Rectangle().size(30, 20).fill(.clear).background(.glass)
                            .voiceOver("Glass arm").name(glassarm).onClick { copy("glass") }
                    } else if stage == 1 {
                        Rectangle().size(50, 20).fill("#0000FF")
                            .voiceOver("Solid arm").name(solidarm).onClick { copy("solid") }
                    }
                }
            }
            """
            let root = t.temporaryDirectory("desk-view-if-window"), time = try S.clock()
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
            guard let old = widget.view.accessibilityParts.first(where: { $0.id.name == "glassarm" }) else { throw S.Failure.fixture }
            t.equal(old.accessibilityLabel(), "Glass arm"); t.equal(old.accessibilityRole(), .button)
            t.equal(widget.nativeComposition.shownPieces.count, 1)
            var solidID: ElementID?
            for stage in [1, 2, 0] {
                let previousGeneration = widget.latestPresented?.scene.generation
                let previousSize = widget.window.frame.size
                let previousParts = widget.view.accessibilityParts
                let previousGlassCount = widget.nativeComposition.shownPieces.count
                t.equal(try S.click(host, "switcher"), []); host.frames.runLoopTurn(.beforeWaiting)
                let nextGeneration = host.scene?.generation
                t.check(host.frames.hasBitmapDelivery)
                t.equal(widget.latestPresented?.scene.generation, previousGeneration)
                t.equal(widget.window.frame.size, previousSize)
                t.equal(widget.nativeComposition.shownPieces.count, previousGlassCount)
                t.check(previousParts.allSatisfy { before in widget.view.accessibilityParts.contains(where: { $0 === before }) })
                var acceptedOnMain = false
                DispatchQueue.main.async {
                    t.equal(widget.latestPresented?.scene.generation, nextGeneration)
                    t.equal(widget.window.frame.size, NSSize(width: stage == 0 ? 50 : stage == 1 ? 70 : 20, height: 20))
                    t.equal(widget.nativeComposition.shownPieces.count, stage == 0 ? 1 : 0)
                    t.equal(widget.view.accessibilityParts.filter { $0.id.name == "glassarm" }.count, stage == 0 ? 1 : 0)
                    t.equal(widget.view.accessibilityParts.filter { $0.id.name == "solidarm" }.count, stage == 1 ? 1 : 0)
                    t.equal(old.accessibilityFrame(), .zero); t.check(!old.accessibilityPerformPress())
                    t.check(previousParts.allSatisfy { before in !widget.view.accessibilityParts.contains(where: { $0 === before }) })
                    t.equal(host.presented?.scene.generation, previousGeneration, "the Main transaction precedes the owner ACK")
                    acceptedOnMain = true
                }
                t.check(AppSelfTest.spin(timeout: 10) { time.runUntilIdle(); return acceptedOnMain && !host.frames.hasBitmapDelivery })
                t.equal(host.presented?.scene.generation, widget.latestPresented?.scene.generation)
                if stage == 1 {
                    let solid = try S.element(widget.latestPresented?.scene, "solidarm")
                    solidID = solid.id; t.check(solid.id != old.id)
                }
                if stage != 0 {
                    guard let image = widget.content.shown.image else { throw S.Failure.bitmap }
                    let width: CGFloat = stage == 1 ? 70 : 20
                    let scale = Int(widget.window.backingScaleFactor)
                    var rectangles = [(CGRect(x: 0, y: 0, width: 20, height: 20), RGBA.white)]
                    if stage == 1 { rectangles.append((CGRect(x: 20, y: 0, width: 50, height: 20), S.blue)) }
                    t.equal(try S.bytes(image), try S.bytes(S.literal(size: NSSize(width: width, height: 20),
                        scale: scale, rectangles: rectangles)), "bitmap replacement contains no stale glass segment")
                } else {
                    t.check(widget.content.shown.image == nil)
                    t.equal(try S.element(widget.latestPresented?.scene, "glassarm").id, old.id)
                }
            }
            t.check(solidID != nil)
            guard let restored = widget.view.accessibilityParts.first(where: { $0.id.name == "glassarm" }) else { throw S.Failure.fixture }
            t.check(restored !== old); t.check(restored.accessibilityPerformPress())
            t.check(AppSelfTest.spin(timeout: 10) { time.runUntilIdle(); return copies == ["glass"] })
        }
    }

    private static func imagePreflightTest(_ t: AppTestRunner) {
        t.suite("App: Desk view if host: inactive image sources still belong to immutable package preflight") {
            let root = t.temporaryDirectory("desk-view-if-images")
            let image = try S.literal(size: NSSize(width: 4, height: 4), scale: 1,
                rectangles: [(CGRect(x: 0, y: 0, width: 4, height: 4), S.red)])
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw S.Failure.bitmap }
            for name in ["active.png", "inactive.png"] { try png.write(to: root.appendingPathComponent(name)) }
            let prepared = DeskProgramResources.prepare(root: root, literals: ["active.png", "inactive.png"],
                                                        maximumBytes: 8_192, maximumFiles: 2)
            defer { prepared.removeCopies() }
            t.equal(prepared.failure, nil)
            let source = """
            widget { if true {
                Image("active.png").size(40, 20).imageMode(.stretch)
            } else {
                Image("inactive.png").size(40, 20).imageMode(.stretch)
            } }
            """
            let result = Desk.compile(Desk.check(Desk.parse(source, fileName: "ViewIfImages.desk"), context: CheckContext(
                resources: PackageResources(package: DeskPackage(files: prepared.files)))))
            guard let program = result.program else { throw S.Failure.compilation(String(describing: result.issues)) }
            t.equal(result.imageSources, ["active.png", "inactive.png"])
            let input = S.input(), time = try S.clock(), provider = S.Provider()
            let host = try DeskProgramHost(program: program, executor: time, provider: provider,
                input: input, prepared: prepared, clock: time.clock)
            defer { host.close() }
            host.take(S.facts(input), input: input); host.start(); host.drawFirstFrame()
            t.equal(host.state, .ready)
            t.equal(try S.bytes(provider.image()), try S.bytes(S.literal(size: NSSize(width: 40, height: 20), scale: 1,
                rectangles: [(CGRect(x: 0, y: 0, width: 40, height: 20), S.red)])))
            try Data("changed inactive source".utf8).write(to: root.appendingPathComponent("inactive.png"))
            host.refresh()
            if case .unavailable = host.state {} else { t.check(false, "an inactive branch does not bypass package immutability") }
            t.check(host.scene == nil && host.presented == nil); t.check(provider.releases > 0)
        }
    }
}
