import Foundation
@testable import DesksetCore

// Patching a running skin from new source text (`Skin.patch(sources:)`, `LiveOptions`): which changes it applies,
// that an applied change leaves the skin as a reload of the new text would, and what it keeps that a reload loses.

/// The text of some files, held in memory (the editing session's buffers stand in for it).
private final class PatchTexts: SourceProvider {
    private var texts: [String: String] = [:]

    private static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() }

    init(_ url: URL? = nil, _ text: String = "") {
        if let url { set(url, text) }
    }

    func set(_ url: URL, _ text: String) { texts[Self.key(url)] = text }
    func sourceText(for url: URL) -> String? { texts[Self.key(url)] }
}

/// A folder with a skin file and some pictures, for skins loaded from text in memory.
private struct PatchFolder {
    let skins: URL
    let file: URL

    init(_ t: TestRunner, files: [String: String] = [:]) throws {
        skins = t.temporaryDirectory("patch").appendingPathComponent("Skins")
        let dir = skins.appendingPathComponent("Root/Sub")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skins.appendingPathComponent("Root/@Resources"),
                                                withIntermediateDirectories: true)
        file = dir.appendingPathComponent("Skin.ini")
        try "[Rainmeter]\n".write(to: file, atomically: true, encoding: .utf8)
        for (path, text) in files {
            let url = skins.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// A skin loaded from `text` (held in memory; the file on disk is not read), with a host of its own.
    func skin(_ text: String, host: FakeHost = FakeHost()) throws -> (Skin, FakeHost) {
        let skin = Skin(config: "Root\\Sub", fileURL: file, skinsDirectory: skins, system: FakeSystem(), host: host)
        skin.sourceProvider = PatchTexts(file, text)
        try skin.load()
        return (skin, host)
    }

    func texts(_ text: String) -> PatchTexts { PatchTexts(file, text) }
}

/// Everything about a skin that a patch and a reload of the same text must agree on: the size, each meter's frame and
/// state, each measure's values and state, each section's options as written and resolved, the variables, the
/// document and where each option is written. Runtime history (graph samples, averages), counters of updates and draws,
/// and caches are left out.
private func patchState(_ skin: Skin, variables: [String]) -> [String] {
    var lines = ["size \(skin.width) x \(skin.height)", "metadata \(skin.metadata.sorted { $0.key < $1.key })"]
    for name in variables { lines.append("#\(name)# = \(skin.variable(name) ?? "nil")") }
    let sections: [SkinSection] = (skin.rainmeterSection.map { [$0] } ?? []) + (skin.measures as [SkinSection])
        + (skin.meters as [SkinSection])
    for section in sections {
        for option in section.inspectedOptions() {
            lines.append("[\(section.name)] \(option.key) = \(option.raw) -> \(option.resolved) (\(option.origin))")
        }
        if let meter = section as? Meter {
            lines.append("[\(meter.name)] frame \(meter.frame) anchor \(meter.anchorX),\(meter.anchorY) hidden \(meter.hidden)")
            if let string = meter as? StringMeter { lines.append("[\(meter.name)] text \(string.text)") }
        }
        if let measure = section as? Measure {
            lines.append("[\(measure.name)] value \(measure.value) \(measure.stringValue) \(measure.minValue)…\(measure.maxValue)")
        }
        lines.append("[\(section.name)] state \(stateDump(section))")
    }
    return lines
}

/// Stored properties that are runtime history, bookkeeping or caches rather than what the options say.
private let volatileLabels: Set<String> = [
    "drawGeneration", "updateTick", "needsOptionRead", "readingAfterLoad", "mentionsSectionVariables",
    "reportedMissingMeasures", "updateCount", "history", "historyNext", "primaryHistory", "secondaryHistory",
    "stringCache", "transitionGeneration", "transitionTick", "lastCheckedPath",
    // Follow the graph's samples, which a patch keeps and a reload starts afresh.
    "autoRangeMin", "autoRangeMax",
    // A Bitmap's transition toward its target frames runs on a timer of its own (the target is compared).
    "displayedFrames", "shownReal", "transitionStep",
    // Counts of changes (a Shape's parsed shapes).
    "revision",
]

/// A stable description of an object's stored properties (superclasses included). Sections and the skin it refers to
/// are named, not described; dictionaries and sets are sorted.
private func stateDump(_ value: Any, depth: Int = 0) -> String {
    if depth > 8 { return "…" }
    if depth > 0, let section = value as? SkinSection { return "<\(type(of: section)) \(section.name)>" }
    if value is Skin { return "<skin>" }
    let mirror = Mirror(reflecting: value)
    switch mirror.displayStyle {
    case .optional?:
        guard let child = mirror.children.first else { return "nil" }
        return stateDump(child.value, depth: depth)
    case .collection?:
        return "[" + mirror.children.map { stateDump($0.value, depth: depth + 1) }.joined(separator: ", ") + "]"
    case .set?, .dictionary?:
        return "{" + mirror.children.map { stateDump($0.value, depth: depth + 1) }.sorted().joined(separator: ", ") + "}"
    case .struct?, .tuple?, .class?:
        var parts: [String] = []
        var current: Mirror? = mirror
        while let m = current {
            for child in m.children {
                let label = child.label ?? "_"
                if volatileLabels.contains(label) || label.hasPrefix("$__lazy_storage_$_") || label.hasPrefix("logged")
                    || label.hasPrefix("warned") { continue }
                parts.append("\(label): \(stateDump(child.value, depth: depth + 1))")
            }
            current = m.superclassMirror
        }
        if parts.isEmpty { return String(describing: value) }
        return "(" + parts.joined(separator: ", ") + ")"
    default:
        return String(describing: value)
    }
}

/// The lines of `a` that differ from `b`, for a failure message.
private func difference(_ a: [String], _ b: [String]) -> String {
    let setB = Set(b), setA = Set(a)
    let onlyA = a.filter { !setB.contains($0) }.prefix(6).map { "  patched: \($0)" }
    let onlyB = b.filter { !setA.contains($0) }.prefix(6).map { "  reloaded: \($0)" }
    return (onlyA + onlyB).joined(separator: "\n")
}

/// `key=value` in the first `[section]` of `text` (replacing the key's line, or added after the header).
private func setting(_ text: String, section: String, key: String, value: String) -> String {
    var lines = text.components(separatedBy: "\n")
    guard let header = lines.firstIndex(where: { $0.caseInsensitiveCompare("[\(section)]") == .orderedSame }) else {
        return text + "\n[\(section)]\n\(key)=\(value)\n"
    }
    var end = header + 1
    while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
    if let existing = lines[(header + 1)..<end].firstIndex(where: {
        $0.lowercased().hasPrefix(key.lowercased() + "=")
    }) {
        lines[existing] = "\(key)=\(value)"
    } else {
        lines.insert("\(key)=\(value)", at: header + 1)
    }
    return lines.joined(separator: "\n")
}

func runLivePatchTests(_ t: TestRunner) {
    runLivePatchPlannerTests(t)
    runLivePatchConsistencyTests(t)
    runLivePatchStateTests(t)
}

// MARK: - (a) Which changes are applied

private func runLivePatchPlannerTests(_ t: TestRunner) {
    t.suite("Session: live patch — the table") {
        func live(_ key: String, _ kind: LiveOptions.Section) -> Bool { LiveOptions.applies(key, in: kind) == .live }
        t.check(live("FontSize", .meter(type: "string")))
        t.check(live("fontcolor", .meter(type: "String")), "any case")
        t.check(live("X", .meter(type: "image")) && live("MouseOverAction", .meter(type: "bar")))
        t.check(live("MeasureName3", .meter(type: "string")), "a numbered MeasureName on any meter")
        t.check(live("Shape", .meter(type: "shape")) && live("Shape12", .meter(type: "shape")))
        t.check(live("Scale2", .meter(type: "line")))
        t.check(!live("Scale2", .meter(type: "string")), "String has one Scale")
        t.check(live("InlineSetting4", .meter(type: "string")) && live("InlinePattern", .meter(type: "string")))
        t.check(live("MacGlass", .meter(type: "unsupported")), "general options on a type the engine does not draw")
        for key in ["Meter", "Container", "DynamicVariables", "UpdateDivider", "Foo", "FontSize2"] {
            t.check(!live(key, .meter(type: "string")), "\(key) reloads a meter")
        }
        t.check(!live("FontSize", .meter(type: "image")), "a key its type does not read")
        for key in ["Update", "LocalFont", "SkinWidth", "OnRefreshAction", "ContextTitle", "BackgroundMode"] {
            t.check(!live(key, .rainmeter), "[Rainmeter] \(key)")
        }
        t.check(live("Author", .metadata) && live("Anything", .variables) && live("SolidColor", .other))
        t.check(live("Format", .measure(type: "time")) && live("Substitute", .measure(type: "calc")))
        t.check(live("String", .measure(type: "string")) && live("Processor", .measure(type: "cpu")))
        t.check(!live("Formula", .measure(type: "calc")), "a Calc's range follows its values")
        t.check(!live("MaxValue", .measure(type: "calc")))
        for key in ["IfCondition", "IfTrueAction", "OnUpdateAction", "AverageSize", "Disabled", "Paused",
                    "UpdateDivider", "DynamicVariables", "Measure"] {
            t.check(!live(key, .measure(type: "time")), "measure \(key)")
        }
        t.check(!live("ScriptFile", .measure(type: "(script)")) && !live("Substitute", .measure(type: "(webparser)")),
                "types the table does not list reload")
        t.check(LiveOptions.canReadAgain(measureType: "calc") && !LiveOptions.canReadAgain(measureType: "(loop)"))

        // Every property the inspector shows for a meter is decided: live, or one of the keys that always reload.
        let reloads: Set<String> = ["container", "dynamicvariables", "updatedivider"]
        for type in EditorSchema.meterTypes {
            for key in EditorSchema.keys(EditorSchema.meterGroups(type)).sorted() {
                let p = EditorSchema.property(key, in: EditorSchema.meterGroups(type))
                let decided = live(key, .meter(type: type)) || reloads.contains(key.lowercased())
                t.check(decided, "\(type) \(key) is in LiveOptions")
                if let p { t.equal(p.applies(toMeterType: type), LiveOptions.applies(p.key, in: .meter(type: type))) }
            }
        }
    }

    t.suite("Session: live patch — what reloads") {
        let folder = try PatchFolder(t, files: ["Root/@Resources/Shared.inc": "[Variables]\nShared=1\n",
                                                "Root/@Resources/Other.inc": "[Variables]\nOther=2\n"])
        let base = """
            [Rainmeter]
            Update=1000
            SolidColor=#Back#
            [Metadata]
            Author=Someone
            [Variables]
            @Include=#@#Shared.inc
            Back=0,0,0,255
            Color=255,0,0,255
            Holder=Target
            Index=1
            Color1=1,2,3
            Style=StyleA
            [StyleA]
            FontSize=10
            [StyleB]
            FontSize=20
            DynamicVariables=1
            [MeasureA]
            Measure=Calc
            Formula=5
            [MeasureAvg]
            Measure=Calc
            Formula=6
            AverageSize=3
            [Target]
            Meter=String
            MeasureName=MeasureA
            MeterStyle=StyleA
            FontColor=#Color#
            Text=%1
            [Other]
            Meter=String
            Text=x
            X=0R
            """
        func decide(_ text: String, from start: String = base) throws -> SkinPatchResult {
            let (skin, _) = try folder.skin(start)
            skin.update()
            let before = skin.document
            let result = skin.patch(sources: folder.texts(text))
            if case .needsReload = result {
                t.equal(skin.document, before, "a patch that needs a reload changes nothing")
                t.equal(skin.sourceGeneration, 0)
            }
            return result
        }
        func expect(_ text: String, _ reason: SkinPatchReason, _ message: String) throws {
            t.equal(try decide(text), .needsReload(reason), message)
        }
        func applied(_ text: String, from start: String = base) throws -> SkinPatchSummary? {
            guard case .applied(let summary) = try decide(text, from: start) else { return nil }
            return summary
        }

        try expect(base.replacingOccurrences(of: "Update=1000", with: "Update=500"), .rainmeter(key: "update"),
                   "[Rainmeter] is read when the skin loads")
        try expect(base.replacingOccurrences(of: "Update=1000", with: "Update=1000\nLocalFont=#@#Font.ttf"),
                   .rainmeter(key: "localfont"), "LocalFont")
        try expect(base.replacingOccurrences(of: "Back=0,0,0,255", with: "Back=9,9,9,255"),
                   .rainmeter(key: "solidcolor"), "a variable [Rainmeter] uses")
        try expect(setting(base, section: "Target", key: "Container", value: "Other"),
                   .option(section: "Target", key: "container"), "Container")
        try expect(setting(base, section: "Target", key: "DynamicVariables", value: "1"),
                   .option(section: "Target", key: "dynamicvariables"), "DynamicVariables")
        try expect(setting(base, section: "Target", key: "UpdateDivider", value: "2"),
                   .option(section: "Target", key: "updatedivider"), "UpdateDivider")
        try expect(setting(base, section: "Target", key: "Foo", value: "1"),
                   .option(section: "Target", key: "foo"), "a key the meter does not read")
        try expect(setting(base, section: "MeasureA", key: "Formula", value: "6"),
                   .option(section: "MeasureA", key: "formula"), "a Calc's Formula")
        try expect(setting(base, section: "MeasureAvg", key: "Substitute", value: "\"6\":\"six\""),
                   .averaged(section: "MeasureAvg"), "a measure that averages its values")
        try expect(setting(base, section: "Target", key: "MeterStyle", value: "StyleB"),
                   .option(section: "Target", key: "dynamicvariables"), "a new style brings a key that reloads")
        try expect(setting(base, section: "StyleA", key: "Container", value: "Other"),
                   .option(section: "Target", key: "container"), "a style's key, decided where it is used")
        try expect(setting(base, section: "Target", key: "MeterStyle", value: "#Style#"),
                   .meterStyle(section: "Target"), "a MeterStyle list written with a variable")
        try expect(setting(base, section: "Other", key: "Container", value: "#Holder#"),
                   .option(section: "Other", key: "container"), "a key that reloads written with a variable")
        let holder = setting(base, section: "Other", key: "Container", value: "#Holder#")
        t.equal(try decide(holder.replacingOccurrences(of: "Holder=Target", with: "Holder=None"), from: holder),
                .needsReload(.option(section: "Other", key: "container")), "…and that variable changes")

        // Structure.
        try expect(base + "\n[New]\nMeter=String\n", .sections, "a section added")
        try expect(base.replacingOccurrences(of: "[Other]\nMeter=String\nText=x\nX=0R", with: ""), .sections,
                   "a section removed")
        try expect(base.replacingOccurrences(of: "[Other]", with: "[Another]"), .sections, "a section renamed")
        try expect(base.replacingOccurrences(of: "[Other]", with: "[other]"), .sections, "…even in another case")
        let swapped = base.replacingOccurrences(of: "[StyleA]\nFontSize=10\n[StyleB]\nFontSize=20\nDynamicVariables=1",
                                                with: "[StyleB]\nFontSize=20\nDynamicVariables=1\n[StyleA]\nFontSize=10")
        t.check(swapped != base)
        try expect(swapped, .sections, "sections in another order")
        try expect(base.replacingOccurrences(of: "[Other]\nMeter=String", with: "[Other]\nMeter=Image"),
                   .type(section: "Other"), "another meter type")
        try expect(base.replacingOccurrences(of: "Measure=Calc\nFormula=5", with: "Measure=Time\nFormula=5"),
                   .type(section: "MeasureA"), "another measure type")
        try expect(base.replacingOccurrences(of: "Update=1000", with: "Update=1000\n[Extra]\n@Include=#@#Other.inc"),
                   .includes, "one more file included")
        try expect(base.replacingOccurrences(of: "@Include=#@#Shared.inc", with: "@Include=#@#Other.inc"), .includes,
                   "another file included")
        try expect(base.replacingOccurrences(of: "@Include=#@#Shared.inc", with: "@Include=#@#Shared.inc\n@Include2=#@#Missing.inc"),
                   .includes, "an include that is missing")
        // Random structural changes always reload.
        let sectionNames = ["StyleA", "StyleB", "MeasureA", "MeasureAvg", "Target", "Other"]
        for name in sectionNames {
            try expect(base.replacingOccurrences(of: "[\(name)]", with: "[\(name)]\n[Inserted\(name)]\nMeter=String"),
                       .sections, "a section inserted before \(name)'s options")
        }

        // Applied.
        guard let color = try applied(setting(base, section: "Target", key: "FontColor", value: "0,255,0,255")) else {
            return t.check(false, "a color is live")
        }
        t.equal(color.changedSections, ["Target"])
        t.equal(color.readAgain, ["Target"])
        t.equal(color.sourceGeneration, 1)
        guard let variable = try applied(base.replacingOccurrences(of: "Color=255,0,0,255", with: "Color=0,0,255,255"))
        else { return t.check(false, "a variable only live options use is live") }
        t.equal(variable.changedVariables, ["color"])
        t.equal(variable.changedSections, ["Target"], "the meter that uses it")
        let nested = setting(base, section: "Other", key: "FontColor", value: "[#Color[#Index]]")
        guard let viaNested = try applied(nested.replacingOccurrences(of: "Color1=1,2,3", with: "Color1=4,5,6"),
                                          from: nested) else { return t.check(false, "a nested variable name") }
        t.equal(viaNested.changedSections, ["Other"], "a nested name may be any variable")
        guard let style = try applied(setting(base, section: "StyleA", key: "FontSize", value: "14")) else {
            return t.check(false, "a style's live key")
        }
        t.equal(style.changedSections, ["Target"], "the meters that use the style, not the style itself")
        guard let meta = try applied(base.replacingOccurrences(of: "Author=Someone", with: "Author=Me")) else {
            return t.check(false, "[Metadata]")
        }
        t.check(meta.metadataChanged && meta.changedSections.isEmpty)
        let (skin, _) = try folder.skin(base)
        skin.update()
        let line = skin.sources.location(section: "Target", key: "FontColor")?.line ?? 0
        let comment = "; a comment\n\n" + base
        guard case .applied(let textOnly) = skin.patch(sources: folder.texts(comment)) else {
            return t.check(false, "comments")
        }
        t.check(textOnly.isTextOnly)
        t.equal(skin.sourceGeneration, 1)
        t.equal(skin.sources.location(section: "Target", key: "FontColor")?.line, line + 2,
                "where each option is written moved")
        t.equal(skin.metadata["Author"], "Someone")
        guard case .applied = skin.patch(sources: folder.texts(comment.replacingOccurrences(of: "Author=Someone",
                                                                                              with: "Author=Me"))) else {
            return t.check(false, "[Metadata] again")
        }
        t.equal(skin.metadata["Author"], "Me")
        t.equal(skin.sourceGeneration, 2)
        skin.close()
        t.equal(skin.patch(sources: folder.texts(base)), .needsReload(.closed))
    }

    t.suite("Session: live patch — measures that cannot be read again") {
        let folder = try PatchFolder(t)
        let base = """
            [Rainmeter]
            [MeasureLoop]
            Measure=Loop
            EndValue=[Target:W]
            [Target]
            Meter=String
            Text=abc
            FontSize=10
            """
        let (skin, _) = try folder.skin(base)
        skin.update()
        t.equal(skin.patch(sources: folder.texts(base.replacingOccurrences(of: "FontSize=10", with: "FontSize=12"))),
                .needsReload(.sectionVariables(section: "MeasureLoop")),
                "a Loop that read a meter's width when the skin loaded would read it again after a reload")

        let script = """
            [Rainmeter]
            [Variables]
            A=1
            [Lua]
            Measure=Script
            ScriptFile=#@#Missing.lua
            [Target]
            Meter=String
            Text=#A#
            """
        let (scripted, _) = try folder.skin(script)
        scripted.update()
        t.equal(scripted.patch(sources: folder.texts(script.replacingOccurrences(of: "A=1", with: "A=2"))),
                .needsReload(.scriptsReadVariables))
        guard case .applied = scripted.patch(sources: folder.texts(script + "\nFontSize=20")) else {
            return t.check(false, "a meter option of a skin with a script")
        }
        t.equal(scripted.patch(sources: folder.texts(script.replacingOccurrences(of: "Missing.lua", with: "Other.lua") + "\nFontSize=20")),
                .needsReload(.option(section: "Lua", key: "scriptfile")))
    }
}

// MARK: - (b) A patch leaves the skin as a reload would

/// Patches `section`'s `key` to each of `samples` in turn on a running skin of `base`, and compares it — after one more
/// update — with a fresh skin of the same text after its first update.
private func checkConsistency(_ t: TestRunner, _ folder: PatchFolder, base: String, section: String, key: String,
                              samples: [String], variables: [String]) throws {
    let hostA = FakeHost()
    let (patched, _) = try folder.skin(base, host: hostA)
    patched.update()
    patched.update()
    for sample in samples {
        let text = setting(base, section: section, key: key, value: sample)
        let result = patched.patch(sources: folder.texts(text))
        guard case .applied = result else {
            return t.check(false, "[\(section)] \(key)=\(sample) is live but was not applied: \(result)")
        }
        patched.update()
        let hostB = FakeHost()
        let (reloaded, _) = try folder.skin(text, host: hostB)
        reloaded.update()
        t.equal(patched.document, reloaded.document, "[\(section)] \(key)=\(sample): the document")
        t.check(patched.sources == reloaded.sources, "[\(section)] \(key)=\(sample): where options are written")
        t.equal(patched.glassRegions, reloaded.glassRegions, "[\(section)] \(key)=\(sample): glass")
        let a = patchState(patched, variables: variables), b = patchState(reloaded, variables: variables)
        t.check(a == b, "[\(section)] \(key)=\(sample) patched differs from reloaded:\n\(difference(a, b))")
        reloaded.close()
    }
    patched.close()
}

/// Base options of the meter under test, by type.
private let targetOptions: [String: String] = [
    "string": "Text=%1 of #Size#\nFontSize=10\nFontColor=#Color#",
    "image": "ImageName=pic100x50.png",
    "bar": "BarColor=0,128,0,255\nBarOrientation=Horizontal",
    "line": "LineCount=2\nMeasureName2=MeasureB\nLineColor=255,0,0,255",
    "histogram": "MeasureName2=MeasureB\nPrimaryColor=0,255,0,255",
    "roundline": "LineLength=20\nLineStart=5\nLineWidth=2",
    "rotator": "ImageName=hand100x50.png\nOffsetX=5\nOffsetY=5",
    "button": "ButtonImage=button100x50.png\nButtonCommand=[!SetVariable Pressed 1]",
    "bitmap": "BitmapImage=digits100x50.png\nBitmapFrames=10",
    "shape": "Shape=Rectangle 0,0,40,20 | Fill Color 255,0,0,255\nShape2=Ellipse 20,10,8 | StrokeWidth 2",
]

/// A skin with the meter under test (`[Target]`) between others that follow it: relative positions, section variables
/// read once and read on every update.
private func meterBase(_ type: String) -> String {
    """
    [Rainmeter]
    Update=1000
    [Metadata]
    Name=Patch test
    [Variables]
    Color=10,20,30,255
    Size=12
    [MeasureA]
    Measure=Calc
    Formula=40
    MinValue=0
    MaxValue=100
    [MeasureB]
    Measure=Calc
    Formula=7
    MaxValue=10
    [MeasureText]
    Measure=String
    String=Hello
    [Style]
    SolidColor=1,2,3,128
    [Style2]
    Padding=1,1,1,1
    [Before]
    Meter=String
    Text=before
    X=5
    Y=5
    [Target]
    Meter=\(type)
    MeasureName=MeasureA
    X=10R
    Y=4r
    W=60
    H=30
    MeterStyle=Style
    \(targetOptions[type] ?? "")
    [After]
    Meter=String
    Text=after
    X=2R
    Y=0r
    [Below]
    Meter=String
    Text=[Target:W]x[Target:H]
    X=[Target:X]
    Y=([Target:YH] + 2)
    [Dynamic]
    Meter=String
    DynamicVariables=1
    Text=[Target:XW]
    X=5R
    Y=[Target:Y]
    """
}

/// Sample values for a key, when its kind alone does not give good ones.
private let sampleOverrides: [String: [String]] = [
    "x": ["20", "(5 + 5)r", "3R"], "y": ["8", "2R", "(#Size# / 2)"], "w": ["80", "", "(#Size# * 3)"],
    "h": ["40", "", "5"], "text": ["Value %1", "", "#Size# pt"], "prefix": ["Up ", ""], "postfix": [" %", ""],
    "measurename": ["MeasureB", "MeasureText", ""], "measurename2": ["MeasureA", "MeasureText", ""],
    "secondarymeasurename": ["MeasureA", ""], "meterstyle": ["Style2", "Style | Style2", ""],
    "group": ["G1 | G2", ""], "tooltipicon": ["Info", ""], "tooltiptype": ["1", "0"],
    "tooltipwidth": ["200", "50"], "path": ["Images", ""], "macdecodesize": ["Drawn", ""],
    "inlinesetting": ["Color | 255,0,0,255", "Size | 20"], "inlinesetting2": ["Weight | 700", ""],
    "inlinepattern": ["Hel", "(?i)val"], "inlinepattern2": ["ue", ""],
    "colormatrix1": ["0.5;0;0;0;0", ""], "colormatrix2": ["0;0.5;0;0;0"], "scale2": ["2", "0.5"],
    "linecolor2": ["0,0,255,255", "#Color#"],
    "shape": ["Rectangle 0,0,50,25,4 | Fill Color 0,0,255,255", "Ellipse 10,10,10", "Line 0,0,30,30 | StrokeWidth 3"],
    "shape2": ["Rectangle 5,5,10,10", ""], "transformationmatrix": ["1;0;0;1;5;5", "0.5;0;0;0.5;0;0", ""],
    "scalemargins": ["2,2,2,2", ""], "valuereminder": ["60", "0"], "valueremainder": ["3600", "0"],
    "imagename": ["pic100x50.png", "sf:star.fill", "missing.png"],
    "buttonimage": ["b100x50.png", "sf:star.fill"], "bitmapimage": ["other100x50.png", ""],
    "barimage": ["bar100x50.png", ""], "maskimagename": ["mask100x50.png", ""],
    "primaryimage": ["graph100x50.png", ""], "secondaryimage": ["graph100x50.png", ""],
    "bothimage": ["graph100x50.png", ""], "tooltiptext": ["Now %1", ""], "tooltiptitle": ["Title", ""],
    "onupdateaction": ["", "[!SetVariable Clicked 1]"], "antialias": ["1", "0"],
    "macsymbolsize": ["24", "8"], "macsymbolweight": ["Bold", "Light"], "macsymbolrendering": ["Hierarchical", "Multicolor"], "fontface": ["Helvetica", "System", "#Size#"],
]

/// Sample values from what a key is: its EditorSchema kind, or its name.
private func samples(for key: String, type: String) -> [String]? {
    if let fixed = sampleOverrides[key] { return fixed }
    if key.hasSuffix("imagecrop") { return ["0,0,20,10", "5,5,20,20,5", ""] }
    if key.hasSuffix("imagepath") { return ["Images", ""] }
    if key.hasSuffix("imagetint") { return ["255,0,0,255", "#Color#", ""] }
    if key.hasSuffix("imagealpha") { return ["128", "0"] }
    if key.hasSuffix("imageflip") { return ["Horizontal", "Both", "None"] }
    if key.hasSuffix("greyscale") { return ["1", "0"] }
    if MouseEventKind.allCases.contains(where: { $0.rawValue.lowercased() == key }) {
        return ["[!SetVariable Clicked 1]", "[]", ""]
    }
    guard let property = EditorSchema.property(key, in: EditorSchema.meterGroups(type)) else { return nil }
    switch property.kind {
    case .text: return ["Hello", ""]
    case .number(let min, let max, _, _):
        let values = [2.0, 7, 25].map { Swift.min(Swift.max($0, min ?? -1e9), max ?? 1e9) }
        return Array(Set(values)).sorted().map { NumberFormatting.plain($0) }
    case .bool: return ["1", "0"]
    case .choice(let choices, _):
        let values = choices.map(\.value).filter { $0 != property.defaultValue }
        return Array(values.prefix(3)) + [property.defaultValue]
    case .alignment9: return ["Right", "CenterCenter", "LeftBottom"]
    case .percent255: return ["128", "0"]
    case .angle: return ["45", "-1.5"]
    case .color: return ["255,0,0,255", "#Color#", "00FF0080"]
    case .font: return ["Helvetica", "System"]
    case .insets: return ["1,2,3,4", "5", ""]
    case .image: return ["pic100x50.png", "sf:star.fill", ""]
    case .sectionRef(.measure): return ["MeasureB", "MeasureText", ""]
    case .sectionRef: return ["Before", ""]
    case .styleList: return ["Style2", ""]
    case .format(let presets, _): return Array(presets.prefix(2))
    case .formula: return ["(1 + 2)", "(#Size#)"]
    case .action: return ["[!SetVariable Clicked 1]", "[]", ""]
    case .shapes: return sampleOverrides["shape"]
    }
}

/// Every key `LiveOptions` makes live on a meter of `type`, with the second of each numbered family.
private func liveMeterKeys(_ type: String) -> [String] {
    var keys = LiveOptions.meterGeneral.union(LiveOptions.meterKeys[type] ?? [])
    for stem in LiveOptions.meterGeneralNumbered.union(LiveOptions.meterNumbered[type] ?? []) {
        if stem == "colormatrix" {
            keys.formUnion(["colormatrix1", "colormatrix2"])
        } else {
            keys.formUnion([stem, stem + "2"])
        }
    }
    return keys.sorted()
}

private func runLivePatchConsistencyTests(_ t: TestRunner) {
    let variables = ["Color", "Size", "Clicked", "Pressed"]
    for type in EditorSchema.meterTypes.map({ $0.lowercased() }) {
        t.suite("Session: live patch — \(type) meters patch as they reload") {
            let folder = try PatchFolder(t)
            let base = meterBase(type)
            for key in liveMeterKeys(type) {
                guard let values = samples(for: key, type: type) else {
                    t.check(false, "no sample values for \(type) \(key)")
                    continue
                }
                try checkConsistency(t, folder, base: base, section: "Target", key: key, samples: values,
                                     variables: variables)
            }
            // A style the meter uses, and a variable it uses.
            try checkConsistency(t, folder, base: base, section: "Style", key: "SolidColor",
                                 samples: ["9,9,9,255", ""], variables: variables)
            try checkConsistency(t, folder, base: base, section: "Style2", key: "Padding", samples: ["3,3,3,3"],
                                 variables: variables)
            try checkConsistency(t, folder, base: base, section: "Variables", key: "Size", samples: ["20", "3"],
                                 variables: variables)
            try checkConsistency(t, folder, base: base, section: "Variables", key: "Color",
                                 samples: ["1,1,1,255", "0,200,0"], variables: variables)
            try checkConsistency(t, folder, base: base, section: "Metadata", key: "Name", samples: ["Other"],
                                 variables: variables)
        }
    }

    t.suite("Session: live patch — measures patch as they reload") {
        let folder = try PatchFolder(t)
        let base = """
            [Rainmeter]
            [Variables]
            Zone=0
            [MeasureTime]
            Measure=Time
            TimeStamp=13390000000
            TimeZone=#Zone#
            Format=%Y-%m-%d %H:%M
            [MeasureUp]
            Measure=Uptime
            [MeasureCPU]
            Measure=CPU
            [MeasureString]
            Measure=String
            String=12.5
            [MeasureCalc]
            Measure=Calc
            Formula=3
            MaxValue=10
            [ShowTime]
            Meter=String
            MeasureName=MeasureTime
            [ShowUp]
            Meter=String
            MeasureName=MeasureUp
            Y=0R
            [ShowCPU]
            Meter=Bar
            MeasureName=MeasureCPU
            W=50
            H=5
            Y=0R
            [ShowString]
            Meter=String
            MeasureName=MeasureString
            Percentual=1
            Y=0R
            [ShowCalc]
            Meter=String
            MeasureName=MeasureCalc
            Text=%1 [MeasureCalc:%]
            Y=0R
            """
        let byType: [(section: String, type: String)] = [("MeasureTime", "time"), ("MeasureUp", "uptime"),
                                                         ("MeasureCPU", "cpu"), ("MeasureString", "string"),
                                                         ("MeasureCalc", "calc")]
        let values: [String: [String]] = [
            "format": ["%A, %B %#d", "%H:%M:%S", "%#I %p"], "formatlocale": ["de", "fr-FR", ""],
            "timezone": ["5.5", "-3", "local"], "daylightsavingtime": ["0", "1"],
            "timestamp": ["13000000000", "13390000123.5"], "timestampformat": ["%Y-%m-%d", ""],
            "timestamplocale": ["en-US", ""], "adddaystohours": ["0", "1"], "secondsvalue": ["100", "90061", ""],
            "processor": ["1", "3", "0"], "string": ["Hi", "", "42"], "minvalue": ["10", "-5", ""],
            "maxvalue": ["200", "50", ""], "substitute": ["\"1\":\"one\"", "\"2\":\"\"", ""],
            "regexpsubstitute": ["1", "0"], "group": ["G | H", ""],
        ]
        for (section, type) in byType {
            let keys = (LiveOptions.measureKeys[type] ?? []).union(LiveOptions.measureGeneral).sorted()
            for key in keys {
                var samples = values[key] ?? []
                if key == "format", type == "uptime" { samples = ["%4!i! days", "%3!i!:%2!02i!:%1!02i!"] }
                t.check(!samples.isEmpty, "samples for \(type) \(key)")
                try checkConsistency(t, folder, base: base, section: section, key: key, samples: samples,
                                     variables: ["Zone"])
            }
        }
        try checkConsistency(t, folder, base: base, section: "Variables", key: "Zone", samples: ["2", "-7"],
                             variables: ["Zone"])
    }
}

// MARK: - (c) What a patch keeps, (d) previews

private func runLivePatchStateTests(_ t: TestRunner) {
    t.suite("Session: live patch — the running skin keeps its history and runtime values") {
        let folder = try PatchFolder(t)
        let base = """
            [Rainmeter]
            Update=1000
            [Variables]
            Size=12
            Color=255,0,0,255
            [MeasureCounter]
            Measure=Calc
            Formula=Counter
            [Graph]
            Meter=Line
            MeasureName=MeasureCounter
            W=20
            H=10
            LineColor=255,255,255,255
            [Histo]
            Meter=Histogram
            MeasureName=MeasureCounter
            W=20
            H=10
            [Label]
            Meter=String
            MeasureName=MeasureCounter
            Text=%1
            FontSize=#Size#
            FontColor=#Color#
            [Other]
            Meter=String
            Text=other
            """
        let (skin, _) = try folder.skin(base)
        for _ in 0..<5 { skin.update() }
        guard let line = skin.meter(named: "Graph") as? LineMeter, let histo = skin.meter(named: "Histo") as? HistogramMeter,
              let counter = skin.measure(named: "MeasureCounter"), let label = skin.meter(named: "Label") else {
            return t.check(false, "the meters")
        }
        func samples(_ history: GraphHistory) -> [Double] { (0..<history.count).map { history.value(age: $0) } }
        let lineSamples = samples(line.lines[0].history), histoSamples = samples(histo.primaryHistory)
        t.equal(lineSamples, [4, 3, 2, 1, 0], "the counter of each update, newest first")
        t.equal(skin.counter, 5)
        skin.execute("[!SetVariable Size 30][!SetOption Label StringAlign Right][!HideMeter Other]"
                     + "[!SetOption Label FontSize 44]", from: nil)
        let edited = base.replacingOccurrences(of: "LineColor=255,255,255,255", with: "LineColor=0,255,0,255")
            .replacingOccurrences(of: "[Histo]\nMeter=Histogram", with: "[Histo]\nMeter=Histogram\nPrimaryColor=0,0,255,255")
            .replacingOccurrences(of: "Size=12", with: "Size=14")
            .replacingOccurrences(of: "Color=255,0,0,255", with: "Color=0,0,255,255")
            .replacingOccurrences(of: "FontSize=#Size#", with: "FontSize=18")
        guard case .applied(let summary) = skin.patch(sources: folder.texts(edited)) else {
            return t.check(false, "applied")
        }
        t.equal(summary.changedVariables, ["color", "size"])
        t.equal(samples(line.lines[0].history), lineSamples, "the line graph keeps its samples, and adds none")
        t.equal(samples(histo.primaryHistory), histoSamples, "so does the histogram")
        t.equal(line.lines[0].color, RGBA(r: 0, g: 255, b: 0, a: 255))
        t.equal(histo.primaryColor, RGBA(r: 0, g: 0, b: 255, a: 255))
        t.equal(skin.counter, 5, "the counter goes on")
        t.equal(counter.value, 4)
        t.equal(skin.variable("Size"), "30", "a value !SetVariable set stays")
        t.equal(skin.variable("Color"), "0,0,255,255", "a variable the skin did not change follows the file")
        t.equal(label.rawOption("StringAlign"), "Right", "!SetOption values stay")
        t.equal(label.rawOption("FontSize"), "44", "also over a key the file changed")
        t.equal(label.fileOption("FontSize"), "18", "which the file layer has")
        t.equal((label as? StringMeter)?.style.color, RGBA(r: 0, g: 0, b: 255, a: 255))
        t.check(skin.meter(named: "Other")?.hidden == true, "a meter a bang hid stays hidden")
        skin.update()
        t.equal(samples(line.lines[0].history), [5] + lineSamples, "the next update adds the next sample")
        t.equal(skin.counter, 6)
    }

    t.suite("Session: live patch — previews end on the new text") {
        let folder = try PatchFolder(t)
        let base = """
            [Rainmeter]
            [Variables]
            Color=255,0,0,255
            [Label]
            Meter=String
            Text=abc
            FontSize=10
            FontColor=#Color#
            SolidColor=0,0,0,0
            """
        let (skin, _) = try folder.skin(base)
        skin.update()
        skin.execute("[!SetOption Label SolidColor 9,9,9,255]", from: nil)
        skin.preview(section: "Label", ["FontSize": "40", "SolidColor": "1,1,1,255"])
        skin.previewVariables(["Color": "0,0,0,255"])
        let edited = base.replacingOccurrences(of: "FontSize=10", with: "FontSize=12\nFontWeight=700")
            .replacingOccurrences(of: "Color=255,0,0,255", with: "Color=0,255,0,255")
        guard case .applied = skin.patch(sources: folder.texts(edited)), let label = skin.meter(named: "Label") else {
            return t.check(false, "applied")
        }
        t.check(skin.isPreviewing)
        t.equal(label.rawOption("FontSize"), "40", "the preview still shows")
        t.equal(skin.variable("Color"), "0,0,0,255")
        t.equal(label.rawOption("FontWeight"), "700", "the new text shows where nothing previews")
        skin.endPreview()
        t.check(!skin.isPreviewing)
        t.equal(label.rawOption("FontSize"), "12", "the file's new value")
        t.equal(label.rawOption("SolidColor"), "9,9,9,255", "the !SetOption value from before the preview")
        t.equal(skin.variable("Color"), "0,255,0,255", "the variable's new definition")
        t.equal((label as? StringMeter)?.style.color, RGBA(r: 0, g: 255, b: 0, a: 255))
        let (reloaded, _) = try folder.skin(edited)
        reloaded.execute("[!SetOption Label SolidColor 9,9,9,255]", from: nil)
        reloaded.update()
        skin.update()
        t.equal(patchState(skin, variables: ["Color"]), patchState(reloaded, variables: ["Color"]),
                "as a reload of the new text with the same !SetOption")
    }
}
