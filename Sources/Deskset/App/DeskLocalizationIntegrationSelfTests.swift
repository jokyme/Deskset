import AppKit
import DeskLanguage
import DesksetCore

enum DeskLocalizationIntegrationSelfTests {
    private typealias S = DeskConditionalTestSupport
    private final class Preferences {
        var languages = ["zh-CN"]
        var locale = Locale(identifier: "en_US")
    }
    private struct Fixture {
        let app: AppController
        let widget: DeskWidgetWindowController
        let time: VirtualTimeExecutor
        let preferences: Preferences
    }
    private static let source = """
    info { name: "Desk status" }
    widget {
        variable count = 0
        Text("Count {count}").size(180, 48).name(counter)
            .voiceOver("Value {count}").tooltip("Tap", title: "Details")
            .onClick { count = count + 1 }
            .menu { Item("Reset").onClick { count = 0 } }
    }
    translations {
        "zh-Hans" {
            "Desk status": "桌面状态"
            "Count {count}": "{count} 次"
            "Value {count}": "数值 {count}"
            "Tap": "点按"
            "Details": "详情"
            "Reset": "重置"
        }
        "fr" {
            "Desk status": "État"
            "Count {count}": "Compte {count}"
            "Value {count}": "Valeur {count}"
            "Tap": "Appuyer"
            "Details": "Détails"
            "Reset": "Réinitialiser"
        }
    }
    """

