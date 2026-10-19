import Foundation

enum DebugFileRefreshSelfTests {
    static func run(_ t: AppTestRunner) {
        coalescingTests(t)
        restartTests(t)
        replacementTests(t)
        fileEventTests(t)
    }

    private static func coalescingTests(_ t: AppTestRunner) {
        t.suite("App: Debug file refresh: repeated saves coalesce and stop drops pending reads") {
            let file = t.temporaryDirectory("debug-refresh-coalesce").appendingPathComponent("Skin.ini")
            let reader = BlockingReader(blockedCalls: [1, 2])
            let refresh = DebugFileRefresh(debounceInterval: 0, readFile: reader.read)
            var refreshes = 0
            refresh.onRefresh = { refreshes += 1 }
            defer { refresh.stop(); reader.releaseAll() }
            refresh.start(files: [file])
            t.check(AppSelfTest.spin { reader.state.current.calls.count == 1 })
            for _ in 0..<12 {
                refresh.checkForChanges()
                t.check(AppSelfTest.spin { !refresh.testIsDebouncing })
            }
            t.equal(refresh.testPendingCount, 1, "file events remain one pending entry during a slow read")
            t.equal(reader.state.current.calls.count, 1)
            t.equal(reader.state.current.mainThreadReads, 0)
            reader.value.access { $0 = Data("changed".utf8) }
            reader.release(1)
            t.check(AppSelfTest.spin { reader.state.current.calls.count == 2 })
            t.equal(refresh.testBaselineCount, 1)
            t.equal(refreshes, 0)
            refresh.checkForChanges()
            t.check(AppSelfTest.spin { !refresh.testIsDebouncing })
            refresh.stop()
            reader.release(2)
            t.check(AppSelfTest.spin { !refresh.testIsReading })
            t.equal(reader.state.current.calls.count, 2, "stop leaves no stale read backlog")
            t.equal(reader.state.current.maxActive, 1)
            t.equal(refreshes, 0, "an in-flight change cannot refresh after stop")
            t.equal(refresh.testPendingCount, 0)
            t.equal(refresh.testBaselineCount, 0)
            t.check(!refresh.testIsWatching)
        }
    }

    private static func restartTests(_ t: AppTestRunner) {
        t.suite("App: Debug file refresh: restart waits for the old read and discards its result") {
            let directory = t.temporaryDirectory("debug-refresh-restart")
            let first = directory.appendingPathComponent("Old.ini")
            let second = directory.appendingPathComponent("New.ini")
            let reader = BlockingReader(blockedCalls: [1, 2])
            let refresh = DebugFileRefresh(debounceInterval: 0, readFile: reader.read)
            var refreshes = 0
            refresh.onRefresh = { refreshes += 1 }
            defer { refresh.stop(); reader.releaseAll() }
            refresh.start(files: [first])
            t.check(AppSelfTest.spin { reader.state.current.calls.count == 1 })
            refresh.checkForChanges()
            t.check(AppSelfTest.spin { !refresh.testIsDebouncing })
            refresh.stop()
            refresh.start(files: [second])
            t.equal(reader.state.current.calls.count, 1)
            t.equal(refresh.testPendingCount, 1)
            reader.release(1)
            t.check(AppSelfTest.spin { reader.state.current.calls.count == 2 })
            t.equal(reader.state.current.calls.map(\.lastPathComponent), ["Old.ini", "New.ini"])
            t.equal(refresh.testBaselineCount, 0, "the old generation cannot set a new activation's baseline")
            reader.release(2)
            t.check(AppSelfTest.spin { refresh.testBaselineCount == 1 && !refresh.testIsReading })
            t.equal(refreshes, 0)
            reader.value.access { $0 = Data("new activation change".utf8) }
            refresh.checkForChanges()
            t.check(AppSelfTest.spin { refreshes == 1 })
            t.equal(reader.state.current.calls.count, 3)
            t.equal(reader.state.current.maxActive, 1)
            t.equal(reader.state.current.mainThreadReads, 0)
        }
    }

