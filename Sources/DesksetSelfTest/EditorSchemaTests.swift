import Foundation
@testable import DesksetCore

func runEditorSchemaV2Tests(_ t: TestRunner) {
    typealias S = EditorSchema

    /// Every group the schema describes, with a name for messages.
    func allGroups() -> [(String, [S.Group])] {
        var result: [(String, [S.Group])] = S.meterTypes.map { ("Meter=\($0)", S.meterGroups($0)) }
        for m in S.measureTypes {
            result.append(("Measure \(m.name)", m.isPlugin ? S.measureGroups("Plugin", plugin: m.name) : S.measureGroups(m.name)))
        }
        result.append(("[Rainmeter]", S.skinGroups))
        result.append(("[Metadata]", [S.aboutGroup]))
        return result
    }

    t.suite("EditorSchema: every meter type the engine draws has groups") {
        t.equal(S.meterTypes.count, 10)
        for type in S.meterTypes {
            let groups = S.meterGroups(type)
            t.check(groups.count >= 3, "\(type): groups")
            t.equal(S.meterGroups(type.uppercased()), groups, "\(type): case-insensitive")
            // The engine really draws the type (not the placeholder for unknown types).
            let (skin, _) = try makeSkin(t, "[Rainmeter]\n[M]\nMeter=\(type)\n")
            t.check(skin.meters.first.map { !($0 is UnsupportedMeter) } == true, "\(type) is drawn by the engine")
        }
        t.equal(S.meterGroups("Nonsense"), [])
        t.equal(S.meterGroups("string").map(\.title), ["Shows", "Text", "Box Behind It", "When Clicked", "Layer"])
        t.equal(S.meterGroups("image").map(\.title), ["Picture", "Box Behind It", "When Clicked", "Layer"])
        t.equal(S.meterGroups("button").map(\.title), ["Button", "Box Behind It", "When Clicked", "Layer"])
        t.equal(S.meterGroups("bar").first?.properties.first?.key, "MeasureName", "what it shows first for data-driven meters")
        t.equal(S.meterGroups("shape").first?.properties.map(\.kind), [.shapes])
    }

    t.suite("EditorSchema: no key twice, choices are consistent") {
        for (name, groups) in allGroups() {
            var seen: Set<String> = []
            for g in groups {
                t.check(!g.properties.isEmpty, "\(name): group \(g.title) is empty")
                for p in g.properties {
                    for key in [p.key] + p.legacyKeys {
                        t.check(seen.insert(key.lowercased()).inserted, "\(name): \(key) twice")
                    }
                    t.check(!p.label.isEmpty, "\(name): \(p.key) has a label")
                    guard let choices = p.kind.choices else { continue }
                    let values = choices.map { $0.value.lowercased() }
                    t.equal(values.count, Set(values).count, "\(name): \(p.key) values unique")
                    if !p.defaultValue.isEmpty {
                        t.check(S.choice(for: p.defaultValue, in: choices) != nil,
                                "\(name): default \(p.defaultValue) of \(p.key) is one of the choices")
                    }
                    for c in choices where !c.supportedOnMac { t.check(!c.note.isEmpty, "\(name): \(c.value) says why") }
                }
                // Conditions refer to options of the same section.
                for p in g.properties {
                    for c in p.visibleWhen + p.defaultWhen.flatMap(\.when) {
                        t.check(S.property(c.key, in: groups) != nil, "\(name): \(p.key) depends on \(c.key), which is listed")
                    }
                    if let choices = p.kind.choices {
                        for d in p.defaultWhen {
                            t.check(S.choice(for: d.value, in: choices) != nil, "\(name): default \(d.value) of \(p.key) is a choice")
                        }
                    }
                }
            }
        }
        // Bool titles are worded positively (no "Don't…" / "Disable…" apart from states that are the option's name).
        for (name, groups) in allGroups() {
            for p in groups.flatMap(\.properties) {
                if case .bool(let title) = p.kind { t.check(!title.isEmpty, "\(name): \(p.key) has a checkbox title") }
            }
        }
    }

    t.suite("EditorSchema: kinds match what the engine reads") {
        func kind(_ key: String, _ type: String) -> S.Kind? { S.property(key, in: S.meterGroups(type))?.kind }
        t.equal(kind("StringAlign", "String"), .alignment9)
        t.equal(kind("ImageAlpha", "Image"), .percent255)
        t.equal(kind("Angle", "String"), .angle(unit: .radians, orientation: true))
        t.equal(kind("StartAngle", "Roundline"), .angle(unit: .radians, orientation: true))
        t.equal(kind("GradientAngle", "Bar"), .angle(unit: .degrees, orientation: true))
        t.equal(kind("Padding", "Image"), .insets)
        t.equal(kind("MeterStyle", "Line"), .styleList)
        t.equal(kind("Container", "Line"), .sectionRef(.meter))
        t.equal(kind("FontFace", "String"), .font)
        t.equal(kind("ImageName", "Image"), .image)
        t.equal(kind("Shape", "Shape"), .shapes)
        // AutoScale: modes on the String meter, a switch on graphs.
        t.check(kind("AutoScale", "String")?.choices?.count == 11)
        t.check(kind("AutoScale", "Line")?.isBool == true)
        t.check(kind("AutoScale", "Histogram")?.isBool == true)
        // Segmented for up to four choices, pop-ups beyond.
        if case .choice(_, let style)? = kind("StringCase", "String") { t.equal(style, .segmented) } else { t.check(false, "StringCase") }
        if case .choice(_, let style)? = kind("FontWeight", "String") { t.equal(style, .popup) } else { t.check(false, "FontWeight") }
        // Legacy spellings the engine reads.
        t.equal(S.property("SecondaryMeasureName", in: S.meterGroups("Histogram"))?.key, "MeasureName2")
        t.equal(S.property("ValueReminder", in: S.meterGroups("Roundline"))?.key, "ValueRemainder")
        t.equal(S.property("Path", in: S.meterGroups("Image"))?.key, "ImagePath")
        t.check(S.keys(S.meterGroups("Rotator")).contains("valuereminder"))
        // Options that do not exist on a type are not offered.
        t.equal(S.property("MaxValue", in: S.measureGroups("PhysicalMemory")), nil, "MaxValue is not settable for memory")
        t.equal(S.property("MaxValue", in: S.measureGroups("FreeDiskSpace")), nil)
        t.equal(S.property("InvertMeasure", in: S.measureGroups("String")), nil, "String measures cannot be inverted")
        t.equal(S.property("AverageSize", in: S.measureGroups("Loop")), nil)
        t.equal(S.property("MinValue", in: S.measureGroups("Loop")), nil)
        t.equal(S.property("InvertMeasure", in: S.measureGroups("Memory"))?.label, "Free", "memory: free instead of used")
        t.equal(S.property("InvertMeasure", in: S.measureGroups("Memory"))?.partOf, "Total", "one Show control")
        t.equal(S.property("MaxValue", in: S.measureGroups("CPU"))?.defaultValue, "100")
        t.equal(S.property("MaxValue", in: S.measureGroups("NetIn"))?.placeholder, "auto")
        t.equal(S.measureGroups("time").first?.properties.first?.kind,
                .format(presets: S.timeFormats, preview: .time))
        t.equal(S.measureGroups("uptime").first?.properties.first?.defaultValue, "%4!i!d %3!i!:%2!02i!")
        // Engine defaults.
        let (skin, _) = try makeSkin(t, "[Rainmeter]\n[B]\nMeter=Bar\n[H]\nMeter=Histogram\n[R]\nMeter=Roundline\n")
        if let bar = skin.meter(named: "B") as? BarMeter {
            t.equal(S.property("BarColor", in: S.meterGroups("Bar"))?.defaultValue, "0,128,0,255")
            t.equal(OptionValue.color("0,128,0,255"), bar.barColor)
            t.equal(bar.vertical, true, "BarOrientation default Vertical")
        } else { t.check(false, "bar") }
        if let h = skin.meter(named: "H") as? HistogramMeter {
            t.equal(OptionValue.color(S.property("PrimaryColor", in: S.meterGroups("Histogram"))?.defaultValue ?? ""), h.primaryColor)
            t.equal(OptionValue.color(S.property("BothColor", in: S.meterGroups("Histogram"))?.defaultValue ?? ""), h.bothColor)
        } else { t.check(false, "histogram") }
    }

    t.suite("EditorSchema: all measure types and plugins") {
        t.equal(S.measureTypes.count, 50)
        t.equal(Set(S.measureTypes.map { $0.name.lowercased() }).count, 50, "no type twice")
        for m in S.measureTypes {
            let d = m.isPlugin ? S.describeMeasure(type: "Plugin", plugin: m.name) : S.describeMeasure(type: m.name)
            t.equal(d.title, m.title, m.name)
            t.check(!d.symbol.isEmpty && d.symbol != "puzzlepiece" && d.symbol != "waveform.path.ecg", "\(m.name) symbol")
            t.equal(S.describeMeasure(type: m.name.lowercased(), plugin: m.name).title, m.title,
                    "\(m.name): the engine's effective type (Measure.type)")
            if m.bothForms { t.equal(S.describeMeasure(type: "Plugin", plugin: m.name).title, m.title, "\(m.name) as a plugin") }
            for alias in m.aliases {
                t.equal(S.describeMeasure(type: "Plugin", plugin: alias).title, m.title, alias)
                t.equal(S.measureGroups("Plugin", plugin: alias), S.measureGroups("Plugin", plugin: m.name), alias)
            }
            t.equal(S.measureGroups(m.name.lowercased(), plugin: nil).map(\.title), ["Settings"])
        }
        // Everything the engine itself registers is known (the app's plugins are checked in the app tests).
        Skin.registerBuiltInExtensions()
        for entry in CorePlugins.pluginTypes {
            t.check(S.measureType(type: "Plugin", plugin: entry.name) != nil, "Plugin=\(entry.name) is described")
        }
        for type in Skin.documentedMeasureTypes where type != "plugin" {
            t.check(S.measureType(type: type) != nil, "Measure=\(type) is described")
        }
        t.equal(S.describeMeasure(type: "Plugin", plugin: "Plugins\\PingPlugin.dll").title, "Ping time")
        t.equal(S.describeMeasure(type: "plugin", plugin: "powerplugin.dll").title, "Battery")
        t.equal(S.describeMeasure(type: "Plugin", plugin: "PowerPlugin").symbol, "battery.75percent")
        t.equal(S.describeMeasure(type: "Plugin", plugin: "SomeWindowsThing").title, "Data from SomeWindowsThing")
        t.equal(S.describeMeasure(type: "Plugin", plugin: "Plugins\\WebView.dll").title, "Data from WebView", "no folder, no .dll")
        t.equal(S.describeMeasure(type: "Plugin").title, "Add-on data")
        t.equal(S.describeMeasure(type: "Plugin", plugin: "SomeWindowsThing").symbol, "puzzlepiece")
        t.equal(S.describeMeasure(type: "Bogus").title, "Bogus")
        t.equal(S.describeMeasure(type: "").title, "Data")
        t.equal(S.describeMeasure(type: "Memory").title, "Memory used (Windows-style)")
        t.equal(S.describeMeasure(type: "Memory", total: true).title, "Total memory (Windows-style)")
        t.equal(S.describeMeasure(type: "PhysicalMemory", invert: true).title, "Memory free")
        // SwapMemory is memory and swap together (as LayerNaming names it; real swap is a formula of two items).
        t.equal(S.describeMeasure(type: "SwapMemory").title, "Memory and swap used")
        t.equal(S.describeMeasure(type: "SwapMemory", total: true).title, "Total memory and swap")
        t.equal(S.describeMeasure(type: "FreeDiskSpace").title, "Free disk space")
        t.equal(S.describeMeasure(type: "FreeDiskSpace", total: true).title, "Disk size")
        t.equal(S.describeMeasure(type: "FreeDiskSpace", invert: true).title, "Used disk space")
        t.equal(S.measureGroups("Plugin", plugin: "PowerPlugin").first?.properties.first?.key, "PowerState")
        t.equal(S.measureGroups("powerplugin").first?.properties.first?.key, "PowerState", "effective type")
        t.equal(S.measureGroups("Plugin").map(\.title), ["Settings"], "a plugin measure without Plugin=")
        t.equal(S.measureGroups("WebParser").first?.essentialRows.map(\.key), ["URL", "RegExp", "StringIndex"])
        t.check(S.property("FinishAction", in: S.measureGroups("WebParser"))?.level == .more, "events behind More")
        t.equal(S.measureGroups("Plugin", plugin: "MediaKey").first?.essentialRows.map(\.key), ["Disabled"],
                "commands only: turning it off")
    }

    t.suite("EditorSchema: every general measure option the engine reads is covered") {
        // Keys read for every measure by SkinSection.readOptions and Measure.readOptions / readConditions /
        // readThresholds / readMatches (MinValue, MaxValue, InvertMeasure and AverageSize depend on the type and are
        // checked in "kinds match what the engine reads").
        let general = ["UpdateDivider", "DynamicVariables", "Group", "Disabled", "Paused", "Substitute", "RegExpSubstitute",
                       "OnUpdateAction", "OnChangeAction", "IfCondition", "IfTrueAction", "IfFalseAction", "IfConditionMode",
                       "IfAboveValue", "IfAboveAction", "IfBelowValue", "IfBelowAction", "IfEqualValue", "IfEqualAction",
                       "IfMatch", "IfMatchAction", "IfNotMatchAction", "IfMatchMode"]
        for m in S.measureTypes {
            let groups = m.isPlugin ? S.measureGroups("Plugin", plugin: m.name) : S.measureGroups(m.name)
            for key in general { t.check(S.property(key, in: groups) != nil, "\(m.name): \(key)") }
        }
        let calc = S.measureGroups("Calc")
        t.equal(S.property("IfCondition", in: calc)?.kind, .formula)
        t.equal(S.property("IfTrueAction", in: calc)?.kind, .action)
        t.check(S.property("IfConditionMode", in: calc)?.kind.isBool == true)
        t.check(S.property("IfAboveValue", in: calc)?.kind.isNumeric == true)
        // Numbered variants, as the engine reads them (Key, Key2, Key3…; no Key1, no leading zero).
        t.equal(S.property("IfCondition2", in: calc)?.key, "IfCondition")
        t.equal(S.property("iftrueaction12", in: calc)?.key, "IfTrueAction")
        t.equal(S.property("IfNotMatchAction3", in: calc)?.key, "IfNotMatchAction")
        t.equal(S.numberedProperty("IfMatch4", in: calc)?.index, 4)
        t.equal(S.numberedProperty("IfMatch", in: calc)?.index, 1)
        t.equal(S.numberedProperty("IfCondition1", in: calc)?.index, nil, "IfCondition1 is not read")
        t.equal(S.numberedProperty("IfCondition02", in: calc)?.index, nil)
        t.equal(S.property("IfAboveValue2", in: calc), nil, "thresholds do not repeat")
        t.equal(S.property("IfConditionMode2", in: calc), nil)
        t.equal(S.property("Formula2", in: calc), nil, "only numbered properties")
        let then2 = S.numbered(S.property("IfTrueAction", in: calc)!, index: 2, in: calc)
        t.equal(then2.key, "IfTrueAction2")
        t.equal(then2.label, "Then (2)")
        t.equal(then2.visibleWhen, [.isSet("IfCondition2")], "the second action follows the second condition")
        t.check(S.isVisible(then2, in: calc, values: { $0 == "IfCondition2" ? "Calc > 1" : nil }))
        t.check(!S.isVisible(then2, in: calc, values: { $0 == "IfCondition" ? "Calc > 1" : nil }))
        t.equal(S.numbered(S.property("IfTrueAction", in: calc)!, index: 1, in: calc).key, "IfTrueAction")
        t.equal(S.numbered(S.property("Formula", in: calc)!, index: 2, in: calc).key, "Formula", "not numbered")
        // Actions and modes only matter with their condition.
        let values: [String: String] = ["IfAboveValue": "80", "IfMatch": "^Error"]
        let visible = S.measureGroups("Calc", values: { values[$0] }).flatMap(\.properties).map(\.key)
        t.check(visible.contains("IfAboveAction") && visible.contains("IfMatchAction") && visible.contains("IfMatchMode"))
        t.check(!visible.contains("IfTrueAction") && !visible.contains("IfBelowAction") && !visible.contains("IfConditionMode"))
        t.check(visible.contains("IfCondition") && visible.contains("IfBelowValue"), "the conditions themselves always show")
    }

    t.suite("EditorSchema: choices understand aliases") {
        t.equal(S.choice(for: "lefttop", in: S.alignments)?.value, "Left")
        t.equal(S.choice(for: " CENTERcenter ", in: S.alignments)?.value, "CenterCenter")
        t.equal(S.choice(for: "LeftMiddle", in: S.alignments), nil)
        t.equal(S.alignmentChoice(for: "Right Bottom").value, "RightBottom", "the engine ignores spaces")
        t.equal(S.alignmentChoice(for: "center").value, "Center")
        t.equal(S.alignmentChoice(for: "Middle").value, "Left", "unknown: Left · Top")
        t.equal(S.choice(for: "1K", in: S.autoScale)?.value, "1k")
        t.equal(S.choice(for: "1.0", in: S.bevel)?.value, "1", "numbers written differently")
        t.equal(S.choice(for: "(2)", in: S.bevel)?.value, "2")
        t.equal(S.choice(for: "3", in: S.bevel), nil)
        t.equal(S.choice(for: "shadow", in: S.stringEffect)?.value, "Shadow")
        let glass = S.property("Type", in: S.measureGroups("Plugin", plugin: "FrostedGlass"))?.kind.choices ?? []
        t.equal(S.choice(for: "TraslucentBackdrop", in: glass)?.value, "TranslucentBackdrop")
        let channel = S.property("Channel", in: S.measureGroups("Plugin", plugin: "AudioLevel"))?.kind.choices ?? []
        t.equal(S.choice(for: "fl", in: channel)?.value, "L")
        t.equal(S.choice(for: "3", in: channel)?.value, "LFE")
        let power = S.property("PowerState", in: S.measureGroups("Plugin", plugin: "PowerPlugin"))?.kind.choices ?? []
        t.equal(S.choice(for: "LIFETIME", in: power)?.value, "Lifetime", "the engine uppercases PowerState")
    }

    t.suite("EditorSchema: issues in plain words") {
        func p(_ key: String, _ groups: [S.Group]) -> S.Property {
            S.property(key, in: groups) ?? S.Property(key, key, .text)
        }
        let string = S.meterGroups("String")
        t.equal(S.issue(for: "aaaa 0,0,10,10", property: p("Shape", S.meterGroups("Shape"))),
                "“aaaa” is not a shape type — nothing is drawn")
        t.equal(S.issue(for: "Rectangle 0,0,10,10 | Fill Color 1,2,3", property: p("Shape", S.meterGroups("Shape"))), nil)
        t.equal(S.issue(for: "Middle", property: p("StringAlign", string)), "“Middle” is not an alignment — Left · Top is used")
        t.equal(S.issue(for: "right  bottom", property: p("StringAlign", string)), nil, "spaces are ignored like the engine")
        t.equal(S.issue(for: "LeftTop", property: p("StringAlign", string)), nil)
        t.equal(S.issue(for: "Upperr", property: p("StringCase", string)), "“Upperr” is not one of the choices for Capitals — As typed is used")
        t.equal(S.issue(for: "upper", property: p("StringCase", string)), nil)
        t.equal(S.issue(for: "650", property: p("FontWeight", string)), nil, "any weight is valid")
        t.equal(S.issue(for: "heavy", property: p("FontWeight", string)), "“heavy” is not one of the choices for Weight — Regular is used")
        t.equal(S.issue(for: "yes", property: p("AntiAlias", string)), "“yes” is not 0 or 1 — the default (0) is used")
        t.equal(S.issue(for: "2", property: p("AntiAlias", string)), nil, "any number is on")
        t.equal(S.issue(for: "red", property: p("FontColor", string)), "“red” is not a color — the default (0,0,0,255) is used")
        t.equal(S.issue(for: "FF0000", property: p("FontColor", string)), nil)
        t.equal(S.issue(for: "#Accent#", property: p("FontColor", string)), nil, "variables are not judged")
        t.equal(S.issue(for: "#Case#", property: p("StringCase", string)), nil)
        t.equal(S.issue(for: "big", property: p("FontSize", string)), "“big” is not a number — the default (10) is used")
        t.equal(S.issue(for: "(10 * 2)", property: p("FontSize", string)), nil)
        t.equal(S.issue(for: "-3", property: p("FontSize", string)), "-3 is less than 0")
        t.equal(S.issue(for: "300", property: p("ImageAlpha", S.meterGroups("Image"))),
                "300 is outside 0–255 — it is limited to that range")
        t.equal(S.issue(for: "HELP", property: p("MouseActionCursorName", string)),
                "“Help” has no effect on the Mac — the Mac shows the arrow")
        t.equal(S.issue(for: "MyCursor.cur", property: p("MouseActionCursorName", string)), nil, "cursor files")
        t.equal(S.issue(for: "Diagonal", property: p("BarOrientation", S.meterGroups("Bar"))),
                "“Diagonal” is not one of the choices for Fills toward — anything but Horizontal fills upward")
        t.equal(S.issue(for: "USER_SID", property: p("SysInfoType", S.measureGroups("SysInfo"))),
                "“Windows user ID” has no effect on the Mac — Windows only; empty on the Mac")
        t.equal(S.issue(for: "en0", property: p("Interface", S.measureGroups("NetIn"))), nil, "interface names")
        t.equal(S.issue(for: "", property: p("StringCase", string)), nil)
        t.equal(S.issue(for: "anything", property: p("Text", string)), nil)
        // Time zones: local or hours from UTC, never a zone name (the engine would silently use local time).
        let time = S.measureGroups("Time")
        t.equal(S.issue(for: "Europe/Paris", property: p("TimeZone", time)),
                "“Europe/Paris” is not one of the choices for Time zone — only hours from UTC are understood, so local time is used")
        t.equal(S.issue(for: "7.25", property: p("TimeZone", time)), nil, "any number of hours")
        t.equal(S.issue(for: "Local", property: p("TimeZone", time)), nil)
    }

    t.suite("EditorSchema: time zones are a menu") {
        guard let zone = S.property("TimeZone", in: S.measureGroups("Time")), case .choice(let choices, let style) = zone.kind
        else { return t.check(false, "TimeZone is a choice") }
        t.equal(style, .popup)
        t.equal(choices.first?.value, "local", "local time first (the default)")
        t.equal(zone.otherValues, .numbers)
        t.equal(choices.first { $0.value == "-5" }?.title, "UTC−5")
        t.equal(choices.first { $0.value == "5.5" }?.title, "UTC+5:30")
        t.equal(choices.first { $0.value == "5.75" }?.title, "UTC+5:45")
        t.equal(choices.first { $0.value == "0" }?.title, "UTC")
        t.check(choices.contains { $0.value == "-12" } && choices.contains { $0.value == "14" }, "−12 to +14")
        t.equal(S.choice(for: "5.50", in: choices)?.value, "5.5", "the same number written differently")
        t.equal(S.choice(for: "(-5)", in: choices)?.value, "-5")
        t.equal(S.choice(for: "LOCAL", in: choices)?.value, "local")
        t.equal(S.choice(for: "7.25", in: choices), nil, "an offset nobody uses is accepted, but not listed")
        // What the engine does with each listed value: that many hours from UTC (local for `local`).
        for c in choices where c.value != "local" {
            let tz = TimeFormatting.timeZone(forOption: c.value, daylightSavingTime: false)
            t.equal(Double(tz.secondsFromGMT()) / 3600, Double(c.value), c.title)
        }
    }

    t.suite("EditorSchema: relevance follows the other options") {
        let string = S.meterGroups("String")
        let effectColor = S.property("FontEffectColor", in: string)!
        t.check(!S.isVisible(effectColor, in: string, values: { _ in nil }), "no effect: no effect color")
        t.check(!S.isVisible(effectColor, in: string, values: { $0 == "StringEffect" ? "none" : nil }))
        t.check(S.isVisible(effectColor, in: string, values: { $0 == "StringEffect" ? "shadow" : nil }), "case-insensitive")
        t.check(S.isVisible(effectColor, in: string, values: { $0 == "StringEffect" ? "#Effect#" : nil }), "variables pass")
        t.check(!S.isVisible(effectColor, in: string, values: { $0 == "StringEffect" ? "aaaa" : nil }),
                "an invalid effect is no effect, as the engine reads it")
        let dst = S.property("DaylightSavingTime", in: S.measureGroups("Time"))!
        t.check(!S.isVisible(dst, in: S.measureGroups("Time"), values: { $0 == "TimeZone" ? "Europe/Paris" : nil }),
                "a zone name is local time: no daylight saving option")
        t.check(S.isVisible(dst, in: S.measureGroups("Time"), values: { $0 == "TimeZone" ? "7.25" : nil }), "any number counts")
        let visible = S.meterGroups("String", values: { _ in nil }).flatMap(\.properties).map(\.key)
        t.check(!visible.contains("FontEffectColor"))
        t.check(!visible.contains("NumOfDecimals"), "number format needs a data source")
        t.check(visible.contains("FontSize"))
        let bound = S.meterGroups("String", values: { $0 == "MeasureName" ? "MeasureCPU" : nil }).flatMap(\.properties).map(\.key)
        t.check(bound.contains("NumOfDecimals") && bound.contains("Scale"))
        let scaled = S.meterGroups("String", values: { ["MeasureName": "M", "AutoScale": "1k"][$0] }).flatMap(\.properties).map(\.key)
        t.check(!scaled.contains("Scale"), "Scale is not used with AutoScale")

        // Bools by truth, choices by alias, several conditions together.
        let line = S.meterGroups("Line")
        let gridColor = S.property("HorizontalLineColor", in: line)!
        t.check(S.isVisible(gridColor, in: line, values: { $0 == "HorizontalLines" ? "2" : nil }))
        t.check(!S.isVisible(gridColor, in: line, values: { $0 == "HorizontalLines" ? "0" : nil }))
        let image = S.meterGroups("Image")
        let margins = S.property("ScaleMargins", in: image)!
        t.check(S.isVisible(margins, in: image, values: { _ in nil }))
        t.check(!S.isVisible(margins, in: image, values: { $0 == "Tile" ? "1" : nil }))
        t.check(!S.isVisible(margins, in: image, values: { $0 == "PreserveAspectRatio" ? "1.0" : nil }))
        let histogram = S.meterGroups("Histogram")
        let second = S.property("SecondaryColor", in: histogram)!
        t.check(S.isVisible(second, in: histogram, values: { $0 == "SecondaryMeasureName" ? "M2" : nil }), "legacy key")
        let calc = S.measureGroups("Calc")
        t.check(S.isVisible(S.property("LowBound", in: calc)!, in: calc, values: { $0 == "Formula" ? "random * 2" : nil }))
        t.check(!S.isVisible(S.property("LowBound", in: calc)!, in: calc, values: { $0 == "Formula" ? "1 + 1" : nil }))
        let sys = S.measureGroups("SysInfo")
        t.check(S.isVisible(S.property("SysInfoData", in: sys)!, in: sys, values: { $0 == "SysInfoType" ? "ip_address" : nil }))
        t.check(!S.isVisible(S.property("SysInfoData", in: sys)!, in: sys, values: { $0 == "SysInfoType" ? "OS_VERSION" : nil }))
        let skin = S.skinGroups
        t.check(!S.isVisible(S.property("SolidColor", in: skin)!, in: skin, values: { _ in nil }), "transparent by default")
        t.check(S.isVisible(S.property("SolidColor", in: skin)!, in: skin, values: { $0 == "BackgroundMode" ? "2" : nil }))
        // A background image without BackgroundMode is shown (the engine's mode 0): its row stays and "Image" is in
        // effect; an explicit mode wins.
        let background = S.property("Background", in: skin)!, mode = S.property("BackgroundMode", in: skin)!
        let withImage: [String: String] = ["Background": "#@#bg.png"]
        t.check(S.isVisible(background, in: skin, values: { withImage[$0] }), "Background= alone shows the image")
        t.equal(S.defaultValue(of: mode, in: skin, values: { withImage[$0] }), "0")
        t.equal(S.defaultValue(of: mode, in: skin, values: { _ in nil }), "1")
        t.check(!S.isVisible(background, in: skin, values: { _ in nil }))
        let transparent: [String: String] = ["Background": "#@#bg.png", "BackgroundMode": "1"]
        t.check(!S.isVisible(background, in: skin, values: { transparent[$0] }), "an explicit mode wins")
        let resolved = S.visibleGroups(skin, values: { withImage[$0] }).flatMap(\.properties)
        t.equal(resolved.first { $0.key == "BackgroundMode" }?.defaultValue, "0", "controls mark Image as in effect")
        t.check(resolved.contains { $0.key == "Background" })
        t.equal(S.resolvingDefaults(skin, values: { _ in nil }), skin, "nothing changes without Background")
        // The engine agrees.
        let (bgSkin, _) = try makeSkin(t, "[Rainmeter]\nBackground=bg.png\n[M]\nMeter=String\n")
        t.equal(String(bgSkin.settings.backgroundMode), S.defaultValue(of: mode, in: skin, values: { withImage[$0] }))
        let (plainSkin, _) = try makeSkin(t, "[Rainmeter]\n[M]\nMeter=String\n")
        t.equal(String(plainSkin.settings.backgroundMode), mode.defaultValue)
        let visibleMeasure = S.measureGroups("Time", values: { _ in nil }).flatMap(\.properties).map(\.key)
        t.check(!visibleMeasure.contains("DaylightSavingTime") && !visibleMeasure.contains("TimeStampFormat"))
        t.check(S.measureGroups("Time", values: { $0 == "TimeZone" ? "5.5" : nil }).flatMap(\.properties)
            .contains { $0.key == "DaylightSavingTime" })
    }
}
