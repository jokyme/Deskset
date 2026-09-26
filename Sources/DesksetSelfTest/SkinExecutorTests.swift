import Darwin
import Foundation
@testable import DesksetCore

// The skin's executor (suite prefix "Executor"; docs/skin-threading.md, phase 0). Skin work that runs later goes
// through `Skin.executor`. A test executor that runs nothing by itself (`ManualExecutor`) shows that each kind of work
// reaches it — and only it: until the test runs the work, none of its effects has happened, and work that went to the
// main queue instead would never show up there — and that closing the skin cancels what it should. The waits are for
// background work (file reads, child processes) to hand its result over; nothing waits for a fixed time.

func runSkinExecutorTests(_ t: TestRunner) {
    CorePlugins.register()
    runMainExecutorTests(t)
    runSeamTests(t)
    runSeamPluginTests(t)
    runExecutorLifetimeTests(t)
    runExecutorCloseTests(t)
    runOwnershipTests(t)
}

// MARK: - Helpers

/// Runs nothing by itself: it keeps every piece of work handed to it, in order, until the test runs it. Background
/// work hands its results over from other threads, hence the lock. The tests own their skins on the main thread.
final class ManualExecutor: SkinExecutor {
    enum Kind: Equatable {
        case async
        case after(TimeInterval)
        case timer(interval: TimeInterval, leeway: TimeInterval, repeats: Bool)
    }

    final class Item {
        let kind: Kind
        let work: SkinScheduledWork

        init(_ kind: Kind, _ work: SkinScheduledWork) {
            self.kind = kind
            self.work = work
        }
    }

    private let lock = NSLock()
    private var items: [Item] = []
    private var nextAsyncHook: (() -> Void)?
    /// False: claims not to be the current thread anywhere (ownership checks).
    var claimsCurrent = true

    var isCurrent: Bool { claimsCurrent && Thread.isMainThread }

    func async(_ work: @escaping () -> Void) {
        add(.async, SkinScheduledWork(work))
        lock.lock()
        let hook = nextAsyncHook
        nextAsyncHook = nil
        lock.unlock()
        hook?()
    }

    /// The next `async`, on whichever thread calls it, runs `hook` once it has handed its work over and before it
    /// returns: a test holds a posting thread up right there.
    func afterNextAsync(_ hook: @escaping () -> Void) {
        lock.lock()
        nextAsyncHook = hook
        lock.unlock()
    }

    func async(after delay: TimeInterval, _ work: @escaping () -> Void) -> SkinScheduledWork {
        add(.after(delay), SkinScheduledWork(work))
    }

    func timer(interval: TimeInterval, leeway: TimeInterval, repeats: Bool,
               _ fire: @escaping () -> Void) -> SkinScheduledWork {
        add(.timer(interval: interval, leeway: leeway, repeats: repeats), SkinScheduledWork(repeats: repeats, fire))
    }

    @discardableResult
    private func add(_ kind: Kind, _ work: SkinScheduledWork) -> SkinScheduledWork {
        lock.lock()
        items.append(Item(kind, work))
        lock.unlock()
        return work
    }

    /// Everything handed over so far, oldest first.
    var all: [Item] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    /// Work that has not run (or a timer that still fires) and was not cancelled.
    var pending: [Item] { all.filter { $0.work.isPending } }
    var pendingKinds: [Kind] { pending.map(\.kind) }

    /// Runs the pending work once each, oldest first (a repeating timer fires once); work handed over meanwhile waits
    /// for the next call. Returns how many ran.
    @discardableResult
    func runPending(where include: (Kind) -> Bool = { _ in true }) -> Int {
        let batch = pending.filter { include($0.kind) }
        for item in batch { item.work.fire() }
        return batch.count
    }

