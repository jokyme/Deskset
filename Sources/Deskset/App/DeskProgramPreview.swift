import AppKit
import DeskLanguage
import DesksetCore
import DesksetDraw

/// A shared program's editor preview. The document checker owns source/version truth; this main-thread owner
/// only compiles its current finished snapshot and borrows the view's drawing destination. It activates no widget.
final class DeskProgramPreviewController: NSViewController, TickTarget {
    enum State: Equatable {
        case checking, ready, empty, unavailable(String), closed
    }

    let canvas = DeskProgramPreviewCanvas(frame: .zero)
    let scrollView = OverlayScrollView(frame: .zero)
    private let backdrop = StudioBackdropView(frame: .zero)
    private let heading = StudioPageStyle.label(StudioText[.previewOnly], font: StudioPageStyle.headingFont)
    private let status = StudioPageStyle.wrapping("")
    private let fitButton = NSButton(title: StudioText[.zoomToFit], target: nil, action: nil)
    private let actualButton = NSButton(title: StudioText[.actualSizeShort], target: nil, action: nil)
    let actionRecordsButton = EditorStyle.disclosure("", open: false)
    let actionRecordsClearButton = NSButton(title: StudioText[.logClear], target: nil, action: nil)
    let actionRecordsText = NSTextView(frame: .zero)
    let actionRecordsScrollView = OverlayScrollView(frame: .zero)
    let actionRecordsNotice = StudioPageStyle.wrapping(StudioText[.deskActionPreviewNotice])
    private let actionRecordsPane = NSStackView()
    private let actionRecordsFooter = NSStackView()
    private var actionRecordsCanvasCap: NSLayoutConstraint?
    private var actionRecordsExpanded = false
    private var actionRecordsLanguage: StudioLanguage?
    private enum ActionRecordsLayout {
        static let preferredHeight: CGFloat = 160
        static let maximumHeightFraction: CGFloat = 0.25
        static let maximumCanvasHeightFraction: CGFloat = 0.75
    }
    private var snapshot: DeskSnapshot?
    private var runtime: ProgramRuntime?
    private var resources: ((DeskSnapshot) -> DeskProgramResources.Input)?
    private var accepts: ((DeskSnapshot) -> Bool)?
    private var projecting = false
    private var primaryPress: (snapshot: DeskSnapshot, element: ElementID)?
    private var secondaryPress: (snapshot: DeskSnapshot, element: ElementID)?
    private let clock: SkinClock
    let executor: SkinExecutor
    private let dateLocale: () -> Locale
    private let colorSource: (NSAppearance) throws -> MacAppearance.ProgramValues
    private let system: SystemDataSource
    private var sampler = ProgramSystemSampler()
    private var lastColors: ProgramColorInput?
    private let tickScheduler = TickScheduler()
    private var visible = false
    var isClosed: Bool { state == .closed }
    var updateMilliseconds: Int {
        switch runtime?.clockPrecision {
        case .second: return 1000
        case .twoSeconds: return 2000
        case .minute, nil: return 60_000
        }
    }
    private(set) var state: State = .checking
    private(set) var scene: WidgetScene?
    /// Resolved user requests are recorded in the preview, never executed against the Mac.
    private(set) var recordedEffects: [ProgramEffect] = []
    var onRecordedEffects: (([ProgramEffect]) -> Void)?
    private static let recordedEffectLimit = 100 // The existing Studio action log retention.

