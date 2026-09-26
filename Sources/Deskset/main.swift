import AppKit

// Developer / build commands (`--render`, `--self-test`, `--make-icon`, `--snapshot-ui`, `--system-report`,
// `--help`) run and exit; an unknown `--` flag prints the usage and exits with status 2; otherwise the menu bar app
// starts (see CommandLineTools).
// App-side plugin measures (Core plugins and Lua register themselves in DesksetCore).
AudioPlugins.register()
MediaUIPlugins.register()
// FileView Type=Icon: file icons come from NSWorkspace.
FileViewIconWriter.install()
// Skin tooltips after half a second, as on Windows (AppKit reads the delay once).
SkinTooltips.registerDelay()

if let status = CommandLineTools.run(CommandLine.arguments) {
    exit(status)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
// Menu bar app (the bundle also sets LSUIElement; this covers `swift run`).
app.setActivationPolicy(.accessory)
app.run()
