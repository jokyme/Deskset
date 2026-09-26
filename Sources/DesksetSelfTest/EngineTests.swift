import Foundation
@testable import DesksetCore

func runEngineTests(_ t: TestRunner) {
    t.suite("Engine: variables, include, calc and string meter") {
        let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        Update=1000

        [Variables]
        @Include=#@#Shared.inc
        Base=10
        Double=(#Base# * 2)

        [MeasureCalc]
        Measure=Calc
        Formula=#Base# + 5

        [MeasureCalc2]
        Measure=Calc
        Formula=MeasureCalc * 2

        [MeterText]
        Meter=String
        MeasureName=MeasureCalc
        MeasureName2=MeasureCalc2
        Text=#Greeting# %1 and %2
        Prefix=<
        Postfix=>
        """, files: ["Root/@Resources/Shared.inc": "[Variables]\nGreeting=Hello\n"])
        skin.update()
        t.equal(skin.variable("Greeting"), "Hello")
        t.close(skin.measure(named: "MeasureCalc")?.value ?? -1, 15)
        t.close(skin.measure(named: "measurecalc2")?.value ?? -1, 30)
        t.equal(text(skin, "MeterText"), "<Hello 15 and 30>")
    }

    t.suite("Engine: relative positions, padding and MeterStyle") {
        let (skin, _) = try makeSkin(t, """
        [StyleBox]
        W=20
        H=10
        SolidColor=255,0,0

        [A]
        Meter=Image
        MeterStyle=StyleBox
        X=5
        Y=7

        [B]
        Meter=Image
        MeterStyle=StyleBox
        X=3R
        Y=0r
        Padding=1,2,3,4

        [C]
        Meter=Image
        MeterStyle=StyleBox
        W=40
        X=(2*5)r
        Y=1R
        """)
        skin.update()
        let a = skin.meter(named: "A")!.frame, b = skin.meter(named: "B")!.frame, c = skin.meter(named: "C")!.frame
        t.equal(a, SkinRect(x: 5, y: 7, width: 20, height: 10))
        t.equal(b, SkinRect(x: 28, y: 7, width: 24, height: 16))
        t.equal(c, SkinRect(x: 38, y: 24, width: 40, height: 10))
        t.equal(skin.meter(named: "A")!.solidColor, RGBA(r: 255, g: 0, b: 0))
        t.close(skin.width, 78)
        t.close(skin.height, 34)
    }

    t.suite("Engine: system measures") {
        let (skin, _) = try makeSkin(t, """
        [CPU]
        Measure=CPU
        [RAM]
        Measure=PhysicalMemory
        [RAMTotal]
        Measure=PhysicalMemory
        Total=1
        [Up]
        Measure=Uptime
        [Disk]
        Measure=FreeDiskSpace
        Drive=C:
        InvertMeasure=1
        [Proc]
        Measure=Process
        ProcessName=Finder.exe
        [User]
        Measure=SysInfo
        SysInfoType=USER_NAME
        [Battery]
        Measure=Plugin
        Plugin=Plugins\\PowerPlugin.dll
        PowerState=PERCENT
        [Reg]
        Measure=Registry
        [MeterCPU]
        Meter=String
        MeasureName=CPU
        Text=%1%
        [MeterRAM]
        Meter=String
        MeasureName=RAM
        AutoScale=1
        NumOfDecimals=1
        Text=%1B
        [MeterUp]
        Meter=String
        MeasureName=Up
        """)
        skin.update()
        t.close(skin.measure(named: "CPU")!.value, 42)
        t.close(skin.measure(named: "CPU")!.maxValue, 100)
        t.equal(text(skin, "MeterCPU"), "42%")
        t.close(skin.measure(named: "RAM")!.relativeValue, 0.5)
        t.close(skin.measure(named: "RAMTotal")!.value, 16 * 1_073_741_824)
        t.equal(text(skin, "MeterRAM"), "8.0 GB")
        t.equal(text(skin, "MeterUp"), "1d 1:01")
        t.close(skin.measure(named: "Disk")!.value, 750)
        t.close(skin.measure(named: "Proc")!.value, 1)
        t.equal(skin.measure(named: "User")!.stringValue, "tester")
        t.close(skin.measure(named: "Battery")!.value, 80)
        t.check(skin.issues.contains { $0.contains("Registry") }, "unsupported measure reported")
    }

    t.suite("Engine: bangs, dynamic variables and section variables") {
        let (skin, host) = try makeSkin(t, """
        [Variables]
        Count=0

        [MeasureCount]
        Measure=Calc
        Formula=#Count#
        DynamicVariables=1

        [MeterBox]
        Meter=Image
        X=50
        W=10
        H=10
        SolidColor=0,0,0,255
        LeftMouseUpAction=[!HideMeter MeterBox][!SetOption MeterCount Text "Changed"][!Move 10 20]["https://example.com"]

        [MeterCount]
        Meter=String
        X=0
        Y=20
        Text=Count #Count# / [MeasureCount:] / [MeterBox:X]
        DynamicVariables=1
        LeftMouseUpAction=[!SetVariable Count "(#Count#+1)"][!UpdateMeasure MeasureCount][!UpdateMeter MeterCount][!Redraw]
        """)
        skin.update()
        t.equal(text(skin, "MeterCount"), "Count 0 / 0 / 50")
        let countFrame = skin.meter(named: "MeterCount")!.frame
        t.check(skin.mouseEvent(.leftUp, x: countFrame.x + 1, y: countFrame.y + 1), "click handled")
        t.equal(skin.variable("Count"), "1")
        t.equal(text(skin, "MeterCount"), "Count 1 / 1 / 50")

        skin.mouseEvent(.leftUp, x: 55, y: 5)
        t.check(skin.meter(named: "MeterBox")!.hidden, "meter hidden")
        skin.update()
        t.equal(text(skin, "MeterCount"), "Changed")
        t.equal(host.handled.map(\.name), ["move"])
        t.equal(host.handled.first?.args ?? [], ["10", "20"])
        t.equal(host.executed, ["https://example.com"])

        skin.execute("[!SetOption MeterCount Text Other \"Root\\Other\"]", from: nil)
        t.equal(host.forwarded.first?.1 ?? "", "Root\\Other")
        t.equal(host.forwarded.first?.0.args ?? [], ["MeterCount", "Text", "Other"])
    }

    t.suite("Engine: IfCondition, IfAbove, OnChangeAction and UpdateDivider") {
        let (skin, _) = try makeSkin(t, """
        [MeasureLoop]
        Measure=Loop
        StartValue=1
        EndValue=4
        IfCondition=MeasureLoop >= 3
        IfTrueAction=[!SetVariable Cond high]
        IfFalseAction=[!SetVariable Cond low]
        IfAboveValue=3
        IfAboveAction=[!SetVariable Above yes]
        OnChangeAction=[!SetVariable Changes "([#Changes]+1)"]

        [MeasureSlow]
        Measure=Calc
        Formula=MeasureSlow + 1
        UpdateDivider=2
        """)
        skin.setVariable("Changes", "0")
        skin.update()
        t.equal(skin.variable("Cond"), "low")
        t.equal(skin.variable("Above"), nil)
        skin.update()
        skin.update()
        t.equal(skin.variable("Cond"), "high")
        skin.update()
        t.equal(skin.variable("Above"), "yes")
        t.equal(skin.variable("Changes"), "3")
        t.close(skin.measure(named: "MeasureSlow")!.value, 2)
        skin.update()
        t.close(skin.measure(named: "MeasureLoop")!.value, 1, "loop wraps")
        t.close(skin.measure(named: "MeasureSlow")!.value, 3)
    }

    t.suite("Engine: Substitute, string align and time") {
        let (skin, _) = try makeSkin(t, """
        [MeasureText]
        Measure=String
        String=Hello World
        Substitute="World":"Mac"

        [MeasureTime]
        Measure=Time
        Format=%Y
        TimeStamp=13394419200

        [MeterRight]
        Meter=String
        MeasureName=MeasureText
        X=100
        StringAlign=Right

        [MeterCenter]
        Meter=String
        MeasureName=MeasureTime
        X=100
        Y=20
        StringAlign=CenterBottom
        """)
        skin.update()
        t.equal(text(skin, "MeterRight"), "Hello Mac")
        t.equal(skin.meter(named: "MeterRight")!.frame, SkinRect(x: 37, y: 0, width: 63, height: 14))
        t.equal(text(skin, "MeterCenter"), "2025")
        t.equal(skin.meter(named: "MeterCenter")!.frame, SkinRect(x: 86, y: 6, width: 28, height: 14))
    }

    t.suite("Engine: action escapes, magic quotes, mouse variables, keywords") {
        let (skin, _) = try makeSkin(t, """
        [Variables]
        MyColor=255,0,0

        [MeasureText]
        Measure=String
        String=a.b*c d

        [MeterBox]
        Meter=Image
        X=10
        Y=10
        W=100
        H=20
        LeftMouseUpAction=[!SetOption MeterText Text #*MyColor*#][!SetVariable Literal \"\"\"[MeasureText] (1+1)\"\"\"][!SetVariable Pos "$MouseX$,$MouseY$,$MouseX:%$"]

        [MeterText]
        Meter=String
        Y=40
        Text=[MeasureText:EscapeRegExp]|[MeasureText:EncodeUrl]
        DynamicVariables=1
        """)
        skin.update()
        t.equal(text(skin, "MeterText"), #"a\.b\*c d|a.b%2Ac%20d"#)
        skin.mouseEvent(.leftUp, x: 35, y: 15)
        t.equal(skin.variable("Literal"), "[MeasureText] (1+1)")
        t.equal(skin.variable("Pos"), "25,5,25")
        t.equal(skin.meter(named: "MeterText")?.rawOption("Text"), "#MyColor#", "escape consumed exactly once")
        skin.update()
        t.equal(text(skin, "MeterText"), "255,0,0", "then resolved dynamically")
    }

    t.suite("Engine: huge formula values do not crash") {
        let (skin, _) = try makeSkin(t, """
        [MeasureRandom]
        Measure=Calc
        Formula=Random
        LowBound=(10**300)
        HighBound=(10**301)
        UpdateRandom=1

        [MeterFar]
        Meter=String
        X=(10**300)
        FontWeight=(10**300)
        Text=[MeterFar:X]
        DynamicVariables=1
        """)
        skin.update()
        skin.update()
        t.check(!text(skin, "MeterFar").isEmpty)
    }

    runEngineManualTests(t)
}

// MARK: - Helpers for the manual-conformance suites

private let gib = 1_073_741_824.0

/// A complete `SystemDataSource` (FakeSystem cannot override the protocol's default methods such as
/// `volumeInfo`, because those are dispatched through its original conformance).
final class EngineTestSystem: SystemDataSource {
    var cpu = 42.0
    var memory = MemoryStatus(physicalTotal: 16 * gib, physicalUsed: 8 * gib, swapTotal: 2 * gib, swapUsed: gib)
    var interfaces = ["en0", "en1"]
    var best: String? = "en1"
    var counters: [String: NetworkCounters] = ["en0": NetworkCounters(received: 1000, sent: 500),
                                               "en1": NetworkCounters(received: 10, sent: 5)]
    var requestedInterfaces: [String?] = []
    var disk: (total: Double, free: Double)? = (1000, 250)
    var volume: VolumeInfo? = VolumeInfo(label: "Macintosh HD", kind: .fixed)
    var uptimeSeconds = 90061.0
    var batteryStatus: BatteryStatus? = BatteryStatus(percent: 80, isCharging: false, isPluggedIn: false,
                                                      minutesRemaining: 90)
    var frequency: Double? = 3.2e9
    var sysInfoAnswers: [String: (number: Double, string: String?)] = ["USER_NAME": (0, "tester")]
    /// Named, so skins reading `WinSat` `PrimaryAdapterString` have a value on Intel Macs (CI runners) too.
    var graphics: String? = "Test Graphics"

    var processorCount: Int { 8 }
    func cpuUsage(processor: Int) -> Double { processor == 0 ? cpu : Double(processor) }
    func memoryStatus() -> MemoryStatus { memory }
    func networkInterfaces() -> [String] { interfaces }
    func networkCounters(interface: String?) -> NetworkCounters {
        requestedInterfaces.append(interface)
        if let interface { return counters[interface] ?? NetworkCounters() }
        var total = NetworkCounters()
        for c in counters.values {
            total.received += c.received
            total.sent += c.sent
        }
        return total
    }
    func diskSpace(path: String) -> (total: Double, free: Double)? { disk }
    func uptime() -> TimeInterval { uptimeSeconds }
    func battery() -> BatteryStatus? { batteryStatus }
    func isProcessRunning(_ name: String) -> Bool { name.lowercased() == "finder" }
    func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { sysInfoAnswers[type] }
    func bestNetworkInterface() -> String? { best }
    func volumeInfo(path: String) -> VolumeInfo? { volume }
    func cpuFrequency() -> Double? { frequency }
    func graphicsAdapterName() -> String? { graphics }
}

/// FakeHost with a configurable environment (window frame, screens, z-position…).
final class EnvironmentHost: FakeHost {
    var env = SkinEnvironment(
        windowFrame: SkinRect(x: 100, y: 200, width: 300, height: 50),
        screens: [SkinScreen(area: SkinRect(width: 1920, height: 1080),
                             workArea: SkinRect(x: 0, y: 25, width: 1920, height: 1055)),
                  SkinScreen(area: SkinRect(x: 1920, y: 0, width: 1280, height: 800),
                             workArea: SkinRect(x: 1920, y: 0, width: 1280, height: 770))],
        zPosition: 1, configEditor: "/usr/bin/vi", currentScreen: 1)
    override func environment(for skin: Skin) -> SkinEnvironment { env }
}

private var retainedEngineHosts: [FakeHost] = []

/// Like `makeSkin`, with any `SystemDataSource`. Returns the skins folder too.
private func makeEngineSkin(_ t: TestRunner, _ ini: String, files: [String: String] = [:],
                            host: FakeHost = FakeHost(), system: SystemDataSource = EngineTestSystem())
    throws -> (skin: Skin, host: FakeHost, skins: URL) {
    let skins = t.temporaryDirectory("engine-manual").appendingPathComponent("Skins")
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
    let skin = Skin(config: "Root\\Sub", fileURL: dir.appendingPathComponent("Skin.ini"), skinsDirectory: skins,
                    system: system, host: host)
    retainedEngineHosts.append(host)
    try skin.load()
    return (skin, host, skins)
}

private func value(_ skin: Skin, _ measure: String) -> Double {
    skin.measure(named: measure)?.value ?? .nan
}

private func string(_ skin: Skin, _ measure: String) -> String {
    skin.measure(named: measure)?.stringValue ?? "<no measure \(measure)>"
}

private func frame(_ skin: Skin, _ meter: String) -> SkinRect {
    skin.meter(named: meter)?.frame ?? SkinRect(x: -1, y: -1, width: -1, height: -1)
}

private func run(_ skin: Skin, _ action: String) {
    skin.execute(action, from: nil)
}

// MARK: - Manual conformance

func runEngineManualTests(_ t: TestRunner) {
    runRainmeterSectionTests(t)
    runMeasureGeneralTests(t)
    runMeterGeneralTests(t)
    runBangTests(t)
    runBuiltinMeasureTests(t)
    runEngineReviewTests(t)
    runEngineIntegrationTests(t)
    runEngineIntegrationReviewTests(t)
    runEngineCompatTests(t)
}

private func runRainmeterSectionTests(_ t: TestRunner) {
    t.suite("Engine: [Rainmeter] options") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Rainmeter]
        Update=5
        DefaultUpdateDivider=2
        DynamicWindowSize=1
        SkinWidth=0
        SkinHeight=50
        DragMargins=0,-10,5
        BackgroundMode=2
        SolidColor2=255,0,0
        GradientAngle=90
        BevelType=1
        BevelColor=1,2,3
        BevelColor2=4,5,6
        BackgroundMargins=1,2,3,4
        TransitionUpdate=50
        ToolTipHidden=1
        MouseActionCursor=0
        MouseActionCursorName=Pointer.cur
        SelectedColor=10,20,30,40
        DragGroup=A | B
        Blur=1
        BlurRegion=1,10,10,190,50
        BlurRegion2=3,10,70,80,110
        DefaultWindowX=50%
        DefaultAlwaysOnTop=1
        Group=Suite | Other
        AccurateText=1
        DynamicVariables=1

        [M]
        Meter=Image
        W=40
        H=20
        """)
        let s = skin.settings
        t.equal(s.update, 16, "Update below 16 is raised to the minimum")
        t.equal(s.defaultUpdateDivider, 2)
        t.check(s.dynamicWindowSize)
        t.check(s.skinWidth == nil, "SkinWidth=0 has no effect")
        t.equal(s.skinHeight, 50)
        t.equal(s.dragMargins, SkinInsets(left: 0, top: -10, right: 5, bottom: 0))
        t.equal(s.backgroundMode, 2)
        t.equal(s.solidColor, RGBA(r: 128, g: 128, b: 128, a: 255), "SolidColor default 128,128,128,255")
        t.equal(s.solidColor2, RGBA(r: 255, g: 0, b: 0))
        t.close(s.gradientAngle, 90)
        t.equal(s.bevelType, 1)
        t.equal(s.bevelColor, RGBA(r: 1, g: 2, b: 3))
        t.equal(s.bevelColor2, RGBA(r: 4, g: 5, b: 6))
        t.equal(s.backgroundMargins, SkinInsets(left: 1, top: 2, right: 3, bottom: 4))
        t.equal(s.transitionUpdate, 50)
        t.check(s.toolTipHidden)
        t.check(!s.mouseActionCursor)
        t.equal(s.mouseActionCursorName, "Pointer.cur")
        t.equal(s.selectedColor, RGBA(r: 10, g: 20, b: 30, a: 40))
        t.equal(s.dragGroups, ["a", "b"])
        t.check(s.blur)
        t.equal(s.blurRegions, [[1, 10, 10, 190, 50], [3, 10, 70, 80, 110]])
        t.equal(s.windowDefaults, ["WindowX": "50%", "AlwaysOnTop": "1"])
        t.equal(s.groups, ["Suite", "Other"])
        t.check(skin.isInSkinGroup("suite") && !skin.isInSkinGroup("nope"))
        t.check(s.accurateText)
        t.check(skin.rainmeterSection?.dynamicVariables == false, "[Rainmeter] does not support DynamicVariables")
        t.check(skin.meter(named: "M")?.mouseActionCursor == false, "meters inherit MouseActionCursor")
        skin.update()
        t.close(skin.width, 40)
        t.close(skin.height, 50, "SkinHeight fixes the height")
        // DragMargins: top -10 → only the bottom 10 points are draggable; right 5 → not the last 5 columns.
        t.check(skin.isInDragArea(x: 10, y: 45))
        t.check(!skin.isInDragArea(x: 10, y: 20))
        t.check(!skin.isInDragArea(x: 36, y: 45))

        let (once, _, _) = try makeEngineSkin(t, "[Rainmeter]\nUpdate=-1\n")
        t.equal(once.settings.update, -1)
        let (zero, _, _) = try makeEngineSkin(t, "[Rainmeter]\nUpdate=0\n")
        t.equal(zero.settings.update, 16)
        let (plain, _, _) = try makeEngineSkin(t, "[M]\nMeter=Image\n")
        t.equal(plain.settings.update, 1000)
        t.equal(plain.settings.backgroundMode, 1, "BackgroundMode default 1")
        t.check(plain.settings.mouseActionCursor)
        t.equal(plain.settings.transitionUpdate, 100)
    }

    t.suite("Engine: DefaultUpdateDivider and UpdateDivider=-1") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Rainmeter]
        DefaultUpdateDivider=-1

        [Once]
        Measure=Calc
        Formula=Once + 1

        [Every]
        Measure=Calc
        Formula=Every + 1
        UpdateDivider=1

        [Text]
        Meter=String
        MeasureName=Once
        """)
        skin.update()
        skin.update()
        skin.update()
        t.close(value(skin, "Once"), 1, "only updated on load")
        t.close(value(skin, "Every"), 3, "own UpdateDivider overrides DefaultUpdateDivider")
        run(skin, "[!UpdateMeasure Once]")
        t.close(value(skin, "Once"), 2, "bangs still update it")
        t.equal(text(skin, "Text"), "1", "meter not updated either")
        run(skin, "[!UpdateMeter Text]")
        t.equal(text(skin, "Text"), "2")
    }

    t.suite("Engine: window size, DynamicWindowSize and MoveMeter") {
        let (skin, host, _) = try makeEngineSkin(t, """
        [Box]
        Meter=Image
        W=10
        H=10
        """)
        skin.update()
        t.close(skin.width, 10)
        run(skin, "[!SetOption Box W 30]")
        skin.update()
        t.close(frame(skin, "Box").width, 30)
        t.close(skin.width, 10, "size is only computed on load without DynamicWindowSize")
        let redraws = host.redraws
        run(skin, "[!MoveMeter 50 5 Box]")
        t.equal(frame(skin, "Box"), SkinRect(x: 50, y: 5, width: 30, height: 10))
        t.close(skin.width, 80, "MoveMeter re-evaluates the window size")
        t.close(skin.height, 15)
        t.check(host.redraws > redraws)

        let (dynamic, _, _) = try makeEngineSkin(t, """
        [Rainmeter]
        DynamicWindowSize=1
        [Box]
        Meter=Image
        X=-5
        W=10
        H=10
        [Hidden]
        Meter=Image
        X=500
        W=10
        H=10
        Hidden=1
        """)
        dynamic.update()
        t.close(dynamic.width, 5, "meters left of 0 are cut off; hidden meters do not count")
        run(dynamic, "[!SetOption Box W 30]")
        dynamic.update()
        t.close(dynamic.width, 25)
    }

    t.suite("Engine: OnRefresh/OnUpdate/OnClose/OnFocus/OnWake actions") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Rainmeter]
        OnRefreshAction=[!SetVariable Refreshed "[MeasureA]"][!SetVariable Refreshes "([#Refreshes]+1)"]
        OnUpdateAction=[!SetVariable Updates "([#Updates]+1)"]
        OnCloseAction=[!SetVariable Closed 1]
        OnFocusAction=[!SetVariable Focus in]
        OnUnfocusAction=[!SetVariable Focus out]
        OnWakeAction=[!SetVariable Woke "[MeasureA]"]

        [Variables]
        Refreshes=0
        Updates=0

        [MeasureA]
        Measure=Calc
        Formula=MeasureA + 1
        """)
        skin.update()
        t.equal(skin.variable("Refreshed"), "1", "OnRefreshAction runs at the end of the first update")
        skin.update()
        skin.update()
        t.equal(skin.variable("Refreshes"), "1")
        t.equal(skin.variable("Updates"), "3")
        skin.focusChanged(true)
        t.equal(skin.variable("Focus"), "in")
        skin.focusChanged(false)
        t.equal(skin.variable("Focus"), "out")
        skin.systemDidWake()
        t.equal(skin.variable("Woke"), nil, "OnWakeAction waits for the end of the next update")
        skin.update()
        t.equal(skin.variable("Woke"), "4")
        skin.close()
        t.equal(skin.variable("Closed"), "1")
        let count = skin.updateCount
        skin.update()
        t.equal(skin.updateCount, count, "a closed skin no longer updates")

        let (once, _, _) = try makeEngineSkin(t, """
        [Rainmeter]
        Update=-1
        OnWakeAction=[!SetVariable Woke yes]
        """)
        once.update()
        once.systemDidWake()
        t.equal(once.variable("Woke"), "yes", "Update=-1 skins run OnWakeAction right away")
    }

    t.suite("Engine: context menu items") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Rainmeter]
        ContextTitle=Open #Name#
        ContextAction=[!SetVariable Picked 1]
        ContextTitle2=---
        ContextTitle3=A very long context menu title that exceeds thirty
        ContextAction3=[!SetVariable Picked 3]
        ContextTitle4=[#Dyn]
        ContextAction4=[!SetVariable Picked 4]
        ContextTitle5=No action here
        ContextTitle6=Never shown
        ContextAction6=[]

        [Variables]
        Name=Site
        Dyn=First
        """)
        var items = skin.contextMenuItems()
        t.equal(items.map(\.title), ["Open Site", "-", "A very long context menu title...", "First"])
        t.equal(items.map(\.isSeparator), [false, true, false, false])
        t.equal(skin.settings.contextItems.map(\.title), ["Open Site", "A very long context menu title...", "First"])
        run(skin, "[!SetVariable Dyn Second]")
        t.equal(skin.contextMenuItems().last?.title, "Second", "titles are read when the menu opens")
        run(skin, "[!SetOption Rainmeter ContextTitle Renamed]")
        items = skin.contextMenuItems()
        t.equal(items.first?.title, "Renamed", "!SetOption may change context items")
        t.equal(skin.settings.contextItems.first?.title, "Renamed")
        run(skin, "[!SetOption Rainmeter Update 50][!SetOption Rainmeter LeftMouseUpAction \"[!Log x]\"]")
        t.equal(skin.settings.update, 1000, "other [Rainmeter] options cannot be changed")
        t.check(skin.rainmeterSection?.mouseActions.isEmpty == true)
        skin.execute(items.first?.action ?? "", from: skin.rainmeterSection)
        t.equal(skin.variable("Picked"), "1")

        let (few, _, _) = try makeEngineSkin(t, """
        [Rainmeter]
        ContextTitle=---
        ContextAction=[!Log dashes]
        ContextTitle2=---
        ContextTitle3=Ignored
        ContextAction3=[!Log x]
        """)
        t.equal(few.contextMenuItems().map(\.title), ["---"],
                "with 3 or fewer titles dashes are a normal item and a title without action ends the list")
    }

    t.suite("Engine: LocalFont and @Resources/Fonts") {
        let (skin, _, skins) = try makeEngineSkin(t, """
        [Rainmeter]
        LocalFont=fonts\\Local.ttf
        """, files: ["Root/@Resources/Fonts/B.ttf": "x", "Root/@Resources/Fonts/a.otf": "x",
                     "Root/@Resources/Fonts/D.TTC": "x", "Root/@Resources/Fonts/c.otc": "x",
                     "Root/@Resources/Fonts/readme.txt": "x", "Root/@Resources/Fonts/old.fon": "x",
                     "Root/@Resources/Fonts/._B.ttf": "x", "Root/@Resources/Fonts/.hidden.otf": "x"])
        let fonts = skin.settings.localFonts
        // TrueType / OpenType and their collections (.ttc, .otc), any case; bitmap fonts, other files and hidden files
        // (AppleDouble `._B.ttf` next to a font copied from a FAT volume) are skipped.
        t.equal(fonts.map { ($0 as NSString).lastPathComponent }, ["Local.ttf", "B.ttf", "D.TTC", "a.otf", "c.otc"])
        t.check(fonts.first?.hasSuffix("/Root/Sub/fonts/Local.ttf") == true, "LocalFont is relative to the skin folder")
        t.check(fonts.last?.hasPrefix(skins.path) == true || fonts.last?.contains("/Root/@Resources/Fonts/") == true)
    }
}

private func runMeasureGeneralTests(_ t: TestRunner) {
    t.suite("Engine: measure range, InvertMeasure and AverageSize") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Counter]
        Measure=Calc
        Formula=Counter + 1

        [MaxOnly]
        Measure=Calc
        Formula=Counter + 5
        MaxValue=100

        [Fixed]
        Measure=Calc
        Formula=3
        MinValue=0
        MaxValue=10
        InvertMeasure=1

        [Str]
        Measure=String
        String=5
        MinValue=0
        MaxValue=10
        InvertMeasure=1

        [Avg]
        Measure=Calc
        Formula=Counter * 3
        AverageSize=3

        [Plain]
        Measure=String
        String=x
        """)
        skin.update()
        skin.update()
        skin.update()
        let counter = skin.measure(named: "Counter")!
        t.close(counter.minValue, 0, "Calc: values 1…3 do not narrow the default MinValue 0")
        t.close(counter.maxValue, 3, "Calc: the largest value seen widens MaxValue")
        t.close(skin.measure(named: "MaxOnly")!.minValue, 0, "MaxValue alone → MinValue 0")
        t.close(skin.measure(named: "MaxOnly")!.maxValue, 100)
        t.close(value(skin, "Fixed"), 7, "InvertMeasure: MaxValue - (value - MinValue)")
        t.close(value(skin, "Str"), 5, "String measures ignore InvertMeasure")
        t.close(value(skin, "Avg"), 3, "average of 0, 3, 6")
        skin.update()
        t.close(value(skin, "Avg"), 6, "average of 3, 6, 9")
        t.close(skin.measure(named: "Plain")!.minValue, 0, "MinValue default 0")
        t.close(skin.measure(named: "Plain")!.maxValue, 1, "MaxValue default 1")
    }

    t.suite("Engine: Disabled and Paused") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Variables]
        PausedUpdates=0

        [Loop]
        Measure=Loop
        StartValue=1
        EndValue=100

        [Text]
        Measure=String
        String=hello
        Disabled=1

        [Paused]
        Measure=Calc
        Formula=Paused + 1
        OnUpdateAction=[!SetVariable PausedUpdates "([#PausedUpdates]+1)"]

        [Show]
        Meter=String
        Text=[Loop:]|[Text]|[Text:]
        DynamicVariables=1
        """)
        skin.update()
        t.close(value(skin, "Loop"), 1)
        t.close(value(skin, "Paused"), 1)
        t.equal(skin.variable("PausedUpdates"), "1")
        t.check(skin.measure(named: "Text")!.disabled, "Disabled=1 on load")
        t.check(skin.measure(named: "Text")!.rawString == nil, "an initially disabled measure populates nothing")

        run(skin, "[!PauseMeasure Paused]")
        skin.update()
        t.close(value(skin, "Paused"), 1, "paused keeps its value")
        t.equal(skin.variable("PausedUpdates"), "1", "no OnUpdateAction while paused")

        run(skin, "[!DisableMeasure Loop]")
        t.close(value(skin, "Loop"), 0, "disabled is 0 in numerical contexts right away")
        skin.update()
        t.close(value(skin, "Loop"), 0)
        run(skin, "[!EnableMeasure Loop][!EnableMeasure Text]")
        skin.update()
        t.close(value(skin, "Loop"), 3, "enabled again, continues")
        t.equal(string(skin, "Text"), "hello")
        run(skin, "[!DisableMeasure Text]")
        skin.update()
        t.equal(text(skin, "Show"), "4|hello|0", "disabled: number 0, previous string kept")

        run(skin, "[!UnpauseMeasure Paused]")
        skin.update()
        t.close(value(skin, "Paused"), 2)
        run(skin, "[!TogglePauseMeasure Paused]")
        t.check(skin.measure(named: "Paused")!.paused)
        run(skin, "[!TogglePauseMeasure Paused][!ToggleMeasure Paused]")
        t.check(!skin.measure(named: "Paused")!.paused && skin.measure(named: "Paused")!.disabled)

        run(skin, "[!SetOption Loop Disabled 1]")
        skin.update()
        t.check(skin.measure(named: "Loop")!.disabled, "Disabled can be set with !SetOption")
        run(skin, "[!SetOption Loop Disabled 0]")
        skin.update()
        t.check(!skin.measure(named: "Loop")!.disabled)
        t.close(value(skin, "Loop"), 6)
    }

    t.suite("Engine: IfCondition") {
        let (skin, host, _) = try makeEngineSkin(t, """
        [Variables]
        V=1
        T=0
        F=0
        Odd=0
        M=0

        [Val]
        Measure=Calc
        Formula=#V#
        DynamicVariables=1
        IfCondition=Val > 5
        IfTrueAction=[!SetVariable T "([#T]+1)"]
        IfFalseAction=[!SetVariable F "([#F]+1)"]
        IfCondition2=(Val = 3) || (Val = 7)
        IfTrueAction2=[!SetVariable Odd "([#Odd]+1)"]
        IfCondition3=Missing > 1
        IfTrueAction3=[!SetVariable Bad 1]
        IfFalseAction3=[!SetVariable Bad 1]

        [Mode]
        Measure=Calc
        Formula=1
        IfCondition=Mode = 1
        IfTrueAction=[!SetVariable M "([#M]+1)"]
        IfConditionMode=1
        """)
        func step(_ v: String) {
            skin.setVariable("V", v)
            skin.update()
        }
        skin.update()
        t.equal(skin.variable("F"), "1", "the first evaluation counts as becoming false")
        t.equal(skin.variable("T"), "0")
        step("3")
        t.equal(skin.variable("Odd"), "1")
        t.equal(skin.variable("F"), "1", "still false: no repeat")
        step("7")
        t.equal(skin.variable("T"), "1")
        t.equal(skin.variable("Odd"), "1", "still true: no repeat")
        step("8")
        step("2")
        t.equal(skin.variable("F"), "2")
        t.equal(skin.variable("T"), "1")
        t.equal(skin.variable("Bad"), nil, "a condition naming an unknown measure runs no action")
        t.check(host.logs.contains { $0.contains("cannot evaluate IfCondition") })
        t.equal(skin.variable("M"), "5", "IfConditionMode=1 runs on every update")

        let (dynamic, _, _) = try makeEngineSkin(t, """
        [Variables]
        Hits=0
        Low=0

        [A]
        Measure=Loop
        StartValue=10
        EndValue=20

        [Check]
        Measure=Calc
        Formula=1
        DynamicVariables=1
        IfCondition=[A:] > 5
        IfTrueAction=[!SetVariable Hits "([#Hits]+1)"]
        IfAboveValue=([A:] - 1)
        IfAboveAction=[!SetVariable Low "([#Low]+1)"]
        """)
        for _ in 0..<4 { dynamic.update() }
        t.equal(dynamic.variable("Hits"), "1", "a dynamic condition keeps its state when its text changes")
        t.equal(dynamic.variable("Low"), "0")
    }

    t.suite("Engine: IfAbove / IfBelow / IfEqual") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Variables]
        V=1
        Above=0
        Below=0
        Equal=0

        [Val]
        Measure=Calc
        Formula=#V#
        DynamicVariables=1
        IfAboveValue=5
        IfAboveAction=[!SetVariable Above "([#Above]+1)"]
        IfBelowValue=2
        IfBelowAction=[!SetVariable Below "([#Below]+1)"]
        IfEqualValue=3
        IfEqualAction=[!SetVariable Equal "([#Equal]+1)"]
        """)
        for v in ["1", "6", "7", "5", "6", "3.4", "2.6", "4", "3", "1"] {
            skin.setVariable("V", v)
            skin.update()
        }
        t.equal(skin.variable("Above"), "2", "fires when going above, re-arms when no longer above")
        t.equal(skin.variable("Below"), "2")
        t.equal(skin.variable("Equal"), "2", "values are rounded to integers (3.4 and 2.6 equal 3)")
    }

    t.suite("Engine: IfMatch") {
        let (skin, host, _) = try makeEngineSkin(t, """
        [Variables]
        S=Mon
        Weekend=0
        Weekday=0
        MM=0

        [Str]
        Measure=String
        String=#S#
        DynamicVariables=1
        Substitute="Sat":"Saturday"
        IfMatch=Saturday|Sunday
        IfMatchAction=[!SetVariable Weekend "([#Weekend]+1)"]
        IfNotMatchAction=[!SetVariable Weekday "([#Weekday]+1)"]
        IfMatch2=(?i)^MON
        IfMatchAction2=[!SetVariable Mon 1]
        IfMatch3=([
        IfMatchAction3=[!SetVariable Bad 1]
        IfNotMatchAction3=[!SetVariable Bad 1]

        [ModeStr]
        Measure=String
        String=abc
        IfMatch=b
        IfMatchAction=[!SetVariable MM "([#MM]+1)"]
        IfMatchMode=1
        """)
        skin.update()
        t.equal(skin.variable("Weekday"), "1")
        t.equal(skin.variable("Mon"), "1")
        for s in ["Sat", "Sunday", "Tue"] {
            skin.setVariable("S", s)
            skin.update()
        }
        t.equal(skin.variable("Weekend"), "1", "matched on the substituted string, once")
        t.equal(skin.variable("Weekday"), "2")
        t.equal(skin.variable("Bad"), nil, "invalid pattern runs no action")
        t.check(host.logs.contains { $0.contains("invalid IfMatch") })
        t.equal(skin.variable("MM"), "4", "IfMatchMode=1 runs on every update")
    }

    t.suite("Engine: OnChangeAction and OnUpdateAction") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Variables]
        N=1
        Changes=0
        Updates=0
        NumChanges=0

        [Str]
        Measure=String
        String=a
        OnChangeAction=[!SetVariable Changes "([#Changes]+1)"]
        OnUpdateAction=[!SetVariable Updates "([#Updates]+1)"]

        [Num]
        Measure=Calc
        Formula=#N#
        DynamicVariables=1
        OnChangeAction=[!SetVariable NumChanges "([#NumChanges]+1)"]
        """)
        skin.update()
        skin.update()
        t.equal(skin.variable("Changes"), "0", "the initial value is not a change")
        t.equal(skin.variable("Updates"), "2")
        run(skin, "[!SetOption Str String b]")
        skin.update()
        t.equal(skin.variable("Changes"), "1")
        run(skin, "[!UpdateMeasure Str]")
        t.equal(skin.variable("Updates"), "4", "bang updates run OnUpdateAction too")
        run(skin, "[!SetOption Str String 1]")
        skin.update()
        run(skin, "[!SetOption Str String 01]")
        skin.update()
        t.equal(skin.variable("Changes"), "3", "a string change with the same number is a change")
        skin.setVariable("N", "2")
        skin.update()
        skin.update()
        t.equal(skin.variable("NumChanges"), "1")
    }

    t.suite("Engine: measure order and Substitute") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [A]
        Measure=Calc
        Formula=B

        [B]
        Measure=Calc
        Formula=B + 1

        [Re]
        Measure=String
        String=I am Rainy
        RegExpSubstitute=1
        Substitute="(\\w+) (\\w+) (\\w+)":"\\3, \\1 \\2","Rainy":"Yoda"

        [Plain]
        Measure=String
        String=1 10
        Substitute="1":"One","10":"Ten"
        """)
        skin.update()
        t.close(value(skin, "A"), 0, "a measure sees later measures' previous values")
        skin.update()
        t.close(value(skin, "A"), 1)
        t.equal(string(skin, "Re"), "Yoda, I am")
        t.equal(string(skin, "Plain"), "One One0", "pairs apply in order to the previous result")
    }
}

