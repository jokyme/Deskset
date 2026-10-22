import Foundation
@testable import DesksetCore

private final class InheritedPluginSource: SourceProvider {
    let text: String
    init(_ text: String) { self.text = text }
    func sourceText(for url: URL) -> String? { text }
}

func runInheritedPluginTests(_ t: TestRunner) {
    t.suite("Engine: inherited plugins use child and later-parent precedence") {
        let (skin, _) = try makeSkin(t, """
        [First]
        Plugin=WebParser
        [Second]
        Plugin=Plugins\\SysInfo.dll
        SysInfoType=USER_NAME
        [Empty]
        Plugin=
        [Inherited]
        Measure=Plugin
        @Inherit=First
        [Later]
        Measure=Plugin
        @Inherit=First | Second
        [Own]
        Measure=Plugin
        @Inherit=First | Second
        Plugin=PowerPlugin
        [EmptyOwn]
        Measure=Plugin
        @Inherit=First
        Plugin=
        [EmptyParent]
        Measure=Plugin
        @Inherit=First | Empty
        [Missing]
        Measure=Plugin
        [EmptyOnly]
        Measure=Plugin
        Plugin=
        """)
        t.check(skin.measure(named: "Inherited") is WebParserMeasure)
        t.check(skin.measure(named: "Later") is SysInfoMeasure)
        t.check(skin.measure(named: "Own") is PowerPluginMeasure)
        t.check(skin.measure(named: "EmptyOwn") is WebParserMeasure,
                "an empty own value keeps the existing option-inheritance fallback")
        t.check(skin.measure(named: "EmptyParent") is WebParserMeasure,
                "an empty later parent does not hide an earlier nonempty value")
        t.check(skin.measure(named: "Missing") is UnsupportedMeasure)
        t.check(skin.measure(named: "EmptyOnly") is UnsupportedMeasure)
        skin.execute("[!UpdateMeasure Later]", from: nil)
        t.equal(skin.measure(named: "Later")?.stringValue, "tester")
    }

    t.suite("Engine: inherited plugin names resolve in the child context") {
        let (skin, _) = try makeSkin(t, """
        [Variables]
        Template=Defaults
        PluginFile=Plugins\\ActionTimer.dll
        [Defaults]
        Plugin=#PluginFile#
        [Scoped]
        Plugin=#CURRENTSECTION#
        [Timer]
        Measure=Plugin
        @Inherit=#Template#
        [WebParser]
        Measure=Plugin
        @Inherit=Scoped
        [Direct]
        Measure=Plugin
        Plugin=#PluginFile#
        [BuiltIn]
        Measure=ActionTimer
        @Inherit=Scoped
        """)
        t.check(skin.measure(named: "Timer") is ActionTimerMeasure)
        t.check(skin.measure(named: "WebParser") is WebParserMeasure,
                "CURRENTSECTION is the child name, not its parent's name")
        t.check(skin.measure(named: "Direct") is ActionTimerMeasure, "legacy direct Plugin variables still work")
        t.check(skin.measure(named: "BuiltIn") is ActionTimerMeasure, "built-in Measure ignores Plugin")
    }

    t.suite("Engine: inherited plugins use the current syntax on first load and refresh") {
        let user = BuiltInVariables.environmentValue("USERNAME")!
        let source = """
        [Rainmeter]
        SyntaxVersion=(#Version#)
        [Variables]
        Version=2
        [%USERNAME%]
        Plugin=WebParser
        [\(user)]
        Plugin=SysInfo
        SysInfoType=USER_NAME
        [Feed]
        Measure=Plugin
        @Inherit=%USERNAME%
        [Explicit]
        Measure=Plugin
        @Inherit=[%USERNAME]
        """
        let (skin, _) = try makeSkin(t, source)
        defer { skin.close() }
        t.equal(skin.settings.syntaxVersion, 2)
        t.check(skin.measure(named: "Feed") is WebParserMeasure, "version 2 keeps the literal parent name")
        t.check(skin.measure(named: "Explicit") is SysInfoMeasure, "bracketed environment references still expand")
        for version in [1, 2, 1, 2] {
            skin.sourceProvider = InheritedPluginSource(source.replacingOccurrences(of: "Version=2", with: "Version=\(version)"))
            try skin.load()
            t.equal(skin.settings.syntaxVersion, version)
            if version == 1 {
                t.check(skin.measure(named: "Feed") is SysInfoMeasure, "version 1 expands the parent name on refresh")
            } else {
                t.check(skin.measure(named: "Feed") is WebParserMeasure, "refresh must not use the previous syntax")
            }
            t.check(skin.measure(named: "Explicit") is SysInfoMeasure)
        }
        skin.sourceProvider = InheritedPluginSource(source.replacingOccurrences(of: "SyntaxVersion=(#Version#)", with: ""))
        try skin.load()
        t.equal(skin.settings.syntaxVersion, 1, "an absent option restores the default")
        t.check(skin.measure(named: "Feed") is SysInfoMeasure)
    }

    t.suite("Engine: inherited plugins do not inherit section types or grandparents") {
        let (skin, _) = try makeSkin(t, """
        [Grandparent]
        Plugin=WebParser
        [Parent]
        @Inherit=Grandparent
        [Child]
        Measure=Plugin
        @Inherit=Parent
        [NoType]
        @Inherit=Child
        [MeterOnly]
        Meter=String
        @Inherit=Child
        Text=unchanged
        """)
        t.check(skin.measure(named: "Child") is UnsupportedMeasure, "inheritance is not recursive")
        t.equal(skin.measures.map(\.name), ["Child"], "Measure must be written on the child itself")
        t.check(skin.meter(named: "MeterOnly") is StringMeter)
        t.equal(skin.meters.map(\.name), ["MeterOnly"])
    }

    t.suite("Engine: inherited plugins preserve disabled, paused and fixed-type lifecycle") {
        let (skin, _) = try makeSkin(t, """
        [Variables]
        Kind=PowerPlugin
        [Defaults]
        Plugin=#Kind#
        PowerState=Percent
        DynamicVariables=1
        [Disabled]
        Measure=Plugin
        @Inherit=Defaults
        Disabled=1
        [Paused]
        Measure=Plugin
        @Inherit=Defaults
        Paused=1
        """)
        let disabled = skin.measure(named: "Disabled")!
        let paused = skin.measure(named: "Paused")!
        t.check(disabled is PowerPluginMeasure)
        t.check(paused is PowerPluginMeasure)
        skin.update()
        t.equal(disabled.value, 0)
        t.equal(paused.value, 0)
        skin.execute("[!EnableMeasure Disabled][!UnpauseMeasure Paused]", from: nil)
        skin.update()
        t.equal(disabled.value, 80)
        t.equal(paused.value, 80)
        skin.setVariable("Kind", "WebParser")
        skin.execute("[!SetOption Disabled Plugin SysInfo]", from: nil)
        skin.update()
        t.check(skin.measure(named: "Disabled") === disabled, "a dynamic option read does not replace the class")
        t.check(skin.measure(named: "Paused") === paused)
        t.equal(disabled.value, 80)
        t.equal(paused.value, 80)
        try skin.load()
        t.check(skin.measure(named: "Disabled") is PowerPluginMeasure, "refresh selects from the file again")
        t.equal(skin.measure(named: "Disabled")?.disabled, true)
    }

    t.suite("Engine: inherited WebParser delivers JSON children without network access") {
        let (prepared, host) = try makeSkin(t, """
        [Defaults]
        Plugin=WebParser
        [Feed]
        Measure=Plugin
        @Inherit=Defaults
        URL=file://#CURRENTPATH#feed.json
        JsonPointer=1
        [Value]
        Measure=Plugin
        @Inherit=Defaults
        URL=[Feed]
        JsonPointer=/weather/temperature
        [Label]
        Meter=String
        MeasureName=Value
        Text=%1
        """, files: ["Root/Sub/feed.json": "{\"weather\":{\"temperature\":21}}"])
        let executor = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
        executor.background.allowsUnfakedWork = false
        let skin = Skin(config: prepared.config, fileURL: prepared.fileURL, skinsDirectory: prepared.skinsDirectory,
                        system: FakeSystem(), host: host)
        skin.runInVirtualTime(executor)
        try skin.load()
        skin.update()
        executor.runUntilIdle()
        skin.update()
        t.equal(skin.measure(named: "Value")?.stringValue, "21")
        t.equal(text(skin, "Label"), "21")
        t.equal((skin.measure(named: "Feed") as? WebParserMeasure)?.fetchCount, 1)
        t.equal(executor.background.unverifiable.count, 0, "every input was provided offline")
        t.equal(skin.issues, [])
        skin.close()
    }

    t.suite("Engine: inherited plugin source changes require a reload") {
        let initial = """
        [Defaults]
        Plugin=WebParser
        [Feed]
        Measure=Plugin
        @Inherit=Defaults
        """
        let (skin, _) = try makeSkin(t, initial)
        let original = skin.measure(named: "Feed")!
        let changed = initial.replacingOccurrences(of: "Plugin=WebParser", with: "Plugin=PowerPlugin")
        t.equal(skin.patch(sources: InheritedPluginSource(changed)),
                .needsReload(.option(section: "Feed", key: "plugin")))
        t.check(skin.measure(named: "Feed") === original, "a rejected live patch leaves the running measure alone")
        skin.sourceProvider = InheritedPluginSource(changed)
        try skin.load()
        t.check(skin.measure(named: "Feed") is PowerPluginMeasure)
    }

    t.suite("Engine: inherited plugin dispatch keeps the unchanged legacy fixture working") {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("TestSkins")
        let host = FakeHost()
        let skin = Skin(config: "Engine\\Compat", fileURL: root.appendingPathComponent("Engine/Compat/Legacy.ini"),
                        skinsDirectory: root, system: FakeSystem(), host: host)
        try skin.load()
        skin.update()
        t.check(skin.measure(named: "MeasureUser") is SysInfoMeasure)
        t.check(skin.measure(named: "MeasureHost") is SysInfoMeasure)
        t.check(skin.measure(named: "MeasureFinder") is ProcessMeasure)
        t.equal(skin.measure(named: "MeasureUser")?.stringValue, "tester")
        skin.close()
    }
}
