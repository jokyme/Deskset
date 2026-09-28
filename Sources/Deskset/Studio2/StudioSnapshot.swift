import AppKit
import DesksetCore

/// `Deskset --snapshot-ui studio2 --screen NAME [--dark] [--language en|zh] [--size WxH] [--out x.png]`: the new Studio
/// window off-screen, 1400 × 860 points at 2x (2800 × 1720 pixels), on one of the designed screens (`StudioScreen`),
/// to be looked at next to the design's picture of it.
///
/// Off-screen there is no window server: the window's own toolbar, the traffic lights, the sidebar and inspector
/// materials and every glass surface are drawn as stand-ins — the toolbar's from the same state its real items show
/// (`StudioToolbarState`) — and the panes' contents are drawn by their views. An open popover (a real `NSPopover` on
/// screen) is composed at its anchor.
enum StudioSnapshot {
    struct Problem: Error, Equatable {
        var message: String
    }

    /// A Studio window open on a screen, over a temporary Skins folder (removed by `close`).
    struct Opened {
        let app: AppController
        let controller: StudioWindowController
        let root: URL

        func close() {
            controller.window?.close()
            app.stopAllForTermination()
            try? FileManager.default.removeItem(at: root)
        }
    }

    static let defaultSize = StudioWindowController.defaultSize
    static let scale: CGFloat = 2

    /// Renders the screen the arguments name. A failure is a mistake in the arguments (exit status 2); nil data is a
    /// screen that could not be rendered (exit status 1).
    static func run(_ arguments: [String]) -> Result<Data?, Problem> {
        func value(after flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count,
                  !arguments[i + 1].hasPrefix("--") else { return nil }
            return arguments[i + 1]
        }
        let list = StudioScreen.names.joined(separator: ", ")
        guard let name = value(after: "--screen") else {
            return .failure(Problem(message: "--snapshot-ui studio2 needs --screen NAME (\(list))"))
        }
        guard let screen = StudioScreen.named(name) else {
            return .failure(Problem(message: "unknown screen \"\(name)\" (\(list))"))
        }
        if arguments.contains("--language") {
            guard let language = value(after: "--language").flatMap(StudioLanguage.init(argument:)) else {
                return .failure(Problem(message: "--language needs en or zh"))
            }
            StudioText.languageOverride = language
        } else {
            StudioText.languageOverride = .english
        }
        var size = defaultSize
        if let text = value(after: "--size") {
            let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2, parts.allSatisfy({ $0.isFinite && $0 >= 600 && $0 <= 3000 }) else {
                return .failure(Problem(message: "--size needs WxH points, each 600 to 3000"))
            }
            size = NSSize(width: parts[0], height: parts[1])
        }
        // The weather widgets show a sample forecast: nothing is fetched and no place is asked for.
        setenv("DESKSET_WEATHER_DEMO", "1", 1)
        WeatherWiring.installPreview()
        if arguments.contains("--on-screen") {
            let explicit = arguments.contains("--size")
            return .success(onScreen(screen, size: explicit ? size : NSSize(width: 1050, height: 700)))
        }
        guard let opened = open(screen, size: size) else { return .success(nil) }
        defer { opened.close() }
        return .success(render(opened.controller)?.representation(using: .png, properties: [:]))
    }

