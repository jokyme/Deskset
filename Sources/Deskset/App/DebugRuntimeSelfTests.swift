import AppKit
import DesksetCore

enum DebugRuntimeSelfTests {
    static func run(_ t: AppTestRunner) {
        expressionAndSourceTests(t)
        consumerAndCancellationTests(t)
    }

    private static func expressionAndSourceTests(_ t: AppTestRunner) {
        for mode in [SkinThreading.main, .engine, .pool] {
            t.suite("App: Debug runtime: watch expressions, source locations and owner executor (\(mode))") {
                guard let app = try AppSelfTest.makeApp(t, threading: mode) else { return }
                defer {
                    app.stopAllForTermination()
                    app.endEngineThread()
                }
                let folder = try writeFixture(app)
                guard let controller = app.activate(config: "Debug\\Probe", file: "Probe.ini") else {
                    return t.check(false, "debug fixture loads")
                }
                t.check(AppSelfTest.spin { controller.isStarted }, "skin started")
                let runtime = controller.runtime
                let counterBefore = runtime.snapshot.counter
                let longValue = String(repeating: "Watch value.", count: 80)
                let expressions: [DebugWatchExpression] = [
                    .init(kind: .string, text: "#Label# / [MeasureNumber]"),
                    .init(kind: .formula, text: "MeasureNumber + #Amount# + [MeasureNumber:]"),
                    .init(kind: .formula, text: "MissingMeasure + 1"),
                    .init(kind: .formula, text: "12px"),
                    .init(kind: .string, text: "#LongValue#"),
                    .init(kind: .string, text: "#NotDefined#"),
                    .init(kind: .formula, text: "$SkinW + #Amount#"),
                    .init(kind: .formula, text: "1 / 0"),
                    .init(kind: .string, text: ""),
                    .init(kind: .formula, text: ""),
                    .init(kind: .string, text: "[&Script:Mark()]"),
                ]
                var captured: SkinDebugState?
                var deliveredOnMain = false
                runtime.requestDebugState(consumerID: UUID(), expressions: expressions) { state in
                    deliveredOnMain = Thread.isMainThread
                    captured = state
                }
                t.check(AppSelfTest.spin { captured != nil }, "watch snapshot delivered")
                guard let state = captured else { return }
                t.check(deliveredOnMain, "immutable results delivered to main")
                t.equal(state.watchResults.map(\.expression), expressions, "stable IDs and original text retained")
                t.equal(state.watchResults.count, expressions.count)
                guard state.watchResults.count == expressions.count else { return }
                t.equal(state.watchResults[0].value, "hello / 7")
                t.equal(state.watchResults[1].value, "19")
                t.equal(state.watchResults[1].error, nil)
                t.equal(state.watchResults[2].value, nil)
                t.check(state.watchResults[2].error?.isEmpty == false, "unknown measure reports a formula error")
                t.equal(state.watchResults[3].value, nil)
                t.check(state.watchResults[3].error?.isEmpty == false, "strict formula parsing rejects a numeric prefix")
                t.equal(state.watchResults[4].value, longValue, "watch output remains untruncated")
                t.equal(state.watchResults[5].value, "#NotDefined#", "unresolved string syntax retains resolver behavior")
                t.equal(state.watchResults[6].value, "125", "formula lookup includes skin dimensions")
                t.equal(state.watchResults[7].value, "0", "formula domain handling remains the engine's")
                t.equal(state.watchResults[8].value, "")
                t.check(state.watchResults[9].error?.isEmpty == false, "empty formula reports its error")
                t.equal(state.watchResults[10].value, "inline")
                t.equal(state.variables.first { $0.name == "FromInline" }?.value, "changed",
                        "inline script work is reflected in the same snapshot")
                t.equal(runtime.snapshot.counter, counterBefore, "inspection does not update the skin")

                let mainFile = folder.appendingPathComponent("Probe.ini")
                let includeFile = folder.appendingPathComponent("Values.inc")
                let scriptFile = folder.appendingPathComponent("Watch.lua")
                t.equal(state.fileURL, mainFile)
                t.equal(state.dependencyFiles, [mainFile, includeFile, scriptFile],
                        "main, include and actual ScriptFile paths are deduplicated")
                t.equal(state.measures.first { $0.name == "MeasureNumber" }?.location,
                        IniSourceLocation(file: includeFile, line: 6))
                t.equal(state.variables.first { $0.name == "Label" }?.location,
                        IniSourceLocation(file: includeFile, line: 2))
                t.check(state.sectionLocations["meterback"] != nil, "meter definitions retain edit locations")

                // Changing a runtime variable does not change the script that is currently loaded.
                runtime.send(.execute("[!SetVariable ScriptName NeverLoaded.lua]", section: nil))
                captured = nil
                runtime.requestDebugState { captured = $0 }
                t.check(AppSelfTest.spin { captured != nil })
                t.equal(captured?.dependencyFiles, [mainFile, includeFile, scriptFile],
                        "dependency inspection does not re-expand ScriptFile using newer variables")
                t.equal(captured?.watchResults, [], "default requests remain compatible")
                t.equal(runtime.snapshot.counter, counterBefore)

                // Clearing both ScriptFile options closes their Lua states; stale resolved paths are not listed.
                runtime.send(.execute("[!SetOption Script ScriptFile \"\"][!UpdateMeasure Script]"
                    + "[!SetOption ScriptAgain ScriptFile \"\"][!UpdateMeasure ScriptAgain]", section: nil))
                captured = nil
                runtime.requestDebugState { captured = $0 }
                t.check(AppSelfTest.spin { captured != nil })
                t.equal(captured?.dependencyFiles, [mainFile, includeFile])
            }
        }
    }

