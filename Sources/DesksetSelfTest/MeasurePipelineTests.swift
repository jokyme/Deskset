import Foundation
@testable import DesksetCore

// These fixtures run against the existing Measure implementation before its action phase moves. The policy sees
// resolved bangs before their effects; the host appends effects to the same log, including synchronous nested work.
private enum MeasurePipelineEvent: Equatable {
    case bang(String, [String])
    case log(SkinLogLevel, String)
    case host(String, [String])
    case execution(String, [String])
    case closed
    case redraw
}

private final class MeasurePipelineHost: FakeHost, SkinActionPolicy {
    var events: [MeasurePipelineEvent] = []
    var closesOnRefresh = false

    func skin(_ skin: Skin, allows bang: Bang) -> Bool {
        events.append(.bang(bang.name, bang.args))
        return true
    }

    func skin(_ skin: Skin, allowsExecuting target: String, arguments: [String]) -> Bool {
        events.append(.execution(target, arguments))
        return true
    }

    override func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {
        events.append(.log(level, message))
        super.skin(skin, log: message, level: level)
    }

    override func skin(_ skin: Skin, handle bang: Bang) -> Bool {
        events.append(.host(bang.name, bang.args))
        if closesOnRefresh && bang.name == "refresh" {
            skin.close()
            events.append(.closed)
        }
        return super.skin(skin, handle: bang)
    }

    override func skinNeedsDisplay(_ skin: Skin) {
        events.append(.redraw)
        super.skinNeedsDisplay(skin)
    }

    override func environment(for skin: Skin) -> SkinEnvironment {
        SkinEnvironment(settingsPath: "/fixture/Settings/", programPath: "/fixture/Program/",
                        configEditor: "/fixture/Editor", locale: Locale(identifier: "en_US_POSIX"),
                        preferredLanguages: ["en"])
    }
}

private enum MeasurePipelineFixtureError: Error { case utcUnavailable }

private func measurePipelineSkin(_ t: TestRunner, _ ini: String, closesOnRefresh: Bool = false)
    throws -> (Skin, MeasurePipelineHost) {
    let skins = t.temporaryDirectory("measure-pipeline").appendingPathComponent("Skins")
    let directory = skins.appendingPathComponent("Root/Sub")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("Skin.ini")
    try ini.write(to: url, atomically: true, encoding: .utf8)
    guard let utc = TimeZone(secondsFromGMT: 0) else { throw MeasurePipelineFixtureError.utcUnavailable }
    let host = MeasurePipelineHost()
    host.closesOnRefresh = closesOnRefresh
    let skin = Skin(config: "Root\\Sub", fileURL: url, skinsDirectory: skins, system: FakeSystem(), host: host)
    skin.skinClock = .fixed(Date(timeIntervalSince1970: 1_798_761_598), timeZone: utc, uptime: 86_400)
    skin.random = SkinRandom(seed: 1)
    skin.actionPolicy = host
    try skin.load()
    t.equal(host.events, [], "the fixture loads without actions or diagnostics")
    return (skin, host)
}

// Kept as literal inputs so the pre-extraction binary and the extracted implementation take the same text.
private enum MeasurePipelineFixtures {
    static let synchronous = """
    [Variables]
    V=0

    [Proxy]
    Measure=Calc
    Formula=#V#
    DynamicVariables=1
    OnUpdateAction=[!Log "proxy:[Proxy:]"]

    [Gate]
    Measure=Calc
    Formula=1
    DynamicVariables=1
    IfCondition=1
    IfTrueAction=[!SetVariable V 7][!UpdateMeasure Proxy][!Log "after-proxy:[Proxy:]:[#V]"]
    IfCondition2=Proxy=7
    IfTrueAction2=[!Log "next:[Proxy:]"]
    IfFalseAction2=[!Log unexpected-stale-proxy]
    IfCondition3=#V#=7
    IfTrueAction3=[!Log "macro-reread:#V#:[#V]"]
    IfFalseAction3=[!Log "macro-frozen:#V#:[#V]"]
    OnUpdateAction=[!Log "gate:#V#:[#V]"]
    """

    static let reentrant = """
    [Self]
    Measure=Calc
    Formula=Self+1
    IfCondition=Self=1
    IfTrueAction=[!Log enter][!UpdateMeasure Self][!Log exit]
    IfAboveValue=1
    IfAboveAction=[!Log "above:[Self:]"]
    IfMatch=^2$
    IfMatchAction=[!Log "match:[Self:]"]
    IfNotMatchAction=[!Log "not-match:[Self:]"]
    OnChangeAction=[!Log "change:[Self:]"]
    OnUpdateAction=[!Log "update:[Self:]"]
    """

