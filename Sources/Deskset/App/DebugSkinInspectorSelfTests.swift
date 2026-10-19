import AppKit
import DesksetCore

enum DebugSkinInspectorSelfTests {
    static func run(_ t: AppTestRunner) {
        tableAndWatchTests(t)
        editorTests(t)
        cancellationTests(t)
        fileRefreshTests(t)
    }

    private static let longValue = String(repeating: "Long watch value.", count: 100)

    private static func tableAndWatchTests(_ t: AppTestRunner) {
        for mode in [SkinThreading.main, .engine, .pool] {
            t.suite("App: Debug skins: selection, groups, filter, full copy and watches (\(mode))") {
                guard let app = try AppSelfTest.makeApp(t, threading: mode) else { return }
                _ = try fixture(app, name: "Alpha", label: "alpha")
                _ = try fixture(app, name: "Beta", label: "beta")
                guard let alpha = app.activate(config: "DebugUI\\Alpha", file: "Skin.ini"),
                      let beta = app.activate(config: "DebugUI\\Beta", file: "Skin.ini") else {
                    return t.check(false, "both inspector fixtures load")
                }
                let view = DebugSkinInspectorView(app: app)
                defer { view.close(); app.stopAllForTermination(); app.endEngineThread() }
                t.check(AppSelfTest.spin { alpha.isStarted && beta.isStarted })
                view.activate(config: "debugui\\alpha")
                t.check(AppSelfTest.spin { view.currentSkinState?.config == "DebugUI\\Alpha" })
                t.equal(view.activeSkinConfigs, ["DebugUI\\Alpha", "DebugUI\\Beta"])
                t.equal(view.selectedSkinConfig, "DebugUI\\Alpha")
                t.equal(view.testTable.tableColumns.map(\.title), ["Name", "Number", "String"])
                t.equal(view.tableView(view.testTable, viewFor: nil, row: 0).flatMap { ($0 as? NSTextField)?.stringValue },
                        "Measures", "AppKit group rows receive a nil table column")
                guard let numberRow = row("MeasureNumber", in: view), let textRow = row("MeasureText", in: view) else {
                    return t.check(false, "measure rows are visible")
                }
                let numberColumn = view.testTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("number"))
                let numberCell = view.tableView(view.testTable, viewFor: numberColumn, row: numberRow) as? NSTextField
                t.equal(numberCell?.toolTip, view.currentSkinState?.measures.first { $0.name == "MeasureNumber" }?.range)
                t.check(view.currentSkinState?.measures.first { $0.name == "MeasureDisabled" }?.isDisabled == true)
                t.check(view.currentSkinState?.measures.first { $0.name == "MeasurePaused" }?.isPaused == true)
                t.check((view.currentSkinState?.measures.first { $0.name == "MeasureText" }?.displayString.count ?? 0) < longValue.count)

                view.testTable.selectRowIndexes(IndexSet(integer: textRow), byExtendingSelection: false)
                view.menuNeedsUpdate(view.testMenu)
                let copyIndex = view.testMenu.indexOfItem(withTitle: "Copy string")
                t.check(copyIndex >= 0)
                alpha.runtime.send(.execute("[!SetVariable LongValue changed][!UpdateMeasure MeasureText]", section: nil))
                view.pollNow()
                t.check(AppSelfTest.spin { view.currentSkinState?.measures.first { $0.name == "MeasureText" }?.string == "changed" })
                if copyIndex >= 0 { view.testMenu.performActionForItem(at: copyIndex) }
                t.equal(NSPasteboard.general.string(forType: .string), longValue,
                        "context copy keeps the full value captured when the menu opened")
                t.equal(cellName(view.testTable.selectedRow, in: view), "MeasureText", "live refresh preserves selected identity")

                setFilter("measurenumber", in: view)
                t.equal(visibleNames(view), ["Measures", "MeasureNumber"])
                setFilter("not-present", in: view)
                t.equal(view.testTable.numberOfRows, 0)
                setFilter("", in: view)
                let formula = DebugWatchExpression(kind: .formula, text: "MeasureNumber + #Amount#")
                view.addWatch(formula)
                view.addWatch(.init(kind: .string, text: "#Label#"))
                t.check(AppSelfTest.spin { view.currentSkinState?.watchResults.count == 2 })
                t.equal(view.currentSkinState?.watchResults.map(\.value), ["12", "alpha"])
                setFilter("not-present", in: view)
                t.equal(visibleNames(view), ["Watch", "MeasureNumber + #Amount#", "#Label#"],
                        "the measure and variable filter leaves watches visible")
                t.check(view.testJumpPopup.item(withTitle: "Watch")?.isEnabled == true)
                t.check(view.testJumpPopup.item(withTitle: "Measures")?.isEnabled == false)
                setFilter("", in: view)

                view.selectSkin(config: "DebugUI\\Beta")
                t.check(AppSelfTest.spin { view.currentSkinState?.config == "DebugUI\\Beta" })
                t.equal(view.testWatchExpressions, [])
                view.selectSkin(config: "DebugUI\\Alpha")
                t.check(AppSelfTest.spin { view.currentSkinState?.watchResults.count == 2 })
                t.equal(view.testWatchExpressions.first?.id, formula.id)
                let previousRuntime = app.controller(for: "DebugUI\\Alpha")?.runtime
                view.refreshNow()
                t.check(AppSelfTest.spin {
                    app.controller(for: "DebugUI\\Alpha")?.runtime !== previousRuntime
                        && view.currentSkinState?.watchResults.count == 2
                }, "refresh replaces the runtime and restores the session's watch expressions")
                t.equal(view.currentSkinState?.watchResults.first?.value, "12")
                view.showWatchEditor(initial: formula)
                t.check(view.editor != nil)
                app.deactivate(config: "DebugUI\\Alpha")
                view.reloadActiveSkinsList()
                t.check(AppSelfTest.spin { view.currentSkinState?.config == "DebugUI\\Beta" })
                t.equal(view.editor, nil, "unloading the editor's skin closes its editor")
                app.deactivate(config: "DebugUI\\Beta")
                view.reloadActiveSkinsList()
                t.equal(view.selectedSkinConfig, nil)
                t.equal(view.currentSkinState, nil)
                t.equal(view.testTable.numberOfRows, 0)
                t.check(!view.testAddWatchButton.isEnabled && !view.testRefreshCheck.isEnabled)
            }
        }
    }

    private static func editorTests(_ t: AppTestRunner) {
        t.suite("App: Debug watch editor: visible dialog, stale previews, complete copy and closing") {
            var requests: [(DebugWatchExpression, (String) -> Void)] = []
            var saved: [DebugWatchExpression] = []
            var executed: [String] = []
            var closed = 0
            let initial = DebugWatchExpression(kind: .string, text: "first")
            let editor = DebugWatchEditorController(initial: initial, preview: { requests.append(($0, $1)) },
                execute: { executed.append($0) }, save: { saved.append($0) }, onClose: { closed += 1 })
            defer { editor.close() }
            editor.window?.alphaValue = 0
            editor.show()
            t.check(editor.window?.isVisible == true, "show presents the editor without an optional caller-side showWindow")
            t.equal(editor.window?.initialFirstResponder, editor.testExpressionView)
            t.check(editor.testResultView.isSelectable && !editor.testResultView.isEditable)
            t.check(!editor.testCopyButton.isEnabled)
            editor.pollPreviewNow()
            t.equal(requests.count, 1, "timer and explicit polls cannot queue a second preview")
            setExpression("latest", in: editor)
            requests.first?.1("stale")
            RenderCommand.wait(milliseconds: 40)
            t.equal(editor.testResultView.string, "")
            editor.pollPreviewNow()
            t.check(AppSelfTest.spin { requests.count >= 2 })
            guard requests.count >= 2 else { return }
            t.equal(requests[1].0.text, "latest")
            requests[1].1(longValue)
            t.check(AppSelfTest.spin { editor.testResultView.string == longValue })
            editor.testCopyButton.performClick(nil)
            t.equal(NSPasteboard.general.string(forType: .string), longValue)
            editor.testFormulaButton.performClick(nil)
            t.check(!editor.testExecuteButton.isEnabled)
            editor.testExecuteButton.performClick(nil)
            t.equal(executed, [])
            editor.testStringButton.performClick(nil)
            editor.testExecuteButton.performClick(nil)
            t.equal(executed, ["latest"])
            editor.testSaveButton.performClick(nil)
            t.equal(saved.map(\.text), ["latest"])
            t.equal(saved.first?.id, initial.id)
            t.check(editor.isClosed && editor.window?.isVisible == false)
            editor.close()
            t.equal(closed, 1)
            requests[1].1("late")
            RenderCommand.wait(milliseconds: 40)
            t.check(editor.testResultView.string != "late")
        }

        t.suite("App: Debug watch editor: inspector ownership, save, cancel and empty input") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            _ = try fixture(app, name: "Alpha", label: "alpha")
            _ = app.activate(config: "DebugUI\\Alpha", file: "Skin.ini")
            let view = DebugSkinInspectorView(app: app)
            defer { view.close(); app.stopAllForTermination(); app.endEngineThread() }
            view.activate(config: "DebugUI\\Alpha")
            view.showWatchEditor(initial: nil)
            guard let editor = view.editor else { return t.check(false, "editor is retained") }
            t.check(!editor.testSaveButton.isEnabled && !editor.testExecuteButton.isEnabled)
            setExpression(" \n\t", in: editor)
            t.check(!editor.testSaveButton.isEnabled)
            setExpression("#Label#", in: editor)
            editor.pollPreviewNow()
            t.check(AppSelfTest.spin { editor.testResultView.string == "alpha" })
            editor.testSaveButton.performClick(nil)
            t.equal(view.editor, nil)
            t.equal(view.testWatchExpressions.map(\.text), ["#Label#"])
            t.check(AppSelfTest.spin { view.currentSkinState?.watchResults.first?.value == "alpha" })
            view.showWatchEditor(initial: view.testWatchExpressions.first)
            guard let cancelled = view.editor else { return t.check(false, "edit existing watch opens") }
            setExpression("not-saved", in: cancelled)
            cancelled.testCancelButton.performClick(nil)
            t.equal(view.editor, nil)
            t.equal(view.testWatchExpressions.map(\.text), ["#Label#"])
        }
    }

    private static func cancellationTests(_ t: AppTestRunner) {
        t.suite("App: Debug skins: switching, replacement and close reject blocked runtime callbacks") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            _ = try fixture(app, name: "Alpha", label: "alpha")
            _ = try fixture(app, name: "Beta", label: "beta")
            guard let alpha = app.activate(config: "DebugUI\\Alpha", file: "Skin.ini"),
                  let beta = app.activate(config: "DebugUI\\Beta", file: "Skin.ini") else { return }
            let view = DebugSkinInspectorView(app: app)
            defer { view.close(); app.stopAllForTermination(); app.endEngineThread() }
            t.check(AppSelfTest.spin { alpha.isStarted && beta.isStarted })
            view.activate(config: alpha.config)
            t.check(AppSelfTest.spin { view.currentSkinState?.config == alpha.config })
            let gate = SkinLifecycleSelfTests.Gate()
            gate.hold(alpha.runtime.executor)
            defer { gate.open() }
            view.pollNow()
            view.showWatchEditor(initial: .init(kind: .string, text: "#Label#"))
            let oldEditor = view.editor
            view.selectSkin(config: beta.config)
            view.deactivate()
            t.equal(view.editor, nil)
            t.check(oldEditor?.isClosed == true)
            gate.open()
            t.check(AppSelfTest.spin { SkinDebugProbe.activeTicketCount == 0 && SkinDebugProbe.activeSlotCount == 0 })
            t.equal(view.currentSkinState, nil, "hidden inspector rejects both old and new queued deliveries")
            view.activate(config: beta.config)
            t.check(AppSelfTest.spin { view.currentSkinState?.config == beta.config })
            let replacing = SkinLifecycleSelfTests.Gate()
            replacing.hold(beta.runtime.executor)
            defer { replacing.open() }
            view.pollNow()
            _ = try fixture(app, name: "Beta", label: "replacement", number: 9)
            view.refreshNow()
            t.equal(view.currentSkinState, nil, "same-config replacement clears the old snapshot immediately")
            replacing.open()
            t.check(AppSelfTest.spin {
                view.currentSkinState?.measures.first { $0.name == "MeasureNumber" }?.number == "9"
            })
            t.equal(view.currentSkinState?.variables.first { $0.name == "Label" }?.value, "replacement")
            guard let current = app.controller(for: beta.config) else { return }
            let closing = SkinLifecycleSelfTests.Gate()
            closing.hold(current.runtime.executor)
            defer { closing.open() }
            view.pollNow()
            view.close()
            closing.open()
            t.check(AppSelfTest.spin { SkinDebugProbe.activeTicketCount == 0 && SkinDebugProbe.activeSlotCount == 0 })
            t.equal(view.currentSkinState, nil, "close releases all subscriptions without a late table refill")
        }
    }

    private static func fileRefreshTests(_ t: AppTestRunner) {
        t.suite("App: Debug skins: include save refreshes selected skin and leaving stops watching") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let folder = try fixture(app, name: "Alpha", label: "before")
            guard let initial = app.activate(config: "DebugUI\\Alpha", file: "Skin.ini") else { return }
            let view = DebugSkinInspectorView(app: app)
            defer { view.close(); app.stopAllForTermination(); app.endEngineThread() }
            view.activate(config: initial.config)
            t.check(AppSelfTest.spin { view.currentSkinState != nil })
            view.testRefreshCheck.performClick(nil)
            t.check(AppSelfTest.spin { view.testFileRefresh.testBaselineCount == 2 })
            let included = folder.appendingPathComponent("Values.inc")
            var text = try String(contentsOf: included, encoding: .utf8)
            text = text.replacingOccurrences(of: "Label=before", with: "Label=after")
            try text.write(to: included, atomically: true, encoding: .utf8)
            t.check(AppSelfTest.spin {
                app.controller(for: initial.config)?.runtime !== initial.runtime
                    && view.currentSkinState?.variables.first { $0.name == "Label" }?.value == "after"
            }, "included file change refreshes the selected runtime and its inspection data")
            view.deactivate()
            t.check(!view.testFileRefresh.testIsWatching)
            t.equal(view.editor, nil)
        }
    }

    @discardableResult
    private static func fixture(_ app: AppController, name: String, label: String, number: Int = 7) throws -> URL {
        let folder = app.skinsDirectory.appendingPathComponent("DebugUI/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        [Variables]
        Label=\(label)
        Amount=5
        LongValue=\(longValue)

        [MeasureNumber]
        Measure=Calc
        Formula=\(number)
        MinValue=0
        MaxValue=100

        """.write(to: folder.appendingPathComponent("Values.inc"), atomically: true, encoding: .utf8)
        try """
        [Rainmeter]
        Update=-1
        @Include=Values.inc

        [MeasureText]
        Measure=String
        String=#LongValue#
        DynamicVariables=1

        [MeasureDisabled]
        Measure=Calc
        Formula=1
        Disabled=1

        [MeasurePaused]
        Measure=Calc
        Formula=2
        Paused=1

        [MeterBack]
        Meter=Shape
        Shape=Rectangle 0,0,120,60 | Fill Color 30,30,40,255 | StrokeWidth 0
        """.write(to: folder.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
        return folder
    }

    private static func cellName(_ row: Int, in view: DebugSkinInspectorView) -> String? {
        guard row >= 0 else { return nil }
        let column = view.testTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        return (view.tableView(view.testTable, viewFor: column, row: row) as? NSTextField)?.stringValue
    }

    private static func visibleNames(_ view: DebugSkinInspectorView) -> [String] {
        (0..<view.testTable.numberOfRows).compactMap { cellName($0, in: view) }
    }

    private static func row(_ name: String, in view: DebugSkinInspectorView) -> Int? {
        (0..<view.testTable.numberOfRows).first { cellName($0, in: view) == name }
    }

    private static func setFilter(_ text: String, in view: DebugSkinInspectorView) {
        view.testFilterField.stringValue = text
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.testFilterField))
    }

    private static func setExpression(_ text: String, in editor: DebugWatchEditorController) {
        editor.testExpressionView.string = text
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: editor.testExpressionView))
    }
}