private func runMeterGeneralTests(_ t: TestRunner) {
    t.suite("Engine: meter section variables and #CURRENTSECTION#") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [M]
        Measure=Calc
        Formula=42
        MaxValue=84

        [Style]
        Text=#CURRENTSECTION#

        [A]
        Meter=Image
        X=5
        Y=6
        W=10
        H=20
        Padding=1,2,3,4

        [B]
        Meter=String
        MeterStyle=Style

        [C]
        Meter=String
        Y=40
        Text=[A:X],[A:Y],[A:W],[A:H],[A:XW],[A:YH],[A],[M:%],[M:MaxValue]
        DynamicVariables=1

        [D]
        Meter=String
        Y=60
        Padding=5,5
        Text=abc
        """)
        skin.update()
        t.equal(frame(skin, "A"), SkinRect(x: 5, y: 6, width: 14, height: 26), "Padding adds to W and H")
        t.equal(skin.meter(named: "A")!.contentFrame, SkinRect(x: 6, y: 8, width: 10, height: 20))
        t.equal(text(skin, "C"), "5,6,14,26,19,32,[A],50,84", "meters have no value without a parameter")
        t.equal(text(skin, "B"), "B", "inherited options resolve #CURRENTSECTION# as the child")
        t.equal(skin.meter(named: "D")!.padding, SkinInsets(left: 5, top: 5, right: 0, bottom: 0),
                "missing Padding values are 0")
        t.equal(frame(skin, "D"), SkinRect(x: 0, y: 60, width: 26, height: 19))
    }

    t.suite("Engine: hidden meters and relative positions") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [A]
        Meter=Image
        X=10
        Y=10
        W=20
        H=20

        [Hidden]
        Meter=Image
        X=5R
        Y=0r
        W=30
        H=30
        Hidden=1

        [C]
        Meter=Image
        X=2R
        Y=0R
        W=5
        H=5
        """)
        skin.update()
        t.equal(frame(skin, "Hidden"), SkinRect(x: 35, y: 10, width: 0, height: 0),
                "a hidden meter has W and H of zero but keeps its position")
        t.equal(frame(skin, "C"), SkinRect(x: 37, y: 10, width: 5, height: 5), "R after a hidden meter")
        t.close(skin.width, 42)
        t.close(skin.height, 30)
        run(skin, "[!ShowMeter Hidden]")
        skin.update()
        t.equal(frame(skin, "Hidden"), SkinRect(x: 35, y: 10, width: 30, height: 30))
        t.equal(frame(skin, "C"), SkinRect(x: 67, y: 40, width: 5, height: 5))
        run(skin, "[!SetOption Hidden Hidden 1]")
        skin.update()
        t.check(skin.meter(named: "Hidden")!.hidden, "Hidden works with !SetOption")
    }

    t.suite("Engine: MeterStyle") {
        let (skin, host, _) = try makeEngineSkin(t, """
        [Variables]
        Color=1,2,3

        [StyleA]
        SolidColor=#Color#
        W=10
        H=10
        X=1

        [StyleB]
        W=20
        ToolTipText=#CURRENTSECTION#

        [One]
        Meter=Image
        MeterStyle=StyleA | StyleB
        H=5

        [Two]
        Meter=Image
        MeterStyle=StyleA|Missing|Variables
        X=5R
        """)
        skin.update()
        t.equal(frame(skin, "One"), SkinRect(x: 1, y: 0, width: 20, height: 5),
                "later styles override earlier ones; the meter's own options override both")
        t.equal(skin.meter(named: "One")!.solidColor, RGBA(r: 1, g: 2, b: 3), "style values resolve variables")
        t.equal(skin.meter(named: "One")!.toolTipText, "One")
        t.equal(frame(skin, "Two"), SkinRect(x: 26, y: 0, width: 10, height: 10),
                "relative positions refer to the previous meter, not the style")
        // Authoring mistakes that behave the same in Rainmeter are log lines, not compatibility issues.
        t.check(host.logs.contains { $0.contains("\"Missing\"") })
        t.check(host.logs.contains { $0.contains("\"Variables\"") }, "[Variables] cannot be a MeterStyle")
        t.check(!skin.issues.contains { $0.contains("MeterStyle") }, "not a compatibility issue: \(skin.issues)")
        run(skin, "[!SetOption One H \"\"]")
        skin.update()
        t.close(frame(skin, "One").height, 10, "!SetOption \"\" removes the option, the style applies again")
        run(skin, "[!SetOption One W 50]")
        skin.update()
        t.close(frame(skin, "One").width, 50)
        run(skin, "[!SetOption One W \"\"]")
        skin.update()
        t.close(frame(skin, "One").width, 20)
        run(skin, "[!SetOption One MeterStyle StyleA]")
        skin.update()
        t.close(frame(skin, "One").width, 10, "MeterStyle can be changed with !SetOption")
    }

    t.suite("Engine: meter background, bevel, matrix and OnUpdateAction") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Variables]
        AUpdates=0

        [A]
        Meter=Image
        W=1
        H=1
        SolidColor=FF000080
        SolidColor2=0,0,255
        GradientAngle=45
        BevelType=2
        BevelColor=1,1,1
        BevelColor2=2,2,2
        AntiAlias=1
        UpdateDivider=2
        OnUpdateAction=[!SetVariable AUpdates "([#AUpdates]+1)"]
        TransformationMatrix=1; 0; 0; 1; (2+3); 5

        [B]
        Meter=Image
        TransformationMatrix=1;0;0;1;5

        [C]
        Meter=Image
        TransformationMatrix=1;0;0;1;5;5;7
        """)
        skin.update()
        skin.update()
        skin.update()
        let a = skin.meter(named: "A")!
        t.equal(a.solidColor, RGBA(r: 255, g: 0, b: 0, a: 128))
        t.equal(a.solidColor2, RGBA(r: 0, g: 0, b: 255))
        t.close(a.gradientAngle, 45)
        t.equal(a.bevelType, 2)
        t.equal(a.bevelColor, RGBA(r: 1, g: 1, b: 1))
        t.equal(a.bevelColor2, RGBA(r: 2, g: 2, b: 2))
        t.check(a.antiAlias)
        t.equal(a.transformationMatrix ?? [], [1, 0, 0, 1, 5, 5])
        t.check(skin.meter(named: "B")!.transformationMatrix == nil, "exactly 6 values are required")
        t.check(skin.meter(named: "C")!.transformationMatrix == nil)
        t.equal(skin.variable("AUpdates"), "2", "meter OnUpdateAction follows its UpdateDivider")
        run(skin, "[!UpdateMeter A]")
        t.equal(skin.variable("AUpdates"), "3", "and runs on !UpdateMeter")
        t.equal(skin.meter(named: "B")!.solidColor, RGBA.clear, "SolidColor default 0,0,0,0")
    }

    t.suite("Engine: tooltips") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [M]
        Measure=Calc
        Formula=2048

        [A]
        Meter=String
        W=10
        H=10
        MeasureName=M
        ToolTipText=Value %1
        ToolTipTitle=Title
        ToolTipIcon=Info
        ToolTipType=1
        ToolTipWidth=200

        [B]
        Meter=Image
        X=20
        W=10
        H=10
        ToolTipText=Hidden
        ToolTipHidden=1
        """)
        skin.update()
        t.equal(skin.toolTipInfo(at: 5, 5), ToolTipInfo(text: "Value 2 k", title: "Title", icon: "Info", balloon: true,
                                                        maxWidth: 200),
                "%1 uses AutoScale=1 and no decimals")
        t.check(skin.toolTip(at: 5, 5)! == ("Title", "Value 2 k"))
        t.check(skin.toolTipInfo(at: 25, 5) == nil, "ToolTipHidden=1")
        run(skin, "[!HideMeter A]")
        t.check(skin.toolTipInfo(at: 5, 5) == nil, "no tooltips on hidden meters")

        let (hiddenAll, _, _) = try makeEngineSkin(t, """
        [Rainmeter]
        ToolTipHidden=1
        [A]
        Meter=Image
        W=10
        H=10
        ToolTipText=x
        """)
        hiddenAll.update()
        t.check(hiddenAll.toolTipInfo(at: 5, 5) == nil, "ToolTipHidden in [Rainmeter] hides all tooltips")
    }

    t.suite("Engine: Container") {
        let (skin, host, _) = try makeEngineSkin(t, """
        [Before]
        Meter=Image
        X=3
        Y=4
        W=10
        H=10

        [Box]
        Meter=Image
        X=20
        Y=30
        W=50
        H=40

        [C1]
        Meter=Image
        Container=Box
        X=5R
        Y=2R
        W=10
        H=10
        LeftMouseUpAction=[!SetVariable Hit C1]

        [C2]
        Meter=Image
        Container=Box
        X=0R
        Y=0r
        W=300
        H=10
        LeftMouseUpAction=[!SetVariable Hit C2]

        [After]
        Meter=Image
        X=1R
        Y=0r
        W=5
        H=5

        [Early]
        Meter=Image
        Container=Late
        X=2
        Y=3
        W=5
        H=5

        [Late]
        Meter=Image
        X=200
        Y=100
        W=10
        H=10

        [Nested]
        Meter=Image
        Container=C1
        W=5
        H=5

        [Self]
        Meter=Image
        Container=Self
        W=1
        H=1
        """)
        skin.update()
        t.equal(frame(skin, "C1"), SkinRect(x: 25, y: 32, width: 10, height: 10),
                "first content: relative to the container, R ignored")
        t.equal(frame(skin, "C2"), SkinRect(x: 35, y: 32, width: 300, height: 10), "later content: relative to each other")
        t.equal(frame(skin, "After"), SkinRect(x: 71, y: 30, width: 5, height: 5),
                "non-content meters are relative to the previous non-content meter")
        t.equal(frame(skin, "Early"), SkinRect(x: 202, y: 103, width: 5, height: 5),
                "content of a later container is positioned with the container's current frame")
        t.check(skin.meter(named: "Box")!.isContainer && skin.meter(named: "Late")!.isContainer)
        t.check(skin.meter(named: "C1")!.container === skin.meter(named: "Box"))
        t.check(skin.meter(named: "Nested")!.container == nil, "containers cannot be nested")
        t.check(skin.meter(named: "Self")!.container == nil)
        t.check(host.logs.contains { $0.contains("[Nested]") } && host.logs.contains { $0.contains("[Self]") })
        t.check(!skin.issues.contains { $0.contains("Container") }, "an authoring error, not a compatibility issue")
        t.close(skin.width, 210, "content does not enlarge the window")
        t.close(skin.height, 110)
        t.check(skin.mouseEvent(.leftUp, x: 30, y: 35))
        t.equal(skin.variable("Hit"), "C1")
        t.check(skin.mouseEvent(.leftUp, x: 50, y: 35))
        t.equal(skin.variable("Hit"), "C2")
        t.check(!skin.mouseEvent(.leftUp, x: 100, y: 35), "content outside its container does not exist")
        run(skin, "[!HideMeter Box]")
        skin.update()
        t.check(!skin.mouseEvent(.leftUp, x: 50, y: 35), "a hidden container hides its content")
    }

    t.suite("Engine: mouse actions and mouse action state bangs") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Rainmeter]
        LeftMouseUpAction=[!SetVariable Hit skin]

        [Back]
        Meter=Image
        W=100
        H=100
        LeftMouseUpAction=[!SetVariable Hit back]

        [Front]
        Meter=Image
        W=50
        H=50
        Group=G
        LeftMouseUpAction=[!SetVariable Hit front]
        MouseOverAction=[!SetVariable Over front]
        MouseLeaveAction=[!SetVariable Over none]

        [Empty]
        Meter=Image
        X=60
        Y=60
        W=10
        H=10
        LeftMouseUpAction=[]
        """)
        skin.update()
        func click(_ x: Double, _ y: Double) -> String? {
            skin.setVariable("Hit", "-")
            skin.mouseEvent(.leftUp, x: x, y: y)
            return skin.variable("Hit")
        }
        t.equal(click(10, 10), "front", "the topmost meter with the action")
        t.equal(click(80, 10), "back")
        t.equal(click(65, 65), "-", "an empty action [] still catches the click")
        t.equal(click(150, 150), "skin", "[Rainmeter] actions when no meter has one")
        run(skin, "[!DisableMouseAction Front LeftMouseUpAction]")
        t.equal(click(10, 10), "-", "disabled: caught, no action")
        t.check(skin.hasAction(.leftUp, x: 10, y: 10))
        run(skin, "[!ClearMouseAction Front \"LeftMouseUpAction|MouseOverAction\"]")
        t.equal(click(10, 10), "back", "cleared: passes through")
        run(skin, "[!ToggleMouseAction Front LeftMouseUpAction]")
        t.equal(click(10, 10), "front")
        run(skin, "[!ToggleMouseAction Front LeftMouseUpAction]")
        t.equal(click(10, 10), "back", "toggle returns to the last non-enabled state (cleared)")
        run(skin, "[!EnableMouseAction Front *]")
        t.equal(click(10, 10), "front")
        run(skin, "[!DisableMouseActionGroup LeftMouseUpAction g]")
        t.equal(click(10, 10), "-")
        run(skin, "[!EnableMouseActionGroup * G][!ClearMouseAction Rainmeter LeftMouseUpAction]")
        t.equal(click(150, 150), "-", "[Rainmeter] can be targeted")
        t.check(!skin.hasAction(.leftUp, x: 150, y: 150))
        run(skin, "[!EnableMouseAction Rainmeter LeftMouseUpAction][!DisableMouseAction * LeftMouseUpAction]")
        t.equal(click(80, 10), "-", "* targets every meter")
        t.equal(click(150, 150), "skin")

        skin.mouseMoved(x: 10, y: 10)
        t.equal(skin.variable("Over"), "front")
        skin.mouseMoved(x: 80, y: 80)
        t.equal(skin.variable("Over"), "none")
        run(skin, "[!DisableMouseAction Front MouseOverAction]")
        skin.setVariable("Over", "-")
        skin.mouseMoved(x: 10, y: 10)
        t.equal(skin.variable("Over"), "-", "disabled hover action does not run")
        skin.mouseExited()
        t.equal(skin.variable("Over"), "none", "the leave action still runs")
    }

    t.suite("Engine: mouse cursor") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [A]
        Meter=Image
        W=10
        H=10
        LeftMouseUpAction=[!Log a]

        [Cover]
        Meter=Image
        W=5
        H=5
        MouseActionCursor=0

        [B]
        Meter=Image
        X=20
        W=10
        H=10
        MouseScrollUpAction=[!Log b]
        MouseActionCursorName=Custom.cur

        [Hover]
        Meter=Image
        X=40
        W=10
        H=10
        MouseOverAction=[!Log h]
        """)
        skin.update()
        t.equal(skin.mouseCursorName(at: 8, 8), "HAND")
        t.equal(skin.mouseCursorName(at: 2, 2), nil, "MouseActionCursor=0 on the meter on top")
        t.equal(skin.mouseCursorName(at: 25, 5), "Custom.cur")
        t.equal(skin.mouseCursorName(at: 45, 5), nil, "hover actions do not show a pointer")
    }

    t.suite("Engine: built-in variables") {
        let host = EnvironmentHost()
        let (skin, _, skins) = try makeEngineSkin(t, """
        [T]
        Meter=String
        Text=#CURRENTCONFIGX#,#CURRENTCONFIGY#,#CURRENTCONFIGWIDTH#,#CURRENTCONFIGHEIGHT#,#CURRENTCONFIGZPOS#|#SCREENAREAWIDTH#,#WORKAREAY#,#PWORKAREAY#,#PSCREENAREAWIDTH#,#SCREENAREAX@2#,#WORKAREAHEIGHT@2#,#VSCREENAREAWIDTH#,#VSCREENAREAHEIGHT#|#PROGRAMDRIVE#|#CONFIGEDITOR#|#CURRENTSECTION#|#SCREENAREAWIDTH@9#
        DynamicVariables=1

        [Static]
        Meter=String
        Y=20
        Text=#CURRENTCONFIGX#
        """, host: host)
        skin.update()
        t.equal(text(skin, "T"), "100,200,300,50,1|1280,0,25,1920,1920,770,3200,1080|/|/usr/bin/vi|T|#SCREENAREAWIDTH@9#")
        host.env.windowFrame.x = 150
        host.env.screens[1].area.width = 1920
        skin.update()
        t.check(text(skin, "T").hasPrefix("150,"), "dynamic built-ins follow the window")
        t.check(text(skin, "T").contains("|1920,0,25,1920,1920,770,3840,1080|"), "monitor variables are dynamic")
        t.equal(text(skin, "Static"), "100", "without DynamicVariables the load-time value stays")
        t.equal(skin.variable("CURRENTCONFIG"), "Root\\Sub")
        t.equal(skin.variable("ROOTCONFIG"), "Root")
        t.equal(skin.variable("CURRENTFILE"), "Skin.ini")
        t.equal(skin.variable("SKINSPATH"), skins.path + "/")
        t.check(skin.variable("@")?.hasSuffix("/Root/@Resources/") == true)
        t.check(skin.variable("ROOTCONFIGPATH")?.hasSuffix("/Root/") == true)
        t.check(skin.variable("CURRENTPATH")?.hasSuffix("/Root/Sub/") == true)
        run(skin, "[!SetVariable CURRENTCONFIG Hacked][!SetVariable CurrentConfigX 5]")
        t.equal(skin.variable("CURRENTCONFIG"), "Root\\Sub", "built-in variables cannot be changed by actions")
        t.equal(skin.variable("CURRENTCONFIGX"), "150")
        for name in BuiltInVariables.names {
            t.check(skin.variable(name) != nil, "#\(name)# is supplied by the engine")
        }
        for name in BuiltInVariables.monitorIndexedNames {
            t.check(skin.variable(name + "@2") != nil, "#\(name)@2# is supplied by the engine")
        }
    }
}

