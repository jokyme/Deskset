import AppKit
import DesksetCore

/// Version and path details presented on the `About Deskset` pane of `SettingsWindowController`
/// and copied for bug reports (`!About`, app/status/skin menus).
enum AboutWindowController {
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
            return L("Deskset %@ (build %@) - %@", version, build, buildArchitecture)
        }
        return L("Deskset %@ - %@", version, buildArchitecture)
    }

    static func versionDetails(for app: AppController) -> (
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

    static func formatVersionReport(for app: AppController) -> String {
        let details = versionDetails(for: app)
        return [
            details.headline,
            "Path: \(details.programPath)",
            "IniFile: \(details.iniFile)",
            "SkinPath: \(details.skinPath)",
            "SettingsPath: \(details.settingsPath)",
            "LogFile: \(details.logFile)",
        ].joined(separator: "\n")
    }

    static func copyVersionDetailsToClipboard(for app: AppController) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(formatVersionReport(for: app), forType: .string)
    }

    private static func trailingSlashPath(_ url: URL) -> String {
        let path = url.path
        return path.hasSuffix("/") ? path : path + "/"
    }
}
