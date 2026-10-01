import AppKit
import DeskLanguage
import DesksetCore
import DesksetDraw

/// A shared program's editor preview. The document checker owns source/version truth; this main-thread owner
/// only compiles its current finished snapshot and borrows the view's drawing destination. It activates no widget.
final class DeskProgramPreviewController: NSViewController {
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
    private var accepts: ((DeskSnapshot) -> Bool)?
    private var projecting = false
    private(set) var state: State = .checking
    private(set) var scene: WidgetScene?

    init(accepts: @escaping (DeskSnapshot) -> Bool) {
        self.accepts = accepts
        super.init(nibName: nil, bundle: nil)
        canvas.beforeDrawing = { [weak self] in self?.prepareToDraw() ?? false }
        canvas.onEnvironmentChange = { [weak self] in self?.refreshEnvironment() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
        if let readError { clear(.unavailable(readError)); return }
        guard accepts?(candidate) == true, candidate.isChecked else { clear(.checking); return }
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
        } catch { clear(.unavailable(String(describing: error))) }
    }

    private func environment() -> EnvironmentStamp {
        AppSceneEnvironment(scale: Double(canvas.window?.backingScaleFactor ?? 1),
                            appearance: MacAppearance.values(for: canvas.effectiveAppearance),
                            appearanceName: canvas.effectiveAppearance.name.rawValue).stamp
    }

    private func project() {
        guard !projecting, state != .closed, let snapshot, accepts?(snapshot) == true,
              var runtime else { return }
        projecting = true
        defer { projecting = false }
        let context = canvas.context ?? DrawContext(fonts: AppFontResolver())
        canvas.context = context
        let stamp = environment()
        do {
            let next = try runtime.project(environment: stamp) { text, style, width in
                // Reject an impossible native font before constructing it; never clamp the program's point size.
                let pixels = style.fontSize * (96.0 / 72.0) * stamp.scale
                guard pixels.isFinite, pixels > 0, pixels <= Double(RenderOptions.maxPixels) else {
                    throw PreviewFailure.extent
                }
                let layout = context.text.layout(text, style: style, wrapWidth: width.map { CGFloat($0) }, cycle: 1)
                return SkinSize(width: layout.size.width, height: layout.size.height)
            }
            let size = next.size
            let side = max(size.width, size.height) * stamp.scale
            guard size.width.isFinite, size.height.isFinite, size.width >= 0, size.height >= 0,
                  side.isFinite, side <= Double(RenderOptions.maxPixels) else { throw PreviewFailure.extent }
            guard accepts?(snapshot) == true else { clear(.checking); return }
            self.runtime = runtime
            scene = next
            canvas.scene = next
            canvas.frame = NSRect(x: 0, y: 0, width: max(size.width, 1), height: max(size.height, 1))
            scrollView.maxMagnification = min(RenderOptions.scaleRange.upperBound,
                                              Double(RenderOptions.maxPixels) / max(side, 1))
            if scrollView.magnification > scrollView.maxMagnification {
                scrollView.setMagnification(scrollView.maxMagnification, centeredAt: NSPoint(x: size.width / 2, y: size.height / 2))
            }
            let hasContent = next.drawingItems.contains {
                switch $0 {
                case .text(let value): return !value.text.isEmpty
                case .fill(let rect, let paint): return rect.width > 0 && rect.height > 0 && paint.color.a > 0
                case .shape(let shape):
                    return shape.contentFrame.width > 0 && shape.contentFrame.height > 0 && shape.shapes.contains { $0.fill.isVisible }
                default: return false
                }
            }
            state = hasContent ? .ready : .empty
            canvas.isHidden = !hasContent
            canvas.needsDisplay = true
            scrollView.contentView.scroll(to: scrollView.contentView.bounds.origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            updateStatus()
        } catch PreviewFailure.extent { clear(.unavailable(StudioText[.deskPreviewTooLarge]), keepingProgram: true) }
        catch { clear(.unavailable(String(describing: error)), keepingProgram: true) }
    }

    private enum PreviewFailure: Error { case extent }

    func refreshEnvironment() {
        guard !projecting, let snapshot, accepts?(snapshot) == true else { return }
        if scene?.environment != environment() { project() }
    }

    private func prepareToDraw() -> Bool {
        guard state != .closed, let snapshot, accepts?(snapshot) == true else {
            if state != .closed { clear(.checking) }
            return false
        }
        refreshEnvironment()
        return state == .ready && scene != nil
    }

    private func clear(_ next: State, keepingProgram: Bool = false) {
        state = next
        // A current program can recover when a display/font changes; errors retain no previous scene or cache.
        // Pending/failed source checks and closing release that program too.
        if !keepingProgram {
            snapshot = nil
            runtime = nil
        }
        scene = nil
        canvas.scene = nil
        canvas.context = nil
        canvas.isHidden = true
        canvas.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
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
        guard let scene, state == .ready, scene.size.width > 0, scene.size.height > 0 else { return }
        view.layoutSubtreeIfNeeded()
        let visible = scrollView.contentView.frame.size
        let scale = min(visible.width / scene.size.width, visible.height / scene.size.height)
        setZoom(min(1, scale))
    }

    @objc func actualSize() { setZoom(1) }

    func setZoom(_ value: CGFloat) {
        guard state == .ready, value.isFinite, let scene else { return }
        let zoom = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        scrollView.setMagnification(zoom, centeredAt: NSPoint(x: scene.size.width / 2, y: scene.size.height / 2))
    }

    func close() {
        precondition(Thread.isMainThread)
        clear(.closed)
        accepts = nil
        canvas.beforeDrawing = nil
        canvas.onEnvironmentChange = nil
    }
}

/// The borrowed CGContext is already in AppKit view coordinates. Only owned bitmap fixtures establish a bitmap
/// transform; this view does not flip the base CTM or ask the compatibility renderer for a Skin.
final class DeskProgramPreviewCanvas: NSView {
    fileprivate var scene: WidgetScene?
    fileprivate var context: DrawContext?
    fileprivate var beforeDrawing: (() -> Bool)?
    fileprivate var onEnvironmentChange: (() -> Void)?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard beforeDrawing?() == true, let scene, let context,
              let destination = NSGraphicsContext.current?.cgContext else { return }
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
