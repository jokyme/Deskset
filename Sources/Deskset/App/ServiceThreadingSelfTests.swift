import AppKit
import CoreAudio
import CoreLocation
import DesksetCore

/// The app's shared services that skins read at every update (docs/skin-threading.md §4.5–§4.8, phase 1), used from
/// several dedicated threads at once, released together:
/// - `SystemMonitor` answers every thread, also when every reading is stale for all of them at once, and the utmpx
///   walks do not skip each other's entries;
/// - what only AppKit knows (the desktop picture, the appearance, a screen's desktop, Location Services) is worked out
///   on the main thread and read elsewhere without waiting for it; the main thread is asked once, however many threads
///   find it stale;
/// - the NowPlaying centre: reads, subscriptions and commands from several threads all arrive, on the main thread;
/// - the Wi-Fi reader and the focused-window info: one reading for every thread, stored on the main thread;
/// - the audio devices: skins asking while the first read runs all wait for it; volume steps and mute toggles of
///   several skins at once all count, on the device too.
///
/// Like `SharedServiceThreadingSelfTests`, the threads never call the runner: they report into `Collected`. Run them
/// under `scripts/check-main-thread.sh "skin threading"` too: nothing of AppKit may run on the threads.
enum ServiceThreadingSelfTests {
    typealias Collected = SharedServiceThreadingSelfTests.Collected

    static func run(_ t: AppTestRunner) {
        systemMonitorTests(t)
        mainPublishedTests(t)
        nowPlayingTests(t)
        desktopInfoTests(t)
        audioTests(t)
        webParserTests(t)
    }

    static func onThreads(_ count: Int, _ body: @escaping (Int) -> Void) -> Bool {
        SharedServiceThreadingSelfTests.onThreads(count, body)
    }

    static func drainMainQueue() -> Bool {
        SharedServiceThreadingSelfTests.drainMainQueue()
    }

