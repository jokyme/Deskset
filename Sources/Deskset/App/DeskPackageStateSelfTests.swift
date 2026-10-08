import Foundation
import DesksetCore

/// Package identity is persisted independently of member and instance identity. These tests use only scratch
/// state files; registering a source does not create a widget window or exercise package installation.
enum DeskPackageStateSelfTests {
    private static let packageID = UUID(uuidString: "89CF6A8F-A749-4E73-9B82-47248133A8B4")!
    private static let sourceID = UUID(uuidString: "068C4FF1-552D-4B52-B4AA-0178060B5371")!
    private static let instanceID = UUID(uuidString: "CE1797A2-A72A-45EF-A509-284B5B73DF23")!

    private static func packageSource() throws -> DeskWidgetSourceState {
        let json = """
        {"id":"\(sourceID)","entry":"\(packageID.uuidString.lowercased())/Small.desk",
         "packageID":"\(packageID)","futureSource":{"keep":7}}
        """
        return try JSONDecoder().decode(DeskWidgetSourceState.self, from: Data(json.utf8))
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(value))
    }

    private static func member(_ name: String, package: UUID = DeskPackageStateSelfTests.packageID,
                               id: UUID = UUID()) -> DeskWidgetSourceState {
        DeskWidgetSourceState(id: id, entry: package.uuidString.lowercased() + "/" + name, packageID: package)
    }

    private static func instances(for sources: [DeskWidgetSourceState]) -> [DeskWidgetInstanceState] {
        sources.map { DeskWidgetInstanceState(id: UUID(), sourceID: $0.id) }
    }

    private static func rejectsUnchanged(_ t: AppTestRunner, _ state: AppState,
                                         sources: [DeskWidgetSourceState], instances: [DeskWidgetInstanceState],
                                         _ message: String, line: UInt = #line) throws {
        let memory = try encoded(state.data), disk = try? Data(contentsOf: state.fileURL)
        do {
            try state.registerDeskInstallation(sources: sources, instances: instances)
            t.check(false, "registration unexpectedly accepted \(message)", line: line)
        } catch {
            t.check(true, line: line)
        }
        t.equal(try encoded(state.data), memory, "memory changed after rejecting \(message)", line: line)
        t.equal(try? Data(contentsOf: state.fileURL), disk, "disk changed after rejecting \(message)", line: line)
    }

    static func run(_ t: AppTestRunner) {
        t.suite("App: Desk package identity: a decoded member registers under its package directory without activation") {
            let url = t.temporaryDirectory("desk-package-identity").appendingPathComponent("state.json")
            let state = AppState(fileURL: url), source = try packageSource()
            var instance = DeskWidgetInstanceState(id: instanceID, sourceID: sourceID, x: 12, y: -34)
            instance.unknownKeys = ["futureInstance": .string("keep")]
            t.check(packageID != sourceID && sourceID != instanceID)
            t.equal(source.id, sourceID)
            t.equal(source.entry, packageID.uuidString.lowercased() + "/Small.desk")

            do {
                try state.registerDeskInstallation(source: source, instance: instance)
            } catch {
                t.check(false, "a package member with a distinct source identity was refused: \(error)")
                return
            }

            t.equal(state.deskSource(sourceID), source)
            t.equal(state.deskInstance(instanceID), instance)
            t.check(state.activeDeskWidgets.isEmpty, "registration must not activate the member")
            let reloaded = AppState(fileURL: url)
            t.equal(reloaded.deskSource(sourceID), source)
            t.equal(reloaded.deskInstance(instanceID), instance)
            t.check(reloaded.activeDeskWidgets.isEmpty, "reloading an inactive registration must not activate it")
            guard let persisted = reloaded.deskSource(sourceID) else {
                t.check(false, "the registered package member was not persisted")
                return
            }
            t.equal(try encoded(persisted), try encoded(source))
            t.equal(try encoded(source)["packageID"], .string(packageID.uuidString))
        }

        t.suite("App: Desk package identity: package metadata is recognized while legacy standalone registration stays compatible") {
            let source = try packageSource()
            t.equal(source.unknownKeys, ["futureSource": .object(["keep": .number(7)])],
                    "packageID is a known identity field, not an uninterpreted future extension")
            let decoded = try JSONDecoder().decode(DeskWidgetSourceState.self, from: JSONEncoder().encode(source))
            t.equal(decoded, source)
            t.equal(try encoded(decoded)["packageID"], .string(packageID.uuidString))

            // The legacy state API accepts these names even though the installation admission rejects the latter
            // two. Adding package identity must not tighten this older, independent low-level contract.
            for name in ["Widget.desk", "package.desk", ".Hidden.desk"] {
                let url = t.temporaryDirectory("desk-package-legacy").appendingPathComponent("state.json")
                let state = AppState(fileURL: url), id = UUID()
                var standalone = DeskWidgetSourceState(id: id, entry: id.uuidString.lowercased() + "/" + name)
                standalone.unknownKeys = ["futureSource": .array([.bool(true), .number(3)])]
                let instance = DeskWidgetInstanceState(id: id, sourceID: id)
                try state.registerDeskInstallation(source: standalone, instance: instance)
                let reloaded = AppState(fileURL: url)
                t.equal(reloaded.deskSource(id), standalone, name)
                t.equal(reloaded.deskInstance(id), instance, name)
                t.equal(try encoded(standalone)["packageID"], nil, "old sources do not gain a package identity")
                t.equal(standalone.packageID, nil)
                t.equal(standalone.directoryID, id)
                t.check(reloaded.activeDeskWidgets.isEmpty, name)
            }
        }

        batchTests(t)
        invalidMemberTests(t)
        collisionTests(t)
        persistenceTests(t)
        optionalFieldTests(t)
    }

    private static func batchTests(_ t: AppTestRunner) {
        t.suite("App: Desk package identity: one batch persists all members and independent inactive instances") {
            let url = t.temporaryDirectory("desk-package-batch").appendingPathComponent("state.json")
            let legacy = #"{"skins":{"Legacy\\Clock":{"file":"Clock.ini","active":true,"x":13,"futureSkin":[1,"keep"]}},"futureRoot":{"keep":true},"deskWidgets":{"futureNamespace":7}}"#
            try Data(legacy.utf8).write(to: url)
            let state = AppState(fileURL: url), before = try encoded(state.data)
            var small = member("Small.desk"), medium = member("Medium.desk")
            small.unknownKeys = ["futureSource": .string("small")]
            medium.unknownKeys = ["futureSource": .string("medium")]
            let sources = [small, medium]
            var smallInstance = DeskWidgetInstanceState(id: small.id, sourceID: small.id, x: -18, y: 29)
            smallInstance.unknownKeys = ["futureInstance": .bool(true)]
            smallInstance.optionValues = ["futureOption": .string("preserve")]
            let otherSmallInstance = DeskWidgetInstanceState(id: UUID(), sourceID: small.id, x: 70, y: 80)
            let mediumInstance = DeskWidgetInstanceState(id: UUID(), sourceID: medium.id)
            let instances = [smallInstance, otherSmallInstance, mediumInstance]
            try state.registerDeskInstallation(sources: sources, instances: instances)

            let reloaded = AppState(fileURL: url)
            t.equal(state.data.deskWidgets.sources.count, 2)
            t.equal(state.data.deskWidgets.instances.count, 3)
            t.equal(reloaded.data.deskWidgets, state.data.deskWidgets)
            for source in sources {
                t.equal(reloaded.deskSource(source.id), source)
                t.equal(source.directoryID, packageID)
                t.equal(source.packageID, packageID)
            }
            for instance in instances { t.equal(reloaded.deskInstance(instance.id), instance) }
            t.check(reloaded.activeDeskWidgets.isEmpty)
            t.equal(reloaded.data.deskWidgets.unknownKeys, ["futureNamespace": .number(7)])
            var after = try encoded(reloaded.data), original = before
            after.removeValue(forKey: "deskWidgets"); original.removeValue(forKey: "deskWidgets")
            t.equal(after, original, "registering the package preserves unrelated legacy and future state")
        }
    }

    private static func invalidMemberTests(_ t: AppTestRunner) {
        t.suite("App: Desk package identity: invalid members and incomplete instance relations reject the whole batch") {
            let state = AppState(fileURL: t.temporaryDirectory("desk-package-invalid").appendingPathComponent("state.json"))
            let sources = [member("Small.desk"), member("Medium.desk")], validInstances = instances(for: sources)
            try rejectsUnchanged(t, state, sources: [], instances: validInstances, "no sources")
            try rejectsUnchanged(t, state, sources: sources, instances: [], "no instances")
            try rejectsUnchanged(t, state, sources: sources, instances: [validInstances[0]], "a member without an instance")
            try rejectsUnchanged(t, state, sources: sources,
                                 instances: validInstances + [DeskWidgetInstanceState(id: UUID(), sourceID: UUID())],
                                 "an instance outside the submitted sources")
            var active = validInstances; active[1].active = true
            try rejectsUnchanged(t, state, sources: sources, instances: active, "an active instance")
            let crossDirectory = [sources[0], member("Other.desk", package: UUID())]
            try rejectsUnchanged(t, state, sources: crossDirectory, instances: instances(for: crossDirectory), "two package directories")
            let independentID = UUID()
            let independent = DeskWidgetSourceState(id: independentID, entry: independentID.uuidString.lowercased() + "/Widget.desk")
            let mixed = [sources[0], independent]
            try rejectsUnchanged(t, state, sources: mixed, instances: instances(for: mixed), "package and standalone sources")
            let anotherID = UUID()
            let independentPair = [independent, DeskWidgetSourceState(id: anotherID, entry: anotherID.uuidString.lowercased() + "/Other.desk")]
            try rejectsUnchanged(t, state, sources: independentPair, instances: instances(for: independentPair), "two standalone directories")

            let directory = packageID.uuidString.lowercased()
            let invalidEntries = [directory + "/package.desk", directory + "/Package.DESK", directory + "/.Hidden.desk",
                                  directory + "/Sub/Widget.desk", directory + "/../Widget.desk", directory + "//Widget.desk",
                                  "/" + directory + "/Widget.desk", directory + "/Widget\\Other.desk", directory + "/Bad\0.desk",
                                  directory + "/Widget.ini", directory + "/", UUID().uuidString.lowercased() + "/Widget.desk"]
            for entry in invalidEntries {
                let bad = DeskWidgetSourceState(id: UUID(), entry: entry, packageID: packageID)
                let batch = [sources[0], bad]
                try rejectsUnchanged(t, state, sources: batch, instances: instances(for: batch), entry)
            }
        }
    }

    private static func collisionTests(_ t: AppTestRunner) {
        t.suite("App: Desk package identity: repeated identities member names and existing directories never alias") {
            let state = AppState(fileURL: t.temporaryDirectory("desk-package-collisions").appendingPathComponent("state.json"))
            let small = member("Small.desk"), medium = member("Medium.desk")
            let duplicateSource = member("Other.desk", id: small.id)
            try rejectsUnchanged(t, state, sources: [small, duplicateSource], instances: instances(for: [small]), "a repeated source id")
            let repeatedInstanceID = UUID()
            try rejectsUnchanged(t, state, sources: [small, medium],
                                 instances: [DeskWidgetInstanceState(id: repeatedInstanceID, sourceID: small.id),
                                             DeskWidgetInstanceState(id: repeatedInstanceID, sourceID: medium.id)], "a repeated instance id")
            for names in [["Small.desk", "Small.desk"], ["Small.desk", "small.DESK"], ["Caf\u{00E9}.desk", "Cafe\u{0301}.desk"]] {
                let pair = names.map { member($0) }
                try rejectsUnchanged(t, state, sources: pair, instances: instances(for: pair), "colliding member paths")
            }

            let initial = instances(for: [small, medium])
            try state.registerDeskInstallation(sources: [small, medium], instances: initial)
            let append = member("Third.desk")
            try rejectsUnchanged(t, state, sources: [append], instances: instances(for: [append]), "an append to an existing package")
            let standaloneAlias = DeskWidgetSourceState(id: packageID, entry: packageID.uuidString.lowercased() + "/Standalone.desk")
            try rejectsUnchanged(t, state, sources: [standaloneAlias], instances: instances(for: [standaloneAlias]), "standalone identity aliasing a package directory")
            let newPackage = UUID(), reusedSource = member("New.desk", package: newPackage, id: small.id)
            try rejectsUnchanged(t, state, sources: [reusedSource], instances: instances(for: [reusedSource]), "an existing source id in a different package")
            let newSource = member("New.desk", package: newPackage)
            try rejectsUnchanged(t, state, sources: [newSource],
                                 instances: [DeskWidgetInstanceState(id: initial[0].id, sourceID: newSource.id)], "an existing instance id")

            let standaloneID = UUID(), standalone = DeskWidgetSourceState(id: standaloneID, entry: standaloneID.uuidString.lowercased() + "/Old.desk")
            try state.registerDeskInstallation(source: standalone, instance: DeskWidgetInstanceState(id: UUID(), sourceID: standaloneID))
            let packageAlias = member("New.desk", package: standaloneID)
            try rejectsUnchanged(t, state, sources: [packageAlias], instances: instances(for: [packageAlias]), "package identity aliasing a standalone directory")
        }
    }

    private static func persistenceTests(_ t: AppTestRunner) {
        t.suite("App: Desk package identity: failed persistence keeps accepted memory and permits an intact retry") {
            let root = t.temporaryDirectory("desk-package-persistence"), folder = root.appendingPathComponent("State")
            let url = folder.appendingPathComponent("state.json"), state = AppState(fileURL: url)
            let oldID = UUID(), old = DeskWidgetSourceState(id: oldID, entry: oldID.uuidString.lowercased() + "/Old.desk")
            try state.registerDeskInstallation(source: old, instance: DeskWidgetInstanceState(id: UUID(), sourceID: oldID))
            let before = try encoded(state.data), raw = try Data(contentsOf: url)
            let preserved = root.appendingPathComponent("Preserved")
            try FileManager.default.moveItem(at: folder, to: preserved)
            let blocker = Data("not a directory".utf8)
            try blocker.write(to: folder)
            let sources = [member("Small.desk"), member("Medium.desk")], values = instances(for: sources)
            try rejectsUnchanged(t, state, sources: sources, instances: values, "a failed state write")
            t.equal(try encoded(state.data), before)
            t.equal(try Data(contentsOf: preserved.appendingPathComponent("state.json")), raw)
            t.equal(try Data(contentsOf: folder), blocker)

            try FileManager.default.removeItem(at: folder)
            try FileManager.default.moveItem(at: preserved, to: folder)
            try state.registerDeskInstallation(sources: sources, instances: values)
            let reloaded = AppState(fileURL: url)
            t.equal(reloaded.data.deskWidgets, state.data.deskWidgets)
            t.equal(reloaded.data.deskWidgets.sources.count, 3)
            t.equal(reloaded.data.deskWidgets.instances.count, 3)
            t.check(reloaded.activeDeskWidgets.isEmpty)
        }
    }

    private static func optionalFieldTests(_ t: AppTestRunner) {
        t.suite("App: Desk package identity: damaged optional package metadata cannot discard other saved sources") {
            let otherSourceID = UUID(), otherInstanceID = UUID(), otherPackageID = UUID()
            let sourceKey = sourceID.uuidString.lowercased(), otherKey = otherSourceID.uuidString.lowercased()
            let variants = ["", ",\"packageID\":null", ",\"packageID\":true", ",\"packageID\":4",
                            ",\"packageID\":\"not-a-uuid\"", ",\"packageID\":[]", ",\"packageID\":{}"]
            for field in variants {
                let url = t.temporaryDirectory("desk-package-optional").appendingPathComponent("state.json")
                let json = """
                {"skins":{},"futureRoot":"keep","deskWidgets":{"futureNamespace":9,"sources":{
                "\(sourceKey)":{"id":"\(sourceID)","entry":"\(packageID.uuidString.lowercased())/Small.desk"\(field),"futureSource":"damaged"},
                "\(otherKey)":{"id":"\(otherSourceID)","entry":"\(otherPackageID.uuidString.lowercased())/Good.desk","packageID":"\(otherPackageID)","futureSource":"intact"}},
                "instances":{
                "\(instanceID.uuidString.lowercased())":{"id":"\(instanceID)","sourceID":"\(sourceID)","futureInstance":true},
                "\(otherInstanceID.uuidString.lowercased())":{"id":"\(otherInstanceID)","sourceID":"\(otherSourceID)","x":42}}}}
                """
                try Data(json.utf8).write(to: url)
                let state = AppState(fileURL: url)
                t.equal(state.data.deskWidgets.sources.count, 2, field)
                t.equal(state.data.deskWidgets.instances.count, 2, field)
                guard let damaged = state.deskSource(sourceID), let intact = state.deskSource(otherSourceID),
                      let instance = state.deskInstance(instanceID) else {
                    t.check(false, "optional package metadata discarded a saved source or instance: \(field)")
                    continue
                }
                t.equal(damaged.packageID, nil, field)
                t.equal(damaged.directoryID, sourceID)
                t.equal(damaged.unknownKeys, ["futureSource": .string("damaged")])
                t.equal(intact.packageID, otherPackageID)
                t.equal(intact.directoryID, otherPackageID)
                t.equal(intact.unknownKeys, ["futureSource": .string("intact")])
                t.equal(instance.unknownKeys, ["futureInstance": .bool(true)])
                t.equal(state.deskInstance(otherInstanceID)?.x, 42)
                t.equal(state.data.deskWidgets.unknownKeys, ["futureNamespace": .number(9)])
                t.equal(try encoded(state.data)["futureRoot"], .string("keep"))
                t.equal(try encoded(damaged)["packageID"], nil)
                state.saveNow()
                let reloaded = AppState(fileURL: url)
                t.equal(reloaded.data.deskWidgets, state.data.deskWidgets)
                t.equal(try encoded(reloaded.data)["futureRoot"], .string("keep"))
                t.check(reloaded.activeDeskWidgets.isEmpty)
                let empty = AppState(fileURL: t.temporaryDirectory("desk-package-fallback-entry").appendingPathComponent("state.json"))
                try rejectsUnchanged(t, empty, sources: [damaged], instances: [instance], "a package directory after identity fallback")
            }
        }
    }
}