private func runBangTests(_ t: TestRunner) {
    t.suite("Engine: bang Config argument") {
        let (skin, host, _) = try makeEngineSkin(t, """
        [M]
        Meter=Image
        W=1
        H=1
        """)
        run(skin, "[!SetVariable X 1 \"Root\\Sub\"]")
        t.equal(skin.variable("X"), "1", "own config: performed here")
        run(skin, "[!SetVariable X 2 \"root/sub/\"]")
        t.equal(skin.variable("X"), "2", "config names are case-insensitive; trailing separators are ignored")
        run(skin, "[!SetVariable X 3 \"Other\\Skin\"]")
        t.equal(skin.variable("X"), "2")
        t.equal(host.forwarded.last?.1 ?? "", "Other\\Skin")
        t.equal(host.forwarded.last?.0 ?? Bang(name: ""), Bang(name: "setvariable", args: ["X", "3"]))
        run(skin, "[!SetVariable X 4 *]")
        t.equal(skin.variable("X"), "4", "* performs the bang here too")
        t.equal(host.forwarded.last?.1 ?? "", "*")
        run(skin, "[!HideMeter M Other][!Redraw Other][!UpdateMeasureGroup G Other][!CommandMeasure A \"B C\" Other]")
        t.equal(host.forwarded.suffix(4).map { $0.0 }, [Bang(name: "hidemeter", args: ["M"]),
                                                        Bang(name: "redraw", args: []),
                                                        Bang(name: "updatemeasuregroup", args: ["G"]),
                                                        Bang(name: "commandmeasure", args: ["A", "B C"])])
        t.check(!skin.meter(named: "M")!.hidden)
        run(skin, "[!ActivateConfig \"Other\\Skin\" \"A.ini\"][!Move 1 2 Other]")
        t.equal(host.handled.suffix(2).map { $0 }, [Bang(name: "activateconfig", args: ["Other\\Skin", "A.ini"]),
                                                     Bang(name: "move", args: ["1", "2", "Other"])],
                "host bangs keep their arguments")
        run(skin, "[!UnknownBang][!SetWallpaper x.png]")
        t.check(!skin.issues.contains { $0.contains("unknownbang") }, "a typo, not a compatibility issue")
        t.check(host.logs.contains { $0.contains("Unknown bang: !unknownbang") })
        t.check(!skin.issues.contains { $0.contains("setwallpaper") }, "handled host bangs are not issues")
    }

    t.suite("Engine: !SetOption and !SetOptionGroup") {
        let (skin, host, _) = try makeEngineSkin(t, """
        [M]
        Measure=Calc
        Formula=21

        [T]
        Meter=String
        Group=Texts
        Text=Old

        [U]
        Meter=String
        Group=texts | Other
        Y=20
        Text=Old
        """)
        skin.update()
        run(skin, "[!SetOption T Text New]")
        t.equal(text(skin, "T"), "Old", "applied on the next update")
        skin.update()
        t.equal(text(skin, "T"), "New")
        run(skin, "[!SetOptionGroup TEXTS Text Grouped]")
        skin.update()
        t.equal(text(skin, "T"), "Grouped")
        t.equal(text(skin, "U"), "Grouped")
        run(skin, "[!SetOption T W \"(M * 2)\"][!SetOption T Text \"(1+2)\"]")
        t.equal(skin.meter(named: "T")?.rawOption("W"), "42", "measures in a formula are resolved by the bang")
        skin.update()
        t.equal(text(skin, "T"), "(1+2)", "other values are stored as written")
        t.close(frame(skin, "T").width, 42)
        run(skin, "[!SetOption T Text \"\"]")
        skin.update()
        t.equal(text(skin, "T"), "", "an empty value removes the option")
        run(skin, "[!SetOption Missing Text X][!SetOption T Meter Image]")
        t.check(host.logs.contains { $0.contains("[Missing] not found") })
        t.check(skin.meter(named: "T") is StringMeter)
        run(skin, "[!SetOption M Formula 5]")
        skin.update()
        t.close(value(skin, "M"), 5, "!SetOption works on measures")
    }

    t.suite("Engine: !SetVariable values") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [M]
        Measure=Calc
        Formula=21
        """)
        skin.update()
        run(skin, "[!SetVariable A \"(2*3)\"][!SetVariable B \"(M/4)\"][!SetVariable C \"(1/3)\"]")
        run(skin, "[!SetVariable D \"not (a formula\"][!SetVariable E \"(Nope+1)\"][!SetVariable F \" (1+1) \"]")
        run(skin, "[!SetVariable G \"\"\"(1+1)\"\"\"][!SetVariable H \"[M]\"][!SetVariable I \"[*M*]\"]")
        t.equal(skin.variable("A"), "6")
        t.equal(skin.variable("B"), "5.25", "measure names in bang formulas are resolved")
        t.equal(skin.variable("C"), "0.3333333333")
        t.equal(skin.variable("D"), "not (a formula")
        t.equal(skin.variable("E"), "(Nope+1)", "a formula that fails is kept as text")
        t.equal(skin.variable("F"), "2")
        t.equal(skin.variable("H"), "21", "section variables in bangs are always resolved")
        t.equal(skin.variable("I"), "[M]")
        t.equal(skin.variable("G"), "(1+1)", "magic quotes keep the text literal, formulas included")
    }

    t.suite("Engine: !WriteKeyValue") {
        let (skin, host, skins) = try makeEngineSkin(t, """
        [Variables]
        A=0

        [M]
        Measure=Calc
        Formula=7
        """, files: ["Root/Sub/Other.inc": "[Variables]\nA=1\n", "Root/@Resources/Vars.inc": "[Variables]\n"])
        skin.update()
        run(skin, "[!WriteKeyValue Variables A \"(2+M)\" \"Other.inc\"]")
        run(skin, "[!WriteKeyValue Variables B Hello \"#@#Vars.inc\"]")
        run(skin, "[!WriteKeyValue Variables C 1]")
        run(skin, "[!WriteKeyValue Variables D 1 \"/Users/Shared/deskset-not-allowed.inc\"]")
        run(skin, "[!WriteKeyValue Variables E 1 \"Missing.inc\"]")
        let other = try String(contentsOf: skins.appendingPathComponent("Root/Sub/Other.inc"), encoding: .utf8)
        let vars = try String(contentsOf: skins.appendingPathComponent("Root/@Resources/Vars.inc"), encoding: .utf8)
        let own = try String(contentsOf: skins.appendingPathComponent("Root/Sub/Skin.ini"), encoding: .utf8)
        t.check(other.contains("A=9"), "relative paths are relative to the skin folder; formulas are evaluated")
        t.check(vars.contains("B=Hello"))
        t.check(own.contains("C=1"), "without FilePath the skin file itself is written")
        t.check(host.logs.contains { $0.contains("not under #SKINSPATH#") })
        t.check(!FileManager.default.fileExists(atPath: "/Users/Shared/deskset-not-allowed.inc"))
        t.check(host.logs.contains { $0.contains("file not found") }, "the file must exist")
        t.equal(skin.variable("A"), "0", "the running skin is not changed")
    }

    t.suite("Engine: update, redraw, meter and measure bangs") {
        let (skin, host, _) = try makeEngineSkin(t, """
        [Rainmeter]
        Update=-1

        [A]
        Measure=Calc
        Formula=A + 1
        Group=G

        [B]
        Measure=Calc
        Formula=B + 1
        UpdateDivider=-1

        [T]
        Meter=String
        MeasureName=A
        UpdateDivider=-1
        Group=MG

        [U]
        Meter=String
        Y=20
        Group=MG
        Text=u
        """)
        skin.update()
        t.equal(host.redraws, 1)
        run(skin, "[!UpdateMeasure *]")
        t.close(value(skin, "A"), 2)
        t.close(value(skin, "B"), 2)
        run(skin, "[!UpdateMeasureGroup g]")
        t.close(value(skin, "A"), 3)
        t.equal(text(skin, "T"), "1")
        run(skin, "[!UpdateMeterGroup MG]")
        t.equal(text(skin, "T"), "3")
        run(skin, "[!Update]")
        t.close(value(skin, "A"), 4)
        t.close(value(skin, "B"), 2, "!Update does not override UpdateDivider")
        t.equal(text(skin, "T"), "3")
        run(skin, "[!Redraw]")
        t.equal(host.redraws, 3)
        run(skin, "[!HideMeterGroup mg]")
        t.check(skin.meter(named: "T")!.hidden && skin.meter(named: "U")!.hidden)
        run(skin, "[!ToggleMeterGroup MG][!ToggleMeter U]")
        t.check(!skin.meter(named: "T")!.hidden && skin.meter(named: "U")!.hidden)
        run(skin, "[!ShowMeter U][!DisableMeasureGroup G]")
        t.check(!skin.meter(named: "U")!.hidden && skin.measure(named: "A")!.disabled)
        run(skin, "[!EnableMeasureGroup G][!PauseMeasureGroup G]")
        t.check(!skin.measure(named: "A")!.disabled && skin.measure(named: "A")!.paused)
        run(skin, "[!TogglePauseMeasureGroup G]")
        t.check(!skin.measure(named: "A")!.paused)
        run(skin, "[!ToggleMeasureGroup G][!UnpauseMeasureGroup G]")
        t.check(skin.measure(named: "A")!.disabled)
    }

    t.suite("Engine: !CommandMeasure, !PluginBang and !Log") {
        let (skin, host, _) = try makeEngineSkin(t, """
        [L]
        Measure=Loop
        StartValue=1
        EndValue=10

        [C]
        Measure=Calc
        Formula=1
        """)
        skin.update()
        skin.update()
        skin.update()
        run(skin, "[!CommandMeasure L Reset]")
        skin.update()
        t.close(value(skin, "L"), 1)
        skin.update()
        run(skin, "[!PluginBang \"L Reset\"]")
        skin.update()
        t.close(value(skin, "L"), 1, "deprecated !PluginBang \"Measure Arguments\"")
        run(skin, "[!CommandMeasure C Something][!CommandMeasure Missing Reset]")
        t.check(host.logs.contains { $0.contains("not supported by calc") })
        t.check(host.logs.contains { $0.contains("[Missing] not found") })
        run(skin, "[!Log hi][!Log \"a b\" Warning][!Log x debug][!Log y ERROR]")
        t.check(host.logs.contains("Notice: hi") && host.logs.contains("Warning: a b"))
        t.check(host.logs.contains("Debug: x") && host.logs.contains("Error: y"))
    }

    t.suite("Engine: !Delay") {
        let (skin, _, _) = try makeEngineSkin(t, "[M]\nMeter=Image\n")
        run(skin, "[!SetVariable A 1][!Delay 0][!SetVariable B 1][!Delay 20][!SetVariable C 1]")
        t.equal(skin.variable("A"), "1")
        t.equal(skin.variable("B"), nil, "the rest of the action waits")
        // Two main-queue hops (16 ms, then 20 ms); a busy CI runner may run them late.
        t.check(spinUntil { skin.variable("C") == "1" }, "the delayed rest of the action ran")
        t.equal(skin.variable("B"), "1")
        t.equal(skin.variable("C"), "1")
        run(skin, "[!Delay 30][!SetVariable D 1]")
        skin.close()
        // The same delay, started later in another skin, has run: D's would have run by then had close() not
        // cancelled it.
        let (witness, _, _) = try makeEngineSkin(t, "[M]\nMeter=Image\n")
        run(witness, "[!Delay 30][!SetVariable Done 1]")
        t.check(spinUntil { witness.variable("Done") == "1" }, "the other skin's delay ran")
        t.equal(skin.variable("D"), nil, "unloading cancels pending delays")
    }

    t.suite("Engine: self-triggering actions terminate") {
        let (skin, host, _) = try makeEngineSkin(t, """
        [Rainmeter]
        OnUpdateAction=[!Update]

        [Self]
        Measure=Calc
        Formula=Self + 1
        IfCondition=Self > 0
        IfTrueAction=[!UpdateMeasure Self]
        IfConditionMode=1

        [Meter]
        Meter=Image
        OnUpdateAction=[!UpdateMeter *]
        """)
        skin.update()
        t.check(skin.updateCount >= 1)
        t.check(value(skin, "Self") < 10_000)
        t.check(host.logs.contains { $0.contains("nested too deeply") || $0.contains("!Update inside an update") })
    }
}

private func runBuiltinMeasureTests(_ t: TestRunner) {
    t.suite("Engine: Calc measure") {
        let (skin, host, _) = try makeEngineSkin(t, """
        [Rand]
        Measure=Calc
        Formula=Random
        LowBound=5
        HighBound=7
        UpdateRandom=1
        UniqueRandom=1

        [Once]
        Measure=Calc
        Formula=Random
        LowBound=1
        HighBound=1000000

        [Default]
        Measure=Calc

        [Count]
        Measure=Calc
        Formula=Counter

        [Ref]
        Measure=Calc
        Formula=Default + Count * 2

        [Bad]
        Measure=Calc
        Formula=Nope + 1

        [Big]
        Measure=Calc
        Formula=Random
        LowBound=(10**12)
        HighBound=(10**13)
        """)
        var seen: [Double] = []
        var once: Set<Double> = []
        for _ in 0..<6 {
            skin.update()
            seen.append(value(skin, "Rand"))
            once.insert(value(skin, "Once"))
        }
        t.equal(Set(seen.prefix(3)), [5, 6, 7], "UniqueRandom: no repeat before every value was used")
        t.equal(Set(seen.suffix(3)), [5, 6, 7])
        t.equal(once.count, 1, "without UpdateRandom the random number is generated once")
        t.close(value(skin, "Default"), 0, "Formula default 0")
        t.close(value(skin, "Count"), 5, "Counter counts completed updates")
        t.close(value(skin, "Ref"), 10)
        t.close(value(skin, "Bad"), 0)
        t.check(host.logs.contains { $0.contains("[Bad] cannot evaluate Formula") })
        t.close(value(skin, "Big"), 2_147_483_647, "bounds are 32-bit integers")
    }

    t.suite("Engine: Uptime, CPU, Process") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [U]
        Measure=Uptime
        SecondsValue=3725
        Format="%3!i!h %2!02i!m %1!02i!s"

        [NoDays]
        Measure=Uptime
        Format=%3!i!:%2!02i!

        [NoAdd]
        Measure=Uptime
        Format=%3!i!:%2!02i!
        AddDaysToHours=0

        [Core]
        Measure=CPU
        Processor=2

        [Proc]
        Measure=Plugin
        Plugin=Plugins\\Process.dll
        ProcessName=Finder.exe

        [Gone]
        Measure=Process
        ProcessName=Nothing.exe
        """)
        skin.update()
        t.close(value(skin, "U"), 3725)
        t.equal(string(skin, "U"), "1h 02m 05s")
        t.equal(string(skin, "NoDays"), "25:01", "AddDaysToHours adds days when %4 is not used")
        t.equal(string(skin, "NoAdd"), "1:01")
        t.close(value(skin, "Core"), 2)
        t.close(skin.measure(named: "Core")!.maxValue, 100)
        t.close(value(skin, "Proc"), 1, "Plugin=Process still works")
        t.close(value(skin, "Gone"), -1)
        t.close(skin.measure(named: "Gone")!.minValue, -1)
    }

    t.suite("Engine: memory measures") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Phys]
        Measure=PhysicalMemory
        MaxValue=5

        [PhysFree]
        Measure=PhysicalMemory
        InvertMeasure=1

        [PhysTotal]
        Measure=PhysicalMemory
        Total=1

        [Swap]
        Measure=SwapMemory

        [Virtual]
        Measure=Memory
        """)
        skin.update()
        t.close(value(skin, "Phys"), 8 * gib)
        t.close(skin.measure(named: "Phys")!.maxValue, 16 * gib, "MaxValue cannot be set on memory measures")
        t.close(value(skin, "PhysFree"), 8 * gib, "InvertMeasure gives the free memory")
        t.close(value(skin, "PhysTotal"), 16 * gib)
        t.close(value(skin, "Swap"), 9 * gib, "SwapMemory = RAM + swap")
        t.close(skin.measure(named: "Swap")!.maxValue, 18 * gib)
        t.close(skin.measure(named: "Virtual")!.maxValue, 34 * gib, "Memory = RAM + RAM + swap")
    }

    t.suite("Engine: Net measures") {
        let system = EngineTestSystem()
        let (skin, host, _) = try makeEngineSkin(t, """
        [In]
        Measure=NetIn

        [Out]
        Measure=NetOut
        Interface=0

        [Total]
        Measure=NetTotal
        Interface=en0
        UseBits=1

        [Cum]
        Measure=NetIn
        Cumulative=1
        Interface=2

        [Max]
        Measure=NetIn
        Interface=Wi-Fi
        MaxValue=8000

        [Speed]
        Measure=NetOut
        NetOutSpeed=500
        """, system: system)
        var now = 100.0
        skin.clock = { now }
        skin.update()
        t.close(value(skin, "In"), 0, "the first sample gives 0")
        system.counters["en0"] = NetworkCounters(received: 3000, sent: 1500)
        system.counters["en1"] = NetworkCounters(received: 110, sent: 55)
        now = 102
        skin.update()
        t.close(value(skin, "In"), 50, "Interface=Best, bytes per second")
        t.close(value(skin, "Out"), 525, "Interface=0: all interfaces")
        t.close(value(skin, "Total"), 12000, "UseBits=1")
        t.close(value(skin, "Cum"), 110, "Cumulative, Interface=2")
        t.close(value(skin, "Max"), 50, "an unknown interface name falls back to Best")
        t.close(skin.measure(named: "Max")!.maxValue, 1000, "MaxValue is written in bits")
        t.close(skin.measure(named: "Speed")!.maxValue, 500, "NetOutSpeed is in bytes")
        t.close(value(skin, "Speed"), 25)
        t.close(skin.measure(named: "In")!.maxValue, 50, "without MaxValue the range tracks the values")
        t.check(system.requestedInterfaces.contains("en1") && system.requestedInterfaces.contains(nil)
                && system.requestedInterfaces.contains("en0"))
        t.check(host.logs.contains { $0.contains("Interface=Wi-Fi") })
        system.counters["en1"] = NetworkCounters(received: 5, sent: 55)
        now = 103
        skin.update()
        t.close(value(skin, "In"), 0, "a counter going backwards gives 0")
    }

    t.suite("Engine: FreeDiskSpace measure") {
        t.equal(FreeDiskSpaceMeasure.volumePath("C:"), "/")
        t.equal(FreeDiskSpaceMeasure.volumePath("d:\\"), "/")
        t.equal(FreeDiskSpaceMeasure.volumePath(""), "/")
        t.equal(FreeDiskSpaceMeasure.volumePath("/Volumes/Data"), "/Volumes/Data")
        t.equal(FreeDiskSpaceMeasure.volumePath("Data"), "/Volumes/Data")
        t.equal(FreeDiskSpaceMeasure.volumePath("\"C:\\\""), "/")

        let system = EngineTestSystem()
        let ini = """
        [Free]
        Measure=FreeDiskSpace

        [Used]
        Measure=FreeDiskSpace
        Drive=C:
        InvertMeasure=1
        MaxValue=10

        [Total]
        Measure=FreeDiskSpace
        Total=1

        [Label]
        Measure=FreeDiskSpace
        Label=1

        [Type]
        Measure=FreeDiskSpace
        Type=1

        [Removable]
        Measure=FreeDiskSpace
        IgnoreRemovable=0
        """
        let (skin, _, _) = try makeEngineSkin(t, ini, system: system)
        skin.update()
        t.close(value(skin, "Free"), 250)
        t.close(skin.measure(named: "Free")!.maxValue, 1000)
        t.close(value(skin, "Used"), 750)
        t.close(skin.measure(named: "Used")!.maxValue, 1000, "MaxValue cannot be set")
        t.close(value(skin, "Total"), 1000)
        t.equal(string(skin, "Label"), "Macintosh HD")
        t.close(value(skin, "Label"), 250, "Label does not change the number")
        t.equal(string(skin, "Type"), "Fixed")
        t.close(value(skin, "Type"), 4)

        system.volume = VolumeInfo(label: "USB", kind: .removable)
        skin.update()
        t.close(value(skin, "Free"), 0, "removable drives are ignored by default")
        t.close(value(skin, "Removable"), 250)
        t.equal(string(skin, "Type"), "Removable")
        t.close(value(skin, "Type"), 3)
        system.volume = VolumeInfo(label: "Share", kind: .network)
        skin.update()
        t.close(value(skin, "Type"), 5)
        system.volume = nil
        skin.update()
        t.equal(string(skin, "Type"), "Removed")
        t.close(value(skin, "Type"), 1)
    }

    t.suite("Engine: Loop measure") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [A]
        Measure=Loop
        StartValue=0
        EndValue=10
        Increment=3

        [B]
        Measure=Loop
        StartValue=10
        EndValue=0
        Increment=-5
        LoopCount=1

        [C]
        Measure=Loop
        MinValue=-5
        MaxValue=500
        AverageSize=5

        [D]
        Measure=Loop
        StartValue=1.9
        EndValue=3.7

        [E]
        Measure=Loop
        StartValue=0
        EndValue=4
        InvertMeasure=1
        """)
        var a: [Double] = [], b: [Double] = [], c: [Double] = [], d: [Double] = [], e: [Double] = []
        for _ in 0..<7 {
            skin.update()
            a.append(value(skin, "A"))
            b.append(value(skin, "B"))
            c.append(value(skin, "C"))
            d.append(value(skin, "D"))
            e.append(value(skin, "E"))
        }
        t.equal(a, [0, 3, 6, 9, 10, 0, 3], "the last step is shortened to end at EndValue")
        t.equal(b, [10, 5, 0, 0, 0, 0, 0], "LoopCount reached: stays at EndValue")
        t.equal(c, [1, 2, 3, 4, 5, 6, 7], "defaults 1…100; AverageSize ignored")
        t.close(skin.measure(named: "C")!.minValue, 1, "MinValue/MaxValue cannot be set")
        t.close(skin.measure(named: "C")!.maxValue, 100)
        t.equal(d, [1, 2, 3, 1, 2, 3, 1], "values are truncated to whole numbers")
        t.equal(e, [4, 3, 2, 1, 0, 4, 3], "InvertMeasure reverses the loop")
        run(skin, "[!SetOption A EndValue 20]")
        skin.update()
        t.close(value(skin, "A"), 0, "changing an option resets the loop")
        run(skin, "[!SetOption E InvertMeasure 0]")
        skin.update()
        t.close(value(skin, "E"), 0, "changing InvertMeasure resets the loop")
    }

    t.suite("Engine: SysInfo measure") {
        let host = EnvironmentHost()
        let (skin, _, _) = try makeEngineSkin(t, """
        [N]
        Measure=SysInfo
        SysInfoType=NUM_MONITORS

        [S]
        Measure=SysInfo
        SysInfoType=screen_size

        [W]
        Measure=SysInfo
        SysInfoType=SCREEN_WIDTH
        SysInfoData=2

        [VW]
        Measure=SysInfo
        SysInfoType=VIRTUAL_SCREEN_WIDTH

        [VL]
        Measure=SysInfo
        SysInfoType=VIRTUAL_SCREEN_LEFT
        SysInfoData=2

        [WA]
        Measure=SysInfo
        SysInfoType=WORK_AREA_HEIGHT

        [WAS]
        Measure=SysInfo
        SysInfoType=WORK_AREA

        [Bits]
        Measure=Plugin
        Plugin=SysInfo.dll
        SysInfoType=OS_BITS

        [Page]
        Measure=SysInfo
        SysInfoType=PAGESIZE

        [User]
        Measure=SysInfo
        SysInfoType=USER_NAME

        [OS]
        Measure=SysInfo
        SysInfoType=OS_VERSION

        [Sid]
        Measure=SysInfo
        SysInfoType=USER_SID

        [Typo]
        Measure=SysInfo
        SysInfoType=USER_NAMES
        """, host: host)
        skin.update()
        t.close(value(skin, "N"), 2)
        t.equal(string(skin, "S"), "1920 x 1080")
        t.close(value(skin, "W"), 1280, "SysInfoData selects the monitor")
        t.close(value(skin, "VW"), 3200)
        t.close(value(skin, "VL"), 1920)
        t.close(value(skin, "WA"), 1055)
        t.equal(string(skin, "WAS"), "1920 x 1055")
        t.close(value(skin, "Bits"), 64, "Plugin=SysInfo still works")
        t.equal(string(skin, "Bits"), "64", "number types have their number as string")
        t.check(value(skin, "Page") >= 4096)
        t.equal(string(skin, "User"), "tester", "answered by the system data source")
        t.check(string(skin, "OS").hasPrefix("macOS "))
        t.equal(string(skin, "Sid"), "")
        t.check(skin.issues.contains("SysInfoType=USER_SID is not supported on macOS"))
        t.check(skin.measure(named: "Sid")?.valueUnavailable == true, "documented, but no Mac answer")
        t.check(skin.measure(named: "User")?.valueUnavailable == false)
        // A type the manual does not list is the skin's own mistake: logged, not a compatibility note.
        t.equal(string(skin, "Typo"), "")
        t.check(!skin.issues.contains { $0.contains("USER_NAMES") }, "\(skin.issues)")
        t.check(host.logs.contains { $0.contains("SysInfoType=USER_NAMES is not a SysInfo type") }, "\(host.logs)")
        t.check(skin.measure(named: "Typo")?.valueUnavailable == false)

        func tz(_ type: String, _ zone: String, _ date: String) -> Double? {
            let parser = ISO8601DateFormatter()
            guard let z = TimeZone(identifier: zone), let d = parser.date(from: date) else { return nil }
            return SysInfoMeasure.timeZoneValue(type, zone: z, at: d)?.number
        }
        t.equal(tz("TIMEZONE_ISDST", "America/New_York", "2025-01-15T12:00:00Z"), 0)
        t.equal(tz("TIMEZONE_ISDST", "America/New_York", "2025-07-15T12:00:00Z"), 1)
        t.equal(tz("TIMEZONE_BIAS", "America/New_York", "2025-07-15T12:00:00Z"), 300, "UTC = local standard + bias")
        t.equal(tz("TIMEZONE_DAYLIGHT_BIAS", "America/New_York", "2025-01-15T12:00:00Z"), -60)
        t.equal(tz("TIMEZONE_DAYLIGHT_BIAS", "America/New_York", "2025-07-15T12:00:00Z"), -60)
        t.equal(tz("TIMEZONE_STANDARD_BIAS", "America/New_York", "2025-07-15T12:00:00Z"), 0)
        t.equal(tz("TIMEZONE_ISDST", "Asia/Shanghai", "2025-07-15T12:00:00Z"), -1, "no daylight saving time")
        t.equal(tz("TIMEZONE_BIAS", "Asia/Shanghai", "2025-07-15T12:00:00Z"), -480)
        t.equal(tz("TIMEZONE_DAYLIGHT_BIAS", "Asia/Shanghai", "2025-07-15T12:00:00Z"), 0)
    }

    t.suite("Engine: PowerPlugin measure") {
        let system = EngineTestSystem()
        let ini = """
        [AC]
        Measure=Plugin
        Plugin=PowerPlugin.dll
        PowerState=ACLine
        [Status]
        Measure=Plugin
        Plugin=PowerPlugin
        PowerState=STATUS
        [Status2]
        Measure=Plugin
        Plugin=PowerPlugin
        PowerState=Status2
        [Life]
        Measure=Plugin
        Plugin=PowerPlugin
        PowerState=Lifetime
        [Percent]
        Measure=Plugin
        Plugin=PowerPlugin
        [MHz]
        Measure=Plugin
        Plugin=PowerPlugin
        PowerState=MHz
        [Hz]
        Measure=Plugin
        Plugin=PowerPlugin
        PowerState=Hz
        """
        let (skin, _, _) = try makeEngineSkin(t, ini, system: system)
        skin.update()
        t.close(value(skin, "AC"), 0)
        t.close(value(skin, "Status"), 4)
        t.close(value(skin, "Status2"), 1, "BatteryFlag: high")
        t.close(value(skin, "Life"), 5400)
        t.equal(string(skin, "Life"), "01:30")
        t.close(value(skin, "Percent"), 80)
        t.close(skin.measure(named: "Percent")!.maxValue, 100)
        t.close(value(skin, "MHz"), 3200)
        t.close(value(skin, "Hz"), 3.2e9)
        system.batteryStatus = BatteryStatus(percent: 20, isCharging: true, isPluggedIn: true)
        skin.update()
        t.close(value(skin, "AC"), 1)
        t.close(value(skin, "Status"), 1)
        t.close(value(skin, "Status2"), 10, "BatteryFlag: low + charging")
        t.close(value(skin, "Life"), -1)
        t.equal(string(skin, "Life"), "Unknown")
        system.batteryStatus = nil
        system.frequency = nil
        skin.update()
        t.close(value(skin, "AC"), 1)
        t.close(value(skin, "Status"), 0)
        t.close(value(skin, "Status2"), 128)
        t.close(value(skin, "Percent"), 100)
        t.close(value(skin, "MHz"), 0)
    }

    t.suite("Engine: Windows-only measures degrade gracefully") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Reg]
        Measure=Registry
        RegKey=Software\\X
        RegValue=Y

        [Recycle]
        Measure=Plugin
        Plugin=Plugins\\RecycleManager.dll

        [Audio]
        Measure=Plugin
        Plugin=Win7AudioPlugin

        [Web]
        Measure=Plugin
        Plugin=WebParser

        [Show]
        Meter=String
        MeasureName=Reg
        Text=[%1]
        """)
        skin.update()
        skin.update()
        t.close(value(skin, "Reg"), 0)
        t.equal(string(skin, "Reg"), "")
        t.equal(text(skin, "Show"), "[]")
        t.check(skin.issues.contains { $0.contains("HKCU\\Software\\X\\Y") && $0.contains("does not exist") },
                "\(skin.issues)")
        // RecycleManager is implemented by CorePlugins (the Mac Trash).
        t.check(!(skin.measure(named: "Recycle") is UnsupportedMeasure), "RecycleManager is a registered plugin")
        t.check(skin.issues.contains { $0.contains("Win7AudioPlugin") })
        t.check(skin.measure(named: "Web") is WebParserMeasure, "Plugin=WebParser is the WebParser measure")
        run(skin, "[!CommandMeasure Reg Anything]")
    }
}

// MARK: - Adversarial review regressions

/// FakeHost that unloads the skin when it handles `!Refresh` / `!DeactivateConfig` (like the app does).
private final class UnloadingHost: FakeHost {
    override func skin(_ skin: Skin, handle bang: Bang) -> Bool {
        if bang.name == "refresh" || bang.name == "deactivateconfig" { skin.close() }
        return super.skin(skin, handle: bang)
    }
}

private func runEngineReviewTests(_ t: TestRunner) {
    t.suite("Engine review: action fan-out is bounded") {
        // With N meters each running [!UpdateMeter *] the work grew like N^16 (3 meters: tens of millions of
        // meter updates, i.e. a hang). The burst budget stops it.
        var ini = ""
        for i in 0..<4 { ini += "[M\(i)]\nMeter=Image\nW=1\nH=1\nOnUpdateAction=[!UpdateMeter *]\n" }
        ini += """
        [A]
        Measure=Calc
        Formula=1
        IfCondition=A = 1
        IfTrueAction=[!UpdateMeasure *]
        IfConditionMode=1
        [B]
        Measure=Calc
        Formula=1
        IfCondition=B = 1
        IfTrueAction=[!UpdateMeasure *]
        IfConditionMode=1
        [C]
        Measure=Calc
        Formula=1
        IfCondition=C = 1
        IfTrueAction=[!UpdateMeasureGroup G]
        IfConditionMode=1
        Group=G
        """
        let (skin, host, _) = try makeEngineSkin(t, ini)
        let start = Date()
        skin.update()
        skin.update()
        run(skin, "[!UpdateMeter *]")
        t.check(Date().timeIntervalSince(start) < 30, "terminates")
        t.equal(skin.updateCount, 2)
        t.equal(host.logs.filter { $0.contains("keep triggering each other") }.count, 1, "logged once")
        t.check(host.redraws >= 2, "the update still completes and redraws")

        // A long but legitimate action is not cut short, and a new update starts with a fresh budget.
        var action = ""
        for i in 0..<2000 { action += "[!SetVariable V\(i) \(i)]" }
        run(skin, action)
        t.equal(skin.variable("V1999"), "1999")
    }

    t.suite("Engine review: measured ranges widen the default range") {
        // Manual (Measures → Percentage) + general options (MinValue 0, MaxValue 1): a Calc fraction bound to a
        // Bar must not collapse to a zero-width range (it used to draw every constant Calc as 0 %).
        let (skin, _, _) = try makeEngineSkin(t, """
        [Variables]
        V=0.5
        [Frac]
        Measure=Calc
        Formula=#V#
        DynamicVariables=1
        [Neg]
        Measure=Calc
        Formula=-3
        [Big]
        Measure=Calc
        Formula=Big + 25
        [MinOnly]
        Measure=Calc
        Formula=20
        MinValue=10
        [Bar]
        Meter=Bar
        MeasureName=Frac
        W=100
        H=10
        """)
        skin.update()
        let frac = skin.measure(named: "Frac")!
        t.close(frac.minValue, 0)
        t.close(frac.maxValue, 1)
        t.close(frac.relativeValue, 0.5, "a Calc of 0.5 is 50 % of the default range")
        skin.setVariable("V", "0.25")
        skin.update()
        t.close(frac.relativeValue, 0.25)
        t.close(skin.measure(named: "Neg")!.minValue, -3, "values below 0 widen MinValue")
        t.close(skin.measure(named: "Neg")!.maxValue, 1)
        skin.update()
        t.close(skin.measure(named: "Big")!.minValue, 0)
        t.close(skin.measure(named: "Big")!.maxValue, 75, "the largest value seen widens MaxValue")
        t.close(skin.measure(named: "Big")!.relativeValue, 1)
        t.close(skin.measure(named: "MinOnly")!.minValue, 10)
        t.close(skin.measure(named: "MinOnly")!.maxValue, 20)
        t.close(skin.measure(named: "Frac")!.relativeValue, 0.25, "[Frac:%] basis")

        let system = EngineTestSystem()
        system.counters["en1"] = NetworkCounters(received: 0, sent: 0)
        var now = 100.0
        let (net, _, _) = try makeEngineSkin(t, "[In]\nMeasure=NetIn\n", system: system)
        net.clock = { now }
        net.update()
        system.counters["en1"] = NetworkCounters(received: 500, sent: 0)
        now += 1
        net.update()
        let netIn = net.measure(named: "In")!
        t.close(netIn.value, 500)
        t.close(netIn.minValue, 0)
        t.close(netIn.maxValue, 500)
    }

    t.suite("Engine review: Memory is PhysicalMemory + SwapMemory") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Mem]
        Measure=Memory
        [MemFree]
        Measure=Memory
        InvertMeasure=1
        [Phys]
        Measure=PhysicalMemory
        [Swap]
        Measure=SwapMemory
        """)
        skin.update()
        // RAM 16 GiB (8 used), swap 2 GiB (1 used): SwapMemory 9 of 18, Memory = 8 + 9 = 17 of 16 + 18 = 34.
        t.close(value(skin, "Mem"), 17 * gib, "used = RAM used + (RAM used + swap used)")
        t.close(skin.measure(named: "Mem")!.maxValue, 34 * gib)
        t.close(value(skin, "MemFree"), 17 * gib, "free = free RAM + (free RAM + free swap)")
        t.close(value(skin, "Mem"), value(skin, "Phys") + value(skin, "Swap"))
    }

    t.suite("Engine review: repeated problems are logged once") {
        let (skin, host, _) = try makeEngineSkin(t, """
        [Rainmeter]
        OnUpdateAction=[!UnknownBang a b]
        [Variables]
        N=1
        [Cond]
        Measure=Calc
        Formula=1
        DynamicVariables=1
        IfCondition=(1 + #N#
        IfTrueAction=[!Log x]
        IfMatch=([#N#
        IfMatchAction=[!Log y]
        [Calc]
        Measure=Calc
        Formula=(#N# +
        DynamicVariables=1
        [Show]
        Meter=String
        MeasureName=Missing
        DynamicVariables=1
        """)
        for i in 0..<5 {
            skin.setVariable("N", String(i))
            skin.update()
        }
        t.equal(host.logs.filter { $0.contains("MeasureName=Missing") }.count, 1)
        t.equal(host.logs.filter { $0.contains("invalid IfCondition") }.count, 1,
                "a dynamic condition whose (invalid) text changes every update")
        t.equal(host.logs.filter { $0.contains("invalid IfMatch") }.count, 1)
        t.equal(host.logs.filter { $0.contains("invalid Formula") }.count, 1)
        t.equal(host.logs.filter { $0.contains("!unknownbang") }.count, 1, "unsupported bang in OnUpdateAction")
        t.check(!skin.issues.contains { $0.contains("unknownbang") }, "a typo, not a compatibility issue")
        t.check(host.logs.contains { $0.contains("Unknown bang: !unknownbang") })
    }

    t.suite("Engine review: string values follow option changes") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Disk]
        Measure=FreeDiskSpace
        Label=1
        [DiskType]
        Measure=FreeDiskSpace
        Type=1
        [Power]
        Measure=Plugin
        Plugin=PowerPlugin
        PowerState=Lifetime
        """)
        skin.update()
        t.equal(string(skin, "Disk"), "Macintosh HD")
        t.equal(string(skin, "DiskType"), "Fixed")
        t.equal(string(skin, "Power"), "01:30")
        run(skin, "[!SetOption Disk Label 0][!SetOption DiskType Type 0][!SetOption Power PowerState Percent]")
        skin.update()
        t.equal(string(skin, "Disk"), "250", "without Label the string is the number")
        t.equal(string(skin, "DiskType"), "250")
        t.equal(string(skin, "Power"), "80")
    }

    t.suite("Engine review: a failing Calc formula keeps its last result") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Variables]
        F=2
        [C]
        Measure=Calc
        Formula=#F#
        DynamicVariables=1
        MinValue=0
        MaxValue=10
        InvertMeasure=1
        """)
        skin.update()
        t.close(value(skin, "C"), 8)
        skin.setVariable("F", "Nope + 1")
        var values: [Double] = []
        for _ in 0..<3 {
            skin.update()
            values.append(value(skin, "C"))
        }
        t.equal(values, [8, 8, 8], "InvertMeasure is not applied twice (it alternated 8, 2, 8…)")
    }

    t.suite("Engine review: !UpdateMeter layout is lazy but current") {
        var measured = 0
        let host = FakeHost()
        host.textSizer = { text, _, _ in
            measured += 1
            return (Double(text.count) * 7, 14)
        }
        var ini = "[A]\nMeter=String\nText=a\n"
        for i in 0..<20 { ini += "[S\(i)]\nMeter=String\nY=R\nText=s\(i)\n" }
        let (skin, _, _) = try makeEngineSkin(t, ini, host: host)
        skin.update()
        measured = 0
        var action = "[!SetOption A Text abcdef][!UpdateMeter A][!SetVariable W [A:W]]"
        for i in 0..<20 { action += "[!UpdateMeter S\(i)]" }
        run(skin, action)
        t.equal(skin.variable("W"), "42", "a meter section variable read after !UpdateMeter sees the new size")
        t.close(frame(skin, "A").width, 42)
        t.check(measured <= 2 * 21, "one layout for the section variable and one at the end, not one per bang "
                + "(measured \(measured) texts)")
        run(skin, "[!SetOption S0 Text longer-text][!UpdateMeterGroup Nope][!UpdateMeter S0]")
        t.close(frame(skin, "S0").width, 77, "laid out at the end of the action")
        skin.perform(Bang(name: "setoption", args: ["S1", "Text", "xyz"]))
        skin.perform(Bang(name: "updatemeter", args: ["S1"]))
        t.close(frame(skin, "S1").width, 21, "bangs performed by the host are laid out too")
    }

    t.suite("Engine review: an action that unloads the skin stops the update") {
        let host = UnloadingHost()
        let (skin, _, _) = try makeEngineSkin(t, """
        [Rainmeter]
        OnUpdateAction=[!SetVariable After 1]
        [Quit]
        Measure=Calc
        Formula=1
        IfCondition=Quit = 1
        IfTrueAction=[!Refresh][!SetVariable Rest 1]
        [Later]
        Measure=Calc
        Formula=1
        OnUpdateAction=[!SetVariable Later 1]
        [M]
        Meter=Image
        OnUpdateAction=[!SetVariable Meter 1]
        """, host: host)
        skin.update()
        t.equal(skin.variable("Rest"), nil)
        t.equal(skin.variable("Later"), nil, "later measures of a closed skin do not run")
        t.equal(skin.variable("Meter"), nil)
        t.equal(skin.variable("After"), nil)
        t.equal(host.redraws, 0, "a closed skin is not redrawn")
    }

    t.suite("Engine review: !Delay keeps the mouse variables") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [M]
        Meter=Image
        X=10
        W=50
        H=10
        LeftMouseUpAction=[!Delay 16][!SetVariable P "$MouseX$,$MouseY$"]
        """)
        skin.update()
        t.check(skin.mouseEvent(.leftUp, x: 35, y: 4))
        t.check(spinUntil { skin.variable("P") != nil }, "the delayed action ran")
        t.equal(skin.variable("P"), "25,4")
    }

    t.suite("Engine review: option lookups are case-insensitive and keep precedence") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [stylea]
        w=10
        H=7
        solidcolor=1,2,3
        [StyleB]
        SOLIDCOLOR=4,5,6
        [One]
        Meter=Image
        MeterStyle=STYLEA | styleb
        h=5
        """)
        skin.update()
        t.equal(frame(skin, "One"), SkinRect(x: 0, y: 0, width: 10, height: 5))
        t.equal(skin.meter(named: "One")!.solidColor, RGBA(r: 4, g: 5, b: 6))
        t.equal(skin.meter(named: "One")!.rawOption("SolidColor"), "4,5,6")
        run(skin, "[!SetOption One h \"\"]")
        skin.update()
        t.close(frame(skin, "One").height, 7)
    }

    t.suite("Engine review: pending delays and distinct messages are bounded") {
        let (skin, host, _) = try makeEngineSkin(t, """
        [C]
        Measure=Calc
        Formula=C + 1
        [M]
        Meter=String
        MeasureName=Missing[C:]
        DynamicVariables=1
        """)
        for _ in 0..<300 { run(skin, "[!Delay 60000][!SetVariable Late 1]") }
        t.equal(host.logs.filter { $0.contains("Too many pending !Delay") }.count, 1)
        for _ in 0..<(Skin.maxDistinctMessages + 50) { skin.update() }
        let missing = host.logs.filter { $0.contains("MeasureName=Missing") }.count
        t.equal(missing, Meter.maxReportedMissingMeasures,
                "a MeasureName that changes every update is logged once per name, but boundedly")
        run(skin, "[!UnknownBang]")
        t.check(host.logs.contains { $0.contains("Unknown bang: !unknownbang") },
                "missing measure names do not use up the skin's budget of distinct messages")
        skin.close()
        t.equal(skin.variable("Late"), nil)
    }

    t.suite("Engine review: Calc Counter survives a refresh") {
        let ini = "[C]\nMeasure=Calc\nFormula=Counter\n"
        let (old, _, _) = try makeEngineSkin(t, ini)
        for _ in 0..<5 { old.update() }
        t.close(value(old, "C"), 4)
        let (refreshed, _, _) = try makeEngineSkin(t, ini)
        refreshed.continueCounter(from: old)
        refreshed.update()
        t.close(value(refreshed, "C"), 5, "continues where the old skin object stopped")
        t.equal(refreshed.updateCount, 1, "updateCount itself (OnRefreshAction timing) restarts")
        let (fresh, _, _) = try makeEngineSkin(t, ini)
        fresh.update()
        t.close(value(fresh, "C"), 0, "a newly loaded skin starts from 0")
    }

    t.suite("Engine review: padded label/value rows (layout pattern of the manual's WebParser tutorial)") {
        // Centered and right-aligned String meters with Padding line up with left-aligned padded boxes: the anchor
        // offset uses the padded size, r/R use the previous meter's real edges.
        let (skin, _, _) = try makeEngineSkin(t, """
        [Back]
        Meter=Image
        W=320
        H=200
        [Title]
        Meter=String
        X=160
        Y=5
        W=300
        H=15
        Padding=5,5,5,5
        StringAlign=Center
        Text=Header
        [Value]
        Meter=String
        X=160
        Y=3R
        W=300
        H=15
        Padding=5,5,5,5
        StringAlign=Center
        Text=v
        [Label]
        Meter=String
        X=5
        Y=3R
        W=300
        H=15
        Padding=5,5,5,8
        Text=Label:
        [Icon]
        Meter=Image
        X=70r
        Y=4r
        W=30
        H=20
        [Right]
        Meter=String
        X=315
        Y=-2r
        Padding=5,5,5,3
        StringAlign=Right
        Text=abc
        [Label2]
        Meter=String
        X=5
        Y=5R
        W=300
        H=15
        Padding=5,5,5,5
        Text=Other:
        [Value2]
        Meter=String
        X=315
        Y=0r
        W=300
        H=15
        Padding=5,5,5,5
        StringAlign=Right
        Text=x
        [Label3]
        Meter=String
        X=5
        Y=3R
        Text=Last
        """)
        skin.update()
        t.equal(frame(skin, "Title"), SkinRect(x: 5, y: 5, width: 310, height: 25), "centered box spans 5…315")
        t.equal(frame(skin, "Value"), SkinRect(x: 5, y: 33, width: 310, height: 25))
        t.equal(frame(skin, "Label"), SkinRect(x: 5, y: 61, width: 310, height: 28))
        t.equal(frame(skin, "Icon"), SkinRect(x: 75, y: 65, width: 30, height: 20))
        t.equal(frame(skin, "Right"), SkinRect(x: 284, y: 63, width: 31, height: 22), "ends at X=315")
        t.equal(frame(skin, "Label2"), SkinRect(x: 5, y: 90, width: 310, height: 25))
        t.equal(frame(skin, "Value2"), SkinRect(x: 5, y: 90, width: 310, height: 25), "same row, same box")
        t.equal(frame(skin, "Label3").y, 118)
        t.close(skin.width, 320)
    }

    t.suite("Engine review: disabled and empty actions show no pointer and block the meters behind") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Rainmeter]
        LeftMouseUpAction=[!Log skin]
        [Back]
        Meter=Image
        W=30
        H=30
        LeftMouseUpAction=[!Log back]
        [Empty]
        Meter=Image
        W=10
        H=10
        LeftMouseUpAction=[]
        [Disabled]
        Meter=Image
        X=10
        W=10
        H=10
        RightMouseUpAction=[!Log disabled]
        [Cleared]
        Meter=Image
        X=20
        W=10
        H=10
        MiddleMouseUpAction=[!Log cleared]
        """)
        skin.update()
        run(skin, "[!DisableMouseAction Disabled RightMouseUpAction][!ClearMouseAction Cleared *]")
        t.equal(skin.mouseCursorName(at: 5, 5), nil, "[] is an action that does nothing: no pointer")
        t.equal(skin.mouseCursorName(at: 15, 5), nil, "a disabled action blocks the pointer of the meter behind")
        t.equal(skin.mouseCursorName(at: 25, 5), "HAND", "a cleared action lets the meter behind through")
        t.equal(skin.mouseCursorName(at: 25, 25), "HAND")
        t.equal(skin.mouseCursorName(at: 45, 45), "HAND", "outside the meters: the [Rainmeter] action")
        run(skin, "[!DisableMouseAction Rainmeter LeftMouseUpAction]")
        t.equal(skin.mouseCursorName(at: 45, 45), nil)
        t.check(Skin.isEmptyAction("[ ][]") && Skin.isEmptyAction("") && !Skin.isEmptyAction("[!Log]"))
    }

    t.suite("Engine review: !SetOption keeps measure formulas dynamic") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Variables]
        V=1
        [Src]
        Measure=Calc
        Formula=#V#
        DynamicVariables=1
        [C]
        Measure=Calc
        Formula=0
        [Check]
        Measure=Calc
        Formula=1
        IfConditionMode=1
        [T]
        Meter=Image
        W=1
        H=1
        """)
        skin.update()
        run(skin, "[!SetOption C Formula \"(Src * 2)\"][!SetOption Check IfCondition \"(Src > 5)\"]"
            + "[!SetOption Check IfTrueAction \"[!SetVariable Big 1]\"][!SetOption T W \"(Src * 3)\"]")
        t.equal(skin.measure(named: "C")?.rawOption("Formula"), "(Src * 2)", "Calc Formula stored as written")
        t.equal(skin.meter(named: "T")?.rawOption("W"), "3", "other options: measures resolved by the bang")
        skin.update()
        t.close(value(skin, "C"), 2)
        skin.setVariable("V", "4")
        skin.update()
        t.close(value(skin, "C"), 8, "the Calc still follows its measure")
        t.equal(skin.variable("Big"), nil)
        skin.setVariable("V", "6")
        skin.update()
        t.equal(skin.variable("Big"), "1", "the IfCondition set by the bang follows its measure")
        t.check(Skin.readsMeasureNames("IfCondition12") && !Skin.readsMeasureNames("IfConditionMode"))
    }

    t.suite("Engine review: compatibility hints do not call portable plugins Windows-only") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Timer]
        Measure=Plugin
        Plugin=ActionTimer
        [Ping]
        Measure=Plugin
        Plugin=Plugins\\PingPlugin.dll
        [Reg]
        Measure=Registry
        [Custom]
        Measure=Plugin
        Plugin=SomeoneElses.dll
        """)
        skin.update()
        // ActionTimer and Ping are implemented (CorePlugins), so they are no compatibility issue at all.
        t.check(!(skin.measure(named: "Timer") is UnsupportedMeasure) && !(skin.measure(named: "Ping") is UnsupportedMeasure))
        t.check(!skin.issues.contains { $0.contains("ActionTimer") || $0.contains("PingPlugin") }, "\(skin.issues)")
        t.check(skin.issues.contains { $0.hasPrefix("Registry value HKCU") }, "\(skin.issues)")
        t.check(skin.issues.contains("Plugin \"SomeoneElses.dll\" is a Windows plugin and is not supported"))
        t.check(!skin.issues.contains { $0.contains("ActionTimer is Windows-only") })
    }

    t.suite("Engine review fuzz: random options and bangs do not crash or hang") {
        struct Rng { var state: UInt64
            mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
            mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
        }
        var rng = Rng(state: UInt64(ProcessInfo.processInfo.environment["FUZZSEED"].flatMap { UInt64($0) } ?? 7))
        let values = ["", "0", "-1", "1", "1e308", "-1e308", "(1/0)", "(0/0)", "abc", "#Missing#", "[Nope]", "[M0:]",
                      "[M1:%]", "[T0:W]", "5r", "-3R", "(#V#*2)", "255,0,0,0", "|", "| |", "\u{1F600}", "((((", "))",
                      "[!Update]", "[!UpdateMeter *][!UpdateMeasure *]", "M0 > 1", "T0", "*", "2147483648", "-99999999999"]
        let measureTypes = ["Calc", "Loop", "String", "Time", "Uptime", "CPU", "Memory", "NetIn", "FreeDiskSpace",
                            "SysInfo", "Process", "Plugin", "Registry", "Script", "Nope"]
        let meterTypes = ["String", "Image", "Bar", "Line", "Histogram", "Roundline", "Rotator", "Shape", "Button",
                          "Bitmap", "Nope"]
        let measureKeys = ["Formula", "MinValue", "MaxValue", "InvertMeasure", "AverageSize", "UpdateDivider", "Disabled",
                           "Paused", "DynamicVariables", "IfCondition", "IfTrueAction", "IfConditionMode", "IfMatch",
                           "IfMatchAction", "IfAboveValue", "IfAboveAction", "IfEqualValue", "IfEqualAction",
                           "OnChangeAction", "OnUpdateAction", "Substitute", "RegExpSubstitute", "StartValue",
                           "EndValue", "Increment", "LoopCount", "LowBound", "HighBound", "UpdateRandom",
                           "UniqueRandom", "String", "SysInfoType", "SysInfoData", "Interface", "Drive", "Group",
                           "SecondsValue", "Plugin", "PowerState", "Total", "Label", "Type"]
        let meterKeys = ["X", "Y", "W", "H", "Hidden", "Padding", "MeterStyle", "Container", "MeasureName",
                         "MeasureName2", "SolidColor", "TransformationMatrix", "UpdateDivider", "DynamicVariables",
                         "OnUpdateAction", "LeftMouseUpAction", "MouseOverAction", "ToolTipText", "Text", "Group"]
        let bangs = ["!SetOption T0 X", "!SetOption M0 Formula", "!SetVariable V", "!UpdateMeter", "!UpdateMeasure",
                     "!ShowMeter", "!HideMeter", "!ToggleMeasure", "!PauseMeasure", "!MoveMeter 1", "!Redraw",
                     "!Update", "!CommandMeasure M0", "!SetOptionGroup G Hidden", "!DisableMouseAction *",
                     "!ToggleMouseActionGroup *", "!Log", "!SetOption Rainmeter ContextTitle", "!WriteKeyValue Variables"]
        for iteration in 0..<60 {
            var ini = "[Rainmeter]\nUpdate=\(rng.pick(values))\nDynamicWindowSize=\(rng.pick(["0", "1"]))\n"
                + "SkinWidth=\(rng.pick(values))\nOnUpdateAction=\(rng.pick(values))\n[Variables]\nV=\(rng.pick(values))\n"
            for i in 0..<4 {
                ini += "[M\(i)]\nMeasure=\(rng.pick(measureTypes))\n"
                for _ in 0..<6 { ini += "\(rng.pick(measureKeys))=\(rng.pick(values))\n" }
            }
            for i in 0..<5 {
                ini += "[T\(i)]\nMeter=\(rng.pick(meterTypes))\n"
                for _ in 0..<6 { ini += "\(rng.pick(meterKeys))=\(rng.pick(values))\n" }
            }
            ini += "[G]\nX=\(rng.pick(values))\n"
            let (skin, _, _) = try makeEngineSkin(t, ini)
            for _ in 0..<3 {
                skin.update()
                var action = ""
                for _ in 0..<4 { action += "[\(rng.pick(bangs)) \"\(rng.pick(values))\" \(rng.pick(["T1", "M1", "*", "G", ""]))]" }
                run(skin, action)
                _ = skin.mouseEvent(.leftUp, x: Double(rng.next() % 300), y: Double(rng.next() % 300))
                skin.mouseMoved(x: Double(rng.next() % 300), y: Double(rng.next() % 300))
                _ = skin.contextMenuItems()
                _ = skin.toolTipInfo(at: 5, 5)
                _ = skin.mouseCursorName(at: 5, 5)
            }
            skin.close()
            t.check(skin.width.isFinite && skin.height.isFinite && skin.width >= 1, "iteration \(iteration)")
        }
    }

    t.suite("Engine review: huge dynamic skin update stays bounded") {
        // Not a timing assertion: checks that a large dynamic skin updates correctly (it is also the benchmark
        // used during the review: ~3.7 ms per update in release for 200 dynamic String meters and 50 measures).
        var big = "[Variables]\nV=1\n"
        for i in 0..<50 {
            big += "[C\(i)]\nMeasure=Calc\nFormula=C\(i) + #V#\nDynamicVariables=1\nIfCondition=C\(i) > 2\n"
                + "IfTrueAction=[!SetVariable X\(i) 1]\nSubstitute=\"1\":\"one\"\n"
        }
        for i in 0..<200 {
            big += "[M\(i)]\nMeter=String\nMeterStyle=S\nY=2R\nText=[C\(i % 50)] [C\(i % 50):1] #V#\n"
                + "DynamicVariables=1\n"
        }
        big += "[S]\nFontSize=10\nPadding=2,2,2,2\n"
        let (skin, _, _) = try makeEngineSkin(t, big)
        skin.update()
        t.equal(text(skin, "M1"), "one 1.0 1", "Substitute applies to the string value")
        skin.update()
        skin.update()
        t.equal(text(skin, "M199"), "3 3.0 1")
        t.equal(skin.variable("X49"), "1")
        t.close(frame(skin, "M199").y, 199 * 20 + 2)
        if let runs = ProcessInfo.processInfo.environment["ENGINE_BENCH"].flatMap({ Int($0) }) {
            let start = Date()
            for _ in 0..<runs { skin.update() }
            print("    ms per update:", Date().timeIntervalSince(start) * 1000 / Double(max(runs, 1)))
        }
    }
}

// MARK: - Integration of the meter / measure areas with the engine

/// FakeHost that answers pixel alpha queries (Button hit tests).
private final class AlphaHost: FakeHost, SkinImageQueries {
    /// Alpha by (file name, x, y); nil = unknown (opaque).
    var alpha: ((String, Int, Int) -> Double?)?
    func imageExifOrientation(atPath path: String) -> Int { 1 }
    func imagePixelAlpha(atPath path: String, x: Int, y: Int, exifOriented: Bool) -> Double? {
        alpha?((path as NSString).lastPathComponent, x, y)
    }
}

/// Spins the main run loop until `condition` holds (true) or `timeout` passes (false).
@discardableResult
private func spinUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    return true
}

private func click(_ skin: Skin, _ x: Double, _ y: Double) {
    skin.mouseEvent(.leftDown, x: x, y: y)
    skin.mouseEvent(.leftUp, x: x, y: y)
}

private func runEngineIntegrationTests(_ t: TestRunner) {
    t.suite("Engine integration: Measure=Plugin with Plugin=WebParser") {
        // WebParser "was previously a plugin": Plugin=WebParser, WebParser.dll and Plugins\WebParser.dll all make the
        // WebParser measure, without a compatibility hint, and children find such a parent.
        let (skin, host, _) = try makeEngineSkin(t, """
        [Variables]
        Parser=Plugins\\WebParser.dll

        [Parent]
        Measure=Plugin
        Plugin=WebParser.dll
        URL=file://#CURRENTPATH#data.txt
        RegExp=(?siU)<a>(.*)</a>.*<b>(.*)</b>

        [ChildA]
        Measure=Plugin
        Plugin=#Parser#
        URL=[Parent]
        StringIndex=1

        [ChildB]
        Measure=Plugin
        Plugin=WebParser
        URL=[Parent]
        StringIndex=2

        [ChildC]
        Measure=WebParser
        URL=[Parent]
        StringIndex=2

        [Show]
        Meter=String
        MeasureName=ChildA
        MeasureName2=ChildB
        Text=%1+%2
        """, files: ["Root/Sub/data.txt": "<a>alpha</a> <b>beta</b>"])
        for name in ["Parent", "ChildA", "ChildB", "ChildC"] {
            t.check(skin.measure(named: name) is WebParserMeasure, "[\(name)] is a WebParser measure")
            t.equal(skin.measure(named: name)?.type, "webparser")
        }
        t.equal(skin.issues, [], "no compatibility hint for WebParser")
        for name in ["ChildA", "ChildB", "ChildC"] {
            t.equal((skin.measure(named: name) as? WebParserMeasure)?.parentName, "Parent", name)
        }
        t.equal((skin.measure(named: "Parent") as? WebParserMeasure)?.parentName, nil)
        skin.update()
        t.check(spinUntil { string(skin, "ChildA") == "alpha" && string(skin, "ChildC") == "beta" },
                "the parent's result reaches its children")
        t.equal(string(skin, "ChildB"), "beta")
        skin.update()
        t.equal(text(skin, "Show"), "alpha+beta")
        t.check(!host.logs.contains { $0.hasPrefix("Error") }, "\(host.logs)")

        let (other, _, _) = try makeEngineSkin(t, """
        [Web]
        Measure=Plugin
        Plugin=Plugins\\WebParser.dll
        URL=file:///nonexistent-deskset-test
        [Unknown]
        Measure=Plugin
        Plugin=Plugins\\SomethingElse.dll
        """)
        t.check(other.measure(named: "Web") is WebParserMeasure)
        t.equal(other.issues, ["Plugin \"Plugins\\SomethingElse.dll\" is a Windows plugin and is not supported"])
    }

    t.suite("Engine integration: meter and skin sizes are finite and bounded") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Rainmeter]
        DynamicWindowSize=1

        [Huge]
        Meter=Image
        X=(10**300)
        Y=(-(10**300))
        W=(10**300)
        H=1e400

        [Chain1]
        Meter=Image
        X=(10**6)R
        W=(10**6)
        H=10

        [Chain2]
        Meter=Image
        X=(10**6)R
        Y=0r
        W=10
        H=10
        Padding=(10**9),0,(10**9),0

        [Show]
        Meter=String
        X=0
        Y=0
        Text=[Huge:X] [Huge:Y] [Huge:W] [Huge:H] [Chain2:X] [Chain2:W]
        DynamicVariables=1
        """)
        skin.update()
        skin.update()
        let limit = Meter.maxCoordinate
        t.equal(frame(skin, "Huge"), SkinRect(x: limit, y: -limit, width: limit, height: 0),
                "X, Y, W clamped to ±1e6; an unreadable H (1e400) uses the natural size")
        t.equal(frame(skin, "Chain1"), SkinRect(x: limit, y: 0, width: limit, height: 10),
                "relative positions cannot run away either")
        t.equal(frame(skin, "Chain2"), SkinRect(x: limit, y: 0, width: limit, height: 10), "padding included")
        t.equal(text(skin, "Show"), "1000000 -1000000 1000000 0 1000000 1000000")
        for m in skin.meters {
            let f = m.frame
            t.check([f.x, f.y, f.width, f.height].allSatisfy { $0.isFinite && abs($0) <= limit }, m.name)
        }
        t.close(skin.width, Skin.maxSide, "the skin is at most 16384 points wide")
        t.close(skin.height, 14, "Show is the tallest meter")

        t.equal(Meter.size(.infinity), nil)
        t.equal(Meter.size(.nan), nil)
        t.equal(Meter.size(-5), 0)
        t.equal(Meter.size(2e6), limit)
        t.equal(Meter.position("12R"), PositionValue(value: 12, mode: .relativeToPreviousEnd))
        t.equal(Meter.position("(-10**30)r"), PositionValue(value: -limit, mode: .relativeToPreviousStart))
        t.equal(Meter.position("abc"), PositionValue(value: 0))
        t.equal(Meter.position(nil), PositionValue(value: 0))
        for (v, expected) in [(Double.nan, 1.0), (.infinity, 1), (-.infinity, 1), (0, 1), (-7, 1), (123.5, 123.5),
                              (1e9, Skin.maxSide)] {
            t.equal(Skin.side(v), expected, "\(v)")
        }

        let (fixed, _, _) = try makeEngineSkin(t, """
        [Rainmeter]
        SkinWidth=(10**300)
        SkinHeight=1e400
        [A]
        Meter=Image
        W=30
        H=(0/0)
        """)
        fixed.update()
        t.equal(fixed.settings.skinWidth, Skin.maxSide)
        t.equal(fixed.settings.skinHeight, nil, "an unreadable SkinHeight has no effect")
        t.close(fixed.width, Skin.maxSide)
        t.close(fixed.height, 1, "at least one point")
    }

    t.suite("Engine integration: mouse detection follows Meter.hitTest (Shape meters)") {
        // Manual (Shape): "The mouse is only detected on any solid part of the drawing created by any and all shapes
        // in the meter", "even if the shapes extend outside the boundaries of the meter container".
        let (skin, _, _) = try makeEngineSkin(t, """
        [Back]
        Meter=Image
        W=300
        H=200
        SolidColor=0,0,0,1
        LeftMouseUpAction=[!SetVariable Hit back]
        ToolTipText=back tip

        [Circle]
        Meter=Shape
        Shape=Ellipse 50,50,50
        LeftMouseUpAction=[!SetVariable Hit circle]
        MouseOverAction=[!SetVariable Over circle]
        MouseLeaveAction=[!SetVariable Over none]
        ToolTipText=circle tip
        MouseActionCursorName=Circle.cur

        [Outside]
        Meter=Shape
        X=200
        Shape=Rectangle -30,0,20,20
        LeftMouseUpAction=[!SetVariable Hit outside]

        [Mask]
        Meter=Shape
        X=0
        Y=300
        Shape=Ellipse 50,50,50

        [Content]
        Meter=Image
        Container=Mask
        W=100
        H=100
        LeftMouseUpAction=[!SetVariable Hit content]
        """)
        skin.update()
        func hit(_ x: Double, _ y: Double) -> String? {
            skin.setVariable("Hit", "-")
            skin.mouseEvent(.leftUp, x: x, y: y)
            return skin.variable("Hit")
        }
        let circle = skin.meter(named: "Circle")!
        t.check(circle.frame.contains(x: 5, y: 5) && !circle.hitTest(x: 5, y: 5), "corner: in the frame, not the shape")
        t.check(!circle.isHit(x: 5, y: 5) && circle.isHit(x: 50, y: 50))
        t.equal(hit(50, 50), "circle")
        t.equal(hit(5, 5), "back", "the empty corner of the Shape lets the meter behind get the click")
        t.equal(hit(180, 10), "outside", "a shape outside its meter's frame is detected")
        t.equal(skin.toolTipInfo(at: 5, 5)?.text, "back tip")
        t.equal(skin.toolTipInfo(at: 50, 50)?.text, "circle tip")
        t.equal(skin.mouseCursorName(at: 5, 5), "HAND")
        t.equal(skin.mouseCursorName(at: 50, 50), "Circle.cur")
        t.check(skin.hasAction(.leftUp, x: 5, y: 5))
        skin.mouseMoved(x: 5, y: 5)
        t.equal(skin.variable("Over"), nil, "no hover over the empty corner")
        skin.mouseMoved(x: 50, y: 50)
        t.equal(skin.variable("Over"), "circle")
        skin.mouseMoved(x: 5, y: 5)
        t.equal(skin.variable("Over"), "none")
        t.equal(hit(50, 350), "content")
        t.equal(hit(3, 303), "-", "content outside the solid part of a Shape container does not exist")
        t.check(!skin.mouseEvent(.leftUp, x: 3, y: 303))
    }

    t.suite("Engine integration: Buttons — transparent pixels, z-order, capture and cancelMousePress") {
        let host = AlphaHost()
        host.imageSizes = ["Under.png": (60, 20), "Top.png": (60, 20)]
        // Top.png: the right half of every frame is transparent.
        host.alpha = { name, x, _ in name == "Top.png" && x % 20 >= 10 ? 0 : 255 }
        let (skin, _, _) = try makeEngineSkin(t, """
        [Variables]
        Under=0
        Top=0

        [Under]
        Meter=Button
        ButtonImage=Under.png
        ButtonCommand=[!SetVariable Under "([#Under]+1)"]

        [Top]
        Meter=Button
        ButtonImage=Top.png
        ButtonCommand=[!SetVariable Top "([#Top]+1)"]

        [Cover]
        Meter=Image
        Y=15
        W=5
        H=5
        LeftMouseDownAction=[!SetVariable Cover down]

        [Far]
        Meter=Image
        X=100
        W=10
        H=10
        LeftMouseUpAction=[!SetVariable Far up]
        """, host: host)
        skin.update()
        let under = skin.meter(named: "Under") as! ButtonMeter
        let top = skin.meter(named: "Top") as! ButtonMeter
        t.check(!top.hitTest(x: 15, y: 5) && top.hitTest(x: 5, y: 5), "Button.hitTest is the Meter.hitTest override")
        t.check(!top.isHit(x: 15, y: 5, precise: true) && top.isHit(x: 5, y: 5, precise: true))
        t.check(top.isHit(x: 15, y: 5), "the Button's general mouse actions use its frame")

        click(skin, 15, 5)
        t.equal(skin.variable("Under"), "1", "a transparent pixel of the top Button lets the Button below get the click")
        t.equal(skin.variable("Top"), "0")
        click(skin, 5, 5)
        t.equal(skin.variable("Top"), "1")
        t.equal(skin.variable("Under"), "1")

        skin.mouseExited()
        click(skin, 2, 17)
        t.equal(skin.variable("Cover"), "down", "a meter drawn above a Button gets the event first")
        t.equal(top.state, .normal, "the Button below it was not pressed")

        // Capture: released outside, the pressed Button still gets the release (no command, back to normal).
        skin.mouseEvent(.leftDown, x: 5, y: 5)
        t.equal(top.state, .pressed)
        skin.mouseEvent(.leftUp, x: 105, y: 5)
        t.equal(top.state, .normal, "the release outside reached the pressed Button")
        t.equal(skin.variable("Top"), "1")
        t.equal(skin.variable("Far"), "up", "and the meter under the pointer still gets its release action")
        skin.mouseEvent(.leftUp, x: 5, y: 5)
        t.equal(skin.variable("Top"), "1", "one release per press")

        // Released on the Button below: only the pressed one is concerned.
        skin.mouseEvent(.leftDown, x: 5, y: 5)
        skin.mouseEvent(.leftUp, x: 15, y: 5)
        t.equal(skin.variable("Top"), "1")
        t.equal(skin.variable("Under"), "1")
        t.equal(top.state, .normal)
        t.equal(under.state, .normal)

        // The host cancels a press whose release will not come (e.g. a window drag).
        skin.mouseEvent(.leftDown, x: 5, y: 5)
        t.equal(top.state, .pressed)
        skin.cancelMousePress()
        t.equal(top.state, .normal)
        skin.mouseEvent(.leftUp, x: 5, y: 5)
        t.equal(skin.variable("Top"), "1", "a cancelled press runs no ButtonCommand")

        // A pressed Button hidden before the release goes back to normal and runs nothing.
        skin.mouseEvent(.leftDown, x: 5, y: 5)
        run(skin, "[!HideMeter Top]")
        skin.mouseEvent(.leftUp, x: 5, y: 5)
        t.equal(top.state, .normal)
        t.equal(skin.variable("Top"), "1")
        t.equal(skin.variable("Under"), "1", "the release does not press through to the Button below")
        run(skin, "[!ShowMeter Top]")

        // Only the topmost Button under the mouse is hovered.
        skin.mouseMoved(x: 5, y: 5)
        t.equal(top.state, .hover)
        t.equal(under.state, .normal)
        skin.mouseMoved(x: 15, y: 5)
        t.equal(top.state, .normal)
        t.equal(under.state, .hover)
        skin.mouseExited()
        t.equal(under.state, .normal)
    }

    t.suite("Engine integration: mouse action state bangs (manual: Bangs → Mouse action state bangs)") {
        let (skin, host, _) = try makeEngineSkin(t, """
        [Rainmeter]
        LeftMouseUpAction=[!SetVariable Hit skin]
        MouseOverAction=[!SetVariable SkinOver in]
        MouseLeaveAction=[!SetVariable SkinOver out]

        [Back]
        Meter=Image
        W=100
        H=100
        Group=G
        LeftMouseUpAction=[!SetVariable Hit back]

        [Front]
        Meter=Image
        W=50
        H=50
        Group=G | H
        LeftMouseUpAction=[!SetVariable Hit front]
        RightMouseUpAction=[!SetVariable Hit right]

        [Solo]
        Meter=Image
        X=300
        W=10
        H=10
        LeftMouseUpAction=[!SetVariable Hit solo]
        """)
        skin.update()
        func hit(_ kind: MouseEventKind = .leftUp, _ x: Double = 10, _ y: Double = 10) -> String? {
            skin.setVariable("Hit", "-")
            skin.mouseEvent(kind, x: x, y: y)
            return skin.variable("Hit")
        }
        run(skin, "[!DisableMouseAction Front \"leftmouseupaction | RightMouseUpAction\"]")
        t.equal(skin.meter(named: "Front")?.mouseActionState(.leftUp), .disabled, "names are case-insensitive")
        t.equal(hit(), "-", "disabled: detected, no action")
        t.equal(hit(.rightUp), "-")
        t.equal(skin.mouseCursorName(at: 10, 10), nil, "disabled: no change to the cursor, blocks the meter behind")
        run(skin, "[!SetOption Front LeftMouseUpAction \"[!SetVariable Hit changed]\"]")
        skin.update()
        t.equal(hit(), "-", "the state survives a new action text")
        run(skin, "[!EnableMouseAction Front LeftMouseUpAction]")
        t.equal(hit(), "changed", "enabling restores the (current) action")

        run(skin, "[!ClearMouseActionGroup * G]")
        t.equal(hit(), "skin", "cleared: not detected, the skin behind gets it")
        t.equal(skin.mouseCursorName(at: 10, 10), "HAND", "the [Rainmeter] action shows the pointer")
        run(skin, "[!ToggleMouseActionGroup LeftMouseUpAction H]")
        t.equal(hit(), "changed")
        run(skin, "[!ToggleMouseActionGroup LeftMouseUpAction H]")
        t.equal(hit(), "skin", "toggle goes back to the last non-enabled state (cleared)")
        run(skin, "[!EnableMouseActionGroup * G][!ToggleMouseAction Back LeftMouseUpAction]")
        t.equal(skin.meter(named: "Back")?.mouseActionState(.leftUp), .cleared, "cleared beforehand: toggles to cleared")
        run(skin, "[!ToggleMouseAction Back LeftMouseUpAction][!ToggleMouseAction Solo LeftMouseUpAction]")
        t.equal(skin.meter(named: "Back")?.mouseActionState(.leftUp), .enabled)
        t.equal(skin.meter(named: "Solo")?.mouseActionState(.leftUp), .disabled, "disabled is the default toggle state")
        t.equal(hit(.leftUp, 305, 5), "-")
        run(skin, "[!ToggleMouseAction Solo LeftMouseUpAction]")
        t.equal(hit(.leftUp, 305, 5), "solo")

        run(skin, "[!DisableMouseAction Rainmeter \"MouseOverAction|LeftMouseUpAction\"]")
        skin.mouseMoved(x: 200, y: 200)
        t.equal(skin.variable("SkinOver"), nil, "a disabled skin MouseOverAction does not run")
        t.equal(hit(.leftUp, 200, 200), "-")
        t.check(skin.hasAction(.leftUp, x: 200, y: 200), "a disabled skin action still catches the click")
        t.equal(skin.mouseCursorName(at: 200, 200), nil)
        skin.mouseExited()
        t.equal(skin.variable("SkinOver"), "out")
        run(skin, "[!ClearMouseAction Rainmeter *]")
        t.check(!skin.hasAction(.leftUp, x: 200, y: 200))
        t.check(!skin.mouseEvent(.leftUp, x: 200, y: 200), "cleared: nothing catches the click")

        run(skin, "[!EnableMouseAction * *]")
        t.equal(skin.rainmeterSection?.mouseActionState(.leftUp), .cleared, "* names meters only")
        t.equal(hit(), "changed")
        run(skin, "[!DisableMouseAction Front LeftMouseUpAction \"Root\\Sub\"]")
        t.equal(hit(), "-", "the Config parameter naming this skin acts here")
        run(skin, "[!EnableMouseAction Front LeftMouseUpAction \"Other\\Skin\"]")
        t.equal(hit(), "-")
        t.check(host.forwarded.contains { $0.0.name == "enablemouseaction" && $0.1 == "Other\\Skin" },
                "another config: forwarded to the host")
        run(skin, "[!DisableMouseAction Missing LeftMouseUpAction][!DisableMouseAction Front NotAnAction]")
        t.check(host.logs.contains { $0.contains("[Missing] not found") })
        t.check(host.logs.contains { $0.contains("no valid mouse action") })
    }

    t.suite("Engine integration: empty option values and MeterStyle (the !SetOption guide hover example)") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [TextStyle]
        FontColor=255,0,0,255

        [MeterOne]
        Meter=String
        MeterStyle=TextStyle
        Text="Hello World"
        MouseOverAction=[!SetOption MeterOne FontColor 0,255,0,255][!SetOption MeterOne StringStyle Bold]
        MouseLeaveAction=[!SetOption MeterOne FontColor ""][!SetOption MeterOne StringStyle ""]

        [MeterTwo]
        Meter=String
        Y=20
        FontColor=255,0,0,255
        Text="Hello World"
        MouseOverAction=[!SetOption MeterTwo FontColor 0,255,0,255]
        MouseLeaveAction=[!SetOption MeterTwo FontColor ""]

        [StyleA]
        SolidColor=1,2,3
        W=10
        H=7
        [StyleB]
        W=
        [Empty]
        Meter=Image
        Y=40
        MeterStyle=StyleA | StyleB
        SolidColor=
        H=
        ToolTipText=
        """)
        skin.update()
        func style(_ name: String) -> TextStyle { (skin.meter(named: name) as! StringMeter).style }
        t.equal(style("MeterOne").color, RGBA(r: 255, g: 0, b: 0, a: 255))
        skin.mouseMoved(x: 5, y: 5)
        skin.update()
        t.equal(style("MeterOne").color, RGBA(r: 0, g: 255, b: 0, a: 255))
        t.check(style("MeterOne").bold)
        skin.mouseMoved(x: 500, y: 500)
        skin.update()
        t.equal(style("MeterOne").color, RGBA(r: 255, g: 0, b: 0, a: 255),
                "removing the option lets the MeterStyle control it again")
        t.check(!style("MeterOne").bold)

        skin.mouseMoved(x: 5, y: 25)
        skin.update()
        t.equal(style("MeterTwo").color, RGBA(r: 0, g: 255, b: 0, a: 255))
        skin.mouseMoved(x: 500, y: 500)
        skin.update()
        t.equal(style("MeterTwo").color, RGBA(r: 0, g: 0, b: 0, a: 255),
                "without a MeterStyle the option is gone: the default (black), not the file's red")

        let empty = skin.meter(named: "Empty")!
        t.equal(empty.solidColor, RGBA(r: 1, g: 2, b: 3), "an empty value in the meter lets the MeterStyle apply")
        t.equal(empty.frame, SkinRect(x: 0, y: 40, width: 10, height: 7),
                "an empty value in a later style does not hide an earlier style's value")
        t.equal(empty.rawOption("SolidColor"), "1,2,3")
        t.equal(empty.rawOption("ToolTipText"), "", "an empty value no style defines stays an empty value")
        t.equal(empty.rawOption("Nothing"), nil)
        run(skin, "[!SetOption Empty ToolTipText \"\"]")
        t.equal(empty.rawOption("ToolTipText"), nil, "removed with !SetOption")
        run(skin, "[!SetOption Empty SolidColor 9,9,9]")
        skin.update()
        t.equal(empty.solidColor, RGBA(r: 9, g: 9, b: 9))
    }

    t.suite("Engine integration: MeasureName slots and tooltip %N") {
        let (skin, host, _) = try makeEngineSkin(t, """
        [M1]
        Measure=Calc
        Formula=2048

        [M2]
        Measure=String
        String=%2

        [Img]
        Meter=Image
        W=10
        H=10
        MeasureName=Missing
        MeasureName2=M1
        MeasureName3=M2
        ToolTipText=[%1][%2][%3][%4]
        ToolTipTitle=T %2
        DynamicVariables=1

        [Bar]
        Meter=Bar
        X=20
        W=10
        H=10
        MeasureName=M1
        MeasureName2=M1
        ToolTipText=%1/%2

        [Histo]
        Meter=Histogram
        X=40
        W=10
        H=10
        MeasureName=M1
        MeasureName2=M1
        MeasureName3=M1
        ToolTipText=%1/%2/%3

        [Label]
        Meter=String
        X=60
        MeasureName2=M1
        ToolTipText=%1|%2|%12
        """)
        for _ in 0..<5 { skin.update() }
        let img = skin.meter(named: "Img")!
        t.equal(img.measureSlots.count, 3)
        t.check(img.measureSlots[0] == nil && img.measureSlots[1] === skin.measure(named: "M1")
                && img.measureSlots[2] === skin.measure(named: "M2"), "slots are index-aligned")
        t.equal(img.measures.map(\.name), ["M1", "M2"], "measures lists the found ones")
        t.equal(img.toolTipInfo?.text, "[][2 k][%2][%4]",
                "a missing measure is empty, values are not substituted again, %4 is not bound")
        t.equal(img.toolTipInfo?.title, "T 2 k")
        t.equal(host.logs.filter { $0.contains("MeasureName=Missing not found") }.count, 1,
                "logged once, not on every update of a dynamic meter")
        t.equal(skin.meter(named: "Bar")?.toolTipInfo?.text, "2 k/%2", "other meters: %1 only")
        t.equal(skin.meter(named: "Histo")?.toolTipInfo?.text, "2 k/2 k/%3", "Histogram: %1 and %2")
        let label = skin.meter(named: "Label")!
        t.equal(label.measureSlots.count, 2)
        t.check(label.measureSlots[0] == nil)
        t.equal(label.toolTipInfo?.text, "|2 k|2", "%12 with two slots is %1 (missing: empty) followed by 2")
    }

    t.suite("Engine integration: number format options accept formulas") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Variables]
        D=2
        [S]
        Meter=String
        NumOfDecimals=(#D#+1)
        Scale=(1000.0)
        AutoScale=(2)
        Percentual=(1-1)
        [B]
        Meter=Bar
        AutoScale=1k
        Scale=1024
        NumOfDecimals=1.9
        Percentual=1
        [N]
        Meter=Image
        [Z]
        Meter=Image
        NumOfDecimals=(-5)
        AutoScale=(1/0)
        Scale=
        """)
        let s = skin.meter(named: "S")!.numberFormatOptions()
        t.equal(s.numOfDecimals, 3)
        t.close(s.scale, 1000)
        t.check(s.scaleHasDecimalPoint)
        t.equal(s.autoScale, .decimal(minimumPower: 0))
        t.check(!s.percentual)
        let b = skin.meter(named: "B")!.numberFormatOptions()
        t.equal(b.autoScale, .binary(minimumPower: 1))
        t.close(b.scale, 1024)
        t.check(!b.scaleHasDecimalPoint)
        t.equal(b.numOfDecimals, 1)
        t.check(b.percentual)
        t.equal(skin.meter(named: "N")!.numberFormatOptions(), NumberFormatOptions())
        let z = skin.meter(named: "Z")!.numberFormatOptions()
        t.equal(z.numOfDecimals, 0)
        t.equal(z.autoScale, .off)
        t.close(z.scale, 1)
        t.equal(Meter.autoScale(" (1) "), .binary(minimumPower: 0))
        t.equal(Meter.autoScale("2m"), .decimal(minimumPower: 2))
        t.equal(Meter.autoScale("(10**300)"), .off)
    }

    t.suite("Engine integration: image names without an extension get .png") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Rainmeter]
        Background=Back
        [Pic]
        Meter=Image
        ImageName=Pic
        [Plain]
        Meter=Image
        ImageName=Plain
        """, files: ["Root/Sub/Plain": "no extension", "Root/Sub/Dir/x.txt": "x"])
        skin.update()
        func p(_ relative: String) -> String { skin.absolutePath(relative) }
        t.equal(skin.imageFilePath("Pic", imagePath: ""), p("Pic.png"), "\"If no file extension is included, .png is assumed\"")
        t.equal(skin.imageFilePath("Plain", imagePath: ""), p("Plain"), "an existing file of exactly that name is used")
        t.equal(skin.imageFilePath("Dir", imagePath: ""), p("Dir.png"), "a folder is not an image")
        t.equal(skin.imageFilePath("a.jpg", imagePath: ""), p("a.jpg"))
        t.equal(skin.imageFilePath("Sub\\Pic", imagePath: ""), p("Sub/Pic.png"))
        t.equal(skin.imageFilePath("Folder/", imagePath: ""), p("Folder"), "a folder name is left alone")
        t.equal(skin.imageFilePath("Pic", imagePath: "#@#Images"), p("#@#Images/Pic.png"))
        t.equal(skin.imageFilePath("Pic", imagePath: skin.resourcesDirectory.path),
                skin.absolutePath(skin.resourcesDirectory.appendingPathComponent("Pic.png").path))
        t.equal(skin.settings.backgroundImage, p("Back.png"), "Background= benefits too")
        t.equal((skin.meter(named: "Pic") as? ImageMeter)?.imagePath, p("Pic.png"), "no double extension")
        t.equal((skin.meter(named: "Plain") as? ImageMeter)?.imagePath, p("Plain"),
                "an existing extensionless file is used as is (no .png added by the image options either)")
    }

    t.suite("Engine integration: OnWakeAction") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Rainmeter]
        OnWakeAction=[!SetVariable Woke "#Prefix#[M]"]
        [Variables]
        Prefix=w-
        [M]
        Measure=Calc
        Formula=M + 1
        """)
        t.equal(skin.settings.onWakeAction, "[!SetVariable Woke \"w-[M]\"]",
                "read as an action option: #Variables# now, [Section] variables when it runs")
        skin.update()
        skin.systemDidWake()
        skin.systemDidWake()
        skin.update()
        t.equal(skin.variable("Woke"), "w-2", "runs once, at the end of the first update after waking")
        skin.setVariable("Woke", "")
        skin.update()
        t.equal(skin.variable("Woke"), "")
        skin.close()
        skin.systemDidWake()
        skin.update()
        t.equal(skin.variable("Woke"), "", "a closed skin ignores the wake")
    }

}

