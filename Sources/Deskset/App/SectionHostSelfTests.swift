import AppKit
import DesksetCore

/// The app's existing capability decisions keep reading the current, weak host. These fixtures use only fake
/// hosts, solid desktop colors and owner-confined virtual work; they start no capture, permission prompt or window.
enum SectionHostSelfTests {
    static func run(_ t: AppTestRunner) {
        capabilityTests(t)
        desktopTests(t)
    }

    private static func capabilityTests(_ t: AppTestRunner) {
        t.suite("App: section host: plugin capabilities follow the current weak host") {
            let plain = Host()
            let (skin, _) = try fixture(t, host: plain)
            defer { skin.close() }
            let measure = MediaUIMeasure(name: "Media", section: MediaUITests.section("Media", []),
                                         skin: skin, type: "test")
            t.check(!AudioPlugins.mayCapture(for: skin, demo: false), "a plain host cannot capture")
            t.check(AudioPlugins.mayCapture(for: skin, demo: true), "the demo needs no live host")
            t.check(!measure.runsInApp && measure.liveHost == nil, "a plain host is not a live app")

            var live: LiveHost? = LiveHost()
            weak var releasedLive = live
            skin.host = live
            t.check(AudioPlugins.mayCapture(for: skin, demo: false), "the same skin now has a live host")
            t.check(measure.runsInApp)
            t.check(measure.liveHost === live, "the capability is the original host, not a wrapper")
            t.equal(measure.liveHost?.areUpdatesPaused, false)
            t.equal(measure.liveHost?.windowDisplay, 7)
            live?.areUpdatesPaused = true
            live?.windowDisplay = 11
            t.equal(measure.liveHost?.areUpdatesPaused, true, "pause changes are read at the call")
            t.equal(measure.liveHost?.windowDisplay, 11, "display changes are read at the call")

            live = nil
            t.check(releasedLive == nil, "neither the service entry nor the measure retains its host")
            t.check(skin.host == nil)
            t.check(!AudioPlugins.mayCapture(for: skin, demo: false))
            t.check(AudioPlugins.mayCapture(for: skin, demo: true))
            t.check(!measure.runsInApp && measure.liveHost == nil, "expired capabilities disappear")

            // Studio is live even without a desktop window or a companion channel. Only its value getters run.
            let studio = StudioHost()
            skin.host = studio
            t.check(AudioPlugins.mayCapture(for: skin, demo: false))
            t.check(measure.runsInApp && measure.liveHost === studio)
            studio.updatesPaused = true
            t.equal(measure.liveHost?.areUpdatesPaused, true)
            t.check(measure.liveHost?.windowDisplay == nil, "no desktop window was created")
            skin.host = plain
            t.check(!AudioPlugins.mayCapture(for: skin, demo: false))
            t.check(!measure.runsInApp && measure.liveHost == nil, "replacing a host removes its capabilities")
            withExtendedLifetime((plain, studio)) {}
        }
    }

    private static func desktopTests(_ t: AppTestRunner) {
        t.suite("App: section host: Chameleon reads fresh facts and closes its original move channel") {
            let source = SolidDesktops()
            let saved = ChameleonMeasure.desktopSource
            ChameleonMeasure.desktopSource = source
            defer { ChameleonMeasure.desktopSource = saved }
            var first: LiveHost? = LiveHost()
            weak var releasedFirst = first
            let second = LiveHost()
            let (skin, executor) = try fixture(t, host: first)
            let wall = ChameleonMeasure(name: "Wall", section: MediaUITests.section("Wall", [
                ("Type", "Desktop"), ("CropDesktop", "Skin"),
            ]), skin: skin, type: "chameleon")
            defer { wall.skinWillClose(); skin.close() }
            wall.readOptions()
            _ = wall.computeValue()
            t.check(wall.samplesUnderSkin && wall.followsWindow)
            t.equal(first?.followed, [1], "the channel is asked once, synchronously")
            t.check(wall.palette == nil, "background completion still waits for the owner")
            t.check(executor.runUntilIdle() > 0)
            t.equal(wall.palette?.average, .black, "the first screen is a known, nonempty solid sample")

            // Prime the engine's per-work environment before moving. Chameleon's force check must ask the host
            // directly while this cached macro value is still the old one, before its queued completion runs.
            t.equal(skin.resolve("#CURRENTCONFIGX#", in: nil, sectionVariables: false), "10")
            first?.facts.windowFrame.x = 110
            first?.facts.appearance = .dark
            first?.settled()
            t.equal(first?.environmentRequests.last?.1.windowFrame.x, 110)
            t.equal(first?.environmentRequests.last?.1.appearance.isDark, true)
            t.equal(skin.resolve("#CURRENTCONFIGX#", in: nil, sectionVariables: false), "10", "the control still holds cached facts")
            t.equal(wall.palette?.average, .black, "the old sample stays until the owner handles the result")
            t.check(executor.runUntilIdle() > 0)
            t.equal(wall.palette?.average, .white, "the move selected the other screen from fresh facts")
            t.equal(first?.followed, [1], "moving does not register another watch")

            // The watch belongs to the original channel, but each delivered move reads the skin's current host.
            skin.host = second
            first?.settled()
            t.equal(second.environmentRequests.map { $0.0 }, [ObjectIdentifier(skin)])
            t.equal(second.environmentRequests.last?.1.windowFrame.x, 10)
            t.check(executor.runUntilIdle() > 0)
            t.equal(wall.palette?.average, .black)
            t.equal(second.followed, [], "an existing watch is not silently rebound")
            t.check(first?.environmentRequests.allSatisfy { $0.0 == ObjectIdentifier(skin) } == true,
                    "the host always receives the original Skin argument")

            let late = first?.callbacks[1]
            wall.skinWillClose()
            t.equal(first?.stopped, [1], "close goes to the original weak channel")
            t.equal(second.stopped, [], "the replacement host receives no cancellation")
            t.check(!wall.followsWindow)
            let reads = second.environmentRequests.count
            late?()
            t.equal(second.environmentRequests.count, reads, "a late move cannot restart a closed measure")
            t.equal(executor.pendingCount, 0)
            t.equal(source.screenQueries, 3)
            t.equal(source.desktopQueries, 0, "CropDesktop=Skin never reads a real desktop")
            t.equal(executor.background.unverifiable, [], "all background work was fixture work")
            t.equal(executor.background.outstanding, 0)
            t.equal(first?.unexpectedRequests, [])
            t.equal(second.unexpectedRequests, [])
            first = nil
            t.check(releasedFirst == nil, "the section and closed channel leave no host-retaining cache")
            withExtendedLifetime(second) {}
        }
    }

