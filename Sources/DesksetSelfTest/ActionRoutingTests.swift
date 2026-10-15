import Foundation
@testable import DesksetCore

// Only the existing Skin API is used, so these observations also run before routing is extracted.
private enum ActionRoutingEvent: Equatable {
    case handle(String, Bang)
    case forward(String, Bang, String)
    case log(String, String)
}

private final class ActionRoutingTrace {
    var events: [ActionRoutingEvent] = []
}

private final class ActionRoutingHost: FakeHost, SkinActionPolicy {
    let label: String
    let trace: ActionRoutingTrace
    var onLog: ((Skin, String) -> Void)?
    var denied: Set<String> = []
    var policyCalls: [Bang] = []

    init(_ label: String, trace: ActionRoutingTrace) {
        self.label = label
        self.trace = trace
    }

    override func skin(_ skin: Skin, handle bang: Bang) -> Bool {
        trace.events.append(.handle(label, bang))
        return true
    }

    override func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {
        trace.events.append(.forward(label, bang, config))
    }

    override func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {
        trace.events.append(.log(label, message))
        onLog?(skin, message)
    }

    func skin(_ skin: Skin, allows bang: Bang) -> Bool {
        policyCalls.append(bang)
        return !denied.contains(bang.name)
    }

    func skin(_ skin: Skin, allowsExecuting target: String, arguments: [String]) -> Bool { false }

    override func environment(for skin: Skin) -> SkinEnvironment {
        SkinEnvironment(settingsPath: "/fixture/Settings/", programPath: "/fixture/Program/",
                        configEditor: "/fixture/Editor", locale: Locale(identifier: "en_US_POSIX"),
                        preferredLanguages: ["en"])
    }
}

private enum ActionRoutingFixtureError: Error { case utcUnavailable }

private func actionRoutingSkin(_ t: TestRunner, _ ini: String)
    throws -> (Skin, ActionRoutingHost, VirtualTimeExecutor) {
    let skins = t.temporaryDirectory("action-routing").appendingPathComponent("Skins")
    let directory = skins.appendingPathComponent("Root/Sub")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("Skin.ini")
    try ini.write(to: url, atomically: true, encoding: .utf8)
    guard let utc = TimeZone(secondsFromGMT: 0) else { throw ActionRoutingFixtureError.utcUnavailable }
    let executor = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 1_798_761_598), timeZone: utc)
    executor.background.allowsUnfakedWork = false
    let host = ActionRoutingHost("first", trace: ActionRoutingTrace())
    let skin = Skin(config: "Root\\Sub", fileURL: url, skinsDirectory: skins, system: FakeSystem(), host: host)
    skin.executor = executor
    skin.skinClock = executor.clock
    skin.random = SkinRandom(seed: 1)
    try skin.load()
    t.equal(host.trace.events, [], "the fixture loads without actions or diagnostics")
    return (skin, host, executor)
}

private enum ActionRoutingFixtures {
    static let plain = """
    [Rainmeter]
    Update=-1
    [Variables]
    V=initial
    [Box]
    Meter=Image
    W=1
    H=1
    """

    static let reentrant = """
    [Rainmeter]
    Update=-1
    [RouteValue]
    Measure=Calc
    Formula=RouteValue+1
    OnUpdateAction=[!Log boundary]
    """
}

