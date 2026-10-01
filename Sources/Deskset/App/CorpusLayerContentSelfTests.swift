#if DEBUG
import AppKit
import CryptoKit
import DesksetCore
import DesksetDraw
import DesksetRuntime
import Metal

/// Opt-in third-party qualification. The manifest and all corpus files/reports stay outside the repository.
/// This observes C bitmap content; it does not enable component clipping in a user's window or certify E content.
enum CorpusLayerContentSelfTests {
    private typealias Rect = InkBounds.DeviceRect
    private static let budget = 256 * 1024 * 1024 // Explicit test allocation bound, not the pending 4x policy.
    private static let ring = 8 // A finite observation canvas, not a guarantee about unobserved distant ink.

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let corpusRoot: String
        let data: String
        let webFixtures: String?
        let reportDirectory: String
        let skins: [String]
        let expectedSkinsRoots: [String: String]?
        let configuration: ConfigurationInputs?
    }
    /// Explicit offline scenarios, never an implicit repair of the original corpus.
    private struct ConfigurationInputs: Decodable {
        let dataSHA256: String
        let webManifestSHA256: String
        let webPayloadSHA256: [String: String]
        let skins: [String: Configuration]
    }
    private struct Configuration: Decodable {
        let originalIndex: Int
        let source: String
        let sourceSHA256: String
        let variables: [String: String]
        let galleryFiles: [String: String]?
        let optionOverrides: [OptionOverride]?
        let sourceAssetsSHA256: [String: String]?
    }
    private struct OptionOverride: Codable {
        let section: String
        let key: String
        let expectedValue: String
        let value: String
    }
    private struct Provenance: Encodable {
        let manifestSHA256: String
        let originalIndex: Int
        let source: String
        let originalSourceSHA256: String
        let preparedSourceSHA256: String
        let variables: [String: String]
        let galleryFiles: [String: String]?
        let optionOverrides: [OptionOverride]?
        let sourceAssetsSHA256: [String: String]?
    }
    private struct Difference: Encodable {
        let pixels: Int
        let changed: Int
        let maximum: Int
        let first: [Int]?
        let exact: Bool
        let withinComponentTolerance: Bool
        init(_ value: PixelComparison.Difference) {
            pixels = value.totalPixels
            changed = value.changedPixels
            maximum = value.maxChannelDifference
            first = value.firstDifference.map { [$0.x, $0.y, $0.channel, Int($0.expected), Int($0.actual)] }
            exact = value.isExact
            withinComponentTolerance = value.meetsComponentTolerance
        }
    }
    private struct Layer: Encodable {
        let role: String
        let rectangle: [Int]
        let members: [String]
    }
    private struct LayerDifference: Encodable {
        let role: String
        let rectangle: [Int]
        let members: [String]
        // First-difference coordinates are local to this rectangle, whose origin is in window pixels.
        // Numeric tolerance is reported only; it does not replace either strict whole-window gate.
        let singleVsCandidate: Difference
        let freshVsIncremental: Difference
    }
    private struct Ink: Encodable {
        let members: [String]
        let rectangle: [Int]
        let canvas: [Int]
        let alphaPixels: Int
        let escapedPixels: Int
        let edgePixels: Int
        let firstEscape: [Int]?
    }
    private struct Areas: Encodable {
        let windowPixels: Int
        let groupPixels: Int
        let baseBitmapPixels: Int
        let baseSlicePixels: Int
        // Sum of the known, unclipped top-level run rectangles, not a union or a 4x decision.
        let knownRunRectanglePixels: Int?
        let unknownRuns: Int
    }
    private struct Frame: Encodable {
        let update: Int
        let virtualSeconds: Double
        let replay: Bool
        let generation: UInt64
        let sequence: UInt64
        let change: String
        let fallback: String?
        let unknown: [String]
        let baseMembers: [String]
        let skipped: [String]
        let layers: [Layer]
        let layerDifferences: [LayerDifference]
        let areas: Areas
        let ink: [Ink]
        let singleVsCandidate: Difference
        let freshVsIncremental: Difference
        let hasPixels: Bool
        let rgbaSHA256: String
        let validationFailures: [String]
    }
    private struct Report: Encodable {
        let schemaVersion = 1
        let skin: String
        var inputMode = "original"
        var configuration: Provenance?
        let scale: Int
        let appearance: String
        var status = "notRun"
        var missing: [String] = []
        var issues: [String] = []
        var coverageMissing: [String] = []
        var resolvedSkinsRoot: String?
        var errors: [String] = []
        var frames: [Frame] = []
        var nativeCanary = false
        // withInputs' first two updates precede its callback. Do not mislabel update 2 as first-frame coverage.
        let capturesFirstUpdate = false
        let schedule = "updates 2,3,4,5; advance virtual time to 60s and update; replay captured A/B/A"
    }
    private struct Sample {
        let scene: WidgetScene
        let cycle: Int
        let seconds: Double
    }
    private enum Failure: Error {
        case invalidManifest(String)
        case unavailable(String)
        case invalidResult(String)
    }

    static func run(_ t: AppTestRunner) {
        layerComparisonTests(t)
        configurationTests(t)
        optionOverrideTests(t)
        t.suite("Runtime: corpus layer content: geometry area reporting matches bitmap modes") {
            guard let empty = Rect(minX: 0, minY: 0, maxX: 0, maxY: 9),
                  let window = Rect(minX: 0, minY: 0, maxX: 7, maxY: 9) else {
                throw Failure.invalidResult("Representable area control rectangles")
            }
            t.equal(try areas(SinglePartition.plan(in: empty), []).baseBitmapPixels, 0,
                    "the actual empty mode owns no base bitmap")
            let component = PartitionPlan(window: window, baseMembers: [], layers: [
                LayerPlan(id: .baseSlice(index: 0), rect: window, content: .baseSlice(source: window))
            ], skipped: [])
            t.equal(try areas(component, []).baseBitmapPixels, 63,
                    "components still allocate the full base when there are no base members")
            do {
                _ = try areas(PartitionPlan(window: window, baseMembers: [], layers: [], skipped: []), [])
                t.check(false, "a positive window with no layer tiling cannot be reported as an empty mode")
            } catch Rasterizer.Failure.invalidPlan { t.check(true) }
        }
        // No manifest means no corpus test was requested, not a skipped or passing corpus qualification.
        guard let path = ProcessInfo.processInfo.environment["DESKSET_LAYER_CORPUS_MANIFEST"] else { return }
        t.suite("Runtime: corpus layer content: explicit manifest qualification") {
            let manifestBytes = try Data(contentsOf: URL(fileURLWithPath: path))
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestBytes)
            let root = canonical(manifest.corpusRoot), output = canonical(manifest.reportDirectory)
            guard manifest.schemaVersion == 1, !manifest.skins.isEmpty,
                  Set(manifest.skins).count == manifest.skins.count,
                  !isInside(output, root), !isInside(root, output) else {
                throw Failure.invalidManifest("Use unique relative skins and a separate report directory")
            }
            let files = try manifest.skins.map { relative -> URL in
                let file = canonical(root.appendingPathComponent(relative).path)
                guard !relative.hasPrefix("/"), file.pathExtension.lowercased() == "ini", isInside(file, root),
                      FileManager.default.fileExists(atPath: file.path) else {
                    throw Failure.invalidManifest("Missing or escaping corpus path: \(relative)")
                }
                return file
            }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let data = canonical(manifest.data)
            let input = try SkinInputData.load(data.path, directory: data.deletingLastPathComponent())
            guard input.system?.isEmpty == false, input.battery != nil, input.sensors != nil,
                  input.nowPlaying != nil, input.audio != nil, input.weather != nil, input.wifi != nil,
                  input.desktopImage != nil, input.programs != nil, input.trash != nil else {
                throw Failure.invalidManifest("Use the complete isolated input fixture; missing services must not read the host")
            }
            let web = try manifest.webFixtures.map { try LegacyRenderWebFixtures(manifest: canonical($0)) }
            try validateConfigurationInputs(manifest, data: data)
            let device = MTLCreateSystemDefaultDevice()
            let saved = NSApp.appearance
            defer { NSApp.appearance = saved; MacAppearance.current.refresh(); DesktopInputs.appearance.refresh() }
            var reports: [Report] = []
            for (index, file) in files.enumerated() {
                for dark in [false, true] {
                    let appearance = dark ? "dark" : "light"
                    RenderCommand.applyAppearance(dark ? .dark : .light)
                    var pair = [1, 2].map { Report(skin: manifest.skins[index], scale: $0, appearance: appearance) }
                    let configuration = manifest.configuration?.skins[manifest.skins[index]]
                    for i in pair.indices { pair[i].inputMode = configuration == nil ? "original" : "configured" }
                    do {
                        guard let device else { throw Failure.unavailable("Metal unavailable; native qualification did not run") }
                        Images.purge()
                        LegacyImages.purge()
                        // Some distributions embed their own Skins folder. Use the render command's actual
                        // nearest-root rule, bounded by the explicit corpus root; keep the original report identity.
                        let located = RenderCommand.locate(file, skinsDir: nil).0
                        let skinsRoot = isInside(located, root) ? located : root
                        for i in pair.indices { pair[i].resolvedSkinsRoot = skinsRoot.path }
                        if let expected = manifest.expectedSkinsRoots?[manifest.skins[index]] {
                            guard skinsRoot == canonical(root.appendingPathComponent(expected).path) else {
                                throw Failure.invalidResult("The actual nearest Skins root differs from the explicit input control")
                            }
                            t.check(true, "the explicit nested-root positive control uses its original include root")
                        }
                        var prepare: ((Skin, RecordingSideEffects, VirtualTimeExecutor) throws -> Void)?
                        if let configuration {
                            prepare = { skin, recording, virtual in
                                let provenance = try prepareConfiguration(configuration, root: root,
                                    fixtureRoot: data.deletingLastPathComponent(), manifestSHA256: hash(manifestBytes),
                                    skin: skin, recording: recording, virtual: virtual)
                                for i in pair.indices { pair[i].configuration = provenance }
                            }
                        }
                        let checked = try LegacyRenderSelfTests.withInputs(file, skinsDir: skinsRoot.path, data: data,
                            webFixtures: web, prepare: prepare) { skin, recording, virtual in
                            guard skin.executor === virtual, virtual.isCurrent, !skin.skinClock.isLive,
                                  !skin.sideEffects.isLive, skin.sideEffects === recording,
                                  !virtual.background.allowsUnfakedWork,
                                  let system = skin.system as? ScriptedSystemData,
                                  system.gives(.system), system.gives(.battery), system.gives(.sensors) else {
                                throw Failure.invalidResult("The existing isolated input contract is not active")
                            }
                            let sessions = try [1, 2].map {
                                try Session(scale: $0, dark: dark, executor: virtual, device: device)
                            }
                            defer { for session in sessions { session.close(t) } }
                            let projector = SceneProjector()
                            var savedSamples: [[Sample]] = [[], []]
                            var missing = Set<String>()
                            for step in 0..<5 {
                                if step > 0 {
                                    system.advance()
                                    let next = step == 4 ? max(60, virtual.now) : virtual.now + 1
                                    RenderCommand.step(virtual, until: next, deadline: Date().addingTimeInterval(5))
                                    skin.update()
                                    RenderCommand.step(virtual, until: virtual.now, deadline: Date().addingTimeInterval(5))
                                }
                                for i in sessions.indices {
                                    let session = sessions[i]
                                    let environment = AppSceneEnvironment(scale: Double(session.scale),
                                        appearance: dark ? .dark : .light,
                                        appearanceName: NSApp.effectiveAppearance.name.rawValue)
                                    let scene = projector.project(skin, environment: environment, glassSource: .current)
                                    let sample = Sample(scene: scene, cycle: skin.updateCount, seconds: virtual.now)
                                    savedSamples[i].append(sample)
                                    let frame = try session.compare(sample, replay: false, t: t,
                                        failurePrefix: output.appendingPathComponent("\(index)-\(session.scale)x-\(appearance)-\(step)"))
                                    pair[i].frames.append(frame)
                                    pair[i].nativeCanary = session.verifiedCanary
                                    // Nil stamps include symbols, so only a failed actual decode is a missing image.
                                    for dependency in scene.backgroundImageDependencies + scene.elements.flatMap(\.imageDependencies) {
                                        if Images.size(atPath: dependency.path) == nil {
                                            missing.insert("Image: unavailable \(dependency.path)")
                                        }
                                    }
                                    try write(pair[i], to: reportURL(output, index, pair[i]))
                                }
                            }
                            t.check(skin.updateCount >= 6, "the original recipe received five sampled updates after initial setup")
                            // Replay is meaningful only while every path still denotes the captured resource version.
                            // The normal history above always compares each scene immediately, before its next update.
                            for i in sessions.indices {
                                let samples = savedSamples[i]
                                guard let a = samples.first, let b = samples.last else {
                                    throw Failure.invalidResult("No real history was captured")
                                }
                                let stamps = a.scene.backgroundImageDependencies + a.scene.elements.flatMap(\.imageDependencies)
                                let now = AppSceneEnvironment(scale: Double(sessions[i].scale),
                                    appearance: dark ? .dark : .light, appearanceName: NSApp.effectiveAppearance.name.rawValue)
                                if stamps.allSatisfy({ $0.stamp == now.imageStamp($0.path) }) {
                                    var replay: [Frame] = []
                                    for sample in [a, b, a] {
                                        replay.append(try sessions[i].compare(sample, replay: true, t: t,
                                            failurePrefix: output.appendingPathComponent("\(index)-\(sessions[i].scale)x-\(appearance)-replay-\(replay.count)")))
                                    }
                                    let returned = replay.first?.rgbaSHA256 == replay.last?.rgbaSHA256
                                    t.check(returned, "captured A returns after B in the same candidate owner")
                                    if !returned { pair[i].errors.append("Captured A changed after B in the same candidate owner") }
                                    pair[i].frames += replay
                                } else {
                                    pair[i].coverageMissing.append("Replay not qualified: a captured image resource changed during history")
                                }
                            }
                            t.equal(virtual.background.outstanding, 0, "input completions settled before qualification")
                            t.equal(virtual.background.unverifiable.count, 0, "unfaked work never qualifies")
                            for i in pair.indices { pair[i].issues += skin.issues }
                            return Array(missing).sorted()
                        }
                        if let configuration {
                            _ = try verifiedFile(configuration.source, under: root, sha256: configuration.sourceSHA256)
                            try verifySourceAssets(configuration, root: root)
                        }
                        for i in pair.indices {
                            pair[i].missing = Array(Set(checked.missing + checked.value)).sorted()
                            let exact = pair[i].errors.isEmpty && !pair[i].frames.isEmpty && pair[i].frames.allSatisfy {
                                $0.singleVsCandidate.exact && $0.freshVsIncremental.exact && $0.hasPixels && $0.validationFailures.isEmpty &&
                                    $0.ink.allSatisfy { $0.escapedPixels == 0 }
                            }
                            pair[i].status = !pair[i].missing.isEmpty ? "inputMissing" : !pair[i].coverageMissing.isEmpty ? "notQualified" : !exact ? "diverged" :
                                pair[i].frames.contains { $0.fallback != nil } ? "verifiedSingleFallback" : "verifiedComponents"
                            t.check(pair[i].missing.isEmpty, "\(pair[i].skin): observed inputs complete: \(pair[i].missing)")
                            t.check(pair[i].coverageMissing.isEmpty, "required sampled history completed: \(pair[i].coverageMissing)")
                            t.check(exact && pair[i].nativeCanary, "\(pair[i].skin) \(pair[i].scale)x \(appearance): actual native qualification")
                        }
                    } catch {
                        for i in pair.indices {
                            pair[i].status = "error"
                            pair[i].errors.append(String(describing: error))
                        }
                        t.check(false, "\(manifest.skins[index]) \(appearance): \(error)")
                    }
                    for report in pair { try write(report, to: reportURL(output, index, report)) }
                    reports += pair
                    try write(reports, to: output.appendingPathComponent("summary.json"))
                    print("    CORPUS \(manifest.skins[index]) \(appearance): \(pair.map { "\($0.scale)x \($0.status)" }.joined(separator: ", "))")
                }
            }
            try validateConfigurationInputs(manifest, data: data)
            t.equal(reports.count, manifest.skins.count * 4, "every requested scale and appearance has an explicit report")
        }
    }

    private static func validateConfigurationInputs(_ manifest: Manifest, data: URL) throws {
        guard let configuration = manifest.configuration else { return }
        guard !configuration.skins.isEmpty, Set(configuration.skins.keys).isSubset(of: Set(manifest.skins)),
              Set(configuration.skins.values.map(\.originalIndex)).count == configuration.skins.count,
              let webPath = manifest.webFixtures else {
            throw Failure.invalidManifest("Configured inputs require unique original indices, selected skins, and explicit web fixtures")
        }
        let root = data.deletingLastPathComponent(), web = canonical(webPath)
        _ = try verifiedFile(data.lastPathComponent, under: root, sha256: configuration.dataSHA256)
        guard isInside(web, root) else { throw Failure.invalidManifest("Configured web fixtures leave the data fixture root") }
        let (_, bytes) = try verifiedFile(web.lastPathComponent, under: web.deletingLastPathComponent(),
                                          sha256: configuration.webManifestSHA256)
        let responses = try JSONDecoder().decode([String: [String: String]].self, from: bytes)
        guard Set(responses.values.flatMap { $0.values }) == Set(configuration.webPayloadSHA256.keys) else {
            throw Failure.invalidManifest("Every mapped response needs exactly one explicit payload hash")
        }
        for (path, expected) in configuration.webPayloadSHA256 {
            _ = try verifiedFile(path, under: web.deletingLastPathComponent(), sha256: expected)
        }
    }

    private static func verifiedFile(_ relative: String, under root: URL, sha256: String) throws -> (URL, Data) {
        let file = canonical(root.appendingPathComponent(relative).path)
        guard !relative.isEmpty, !(relative as NSString).isAbsolutePath, !relative.hasPrefix("~"),
              !relative.split(separator: "/").contains(".."), file != root, isInside(file, root),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            throw Failure.invalidManifest("Missing, nonregular, or escaping configured input: \(relative)")
        }
        let bytes = try Data(contentsOf: file)
        guard !bytes.isEmpty, hash(bytes) == sha256 else {
            throw Failure.invalidManifest("Configured input hash mismatch: \(relative)")
        }
        return (file, bytes)
    }

    private static func prepareConfiguration(_ configuration: Configuration, root: URL, fixtureRoot: URL,
                                             manifestSHA256: String, skin: Skin, recording: RecordingSideEffects,
                                             virtual: VirtualTimeExecutor) throws -> Provenance {
        guard configuration.originalIndex >= 0, skin.measures.isEmpty, skin.executor === virtual, virtual.isCurrent,
              skin.sourceProvider === recording, skin.sideEffects === recording,
              !virtual.background.allowsUnfakedWork, !skin.skinClock.isLive,
              !configuration.variables.isEmpty || configuration.galleryFiles?.isEmpty == false ||
                configuration.optionOverrides?.isEmpty == false,
              configuration.variables.keys.allSatisfy({ !$0.isEmpty && !$0.contains("\n") && !$0.contains("\r") }),
              configuration.variables.values.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") }) else {
            throw Failure.invalidManifest("Configuration requires explicit values at the isolated pre-load seam")
        }
        let (source, original) = try verifiedFile(configuration.source, under: root, sha256: configuration.sourceSHA256)
        try verifySourceAssets(configuration, root: root)
        let overrides = configuration.optionOverrides ?? []
        if !overrides.isEmpty {
            let document = IniDocument.parse(TextDecoding.decode(original))
            var targets = ["variables": Set(configuration.variables.keys.map { $0.lowercased() })]
            if configuration.galleryFiles != nil { targets["variables", default: []].insert("gallerypath") }
            for change in overrides {
                guard !change.section.isEmpty, !change.key.isEmpty,
                      [change.section, change.key, change.expectedValue, change.value].allSatisfy({ !$0.contains("\r") && !$0.contains("\n") }),
                      targets[change.section.lowercased(), default: []].insert(change.key.lowercased()).inserted,
                      let old = document.section(named: change.section)?.value(forKey: change.key),
                      old.utf8.elementsEqual(change.expectedValue.utf8) else {
                    throw Failure.invalidManifest("Missing, duplicate, or mismatched option override: [\(change.section)] \(change.key)")
                }
            }
        }
        var variables = configuration.variables
        if let files = configuration.galleryFiles {
            guard !files.isEmpty, variables.keys.allSatisfy({ $0.lowercased() != "gallerypath" }),
                  Set(files.keys.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }).count == files.count else {
                throw Failure.invalidManifest("Gallery needs unique fixture names and owns the GalleryPath value")
            }
            let inputs = try files.keys.sorted().map { path -> (URL, Data) in
                guard let expected = files[path] else { throw Failure.invalidManifest("Missing Gallery hash") }
                return try verifiedFile(path, under: fixtureRoot, sha256: expected)
            }
            let directory = canonical(EnvironmentStore.shared.settingsPath).appendingPathComponent("CorpusInputs/Gallery")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (file, bytes) in inputs {
                try bytes.write(to: directory.appendingPathComponent(file.lastPathComponent), options: .atomic)
            }
            virtual.background.allowFixtureReads(under: directory)
            variables["GalleryPath"] = directory.path
        }
        let copy = canonical(recording.files.path(for: source.path, access: .update))
        guard recording.files.contains(copy.path), copy != source, try Data(contentsOf: copy) == original else {
            throw Failure.invalidResult("Configuration did not start from an independent recorded source copy")
        }
        for key in variables.keys.sorted() {
            guard let value = variables[key] else { throw Failure.invalidManifest("Missing configured value") }
            try IniWriter.writeValue(value, key: key, section: "Variables", fileURL: copy)
        }
        for change in overrides {
            try IniWriter.writeValue(change.value, key: change.key, section: change.section, fileURL: copy)
        }
        _ = try verifiedFile(configuration.source, under: root, sha256: configuration.sourceSHA256)
        try verifySourceAssets(configuration, root: root)
        return Provenance(manifestSHA256: manifestSHA256, originalIndex: configuration.originalIndex,
            source: configuration.source, originalSourceSHA256: hash(original),
            preparedSourceSHA256: hash(try Data(contentsOf: copy)), variables: variables,
            galleryFiles: configuration.galleryFiles, optionOverrides: configuration.optionOverrides,
            sourceAssetsSHA256: configuration.sourceAssetsSHA256)
    }

    /// Source assets remain at their original paths. An absent or altered file is never substituted.
    private static func verifySourceAssets(_ configuration: Configuration, root: URL) throws {
        guard let assets = configuration.sourceAssetsSHA256 else { return }
        guard !assets.isEmpty else { throw Failure.invalidManifest("Explicit source asset bindings cannot be empty") }
        for path in assets.keys.sorted() {
            guard let expected = assets[path] else { throw Failure.invalidManifest("Missing source asset hash") }
            _ = try verifiedFile(path, under: root, sha256: expected)
        }
    }

    private static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func configurationTests(_ t: AppTestRunner) {
        t.suite("Runtime: corpus layer content: configured copies precede load and retain input provenance") {
            guard let testSkins = Paths.repositoryFolder("TestSkins") else {
                throw Failure.invalidResult("The existing isolated input fixture is required")
            }
            let root = canonical(t.temporaryDirectory("corpus-configuration").path)
            let fixtureRoot = root.appendingPathComponent("inputs")
            try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("options.inc"), file = root.appendingPathComponent("Test.ini")
            let original = Data("[Variables]\nLabel=original\nUnrelated=preserved\nGalleryPath=\n".utf8)
            try original.write(to: source)
            try """
            [Rainmeter]
            OnRefreshAction=[!SetVariable SeenAtRefresh "#Label#"]
            [Variables]
            @Include=#CURRENTPATH#options.inc
            [Photo]
            Measure=Plugin
            Plugin=QuotePlugin
            PathName=#GalleryPath#
            FileFilter=*.txt
            UpdateDivider=-1
            [Text]
            Meter=String
            Text=#Label#
            """.write(to: file, atomically: true, encoding: .utf8)
            let photo = Data("owned fixture".utf8), ignored = Data("ignored by the original filter".utf8)
            try photo.write(to: fixtureRoot.appendingPathComponent("photo.txt"))
            try ignored.write(to: fixtureRoot.appendingPathComponent("ignored.bin"))
            let configuration = Configuration(originalIndex: 11, source: "options.inc", sourceSHA256: hash(original),
                variables: ["Label": "configured"], galleryFiles: ["photo.txt": hash(photo), "ignored.bin": hash(ignored)],
                optionOverrides: nil, sourceAssetsSHA256: nil)
            let data = testSkins.appendingPathComponent("Runtime/Data/mac.json")
            let unprepared = try LegacyRenderSelfTests.withInputs(file, skinsDir: root.path, data: data) { skin, _, _ in
                t.equal(skin.variable("SeenAtRefresh"), "original", "no preparation keeps the original refresh input")
                t.equal((skin.measure(named: "Photo") as? QuoteMeasure)?.itemCount, 0)
            }
            t.equal(unprepared.missing, [])
            var provenance: Provenance?
            let prepared = try LegacyRenderSelfTests.withInputs(file, skinsDir: root.path, data: data,
                prepare: { skin, recording, virtual in
                    provenance = try prepareConfiguration(configuration, root: root, fixtureRoot: fixtureRoot,
                        manifestSHA256: hash(Data("private control manifest".utf8)),
                        skin: skin, recording: recording, virtual: virtual)
                }) { skin, _, virtual in
                    t.equal(skin.variable("SeenAtRefresh"), "configured", "the first refresh already reads the recorded include")
                    t.equal(skin.variable("Unrelated"), "preserved")
                    t.equal((skin.meter(named: "Text") as? StringMeter)?.text, "configured")
                    t.equal((skin.measure(named: "Photo") as? QuoteMeasure)?.itemCount, 1,
                            "the real Quote fixture reads the private directory and retains its file filter")
                    let path = skin.measure(named: "Photo")?.stringValue ?? ""
                    t.equal(try Data(contentsOf: URL(fileURLWithPath: path)), photo)
                    t.equal(virtual.background.outstanding, 0)
                    t.equal(virtual.background.unverifiable.count, 0)
                }
            t.equal(prepared.missing, [])
            guard let provenance else { throw Failure.invalidResult("Configured preparation did not produce provenance") }
            t.equal(provenance.originalSourceSHA256, hash(original))
            t.check(provenance.preparedSourceSHA256 != hash(original) && provenance.originalIndex == 11,
                    "the report distinguishes prepared bytes from the original occurrence")
            t.equal(try Data(contentsOf: source), original, "the configured include never replaces original bytes")

            func rejects(_ operation: () throws -> Void, _ note: String) {
                do { try operation(); t.check(false, note) }
                catch Failure.invalidManifest { t.check(true, note) }
                catch { t.check(false, "Unexpected configuration failure: \(error)") }
            }
            rejects({ _ = try verifiedFile("options.inc", under: root, sha256: hash(photo)) },
                    "a mismatched original hash cannot become a configured scenario")
            rejects({ _ = try verifiedFile("../options.inc", under: fixtureRoot, sha256: hash(original)) },
                    "a fixture cannot borrow a file outside its declared root")
            try FileManager.default.createSymbolicLink(at: fixtureRoot.appendingPathComponent("escape.inc"),
                                                       withDestinationURL: source)
            rejects({ _ = try verifiedFile("escape.inc", under: fixtureRoot, sha256: hash(original)) },
                    "an apparently local fixture symlink cannot escape its root")

            let inputBytes = Data("{}".utf8)
            let webBytes = Data("{\"webParserPage\":{\"https://fixtures.invalid/control\":\"photo.txt\"}}".utf8)
            let inputFile = fixtureRoot.appendingPathComponent("data.json"), webFile = fixtureRoot.appendingPathComponent("web.json")
            try inputBytes.write(to: inputFile)
            try webBytes.write(to: webFile)
            func manifest(_ inputHash: String, _ webHash: String, _ payloads: [String: String]) -> Manifest {
                Manifest(schemaVersion: 1, corpusRoot: root.path, data: inputFile.path, webFixtures: webFile.path,
                    reportDirectory: root.deletingLastPathComponent().appendingPathComponent("unused-report").path,
                    skins: ["Test.ini"], expectedSkinsRoots: nil,
                    configuration: ConfigurationInputs(dataSHA256: inputHash, webManifestSHA256: webHash,
                        webPayloadSHA256: payloads, skins: ["Test.ini": configuration]))
            }
            try validateConfigurationInputs(manifest(hash(inputBytes), hash(webBytes), ["photo.txt": hash(photo)]), data: inputFile)
            rejects({ try validateConfigurationInputs(manifest(hash(photo), hash(webBytes), ["photo.txt": hash(photo)]), data: inputFile) },
                    "data bytes must match the configured input binding")
            rejects({ try validateConfigurationInputs(manifest(hash(inputBytes), hash(photo), ["photo.txt": hash(photo)]), data: inputFile) },
                    "the exact response mapping is bound before a configured load")
            rejects({ try validateConfigurationInputs(manifest(hash(inputBytes), hash(webBytes), [:]), data: inputFile) },
                    "an unhashed mapped response cannot silently pass configured validation")
            rejects({ try validateConfigurationInputs(manifest(hash(inputBytes), hash(webBytes), ["photo.txt": hash(ignored)]), data: inputFile) },
                    "a response payload with changed bytes cannot silently pass configured validation")
        }
    }

    private static func optionOverrideTests(_ t: AppTestRunner) {
        t.suite("Runtime: corpus layer content: explicit source corrections require the original option and assets") {
            guard let testSkins = Paths.repositoryFolder("TestSkins") else {
                throw Failure.invalidResult("The existing isolated input fixture is required")
            }
            let root = canonical(t.temporaryDirectory("corpus-option-override").path)
            let folder = root.appendingPathComponent("Assets")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let asset = folder.appendingPathComponent("cover.png")
            try FileManager.default.copyItem(at: testSkins.appendingPathComponent("Runtime/Data/cover.png"), to: asset)
            let assetBytes = try Data(contentsOf: asset), data = testSkins.appendingPathComponent("Runtime/Data/mac.json")
            let file = root.appendingPathComponent("Test.ini")
            let original = Data("""
            [Frame]
            Measure=Calc
            Formula=Counter % 7
            [Panel]
            Meter=Image
            ImageName=#CURRENTPATH#Missing/cover.png
            DynamicVariables=1
            """.utf8)
            try original.write(to: file)
            let override = OptionOverride(section: "Panel", key: "ImageName",
                expectedValue: "#CURRENTPATH#Missing/cover.png", value: "#CURRENTPATH#Assets/cover.png")
            let assets = ["Assets/cover.png": hash(assetBytes)]
            func configuration(_ changes: [OptionOverride], _ assets: [String: String]) -> Configuration {
                Configuration(originalIndex: 334, source: "Test.ini", sourceSHA256: hash(original),
                    variables: [:], galleryFiles: nil, optionOverrides: changes, sourceAssetsSHA256: assets)
            }
            var provenance: Provenance?
            let result = try LegacyRenderSelfTests.withInputs(file, skinsDir: root.path, data: data,
                prepare: { skin, recording, virtual in
                    provenance = try prepareConfiguration(configuration([override], assets), root: root, fixtureRoot: root,
                        manifestSHA256: hash(Data("source correction control".utf8)),
                        skin: skin, recording: recording, virtual: virtual)
                }) { skin, recording, _ in
                    guard let path = (skin.meter(named: "Panel") as? ImageMeter)?.imagePath else {
                        throw Failure.invalidResult("The image meter must consume the corrected option during load")
                    }
                    t.equal(canonical(path), asset, "the real image meter resolves the corrected macro at its original read time")
                    t.check(Images.size(atPath: path) != nil, "the bound original asset actually decodes")
                    let copied = IniDocument.parse(recording.sourceText(for: file) ?? "")
                    t.equal(copied.section(named: "Panel")?.value(forKey: "ImageName"), override.value,
                            "the harness preserves the literal macro instead of resolving it early")
                    t.equal(copied.section(named: "Frame")?.value(forKey: "Formula"), "Counter % 7")
                    t.equal(copied.section(named: "Panel")?.value(forKey: "DynamicVariables"), "1")
                }
            t.equal(result.missing, [])
            t.equal(provenance?.optionOverrides?.first?.expectedValue, override.expectedValue)
            t.equal(provenance?.sourceAssetsSHA256, assets)
            t.equal(try Data(contentsOf: file), original, "the original source is unchanged after configured load")
            t.equal(try Data(contentsOf: asset), assetBytes, "source asset verification does not rewrite its bytes")

            func rejects(_ changes: [OptionOverride], _ bindings: [String: String], _ note: String) throws {
                var entered = false
                do {
                    _ = try LegacyRenderSelfTests.withInputs(file, skinsDir: root.path, data: data,
                        prepare: { skin, recording, virtual in
                            do {
                                _ = try prepareConfiguration(configuration(changes, bindings), root: root, fixtureRoot: root,
                                    manifestSHA256: "rejected control", skin: skin, recording: recording, virtual: virtual)
                            } catch {
                                t.check(recording.files.copy(of: file.path) == nil,
                                        "all correction preconditions precede creating or modifying a source copy")
                                throw error
                            }
                        }) { _, _, _ in entered = true }
                    t.check(false, note)
                } catch Failure.invalidManifest { t.check(true, note) }
                t.check(!entered, "a rejected correction never reaches the loaded-skin callback")
                t.equal(try Data(contentsOf: file), original)
            }
            try rejects([OptionOverride(section: "Panel", key: "ImageName", expectedValue: "wrong", value: override.value)],
                        assets, "a wrong original value is not silently replaced")
            try rejects([override], ["Assets/missing.png": hash(assetBytes)], "a missing bound source asset remains an input failure")
            try rejects([override, OptionOverride(section: "panel", key: "imagename", expectedValue: override.expectedValue,
                        value: override.value)], assets, "case-insensitive duplicate targets cannot make the outcome order-dependent")
            try rejects([OptionOverride(section: "Absent", key: "ImageName", expectedValue: override.expectedValue,
                        value: override.value)], assets, "an absent section is rejected rather than appended")
            try rejects([OptionOverride(section: "Panel", key: "Absent", expectedValue: override.expectedValue,
                        value: override.value)], assets, "an absent option is rejected rather than appended")
        }
    }

    /// All three bitmap owners stay on the virtual executor. Only immutable scenes/images reach native CA.
    private final class Session {
        let scale: Int
        private let dark: Bool
        private let executor: VirtualTimeExecutor
        private let device: any MTLDevice
        private let space: CGColorSpace
        private let runtime: LayerRuntime
        private let context = DrawContext(fonts: AppFontResolver())
        private var renderer: OffscreenRenderer?
        private var dimensions: Rect?
        private var omissionChecked = false
        var verifiedCanary: Bool { renderer?.hasVerifiedCanary == true }
        private var glass: GlassPaint { .placeholder(dark: dark) }

        init(scale: Int, dark: Bool, executor: VirtualTimeExecutor, device: any MTLDevice) throws {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure.unavailable("sRGB unavailable") }
            self.scale = scale
            self.dark = dark
            self.executor = executor
            self.device = device
            self.space = space
            runtime = try LayerRuntime(executor: executor, maximumOwnedBitmapBytes: budget)
        }

        func close(_ t: AppTestRunner) {
            do { try runtime.beginClose(); try runtime.close() }
            catch { t.check(false, "corpus runtime cleanup: \(error)") }
        }

        func compare(_ sample: Sample, replay: Bool, t: AppTestRunner, failurePrefix: URL) throws -> Frame {
            let failuresBefore = t.failures.count
            let scene = sample.scene
            let window = try deviceWindow(scene)
            let readbackBytes = try Rasterizer.requiredBytes(width: window.width, height: window.height)
            guard readbackBytes <= budget else { throw Failure.unavailable("Readback exceeds the explicit test budget") }
            if dimensions != window {
                renderer = try OffscreenRenderer(width: window.width, height: window.height, device: device,
                    maximumReadbackBytes: readbackBytes)
                dimensions = window
            }
            guard let renderer else { throw Failure.unavailable("Offscreen renderer unavailable") }
            let prepared = ScenePreparer.prepare(scene, context: context, target: try target())
            let frame = try updated(runtime, prepared, context, sample.cycle, window)
            let freshContext = DrawContext(fonts: AppFontResolver())
            let fresh = try LayerRuntime(executor: executor, maximumOwnedBitmapBytes: budget)
            defer { try? fresh.beginClose(); try? fresh.close() }
            let freshPrepared = ScenePreparer.prepare(scene, context: freshContext, target: try target())
            _ = try updated(fresh, freshPrepared, freshContext, sample.cycle, window)
            let single = try LayerContentBuilder(plan: SinglePartition.plan(in: window), scale: CGFloat(scale),
                                                colorSpace: space, maximumOwnedBitmapBytes: budget)
            let singleContents = try single.build(scene, context: DrawContext(fonts: AppFontResolver()),
                                                 cycle: sample.cycle, glass: glass)
            guard singleContents.count == 1 else { throw Failure.invalidResult("Single did not produce one image") }
            let candidateTree = host(runtime.root, window)
            let freshTree = host(fresh.root, window)
            let singleTree = imageTree(singleContents[0].image, window)
            let actual = try renderer.render(candidateTree, at: 0, deadline: .now() + .seconds(30))
            let reference = try renderer.render(singleTree, at: 0, deadline: .now() + .seconds(30))
            let cold = try renderer.render(freshTree, at: 0, deadline: .now() + .seconds(30))
            let a = try PixelComparison.compare(reference: reference.rgba, candidate: actual.rgba,
                                                width: window.width, height: window.height)
            let b = try PixelComparison.compare(reference: cold.rgba, candidate: actual.rgba,
                                                width: window.width, height: window.height)
            let hasPixels = stride(from: 3, to: actual.rgba.count, by: 4).contains { actual.rgba[$0] > 0 }
            t.check(renderer.hasVerifiedCanary, "native scribble/known-image canary passed")
            t.check(hasPixels, "the actual original skin paints nonempty pixels")
            t.check(a.isExact, "Single/candidate: \(a.changedPixels) pixels, max \(a.maxChannelDifference)")
            t.check(b.isExact, "fresh/incremental: \(b.changedPixels) pixels, max \(b.maxChannelDifference)")
            if !a.isExact || !b.isExact {
                try Data(reference.rgba).write(to: failurePrefix.appendingPathExtension("single.rgba"))
                try Data(actual.rgba).write(to: failurePrefix.appendingPathExtension("candidate.rgba"))
                try Data(cold.rgba).write(to: failurePrefix.appendingPathExtension("fresh.rgba"))
            }
            let layerDifferences = try compareLayers(frame.plan, reference: reference.rgba,
                                                     candidate: actual.rgba, fresh: cold.rgba)
            var ink: [Ink] = []
            for layer in frame.plan.layers {
                guard case let .group(ids) = layer.content else { continue }
                let members = try ids.map { id -> SceneElement in
                    guard let element = scene.topLevelElements.first(where: { $0.id == id }) else {
                        throw Failure.invalidResult("Group member absent from atomic scene order")
                    }
                    return element
                }
                let observation = try observe(members.flatMap { scene.drawingItems(for: $0) },
                                              bounds: layer.rect, window: window, cycle: sample.cycle)
                t.equal(observation.escapedPixels, 0, "foreground-only group ink stays in its proposed device rectangle")
                ink.append(Ink(members: ids.map(identity), rectangle: rectangle(layer.rect), canvas: observation.canvas,
                    alphaPixels: observation.alphaPixels, escapedPixels: observation.escapedPixels,
                    edgePixels: observation.edgePixels, firstEscape: observation.firstEscape))
                if !omissionChecked, observation.alphaPixels > 0 {
                    let removed = contentsTree(frame.contents.filter { $0.plan.id != layer.id }, window)
                    let without = try renderer.render(removed, at: 0, deadline: .now() + .seconds(30))
                    let control = try PixelComparison.compare(reference: actual.rgba, candidate: without.rgba,
                                                               width: window.width, height: window.height)
                    t.check(!control.isExact, "omitting an actually painted group is detected by native comparison")
                    omissionChecked = true
                }
            }
            let unknown = zip(scene.topLevelElements, prepared.runInk.dropFirst()).compactMap { element, candidate -> String? in
                if case let .unknown(reason) = candidate { return identity(element.id) + ":" + reason.rawValue }
                return nil
            }
            let fallback: String?
            switch frame.fallback {
            case let .some(.unresolvedInk(id, reason)): fallback = identity(id) + ":" + reason.rawValue
            case let .some(.localizedAntialiasedLine(group)): fallback = "localizedAntialiasedLine:\(group)"
            case .none: fallback = nil
            }
            return Frame(update: sample.cycle, virtualSeconds: sample.seconds, replay: replay,
                generation: scene.generation, sequence: frame.sequence, change: String(describing: frame.change),
                fallback: fallback, unknown: unknown, baseMembers: frame.plan.baseMembers.map(identity),
                skipped: frame.plan.skipped.map(identity), layers: frame.plan.layers.map(layerReport),
                layerDifferences: layerDifferences, areas: try areas(frame.plan, prepared.runInk), ink: ink,
                singleVsCandidate: Difference(a), freshVsIncremental: Difference(b), hasPixels: hasPixels,
                rgbaSHA256: SHA256.hash(data: Data(actual.rgba)).map { String(format: "%02x", $0) }.joined(),
                validationFailures: Array(t.failures.dropFirst(failuresBefore)))
        }

        private func updated(_ runtime: LayerRuntime, _ prepared: SceneInkCandidates, _ context: DrawContext,
                             _ cycle: Int, _ window: Rect) throws -> LayerRuntime.Frame {
            switch try runtime.update(prepared, in: window, scale: CGFloat(scale), colorSpace: space,
                partition: .candidateComponents, context: context, cycle: cycle, glass: glass) {
            case let .submitted(frame), let .unchanged(frame): return frame
            case .suppressed: throw Failure.invalidResult("A live diagnostic update was suppressed")
            }
        }
        private func target() throws -> DrawTarget {
            guard let bitmap = SkinBitmapDrawing.makeContext(1, 1, space) else { throw Failure.unavailable("Mapping bitmap") }
            bitmap.translateBy(x: 0, y: 1)
            bitmap.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
            let target = DrawTarget.prepareOwnedBitmap(bitmap, glass: glass)
            guard target.userToDevice == CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)) else {
                throw Failure.invalidResult("Preparation mapping is not canonical")
            }
            return target
        }
        private func deviceWindow(_ scene: WidgetScene) throws -> Rect {
            let w = scene.size.width * Double(scale), h = scene.size.height * Double(scale)
            guard w.isFinite, h.isFinite, w > 0, h > 0,
                  w <= Double(Rasterizer.maximumDimension), h <= Double(Rasterizer.maximumDimension),
                  let rect = Rect(minX: 0, minY: 0, maxX: Int(w.rounded(.up)), maxY: Int(h.rounded(.up))) else {
                throw Failure.invalidResult("Nonempty scene dimensions exceed the explicit bitmap boundary")
            }
            return rect
        }
        private func observe(_ items: [DrawItem], bounds: Rect, window: Rect, cycle: Int) throws -> Ink {
            // Window clipping is real destination semantics. The group clip itself is deliberately absent.
            guard let canvas = Rect(minX: bounds.minX - ring, minY: bounds.minY - ring,
                                    maxX: bounds.maxX + ring, maxY: bounds.maxY + ring) else {
                throw Failure.invalidResult("Observation rectangle cannot be represented")
            }
            let bytes = try Rasterizer.requiredBytes(width: canvas.width, height: canvas.height)
            guard bytes <= budget,
                  let bitmap = CGContext(data: nil, width: canvas.width, height: canvas.height, bitsPerComponent: 8,
                    bytesPerRow: canvas.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                throw Failure.unavailable("Observation bitmap exceeds the explicit allocation budget")
            }
            bitmap.concatenate(CGAffineTransform(a: CGFloat(scale), b: 0, c: 0, d: -CGFloat(scale),
                                                  tx: -CGFloat(canvas.minX), ty: CGFloat(canvas.maxY)))
            bitmap.clip(to: CGRect(x: 0, y: 0, width: CGFloat(window.width) / CGFloat(scale),
                                   height: CGFloat(window.height) / CGFloat(scale)))
            let target = DrawTarget.prepareOwnedBitmap(bitmap, glass: glass)
            DesksetDraw.DrawExecutor.draw(items, in: bitmap, context: context, cycle: cycle, target: target)
            guard let image = bitmap.makeImage() else { throw Failure.unavailable("Observation snapshot") }
            let observation = try InkEscapeObservation.scan(image, in: canvas, candidate: .rectangle(bounds),
                colorSpace: space, maximumPixels: budget / 4, maximumBytes: budget)
            guard case let .counted(pixels, first) = observation.outside else {
                throw Failure.invalidResult("A finite group observation unexpectedly became unknown")
            }
            return Ink(members: [], rectangle: rectangle(bounds), canvas: rectangle(canvas),
                alphaPixels: observation.alphaPixels, escapedPixels: pixels, edgePixels: observation.edgePixels,
                firstEscape: first.map { [$0.globalX, $0.globalY, Int($0.alpha)] })
        }
        private func host(_ content: CALayer, _ window: Rect) -> CALayer {
            let root = tree(window)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            content.setAffineTransform(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
            root.addSublayer(content)
            CATransaction.commit()
            return root
        }
        private func imageTree(_ image: CGImage, _ window: Rect) -> CALayer {
            let root = tree(window)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let layer = CALayer()
            layer.anchorPoint = .zero
            layer.frame = root.bounds
            layer.contents = image
            configure(layer)
            root.addSublayer(layer)
            CATransaction.commit()
            return root
        }
        private func contentsTree(_ contents: [LayerContentBuilder.Content], _ window: Rect) -> CALayer {
            let root = tree(window)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for content in contents {
                let layer = CALayer(), rect = content.plan.rect
                layer.anchorPoint = .zero
                layer.frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
                layer.contents = content.image
                layer.contentsRect = content.contentsRect
                configure(layer)
                root.addSublayer(layer)
            }
            CATransaction.commit()
            return root
        }
        private func tree(_ window: Rect) -> CALayer {
            let root = CALayer()
            root.anchorPoint = .zero
            root.bounds = CGRect(x: 0, y: 0, width: window.width, height: window.height)
            root.isGeometryFlipped = true
            root.contentsFormat = .RGBA8Uint
            return root
        }
        private func configure(_ layer: CALayer) {
            layer.contentsFormat = .RGBA8Uint
            layer.contentsScale = CGFloat(scale)
            layer.contentsGravity = .resize
            layer.minificationFilter = .nearest
            layer.magnificationFilter = .nearest
        }
    }

    private static func layerComparisonTests(_ t: AppTestRunner) {
        t.suite("Runtime: corpus layer content: layer comparisons use their own rectangles") {
            guard let window = Rect(minX: 0, minY: 0, maxX: 1000, maxY: 1),
                  let group = Rect(minX: 0, minY: 0, maxX: 999, maxY: 1),
                  let slice = Rect(minX: 999, minY: 0, maxX: 1000, maxY: 1),
                  let smallWindow = Rect(minX: 0, minY: 0, maxX: 3, maxY: 2),
                  let leftColumn = Rect(minX: 0, minY: 0, maxX: 1, maxY: 2),
                  let smallCrop = Rect(minX: 1, minY: 0, maxX: 3, maxY: 2) else {
                throw Failure.invalidResult("Representable layer comparison controls")
            }
            let member = ElementID(name: "Control", index: 0)
            let plan = PartitionPlan(window: window, baseMembers: [], layers: [
                LayerPlan(id: .group(fileIndex: 0), rect: group, content: .group(members: [member])),
                LayerPlan(id: .baseSlice(index: 0), rect: slice, content: .baseSlice(source: slice))
            ], skipped: [])
            let reference = (0..<1000).flatMap { _ -> [UInt8] in [0, 0, 0, 255] }
            var changed = reference
            changed[17 * 4] = 1
            let whole = try PixelComparison.compare(reference: reference, candidate: changed, width: 1000, height: 1)
            let layers = try compareLayers(plan, reference: reference, candidate: changed, fresh: reference)
            guard layers.count == 2 else { throw Failure.invalidResult("Every actual layer must be reported") }
            t.check(whole.meetsComponentTolerance && !whole.isExact,
                    "the 1000-pixel window's numeric allowance is not strict equality")
            t.check(layers[0].singleVsCandidate.pixels == 999 && layers[0].singleVsCandidate.changed == 1 &&
                    !layers[0].singleVsCandidate.withinComponentTolerance && !layers[0].singleVsCandidate.exact,
                    "the 999-pixel group cannot borrow the window's larger denominator")
            t.check(layers[0].role == "group" && layers[0].members == ["0:control"] &&
                    layers[1].role == "baseSlice" && layers[1].singleVsCandidate.exact,
                    "the observed change stays associated with its actual group and leaves the other slice exact")
            let basePlan = PartitionPlan(window: window, baseMembers: [], layers: [
                LayerPlan(id: .baseSlice(index: 0), rect: window, content: .baseSlice(source: window))
            ], skipped: [])
            let base = try compareLayers(basePlan, reference: reference, candidate: changed, fresh: changed)
            let fresh = try compareLayers(basePlan, reference: reference, candidate: reference, fresh: changed)
            guard let baseDifference = base.first, let freshDifference = fresh.first else {
                throw Failure.invalidResult("The full base slice must be reported")
            }
            t.check(baseDifference.singleVsCandidate.withinComponentTolerance &&
                    !baseDifference.singleVsCandidate.exact && baseDifference.freshVsIncremental.exact,
                    "a nonzero base difference remains a strict failure even when its numeric flag is true")
            t.check(freshDifference.singleVsCandidate.exact &&
                    freshDifference.freshVsIncremental.withinComponentTolerance &&
                    !freshDifference.freshVsIncremental.exact,
                    "a nonzero fresh/incremental difference remains a strict failure independently of Single")

            let rows = (0..<24).map { UInt8($0) }
            t.equal(try cropRGBA(rows, in: smallWindow, to: smallCrop),
                    [4, 5, 6, 7, 8, 9, 10, 11, 16, 17, 18, 19, 20, 21, 22, 23],
                    "top-row RGBA cropping copies active row segments without the skipped left pixels")
            let smallPlan = PartitionPlan(window: smallWindow, baseMembers: [], layers: [
                LayerPlan(id: .baseSlice(index: 0), rect: leftColumn, content: .baseSlice(source: leftColumn)),
                LayerPlan(id: .group(fileIndex: 0), rect: smallCrop, content: .group(members: [member]))
            ], skipped: [])
            var lastPixelChanged = rows
            lastPixelChanged[23] = 24
            let rowDifference = try compareLayers(smallPlan, reference: rows, candidate: lastPixelChanged, fresh: rows)
            t.equal(rowDifference.last?.singleVsCandidate.first, [1, 1, 3, 23, 24],
                    "a lower-row alpha difference uses local layer coordinates, not the window origin")

            func rejects(_ bytes: [UInt8], _ window: Rect, _ rect: Rect, _ note: String) {
                do {
                    _ = try cropRGBA(bytes, in: window, to: rect)
                    t.check(false, note)
                } catch Failure.invalidResult { t.check(true, note) }
                catch { t.check(false, "Unexpected crop failure: \(error)") }
            }
            rejects(Array(rows.dropLast()), smallWindow, smallCrop, "short source data cannot become an exact crop")
            rejects(rows + [0], smallWindow, smallCrop, "long source data does not silently become another format")
            guard let outside = Rect(minX: -1, minY: 0, maxX: 2, maxY: 1),
                  let empty = Rect(minX: 1, minY: 1, maxX: 1, maxY: 2),
                  let overflowingRow = Rect(minX: 0, minY: 0, maxX: Int.max, maxY: 1),
                  let overflowingImage = Rect(minX: 0, minY: 0, maxX: Int.max / 4, maxY: 2) else {
                throw Failure.invalidResult("Representable rejected crop controls")
            }
            rejects(rows, smallWindow, outside, "a layer outside the bitmap is rejected, not clipped")
            rejects(rows, smallWindow, empty, "an empty layer is not a passing image comparison")
            rejects([], overflowingRow, group, "row-byte multiplication is checked before source access")
            rejects([], overflowingImage, group, "total-byte multiplication is checked before source access")
        }
    }

    private static func compareLayers(_ plan: PartitionPlan, reference: [UInt8], candidate: [UInt8],
                                      fresh: [UInt8]) throws -> [LayerDifference] {
        try plan.layers.map { layer in
            let a = try cropRGBA(reference, in: plan.window, to: layer.rect)
            let b = try cropRGBA(candidate, in: plan.window, to: layer.rect)
            let c = try cropRGBA(fresh, in: plan.window, to: layer.rect)
            let description = layerReport(layer)
            return LayerDifference(role: description.role, rectangle: description.rectangle, members: description.members,
                singleVsCandidate: Difference(try PixelComparison.compare(reference: a, candidate: b,
                    width: layer.rect.width, height: layer.rect.height)),
                freshVsIncremental: Difference(try PixelComparison.compare(reference: c, candidate: b,
                    width: layer.rect.width, height: layer.rect.height)))
        }
    }

    private static func cropRGBA(_ rgba: [UInt8], in window: Rect, to rect: Rect) throws -> [UInt8] {
        guard window.minX == 0, window.minY == 0, !window.isEmpty, !rect.isEmpty,
              rect.minX >= 0, rect.minY >= 0, rect.maxX <= window.maxX, rect.maxY <= window.maxY else {
            throw Failure.invalidResult("Layer crop is outside a nonempty zero-origin bitmap")
        }
        let row = window.width.multipliedReportingOverflow(by: 4)
        guard !row.overflow else { throw Failure.invalidResult("Bitmap row bytes overflow") }
        let total = row.partialValue.multipliedReportingOverflow(by: window.height)
        guard !total.overflow, rgba.count == total.partialValue else {
            throw Failure.invalidResult("Bitmap byte count is not tightly packed RGBA")
        }
        // The checked full bitmap and contained rectangle bound all following offsets and the crop allocation.
        let active = rect.width * 4
        let count = active * rect.height
        let column = rect.minX * 4
        var result: [UInt8] = []
        result.reserveCapacity(count)
        for y in rect.minY..<rect.maxY {
            let start = y * row.partialValue + column
            let end = start + active
            guard end <= rgba.count else { throw Failure.invalidResult("Layer row exceeds the source bitmap") }
            result.append(contentsOf: rgba[start..<end])
        }
        return result
    }

    private static func areas(_ plan: PartitionPlan, _ runs: [InkBounds.Candidate]) throws -> Areas {
        func pixels(_ rect: Rect) throws -> Int {
            let result = rect.width.multipliedReportingOverflow(by: rect.height)
            guard !result.overflow else { throw Failure.invalidResult("Plan area overflows") }
            return result.partialValue
        }
        func adding(_ a: Int, _ b: Int) throws -> Int {
            let result = a.addingReportingOverflow(b)
            guard !result.overflow else { throw Failure.invalidResult("Plan area sum overflows") }
            return result.partialValue
        }
        let window = try pixels(plan.window)
        let base: Int
        switch try LayerContentBuilder.validateGeometry(plan) {
        case .empty, .single: base = 0
        case .components: base = window
        }
        var groups = 0, slices = 0, unknown = 0
        var known: Int? = 0
        for layer in plan.layers {
            switch layer.content {
            case .fullScene: break
            case .group: groups = try adding(groups, pixels(layer.rect))
            case .baseSlice: slices = try adding(slices, pixels(layer.rect))
            }
        }
        for candidate in runs.dropFirst() {
            switch candidate {
            case .empty: break
            case .unknown: unknown += 1
            case let .rectangle(rect):
                // An arbitrary off-window ideal rectangle may overflow even though the window is small.
                // Preserve that unknown numeric sum instead of saturating it or selecting a policy.
                if let accumulated = known { known = try? adding(accumulated, pixels(rect)) }
            }
        }
        return Areas(windowPixels: window, groupPixels: groups, baseBitmapPixels: base,
                     baseSlicePixels: slices, knownRunRectanglePixels: known, unknownRuns: unknown)
    }

    private static func layerReport(_ layer: LayerPlan) -> Layer {
        let role: String, members: [String]
        switch layer.content {
        case .fullScene: role = "single"; members = []
        case let .group(ids): role = "group"; members = ids.map(identity)
        case .baseSlice: role = "baseSlice"; members = []
        }
        return Layer(role: role, rectangle: rectangle(layer.rect), members: members)
    }
    private static func identity(_ id: ElementID) -> String { "\(id.index):\(id.name)" }
    private static func rectangle(_ rect: Rect) -> [Int] { [rect.minX, rect.minY, rect.maxX, rect.maxY] }
    private static func canonical(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }
    private static func isInside(_ file: URL, _ root: URL) -> Bool {
        file.path == root.path || file.path.hasPrefix(root.path + "/")
    }
    private static func reportURL(_ output: URL, _ index: Int, _ report: Report) -> URL {
        output.appendingPathComponent("\(index)-\(report.scale)x-\(report.appearance).json")
    }
    private static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
#endif