    /// Waits until `condition` holds (background work handing its result over), running the main run loop meanwhile;
    /// false after a minute, which only tells "late" from "never".
    func wait(until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(60)
        while !condition() {
            if Date() >= deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        return true
    }

    /// Waits until `count` pieces of work handed over with `async` are pending.
    func waitForAsync(_ count: Int = 1) -> Bool {
        wait { pendingKinds.filter { $0 == .async }.count >= count }
    }
}

private var retainedExecutorHosts: [FakeHost] = []

/// Writes `ini` (and `files`, relative to the Skins folder) and loads `Root\Sub\Skin.ini` on `executor`.
private func executorSkin(_ t: TestRunner, _ ini: String, files: [String: String] = [:],
                          executor: SkinExecutor? = nil, host: FakeHost = FakeHost()) throws -> (Skin, FakeHost) {
    let skins = t.temporaryDirectory("executor").appendingPathComponent("Skins")
    let dir = skins.appendingPathComponent("Root/Sub")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try ini.write(to: dir.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
    for (path, text) in files {
        let url = skins.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    let skin = Skin(config: "Root\\Sub", fileURL: dir.appendingPathComponent("Skin.ini"), skinsDirectory: skins,
                    system: FakeSystem(), host: host)
    if let executor { skin.executor = executor }
    retainedExecutorHosts.append(host)  // Skin.host is weak.
    try skin.load()
    return (skin, host)
}

/// Spins the main run loop until `condition` holds; false after a minute ("late" versus "never").
@discardableResult
private func spinMain(until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(60)
    while !condition() {
        if Date() >= deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    return true
}

private final class Token {}

/// A count that background work adds to and the test reads on the main thread.
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func add() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

/// Files in WebParser's temporary download folder whose names end with `suffix` (downloads without DownloadFile are
/// saved as `<measure token>-<file name>`). The folder is the user's temporary folder, which other runs share (TMPDIR
/// does not move it), so the tests download files with names of their own.
private func temporaryDownloads(endingWith suffix: String) -> [String] {
    let folder = WebParserURL.temporaryDirectory.path
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    return names.filter { $0.hasSuffix(suffix) }.map { folder + "/" + $0 }
}

// MARK: - MainSkinExecutor

private func runMainExecutorTests(_ t: TestRunner) {
    t.suite("Executor: the main executor keeps the main queue's order") {
        let main = MainSkinExecutor.shared
        t.check(main.isCurrent, "the tests run on the main thread")
        var order: [Int] = []
        DispatchQueue.main.async { order.append(1) }
        main.async { order.append(2) }
        DispatchQueue.main.async { order.append(3) }
        t.equal(order, [], "never inline")
        t.check(spinMain { order.count == 3 })
        t.equal(order, [1, 2, 3], "the same first-in, first-out queue as DispatchQueue.main (AppController.later)")

        var ran = false
        let soon = main.async(after: 0) { ran = true }
        t.check(!ran && soon.isPending, "async(after: 0) is not inline either")
        t.check(spinMain { ran })
        t.check(!soon.isPending && !soon.isCancelled)

        weak var captured: Token?
        var late: SkinScheduledWork?
        do {
            let token = Token()
            captured = token
            late = main.async(after: 3600) { _ = token }
        }
        t.check(captured != nil, "pending work holds what it captured")
        late?.cancel()
        t.check(late?.isCancelled == true)
        t.check(captured == nil, "cancelling lets go of it at once, not an hour later")
    }

    t.suite("Executor: the main executor's timers") {
        let main = MainSkinExecutor.shared
        var fired = 0
        let once = main.timer(interval: 0, leeway: 0, repeats: false) { fired += 1 }
        t.equal(fired, 0, "a timer never fires inline, not even with interval 0")
        t.check(spinMain { fired == 1 })
        t.check(!once.isPending, "a one-shot is done once it fired")

        // Common modes: it also fires while the run loop runs in another common mode, as it does while a menu tracks
        // the mouse (AppKit's event tracking mode, which DesksetCore does not see).
        let mode = RunLoop.Mode("DesksetExecutorTest")
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: mode.rawValue as CFString))
        var tracked = false
        _ = main.timer(interval: 0.001, leeway: 0, repeats: false) { tracked = true }
        let deadline = Date().addingTimeInterval(60)
        while !tracked && Date() < deadline {
            _ = RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.01))
        }
        t.check(tracked, "fired in another common mode")

        var ticks = 0
        let repeating = main.timer(interval: 0.001, leeway: 0, repeats: true) { ticks += 1 }
        t.check(spinMain { ticks >= 3 }, "a repeating timer fires until it is cancelled")
        // Cancelled on another thread while the main thread waits (so no tick is under way): from then on its work
        // never runs, although the timer itself is invalidated on the main thread a moment later.
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            repeating.cancel()
            done.signal()
        }
        done.wait()
        let atCancel = ticks
        t.check(repeating.isCancelled)
        var flushed = false
        DispatchQueue.main.async { flushed = true }
        t.check(spinMain { flushed })
        t.equal(ticks, atCancel, "no tick after cancel() from another thread")
    }

    t.suite("Executor: scheduled work runs once and cancels once") {
        var runs = 0, cancels = 0
        let once = SkinScheduledWork { runs += 1 }
        once.setCancelHandler { cancels += 1 }
        once.fire()
        once.fire()
        once.cancel()
        t.equal(runs, 1)
        t.equal(cancels, 0, "nothing to cancel once a one-shot has run")
        t.check(!once.isPending && !once.isCancelled)

        let timer = SkinScheduledWork(repeats: true) { runs += 1 }
        timer.setCancelHandler { cancels += 1 }
        timer.fire()
        timer.fire()
        t.equal(runs, 3)
        t.check(timer.isPending)
        timer.cancel()
        timer.cancel()
        timer.fire()
        t.equal(runs, 3, "not after cancel()")
        t.equal(cancels, 1, "the executor's cancel handler runs once")
        var late = false
        timer.setCancelHandler { late = true }
        t.check(late, "a handler set after cancel() runs at once")
    }
}

// MARK: - The engine's own work