    /// Opens the new Studio on `screen`'s widget, headless, in the screen's state. nil when the fixture is not found
    /// or its widget does not load (the reason is printed).
    static func open(_ screen: StudioScreen, size: NSSize = defaultSize, onScreen: Bool = false) -> Opened? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesksetStudio2-\(screen.name)-\(UUID().uuidString)", isDirectory: true)
        let skins = root.appendingPathComponent("Skins", isDirectory: true)
        do {
            guard try screen.install(into: skins) else {
                fputs("error: the fixture of \(screen.name) (\(screen.fixture.source)/\(screen.fixture.root)) is not "
                      + "found or no longer takes its edits; run from the repository\n", stderr)
                try? FileManager.default.removeItem(at: root)
                return nil
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            try? FileManager.default.removeItem(at: root)
            return nil
        }
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                                skinsDirectory: skins, layoutsDirectory: root.appendingPathComponent("Layouts"),
                                backupsDirectory: root.appendingPathComponent("Backups"),
                                defaultSkinsSource: Paths.repositoryFolder("DefaultSkins"), presentsWindows: onScreen)
        guard let c = app.activate(config: screen.fixture.config, file: screen.fixture.file) else {
            fputs("error: \(screen.fixture.config) does not load\n", stderr)
            try? FileManager.default.removeItem(at: root)
            return nil
        }
        if onScreen {
            // On screen the switch would read the user's defaults: the window is asked for directly.
            StudioWindowController.show(for: c, app: app)
        } else {
            let switchWas = StudioSwitch.headlessValue
            StudioSwitch.headlessValue = true
            app.showInspector(for: c)
            StudioSwitch.headlessValue = switchWas
        }
        guard let controller = StudioWindowController.window(for: app) else {
            app.stopAllForTermination()
            try? FileManager.default.removeItem(at: root)
            return nil
        }
        apply(screen, to: controller, size: size)
        return Opened(app: app, controller: controller, root: root)
    }

    /// Puts the window in the screen's state: its size, the sidebar, the inspector, the zoom.
    static func apply(_ screen: StudioScreen, to controller: StudioWindowController, size: NSSize = defaultSize) {
        controller.window?.setContentSize(size)
        controller.setSidebarOpen(screen.depth == .build)
        controller.setInspectorShown(screen.inspectorShown)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.placeInspector()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.canvasController.fixedZoom = screen.zoom
        controller.canvasController.reload(fit: true)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.updateToolbar()
        let preview = controller.preview!
        preview.setBackdrop(screen.backdrop)
        if !screen.pinned.isEmpty {
            // Pinned before the instance's first update: some readings are taken only once (a name, a disk's size).
            preview.sample.pinned = screen.pinned
            controller.session?.reloadStudioSkin()
        }
        for _ in 1..<max(screen.updates, 1) { controller.skin?.update() }
        if let data = screen.data { preview.setData(data) }
        if screen.frozen { preview.setTime(.frozen(StudioScreen.frozenTime)) }
        if screen.previewPopover { preview.showPreviewPopover() }
        // The widget page as the numbers are now, its look thumbnails, and the color popover when the screen has it.
        controller.widgetPage.rebuild()
        controller.drawThumbnails()
        if let swatch = screen.colorPopover, let facts = controller.widgetPage.facts,
           let role = controller.widgetPage.colorRoles(facts)[swatch] {
            StudioColorPopover.recentInMemory = screen.recentColors
            controller.widgetPage.openColor(role, swatch: swatch)
        }
        if let swatch = screen.hoverSwatch { controller.widgetPage.handle(.hoverSwatch(item: "colors", swatch: swatch)) }
        // The sidebar's page, and the data row the pointer is on.
        if screen.depth == .build {
            controller.sidebarController.show(screen.sidebarPage)
            controller.refreshLayers()
            controller.updateToolbar()
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            controller.sidebarController.layout()
            controller.sidebarController.layersView.layoutSubtreeIfNeeded()
            if let data = screen.pointedData { controller.sidebarController.layersView.setHoveredData(data) }
        }
        // The part's page, as the screen has it.
        if let part = screen.selection {
            StudioPartPage.rememberedInMemory = []
            controller.select(part: part)
            if screen.everySetting { controller.partPage.toggleEverySetting() }
            if let row = screen.scrubbing {
                controller.partPage.scrubbingItem = row
                controller.partPage.refresh()
            }
            if screen.scopeHover { controller.partPage.handle(.scopeHover(true)) }
            if screen.distances { controller.canvasController.overlay.setShowsDistances(true) }
        }
        applyCode(screen, to: controller)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.canvasController.geometryChanged()
        controller.canvasController.layoutFloating()
    }

    /// The code pane as the screen has it: open, the edits typed and committed, the caret, the file menu.
    static func applyCode(_ screen: StudioScreen, to controller: StudioWindowController) {
        guard screen.code != .hidden else { return }
        // "Open in …" names one editor on every Mac.
        StudioCodeState.editorName = { _, _ in "Visual Studio Code" }
        controller.setCodeMode(screen.code)
        guard let session = controller.session, let skin = controller.skin else { return }
        let root = skin.rootConfigDirectory
        for edit in screen.codeEdits {
            let url = root.appendingPathComponent(edit.path)
            guard let text = try? session.buffers.text(of: url), text.contains(edit.find) else { continue }
            _ = try? session.apply(StudioText[.stepTyping], [.editSource(
                file: url, text: text.replacingOccurrences(of: edit.find, with: edit.replace), encoding: nil)])
        }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.codeController.layOut()
        if let caret = screen.caret {
            let url = root.appendingPathComponent(caret.path)
            controller.codeView.reveal(line: caret.line, in: url, select: false)
            controller.codeCaretRested(controller.codeView.caretSection, file: url)
        }
        controller.refreshDiagnostics()
        if screen.fileMenu { controller.isShowingFileMenu = true }
        controller.codeController.layOut()
    }

    // MARK: On screen

    /// `--on-screen`: the window as the window server draws it — real glass, the system toolbar, the popover's own
    /// window — read back from this process's own windows only. Runs only when the process may already read them
    /// (`CGPreflightScreenCaptureAccess`): it never asks for permission. The window and the widget are put at the
    /// bottom right of the main screen (the top left is left alone), and closed afterwards.
    static func onScreen(_ screen: StudioScreen, size: NSSize) -> Data? {
        guard CGPreflightScreenCaptureAccess() else {
            fputs("error: --on-screen reads the window back, which this process may not do (it does not ask)\n", stderr)
            return nil
        }
        NSApp.setActivationPolicy(.accessory)
        guard let opened = open(screen, size: size, onScreen: true), let window = opened.controller.window else {
            return nil
        }
        defer { opened.close() }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 949)
        // The widget where the canvas can line up with it: bottom right, left of the window.
        if let widget = opened.controller.link?.desktopWindow {
            widget.setFrameOrigin(NSPoint(x: visible.maxX - size.width - widget.frame.width - 16,
                                          y: visible.minY + 16))
        }
        window.setFrameOrigin(NSPoint(x: visible.maxX - window.frame.width, y: visible.minY))
        window.orderFrontRegardless()
        opened.controller.canvasController.geometryChanged()
        opened.controller.preview.refreshBackdrop()
        if screen.previewPopover { opened.controller.preview.showPreviewPopover() }
        // Let the window server draw it (and the glass settle).
        let until = Date().addingTimeInterval(1.5)
        while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        guard let base = windowImage(window) else {
            fputs("error: the window could not be read back\n", stderr)
            return nil
        }
        // The popover is a window of its own: laid over the window's picture where it is on screen.
        let scale = CGFloat(base.width) / window.frame.width
        let popovers = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.className.contains("Popover") }
        guard !popovers.isEmpty,
              let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSBitmapImageRep(cgImage: base).representation(using: .png, properties: [:])
        }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for popover in popovers {
            guard let image = windowImage(popover) else { continue }
            let f = popover.frame
            ctx.draw(image, in: CGRect(x: (f.minX - window.frame.minX) * scale, y: (f.minY - window.frame.minY) * scale,
                                       width: f.width * scale, height: f.height * scale))
        }
        guard let composed = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:])
    }

    /// A picture of one of this process's windows as it is on screen (`CGWindowListCreateImage`, looked up at run
    /// time: the SDK marks it unavailable to new code).
    private static func windowImage(_ window: NSWindow) -> CGImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        // kCGWindowListOptionIncludingWindow; kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
        return create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue()
    }

    // MARK: Rendering

    /// The window as the screen shows it, at `scale`.
    static func render(_ controller: StudioWindowController) -> NSBitmapImageRep? {
        guard let content = controller.window?.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        let size = content.bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = content.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            // The window's rounded corners.
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: windowCornerRadius,
                         yRadius: windowCornerRadius).addClip()
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
            drawPanes(controller, in: content, dark: dark)
            if let popover = controller.runningPopoverContent {
                drawPopover(popover.view, anchor: controller.toolbar.titleView, in: content, dark: dark)
            }
            if let popover = controller.widgetPage.colorPopover, let anchor = controller.widgetPage.popoverAnchor() {
                _ = popover.view
                drawPopover(popover.view, anchor: anchor.view, in: content, dark: dark, edge: .maxX,
                            anchorRect: anchor.rect)
            }
            if controller.isShowingFileMenu, !controller.codeItem.isCollapsed {
                drawFileMenu(controller, in: content, dark: dark)
            }
            if let popover = controller.preview.previewPopoverContent {
                drawPopover(popover.view, anchor: controller.canvasController.previewBar.appearanceItem, in: content,
                            dark: dark, minX: 62)
            }
            drawToolbar(controller, in: content, dark: dark)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static let windowCornerRadius: CGFloat = 18

    /// Draws `view`'s visible part where it is in `content`.
    static func draw(_ view: NSView, in content: NSView) {
        guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0 else { return }
        let visible = view.visibleRect
        guard visible.width > 0, visible.height > 0 else { return }
        let target = view.convert(visible, to: content)
        guard let part = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((target.width * scale).rounded()),
                                          pixelsHigh: Int((target.height * scale).rounded()), bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        part.size = visible.size
        view.cacheDisplay(in: visible, to: part)
        part.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// The canvas (its planes, the widget, what floats over it), the sidebar and the inspector, with stand-ins for their
    /// materials.
    private static func drawPanes(_ controller: StudioWindowController, in content: NSView, dark: Bool) {
        let canvas = controller.canvasController
        for plane in [canvas.backdropView, canvas.neighboursView, canvas.glassPlane, canvas.canvas, canvas.overlay,
                      canvas.problemMarks] as [NSView] {
            draw(plane, in: content)
        }
        for floating in [canvas.captionTag, canvas.problemCapsule, canvas.statusCapsule, canvas.compatCapsule,
                         canvas.hintPill,
                         canvas.previewBar, canvas.zoomCapsule] as [NSView] {
            draw(floating, in: content)
        }
        if !controller.codeItem.isCollapsed { drawCode(controller, in: content, dark: dark) }
        if !controller.inspectorItem.isCollapsed {
            let pane = controller.inspectorController.view
            let r = pane.convert(pane.bounds, to: content)
            (dark ? NSColor(white: 0.155, alpha: 1) : NSColor(white: 0.975, alpha: 1)).setFill()
            r.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: r.minX, y: r.minY, width: 1, height: r.height).fill()
            // The page itself (a scroll view's own drawing is not what the window shows off screen).
            draw(controller.inspectorController.pageView, in: content)
            redrawSegments(in: controller.inspectorController.pageView, content: content)
        }
        if !controller.sidebarItem.isCollapsed {
            let pane = controller.sidebarController.view
            let r = pane.convert(pane.bounds, to: content)
            (dark ? NSColor(white: 0.18, alpha: 1)
                  : NSColor(srgbRed: 0.955, green: 0.95, blue: 0.955, alpha: 1)).setFill()
            r.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height).fill()
            // Its pieces (a scroll view's own drawing is not what the window shows off screen).
            for view in controller.sidebarController.snapshotViews {
                if let tabs = view as? NSSegmentedControl {
                    drawSegments(tabs, in: content, dark: dark)
                } else {
                    draw(view, in: content)
                }
            }
        }
    }

    // MARK: The code pane

    /// The code pane, piece by piece (a scroll view's own drawing is not what the window shows off screen): its
    /// background, the header, the line numbers, the text with its cards, the marks over them, the status line.
    static func drawCode(_ controller: StudioWindowController, in content: NSView, dark: Bool) {
        let pane = controller.codeController
        pane.layOut()
        pane.codeView.layoutSubtreeIfNeeded()
        let r = pane.view.convert(pane.view.bounds, to: content)
        NSColor.textBackgroundColor.setFill()
        r.fill()
        let top = pane.view.convert(NSRect(x: 0, y: 0, width: pane.view.bounds.width,
                                           height: StudioCanvasViewController.toolbarHeight), to: content)
        StudioCodeHeader.fill.setFill()
        top.fill()
        // The text first: its clip view reaches under the line numbers (a left inset keeps the text clear of them).
        for view in [pane.header, pane.codeView.textView, pane.codeView.ruler, pane.decorations.overlay,
                     pane.statusLine] as [NSView] {
            draw(view, in: content)
        }
        NSColor.separatorColor.setFill()
        NSRect(x: r.minX, y: r.minY, width: 1, height: r.height).fill()
    }

    /// The file menu, open under the file's name: a menu's material, the widget's files with their counts (the one
    /// shown checked), Show in Finder, Open in <editor>.
    static func drawFileMenu(_ controller: StudioWindowController, in content: NSView, dark: Bool) {
        let button = controller.codeController.header.fileButton
        let anchor = button.convert(button.bounds, to: content)
        let files = controller.codeFiles()
        var plain = [StudioText[.showInFinder]]
        if let name = controller.codeEditorName { plain.append(StudioText.format(.codeOpenIn, name)) }
        let rowHeight: CGFloat = 25, width: CGFloat = 300
        let height = CGFloat(files.count) * rowHeight + 11 + CGFloat(plain.count) * 24 + 12
        let frame = NSRect(x: anchor.minX + 4, y: anchor.minY - 6 - height, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.45 : 0.18)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        let path = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        (dark ? NSColor(white: 0.17, alpha: 0.98) : NSColor(white: 0.965, alpha: 0.98)).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.10)).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        let font = NSFont.systemFont(ofSize: 13)
        let small = NSFont.systemFont(ofSize: 11.5)
        var y = frame.maxY - 6
        for f in files {
            y -= rowHeight
            let mid = y + rowHeight / 2
            if f.current, let check = symbol("checkmark", size: 11, color: .labelColor) {
                check.draw(in: NSRect(x: frame.minX + 12, y: mid - check.size.height / 2, width: check.size.width,
                                      height: check.size.height))
            }
            if let doc = symbol("doc.text", size: 11.5, color: .secondaryLabelColor) {
                doc.draw(in: NSRect(x: frame.minX + 31, y: mid - doc.size.height / 2, width: doc.size.width,
                                    height: doc.size.height))
            }
            let title = NSAttributedString(string: f.title, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            title.draw(at: NSPoint(x: frame.minX + 50, y: mid - title.size().height / 2))
            var x = frame.maxX - 14
            for (count, color) in [(f.warnings, StudioCodeColors.warning), (f.problems, StudioCodeColors.problem)]
                where count > 0 {
                let n = NSAttributedString(string: "\(count)", attributes: [.font: small, .foregroundColor: NSColor.labelColor])
                x -= n.size().width
                n.draw(at: NSPoint(x: x, y: mid - n.size().height / 2))
                x -= 10
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: mid - 3.5, width: 7, height: 7)).fill()
                x -= 8
            }
        }
        y -= 5
        NSColor.separatorColor.setFill()
        NSRect(x: frame.minX + 12, y: y, width: width - 24, height: 1).fill()
        y -= 6
        for text in plain {
            y -= 24
            let t = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            t.draw(at: NSPoint(x: frame.minX + 16, y: y + 12 - t.size().height / 2))
        }
    }

    // MARK: Stand-ins

    /// A segmented control as the window in front draws it: a capsule track, the chosen segment filled with the accent
    /// color and its words white (off screen the control draws the grey of a window behind others).
    /// Draws the segmented controls under `view` again as a key window shows them: a control in a window that is not
    /// the active app's draws its chosen segment grey, so a copy outside any window (which draws as active: the chosen
    /// segment in the accent color) is drawn over each.
    static func redrawSegments(in view: NSView, content: NSView) {
        for sub in view.subviews {
            if let control = sub as? NSSegmentedControl {
                guard !control.isHiddenOrHasHiddenAncestor, control.bounds.width > 0, control.bounds.height > 0,
                      !control.visibleRect.intersection(control.bounds).isEmpty else { continue }
                let copy = detachedCopy(of: control)
                guard let part = copy.bitmapImageRepForCachingDisplay(in: copy.bounds) else { continue }
                copy.cacheDisplay(in: copy.bounds, to: part)
                part.draw(in: control.convert(control.bounds, to: content), from: .zero, operation: .sourceOver,
                          fraction: 1, respectFlipped: true, hints: nil)
            } else {
                redrawSegments(in: sub, content: content)
            }
        }
    }

    /// A copy of `control` in no window, with its segments, widths, choice, font and colors.
    static func detachedCopy(of control: NSSegmentedControl) -> NSSegmentedControl {
        let copy = NSSegmentedControl(frame: NSRect(origin: .zero, size: control.bounds.size))
        copy.appearance = control.effectiveAppearance
        copy.segmentCount = control.segmentCount
        copy.trackingMode = control.trackingMode
        copy.segmentStyle = control.segmentStyle
        copy.segmentDistribution = control.segmentDistribution
        copy.controlSize = control.controlSize
        copy.font = control.font
        copy.selectedSegmentBezelColor = control.selectedSegmentBezelColor
        copy.isEnabled = control.isEnabled
        for i in 0..<control.segmentCount {
            copy.setLabel(control.label(forSegment: i) ?? "", forSegment: i)
            copy.setImage(control.image(forSegment: i), forSegment: i)
            copy.setWidth(control.width(forSegment: i), forSegment: i)
            copy.setEnabled(control.isEnabled(forSegment: i), forSegment: i)
            copy.setSelected(control.isSelected(forSegment: i), forSegment: i)
        }
        copy.frame = NSRect(origin: .zero, size: control.bounds.size)
        copy.layoutSubtreeIfNeeded()
        return copy
    }

    static func drawSegments(_ control: NSSegmentedControl, in content: NSView, dark: Bool) {
        guard !control.isHiddenOrHasHiddenAncestor else { return }
        let r = control.convert(control.bounds, to: content).insetBy(dx: 0, dy: 0.5)
        let track = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        (dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.06)).setFill()
        track.fill()
        var x = r.minX + 2
        let font = NSFont.systemFont(ofSize: 13)
        for i in 0..<control.segmentCount {
            let w = control.width(forSegment: i) > 0 ? control.width(forSegment: i) : (r.width - 4) / CGFloat(control.segmentCount)
            let seg = NSRect(x: x, y: r.minY + 2, width: w, height: r.height - 4)
            let chosen = control.isSelected(forSegment: i)
            if chosen {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: seg, xRadius: seg.height / 2, yRadius: seg.height / 2).fill()
            }
            let label = NSAttributedString(string: control.label(forSegment: i) ?? "", attributes: [
                .font: chosen ? NSFont.systemFont(ofSize: 13, weight: .medium) : font,
                .foregroundColor: chosen ? NSColor.white : NSColor.labelColor])
            let size = label.size()
            label.draw(at: NSPoint(x: seg.midX - size.width / 2, y: seg.midY - size.height / 2))
            x += w + 2
        }
    }

    /// A glass capsule (or circle) of the toolbar: a pale fill, a hairline and a soft shadow.
    static func drawGlass(_ rect: NSRect, dark: Bool, fill: NSColor? = nil) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.35 : 0.10)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        (fill ?? (dark ? NSColor(white: 0.24, alpha: 0.92) : NSColor(white: 1, alpha: 0.78))).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        if fill == nil {
            (dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.07)).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    static func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    /// One part of a toolbar group: an icon, maybe words.
    struct Part {
        var symbol: String
        var title: String?
        var enabled = true
        var on = false

        func width(font: NSFont) -> CGFloat {
            let icon: CGFloat = 18
            guard let title else { return icon + 16 }
            return icon + 5 + (title as NSString).size(withAttributes: [.font: font]).width + 18
        }
    }

    static let groupHeight: CGFloat = 36
    static let toolbarMidY: CGFloat = 26

    /// A glass group of parts starting at `x` (top-left coordinates); returns its width.
    @discardableResult
    static func drawGroup(_ parts: [Part], x: CGFloat, top: CGFloat, dark: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let width = parts.map { $0.width(font: font) }.reduce(0, +) + 6
        let rect = NSRect(x: x, y: top - toolbarMidY - groupHeight / 2, width: width, height: groupHeight)
        drawGlass(rect, dark: dark)
        var cx = x + 3
        for part in parts {
            let w = part.width(font: font)
            let color: NSColor = part.on ? .controlAccentColor
                : NSColor.labelColor.withAlphaComponent(part.enabled ? 0.85 : 0.35)
            if part.on {
                let pill = NSRect(x: cx + 1, y: rect.midY - 15, width: w - 2, height: 30)
                NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 15, yRadius: 15).fill()
            }
            let iconSize: CGFloat = part.title == nil ? 15 : 13
            var ix = cx + (part.title == nil ? (w - 18) / 2 : 9)
            if let image = symbol(part.symbol, size: iconSize, color: color) {
                let s = image.size
                image.draw(in: NSRect(x: ix + (18 - s.width) / 2, y: rect.midY - s.height / 2, width: s.width,
                                      height: s.height))
            }
            ix += 18 + 5
            if let title = part.title {
                let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
                let ts = text.size()
                text.draw(at: NSPoint(x: ix, y: rect.midY - ts.height / 2))
            }
            cx += w
        }
        return width
    }

    /// The toolbar: traffic lights, the sidebar button, the name and sentence, the two centred groups (over the canvas
    /// column), Share, Done and the inspector button — from `StudioToolbarState`, as the real items show it.
    static func drawToolbar(_ controller: StudioWindowController, in content: NSView, dark: Bool) {
        let state = controller.toolbar.state
        let top = content.bounds.height
        let width = content.bounds.width
        func y(_ fromTop: CGFloat) -> CGFloat { top - fromTop }
        // Traffic lights.
        let lights = [NSColor(srgbRed: 1, green: 0.373, blue: 0.341, alpha: 1),
                      NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1),
                      NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1)]
        for (i, color) in lights.enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 20.5 + CGFloat(i) * 22.5, y: y(toolbarMidY) - 6, width: 12, height: 12)).fill()
        }
        // The sidebar button: a glass circle while the sidebar is closed, on the sidebar's edge while it is open.
        let sidebarOpen = !controller.sidebarItem.isCollapsed
        let sidebarMaxX = sidebarOpen ? controller.sidebarController.view.convert(
            controller.sidebarController.view.bounds, to: content).maxX : 0
        let sidebarCentre = sidebarOpen ? sidebarMaxX - 24 : 132
        if !sidebarOpen {
            drawGlass(NSRect(x: sidebarCentre - 20, y: y(toolbarMidY) - 20, width: 40, height: 40), dark: dark)
        }
        if let image = symbol("sidebar.left", size: 17, color: NSColor.labelColor.withAlphaComponent(0.85)) {
            image.draw(in: NSRect(x: sidebarCentre - image.size.width / 2, y: y(toolbarMidY) - image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
        }
        // The canvas column: the groups are centred over it.
        let canvasPane = controller.canvasController.view.convert(controller.canvasController.view.bounds, to: content)
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let undoParts = [Part(symbol: "arrow.uturn.backward", title: state.undoTitle, enabled: state.canUndo),
                         Part(symbol: "arrow.uturn.forward", enabled: state.canRedo)]
        let addParts = [Part(symbol: "plus", title: StudioText[.add], on: state.addOn),
                        Part(symbol: "chevron.left.forwardslash.chevron.right", title: StudioText[.code], on: state.codeOn)]
        let undoWidth = undoParts.map { $0.width(font: font) }.reduce(0, +) + 6
        let addWidth = addParts.map { $0.width(font: font) }.reduce(0, +) + 6
        let groupsWidth = undoWidth + 12 + addWidth
        let titleStart = sidebarOpen ? sidebarMaxX + 20 : 172
        var groupsStart = canvasPane.midX - groupsWidth / 2
        // The name keeps its room: the groups move right of it when the canvas is narrow.
        let name = NSAttributedString(string: state.name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let sentence = NSAttributedString(string: state.sentence, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        let titleWidth = max(name.size().width, sentence.size().width)
        groupsStart = max(groupsStart, titleStart + min(titleWidth, 200) + 20)
        let room = max(groupsStart - titleStart - 16, 40)
        name.draw(with: NSRect(x: titleStart, y: y(toolbarMidY) + 1, width: room, height: 17),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        sentence.draw(with: NSRect(x: titleStart, y: y(toolbarMidY) - 15, width: room, height: 15),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        drawGroup(undoParts, x: groupsStart, top: top, dark: dark)
        drawGroup(addParts, x: groupsStart + undoWidth + 12, top: top, dark: dark)
        // Share, Done and the inspector button, from the trailing edge.
        let circle: CGFloat = 36
        let inspectorCentre = width - 28
        drawGlass(NSRect(x: inspectorCentre - circle / 2, y: y(toolbarMidY) - circle / 2, width: circle, height: circle),
                  dark: dark)
        if let image = symbol("sidebar.right", size: 17, color: NSColor.labelColor.withAlphaComponent(0.85)) {
            image.draw(in: NSRect(x: inspectorCentre - image.size.width / 2, y: y(toolbarMidY) - image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
        }
        let done = NSAttributedString(string: state.primary, attributes: [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.white.withAlphaComponent(state.primaryEnabled ? 1 : 0.6)])
        let doneWidth = done.size().width + 34
        let doneRect = NSRect(x: inspectorCentre - circle / 2 - 12 - doneWidth, y: y(toolbarMidY) - groupHeight / 2,
                              width: doneWidth, height: groupHeight)
        drawGlass(doneRect, dark: dark,
                  fill: NSColor.controlAccentColor.withAlphaComponent(state.primaryEnabled ? 1 : 0.5))
        done.draw(at: NSPoint(x: doneRect.midX - done.size().width / 2, y: doneRect.midY - done.size().height / 2))
        let shareCentre = doneRect.minX - 8 - circle / 2
        drawGlass(NSRect(x: shareCentre - circle / 2, y: y(toolbarMidY) - circle / 2, width: circle, height: circle),
                  dark: dark)
        // Sharing is not there yet: its button is dimmed.
        if let image = symbol("square.and.arrow.up", size: 15, color: NSColor.labelColor.withAlphaComponent(0.35)) {
            image.draw(in: NSRect(x: shareCentre - image.size.width / 2, y: y(toolbarMidY) - image.size.height / 2 + 1,
                                  width: image.size.width, height: image.size.height))
        }
    }

    /// A popover left of its anchor, its arrow on its right edge pointing at the anchor (the color popover beside a
    /// swatch of the inspector): placed so the arrow sits a third of the way down, kept inside the window.
    static func drawSidePopover(_ view: NSView, size: NSSize, anchor a: NSRect, in content: NSView, dark: Bool,
                                arrow: CGFloat) {
        var frame = NSRect(x: a.minX - arrow - size.width, y: a.midY - size.height * 0.62, width: size.width,
                           height: size.height)
        frame.origin.y = min(max(frame.minY, 8), content.bounds.height - size.height - 60)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.5 : 0.22)
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        let path = NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14)
        let tipX = frame.maxX + arrow
        path.move(to: NSPoint(x: frame.maxX - 1, y: a.midY + arrow))
        path.line(to: NSPoint(x: tipX, y: a.midY))
        path.line(to: NSPoint(x: frame.maxX - 1, y: a.midY - arrow))
        path.close()
        (dark ? NSColor(white: 0.19, alpha: 0.97) : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 0.97)).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        (dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.10)).setStroke()
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.25, dy: 0.25), xRadius: 14, yRadius: 14)
        outline.lineWidth = 0.5
        outline.stroke()
        guard let part = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: part)
        part.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// A popover (`NSPopover` on screen) composed off-screen: its material, its arrow pointing at `anchor`, and its
    /// content, below the anchor (or above it when there is no room).
    static func drawPopover(_ view: NSView, anchor: NSView, in content: NSView, dark: Bool, minX: CGFloat = 8,
                            edge: NSRectEdge = .minY, anchorRect: NSRect? = nil) {
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize.width > 0 ? view.fittingSize : view.frame.size
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        let a = anchor.convert(anchorRect ?? anchor.bounds, to: content)
        let arrow: CGFloat = 9
        if edge == .maxX {
            return drawSidePopover(view, size: size, anchor: a, in: content, dark: dark, arrow: arrow)
        }
        var frame = NSRect(x: a.midX - size.width / 2, y: a.minY - arrow - size.height, width: size.width,
                           height: size.height)
        frame.origin.x = min(max(frame.minX, minX), content.bounds.width - size.width - 8)
        let below = frame.minY >= 8
        if !below { frame.origin.y = a.maxY + arrow }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.5 : 0.18)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        let path = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
        let tipY = below ? frame.maxY + arrow : frame.minY - arrow
        let baseY = below ? frame.maxY - 1 : frame.minY + 1
        path.move(to: NSPoint(x: a.midX - arrow, y: baseY))
        path.line(to: NSPoint(x: a.midX, y: tipY))
        path.line(to: NSPoint(x: a.midX + arrow, y: baseY))
        path.close()
        (dark ? NSColor(white: 0.20, alpha: 0.98) : NSColor(white: 0.985, alpha: 0.98)).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let part = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: part)
        part.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
