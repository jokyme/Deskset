import Foundation
@testable import DesksetCore

// These fixtures use the existing Skin API and run unchanged before and after typed local dispatch.
private final class LocalActionEffectsHost: FakeHost {
    override func environment(for skin: Skin) -> SkinEnvironment {
        SkinEnvironment(settingsPath: "/fixture/Settings/", programPath: "/fixture/Program/",
                        configEditor: "/fixture/Editor", locale: Locale(identifier: "en_US_POSIX"),
                        preferredLanguages: ["en"])
    }
}

private enum LocalActionEffectsError: Error { case utcUnavailable }

private func localActionEffectsSkin(_ t: TestRunner, _ ini: String) throws -> (Skin, LocalActionEffectsHost) {
    let skins = t.temporaryDirectory("local-action-effects").appendingPathComponent("Skins")
    let directory = skins.appendingPathComponent("Root/Sub")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("Skin.ini")
    try ini.write(to: url, atomically: true, encoding: .utf8)
    guard let utc = TimeZone(secondsFromGMT: 0) else { throw LocalActionEffectsError.utcUnavailable }
    let executor = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 1_798_761_598), timeZone: utc)
    executor.background.allowsUnfakedWork = false
    let host = LocalActionEffectsHost()
    let skin = Skin(config: "Root\\Sub", fileURL: url, skinsDirectory: skins, system: FakeSystem(), host: host)
    skin.executor = executor
    skin.skinClock = executor.clock
    skin.random = SkinRandom(seed: 1)
    try skin.load()
    t.equal(host.logs, [], "the fixture loads without actions or diagnostics")
    return (skin, host)
}

private enum LocalActionEffectsFixtures {
    static let group = """
    [Rainmeter]
    Update=-1
    [StepA]
    Measure=Calc
    Formula=StepA+1
    Group=G
    OnUpdateAction=[!SetOption StepB Group Away][!UpdateMeasure StepB][!Log "A=[StepA],B=[StepB]"]
    [StepB]
    Measure=Calc
    Formula=StepB+1
    Group=G
    OnUpdateAction=[!Log "B=[StepB]"]
    """

    static let values = """
    [Rainmeter]
    Update=-1
    [ValueSource]
    Measure=Calc
    Formula=ValueSource+1
    [Box]
    Meter=Image
    Group=Boxes
    W=1
    H=1
    [Peer]
    Meter=Image
    Group=Boxes
    W=1
    H=1
    """
}

func runActionEffectsTests(_ t: TestRunner) {
    t.suite("Engine: local action effects: a group update retains its selected members through synchronous reentry") {
        let (skin, host) = try localActionEffectsSkin(t, LocalActionEffectsFixtures.group)
        defer { skin.close() }
        skin.perform(Bang(name: "updatemeasuregroup", args: ["g"]))
        t.equal(host.logs, ["Notice: B=1", "Notice: A=1,B=1", "Notice: B=2"],
                "B is updated by A's action and then by the original group snapshot")
        t.equal(skin.measure(named: "StepA")?.value, 1)
        t.equal(skin.measure(named: "StepB")?.value, 2)
        t.equal(skin.measure(named: "StepB")?.groups, ["away"])

        skin.perform(Bang(name: "updatemeasuregroup", args: ["G"]))
        t.equal(host.logs, ["Notice: B=1", "Notice: A=1,B=1", "Notice: B=2",
                           "Notice: B=3", "Notice: A=2,B=3"],
                "the next group action selects again and no longer contains B")
        t.equal(skin.measure(named: "StepA")?.value, 2)
        t.equal(skin.measure(named: "StepB")?.value, 3)
        skin.perform(Bang(name: "updatemeasuregroup", args: ["away"]))
        t.equal(host.logs.last, "Notice: B=4")
        t.equal(skin.measure(named: "StepB")?.value, 4)
    }

    t.suite("Engine: local action effects: values stay current per action while magic and measure formulas stay raw") {
        let (skin, host) = try localActionEffectsSkin(t, LocalActionEffectsFixtures.values)
        defer { skin.close() }
        let firstActions = #"[!UpdateMeasure ValueSource][!SetOption Box W "(ValueSource*2)"]"#
            + #"[!SetVariable First "(ValueSource*3)"][!SetVariable Literal """(ValueSource*5)"""]"#
            + #"[!Log "one=[ValueSource]; first=[#First]; literal=[#Literal]"][!UpdateMeasure ValueSource]"#
            + #"[!SetOptionGroup Boxes H "(ValueSource*4)"][!SetVariable Second "(ValueSource*3)"]"#
            + #"[!Log "two=[ValueSource]; second=[#Second]"]"#
        skin.execute(firstActions, from: nil)
        t.equal(host.logs, ["Notice: one=1; first=3; literal=(ValueSource*5)", "Notice: two=2; second=6"],
                "later actions observe earlier measure updates and variable writes")
        t.equal(skin.variable("First"), "3")
        t.equal(skin.variable("Second"), "6")
        t.equal(skin.variable("Literal"), "(ValueSource*5)")
        t.equal(skin.meter(named: "Box")?.rawOption("W"), "2")
        t.equal(skin.meter(named: "Peer")?.rawOption("W"), "1", "the named target does not affect its peer")
        t.equal(skin.meter(named: "Box")?.rawOption("H"), "8")
        t.equal(skin.meter(named: "Peer")?.rawOption("H"), "8", "the group applies one current value to both")

        let secondActions = #"[!SetOption ValueSource Formula "(ValueSource+3)"][!UpdateMeasure ValueSource]"#
            + #"[!SetVariable Third "(ValueSource*3)"][!SetOption Box W """(ValueSource*2)"""]"#
            + #"[!Log "three=[ValueSource]; third=[#Third]"]"#
        skin.execute(secondActions, from: nil)
        t.equal(skin.variable("Third"), "15")
        t.equal(host.logs.last, "Notice: three=5; third=15")
        t.equal(skin.measure(named: "ValueSource")?.rawOption("Formula"), "(ValueSource+3)")
        t.equal(skin.meter(named: "Box")?.rawOption("W"), "(ValueSource*2)")
        skin.perform(Bang(name: "updatemeasure", args: ["ValueSource"]))
        t.equal(skin.measure(named: "ValueSource")?.value, 8,
                "a second evaluation proves the Formula was not frozen at bang time")
    }
}
