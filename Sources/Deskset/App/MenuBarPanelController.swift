import AppKit
import SwiftUI

/// Deskset's menu bar panel, opened on right-clicking the status bar icon:
/// header (`AppIcon` + `Deskset`), `组件库` (`Widget Library`), `安装皮肤…` (`Install Skin…`),
/// `设置…` (`Settings…`), `检查更新…` (`Check for Updates…` with update reminder badge),
/// `关于 Deskset` (`About Deskset`), and `退出 Deskset` (`Quit Deskset`).
final class MenuBarPanelController: NSObject, NSWindowDelegate {
    static let panelWidth: CGFloat = 320

    struct ItemSummary: Equatable {
        let title: String
        let badge: String?
        let isEnabled: Bool
    }

    private unowned let app: AppController
    private var panel: MenuBarFloatingPanel?
    private weak var highlightedButton: NSStatusBarButton?
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var appResignObserver: NSObjectProtocol?
    private(set) var didRequestOpenTesting = false

    init(app: AppController) {
        self.app = app
        super.init()
    }

    deinit {
        removeMonitors()
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    var windowForTesting: NSWindow? {
        ensurePanel()
        return panel
    }

    var itemsForTesting: [ItemSummary] {
        let updateVersion = app.updates.availableRelease?.version.description
        let isChecking = app.updates.isChecking
        return [
            ItemSummary(title: L("Widget Library"), badge: nil, isEnabled: true),
            ItemSummary(title: L("Install Skin…"), badge: nil, isEnabled: true),
            ItemSummary(title: L("Settings…"), badge: nil, isEnabled: true),
            ItemSummary(
                title: isChecking ? L("Checking for Updates…") : L("Check for Updates…"),
                badge: updateVersion.map { "v\($0)" },
                isEnabled: updateVersion != nil || !isChecking
            ),
            ItemSummary(title: L("About Deskset"), badge: nil, isEnabled: true),
            ItemSummary(title: L("Quit Deskset"), badge: nil, isEnabled: true),
        ]
    }

    func toggle(relativeTo button: NSStatusBarButton?) {
        if isVisible || (!app.presentsWindows && didRequestOpenTesting) {
            close()
        } else {
            show(relativeTo: button)
        }
    }

    func refreshIfLoaded() {
        guard let window = panel else { return }
        AppTheme.apply(app.state.uiTheme, to: window)
        updateRootView(in: window)
        window.contentView?.layoutSubtreeIfNeeded()
        let fittingHeight = max(168, ceil(window.contentView?.fittingSize.height ?? 186))
        if window.isVisible {
            var frame = window.frame
            let topY = frame.maxY
            frame.size = NSSize(width: Self.panelWidth, height: fittingHeight)
            frame.origin.y = topY - fittingHeight
            window.setFrame(frame, display: true)
        } else {
            window.setContentSize(NSSize(width: Self.panelWidth, height: fittingHeight))
        }
    }

    func show(relativeTo button: NSStatusBarButton?) {
        let window = ensurePanel()
        AppTheme.apply(app.state.uiTheme, to: window)
        updateRootView(in: window)
        window.contentView?.layoutSubtreeIfNeeded()
        let fittingHeight = max(168, ceil(window.contentView?.fittingSize.height ?? 186))
        let size = NSSize(width: Self.panelWidth, height: fittingHeight)

        if let button, let buttonWindow = button.window {
            let buttonRectInWindow = button.convert(button.bounds, to: nil)
            let screenRect = buttonWindow.convertToScreen(buttonRectInWindow)
            let screen = buttonWindow.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let minX = visible.minX + 8
            let maxX = max(minX, visible.maxX - size.width - 8)
            let x = min(max(round(screenRect.midX - size.width / 2), minX), maxX)
            let y = round(screenRect.minY - size.height - 6)
            window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
            highlightedButton = button
            button.highlight(true)
        } else {
            window.setContentSize(size)
            window.center()
        }

        didRequestOpenTesting = true
        guard app.presentsWindows else { return }
        installMonitors()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        didRequestOpenTesting = false
        removeMonitors()
        highlightedButton?.highlight(false)
        highlightedButton = nil
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// Triggers one of the panel's primary actions directly for headless self-tests.
    func performUpdateActionForTesting() {
        triggerUpdateAction()
    }

    func performInstallSkinForTesting() {
        leave { self.app.installSkinAction() }
    }

    func performAboutForTesting() {
        leave { _ = SettingsWindowController.show(app: self.app, pane: .about) }
    }

    @discardableResult
    private func ensurePanel() -> MenuBarFloatingPanel {
        if let panel { return panel }
        let created = MenuBarFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        created.isReleasedWhenClosed = false
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.level = .popUpMenu
        created.collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace, .fullScreenAuxiliary]
        created.delegate = self
        created.onCancel = { [weak self] in self?.close() }
        AppTheme.register(created, app: app)
        updateRootView(in: created)
        panel = created
        return created
    }

    private func triggerUpdateAction() {
        if app.updates.availableRelease != nil {
            leave { self.app.showAvailableUpdateAction() }
        } else if !app.updates.isChecking {
            leave { self.app.checkForUpdatesAction() }
        }
    }

    private func updateRootView(in window: MenuBarFloatingPanel) {
        let updateVersion = app.updates.availableRelease?.version.description
        let isChecking = app.updates.isChecking
        let rootView = DesksetMenuBarPanelView(
            updateVersion: updateVersion,
            isCheckingUpdates: isChecking,
            onOpenLibrary: { [weak self] in
                guard let self else { return }
                self.leave { self.app.manageAction() }
            },
            onInstallSkin: { [weak self] in
                guard let self else { return }
                self.leave { self.app.installSkinAction() }
            },
            onOpenSettings: { [weak self] in
                guard let self else { return }
                self.leave { self.app.settingsAction() }
            },
            onCheckUpdates: { [weak self] in
                self?.triggerUpdateAction()
            },
            onOpenAbout: { [weak self] in
                guard let self else { return }
                self.leave { _ = SettingsWindowController.show(app: self.app, pane: .about) }
            },
            onQuit: { [weak self] in
                guard let self else { return }
                self.close()
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
        )

        let container = MenuBarCardContainerView(rootView: rootView)
        window.contentView = container
    }

    private func leave(_ action: @escaping () -> Void) {
        close()
        if app.presentsWindows {
            DispatchQueue.main.async(execute: action)
        } else {
            action()
        }
    }

    private func installMonitors() {
        removeMonitors()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.close()
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if event.window !== panel && event.window !== self.highlightedButton?.window {
                    self.close()
                }
                return event
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if event.keyCode == 53 { // Escape
                self.close()
                return nil
            }
            if flags == [.command], chars == "," {
                self.leave { self.app.settingsAction() }
                return nil
            }
            if (flags == [.command, .shift] && chars == ",") || (flags == [.command] && chars == "n") {
                self.leave { self.app.manageAction() }
                return nil
            }
            if flags == [.command], chars == "q" {
                self.close()
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return nil
            }
            return event
        }
        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.close()
        }
    }

