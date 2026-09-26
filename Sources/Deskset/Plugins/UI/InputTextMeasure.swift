import AppKit
import DesksetCore

// InputText plugin (manual: /manual/plugins/inputtext/): a real text field shown over the skin.

/// Shows one input box and reports the result (nil = dismissed).
protocol InputTextPrompting: AnyObject {
    func show(_ settings: InputTextSettings, completion: @escaping (String?) -> Void)
    /// Closes the box without reporting (the skin was refreshed or unloaded).
    func cancel()
}

/// `Plugin=InputText`.
///
/// - `!CommandMeasure Measure "ExecuteBatch All|N|N-M"` runs an `InputTextBatch` over `Command1`… (commands are
///   read when the bang runs, with the current `#Variables#`). Judgment: any other argument is run as one command.
/// - While a batch is open further ExecuteBatch bangs are ignored (Judgment; a click elsewhere on the skin first
///   dismisses the open box when FocusDismiss=1, so clicking the skin again starts a new batch as on Windows).
/// - The measure's string value is the last submitted input ("" before any), the number is that text as a number.
final class InputTextMeasure: MediaUIMeasure {
    private var batch: InputTextBatch?
    private var prompt: InputTextPrompting?
    private(set) var lastInput = ""
    /// Tests supply a fake prompt; the app shows `InputTextPanelPrompt` over the skin window.
    static var promptFactory: ((InputTextMeasure) -> InputTextPrompting?)?

    deinit {
        prompt?.cancel()
    }

    var isPrompting: Bool { batch != nil }

    override func computeValue() -> Double {
        publishString(lastInput)
        return Double(lastInput.muiTrimmed) ?? 0
    }

    override func execute(command: String) {
        guard let bang = InputTextBang.parse(command) else {
            skin.log("InputText [\(name)]: unknown command \"\(command)\"", level: .warning)
            return
        }
        guard batch == nil else {
            skin.log("InputText [\(name)]: an input box is already open", level: .debug)
            return
        }
        var steps: [InputTextBatch.Step] = []
        switch bang {
        case .all:
            var i = 1
            while i <= 1000, let c = commandOption(i) {
                steps.append(.init(index: i, command: c))
                i += 1
            }
        case .range(let range):
            for i in range { if let c = commandOption(i) { steps.append(.init(index: i, command: c)) } }
        case .command(let text):
            steps = [.init(index: 0, command: InputTextCommand.parse(skin.resolveStandardVariables(text, in: self)))]
        }
        guard !steps.isEmpty else {
            skin.log("InputText [\(name)]: no Command option for \"\(command)\"", level: .warning)
            return
        }
        batch = InputTextBatch(steps: steps)
        advance()
    }

    private func commandOption(_ index: Int) -> InputTextCommand? {
        guard let raw = rawOption("Command\(index)") else { return nil }
        return InputTextCommand.parse(skin.resolveStandardVariables(raw, in: self))
    }

    /// The measure's options with the command's overrides on top. Judgment: section variables are resolved whether
    /// or not the measure has DynamicVariables=1 (plugins read their options with section variables replaced), so
    /// overrides such as `Y=([MeterLabel:Y])` work.
    func settings(for command: InputTextCommand) -> InputTextSettings {
        var s = InputTextSettings.read { key in
            guard let raw = command.overrides[key.lowercased()] ?? rawOption(key) else { return nil }
            return skin.resolve(raw, in: self, sectionVariables: true)
        }
        s.onDismissAction = command.overrides["ondismissaction"] ?? actionOption("OnDismissAction")
        s.defaultValue = InputTextFilter.sanitize(s.defaultValue, number: s.inputNumber, limit: s.inputLimit)
        return s
    }