// MARK: - Integration review

private func runEngineIntegrationReviewTests(_ t: TestRunner) {
    t.suite("Engine integration review: a Button's own mouse actions use its frame, ButtonCommand its pixels") {
        // Manual (Button): "ButtonCommand ignores transparent pixels in the image at all times, where
        // LeftMouseUpAction will only ignore clicks on transparent areas if there is not some other meter behind the
        // image" — the window lets clicks on fully transparent pixels through; inside the skin the frame counts.
        let host = AlphaHost()
        host.imageSizes = ["Btn.png": (60, 20), "Plain.png": (60, 20)]
        // Btn.png: the right half of every frame is transparent.
        host.alpha = { name, x, _ in name == "Btn.png" && x % 20 >= 10 ? 0 : 255 }
        let (skin, _, _) = try makeEngineSkin(t, """
        [Variables]
        Cmd=0

        [Back]
        Meter=Image
        W=100
        H=100
        SolidColor=0,0,0,1
        LeftMouseUpAction=[!SetVariable Hit back]
        ToolTipText=back tip

        [Btn]
        Meter=Button
        ButtonImage=Btn.png
        ButtonCommand=[!SetVariable Cmd "([#Cmd]+1)"]
        LeftMouseUpAction=[!SetVariable Hit button]
        MouseOverAction=[!SetVariable Over in]
        MouseLeaveAction=[!SetVariable Over out]
        ToolTipText=button tip

        [Down]
        Meter=Button
        Y=40
        ButtonImage=Btn.png
        ButtonCommand=[!SetVariable Cmd "([#Cmd]+100)"]
        LeftMouseDownAction=[!SetVariable Pressed down]
        """, host: host)
        skin.update()
        let btn = skin.meter(named: "Btn") as! ButtonMeter
        func hit(_ x: Double, _ y: Double) -> String? {
            skin.setVariable("Hit", "-")
            click(skin, x, y)
            return skin.variable("Hit")
        }

        t.equal(hit(15, 5), "button", "LeftMouseUpAction on a transparent pixel with a meter behind")
        t.equal(skin.variable("Cmd"), "0", "ButtonCommand ignores the transparent pixel")
        t.equal(btn.state, .normal)
        t.equal(hit(5, 5), "button")
        t.equal(skin.variable("Cmd"), "1", "an opaque pixel runs ButtonCommand and the action")
        t.equal(hit(80, 5), "back")
        t.equal(skin.toolTipInfo(at: 15, 5)?.text, "button tip", "the Button's tooltip covers its frame")
        skin.mouseMoved(x: 15, y: 5)
        t.equal(skin.variable("Over"), "in", "MouseOverAction on the frame")
        t.equal(btn.state, .normal, "but the hover frame only over opaque pixels")
        skin.mouseMoved(x: 5, y: 5)
        t.equal(btn.state, .hover)
        skin.mouseMoved(x: 80, y: 80)
        t.equal(skin.variable("Over"), "out")
        t.equal(btn.state, .normal)

        // LeftMouseDownAction in the transparent part: the action runs, the Button is not pressed, and a release on
        // its pixels does not count as a click.
        let down = skin.meter(named: "Down") as! ButtonMeter
        skin.mouseEvent(.leftDown, x: 15, y: 45)
        t.equal(skin.variable("Pressed"), "down")
        t.equal(down.state, .normal)
        skin.mouseEvent(.leftUp, x: 5, y: 45)
        t.equal(skin.variable("Cmd"), "1", "no ButtonCommand without a press on the button")
        skin.mouseEvent(.leftDown, x: 5, y: 45)
        t.equal(down.state, .pressed, "pressed on its pixels (with its own LeftMouseDownAction)")
        skin.mouseEvent(.leftUp, x: 5, y: 45)
        t.equal(skin.variable("Cmd"), "101")
        t.equal(down.state, .hover)
    }

    t.suite("Engine integration review: a captured Button hidden by its container runs nothing on release") {
        let host = AlphaHost()
        host.imageSizes = ["Btn.png": (60, 20)]
        let (skin, _, _) = try makeEngineSkin(t, """
        [Variables]
        Cmd=0

        [Box]
        Meter=Image
        W=15
        H=20

        [Btn]
        Meter=Button
        Container=Box
        ButtonImage=Btn.png
        ButtonCommand=[!SetVariable Cmd "([#Cmd]+1)"]
        """, host: host)
        skin.update()
        let btn = skin.meter(named: "Btn") as! ButtonMeter
        t.check(btn.isHit(x: 5, y: 5, precise: true) && !btn.isHit(x: 17, y: 5, precise: true),
                "the container masks the button")
        click(skin, 5, 5)
        t.equal(skin.variable("Cmd"), "1")
        click(skin, 17, 5)
        t.equal(skin.variable("Cmd"), "1", "no click outside the container")

        skin.mouseEvent(.leftDown, x: 5, y: 5)
        t.equal(btn.state, .pressed)
        skin.mouseEvent(.leftUp, x: 17, y: 5)
        t.equal(skin.variable("Cmd"), "1", "released on the masked part of the button: not a click")
        t.equal(btn.state, .normal)

        skin.mouseEvent(.leftDown, x: 5, y: 5)
        run(skin, "[!HideMeter Box]")
        skin.mouseEvent(.leftUp, x: 5, y: 5)
        t.equal(skin.variable("Cmd"), "1", "the container was hidden before the release")
        t.equal(btn.state, .normal)
        run(skin, "[!ShowMeter Box][!Redraw]")
        click(skin, 5, 5)
        t.equal(skin.variable("Cmd"), "2")
    }

    t.suite("Engine: MeasureRegistry and function section variables") {
        MeasureRegistry.registerPlugin("Plugins\\RegistryProbe.dll", RegistryProbeMeasure.self)
        MeasureRegistry.registerMeasure("ProbeType", RegistryProbeMeasure.self)
        let (skin, _) = try makeSkin(t, """
        [P1]
        Measure=Plugin
        Plugin=RegistryProbe
        [P2]
        Measure=ProbeType
        [M]
        Meter=String
        Text=[&P1:Double(21)]|[P2]|[&P1:Missing()]
        DynamicVariables=1
        """)
        skin.update()
        t.check(skin.measure(named: "P1") is RegistryProbeMeasure, "Plugin= resolved through the registry")
        t.check(skin.measure(named: "P2") is RegistryProbeMeasure, "Measure= resolved through the registry")
        t.equal(text(skin, "M"), "42|probe|[&P1:Missing()]")
        t.check(skin.issues.isEmpty, "registered types are not compatibility issues: \(skin.issues)")
    }
}

