import AppKit
import DesksetCore

/// These old-API fixtures distinguish a live host query from the companions' existing first-use weak bindings.
/// No window, weather transport, location service or external program is created.
enum ServiceHostLookupSelfTests {
    static func run(_ t: AppTestRunner) {
        glassTests(t)
        inputTests(t)
        weatherTests(t)
    }

    private static func glassTests(_ t: AppTestRunner) {
        t.suite("App: host service lookup: FrostedGlass binds at first use and keeps the original weak channel") {
            let initial = Channel()
            var first: Channel? = Channel()
            weak var releasedFirst = first
            let replacement = Channel()
            let (skin, executor) = try fixture(t, host: initial)
            var measure: FrostedGlassMeasure? = FrostedGlassMeasure(name: "Glass", section: MediaUITests.section("Glass", [
                ("Type", "Acrylic"), ("Corner", "Round"),
            ]), skin: skin, type: "frostedglass")
            weak var releasedMeasure = measure
            defer { measure = nil; skin.close() }
            measure?.readOptions()
            t.equal(initial.glass, [], "reading options does not take the channel")
            skin.host = first
            t.equal(measure?.computeValue(), 1)
            t.equal(initial.glass, [], "the constructor's host was not captured")
            t.equal(first?.glass, ["enabled"])

            skin.host = replacement
            measure?.execute(command: "DisableBlur")
            t.equal(first?.glass, ["enabled", "disabled"], "a new style still goes to the first-use channel")
            t.equal(replacement.glass, [], "a host replacement does not rebind an existing backdrop")
            first = nil
            t.check(releasedFirst == nil, "the measure's channel does not retain its host")
            measure?.execute(command: "EnableBlur")
            t.equal(replacement.glass, [], "an expired channel is not replaced on the next style change")
            measure = nil
            t.check(releasedMeasure == nil)
            t.equal(replacement.glass, [], "cleanup cannot remove a replacement host's backdrop")

            // A first-use lookup that found no channel is also final; a later host is not a retry trigger.
            skin.host = nil
            let absent = FrostedGlassMeasure(name: "Absent", section: MediaUITests.section("Absent", [
                ("Type", "Acrylic"),
            ]), skin: skin, type: "frostedglass")
            absent.readOptions()
            t.equal(absent.computeValue(), 1)
            skin.host = replacement
            absent.execute(command: "DisableBlur")
            t.equal(replacement.glass, [], "first-use nil remains unbound")
            let fresh = FrostedGlassMeasure(name: "Fresh", section: MediaUITests.section("Fresh", [
                ("Type", "Acrylic"),
            ]), skin: skin, type: "frostedglass")
            fresh.readOptions()
            t.equal(fresh.computeValue(), 1)
            t.equal(replacement.glass, ["enabled"], "control: a new measure can use the replacement channel")
            t.equal(executor.background.unverifiable, [])
            t.equal(executor.background.outstanding, 0)
            t.equal(initial.unexpected + replacement.unexpected, [])
            withExtendedLifetime((initial, replacement)) {}
        }
    }

    private static func inputTests(_ t: AppTestRunner) {
        t.suite("App: host service lookup: InputText keeps its first prompt channel through replacement and release") {
            let saved = InputTextMeasure.promptFactory
            InputTextMeasure.promptFactory = nil
            defer { InputTextMeasure.promptFactory = saved }
            let initial = Channel()
            var first: Channel? = Channel()
            weak var releasedFirst = first
            let replacement = Channel()
            let (skin, executor) = try fixture(t, host: initial)
            var measure: InputTextMeasure? = input(skin)
            defer { measure = nil; skin.close() }
            skin.setVariable("Result", "old")
            skin.setVariable("Dismissed", "0")
            measure?.readOptions()
            t.equal(initial.shown.count, 0)
            skin.host = first
            measure?.execute(command: "ExecuteBatch 1")
            t.equal(first?.shown.count, 1)
            t.equal(first?.shown.first?.defaultValue, "entry")
            t.equal(initial.shown.count, 0, "the host is first read when a prompt is needed")
            t.equal(measure?.isPrompting, true)

            skin.host = replacement
            first?.answer(1, "alpha")
            t.equal(skin.variable("Result"), "alpha", "the original prompt answers on the skin's owner")
            t.equal(measure?.isPrompting, false)
            measure?.execute(command: "ExecuteBatch 1")
            t.equal(first?.shown.count, 2, "the next batch reuses its existing prompt")
            t.equal(replacement.shown.count, 0)
            first?.answer(2, "beta")
            t.equal(skin.variable("Result"), "beta")
            first = nil
            t.check(releasedFirst == nil, "the kept prompt holds only a weak channel")
            measure?.execute(command: "ExecuteBatch 1")
            t.equal(measure?.isPrompting, false, "an expired channel dismisses synchronously")
            t.equal(skin.variable("Dismissed"), "1")
            t.equal(skin.variable("Result"), "beta", "dismissal does not submit another value")
            t.equal(replacement.shown.count, 0, "an existing prompt does not rebind to a new host")
            measure = nil

            // A new measure may use the new host. Its destruction cancels that box, and a late answer is inert.
            measure = input(skin)
            weak var releasedMeasure = measure
            measure?.readOptions()
            measure?.execute(command: "ExecuteBatch 1")
            t.equal(replacement.shown.count, 1)
            let late = replacement.answers[1]
            t.check(late != nil, "the late-answer control is a real, open callback")
            measure = nil
            t.check(releasedMeasure == nil)
            t.equal(replacement.cancelled, [1])
            late?("late")
            t.equal(skin.variable("Result"), "beta", "a cancelled prompt cannot revive the measure")
            t.equal(executor.background.unverifiable, [])
            t.equal(executor.background.outstanding, 0)
            t.equal(initial.unexpected + replacement.unexpected, [])
            withExtendedLifetime((initial, replacement)) {}
        }
    }

