import AppKit
import DesksetCore

/// `Deskset --snapshot-ui <what> --out file.png [--dark] [--select Config] [--size WxH] [--skins-dir DIR]`: renders app UI
/// off-screen so it can be checked without a visible screen.
///
/// - `manage`: the Manage window over a temporary copy of TestSkins/App and TestSkins/Deskset, the example skins of
///   Deskset 0.1 (or `--skins-dir`), with App\Focus and Deskset\Clock loaded and `--select` (default App\Focus)
///   selected (`Config\File.ini` selects one file); `--hidden` loads the selected skin when it is not loaded and has
///   it hide itself (`!Hide`), `--coordinates X,Y` types coordinates for it; `--pane layouts` shows saved layouts
///   made from these temporary skins.
/// - `install`: the .rmskin confirmation for a generated package (header image, plugin warning).
/// - `install-zip`: the confirmation for a plain ZIP archive (no RMSKIN.ini) with fonts.
/// - `icon`: the app icon at 1024 px.
/// - `menubar`: the menu bar glyph, enlarged.
/// - `settings`: the Settings window on its Editor pane (or `--pane general`), listing the editors installed here.
/// - `codeeditor`: the built-in code editor on a copy of Deskset\System (System.ini and its @Include files), with a
///   section revealed and tinted (`--size WxH`, default 760x560).
enum UISnapshot {
    static func run(_ arguments: [String]) -> Int32 {
        func value(after flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count,
                  !arguments[i + 1].hasPrefix("--") else { return nil }
            return arguments[i + 1]
        }
        let what = value(after: "--snapshot-ui") ?? "manage"
        let output = URL(fileURLWithPath: value(after: "--out") ?? "\(what).png")
        NSApp.appearance = NSAppearance(named: arguments.contains("--dark") ? .darkAqua : .aqua)

        let data: Data?
        switch what {
        case "icon":
            data = AppIcon.pngData(pixels: 1024)
        case "menubar":
            data = png(of: menuBarPreview())
        case "install":
            data = installPreview().flatMap(png)
        case "install-zip":
            data = installPreview(plainArchive: true).flatMap(png)
        case "settings":
            data = settingsPreview(pane: value(after: "--pane").flatMap(SettingsWindowController.Pane.init) ?? .editor)
        case "codeeditor":
            let size = (value(after: "--size").map { $0.split(separator: "x").compactMap { Double($0) } } ?? [])
                .map { $0.isFinite ? min(max($0, 200), 3000) : 760 }
            data = codeEditorPreview(size: size.count == 2 ? NSSize(width: size[0], height: size[1])
                                                           : NSSize(width: 760, height: 560))
        case "manage":
            // Sizes are clamped (a typo like 90000x600 would otherwise ask for a gigabyte-sized bitmap).
            let size = (value(after: "--size").map { $0.split(separator: "x").compactMap { Double($0) } } ?? [])
                .map { $0.isFinite ? min(max($0, 200), 3000) : 900 }
            let typed = (value(after: "--coordinates")?.split(separator: ",").compactMap { Int($0) }) ?? []
            data = managePreview(select: value(after: "--select") ?? "App\\Focus", skinsDir: value(after: "--skins-dir"),
                                 size: size.count == 2 ? NSSize(width: size[0], height: size[1]) : nil,
                                 hidden: arguments.contains("--hidden"),
                                 coordinates: typed.count == 2 ? (typed[0], typed[1]) : nil,
                                 pane: value(after: "--pane").flatMap(ManageWindowController.Tab.init(rawValue:)) ?? .skins)
        default:
            fputs("unknown snapshot \"\(what)\" (manage, settings, codeeditor, install, install-zip, icon, menubar)\n", stderr)
            return 2
        }
        guard let data else {
            fputs("error: could not render \(what)\n", stderr)
            return 1
        }
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: output)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 1
        }
        print("wrote \(output.path)")
        return 0
    }

    private static func temporaryDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesksetSnapshot-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Renders a view (with its subviews) into a PNG at 2x.
    static func png(of view: NSView) -> Data? {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2),
                                         pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func managePreview(select: String, skinsDir: String?, size: NSSize?, hidden: Bool = false,
                                      coordinates: (x: Int, y: Int)? = nil,
                                      pane: ManageWindowController.Tab = .skins) -> Data? {
        let root = temporaryDirectory("manage")
        let skins: URL
        if let skinsDir {
            skins = URL(fileURLWithPath: skinsDir)
        } else {
            skins = root.appendingPathComponent("Skins")
            try? FileManager.default.createDirectory(at: skins, withIntermediateDirectories: true)
            if let test = Paths.repositoryFolder("TestSkins") {
                for folder in ["App", "Deskset"] {
                    try? FileManager.default.copyItem(at: test.appendingPathComponent(folder),
                                                      to: skins.appendingPathComponent(folder))
                }
            }
        }
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                                skinsDirectory: skins, layoutsDirectory: root.appendingPathComponent("Layouts"),
                                backupsDirectory: root.appendingPathComponent("Backups"), presentsWindows: false)
        app.activate(config: "App\\Focus", file: "Focus.ini")
        app.activate(config: "Deskset\\Clock", file: nil)
        let manage = ManageWindowController(app: app)
        if let size { manage.window?.setContentSize(size) }
        // --select Config or Config\File.ini.
        var config = SkinLibrary.normalizedConfigName(select), file: String?
        if config.lowercased().hasSuffix(".ini"), let cut = config.lastIndex(of: "\\") {
            file = String(config[config.index(after: cut)...])
            config = String(config[..<cut])
        }
        // --hidden: the selected skin (loaded first when it is not) hides itself, as a widget that hides while idle does.
        if hidden, let c = app.controller(for: config) ?? app.activate(config: config, file: file), !c.isHiddenByBang {
            c.skin.execute("[!Hide]", from: nil)
        }
        manage.select(config: config, file: file)
        if let coordinates { manage.testTypeCoordinates(x: coordinates.x, y: coordinates.y) }
        if pane == .layouts {
            // The preview writes only under its temporary root, never the user's saved layouts or wallpaper.
            do {
                try app.saveLayout(named: "Desktop", options: LayoutSaveOptions())
                try app.saveLayout(named: "Empty", options: LayoutSaveOptions(empty: true))
            } catch {
                fputs("error: could not prepare layout preview: \(error.localizedDescription)\n", stderr)
                return nil
            }
            manage.selectTab(.layouts)
            manage.testSelectLayout("Desktop")
        }
        let rep = manage.snapshot()
        let data = rep?.representation(using: .png, properties: [:])
        withExtendedLifetime(app) {}
        return data
    }

    private static func settingsPreview(pane: SettingsWindowController.Pane) -> Data? {
        let root = temporaryDirectory("settings")
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                                skinsDirectory: root.appendingPathComponent("Skins"),
                                layoutsDirectory: root.appendingPathComponent("Layouts"),
                                backupsDirectory: root.appendingPathComponent("Backups"), presentsWindows: false)
        let settings = SettingsWindowController(app: app)
        settings.select(pane)
        let data = settings.snapshot()?.representation(using: .png, properties: [:])
        withExtendedLifetime(app) {}
        return data
    }

    /// The code editor on the 0.1 example System.ini (or an original stand-in when the repository's TestSkins are not
    /// around).
    static func codeEditorPreview(size: NSSize) -> Data? {
        let root = temporaryDirectory("code")
        let folder = root.appendingPathComponent("Deskset")
        var main = folder.appendingPathComponent("System/System.ini")
        var files = [main, folder.appendingPathComponent("@Resources/Variables.inc"),
                     folder.appendingPathComponent("@Resources/Styles.inc")]
        if let test = Paths.repositoryFolder("TestSkins") {
            try? FileManager.default.copyItem(at: test.appendingPathComponent("Deskset"), to: folder)
        }
        if !FileManager.default.fileExists(atPath: main.path) {
            main = root.appendingPathComponent("Sample.ini")
            files = [main]
            let sample = "; An original sample skin.\r\n[Rainmeter]\r\nUpdate=1000\r\n\r\n[Variables]\r\nColor=255,200,80\r\n\r\n"
                + "[MeasureCPU]\r\nMeasure=CPU\r\n\r\n[MeterCPU]\r\nMeter=String\r\nMeasureName=MeasureCPU\r\n"
                + "Text=CPU %1%\r\nFontColor=#Color#\r\nW=([MeterCPU:H] * 2)\r\n"
                + "LeftMouseUpAction=[!SetOption MeterCPU Text \"Hello\"][!Redraw]\r\n"
            try? Data(sample.utf8).write(to: main)
        }
        let editor = CodeEditorView(frame: NSRect(origin: .zero, size: size))
        editor.appearance = NSApp.appearance
        do {
            try editor.open(files: files, current: main)
        } catch {
            return nil
        }
        editor.layoutSubtreeIfNeeded()
        let section = FileManager.default.fileExists(atPath: folder.appendingPathComponent("System/System.ini").path)
            ? "MeasureSwapTotal" : "MeterCPU"
        editor.revealSection(section, in: main)
        if let lines = editor.lineRange(ofSection: section), let document = editor.document(for: main) {
            var caretDocument = document
            caretDocument.text = editor.text
            let line = caretDocument.range(ofLine: lines.lowerBound + 2)
            editor.textView.setSelectedRange(NSRange(location: NSMaxRange(line), length: 0))
            // Let the caret come to rest so the jump bar names its section.
            RunLoop.main.run(until: Date().addingTimeInterval(CodeEditorView.defaultCaretRestDelay + 0.1))
        }
        editor.layoutSubtreeIfNeeded()
        let data = png(of: editor)
        withExtendedLifetime(editor) {}
        return data
    }

    private static func installPreview(plainArchive: Bool = false) -> NSView? {
        let dir = temporaryDirectory("install")
        let url: URL?
        if plainArchive {
            url = try? AppSelfTest.makeZip(in: dir, name: "Aurora Suite.zip", files: [
                "Aurora Suite/Clock/Clock.ini": Data("[Rainmeter]\n".utf8),
                "Aurora Suite/Weather/Weather.ini": Data("[Rainmeter]\n".utf8),
                "Aurora Suite/@Resources/Fonts/Aurora Sans.otf": Data(),
                "Aurora Suite/Fonts/Aurora Mono.ttf": Data(),
                "Read me.txt": Data("Unzip into Documents/Rainmeter/Skins".utf8),
            ])
        } else {
            let header = headerImageBMP()
            let manifest = "[rmskin]\nName=Aurora Suite\nAuthor=Jane Example\nVersion=1.4\nLoadType=Skin\n"
                + "Load=Aurora\\Clock\\Clock.ini\n"
            var files: [String: Data] = [
                "RMSKIN.ini": Data(manifest.utf8),
                "Skins/Aurora/Clock/Clock.ini": Data("[Rainmeter]\n".utf8),
                "Skins/Aurora/Weather/Weather.ini": Data("[Rainmeter]\n".utf8),
                "Plugins/64bit/AuroraHelper.dll": Data([0x4D, 0x5A]),
            ]
            if let header { files["RMSKIN.bmp"] = header }
            url = try? AppSelfTest.makePackage(in: dir, name: "Aurora.rmskin", files: files)
        }
        guard let url, let inspection = try? RmskinPackage.inspect(url) else { return nil }
        defer { inspection.cleanup() }
        let summary = InstallSummary(inspection, packageName: url.lastPathComponent,
                                     skinsDirectory: temporaryDirectory("skins"))
        let image = inspection.headerImageURL.flatMap { NSImage(contentsOf: $0) }
        let accessory = SkinInstallFlow.accessoryView(summary, headerImage: image)
        // A stand-in for the alert chrome: title, subtitle, accessory, buttons.
        let title = NSTextField(labelWithString: summary.title)
        title.font = .boldSystemFont(ofSize: 13)
        let subtitle = NSTextField(labelWithString: summary.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        let icon = NSImageView(image: AppIcon.image(size: 64))
        let install = NSButton(title: "Install", target: nil, action: nil)
        install.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        let buttons = NSStackView(views: [cancel, install])
        let stack = NSStackView(views: [icon, title, subtitle, accessory, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 10))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
        ])
        stack.layoutSubtreeIfNeeded()
        box.frame.size = NSSize(width: 440, height: stack.fittingSize.height)
        box.layoutSubtreeIfNeeded()
        return box
    }

    /// An original 400×60 header image, as a Windows bitmap.
    private static func headerImageBMP() -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 60, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.14, blue: 0.40, alpha: 1),
                   ending: NSColor(srgbRed: 0.05, green: 0.60, blue: 0.65, alpha: 1))?
            .draw(in: NSRect(x: 0, y: 0, width: 400, height: 60), angle: 0)
        ("Aurora Suite" as NSString).draw(at: NSPoint(x: 18, y: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .bmp, properties: [:])
    }

    private static func menuBarPreview() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 44))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        for (i, scale) in [CGFloat(1), CGFloat(2)].enumerated() {
            let image = NSImageView(frame: NSRect(x: 10 + CGFloat(i) * 40, y: 4, width: 18 * scale, height: 18 * scale))
            image.image = AppIcon.statusBarImage()
            image.imageScaling = .scaleProportionallyUpOrDown
            image.contentTintColor = .labelColor
            view.addSubview(image)
        }
        return view
    }
}

