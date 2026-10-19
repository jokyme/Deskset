import AppKit
import DesksetCore

enum AboutSelfTests {
    static func run(_ t: AppTestRunner) {
        entryPointAndBangTests(t)
        logTabTests(t)
        skinsTabMainEnginePoolTests(t)
        truncationAndFrozenMenuCopyTests(t)
        concurrencyAndSlotCleanupTests(t)
        pluginsAndVersionTabTests(t)
    }

    // MARK: Entry Points, Menus, Bangs & CLI

    private static func entryPointAndBangTests(_ t: AppTestRunner) {
        t.suite("App: About: entry points, skin Deskset submenu, Manage Open Log, !About bangs and CLI") {
            guard let app = try AppSelfTest.makeApp(t),
                  let focus = app.activate(config: "App\\Focus", file: "Focus.ini") else {
                return t.check(false, "app and Focus skin load")
            }
            defer { AboutWindowController.window(for: app)?.close() }

            // Tab parser covers canonical names, case-insensitivity, legacy Measures -> Skins, and unknown fallback -> Log.
            t.equal(AboutWindowController.Tab.parse(nil), .log)
            t.equal(AboutWindowController.Tab.parse(""), .log)
            t.equal(AboutWindowController.Tab.parse("  log "), .log)
            t.equal(AboutWindowController.Tab.parse("Skins"), .skins)
            t.equal(AboutWindowController.Tab.parse("MEASURES"), .skins)
            t.equal(AboutWindowController.Tab.parse("plugins"), .plugins)
            t.equal(AboutWindowController.Tab.parse("Version"), .version)
            t.equal(AboutWindowController.Tab.parse("UnknownFutureTab"), .log)

            // Status bar menu entries.
            let mainMenu = NSMenu()
            app.buildMainMenu(mainMenu)
            let openLogItem = mainMenu.item(withTitle: "Open Log")
            let aboutItem = mainMenu.item(withTitle: "About Deskset")
            t.equal(openLogItem?.action, #selector(AppController.openLogAction))
            t.equal(aboutItem?.action, #selector(AppController.aboutAction))

            // Skin context menu puts Manage / About / Refresh All inside the "Deskset" submenu, not after Unload Skin.
            let skinContext = app.skinMenu(for: focus, includeCustomItems: true)
            t.equal(skinContext.items.last?.title, "Unload Skin")
            t.equal(skinContext.item(withTitle: "About Deskset"), nil)
            let desksetSubmenu = skinContext.item(withTitle: "Deskset")?.submenu
            t.check(desksetSubmenu != nil, "skin context menu includes the Deskset submenu")
            t.equal(desksetSubmenu?.item(withTitle: "Manage")?.action, #selector(AppController.manageAction))
            t.equal(desksetSubmenu?.item(withTitle: "About")?.action, #selector(AppController.aboutAction))
            t.equal(desksetSubmenu?.item(withTitle: "Refresh All")?.action, #selector(AppController.refreshAllAction))

            // Manage window bottom bar has an "Open Log" button wired to openLogAction.
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            let openLogButton = findButton(titled: "Open Log", in: manage.window?.contentView)
            t.check(openLogButton != nil, "Manage window has Open Log button")
            t.equal(openLogButton?.action, #selector(AppController.openLogAction))

            // Opening via openLogAction and aboutAction routes to the shared About window on the Log tab.
            app.showAbout(tab: .version)
            guard let about = AboutWindowController.window(for: app) else {
                return t.check(false, "About window created")
            }
            t.equal(about.selectedTab, .version)
            app.openLogAction()
            t.equal(about.selectedTab, .log)
            about.selectTab(.plugins)
            t.equal(about.selectedTab, .plugins)
            app.aboutAction()
            t.equal(about.selectedTab, .log)

            // !About bangs from a skin switch tabs in the shared About window.
            focus.skin.execute("[!About Skins]", from: nil)
            t.check(AppSelfTest.spin { about.selectedTab == .skins })
            focus.skin.execute("[!About Plugins]", from: nil)
            t.check(AppSelfTest.spin { about.selectedTab == .plugins })
            focus.skin.execute("[!About Measures]", from: nil)
            t.check(AppSelfTest.spin { about.selectedTab == .skins }, "legacy !About Measures opens Skins tab")
            focus.skin.execute("[!About Version]", from: nil)
            t.check(AppSelfTest.spin { about.selectedTab == .version })
            focus.skin.execute("[!About]", from: nil)
            t.check(AppSelfTest.spin { about.selectedTab == .log }, "!About with no args defaults to Log")
            focus.skin.execute("[!About UnrecognizedTab]", from: nil)
            t.check(AppSelfTest.spin { about.selectedTab == .log }, "unknown !About argument falls back to Log")

            // CLI IPC routing via LayoutCommandServer / LayoutCommandClient and app.receiveLayoutCommand.
            app.finishLayoutCommandStartup()
            let channel = LayoutCommandsSelfTests.MemoryChannel()
            let namespace = "DesksetTests.About.\(UUID().uuidString)"
            let server = LayoutCommandServer(channel: channel, namespace: namespace, pid: 777) { request, completion in
                app.receiveLayoutCommand(request, completion: completion)
            }
            defer { server.stop() }
            let client = LayoutCommandClient(channel: channel, namespace: namespace)
            t.equal(client.send(.command(.about(.plugins)), to: 777, timeout: 0.2), .succeeded)
            t.equal(about.selectedTab, .plugins)
            t.equal(client.send(.command(.about(.skins)), to: 777, timeout: 0.2), .succeeded)
            t.equal(about.selectedTab, .skins)
        }
    }

    // MARK: Log Tab Behavior

    private static func logTabTests(_ t: AppTestRunner) {
        t.suite("App: About: Log tab initial 20 entries, newest-first polling, selection retention, filter and Clear") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            defer { AboutWindowController.window(for: app)?.close() }

            let token = UUID().uuidString
            for index in 1...25 {
                Log.write("History-\(token)-\(index)", level: .notice, source: "LogTest")
            }

            app.showAbout(tab: .log)
            guard let about = AboutWindowController.window(for: app) else {
                return t.check(false, "About window opens")
            }

            // Initial snapshot loads at most 20 recent entries, newest at index 0.
            t.equal(about.displayedLogs.count, 20)
            t.equal(about.displayedLogs.first?.message, "History-\(token)-25")
            t.equal(about.displayedLogs.last?.message, "History-\(token)-6")

            // Select row 0 ("History-...-25"), then emit two new log lines and poll:
            // newest lines prepend at top and the selected line moves down to index 2 with its selection preserved.
            about.testLogTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            Log.write("Live-\(token)-26", level: .warning, source: "LogTest")
            Log.write("Live-\(token)-27", level: .error, source: "LogTest")
            about.pollLogNow()
            t.equal(about.displayedLogs.first?.message, "Live-\(token)-27")
            t.equal(about.displayedLogs.dropFirst().first?.message, "Live-\(token)-26")
            t.equal(about.testLogTable.selectedRow, 2, "selection follows the same Log.Line.id after prepending")
            t.equal(about.displayedLogs[about.testLogTable.selectedRow].message, "History-\(token)-25")

            // Copy copies only the Message column, not TSV columns, and works via the table copy(_:) responder when menu is closed.
            NSPasteboard.general.clearContents()
            _ = about.window?.makeFirstResponder(about.testLogTable)
            t.check(NSApp.sendAction(#selector(NSText.copy(_:)), to: about.testLogTable, from: nil))
            t.equal(NSPasteboard.general.string(forType: .string), "History-\(token)-25")

            // Right-click menu freezes the copy text when opened so a poll before clicking Copy still copies the original row.
            about.testLogTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            about.menuNeedsUpdate(about.testLogMenu)
            Log.write("Live-\(token)-28", level: .notice, source: "LogTest")
            about.pollLogNow()
            t.equal(about.displayedLogs.first?.message, "Live-\(token)-28")
            about.testLogMenu.performActionForItem(at: 0)
            t.equal(NSPasteboard.general.string(forType: .string), "Live-\(token)-27",
                    "menuNeedsUpdate freezes the target message across common-mode polling")

            // Filtering checkboxes only control subsequent new messages and drain pending backlog under the old filter first.
            let countBeforeFilter = about.displayedLogs.count
            about.setLogFilter(error: false, warning: true, notice: false, debug: false)
            t.equal(about.displayedLogs.count, countBeforeFilter, "toggling filters does not delete existing rows")
            Log.write("FilteredOutError-\(token)", level: .error, source: "LogTest")
            Log.write("FilteredOutNoticeA-\(token)", level: .notice, source: "LogTest")
            Log.write("AcceptedWarning-\(token)", level: .warning, source: "LogTest")
            // Re-enabling Notice must drain FilteredOutNoticeA under the old (disabled) filter before enabling Notice.
            about.setLogFilter(error: true, warning: true, notice: true, debug: true)
            about.pollLogNow()
            t.equal(about.displayedLogs.count, countBeforeFilter + 1)
            t.equal(about.displayedLogs.first?.message, "AcceptedWarning-\(token)")
            t.check(!about.displayedLogs.contains(where: { $0.message == "FilteredOutNoticeA-\(token)" }),
                    "notice written while Notice filter was off is not retroactively added when Notice is turned back on")
            // Conversely, a notice written while Notice filter is on must not be lost if Notice is turned off before the next timer tick.
            Log.write("AcceptedNoticeB-\(token)", level: .notice, source: "LogTest")
            about.setLogFilter(notice: false)
            t.equal(about.displayedLogs.first?.message, "AcceptedNoticeB-\(token)",
                    "notice written while Notice filter was on is drained before Notice filter turns off")
            about.setLogFilter(error: true, warning: true, notice: true, debug: true)

            // Clear empties only the About panel and advances its cursor without wiping Log.recent.
            let globalBeforeClear = Log.recent.count
            about.clearLogPanel()
            t.equal(about.displayedLogs.count, 0)
            t.check(Log.recent.count >= globalBeforeClear, "global Log.recent is preserved for Studio")
            about.pollLogNow()
            t.equal(about.displayedLogs.count, 0, "poll after Clear does not reload old entries")

            // Exceeding Log.recentLimit caps displayedLogs to Log.recentLimit and clears selection if truncated out.
            Log.write("AnchorSelected-\(token)", level: .notice, source: "LogTest")
            about.pollLogNow()
            about.testLogTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            t.equal(about.testLogTable.selectedRow, 0)
            for idx in 1...(Log.recentLimit + 5) {
                Log.write("Flood-\(token)-\(idx)", level: .notice, source: "LogTest")
            }
            about.pollLogNow()
            t.equal(about.displayedLogs.count, Log.recentLimit, "displayedLogs is bounded by Log.recentLimit")
            t.equal(about.testLogTable.selectedRow, -1, "selection is cleared when selected row is truncated past Log.recentLimit")

            // Closing and reopening reloads the latest 20 entries from Log.recent.
            about.close()
            t.check(AboutWindowController.window(for: app) == nil, "closing releases the shared controller")
            app.showAbout(tab: .log)
            t.equal(AboutWindowController.window(for: app)?.displayedLogs.count, 20)
        }
    }

    // MARK: Skins Tab Across Main, Engine, and Pool Runtimes

    private static func skinsTabMainEnginePoolTests(_ t: AppTestRunner) {
        for mode in [SkinThreading.main, .engine, .pool] {
            t.suite("App: About: Skins inspector live measures and variables (\(mode))") {
                guard let app = try AppSelfTest.makeApp(t, threading: mode) else { return }
                defer {
                    AboutWindowController.window(for: app)?.close()
                    app.stopAllForTermination()
                    app.endEngineThread()
                }

                let folder = app.skinsDirectory.appendingPathComponent("Inspector/Probe")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let ini = """
                [Rainmeter]
                Update=-1

                [Variables]
                MixedCaseVar=InitialValue
                SecondVar=42

                [MeasureActive]
                Measure=Calc
                Formula=25
                MinValue=0
                MaxValue=100

                [MeasurePaused]
                Measure=Calc
                Formula=7
                Paused=1

                [MeasureDisabled]
                Measure=Calc
                Formula=99
                Disabled=1

                [MeterText]
                Meter=String
                Text=Hello
                """
                try ini.write(to: folder.appendingPathComponent("Probe.ini"), atomically: true, encoding: .utf8)
                app.rescanLibrary()

                guard let skin = app.activate(config: "Inspector\\Probe", file: "Probe.ini") else {
                    return t.check(false, "Inspector\\Probe loads")
                }
                t.check(AppSelfTest.spin { skin.isStarted }, "skin started")

                // Set a dynamic variable that was not declared in [Variables].
                skin.runtime.send(.execute(#"[!SetVariable DynamicRuntimeVar "AddedByBang"][!Update]"#, section: nil))

                app.showAbout(tab: .skins)
                guard let about = AboutWindowController.window(for: app) else {
                    return t.check(false, "About window opens")
                }
                t.check(AppSelfTest.spin {
                    about.currentSkinState?.config == "Inspector\\Probe"
                        && about.currentSkinState?.variables.contains(where: { $0.value == "AddedByBang" }) == true
                }, "Skins inspector receives live debug state")

                guard let state = about.currentSkinState else {
                    return t.check(false, "currentSkinState populated")
                }
                t.equal(state.measures.map(\.name), ["MeasureActive", "MeasurePaused", "MeasureDisabled"])
                t.equal(state.measures[0].range, "0 \u{2013} 100")
                t.equal(state.measures[0].number, "25")
                t.equal(state.measures[0].string, "25")
                t.check(!state.measures[0].isPaused && !state.measures[0].isDisabled)
                t.check(state.measures[1].isPaused && !state.measures[1].isDisabled)
                t.check(!state.measures[2].isPaused && state.measures[2].isDisabled)

                // Verify table views and visual state for Paused (yellow row view) and Disabled (tertiary label color).
                about.window?.contentView?.layoutSubtreeIfNeeded()
                let pausedRow = about.tableView(about.testMeasuresTable, rowViewForRow: 1) as? AboutMeasureRowView
                t.equal(pausedRow?.isPausedMeasure, true, "paused measure row uses yellow highlight row view")
                let activeRow = about.tableView(about.testMeasuresTable, rowViewForRow: 0) as? AboutMeasureRowView
                t.equal(activeRow?.isPausedMeasure, false)
                let disabledCell = about.tableView(
                    about.testMeasuresTable,
                    viewFor: about.testMeasuresTable.tableColumns.first,
                    row: 2
                ) as? NSTextField
                t.equal(disabledCell?.textColor, .tertiaryLabelColor, "disabled measure uses gray tertiaryLabelColor")

                // Variables preserve declared [Variables] casing, include dynamic runtime variables, and exclude built-ins.
                let varNames = state.variables.map(\.name)
                t.check(varNames.contains("MixedCaseVar"), "preserves declared variable casing")
                t.check(varNames.contains("SecondVar"))
                t.check(varNames.contains { $0.caseInsensitiveCompare("DynamicRuntimeVar") == .orderedSame },
                        "includes dynamic variable created via !SetVariable")
                t.check(!varNames.contains { $0.caseInsensitiveCompare("CURRENTPATH") == .orderedSame },
                        "excludes built-in variables")
                t.check(!varNames.contains { $0.caseInsensitiveCompare("CURRENTSECTION") == .orderedSame },
                        "excludes internal currentsection variable")

                // Deselecting in skinsTable (row = -1) calls selectSkin(config: nil) and clears the right-hand tables.
                about.testSkinsTable.deselectAll(nil)
                t.equal(about.selectedSkinConfig, nil)
                t.equal(about.currentSkinState, nil)
                t.equal(about.numberOfRows(in: about.testMeasuresTable), 0)
                t.equal(about.numberOfRows(in: about.testVariablesTable), 0)

                // Re-selecting restores the inspector state.
                about.selectSkin(config: "Inspector\\Probe")
                t.check(AppSelfTest.spin { about.currentSkinState?.config == "Inspector\\Probe" })
            }
        }
    }

    // MARK: 512-Character Display Truncation & Frozen Context Menu Copy

    private static func truncationAndFrozenMenuCopyTests(_ t: AppTestRunner) {
        t.suite("App: About: 512-char display truncation vs full clipboard copy and frozen context menu targets") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            defer { AboutWindowController.window(for: app)?.close() }

            let longMeasureTail = "END_OF_LONG_MEASURE_800"
            let longMeasureValue = String(repeating: "M", count: 600) + longMeasureTail
            let longVarTail = "END_OF_LONG_VARIABLE_800"
            let longVarValue = String(repeating: "V", count: 600) + longVarTail

            let folder = app.skinsDirectory.appendingPathComponent("Inspector/LongText")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ini = """
            [Rainmeter]
            Update=-1

            [Variables]
            LongVar=\(longVarValue)

            [MeasureLong]
            Measure=String
            String=\(longMeasureValue)

            [MeterStub]
            Meter=String
            Text=Stub
            """
            try ini.write(to: folder.appendingPathComponent("LongText.ini"), atomically: true, encoding: .utf8)
            app.rescanLibrary()

            guard let skin = app.activate(config: "Inspector\\LongText", file: "LongText.ini") else {
                return t.check(false, "LongText skin loads")
            }
            app.showAbout(tab: .skins)
            guard let about = AboutWindowController.window(for: app) else {
                return t.check(false, "About window opens")
            }
            t.check(AppSelfTest.spin { about.currentSkinState?.config == "Inspector\\LongText" })

            guard let measureItem = about.currentSkinState?.measures.first,
                  let varItem = about.currentSkinState?.variables.first(where: { $0.name == "LongVar" }) else {
                return t.check(false, "measure and variable items present")
            }

            // Display strings are truncated to 512 characters + "...".
            t.equal(measureItem.displayString.count, 515)
            t.check(measureItem.displayString.hasSuffix("..."))
            t.check(!measureItem.displayString.contains(longMeasureTail))
            t.equal(measureItem.string, longMeasureValue)

            t.equal(varItem.displayValue.count, 515)
            t.check(varItem.displayValue.hasSuffix("..."))
            t.check(!varItem.displayValue.contains(longVarTail))
            t.equal(varItem.value, longVarValue)

            // Context menu copy actions copy the full untruncated values, and freeze the target when the menu opens.
            about.testMeasuresTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            about.menuNeedsUpdate(about.testMeasuresMenu)
            skin.skin.execute(#"[!SetOption MeasureLong String "ChangedWhileMenuOpen"][!UpdateMeasure MeasureLong][!Update]"#, from: nil)
            about.refreshSelectedSkinDebugState()
            t.check(AppSelfTest.spin { about.currentSkinState?.measures.first?.string == "ChangedWhileMenuOpen" })
            about.testMeasuresMenu.performActionForItem(at: 3)
            t.equal(NSPasteboard.general.string(forType: .string), longMeasureValue,
                    "Measure Copy String uses the target frozen when the context menu opened")
            about.menuNeedsUpdate(about.testMeasuresMenu)

            about.testMeasuresMenu.performActionForItem(at: 0)
            t.equal(NSPasteboard.general.string(forType: .string), "MeasureLong")
            about.testMeasuresMenu.performActionForItem(at: 1)
            t.equal(NSPasteboard.general.string(forType: .string), "0 \u{2013} 1")
            about.testMeasuresMenu.performActionForItem(at: 2)
            t.equal(NSPasteboard.general.string(forType: .string), "0")

            // Variables context menu has only the official "Copy Value" item.
            t.equal(about.testVariablesMenu.items.map(\.title), ["Copy Value"])

            if let varIndex = about.currentSkinState?.variables.firstIndex(where: { $0.name == "LongVar" }) {
                about.testVariablesTable.selectRowIndexes(IndexSet(integer: varIndex), byExtendingSelection: false)
                about.menuNeedsUpdate(about.testVariablesMenu)
                skin.skin.execute(#"[!SetVariable LongVar "UpdatedVarWhileMenuOpen"][!Update]"#, from: nil)
                about.refreshSelectedSkinDebugState()
                t.check(AppSelfTest.spin {
                    about.currentSkinState?.variables.first(where: { $0.name == "LongVar" })?.value == "UpdatedVarWhileMenuOpen"
                })
                about.testVariablesMenu.performActionForItem(at: 0)
                t.equal(NSPasteboard.general.string(forType: .string), longVarValue,
                        "Variable Copy Value uses the target frozen when the context menu opened")
            }
        }
    }

    // MARK: Concurrency, Coalescing, Stale Callback Rejection & Slot Cleanup

    private static func concurrencyAndSlotCleanupTests(_ t: AppTestRunner) {
        t.suite("App: About: blocked executor coalesces to 1 closure, drops cancelled/stale results and releases slots") {
            SkinDebugProbe.setTestMetricsRecording(true)
            SkinDebugProbe.resetTestCounters()
            defer { SkinDebugProbe.setTestMetricsRecording(false) }

            guard let app = try AppSelfTest.makeApp(t) else { return }
            let executorA = SkinThreadExecutor(name: "AboutProbeA")
            let executorB = SkinThreadExecutor(name: "AboutProbeB")
            defer {
                AboutWindowController.window(for: app)?.close()
                app.stopAllForTermination()
                executorA.stop()
                executorB.stop()
            }

            try SkinLifecycleSelfTests.write(app, [
                "Alpha": SkinLifecycleSelfTests.plainSkin,
                "Beta": SkinLifecycleSelfTests.plainSkin,
            ])
            app.skinExecutor = { config in
                if config == "Life\\Alpha" { return executorA }
                if config == "Life\\Beta" { return executorB }
                return MainSkinExecutor.shared
            }

            guard let alpha = app.activate(config: "Life\\Alpha", file: nil),
                  let beta = app.activate(config: "Life\\Beta", file: nil) else {
                return t.check(false, "Alpha and Beta load")
            }
            t.check(AppSelfTest.spin { alpha.isStarted && beta.isStarted }, "both skins started")

            let alphaRuntime = alpha.runtime
            SkinDebugProbe.resetTestCounters()

            // Hold Alpha's executor and issue 10 rapid debug state requests: only 1 closure may be queued.
            let gate = SkinLifecycleSelfTests.Gate()
            gate.hold(executorA)
            var callbacksReceived = 0
            var lastTicket: SkinDebugRequestTicket?
            for _ in 0..<10 {
                lastTicket = alphaRuntime.requestDebugState { _ in
                    callbacksReceived += 1
                }
            }
            let whileBlocked = SkinDebugProbe.testCounters(for: alphaRuntime)
            t.equal(whileBlocked.enqueued, 1, "at most one closure queued on blocked executor")
            t.equal(whileBlocked.evaluated, 0)
            t.equal(whileBlocked.isQueued, true)
            t.equal(SkinDebugProbe.activeSlotCount, 1)
            t.equal(SkinDebugProbe.activeTicketCount, 1)

            // Cancel the ticket while Alpha's executor is still blocked, then open the gate:
            // the queued closure sees no subscriber, skips evaluation, delivers nothing, and releases the slot.
            lastTicket?.cancel()
            gate.open()
            t.check(AppSelfTest.spin { !SkinDebugProbe.testCounters(for: alphaRuntime).isQueued })
            let afterCancel = SkinDebugProbe.testCounters(for: alphaRuntime)
            t.equal(afterCancel.enqueued, 1)
            t.equal(afterCancel.evaluated, 0, "cancelled request skips capture on executor")
            t.equal(callbacksReceived, 0)
            t.equal(SkinDebugProbe.activeSlotCount, 0, "slot released after cancelled executor turn drains")
            t.equal(SkinDebugProbe.activeTicketCount, 0)

            // Now test switching skins and closing the About window while Alpha's executor is blocked.
            app.showAbout(tab: .skins)
            guard let about = AboutWindowController.window(for: app) else {
                return t.check(false, "About window opens")
            }
            about.selectSkin(config: "Life\\Alpha")
            t.check(AppSelfTest.spin {
                about.currentSkinState?.config == "Life\\Alpha"
                    && SkinDebugProbe.activeSlotCount == 0 && SkinDebugProbe.activeTicketCount == 0
            })
            t.equal(SkinDebugProbe.activeSlotCount, 0)

            SkinDebugProbe.resetTestCounters()
            let gate2 = SkinLifecycleSelfTests.Gate()
            gate2.hold(executorA)
            for _ in 0..<5 {
                about.refreshSelectedSkinDebugState()
            }
            t.equal(SkinDebugProbe.testCounters(for: alphaRuntime).enqueued, 1)

            // Switch to Beta before Alpha's gate opens: Alpha's ticket is cancelled and Beta's state loads.
            about.selectSkin(config: "Life\\Beta")
            t.check(AppSelfTest.spin { about.currentSkinState?.config == "Life\\Beta" })
            gate2.open()
            // Beta's polling timer may enqueue a fresh request while the main run loop drains Alpha.
            t.check(AppSelfTest.spin {
                !SkinDebugProbe.testCounters(for: alphaRuntime).isQueued
                    && SkinDebugProbe.activeSlotCount == 0 && SkinDebugProbe.activeTicketCount == 0
            })
            t.equal(about.currentSkinState?.config, "Life\\Beta", "stale Alpha callback never overwrites Beta")
            t.equal(SkinDebugProbe.activeSlotCount, 0, "no residual slots after skin switch")

            // Replacing the runtime for the same config immediately clears currentSkinState before the new runtime responds.
            if let betaBeforeRefresh = app.controller(for: "Life\\Beta") {
                let gateRefresh = SkinLifecycleSelfTests.Gate()
                app.refresh(betaBeforeRefresh)
                gateRefresh.hold(executorB)
                about.reloadActiveSkinsList()
                t.equal(about.currentSkinState, nil, "same-config runtime replacement immediately clears stale currentSkinState")
                gateRefresh.open()
                t.check(AppSelfTest.spin { about.currentSkinState?.config == "Life\\Beta" })
            }

            // Repeated refreshes and unloads leave 0 active slots and 0 active tickets.
            for _ in 0..<4 {
                if let currentBeta = app.controller(for: "Life\\Beta") {
                    app.refresh(currentBeta)
                }
                t.check(AppSelfTest.spin { app.controller(for: "Life\\Beta")?.isStarted == true })
                about.refreshSelectedSkinDebugState()
            }
            t.check(AppSelfTest.spin {
                about.currentSkinState?.config == "Life\\Beta" && SkinDebugProbe.activeSlotCount == 0
            })
            t.equal(SkinDebugProbe.activeSlotCount, 0, "slots do not grow across repeated refreshes")
            t.equal(SkinDebugProbe.activeTicketCount, 0)

            // Closing the window while a request is queued cancels it and leaves 0 slots once drained.
            if let currentAlpha = app.controller(for: "Life\\Alpha") {
                about.selectSkin(config: "Life\\Alpha")
                t.check(AppSelfTest.spin { about.currentSkinState?.config == "Life\\Alpha" })
                let gate3 = SkinLifecycleSelfTests.Gate()
                gate3.hold(executorA)
                about.refreshSelectedSkinDebugState()
                t.equal(SkinDebugProbe.activeSlotCount, 1)
                about.close()
                gate3.open()
                t.check(AppSelfTest.spin {
                    !SkinDebugProbe.testCounters(for: currentAlpha.runtime).isQueued
                        && SkinDebugProbe.activeSlotCount == 0
                })
                t.equal(SkinDebugProbe.activeSlotCount, 0, "closing window releases slot")
                t.equal(SkinDebugProbe.activeTicketCount, 0)
            }

            // Deterministic post-capture close window: on the main thread, enqueue requestDebugState on the worker
            // executor, immediately enqueue .close(fadeOut: false), and waitUntilClosed() without pumping main.
            // Worker FIFO runs capture first (queueing deliver onto main), then runs close (setting didClose = true).
            // Pumping main afterwards must drop the delivery and clean up both the ticket and slot.
            if let currentAlpha = app.controller(for: "Life\\Alpha") {
                let closingRuntime = currentAlpha.runtime
                SkinDebugProbe.resetTestCounters()
                var deliveredAfterClose = 0
                _ = closingRuntime.requestDebugState { _ in
                    deliveredAfterClose += 1
                }
                closingRuntime.send(.close(fadeOut: false))
                t.check(closingRuntime.waitUntilClosed(before: Date().addingTimeInterval(5)))
                t.equal(SkinDebugProbe.testCounters(for: closingRuntime).evaluated, 1,
                        "worker FIFO captured state before processing close")
                t.check(AppSelfTest.spin {
                    SkinDebugProbe.activeSlotCount == 0 && SkinDebugProbe.activeTicketCount == 0
                }, "main-thread deliver cleans up slot and ticket when runtime.didClose is true")
                t.equal(deliveredAfterClose, 0, "closed runtime never delivers captured state on main")
                t.equal(SkinDebugProbe.activeSlotCount, 0)
                t.equal(SkinDebugProbe.activeTicketCount, 0)
            }
        }
    }

    // MARK: Plugins & Version Tabs + UI Snapshots

    private static func pluginsAndVersionTabTests(_ t: AppTestRunner) {
        t.suite("App: About: Plugins 3 official columns, Version paths/copy, and 4-pane UI snapshots") {
            let root = t.temporaryDirectory("about-version")
            let customStateURL = root.appendingPathComponent("CustomConfigDir/custom-state.json")
            let settingsDir = root.appendingPathComponent("SettingsRoot", isDirectory: true)
            let skinsDir = root.appendingPathComponent("SkinsRoot", isDirectory: true)
            try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: skinsDir, withIntermediateDirectories: true)
            let app = AppController(
                state: AppState(fileURL: customStateURL),
                skinsDirectory: skinsDir,
                settingsDirectory: settingsDir,
                presentsWindows: false,
                threading: .main
            )
            defer { AboutWindowController.window(for: app)?.close() }

            app.showAbout(tab: .plugins)
            guard let about = AboutWindowController.window(for: app) else {
                return t.check(false, "About window opens")
            }

            // Official 3 columns only: Name, Version, Author.
            let columnTitles = about.testPluginsTable.tableColumns.map(\.title)
            t.equal(columnTitles, ["Name", "Version", "Author"])
            t.check(about.plugins.count >= 15, "registered compatibility plugins listed")
            let pluginNames = about.plugins.map(\.name)
            t.equal(pluginNames, pluginNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
            t.check(pluginNames.contains("NowPlaying") && pluginNames.contains("ActionTimer") && pluginNames.contains("AudioLevel"))
            for prefix in ["itunes", "win7audio"] {
                t.equal(pluginNames.filter { $0.lowercased().hasPrefix(prefix) }.count, 1,
                        "legacy \(prefix) plugin aliases share one row")
            }
            t.check(about.plugins.allSatisfy { $0.version == "\(AppVersion.current) (bundled)" },
                    "built-in implementations follow the Deskset version and are marked bundled")
            t.check(about.plugins.allSatisfy { $0.author == "jokyme" },
                    "built-in implementations identify their Deskset author")
            t.check(pluginNames.allSatisfy { !$0.hasSuffix("Measure") }, "internal Swift Measure type names are not exposed")

            // Version tab details & clipboard copy use app.state.fileURL.path directly.
            about.selectTab(.version)
            let details = about.currentVersionDetails()
            t.check(details.headline.hasPrefix("Deskset \(AppVersion.current)"))
            t.check(details.headline.contains(AboutWindowController.buildArchitecture))
            t.check(details.skinPath.hasPrefix(app.skinsDirectory.path))
            t.check(details.settingsPath.hasPrefix(app.settingsDirectory.path))
            t.equal(details.iniFile, customStateURL.path)
            t.equal(details.logFile, Log.fileURL.path)

            NSPasteboard.general.clearContents()
            about.copyVersionDetailsToClipboard()
            let copiedReport = NSPasteboard.general.string(forType: .string) ?? ""
            t.check(copiedReport.contains(details.headline))
            t.check(copiedReport.contains("IniFile: \(customStateURL.path)"))
            t.check(copiedReport.contains("SkinPath: \(details.skinPath)"))
            t.check(copiedReport.contains("SettingsPath: \(details.settingsPath)"))
            t.check(copiedReport.contains("LogFile: \(details.logFile)"))

            // Snapshot rendering across all 4 tabs in both Aqua and Dark Aqua appearances.
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                about.window?.appearance = NSAppearance(named: appearance)
                about.window?.setContentSize(NSSize(width: 680, height: 398))
                for tab in AboutWindowController.Tab.allCases {
                    about.selectTab(tab)
                    if let rep = about.snapshot() {
                        let scale = about.window?.backingScaleFactor ?? 1
                        t.equal(rep.pixelsWide, Int(680 * scale),
                                "snapshot width for \(tab.rawValue) in \(appearance.rawValue) at \(scale)x")
                        t.equal(rep.pixelsHigh, Int(398 * scale),
                                "snapshot height for \(tab.rawValue) in \(appearance.rawValue) at \(scale)x")
                        t.equal(about.window?.contentView?.bounds.width, 680,
                                "long paths do not widen the minimum-size window")
                    } else {
                        t.check(false, "snapshot failed for \(tab.rawValue)")
                    }
                }
            }
        }
    }

    private static func findButton(titled title: String, in root: NSView?) -> NSButton? {
        guard let root else { return nil }
        if let button = root as? NSButton, button.title == title {
            return button
        }
        for subview in root.subviews {
            if let hit = findButton(titled: title, in: subview) {
                return hit
            }
        }
        return nil
    }
}
