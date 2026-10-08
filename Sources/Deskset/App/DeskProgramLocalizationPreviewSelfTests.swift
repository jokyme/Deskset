import AppKit
import DeskLanguage
import DesksetCore
import DesksetDraw

/// Widget language is a preview-session input. These fixtures never change the Mac's language or open a menu.
enum DeskProgramLocalizationPreviewSelfTests {
    private typealias S = DeskConditionalTestSupport
    private enum Failure: Error { case fixture(String) }

    private final class Inputs {
        var languages: [String]
        var locale = Locale(identifier: "en_US")
        init(_ languages: [String]) { self.languages = languages }
    }

    private struct Fixture {
        let service: DeskLanguageService
        let preview: DeskProgramPreviewController
        let window: NSWindow
        let time: VirtualTimeExecutor
    }

    private static func fixture(_ t: AppTestRunner, _ source: String, inputs: Inputs,
                                package: String? = nil, preparation: S.Preparation? = nil) throws -> Fixture {
        let file = DeskFileID(path: "Localization.desk")
        var files = [file: source]
        if let package { files[DeskFileID(path: "package.desk")] = package }
        let service = DeskLanguageService(openFile: file, files: files)
        guard !service.snapshot.diagnostics.contains(where: { $0.severity == .error }) else {
            throw Failure.fixture("checker: \(service.snapshot.diagnostics)")
        }
        let compiled = Desk.compile(service.snapshot.checked, catalog: service.snapshot.options.catalog,
                                    package: service.snapshot.package)
        guard compiled.program != nil else {
            throw Failure.fixture("compiler: \(compiled.issues.map(\.message).joined(separator: "; "))")
        }
        let time = try S.clock()
        let prepare: DeskProgramPreviewController.IconPreparation = preparation.map { $0.submit } ?? DeskIconResources.prepare
        let preview = DeskProgramPreviewController(clock: time.clock, executor: time,
            dateLocale: { inputs.locale }, preferredLanguages: { inputs.languages }, system: S.System(),
            prepareIcons: prepare, presentsTooltips: false, presentsMenus: false) {
                $0.file == file && $0.generation == service.snapshot.generation
                    && $0.tree.version == service.snapshot.tree.version && service.snapshot.isChecked
            }
        let window = NSWindow(contentViewController: preview)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.layoutSubtreeIfNeeded()
        t.atSuiteEnd { preview.close(); window.close(); time.runUntilIdle() }
        preview.show(service.snapshot, readError: nil)
        preview.setVisible(true)
        return Fixture(service: service, preview: preview, window: window, time: time)
    }