private func runSeamTests(_ t: TestRunner) {
    t.suite("Executor: !Delay waits on the skin's executor") {
        let executor = ManualExecutor()
        let (skin, _) = try executorSkin(t, "[M]\nMeter=Image\n", executor: executor)
        skin.execute("[!SetVariable A 1][!Delay 86400000][!SetVariable B 1][!Delay 0][!SetVariable C 1]", from: nil)
        t.equal(skin.variable("A"), "1")
        t.equal(executor.pendingKinds, [.after(86_400)], "a day, on the skin's executor")
        t.equal(skin.variable("B"), nil)
        executor.runPending()
        t.equal(skin.variable("B"), "1", "the rest of the action runs when the executor runs it")
        t.equal(executor.pendingKinds, [.after(0.016)], "16 ms at least")
        t.equal(skin.variable("C"), nil)
        executor.runPending()
        t.equal(skin.variable("C"), "1")
        t.equal(executor.pendingKinds, [])
    }

    t.suite("Executor: ActionTimer steps are timers of the skin's executor") {
        let executor = ManualExecutor()
        let (skin, _) = try executorSkin(t, """
        [Rainmeter]
        Update=-1
        [Timer]
        Measure=Plugin
        Plugin=ActionTimer
        ActionList1=First | Wait 5000 | Second | Repeat Third, 250, 2
        First=[!SetVariable First 1]
        Second=[!SetVariable Second 1]
        Third=[!SetVariable Third ([#Third]+1)]
        [Variables]
        Third=0
        """, executor: executor)
        skin.update()
        guard let timer = skin.measure(named: "Timer") as? ActionTimerMeasure else {
            t.check(false, "ActionTimer measure")
            return
        }
        var now = 100.0
        timer.clock = { now }
        skin.execute("[!CommandMeasure Timer \"Execute 1\"]", from: nil)
        t.equal(executor.pendingKinds, [.timer(interval: 0, leeway: 0, repeats: false)],
                "the first step runs after the action that sent Execute")
        t.equal(skin.variable("First"), nil)
        executor.runPending()
        t.equal(skin.variable("First"), "1")
        t.equal(executor.pendingKinds, [.timer(interval: 5, leeway: 0, repeats: false)], "Wait 5000")
        now = 105
        executor.runPending()
        t.equal(skin.variable("Second"), "1")
        t.equal(skin.variable("Third"), "1", "the first repetition right after")
        t.equal(executor.pendingKinds, [.timer(interval: 0.25, leeway: 0, repeats: false)])
        now = 105.25
        executor.runPending()
        t.equal(skin.variable("Third"), "2")
        t.equal(executor.pendingKinds, [])
        t.equal(timer.runningLists, [])
    }

    t.suite("Executor: Bitmap transition frames step on the skin's executor") {
        let executor = ManualExecutor()
        let host = FakeHost()
        let (skin, _) = try executorSkin(t, """
        [Rainmeter]
        Update=-1
        TransitionUpdate=50
        [V]
        Measure=Calc
        Formula=0
        MinValue=0
        MaxValue=100
        [B]
        Meter=Bitmap
        MeasureName=V
        BitmapImage=Strip.png
        BitmapFrames=4
        BitmapTransitionFrames=1
        """, executor: executor, host: host)
        skin.update()
        let bitmap = skin.meter(named: "B") as! BitmapMeter
        t.equal(bitmap.displayedFrames, [0])
        skin.execute("[!SetOption V Formula 100][!UpdateMeasure V][!UpdateMeter B]", from: nil)
        t.equal(bitmap.displayedFrames, [1], "the transition frame after frame 0")
        t.equal(executor.pendingKinds, [.after(0.05)], "TransitionUpdate=50")
        let redraws = host.redraws
        executor.runPending()
        t.equal(bitmap.displayedFrames, [2], "then the new frame")
        t.equal(host.redraws, redraws + 1)
        t.equal(executor.pendingKinds, [])
    }

    t.suite("Executor: Mouse and Slider timers run on the skin's executor") {
        let executor = ManualExecutor()
        let (skin, _) = try executorSkin(t, """
        [Rainmeter]
        Update=-1
        [Variables]
        Log=
        [M]
        Measure=Plugin
        Plugin=Mouse
        UpdateRate=1000
        MouseMoveAction=[!SetVariable Log "[#Log]$MouseX$;"]
        [S]
        Measure=Plugin
        Plugin=Slider
        HoldDelay=60000
        HoldAction=[!SetVariable Held "$MouseX$"]
        [Box]
        Meter=Image
        W=100
        H=50
        SolidColor=0,0,0,255
        """, executor: executor)
        guard let mouse = skin.measure(named: "M") as? MouseMeasure,
              let slider = skin.measure(named: "S") as? SliderMeasure else {
            t.check(false, "Mouse and Slider measures")
            return
        }
        var now = 100.0
        mouse.clock = { now }
        slider.clock = { now }
        skin.update()
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10, y: 10)
        t.equal(executor.pendingKinds, [.timer(interval: 60, leeway: 0, repeats: false)], "HoldDelay=60000")
        skin.pointerEvent(.dragged, x: 11, y: 10)
        t.equal(skin.variable("Log"), "11;")
        now = 100.25
        skin.pointerEvent(.dragged, x: 12, y: 10)
        t.equal(skin.variable("Log"), "11;", "within UpdateRate: the move waits")
        t.equal(executor.pendingKinds.last, .timer(interval: 0.75, leeway: 0, repeats: false), "the rest of the second")
        t.check(mouse.hasPendingMove && slider.isHoldWaiting)
        now = 101
        executor.runPending()
        t.equal(skin.variable("Log"), "11;12;", "the waiting move ran when its timer fired")
        t.equal(skin.variable("Held"), "12", "and the hold, where the pointer is")
        t.check(!mouse.hasPendingMove && !slider.isHoldWaiting)
        t.equal(executor.pendingKinds, [])
    }

    t.suite("Executor: RunCommand results and time-outs") {
        let executor = ManualExecutor()
        let (skin, _) = try executorSkin(t, """
        [Rainmeter]
        Update=-1
        [Run]
        Measure=Plugin
        Plugin=RunCommand
        Parameter=echo seam
        Timeout=86400000
        FinishAction=[!SetVariable Finished 1]
        [Fail]
        Measure=Plugin
        Plugin=RunCommand
        Parameter=dir C:\\Windows
        FinishAction=[!SetVariable Failed 1]
        [Stay]
        Measure=Plugin
        Plugin=RunCommand
        Parameter=sleep 60
        FinishAction=[!SetVariable Stayed 1]
        """, executor: executor)
        skin.update()
        guard let run = skin.measure(named: "Run") as? RunCommandMeasure else {
            t.check(false, "RunCommand measure")
            return
        }
        skin.execute("[!CommandMeasure Run Run]", from: nil)
        // (The program's exit may be on its way back already.)
        t.equal(executor.pendingKinds.filter { $0 != .async }, [.after(86_400)], "Timeout on the skin's executor")
        t.check(executor.waitForAsync(), "the program's exit comes back through the executor")
        t.check(run.isRunning && skin.variable("Finished") == nil, "nothing happened before the executor ran it")
        executor.runPending(where: { $0 == .async })
        // The output is decoded off the skin's thread, then handed back again.
        t.check(executor.waitForAsync(), "the decoded output comes back through the executor")
        t.equal(skin.variable("Finished"), nil)
        executor.runPending(where: { $0 == .async })
        t.equal(skin.variable("Finished"), "1")
        t.equal(run.value, 1)
        t.equal(run.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), "seam")

        // A command that cannot start: FinishAction after the current action, through the executor.
        skin.execute("[!CommandMeasure Fail Run]", from: nil)
        t.equal(skin.measure(named: "Fail")?.value, 103)
        t.equal(executor.pendingKinds.last, .async)
        t.equal(skin.variable("Failed"), nil)
        executor.runPending(where: { $0 == .async })
        t.equal(skin.variable("Failed"), "1")

        // Close: the run finishes without the program once the grace period is over, which is waited for on the
        // skin's executor; unloading the skin cancels that wait.
        skin.execute("[!CommandMeasure Stay Run][!CommandMeasure Stay Close]", from: nil)
        let grace = executor.pending.first { $0.kind == .after(RunCommandMeasure.closeGrace) }
        t.check(grace != nil, "the grace period after Close waits on the skin's executor (\(executor.pendingKinds))")
        t.equal(skin.variable("Stayed"), nil)
        skin.close()
        t.check(grace?.work.isCancelled == true, "unloading the skin cancels it")
        executor.runPending()
        t.equal(skin.variable("Stayed"), nil)
    }

    t.suite("Executor: WebParser results come back through the skin's executor") {
        let executor = ManualExecutor()
        let (skin, _) = try executorSkin(t, """
        [Rainmeter]
        Update=-1
        [Parent]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        RegExp=(?siU)value=(.*);image=(.*);bad=(.*);
        StringIndex=1
        FinishAction=[!SetVariable Done 1]
        [Image]
        Measure=WebParser
        URL=[Parent]
        StringIndex=2
        Download=1
        FinishAction=[!SetVariable Downloaded 1]
        [Bad]
        Measure=WebParser
        URL=[Parent]
        StringIndex=3
        Download=1
        OnDownloadErrorAction=[!SetVariable BadURL 1]
        """, executor: executor)
        // The page names the file to download by its full path (a child resolves relative URLs only against http).
        let picture = skin.directory.appendingPathComponent("executor-seam-picture.txt")
        try "picture".write(to: picture, atomically: true, encoding: .utf8)
        try "value=42;image=\(picture.path);bad=nonsense;".write(to: skin.directory.appendingPathComponent("data.txt"),
                                                                 atomically: true, encoding: .utf8)
        skin.update()
        let parent = skin.measure(named: "Parent") as! WebParserMeasure
        let image = skin.measure(named: "Image") as! WebParserMeasure
        t.check(executor.waitForAsync(), "the parsed page comes back through the executor")
        t.check(parent.isFetching && parent.stringValue.isEmpty && skin.variable("Done") == nil,
                "nothing was applied before the executor ran it")
        executor.runPending()
        t.equal(parent.stringValue, "42")
        t.equal(skin.variable("Done"), "1")
        t.check(!parent.isFetching)

        // The children's downloads start now. One has no usable URL: it fails after the current action, through the
        // executor, like a transfer that fails.
        t.equal(skin.variable("BadURL"), nil, "the bad URL fails after the current action")
        t.check(executor.pendingKinds.contains(.async), "on the executor")
        t.check(executor.waitForAsync(2), "the downloaded file comes back through the executor too")
        t.check(image.isDownloading && image.stringValue.isEmpty && skin.variable("Downloaded") == nil
                    && skin.variable("BadURL") == nil,
                "neither was applied before the executor ran it")
        executor.runPending()
        t.equal(skin.variable("BadURL"), "1")
        t.equal(skin.variable("Downloaded"), "1")
        t.check(!image.isDownloading)
        t.check(image.stringValue.hasSuffix("-executor-seam-picture.txt"), image.stringValue)
        t.equal(try? String(contentsOfFile: image.stringValue, encoding: .utf8), "picture")
        skin.close()
    }
}

