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
    private var snapshot: DeskSnapshot?
    private var runtime: ProgramRuntime?
    private var resources: ((DeskSnapshot) -> DeskProgramResources.Input)?
    private var accepts: ((DeskSnapshot) -> Bool)?
    private var projecting = false
    private var primaryPress: (snapshot: DeskSnapshot, element: ElementID)?
    private let clock: SkinClock
    let executor: SkinExecutor
    private let dateLocale: () -> Locale
    private let colorSource: (NSAppearance) throws -> MacAppearance.ProgramValues
    private var lastColors: ProgramColorInput?
    private let tickScheduler = TickScheduler()
    private var visible = false
    var isClosed: Bool { state == .closed }
    var updateMilliseconds: Int { runtime?.clockPrecision == .second ? 1000 : 60_000 }
    private(set) var state: State = .checking
    private(set) var scene: WidgetScene?

    init(resources: @escaping (DeskSnapshot) -> DeskProgramResources.Input = { _ in .ready([:]) },
         clock: SkinClock = .live, executor: SkinExecutor = MainSkinExecutor.shared,
         dateLocale: @escaping () -> Locale = DeskProgramPreviewController.currentDateLocale,
         colors: @escaping (NSAppearance) throws -> MacAppearance.ProgramValues = MacAppearance.programValues(for:),
         accepts: @escaping (DeskSnapshot) -> Bool) {
        self.clock = clock
        self.executor = executor
        self.dateLocale = dateLocale
        self.colorSource = colors
        self.resources = resources
        self.accepts = accepts
        super.init(nibName: nil, bundle: nil)
        canvas.beforeDrawing = { [weak self] in self?.prepareToDraw() ?? false }
        canvas.onEnvironmentChange = { [weak self] in self?.refreshEnvironment() }
        canvas.onImageFailure = { [weak self] in self?.clear(.unavailable("Cannot decode the prepared image for this drawing")) }
        canvas.onPrimaryPress = { [weak self] point in self?.beginPrimaryPress(at: point) }
        canvas.onPrimaryRelease = { [weak self] point in self?.endPrimaryPress(at: point) }
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
        if value { updateForTick() } else { primaryPress = nil; tickScheduler.cancel() }
    }

    func updateForTick() {
        precondition(executor.isCurrent && Thread.isMainThread)
        tickScheduler.cancel()
        guard visible, state != .closed, let snapshot else { return }
        guard accepts?(snapshot) == true else { clear(.checking); return }
        project()
    }

    func notifySystemWake() { updateForTick() }

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
        for child in [backdrop, scrollView, toolbar, status] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
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
            status.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        view = container
        updateStatus()
    }

    /// A stale or pending result cannot borrow an earlier picture. The existing checker supplies all four guards.
    func show(_ candidate: DeskSnapshot, readError: String?) {
        precondition(Thread.isMainThread)
        guard state != .closed else { return }
        primaryPress = nil
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

    private func project(click: (point: SkinPoint, generation: UInt64)? = nil,
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
            let next: WidgetScene
            if let click {
                guard let clicked = try runtime.click(at: click.point, expectedGeneration: click.generation,
                                                     environment: stamp, images: images, dateInput: dateInput,
                                                     colorInput: input.colors, measure: measure) else { return }
                next = clicked
            } else {
                next = try runtime.project(environment: stamp, images: images, dateInput: dateInput, colorInput: input.colors, measure: measure)
            }
            let size = next.size
            guard size.width.isFinite, size.height.isFinite, size.width >= 0, size.height >= 0 else { throw PreviewFailure.extent }
            let extent = try paintExtent(next)
            let side = max(extent.width, extent.height) * stamp.scale
            guard side.isFinite, side <= Double(RenderOptions.maxPixels) else { throw PreviewFailure.extent }
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
            if visible, let precision = runtime.clockPrecision {
                tickScheduler.startClockBoundary(after: try precision.delayToNextBoundary(after: dateInput.instant), for: self)
            }
        } catch PreviewFailure.extent { clear(.unavailable(StudioText[.deskPreviewTooLarge]), keepingProgram: true) }
        catch { clear(.unavailable(previewMessage(for: error)), keepingProgram: true) }
    }

    private func previewMessage(for error: Error) -> String {
        if let error = error as? ProgramRuntimeError, case .invalidText = error {
            return StudioText[.deskPreviewInvalidText]
        }
        return String(describing: error)
    }

    private enum PreviewFailure: Error { case extent }

    /// These static programs emit known path geometry, so its captured visual bounds can enclose centered strokes.
    /// This is a preview viewport, not a new layout, clipping rule or generic ink-coverage claim.
    private func paintExtent(_ scene: WidgetScene) throws -> CGRect {
        var result = CGRect(x: 0, y: 0, width: max(scene.size.width, 1), height: max(scene.size.height, 1))
        for item in scene.drawingItems {
            guard case .shape(let draw) = item else { continue }
            for shape in draw.shapes where shape.fill.isVisible || (shape.stroke.isVisible && shape.strokePlan?.isEmpty == false) {
                let b = shape.visualBounds
                let x0 = draw.contentFrame.x + b.minX, y0 = draw.contentFrame.y + b.minY
                let x1 = draw.contentFrame.x + b.maxX, y1 = draw.contentFrame.y + b.maxY
                guard [x0, y0, x1, y1, x1 - x0, y1 - y0].allSatisfy(\.isFinite), x1 >= x0, y1 >= y0 else {
                    throw PreviewFailure.extent
                }
                result = result.union(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            }
        }
        guard [result.minX, result.minY, result.maxX, result.maxY, result.width, result.height].allSatisfy(\.isFinite) else {
            throw PreviewFailure.extent
        }
        return result
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
        primaryPress = nil
        guard visible, prepareToDraw(), let snapshot,
              let id = scene?.hitMap.entry(at: point.x, point.y, handling: .leftUp, images: nil)?.elementID else { return }
        primaryPress = (snapshot, id)
    }

    private func endPrimaryPress(at point: SkinPoint?) {
        let press = primaryPress
        primaryPress = nil
        guard visible, let point, let press, accepts?(press.snapshot) == true, prepareToDraw(), let scene,
              scene.hitMap.entry(at: point.x, point.y, handling: .leftUp, images: nil)?.elementID == press.element else { return }
        // A legal boundary tick changes the scene, not this checked source session or pressed element identity.
        project(click: (point, scene.generation))
    }

    private func clear(_ next: State, keepingProgram: Bool = false) {
        primaryPress = nil
        tickScheduler.cancel()
        state = next
        // A current program can recover when a display/font changes; errors retain no previous scene or cache.
        // Pending/failed source checks and closing release that program too.
        if !keepingProgram {
            snapshot = nil
            runtime = nil
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
        clear(.closed)
        accepts = nil
        resources = nil
        canvas.beforeDrawing = nil
        canvas.onEnvironmentChange = nil
        canvas.onImageFailure = nil
        canvas.onPrimaryPress = nil
        canvas.onPrimaryRelease = nil
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
    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0, !event.modifierFlags.contains(.control) else { onPrimaryRelease?(nil); return }
        let point = convert(event.locationInWindow, from: nil)
        onPrimaryPress?(SkinPoint(x: point.x, y: point.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard event.buttonNumber == 0, !event.modifierFlags.contains(.control) else { onPrimaryRelease?(nil); return }
        let point = convert(event.locationInWindow, from: nil)
        onPrimaryRelease?(SkinPoint(x: point.x, y: point.y))
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
