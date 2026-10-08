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
    private let preferredLanguages: () -> [String]
    private let dateLocale: () -> Locale
    private let loadedLanguages: [String]
    let displayName: String

    private(set) var window: SkinPanel
    let view: DeskWidgetView
    let content: LayerContentProvider
    let nativeComposition: SkinNativeCompositionView
    private let supportsSystemGlass: Bool
    let owner: DeskWidgetHostOwner

    private(set) var isStarted = false
    private(set) var isClosing = false
    private(set) var isClosed = false
    private var deactivationRequested = false
    private(set) var sessionID: UUID
    private var factsSequence = 0
    private var lastPresentedGeneration: UInt64 = 0
    private(set) var lastPresentationSerial: UInt64 = 0
    private var lastPresentationLifecycle: UInt64 = 0
    private(set) var latestPresented: DeskProgramHost.Presented?
    private(set) var lastUnavailableMessage: String?
    private(set) var lastActionFailure: String?
    private let actionServices: DeskProgramActionServices
    private var lastIssuedClickSerial: UInt64 = 0
    private var lastConsumedClickSerial: UInt64 = 0
    private var menuSession: DeskProgramMenuSession?
    private(set) var optionsSnapshot: ProgramOptionsSnapshot?
    private(set) var optionsSession: DeskProgramOptionsSession?
    private let optionDefaults: ProgramOptionsInput?
    private let optionsWereRestored: Bool
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
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(source: DeskWidgetSourceState, instance: DeskWidgetInstanceState, directory: URL,
         program: WidgetProgram, prepared: DeskProgramResources.Prepared?,
         app: AppController, executor: SkinExecutor = MainSkinExecutor.shared,
         clock: SkinClock = .live, initialPosition: (x: Double, y: Double)? = nil,
         actionServices: DeskProgramActionServices = .live,
         tooltipExecutor: SkinExecutor = MainSkinExecutor.shared,
         preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages },
         dateLocale: @escaping () -> Locale = { Locale.current },
         system: SystemDataSource = SystemMonitor.shared) {
        let initialLanguages = preferredLanguages(), initialLocale = dateLocale()
        let localization = DeskProgramLocalization(program: program, preferredLanguages: initialLanguages, locale: initialLocale)
        self.source = source
        self.instance = instance
        self.directory = directory
        self.program = program
        self.app = app
        self.executor = executor
        self.actionServices = actionServices
        self.preferredLanguages = preferredLanguages
        self.dateLocale = dateLocale
        self.loadedLanguages = initialLanguages
        self.displayName = localization.name
        let liveOptions = app.deskOptionDrafts[instance.id].flatMap { $0.sourceID == source.id ? $0.values : nil }
        let restoredOptions = try? DeskProgramOptionStore.restore(instance.optionValues, for: program, live: liveOptions)
        self.optionDefaults = restoredOptions?.defaults
        self.optionsWereRestored = restoredOptions?.restoredNames.isEmpty == false
        let currentSession = UUID()
        self.sessionID = currentSession

        let panel = SkinWindowController.makePanel()
        panel.title = localization.name
        self.window = panel
        self.view = DeskWidgetView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        self.content = LayerContentProvider(in: view)
        let systemGlass = SkinGlassViews.usesSystemGlass
        self.supportsSystemGlass = systemGlass
        self.nativeComposition = SkinNativeCompositionView(systemGlass: systemGlass)
        view.addSubview(nativeComposition)
        panel.contentView = view

        let hostOwner = DeskWidgetHostOwner(program: program, executor: executor, provider: content,
                                            prepared: prepared, clock: clock, source: source.entry, session: currentSession,
                                            options: restoredOptions?.input, system: system)
        self.owner = hostOwner

        super.init()

        view.controller = self
        view.programTooltips = DeskProgramTooltips(view: view, executor: tooltipExecutor,
            pointerLocation: { [weak view] in view?.pointerLocation() ?? .zero },
            presentsWindows: app.presentsWindows,
            targetAt: { [weak self] in self?.tooltipTarget(at: $0) })
        view.programMenus = DeskProgramMenus(view: view, presentsWindows: app.presentsWindows)
        panel.delegate = self

        let appearance = panel.effectiveAppearance
        let scale = panel.backingScaleFactor
        let initialFacts = currentFacts()
        let initialInput = try? DeskWidgetWindowController.makeInput(for: appearance, scale: scale,
            program: program, preferredLanguages: initialLanguages, locale: initialLocale)

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
            hostOwner.start(input: initialInput, facts: initialFacts, supportsSystemGlass: systemGlass,
                            onDelivery: { [weak hostOwner] request in
                                guard let hostOwner else { return }
                                DispatchQueue.main.async { [weak self] in
                                    self?.handleBitmapRequest(request, session: currentSession)
                                    // A deallocated window still rejects and acknowledges its outstanding request.
                                    switch request {
                                    case .frame(let frame): frame.finishOnMain(accepted: false)
                                    case .clear(let clear): clear.finishOnMain(accepted: false)
                                    }
                                    hostOwner.executor.async { [hostOwner] in hostOwner.finishBitmapRequest(request) }
                                }
                            },
                            onUnavailable: { errorDesc, epoch, invalidation in
                                DispatchQueue.main.async { [weak self] in
                                    self?.handleUnavailable(errorDesc, session: currentSession, epoch: epoch,
                                                            invalidation: invalidation)
                                }
                            }, onRejected: { _, epoch, generation in
                                DispatchQueue.main.async { [weak self] in
                                    self?.handleRejectedProjection(session: currentSession, epoch: epoch, generation: generation)
                                }
                            }, onOptions: { snapshot in
                                DispatchQueue.main.async { [weak self] in
                                    guard let self, self.sessionID == currentSession, !self.isClosing, !self.isClosed else { return }
                                    self.receiveOptions(snapshot)
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
                if name == NSLocale.currentLocaleDidChangeNotification { self?.refreshDateInput() }
                else { self?.publishFacts(refreshTime: true) }
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

        let detailsToken = center.addObserver(forName: .desksetBatteryDetailsDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.isClosing, !self.isClosed else { return }
            let hostOwner = self.owner
            self.executor.async { [hostOwner] in
                hostOwner.notifyBatteryDetailsReady()
            }
        }
        observers.append((center, detailsToken))
    }

    static func makeInput(for appearance: NSAppearance, scale: CGFloat, program: WidgetProgram? = nil,
                          preferredLanguages: [String] = [], locale: Locale = .current) throws -> DeskProgramHost.Input {
        let values = try MacAppearance.programValues(for: appearance)
        let env = AppSceneEnvironment(scale: Double(scale), appearance: values.appearance,
                                      appearanceName: appearance.name.rawValue).stamp
        let localization = program.map { DeskProgramLocalization(program: $0, preferredLanguages: preferredLanguages, locale: locale) }
        return DeskProgramHost.Input(environment: env, colors: values.colors, locale: localization?.locale ?? locale,
                                     language: localization?.language)
    }

    /// A language change reloads the installed source through the usual admission/resource path. The old session
    /// closes before the replacement starts; changes to region or calendar alone preserve its session variables.
    func refreshDateInput() {
        precondition(Thread.isMainThread)
        guard !isClosing, !isClosed else { return }
        guard preferredLanguages() != loadedLanguages else { publishFacts(refreshTime: true); return }
        let app = app, instanceID = instance.id, sourceID = source.id, entry = source.entry
        let languages = preferredLanguages, locale = dateLocale
        close(deactivate: false) { [weak self, weak app] in
            guard let self, let app, !app.isTerminating, !self.deactivationRequested,
                  let current = app.state.deskInstance(instanceID), current.sourceID == sourceID,
                  current.active || !self.isStarted else { return }
            if app.state.deskSource(sourceID)?.packageID != nil {
                app.activateDeskWidgetAsync(instanceID: instanceID, preferredLanguages: languages, dateLocale: locale,
                    requiresActive: self.isStarted) { result in
                    if case .failure(let error) = result, (error as? DeskWidgetActivation.Failure) != .cancelled {
                        Log.write(StudioText[.deskWidgetUnavailable] + ": " + String(describing: error),
                                  level: .warning, source: entry)
                    }
                }
                return
            }
            do {
                try app.activateDeskWidget(instanceID: instanceID, preferredLanguages: languages, dateLocale: locale)
            } catch {
                Log.write(StudioText[.deskWidgetUnavailable] + ": " + String(describing: error),
                          level: .warning, source: entry)
            }
        }
    }

    private func receiveOptions(_ snapshot: ProgramOptionsSnapshot) {
        guard snapshot.revision >= (optionsSnapshot?.revision ?? 0) else { return }
        optionsSnapshot = snapshot
        app.deskOptionDrafts[instance.id] = .init(sourceID: source.id, values: snapshot.values)
        optionsSession?.receive(snapshot)
        // Actions outside an open panel have no later panel-close event. Save accepted changes immediately;
        // a failed write keeps the live values and opens the same panel with a visible retry path.
        if snapshot.revision > 0, optionsSession == nil {
            do { try saveOptions(snapshot.values) }
            catch { showOptions(); optionsSession?.panel.setFeedback(StudioText[.deskOptionsSaveFailed]) }
        }
    }

    private func saveOptions(_ input: ProgramOptionsInput) throws {
        let records = try DeskProgramOptionStore.encode(input)
        try app.state.saveDeskOptions(instance.id, sourceID: source.id, values: records)
    }

    func showOptions() {
        precondition(Thread.isMainThread)
        guard !isClosing, !isClosed, !program.options.isEmpty, let defaults = optionDefaults else { return }
        if let optionsSession { optionsSession.panel.present(relativeTo: window.frame); return }
        guard let snapshot = optionsSnapshot else {
            let owner = owner, session = sessionID
            executor.async { [weak self, owner] in
                guard let snapshot = try? owner.optionsSnapshot() else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sessionID == session, !self.isClosing, !self.isClosed else { return }
                    self.optionsSnapshot = snapshot
                    self.showOptions()
                }
            }
            return
        }
        let session = sessionID
        let options = DeskProgramOptionsSession(snapshot: snapshot, defaults: defaults, isPreview: false,
            presentsWindows: app.presentsWindows, update: { [weak self] input, revision, completion in
                guard let self, self.sessionID == session, !self.isClosing, !self.isClosed else {
                    completion(.failure(DeskProgramHost.Failure.optionsCancelled)); return
                }
                let owner = self.owner
                self.executor.async { [owner] in
                    owner.updateOptions(input, expectedRevision: revision) { result in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.sessionID == session, !self.isClosing, !self.isClosed else {
                                completion(.failure(DeskProgramHost.Failure.optionsCancelled)); return
                            }
                            if case .success(let snapshot) = result { self.receiveOptions(snapshot) }
                            completion(result)
                        }
                    }
                }
            }, save: { [weak self] input in
                guard let self, self.sessionID == session, !self.isClosing, !self.isClosed else {
                    throw DeskProgramHost.Failure.optionsCancelled
                }
                try self.saveOptions(input)
            }, moreStyles: { [weak self] in
                guard let self, self.sessionID == session, !self.isClosing else { return }
                let member = URL(fileURLWithPath: self.source.entry).lastPathComponent
                if self.source.packageID != nil {
                    self.app.deskPackages.open(root: self.directory, member: DeskFileID(path: member)) { [weak self] result in
                        guard let self, self.sessionID == session, !self.isClosing, !self.isClosed,
                              !self.app.isTerminating, case .failure(let error) = result,
                              let message = DeskPackageFlow.message(for: error) else { return }
                        self.app.alert(StudioText[.deskOpenPackageFolder], message)
                    }
                } else {
                    self.app.showCodeFile(self.directory.appendingPathComponent(member), line: nil)
                }
            })
        options.onClosed = { [weak self, weak options] in
            guard let self, self.optionsSession === options else { return }
            self.optionsSession = nil
        }
        optionsSession = options
        options.panel.displayTitle = displayName
        if optionsWereRestored { options.panel.setFeedback(StudioText[.deskOptionsRecovered]) }
        options.panel.present(relativeTo: window.frame)
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
            view.programTooltips?.cancel()
            view.programMenus?.cancel()
        }
        if !takesPointer {
            view.programTooltips?.cancel()
        }
        if window.ignoresMouseEvents || window.isMiniaturized || view.isHiddenOrHasHiddenAncestor ||
            (app.presentsWindows && !isOrderedIn) { view.programMenus?.cancel() }

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

    func publishFacts(refreshTime: Bool = false) {
        precondition(Thread.isMainThread)
        guard !isClosing, !isClosed else { return }
        let facts = currentFacts()
        let appearance = window.effectiveAppearance
        let scale = window.backingScaleFactor
        guard let currentInput = try? DeskWidgetWindowController.makeInput(for: appearance, scale: scale,
            program: program, preferredLanguages: loadedLanguages, locale: dateLocale()) else { return }
        let hostOwner = owner
        let menuAllowed = !window.ignoresMouseEvents && !window.isMiniaturized && !view.isHiddenOrHasHiddenAncestor
        executor.async { [hostOwner] in
            hostOwner.take(facts, input: currentInput, menuAllowed: menuAllowed)
            // Clock and zone inputs can change while the captured appearance/locale input stays equal.
            // Reuse wake's cache invalidation and visible-owner projection to replace the clock boundary.
            if refreshTime { hostOwner.wake() }
        }
    }

    /// Validate before touching pixels. A request claims its single Main transaction; the owner receives its ACK
    /// only after the content, view and window have committed together. The direct INI writer does not use this.
    func handleBitmapRequest(_ request: SkinBitmapRequest, session: UUID) {
        precondition(Thread.isMainThread)
        switch request {
        case .frame(let delivery):
            defer { delivery.finishOnMain(accepted: false) }
            guard !isClosing, !isClosed, session == sessionID, delivery.state == .pending else { return }
            // A display notification can still be queued. Read the actual destination now, including its profile.
            let facts = currentFacts()
            guard delivery.panelGeneration == destinationEpoch,
                  delivery.content.scale == facts.scale, delivery.scene.environment.scale == Double(facts.scale),
                  delivery.space == facts.colorSpace, facts.colorSpace?.model == .rgb,
                  delivery.appearance == facts.appearance,
                  delivery.scene.environment.appearance.name == facts.appearance else {
                publishFacts()
                return
            }
            guard delivery.serial > lastPresentationSerial, delivery.lifecycle >= lastPresentationLifecycle,
                  delivery.origin.x.isFinite, delivery.origin.y.isFinite,
                  delivery.content.size.width.isFinite, delivery.content.size.height.isFinite,
                  delivery.content.size.width > 0, delivery.content.size.height > 0 else { return }
            if delivery.panelGeneration == lastAcceptedEpoch {
                guard delivery.scene.generation >= lastPresentedGeneration else { return }
            }
            if case .composition(let composition) = delivery.content {
                guard composition.systemGlass == supportsSystemGlass, composition.isValid(for: delivery.space) else { return }
            }
            guard delivery.claimOnMain() else { return }
            let presented = DeskProgramHost.Presented(scene: delivery.scene, origin: delivery.origin,
                                                       size: delivery.content.size, scale: delivery.content.scale)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let accepted: Bool
            switch delivery.content {
            case .bitmap(let frame):
                accepted = content.presentAccepted(frame)
                if accepted { nativeComposition.clear() }
            case .composition(let composition):
                accepted = content.releaseContentsAccepted()
                if accepted { nativeComposition.apply(composition) }
            }
            if accepted { resize(for: presented) }
            CATransaction.commit()
            guard accepted else { return }
            lastPresentationSerial = delivery.serial
            lastPresentationLifecycle = delivery.lifecycle
            recordPresented(presented, epoch: delivery.panelGeneration)
            delivery.finishOnMain(accepted: true)

        case .clear(let invalidation):
            defer { invalidation.finishOnMain(accepted: false) }
            guard !isClosing, !isClosed, session == sessionID else { return }
            _ = currentFacts()
            guard invalidation.panelGeneration == destinationEpoch else {
                publishFacts()
                return
            }
            guard invalidation.serial > lastPresentationSerial,
                  invalidation.lifecycle >= lastPresentationLifecycle,
                  invalidation.claimOnMain() else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let accepted = content.releaseContentsAccepted()
            if accepted { nativeComposition.clear() }
            CATransaction.commit()
            guard accepted else { return }
            lastPresentationSerial = invalidation.serial
            lastPresentationLifecycle = invalidation.lifecycle
            latestPresented = nil
            view.clearAccessibility()
            view.programTooltips?.cancel()
            view.programMenus?.cancel()
            invalidation.finishOnMain(accepted: true)
        }
    }

    private func recordPresented(_ presented: DeskProgramHost.Presented, epoch: UInt64) {
        latestPresented = presented
        lastPresentedGeneration = presented.scene.generation
        lastAcceptedEpoch = epoch
        if let menuSession, !menuSession.owners.allSatisfy({ id in
            presented.scene.elements.contains { $0.id == id && $0.visibility == .visible }
        }) { view.programMenus?.cancel() }
        lastUnavailableMessage = nil
        lastActionFailure = nil
        view.toolTip = nil
        view.setAccessibilityLabel(nil)

        // Shown and active intent are written only after the complete first transaction is accepted.
        if !isStarted {
            isStarted = true
            if app.presentsWindows { window.orderFront(nil) }
            let pos = WindowGeometry.topLeft(of: window.frame, primaryHeight: WindowGeometry.primaryHeight(WindowGeometry.currentScreens()))
            app.state.updateDeskInstance(instance.id) {
                $0.active = true
                $0.x = pos.x
                $0.y = pos.y
            }
            publishFacts()
        }
        view.refreshAccessibility()
        view.programTooltips?.refresh()
    }

    /// Main starts the request; the owner resolves expressions asynchronously without blocking the event loop.
    func showProgramMenu(at point: NSPoint, nativeItems: [NSMenuItem]) {
        guard !isClosing, !isClosed, lastAcceptedEpoch == destinationEpoch,
              let presented = latestPresented, let menus = view.programMenus else { return }
        let id = UUID(), session = sessionID, epoch = lastAcceptedEpoch, hostOwner = owner
        view.programTooltips?.mouseDown()
        guard let request = menus.begin(at: point, onCancel: { [weak self] _ in
            guard let self else { return }
            if self.menuSession?.id == id { self.menuSession = nil }
            self.executor.async { [hostOwner] in hostOwner.cancelMenu(id) }
        }) else { return }
        executor.async { [hostOwner] in
            hostOwner.openMenu(at: SkinPoint(x: point.x, y: point.y), expectedGeneration: presented.scene.generation,
                epoch: epoch, menuID: id) { resolved, failure in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isClosing, !self.isClosed, self.sessionID == session,
                          self.destinationEpoch == epoch, self.lastAcceptedEpoch == epoch,
                          menus.currentRequest == request else { return }
                    self.menuSession = resolved
                    if let failure {
                        let message = self.localizedUnavailableDescription(failure)
                        self.lastActionFailure = message
                        self.view.toolTip = message
                        self.view.setAccessibilityLabel(message)
                        Log.write(message, level: .warning, source: self.source.entry)
                    }
                    menus.present(resolved?.items ?? [], for: request, nativeItems: nativeItems) { [weak self] item in
                        guard let self, self.menuSession?.id == id, self.sessionID == session,
                              self.destinationEpoch == epoch, let token = self.issueClickToken() else { return }
                        self.menuSession = nil
                        self.executor.async { [hostOwner] in
                            hostOwner.activateMenuItem(item, menuID: id, token: token) { returned, effects in
                                DispatchQueue.main.async { [weak self] in
                                    self?.handleEffects(effects, token: returned, issuedToken: token)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Only the accepted picture owns hover content. Its viewport origin is applied exactly once.
    func tooltipTarget(at point: NSPoint) -> DeskProgramTooltips.Target? {
        guard !isClosing, !isClosed, !window.ignoresMouseEvents, view.toolTip == nil,
              lastAcceptedEpoch == destinationEpoch, let presented = latestPresented else { return nil }
        return DeskProgramTooltips.target(in: presented.scene.hitMap,
            at: SkinPoint(x: point.x + presented.origin.x, y: point.y + presented.origin.y),
            revision: .init(session: sessionID, epoch: lastAcceptedEpoch, generation: presented.scene.generation))
    }

    private func resize(for presented: DeskProgramHost.Presented) {
        // The view's geometry precedes its containing window in the same disabled-actions transaction.
        view.frame = NSRect(origin: .zero, size: presented.size)
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
    }

    /// Contract: Filter stale sessions, clear Main accepted presentation, localized visible UI feedback, keep active intent.
    func handleUnavailable(_ errorDesc: String, session: UUID, epoch: UInt64,
                           invalidation: SkinBitmapInvalidation? = nil) {
        precondition(Thread.isMainThread)
        guard !isClosing, !isClosed, session == sessionID else { return }

        // Reject stale unavailable reports from mismatched destination epoch
        guard epoch == destinationEpoch else { return }
        if let invalidation {
            guard invalidation.state == .finished(accepted: true),
                  invalidation.serial == lastPresentationSerial,
                  invalidation.lifecycle == lastPresentationLifecycle else { return }
        }

        latestPresented = nil
        view.clearAccessibility()
        view.programTooltips?.cancel()
        view.programMenus?.cancel()
        let localizedMessage = localizedUnavailableDescription(errorDesc)
        let changed = lastUnavailableMessage != localizedMessage
        lastUnavailableMessage = localizedMessage
        view.toolTip = localizedMessage
        view.setAccessibilityLabel(localizedMessage)
        guard changed else { return }
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

    /// A precommit rejection leaves the accepted picture, accessibility children and interaction intact. A later
    /// successful picture or destination change makes its feedback obsolete before this Main callback arrives.
    func handleRejectedProjection(session: UUID, epoch: UInt64, generation: UInt64) {
        precondition(Thread.isMainThread)
        guard !isClosing, !isClosed, session == sessionID, epoch == destinationEpoch,
              epoch == lastAcceptedEpoch, latestPresented?.scene.generation == generation else { return }
        let message = StudioText[.deskOptionsChangeFailed]
        let changed = lastActionFailure != message
        lastActionFailure = message
        view.toolTip = message
        view.programTooltips?.cancel()
        view.setAccessibilityLabel(message)
        if changed { Log.write(message, level: .warning, source: source.entry) }
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
        enqueueRelease(at: point, token: token, pressBeforeRelease: false, event: .leftUp)
    }

    func sendSecondaryRelease(at point: SkinPoint) {
        guard let token = issueClickToken() else { return }
        enqueueRelease(at: point, token: token, pressBeforeRelease: false, event: .rightUp)
    }

    private func enqueueRelease(at point: SkinPoint, token: DeskWidgetClickToken, pressBeforeRelease: Bool,
                                event: MouseEventKind) {
        let hostOwner = owner
        executor.async { [hostOwner] in
            if pressBeforeRelease {
                hostOwner.primaryPress(at: point, expectedGeneration: token.sourceGeneration, epoch: token.epoch)
            }
            let receive: (DeskWidgetClickToken, [ProgramEffect]) -> Void = { returnedToken, effects in
                DispatchQueue.main.async { [weak self] in
                    self?.handleEffects(effects, token: returnedToken, issuedToken: token)
                }
            }
            if event == .leftUp { hostOwner.primaryRelease(at: point, token: token, onEffects: receive) }
            else { hostOwner.secondaryRelease(at: point, token: token, onEffects: receive) }
        }
    }

    /// AX Press is explicit user activation of the exact accepted actionable element. The owner still qualifies
    /// pointer eligibility, current presentation, hit identity and destination before resolving any effects.
    fileprivate func activateAccessibility(_ child: DeskWidgetAccessibilityElement) -> Bool {
        guard Thread.isMainThread, child.canPress, let presented = view.presentation(for: child),
              let element = presented.scene.elements.first(where: { $0.id == child.id }),
              element.visibility == .visible else { return false }
        switch element.kind {
        case .unknown("Column"), .unknown("Row"), .unknown("Freeform"):
            guard element.frame.width > 0, element.frame.height > 0,
                  let token = issueClickToken(), token.session == child.session, token.epoch == child.epoch,
                  token.sourceGeneration == child.generation else { return false }
            let id = child.id, hostOwner = owner
            executor.async { [hostOwner] in
                hostOwner.activateContainer(id, token: token) { returnedToken, effects in
                    DispatchQueue.main.async { [weak self] in
                        self?.handleEffects(effects, token: returnedToken, issuedToken: token)
                    }
                }
            }
            return true
        default: break
        }
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
        enqueueRelease(at: point, token: token, pressBeforeRelease: true, event: .leftUp)
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
                view.programTooltips?.cancel()
                view.setAccessibilityLabel(message)
                Log.write(message, level: .warning, source: source.entry)
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        view.programTooltips?.cancel()
        view.programMenus?.cancel()
    }

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
    /// Record explicit deactivation before waiting; the ACK only releases the old window's resources.
    func close(deactivate: Bool, completion: (() -> Void)? = nil) {
        precondition(Thread.isMainThread)
        if deactivate {
            deactivationRequested = true
            app.cancelDeskWidgetActivation(instanceID: instance.id)
            app.state.updateDeskInstance(instance.id) { $0.active = false }
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
        optionsSession?.close()
        optionsSession = nil
        sessionID = UUID() // invalidate any pending in-flight didPresent callbacks
        latestPresented = nil
        view.clearAccessibility()
        view.programTooltips?.close()
        view.programMenus?.close()

        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()

        let hostOwner = owner
        executor.async { [hostOwner] in
            let finalOptions = try? hostOwner.optionsSnapshot()
            hostOwner.close {
                DispatchQueue.main.async { [self] in
                    if let finalOptions, !finalOptions.values.values.isEmpty {
                        self.app.deskOptionDrafts[self.instance.id] = .init(sourceID: self.source.id, values: finalOptions.values)
                        do { try self.saveOptions(finalOptions.values) }
                        catch {
                            Log.write(StudioText[.deskOptionsClosingSaveFailed], level: .warning, source: self.source.entry)
                            if !self.app.isTerminating {
                                self.app.alert(StudioText[.sectionOptions], StudioText[.deskOptionsClosingSaveFailed], style: .warning)
                            }
                        }
                    }
                    self.isClosed = true
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.nativeComposition.clear()
                    self.content.teardown()
                    CATransaction.commit()
                    self.window.orderOut(nil)
                    self.window.close()
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
    let session: UUID
    private let initialOptions: ProgramOptionsInput?
    private let system: SystemDataSource
    var prepared: DeskProgramResources.Prepared?
    private(set) var host: DeskProgramHost?
    private(set) var isClosed = false

    private(set) var currentEpoch: UInt64 = 0
    private var primaryPressEpoch: UInt64?
    private var secondaryPressEpoch: UInt64?

    init(program: WidgetProgram, executor: SkinExecutor, provider: ContentProvider,
         prepared: DeskProgramResources.Prepared?, clock: SkinClock, source: String, session: UUID,
         options: ProgramOptionsInput? = nil, system: SystemDataSource = SystemMonitor.shared) {
        self.program = program
        self.executor = executor
        self.provider = provider
        self.prepared = prepared
        self.clock = clock
        self.source = source
        self.session = session
        self.initialOptions = options
        self.system = system
    }

    func start(input: DeskProgramHost.Input, facts: SkinWindowFacts, supportsSystemGlass: Bool = false,
               onDelivery: @escaping (SkinBitmapRequest) -> Void,
               onUnavailable: @escaping (String, UInt64, SkinBitmapInvalidation?) -> Void,
               onRejected: @escaping (String, UInt64, UInt64) -> Void = { _, _, _ in },
               onOptions: @escaping (ProgramOptionsSnapshot) -> Void = { _ in }) {
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
                                                system: system, source: source, options: initialOptions)
            guard !isClosed else {
                readyHost.close()
                return
            }
            readyHost.frames.bitmapCompositionSupportsSystemGlass = supportsSystemGlass
            readyHost.frames.requestBitmapDelivery = { [weak self] request in
                guard let self else { return }
                onDelivery(request)
                // Each replacement clear inherits the current failure. A second failed capture can supersede
                // the first clear before Main runs; binding only the first error callback would lose feedback.
                if case .clear(let invalidation) = request, let state = self.host?.state,
                   case .unavailable(let message) = state {
                    onUnavailable(message, self.currentEpoch, invalidation)
                }
            }
            self.host = readyHost
            readyHost.didChangeOptions = onOptions
            readyHost.didRejectProjection = { [weak self] message, generation in
                guard let self, !isClosed else { return }
                onRejected(message, currentEpoch, generation)
            }
            readyHost.take(facts, input: input)
            readyHost.start()
            readyHost.drawFirstFrame()
        } catch {
            prepared?.removeCopies()
            prepared = nil
            onUnavailable(String(describing: error), currentEpoch, nil)
        }
    }

    func optionsSnapshot() throws -> ProgramOptionsSnapshot {
        precondition(executor.isCurrent)
        guard !isClosed, let host else { throw DeskProgramHost.Failure.optionsCancelled }
        return try host.optionsSnapshot()
    }

    func updateOptions(_ input: ProgramOptionsInput, expectedRevision: UInt64,
                       completion: @escaping (Result<ProgramOptionsSnapshot, Error>) -> Void) {
        precondition(executor.isCurrent)
        guard !isClosed, let host else { completion(.failure(DeskProgramHost.Failure.optionsCancelled)); return }
        host.updateOptions(input, expectedRevision: expectedRevision, completion: completion)
    }

    func finishBitmapRequest(_ request: SkinBitmapRequest) {
        precondition(executor.isCurrent)
        guard let host else { return }
        switch request {
        case .frame(let delivery): host.frames.finishBitmapDelivery(delivery)
        case .clear(let invalidation): host.frames.finishBitmapInvalidation(invalidation)
        }
    }

    func take(_ facts: SkinWindowFacts, input: DeskProgramHost.Input, menuAllowed: Bool? = nil) {
        precondition(executor.isCurrent)
        guard !isClosed else { return }
        if currentEpoch != facts.panelGeneration {
            host?.primaryRelease(at: nil)
            host?.secondaryRelease(at: nil)
            primaryPressEpoch = nil
            secondaryPressEpoch = nil
        }
        currentEpoch = facts.panelGeneration
        host?.take(facts, input: input, menuAllowed: menuAllowed)
        host?.drawFirstFrame()
    }

    func primaryPress(at point: SkinPoint, expectedGeneration: UInt64, epoch: UInt64? = nil) {
        press(at: point, expectedGeneration: expectedGeneration, epoch: epoch, event: .leftUp)
    }

    func secondaryPress(at point: SkinPoint, expectedGeneration: UInt64, epoch: UInt64? = nil) {
        press(at: point, expectedGeneration: expectedGeneration, epoch: epoch, event: .rightUp)
    }

    private func press(at point: SkinPoint, expectedGeneration: UInt64, epoch: UInt64?, event: MouseEventKind) {
        precondition(executor.isCurrent)
        cancelPress(event)
        guard !isClosed, let host, host.scene?.generation == expectedGeneration else { return }
        if let epoch, epoch != currentEpoch { return }
        if event == .leftUp { host.primaryPress(at: point); primaryPressEpoch = currentEpoch }
        else { host.secondaryPress(at: point); secondaryPressEpoch = currentEpoch }
    }

    func primaryRelease(at point: SkinPoint?, expectedGeneration: UInt64?) {
        release(at: point, expectedGeneration: expectedGeneration, event: .leftUp)
    }

    func secondaryRelease(at point: SkinPoint?, expectedGeneration: UInt64?) {
        release(at: point, expectedGeneration: expectedGeneration, event: .rightUp)
    }

    private func release(at point: SkinPoint?, expectedGeneration: UInt64?, event: MouseEventKind) {
        precondition(executor.isCurrent)
        guard !isClosed, let host else { return }
        if let expectedGeneration, host.scene?.generation != expectedGeneration { cancelPress(event); return }
        if event == .leftUp { host.primaryRelease(at: point); primaryPressEpoch = nil }
        else { host.secondaryRelease(at: point); secondaryPressEpoch = nil }
    }

    func primaryRelease(at point: SkinPoint, token: DeskWidgetClickToken,
                        onEffects: @escaping (DeskWidgetClickToken, [ProgramEffect]) -> Void) {
        release(at: point, token: token, event: .leftUp, onEffects: onEffects)
    }

    func secondaryRelease(at point: SkinPoint, token: DeskWidgetClickToken,
                          onEffects: @escaping (DeskWidgetClickToken, [ProgramEffect]) -> Void) {
        release(at: point, token: token, event: .rightUp, onEffects: onEffects)
    }

    func activateContainer(_ id: ElementID, token: DeskWidgetClickToken,
                           onEffects: @escaping (DeskWidgetClickToken, [ProgramEffect]) -> Void) {
        precondition(executor.isCurrent)
        guard !isClosed, token.session == session, token.epoch == currentEpoch, let host,
              token.sourceGeneration == host.scene?.generation,
              token.sourceGeneration == host.presented?.scene.generation else { return }
        cancelPress(.leftUp)
        let consume: ([ProgramEffect]) -> Void = { [weak self] effects in
            guard let self, !self.isClosed, self.session == token.session,
                  self.currentEpoch == token.epoch, !effects.isEmpty else { return }
            precondition(self.executor.isCurrent)
            onEffects(token, effects)
        }
        if let effects = host.activateContainer(id, expectedGeneration: token.sourceGeneration, completion: consume) {
            consume(effects)
        }
    }

    func openMenu(at point: SkinPoint, expectedGeneration: UInt64, epoch: UInt64, menuID: UUID,
                  completion: (DeskProgramMenuSession?, String?) -> Void) {
        precondition(executor.isCurrent)
        guard !isClosed, epoch == currentEpoch, let host else { completion(nil, nil); return }
        cancelPress(.leftUp); cancelPress(.rightUp)
        do { completion(try host.openMenu(at: point, expectedGeneration: expectedGeneration, id: menuID), nil) }
        catch { completion(nil, String(describing: error)) }
    }

    func cancelMenu(_ id: UUID) {
        precondition(executor.isCurrent)
        host?.cancelMenu(id)
    }

    func activateMenuItem(_ item: ProgramMenuItemID, menuID: UUID, token: DeskWidgetClickToken,
                          onEffects: @escaping (DeskWidgetClickToken, [ProgramEffect]) -> Void) {
        precondition(executor.isCurrent)
        guard !isClosed, token.session == session, token.epoch == currentEpoch, let host else { return }
        let consume: ([ProgramEffect]) -> Void = { [weak self] effects in
            guard let self, !self.isClosed, self.session == token.session,
                  self.currentEpoch == token.epoch, !effects.isEmpty else { return }
            precondition(self.executor.isCurrent)
            onEffects(token, effects)
        }
        if let effects = host.activateMenuItem(item, menuID: menuID, expectedGeneration: token.sourceGeneration,
                                               completion: consume) { consume(effects) }
    }

    private func release(at point: SkinPoint, token: DeskWidgetClickToken, event: MouseEventKind,
                         onEffects: @escaping (DeskWidgetClickToken, [ProgramEffect]) -> Void) {
        precondition(executor.isCurrent)
        guard !isClosed, let host else { return }
        let pressEpoch = event == .leftUp ? primaryPressEpoch : secondaryPressEpoch
        guard token.session == session, token.epoch == currentEpoch, token.epoch == pressEpoch, token.sourceGeneration == host.scene?.generation,
              token.sourceGeneration == host.presented?.scene.generation else {
            cancelPress(event)
            return
        }
        let consume: ([ProgramEffect]) -> Void = { [weak self] effects in
            guard let self, !self.isClosed, self.session == token.session,
                  self.currentEpoch == token.epoch, !effects.isEmpty else { return }
            precondition(self.executor.isCurrent)
            onEffects(token, effects)
        }
        let effects = event == .leftUp ? host.primaryRelease(at: point, completion: consume) :
            host.secondaryRelease(at: point, completion: consume)
        if event == .leftUp { primaryPressEpoch = nil } else { secondaryPressEpoch = nil }
        if let effects { consume(effects) }
    }

    private func cancelPress(_ event: MouseEventKind) {
        if event == .leftUp { host?.primaryRelease(at: nil); primaryPressEpoch = nil }
        else { host?.secondaryRelease(at: nil); secondaryPressEpoch = nil }
    }

    func notifyPowerChange() {
        precondition(executor.isCurrent)
        guard !isClosed, let host else { return }
        host.notifyPowerChange()
    }
    func notifyBatteryDetailsReady() {
        precondition(executor.isCurrent)
        guard !isClosed, let host else { return }
        host.notifyBatteryDetailsReady()
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
        primaryPressEpoch = nil
        secondaryPressEpoch = nil
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
    fileprivate(set) var programTooltips: DeskProgramTooltips?
    fileprivate(set) var programMenus: DeskProgramMenus?
    private var hoverTrackingArea: NSTrackingArea?
    private(set) var accessibilityParts: [DeskWidgetAccessibilityElement] = []
    private var dragStart: NSPoint?
    private var windowOrigin: NSPoint?
    private var dragged = false
    private var primaryGesture: (event: MouseEventKind, session: UUID, epoch: UInt64)?
    private var secondaryGesture: (session: UUID, epoch: UInt64)?
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    /// Self-tests intercept the real constructed menu instead of entering AppKit's modal menu tracking loop.
    var contextMenuPresenterForTesting: ((NSMenu, NSEvent) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        programTooltips?.mouseMoved(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) { programTooltips?.mouseExited() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        programTooltips?.cancel()
    }

    override func accessibilityChildren() -> [Any]? { accessibilityParts }

    fileprivate func refreshAccessibility() {
        guard let controller, !controller.isClosing, !controller.isClosed,
              controller.lastAcceptedEpoch == controller.destinationEpoch,
              let presented = controller.latestPresented else { clearAccessibility(); return }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(controller.displayName)
        let clickable = Set(presented.scene.hitMap.entries.filter { $0.action(.leftUp) != .absent }.compactMap(\.elementID))
        var parts: [DeskWidgetAccessibilityElement] = []
        for element in presented.scene.elements where element.visibility == .visible {
            // Decorations and a preset transform share the text recipe. The element's frame already uses
            // displayed coordinates. Explicit labels are resolved by the owner in this same scene transaction.
            let canPress = clickable.contains(element.id)
            let label = element.accessibilityLabel ?? (canPress && element.kind == .string ? projectedText(in: element.items) : nil)
            guard let label else { continue }
            // isContainer describes legacy image masks, not the Desk layout hierarchy.
            let isGroup: Bool
            switch element.kind {
            case .unknown("Column"), .unknown("Row"), .unknown("Freeform"): isGroup = true
            default: isGroup = false
            }
            let role: NSAccessibility.Role = canPress ? .button :
                (element.kind == .string ? .staticText : (isGroup ? .group : .image))
            parts.append(DeskWidgetAccessibilityElement(id: element.id, text: label, role: role, canPress: canPress,
                session: controller.sessionID, epoch: controller.lastAcceptedEpoch,
                generation: presented.scene.generation, owner: self))
        }
        replaceAccessibility(parts)
    }

    private func projectedText(in items: [DrawItem]) -> String? {
        var pending = items.map { ($0, 0) }
        var label: String?
        while let (item, depth) = pending.popLast() {
            guard depth <= ProgramLimits.maximumDepth else { return nil }
            switch item {
            case .text(let text):
                guard label == nil else { return nil }
                label = text.text
            case .transformed(_, let children), .antialias(_, let children):
                pending.append(contentsOf: children.map { ($0, depth + 1) })
            case .fill, .shape, .glass: break
            default: return nil
            }
        }
        return label
    }

    fileprivate func clearAccessibility() { replaceAccessibility([]) }

    private func replaceAccessibility(_ parts: [DeskWidgetAccessibilityElement]) {
        let changed = !accessibilityParts.isEmpty || !parts.isEmpty
        accessibilityParts = parts
        guard changed, controller?.app.presentsWindows == true else { return }
        // Notify clients about the replaced tree; do not announce every changing CPU/text value aloud.
        var affected: [Any] = [self]
        affected.append(contentsOf: parts)
        NSAccessibility.post(element: self, notification: .layoutChanged, userInfo: [.uiElements: affected])
    }

    fileprivate func presentation(for child: DeskWidgetAccessibilityElement) -> DeskProgramHost.Presented? {
        guard let controller, !controller.isClosing, !controller.isClosed,
              child.owner === self, accessibilityParts.contains(where: { $0 === child }),
              child.session == controller.sessionID, child.epoch == controller.destinationEpoch,
              child.epoch == controller.lastAcceptedEpoch,
              let presented = controller.latestPresented, presented.scene.generation == child.generation else { return nil }
        return presented
    }

    fileprivate func screenFrame(for child: DeskWidgetAccessibilityElement) -> NSRect {
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
        programTooltips?.mouseDown()
        programMenus?.cancel()
        guard let controller, !controller.isClosing, !controller.isClosed else { return }
        if let previous = primaryGesture { cancelPointer(previous.event) }
        primaryGesture = nil
        dragStart = nil
        dragged = false
        if event.modifierFlags.contains(.control) {
            cancelPointer(.leftUp)
            if let press = beginSecondaryPress(with: event) {
                primaryGesture = (.rightUp, press.session, press.epoch)
            }
            return
        }
        primaryGesture = (.leftUp, controller.sessionID, controller.lastAcceptedEpoch)
        dragStart = pointerLocation()
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
        programTooltips?.mouseDown()
        programMenus?.cancel()
        if primaryGesture?.event == .rightUp {
            primaryGesture = nil
            cancelPointer(.rightUp)
            return
        }
        guard let controller, !controller.isClosing, !controller.isClosed,
              let press = primaryGesture, press.session == controller.sessionID,
              press.epoch == controller.destinationEpoch,
              let start = dragStart, let origin = windowOrigin, let window else { return }
        let now = pointerLocation()
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
        let press = primaryGesture
        primaryGesture = nil
        guard let controller, !controller.isClosing, !controller.isClosed else {
            dragStart = nil
            dragged = false
            return
        }
        guard let press else { return }
        if press.event == .rightUp {
            endSecondaryPress(with: event, session: press.session, epoch: press.epoch)
            return
        }
        guard press.session == controller.sessionID, press.epoch == controller.destinationEpoch,
              press.epoch == controller.lastAcceptedEpoch else {
            cancelPointer(.leftUp)
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
        programTooltips?.mouseDown()
        programMenus?.cancel()
        secondaryGesture = beginSecondaryPress(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        programTooltips?.mouseDown()
        programMenus?.cancel()
        secondaryGesture = nil
        cancelPointer(.rightUp)
    }

    override func rightMouseUp(with event: NSEvent) {
        let press = secondaryGesture
        secondaryGesture = nil
        guard let press else { return }
        endSecondaryPress(with: event, session: press.session, epoch: press.epoch)
    }

    private func pointerPresentation() -> DeskProgramHost.Presented? {
        guard acceptsPointerMenu(), let controller,
              controller.lastAcceptedEpoch == controller.destinationEpoch else { return nil }
        return controller.latestPresented
    }

    private func acceptsPointerMenu() -> Bool {
        guard let controller, !controller.isClosing, !controller.isClosed,
              !isHiddenOrHasHiddenAncestor, !controller.window.ignoresMouseEvents,
              !controller.app.presentsWindows || (controller.window.isVisible && controller.window.occlusionState.contains(.visible)) else {
            return false
        }
        // The native component menu remains reachable while a program fails or a new destination awaits its
        // first picture. It uses the living Main window, never a stale program hit or viewport mapping.
        return true
    }

    private func beginSecondaryPress(with event: NSEvent) -> (session: UUID, epoch: UInt64)? {
        cancelPointer(.rightUp)
        guard let controller, acceptsPointerMenu() else { return nil }
        guard let presented = pointerPresentation() else { showContextMenu(with: event); return nil }
        let local = convert(event.locationInWindow, from: nil)
        let point = SkinPoint(x: local.x, y: local.y)
        let hit = presented.scene.hitMap.entry(at: point.x + presented.origin.x, point.y + presented.origin.y,
                                                handling: .rightUp, images: nil)
        guard !event.modifierFlags.contains(.option), hit != nil else {
            showContextMenu(with: event)
            return nil
        }
        let epoch = controller.lastAcceptedEpoch
        controller.executor.async { [owner = controller.owner] in
            owner.secondaryPress(at: point, expectedGeneration: presented.scene.generation, epoch: epoch)
        }
        return (controller.sessionID, epoch)
    }

    private func endSecondaryPress(with event: NSEvent, session: UUID, epoch: UInt64) {
        guard let controller, session == controller.sessionID, epoch == controller.destinationEpoch,
              epoch == controller.lastAcceptedEpoch else {
            cancelPointer(.rightUp)
            return
        }
        if event.modifierFlags.contains(.option) {
            cancelPointer(.rightUp)
            showContextMenu(with: event)
            return
        }
        guard pointerPresentation() != nil else { cancelPointer(.rightUp); return }
        let local = convert(event.locationInWindow, from: nil)
        controller.sendSecondaryRelease(at: SkinPoint(x: local.x, y: local.y))
    }

    private func cancelPointer(_ event: MouseEventKind) {
        guard let controller else { return }
        controller.executor.async { [owner = controller.owner] in
            if event == .leftUp { owner.primaryRelease(at: nil, expectedGeneration: nil) }
            else { owner.secondaryRelease(at: nil, expectedGeneration: nil) }
        }
    }

    private func showContextMenu(with event: NSEvent) {
        guard acceptsPointerMenu() else { return }
        programMenus?.cancel()
        let menu = NSMenu(title: "Desk Widget")
        let removeItem = NSMenuItem(title: StudioText[.removeWidgetFromDesktop],
                                    action: #selector(removeWidgetFromDesktop(_:)), keyEquivalent: "")
        removeItem.target = self
        var nativeItems: [NSMenuItem] = []
        if controller?.program.options.isEmpty == false {
            let options = NSMenuItem(title: StudioText[.deskOptions], action: #selector(showOptions(_:)), keyEquivalent: "")
            options.target = self
            nativeItems.append(options)
        }
        nativeItems.append(removeItem)
        if !event.modifierFlags.contains(.option), let controller, let presented = pointerPresentation() {
            let local = convert(event.locationInWindow, from: nil)
            let world = SkinPoint(x: local.x + presented.origin.x, y: local.y + presented.origin.y)
            if !DeskProgramMenuSession.owners(root: controller.program.root, scene: presented.scene, at: world).isEmpty {
                controller.showProgramMenu(at: local, nativeItems: nativeItems)
                return
            }
        }
        menu.autoenablesItems = false
        for item in nativeItems { menu.addItem(item) }
        if let contextMenuPresenterForTesting { contextMenuPresenterForTesting(menu, event) }
        else { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    @objc private func removeWidgetFromDesktop(_ sender: Any?) {
        controller?.deactivateAndClose()
    }

    @objc private func showOptions(_ sender: Any?) { controller?.showOptions() }
}

/// One accepted labelled element. Held children cannot adopt a newer scene's identity or generation.
final class DeskWidgetAccessibilityElement: NSAccessibilityElement {
    let id: ElementID
    let session: UUID
    let epoch: UInt64
    let generation: UInt64
    let canPress: Bool
    weak var owner: DeskWidgetView?
    private var pressed = false

    init(id: ElementID, text: String, role: NSAccessibility.Role, canPress: Bool,
         session: UUID, epoch: UInt64, generation: UInt64, owner: DeskWidgetView) {
        self.id = id
        self.session = session
        self.epoch = epoch
        self.generation = generation
        self.canPress = canPress
        self.owner = owner
        super.init()
        setAccessibilityRole(role)
        setAccessibilityLabel(text)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityParent() -> Any? { owner }
    override func accessibilityFrame() -> NSRect { owner?.screenFrame(for: self) ?? .zero }

    override func accessibilityPerformPress() -> Bool {
        guard Thread.isMainThread, canPress, !pressed, let controller = owner?.controller,
              controller.activateAccessibility(self) else { return false }
        pressed = true
        return true
    }
}