    private func removeMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
    }

    /// Off-screen render for `--snapshot-ui` and self-tests.
    func snapshot() -> NSBitmapImageRep? {
        let window = ensurePanel()
        AppTheme.apply(app.state.uiTheme, to: window)
        updateRootView(in: window)
        guard let view = window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        let height = max(168, ceil(view.fittingSize.height))
        window.setContentSize(NSSize(width: Self.panelWidth, height: height))
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: Int(bounds.width * 2),
                  pixelsHigh: Int(bounds.height * 2),
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }
}

private final class MenuBarFloatingPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private final class MenuBarCardContainerView<Content: View>: NSVisualEffectView {
    private let hostingView: NSHostingView<Content>

    init(rootView: Content) {
        self.hostingView = NSHostingView(rootView: rootView)
        super.init(frame: NSRect(x: 0, y: 0, width: MenuBarPanelController.panelWidth, height: 280))
        material = .popover
        state = .active
        blendingMode = .behindWindow
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        updateBorderColor()

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: MenuBarPanelController.panelWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let s = hostingView.fittingSize
        return NSSize(width: MenuBarPanelController.panelWidth, height: s.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.borderColor = NSColor(white: isDark ? 1.0 : 0.0, alpha: isDark ? 0.14 : 0.10).cgColor
    }
}

// MARK: - SwiftUI Menu Bar Panel View

struct DesksetMenuBarPanelView: View {
    let updateVersion: String?
    let isCheckingUpdates: Bool
    let onOpenLibrary: () -> Void
    let onInstallSkin: () -> Void
    let onOpenSettings: () -> Void
    let onCheckUpdates: () -> Void
    let onOpenAbout: () -> Void
    let onQuit: () -> Void

