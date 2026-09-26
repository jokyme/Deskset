import AppKit
import DesksetCore

extension AppSelfTest {
    /// The editor schema (DesksetCore) against the measure types that exist once the app registered its plugins:
    /// every type the schema lists can be created, and every plugin the app registers is described.
    static func editorSchemaTests(_ t: AppTestRunner) {
        t.suite("App: editor schema knows every registered measure type") {
            // What a skin load does first (Skin.registerBuiltInExtensions): the engine's own plugins and Lua.
            CorePlugins.register()
            LuaSupport.register()
            // Types `Skin.makeMeasure` builds itself (its switch), beside the ones in MeasureRegistry.
            let engineBuiltIn: Set<String> = ["calc", "time", "uptime", "cpu", "memory", "physicalmemory", "swapmemory",
                                              "netin", "netout", "nettotal", "freediskspace", "loop", "string", "process",
                                              "sysinfo", "webparser", "powerplugin", "registry"]
            for m in EditorSchema.measureTypes {
                let name = m.name.lowercased()
                let registered = m.isPlugin
                    ? MeasureRegistry.plugin(named: m.name) != nil
                    : MeasureRegistry.measure(named: m.name) != nil || MeasureRegistry.plugin(named: m.name) != nil
                t.check(registered || engineBuiltIn.contains(name), "\(m.name) can be created")
                for alias in m.aliases {
                    t.check(MeasureRegistry.plugin(named: alias) != nil, "Plugin=\(alias) is registered")
                }
            }
            // The plugins the app registers (Plugins/Audio, Plugins/Media, Plugins/UI).
            for plugin in ["AudioLevel", "Win7AudioPlugin", "Win7Audio", "AppVolume", "NowPlaying", "WiFiStatus", "MediaKey",
                           "iTunesPlugin", "iTunes", "WebNowPlaying", "InputText", "FrostedGlass", "Chameleon",
                           "IsFullScreen", "GetActiveTitle", "SysColor"] {
                t.check(MeasureRegistry.plugin(named: plugin) != nil, "\(plugin) is registered")
                let d = EditorSchema.describeMeasure(type: "Plugin", plugin: plugin)
                t.check(d.symbol != "puzzlepiece", "Plugin=\(plugin) is described: \(d.title)")
            }
            // Symbols exist on this system (a missing one would show an empty image).
            for m in EditorSchema.measureTypes {
                t.check(NSImage(systemSymbolName: m.symbol, accessibilityDescription: nil) != nil, "symbol \(m.symbol)")
            }
            for kind in ShapeSpec.Kind.allCases {
                t.check(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil) != nil, "symbol \(kind.symbol)")
            }
        }
        // The inspector built on the schema (InspectorControlsSelfTests.swift).
        inspectorControlTests(t)
    }
}