func runActionRoutingTests(_ t: TestRunner) {
    t.suite("Engine: action routing: config trimming preserves arguments and direct bang names") {
        let (skin, host, _) = try actionRoutingSkin(t, ActionRoutingFixtures.plain)
        defer { skin.close() }
        skin.perform(Bang(name: "setvariable", args: ["Own", "7", " /rOoT/sUb/ ", "discarded"]))
        t.equal(skin.variable("Own"), "7", "own Config is trimmed and compared case-insensitively")
        skin.perform(Bang(name: "setvariable", args: ["Blank", "8", " /\\ ", "discarded"]))
        t.equal(skin.variable("Blank"), "8", "an empty normalized Config still runs locally")
        skin.execute(#"[!SetVariable Literal """(1+2)""" "Root/Sub/" discarded]"#, from: nil)
        t.equal(skin.variable("Literal"), "(1+2)", "truncating Config does not change magic-argument indices")

        skin.perform(Bang(name: "setvariable", args: ["Elsewhere", "(2+3)", " /Other/Child/ ", "discarded"]))
        t.equal(skin.variable("Elsewhere"), nil, "another Config is not evaluated here")
        let direct = Bang(name: "SetVariable", args: ["Case", "9", "Root/Sub", "kept"])
        skin.perform(direct)
        t.equal(skin.variable("Case"), nil, "direct Bang names are not canonicalized again")
        let window = Bang(name: "move", args: ["1", "2", " Root/Sub/ ", "kept"])
        skin.perform(window)
        t.equal(host.trace.events, [
            .forward("first", Bang(name: "setvariable", args: ["Elsewhere", "(2+3)"]), "Other/Child"),
            .handle("first", direct),
            .handle("first", window),
        ], "only local bangs lose Config; host bangs keep their original arguments")
    }

    t.suite("Engine: action routing: all configs uses the host after local reentry even when it closes") {
        let (skin, first, _) = try actionRoutingSkin(t, ActionRoutingFixtures.reentrant)
        defer { skin.close() }
        let second = ActionRoutingHost("second", trace: first.trace)
        first.onLog = { skin, message in
            guard message == "boundary" else { return }
            skin.perform(Bang(name: "setvariable", args: ["Nested", "done"]))
            skin.host = second
        }
        let forwarded = Bang(name: "updatemeasure", args: ["RouteValue"])
        skin.execute("[!UpdateMeasure RouteValue *][!SetVariable Tail 1]", from: nil)
        t.equal(skin.measure(named: "RouteValue")?.value, 1)
        t.equal(skin.variable("Nested"), "done")
        t.equal(skin.variable("Tail"), "1")
        t.equal(first.trace.events, [.log("first", "boundary"), .forward("second", forwarded, "*")],
                "the synchronous local action finishes before the current host receives the stripped bang")

        first.onLog = nil
        skin.host = nil
        skin.perform(Bang(name: "updatemeasure", args: ["RouteValue", "*"]))
        t.equal(skin.measure(named: "RouteValue")?.value, 2, "a missing host does not skip the local operation")
        t.equal(first.trace.events.count, 2, "the preceding host was not retained for the next operation")

        skin.host = second
        second.onLog = { skin, message in if message == "boundary" { skin.close() } }
        skin.execute("[!UpdateMeasure RouteValue *][!SetVariable Forbidden 1]", from: nil)
        t.equal(skin.measure(named: "RouteValue")?.value, 3)
        t.equal(skin.variable("Forbidden"), nil, "closing stops the later action")
        t.equal(first.trace.events, [
            .log("first", "boundary"), .forward("second", forwarded, "*"),
            .log("second", "boundary"), .forward("second", forwarded, "*"),
        ], "closing inside the local operation does not suppress its existing forward")
    }

    t.suite("Engine: action routing: direct Delay is ignored and parsed Delay retains policy and scheduling") {
        let (skin, host, executor) = try actionRoutingSkin(t, ActionRoutingFixtures.plain)
        defer { skin.close() }
        skin.actionPolicy = host
        let delay = Bang(name: "delay", args: ["0"])
        skin.perform(delay)
        t.equal(host.policyCalls, [delay], "direct perform still asks the policy")
        t.equal(executor.pendingCount, 0)
        t.equal(host.trace.events, [])

        let mixedCase = Bang(name: "Delay", args: ["0"])
        skin.perform(mixedCase)
        t.equal(host.trace.events, [.handle("first", mixedCase)], "only the original canonical delay is ignored")
        host.policyCalls = []
        host.trace.events = []
        skin.execute("[!SetVariable V before][!Delay 0][!SetVariable V after][!Log finished]", from: nil)
        t.equal(skin.variable("V"), "before")
        t.equal(host.policyCalls, [Bang(name: "setvariable", args: ["V", "before"]), delay],
                "later actions are not resolved or sent to the policy early")
        t.equal(executor.pendingCount, 1)
        executor.advance(by: 0.015)
        t.equal(skin.variable("V"), "before", "the rest waits at least 16 ms")
        executor.advance(by: 0.001)
        t.equal(skin.variable("V"), "after")
        t.equal(executor.pendingCount, 0)
        t.equal(host.trace.events, [.log("first", "finished")])
        t.equal(host.policyCalls, [
            Bang(name: "setvariable", args: ["V", "before"]), delay,
            Bang(name: "setvariable", args: ["V", "after"]), Bang(name: "log", args: ["finished"]),
        ])

        host.denied = ["delay"]
        skin.execute("[!Delay 100][!SetVariable AllowedTail 1]", from: nil)
        t.equal(skin.variable("AllowedTail"), "1", "a refused delay is skipped before routing or scheduling")
        t.equal(executor.pendingCount, 0)
    }
}
