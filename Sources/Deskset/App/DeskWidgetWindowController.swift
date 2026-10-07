import AppKit
import Darwin
import DeskLanguage
import DesksetCore
import DesksetDraw

/// Hosts an accepted, installed Desk widget document in an independent desktop window.
/// Reuses SkinPanel, LayerContentProvider, DeskProgramHost and WindowGeometry.
/// No pseudo-Skin or secondary expression evaluator is created.
final class DeskWidgetWindowController: NSObject, NSWindowDelegate {
    let source: DeskWidgetSourceState
    let instance: DeskWidgetInstanceState
    let directory: URL
    let program: WidgetProgram
    unowned let app: AppController
    let executor: SkinExecutor

    private(set) var window: SkinPanel
    let view: DeskWidgetView
    let content: LayerContentProvider
    let owner: DeskWidgetHostOwner

    private(set) var isStarted = false
    private(set) var isClosing = false
    private(set) var isClosed = false
    private(set) var sessionID = UUID()
    private var factsSequence = 0
    private var lastPresentedGeneration: UInt64 = 0
    private(set) var latestPresented: DeskProgramHost.Presented?
    private(set) var lastUnavailableMessage: String?
    private(set) var lastActionFailure: String?
    private let actionServices: DeskProgramActionServices
    private var lastIssuedClickSerial: UInt64 = 0
    private var lastConsumedClickSerial: UInt64 = 0
    private struct DestinationKey: Equatable {
        let colorSpace: CGColorSpace?
        let scale: CGFloat
        let appearance: String
        let windowID: ObjectIdentifier
    }
    private var currentDestinationKey: DestinationKey?
    private(set) var destinationEpoch: UInt64 = 0
    private(set) var lastAcceptedEpoch: UInt64 = 0
    private var closeWaiters: [() -> Void] = []
    private var deactivatesOnClose = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(source: DeskWidgetSourceState, instance: DeskWidgetInstanceState, directory: URL,
         program: WidgetProgram, prepared: DeskProgramResources.Prepared?,
         app: AppController, executor: SkinExecutor = MainSkinExecutor.shared,
         clock: SkinClock = .live, initialPosition: (x: Double, y: Double)? = nil,
         actionServices: DeskProgramActionServices = .live) {
        self.source = source
        self.instance = instance
        self.directory = directory
        self.program = program
        self.app = app
        self.executor = executor
        self.actionServices = actionServices

        let panel = SkinWindowController.makePanel()
        self.window = panel
        self.view = DeskWidgetView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        self.content = LayerContentProvider(in: view)
        panel.contentView = view

        let hostOwner = DeskWidgetHostOwner(program: program, executor: executor, provider: content,
                                            prepared: prepared, clock: clock, source: source.entry)
        self.owner = hostOwner

        super.init()

        view.controller = self
        panel.delegate = self

        let currentSession = sessionID
        let appearance = panel.effectiveAppearance
        let scale = panel.backingScaleFactor
        let initialFacts = currentFacts()
        let initialInput = try? DeskWidgetWindowController.makeInput(for: appearance, scale: scale)

        // Contract: Host lifecycle and callback setters MUST run solely on the executor owner.
        // Worker async loading avoids Main thread blocking; cancellation and failure safely clean up Prepared.
        // Main thread never touches host directly; messages are queued in strict FIFO.
        executor.async { [hostOwner] in
            guard let initialInput else {
                hostOwner.prepared?.removeCopies()
                hostOwner.prepared = nil
                DispatchQueue.main.async { [weak self] in
                    self?.handleUnavailable("invalidEnvironment", session: currentSession, epoch: initialFacts.panelGeneration)
                }
                return
            }
            hostOwner.start(input: initialInput, facts: initialFacts,
                            onPresent: { presented, epoch in
                                DispatchQueue.main.async { [weak self] in
                                    self?.handlePresented(presented, session: currentSession, epoch: epoch)
                                }
                            },
                            onUnavailable: { errorDesc, epoch in
                                DispatchQueue.main.async { [weak self] in
                                    self?.handleUnavailable(errorDesc, session: currentSession, epoch: epoch)
                                }
                            })
        }

        setupObservers()
        app.registerDeskWidgetWindow(self)
    }