    /// `body` on another thread, while the main thread waits for it (and does nothing else): what a skin thread gets
    /// when the main thread is busy.
    static func offMain<T>(_ body: @escaping () -> T) -> T {
        var result: T?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = body()
            done.signal()
        }
        thread.stackSize = 8 << 20
        thread.start()
        done.wait()
        return result!
    }

    // MARK: SystemMonitor

    static func systemMonitorTests(_ t: AppTestRunner) {
        t.suite("App: skin threading: the system monitor answers several threads at once") {
            // As the app's skins use it: most readings come from the caches, which one thread fills now and then.
            checkSystemMonitor(t, SystemMonitor.shared, rounds: 40)
            // Every reading stale at every look (the monitor's clock runs an hour ahead each time): all six threads
            // take every reading and fill every cache at the same time, over and over. That is what a missing lock
            // gets wrong (two threads replacing one cache's dictionaries and arrays at once crash the process), and
            // what the caches' lifetimes (a quarter of a second to a minute) make rare above.
            let time = Guarded(ProcessInfo.processInfo.systemUptime)
            let stale = SystemMonitor(clock: { time.access { now -> TimeInterval in
                now += 3600
                return now
            } })
            checkSystemMonitor(t, stale, rounds: 4)
            hammerSystemMonitor(t, stale)
        }
    }

    /// Six threads take `monitor`'s readings as fast as they can, all at once: the quick ones (CPU ticks, memory, the
    /// interface list, the mounts, a volume) in every round, the slow ones (the adapters, the "Best" interface, the
    /// battery, the process list) in every eighth.
    ///
    /// Without the CPU, network or volume lock this crashes in most runs (tried: 4–6 runs in 6 for each). The slow
    /// readings are taken between two accesses and only their result is stored under the lock: two threads storing
    /// it at the very moment a third copies it is too narrow a window for a test to hit, and a torn memory reading
    /// (plain numbers) looks like a valid one. Those locks are there all the same; this only shows that the paths
    /// run side by side.
    private static func hammerSystemMonitor(_ t: AppTestRunner, _ monitor: SystemMonitor) {
        let processors = monitor.processorCount
        let memoryTotal = monitor.memoryStatus().physicalTotal
        let problems = Collected<String>()
        t.check(onThreads(6) { i in
            for round in 0..<300 {
                for n in 0..<4 {
                    let cpu = monitor.cpuUsage(processor: (round + i + n) % (processors + 1))
                    if !(0...100).contains(cpu) { problems.add("cpu \(cpu)") }
                }
                let memory = monitor.memoryStatus()
                if memory.physicalTotal != memoryTotal || memory.physicalUsed <= 0 { problems.add("memory") }
                for _ in 0..<2 {
                    let interfaces = monitor.networkInterfaces()
                    _ = monitor.networkCounters(interface: nil)
                    if let first = interfaces.first { _ = monitor.networkCounters(interface: first) }
                }
                if monitor.volumeInfo(path: "/") == nil { problems.add("volume") }
                guard (round + i) % 8 == 0 else { continue }
                _ = monitor.bestNetworkInterface()
                _ = monitor.sysInfo(type: "ADAPTER_TYPE", data: "")
                _ = monitor.battery()
                if !monitor.isProcessRunning("launchd") { problems.add("process list") }
            }
        }, "the threads finish")
        t.equal(Set(problems.all).sorted(), [], "every thread got sensible readings, all of them stale")
    }

    /// Six threads read everything `monitor` offers `rounds` times, all at once, and must get what the main thread got.
    private static func checkSystemMonitor(_ t: AppTestRunner, _ monitor: SystemMonitor, rounds: Int) {
        // What every thread must agree with, read on the main thread first.
        let processors = monitor.processorCount
        let memoryTotal = monitor.memoryStatus().physicalTotal
        let computer = monitor.sysInfo(type: "COMPUTER_NAME", data: "")?.string
        let logon = monitor.logonTime()
        t.check(monitor.desktopPicturePath() != nil, "the desktop picture is known on the main thread")
        let problems = Collected<String>()
        let finished = onThreads(6) { i in
            for round in 0..<rounds {
                let cpu = monitor.cpuUsage(processor: (round + i) % (processors + 1))
                if !(0...100).contains(cpu) { problems.add("cpu \(cpu)") }
                if monitor.processorCount != processors { problems.add("processor count") }
                let memory = monitor.memoryStatus()
                if memory.physicalTotal != memoryTotal || memory.physicalUsed <= 0 { problems.add("memory") }
                let interfaces = monitor.networkInterfaces()
                _ = monitor.networkCounters(interface: nil)
                _ = monitor.networkCounters(interface: interfaces.first)
                _ = monitor.bestNetworkInterface()
                if monitor.diskSpace(path: "/") == nil { problems.add("disk space") }
                if monitor.volumeInfo(path: "/") == nil { problems.add("volume") }
                if monitor.uptime() <= 0 { problems.add("uptime") }
                _ = monitor.battery()
                if !monitor.isProcessRunning("launchd") { problems.add("process list") }
                for type in ["IP_ADDRESS", "MAC_ADDRESS", "ADAPTER_TYPE", "ADAPTER_STATE", "GATEWAY_ADDRESS",
                             "DNS_SERVER", "LAN_CONNECTIVITY", "USER_LOGONTIME", "OS_VERSION"] {
                    _ = monitor.sysInfo(type: type, data: "")
                }
                if monitor.sysInfo(type: "COMPUTER_NAME", data: "")?.string != computer {
                    problems.add("computer name")
                }
                // The walk itself, not its cached value: walks on several threads at once each see every entry.
                if monitor.logonTime() != logon { problems.add("logon time") }
                // Published by the main thread: never "unknown" on a skin thread.
                if monitor.desktopPicturePath() == nil { problems.add("desktop picture") }
            }
        }
        t.check(finished, "the threads finish")
        t.equal(Set(problems.all).sorted(), [], "every thread got sensible, matching readings")
    }

    // MARK: Values only the main thread can work out

    static func mainPublishedTests(_ t: AppTestRunner) {
        t.suite("App: skin threading: values only AppKit knows are worked out on the main thread, read anywhere") {
            var computed = 0
            var value = 1
            let published = MainPublished<Int>(maxAge: 2, initial: -1) {
                computed += 1
                return value
            }
            let clock = Collected<TimeInterval>()
            clock.add(100)
            published.clock = { clock.all.last ?? 0 }
            let reads = Collected<Int>()
            t.check(onThreads(8) { _ in reads.add(published.value()) }, "the threads finish")
            t.check(Set(reads.all).isSubset(of: [-1, 1]),
                    "nothing published yet: the initial value, or the main thread's once it answered: \(reads.all)")
            t.check(drainMainQueue())
            t.equal(computed, 1, "the main thread was asked once, however many threads asked")
            t.equal(offMain { published.value() }, 1)

            value = 2
            clock.add(101)
            t.equal(offMain { published.value() }, 1, "younger than maxAge: used as it is")
            t.check(drainMainQueue())
            t.equal(computed, 1, "and the main thread is not asked")
            clock.add(102)
            t.equal(offMain { published.value() }, 1, "older: still used, without waiting for the main thread…")
            t.check(drainMainQueue())
            t.equal(computed, 2, "…which is asked to work it out again")
            t.equal(offMain { published.value() }, 2)
            value = 3
            t.equal(published.value(), 3, "the main thread works it out whenever it reads it")
            t.equal(computed, 3)
            t.equal(offMain { published.value() }, 3, "and publishes it")
            published.publish(4)
            t.equal(offMain { published.value() }, 4, "or publishes what it learned elsewhere")
        }
    }

    // MARK: NowPlaying

    static func nowPlayingTests(_ t: AppTestRunner) {
        t.suite("App: skin threading: NowPlaying: several threads read, subscribe and command at once") {
            let backend = DemoNowPlayingBackend()
            backend.artworkEnabled = false
            let center = NowPlayingCenter(backend: backend)
            center.interval = 3600
            var first: NowPlayingSubscription? = center.subscribe(live: true)
            t.check(center.isPolling, "a subscription on the main thread starts polling at once, as before")
            t.check(AppSelfTest.spin(timeout: 60) { center.snapshot(preferring: .music).statusKnown },
                    "the first poll arrives")

            var held: Collected<NowPlayingSubscription>? = Collected()
            let problems = Collected<String>()
            let threads = 4, commands = 5
            t.check(onThreads(threads) { i in
                let subscriptions = (0..<5).map { _ in center.subscribe(live: true) }
                for s in subscriptions { held?.add(s) }
                for round in 0..<50 {
                    let snap = center.snapshot(preferring: round % 2 == 0 ? .music : nil)
                    if snap.app != .music || !snap.running { problems.add("snapshot \(snap.app)") }
                    if center.peek(preferring: .spotify).app != .music { problems.add("peek") }
                    if center.isDenied(.music) { problems.add("denied") }
                    subscriptions[(round + i) % 5].wantsCover = round % 3 == 0
                }
                for _ in 0..<commands { center.perform(.next, preferring: .music, live: true) }
            }, "the threads finish")
            t.equal(problems.all, [])
            // The subscriptions and commands were queued on the main thread; the commands then went to the worker.
            t.check(drainMainQueue())
            let performed = Collected<Int>()
            center.worker.async { performed.add(backend.performed.filter { $0.0 == .next }.count) }
            t.check(AppSelfTest.spin(timeout: 60) { performed.count == 1 })
            t.equal(performed.all, [threads * commands], "every thread's commands reached the player")

            // The threads' subscriptions go (their hops come after their registrations): polling goes on for the
            // main thread's one, and stops with it.
            held = nil
            t.check(drainMainQueue())
            t.check(center.isPolling, "the main thread's subscription still polls")
            withExtendedLifetime(first) {}
            first = nil
            t.check(drainMainQueue())
            t.check(!center.isPolling, "the last subscription gone: polling stops")
        }
    }

    // MARK: Wi-Fi, focused window, Location Services, desktop inputs

    static func desktopInfoTests(_ t: AppTestRunner) {
        t.suite("App: skin threading: Wi-Fi, the focused window and desktop inputs for several threads") {
            // Wi-Fi: one reading and one scan for every thread; the main thread stores them (it runs meanwhile).
            let wifi = WiFiCenter()
            wifi.clock = { 0 }
            let reads = Collected<Int>()
            wifi.reader = { index in
                reads.add(index)
                return WiFiNetworkInfo(ssid: "Office", rssi: -60, transmitRate: 300, encryption: "AES",
                                       auth: "WPA2-Personal", phy: "802.11ax")
            }
            wifi.scanner = { _ in [WiFiNetworkInfo(ssid: "Cafe", rssi: -70)] }
            let ssids = Collected<String>()
            t.check(onThreads(6) { _ in
                let end = Date().addingTimeInterval(60)
                while Date() < end {
                    if let info = wifi.info(interface: 0), !wifi.networks(interface: 0).isEmpty {
                        return ssids.add(info.ssid)
                    }
                    usleep(1000)
                }
            }, "the threads finish")
            t.equal(ssids.all, Array(repeating: "Office", count: 6), "every thread sees the reading")
            t.equal(reads.all, [0], "read once for all of them")

            // The focused window: asked on the main thread for whichever thread finds it stale.
            let infos = Collected<FrontmostAppInfo.Info>()
            t.check(onThreads(4) { _ in
                for _ in 0..<20 {
                    infos.add(FrontmostAppInfo.shared.current())
                    usleep(1000)
                }
            }, "the threads finish")
            t.equal(infos.count, 80)
            t.check(drainMainQueue(), "the refresh the threads asked for ran on the main thread")
            let settled = Collected<Bool>()
            FrontmostAppInfo.shared.worker.async { settled.add(true) }
            t.check(AppSelfTest.spin(timeout: 60) { settled.count == 1 }, "and the worker read the windows")
            t.check(drainMainQueue(), "the main thread stored what the worker read")
            t.equal(offMain { FrontmostAppInfo.shared.current() }, FrontmostAppInfo.shared.info,
                    "another thread reads what the main thread stored")

            // Location Services: the status comes from the main thread's manager.
            let onMain = MediaUILocationPermission.shared.status
            t.equal(offMain { MediaUILocationPermission.shared.status }, onMain, "another thread gets the main thread's")

            // SysColor and Chameleon: the same colors and desktop on every thread as on the main thread.
            DesktopInputs.publishAll()
            let types = ["Accent", "Highlight", "Desktop", "WindowText", "GrayText", "Hyperlink"]
            func colors() -> [RGBA?] { types.map { SysColorFormat.color($0).flatMap(SysColorFormat.resolved) } }
            let mainColors = colors()
            let mainDesktop = ChameleonMeasure.desktop(of: nil)
            let mainReduce = DesktopInputs.reduceTransparency.value()
            t.check(mainColors.allSatisfy { $0 != nil }, "the colors resolve")
            let problems = Collected<String>()
            t.check(onThreads(4) { _ in
                for _ in 0..<20 {
                    if colors() != mainColors { problems.add("colors") }
                    if ChameleonMeasure.desktop(of: nil) != mainDesktop { problems.add("desktop") }
                    if DesktopInputs.reduceTransparency.value() != mainReduce { problems.add("reduce transparency") }
                }
            }, "the threads finish")
            t.equal(Set(problems.all).sorted(), [])
        }
    }

    // MARK: Audio

    static func audioTests(_ t: AppTestRunner) {
        t.suite("App: skin threading: volume steps and mute toggles of several skins at once all count") {
            // Skins loading at the same time: each one that asks while the first read of the devices runs waits for
            // it, not only the one that started it (the fake HAL takes 0.3 s for that read).
            let slowHAL = AudioSelfTests.FakeSystemHAL()
            slowHAL.readDelay = 0.3
            let slow = AudioSystem(hal: slowHAL, firstReadWait: 60)
            let loaded = Collected<Bool>()
            t.check(onThreads(4) { _ in loaded.add(slow.snapshot().loaded) }, "the threads finish")
            t.equal(loaded.all, Array(repeating: true, count: 4), "every skin's first look found the devices")
            AudioSelfTests.drainHAL()

            let hal = AudioSelfTests.FakeSystemHAL()
            let system = AudioSystem(hal: hal, firstReadWait: 60)
            system.activateIfNeeded()
            t.close(system.snapshot().output.volume ?? -1, 0.4)
            // ChangeVolume from four skins at once: 40 steps of 1 %.
            t.check(onThreads(4) { _ in
                for _ in 0..<10 { _ = Win7AudioCommand.changeVolume(1).apply(to: system) }
            }, "the threads finish")
            AudioSelfTests.drainHAL()
            t.close(system.snapshot().output.volume ?? -1, 0.8, accuracy: 1e-9, "every step counts")
            t.close(hal.volumeValue(10) ?? -1, 0.8, accuracy: 1e-9, "on the device too, in the order decided")
            t.check(onThreads(4) { _ in
                for _ in 0..<5 { system.changeOutputVolume(byPercent: -1) }
            }, "the threads finish")
            AudioSelfTests.drainHAL()
            t.close(hal.volumeValue(10) ?? -1, 0.6, accuracy: 1e-9)

            // ToggleMute: 20 toggles leave it unmuted, 9 more mute it.
            t.check(onThreads(4) { _ in
                for _ in 0..<5 { _ = Win7AudioCommand.toggleMute.apply(to: system) }
            }, "the threads finish")
            AudioSelfTests.drainHAL()
            t.check(!system.snapshot().output.muted)
            t.equal(hal.mutedValue(10), false)
            t.check(onThreads(3) { _ in
                for _ in 0..<3 { _ = Win7AudioCommand.toggleMute.apply(to: system) }
            }, "the threads finish")
            AudioSelfTests.drainHAL()
            t.check(system.snapshot().output.muted)
            t.equal(hal.mutedValue(10), true)

            // AppVolume togglemute: one app toggled by several skins at once.
            guard #available(macOS 14.2, *) else { return }
            let catalog = AudioAppCatalog()
            let taps = Collected<String>()
            catalog.readApps = { [] }
            catalog.makeMuteTap = { pid in
                taps.add("make \(pid)")
                return AudioObjectID(1000 + pid)
            }
            catalog.destroyTap = { taps.add("destroy \($0)") }
            catalog.captureAllowed = { true }
            t.check(onThreads(4) { _ in
                for _ in 0..<6 { _ = catalog.toggleMuted(100) }
            }, "the threads finish")
            AudioSelfTests.drainHAL()
            t.check(!catalog.isMuted(100), "24 toggles: unmuted")
            let events = taps.all
            t.check(events.last != "make 100" && events.filter { $0 == "make 100" }.count
                        == events.filter { $0 == "destroy 1100" }.count,
                    "every tap made was destroyed again: \(events)")
            t.check(onThreads(3) { _ in _ = catalog.toggleMuted(100) }, "the threads finish")
            AudioSelfTests.drainHAL()
            t.check(catalog.isMuted(100), "3 more: muted")
            t.equal(taps.all.last, "make 100", "and its tap is there")
        }
    }

    // MARK: WebParser

    static func webParserTests(_ t: AppTestRunner) {
        t.suite("App: skin threading: a refused WebParser file is logged once, whichever threads ask") {
            let path = "/private/skin-threading-\(UUID().uuidString)/secret.txt"
            let firsts = Collected<Bool>()
            t.check(onThreads(8) { _ in
                for _ in 0..<20 { firsts.add(WebParserAccess.isFirstRefusal(path)) }
            }, "the threads finish")
            t.equal(firsts.all.filter { $0 }.count, 1)
            t.equal(firsts.count, 160)
        }
    }
}
