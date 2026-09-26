import Foundation
@testable import DesksetCore

// Engine wiring after the compatibility round: meter geometry before the first update (provisional layout),
// MeterStyle names built from section variables, app-provided plugin names in core-only contexts, and the Registry
// measure's live wallpaper value and environment keys (docs/compat/engine.md, lua.md).

/// A data source with a desktop picture (`FakeSystem` cannot be subclassed for this: the protocol's default
/// `desktopPicturePath()` would be used for it).
private final class WallpaperSystem: SystemDataSource {
    var wallpaper: String? = "/Users/jane/Pictures/Lake.jpg"
    var wallpaperReads = 0

    var processorCount: Int { 8 }
    func cpuUsage(processor: Int) -> Double { 0 }
    func memoryStatus() -> MemoryStatus {
        MemoryStatus(physicalTotal: 1_073_741_824, physicalUsed: 0, swapTotal: 0, swapUsed: 0)
    }
    func networkInterfaces() -> [String] { [] }
    func networkCounters(interface: String?) -> NetworkCounters { NetworkCounters(received: 0, sent: 0) }
    func diskSpace(path: String) -> (total: Double, free: Double)? { nil }
    func uptime() -> TimeInterval { 0 }
    func battery() -> BatteryStatus? { nil }
    func isProcessRunning(_ name: String) -> Bool { false }
    func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { nil }
    func desktopPicturePath() -> String? {
        wallpaperReads += 1
        return wallpaper
    }
}

private var retainedWiringHosts: [FakeHost] = []