    init(resources: @escaping (DeskSnapshot) -> DeskProgramResources.Input = { _ in .ready([:]) },
         clock: SkinClock = .live, executor: SkinExecutor = MainSkinExecutor.shared,
         dateLocale: @escaping () -> Locale = DeskProgramPreviewController.currentDateLocale,
         colors: @escaping (NSAppearance) throws -> MacAppearance.ProgramValues = MacAppearance.programValues(for:),
         system: SystemDataSource = SystemMonitor.shared,
         accepts: @escaping (DeskSnapshot) -> Bool) {
        self.clock = clock
        self.executor = executor
        self.dateLocale = dateLocale
        self.colorSource = colors
        self.system = system
        self.resources = resources
        self.accepts = accepts
        super.init(nibName: nil, bundle: nil)
        canvas.beforeDrawing = { [weak self] in self?.prepareToDraw() ?? false }
        canvas.onEnvironmentChange = { [weak self] in self?.refreshEnvironment() }
        canvas.onImageFailure = { [weak self] in self?.clear(.unavailable("Cannot decode the prepared image for this drawing")) }
        canvas.onPrimaryPress = { [weak self] point in self?.beginPrimaryPress(at: point) }
        canvas.onPrimaryRelease = { [weak self] point in self?.endPrimaryPress(at: point) }
        canvas.onSecondaryPress = { [weak self] point in self?.beginSecondaryPress(at: point) }
        canvas.onSecondaryRelease = { [weak self] point in self?.endSecondaryPress(at: point) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func currentDateLocale() -> Locale {
        // Preserve the Mac's region/calendar preferences while using the Studio's selected display language.
        var components = Locale.components(fromIdentifier: Locale.current.identifier)
        components[NSLocale.Key.languageCode.rawValue] = StudioText.language == .chinese ? "zh" : "en"
        if StudioText.language == .chinese { components[NSLocale.Key.scriptCode.rawValue] = "Hans" }
        else { components.removeValue(forKey: NSLocale.Key.scriptCode.rawValue) }
        return Locale(identifier: Locale.identifier(fromComponents: components))
    }

    func setVisible(_ value: Bool) {
        precondition(executor.isCurrent && Thread.isMainThread)
        guard state != .closed, visible != value else { return }
        visible = value
        if value { updateForTick() } else {
            primaryPress = nil; secondaryPress = nil; canvas.clearPointerGestures(); tickScheduler.cancel()
        }
    }

    func updateForTick() {
        precondition(executor.isCurrent && Thread.isMainThread)
        tickScheduler.cancel()
        guard visible, state != .closed, let snapshot else { return }
        guard accepts?(snapshot) == true else { clear(.checking); return }
        project()
    }

    func notifySystemWake() {
        sampler.invalidateTimeBased()
        updateForTick()
    }
    func notifyPowerChange() {
        guard state != .closed else { return }
        sampler.invalidateBattery()
        guard visible, let runtime else { return }
        let batteryProps: Set<ProgramSystemProperty> = [.batteryLevel, .batteryCharging, .batteryPluggedIn]
        guard !runtime.neededSystemProperties().isDisjoint(with: batteryProps) else { return }
        updateForTick()
    }

    /// Date/zone/locale notifications change input, not the checked program or its session variables.
    func refreshDateInput() {
        guard state != .closed else { return }
        if visible { updateForTick() }
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 580))
        backdrop.kind = .workbench
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = RenderOptions.scaleRange.lowerBound
        scrollView.maxMagnification = RenderOptions.scaleRange.upperBound
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.setAccessibilityLabel(StudioText[.previewOnly])
        fitButton.target = self
        fitButton.action = #selector(fit)
        actualButton.target = self
        actualButton.action = #selector(actualSize)
        fitButton.bezelStyle = .rounded
        actualButton.bezelStyle = .rounded
        let toolbar = NSStackView(views: [heading, NSView(), actualButton, fitButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        actionRecordsButton.target = self
        actionRecordsButton.action = #selector(toggleActionRecords)
        actionRecordsButton.setButtonType(.pushOnPushOff)
        actionRecordsClearButton.target = self
        actionRecordsClearButton.action = #selector(clearActionRecords)
        actionRecordsClearButton.bezelStyle = .inline
        actionRecordsClearButton.controlSize = .small
        actionRecordsClearButton.font = StudioPageStyle.smallFont
        let recordsHeader = NSStackView(views: [actionRecordsButton, NSView(), actionRecordsClearButton])
        recordsHeader.orientation = .horizontal
        recordsHeader.spacing = 8
        actionRecordsText.isEditable = false
        actionRecordsText.isSelectable = true
        actionRecordsText.isRichText = false
        actionRecordsText.importsGraphics = false
        actionRecordsText.drawsBackground = false
        actionRecordsText.font = StudioPageStyle.valueFont
        actionRecordsText.textColor = .labelColor
        actionRecordsText.textContainerInset = NSSize(width: 6, height: 8)
        actionRecordsText.minSize = .zero
        actionRecordsText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        actionRecordsText.isVerticallyResizable = true
        actionRecordsText.isHorizontallyResizable = false
        actionRecordsText.autoresizingMask = [.width]
        actionRecordsText.textContainer?.widthTracksTextView = true
        actionRecordsText.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        actionRecordsScrollView.documentView = actionRecordsText
        actionRecordsScrollView.borderType = .noBorder
        actionRecordsScrollView.drawsBackground = false
        actionRecordsScrollView.hasVerticalScroller = true
        actionRecordsScrollView.hasHorizontalScroller = false
        // Keep a stable text width with legacy scrollers, matching the code editor's soft-wrap behavior.
        actionRecordsScrollView.autohidesScrollers = false
        actionRecordsPane.orientation = .vertical
        actionRecordsPane.alignment = .leading
        actionRecordsPane.spacing = 4
        actionRecordsPane.addArrangedSubview(actionRecordsNotice)
        actionRecordsPane.addArrangedSubview(actionRecordsScrollView)
        actionRecordsFooter.orientation = .vertical
        actionRecordsFooter.alignment = .leading
        actionRecordsFooter.spacing = 8
        // Removing only the arrangement preserves the pane's cross-view constraints while collapsed.
        actionRecordsFooter.detachesHiddenViews = false
        actionRecordsFooter.addArrangedSubview(recordsHeader)
        actionRecordsFooter.addArrangedSubview(actionRecordsPane)
        let recordsFooter = actionRecordsFooter
        for child in [backdrop, scrollView, toolbar, status, recordsFooter] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        let recordsHeight = actionRecordsPane.heightAnchor.constraint(equalToConstant: ActionRecordsLayout.preferredHeight)
        recordsHeight.priority = .defaultLow
        // The whole-view cap alone cannot account for the toolbar and wrapped status in a short window.
        actionRecordsCanvasCap = actionRecordsPane.heightAnchor.constraint(lessThanOrEqualTo: scrollView.heightAnchor,
            multiplier: ActionRecordsLayout.maximumCanvasHeightFraction)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: StudioPageStyle.margin),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -StudioPageStyle.margin),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: StudioPageStyle.margin),
            status.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -StudioPageStyle.margin),
            status.bottomAnchor.constraint(equalTo: recordsFooter.topAnchor, constant: -8),
            recordsFooter.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: StudioPageStyle.margin),
            recordsFooter.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -StudioPageStyle.margin),
            recordsFooter.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            recordsHeader.widthAnchor.constraint(equalTo: recordsFooter.widthAnchor),
            actionRecordsPane.widthAnchor.constraint(equalTo: recordsFooter.widthAnchor),
            actionRecordsPane.topAnchor.constraint(equalTo: recordsHeader.bottomAnchor, constant: 8),
            actionRecordsNotice.widthAnchor.constraint(equalTo: actionRecordsPane.widthAnchor),
            actionRecordsScrollView.widthAnchor.constraint(equalTo: actionRecordsPane.widthAnchor),
            actionRecordsPane.heightAnchor.constraint(lessThanOrEqualTo: container.heightAnchor,
                multiplier: ActionRecordsLayout.maximumHeightFraction),
            recordsHeight,
        ])
        view = container
        updateStatus()
        updateActionRecords()
    }

    /// A stale or pending result cannot borrow an earlier picture. The existing checker supplies all four guards.
    func show(_ candidate: DeskSnapshot, readError: String?) {
        precondition(Thread.isMainThread)
        guard state != .closed else { return }
        primaryPress = nil
        secondaryPress = nil
        canvas.clearPointerGestures()
        if let readError { clear(.unavailable(readError)); return }
        guard accepts?(candidate) == true, candidate.isChecked else { clear(.checking); return }
        // A supported new literal can still have DK4029 in the old resource package while its actual bytes are
        // being prepared. Keep that diagnostic, but present loading until the curated package is rechecked.
        switch resources?(candidate) ?? .pending {
        case .pending: clear(.checking); return
        case .failed(let message): clear(.unavailable(message)); return
        case .ready: break
        }
        let result = Desk.compile(candidate.checked, catalog: candidate.options.catalog)
        guard let program = result.program else {
            if let diagnostic = result.diagnostics.first(where: { $0.severity == .error }) {
                clear(.unavailable(diagnostic.message(in: candidate.options.messageLanguage)))
            } else if let issue = result.issues.first {
                let position = candidate.index.position(utf8: issue.range.lowerBound)
                clear(.unavailable("\(issue.file.path):\(position): \(issue.message)"))
            } else { clear(.unavailable(StudioText[.deskPreviewUnavailable])) }
            return
        }
        do {
            let next = try ProgramRuntime(program: program)
            guard accepts?(candidate) == true else { clear(.checking); return }
            snapshot = candidate
            runtime = next
            resetActionRecords()
            canvas.context = DrawContext(fonts: AppFontResolver())
            project()
        } catch { clear(.unavailable(previewMessage(for: error))) }
    }

    private func environment() throws -> (stamp: EnvironmentStamp, colors: ProgramColorInput) {
        let appearance = canvas.effectiveAppearance
        let values = try colorSource(appearance)
        let stamp = AppSceneEnvironment(scale: Double(canvas.window?.backingScaleFactor ?? 1), appearance: values.appearance,
                                        appearanceName: appearance.name.rawValue).stamp
        return (stamp, values.colors)
    }

    private func project(click: (point: SkinPoint, generation: UInt64, event: MouseEventKind)? = nil,
                         captured: (stamp: EnvironmentStamp, colors: ProgramColorInput)? = nil) {
        guard !projecting, state != .closed, let snapshot, accepts?(snapshot) == true,
              var runtime else { return }
        projecting = true
        defer { projecting = false }
        let context = canvas.context ?? DrawContext(fonts: AppFontResolver())
        canvas.context = context
        let dateInput = ProgramDateInput(instant: clock.now(), timeZone: clock.timeZone(), locale: dateLocale())
        do {
            let input = try captured ?? environment()
            let stamp = input.stamp
            let images: [String: ProgramImageResource]
            switch resources?(snapshot) ?? .pending {
            case .pending: clear(.checking); return
            case .failed(let message): clear(.unavailable(message)); return
            case .ready(let values): images = values
            }
            let measure: (String, TextStyle, Double?) throws -> SkinSize = { text, style, width in
                // Reject an impossible native font before constructing it; never clamp the program's point size.
                let pixels = style.fontSize * (96.0 / 72.0) * stamp.scale
                guard pixels.isFinite, pixels > 0, pixels <= Double(RenderOptions.maxPixels) else {
                    throw PreviewFailure.extent
                }
                let layout = context.text.layout(text, style: style, wrapWidth: width.map { CGFloat($0) }, cycle: 1)
                return SkinSize(width: layout.size.width, height: layout.size.height)
            }
            let needed = runtime.neededSystemProperties(clickAt: click?.point, event: click?.event ?? .leftUp)
            let now = dateInput.instant.timeIntervalSince1970
            let systemInput = sampler.sample(from: system, for: needed, at: now)
            let next: WidgetScene
            var effects: [ProgramEffect] = []
            if let click {
                guard let clicked = try runtime.clickWithEffects(at: click.point, expectedGeneration: click.generation,
                                                     event: click.event,
                                                     environment: stamp, images: images, dateInput: dateInput,
                                                     colorInput: input.colors, systemInput: systemInput, measure: measure) else { return }
                next = clicked.scene
                effects = clicked.effects
            } else {
                next = try runtime.project(environment: stamp, images: images, dateInput: dateInput, colorInput: input.colors,
                                          systemInput: systemInput, measure: measure)
            }
            let size = next.size
            guard size.width.isFinite, size.height.isFinite, size.width >= 0, size.height >= 0 else { throw PreviewFailure.extent }
            let extent = try paintExtent(next)
            let side = max(extent.width, extent.height) * stamp.scale
            guard side.isFinite, side <= Double(RenderOptions.maxPixels) else { throw PreviewFailure.extent }
            let nextClockDelay: TimeInterval?
            if visible, let precision = runtime.clockPrecision {
                nextClockDelay = try precision.delayToNextBoundary(after: dateInput.instant)
            } else { nextClockDelay = nil }
            guard accepts?(snapshot) == true else { clear(.checking); return }
            self.runtime = runtime
            lastColors = input.colors
            scene = next
            canvas.scene = next
            // AppKit maps this enclosing paint viewport; the shared scene and its layout coordinates stay intact.
            canvas.frame = NSRect(origin: .zero, size: extent.size)
            canvas.bounds = extent
            scrollView.maxMagnification = min(RenderOptions.scaleRange.upperBound,
                                              Double(RenderOptions.maxPixels) / max(side, 1))
            if scrollView.magnification > scrollView.maxMagnification {
                scrollView.setMagnification(scrollView.maxMagnification, centeredAt: NSPoint(x: extent.midX, y: extent.midY))
            }
            let hasContent = next.drawingItems.contains {
                switch $0 {
                case .text(let value): return !value.text.isEmpty
                case .fill(let rect, let paint): return rect.width > 0 && rect.height > 0 && paint.color.a > 0
                case .image(let image): return image.path != nil && image.contentFrame.width > 0 && image.contentFrame.height > 0
                case .shape(let shape):
                    return shape.contentFrame.width > 0 && shape.contentFrame.height > 0 && shape.shapes.contains {
                        $0.fill.isVisible || ($0.stroke.isVisible && $0.strokePlan?.isEmpty == false)
                    }
                default: return false
                }
            }
            let interactive = !next.hitMap.entries.isEmpty
            state = hasContent || interactive ? .ready : .empty
            canvas.isHidden = !(hasContent || interactive)
            canvas.needsDisplay = true
            scrollView.contentView.scroll(to: scrollView.contentView.bounds.origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            updateStatus()
            tickScheduler.cancel()
            if let nextClockDelay { tickScheduler.startClockBoundary(after: nextClockDelay, for: self) }
            if !effects.isEmpty {
                recordedEffects.append(contentsOf: effects)
                if recordedEffects.count > Self.recordedEffectLimit {
                    recordedEffects.removeFirst(recordedEffects.count - Self.recordedEffectLimit)
                }
                updateActionRecords()
                onRecordedEffects?(effects)
            }
        } catch PreviewFailure.extent { clear(.unavailable(StudioText[.deskPreviewTooLarge]), keepingProgram: true) }
        catch { clear(.unavailable(previewMessage(for: error)), keepingProgram: true) }
    }

    private func previewMessage(for error: Error) -> String {
        if let error = error as? ProgramRuntimeError, case .invalidText = error {
            return StudioText[.deskPreviewInvalidText]
        }
        if let error = error as? ProgramRuntimeError, error == .missingActionString {
            return StudioText[.deskActionMissingValue]
        }
        return String(describing: error)
    }

    private enum PreviewFailure: Error { case extent }

    /// These static programs emit known path geometry, so its captured visual bounds can enclose centered strokes.
    /// This is a preview viewport, not a new layout, clipping rule or generic ink-coverage claim.
    private func paintExtent(_ scene: WidgetScene) throws -> CGRect {
        do { return try DeskProgramViewport.extent(scene) }
        catch { throw PreviewFailure.extent }
    }

    func refreshEnvironment() {
        guard !projecting, let snapshot, accepts?(snapshot) == true else { return }
        do {
            let input = try environment()
            if scene?.environment != input.stamp || lastColors != input.colors { project(captured: input) }
        } catch { clear(.unavailable(String(describing: error)), keepingProgram: true) }
    }

    private func prepareToDraw() -> Bool {
        guard state != .closed, let snapshot, accepts?(snapshot) == true else {
            if state != .closed { clear(.checking) }
            return false
        }
        switch resources?(snapshot) ?? .pending {
        case .pending: clear(.checking); return false
        case .failed(let message): clear(.unavailable(message)); return false
        case .ready: break
        }
        refreshEnvironment()
        return state == .ready && scene != nil
    }

    private func beginPrimaryPress(at point: SkinPoint) {
        beginPress(at: point, event: .leftUp)
    }

    private func beginSecondaryPress(at point: SkinPoint) {
        beginPress(at: point, event: .rightUp)
    }

    private func beginPress(at point: SkinPoint, event: MouseEventKind) {
        if event == .leftUp { primaryPress = nil } else { secondaryPress = nil }
        guard visible, prepareToDraw(), let snapshot,
              let id = scene?.hitMap.entry(at: point.x, point.y, handling: event, images: nil)?.elementID else { return }
        if event == .leftUp { primaryPress = (snapshot, id) } else { secondaryPress = (snapshot, id) }
    }

    private func endPrimaryPress(at point: SkinPoint?) {
        endPress(at: point, event: .leftUp)
    }

    private func endSecondaryPress(at point: SkinPoint?) {
        endPress(at: point, event: .rightUp)
    }

    private func endPress(at point: SkinPoint?, event: MouseEventKind) {
        let press = event == .leftUp ? primaryPress : secondaryPress
        if event == .leftUp { primaryPress = nil } else { secondaryPress = nil }
        guard visible, let point, let press, accepts?(press.snapshot) == true, prepareToDraw(), let scene,
              scene.hitMap.entry(at: point.x, point.y, handling: event, images: nil)?.elementID == press.element else { return }
        // A legal boundary tick changes the scene, not this checked source session or pressed element identity.
        project(click: (point, scene.generation, event))
    }

    private func clear(_ next: State, keepingProgram: Bool = false) {
        primaryPress = nil
        secondaryPress = nil
        canvas.clearPointerGestures()
        tickScheduler.cancel()
        state = next
        // A current program can recover when a display/font changes; errors retain no previous scene or cache.
        // Pending/failed source checks and closing release that program too.
        if !keepingProgram {
            snapshot = nil
            runtime = nil
            resetActionRecords()
        }
        scene = nil
        lastColors = nil
        canvas.scene = nil
        canvas.context = nil
        canvas.isHidden = true
        canvas.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        canvas.setBoundsOrigin(.zero)
        canvas.needsDisplay = true
        updateStatus()
    }

    private func updateStatus() {
        let message: String
        switch state {
        case .checking: message = StudioText[.deskPreviewChecking]
        case .ready: message = StudioText[.deskPreviewStatic]
        case .empty: message = StudioText[.deskPreviewEmpty]
        case .unavailable(let reason): message = StudioText[.deskPreviewUnavailable] + "\n" + reason
        case .closed: message = ""
        }
        status.stringValue = message
        status.setAccessibilityLabel(message)
        actualButton.isEnabled = state == .ready
        fitButton.isEnabled = state == .ready
        // The existing date/locale refresh path also refreshes the words, once per actual language change.
        if actionRecordsLanguage != StudioText.language { updateActionRecords() }
    }

    private func updateActionRecords() {
        guard isViewLoaded else { return }
        actionRecordsLanguage = StudioText.language
        heading.stringValue = StudioText[.previewOnly]
        fitButton.title = StudioText[.zoomToFit]
        actualButton.title = StudioText[.actualSizeShort]
        scrollView.setAccessibilityLabel(StudioText[.previewOnly])
        let title = StudioText.format(.deskActionRecordsCount, recordedEffects.count)
        actionRecordsButton.title = title
        actionRecordsButton.state = actionRecordsExpanded ? .on : .off
        actionRecordsButton.image = StudioPageStyle.symbol(actionRecordsExpanded ? "chevron.down" : "chevron.right",
                                                          size: 9, weight: .semibold)
        actionRecordsButton.setAccessibilityLabel(title)
        actionRecordsButton.isEnabled = state != .closed
        actionRecordsClearButton.title = StudioText[.logClear]
        actionRecordsClearButton.setAccessibilityLabel(StudioText[.logClear])
        actionRecordsClearButton.isEnabled = state != .closed && !recordedEffects.isEmpty
        actionRecordsNotice.stringValue = StudioText[.deskActionPreviewNotice]
        actionRecordsNotice.setAccessibilityLabel(StudioText[.deskActionPreviewNotice])
        actionRecordsPane.setAccessibilityLabel(StudioText[.previewOnly])
        actionRecordsScrollView.setAccessibilityLabel(title)
        actionRecordsText.setAccessibilityLabel(title)
        let expanded = actionRecordsExpanded && state != .closed
        // A folded pane stays in the hierarchy for its constraints, but reserves no canvas space.
        actionRecordsCanvasCap?.isActive = expanded
        if expanded {
            if !actionRecordsFooter.arrangedSubviews.contains(actionRecordsPane) {
                actionRecordsFooter.addArrangedSubview(actionRecordsPane)
            }
        } else if actionRecordsFooter.arrangedSubviews.contains(actionRecordsPane) {
            actionRecordsFooter.removeArrangedSubview(actionRecordsPane)
        }
        actionRecordsPane.isHidden = !expanded
        let text: String
        if state == .closed || !actionRecordsExpanded { text = "" }
        else if recordedEffects.isEmpty { text = StudioText[.deskActionRecordsEmpty] }
        else {
            text = recordedEffects.enumerated().map { index, effect in
                let sentence: String
                switch effect {
                // These templates already include their separator; preserve every code point in the argument.
                case .copy(let value): sentence = String(format: StudioText[.wouldCopy], value)
                case .open(let value): sentence = String(format: StudioText[.wouldOpen], value)
                }
                return "\(index + 1). \(sentence)"
            }.joined(separator: "\n\n")
        }
        if actionRecordsText.string != text {
            actionRecordsText.string = text
            actionRecordsText.setSelectedRange(NSRange(location: 0, length: 0))
            actionRecordsText.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        view.needsLayout = true
    }

    private func resetActionRecords() {
        recordedEffects.removeAll()
        updateActionRecords()
    }

    @objc func toggleActionRecords() {
        guard state != .closed else { return }
        actionRecordsExpanded.toggle()
        updateActionRecords()
    }

    @objc func clearActionRecords() {
        guard state != .closed else { return }
        resetActionRecords()
    }

    @objc func fit() {
        guard scene != nil, state == .ready, canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
        view.layoutSubtreeIfNeeded()
        let visible = scrollView.contentView.frame.size
        let scale = min(visible.width / canvas.bounds.width, visible.height / canvas.bounds.height)
        setZoom(min(1, scale))
    }

    @objc func actualSize() { setZoom(1) }

    func setZoom(_ value: CGFloat) {
        guard state == .ready, value.isFinite, scene != nil else { return }
        let zoom = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        scrollView.setMagnification(zoom, centeredAt: NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
    }

    func close() {
        precondition(Thread.isMainThread)
        actionRecordsExpanded = false
        clear(.closed)
        accepts = nil
        resources = nil
        onRecordedEffects = nil
        actionRecordsButton.target = nil
        actionRecordsButton.action = nil
        actionRecordsClearButton.target = nil
        actionRecordsClearButton.action = nil
        canvas.beforeDrawing = nil
        canvas.onEnvironmentChange = nil
        canvas.onImageFailure = nil
        canvas.onPrimaryPress = nil
        canvas.onPrimaryRelease = nil
        canvas.onSecondaryPress = nil
        canvas.onSecondaryRelease = nil
    }
}

/// The borrowed CGContext is already in AppKit view coordinates. Only owned bitmap fixtures establish a bitmap
/// transform; this view does not flip the base CTM or ask the compatibility renderer for a Skin.
final class DeskProgramPreviewCanvas: NSView {
    fileprivate var scene: WidgetScene?
    fileprivate var context: DrawContext?
    fileprivate var beforeDrawing: (() -> Bool)?
    fileprivate var onEnvironmentChange: (() -> Void)?
    fileprivate var onImageFailure: (() -> Void)?
    fileprivate var onPrimaryPress: ((SkinPoint) -> Void)?
    fileprivate var onPrimaryRelease: ((SkinPoint?) -> Void)?
    fileprivate var onSecondaryPress: ((SkinPoint) -> Void)?
    fileprivate var onSecondaryRelease: ((SkinPoint?) -> Void)?
    private var primaryEvent: MouseEventKind?
    private var secondaryPressed = false
    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if primaryEvent == .rightUp { onSecondaryRelease?(nil) }
        primaryEvent = nil
        onPrimaryRelease?(nil)
        guard event.buttonNumber == 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.control) {
            onSecondaryRelease?(nil)
            guard !event.modifierFlags.contains(.option) else { return }
            primaryEvent = .rightUp
            onSecondaryPress?(SkinPoint(x: point.x, y: point.y))
        } else {
            primaryEvent = .leftUp
            onPrimaryPress?(SkinPoint(x: point.x, y: point.y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        let selected = primaryEvent
        primaryEvent = nil
        guard event.buttonNumber == 0, let selected else { return }
        let point = convert(event.locationInWindow, from: nil)
        if selected == .leftUp { onPrimaryRelease?(SkinPoint(x: point.x, y: point.y)) }
        else { onSecondaryRelease?(event.modifierFlags.contains(.option) ? nil : SkinPoint(x: point.x, y: point.y)) }
    }

    override func mouseDragged(with event: NSEvent) {
        if primaryEvent == .rightUp { primaryEvent = nil; onSecondaryRelease?(nil) }
    }

    override func rightMouseDown(with event: NSEvent) {
        secondaryPressed = false
        onSecondaryRelease?(nil)
        guard !event.modifierFlags.contains(.option) else { return }
        secondaryPressed = true
        let point = convert(event.locationInWindow, from: nil)
        onSecondaryPress?(SkinPoint(x: point.x, y: point.y))
    }

    override func rightMouseDragged(with event: NSEvent) {
        secondaryPressed = false
        onSecondaryRelease?(nil)
    }

    override func rightMouseUp(with event: NSEvent) {
        let pressed = secondaryPressed
        secondaryPressed = false
        guard pressed else { return }
        let point = convert(event.locationInWindow, from: nil)
        onSecondaryRelease?(event.modifierFlags.contains(.option) ? nil : SkinPoint(x: point.x, y: point.y))
    }

    fileprivate func clearPointerGestures() {
        primaryEvent = nil
        secondaryPressed = false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard beforeDrawing?() == true, let scene, let context,
              let destination = NSGraphicsContext.current?.cgContext else { return }
        // Qualify the actual renderer's drawn-size input before borrowing any destination pixels. A real
        // decoding failure clears the owner, rather than treating a valid header/thumbnail as a successful draw.
        for item in scene.drawingItems {
            guard case .image(let image) = item, var path = image.path else { continue }
            if image.naturalSize != nil {
                guard ImageRenderer.preparedNaturalImage(image, in: destination) != nil else { onImageFailure?(); return }
                continue
            }
            let fit = image.preserveAspectRatio == 1
            if image.decodesAtDrawnSize, !image.tile {
                path = ImageRenderer.drawnDecodePath(path, options: image.options, drawn: image.contentFrame.cgRect.size,
                                                    fit: fit, in: destination)
            }
            guard PreparedImage(path: path, options: image.options) != nil else { onImageFailure?(); return }
        }
        destination.saveGState()
        defer { destination.restoreGState() }
        DesksetDraw.DrawExecutor.draw(scene: scene, in: destination, context: context, cycle: 1,
                                     target: DrawTarget.capture(destination, glass: .none))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEnvironmentChange?()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onEnvironmentChange?()
        needsDisplay = true
    }
}