    private func advance() {
        guard let batch else { return }
        guard let step = batch.nextPrompt() else {
            self.batch = nil
            for action in batch.actions() { skin.execute(action, from: self) }
            return
        }
        let settings = settings(for: step.command)
        if prompt == nil { prompt = InputTextMeasure.promptFactory?(self) ?? controller.map { InputTextPanelPrompt(controller: $0) } }
        guard let prompt else {
            self.batch = nil
            skin.log("InputText [\(name)]: input boxes need a skin window", level: .debug)
            return
        }
        prompt.show(settings) { [weak self] input in
            guard let self, self.batch === batch else { return }
            if let input {
                self.lastInput = input
                self.publishString(input)
                batch.submit(input, for: step)
                self.advance()
            } else {
                self.batch = nil
                let action = settings.onDismissAction.muiTrimmed
                if !action.isEmpty && action != "0" { self.skin.execute(action, from: self) }
            }
        }
    }
}

// MARK: - The input box

/// Borderless non-activating panel: it takes keyboard focus without activating Deskset, so the app the user was in
/// stays frontmost and gets the focus back when the box closes.
final class InputTextPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The AppKit input box, positioned over the skin window at the measure's X/Y/W/H.
final class InputTextPanelPrompt: NSObject, InputTextPrompting, NSTextFieldDelegate, NSWindowDelegate {
    private weak var controller: SkinController?
    private var panel: InputTextPanel?
    private var field: NSTextField?
    private var completion: ((String?) -> Void)?
    private var settings = InputTextSettings()
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var becameKey = false
    private weak var previousKeyWindow: NSWindow?

    init(controller: SkinController) {
        self.controller = controller
    }

    deinit {
        tearDown()
    }

