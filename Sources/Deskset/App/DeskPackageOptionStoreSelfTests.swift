import Foundation
import DesksetCore

/// Scratch-only durable records and pure scope reconciliation; no widget owner or shared fanout is started.
enum DeskPackageOptionStoreSelfTests {
    private enum Failure: Error { case fixture }
    private struct Package {
        let id: UUID
        let sources: [DeskWidgetSourceState]
        let instances: [DeskWidgetInstanceState]
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(value))
    }

    private static func records(_ values: [String: ProgramOptionValue]) throws -> [String: JSONValue] {
        try DeskProgramOptionStore.encode(ProgramOptionsInput(values: values))
    }

    private static func makeState(_ t: AppTestRunner) throws -> AppState {
        let file = t.temporaryDirectory("desk-package-options").appendingPathComponent("state.json")
        try Data(#"{"futureRoot":{"keep":true},"deskWidgets":{"futureNamespace":[7,"keep"]}}"#.utf8).write(to: file)
        return AppState(fileURL: file)
    }

    private static func install(_ state: AppState) throws -> Package {
        let id = UUID()
        let sources = ["Small.desk", "Mid.desk"].map { name -> DeskWidgetSourceState in
            var source = DeskWidgetSourceState(id: UUID(), entry: id.uuidString.lowercased() + "/" + name, packageID: id)
            source.unknownKeys = ["futureSource": .string(name)]
            return source
        }
        let instances = (sources + [sources[0]]).map { source -> DeskWidgetInstanceState in
            var instance = DeskWidgetInstanceState(id: UUID(), sourceID: source.id)
            instance.unknownKeys = ["futureInstance": .bool(true)]
            return instance
        }
        try state.registerDeskInstallation(sources: sources, instances: instances)
        return Package(id: id, sources: sources, instances: instances)
    }

    private static func program(_ options: [ProgramOptionNode]) -> WidgetProgram {
        WidgetProgram(name: "Options", root: ProgramElement(id: ElementID(name: "root", index: 0),
            content: .rectangle(fill: .accent), width: .fixed(1), height: .fixed(1)), options: options)
    }

    private static func sharedDefinitions() -> [ProgramOptionNode] {
        [
            .option(ProgramOption(name: "show", title: .string("Show"), control: .toggle,
                                  defaultValue: .boolean(true), scope: .package)),
            .option(ProgramOption(name: "amount", title: .string("Amount"),
                control: .slider(min: ProgramNumber(0, dimension: .plain), max: ProgramNumber(10, dimension: .plain), step: nil),
                defaultValue: .number(ProgramNumber(2, dimension: .plain)), scope: .package)),
            .option(ProgramOption(name: "label", title: .string("Label"), control: .input(placeholder: nil),
                                  defaultValue: .string("Package default"), scope: .package)),
            .option(ProgramOption(name: "look", title: .string("Look"), control: .picker(choices: [
                .init(value: .localCase(option: "look", name: "mono"), title: .string("Mono")),
                .init(value: .localCase(option: "look", name: "full"), title: .string("Full"))]),
                defaultValue: .localCase(option: "look", name: "mono"), scope: .package)),
            .option(ProgramOption(name: "bytes", title: .string("Bytes"), control: .slider(
                min: ProgramNumber(0, dimension: .bytes, displayBase: 1000),
                max: ProgramNumber(10000, dimension: .bytes, displayBase: 1000), step: nil),
                defaultValue: .number(ProgramNumber(1000, dimension: .bytes, displayBase: 1000)), scope: .package))
        ]
    }

    static func run(_ t: AppTestRunner) {
        compatibility(t)
        identity(t)
        atomicSave(t)
        scopes(t)
        budgets(t)
    }

    private static func compatibility(_ t: AppTestRunner) {
        t.suite("App: Desk package options storage: legacy JSON and unknown fields survive independent package records") {
            let state = try makeState(t)
            t.check(state.data.deskWidgets.packageOptions.isEmpty)
            guard case .object(let legacy)? = try encoded(state.data)["deskWidgets"] else { throw Failure.fixture }
            t.equal(legacy["packageOptions"], nil)
            let id = UUID(), empty = UUID(), damaged = UUID()
            let futureValue: JSONValue = .object(["version": .number(2), "kind": .string("future"),
                                                  "payload": .array([.string("untouched"), .number(3)])])
            let raw: [String: JSONValue] = ["futureRoot": .bool(true), "deskWidgets": .object([
                "futureNamespace": .string("keep"), "packageOptions": .object([
                    id.uuidString.lowercased(): .object(["optionValues": .object(["future": futureValue]),
                        "futureRecord": .object(["keep": .bool(true)])]),
                    empty.uuidString.lowercased(): .object(["optionValues": .string("damaged"), "futureRecord": .number(9)]),
                    damaged.uuidString.lowercased(): .bool(false)
                ])])]
            try JSONEncoder().encode(raw).write(to: state.fileURL)
            let loaded = AppState(fileURL: state.fileURL)
            t.equal(loaded.deskPackageOptions(id)?.optionValues, ["future": futureValue])
            t.equal(loaded.deskPackageOptions(id)?.unknownKeys, ["futureRecord": .object(["keep": .bool(true)])])
            t.equal(loaded.deskPackageOptions(empty)?.optionValues, [:])
            t.equal(loaded.deskPackageOptions(empty)?.unknownKeys, ["futureRecord": .number(9)])
            t.equal(loaded.deskPackageOptions(damaged), nil)
            t.check(!loaded.data.deskWidgets.isEmpty)
            loaded.saveNow()
            let again = AppState(fileURL: state.fileURL)
            t.equal(again.data.deskWidgets, loaded.data.deskWidgets)
            t.equal(again.data.unknownKeys, ["futureRoot": .bool(true)])
            t.equal(again.data.deskWidgets.unknownKeys, ["futureNamespace": .string("keep")])
            let bytes = try Data(contentsOf: state.fileURL)
            do {
                try loaded.saveDeskPackageOptions(id, values: [:])
                t.check(false, "an orphan record does not authorize a package write")
            } catch {
                if case AppState.DeskOptionsSaveFailure.packageChanged = error { t.check(true) }
                else { t.check(false, "unexpected orphan error: \(error)") }
            }
            t.equal(try Data(contentsOf: state.fileURL), bytes)
            t.equal(loaded.data.deskWidgets, again.data.deskWidgets)
        }
    }

    private static func identity(_ t: AppTestRunner) {
        t.suite("App: Desk package options storage: installed package identity owns one record across members and instances") {
            let state = try makeState(t), a = try install(state), b = try install(state)
            let standalone = UUID(), standaloneInstance = UUID()
            try state.registerDeskInstallation(source: .init(id: standalone, entry: standalone.uuidString.lowercased() + "/Widget.desk"),
                instance: .init(id: standaloneInstance, sourceID: standalone))
            let local = try records(["label": .string("Local override")])
            try state.saveDeskOptions(a.instances[0].id, sourceID: a.sources[0].id, values: local)
            try state.saveDeskOptions(standaloneInstance, sourceID: standalone, values: local)
            let aValues = try records(["label": .string("A"), "show": .boolean(false)])
            let bValues = try records(["label": .string("B"), "show": .boolean(true)])
            try state.saveDeskPackageOptions(a.id, values: aValues)
            try state.saveDeskPackageOptions(b.id, values: bValues)
            t.equal(Set(state.data.deskWidgets.packageOptions.keys), Set([a.id, b.id].map { $0.uuidString.lowercased() }))
            for source in a.sources {
                t.check(source.id != a.id)
                t.equal(state.deskPackageOptions(source.packageID!)?.optionValues, aValues)
                t.equal(state.deskPackageOptions(source.id), nil)
            }
            for instance in a.instances {
                t.equal(state.deskInstance(instance.id)?.optionValues, instance.id == a.instances[0].id ? local : [:])
            }
            state.updateDeskInstance(a.instances[0].id) { $0.x = 123; $0.y = -45; $0.active = true }
            let latestInstances = state.data.deskWidgets.instances, sources = state.data.deskWidgets.sources
            let changed = try records(["label": .string("A changed"), "show": .boolean(false)])
            try state.saveDeskPackageOptions(a.id, values: changed)
            let reloaded = AppState(fileURL: state.fileURL)
            t.equal(reloaded.data.deskWidgets.instances, latestInstances)
            t.equal(reloaded.data.deskWidgets.sources, sources)
            t.equal(reloaded.deskPackageOptions(a.id)?.optionValues, changed)
            t.equal(reloaded.deskPackageOptions(b.id)?.optionValues, bValues)
            t.equal(reloaded.deskInstance(standaloneInstance)?.optionValues, local)
            t.equal(reloaded.data.unknownKeys, ["futureRoot": .object(["keep": .bool(true)])])
            t.equal(reloaded.data.deskWidgets.unknownKeys, ["futureNamespace": .array([.number(7), .string("keep")])])
            let disk = try Data(contentsOf: state.fileURL), memory = try encoded(state.data)
            for wrong in [a.sources[0].id, standalone, UUID()] {
                do { try state.saveDeskPackageOptions(wrong, values: changed); t.check(false, "not an installed package") }
                catch {
                    if case AppState.DeskOptionsSaveFailure.packageChanged = error { t.check(true) }
                    else { t.check(false, "unexpected package identity error: \(error)") }
                }
            }
            t.equal(try encoded(state.data), memory); t.equal(try Data(contentsOf: state.fileURL), disk)
            state.updateDeskInstance(a.instances[0].id) { $0.active = false }
            state.saveNow()
            t.equal(AppState(fileURL: state.fileURL).deskPackageOptions(a.id)?.optionValues, changed,
                    "deactivation keeps the installed package's options")
        }
    }

    private static func atomicSave(_ t: AppTestRunner) {
        t.suite("App: Desk package options storage: mixed saves are atomic and preserve latest instance state") {
            let state = try makeState(t), a = try install(state), b = try install(state)
            let localOld = try records(["label": .string("Local old")]), localNew = try records(["label": .string("Local new")])
            let sharedOld = try records(["show": .boolean(true)]), sharedNew = try records(["show": .boolean(false)])
            try state.saveDeskOptions(a.instances[0].id, sourceID: a.sources[0].id, values: localOld,
                package: .init(packageID: a.id, values: sharedOld))
            try state.saveDeskPackageOptions(b.id, values: sharedOld)
            state.updateDeskInstance(a.instances[0].id) { $0.x = -86; $0.y = 73; $0.active = true }
            state.saveNow()
            let before = try encoded(state.data), original = try Data(contentsOf: state.fileURL)
            let backup = state.fileURL.deletingLastPathComponent().appendingPathComponent("saved.json")
            try FileManager.default.moveItem(at: state.fileURL, to: backup)
            try FileManager.default.createDirectory(at: state.fileURL, withIntermediateDirectories: false)
            var blocked = true
            defer {
                if blocked {
                    try? FileManager.default.removeItem(at: state.fileURL)
                    try? FileManager.default.moveItem(at: backup, to: state.fileURL)
                }
            }
            for mixed in [false, true] {
                do {
                    if mixed {
                        try state.saveDeskOptions(a.instances[0].id, sourceID: a.sources[0].id, values: localNew,
                            package: .init(packageID: a.id, values: sharedNew))
                    } else { try state.saveDeskPackageOptions(a.id, values: sharedNew) }
                    t.check(false, "a directory at the state file must reject the atomic write")
                } catch { t.check(true) }
                t.equal(try encoded(state.data), before)
                t.equal(try Data(contentsOf: backup), original)
            }
            try FileManager.default.removeItem(at: state.fileURL)
            try FileManager.default.moveItem(at: backup, to: state.fileURL)
            blocked = false
            do {
                try state.saveDeskOptions(a.instances[0].id, sourceID: a.sources[0].id, values: localNew,
                    package: .init(packageID: b.id, values: sharedNew))
                t.check(false, "an instance cannot include another package in its write")
            } catch {
                if case AppState.DeskOptionsSaveFailure.packageChanged = error { t.check(true) }
                else { t.check(false, "unexpected mixed identity error: \(error)") }
            }
            t.equal(try encoded(state.data), before); t.equal(try Data(contentsOf: state.fileURL), original)
            try state.saveDeskOptions(a.instances[0].id, sourceID: a.sources[0].id, values: localNew,
                package: .init(packageID: a.id, values: sharedNew))
            let reloaded = AppState(fileURL: state.fileURL)
            t.equal(reloaded.deskInstance(a.instances[0].id)?.optionValues, localNew)
            t.equal(reloaded.deskPackageOptions(a.id)?.optionValues, sharedNew)
            t.equal(reloaded.deskPackageOptions(b.id)?.optionValues, sharedOld)
            t.equal(reloaded.deskInstance(a.instances[0].id)?.x, -86)
            t.equal(reloaded.deskInstance(a.instances[0].id)?.y, 73)
            t.equal(reloaded.deskInstance(a.instances[0].id)?.active, true)
            t.equal(reloaded.deskInstance(a.instances[0].id)?.unknownKeys, a.instances[0].unknownKeys)
            for instance in Array(a.instances.dropFirst()) + b.instances {
                t.equal(reloaded.deskInstance(instance.id), instance)
            }
        }
    }

    private static func scopes(_ t: AppTestRunner) {
        t.suite("App: Desk package options storage: schema recovery and instance overrides never rewrite authoritative package values") {
            let definitions = sharedDefinitions(), packageSchema = try ProgramOptionsSchema(options: definitions)
            let inherited = program(definitions)
            let member = program([.section(title: .string("Member"), items: definitions.filter {
                if case .option(let option) = $0 { return option.name != "label" }; return true
            } + [
                .option(ProgramOption(name: "label", title: .string("Local label"), control: .input(placeholder: nil),
                    defaultValue: .string("Local default"))),
                .option(ProgramOption(name: "local", title: .string("Local"), control: .toggle, defaultValue: .boolean(false)))
            ])])
            let saved = try records(["show": .boolean(false), "amount": .number(ProgramNumber(8, dimension: .plain)),
                "label": .string("Shared saved"), "look": .localCase(option: "look", name: "full"),
                "bytes": .number(ProgramNumber(1024, dimension: .bytes, displayBase: 1024)), "removed": .boolean(true)])
            let shared = DeskProgramOptionStore.restore(saved, schema: packageSchema)
            t.equal(shared.restoredNames, Set(["removed"]))
            t.equal(shared.input.values["bytes"], .number(ProgramNumber(1024, dimension: .bytes, displayBase: 1000)))
            let local = try records(["label": .string("Instance saved"), "local": .boolean(true),
                                     "amount": .number(ProgramNumber(9, dimension: .plain)), "obsolete": .boolean(true)])
            let restored = try DeskProgramOptionStore.restoreInstance(local, for: member, package: shared.input)
            t.equal(restored.input.values["label"], .string("Instance saved"))
            t.equal(restored.input.values["local"], .boolean(true))
            t.equal(restored.input.values["amount"], .number(ProgramNumber(8, dimension: .plain)))
            t.equal(restored.restoredNames, Set(["amount", "obsolete"]))
            let other = try DeskProgramOptionStore.restoreInstance([:], for: inherited, package: shared.input)
            t.equal(other.input, shared.input)
            let split = try DeskProgramOptionStore.split(restored.input, for: member)
            t.equal(split.instance.values, ["label": .string("Instance saved"), "local": .boolean(true)])
            t.equal(split.packagePatch["label"], nil); t.equal(split.packagePatch["local"], nil)
            t.equal(split.packagePatch["amount"], .number(ProgramNumber(8, dimension: .plain)))

            let state = try makeState(t), installed = try install(state)
            try state.saveDeskPackageOptions(installed.id, values: saved)
            let disk = try Data(contentsOf: state.fileURL), before = state.deskPackageOptions(installed.id)
            var corrupt = saved
            corrupt["show"] = .object(["version": .number(2), "kind": .string("bool"), "value": .bool(false)])
            corrupt["amount"] = try records(["amount": .number(ProgramNumber(99, dimension: .plain))])["amount"]
            corrupt["look"] = try records(["look": .localCase(option: "other", name: "full")])["look"]
            let recovered = DeskProgramOptionStore.restore(corrupt, schema: packageSchema)
            t.equal(recovered.restoredNames, Set(["show", "amount", "look", "removed"]))
            for name in ["show", "amount", "look"] { t.equal(recovered.input.values[name], packageSchema.defaults.values[name]) }
            let defaultOverride = try DeskProgramOptionStore.restoreInstance([:], for: member, package: recovered.input)
            t.equal(defaultOverride.input.values["label"], .string("Local default"))
            t.equal(recovered.input.values["label"], .string("Shared saved"))
            t.equal(state.deskPackageOptions(installed.id), before); t.equal(try Data(contentsOf: state.fileURL), disk)
            for invalid in [ProgramOptionsInput(values: [:]), ProgramOptionsInput(values: ["show": .boolean(true),
                "amount": .number(ProgramNumber(99, dimension: .plain)), "look": .localCase(option: "look", name: "mono"),
                "bytes": .number(ProgramNumber(1000, dimension: .bytes, displayBase: 1000))])] {
                do { _ = try DeskProgramOptionStore.restoreInstance([:], for: member, package: invalid); t.check(false) }
                catch { t.check(true, "missing or incompatible shared values cannot become member defaults") }
            }

            // Only explicitly edited shared names are overlaid onto the latest complete package record.
            var latest = shared.input.values
            latest["label"] = .string("Newer shared label")
            try state.saveDeskPackageOptions(installed.id, values: records(latest))
            let authoritative = DeskProgramOptionStore.restore(state.deskPackageOptions(installed.id)?.optionValues ?? [:], schema: packageSchema)
            var merged = authoritative.input.values
            merged.merge(split.packagePatch.filter { $0.key == "amount" }) { _, changed in changed }
            let accepted = try packageSchema.validate(ProgramOptionsInput(values: merged))
            try state.saveDeskOptions(installed.instances[0].id, sourceID: installed.sources[0].id,
                values: DeskProgramOptionStore.encode(split.instance),
                package: .init(packageID: installed.id, values: DeskProgramOptionStore.encode(accepted)))
            t.equal(DeskProgramOptionStore.decode(state.deskPackageOptions(installed.id)?.optionValues ?? [:]).values["label"],
                    .string("Newer shared label"))
            t.equal(state.deskInstance(installed.instances[0].id)?.optionValues, try DeskProgramOptionStore.encode(split.instance))
            t.equal(DeskProgramOptionStore.decode(saved).values["label"], .string("Shared saved"))
        }
    }

    private static func budgets(_ t: AppTestRunner) {
        t.suite("App: Desk package options storage: encoded value and record limits are independent per installed package") {
            let state = try makeState(t), a = try install(state), b = try install(state)
            guard case .object(var boundary)? = try records(["text": .string("")])["text"] else { throw Failure.fixture }
            let overhead = try JSONEncoder().encode(JSONValue.object(boundary)).count
            boundary["value"] = .string(String(repeating: "x", count: DeskProgramOptionStore.maximumValueBytes - overhead))
            t.equal(try JSONEncoder().encode(JSONValue.object(boundary)).count, DeskProgramOptionStore.maximumValueBytes)
            let accepted = Dictionary(uniqueKeysWithValues: (0..<15).map { ("value\($0)", JSONValue.object(boundary)) })
            t.check(try JSONEncoder().encode(accepted).count < DeskProgramOptionStore.maximumTotalBytes)
            try state.saveDeskPackageOptions(a.id, values: accepted)
            try state.saveDeskPackageOptions(b.id, values: accepted)
            t.check(try JSONEncoder().encode(state.data.deskWidgets.packageOptions).count > DeskProgramOptionStore.maximumTotalBytes,
                    "1 MiB is a per-record policy, not a new all-packages quota")
            let before = try encoded(state.data), disk = try Data(contentsOf: state.fileURL)
            var overValue = boundary
            overValue["value"] = .string(String(repeating: "x", count: DeskProgramOptionStore.maximumValueBytes - overhead + 1))
            do { try state.saveDeskPackageOptions(a.id, values: ["text": .object(overValue)]); t.check(false) }
            catch {
                if case AppState.DeskOptionsSaveFailure.valueLimit = error { t.check(true) }
                else { t.check(false, "unexpected value limit error: \(error)") }
            }
            var overTotal = accepted; overTotal["value15"] = .object(boundary)
            t.check(try JSONEncoder().encode(overTotal).count > DeskProgramOptionStore.maximumTotalBytes)
            do {
                try state.saveDeskOptions(a.instances[0].id, sourceID: a.sources[0].id,
                    values: records(["local": .boolean(true)]), package: .init(packageID: a.id, values: overTotal))
                t.check(false)
            } catch {
                if case AppState.DeskOptionsSaveFailure.totalLimit = error { t.check(true) }
                else { t.check(false, "unexpected total limit error: \(error)") }
            }
            t.equal(try encoded(state.data), before); t.equal(try Data(contentsOf: state.fileURL), disk)
            let decoded = DeskProgramOptionStore.decode(overTotal)
            t.check(decoded.values.isEmpty); t.equal(decoded.invalidNames, Set(overTotal.keys))
            t.equal(AppState(fileURL: state.fileURL).data.deskWidgets, state.data.deskWidgets)
        }
    }
}
