import AppKit

// --render: the same order of sets and dictionaries in every run (it starts again with deterministic hashing).
CommandLineTools.makeHashingDeterministic(for: CommandLine.arguments)

// Legacy ANSI skin files are read in the code page of the user's language (GBK for Simplified Chinese…), except
// under --self-test; set before anything can load a skin.
CommandLineTools.useANSICodePage(for: CommandLine.arguments)

// One symbol renderer for the shared image cache in every command-line mode and the interactive app.
Images.configure(symbols: AppSymbolRasterizer())

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
// Where the desktop skins run (`SkinThreading`: main or engine), read once: the modes above always use the main thread.
let threading = SkinThreading.chosen(in: .standard)
let controller = AppController(threading: threading.mode)
controller.threadingNote = threading.note
app.delegate = controller
// Menu bar app (the bundle also sets LSUIElement; this covers `swift run`).
app.setActivationPolicy(.accessory)
app.run()
