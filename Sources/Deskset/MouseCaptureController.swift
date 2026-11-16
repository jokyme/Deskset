import AppKit
import DesksetCore

/// Event monitor abstraction for `!Mouse:StartCapture` so capture tests run without real hardware input.
protocol MouseCaptureMonitorSource: AnyObject {
    func start(handler: @escaping (NSEvent, _ local: Bool) -> NSEvent?)
    func stop()
}

/// Default AppKit event monitor watching local and global key/mouse events during capture.
final class AppKitMouseCaptureMonitorSource: MouseCaptureMonitorSource {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let mask: NSEvent.EventTypeMask = [
        .keyDown,
        .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp,
    ]

    func start(handler: @escaping (NSEvent, _ local: Bool) -> NSEvent?) {
        stop()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handler(event, true)
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            _ = handler(event, false)
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    deinit {
        stop()
    }
}

/// Manages the global desktop overlay and click interception for `Measure=Mouse` `!Mouse:StartCapture` /
/// `!Mouse:StopCapture`. Runs strictly on the main thread.
final class MouseCaptureController {
    struct Session {
        weak var controller: SkinWindowController?
        let request: MouseCaptureRequest
    }

    private unowned let app: AppController
    private var session: Session?
    private var panels: [CaptureOverlayPanel] = []
    /// Bitmask of mouse buttons already held when `StartCapture` began; all must release before a click captures.
    private var pendingHeldButtons = 0
    private var monitorSource: MouseCaptureMonitorSource = AppKitMouseCaptureMonitorSource()

    /// Screen list provider (replaceable in headless self-tests for multi-monitor coordinate checks).
    var screensProvider: () -> [WindowGeometry.Screen] = { WindowGeometry.currentScreens() }
    /// Currently pressed mouse button bitmask (replaceable in tests).
    var pressedButtonsProvider: () -> Int = { NSEvent.pressedMouseButtons }

    var activeSession: MouseCaptureRequest? { session?.request }
    var activeOverlayPanels: [NSPanel] { panels }
    var isWaitingForInitialRelease: Bool { pendingHeldButtons != 0 }

    init(app: AppController) {
        self.app = app
    }

    /// Replaces the monitor source (used by self-tests to avoid registering real AppKit global monitors).
    func use(_ source: MouseCaptureMonitorSource) {
        monitorSource.stop()
        monitorSource = source
        if session != nil {
            startMonitor()
        }
    }

    /// Starts or replaces capture for `controller` with `request`.
    func update(for controller: SkinWindowController, request: MouseCaptureRequest) {
        if let previous = session?.controller, previous !== controller {
            previous.runtime.send(.cancelMouseCapture(measureName: nil))
        }
        teardownOverlaysAndMonitor()
        session = Session(controller: controller, request: request)
        pendingHeldButtons = pressedButtonsProvider()
        buildOverlayPanels(for: controller, request: request)
        startMonitor()
    }

    /// Clears capture only when `controller` owns the active capture session.
    func clear(for controller: SkinWindowController) {
        guard let active = session, active.controller == nil || active.controller === controller else { return }
        teardownOverlaysAndMonitor()
        session = nil
        pendingHeldButtons = 0
    }

    /// Cancels any active capture session, optionally informing its skin without triggering a mouse-up action.
    func cancel(notifySkin: Bool) {
        guard let active = session else { return }
        let owner = active.controller
        let measureName = active.request.measureName
        teardownOverlaysAndMonitor()
        session = nil
        pendingHeldButtons = 0
        if notifySkin {
            owner?.runtime.send(.cancelMouseCapture(measureName: measureName))
        }
    }

    /// Handles a mouse event received by an overlay panel or monitor, returns whether it was consumed.
    @discardableResult
    func handleMonitorEvent(_ event: NSEvent, local: Bool) -> NSEvent? {
        guard session != nil else { return event }
        switch event.type {
        case .keyDown where event.keyCode == 53:
            cancel(notifySkin: true)
            return local ? nil : event
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Consume button-down events hitting our overlay windows so nothing underneath activates.
            if local, let w = event.window, panels.contains(where: { $0 === w }) {
                return nil
            }
            return event
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let (button, mask) = buttonAndMask(for: event) else { return event }
            if pendingHeldButtons != 0 {
                pendingHeldButtons &= ~mask
                return event
            }
            let screenPoint = Self.screenPoint(for: event)
            completeCapture(button: button, screenPoint: screenPoint)
            return local ? nil : event
        default:
            return event
        }
    }