    /// Frame in screen coordinates: skin point (x, y) from the window's top-left; W defaults to the rest of the skin
    /// width (at least 40), H to the font's line height plus 6 (Judgment: the manual gives no defaults).
    /// X / Y are clamped to ±`maxOffset` points: AppKit raises an uncaught exception (the app would quit) for a window
    /// frame outside the 32-bit integer range, which a skin's formula (`X=(1/0.0000001)`, `Y=1e300`) can produce.
    static func frame(_ s: InputTextSettings, skinFrame: CGRect, skinWidth: Double, lineHeight: CGFloat) -> CGRect {
        func clamped(_ v: Double) -> Double { v.isFinite ? min(max(v, -maxOffset), maxOffset) : 0 }
        let x = clamped(s.x), y = clamped(s.y)
        let skinW = skinWidth.isFinite ? skinWidth : 0
        let width = CGFloat(s.width.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } ?? max(skinW - x, 40))
        let height = CGFloat(s.height.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } ?? Double(ceil(lineHeight + 6)))
        let w = min(max(width, 4), 8192), h = min(max(height, 4), 8192)
        return CGRect(x: skinFrame.minX + CGFloat(x), y: skinFrame.maxY - CGFloat(y) - h, width: w, height: h)
    }

    /// Largest X / Y offset of the box from the skin window (far beyond any screen, far inside AppKit's limits).
    static let maxOffset = 100_000.0

    /// TopMost: unset → the skin's level (the box is ordered just above the skin); 1 → above normal and floating
    /// windows; 0 → a normal window.
    static func level(_ topMost: Bool?, skinLevel: NSWindow.Level) -> NSWindow.Level {
        switch topMost {
        case nil: return skinLevel
        case true?: return NSWindow.Level(rawValue: max(skinLevel.rawValue, NSWindow.Level.floating.rawValue) + 1)
        case false?: return .normal
        }
    }

    static func font(_ s: InputTextSettings) -> NSFont {
        var style = TextStyle()
        style.fontFace = s.fontFace
        style.fontSize = s.fontSize
        style.bold = s.bold
        style.italic = s.italic
        return Fonts.font(for: style)
    }

    func show(_ settings: InputTextSettings, completion: @escaping (String?) -> Void) {
        tearDown()
        self.settings = settings
        self.completion = completion
        guard let controller, !controller.isStopped, controller.app.presentsWindows else {
            finish(nil)
            return
        }
        let skinWindow = controller.window
        let font = InputTextPanelPrompt.font(settings)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let frame = InputTextPanelPrompt.frame(settings, skinFrame: skinWindow.frame, skinWidth: controller.skin.width,
                                               lineHeight: lineHeight)
        let panel = InputTextPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.tabbingMode = .disallowed
        panel.canHide = false
        panel.level = InputTextPanelPrompt.level(settings.topMost, skinLevel: skinWindow.level)
        panel.collectionBehavior = skinWindow.collectionBehavior
        // "The alpha channel [of SolidColor] changes the opacity of the entire input box including the text."
        panel.alphaValue = CGFloat(min(max(settings.solidColor.a, 0), 255) / 255)
        panel.delegate = self

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        var background = settings.solidColor
        background.a = 255
        container.layer?.backgroundColor = background.cgColor

        let field: NSTextField = settings.password ? NSSecureTextField(frame: .zero) : NSTextField(frame: .zero)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        var color = settings.fontColor
        color.a = 255   // "Any alpha channel setting of FontColor is entirely ignored."
        field.textColor = color.nsColor
        switch settings.align {
        case .left: field.alignment = .left
        case .center: field.alignment = .center
        case .right: field.alignment = .right
        }
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.stringValue = settings.defaultValue
        field.delegate = self
        // Vertically centred, 2 points of margin at the sides (like an edit control).
        let fieldHeight = min(max(ceil(lineHeight + 2), 1), frame.height)
        field.frame = NSRect(x: 2, y: floor((frame.height - fieldHeight) / 2), width: max(frame.width - 4, 1),
                             height: fieldHeight)
        field.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        container.addSubview(field)
        panel.contentView = container

        self.panel = panel
        self.field = field
        previousKeyWindow = NSApp.keyWindow
        panel.makeKeyAndOrderFront(nil)
        if panel.level == skinWindow.level { panel.order(.above, relativeTo: skinWindow.windowNumber) }
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        installMonitors()
        observeSkinWindow(skinWindow)
    }

    func cancel() {
        completion = nil
        tearDown()
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window === panel { return event }
            if self.settings.focusDismiss {
                self.finish(nil)
                return event
            }
            // FocusDismiss=0: "the mouse is disabled until Enter or Escape is pressed" (in Deskset's own windows).
            panel.makeKey()
            return nil
        }) {
            monitors.append(local)
        }
        // Clicks in other apps (no permission needed for mouse monitors).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            guard let self, self.settings.focusDismiss else { return }
            self.finish(nil)
        }) {
            monitors.append(global)
        }
    }

    private func observeSkinWindow(_ window: NSWindow) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) {
            [weak self] _ in self?.followSkinWindow()
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
            [weak self] _ in self?.finish(nil)
        })
    }

    private func followSkinWindow() {
        guard let controller, let panel else { return }
        let font = InputTextPanelPrompt.font(settings)
        let frame = InputTextPanelPrompt.frame(settings, skinFrame: controller.window.frame,
                                               skinWidth: controller.skin.width,
                                               lineHeight: ceil(font.ascender - font.descender + font.leading))
        panel.setFrameOrigin(frame.origin)
    }

    // MARK: NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Ctrl+Enter inserts a line break (manual: InputLimit note); Enter submits.
            if NSApp.currentEvent?.modifierFlags.contains(.control) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                finish(field?.stringValue ?? "")
            }
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finish(nil)
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field, settings.inputNumber || settings.inputLimit > 0 else { return }
        let text = field.stringValue
        let clean = InputTextFilter.sanitize(text, number: settings.inputNumber, limit: settings.inputLimit)
        if clean != text { field.stringValue = clean }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        becameKey = true
    }

    func windowDidResignKey(_ notification: Notification) {
        // Focus moved elsewhere (another app, ⌘Tab): dismissed like a click outside the field.
        if becameKey && settings.focusDismiss { finish(nil) }
    }

    // MARK: Closing

    private func finish(_ result: String?) {
        let completion = self.completion
        self.completion = nil
        tearDown()
        completion?(result)
    }

    private func tearDown() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        becameKey = false
        guard let panel else { return }
        self.panel = nil
        field?.delegate = nil
        field = nil
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
        // Give the keyboard back to the skin window if it had it (Deskset never became the active app).
        if let previous = previousKeyWindow, previous.isVisible, previous.canBecomeKey { previous.makeKey() }
        previousKeyWindow = nil
    }
}
