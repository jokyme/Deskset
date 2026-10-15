import Foundation
@testable import DesksetCore

// All fixtures use the pre-extraction API so they can establish a baseline before layout moves.
private final class LayoutDriverHost: FakeHost, SkinActionPolicy {
    var bangs: [String] = []
    var textReads: [String] = []

    func skin(_ skin: Skin, allows bang: Bang) -> Bool {
        bangs.append(([bang.name] + bang.args).joined(separator: "|"))
        return true
    }

    func skin(_ skin: Skin, allowsExecuting target: String, arguments: [String]) -> Bool { false }

    override func textSize(_ text: String, style: TextStyle, wrapWidth: Double?, for skin: Skin)
        -> (width: Double, height: Double) {
        textReads.append(text)
        return super.textSize(text, style: style, wrapWidth: wrapWidth, for: skin)
    }

    override func environment(for skin: Skin) -> SkinEnvironment {
        SkinEnvironment(settingsPath: "/fixture/Settings/", programPath: "/fixture/Program/",
                        configEditor: "/fixture/Editor", locale: Locale(identifier: "en_US_POSIX"),
                        preferredLanguages: ["en"])
    }
}

private enum LayoutDriverFixtureError: Error { case utcUnavailable }

private func layoutDriverSkin(_ t: TestRunner, _ ini: String) throws -> (Skin, LayoutDriverHost) {
    let skins = t.temporaryDirectory("layout-driver").appendingPathComponent("Skins")
    let directory = skins.appendingPathComponent("Root/Sub")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("Skin.ini")
    try ini.write(to: url, atomically: true, encoding: .utf8)
    guard let utc = TimeZone(secondsFromGMT: 0) else { throw LayoutDriverFixtureError.utcUnavailable }
    let executor = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 1_798_761_598), timeZone: utc)
    executor.background.allowsUnfakedWork = false
    let host = LayoutDriverHost()
    let skin = Skin(config: "Root\\Sub", fileURL: url, skinsDirectory: skins, system: FakeSystem(), host: host)
    skin.executor = executor
    skin.skinClock = executor.clock
    skin.random = SkinRandom(seed: 1)
    skin.actionPolicy = host
    try skin.load()
    return (skin, host)
}

private enum LayoutDriverFixtures {
    static let reentrant = """
    [A]
    Meter=Image
    X=1
    W=10
    H=1
    [B]
    Meter=Image
    X=1R
    W=2
    H=1
    OnUpdateAction=[!SetOption A X 100][!UpdateMeter A]
    """

    static let laterContainer = """
    [Child]
    Meter=String
    Text=child
    Container=Late
    X=2
    Y=3
    [Late]
    Meter=Image
    X=100
    Y=50
    W=10
    H=10
    """

    static let rawAnchor = """
    [A]
    Meter=Image
    X=1000000
    W=1000000
    H=1
    [B]
    Meter=String
    X=0R
    W=1000000
    H=1
    StringAlign=Right
    Text=x
    [C]
    Meter=Image
    X=0R
    W=1
    H=1
    [Padding]
    Meter=Image
    X=-1000000
    Y=-1000000
    W=5
    H=4
    Padding=-8,-6,1,1
    """
}

/// The existing open hooks may change stored options and geometry synchronously. These changes distinguish the
/// original read points from eagerly capturing all input fields before naturalSize/anchorOffset.
private final class LayoutReadPointMeter: Meter {
    var events: [String] = []
    var previousMeter: Meter?
    var containerMeter: Meter?

    override func naturalSize() -> (width: Double, height: Double) {
        events.append("natural")
        widthOption = 11
        padding = SkinInsets(left: 1, top: 2, right: 3, bottom: 4)
        return (20, 30)
    }

    override func anchorOffset(width: Double, height: Double) -> (dx: Double, dy: Double) {
        events.append("anchor:\(Int(width)),\(Int(height))")
        containerMeter?.frame = SkinRect(x: 300, y: 400, width: 10, height: 10)
        previousMeter?.anchorX = 50
        previousMeter?.anchorY = 60
        previousMeter?.frame = SkinRect(x: 50, y: 60, width: 40, height: 70)
        xPosition = PositionValue(value: 4)
        return (-width, -height)
    }
}