// MARK: - Plugins' background work

private func runSeamPluginTests(_ t: TestRunner) {
    t.suite("Executor: plugin results come back through the skin's executor") {
        let executor = ManualExecutor()
        let savedWriter = FileViewIcons.writer
        FileViewIcons.writer = { _, _, destination in
            FileManager.default.createFile(atPath: destination, contents: Data("icon".utf8))
        }
        defer { FileViewIcons.writer = savedWriter }
        let (skin, _) = try executorSkin(t, """
        [Rainmeter]
        Update=-1
        [Quote]
        Measure=Plugin
        Plugin=QuotePlugin
        PathName=#CURRENTPATH#quotes.txt
        [Info]
        Measure=Plugin
        Plugin=FolderInfo
        Folder=#CURRENTPATH#Folder
        InfoType=FileCount
        [View]
        Measure=Plugin
        Plugin=FileView
        Path=#CURRENTPATH#Folder
        ShowDotDot=0
        FinishAction=[!SetVariable Listed 1]
        [Icon]
        Measure=Plugin
        Plugin=FileView
        Path=[View]
        Type=Icon
        [Res]
        Measure=Plugin
        Plugin=ResMon
        ResCountType=Handle
        ProcessName=launchd
        [Ping]
        Measure=Plugin
        Plugin=PingPlugin
        DestAddress=127.0.0.1
        Timeout=5000
        FinishAction=[!SetVariable Pinged 1]
        """, files: ["Root/Sub/quotes.txt": "alpha", "Root/Sub/Folder/a.txt": "a", "Root/Sub/Folder/b.txt": "b"],
            executor: executor)
        skin.update()
        let quote = skin.measure(named: "Quote") as! QuoteMeasure
        let info = skin.measure(named: "Info") as! FolderInfoMeasure
        let view = skin.measure(named: "View") as! FileViewMeasure
        let res = skin.measure(named: "Res") as! ResMonMeasure
        let ping = skin.measure(named: "Ping") as! PingMeasure
        t.check(executor.waitForAsync(5), "five results come back through the executor")
        t.check(quote.isLoading && quote.itemCount == 0, "Quote: not applied yet")
        t.check(info.isScanning && info.latestResult.files == 0, "FolderInfo: not applied yet")
        t.check(skin.variable("Listed") == nil && view.value == 0, "FileView: not applied yet")
        t.check(res.knownProcessIDs == nil, "ResMon: not applied yet")
        t.check(ping.isPinging && skin.variable("Pinged") == nil, "Ping: not applied yet")
        executor.runPending(where: { $0 == .async })
        t.equal(quote.itemCount, 1)
        t.equal(info.latestResult.files, 2)
        t.equal(skin.variable("Listed"), "1")
        t.equal(view.value, 2, "the parent's number is the number of listed items")
        t.check(res.knownProcessIDs != nil)
        t.check(!ping.isPinging)
        t.equal(skin.variable("Pinged"), "1")

        // The listing gave the icon child its file: the icon is written in the background and its path comes back
        // through the executor.
        let icon = skin.measure(named: "Icon") as! FileViewMeasure
        let iconFile = skin.directory.appendingPathComponent("icon1.ico").path
        t.check(executor.waitForAsync(), "the written icon comes back through the executor")
        t.check(FileManager.default.fileExists(atPath: iconFile))
        t.equal(icon.stringValue, "", "FileView icon: not applied yet")
        executor.runPending()
        t.equal(icon.stringValue, iconFile)
        skin.close()
    }

    t.suite("Executor: shared services hand callbacks to the executor that asked") {
        let dir = t.temporaryDirectory("executor-trash")
        try Data("1234".utf8).write(to: dir.appendingPathComponent("a"))
        let savedFolders = TrashMonitor.folders
        TrashMonitor.folders = { [dir.path] }
        defer { TrashMonitor.folders = savedFolders }
        let executor = ManualExecutor()
        var done = false
        TrashMonitor.shared.refresh(includeSize: true, force: true, on: executor) { done = true }
        t.check(executor.waitForAsync(), "the Trash reading comes back through the executor")
        t.check(!done)
        executor.runPending()
        t.check(done)

        // One block per executor, in the order the callbacks were asked for.
        let other = ManualExecutor()
        var order: [String] = []
        TrashMonitor.deliver([(other, { order.append("a") }), (MainSkinExecutor.shared, { order.append("main") }),
                              (other, { order.append("b") })])
        t.equal(other.pendingKinds, [.async], "the skin's callbacks in one block")
        other.runPending()
        t.equal(order, ["a", "b"])
        t.check(spinMain { order.count == 3 })
        t.equal(order.last, "main")

        // Helper programs: the exit status reaches the executor of the skin that started them.
        let savedLauncher = PluginProcess.launcher
        PluginProcess.launcher = { _, _, completion in DispatchQueue.global().async { completion?(7) } }
        defer { PluginProcess.launcher = savedLauncher }
        var status: Int32?
        PluginProcess.run("/usr/bin/true", [], on: executor) { status = $0 }
        t.check(executor.waitForAsync(), "the exit status comes back through the executor")
        t.equal(status, nil)
        executor.runPending()
        t.equal(status, 7)

        // RecycleManager, the skin side of both: its first reading and Finder's answer to EmptyBin wait for the
        // skin's executor. (The Trash readings count how often the folders are looked at.)
        let reads = Tally()
        TrashMonitor.folders = {
            reads.add()
            return [dir.path]
        }
        // A reading of this folder only, started after any other has finished.
        var fresh = false
        TrashMonitor.shared.refresh(includeSize: false, force: true, on: MainSkinExecutor.shared) { fresh = true }
        t.check(spinMain { fresh })
        let binExecutor = ManualExecutor()
        let (skin, _) = try executorSkin(t, "[Rainmeter]\nUpdate=-1\n[Bin]\nMeasure=RecycleManager\n",
                                         executor: binExecutor)
        let bin = skin.measure(named: "Bin") as! RecycleManagerMeasure
        skin.update()
        t.check(binExecutor.waitForAsync(), "the first reading comes back through the skin's executor")
        t.check(!bin.hasReading, "RecycleManager: not applied yet")
        binExecutor.runPending()
        t.check(bin.hasReading)
        t.equal(bin.value, 1, "the Trash's one item")

        let readsBefore = reads.value
        skin.execute("[!CommandMeasure Bin EmptyBin]", from: nil)
        t.check(binExecutor.waitForAsync(), "Finder's exit status comes back through the skin's executor")
        t.equal(reads.value, readsBefore, "the Trash is not read again before the executor ran it")
        binExecutor.runPending()
        t.check(spinMain { reads.value > readsBefore }, "then it is read again")
        skin.close()
    }
}