    private enum FixtureError: Error { case utcUnavailable }

    /// No load is needed for these directly constructed measures; their sections reuse MediaUITests.section.
    /// There are no timers or live system readings; the fixture source only produces a color on this owner.
    private static func fixture(_ t: AppTestRunner, host: SkinHost?) throws -> (Skin, VirtualTimeExecutor) {
        guard let utc = TimeZone(secondsFromGMT: 0) else { throw FixtureError.utcUnavailable }
        let folder = t.temporaryDirectory("section-host")
        let skin = Skin(config: "Fixture", fileURL: folder.appendingPathComponent("Fixture/Skin.ini"),
                        skinsDirectory: folder, system: System(), host: host)
        let executor = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 1_798_761_598), timeZone: utc)
        executor.background.allowsUnfakedWork = false
        skin.runInVirtualTime(executor)
        return (skin, executor)
    }

    private class Host: SkinHost {
        var facts = SkinEnvironment(windowFrame: SkinRect(x: 10, y: 10, width: 20, height: 20),
                                    settingsPath: "/fixture/Settings/", programPath: "/fixture/Program/",
                                    configEditor: "/fixture/Editor", appearance: .light,
                                    locale: Locale(identifier: "en_US_POSIX"), preferredLanguages: ["en"])
        // Identity only: recording a call must not extend Skin's lifetime.
        var environmentRequests: [(ObjectIdentifier, SkinEnvironment)] = []
        func environment(for skin: Skin) -> SkinEnvironment {
            environmentRequests.append((ObjectIdentifier(skin), facts))
            return facts
        }
        func skinNeedsDisplay(_ skin: Skin) {}
        func skin(_ skin: Skin, handle bang: Bang) -> Bool { false }
        func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {}
        func skin(_ skin: Skin, execute target: String, arguments: [String]) {}
        func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {}
        func textSize(_ text: String, style: TextStyle, wrapWidth: Double?, for skin: Skin)
            -> (width: Double, height: Double) { (0, 0) }
        func imageSize(atPath path: String) -> (width: Double, height: Double)? { nil }
    }

    /// Like the runtime's channel, callbacks execute on the owner. This fixture is never sent to another thread.
    private final class LiveHost: Host, LiveSkinHost, SkinCompanionChannel {
        var areUpdatesPaused = false
        var windowDisplay: CGDirectDisplayID? = 7
        var followed: [Int] = []
        var stopped: [Int] = []
        var callbacks: [Int: () -> Void] = [:]
        var unexpectedRequests: [String] = []
        func followWindowMoves(settled: @escaping () -> Void) -> Int {
            let id = followed.count + 1
            followed.append(id)
            callbacks[id] = settled
            return id
        }
        func stopFollowingWindow(_ id: Int) {
            stopped.append(id)
            callbacks.removeValue(forKey: id)
        }
        func settled() { callbacks[1]?() }
        func companion(_ companion: SkinCompanionRequest) { unexpectedRequests.append("companion") }
        func showInputText(_ settings: InputTextSettings, answered: @escaping (String?) -> Void) -> Int {
            unexpectedRequests.append("inputText")
            return 0
        }
        func cancelInputText(_ id: Int) { unexpectedRequests.append("cancelInputText") }
    }

    private final class SolidDesktops: DesktopPictureSource {
        var screenQueries = 0
        var desktopQueries = 0
        var isFixture: Bool { true }
        func desktop(of host: LiveSkinHost?) -> ScreenDesktop? { desktopQueries += 1; return nil }
        func screenDesktops() -> [ScreenDesktop] {
            screenQueries += 1
            let left = CGRect(x: 0, y: 0, width: 100, height: 100)
            let right = CGRect(x: 100, y: 0, width: 100, height: 100)
            return [ScreenDesktop(picture: "", frame: left, area: left, solid: .black),
                    ScreenDesktop(picture: "", frame: right, area: right, solid: .white)]
        }
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