    private func setupObservers() {
        let center = NotificationCenter.default
        let colors = center.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.publishFacts()
        }
        observers.append((center, colors))

        let occlusion = center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            self?.publishFacts()
        }
        observers.append((center, occlusion))

        for name in [NSLocale.currentLocaleDidChangeNotification, NSNotification.Name.NSSystemTimeZoneDidChange,
                     NSNotification.Name.NSSystemClockDidChange] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.publishFacts()
            }
            observers.append((center, token))
        }

        let powerToken = center.addObserver(forName: .desksetPowerSourceDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.isClosing, !self.isClosed else { return }
            let hostOwner = self.owner
            self.executor.async { [hostOwner] in
                hostOwner.notifyPowerChange()
            }
        }
        observers.append((center, powerToken))
    }

    static func makeInput(for appearance: NSAppearance, scale: CGFloat) throws -> DeskProgramHost.Input {
        let values = try MacAppearance.programValues(for: appearance)
        let env = AppSceneEnvironment(scale: Double(scale), appearance: values.appearance,
                                      appearanceName: appearance.name.rawValue).stamp
        return DeskProgramHost.Input(environment: env, colors: values.colors, locale: Locale.current)
    }

    /// Contract: Real window facts, no forced visible or synthetic profile, incrementing sequence.
    /// isOrderedIn follows window.isVisible (never occluded), so covered desktop clocks do not stop.
    func currentFacts() -> SkinWindowFacts {
        precondition(Thread.isMainThread)
        factsSequence += 1
        let isOrderedIn = window.isVisible
        let isVisible = window.isVisible && window.occlusionState.contains(.visible)
        let takesPointer = !window.ignoresMouseEvents && isVisible

        let key = DestinationKey(
            colorSpace: window.colorSpace?.cgColorSpace,
            scale: window.backingScaleFactor,
            appearance: window.effectiveAppearance.name.rawValue,
            windowID: ObjectIdentifier(window)
        )
        if currentDestinationKey != key {
            currentDestinationKey = key
            destinationEpoch &+= 1
            view.clearAccessibility()
        }

        return SkinWindowFacts(
            frame: window.frame,
            screen: window.screen.flatMap { NSScreen.screens.firstIndex(of: $0) },
            isVisible: isVisible,
            isOrderedIn: isOrderedIn,
            scale: window.backingScaleFactor,
            colorSpace: window.colorSpace?.cgColorSpace,
            appearance: window.effectiveAppearance.name.rawValue,
            takesPointer: takesPointer,
            sequence: factsSequence,
            panelGeneration: destinationEpoch
        )
    }

    func publishFacts() {
        precondition(Thread.isMainThread)
        guard !isClosing, !isClosed else { return }
        let facts = currentFacts()
        let appearance = window.effectiveAppearance
        let scale = window.backingScaleFactor
        guard let currentInput = try? DeskWidgetWindowController.makeInput(for: appearance, scale: scale) else { return }
        let hostOwner = owner
        executor.async { [hostOwner] in
            hostOwner.take(facts, input: currentInput)
        }
    }

    /// Contract: Main accepts didPresent by session/panel/generation; rejects stale queued frames when
    /// destination/profile/backing change; updates view.frame FIRST, then window frame.
    func handlePresented(_ presented: DeskProgramHost.Presented, session: UUID, epoch: UInt64) {
        precondition(Thread.isMainThread)
        guard !isClosing, !isClosed, session == sessionID else { return }

        // Must match current destination epoch
        guard epoch == destinationEpoch else { return }

        // 1. Generation check: within the same accepted epoch, reject older/same generations.
        // When transitioning to a new epoch (epoch > lastAcceptedEpoch), redraw with same generation is accepted.
        if epoch == lastAcceptedEpoch {
            guard presented.scene.generation > lastPresentedGeneration else { return }
        }

        // 2. Reject stale destination / backing scale / color space model
        guard presented.scale == window.backingScaleFactor,
              presented.size.width.isFinite, presented.size.height.isFinite,
              presented.size.width > 0, presented.size.height > 0,
              presented.scene.environment.appearance.name == window.effectiveAppearance.name.rawValue,
              let colorSpace = window.colorSpace?.cgColorSpace,
              colorSpace.model == .rgb else {
            publishFacts()
            return
        }

        latestPresented = presented
        lastPresentedGeneration = presented.scene.generation
        lastAcceptedEpoch = epoch
        lastUnavailableMessage = nil
        lastActionFailure = nil
        view.toolTip = nil
        view.setAccessibilityLabel(nil)

        // 1. First update view.frame
        view.frame = NSRect(origin: .zero, size: presented.size)

        // 2. Then update window frame
        let screens = WindowGeometry.currentScreens()
        let ph = WindowGeometry.primaryHeight(screens)
        let newFrame: CGRect

        if isStarted {
            let currentTopLeft = WindowGeometry.topLeft(of: window.frame, primaryHeight: ph)
            let unconstrained = WindowGeometry.frame(topLeftX: currentTopLeft.x, y: currentTopLeft.y, size: presented.size, primaryHeight: ph)
            newFrame = WindowGeometry.keptOnScreen(unconstrained, screens: screens)
        } else {
            if let x = instance.x, let y = instance.y {
                let unconstrained = WindowGeometry.frame(topLeftX: x, y: y, size: presented.size, primaryHeight: ph)
                newFrame = WindowGeometry.keptOnScreen(unconstrained, screens: screens)
            } else {
                let visible = screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
                let cascade = WindowGeometry.cascadeFrame(index: app.deskWidgetWindows.count, size: presented.size, visible: visible)
                newFrame = WindowGeometry.keptOnScreen(cascade, screens: screens)
            }
        }

        window.setFrame(newFrame, display: false)

        // Contract: Shown and active written only after first successful frame presentation accepted by Main
        if !isStarted {
            isStarted = true
            if app.presentsWindows {
                window.orderFront(nil)
            }
            let pos = WindowGeometry.topLeft(of: newFrame, primaryHeight: ph)
            app.state.updateDeskInstance(instance.id) {
                $0.active = true
                $0.x = pos.x
                $0.y = pos.y
            }
            // After being shown, publish real visible facts
            publishFacts()
        }
        view.refreshAccessibility()
    }

    /// Contract: Filter stale sessions, clear Main accepted presentation, localized visible UI feedback, keep active intent.
    func handleUnavailable(_ errorDesc: String, session: UUID, epoch: UInt64) {
        precondition(Thread.isMainThread)
        guard !isClosing, !isClosed, session == sessionID else { return }

        // Reject stale unavailable reports from mismatched destination epoch
        guard epoch == destinationEpoch else { return }

        latestPresented = nil
        view.clearAccessibility()
        let localizedMessage = localizedUnavailableDescription(errorDesc)
        lastUnavailableMessage = localizedMessage
        view.toolTip = localizedMessage
        view.setAccessibilityLabel(localizedMessage)
        Log.write("Desk widget unavailable (\(source.entry)): \(localizedMessage)", level: .warning)
        if !isStarted {
            app.alert(StudioText[.deskWidgetUnavailable], localizedMessage, style: .warning)
        }
    }

    private func localizedUnavailableDescription(_ raw: String) -> String {
        if raw == String(describing: ProgramRuntimeError.missingActionString) {
            return StudioText[.deskActionMissingValue]
        }
        if raw.contains("resources") || raw.contains("resourceLimit") {
            return StudioText[.deskWidgetPreparationFailed]
        }
        if raw.contains("invalidEnvironment") {
            return StudioText[.deskPreviewUnavailable]
        }
        return StudioText[.deskWidgetUnavailable]
    }

    /// The exact source picture was accepted before Main issues this release. Ordinary newer frames are legal.
    func issueClickToken() -> DeskWidgetClickToken? {
        precondition(Thread.isMainThread)
        guard !isClosing, !isClosed, let latestPresented, lastAcceptedEpoch == destinationEpoch else { return nil }
        let next = lastIssuedClickSerial.addingReportingOverflow(1)
        guard !next.overflow else { return nil }
        lastIssuedClickSerial = next.partialValue
        return DeskWidgetClickToken(session: sessionID, epoch: destinationEpoch,
                                    sourceGeneration: latestPresented.scene.generation, serial: next.partialValue)
    }

    func sendPrimaryRelease(at point: SkinPoint) {
        guard let token = issueClickToken() else { return }
        enqueuePrimaryRelease(at: point, token: token, pressBeforeRelease: false)
    }

    private func enqueuePrimaryRelease(at point: SkinPoint, token: DeskWidgetClickToken, pressBeforeRelease: Bool) {
        let hostOwner = owner
        executor.async { [hostOwner] in
            if pressBeforeRelease {
                hostOwner.primaryPress(at: point, expectedGeneration: token.sourceGeneration, epoch: token.epoch)
            }
            hostOwner.primaryRelease(at: point, token: token) { returnedToken, effects in
                DispatchQueue.main.async { [weak self] in
                    self?.handleEffects(effects, token: returnedToken, issuedToken: token)
                }
            }
        }
    }

    /// AX Press is explicit user activation of the exact accepted text element. The owner still qualifies
    /// pointer eligibility, current presentation, hit identity and destination before resolving any effects.
    fileprivate func activateAccessibility(_ child: DeskWidgetTextAccessibilityElement) -> Bool {
        guard Thread.isMainThread, let presented = view.presentation(for: child),
              let element = presented.scene.elements.first(where: { $0.id == child.id }),
              element.visibility == .visible else { return false }
        let center = SkinPoint(x: element.frame.x + element.frame.width / 2,
                               y: element.frame.y + element.frame.height / 2)
        guard presented.scene.hitMap.entry(at: center.x, center.y, handling: .leftUp, images: nil)?.elementID == child.id else {
            return false
        }
        // The owner adds the captured viewport origin once, as it does for real mouse coordinates.
        let point = SkinPoint(x: center.x - presented.origin.x, y: center.y - presented.origin.y)
        guard point.x.isFinite, point.y.isFinite, let token = issueClickToken(),
              token.session == child.session, token.epoch == child.epoch,
              token.sourceGeneration == child.generation else { return false }
        enqueuePrimaryRelease(at: point, token: token, pressBeforeRelease: true)
        return true
    }

    /// A batch uses its original issued token, not the latest CPU/clock frame's generation.
    /// Owner and Main queues are FIFO; consume before calling services, including a service that reenters Main.
    func handleEffects(_ effects: [ProgramEffect], token: DeskWidgetClickToken, issuedToken: DeskWidgetClickToken) {
        precondition(Thread.isMainThread)
        guard !isClosing, !isClosed, token == issuedToken, token.session == sessionID,
              token.epoch == destinationEpoch, token.epoch == lastAcceptedEpoch,
              token.sourceGeneration <= lastPresentedGeneration,
              token.serial > lastConsumedClickSerial, token.serial <= lastIssuedClickSerial else { return }
        lastConsumedClickSerial = token.serial
        lastActionFailure = nil
        for effect in effects {
            guard !isClosing, !isClosed, token.session == sessionID, token.epoch == destinationEpoch else { break }
            if let message = actionServices.perform(effect, directory: directory) {
                lastActionFailure = message
                view.toolTip = message
                view.setAccessibilityLabel(message)
                Log.write(message, level: .warning, source: source.entry)
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowDidChangeScreenProfile(_ notification: Notification) {
        publishFacts()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        publishFacts()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        publishFacts()
    }

    func savePosition() {
        precondition(Thread.isMainThread)
        guard !isClosing, !isClosed else { return }
        let screens = WindowGeometry.currentScreens()
        let ph = WindowGeometry.primaryHeight(screens)
        let p = WindowGeometry.topLeft(of: window.frame, primaryHeight: ph)
        app.state.updateDeskInstance(instance.id) {
            $0.x = p.x
            $0.y = p.y
        }
    }

    func deactivateAndClose() {
        app.deactivateDeskWidget(instanceID: instance.id)
    }

    /// Contract: Main invalidates -> owner FIFO close -> Main ack -> provider/window teardown.
    /// Repeated close calls wait for the actual ACK. Shared worker is never stopped prematurely.
    func close(deactivate: Bool, completion: (() -> Void)? = nil) {
        precondition(Thread.isMainThread)
        if deactivate {
            deactivatesOnClose = true
        }
        if isClosed {
            completion?()
            return
        }
        if let completion {
            closeWaiters.append(completion)
        }
        guard !isClosing else {
            return
        }
        isClosing = true
        sessionID = UUID() // invalidate any pending in-flight didPresent callbacks
        latestPresented = nil
        view.clearAccessibility()

        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()

        let hostOwner = owner
        executor.async { [hostOwner] in
            hostOwner.close {
                DispatchQueue.main.async { [self] in
                    self.isClosed = true
                    self.content.teardown()
                    self.window.orderOut(nil)
                    self.window.close()
                    if self.deactivatesOnClose {
                        self.app.state.updateDeskInstance(self.instance.id) { $0.active = false }
                    }
                    self.app.deskWidgetWindowDidClose(self)
                    let waiters = self.closeWaiters
                    self.closeWaiters.removeAll()
                    for waiter in waiters {
                        waiter()
                    }
                }
            }
        }
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }
}

/// Owns the DeskProgramHost on its dedicated executor thread.
/// All creation, take, click, and close operations run strictly on executor.
final class DeskWidgetHostOwner {
    let program: WidgetProgram
    let executor: SkinExecutor
    let provider: ContentProvider
    let clock: SkinClock
    let source: String
    var prepared: DeskProgramResources.Prepared?
    private(set) var host: DeskProgramHost?
    private(set) var isClosed = false

    private(set) var currentEpoch: UInt64 = 0

    init(program: WidgetProgram, executor: SkinExecutor, provider: ContentProvider,
         prepared: DeskProgramResources.Prepared?, clock: SkinClock, source: String) {
        self.program = program
        self.executor = executor
        self.provider = provider
        self.prepared = prepared
        self.clock = clock
        self.source = source
    }

    func start(input: DeskProgramHost.Input, facts: SkinWindowFacts,
               onPresent: @escaping (DeskProgramHost.Presented, UInt64) -> Void,
               onUnavailable: @escaping (String, UInt64) -> Void) {
        precondition(executor.isCurrent)
        guard !isClosed else {
            prepared?.removeCopies()
            prepared = nil
            return
        }
        currentEpoch = facts.panelGeneration
        do {
            let readyHost = try DeskProgramHost(program: program, executor: executor, provider: provider,
                                                input: input, prepared: prepared, clock: clock,
                                                source: source)
            guard !isClosed else {
                readyHost.close()
                return
            }
            readyHost.didPresent = { [weak self] presented in
                guard let self else { return }
                onPresent(presented, self.currentEpoch)
            }
            readyHost.didBecomeUnavailable = { [weak self] errorDesc in
                guard let self else { return }
                onUnavailable(errorDesc, self.currentEpoch)
            }
            self.host = readyHost
            readyHost.take(facts, input: input)
            readyHost.start()
            readyHost.drawFirstFrame()
        } catch {
            prepared?.removeCopies()
            prepared = nil
            onUnavailable(String(describing: error), currentEpoch)
        }
    }

    func take(_ facts: SkinWindowFacts, input: DeskProgramHost.Input) {
        precondition(executor.isCurrent)
        guard !isClosed else { return }
        currentEpoch = facts.panelGeneration
        host?.take(facts, input: input)
        host?.drawFirstFrame()
    }

    func primaryPress(at point: SkinPoint, expectedGeneration: UInt64, epoch: UInt64? = nil) {
        precondition(executor.isCurrent)
        guard !isClosed, let host, host.scene?.generation == expectedGeneration else { return }
        if let epoch, epoch != currentEpoch { return }
        host.primaryPress(at: point)
    }

    func primaryRelease(at point: SkinPoint?, expectedGeneration: UInt64?) {
        precondition(executor.isCurrent)
        guard !isClosed, let host else { return }
        if let expectedGeneration, host.scene?.generation != expectedGeneration { return }
        host.primaryRelease(at: point)
    }

    func primaryRelease(at point: SkinPoint, token: DeskWidgetClickToken,
                        onEffects: (DeskWidgetClickToken, [ProgramEffect]) -> Void) {
        precondition(executor.isCurrent)
        guard !isClosed, let host else { return }
        guard token.epoch == currentEpoch, token.sourceGeneration == host.scene?.generation,
              token.sourceGeneration == host.presented?.scene.generation else {
            host.primaryRelease(at: nil)
            return
        }
        if let effects = host.primaryRelease(at: point), !effects.isEmpty { onEffects(token, effects) }
    }

    func notifyPowerChange() {
        precondition(executor.isCurrent)
        guard !isClosed, let host else { return }
        host.notifyPowerChange()
    }

    func wake() {
        precondition(executor.isCurrent)
        guard !isClosed, let host else { return }
        host.wake()
    }

    func close(onClosed: @escaping () -> Void) {
        precondition(executor.isCurrent)
        guard !isClosed else {
            onClosed()
            return
        }
        isClosed = true
        host?.close()
        host = nil
        prepared?.removeCopies()
        prepared = nil
        onClosed()
    }
}

/// The view displaying Desk widget content and routing mouse input and dragging.
final class DeskWidgetView: NSView {
    weak var controller: DeskWidgetWindowController?
    private(set) var accessibilityParts: [DeskWidgetTextAccessibilityElement] = []
    private var dragStart: NSPoint?
    private var windowOrigin: NSPoint?
    private var dragged = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityChildren() -> [Any]? { accessibilityParts }

    fileprivate func refreshAccessibility() {
        guard let controller, !controller.isClosing, !controller.isClosed,
              controller.lastAcceptedEpoch == controller.destinationEpoch,
              let presented = controller.latestPresented else { clearAccessibility(); return }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(controller.program.name)
        let clickable = Set(presented.scene.hitMap.entries.compactMap(\.elementID))
        var parts: [DeskWidgetTextAccessibilityElement] = []
        for element in presented.scene.elements where element.visibility == .visible && clickable.contains(element.id) {
            // ProgramRuntime stores a Text's sole projected TextDraw directly on the same SceneElement ID.
            guard element.kind == .string, element.items.count == 1,
                  case .text(let text) = element.items[0] else { continue }
            parts.append(DeskWidgetTextAccessibilityElement(id: element.id, text: text.text,
                session: controller.sessionID, epoch: controller.lastAcceptedEpoch,
                generation: presented.scene.generation, owner: self))
        }
        replaceAccessibility(parts)
    }

    fileprivate func clearAccessibility() { replaceAccessibility([]) }

    private func replaceAccessibility(_ parts: [DeskWidgetTextAccessibilityElement]) {
        let changed = !accessibilityParts.isEmpty || !parts.isEmpty
        accessibilityParts = parts
        guard changed, controller?.app.presentsWindows == true else { return }
        // Notify clients about the replaced tree; do not announce every changing CPU/text value aloud.
        var affected: [Any] = [self]
        affected.append(contentsOf: parts)
        NSAccessibility.post(element: self, notification: .layoutChanged, userInfo: [.uiElements: affected])
    }

    fileprivate func presentation(for child: DeskWidgetTextAccessibilityElement) -> DeskProgramHost.Presented? {
        guard let controller, !controller.isClosing, !controller.isClosed,
              child.owner === self, accessibilityParts.contains(where: { $0 === child }),
              child.session == controller.sessionID, child.epoch == controller.destinationEpoch,
              child.epoch == controller.lastAcceptedEpoch,
              let presented = controller.latestPresented, presented.scene.generation == child.generation else { return nil }
        return presented
    }

    fileprivate func screenFrame(for child: DeskWidgetTextAccessibilityElement) -> NSRect {
        guard let presented = presentation(for: child),
              let element = presented.scene.elements.first(where: { $0.id == child.id }) else { return .zero }
        let frame = NSRect(x: element.frame.x - presented.origin.x, y: element.frame.y - presented.origin.y,
                           width: element.frame.width, height: element.frame.height)
        return window == nil ? frame : NSAccessibility.screenRect(fromView: self, rect: frame)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        controller?.publishFacts()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        controller?.publishFacts()
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller, !controller.isClosing, !controller.isClosed else { return }
        if event.modifierFlags.contains(.control) {
            showContextMenu(with: event)
            return
        }
        dragStart = NSEvent.mouseLocation
        windowOrigin = window?.frame.origin
        dragged = false

        let local = convert(event.locationInWindow, from: nil)
        let pt = SkinPoint(x: Double(local.x), y: Double(local.y))

        // Contract: Carry Main's current accepted presentation; origin added only once inside owner.
        if let presented = controller.latestPresented {
            let gen = presented.scene.generation
            let epoch = controller.lastAcceptedEpoch
            let hostOwner = controller.owner
            controller.executor.async { [hostOwner] in
                hostOwner.primaryPress(at: pt, expectedGeneration: gen, epoch: epoch)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, !controller.isClosing, !controller.isClosed,
              let start = dragStart, let origin = windowOrigin, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if !dragged && hypot(dx, dy) < 3 { return }
        if !dragged {
            dragged = true
            let hostOwner = controller.owner
            controller.executor.async { [hostOwner] in
                hostOwner.primaryRelease(at: nil, expectedGeneration: nil)
            }
        }
        var frame = window.frame
        frame.origin = NSPoint(x: origin.x + dx, y: origin.y + dy)
        let screens = WindowGeometry.currentScreens()
        frame = WindowGeometry.keptOnScreen(frame, screens: screens)
        window.setFrameOrigin(frame.origin)
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller, !controller.isClosing, !controller.isClosed else {
            dragStart = nil
            dragged = false
            return
        }
        if dragged {
            dragged = false
            dragStart = nil
            controller.savePosition()
        } else {
            dragStart = nil
            let local = convert(event.locationInWindow, from: nil)
            let pt = SkinPoint(x: Double(local.x), y: Double(local.y))
            controller.sendPrimaryRelease(at: pt)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(with: event)
    }

    private func showContextMenu(with event: NSEvent) {
        guard let controller, !controller.isClosing, !controller.isClosed else { return }
        let menu = NSMenu(title: "Desk Widget")
        let removeItem = NSMenuItem(title: StudioText[.removeWidgetFromDesktop],
                                    action: #selector(removeWidgetFromDesktop(_:)), keyEquivalent: "")
        removeItem.target = self
        menu.addItem(removeItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func removeWidgetFromDesktop(_ sender: Any?) {
        controller?.deactivateAndClose()
    }
}

/// A single accepted clickable Text. Held children cannot adopt a newer scene's identity or generation.
final class DeskWidgetTextAccessibilityElement: NSAccessibilityElement {
    let id: ElementID
    let session: UUID
    let epoch: UInt64
    let generation: UInt64
    weak var owner: DeskWidgetView?
    private var pressed = false

    init(id: ElementID, text: String, session: UUID, epoch: UInt64, generation: UInt64, owner: DeskWidgetView) {
        self.id = id
        self.session = session
        self.epoch = epoch
        self.generation = generation
        self.owner = owner
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityParent() -> Any? { owner }
    override func accessibilityFrame() -> NSRect { owner?.screenFrame(for: self) ?? .zero }

    override func accessibilityPerformPress() -> Bool {
        guard Thread.isMainThread, !pressed, let controller = owner?.controller,
              controller.activateAccessibility(self) else { return false }
        pressed = true
        return true
    }
}