    static let disabled = """
    [Gate]
    Measure=String
    String=1
    IfCondition=Gate=1
    IfTrueAction=[!DisableMeasure Gate][!Log "disabled:[Gate:]:[Gate]"]
    IfCondition2=Gate=0
    IfTrueAction2=[!Log later-condition]
    IfFalseAction2=[!Log unexpected-nonzero]
    IfAboveValue=-1
    IfAboveAction=[!Log "threshold:[Gate:]"]
    IfMatch=^1$
    IfMatchAction=[!Log "kept-string:[Gate]"]
    OnChangeAction=[!Log unexpected-initial-change]
    OnUpdateAction=[!Log "gate-finished:[Gate:]:[Gate]"]

    [Show]
    Meter=String
    Text=[Gate:]/[Gate]
    DynamicVariables=1
    X=3
    Y=4
    W=21
    H=14
    """

    static let closing = """
    [Rainmeter]
    OnCloseAction=[!Log close-action]
    OnUpdateAction=[!Log forbidden-skin-update]

    [Gate]
    Measure=Calc
    Formula=1
    IfCondition=1
    IfTrueAction=[!Refresh][!Log forbidden-current-action-tail]
    IfCondition2=MissingAfterClose > 0
    IfTrueAction2=[!Log forbidden-invalid-condition]
    IfCondition3=1
    IfTrueAction3=[!Log forbidden-next-condition]
    IfAboveValue=0
    IfAboveAction=[!Log forbidden-threshold]
    IfMatch=[
    IfMatchAction=[!Log forbidden-match]
    OnChangeAction=[!Log forbidden-change]
    OnUpdateAction=[!Log forbidden-measure-update]

    [Later]
    Measure=Calc
    Formula=9
    OnUpdateAction=[!Log forbidden-later-measure]

    [Show]
    Meter=String
    Text=after
    W=35
    H=14
    OnUpdateAction=[!Log forbidden-meter]
    """
}