private final class RegistryProbeMeasure: Measure, SectionVariableFunctions {
    override func computeValue() -> Double {
        rawString = "probe"
        return 1
    }

    func sectionVariableFunction(_ call: String) -> String? {
        guard call.hasPrefix("Double("), call.hasSuffix(")"),
              let n = Double(call.dropFirst(7).dropLast()) else { return nil }
        return NumberFormatting.plain(n * 2)
    }
}

// MARK: - Compatibility round (real-world skins)

private func runEngineCompatTests(_ t: TestRunner) {
    t.suite("Engine compat: r / R after aligned strings follow the anchor") {
        // FakeHost: 7 pt per character, 14 pt per line.
        let (skin, _, _) = try makeEngineSkin(t, """
        [Shadow1]
        Meter=String
        X=100
        Y=50
        StringAlign=Right
        Text=abcd
        [Shadow2]
        Meter=String
        X=1r
        Y=1r
        StringAlign=Right
        Text=abcd
        [Centered]
        Meter=String
        X=0r
        Y=0R
        StringAlign=CenterCenter
        Text=ab
        [After]
        Meter=Image
        X=2R
        Y=3r
        W=5
        H=5
        [Label]
        Meter=String
        X=35
        Y=100
        W=25
        StringAlign=Right
        Text=CPU
        [Value]
        Meter=String
        X=9r
        Y=r
        Text=42
        [HiddenRight]
        Meter=String
        X=300
        Y=10
        StringAlign=Right
        Hidden=1
        Text=abc
        [AfterHidden]
        Meter=Image
        X=1R
        Y=1R
        W=1
        H=1
        [Report]
        Meter=String
        X=0
        Y=200
        Text=[Shadow2:X],[Shadow2:Y],[Centered:X],[Centered:Y]
        DynamicVariables=1
        """)
        skin.update()
        t.equal(frame(skin, "Shadow1"), SkinRect(x: 72, y: 50, width: 28, height: 14))
        t.equal(frame(skin, "Shadow2"), SkinRect(x: 73, y: 51, width: 28, height: 14),
                "a long-shadow copy is 1 px right / down of the previous copy (its anchor), not of its moved box")
        t.equal(frame(skin, "Centered"), SkinRect(x: 94, y: 58, width: 14, height: 14),
                "X=0r: the same anchor X; Y=0R: the previous anchor Y + its H")
        t.equal(frame(skin, "After"), SkinRect(x: 117, y: 68, width: 5, height: 5), "R = anchor + W, r = anchor")
        t.equal(frame(skin, "Label"), SkinRect(x: 10, y: 100, width: 25, height: 14))
        t.equal(frame(skin, "Value"), SkinRect(x: 44, y: 100, width: 14, height: 14),
                "a value 9 px right of a right-aligned label's X")
        t.equal(frame(skin, "AfterHidden"), SkinRect(x: 301, y: 11, width: 1, height: 1),
                "a hidden meter has no size and is not moved")
        t.equal(text(skin, "Report"), "73,51,94,58", "[Meter:X] / [Meter:Y] are the moved (real) box")
        let anchor = (skin.meter(named: "Centered") as? StringMeter)?.anchorPoint
        t.close(anchor?.x ?? -1, 101)
        t.close(anchor?.y ?? -1, 65)
    }

    t.suite("Engine compat: an empty String meter has no size unless its measure is unavailable on the Mac") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Empty]
        Measure=String
        String=
        [CoreTemp]
        Measure=Plugin
        Plugin=Plugins\\VendorSensors.dll
        SensorType=CpuName
        [Reg]
        Measure=Registry
        RegHKey=HKEY_LOCAL_MACHINE
        RegKey=SOFTWARE\\Vendor\\Tool
        RegValue=Missing
        [EmptyText]
        Meter=String
        X=0
        Y=10
        MeasureName=Empty
        [Row1]
        Meter=String
        Y=0R
        Text=ab
        [Unavailable]
        Meter=String
        X=0
        Y=40
        MeasureName=CoreTemp
        Text=%1
        [Row2]
        Meter=String
        Y=5R
        Text=ab
        [UnavailableRegistry]
        Meter=String
        X=0
        Y=80
        MeasureName=Reg
        [Row3]
        Meter=String
        Y=0R
        Text=ab
        [NoFont]
        Meter=String
        X=0
        Y=120
        MeasureName=CoreTemp
        FontSize=0
        """)
        skin.update()
        t.equal(frame(skin, "EmptyText"), SkinRect(x: 0, y: 10, width: 0, height: 0),
                "history 3.0: a string meter with an empty string has no width and height")
        t.equal(frame(skin, "Row1").y, 10)
        t.equal(frame(skin, "Unavailable"), SkinRect(x: 0, y: 40, width: 0, height: 14),
                "empty because the plugin has no value on the Mac: one line high, width 0")
        t.equal(frame(skin, "Row2").y, 59, "rows stacked with Y=5R keep their spacing")
        t.equal(frame(skin, "UnavailableRegistry"), SkinRect(x: 0, y: 80, width: 0, height: 14))
        t.equal(frame(skin, "Row3").y, 94)
        t.equal(frame(skin, "NoFont").height, 0, "FontSize=0 stays invisible and sizeless")
    }

    t.suite("Engine compat: former plugins in the plugin form are the built-in measures") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [User1]
        Measure=Plugin
        Plugin=SysInfo
        SysInfoType=USER_NAME
        [User2]
        Measure=Plugin
        Plugin=SysInfo.dll
        SysInfoType=USER_NAME
        [User3]
        Measure=Plugin
        Plugin=Plugins\\SysInfo.dll
        SysInfoType=USER_NAME
        [Proc]
        Measure=Plugin
        Plugin=Process.dll
        ProcessName=Finder.exe
        [Web]
        Measure=Plugin
        Plugin=Plugins\\WebParser.dll
        [Recycle]
        Measure=Plugin
        Plugin=RecycleManager.dll
        [Media]
        Measure=Plugin
        Plugin=MediaKey
        [WiFi]
        Measure=Plugin
        Plugin=WiFiStatus.dll
        [NotAPlugin]
        Measure=Plugin
        Plugin=Calc
        Formula=1+1
        [Show]
        Meter=String
        MeasureName=User1
        MeasureName2=User2
        MeasureName3=User3
        Text=%1 %2 %3
        """)
        skin.update()
        for name in ["User1", "User2", "User3"] {
            t.check(skin.measure(named: name) is SysInfoMeasure, "\(name) is a SysInfo measure")
        }
        t.equal(text(skin, "Show"), "tester tester tester")
        t.check(skin.measure(named: "Proc") is ProcessMeasure)
        t.close(value(skin, "Proc"), 1)
        t.check(skin.measure(named: "Web") is WebParserMeasure)
        // Without a module that provides them (plugins / media modules register them when present) these are the
        // engine's Windows-only fallback.
        for (section, plugin) in [("Recycle", "RecycleManager.dll"), ("Media", "MediaKey"), ("WiFi", "WiFiStatus.dll")] {
            let bare = MeasureRegistry.normalizedPluginName(plugin)
            if MeasureRegistry.plugin(named: plugin) == nil, MeasureRegistry.measure(named: bare) == nil {
                // App-side plugins (MediaKey, WiFiStatus) are registered by the app; core-only runs say so.
                t.check(skin.issues.contains("Plugin \"\(plugin)\" is provided by the Deskset app and is not available here"),
                        "\(skin.issues)")
            } else {
                t.check(!(skin.measure(named: section) is UnsupportedMeasure), "\(section): the registered measure")
            }
        }
        t.check(skin.measure(named: "NotAPlugin") is UnsupportedMeasure, "Plugin=Calc is not the Calc measure")
        t.check(!skin.issues.contains { $0.contains("SysInfo") || $0.contains("Process") || $0.contains("WebParser") },
                "\(skin.issues)")
        t.equal(Skin.formerPluginMeasures, ["sysinfo", "process", "webparser", "recyclemanager", "mediakey",
                                            "nowplaying", "wifistatus"])
    }

    t.suite("Engine compat: compatibility notes list only Mac differences") {
        let (skin, host, _) = try makeEngineSkin(t, """
        [Rainmeter]
        OnRefreshAction=[!UnknownBang][!SetWallpaper x.png]
        [Typo]
        Measure=Clac
        [Media]
        Measure=Plugin
        Plugin=Plugins\\VendorAudio.dll
        [NoPlugin]
        Measure=Plugin
        [BadMeter]
        Meter=Strng
        [Styled]
        Meter=String
        MeterStyle=NoSuchStyle
        [Content]
        Meter=String
        Container=Nowhere
        """)
        skin.update()
        skin.update()
        t.equal(Set(skin.issues), ["Plugin \"Plugins\\VendorAudio.dll\" is a Windows plugin and is not supported"],
                "only the measure that works differently on the Mac")
        t.check(skin.measure(named: "Media")?.valueUnavailable == true)
        t.check(skin.measure(named: "Typo")?.valueUnavailable == false, "a typo is not missing Mac data")
        t.check(skin.measure(named: "NoPlugin")?.valueUnavailable == false)
        for fragment in ["Measure=Clac is not a valid measure type", "Meter=Strng is not a valid meter type",
                         "Measure=Plugin without a Plugin option", "\"NoSuchStyle\"", "Container=Nowhere",
                         "Unknown bang: !unknownbang"] {
            t.equal(host.logs.filter { $0.contains(fragment) }.count, 1, "logged once: \(fragment)")
        }
    }

    t.suite("Engine compat: section variables without DynamicVariables are resolved when the options are read") {
        // Skins known to work in Rainmeter rely on it (HDD_Usage_Bars `X=[MeterDiskIcon:X]`, confirmed by its author's
        // screenshot; Mini Weather `X=([Icon:X] + [Icon:W] / 2)`); the value is not kept up to date without
        // DynamicVariables=1. Mac timing: the first update's read, after the measures and the meters above.
        let (skin, _, _) = try makeEngineSkin(t, """
        [Greeting]
        Measure=String
        String=Hello
        [User]
        Measure=SysInfo
        SysInfoType=USER_NAME
        [Count]
        Measure=Calc
        Formula=Count + 1
        [Joined]
        Measure=String
        String=[Greeting] world
        [Icon]
        Meter=Image
        X=12
        Y=4
        W=50
        H=10
        [Centered]
        Meter=String
        StringAlign=Center
        X=([Icon:X] + [Icon:W] / 2)
        Y=([Icon:Y] + 20)
        Text=x
        [Static]
        Meter=String
        MeasureName=Greeting
        Postfix=, [User]!
        [Frozen]
        Meter=String
        Text=[Count]
        [Dynamic]
        Meter=String
        Text=[Count]
        DynamicVariables=1
        [Plain]
        Meter=String
        Text=[NotASection] stays
        [Bang]
        Meter=String
        Text=none
        """)
        t.check(skin.meter(named: "Frozen")?.needsOptionRead == true, "read again at the first update")
        t.check(skin.meter(named: "Plain")?.needsOptionRead == false, "no section variable: not read again")
        t.check(skin.measure(named: "Count")?.needsOptionRead == false)
        skin.update()
        t.equal(text(skin, "Static"), "Hello, tester!")
        t.equal(text(skin, "Frozen"), "1")
        t.equal(text(skin, "Dynamic"), "1")
        t.equal(text(skin, "Plain"), "[NotASection] stays")
        t.equal(skin.measure(named: "Joined")?.stringValue, "Hello world")
        t.equal(skin.meter(named: "Centered")?.anchorX, 37, "[Icon:X] + [Icon:W] / 2")
        t.equal(skin.meter(named: "Centered")?.anchorY, 24)
        skin.update()
        t.equal(text(skin, "Frozen"), "1", "not kept up to date without DynamicVariables")
        t.equal(text(skin, "Dynamic"), "2")
        // "!SetOption … the meter or measure that is being changed is automatically made dynamic for one update".
        run(skin, "[!SetOption Frozen FontSize 12][!UpdateMeter Frozen]")
        t.equal(text(skin, "Frozen"), "2")
        run(skin, "[!SetOption Bang Text \"[User]\"][!UpdateMeter Bang]")
        t.equal(text(skin, "Bang"), "tester", "section variables in bangs are always resolved")
    }

    t.suite("Engine compat: Registry measure emulates common Windows keys") {
        let facts = RegistryMeasure.Facts(productName: "macOS Tahoe", version: "26.5", fullVersion: "26.5.1",
                                          majorVersion: 26, minorVersion: 5, patchVersion: 1, build: "25F71",
                                          processorName: "Apple M9", architecture: "arm64", processorCount: 12,
                                          processorMHz: 0, userFullName: "Jane Doe", userName: "jane",
                                          computerName: "Jane's Mac", homeDirectory: "/Users/jane")
        func v(_ hive: String, _ key: String, _ value: String) -> RegistryMeasure.Value? {
            RegistryMeasure.emulatedValue(hive: hive, key: key, value: value, facts: facts)
        }
        let cv = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion"
        t.equal(v("HKEY_LOCAL_MACHINE", cv, "ProductName"), .string("macOS Tahoe"))
        t.equal(v("HKLM", cv.lowercased(), "productname"), .string("macOS Tahoe"), "names are case-insensitive")
        t.equal(v("HKEY_LOCAL_MACHINE", cv + "\\", "CurrentVersion"), .string("26.5"))
        t.equal(v("HKEY_LOCAL_MACHINE", cv, "CurrentBuild"), .string("25F71"))
        t.equal(v("HKEY_LOCAL_MACHINE", cv, "CurrentBuildNumber"), .string("25F71"))
        t.equal(v("HKEY_LOCAL_MACHINE", cv, "DisplayVersion"), .string("26.5.1"))
        t.equal(v("HKEY_LOCAL_MACHINE", cv, "ReleaseId"), .string("26.5.1"))
        t.equal(v("HKEY_LOCAL_MACHINE", cv, "CurrentMajorVersionNumber"), .number(26))
        t.equal(v("HKEY_LOCAL_MACHINE", cv, "UBR"), .number(1))
        t.equal(v("HKEY_LOCAL_MACHINE", cv, "RegisteredOwner"), .string("Jane Doe"))
        t.equal(v("HKEY_LOCAL_MACHINE", "SOFTWARE\\WOW6432Node\\Microsoft\\Windows NT\\CurrentVersion", "ProductName"),
                .string("macOS Tahoe"), "the 32-bit view reads the same")
        t.equal(v("HKEY_LOCAL_MACHINE", cv + "\\WinSat", "PrimaryAdapterString"), .string("Apple M9"),
                "Apple silicon: the GPU is part of the chip")
        var intel = facts
        intel.processorName = "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz"
        intel.graphicsName = "AMD Radeon Pro 5500M"
        t.equal(RegistryMeasure.emulatedValue(hive: "HKLM", key: cv + "\\WinSat", value: "PrimaryAdapterString",
                                              facts: intel), .string("AMD Radeon Pro 5500M"),
                "Intel: the graphics processor the data source names")
        intel.graphicsName = ""
        t.equal(RegistryMeasure.emulatedValue(hive: "HKLM", key: cv + "\\WinSat", value: "PrimaryAdapterString",
                                              facts: intel), nil, "Intel, graphics processor unknown: no value")
        let cpu = "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0"
        t.equal(v("HKEY_LOCAL_MACHINE", cpu, "ProcessorNameString"), .string("Apple M9"))
        t.equal(v("HKEY_LOCAL_MACHINE", "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\11", "~MHz"), .number(0))
        t.equal(v("HKEY_LOCAL_MACHINE", "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\12", "~MHz"), nil,
                "no such processor")
        let env = "SYSTEM\\ControlSet001\\Control\\Session Manager\\Environment"
        t.equal(v("HKEY_LOCAL_MACHINE", env, "NUMBER_OF_PROCESSORS"), .string("12"))
        t.equal(v("HKEY_LOCAL_MACHINE", env, "PROCESSOR_ARCHITECTURE"), .string("ARM64"))
        t.equal(v("HKEY_LOCAL_MACHINE", env, "PROCESSOR_IDENTIFIER"), .string("Apple M9"))
        t.equal(v("HKEY_CURRENT_USER", "Volatile Environment", "USERNAME"), .string("jane"))
        t.equal(v("HKEY_CURRENT_USER", "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Shell Folders",
                  "Personal"), .string("/Users/jane/Documents"))
        t.equal(v("HKEY_CURRENT_USER", cv, "ProductName"), nil, "HKCU has no CurrentVersion values")
        t.equal(v("HKEY_BOGUS", cv, "ProductName"), nil)
        t.equal(v("HKEY_LOCAL_MACHINE", "SYSTEM\\ControlSet001\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}\\0000",
                  "HardwareInformation.qwMemorySize"), nil, "video memory is not emulated")

        let (skin, _, _) = try makeEngineSkin(t, """
        [Product]
        Measure=Registry
        RegHKey=HKEY_LOCAL_MACHINE
        RegKey=SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion
        RegValue=ProductName
        UpdateDivider=-1
        [Cores]
        Measure=Registry
        RegHKey=HKEY_LOCAL_MACHINE
        RegKey=SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment
        RegValue=NUMBER_OF_PROCESSORS
        [Major]
        Measure=Registry
        RegHKey=HKEY_LOCAL_MACHINE
        RegKey=SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion
        RegValue=CurrentMajorVersionNumber
        [Values]
        Measure=Registry
        RegHKey=HKEY_LOCAL_MACHINE
        RegKey=SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment
        OutputType=ValueList
        OutputDelimiter=|
        [Wallpaper]
        Measure=Registry
        RegKey=Control Panel\\Desktop
        RegValue=Wallpaper
        [Show]
        Meter=String
        MeasureName=Product
        MeasureName2=Major
        Text=Version: %1 (%2)
        """)
        skin.update()
        skin.update()
        let product = string(skin, "Product")
        t.check(product.hasPrefix("macOS"), "the product name is a macOS name: \(product)")
        let major = Double(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        t.close(value(skin, "Major"), major)
        t.equal(text(skin, "Show"), "Version: \(product) (\(Int(major)))", "numbers have no string of their own")
        t.check(value(skin, "Cores") >= 1, "a numeric string is also the number")
        t.equal(string(skin, "Values"), "NUMBER_OF_PROCESSORS|PROCESSOR_ARCHITECTURE|PROCESSOR_IDENTIFIER")
        t.equal(string(skin, "Wallpaper"), "")
        t.check(skin.measure(named: "Wallpaper")?.valueUnavailable == true)
        t.check(skin.measure(named: "Product")?.valueUnavailable == false)
        t.equal(skin.issues.filter { $0.hasPrefix("Registry value") }.count, 1, "\(skin.issues)")
        t.check(skin.issues.contains { $0.contains("HKCU\\Control Panel\\Desktop\\Wallpaper") })
    }

    t.suite("Engine compat: bound measures use their MeasureName slot") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [A]
        Measure=String
        String=%2
        [B]
        Measure=String
        String=q
        [Full]
        Measure=Calc
        Formula=1
        [Bar]
        Meter=Bar
        MeasureName=Nope
        MeasureName2=Full
        W=10
        H=10
        [Pic]
        Meter=Image
        MeasureName=A
        MeasureName2=B
        ImageName=%1-%2.png
        [Gap]
        Meter=Image
        MeasureName=Nope
        MeasureName2=B
        ImageName=x%1y%2
        [Plain]
        Meter=Image
        MeasureName=Nope
        MeasureName2=B
        ImageName=Fallback
        [Round]
        Meter=Roundline
        MeasureName=Nope
        MeasureName2=Full
        W=10
        H=10
        """)
        skin.update()
        t.close((skin.meter(named: "Bar") as? BarMeter)?.fraction ?? -1, 0, "MeasureName names no measure: empty bar")
        func file(_ meter: String) -> String? {
            ((skin.meter(named: meter) as? ImageMeter)?.imagePath as NSString?)?.lastPathComponent
        }
        t.equal(file("Pic"), "%2-q.png", "%N is replaced in one pass")
        t.equal(file("Gap"), "xyq.png", "%1 is MeasureName even when it names no measure")
        t.equal(file("Plain"), "Fallback.png", "without a placeholder only MeasureName replaces ImageName")
        t.close((skin.meter(named: "Round") as? RoundlineMeter)?.fraction ?? -1, 1, "no measure in slot 1: 100%")
    }

    t.suite("Engine compat: a Button with a cleared mouse action handles the event itself") {
        let host = AlphaHost()
        host.imageSizes = ["Btn.png": (60, 20)]
        let (skin, _, _) = try makeEngineSkin(t, """
        [Variables]
        Cmd=0
        [Btn]
        Meter=Button
        ButtonImage=Btn.png
        ButtonCommand=[!SetVariable Cmd "([#Cmd]+1)"]
        LeftMouseUpAction=[!SetVariable Up yes]
        """, host: host)
        skin.update()
        let btn = skin.meter(named: "Btn") as! ButtonMeter
        run(skin, "[!ClearMouseAction Btn \"LeftMouseUpAction\"]")
        t.check(btn.handleMouse(.leftDown, x: 5, y: 5), "no LeftMouseDownAction: consumed")
        t.check(btn.handleMouse(.leftUp, x: 5, y: 5), "the cleared LeftMouseUpAction does not count")
        t.equal(skin.variable("Cmd"), "1")
        run(skin, "[!DisableMouseAction Btn \"LeftMouseUpAction\"]")
        t.check(btn.handleMouse(.leftDown, x: 5, y: 5))
        t.check(!btn.handleMouse(.leftUp, x: 5, y: 5), "a disabled action still catches the event")
        t.equal(skin.variable("Up"), nil)
    }

    t.suite("Engine compat: String meter number options accept formulas") {
        let (skin, _, _) = try makeEngineSkin(t, """
        [Variables]
        Mode=1
        [Big]
        Measure=Calc
        Formula=2048
        [Plain]
        Meter=String
        MeasureName=Big
        AutoScale=1
        [Formula]
        Meter=String
        MeasureName=Big
        AutoScale=(#Mode#)
        NumOfDecimals=(#Mode# + 1)
        [Decimals]
        Meter=String
        MeasureName=Big
        AutoScale=1
        NumOfDecimals=2
        """)
        skin.update()
        t.check(text(skin, "Plain") != "2048", text(skin, "Plain"))
        t.equal(text(skin, "Formula"), text(skin, "Decimals"), "AutoScale=(#Mode#) is AutoScale=1")
    }

    t.suite("Engine compat: BackgroundMode=0 sizes the window with the background's image options") {
        let host = FakeHost()
        host.imageSizes = ["Back.png": (100, 50)]
        let (cropped, _, _) = try makeEngineSkin(t, """
        [Rainmeter]
        Background=Back.png
        BackgroundMode=0
        ImageCrop=10,10,40,30
        """, host: host)
        cropped.update()
        t.close(cropped.width, 40)
        t.close(cropped.height, 30)
        t.equal(cropped.settings.backgroundImageOptions.crop?.width, 40)
        let (rotated, _, _) = try makeEngineSkin(t, """
        [Rainmeter]
        Background=Back.png
        ImageRotate=90
        """, host: host)
        rotated.update()
        t.close(rotated.width, 50)
        t.close(rotated.height, 100)
    }

    t.suite("Engine compat: a !Redraw during the first update does not size the window early") {
        // EasyInfo: an IfAboveAction with [!Redraw] runs while the measures of the first update are updating.
        let (skin, host, _) = try makeEngineSkin(t, """
        [Blink]
        Measure=Calc
        Formula=1
        IfAboveValue=0
        IfAboveAction=[!SetOption Text FontSize 10][!Redraw]
        IfCondition=Blink = 1
        IfTrueAction=[!UpdateMeter *][!Redraw]
        [Text]
        Meter=String
        Text=abcdef
        [Below]
        Meter=Image
        Y=0R
        W=3
        H=3
        """)
        skin.layout()
        t.close(skin.width, 0, "no size before the first update")
        skin.update()
        t.close(skin.width, 42, "sized from the updated meters")
        t.close(skin.height, 17)
        host.textSizer = { text, _, _ in (Double(text.count) * 20, 30) }
        skin.update()
        t.close(skin.width, 42, "then kept (no DynamicWindowSize)")
    }

    t.suite("Engine compat: TestSkins/Engine/Compat fixtures") {
        let testSkins = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("TestSkins")
        func load(_ file: String) throws -> (Skin, FakeHost) {
            let host = FakeHost()
            let url = testSkins.appendingPathComponent("Engine/Compat").appendingPathComponent(file)
            let skin = Skin(config: "Engine\\Compat", fileURL: url, skinsDirectory: testSkins,
                            system: EngineTestSystem(), host: host)
            retainedEngineHosts.append(host)
            try skin.load()
            skin.update()
            return (skin, host)
        }
        let (anchors, anchorsHost) = try load("Anchors.ini")
        t.equal(anchors.issues, [])
        t.check(anchorsHost.logs.filter { $0.hasPrefix("Error") || $0.hasPrefix("Warning") }.isEmpty,
                "\(anchorsHost.logs)")
        let base = anchors.meter(named: "ShadowBase")!, top = anchors.meter(named: "Shadow6")!
        t.close(top.frame.maxX - base.frame.maxX, 5, "each shadow copy 1 px right of the previous anchor")
        t.close(top.frame.y - base.frame.y, 5)
        t.equal(anchors.meter(named: "LedFront")!.frame.x + anchors.meter(named: "LedFront")!.frame.width / 2,
                anchors.meter(named: "LedBack")!.frame.x + anchors.meter(named: "LedBack")!.frame.width / 2,
                "the text is centered on the backlight's anchor")
        t.close(anchors.meter(named: "ValueA")!.frame.x, 78, "value 8 px right of the label's X")
        t.close(anchors.meter(named: "Pill2")!.frame.x, 220, "back to the pill's X from the caption's anchor")
        t.close(anchors.meter(named: "Pill2")!.frame.y, 128 + 15 + 14 + 8, "below the caption's anchor + H")

        let (rows, _) = try load("EmptyRows.ini")
        t.equal(rows.meter(named: "Value2")!.frame.height, 14, "no data on the Mac: one line")
        t.equal(rows.meter(named: "Value3")!.frame.height, 14)
        t.equal(rows.meter(named: "Value4")!.frame.height, 0, "empty in Rainmeter too: no size")
        t.close(rows.meter(named: "Title5")!.frame.y, rows.meter(named: "Title4")!.frame.y + 6)

        let (legacy, legacyHost) = try load("Legacy.ini")
        t.equal(legacy.issues, [], "no compatibility notes for the legacy forms")
        t.check(!legacyHost.logs.contains { $0.contains("Shape") }, "\(legacyHost.logs)")
        t.check(legacy.measure(named: "MeasureHost") is SysInfoMeasure)
        t.check(legacy.measure(named: "MeasureFinder") is ProcessMeasure)
        t.check(text(legacy, "Line1").hasPrefix("tester on "))
        t.check(text(legacy, "Line2").hasPrefix("macOS"), text(legacy, "Line2"))
        t.check((legacy.meter(named: "HourHand") as? RoundlineMeter)?.options.valueRemainder == 43_200)
        t.equal((legacy.meter(named: "Card") as? ShapeMeter)?.shapes.count, 1)

        let (vars, varsHost) = try load("SectionVars.ini")
        t.equal(vars.issues, [])
        t.check(varsHost.logs.filter { $0.hasPrefix("Error") || $0.hasPrefix("Warning") }.isEmpty, "\(varsHost.logs)")
        t.equal(vars.meter(named: "Tile2")?.frame.x, 160, "150 px right of the hidden ring at [Tile1:X]")
        t.equal(vars.meter(named: "Tile3")?.frame.x, 310, "three tiles in a row, not two stacked")
        t.equal(vars.meter(named: "Caption")?.anchorX, 70, "centered under the square")
        t.equal(vars.meter(named: "Caption")?.anchorY, 124)
        t.equal(text(vars, "Greeting"), "Hello, tester!")
        t.check(!text(vars, "FrozenSecond").contains("["), text(vars, "FrozenSecond"))
    }

    t.suite("Engine compat: fontsDidChange measures text again and resizes a fixed-size window") {
        let host = FakeHost()
        let (skin, _, _) = try makeEngineSkin(t, """
        [Text]
        Meter=String
        Text=abcd
        """, host: host)
        skin.fontsDidChange()
        t.close(skin.width, 0, "before the first update: nothing measured, the window size is not fixed early")
        skin.update()
        t.close(skin.width, 28)
        host.textSizer = { text, _, _ in (Double(text.count) * 10, 20) }
        skin.update()
        t.close(skin.width, 28, "without DynamicWindowSize the window keeps its first size")
        let redraws = host.redraws
        skin.fontsDidChange()
        t.close(skin.width, 40, "a font that appeared later: measured again, window resized once")
        t.close(skin.height, 20)
        t.check(host.redraws > redraws)
        skin.close()
        skin.fontsDidChange()
    }
}
