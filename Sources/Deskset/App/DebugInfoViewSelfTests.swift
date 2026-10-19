import AppKit

enum DebugInfoViewSelfTests {
    static func run(_ t: AppTestRunner) {
        lifecycleTests(t)
        checkboxTests(t)
        clipboardTests(t)
        layoutTests(t)
    }

    private static func lifecycleTests(_ t: AppTestRunner) {
        t.suite("App: Debug info view: one background request, stale activation and close results are dropped") {
            let reader = BlockingReader(blockedCalls: [1, 2])
            let view = DebugInfoView(kind: .network, networkReader: reader.read, refreshInterval: nil)
            defer { view.close(); reader.releaseAll() }
            view.activate()
            t.check(AppSelfTest.spin(timeout: 10) { reader.state.current.calls.count == 1 })
            for _ in 0..<20 { view.refresh() }
            t.equal(reader.state.current.calls.count, 1, "refreshes coalesce while the system lookup is blocked")
            t.equal(reader.state.current.maxActive, 1)
            t.equal(reader.state.current.mainThreadReads, 0)
            var mainResponded = false
            DispatchQueue.main.async { mainResponded = true }
            t.check(AppSelfTest.spin { mainResponded }, "main remains responsive while the worker is blocked")

            view.deactivate()
            view.activate()
            reader.release(1)
            t.check(AppSelfTest.spin(timeout: 10) { reader.state.current.calls.count == 2 })
            t.equal(view.groups, [], "a previous activation cannot populate the current page")
            t.equal(reader.state.current.maxActive, 1, "a new activation waits for the old lookup to finish")

            view.close()
            reader.release(2)
            t.check(AppSelfTest.spin(timeout: 10) { !view.isNetworkRequestInFlight })
            t.equal(view.groups, [], "closing drops a queued result without repopulating the page")
            t.equal(reader.state.current.calls.count, 2, "close does not schedule another coalesced request")

            view.activate()
            t.check(AppSelfTest.spin(timeout: 10) { view.groups == result(number: 3, virtual: false) })
            view.deactivate()
            t.equal(reader.state.current.maxActive, 1)
        }
    }

    private static func checkboxTests(_ t: AppTestRunner) {
        t.suite("App: Debug info view: virtual-interface changes reread once with the latest setting") {
            let reader = BlockingReader(blockedCalls: [1, 2])
            let view = DebugInfoView(kind: .network, networkReader: reader.read, refreshInterval: nil)
            defer { view.close(); reader.releaseAll() }
            view.activate()
            t.check(AppSelfTest.spin(timeout: 10) { reader.state.current.calls.count == 1 })
            t.equal(reader.state.current.calls, [false])
            view.testVirtualCheckbox.performClick(nil)
            t.equal(view.testVirtualCheckbox.state, .on)
            reader.release(1)
            t.check(AppSelfTest.spin(timeout: 10) { reader.state.current.calls.count == 2 })
            t.equal(reader.state.current.calls, [false, true])
            t.equal(view.groups, [], "the previous filter's delayed result is discarded")
            reader.release(2)
            t.check(AppSelfTest.spin(timeout: 10) { view.groups == result(number: 2, virtual: true) })
            view.deactivate()
            t.equal(reader.state.current.maxActive, 1)
            t.equal(view.testStatusText, "")
        }
    }