func runLayoutDriverTests(_ t: TestRunner) {
    t.suite("Engine: layout driver: an action repositions the previous meter before placement") {
        let (skin, host) = try layoutDriverSkin(t, LayoutDriverFixtures.reentrant)
        defer { skin.close() }
        let a = skin.meter(named: "A")!, b = skin.meter(named: "B")!
        let before = b.drawGeneration
        t.equal(host.bangs, [])
        skin.update()
        t.equal(a.frame, SkinRect(x: 100, y: 0, width: 10, height: 1))
        t.equal(b.frame, SkinRect(x: 111, y: 0, width: 2, height: 1))
        t.equal(b.anchorX, 111)
        t.equal(skin.width, 113)
        t.equal(b.drawGeneration - before, 2, "one meter update and one changed frame, despite nested layout")
        t.equal(host.bangs, ["setoption|A|X|100", "updatemeter|A"])
        let afterFirst = b.drawGeneration
        host.bangs = []
        skin.update()
        t.equal(b.frame, SkinRect(x: 111, y: 0, width: 2, height: 1))
        t.equal(b.drawGeneration - afterFirst, 1, "second tick changes no frame")
        t.equal(host.bangs, ["setoption|A|X|100", "updatemeter|A"])
        t.equal(host.textReads, [])
    }

    t.suite("Engine: layout driver: a later container keeps every original measurement pass") {
        let (skin, host) = try layoutDriverSkin(t, LayoutDriverFixtures.laterContainer)
        defer { skin.close() }
        t.equal(host.textReads, [])
        skin.update()
        t.equal(host.textReads, ["child", "child", "child"], "interleaved placement then both layoutMeters passes")
        t.equal(skin.meter(named: "Child")?.frame, SkinRect(x: 102, y: 53, width: 35, height: 14))
        t.equal(SkinSize(width: skin.width, height: skin.height), SkinSize(width: 110, height: 60))
        host.textReads = []
        skin.layout()
        t.equal(host.textReads, ["child", "child"], "explicit layout retains its second pass")

        let (early, earlyHost) = try layoutDriverSkin(t, LayoutDriverFixtures.laterContainer)
        defer { early.close() }
        t.equal(early.resolve("[Child:X],[Child:W]", in: nil, sectionVariables: true), "102,35")
        t.equal(earlyHost.textReads, ["child", "child"], "first read lays out provisionally once, with two passes")
        t.equal(SkinSize(width: early.width, height: early.height), SkinSize(width: 0, height: 0))
        earlyHost.textReads = []
        t.equal(early.resolve("[Child:Y]", in: nil, sectionVariables: true), "53")
        t.equal(earlyHost.textReads, [], "frame readiness prevents another provisional pass")
        early.update()
        t.equal(earlyHost.textReads, ["child", "child", "child"])
        t.equal(SkinSize(width: early.width, height: early.height), SkinSize(width: 110, height: 60))
    }

    t.suite("Engine: layout driver: alignment uses the raw anchor before its separate clamp") {
        let (skin, host) = try layoutDriverSkin(t, LayoutDriverFixtures.rawAnchor)
        defer { skin.close() }
        skin.update()
        let b = skin.meter(named: "B")!
        t.equal(b.anchorX, 1_000_000)
        t.equal(b.frame, SkinRect(x: 1_000_000, y: 0, width: 1_000_000, height: 1),
                "raw 2000000 minus right-aligned width, independently clamped")
        t.equal(skin.meter(named: "C")?.frame.x, 1_000_000)
        t.equal(skin.meter(named: "Padding")?.frame, SkinRect(x: -1_000_000, y: -1_000_000, width: 0, height: 0))
        t.equal(skin.width, 16_384)
        t.equal(host.textReads, [], "explicit W and H bypass natural text measurement")
        skin.execute("[!HideMeter B][!Redraw]", from: nil)
        t.equal(b.frame, SkinRect(x: 1_000_000, y: 0, width: 0, height: 0))
        t.equal(b.anchorX, 1_000_000)
        t.equal(skin.meter(named: "C")?.frame.x, 1_000_000)
        t.equal(host.textReads, [], "hidden aligned text still needs no natural measurement")
    }

    t.suite("Engine: layout driver: natural size and alignment retain their live read points") {
        let (skin, _) = try layoutDriverSkin(t, "[Rainmeter]\n")
        defer { skin.close() }
        let previous = Meter(name: "Previous", section: IniSection(name: "Previous"), skin: skin, type: "image")
        previous.anchorX = 1
        previous.anchorY = 2
        previous.frame = SkinRect(x: 1, y: 2, width: 3, height: 4)
        let container = Meter(name: "Container", section: IniSection(name: "Container"), skin: skin, type: "image")
        container.frame = SkinRect(x: 100, y: 200, width: 10, height: 10)
        let meter = LayoutReadPointMeter(name: "Probe", section: IniSection(name: "Probe"), skin: skin, type: "probe")
        meter.previousMeter = previous
        meter.containerMeter = container
        meter.xPosition = PositionValue(value: 2)
        meter.yPosition = PositionValue(value: 3, mode: .relativeToPreviousEnd)
        let generation = meter.drawGeneration
        meter.layout(after: previous, in: container)
        t.equal(meter.events, ["natural", "anchor:15,36"], "each hook runs once and in order")
        t.equal(meter.frame, SkinRect(x: 89, y: 97, width: 15, height: 36))
        t.equal(meter.anchorX, 104, "origin 100 was read before the hook; option 4 was read after it")
        t.equal(meter.anchorY, 133, "the previous meter's current anchor 60 plus height 70 plus offset 3")
        t.equal(meter.drawGeneration - generation, 1, "only the committed frame changes this meter's drawing")
        t.equal(container.frame.x, 300, "the hook's change is real, but too late to change the captured origin")
    }
}