func runMeasurePipelineTests(_ t: TestRunner) {
    t.suite("Engine: measure pipeline: synchronous actions precede the next condition") {
        let (skin, host) = try measurePipelineSkin(t, MeasurePipelineFixtures.synchronous)
        t.equal(skin.measures.map(\.name), ["Proxy", "Gate"])
        skin.update()
        t.equal(host.events, [
            .bang("log", ["proxy:0"]), .log(.notice, "proxy:0"),
            .bang("setvariable", ["V", "7"]),
            .bang("updatemeasure", ["Proxy"]),
            .bang("log", ["proxy:7"]), .log(.notice, "proxy:7"),
            .bang("log", ["after-proxy:7:7"]), .log(.notice, "after-proxy:7:7"),
            .bang("log", ["next:7"]), .log(.notice, "next:7"),
            .bang("log", ["macro-frozen:0:7"]), .log(.notice, "macro-frozen:0:7"),
            .bang("log", ["gate:0:7"]), .log(.notice, "gate:0:7"),
            .redraw,
        ], "the next formula sees the nested update; #V# still came from the earlier option read")
        t.equal(skin.variable("V"), "7")
        t.close(skin.measure(named: "Proxy")?.value ?? .nan, 7)
        t.equal(skin.measure(named: "Proxy")?.updateCount, 2)
        t.equal(skin.measure(named: "Gate")?.updateCount, 1)
        t.equal(skin.updateCount, 1)

        host.events.removeAll()
        skin.update()
        t.equal(host.events, [
            .bang("log", ["proxy:7"]), .log(.notice, "proxy:7"),
            .bang("log", ["macro-reread:7:7"]), .log(.notice, "macro-reread:7:7"),
            .bang("log", ["gate:7:7"]), .log(.notice, "gate:7:7"),
            .redraw,
        ], "dynamic rereading preserves condition edges and only the macro condition changes")
        t.equal(skin.measure(named: "Proxy")?.updateCount, 3)
        t.equal(skin.measure(named: "Gate")?.updateCount, 2)
        t.equal(skin.updateCount, 2)
        t.equal(host.redraws, 2)
    }

    t.suite("Engine: measure pipeline: self update keeps the threshold armed on the next tick") {
        let (skin, host) = try measurePipelineSkin(t, MeasurePipelineFixtures.reentrant)
        skin.update()
        t.equal(host.events, [
            .bang("log", ["enter"]), .log(.notice, "enter"),
            .bang("updatemeasure", ["Self"]),
            .bang("log", ["above:2"]), .log(.notice, "above:2"),
            .bang("log", ["match:2"]), .log(.notice, "match:2"),
            .bang("log", ["update:2"]), .log(.notice, "update:2"),
            .bang("log", ["exit"]), .log(.notice, "exit"),
            .bang("log", ["update:2"]), .log(.notice, "update:2"),
            .redraw,
        ], "nested actions finish before the outer condition returns; the initial baseline is not a change")
        t.close(skin.measure(named: "Self")?.value ?? .nan, 2)
        t.equal(skin.measure(named: "Self")?.updateCount, 2)
        t.equal(skin.updateCount, 1)

        host.events.removeAll()
        skin.update()
        t.equal(host.events, [
            .bang("log", ["not-match:3"]), .log(.notice, "not-match:3"),
            .bang("log", ["change:3"]), .log(.notice, "change:3"),
            .bang("log", ["update:3"]), .log(.notice, "update:3"),
            .redraw,
        ], "capturing value before IfCondition would re-arm the outer threshold and add above:3 here")
        t.close(skin.measure(named: "Self")?.value ?? .nan, 3)
        t.equal(skin.measure(named: "Self")?.updateCount, 3)
        t.equal(skin.updateCount, 2)
        t.equal(host.redraws, 2)
    }

    t.suite("Engine: measure pipeline: disabling a measure does not truncate its current actions") {
        let (skin, host) = try measurePipelineSkin(t, MeasurePipelineFixtures.disabled)
        skin.update()
        t.equal(host.events, [
            .bang("disablemeasure", ["Gate"]),
            .bang("log", ["disabled:0:1"]), .log(.notice, "disabled:0:1"),
            .bang("log", ["later-condition"]), .log(.notice, "later-condition"),
            .bang("log", ["threshold:0"]), .log(.notice, "threshold:0"),
            .bang("log", ["kept-string:1"]), .log(.notice, "kept-string:1"),
            .bang("log", ["gate-finished:0:1"]), .log(.notice, "gate-finished:0:1"),
            .redraw,
        ], "the live number becomes zero while the string and remaining action phases survive")
        t.equal(skin.measure(named: "Gate")?.disabled, true)
        t.close(skin.measure(named: "Gate")?.value ?? .nan, 0)
        t.equal(skin.measure(named: "Gate")?.stringValue, "1")
        t.equal(skin.measure(named: "Gate")?.updateCount, 1)
        t.equal(text(skin, "Show"), "0/1")
        t.equal(skin.meter(named: "Show")?.frame, SkinRect(x: 3, y: 4, width: 21, height: 14))

        host.events.removeAll()
        skin.update()
        t.equal(host.events, [.redraw], "the next scheduled update exits before the action phase")
        t.close(skin.measure(named: "Gate")?.value ?? .nan, 0)
        t.equal(skin.measure(named: "Gate")?.stringValue, "1")
        t.equal(skin.measure(named: "Gate")?.updateCount, 1)
        t.equal(skin.updateCount, 2)
        t.equal(host.redraws, 2)
    }

    t.suite("Engine: measure pipeline: refresh stops effects but retains existing post-close diagnostics") {
        let (skin, host) = try measurePipelineSkin(t, MeasurePipelineFixtures.closing, closesOnRefresh: true)
        skin.update()
        t.equal(host.events, [
            .bang("refresh", []), .host("refresh", []),
            .bang("log", ["close-action"]), .log(.notice, "close-action"),
            .closed,
            .log(.error, "[Gate] cannot evaluate IfCondition: MissingAfterClose > 0"),
            .log(.error, "[Gate] invalid IfMatch pattern: ["),
        ], "mechanical extraction preserves the old diagnostics after close; no later bang reaches the policy")
        t.check(skin.isClosed)
        t.equal(skin.measure(named: "Gate")?.updateCount, 1)
        t.close(skin.measure(named: "Gate")?.value ?? .nan, 1)
        t.equal(skin.measure(named: "Later")?.updateCount, 0)
        t.close(skin.measure(named: "Later")?.value ?? .nan, 0)
        t.equal(skin.updateCount, 0)
        t.equal(host.redraws, 0)
        t.equal(host.handled.map(\.name), ["refresh"])

        host.events.removeAll()
        skin.update()
        t.equal(host.events, [], "a second update of the closed skin does no further work")
        t.equal(skin.measure(named: "Gate")?.updateCount, 1)
        t.equal(skin.measure(named: "Later")?.updateCount, 0)
        t.equal(host.redraws, 0)
    }
}