    static func run(_ t: AppTestRunner) {
        t.suite("App: Desk localization: preferred languages choose source or translations while preserving region and calendar") {
            let program = try S.program(source)
            let locale = Locale(identifier: "en_GB@calendar=buddhist")
            for (preferred, language, name) in [(["de", "zh_CN"], "zh-Hans", "桌面状态"),
                                               (["fr-CA", "zh"], "fr", "État")] {
                let resolved = DeskProgramLocalization(program: program, preferredLanguages: preferred, locale: locale)
                t.equal(resolved.language, language)
                t.equal(resolved.name, name)
                t.equal(resolved.locale.region?.identifier, "GB")
                t.equal(resolved.locale.calendar.identifier, .buddhist)
            }
            for preferred in [[], ["ja"], ["zh-TW"]] {
                let resolved = DeskProgramLocalization(program: program, preferredLanguages: preferred, locale: locale)
                t.equal(resolved.language, nil)
                t.equal(resolved.name, "Desk status")
                t.equal(resolved.locale.language.languageCode?.identifier, "en")
                t.equal(resolved.locale.region?.identifier, "GB")
                t.equal(resolved.locale.calendar.identifier, .buddhist)
            }
            let input = try DeskWidgetWindowController.makeInput(for: NSAppearance(named: .aqua)!, scale: 2,
                program: program, preferredLanguages: ["zh_CN"], locale: locale)
            t.equal(input.language, "zh-Hans"); t.equal(input.locale.language.languageCode?.identifier, "zh")
            t.equal(input.locale.language.script?.identifier, "Hans"); t.equal(input.locale.region?.identifier, "GB")
        }

        t.suite("App: Desk localization: bitmap owner resolves labels menus and clicks from one fixed language") {
            let program = try S.program(source), time = try S.clock(), provider = S.Provider()
            let base = S.input()
            let localized = DeskProgramLocalization(program: program, preferredLanguages: ["zh-CN"], locale: base.locale)
            let input = DeskProgramHost.Input(environment: base.environment, colors: base.colors,
                                              locale: localized.locale, language: localized.language)
            let host = try DeskProgramHost(program: program, executor: time, provider: provider, input: input,
                clock: time.clock, system: S.System())
            defer { host.close(); time.runUntilIdle() }
            host.take(S.facts(input), input: input); host.start(); S.flush(host, time)
            t.equal(S.texts(host.scene), ["0 次"])
            t.equal(try S.element(host.scene, "counter").accessibilityLabel, "数值 0")
            let point = try S.point(host, "counter")
            t.equal(host.scene?.hitMap.toolTipInfo(at: point.x, point.y, images: nil), ToolTipInfo(text: "点按", title: "详情"))
            guard let generation = host.scene?.generation,
                  let opened = try host.openMenu(at: point, expectedGeneration: generation, id: UUID()) else {
                throw S.Failure.fixture
            }
            t.equal(opened.items.count, 1)
            guard case .item(_, let title, _, _)? = opened.items.first else { throw S.Failure.fixture }
            t.equal(title, "重置")
            _ = try S.click(host, "counter"); S.flush(host, time)
            t.equal(S.texts(host.scene), ["1 次"])
            let regional = DeskProgramHost.Input(environment: input.environment, colors: input.colors,
                locale: Locale(identifier: "zh_Hans_GB"), language: input.language)
            host.take(S.facts(regional), input: regional); S.flush(host, time)
            t.equal(S.texts(host.scene), ["1 次"], "formatting changes do not reset session variables")
            let other = DeskProgramHost.Input(environment: input.environment, colors: input.colors,
                locale: Locale(identifier: "fr_US"), language: "fr")
            host.take(S.facts(other), input: other)
            t.check(host.scene == nil && host.presented == nil, "a different language requires a new loaded session")
            host.take(S.facts(regional), input: regional); S.flush(host, time)
            t.equal(S.texts(host.scene), ["1 次"], "the rejected input cannot partially change the retained language or variables")
            t.equal(time.background.reports, [])
        }

        t.suite("App: Desk localization: installed desktop reload retires native menus and accessibility from the old language") {
            let f = try fixture(t), widget = f.widget
            t.equal(S.texts(widget.latestPresented?.scene), ["0 次"])
            t.equal(widget.displayName, "桌面状态"); t.equal(widget.window.title, "桌面状态")
            t.equal(widget.view.accessibilityLabel(), "桌面状态")
            guard let oldAccessibility = widget.view.accessibilityParts.first else { throw S.Failure.fixture }
            t.equal(oldAccessibility.accessibilityLabel(), "数值 0")
            try takeFacts(t, f)
            try mouse(.leftMouseDown, f); try mouse(.leftMouseUp, f)
            t.check(AppSelfTest.spin(timeout: 10) {
                f.time.runUntilIdle()
                return S.texts(widget.latestPresented?.scene) == ["1 次"]
            })
            try takeFacts(t, f)
            widget.showProgramMenu(at: NSPoint(x: 90, y: 24), nativeItems: [])
            t.check(AppSelfTest.spin(timeout: 10) { f.time.runUntilIdle(); return widget.view.programMenus?.menu != nil })
            guard let oldItem = widget.view.programMenus?.menu?.items.first else { throw S.Failure.fixture }
            t.equal(oldItem.title, "重置")

            f.preferences.locale = Locale(identifier: "en_GB")
            widget.refreshDateInput()
            t.check(AppSelfTest.spin(timeout: 10) { f.time.runUntilIdle(); return widget.owner.host?.frames.hasBitmapDelivery == false })
            t.check(!widget.isClosing)
            t.equal(S.texts(widget.latestPresented?.scene), ["1 次"])
            let oldSession = widget.sessionID
            f.preferences.languages = ["fr-CA"]
            widget.refreshDateInput()
            t.check(widget.isClosing && widget.sessionID != oldSession)
            t.check(widget.latestPresented == nil && widget.view.programMenus?.menu == nil)
            t.check(!oldAccessibility.accessibilityPerformPress())
            if let action = oldItem.action, let target = oldItem.target {
                _ = NSApplication.shared.sendAction(action, to: target, from: oldItem)
            }
            t.check(AppSelfTest.spin(timeout: 10) {
                f.time.runUntilIdle()
                guard let current = f.app.deskWidgetWindows[widget.instance.id], current !== widget else { return false }
                return current.isStarted && current.latestPresented != nil
            })
            guard let replacement = f.app.deskWidgetWindows[widget.instance.id], replacement !== widget else {
                throw S.Failure.fixture
            }
            t.check(widget.isClosed)
            t.equal(S.texts(replacement.latestPresented?.scene), ["Compte 0"], "language reload starts a fresh variable session")
            t.equal(replacement.displayName, "État")
            t.equal(replacement.view.accessibilityLabel(), "État")
            t.equal(replacement.view.accessibilityParts.first?.accessibilityLabel(), "Valeur 0")
            t.check(f.app.state.deskInstance(widget.instance.id)?.active == true)
            t.check(!widget.window.isVisible && !replacement.window.isVisible)
            t.equal(try String(contentsOf: widget.directory.appendingPathComponent("Main.desk"), encoding: .utf8), source)
        }

        t.suite("App: Desk localization: explicit deactivation during a queued language reload prevents resurrection") {
            let f = try fixture(t), widget = f.widget
            f.preferences.languages = ["fr"]
            widget.refreshDateInput()
            t.check(widget.isClosing)
            f.app.deactivateDeskWidget(instanceID: widget.instance.id)
            t.check(AppSelfTest.spin(timeout: 10) { f.time.runUntilIdle(); return widget.isClosed })
            t.check(f.app.deskWidgetWindows[widget.instance.id] == nil)
            t.check(f.app.state.deskInstance(widget.instance.id)?.active == false)
            t.equal(f.time.background.reports, [])
        }
    }