// MARK: - Lifetime

private func runExecutorLifetimeTests(_ t: TestRunner) {
    t.suite("Executor: queued work keeps the skin alive; results only while they run; delays and timers do not") {
        let ini = """
        [Rainmeter]
        Update=-1
        [Timer]
        Measure=Plugin
        Plugin=ActionTimer
        ActionList1=Wait 60000 | Tick
        Tick=[!SetVariable Ticked 1]
        """
        let executor = ManualExecutor()
        weak var weakSkin: Skin?
        var ran = false
        do {
            let (skin, _) = try executorSkin(t, ini, executor: executor)
            weakSkin = skin
            skin.async { ran = true }
        }
        t.check(weakSkin != nil, "work queued with Skin.async holds the skin")
        executor.runPending()
        t.check(ran)
        t.check(weakSkin == nil, "and lets go of it once it has run")

        // A result on its way back from background work does not hold the skin; it is dropped when the skin is gone
        // by the time the executor gets to it.
        var late = false
        do {
            let (skin, _) = try executorSkin(t, ini, executor: executor)
            weakSkin = skin
            let hop = skin.hop()
            let posted = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                hop.post { late = true }
                posted.signal()
            }
            posted.wait()
        }
        t.check(weakSkin == nil, "a result posted from another thread does not hold the skin while it waits")
        t.equal(executor.pendingKinds, [.async])
        executor.runPending()
        t.check(!late, "it is dropped: the skin is gone")

        // While it runs, it holds the skin, which the executor then lets go of — even when the thread that posted it
        // has not got past `post` yet. Were that thread holding the skin, it could end up with the last reference,
        // and the skin with its measures and meters would be released there, off the executor.
        var owner: Skin? = try executorSkin(t, ini, executor: executor).0
        weakSkin = owner
        let hop = owner!.hop()
        let handedOver = DispatchSemaphore(value: 0), goOn = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        executor.afterNextAsync {
            handedOver.signal()
            goOn.wait()
        }
        var aliveWhileRunning = false
        DispatchQueue.global().async {
            hop.post {
                owner = nil  // the skin's last owner lets go while the result runs
                aliveWhileRunning = weakSkin != nil
            }
            returned.signal()
        }
        // The posting thread is held up inside `post`, right after handing the result over.
        t.check(handedOver.wait(timeout: .now() + 60) == .success, "the result was handed over")
        executor.runPending()
        t.check(aliveWhileRunning, "the result holds the skin while it runs")
        t.check(weakSkin == nil, "and the executor lets go of it, not the thread that posted the result")
        goOn.signal()
        t.check(returned.wait(timeout: .now() + 60) == .success)

        var gone: SkinHop?
        do {
            let (skin, _) = try executorSkin(t, ini, executor: executor)
            weakSkin = skin
            gone = skin.hop()
        }
        t.check(weakSkin == nil, "a hop taken for background work does not hold the skin")
        var goneRan = false, dropped = false
        gone?.post({ goneRan = true }, orElse: { dropped = true })
        t.equal(executor.pendingKinds, [.async], "whether the skin is there is decided on the executor")
        t.check(!dropped)
        executor.runPending()
        t.check(!goneRan && dropped, "the work is dropped, and what must not be left behind is cleaned up instead")

        do {
            let (skin, _) = try executorSkin(t, ini, executor: executor)
            weakSkin = skin
            (skin.measure(named: "Timer") as? ActionTimerMeasure)?.clock = { 100 }
            skin.update()
            skin.execute("[!Delay 86400000][!SetVariable Late 1][!CommandMeasure Timer \"Execute 1\"]", from: nil)
            executor.runPending()  // the delay: the ActionTimer starts
            executor.runPending()  // its first step: it waits a minute
            t.equal(executor.pendingKinds, [.timer(interval: 60, leeway: 0, repeats: false)])
            skin.execute("[!Delay 86400000][!SetVariable Late 1]", from: nil)
        }
        t.check(weakSkin == nil, "a pending !Delay or a waiting ActionTimer does not keep a dropped skin alive")
        t.check(executor.all.last?.work.isCancelled == true, "the released skin cancelled its pending delay")
        t.check(executor.all.first { $0.kind == .timer(interval: 60, leeway: 0, repeats: false) }?.work.isCancelled
                == true, "the released ActionTimer cancelled its timer")
        executor.runPending()
    }
}