    @Environment(\.colorScheme) private var scheme

    static let brandOrange = Color(red: 1.0, green: 107.0 / 255.0, blue: 44.0 / 255.0)

    var body: some View {
        VStack(spacing: 0) {
            header
            MenuPanelRule()
            VStack(spacing: 0) {
                MenuPanelRow(
                    symbol: "square.grid.2x2",
                    title: L("Widget Library"),
                    shortcut: "⇧⌘,",
                    action: onOpenLibrary
                )
                MenuPanelRow(
                    symbol: "square.and.arrow.down",
                    title: L("Install Skin…"),
                    action: onInstallSkin
                )
            }
            .padding(.vertical, 4)
            MenuPanelRule()
            VStack(spacing: 0) {
                MenuPanelRow(
                    symbol: "gearshape",
                    title: L("Settings…"),
                    shortcut: "⌘,",
                    action: onOpenSettings
                )
                updateRow
                MenuPanelRow(
                    symbol: "info.circle",
                    title: L("About Deskset"),
                    action: onOpenAbout
                )
            }
            .padding(.vertical, 4)
            MenuPanelRule()
            VStack(spacing: 0) {
                MenuPanelRow(
                    symbol: "power",
                    title: L("Quit Deskset"),
                    shortcut: "⌘Q",
                    action: onQuit
                )
            }
            .padding(.vertical, 4)
        }
        .frame(width: MenuBarPanelController.panelWidth)
        .background(
            (scheme == .dark ? Color(white: 0.13).opacity(0.82) : Color(white: 0.975).opacity(0.86))
        )
    }

    private var updateRow: some View {
        let hasUpdate = updateVersion != nil
        let rowTitle = (isCheckingUpdates && !hasUpdate)
            ? L("Checking for Updates…")
            : L("Check for Updates…")

        return MenuPanelRow(
            symbol: hasUpdate ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath",
            filled: hasUpdate,
            tint: hasUpdate ? Self.brandOrange : nil,
            title: rowTitle,
            badgeText: updateVersion.map { "v\($0)" },
            badgeHelp: updateVersion.map { L("Update to Deskset %@…", $0) },
            isDisabled: isCheckingUpdates && !hasUpdate,
            action: onCheckUpdates
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcon.image(size: 64))
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
            Text("Deskset")
                .font(.system(size: 14, weight: .semibold))
                .fixedSize()
            Spacer(minLength: 8)
            Text(L("Version %@", AppVersion.current))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

private struct MenuPanelRow: View {
    let symbol: String
    var filled = false
    var tint: Color? = nil
    let title: String
    var shortcut: String? = nil
    var badgeText: String? = nil
    var badgeHelp: String? = nil
    var isDisabled = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MenuPanelBadge(symbol: symbol, tint: tint, filled: filled)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(isDisabled ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let badgeText {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 5, height: 5)
                        Text(badgeText)
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .lineLimit(1)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(DesksetMenuBarPanelView.brandOrange))
                    .help(badgeHelp ?? "")
                } else if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .disabled(isDisabled)
        .buttonStyle(MenuPanelRowStyle(hovered: hovered && !isDisabled))
        .onHover { hovered = $0 }
    }
}

private struct MenuPanelRowStyle: ButtonStyle {
    let hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.07 : 0))
            )
            .padding(.horizontal, 6)
    }
}

private struct MenuPanelRule: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.horizontal, 14)
    }
}

private struct MenuPanelBadge: View {
    let symbol: String
    var tint: Color? = nil
    var filled = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(filled ? .white : (tint ?? .primary))
            .frame(width: 24, height: 24)
            .background(
                Circle()
                    .fill(
                        filled
                            ? (tint ?? Color.accentColor)
                            : (tint ?? Color.primary).opacity(tint == nil ? 0.09 : 0.14)
                    )
            )
    }
}
