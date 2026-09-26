import Foundation
@testable import DesksetCore

/// Names found by the friendliness review (docs/editor-friendly.md §6 and §8.1.1): time data named by its format,
/// data chosen by a setting counted as used, formula chains and runs of data never named after section names or
/// themselves, pictures from live data, layers that share a name told apart, colour roles that say what they paint;
/// and what naming a big widget costs (section lookups, one walk for the widgets reading a shared file), and the
/// encoding an edited ANSI file is saved in. Suites: "Editor: friendly names …", "Ini: …".
func runFriendlyNamesTests(_ t: TestRunner) {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    func load(_ folder: String, _ config: String) throws -> Skin {
        let skins = repo.appendingPathComponent(folder)
        let parts = config.split(separator: "\\").map(String.init)
        let skin = Skin(config: config, fileURL: skins.appendingPathComponent(parts.joined(separator: "/"))
                            .appendingPathComponent("\(parts.last ?? "").ini"),
                        skinsDirectory: skins, system: FakeSystem(), host: FakeHost())
        try skin.load()
        skin.update()
        return skin
    }

    t.suite("Editor: friendly names — time data is named by what its format shows") {
        func name(_ format: String) -> String { LayerNaming.timeName(format: format).name }
        t.equal(name("%H:%M"), "Hours and minutes")
        t.equal(name("%#I:%M"), "Hours and minutes (12-hour)")
        t.equal(name("%H:%M:%S"), "Time with seconds")
        t.equal(name("%S"), "Seconds", "not \"Time (09)\"")
        t.equal(name("%M"), "Minutes")
        t.equal(name("%A"), "Weekday")
        t.equal(name("%a"), "Weekday")
        t.equal(name("%V"), "Week number")
        t.equal(name("%p"), "AM/PM")
        t.equal(name("%m"), "Month number", "not \"Time (09)\" either")
        t.equal(name("%B"), "Month name")
        t.equal(name("%#d"), "Day of the month")
        t.equal(name("%Y"), "Year")
        t.equal(name("%B %Y"), "Month and year")
        t.equal(name("%B %#d, %Y"), "Date")
        t.equal(name("%Y-%m-%d %H:%M"), "Date and time")
        t.equal(name("%T"), "Time with seconds", "%T stands for %H:%M:%S")
        t.equal(name("100%%"), "Time", "no codes")
        t.equal(LayerNaming.timeName(format: "%S").short, "Seconds")
    }

    t.suite("Editor: friendly names — Clock: data a setting chooses is used, and named by its format") {
        let skin = try load("DefaultSkins", "Deskset\\Clock")
        let catalog = LayerNaming.catalog(of: skin)
        for (data, layer) in [("MeasureTime24", "MeterTime"), ("MeasureTime12", "MeterTime"),
                              ("MeasureSuffix24", "MeterSuffix"), ("MeasureSuffix12", "MeterSuffix")] {
            t.equal(catalog.users(ofData: data).layers, [layer], "\(data): MeasureName=…#ClockHours# can choose it")
        }
        t.equal(catalog.data("MeasureTime24")?.name, "Hours and minutes")
        t.equal(catalog.data("MeasureTime12")?.name, "Hours and minutes (12-hour)")
        t.equal(catalog.data("MeasureSeconds")?.name, "Seconds")
        t.equal(catalog.data("MeasureWeekday")?.name, "Weekday")
        t.equal(catalog.data("MeasureDate")?.name, "Date")
        t.equal(catalog.data("MeasureWeek")?.name, "Week number", "a formula that is only another data item")
        t.equal(catalog.layer("MeterMinute")?.title, "Seconds progress line")
        t.equal(catalog.layer("MeterSuffix")?.title, "AM/PM (empty)", "24-hour mode chose the empty data")
        for m in skin.measures {
            t.check(!(catalog.data(m.name)?.name ?? "").contains("Time ("), "\(m.name): no frozen example")
        }
    }

    t.suite("Editor: friendly names — formula chains and runs of data in the default widgets") {
        for config in ["Deskset\\Calendar", "Deskset\\Clock", "Deskset\\System", "Deskset\\Disk", "Deskset\\Battery",
                       "Deskset\\Network"] {
            let skin = try load("DefaultSkins", config)
            let catalog = LayerNaming.catalog(of: skin)
            for m in skin.measures {
                let name = catalog.data(m.name)?.name ?? ""
                t.check(!name.lowercased().contains("calculated from calculated"), "\(config) \(m.name): \(name)")
            }
            for s in catalog.series where s.kind == .data {
                let name = catalog.dataName(of: s)?.name ?? ""
                t.check(!name.contains("×"), "\(config): \(name) is not named after its sections")
            }
        }
        let calendar = try load("DefaultSkins", "Deskset\\Calendar")
        let catalog = LayerNaming.catalog(of: calendar)
        let heads = catalog.series(containing: "MeasureHead0").flatMap(catalog.dataName(of:))
        t.equal(heads?.name, "7 weekdays")
        t.equal(catalog.data("MeasureHead2")?.name, "Weekday 3", "members numbered from 1, never all the same")
        let cells = catalog.series(containing: "MeasureCell0").flatMap(catalog.dataName(of:))
        t.equal(cells?.name, "42 calculated numbers")
        t.equal(catalog.data("MeasureCell7")?.name, "Calculated number 8")
        t.equal(catalog.data("MeasureTitle")?.name, "Month and year")
        // The calendar's formulas, each once "Calculated from month number": told apart by their own words.
        t.equal(catalog.data("MeasureLeapYear")?.name, "Leap year")
        t.equal(catalog.data("MeasureFirstWeekday")?.name, "First weekday")
        t.check(catalog.data("MeasureFirstWeekday")?.subtitle.hasPrefix("Calculated") == true, "what it is, second")
        let names = calendar.measures.filter { catalog.series(containing: $0.name) == nil }.compactMap { catalog.data($0.name)?.name }
        t.equal(Set(names).count, names.count, "no two rows share a name: \(names)")
        let disk = try load("DefaultSkins", "Deskset\\Disk")
        t.check(LayerNaming.catalog(of: disk).data("MeasurePercent")?.name.hasSuffix(" as %") == true,
                "used / total * 100 is a percentage, not \"calculated from\" the size")
    }

    t.suite("Editor: friendly names — pictures from live data, players, Wi-Fi and web pages") {
        let (skin, _) = try makeSkin(t, """
            [Rainmeter]
            [MeasureCover]
            Measure=Plugin
            Plugin=NowPlaying
            PlayerType=Cover
            [MeasureYear]
            Measure=Plugin
            Plugin=NowPlaying
            PlayerType=Year
            [MeasureVolume]
            Measure=Plugin
            Plugin=NowPlaying
            PlayerType=Volume
            [MeasureShuffle]
            Measure=Plugin
            Plugin=NowPlaying
            PlayerType=Shuffle
            [MeasureSpeed]
            Measure=Plugin
            Plugin=WiFiStatus
            WiFiInfoType=TXRATE
            [MeasureNetworks]
            Measure=Plugin
            Plugin=WiFiStatus
            WiFiInfoType=LIST
            [MeasureFeed]
            Measure=WebParser
            URL=file:///tmp/feed.xml
            [MeasureItem]
            Measure=WebParser
            URL=[MeasureFeed]
            StringIndex=2
            [MeterCover]
            Meter=Image
            MeasureName=MeasureCover
            W=72
            H=72
            [MeterSong]
            Meter=String
            Text=Song
            X=80
            W=120
            H=20
            """)
        skin.update()
        let catalog = LayerNaming.catalog(of: skin)
        t.equal(catalog.data("MeasureYear")?.name, "Song year")
        t.equal(catalog.data("MeasureVolume")?.name, "Player volume")
        t.equal(catalog.data("MeasureShuffle")?.name, "Shuffle")
        t.equal(catalog.data("MeasureSpeed")?.name, "Wi-Fi send speed")
        t.equal(catalog.data("MeasureNetworks")?.name, "Nearby Wi-Fi networks")
        t.equal(catalog.data("MeasureFeed")?.name, "Text from feed.xml", "a file, not \"a web page\"")
        t.equal(catalog.data("MeasureItem")?.name, "Value 2 from feed.xml")
        guard let cover = skin.meter(named: "MeterCover") else { return t.check(false, "the cover loads") }
        t.equal(LayerNaming.kindNoun(cover), "Picture", "not a color block: its picture comes from live data")
        t.equal(catalog.layer("MeterCover")?.title, "Album cover")
        t.equal(catalog.layer("MeterCover")?.sentence, "Picture showing the album cover, 72 × 72.")
    }

    t.suite("Editor: friendly names — layers that share a name are told apart") {
        let clock = try load("TestSkins", "Round\\AnalogClock")
        let catalog = LayerNaming.catalog(of: clock)
        t.equal(catalog.layer("MeterHourHand")?.title, "Hour hand")
        t.equal(catalog.layer("MeterMinuteHand")?.title, "Minute hand")
        t.equal(catalog.layer("Tick12")?.title, "Tick 12")
        t.equal(catalog.layer("MeterFace")?.title, "Face")
        t.equal(catalog.layer("MeterFace")?.subtitle, "Gauge · fixed shape", "a disc drawn without data isn't waiting for any")
        let titles = clock.meters.compactMap { catalog.layer($0.name)?.title }
        t.equal(Set(titles).count, titles.count, "every row title differs: \(titles)")
        let (skin, _) = try makeSkin(t, """
            [Rainmeter]
            [MeasureCPU]
            Measure=CPU
            [Meter1]
            Meter=Line
            MeasureName=MeasureCPU
            W=40
            H=20
            [MeterLine]
            Meter=Line
            MeasureName=MeasureCPU
            Y=30
            W=40
            H=20
            [MeterBlock]
            Meter=Image
            SolidColor=255,0,0
            Y=60
            W=10
            H=10
            """)
        skin.update()
        let named = LayerNaming.catalog(of: skin)
        t.equal(named.layer("Meter1")?.title, "CPU graph 1", "section names that say nothing: numbered")
        t.equal(named.layer("MeterLine")?.title, "CPU graph 2")
        t.equal(named.layer("MeterBlock")?.subtitle, "Color block · 10 × 10", "never the title again")
    }

    t.suite("Editor: friendly names — colour roles say what they paint") {
        let system = try load("DefaultSkins", "Deskset\\System")
        let index = system.valueUsages()
        t.equal(index.variable("PanelBorderHover")?.role, "Background panel outline when pointed at",
                "what the hover action colors, not \"Widget when pointed at\"")
        t.equal(index.variable("PanelBorder")?.role, "Background panel outline", "leaving puts the usual color back")
        t.equal(index.variable("TrackColor")?.role, "Empty part of bars", "the grey tracks under the memory and swap bars")
        t.equal(index.variable("PanelHighlight")?.role, "Background panel line", "a line's stroke is the line, not an outline")
        let names = index.colorGroups().map(\.name)
        t.equal(Set(names).count, names.count, "every row has its own name: \(names)")
        t.check(index.variable("SubtleColor")?.roles.contains { $0.name == "Dimmed parts of texts" } == true,
                "the grey \" / 16 GB\": \(index.variable("SubtleColor")?.roles ?? [])")
        let battery = try load("DefaultSkins", "Deskset\\Battery")
        t.equal(battery.valueUsages().variable("CriticalColor")?.role, "Battery bar in some states")
        for config in ["Deskset\\System", "Deskset\\Clock", "Deskset\\Battery", "Deskset\\Calendar", "Deskset\\Network"] {
            let skin = try load("DefaultSkins", config)
            for value in skin.valueUsages().values {
                for role in value.roles {
                    t.check(!role.name.contains("Widget when") && !role.name.contains("(live data)")
                            && !role.name.contains("fade start") && !role.name.contains("wi-Fi"),
                            "\(config) \(value.source): \(role.name)")
                }
            }
        }
    }

    t.suite("Editor: friendly names — a big widget is named without a pause") {
        var ini = "[Rainmeter]\n[Variables]\nColor=200,100,50\n"
        for i in 0..<300 {
            ini += "[MeasureC\(i)]\nMeasure=Calc\nFormula=MeasureC\(max(i - 1, 0)) + \(i)\n"
            ini += "[MeterT\(i)]\nMeter=String\nMeasureName=MeasureC\(i)\nFontColor=#Color#\nY=\(i * 12)\n"
                + "SolidColor=\(i % 255),0,0\n"
        }
        let (skin, _) = try makeSkin(t, ini)
        skin.update()
        let start = Date()
        let index = skin.valueUsages()
        _ = LayerNaming.catalog(of: skin)
        let seconds = Date().timeIntervalSince(start)
        t.equal(index.variable("Color")?.sections.count, 300)
        t.check(seconds < 2, "300 layers and 300 data items named in \(seconds) s")
    }

    t.suite("Ini: section lookups by name follow every change") {
        var doc = IniDocument.parse("[A]\nk=1\n[b]\nk=2\n")
        t.equal(doc.indexOfSection(named: "B"), 1, "case-insensitive")
        doc.sections.insert(IniSection(name: "New"), at: 0)
        t.equal(doc.indexOfSection(named: "a"), 1, "an insert moves the others")
        t.equal(doc.indexOfSection(named: "new"), 0)
        let copy = doc
        doc.sections[0].name = "Renamed"
        t.equal(doc.indexOfSection(named: "new"), nil)
        t.equal(doc.indexOfSection(named: "renamed"), 0)
        t.equal(copy.indexOfSection(named: "new"), 0, "a copy keeps its own sections")
        t.equal(doc == copy, false)
        t.equal(IniDocument(sections: [IniSection(name: "X"), IniSection(name: "x")]).indexOfSection(named: "X"), 0,
                "the first of two with one name")
    }

    t.suite("Editor: friendly names — one walk finds the widgets reading each shared file") {
        let skin = try load("DefaultSkins", "Deskset\\System")
        let map = skin.includeMap()
        let variables = skin.resourcesDirectory.appendingPathComponent("Variables.inc")
        let readers = map.configs(including: variables)
        t.check(readers.contains("deskset\\system") && readers.contains("deskset\\clock"), "\(readers)")
        t.equal(skin.configsIncluding(variables), readers)
        t.equal(map.configs(including: skin.fileURL), [], "nothing includes a widget's own .ini")
    }

    t.suite("Ini: an edited ANSI file that can't hold the new text is saved as UTF-16 with a BOM") {
        let dir = t.temporaryDirectory("encoding")
        let url = dir.appendingPathComponent("Skin.ini")
        try Data("[Variables]\r\n@Include=#@#Theme.inc\r\nFont=Caf\u{E9}\r\n".utf8).write(to: url)
        // As Windows-1252 bytes: é is one byte.
        try (TextDecoding.encode("[Variables]\r\n@Include=#@#Theme.inc\r\nFont=Caf\u{E9}\r\n", as: .windows1252) ?? Data())
            .write(to: url)
        try IniWriter.writeAfterIncludes("ヒラギノ角ゴ", key: "Font", section: "Variables", fileURL: url)
        let bytes = [UInt8](try Data(contentsOf: url).prefix(2))
        t.equal(bytes, [0xFF, 0xFE], "UTF-16 LE with BOM, as IniWriter.writeValue saves it")
        t.equal(try TextDecoding.readFileDetectingEncoding(at: url).text.contains("Font=ヒラギノ角ゴ"), true)
        t.equal(TextDecoding.encodeForWriting("abc", preferring: .windows1252), Data("abc".utf8), "its own encoding when it can")
    }
}