    private static func replacementTests(_ t: AppTestRunner) {
        t.suite("App: Debug file refresh: removing and readding a file rejects its old baseline") {
            let file = t.temporaryDirectory("debug-refresh-replace").appendingPathComponent("Skin.ini")
            let reader = BlockingReader(blockedCalls: [1, 2])
            let refresh = DebugFileRefresh(debounceInterval: 0, readFile: reader.read)
            var refreshes = 0
            refresh.onRefresh = { refreshes += 1 }
            defer { refresh.stop(); reader.releaseAll() }
            refresh.start(files: [file])
            t.check(AppSelfTest.spin { reader.state.current.calls.count == 1 })
            refresh.update(files: [])
            reader.value.access { $0 = Data("replacement".utf8) }
            refresh.update(files: [file])
            reader.release(1)
            t.check(AppSelfTest.spin { reader.state.current.calls.count == 2 })
            t.equal(refresh.testBaselineCount, 0, "matching paths do not make a removed source current again")
            reader.release(2)
            t.check(AppSelfTest.spin { refresh.testBaselineCount == 1 && !refresh.testIsReading })
            t.equal(refreshes, 0)
            refresh.checkForChanges()
            t.check(AppSelfTest.spin { reader.state.current.calls.count == 3 && !refresh.testIsReading })
            t.equal(refreshes, 0, "the replacement's contents become its own baseline")
        }
    }

    private static func fileEventTests(_ t: AppTestRunner) {
        t.suite("App: Debug file refresh: initial save, native events, unchanged writes and storm limit") {
            let file = t.temporaryDirectory("debug-refresh-events").appendingPathComponent("Skin.ini")
            try "before".write(to: file, atomically: true, encoding: .utf8)
            let reader = BlockingReader(blockedCalls: [1], readsDisk: true)
            let refresh = DebugFileRefresh(maximumRefreshes: 2, stormInterval: 30,
                                           debounceInterval: 0, readFile: reader.read)
            var refreshes = 0
            var disabled: [String] = []
            refresh.onRefresh = { refreshes += 1 }
            refresh.onDisabled = { disabled.append($0) }
            defer { refresh.stop(); reader.releaseAll() }
            refresh.start(files: [file])
            t.check(AppSelfTest.spin { reader.state.current.calls.count == 1 })
            try "saved before baseline completes".write(to: file, atomically: true, encoding: .utf8)
            reader.release(1)
            t.check(AppSelfTest.spin { refreshes == 1 && !refresh.testIsReading && !refresh.testIsDebouncing })
            t.check(refresh.testIsWatching)
            t.equal(refresh.testBaselineCount, 1)

            // Reading the same bytes, including after an atomic save, must not reload the skin again.
            let readsBefore = reader.state.current.calls.count
            try "saved before baseline completes".write(to: file, atomically: true, encoding: .utf8)
            refresh.checkForChanges()
            t.check(AppSelfTest.spin {
                reader.state.current.calls.count > readsBefore && !refresh.testIsReading && !refresh.testIsDebouncing
            })
            t.equal(refreshes, 1)
            refresh.update(files: [file])
            try "native event".write(to: file, atomically: true, encoding: .utf8)
            t.check(AppSelfTest.spin { refreshes == 2 }, "FSEvents triggers a content check without manual polling")
            try "one change too many".write(to: file, atomically: true, encoding: .utf8)
            refresh.checkForChanges()
            t.check(AppSelfTest.spin { !refresh.isEnabled })
            t.equal(refreshes, 2, "the limit stops the next refresh instead of starting a loop")
            t.equal(disabled, ["Automatic refresh stopped because the skin files changed too frequently."])
            t.check(!refresh.testIsWatching)
            t.equal(refresh.testPendingCount, 0)
        }
    }

    private final class BlockingReader {
        struct State {
            var calls: [URL] = []
            var active = 0
            var maxActive = 0
            var mainThreadReads = 0
        }

        let state = Guarded(State())
        let value = Guarded<Data?>(Data("baseline".utf8))
        private let gates: [Int: DispatchSemaphore]
        private let readsDisk: Bool

        init(blockedCalls: [Int], readsDisk: Bool = false) {
            gates = Dictionary(uniqueKeysWithValues: blockedCalls.map { ($0, DispatchSemaphore(value: 0)) })
            self.readsDisk = readsDisk
        }

        func read(_ url: URL) -> Data? {
            let number = state.access { value -> Int in
                value.calls.append(url)
                value.active += 1
                value.maxActive = max(value.maxActive, value.active)
                if Thread.isMainThread { value.mainThreadReads += 1 }
                return value.calls.count
            }
            defer { state.access { $0.active -= 1 } }
            let captured = value.current
            if let gate = gates[number] { _ = gate.wait(timeout: .now() + 30) }
            return readsDisk ? try? Data(contentsOf: url) : captured
        }

        func release(_ number: Int) { gates[number]?.signal() }
        func releaseAll() { gates.values.forEach { $0.signal() } }
    }
}