    static func run(_ t: AppTestRunner) {
        t.suite("Desk: localization preview: text tooltip menu and semantic label share the widget language") {
            let source = """
            translations { "zh-Hans" {
                "Battery {count}": "电量 {count}"
                "Details {count}": "细节 {count}"
                "Battery": "电池"
                "Read {count}": "读取 {count}"
                "Copy {count}": "复制 {count}"
                "More": "更多"
            } }
            widget { variable count = 0
                Text("Battery {count}").font(20).digits(.normal).color(.black).size(240, 40).name(label)
                    .tooltip("Details {count}", title: "Battery").voiceOver("Read {count}")
                    .onClick { count = count + 1 }
                    .menu {
                        Item("Copy {count}").onClick { copy("Payload {count}") }
                        Menu("More") { Item("Untranslated").onClick {} }
                    }
            }
            """
            let inputs = Inputs(["zh-CN"]), f = try fixture(t, source, inputs: inputs), p = f.preview
            t.equal(p.state, .ready)
            t.equal(S.texts(p.scene), ["电量 0"])
            t.equal(try S.element(p.scene, "label").accessibilityLabel, "读取 0")
            let location = try point(p, "label")
            t.equal(p.tooltipTarget(at: location)?.info.text, "细节 0")
            t.equal(p.tooltipTarget(at: location)?.info.title, "电池")
            try textPixels(t, p, "电量 0", wrong: "Battery 0")
            try mouse(.rightMouseDown, at: location, preview: p, window: f.window)
            guard let menu = p.canvas.programMenus?.menu, menu.items.count == 2 else {
                throw Failure.fixture("translated native menu")
            }
            t.equal(menu.items.map(\.title), ["复制 0", "更多"])
            t.equal(menu.items[1].submenu?.items.map(\.title), ["Untranslated"], "a missing key uses its source")
            choose(menu.items[0]); choose(menu.items[0])
            t.equal(p.recordedEffects, [.copy("Payload 0")], "copy payloads are not translatable and selection is once")
            try click(p, "label", in: f.window)
            t.equal(S.texts(p.scene), ["电量 1"])
            t.equal(try S.element(p.scene, "label").accessibilityLabel, "读取 1")
            t.equal(p.tooltipTarget(at: location)?.info.text, "细节 1")
            try textPixels(t, p, "电量 1", wrong: "电量 0")
            let oldTooltip = p.tooltipTarget(at: location)
            try mouse(.rightMouseDown, at: location, preview: p, window: f.window)
            guard let oldItem = p.canvas.programMenus?.menu?.items.first else { throw Failure.fixture("menu before language change") }
            inputs.languages = ["en"]
            p.refreshDateInput()
            t.equal(S.texts(p.scene), ["Battery 0"])
            t.equal(try S.element(p.scene, "label").accessibilityLabel, "Read 0")
            t.equal(p.tooltipTarget(at: location)?.info.text, "Details 0")
            t.check(p.tooltipTarget(at: location)?.revision.session != oldTooltip?.revision.session)
            t.check(p.canvas.programMenus?.menu == nil)
            choose(oldItem)
            t.equal(p.recordedEffects, [], "a menu from the old language session cannot activate the reloaded program")
            t.equal(f.service.snapshot.text, source)
        }

        t.suite("Desk: localization preview: region clock and Studio changes keep state but language preferences reload") {
            let source = """
            translations { "zh-Hans" {
                "State {count} / {opened, format: .weekday}": "状态 {count} / {opened, format: .weekday}"
            } }
            widget { variable count = 0; variable opened = time.now
                Text("State {count} / {opened, format: .weekday}").size(300, 40).name(label)
                    .onClick { count = count + 1 }
            }
            """
            let inputs = Inputs(["fr-FR"]), f = try fixture(t, source, inputs: inputs), p = f.preview
            t.equal(S.texts(p.scene), ["State 0 / Thursday"], "no matching table means source English")
            try click(p, "label", in: f.window)
            t.equal(S.texts(p.scene), ["State 1 / Thursday"])
            inputs.locale = Locale(identifier: "en_GB")
            f.time.setWallClock(Date(timeIntervalSince1970: 86_400))
            f.time.timeZone = TimeZone(identifier: "Asia/Tokyo")!
            p.refreshDateInput()
            t.equal(S.texts(p.scene), ["State 1 / Thursday"], "date/zone/region refresh keeps the initialized Date and variable")
            let oldStudioLanguage = StudioText.languageOverride
            defer { StudioText.languageOverride = oldStudioLanguage }
            StudioText.languageOverride = .chinese
            p.refreshDateInput()
            t.equal(S.texts(p.scene), ["State 1 / Thursday"], "Studio language does not choose widget text or automatic date words")
            inputs.languages = ["it-IT"] // Both lists fall back to English, but the system language did change.
            p.refreshDateInput()
            t.equal(S.texts(p.scene), ["State 0 / Friday"], "reload is keyed by preferences, not only the selected table")
            inputs.languages = ["zh-Hans"]
            p.refreshDateInput()
            t.equal(S.texts(p.scene), ["状态 0 / 星期五"])
            try click(p, "label", in: f.window)
            StudioText.languageOverride = .english
            p.refreshDateInput()
            t.equal(S.texts(p.scene), ["状态 1 / 星期五"])
            t.equal(f.time.pendingCount, 0, "a frozen Date does not acquire a display clock")
        }

        t.suite("Desk: localization preview: package translations reach previews and widget entries override matching keys") {
            let source = """
            translations { "zh-Hans" { "Local": "组件" } }
            widget { Column(spacing: 0, align: .left) {
                Text("Shared").size(160, 30).name(shared).tooltip("Shared")
                Text("Local").size(160, 30).name(local)
            } }
            """
            let package = """
            translations { "zh-Hans" {
                "Shared": "套件共用"
                "Local": "套件默认"
            } }
            """
            let f = try fixture(t, source, inputs: Inputs(["zh-SG"]), package: package), p = f.preview
            t.check(f.service.snapshot.package != nil)
            t.equal(p.state, .ready)
            t.equal(S.texts(p.scene), ["套件共用", "组件"])
            t.equal(p.tooltipTarget(at: try point(p, "shared"))?.info.text, "套件共用")
            t.equal(f.service.snapshot.folder[DeskFileID(path: "package.desk")], package)
            t.equal(f.service.snapshot.text, source)
        }

        t.suite("Desk: localization preview: language reload cancels pending resources and effects while region refresh stays frozen") {
            let source = """
            translations { "zh-Hans" {
                "Count {count}": "计数 {count}"
                "Choose": "选择"
            } }
            widget { variable count = 0
                Column(spacing: 0, align: .left) {
                    Icon(count == 0 ? "wifi" : "sun.max.fill").font(20 + count).size(60).name(symbol)
                        .onClick { count = count + 1; copy("{count}|{time.now, format: "HH:mm:ss"}") }
                    Text("Count {count}").size(180, 30).name(label)
                        .menu { Item("Choose").onClick { copy("menu") } }
                }
            }
            """
            let inputs = Inputs(["en"]), preparation = S.Preparation()
            let f = try fixture(t, source, inputs: inputs, preparation: preparation), p = f.preview
            t.check(p.isPreparingIcons)
            try preparation.succeed(0); f.time.runUntilIdle()
            t.equal(p.state, .ready); t.equal(S.texts(p.scene), ["Count 0"])
            try click(p, "symbol", in: f.window)
            t.check(p.isPreparingIcons); t.equal(preparation.calls.count, 2)
            t.equal(S.texts(p.scene), ["Count 0"]); t.equal(p.recordedEffects, [])
            inputs.languages = ["zh-CN"]
            p.refreshDateInput()
            t.check(try preparation.call(1).ticket.isCancelled)
            t.equal(p.state, .ready, "the reloaded initial symbol can reuse its committed native resource")
            t.equal(S.texts(p.scene), ["计数 0"])
            let reloadedGeneration = p.scene?.generation
            try preparation.succeed(1); f.time.runUntilIdle()
            t.equal(S.texts(p.scene), ["计数 0"])
            t.equal(p.scene?.generation, reloadedGeneration)
            t.equal(p.recordedEffects, [], "an old-language action cannot publish after the reload")
            t.equal(S.icons(p.scene).map(\.request.name), ["wifi"])

            try click(p, "symbol", in: f.window)
            let held = preparation.calls.count - 1
            t.check(p.isPreparingIcons)
            inputs.locale = Locale(identifier: "en_GB")
            f.time.setWallClock(Date(timeIntervalSince1970: 30))
            p.refreshDateInput()
            t.check(try preparation.call(held).ticket.isCancelled == false, "region refresh defers without cancelling the frozen action")
            t.equal(S.texts(p.scene), ["计数 0"]); t.equal(p.recordedEffects, [])
            try preparation.succeed(held); f.time.runUntilIdle()
            t.equal(S.texts(p.scene), ["计数 1"])
            t.equal(p.recordedEffects, [.copy("1|00:00:00")], "the pending action still uses its original clock sample")
            try preparation.succeed(held); f.time.runUntilIdle()
            t.equal(p.recordedEffects.count, 1)
            try click(p, "symbol", in: f.window)
            let closing = preparation.calls.count - 1
            t.check(p.isPreparingIcons)
            p.close()
            t.check(try preparation.call(closing).ticket.isCancelled)
            try preparation.succeed(closing); f.time.runUntilIdle()
            p.refreshDateInput()
            t.equal(p.state, .closed); t.check(p.scene == nil && !p.isPreparingIcons)
            t.equal(f.time.pendingCount, 0)
        }

        t.suite("Desk: localization preview: code window locale notifications distinguish preferences and region without editing source") {
            let source = """
            translations { "zh-Hans" { "Count {count}": "计数 {count}" } }
            widget { variable count = 0
                Text("Count {count}").size(180, 40).name(label).onClick { count = count + 1 }
            }
            """
            let root = t.temporaryDirectory("desk-localization-preview"), inputs = Inputs(["en"]), time = try S.clock()
            let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                skinsDirectory: root.appendingPathComponent("Skins"), layoutsDirectory: root.appendingPathComponent("Layouts"),
                backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
                settingsDirectory: root.appendingPathComponent("Settings"), presentsWindows: false)
            let file = root.appendingPathComponent("Preview.desk")
            try Data(source.utf8).write(to: file)
            let controller = try CodeFileWindowController(file: file, app: app, previewClock: time.clock,
                previewExecutor: time, previewLocale: { inputs.locale }, previewPreferredLanguages: { inputs.languages },
                previewSystem: S.System())
            t.atSuiteEnd {
                controller.codeView.onCommit = { _, _ in false }
                controller.codeView.onDiskConflict = { _ in .decideLater }
                controller.codeView.discardUncommittedChanges(); controller.window?.close()
                _ = app.stopAllForTermination(); app.endEngineThread()
            }
            guard let p = controller.deskPreview, let window = controller.window else { throw Failure.fixture("code preview") }
            window.appearance = NSAppearance(named: .aqua)
            window.contentView?.layoutSubtreeIfNeeded()
            t.check(AppSelfTest.spin(timeout: 10) { p.state == .ready })
            p.setVisible(true)
            try click(p, "label", in: window)
            t.equal(S.texts(p.scene), ["Count 1"])
            inputs.locale = Locale(identifier: "en_GB")
            NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
            t.equal(S.texts(p.scene), ["Count 1"])
            inputs.languages = ["zh-Hans"]
            NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
            t.equal(S.texts(p.scene), ["计数 0"])
            t.equal(controller.codeView.text, source)
            t.equal(try Data(contentsOf: file), Data(source.utf8))
            t.check(app.sortedControllers.isEmpty, "a language refresh activates no desktop widget")
            window.close()
            inputs.languages = ["en"]
            NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
            t.equal(p.state, .closed); t.check(p.scene == nil)
            t.equal(time.pendingCount, 0)
        }
    }

    private static func point(_ preview: DeskProgramPreviewController, _ name: String) throws -> NSPoint {
        let frame = try S.element(preview.scene, name).frame
        return NSPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
    }

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, preview: DeskProgramPreviewController,
                              window: NSWindow) throws {
        guard let event = NSEvent.mouseEvent(with: type, location: preview.canvas.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1) else { throw Failure.fixture("mouse event") }
        switch type {
        case .leftMouseDown: preview.canvas.mouseDown(with: event)
        case .leftMouseUp: preview.canvas.mouseUp(with: event)
        case .rightMouseDown: preview.canvas.rightMouseDown(with: event)
        default: throw Failure.fixture("unsupported mouse event")
        }
    }

    private static func click(_ preview: DeskProgramPreviewController, _ name: String, in window: NSWindow) throws {
        let location = try point(preview, name)
        try mouse(.leftMouseDown, at: location, preview: preview, window: window)
        try mouse(.leftMouseUp, at: location, preview: preview, window: window)
    }

    private static func choose(_ item: NSMenuItem) {
        if let action = item.action { NSApplication.shared.sendAction(action, to: item.target, from: item) }
    }

    private final class LiteralTextView: NSView {
        let item: DrawItem
        private let context = DrawContext(fonts: AppFontResolver())
        override var isFlipped: Bool { true }
        init(_ text: String) {
            var style = TextStyle()
            style.fontFace = "System"; style.fontSize = 15; style.fontWeight = 400; style.color = .black
            style.horizontalAlign = .center; style.verticalAlign = .center
            style.accurateText = true; style.antiAlias = true; style.trailingSpaces = true
            let frame = SkinRect(width: 240, height: 40)
            item = .text(TextDraw(text: text, style: style, frame: frame, contentFrame: frame, anchor: SkinPoint()))
            super.init(frame: frame.cgRect)
        }
        required init?(coder: NSCoder) { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard let destination = NSGraphicsContext.current?.cgContext else { return }
            DesksetDraw.DrawExecutor.draw([item], in: destination, context: context, cycle: 1,
                                          target: DrawTarget.capture(destination, glass: .none))
        }
    }

    private static func textPixels(_ t: AppTestRunner, _ preview: DeskProgramPreviewController,
                                   _ text: String, wrong: String) throws {
        let literal = LiteralTextView(text), untranslated = LiteralTextView(wrong)
        t.equal(preview.scene?.drawingItems, [literal.item], "independent literal text and point-font recipe")
        for scale in [1, 2] {
            let actual = try S.bytes(S.paint(preview.canvas, scale: scale))
            let expected = try S.bytes(S.paint(literal, scale: scale))
            t.check(actual.contains(where: { $0 != 0 }))
            t.equal(actual, expected, "translated native pixels at \(scale)x")
            t.check(actual != (try S.bytes(S.paint(untranslated, scale: scale))), "source/stale text is a negative pixel control")
        }
    }
}