    private static func consumerAndCancellationTests(_ t: AppTestRunner) {
        t.suite("App: Debug runtime: consumers coalesce independently and drop cancelled or closed deliveries") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            defer {
                app.stopAllForTermination()
                app.endEngineThread()
            }
            _ = try writeFixture(app)
            guard let controller = app.activate(config: "Debug\\Probe", file: "Probe.ini") else {
                return t.check(false, "debug fixture loads")
            }
            t.check(AppSelfTest.spin { controller.isStarted })
            let runtime = controller.runtime
            SkinDebugProbe.setTestMetricsRecording(true)
            SkinDebugProbe.resetTestCounters()
            defer { SkinDebugProbe.setTestMetricsRecording(false) }

            let pollConsumer = UUID()
            let editorConsumer = UUID()
            let watchID = UUID()
            let gate = SkinLifecycleSelfTests.Gate()
            gate.hold(runtime.executor)
            defer { gate.open() }
            var pollValues: [String] = []
            var editorValues: [String] = []
            var defaultValues: [String] = []
            var firstPollTicket: SkinDebugRequestTicket?
            for value in 1...20 {
                let ticket = runtime.requestDebugState(consumerID: pollConsumer, expressions: [
                    .init(id: watchID, kind: .formula, text: String(value)),
                ]) { state in
                    pollValues.append(state.watchResults.first?.value ?? "missing")
                }
                if value == 1 { firstPollTicket = ticket }
            }
            runtime.requestDebugState(consumerID: editorConsumer, expressions: [
                .init(kind: .formula, text: "100"),
            ]) { editorValues.append($0.watchResults.first?.value ?? "missing") }
            runtime.requestDebugState(expressions: [.init(kind: .formula, text: "200")]) {
                defaultValues.append($0.watchResults.first?.value ?? "missing")
            }
            firstPollTicket?.cancel()
            t.equal(SkinDebugProbe.testCounters(for: runtime).enqueued, 3,
                    "one queued closure for each independent consumer")
            t.equal(SkinDebugProbe.activeTicketCount, 3)
            gate.open()
            t.check(AppSelfTest.spin {
                pollValues.count == 1 && editorValues.count == 1 && defaultValues.count == 1
                    && SkinDebugProbe.activeSlotCount == 0
            })
            t.equal(pollValues, ["20"], "only the latest expression revision of a consumer is read")
            t.equal(editorValues, ["100"], "the editor is not replaced by polling")
            t.equal(defaultValues, ["200"], "the default consumer is independent")
            t.equal(SkinDebugProbe.testCounters(for: runtime).evaluated, 3)
            t.equal(SkinDebugProbe.activeTicketCount, 0)

            // A captured response can already be queued to main when the user edits the expression.
            // Wait only for the engine barrier, without pumping main, to force this order deterministically.
            var revisedValues: [String] = []
            runtime.requestDebugState(consumerID: editorConsumer, expressions: [
                .init(id: watchID, kind: .formula, text: "1"),
            ]) { revisedValues.append($0.watchResults.first?.value ?? "missing") }
            let capturedBarrier = DispatchSemaphore(value: 0)
            runtime.executor.async { capturedBarrier.signal() }
            t.check(capturedBarrier.wait(timeout: .now() + 5) == .success, "first revision was captured")
            runtime.requestDebugState(consumerID: editorConsumer, expressions: [
                .init(id: watchID, kind: .formula, text: "2"),
            ]) { revisedValues.append($0.watchResults.first?.value ?? "missing") }
            t.check(AppSelfTest.spin { revisedValues == ["2"] && SkinDebugProbe.activeSlotCount == 0 })
            t.equal(revisedValues, ["2"], "captured stale revision never reaches the editor")

            SkinDebugProbe.resetTestCounters()
            let cancelGate = SkinLifecycleSelfTests.Gate()
            cancelGate.hold(runtime.executor)
            defer { cancelGate.open() }
            var cancelledDeliveries = 0
            var liveDeliveries = 0
            let cancelled = runtime.requestDebugState(consumerID: pollConsumer) { _ in cancelledDeliveries += 1 }
            runtime.requestDebugState(consumerID: editorConsumer) { _ in liveDeliveries += 1 }
            cancelled.cancel()
            cancelGate.open()
            t.check(AppSelfTest.spin { liveDeliveries == 1 && SkinDebugProbe.activeSlotCount == 0 })
            t.equal(cancelledDeliveries, 0)
            t.equal(SkinDebugProbe.testCounters(for: runtime).evaluated, 1,
                    "cancelling one consumer skips its read without cancelling the other")
            t.equal(SkinDebugProbe.activeTicketCount, 0)

            SkinDebugProbe.resetTestCounters()
            var closedDeliveries = 0
            runtime.requestDebugState(consumerID: pollConsumer) { _ in closedDeliveries += 1 }
            runtime.requestDebugState(consumerID: editorConsumer) { _ in closedDeliveries += 1 }
            runtime.send(.close(fadeOut: false))
            t.check(runtime.waitUntilClosed(before: Date().addingTimeInterval(5)))
            t.equal(SkinDebugProbe.testCounters(for: runtime).evaluated, 2,
                    "both consumers captured before the queued close")
            t.check(AppSelfTest.spin {
                SkinDebugProbe.activeSlotCount == 0 && SkinDebugProbe.activeTicketCount == 0
            })
            t.equal(closedDeliveries, 0, "a closed runtime never delivers either consumer's captured state")
            runtime.requestDebugState(consumerID: editorConsumer) { _ in closedDeliveries += 1 }
            t.equal(SkinDebugProbe.activeSlotCount, 0, "closed runtimes accept no new slots")
        }
    }

    private static func writeFixture(_ app: AppController) throws -> URL {
        let folder = app.skinsDirectory.appendingPathComponent("Debug/Probe")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let values = """
        [Variables]
        Label=hello
        Amount=5
        LongValue=\(String(repeating: "Watch value.", count: 80))

        [MeasureNumber]
        Measure=Calc
        Formula=7
        """
        try values.write(to: folder.appendingPathComponent("Values.inc"), atomically: true, encoding: .utf8)
        let ini = """
        [Rainmeter]
        Update=-1
        @Include=Values.inc

        [Variables]
        ScriptName=Watch.lua
        FromInline=initial

        [Script]
        Measure=Script
        ScriptFile=#ScriptName#

        [ScriptAgain]
        Measure=Script
        ScriptFile=#ScriptName#

        """ + SkinLifecycleSelfTests.meter
        try ini.write(to: folder.appendingPathComponent("Probe.ini"), atomically: true, encoding: .utf8)
        let script = """
        function Update() return 3 end
        function Mark()
            SKIN:Bang('!SetVariable', 'FromInline', 'changed')
            return 'inline'
        end
        """
        try script.write(to: folder.appendingPathComponent("Watch.lua"), atomically: true, encoding: .utf8)
        app.rescanLibrary()
        return folder
    }
}
