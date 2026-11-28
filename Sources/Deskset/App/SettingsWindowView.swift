import AppKit
import DesksetCore
import SwiftUI

/// Observable model bridging `SettingsWindowController` and `DesksetSettingsRootView`.
final class DesksetSettingsViewModel: ObservableObject {
    struct EditorItem: Identifiable {
        let id: Int
        let title: String
        let icon: NSImage?
        let isSeparator: Bool
    }

    struct LanguageItem: Identifiable {
        let id: Int
        let title: String
        let isSeparator: Bool
    }

    @Published var pane: SettingsWindowController.Pane = .general

    // General
    @Published var languageItems: [LanguageItem] = []
    @Published var selectedLanguageIndex: Int = 0
    @Published var uiTheme: AppUITheme = .auto
    @Published var launchAtLogin: Bool = false
    @Published var launchAtLoginAvailable: Bool = false
    @Published var automaticallyChecksUpdates: Bool = true
    @Published var isCheckingUpdates: Bool = false
    @Published var checkUpdatesTitle: String = ""
    @Published var availableUpdateVersion: String? = nil
    @Published var updateStatusText: String = ""

    // Desktop & Skins
    @Published var defaultZoomPercent: Int = 100
    @Published var forceDefaultZoom: Bool = false
    @Published var disableDragging: Bool = false
    @Published var skinsFolderDisplayPath: String = ""
    @Published var settingsFolderDisplayPath: String = ""

    // Editor
    @Published var editorItems: [EditorItem] = []
    @Published var selectedEditorIndex: Int = 0
    @Published var editorHelperText: String = ""
    @Published var codeFontSize: Int = 13
    @Published var liveReload: Bool = true

    // Debug & Log
    @Published var developerMode: Bool = true
    @Published var fileLoggingEnabled: Bool = false
    @Published var recentLogs: [Log.Line] = []
    @Published var showErrorLogs: Bool = true
    @Published var showWarningLogs: Bool = true
    @Published var showNoticeLogs: Bool = true
    @Published var showDebugLogs: Bool = true
}

/// Deskset Settings with 4 flat preference categories (`General`, `Desktop & Skins`, `Editor`, `Debug & Log`)
/// and `About Deskset` anchored at the bottom of the left sidebar.
struct DesksetSettingsRootView: View {
    @ObservedObject var model: DesksetSettingsViewModel
    weak var controller: SettingsWindowController?
    let app: AppController

    private static let topHeight: CGFloat = 56
    private static let topAnchorID = "settings.top"

