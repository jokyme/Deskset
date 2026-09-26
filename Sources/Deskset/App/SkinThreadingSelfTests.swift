import AppKit
import DesksetCore

/// The skin's executor in the app (docs/skin-threading.md, phase 0): the update clock and the app's plugin results are
/// skin work, so they go through `Skin.executor` like the engine's own (DesksetSelfTest "Executor: …" covers those).
/// A test executor that runs nothing by itself shows that the work reaches it: until the test runs it, none of its
/// effects has happened.
enum SkinThreadingSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: skin threading: the update clock is a timer of the skin's executor") {
            guard let app = try AppSelfTest.makeApp(t),
                  let c = app.activate(config: "App\\Counter", file: nil) else { return }
            let executor = HeldExecutor()
            c.pauseUpdates()
            c.skin.executor = executor
            c.resumeUpdates(updateNow: false)
            t.equal(executor.pendingTimers.map(\.interval), [1], "Update=1000")
            t.equal(executor.pendingTimers.map(\.leeway), [0.1], "10 % leeway, as the timer's tolerance had")
            t.equal(executor.pendingTimers.map(\.repeats), [true])
            let updates = c.skin.updateCount
            executor.fireAll()
            t.equal(c.skin.updateCount, updates + 1, "the clock updates the skin")
            executor.fireAll()
            t.equal(c.skin.updateCount, updates + 2, "and keeps ticking")
            c.pauseUpdates()
            t.equal(executor.pendingTimers.count, 0, "pausing cancels it")
            c.skin.executor = MainSkinExecutor.shared
            c.resumeUpdates(updateNow: false)
            app.stopAllForTermination()
        }

        t.suite("App: skin threading: Chameleon's colors come back through the skin's executor") {
            let folder = t.temporaryDirectory("threading-chameleon")
            let image = folder.appendingPathComponent("blue.png")
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
                t.check(false, "test image")
                return
            }
            ctx.cgContext.setFillColor(CGColor(red: 0, green: 0.1, blue: 1, alpha: 1))
            ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            try rep.representation(using: .png, properties: [:])?.write(to: image)

            let (skin, host) = try MediaUITests.bareSkin(t, "[Rainmeter]\nUpdate=1000\n")
            let executor = HeldExecutor()
            skin.executor = executor
            let parent = ChameleonMeasure(name: "Cham", section: MediaUITests.section("Cham", [
                ("Type", "File"), ("Path", image.path),
            ]), skin: skin, type: "chameleon")
            parent.readOptions()
            _ = parent.computeValue()
            t.check(AppSelfTest.spin(timeout: 60) { executor.pendingAsync > 0 },
                    "the analysis hands its colors to the skin's executor")
            t.check(parent.palette == nil, "not applied before the executor ran it")
            executor.fireAll()
            t.check(parent.palette.map { $0.background1.b > 200 } == true, "applied when it ran")
            withExtendedLifetime(host) {}
        }
    }
}

/// Runs nothing by itself: keeps the work handed to it until the test fires it. Background work hands its results
/// over from other threads, hence the lock. The tests own their skins on the main thread.
private final class HeldExecutor: SkinExecutor {
    private struct Item {
        var timer: (interval: TimeInterval, leeway: TimeInterval, repeats: Bool)?
        var work: SkinScheduledWork
    }

    private let lock = NSLock()
    private var items: [Item] = []

    var isCurrent: Bool { Thread.isMainThread }

    func async(_ work: @escaping () -> Void) {
        add(Item(timer: nil, work: SkinScheduledWork(work)))
    }

    func async(after delay: TimeInterval, _ work: @escaping () -> Void) -> SkinScheduledWork {
        add(Item(timer: nil, work: SkinScheduledWork(work)))
    }

    func timer(interval: TimeInterval, leeway: TimeInterval, repeats: Bool,
               _ fire: @escaping () -> Void) -> SkinScheduledWork {
        add(Item(timer: (interval, leeway, repeats), work: SkinScheduledWork(repeats: repeats, fire)))
    }

    @discardableResult
    private func add(_ item: Item) -> SkinScheduledWork {
        lock.lock()
        items.append(item)
        lock.unlock()
        return item.work
    }

    private var pending: [Item] {
        lock.lock()
        defer { lock.unlock() }
        return items.filter { $0.work.isPending }
    }

    var pendingTimers: [(interval: TimeInterval, leeway: TimeInterval, repeats: Bool)] {
        pending.compactMap(\.timer)
    }

    var pendingAsync: Int { pending.filter { $0.timer == nil }.count }

    /// Runs every pending piece of work once, oldest first (a repeating timer fires once).
    func fireAll() {
        for item in pending { item.work.fire() }
    }
}