    private static func input(_ skin: Skin) -> InputTextMeasure {
        InputTextMeasure(name: "Input", section: MediaUITests.section("Input", [
            ("DefaultValue", "entry"), ("Command1", "[!SetVariable Result \"$UserInput$\"]"),
            ("OnDismissAction", "[!SetVariable Dismissed 1]"),
        ]), skin: skin, type: "inputtext")
    }

    private static func weatherTests(_ t: AppTestRunner) {
        t.suite("App: host service lookup: the weather live predicate reads each skin's current weak host") {
            let plain = Host()
            let (skin, _) = try fixture(t, host: plain)
            let (other, _) = try fixture(t, host: plain)
            defer { skin.close(); other.close() }
            let isLive: (Skin) -> Bool = WeatherWiring.isLive
            t.check(!isLive(skin))
            var live: Channel? = Channel()
            weak var releasedLive = live
            skin.host = live
            t.check(isLive(skin), "the pre-existing hook sees a host added after it was obtained")
            t.check(!isLive(other), "the same hook uses its actual Skin argument")
            skin.host = plain
            other.host = live
            t.check(!isLive(skin), "replacing the host revokes this skin's live capability")
            t.check(isLive(other))
            live = nil
            t.check(releasedLive == nil, "the hook does not retain a previously queried host")
            t.check(!isLive(other), "an expired weak host is not live")
            t.equal(plain.unexpected, [])
            withExtendedLifetime(plain) {}
        }
    }

    private enum FixtureError: Error { case utcUnavailable }

    /// Like SectionHostSelfTests: no loaded skin or live system source is needed for these directly created measures.
    private static func fixture(_ t: AppTestRunner, host: SkinHost?) throws -> (Skin, VirtualTimeExecutor) {
        guard let utc = TimeZone(secondsFromGMT: 0) else { throw FixtureError.utcUnavailable }
        let folder = t.temporaryDirectory("host-service-lookup")
        let skin = Skin(config: "Fixture", fileURL: folder.appendingPathComponent("Fixture/Skin.ini"),
                        skinsDirectory: folder, system: System(), host: host)
        let executor = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 1_798_761_598), timeZone: utc)
        executor.background.allowsUnfakedWork = false
        skin.runInVirtualTime(executor)
        skin.random = SkinRandom(seed: 1)
        return (skin, executor)
    }

    private class Host: SkinHost {
        var unexpected: [String] = []
        func environment(for skin: Skin) -> SkinEnvironment {
            SkinEnvironment(settingsPath: "/fixture/Settings/", programPath: "/fixture/Program/",
                            configEditor: "/fixture/Editor", locale: Locale(identifier: "en_US_POSIX"),
                            preferredLanguages: ["en"])
        }
        func skinNeedsDisplay(_ skin: Skin) {}
        func skin(_ skin: Skin, handle bang: Bang) -> Bool { unexpected.append("bang:" + bang.name); return false }
        func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) { unexpected.append("forward") }
        func skin(_ skin: Skin, execute target: String, arguments: [String]) { unexpected.append("execute") }
        func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {}
        func textSize(_ text: String, style: TextStyle, wrapWidth: Double?, for skin: Skin)
            -> (width: Double, height: Double) { (0, 0) }
        func imageSize(atPath path: String) -> (width: Double, height: Double)? { nil }
    }

    /// Callbacks are delivered on this fixture's owner, exactly as a SkinCompanionChannel promises.
    private final class Channel: Host, LiveSkinHost, SkinCompanionChannel {
        var areUpdatesPaused = false
        var windowDisplay: CGDirectDisplayID? { nil }
        var glass: [String] = []
        var shown: [InputTextSettings] = []
        var cancelled: [Int] = []
        var answers: [Int: (String?) -> Void] = [:]
        func companion(_ request: SkinCompanionRequest) {
            if case .frostedGlass(_, let style) = request {
                glass.append(style.map { $0.enabled ? "enabled" : "disabled" } ?? "remove")
            } else { unexpected.append("companion") }
        }
        func showInputText(_ settings: InputTextSettings, answered: @escaping (String?) -> Void) -> Int {
            shown.append(settings)
            let id = shown.count
            answers[id] = answered
            return id
        }
        func answer(_ id: Int, _ text: String?) { answers.removeValue(forKey: id)?(text) }
        func cancelInputText(_ id: Int) { cancelled.append(id); answers.removeValue(forKey: id) }
        func followWindowMoves(settled: @escaping () -> Void) -> Int { unexpected.append("follow"); return 0 }
        func stopFollowingWindow(_ id: Int) { unexpected.append("stopFollow") }
    }

    private final class System: SystemDataSource {
        var processorCount: Int { 1 }
        func cpuUsage(processor: Int) -> Double { 0 }
        func memoryStatus() -> MemoryStatus { MemoryStatus() }
        func networkInterfaces() -> [String] { [] }
        func networkCounters(interface: String?) -> NetworkCounters { NetworkCounters() }
        func diskSpace(path: String) -> (total: Double, free: Double)? { nil }
        func uptime() -> TimeInterval { 86_400 }
        func battery() -> BatteryStatus? { nil }
        func isProcessRunning(_ name: String) -> Bool { false }
        func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { nil }
        func volumeInfo(path: String) -> VolumeInfo? { nil }
    }
}