    @State private var defaultZoomText: String = "100"
    @State private var fontSizeText: String = "13"

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                sidebar
                Divider()
                detailArea(proxy: proxy)
            }
            .font(.system(size: 13))
            .frame(minWidth: 800, minHeight: 540)
            .background(DeskProPalette.page)
            .onAppear {
                defaultZoomText = String(model.defaultZoomPercent)
                fontSizeText = String(model.codeFontSize)
            }
            .onChange(of: model.defaultZoomPercent) { newValue in
                defaultZoomText = String(newValue)
            }
            .onChange(of: model.codeFontSize) { newValue in
                fontSizeText = String(newValue)
            }
            .onChange(of: model.pane) { _ in
                proxy.scrollTo(Self.topAnchorID, anchor: .top)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Left Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            sidebarHeader
                .padding(.top, 26)
                .frame(maxWidth: .infinity, minHeight: Self.topHeight + 26, maxHeight: Self.topHeight + 26, alignment: .leading)
                .background(WindowDragArea())

            ForEach(SettingsWindowController.Pane.mainPanes, id: \.rawValue) { item in
                sidebarRow(for: item)
            }

            Spacer(minLength: 12)

            Divider()
                .padding(.horizontal, 6)
                .padding(.bottom, 4)

            sidebarRow(for: .about)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 10)
        .frame(width: 240)
        .background(DeskProPalette.utilitySidebar)
    }

    private func sidebarRow(for item: SettingsWindowController.Pane) -> some View {
        let selected = model.pane == item
        return Button {
            controller?.select(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.sidebarSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(item.sidebarTint)
                    )
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .white : .primary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            DeskAppMark(size: 30)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Deskset")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    Text(L("Version %@", AppVersion.current))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if model.availableUpdateVersion != nil {
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Button(L("Update…")) {
                            app.showAvailableUpdateAction()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.accentColor)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
    }

    // MARK: - Right Detail Area

    private func detailArea(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.pane.title)
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 32)
            .frame(height: Self.topHeight)
            .background(WindowDragArea())

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.topAnchorID)
                    switch model.pane {
                    case .general:
                        generalPage
                    case .desktop:
                        desktopPage
                    case .editor:
                        editorPage
                    case .debug:
                        debugPage
                    case .about:
                        aboutPage
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 6)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 1. General Page

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeskProSettingsGroup(title: L("Startup & Language")) {
                DeskProSettingsRow(
                    title: L("Launch Deskset at login"),
                    detail: model.launchAtLoginAvailable
                        ? L("Deskset opens with your skins when you log in.")
                        : L("Available when Deskset runs from the Applications folder.")
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { _ in controller?.toggleLoginFromUI() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!model.launchAtLoginAvailable)
                }

                DeskProSettingsRow(title: L("Language"), divider: false) {
                    Picker("", selection: Binding(
                        get: { model.selectedLanguageIndex },
                        set: { controller?.chooseLanguageIndexFromUI($0) }
                    )) {
                        ForEach(model.languageItems) { item in
                            if item.isSeparator {
                                Divider()
                            } else {
                                Text(item.title).tag(item.id)
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            DeskProSettingsGroup(title: L("Appearance")) {
                HStack(alignment: .top, spacing: 10) {
                    appearancePreviewCard(
                        selected: model.uiTheme == .auto,
                        darkPreview: false,
                        splitAuto: true,
                        title: L("Auto"),
                        subtitle: L("Follows macOS Light and Dark Mode automatically.")
                    ) {
                        controller?.chooseThemeFromUI(.auto)
                    }

                    appearancePreviewCard(
                        selected: model.uiTheme == .light,
                        darkPreview: false,
                        splitAuto: false,
                        title: L("Light"),
                        subtitle: L("Keeps Deskset windows and menus in a fixed appearance.")
                    ) {
                        controller?.chooseThemeFromUI(.light)
                    }

                    appearancePreviewCard(
                        selected: model.uiTheme == .dark,
                        darkPreview: true,
                        splitAuto: false,
                        title: L("Dark"),
                        subtitle: L("Keeps Deskset windows and menus in a fixed appearance.")
                    ) {
                        controller?.chooseThemeFromUI(.dark)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
            }

            DeskProSettingsGroup(title: L("Software Update")) {
                DeskProSettingsRow(
                    title: L("Automatically check for updates"),
                    detail: L("Deskset checks once a day and downloads updates itself; you choose when to install them.")
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.automaticallyChecksUpdates },
                        set: { controller?.setAutomaticUpdatesFromUI($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }

                DeskProSettingsRow(
                    title: L("Updates:"),
                    detail: model.updateStatusText,
                    divider: false
                ) {
                    HStack(spacing: 8) {
                        if model.availableUpdateVersion != nil {
                            Button(L("Update…")) {
                                app.showAvailableUpdateAction()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        Button(model.checkUpdatesTitle.isEmpty ? L("Check for Updates…") : model.checkUpdatesTitle) {
                            app.checkForUpdatesAction()
                        }
                        .disabled(model.isCheckingUpdates)
                    }
                }
            }
        }
    }

    // MARK: - 2. Desktop & Skins Page

    private var desktopPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Desktop Interaction"))
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 2)

                HStack(alignment: .top, spacing: 14) {
                    desktopModeVisualCard(
                        selected: !model.disableDragging,
                        isLocked: false,
                        title: L("Interactive Desktop"),
                        caption: L("Drag widgets freely on the desktop and right-click any widget for quick actions.")
                    ) {
                        controller?.setDisableDraggingFromUI(false)
                    }

                    desktopModeVisualCard(
                        selected: model.disableDragging,
                        isLocked: true,
                        title: L("Locked Positions"),
                        caption: L("Prevent accidental mouse dragging while keeping buttons and actions interactive.")
                    ) {
                        controller?.setDisableDraggingFromUI(true)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 22)

            DeskProSettingsGroup(title: L("Global Zoom")) {
                DeskProSettingsRow(title: L("Default zoom")) {
                    HStack(spacing: 6) {
                        TextField("100", text: $defaultZoomText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 58)
                            .multilineTextAlignment(.trailing)
                            .onSubmit {
                                controller?.commitDefaultZoomTextFromUI(defaultZoomText)
                            }
                        Stepper("", value: Binding(
                            get: { model.defaultZoomPercent },
                            set: { controller?.stepDefaultZoomFromUI($0) }
                        ), in: 10...500, step: 10)
                        .labelsHidden()
                        Text("%")
                            .foregroundColor(.secondary)
                    }
                }

                DeskProSettingsRow(
                    title: L("Apply to all skins"),
                    detail: L("Apply the default zoom to every skin."),
                    divider: false
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.forceDefaultZoom },
                        set: { controller?.setForceZoomFromUI($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }

            DeskProSettingsGroup(title: L("Directories")) {
                DeskProSettingsRow(
                    title: L("Skins folder"),
                    detail: model.skinsFolderDisplayPath
                ) {
                    HStack(spacing: 8) {
                        Button(L("Refresh All")) {
                            app.refreshAllAction()
                        }
                        Button(L("Show in Finder")) {
                            app.openSkinsFolderAction()
                        }
                    }
                }

                DeskProSettingsRow(
                    title: L("Settings folder"),
                    detail: model.settingsFolderDisplayPath,
                    divider: false
                ) {
                    Button(L("Show in Finder")) {
                        Workspace.reveal(app.settingsDirectory)
                    }
                }
            }
        }
    }

    private func desktopModeVisualCard(
        selected: Bool,
        isLocked: Bool,
        title: String,
        caption: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [DeskProPalette.hex(0x2B3A66), DeskProPalette.hex(0x7E6A8E), DeskProPalette.hex(0xD99272)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 34, height: 34)
                        .offset(x: 10, y: 10)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 34, height: 16)
                        .offset(x: 10, y: 50)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 22, height: 16)
                        .offset(x: 50, y: 10)

                    VStack(spacing: 0) {
                        Rectangle().fill(Color(white: 0.93)).frame(height: 7)
                        Rectangle().fill(Color.white)
                    }
                    .frame(width: 80, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .shadow(color: .black.opacity(0.24), radius: 4, y: 2)
                    .offset(x: 48, y: 24)

                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .offset(x: 112, y: 8)
                    }
                }
                .frame(width: 136, height: 84)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.accentColor)
                        }
                    }
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DeskProPalette.box))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func appearancePreviewCard(
        selected: Bool,
        darkPreview: Bool,
        splitAuto: Bool,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        let backdropColors: [Color] = {
            if splitAuto {
                return [DeskProPalette.hex(0x2B3A66), DeskProPalette.hex(0x7E6A8E), DeskProPalette.hex(0xD99272)]
            } else if darkPreview {
                return [DeskProPalette.hex(0x161E35), DeskProPalette.hex(0x292544), DeskProPalette.hex(0x4E374B)]
            } else {
                return [DeskProPalette.hex(0x5E85C8), DeskProPalette.hex(0x9BB5DC), DeskProPalette.hex(0xEBD2B7)]
            }
        }()

        return Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: backdropColors,
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    HStack(spacing: 0) {
                        if splitAuto {
                            ZStack {
                                Color.white.opacity(0.94)
                                Text("09")
                                    .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                                    .foregroundColor(.black.opacity(0.85))
                            }
                            ZStack {
                                Color(white: 0.14).opacity(0.94)
                                Text("41")
                                    .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                                    .foregroundColor(.white)
                            }
                        } else {
                            ZStack {
                                (darkPreview ? Color(white: 0.14) : Color.white).opacity(0.94)
                                Text("09:41")
                                    .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                                    .foregroundColor(darkPreview ? .white : .black.opacity(0.85))
                            }
                        }
                    }
                    .frame(width: 64, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.accentColor)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 3. Editor Page

    private var editorPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeskProSettingsGroup(footer: model.editorHelperText) {
                DeskProSettingsRow(title: L("Edit code with")) {
                    Picker("", selection: Binding(
                        get: { model.selectedEditorIndex },
                        set: { controller?.chooseEditorIndexFromUI($0) }
                    )) {
                        ForEach(model.editorItems) { item in
                            if item.isSeparator {
                                Divider()
                            } else {
                                HStack {
                                    if let icon = item.icon {
                                        Image(nsImage: icon)
                                    }
                                    Text(item.title)
                                }
                                .tag(item.id)
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                DeskProSettingsRow(title: L("Code font size")) {
                    HStack(spacing: 6) {
                        TextField("13", text: $fontSizeText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 52)
                            .multilineTextAlignment(.trailing)
                            .onSubmit {
                                controller?.commitFontSizeTextFromUI(fontSizeText)
                            }
                        Stepper("", value: Binding(
                            get: { model.codeFontSize },
                            set: { controller?.stepFontSizeFromUI($0) }
                        ), in: Int(EditorPreferences.fontSizes.lowerBound)...Int(EditorPreferences.fontSizes.upperBound), step: 1)
                        .labelsHidden()
                        Text(L("pt"))
                            .foregroundColor(.secondary)
                    }
                }

                DeskProSettingsRow(
                    title: L("Live reload:"),
                    detail: L("Refresh the skin when the file is saved elsewhere"),
                    divider: false
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.liveReload },
                        set: { controller?.setLiveReloadFromUI($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: - 4. Debug & Log Page

    private var filteredLogs: [Log.Line] {
        model.recentLogs.filter { line in
            switch line.level {
            case .error: return model.showErrorLogs
            case .warning: return model.showWarningLogs
            case .notice: return model.showNoticeLogs
            case .debug: return model.showDebugLogs
            }
        }
    }

    private var debugPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeskProSettingsGroup {
                DeskProSettingsRow(
                    title: L("Developer mode"),
                    detail: L("Show debug, refresh and folder actions in skin context menus. Hold Option when right-clicking a skin to show them temporarily."),
                    divider: false
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.developerMode },
                        set: { controller?.setDeveloperModeFromUI($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }

            DeskProSettingsGroup(title: L("Diagnostics")) {
                DeskProSettingsRow(
                    title: L("Log file"),
                    detail: Log.fileURL.path
                ) {
                    HStack(spacing: 8) {
                        Button(L("Show log file")) {
                            Log.flush()
                            Workspace.edit(Log.fileURL)
                        }
                        .controlSize(.small)

                        Toggle("", isOn: Binding(
                            get: { model.fileLoggingEnabled },
                            set: {
                                app.setFileLoggingEnabled($0)
                                model.fileLoggingEnabled = $0
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }

                DeskProSettingsRow(
                    title: L("Debug Deskset"),
                    detail: L("Inspect live skin measures, variables, built-in plugins, displays and network statistics."),
                    divider: false
                ) {
                    Button(L("Open Inspector…")) {
                        app.showDebug(tab: .skins)
                    }
                }
            }

            DeskProSettingsGroup(title: L("Log")) {
                HStack(spacing: 8) {
                    logFilterPill(L("Error"), isOn: $model.showErrorLogs, tint: .red)
                    logFilterPill(L("Warning"), isOn: $model.showWarningLogs, tint: .orange)
                    logFilterPill(L("Notice"), isOn: $model.showNoticeLogs, tint: .accentColor)
                    logFilterPill(L("Debug"), isOn: $model.showDebugLogs, tint: .secondary)
                    Spacer()
                    Button(L("Refresh")) {
                        controller?.refreshDebugData()
                    }
                    .controlSize(.small)
                    Button(L("Copy all")) {
                        let text = filteredLogs.map {
                            "[\($0.level.rawValue)]\($0.source.map { " (\($0))" } ?? "") \($0.message)"
                        }.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                if filteredLogs.isEmpty {
                    Text(L("No log entries."))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(filteredLogs.prefix(80).enumerated()), id: \.offset) { idx, line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Circle()
                                        .fill(logLevelColor(line.level))
                                        .frame(width: 6, height: 6)
                                    if let source = line.source, !source.isEmpty {
                                        Text(source)
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Text(line.message)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundColor(.primary)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                if idx < min(filteredLogs.count, 80) - 1 {
                                    Divider().padding(.leading, 14)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                }
            }
        }
    }

    private func logFilterPill(_ title: String, isOn: Binding<Bool>, tint: Color) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isOn.wrappedValue ? .white : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(isOn.wrappedValue ? tint : Color.primary.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
    }

    private func logLevelColor(_ level: SkinLogLevel) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .notice: return .accentColor
        case .debug: return .secondary
        }
    }

    // MARK: - 5. About Deskset Page

    private var aboutPage: some View {
        let details = AboutWindowController.versionDetails(for: app)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: AppIcon.image(size: 128))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Deskset")
                        .font(.system(size: 17, weight: .semibold))
                    Text(details.headline)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    Text(L("Desktop widgets for your Mac, compatible with Rainmeter skins."))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(L("Copy to Clipboard")) {
                    AboutWindowController.copyVersionDetailsToClipboard(for: app)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DeskProPalette.box))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .padding(.bottom, 22)

            DeskProSettingsGroup(
                title: L("Help"),
                footer: L("Rainmeter is a trademark of its respective owners; Deskset is not affiliated with it.")
                    + "\n" + WeatherWiring.credits
            ) {
                DeskProSettingsRow(title: L("Documentation"), divider: false) {
                    Button(L("Open")) {
                        if let url = URL(string: "https://docs.rainmeter.net/") {
                            app.openMenuURL(url)
                        }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }
}

extension SettingsWindowController.Pane {
    var sidebarSymbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .desktop: return "rectangle.3.group.fill"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .debug: return "ladybug.fill"
        case .about: return "info.circle.fill"
        }
    }

    var sidebarTint: Color {
        switch self {
        case .general: return Color(white: 0.55)
        case .desktop: return DeskProPalette.indigoTint
        case .editor: return DeskProPalette.discoverBlue
        case .debug: return DeskProPalette.privacyGreen
        case .about: return DeskProPalette.aboutInk
        }
    }
}
