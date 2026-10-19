import AppKit
import DesksetCore

final class AboutWindowController: NSWindowController, NSWindowDelegate {
    enum Tab: String, CaseIterable, Equatable {
        case log = "Log", skins = "Skins", plugins = "Plugins", version = "Version"
        static func parse(_ raw: String?) -> Tab {
            switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "log": return .log
            case "skins", "measures": return .skins
            case "plugins": return .plugins
            default: return .version
            }
        }
    }
    static var buildArchitecture: String {
        #if arch(arm64)
        return "64-bit (arm64)"
        #elseif arch(x86_64)
        return "64-bit (x86_64)"
        #else
        return "64-bit"
        #endif
    }

    static func versionHeadline(bundle: Bundle = .main) -> String {
        let version = AppVersion.current
        if let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Deskset \(version) (build \(build)) - \(buildArchitecture)"
        }
        return "Deskset \(version) - \(buildArchitecture)"
    }

    private static var currentController: AboutWindowController?
    static var openWindow: NSWindow? {
        guard let w = currentController?.window, w.isVisible || w.isMiniaturized else { return nil }; return w
    }
    static func window(for app: AppController) -> AboutWindowController? {
        guard let c = currentController, c.app === app else { return nil }; return c
    }
    @discardableResult
    static func show(app: AppController, tab: Tab = .version) -> AboutWindowController {
        let c: AboutWindowController
        if let existing = window(for: app) { c = existing }
        else { currentController?.close(); c = AboutWindowController(app: app); currentController = c }
        c.selectTab(tab); app.bringToFront(c); return c
    }
    private unowned let app: AppController
    let selectedTab: Tab = .version
    private let versionHeadlineField = NSTextField(labelWithString: "")
    private let pathValueFields: [String: NSTextField]
    init(app: AppController) {
        self.app = app
        var fields: [String: NSTextField] = [:]
        for key in ["ProgramPath", "IniFile", "SkinPath", "SettingsPath", "LogFile"] {
            let field = NSTextField(labelWithString: "")
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.textColor = .secondaryLabelColor; field.lineBreakMode = .byTruncatingMiddle; field.isSelectable = true
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            fields[key] = field
        }
        pathValueFields = fields
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 380),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "About Deskset"; w.minSize = NSSize(width: 680, height: 360); w.isReleasedWhenClosed = false; w.center()
        super.init(window: w); w.delegate = self
        guard let content = w.contentView else { return }
        let body = buildVersionTab()
        let close = NSButton(title: "Close", target: self, action: #selector(closeButtonClicked))
        close.keyEquivalent = "\u{1b}"
        for v in [body, close] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), body.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -12),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            close.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func selectTab(_ tab: Tab) { refreshVersionDetails() }
    override func close() { if Self.currentController === self { Self.currentController = nil }; super.close() }
    func windowWillClose(_ notification: Notification) { if Self.currentController === self { Self.currentController = nil } }
    @objc private func closeButtonClicked() { close() }
    private func buildVersionTab() -> NSView {
        let container = NSView()

        let iconView = NSImageView(image: AppIcon.image(size: 64))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
        ])

        let titleField = NSTextField(labelWithString: "Deskset")
        titleField.font = .systemFont(ofSize: 20, weight: .bold)

        versionHeadlineField.font = .systemFont(ofSize: 13, weight: .medium)
        versionHeadlineField.isSelectable = true

        let copyButton = NSButton(title: "Copy to Clipboard", target: self, action: #selector(copyVersionDetailsToClipboard))
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let headerTextStack = NSStackView(views: [titleField, versionHeadlineField])
        headerTextStack.orientation = .vertical
        headerTextStack.alignment = .leading
        headerTextStack.spacing = 4

        let headerRow = NSStackView(views: [iconView, headerTextStack])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 14
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let pathsGrid = NSGridView(numberOfColumns: 2, rows: 0)
        pathsGrid.rowSpacing = 6
        pathsGrid.columnSpacing = 12
        pathsGrid.translatesAutoresizingMaskIntoConstraints = false

        let pathLabels: [(String, String)] = [
            ("ProgramPath", "Path:"),
            ("IniFile", "IniFile:"),
            ("SkinPath", "SkinPath:"),
            ("SettingsPath", "SettingsPath:"),
            ("LogFile", "LogFile:"),
        ]
        for (key, title) in pathLabels {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.alignment = .right
            let valueField = pathValueFields[key] ?? NSTextField(labelWithString: "")
            pathsGrid.addRow(with: [label, valueField])
        }
        pathsGrid.column(at: 0).xPlacement = .trailing
        pathsGrid.column(at: 0).width = 90
        pathsGrid.column(at: 1).xPlacement = .fill

        let creditsBox = NSBox()
        creditsBox.boxType = .custom
        creditsBox.borderWidth = 1
        creditsBox.cornerRadius = 6
        creditsBox.borderColor = .separatorColor
        creditsBox.fillColor = .controlBackgroundColor
        creditsBox.contentViewMargins = NSSize(width: 12, height: 10)
        creditsBox.translatesAutoresizingMaskIntoConstraints = false

        let creditsText = NSTextField(wrappingLabelWithString:
            "Desktop widgets for your Mac, compatible with Rainmeter skins.\n"
            + "Rainmeter is a trademark of its respective owners; Deskset is not affiliated with it.\n"
            + WeatherWiring.credits)
        creditsText.font = .systemFont(ofSize: 11)
        creditsText.textColor = .secondaryLabelColor
        creditsText.isSelectable = true
        creditsBox.contentView = creditsText

        container.addSubview(headerRow)
        container.addSubview(copyButton)
        container.addSubview(pathsGrid)
        container.addSubview(creditsBox)

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            headerRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),

            copyButton.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),

            pathsGrid.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 18),
            pathsGrid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            pathsGrid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),

            creditsBox.topAnchor.constraint(greaterThanOrEqualTo: pathsGrid.bottomAnchor, constant: 18),
            creditsBox.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            creditsBox.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            creditsBox.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        refreshVersionDetails()
        return container
    }

    func versionReportText() -> String {
        let details = currentVersionDetails()
        return [
            details.headline,
            "Path: \(details.programPath)",
            "IniFile: \(details.iniFile)",
            "SkinPath: \(details.skinPath)",
            "SettingsPath: \(details.settingsPath)",
            "LogFile: \(details.logFile)",
        ].joined(separator: "\n")
    }

    func currentVersionDetails() -> (
        headline: String,
        programPath: String,
        iniFile: String,
        skinPath: String,
        settingsPath: String,
        logFile: String
    ) {
        let headline = Self.versionHeadline()
        let programURL = Bundle.main.executableURL?.deletingLastPathComponent() ?? Bundle.main.bundleURL
        let programPath = Self.trailingSlashPath(programURL)
        let settingsDirURL = app.settingsDirectory
        let settingsPath = Self.trailingSlashPath(settingsDirURL)
        let iniFile = app.state.fileURL.path
        let skinPath = Self.trailingSlashPath(app.skinsDirectory)
        let logFile = Log.fileURL.path
        return (headline, programPath, iniFile, skinPath, settingsPath, logFile)
    }

    private static func trailingSlashPath(_ url: URL) -> String {
        let path = url.path
        return path.hasSuffix("/") ? path : path + "/"
    }

    private func refreshVersionDetails() {
        let details = currentVersionDetails()
        versionHeadlineField.stringValue = details.headline
        pathValueFields["ProgramPath"]?.stringValue = details.programPath
        pathValueFields["IniFile"]?.stringValue = details.iniFile
        pathValueFields["SkinPath"]?.stringValue = details.skinPath
        pathValueFields["SettingsPath"]?.stringValue = details.settingsPath
        pathValueFields["LogFile"]?.stringValue = details.logFile
    }

    @objc func copyVersionDetailsToClipboard() {
        writeToPasteboard(versionReportText())
    }

    private func writeToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    func snapshot() -> NSBitmapImageRep? {
        guard let view = window?.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        // As in Manage, the window frame supplies the background in normal display, outside the content view.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        view.displayIgnoringOpacity(view.bounds, in: context)
        return rep
    }
}