    private static func fixture(_ t: AppTestRunner) throws -> Fixture {
        let root = t.temporaryDirectory("desk-localization"), time = try S.clock(), preferences = Preferences()
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
            skinsDirectory: root.appendingPathComponent("Skins"), layoutsDirectory: root.appendingPathComponent("Layouts"),
            backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
            settingsDirectory: root.appendingPathComponent("Settings"), widgetsDirectory: root.appendingPathComponent("Widgets"),
            presentsWindows: false)
        let sourceID = UUID(), instanceID = UUID()
        let entry = DeskWidgetSourceState(id: sourceID, entry: sourceID.uuidString.lowercased() + "/Main.desk")
        let instance = DeskWidgetInstanceState(id: instanceID, sourceID: sourceID)
        let directory = root.appendingPathComponent("Widgets").appendingPathComponent(sourceID.uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(source.utf8).write(to: directory.appendingPathComponent("Main.desk"))
        try app.state.registerDeskInstallation(source: entry, instance: instance)
        let widget = DeskWidgetWindowController(source: entry, instance: instance, directory: directory,
            program: try S.program(source), prepared: nil, app: app, executor: time, clock: time.clock,
            preferredLanguages: { preferences.languages }, dateLocale: { preferences.locale })
        t.atSuiteEnd {
            widget.close(deactivate: false)
            _ = AppSelfTest.spin(timeout: 10) { time.runUntilIdle(); return widget.isClosed }
            _ = app.stopAllForTermination(); app.endEngineThread()
        }
        t.check(AppSelfTest.spin(timeout: 10) { time.runUntilIdle(); return widget.isStarted && widget.latestPresented != nil })
        guard widget.owner.host != nil else { throw S.Failure.fixture }
        return Fixture(app: app, widget: widget, time: time, preferences: preferences)
    }

    private static func takeFacts(_ t: AppTestRunner, _ f: Fixture) throws {
        let widget = f.widget
        // Drain real Main appearance/frame callbacks before publishing the explicit offscreen pointer facts.
        var drained = false
        f.time.async { DispatchQueue.main.async { drained = true } }
        _ = AppSelfTest.spin(timeout: 10) { f.time.runUntilIdle(); return drained }
        let input = try DeskWidgetWindowController.makeInput(for: widget.window.effectiveAppearance,
            scale: widget.window.backingScaleFactor, program: widget.program,
            preferredLanguages: f.preferences.languages, locale: f.preferences.locale)
        guard let space = widget.window.colorSpace?.cgColorSpace else { throw S.Failure.fixture }
        widget.owner.take(SkinWindowFacts(frame: widget.window.frame, isVisible: true, isOrderedIn: true,
            scale: widget.window.backingScaleFactor, colorSpace: space, appearance: input.environment.appearance.name,
            takesPointer: true, sequence: 100, panelGeneration: widget.destinationEpoch), input: input)
        guard let host = widget.owner.host else { throw S.Failure.fixture }
        t.check(AppSelfTest.spin(timeout: 10) {
            f.time.runUntilIdle(); host.frames.runLoopTurn(.beforeWaiting)
            return !host.frames.hasBitmapDelivery && host.scene?.generation == host.presented?.scene.generation
                && host.presented?.scene.generation == widget.latestPresented?.scene.generation
        }, "pointer input waits for the actual accepted picture after publishing offscreen facts")
        t.equal(host.scene?.hitMap.entry(at: 90, 24, handling: .leftUp, images: nil)?.elementID?.name, "counter")
    }

    private static func mouse(_ type: NSEvent.EventType, _ f: Fixture) throws {
        guard let event = NSEvent.mouseEvent(with: type, location: f.widget.view.convert(NSPoint(x: 90, y: 24), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: f.widget.window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { throw S.Failure.fixture }
        if type == .leftMouseDown { f.widget.view.mouseDown(with: event) }
        else { f.widget.view.mouseUp(with: event) }
    }
}