// MARK: - Close

private func runExecutorCloseTests(_ t: TestRunner) {
    t.suite("Executor: closing a skin cancels its delays and timers") {
        let executor = ManualExecutor()
        let (skin, _) = try executorSkin(t, """
        [Rainmeter]
        Update=-1
        TransitionUpdate=50
        [V]
        Measure=Calc
        Formula=0
        MinValue=0
        MaxValue=100
        [Timer]
        Measure=Plugin
        Plugin=ActionTimer
        ActionList1=Wait 60000 | Tick
        Tick=[!SetVariable Ticked 1]
        [M]
        Measure=Plugin
        Plugin=Mouse
        UpdateRate=1000
        MouseMoveAction=[!SetVariable Moved "$MouseX$"]
        [S]
        Measure=Plugin
        Plugin=Slider
        HoldDelay=60000
        HoldAction=[!SetVariable Held 1]
        [Run]
        Measure=Plugin
        Plugin=RunCommand
        Parameter=sleep 60
        Timeout=86400000
        FinishAction=[!SetVariable Finished 1]
        [B]
        Meter=Bitmap
        MeasureName=V
        BitmapImage=Strip.png
        BitmapFrames=4
        BitmapTransitionFrames=1
        [Box]
        Meter=Image
        W=100
        H=50
        SolidColor=0,0,0,255
        """, executor: executor)
        var now = 100.0
        (skin.measure(named: "Timer") as! ActionTimerMeasure).clock = { now }
        (skin.measure(named: "M") as! MouseMeasure).clock = { now }
        (skin.measure(named: "S") as! SliderMeasure).clock = { now }
        skin.update()
        skin.execute("[!CommandMeasure Timer \"Execute 1\"]", from: nil)
        executor.runPending()
        skin.execute("[!SetOption V Formula 100][!UpdateMeasure V][!UpdateMeter B]", from: nil)
        skin.execute("[!Delay 86400000][!SetVariable Late 1]", from: nil)
        skin.execute("[!CommandMeasure Run Run]", from: nil)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10, y: 10)
        skin.pointerEvent(.dragged, x: 11, y: 10)
        now = 100.25
        skin.pointerEvent(.dragged, x: 12, y: 10)
        // (Anything handed over with `async` belongs to the program, which is still running.)
        let waiting = executor.pending.filter { $0.kind != .async }
        t.equal(Set(waiting.map { "\($0.kind)" }), Set([
            ManualExecutor.Kind.timer(interval: 60, leeway: 0, repeats: false),   // ActionTimer Wait, Slider hold
            .after(0.05),                                                         // Bitmap transition
            .after(86_400),                                                       // !Delay, RunCommand Timeout
            .timer(interval: 0.75, leeway: 0, repeats: false),                    // Mouse UpdateRate
        ].map { "\($0)" }))
        t.equal(waiting.count, 6)
        skin.close()
        t.check(waiting.allSatisfy { $0.work.isCancelled }, "every delay and timer of the skin is cancelled")
        // What the killed program's exit hands back finds the run over.
        t.check(executor.waitForAsync(), "the killed program's exit still comes back")
        executor.runPending()
        for name in ["Ticked", "Late", "Held", "Finished"] { t.equal(skin.variable(name), nil, name) }
        t.equal(skin.variable("Moved"), "11")
    }

    t.suite("Executor: closing a skin cancels its transfers and drops late results") {
        let executor = ManualExecutor()
        let host = FakeHost()
        let (skin, _) = try executorSkin(t, """
        [Rainmeter]
        Update=-1
        [Parent]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        RegExp=(?siU)value=(.*);
        StringIndex=1
        FinishAction=[!SetVariable Done 1]
        [Res]
        Measure=Plugin
        Plugin=ResMon
        ResCountType=Handle
        ProcessName=launchd
        """, files: ["Root/Sub/data.txt": "value=42;"], executor: executor, host: host)
        skin.update()
        let parent = skin.measure(named: "Parent") as! WebParserMeasure
        let res = skin.measure(named: "Res") as! ResMonMeasure
        t.check(executor.waitForAsync(2), "both results are on their way back")
        let handle = parent.fetchHandle
        t.check(handle != nil && handle?.cancelled == false)
        let logs = host.logs
        skin.close()
        t.check(handle?.cancelled == true, "the unload cancels the transfer")
        executor.runPending()
        t.equal(parent.stringValue, "", "a result that arrives after the unload is dropped")
        t.equal(skin.variable("Done"), nil, "and runs no action")
        t.equal(host.logs, logs, "nor logs anything")
        t.check(res.knownProcessIDs == nil, "a ResMon lookup that ends after the unload is dropped")
    }

    t.suite("Executor: closing a skin cancels its downloads; a temporary file that nobody takes is deleted") {
        let ini = """
        [Rainmeter]
        Update=-1
        [Parent]
        Measure=WebParser
        URL=file://#CURRENTPATH#data.txt
        RegExp=(?siU)image=(.*);
        [Image]
        Measure=WebParser
        URL=[Parent]
        StringIndex=1
        Download=1
        FinishAction=[!SetVariable Downloaded 1]
        """
        /// Loads the skin and applies the page; returns once the child's download has been saved to a temporary file
        /// (`file`: its path) and the result waits on the executor.
        func downloaded(_ name: String, on executor: ManualExecutor) throws
            -> (skin: Skin, image: WebParserMeasure, file: String?) {
            let (skin, _) = try executorSkin(t, ini, executor: executor)
            let picture = skin.directory.appendingPathComponent(name)
            try "picture".write(to: picture, atomically: true, encoding: .utf8)
            try "image=\(picture.path);".write(to: skin.directory.appendingPathComponent("data.txt"), atomically: true,
                                               encoding: .utf8)
            skin.update()
            t.check(executor.waitForAsync(), "the page comes back")
            executor.runPending()
            t.check(executor.waitForAsync(), "the download comes back")
            return (skin, skin.measure(named: "Image") as! WebParserMeasure,
                    temporaryDownloads(endingWith: "-" + name).first)
        }

        let run = String(UUID().uuidString.prefix(8))
        let executor = ManualExecutor()
        let (skin, image, file) = try downloaded("executor-close-\(run).txt", on: executor)
        t.check(file.map { FileManager.default.fileExists(atPath: $0) } == true, "saved to a temporary file")
        let handle = image.downloadHandle
        t.check(handle != nil && handle?.cancelled == false)
        skin.close()
        t.check(handle?.cancelled == true, "the unload cancels the download")
        executor.runPending()
        t.equal(skin.variable("Downloaded"), nil, "a download that arrives after the unload runs no action")
        t.equal(image.stringValue, "", "and sets no value")
        t.check(file.map { !FileManager.default.fileExists(atPath: $0) } == true, "and its temporary file is deleted")

        // A skin dropped without being closed (the Manage window's dry runs): the result finds nobody to take it.
        let dropping = ManualExecutor()
        weak var weakSkin: Skin?
        var orphan: String?
        do {
            let loaded = try downloaded("executor-gone-\(run).txt", on: dropping)
            weakSkin = loaded.skin
            orphan = loaded.file
        }
        t.check(weakSkin == nil, "the result on its way back does not keep the skin alive")
        t.check(orphan.map { FileManager.default.fileExists(atPath: $0) } == true, "saved to a temporary file")
        dropping.runPending()
        t.check(orphan.map { !FileManager.default.fileExists(atPath: $0) } == true,
                "a temporary file saved for a skin that is gone is deleted")
    }
}

