import AppKit
import ServiceManagement

/// "Launch at Login" through `SMAppService.mainApp` (macOS 13+). Only meaningful for the installed .app bundle:
/// a `swift run` binary cannot be registered as a login item.
enum LaunchAtLogin {
    static var isAvailable: Bool { Paths.isAppBundle }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// On, or waiting for the user's approval in System Settings.
    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return status == .enabled || status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Flips the setting and explains problems (approval needed, registration failed) to the user.
    static func toggle(app: AppController) {
        guard isAvailable else {
            app.alert("Launch at Login is unavailable",
                      "Move Deskset to the Applications folder and open it from there to start it at login.")
            return
        }
        let enable = !isEnabled
        do {
            try setEnabled(enable)
            Log.write("Launch at login \(enable ? "enabled" : "disabled") (status \(status.rawValue))")
            if enable && status == .requiresApproval {
                promptForApproval(app)
            }
        } catch {
            Log.write("Launch at login: \(error.localizedDescription)", level: .error)
            if enable && status == .requiresApproval {
                promptForApproval(app)
            } else {
                app.alert(enable ? "Couldn’t turn on Launch at Login" : "Couldn’t turn off Launch at Login",
                          error.localizedDescription)
            }
        }
    }

    private static func promptForApproval(_ app: AppController) {
        guard app.presentsWindows else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow Deskset to open at login"
        alert.informativeText = "macOS needs your approval. Turn on Deskset in System Settings › General › Login Items."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