    private static func clipboardTests(_ t: AppTestRunner) {
        t.suite("App: Debug info view: complete value and all-fields copy freeze when the menu opens") {
            let long = String(repeating: "Display value 🌤 ", count: 80)
            var content = [DebugSystemInfo.Group(title: "Overview", fields: [
                DebugSystemInfo.Field(label: "Primary device", value: long),
                DebugSystemInfo.Field(label: "Display count", value: "2")
            ])]
            let view = DebugInfoView(kind: .display, displayReader: { content })
            defer { view.close() }
            view.activate()
            let table = view.testTable
            t.equal(table.numberOfRows, 3)
            t.equal(table.delegate?.tableView?(table, shouldSelectRow: 0), false)
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            view.copySelectedValue()
            t.equal(NSPasteboard.general.string(forType: .string), long, "copy keeps the full unclipped value")

            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                           timestamp: 0, windowNumber: 0, context: nil, characters: "c",
                                           charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8) {
                NSPasteboard.general.clearContents()
                t.check(table.performKeyEquivalent(with: event), "Command-C is handled by the focused property table")
                t.equal(NSPasteboard.general.string(forType: .string), long)
            } else {
                t.check(false, "a copy key event can be made")
            }

            guard let menu = table.menu, let copy = menu.item(withTitle: "Copy"),
                  let all = menu.item(withTitle: "Copy all") else { return t.check(false, "copy menu exists") }
            view.menuNeedsUpdate(menu)
            let before = view.copyAllText
            t.check(copy.isEnabled && all.isEnabled)
            content[0].fields[0].value = "New live value"
            view.refresh()
            t.equal(table.selectedRow, 1, "selection follows the same property across refresh")
            t.check(view.copyAllText != before)
            if let action = copy.action {
                t.check(NSApp.sendAction(action, to: copy.target, from: copy))
                t.equal(NSPasteboard.general.string(forType: .string), long, "menu Copy uses the value when opened")
            } else { t.check(false, "Copy has an action") }
            if let action = all.action {
                t.check(NSApp.sendAction(action, to: all.target, from: all))
                t.equal(NSPasteboard.general.string(forType: .string), before, "Copy all freezes groups and fields")
                t.equal(before, "Overview\nPrimary device: \(long)\nDisplay count: 2")
            } else { t.check(false, "Copy all has an action") }
            table.deselectAll(nil)
            view.menuNeedsUpdate(menu)
            t.equal(copy.isEnabled, false)
            t.equal(all.isEnabled, true)
        }
    }

    private static func layoutTests(_ t: AppTestRunner) {
        t.suite("App: Debug info view: grouped native tables fit light and dark minimum-size panes") {
            let fixture = [DebugSystemInfo.Group(title: "Device 1", fields: [
                DebugSystemInfo.Field(label: "Physical virtual screen", value: String(repeating: "long value ", count: 80)),
                DebugSystemInfo.Field(label: "Display name", value: "Built-in Display")
            ])]
            for kind in [DebugInfoView.Kind.display, .network] {
                let view = DebugInfoView(kind: kind, displayReader: { fixture }, networkReader: { _ in fixture },
                                         refreshInterval: nil)
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 300),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                defer { view.close(); window.close() }
                view.activate()
                t.check(AppSelfTest.spin { view.groups == fixture })
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    window.appearance = NSAppearance(named: appearance)
                    view.layoutSubtreeIfNeeded()
                    t.equal(view.bounds.width, 640, "long values never force a wider pane")
                    t.equal(view.testTable.tableColumns.map(\.title), ["Property", "Value"])
                    let firstGroup = view.tableView(view.testTable, viewFor: nil, row: 0) as? NSTextField
                    t.equal(firstGroup?.stringValue, "Device 1", "group titles also support the spanning-row request")
                    t.check(view.testTable.enclosingScrollView?.hasHorizontalScroller == true)
                    if kind == .network {
                        t.check(view.bounds.contains(view.convert(view.testVirtualCheckbox.bounds, from: view.testVirtualCheckbox)),
                                "the virtual-interface checkbox fits inside the pane")
                    }
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        t.check(false, "pane bitmap can be allocated")
                        continue
                    }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    t.equal(bitmap.pixelsWide, Int(view.bounds.width * window.backingScaleFactor))
                    t.equal(bitmap.pixelsHigh, Int(view.bounds.height * window.backingScaleFactor))
                }
            }
        }
    }

    private static func result(number: Int, virtual: Bool) -> [DebugSystemInfo.Group] {
        [DebugSystemInfo.Group(title: "en0", fields: [
            DebugSystemInfo.Field(label: "Alias", value: "Read \(number), virtual=\(virtual)")
        ])]
    }

    private final class BlockingReader {
        struct State {
            var calls: [Bool] = []
            var active = 0
            var maxActive = 0
            var mainThreadReads = 0
        }

        let state = Guarded(State())
        private let gates: [Int: DispatchSemaphore]

        init(blockedCalls: [Int]) {
            gates = Dictionary(uniqueKeysWithValues: blockedCalls.map { ($0, DispatchSemaphore(value: 0)) })
        }

        func read(_ virtual: Bool) -> [DebugSystemInfo.Group] {
            let number = state.access { value -> Int in
                value.calls.append(virtual)
                value.active += 1
                value.maxActive = max(value.maxActive, value.active)
                if Thread.isMainThread { value.mainThreadReads += 1 }
                return value.calls.count
            }
            defer { state.access { $0.active -= 1 } }
            if let gate = gates[number] { _ = gate.wait(timeout: .now() + 30) }
            return DebugInfoViewSelfTests.result(number: number, virtual: virtual)
        }

        func release(_ number: Int) { gates[number]?.signal() }
        func releaseAll() { gates.values.forEach { $0.signal() } }
    }
}