/// Writes `files` (paths relative to the Skins folder) and loads `Root\Sub\Skin.ini`.
private func wiringSkin(_ t: TestRunner, _ ini: String, files: [String: String] = [:],
                        system: SystemDataSource = FakeSystem()) throws -> (Skin, FakeHost) {
    let skins = t.temporaryDirectory("wiring").appendingPathComponent("Skins")
    let dir = skins.appendingPathComponent("Root/Sub")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: skins.appendingPathComponent("Root/@Resources"),
                                            withIntermediateDirectories: true)
    try ini.write(to: dir.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
    for (path, text) in files {
        let url = skins.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    let host = FakeHost()
    retainedWiringHosts.append(host)
    let skin = Skin(config: "Root\\Sub", fileURL: dir.appendingPathComponent("Skin.ini"), skinsDirectory: skins,
                    system: system, host: host)
    try skin.load()
    return (skin, host)
}

private func global(_ skin: Skin, _ name: String, _ measure: String = "Script") -> String? {
    (skin.measure(named: measure) as? ScriptMeasure)?.sectionVariableFunction(name)
}

func runEngineWiringTests(_ t: TestRunner) {
    LuaSupport.register()

    // MARK: Provisional meter geometry

    t.suite("Engine wiring: Lua sees meter geometry before the first update") {
        let lua = """
        local box = SKIN:GetMeter('Box')
        chunk = table.concat({ box:GetX(), box:GetY(), box:GetW(), box:GetH() }, ',')
        function Initialize()
          local label = SKIN:GetMeter('Label')
          init = table.concat({ label:GetX(), label:GetY(), label:GetW(), label:GetH(), label:GetX(true) }, ',')
        end
        function Update()
          if not first then first = tostring(SKIN:GetMeter('Label'):GetW()) end
          return 'abcdefghijklmnopqrstuvwxyz'
        end
        """
        let (skin, host) = try wiringSkin(t, """
        [Rainmeter]
        Update=1000
        [Script]
        Measure=Script
        ScriptFile=Geo.lua
        [Box]
        Meter=Image
        X=10
        Y=20
        W=30
        H=40
        Padding=1,2,3,4
        [Label]
        Meter=String
        X=5R
        Y=0r
        Text=Hello
        [Value]
        Meter=String
        MeasureName=Script
        Y=100
        """, files: ["Root/Sub/Geo.lua": lua])
        // The main chunk ran while the measures were read, before the meters' options: they were read for it.
        t.equal(global(skin, "chunk"), "10,20,34,46", "main chunk: X, Y, W / H with Padding")
        t.equal(skin.width, 0, "the provisional layout does not size the window")
        t.equal(skin.height, 0)
        skin.update()
        t.equal(global(skin, "init"), "49,20,35,14,49", "Initialize(): R / r positions and the String meter's text")
        t.equal(global(skin, "first"), "35", "the first Update() sees the String meter's width")
        // Sized at the end of the first update, from the updated meters (the provisional Value text was empty).
        t.equal(skin.width, 182, "26 characters × 7")
        t.equal(skin.height, 114)
        t.equal(skin.meter(named: "Label")?.frame, SkinRect(x: 49, y: 20, width: 35, height: 14))
        t.equal(host.logs.filter { $0.contains("Error") }, [])
    }

    t.suite("Engine wiring: [Meter:X] read by measures in the first update") {
        let (skin, host) = try wiringSkin(t, """
        [Rainmeter]
        Update=1000
        [Dyn]
        Measure=Calc
        Formula=[Right:X] + [Right:W]
        DynamicVariables=1
        [Static]
        Measure=Calc
        Formula=[Right:XW] + [Right:YH]
        [Broken]
        Measure=Calc
        Formula=[Right:X] +
        IfCondition=[Right:W] >
        IfTrueAction=[!Log x]
        [Checked]
        Measure=Calc
        Formula=1
        IfCondition=[Right:W] > 10
        IfTrueAction=[!SetVariable Wide 1]
        [Left]
        Meter=String
        Text=abcd
        FontSize=10
        [Right]
        Meter=Image
        X=6R
        Y=5
        W=20
        H=10
        """)
        // Formulas naming meters without DynamicVariables are not "invalid" at load: they are read at the first
        // update, with the section variables resolved.
        t.equal(host.logs.filter { $0.contains("Error") }, [], "nothing reported at load")
        // The dynamic formula was resolved at load: the provisional layout ran then (Left is 4 × 7 wide).
        skin.update()
        t.equal(skin.measure(named: "Dyn")?.value, 54, "34 + 20")
        t.equal(skin.measure(named: "Static")?.value, 69, "54 + 15, resolved once at the first update")
        t.equal(skin.variable("Wide"), "1", "the IfCondition sees the provisional width")
        t.equal(skin.width, 54)
        t.equal(host.logs.filter { $0.contains("does not exist") || $0.contains("Error") && !$0.contains("[Broken]") },
                [])
        // Really invalid once resolved: reported (once each) at the first update.
        t.equal(host.logs.filter { $0.contains("[Broken] invalid Formula: 34 +") }.count, 1, "\(host.logs)")
        t.equal(host.logs.filter { $0.contains("[Broken] invalid IfCondition: 20 >") }.count, 1, "\(host.logs)")
        // A meter that moves later: the dynamic measure follows, the static one kept its first value.
        skin.execute("[!SetOption Right X 100][!UpdateMeter Right]", from: nil)
        skin.update()
        skin.update()
        t.equal(skin.measure(named: "Dyn")?.value, 120)
        t.equal(skin.measure(named: "Static")?.value, 69)
    }

    t.suite("Engine wiring: provisional layout keeps the first update's sizing") {
        let (skin, _) = try wiringSkin(t, """
        [Rainmeter]
        Update=1000
        [Grow]
        Measure=String
        String=a much longer text
        [Probe]
        Measure=Calc
        Formula=[Text:W]
        DynamicVariables=1
        [Text]
        Meter=String
        MeasureName=Grow
        [Hidden]
        Meter=Image
        W=500
        H=500
        Hidden=1
        """)
        // Before the first update the bound measure has its initial value (0, shown as "0"): the provisional text.
        t.equal(skin.meter(named: "Text")?.frame.width, 7)
        t.equal(skin.width, 0)
        skin.update()
        t.equal(skin.measure(named: "Probe")?.value, 7, "the measure ran before the meter updated its text")
        t.equal(skin.meter(named: "Text")?.frame.width, 126, "18 × 7")
        t.equal(skin.width, 126, "the window size comes from the first update, not from the provisional layout")
        t.equal(skin.meter(named: "Hidden")?.frame, SkinRect(x: 0, y: 0, width: 0, height: 0))
        skin.update()
        t.equal(skin.measure(named: "Probe")?.value, 126)
    }

    t.suite("Engine wiring: Lua SetX before the first layout") {
        let lua = """
        local m = SKIN:GetMeter('Box')
        m:SetX(40)
        moved = table.concat({ m:GetX(), m:GetW() }, ',')
        function Update() end
        """
        let (skin, _) = try wiringSkin(t, """
        [Script]
        Measure=Script
        ScriptFile=Move.lua
        [Box]
        Meter=Image
        X=1
        W=3
        H=4
        [After]
        Meter=Image
        X=0R
        W=1
        H=1
        """, files: ["Root/Sub/Move.lua": lua])
        t.equal(global(skin, "moved"), "40,3")
        skin.update()
        t.equal(skin.meter(named: "Box")?.frame, SkinRect(x: 40, y: 0, width: 3, height: 4))
        t.equal(skin.meter(named: "After")?.frame.x, 43)
    }

    t.suite("Engine wiring: provisional layout re-entered from inline Lua") {
        // The main chunk asks for geometry while the measures are read; the provisional layout reads a dynamic meter
        // whose options call back into the same script (still running its main chunk), which asks for geometry
        // again. Nothing recurses, and every read settles on the real values at the first update.
        let lua = """
        chunk = SKIN:GetMeter('Label'):GetW()
        function Width() return SKIN:GetMeter('Label'):GetW() end
        function Update() return Width() end
        """
        let (skin, host) = try wiringSkin(t, """
        [Rainmeter]
        Update=1000
        [Script]
        Measure=Script
        ScriptFile=Again.lua
        [Label]
        Meter=String
        Text=abc
        [Echo]
        Meter=String
        X=[&Script:Width()]
        Y=20
        Text=x
        DynamicVariables=1
        [Late]
        Meter=Image
        X=([Echo:X] + 1)
        W=2
        H=2
        """, files: ["Root/Sub/Again.lua": lua])
        t.equal(global(skin, "chunk"), "21", "3 × 7")
        t.equal(skin.width, 0)
        skin.update()
        skin.update()
        t.equal(skin.meter(named: "Echo")?.frame.x, 21)
        t.equal(skin.measure(named: "Script")?.value, 21)
        t.equal(skin.meter(named: "Late")?.frame.x, 22, "resolved once at the first update from the provisional X")
        t.equal(host.logs.filter { $0.hasPrefix("Error") }, [], "\(host.logs)")
    }

    t.suite("Engine wiring: forward [Meter:X] in the first update's meter pass") {
        // A meter above another reads its position in the first update (non-dynamic: resolved once). Before, the
        // later meter had no frame yet (0); now it has its provisional one. The pass still ends with the real layout
        // and the window size from it.
        let (skin, host) = try wiringSkin(t, """
        [Rainmeter]
        Update=1000
        [Text]
        Measure=String
        String=wider text
        [Marker]
        Meter=Image
        X=([Target:X] - 4)
        Y=0
        W=3
        H=3
        [Target]
        Meter=String
        MeasureName=Text
        X=30
        Y=10
        [After]
        Meter=Image
        X=2R
        Y=0r
        W=5
        H=5
        """)
        skin.update()
        t.equal(skin.meter(named: "Marker")?.frame.x, 26)
        t.equal(skin.meter(named: "Target")?.frame, SkinRect(x: 30, y: 10, width: 70, height: 14), "10 × 7")
        t.equal(skin.meter(named: "After")?.frame.x, 102, "after the updated text")
        t.equal(skin.width, 107)
        t.equal(skin.height, 24)
        t.equal(host.logs.filter { $0.hasPrefix("Error") || $0.hasPrefix("Warning") }, [], "\(host.logs)")
    }

    t.suite("Engine wiring: TestSkins/Engine/Compat/EarlyGeometry fixture") {
        let testSkins = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("TestSkins")
        let host = FakeHost()
        retainedWiringHosts.append(host)
        let skin = Skin(config: "Engine\\Compat",
                        fileURL: testSkins.appendingPathComponent("Engine/Compat/EarlyGeometry.ini"),
                        skinsDirectory: testSkins, system: FakeSystem(), host: host)
        try skin.load()
        skin.update()
        // FakeHost: 7 points per character, 14 per line. Title "Early geometry" at X=12, the badge 8 px after it.
        t.equal(text(skin, "Report"), "Initialize(): title 98x14, badge at x=118\nfirst update: the badge ends at 146")
        t.equal(skin.issues, [])
        t.check(host.logs.filter { $0.hasPrefix("Error") || $0.hasPrefix("Warning") }.isEmpty, "\(host.logs)")
        t.equal(skin.meter(named: "Dot1")?.solidColor, RGBA(r: 120, g: 200, b: 255, a: 255))
        t.equal(skin.meter(named: "Dot2")?.frame, SkinRect(x: 212, y: 15, width: 10, height: 10))
        // FakeHost measures the two report lines as one: the widest meter sets the (first-update) window size.
        t.equal(skin.width, skin.meter(named: "Report")?.frame.maxX)
        skin.execute("[!SetVariable Page 2][!Update]", from: nil)
        t.equal(skin.meter(named: "Dot2")?.solidColor, RGBA(r: 120, g: 200, b: 255, a: 255))
        t.equal(skin.meter(named: "Dot1")?.solidColor, RGBA(r: 255, g: 255, b: 255, a: 70))
    }

    // MARK: MeterStyle with section variables

    t.suite("Engine wiring: MeterStyle names built from section variables") {
        let (skin, host) = try wiringSkin(t, """
        [Rainmeter]
        Update=1000
        [Variables]
        Current=1
        [Active1]
        Measure=Calc
        Formula=#Current#=1
        DynamicVariables=1
        [Active2]
        Measure=Calc
        Formula=#Current#=2
        DynamicVariables=1
        [StyleGrabber]
        W=10
        H=10
        DynamicVariables=1
        [StyleGrabber0]
        SolidColor=0,0,0
        [StyleGrabber1]
        SolidColor=255,255,255
        [Grabber1]
        Meter=Image
        MeterStyle=StyleGrabber | StyleGrabber[Active1] | NoSuchStyle
        [Grabber2]
        Meter=Image
        MeterStyle=StyleGrabber | StyleGrabber[Active2]
        [Plain]
        Meter=Image
        MeterStyle=StyleGrabber[Active1]
        W=5
        H=5
        [Broken]
        Meter=Image
        MeterStyle=Missing[Active1]
        DynamicVariables=1
        """)
        func warnings(_ fragment: String) -> Int {
            host.logs.filter { $0.contains("MeterStyle") && $0.contains(fragment) }.count
        }
        t.equal(warnings("\"NoSuchStyle\""), 1, "a plain missing name is reported at load")
        t.equal(warnings("StyleGrabber[") + warnings("Missing["), 0,
                "names with section variables are not reported before they can resolve: \(host.logs)")
        skin.update()
        let white = RGBA(r: 255, g: 255, b: 255, a: 255)
        let black = RGBA(r: 0, g: 0, b: 0, a: 255)
        t.equal(skin.meter(named: "Grabber1")?.solidColor, white)
        t.equal(skin.meter(named: "Grabber2")?.solidColor, black)
        t.equal(skin.meter(named: "Plain")?.solidColor, white,
                "without DynamicVariables the MeterStyle is resolved once, at the first update")
        t.equal(warnings("\"Missing1\""), 1, "a resolved name that names no section is reported")
        t.equal(warnings("StyleGrabber"), 0, "\(host.logs)")
        t.equal(warnings("\"NoSuchStyle\""), 1, "reported once")
        skin.execute("[!SetVariable Current 2]", from: nil)
        skin.update()
        t.equal(skin.meter(named: "Grabber1")?.solidColor, black)
        t.equal(skin.meter(named: "Grabber2")?.solidColor, white)
        t.equal(skin.meter(named: "Plain")?.solidColor, white, "not dynamic: keeps its first value")
        t.equal(warnings("\"Missing0\""), 1)
    }

    // MARK: App-provided plugins

    t.suite("Engine wiring: app-provided plugins in core-only contexts") {
        let (skin, host) = try wiringSkin(t, """
        [Playing]
        Measure=NowPlaying
        [PlayingPlugin]
        Measure=Plugin
        Plugin=Plugins\\NowPlaying.dll
        [Audio]
        Measure=Plugin
        Plugin=AudioLevel
        [Volume]
        Measure=Plugin
        Plugin=Win7AudioPlugin.dll
        [Apps]
        Measure=Plugin
        Plugin=AppVolume
        [Input]
        Measure=Plugin
        Plugin=InputText
        [Glass]
        Measure=Plugin
        Plugin=FrostedGlass
        [Keys]
        Measure=MediaKey
        [WiFi]
        Measure=Plugin
        Plugin=WiFiStatus
        [Vendor]
        Measure=Plugin
        Plugin=SomeVendor.dll
        [AudioTypo]
        Measure=AudioLevel
        [InputTypo]
        Measure=InputText
        """)
        // DesksetSelfTest does not link the app: its plugins are not registered here (they are in the app).
        let appNames = ["Plugins\\NowPlaying.dll", "AudioLevel", "Win7AudioPlugin.dll", "AppVolume",
                        "InputText", "FrostedGlass", "WiFiStatus"]
        for name in appNames where MeasureRegistry.plugin(named: name) == nil {
            t.check(skin.issues.contains("Plugin \"\(name)\" is provided by the Deskset app and is not available here"),
                    "\(name): \(skin.issues)")
        }
        if MeasureRegistry.measure(named: "NowPlaying") == nil {
            t.check(skin.issues.contains("Measure=NowPlaying is provided by the Deskset app and is not available here"))
            t.check(skin.issues.contains("Measure=MediaKey is provided by the Deskset app and is not available here"))
        }
        t.equal(skin.issues.filter { $0.contains("Windows") }, ["Plugin \"SomeVendor.dll\" is a Windows plugin and is not supported"])
        // A plugin name used as a measure type is not a Rainmeter measure type, and the app registers these names only
        // as plugins: the app reaches this fallback too, so no "provided by the Deskset app" note there — the same
        // invalid-type log line in every context.
        t.equal(skin.issues.filter { $0.contains("AudioLevel") || $0.contains("InputText") }
                    .filter { !$0.hasPrefix("Plugin ") }, [], "\(skin.issues)")
        t.check(host.logs.contains { $0.contains("[AudioTypo] Measure=AudioLevel is not a valid measure type") },
                "\(host.logs)")
        t.check(host.logs.contains { $0.contains("[InputTypo] Measure=InputText is not a valid measure type") })
        for name in ["mediakey", "wifistatus", "nowplaying", "audiolevel", "win7audio", "win7audioplugin", "appvolume",
                     "inputtext", "frostedglass"] {
            t.check(Skin.appProvidedMeasures.contains(name), name)
        }
        // None of them is a core plugin (those are registered in every context).
        for entry in CorePlugins.pluginTypes {
            t.check(!Skin.appProvidedMeasures.contains(MeasureRegistry.normalizedPluginName(entry.name)), entry.name)
        }
    }

    // MARK: Registry

    t.suite("Engine wiring: Registry wallpaper and processor environment") {
        let system = WallpaperSystem()
        let (skin, _) = try wiringSkin(t, """
        [Wallpaper]
        Measure=Registry
        RegHKey=HKEY_CURRENT_USER
        RegKey=Control Panel\\Desktop
        RegValue=Wallpaper
        UpdateDivider=1
        [Cores]
        Measure=Registry
        RegHKey=HKEY_LOCAL_MACHINE
        RegKey=SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment
        RegValue=NUMBER_OF_PROCESSORS
        UpdateDivider=-1
        [Scale]
        Measure=Calc
        Formula=Cores * 100000 * 5
        [Identifier]
        Measure=Registry
        RegHKey=HKLM
        RegKey=SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment
        RegValue=PROCESSOR_IDENTIFIER
        [Thumb]
        Meter=Image
        MeasureName=Wallpaper
        W=83
        H=54
        """, system: system)
        skin.update()
        t.equal(skin.measure(named: "Wallpaper")?.stringValue, "/Users/jane/Pictures/Lake.jpg")
        t.equal(skin.measure(named: "Wallpaper")?.valueUnavailable, false)
        t.equal((skin.meter(named: "Thumb") as? ImageMeter)?.imagePath, "/Users/jane/Pictures/Lake.jpg")
        system.wallpaper = "/Users/jane/Pictures/Dunes.heic"
        skin.update()
        t.equal(skin.measure(named: "Wallpaper")?.stringValue, "/Users/jane/Pictures/Dunes.heic",
                "read again at every update of the measure")
        system.wallpaper = ""
        skin.update()
        t.equal(skin.measure(named: "Wallpaper")?.stringValue, "", "no picture file")
        t.equal(skin.issues.filter { $0.contains("Wallpaper") }, [])
        let reads = system.wallpaperReads
        skin.update()
        t.equal(system.wallpaperReads, reads + 1, "one read per update")

        let cores = skin.measure(named: "Cores")?.value ?? 0
        t.check(cores >= 1)
        t.equal(skin.measure(named: "Cores")?.stringValue, String(Int(cores)))
        t.equal(skin.measure(named: "Scale")?.value, cores * 500_000, "Enigma Process: Scale from the core count")
        t.check(skin.measure(named: "Identifier")?.stringValue.isEmpty == false, "the CPU brand string")
        t.equal(skin.issues, [])

        // A data source that cannot tell (the default): not emulated, as before.
        let (other, _) = try wiringSkin(t, """
        [Wallpaper]
        Measure=Registry
        RegKey=Control Panel\\Desktop
        RegValue=Wallpaper
        """)
        other.update()
        t.equal(other.measure(named: "Wallpaper")?.stringValue, "")
        t.equal(other.measure(named: "Wallpaper")?.valueUnavailable, true)
        t.equal(other.issues.filter { $0.contains("Control Panel\\Desktop\\Wallpaper") }.count, 1)
        t.check(RegistryMeasure.isWallpaperValue(hive: "HKCU", key: "control panel/desktop/", value: " WALLPAPER "))
        t.check(!RegistryMeasure.isWallpaperValue(hive: "HKLM", key: "Control Panel\\Desktop", value: "Wallpaper"))
        t.check(!RegistryMeasure.isWallpaperValue(hive: "HKCU", key: "Control Panel\\Desktop", value: "WallpaperStyle"))
    }

    // MARK: Transient compatibility notes

    t.suite("Engine wiring: removeIssue takes back a note that no longer applies") {
        let (skin, _) = try wiringSkin(t, "[Rainmeter]\nUpdate=1000\n")
        skin.addIssue("A: permission missing")
        skin.addIssue("B: Windows only")
        skin.addIssue("A: permission missing")
        t.equal(skin.issues, ["A: permission missing", "B: Windows only"])
        skin.removeIssue("A: permission missing")
        t.equal(skin.issues, ["B: Windows only"])
        skin.removeIssue("A: permission missing")
        skin.removeIssue("never added")
        t.equal(skin.issues, ["B: Windows only"], "removing an absent note changes nothing")
        skin.addIssue("A: permission missing")
        t.equal(skin.issues, ["B: Windows only", "A: permission missing"], "a removed note can come back")
    }
}
