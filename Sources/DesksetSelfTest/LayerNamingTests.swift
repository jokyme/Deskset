import Foundation
@testable import DesksetCore

/// Names of layers and live data (`LayerNaming`, docs/editor-friendly.md §6), the runs of repeated layers and data
/// (`LayerSeries`, §5.2) and the reorder guard (`LayerReorder`, §5.2). Suites: "Editor: layer names …",
/// "Editor: layer series …", "Editor: reorder guard …" (WP-A).
func runLayerNamingTests(_ t: TestRunner) {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// TestSkins/Audio/Visualizer as a skin of its own. AudioLevel is an app plugin (not here): its values are set by
    /// hand — 48.23634 Hz and 13268.00443 Hz at the band edges, `device` as the output device — and kept (paused).
    func visualizer(device: String = "MacBook Pro扬声器") throws -> Skin {
        let ini = try String(contentsOf: repository.appendingPathComponent("TestSkins/Audio/Visualizer/Visualizer.ini"),
                             encoding: .utf8)
        let (skin, _) = try makeSkin(t, ini)
        skin.update()
        for (name, value) in [("MeasureLowFreq", 48.23634), ("MeasureHighFreq", 13268.00443)] {
            guard let m = skin.measure(named: name) else { continue }
            m.value = value
            m.rawString = nil
            m.paused = true
        }
        if let m = skin.measure(named: "MeasureDevice") {
            m.rawString = device
            m.paused = true
        }
        skin.update()
        return skin
    }

    t.suite("Editor: layer names — the humanised section name is the fallback") {
        let h = LayerNaming.humanized
        t.equal(h("MeterLeftLabel"), "Left label")
        t.equal(h("MeterCPUValue"), "CPU value")
        t.equal(h("MeasureBand5"), "Band 5")
        t.equal(h("MeterPeakX"), "Peak X")
        t.equal(h("Meter_Top_Bar"), "Top bar")
        t.equal(h("Meteorite"), "Meteorite", "a word that only starts like the prefix keeps it")
        t.equal(h("Meter"), "Meter")
        t.equal(h("Measure2"), "2")
        t.equal(h("时钟"), "时钟")
        t.equal(LayerNaming.humanizedFile("#@#Images/clock-face.png"), "Clock face")
        t.equal(LayerNaming.humanizedFile("Backgrounds\\DarkPanel.png"), "Dark panel")
        // A path that starts with a variable names the file, not the variable (no "#@#" in the default UI, §3.3).
        t.equal(LayerNaming.humanizedFile("#@#dot.png"), "Dot")
        t.equal(LayerNaming.fileName("#@#dot.png"), "dot.png")
        t.equal(LayerNaming.fileName("#ROOTCONFIGPATH#Images\\face.png"), "face.png")
        t.equal(LayerNaming.inSentence("Lowest band frequency"), "lowest band frequency")
        t.equal(LayerNaming.inSentence("CPU usage"), "CPU usage")
        t.equal(LayerNaming.inSentence("Wi-Fi signal"), "Wi-Fi signal")
        t.equal(LayerNaming.quoted("A text much longer than twenty-eight characters"), "“A text much longer than twen…”")
        t.equal(LayerNaming.quoted("Two\nlines"), "“Two lines”")

        let (skin, _) = try makeSkin(t, """
            [Rainmeter]
            [MeterLeftLabel]
            Meter=String
            Text=L
            [MeterPeak]
            Meter=Image
            SolidColor=255,255,255
            W=2
            H=27
            [MeterButton]
            Meter=Button
            [MeasureBand5]
            Measure=Calc
            Formula=1
            """)
        skin.update()
        guard let label = skin.meter(named: "MeterLeftLabel"), let peak = skin.meter(named: "MeterPeak"),
              let button = skin.meter(named: "MeterButton"), let band = skin.measure(named: "MeasureBand5") else {
            return t.check(false, "the sections load")
        }
        t.equal(LayerNaming.layer(label, in: skin),
                LayerName(title: "“L”", subtitle: "Text", sentence: "Text that says “L”.", symbol: "textformat"))
        t.equal(LayerNaming.layer(peak, in: skin).title, "Color block", "a color block that follows nothing")
        t.equal(LayerNaming.layer(peak, in: skin).sentence, "A 2 × 27 white block.")
        t.equal(LayerNaming.layer(button, in: skin),
                LayerName(title: "Button", subtitle: "Button", sentence: "Button.", symbol: "hand.tap"),
                "the fallback: the humanised section name")
        t.equal(LayerNaming.data(band, in: skin).name, "Calculated number")
    }

    t.suite("Editor: layer names on the Visualizer") {
        let skin = try visualizer()
        func layer(_ name: String) -> LayerName? { skin.meter(named: name).map { LayerNaming.layer($0, in: skin) } }
        func data(_ name: String) -> DataName? { skin.measure(named: name).map { LayerNaming.data($0, in: skin) } }

        t.equal(layer("MeterTitle"), LayerName(title: "“Audio”", subtitle: "Text", sentence: "Text that says “Audio”.",
                                               symbol: "textformat"))
        t.equal(layer("MeterLeftLabel")?.title, "“L”")
        t.equal(layer("MeterRightLabel")?.title, "“R”")
        t.equal(layer("MeterLowFreq"), LayerName(title: "“48 Hz”", subtitle: "Text · lowest band frequency",
                                                 sentence: "Text showing the lowest band frequency, written as “48 Hz”.",
                                                 symbol: "textformat"))
        t.equal(layer("MeterHighFreq")?.title, "“13268 Hz”")
        t.equal(layer("MeterHighFreq")?.subtitle, "Text · highest band frequency")
        t.equal(layer("MeterDevice")?.title, "“MacBook Pro扬声器”")
        t.equal(layer("MeterDevice")?.subtitle, "Text · output device name")
        t.equal(layer("MeterLeft"), LayerName(title: "Left channel bar", subtitle: "Bar · left channel level",
                                              sentence: "Bar showing the left channel level, filling to the right.",
                                              symbol: "chart.bar.fill"))
        t.equal(layer("MeterRight")?.title, "Right channel bar")
        t.equal(layer("MeterPeak"), LayerName(title: "Peak marker", subtitle: "Color block · moves with peak level",
                                              sentence: "A 2 × 27 white block that moves with the peak level.",
                                              symbol: "photo"))
        t.equal(LayerNaming.background(in: skin), "MeterBackground", "the full-size shape drawn first")
        t.equal(layer("MeterBackground"), LayerName(title: "Background", subtitle: "Rounded rectangle · whole widget",
                                                    sentence: "Rounded rectangle, 217 × 196, behind everything.",
                                                    symbol: "square.on.circle"))
        // Repeated bars: named by their place in the run, 1-based.
        t.equal(layer("MeterBand5"), LayerName(title: "Bar 6", subtitle: "Sound band 6 of 16",
                                               sentence: "Bar showing sound band 6 of 16, filling upward.",
                                               symbol: "chart.bar.fill"))
        t.equal(layer("MeterBand0")?.subtitle, "Sound band 1 of 16 (lowest)")
        t.equal(layer("MeterBand15")?.subtitle, "Sound band 16 of 16 (highest)")
        let bars = LayerSeries.detect(in: skin).first { $0.kind == .layers }
        t.equal(bars.map { LayerNaming.series($0, in: skin) },
                LayerName(title: "16 bars", subtitle: "Bar · sound bands 1–16",
                          sentence: "16 bars showing sound bands 1–16, low to high.", symbol: "chart.bar.fill"))

        t.equal(data("MeasureAudio"), DataName(name: "Sound from your Mac", short: "Sound", subtitle: "What your Mac plays"))
        t.equal(data("MeasureBand5"), DataName(name: "Sound band 6", short: "Band 6", subtitle: ""))
        t.equal(data("MeasureBand0")?.name, "Sound band 1", "bands count from 1")
        t.equal(data("MeasureLeft"), DataName(name: "Left channel level", short: "Left channel", subtitle: ""))
        t.equal(data("MeasureRight")?.name, "Right channel level")
        t.equal(data("MeasurePeak")?.name, "Peak level")
        t.equal(data("MeasureDevice")?.name, "Output device name")
        t.equal(data("MeasureLowFreq")?.name, "Lowest band frequency")
        t.equal(data("MeasureHighFreq")?.name, "Highest band frequency")
        t.equal(data("MeasurePeakX")?.name, "Peak marker position", "a formula that only places one layer")
        let bands = LayerSeries.detect(in: skin).first { $0.kind == .data }
        t.equal(bands.map { LayerNaming.dataSeries($0, in: skin) },
                DataName(name: "16 sound bands", short: "Sound bands", subtitle: ""))

        // Who uses what.
        t.equal(LayerNaming.users(ofData: "MeasurePeakX", in: skin), DataUsers(layers: ["MeterPeak"]))
        t.equal(LayerNaming.users(ofData: "MeasurePeak", in: skin), DataUsers(data: ["MeasurePeakX"]))
        t.equal(LayerNaming.users(ofData: "MeasureBand5", in: skin), DataUsers(layers: ["MeterBand5"]))
        t.equal(LayerNaming.users(ofData: "MeasureAudio", in: skin).data.count, 22, "the children of the parent")
        t.equal(skin.meter(named: "MeterPeak").flatMap { LayerNaming.followedData(of: $0, in: skin)?.name }, "MeasurePeak")

        // The catalog names everything at once, the same way.
        let catalog = LayerNaming.catalog(of: skin)
        t.equal(catalog.layer("meterlowfreq"), layer("MeterLowFreq"))
        t.equal(catalog.data("MeasurePeakX")?.name, "Peak marker position")
        t.equal(catalog.background, "MeterBackground")
        t.equal(catalog.series(containing: "MeterBand7")?.members.count, 16)
        t.equal(bars.flatMap { catalog.name(of: $0)?.title }, "16 bars")
        t.equal(bands.flatMap { catalog.dataName(of: $0)?.name }, "16 sound bands")
        t.equal(catalog.users(ofData: "MeasureLeft"), DataUsers(layers: ["MeterLeft"]))
        // No title is a section name (G1).
        let sections = Set(skin.meters.map { $0.name.lowercased() } + skin.measures.map { $0.name.lowercased() })
        t.equal(skin.meters.filter { sections.contains(catalog.layer($0.name)?.title.lowercased() ?? "") }.map(\.name), [])

        // A text showing data that is empty says so.
        let silent = try visualizer(device: "")
        t.equal(silent.meter(named: "MeterDevice").map { LayerNaming.layer($0, in: silent).title },
                "Output device name (empty)")
    }

    t.suite("Editor: layer names for each kind of data and layer") {
        let (skin, _) = try makeSkin(t, """
            [Rainmeter]
            [MeasureCPU]
            Measure=CPU
            [MeasureCore2]
            Measure=CPU
            Processor=2
            [MeasureRAM]
            Measure=PhysicalMemory
            [MeasureRAMTotal]
            Measure=PhysicalMemory
            Total=1
            [MeasureSwap]
            Measure=SwapMemory
            [MeasureDown]
            Measure=NetIn
            [MeasureUp]
            Measure=NetOut
            [MeasureNet]
            Measure=NetTotal
            [MeasureUsed]
            Measure=FreeDiskSpace
            Drive=/Volumes/Data
            InvertMeasure=1
            [MeasureClock]
            Measure=Time
            Format=%H:%M
            [MeasureDate]
            Measure=Time
            Format=%B %#d, %Y
            [MeasureUp2]
            Measure=Uptime
            [MeasureBattery]
            Measure=Plugin
            Plugin=PowerPlugin
            PowerState=Percent
            [MeasureDice]
            Measure=Calc
            Formula=Random
            [MeasureHalf]
            Measure=Calc
            Formula=MeasureCPU / 2
            [MeasureLoop]
            Measure=Loop
            [MeasureWords]
            Measure=String
            String=Hello
            [MeasureWeb]
            Measure=WebParser
            URL=https://www.example.com/feed
            [MeterGraph]
            Meter=Line
            MeasureName=MeasureCPU
            W=40
            H=20
            [MeterBars]
            Meter=Histogram
            MeasureName=MeasureCPU
            W=40
            H=20
            [MeterGauge]
            Meter=Roundline
            MeasureName=MeasureCPU
            W=40
            H=40
            [MeterEmpty]
            Meter=Bar
            W=40
            H=4
            [MeterFace]
            Meter=Image
            ImageName=#@#Images/clock-face.png
            W=120
            H=120
            [MeterRAMShape]
            Meter=Shape
            Shape=Rectangle 0,0,20,4 | Fill Color 255,0,0
            Shape2=Rectangle 0,0,([MeasureRAM:%] / 5),4 | Fill Color 0,0,255
            DynamicVariables=1
            [MeterPair]
            Meter=Shape
            Shape=Ellipse 5,5,5
            Shape2=Ellipse 20,5,5
            [MeterDot]
            Meter=Shape
            Shape=Ellipse 5,5,5
            [MeterCPUText]
            Meter=String
            MeasureName=MeasureCPU
            Text=%1%
            """)
        skin.update()
        func data(_ name: String) -> String? { skin.measure(named: name).map { LayerNaming.data($0, in: skin).name } }
        func short(_ name: String) -> String? { skin.measure(named: name).map { LayerNaming.data($0, in: skin).short } }
        func layer(_ name: String) -> LayerName? { skin.meter(named: name).map { LayerNaming.layer($0, in: skin) } }
        t.equal(data("MeasureCPU"), "CPU usage")
        t.equal(short("MeasureCPU"), "CPU")
        t.equal(data("MeasureCore2"), "CPU core 2 usage")
        t.equal(short("MeasureCore2"), "Core 2")
        t.equal(data("MeasureRAM"), "Memory used")
        t.equal(data("MeasureRAMTotal"), "Total memory")
        t.equal(data("MeasureSwap"), "Memory and swap used", "SwapMemory counts the memory too")
        t.equal(short("MeasureSwap"), "Memory + swap")
        t.equal(data("MeasureDown"), "Download speed")
        t.equal(data("MeasureUp"), "Upload speed")
        t.equal(data("MeasureNet"), "Network speed")
        t.equal(data("MeasureUsed"), "Used space on Data")
        t.equal(data("MeasureClock"), "Hours and minutes", "what the format shows, not an example moment")
        t.equal(data("MeasureDate"), "Date")
        t.equal(data("MeasureUp2"), "Time since startup")
        t.equal(data("MeasureBattery"), "Battery level")
        t.equal(data("MeasureDice"), "Random number")
        t.equal(data("MeasureHalf"), "Calculated from CPU usage")
        t.equal(data("MeasureLoop"), "Counting number")
        t.equal(data("MeasureWords"), "Fixed text")
        t.equal(data("MeasureWeb"), "Text from example.com")

        t.equal(layer("MeterGraph")?.title, "CPU graph")
        t.equal(layer("MeterGraph")?.sentence, "Line graph showing the CPU usage.")
        t.equal(layer("MeterBars")?.title, "CPU bar graph")
        t.equal(layer("MeterGauge")?.title, "CPU gauge")
        t.equal(layer("MeterEmpty"), LayerName(title: "Bar", subtitle: "Bar · not showing anything yet",
                                               sentence: "Bar that isn't showing anything yet.", symbol: "chart.bar.fill"))
        t.equal(layer("MeterFace"), LayerName(title: "Clock face", subtitle: "Picture",
                                              sentence: "Picture “clock-face.png”, 120 × 120.", symbol: "photo"))
        t.equal(layer("MeterRAMShape")?.title, "Memory bar", "a rectangle whose length follows the data")
        t.equal(layer("MeterRAMShape")?.subtitle, "Shape · memory used")
        t.equal(layer("MeterPair")?.title, "2 shapes")
        t.equal(layer("MeterDot")?.title, "Circle")
        t.equal(layer("MeterCPUText")?.subtitle, "Text · CPU usage")
        t.equal(LayerNaming.background(in: skin), nil, "nothing covers the widget")
        t.equal(LayerNaming.colorName(RGBA(r: 120, g: 200, b: 255)), "blue")
        t.equal(LayerNaming.colorName(RGBA(r: 16, g: 19, b: 28)), "black")
        t.equal(LayerNaming.colorName(RGBA(r: 150, g: 158, b: 175)), "gray")
    }

    t.suite("Editor: layer names — memory, swap and formulas say what they count") {
        let (skin, _) = try makeSkin(t, """
            [Rainmeter]
            [MeasureRAM]
            Measure=PhysicalMemory
            [MeasureRAMTotal]
            Measure=PhysicalMemory
            Total=1
            [MeasureVirtual]
            Measure=SwapMemory
            [MeasureVirtualTotal]
            Measure=SwapMemory
            Total=1
            [MeasureVirtualFree]
            Measure=SwapMemory
            InvertMeasure=1
            [MeasureWindows]
            Measure=Memory
            [MeasureSwapTotal]
            Measure=Calc
            Formula=Max(MeasureVirtualTotal - MeasureRAMTotal, 0)
            [MeasureSwap]
            Measure=Calc
            Formula=Clamp(MeasureVirtual - MeasureRAM, 0, MeasureSwapTotal)
            [MeasureMixed]
            Measure=Calc
            Formula=MeasureVirtualTotal - MeasureRAM
            [MeasureSum]
            Measure=Calc
            Formula=MeasureVirtual + MeasureRAM
            [MeasureTick]
            Measure=Calc
            Formula=(MeasureTick + 1) % 10
            [MeterLabel]
            Meter=String
            Text=Swap
            Y=10
            W=100
            H=20
            [MeterSwapBar]
            Meter=Shape
            Shape=Rectangle 0,0,([MeasureSwap:%] / 5),4 | Fill Color 0,0,255
            DynamicVariables=1
            """)
        skin.update()
        func data(_ name: String) -> DataName? { skin.measure(named: name).map { LayerNaming.data($0, in: skin) } }
        t.equal(data("MeasureVirtual"), DataName(name: "Memory and swap used", short: "Memory + swap", subtitle: ""))
        t.equal(data("MeasureVirtualTotal")?.name, "Total memory and swap")
        t.equal(data("MeasureVirtualFree")?.name, "Memory and swap free")
        t.equal(data("MeasureWindows")?.name, "Memory used (Windows-style)", "the memory counted twice, plus the swap")
        // Memory and swap − memory is the swap itself.
        t.equal(data("MeasureSwapTotal"), DataName(name: "Total swap", short: "Swap", subtitle: ""))
        t.equal(data("MeasureSwap")?.name, "Swap used")
        t.equal(skin.meter(named: "MeterSwapBar").map { LayerNaming.layer($0, in: skin).title }, "Swap bar")
        t.equal(data("MeasureMixed")?.name, "Calculated from total memory and swap", "a total minus a used amount")
        t.equal(data("MeasureSum")?.name, "Calculated from memory and swap used", "a sum is not the swap")
        t.equal(data("MeasureTick")?.name, "Counting number", "a formula that counts on its own value")
    }

    t.suite("Editor: layer names — data used by actions is used") {
        // Data a click, the widget or its own condition acts on is in use, though no layer shows it.
        let (skin, _) = try makeSkin(t, """
            [Rainmeter]
            OnRefreshAction=[!EnableMeasure MeasureSlow]
            [Variables]
            Next=[!CommandMeasure MeasureOther "Next"]
            Shown=[MeasureShown]
            [MeasurePlayer]
            Measure=String
            String=Song
            [MeasureOther]
            Measure=String
            String=Other
            [MeasureShown]
            Measure=String
            String=Shown
            [MeasureCounter]
            Measure=Calc
            Formula=(MeasureCounter + 1) % 10
            IfCondition=MeasureCounter = 5
            IfTrueAction=[!SetOption MeterText FontColor 255,0,0][!UpdateMeasure MeasureUpdated][!Redraw]
            [MeasureSlow]
            Measure=Time
            Format=%H:%M
            Disabled=1
            [MeasureUpdated]
            Measure=Calc
            Formula=1
            [MeasureElsewhere]
            Measure=Calc
            Formula=2
            [MeasureSpare]
            Measure=Calc
            Formula=3
            [MeterText]
            Meter=String
            Text=Hello
            LeftMouseUpAction=[!CommandMeasure MeasurePlayer "PlayPause"]
            [MeterNext]
            Meter=String
            Text=Next
            Y=4R
            LeftMouseUpAction=[!CommandMeasure "MeasurePlayer" "Next"][!DisableMeasure MeasureElsewhere "Other\\Config"]
            """)
        skin.update()
        let catalog = LayerNaming.catalog(of: skin)
        t.equal(catalog.users(ofData: "MeasurePlayer"), DataUsers(layers: ["MeterText", "MeterNext"]),
                "!CommandMeasure in click actions")
        t.equal(catalog.users(ofData: "MeasureCounter"), DataUsers(runsActions: true), "its own IfTrueAction")
        t.equal(catalog.users(ofData: "MeasureSlow"), DataUsers(widget: true), "turned on when the widget opens")
        t.equal(catalog.users(ofData: "MeasureOther"), DataUsers(widget: true), "a variable holding an action")
        t.equal(catalog.users(ofData: "MeasureShown"), DataUsers(widget: true), "a variable reading it")
        t.equal(catalog.users(ofData: "MeasureUpdated"), DataUsers(data: ["MeasureCounter"]), "another data's action")
        t.check(catalog.users(ofData: "MeasureElsewhere").isEmpty, "a bang aimed at another widget")
        t.check(catalog.users(ofData: "MeasureSpare").isEmpty, "nothing uses it")
        t.check(!catalog.users(ofData: "MeasureCounter").isEmpty && !catalog.users(ofData: "MeasureSlow").isEmpty)
    }

    t.suite("Editor: layer names — a block moved by its own counter") {
        let (skin, _) = try makeSkin(t, """
            [Rainmeter]
            [MeasureScroll]
            Measure=Calc
            Formula=(MeasureScroll+1)%100
            [MeasureFixed]
            Measure=Calc
            Formula=5 * 2
            [MeterBg]
            Meter=Image
            SolidColor=20,20,20,255
            W=200
            H=100
            [MeterDot]
            Meter=Image
            SolidColor=255,0,0
            W=4
            H=4
            X=[MeasureScroll]
            DynamicVariables=1
            [MeterStill]
            Meter=Image
            SolidColor=0,0,255
            W=4
            H=4
            X=[MeasureFixed]
            Y=20
            DynamicVariables=1
            """)
        skin.update()
        for first in ["layer", "data"] {
            // Named in either order (the catalog names layers first; a single question may ask the data first).
            let dot = skin.meter(named: "MeterDot")!, scroll = skin.measure(named: "MeasureScroll")!
            let namer = LayerNamer(skin: skin)
            if first == "data" { _ = namer.data(scroll) }
            t.equal(namer.layer(dot), LayerName(title: "Moving block", subtitle: "Color block · moves on its own",
                                                sentence: "A 4 × 4 red block that moves on its own.", symbol: "photo"),
                    "\(first) first")
            t.equal(namer.data(scroll).name, "Moving block position", "\(first) first")
        }
        t.equal(skin.meter(named: "MeterStill").map { LayerNaming.layer($0, in: skin).title }, "Color block",
                "a fixed number does not move it")
    }

    t.suite("Editor: layer series") {
        let skin = try visualizer()
        let series = LayerSeries.detect(in: skin)
        t.equal(series.filter { $0.kind == .layers }.map(\.members), [(0...15).map { "MeterBand\($0)" }],
                "exactly one run of layers: the 16 bands")
        t.equal(series.filter { $0.kind == .data }.map(\.members), [(0...15).map { "MeasureBand\($0)" }],
                "and one run of data")
        t.equal(series.first?.index(of: "meterband5"), 5)

        func runs(_ ini: String) throws -> [[String]] {
            let (skin, _) = try makeSkin(t, "[Rainmeter]\n" + ini)
            skin.update()
            return LayerSeries.detect(in: skin).filter { $0.kind == .layers }.map(\.members)
        }
        func bar(_ name: String, _ extra: String = "") -> String { "[\(name)]\nMeter=Bar\nW=4\nH=4\n\(extra)\n" }
        t.equal(try runs(bar("B1") + bar("B2") + bar("B3")), [["B1", "B2", "B3"]])
        t.equal(try runs(bar("B1") + bar("B2")), [], "fewer than 3")
        t.equal(try runs(bar("B1") + bar("B2") + bar("B3", "MeterStyle=Other") + bar("B4")), [],
                "a changed look breaks the run")
        t.equal(try runs(bar("B1") + bar("B2") + "[B3]\nMeter=Image\nW=4\nH=4\n" + bar("B4") + bar("B5") + bar("B6")),
                [["B4", "B5", "B6"]], "a changed type breaks the run")
        t.equal(try runs(bar("B1") + bar("B2") + bar("B4") + bar("B5")), [], "a gap in the numbers breaks the run")
        t.equal(try runs(bar("B1") + bar("B2") + "[Label]\nMeter=String\nText=x\n" + bar("B3")), [],
                "a layer in between breaks the run")
        t.equal(try runs(bar("B1") + bar("B2") + bar("B3") + bar("C4") + bar("C5") + bar("C6")),
                [["B1", "B2", "B3"], ["C4", "C5", "C6"]], "another name starts another run")
        t.equal(try runs("[S1]\n[S2]\n[S3]\n" + bar("CPU1", "MeterStyle=S1") + bar("CPU2", "MeterStyle=S2")
                         + bar("CPU3", "MeterStyle=S3")), [], "CPU1, CPU2, CPU3 with different looks")
        t.equal(try runs("[Box]\nMeter=Image\nW=40\nH=40\n" + bar("B1", "Container=Box") + bar("B2", "Container=Box")
                         + bar("B3", "Container=Box")), [], "not in a container")
    }

    t.suite("Editor: reorder guard") {
        let skin = try visualizer()
        let before = Dictionary(uniqueKeysWithValues: skin.meters.map { ($0.name, $0.frame) })

        // "13268 Hz" is placed "Y=0r": under "48 Hz". Moving "48 Hz" to the front gives it a fixed Y.
        let edits = LayerReorder.fixups(skin: skin, moving: ["MeterLowFreq"], to: nil)
        t.equal(edits, [LayerReorder.Edit(section: "MeterHighFreq", key: "Y", value: "136")])
        for e in edits { _ = try skin.writeOwnOption(section: e.section, key: e.key, value: e.value) }
        _ = try skin.moveSection("MeterLowFreq", before: nil)
        let moved = Skin(config: skin.config, fileURL: skin.fileURL, skinsDirectory: skin.skinsDirectory,
                         system: FakeSystem(), host: reorderHost)
        try moved.load()
        moved.update()
        for name in ["MeasureLowFreq", "MeasureHighFreq", "MeasureDevice"] {
            moved.measure(named: name)?.value = skin.measure(named: name)?.value ?? 0
            moved.measure(named: name)?.rawString = skin.measure(named: name)?.rawString
            moved.measure(named: name)?.paused = true
        }
        moved.update()
        t.equal(moved.meters.last?.name, "MeterLowFreq", "in front")
        t.equal(moved.meters.filter { before[$0.name] != $0.frame }.map(\.name), [], "every frame is unchanged")

        // A run moved as one block keeps its chain; a bar moved alone takes and leaves a fixed X.
        let fresh = try visualizer()
        let bands = (0...15).map { "MeterBand\($0)" }
        t.equal(LayerReorder.fixups(skin: fresh, moving: bands, to: nil), [], "the whole run: nothing to fix")
        t.equal(LayerReorder.fixups(skin: fresh, moving: ["MeterBand5"], to: nil),
                [LayerReorder.Edit(section: "MeterBand5", key: "X", value: "74"),
                 LayerReorder.Edit(section: "MeterBand6", key: "X", value: "86")])
        t.equal(LayerReorder.fixups(skin: fresh, moving: ["MeterTitle"], to: "MeterTitle"), [], "no move")
        t.equal(LayerReorder.order(of: ["A", "B", "C", "D"], moving: ["B", "C"], before: nil), ["A", "D", "B", "C"])
        t.equal(LayerReorder.order(of: ["A", "B", "C", "D"], moving: ["D"], before: "B"), ["A", "D", "B", "C"])

        // A position that reads another layer is fixed when the two change places.
        let (linked, _) = try makeSkin(t, """
            [Rainmeter]
            [Base]
            Meter=Image
            SolidColor=0,0,0
            X=10
            W=30
            H=10
            [Follower]
            Meter=Image
            SolidColor=0,0,0
            X=([Base:X] + 40)
            W=10
            H=10
            DynamicVariables=1
            [Other]
            Meter=Image
            SolidColor=0,0,0
            X=100
            W=10
            H=10
            """)
        linked.update()
        t.equal(LayerReorder.fixups(skin: linked, moving: ["Base"], to: nil),
                [LayerReorder.Edit(section: "Follower", key: "X", value: "50")])
        t.equal(LayerReorder.fixups(skin: linked, moving: ["Other"], to: "Base"), [], "their order stays")
    }
}

/// The host of the skin reloaded by the reorder guard test (`Skin.host` is weak).
private let reorderHost = FakeHost()