    fileprivate func overlayMouseUp(event: NSEvent) {
        guard session != nil, let (button, mask) = buttonAndMask(for: event) else { return }
        if pendingHeldButtons != 0 {
            pendingHeldButtons &= ~mask
            return
        }
        completeCapture(button: button, screenPoint: Self.screenPoint(for: event))
    }

    fileprivate func overlayEscapePressed() {
        cancel(notifySkin: true)
    }

    // MARK: Private

    private func startMonitor() {
        monitorSource.start { [weak self] event, local in
            guard let self else { return event }
            return self.handleMonitorEvent(event, local: local)
        }
    }

    private func completeCapture(button: MouseButton, screenPoint: NSPoint) {
        guard let active = session, let controller = active.controller, !controller.isStopped else {
            cancel(notifySkin: false)
            return
        }
        let measureName = active.request.measureName
        let screens = screensProvider()
        let primaryHeight = Double(WindowGeometry.primaryHeight(screens))
        let screenX = Double(screenPoint.x)
        let screenY = primaryHeight - Double(screenPoint.y)
        let skinPt = controller.skinPoint(fromScreen: screenPoint)

        teardownOverlaysAndMonitor()
        session = nil
        pendingHeldButtons = 0

        controller.runtime.send(.completeMouseCapture(measureName: measureName,
                                                      button: button,
                                                      skinX: skinPt.x,
                                                      skinY: skinPt.y,
                                                      screenX: screenX,
                                                      screenY: screenY))
    }

    private func buildOverlayPanels(for controller: SkinWindowController, request: MouseCaptureRequest) {
        let screens = screensProvider()
        guard !screens.isEmpty else { return }
        let cursor = SkinView.cursor(named: request.overlayCursorName, in: controller)
        let color = Self.overlayNSColor(request.overlayColor)
        for screen in screens {
            let panel = CaptureOverlayPanel(frame: screen.frame,
                                            color: color,
                                            cursor: cursor,
                                            captureController: self)
            panels.append(panel)
            if app.presentsWindows {
                panel.orderFrontRegardless()
            }
        }
        if app.presentsWindows {
            cursor.set()
        }
    }

    private func teardownOverlaysAndMonitor() {
        monitorSource.stop()
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
    }

    private static func overlayNSColor(_ rgba: RGBA) -> NSColor {
        let alpha = max(CGFloat(rgba.a) / 255.0, 1.0 / 255.0)
        return NSColor(srgbRed: CGFloat(rgba.r) / 255.0,
                       green: CGFloat(rgba.g) / 255.0,
                       blue: CGFloat(rgba.b) / 255.0,
                       alpha: alpha)
    }

    private static func screenPoint(for event: NSEvent) -> NSPoint {
        if let w = event.window {
            return w.convertPoint(toScreen: event.locationInWindow)
        }
        return event.locationInWindow
    }

    private func buttonAndMask(for event: NSEvent) -> (MouseButton, Int)? {
        switch event.type {
        case .leftMouseUp, .leftMouseDown:
            return (.left, 1 << 0)
        case .rightMouseUp, .rightMouseDown:
            return (.right, 1 << 1)
        case .otherMouseUp, .otherMouseDown:
            switch event.buttonNumber {
            case 2: return (.middle, 1 << 2)
            case 3: return (.x1, 1 << 3)
            case 4: return (.x2, 1 << 4)
            default: return nil
            }
        default:
            return nil
        }
    }
}

private final class CaptureOverlayPanel: NSPanel {
    init(frame: CGRect, color: NSColor, cursor: NSCursor, captureController: MouseCaptureController) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isReleasedWhenClosed = false
        contentView = CaptureOverlayView(frame: NSRect(origin: .zero, size: frame.size),
                                         fillColor: color,
                                         cursor: cursor,
                                         captureController: captureController)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CaptureOverlayView: NSView {
    private let fillColor: NSColor
    private let captureCursor: NSCursor
    private weak var captureController: MouseCaptureController?

    init(frame: NSRect, fillColor: NSColor, cursor: NSCursor, captureController: MouseCaptureController) {
        self.fillColor = fillColor
        self.captureCursor = cursor
        self.captureController = captureController
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: captureCursor)
    }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        dirtyRect.fill()
    }

    override func mouseEntered(with event: NSEvent) {
        captureCursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        captureCursor.set()
    }

    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        captureController?.overlayMouseUp(event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        captureController?.overlayMouseUp(event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        captureController?.overlayMouseUp(event: event)
    }

    override func cancelOperation(_ sender: Any?) {
        captureController?.overlayEscapePressed()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            captureController?.overlayEscapePressed()
        } else {
            super.keyDown(with: event)
        }
    }
}