// MARK: - Ownership

private func runOwnershipTests(_ t: TestRunner) {
    t.suite("Executor: debug builds check who touches a skin") {
        #if DEBUG
        var violations: [String] = []
        let saved = Skin.ownershipViolation
        Skin.ownershipViolation = { _, entry in violations.append("\(entry)") }
        defer { Skin.ownershipViolation = saved }

        let ini = """
        [Rainmeter]
        Update=-1
        [C]
        Measure=Calc
        Formula=C + 1
        DynamicVariables=1
        [M]
        Meter=String
        MeasureName=C
        W=50
        H=20
        LeftMouseUpAction=[!SetVariable Clicked 1]
        """
        // A whole life on the skin's own thread: nothing to report.
        let (skin, _) = try executorSkin(t, ini)
        skin.update()
        skin.execute("[!SetVariable A 1][!Redraw]", from: nil)
        skin.perform(Bang(name: "update", args: []))
        skin.mouseMoved(x: 5, y: 5)
        t.check(skin.mouseEvent(.leftUp, x: 5, y: 5))
        skin.mouseExited()
        _ = skin.toolTipInfo(at: 5, 5)
        _ = skin.contextMenuItems()
        skin.preview(section: "M", ["X": "5"])
        skin.endPreview()
        skin.close()
        t.equal(violations, [], "the main executor owns the skin on the main thread")

        // The same calls from somewhere that does not own the skin: every entry point says so.
        let elsewhere = ManualExecutor()
        let (other, _) = try executorSkin(t, ini)
        other.executor = elsewhere
        elsewhere.claimsCurrent = false
        other.update()
        other.execute("[!SetVariable A 1]", from: nil)
        other.perform(Bang(name: "redraw", args: []))
        _ = other.mouseEvent(.leftUp, x: 5, y: 5)
        other.pointerEvent(.moved, x: 5, y: 5)
        other.preview(section: "M", ["X": "5"])
        other.setVariable("B", "2")
        other.measure(named: "C")?.readOptionsIfNeeded()
        other.close()
        for entry in ["update()", "execute(_:from:)", "perform(_:from:)", "mouseEvent(_:x:y:)",
                      "pointerEvent(_:x:y:)", "preview(section:_:)", "setVariable(_:_:)", "readOptionsIfNeeded()",
                      "close()"] {
            t.check(violations.contains(entry), "\(entry) is checked (\(violations.count) reports)")
        }

        // The main executor off the main thread.
        violations = []
        let (mainSkin, _) = try executorSkin(t, ini)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            mainSkin.assertOwned("background probe")
            done.signal()
        }
        done.wait()
        t.equal(violations, ["background probe"])
        #else
        print("    (skipped: the ownership checks exist in debug builds only)")
        #endif
    }
}
