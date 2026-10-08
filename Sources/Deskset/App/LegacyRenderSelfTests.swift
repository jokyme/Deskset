#if DEBUG
import AppKit
import Darwin
import DesksetCore

/// The frozen copy of the renderer (`LegacyRender/`, debug builds only) draws what the renderer draws, byte for byte:
/// the same skins, in one process, at the same moment, through both paths — `--render`'s bitmap in sRGB at 1x and 2x,
/// and at 2x also in the device RGB space and a skin window's full picture — light and dark. It is the reference the
/// renderer is compared with while its code moves, so these checks have to hold before anything moves.
enum LegacyRenderSelfTests {
    /// The TestSkins folders drawn: every meter type, containers, glass, SF Symbols, the system font designs, inline
    /// text options, and the example skins.
    static let folders = ["Graphs", "Image", "Round", "Shape", "String", "Mac", "Engine/Container", "Engine/Layout",
                          "Engine/Compat", "Deskset"]
    /// Left to the command-line comparison: String/Review draws a very long text with combining marks, seconds per
    /// picture in a debug build.
    static let skipped = ["String/Review/Review.ini"]
    /// `DESKSET_LEGACY_RENDER_EXTRA`: more skins to draw both ways, as `.ini` files or folders of them separated by
    /// colons (a local corpus, or skins whose data changes from run to run, which only a comparison in one process at
    /// one moment can check). Their writes and programs are recorded; missing inputs prevent full verification.
    static var extraSkins: [URL] {
        let list = ProcessInfo.processInfo.environment["DESKSET_LEGACY_RENDER_EXTRA"] ?? ""
        return list.split(separator: ":").flatMap { item -> [URL] in
            let url = URL(fileURLWithPath: String(item)).standardizedFileURL
            return url.pathExtension.lowercased() == "ini" ? [url] : iniFiles(in: url)
        }
    }

    static func run(_ t: AppTestRunner) {
        t.suite("Runtime: legacy renderer: draws the TestSkins byte for byte as the renderer does") {
            guard let testSkins = Paths.repositoryFolder("TestSkins") else {
                print("    (skipped: TestSkins not found; run from the repository)")
                return
            }
            // A copy: skins may write their own files.
            let skins = t.temporaryDirectory("legacy-render").appendingPathComponent("TestSkins")
            try FileManager.default.copyItem(at: testSkins, to: skins)
            let set = folders.flatMap { iniFiles(in: skins.appendingPathComponent($0)) }
                .filter { file in !skipped.contains { file.path.hasSuffix("/" + $0) } }
            t.check(set.count >= 30, "the TestSkins set is there: \(set.count) skins")
            let files = set.map { ($0, true) } + extraSkins.map { ($0, false) }
            let data = skins.appendingPathComponent("Runtime/Data/mac.json")
            let manifest = ProcessInfo.processInfo.environment["DESKSET_LEGACY_RENDER_WEB_FIXTURES"]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            let webFixtures = try manifest.map { try LegacyRenderWebFixtures(manifest: $0) }
            let savedAppearance = NSApp.appearance
            defer {
                NSApp.appearance = savedAppearance
                MacAppearance.current.refresh()
                DesktopInputs.appearance.refresh()
            }
            var drawn = 0, baseWithPixels = 0, covered = 0
            for appearance in [RenderOptions.Appearance.light, .dark] {
                RenderCommand.applyAppearance(appearance)
                for (file, inSet) in files {
                    let name = file.path.replacingOccurrences(of: skins.path + "/", with: "")
                        + " (\(appearance.rawValue))"
                    do {
                        let checked = try withInputs(file, skinsDir: inSet ? skins.path : nil, data: data,
                                                     webFixtures: webFixtures) {
                            skin, _, _ in compare(skin, name, t)
                        }
                        drawn += checked.value.drawn
                        if inSet && checked.value.hasPixels { baseWithPixels += 1 }
                        if complete(hasPixels: checked.value.hasPixels, missing: checked.missing) { covered += 1 }
                        if !checked.missing.isEmpty {
                            print("    input coverage incomplete: \(name): \(checked.missing.joined(separator: "; "))")
                        }
                        t.check(checked.missing.isEmpty, "\(name): every observed input is covered")
                        if !inSet {
                            t.check(checked.value.hasPixels, "\(name): the extra skin has visible pixels")
                        }
                    } catch {
                        t.check(false, "\(name) loads with isolated inputs: \(error)")
                    }
                }
            }
            t.check(drawn >= files.count * 2 * 4, "every skin drawn both ways at 1x and 2x: \(drawn) pictures")
            // Not an empty comparison: nearly every skin draws something.
            t.check(baseWithPixels >= set.count * 2 - 4, "\(baseWithPixels) of \(set.count * 2) base drawings have pixels")
            print("    Compared \(drawn) pictures; \(covered) of \(files.count * 2) skin appearances have pixels and covered observed inputs.")
        }

        inputTests(t)
        LegacyRenderWebFixtureSelfTests.run(t)

        t.suite("Runtime: legacy renderer: image histories are reset before comparison") {
            guard let canvas = Images.bitmapContext(width: 14, height: 14) else { return t.check(false, "a bitmap") }
            for y in 0..<14 {
                for x in 0..<14 {
                    let color = RGBA(r: Double((x * 17 + y * 7) % 256), g: Double((y * 19 + x * 11) % 256),
                                     b: Double((x * 23 + y * 13) % 256), a: Double(17 + (x * 13 + y * 19) % 239))
                    canvas.setFillColor(color.cgColor)
                    canvas.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            guard let image = canvas.makeImage(), let png = FileViewIconWriter.encode(image, pathExtension: "png"),
                  let loaded = SkinDrawingSelfTests.load(t, """
                    [Rainmeter]
                    Update=-1
                    [Image]
                    Meter=Image
                    ImageName=alpha.png
                    X=5
                    Y=3
                    """, files: ["alpha.png": png], "legacy-image-history"),
                  let space = CGColorSpace(name: CGColorSpace.sRGB) else {
                return t.check(false, "the original translucent image and skin load")
            }
            let skin = loaded.skin, path = loaded.folder.appendingPathComponent("alpha.png").path
            defer { withExtendedLifetime(loaded.host) { skin.close() } }
            let w = max(Int(skin.width * 2), 1), h = max(Int(skin.height * 2), 1)
            for legacyFirst in [false, true] {
                // Different prior formats and scales, in both orders; measuring has also warmed only Images.
                var options = RenderOptions(input: "")
                options.colorSpace = .srgb
                options.legacy = legacyFirst
                t.check(RenderCommand.draw(skin, width: w / 2, height: h / 2, scale: 1, options: options) != nil)
                let window = legacyFirst
                    ? SkinBitmapDrawing.fullDrawing(of: skin, w, h, scale: 2, space: space)
                    : LegacySkinBitmapDrawing.fullDrawing(of: skin, w, h, scale: 2, space: space)
                t.check(window?.makeImage() != nil)
                guard let current = Images.cachedImage(path), let legacy = LegacyImages.cachedImage(path) else {
                    t.check(false, "both paths have a warmed source image")
                    continue
                }
                t.check(bytesEqual(current, legacy), "the source pixels match despite their different histories")
                let checked = compare(skin, "image histories, legacy first=\(legacyFirst)", t)
                t.equal(checked.drawn, 4)
                t.check(checked.hasPixels, "all four comparisons draw the translucent pattern")
                t.check(Images.cachedImage(path) !== current, "the comparison starts with a fresh current source")
                t.check(LegacyImages.cachedImage(path) !== legacy, "the comparison starts with a fresh legacy source")
            }
        }

        t.suite("Runtime: legacy renderer: a difference is found") {
            guard let loaded = SkinDrawingSelfTests.load(t, """
                [Rainmeter]
                Update=-1
                [Square]
                Meter=Image
                W=20
                H=20
                SolidColor=200,40,40,255
                """, "legacy-canary") else {
                t.check(false, "the canary skin loads")
                return
            }
            let skin = loaded.skin
            defer { withExtendedLifetime(loaded.host) { skin.close() } }
            guard let before = pngs(skin, scale: 1, colorSpace: .srgb) else {
                t.check(false, "the canary is drawn")
                return
            }
            t.check(before.current == before.legacy, "the same skin draws the same both ways")
            // One of the two paths drawing another picture must show.
            skin.execute("[!SetOption Square SolidColor 200,40,41,255][!UpdateMeter Square]", from: nil)
            guard let after = pngs(skin, scale: 1, colorSpace: .srgb) else {
                t.check(false, "the changed canary is drawn")
                return
            }
            t.check(after.current != before.legacy, "one level of one channel differs")
            t.check(pixelsEqual(after.current, before.legacy) == false, "and the pixel comparison finds it")
        }

        t.suite("Runtime: legacy renderer: --render --legacy gives the same bytes as --render") {
            guard let testSkins = Paths.repositoryFolder("TestSkins") else {
                print("    (skipped: TestSkins not found; run from the repository)")
                return
            }
            typealias V = CommandLineTools.Validation
            let program = ["/Applications/Deskset.app/Contents/MacOS/Deskset"]
            t.equal(CommandLineTools.validate(program + ["--render", "a.ini", "--legacy"]), V.mode)
            t.equal(CommandLineTools.validate(program + ["--legacy"]),
                    V.invalid("--legacy needs one of --render, --snapshot-ui, --weather-report, --benchmark"))
            t.check(RenderOptions.parse(["Deskset", "--render", "a.ini", "--legacy"])?.legacy == true)
            t.check(RenderOptions.parse(["Deskset", "--render", "a.ini"])?.legacy == false)
            t.check(!CommandLineTools.usage.contains("--legacy"), "a development flag, not in the usage")

            let root = t.temporaryDirectory("legacy-render-command")
            let skins = root.appendingPathComponent("TestSkins")
            try FileManager.default.copyItem(at: testSkins, to: skins)
            let data = skins.appendingPathComponent("Runtime/Data/mac.json").path
            let out = root.appendingPathComponent("out")
            for skin in ["Deskset/System/System.ini", "String/Inline/Inline.ini", "Mac/Glass/Glass.ini",
                         "Shape/Paint/Paint.ini"] {
                var images: [Data?] = []
                for legacy in [false, true] {
                    let png = out.appendingPathComponent(skin.replacingOccurrences(of: "/", with: "_")
                                                         + (legacy ? ".legacy.png" : ".png"))
                    let status = RenderCommand.run(["Deskset", "--render", skins.appendingPathComponent(skin).path,
                                                    "--out", png.path, "--updates", "3", "--scale", "2",
                                                    "--clock", "2026-09-26T12:00:00Z", "--time-zone", "Europe/Oslo",
                                                    "--seed", "7", "--data", data, "--color-space", "srgb"]
                                                   + (legacy ? ["--legacy"] : []))
                    t.equal(status, 0, "\(skin) renders")
                    images.append(try? Data(contentsOf: png))
                }
                t.check(images[0] != nil && images[0] == images[1], "\(skin): the same bytes")
            }
        }
    }

    /// Pixel equality alone cannot verify an empty skin or a skin whose inputs were unavailable.
    private static func complete(hasPixels: Bool, missing: [String]) -> Bool { hasPixels && missing.isEmpty }

    /// The same render host and skin serve both paths. Shared inputs are replaced before loading the skin;
    /// per-measure backends are replaced after loading and before the first update.
    static func withInputs<Value>(_ file: URL, skinsDir: String? = nil, data dataURL: URL,
                                  webFixtures: LegacyRenderWebFixtures? = nil, closeTimeout: TimeInterval = 5,
                                  prepare: ((Skin, RecordingSideEffects, VirtualTimeExecutor) throws -> Void)? = nil,
                                  driveUpdates: ((Skin, RecordingSideEffects, VirtualTimeExecutor, RenderData) throws -> Void)? = nil,
                                  _ body: (Skin, RecordingSideEffects, VirtualTimeExecutor) throws -> Value)
        throws -> (value: Value, missing: [String]) {
        let data = try SkinInputData.load(dataURL.path, directory: dataURL.deletingLastPathComponent())
        let inputs = RenderData(data)
        let directory = skinsDir.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        let (root, config) = RenderCommand.locate(file.standardizedFileURL.resolvingSymlinksInPath(), skinsDir: directory)
        var options = RenderOptions(input: file.path)
        options.timeZone = TimeZone(identifier: "Europe/Oslo")!
        options.clock = RenderOptions.date("2026-09-26T12:00:00Z", zone: options.timeZone!)!
        let virtual = options.virtualTime()!
        virtual.background.allowsUnfakedWork = false
        let host = RenderHost()
        host.fixed = options.environment
        let skin = Skin(config: config, fileURL: file, skinsDirectory: root,
                        system: inputs.systemSource(base: SystemMonitor.shared), host: host)
        defer { withExtendedLifetime(host) {} }
        skin.runInVirtualTime(virtual)
        skin.random = SkinRandom(seed: 7)
        virtual.background.allowFixtureReads(under: dataURL.deletingLastPathComponent())
        virtual.background.setFake(.service, for: .weather)
        virtual.background.setFake(.service, for: .sun)
        if data.sensors != nil { virtual.background.setFake(.service, for: .sensorList) }
        virtual.background.addSettleHook { WeatherService.shared.drain() }
        virtual.background.setFake(.value(.number(12)), for: .ping)

        let savedIcons = FileViewIcons.renderer, savedPlayer = NowPlayingCenter.current
        let savedWeather = WeatherService.shared.environment, savedCache = MediaUICache.root
        let savedSettings = EnvironmentStore.shared.settingsPath
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyRender-\(UUID().uuidString)")
        let settings = scratch.appendingPathComponent("Settings")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        let stationery = settings.appendingPathComponent(DefaultSkins.stationeryFileName)
        try DefaultSkins.stationeryFileHeader.write(to: stationery, atomically: true, encoding: .utf8)
        MediaUICache.root = scratch.appendingPathComponent("Caches")
        EnvironmentStore.shared.settingsPath = settings.path + "/"
        virtual.background.allowFixtureReads(under: settings)
        virtual.background.allowFixtureReads(under: MediaUICache.root)
        FileViewIcons.renderer = { _, size, _ in iconPNG(size: size) }
        virtual.background.setFake(.service, for: .fileViewIcon)
        inputs.install(for: skin, virtual: virtual, locale: host.fixed.locale)
        defer {
            inputs.restore()
            FileViewIcons.renderer = savedIcons
            NowPlayingCenter.current = savedPlayer
            WeatherService.install(savedWeather)
            MediaUICache.root = savedCache
            EnvironmentStore.shared.settingsPath = savedSettings
            try? FileManager.default.removeItem(at: scratch)
        }
        var closed = false
        func close() {
            skin.close()
            RenderCommand.step(virtual, until: virtual.now, deadline: Date().addingTimeInterval(closeTimeout))
            closed = true
        }
        defer { if !closed { close() } }
        guard let recording = inputs.recording else {
            throw NSError(domain: "LegacyRender", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "the render data must supply recorded programs"])
        }
        var missing: [String] = []
        // The app creates this file before skins load. Its existing-file check then does nothing, but it still
        // runs through the recording. Only this exact command against the existing private file is covered.
        let stationeryProgram = SkinInputData.Program(
            match: "test -e \"\(stationery.path)\" || : > \"\(stationery.path)\"", output: "")
        var programData = data
        programData.programs?.append(stationeryProgram)
        recording.programOutput = { Data(programData.programOutput(for: $0).utf8) }
        let missingPrograms = Guarded<[String]>([])
        recording.onRecord = { [weak recording] effect in
            guard case let .launch(executable, arguments, _) = effect, executable == "/bin/sh",
                  arguments.first == "-c", let command = arguments.dropFirst().first else { return }
            if command == stationeryProgram.match, arguments.count == 2,
               let path = recording?.files.path(for: stationery.path, access: .read),
               FileManager.default.fileExists(atPath: path) { return }
            if !(data.programs ?? []).contains(where: { command.contains($0.match) }) {
                missingPrograms.access { $0.append("RunCommand: no fixture for \(command)") }
            }
        }
        let recordingRoot = recording.files.directory.standardizedFileURL.resolvingSymlinksInPath().path
        let roots = [skin.rootConfigDirectory, dataURL.deletingLastPathComponent(), scratch]
            .map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
            + [recordingRoot]
        func fixturePath(_ path: String, under allowed: [String]) -> String? {
            let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            return allowed.contains { resolved == $0 || resolved.hasPrefix($0 + "/") } ? resolved : nil
        }
        let web = BackgroundFake.script { request -> BackgroundFakeValue in
            do {
                if let bytes = try webFixtures?.response(for: request) { return .data(bytes) }
            } catch {
                let reason = "\(request.kind.rawValue): \(request.subject): \(error.localizedDescription)"
                missing.append(reason)
                return .failure(reason)
            }
            // WebParser reports its normalized target as file:// plus the absolute path (possibly unescaped).
            if request.subject.hasPrefix("file://") {
                let path = String(request.subject.dropFirst(7))
                for candidate in [path, path.removingPercentEncoding ?? path] {
                    let fixture: String
                    if let copy = recording.files.copy(of: candidate) {
                        // A skin may write outside its tree. Only its existing, private copy is an input then.
                        guard let readable = fixturePath(copy, under: [recordingRoot]) else { continue }
                        fixture = readable
                    } else {
                        guard fixturePath(candidate, under: roots) != nil else { continue }
                        let readable = recording.files.path(for: candidate, access: .read)
                        guard let checked = fixturePath(readable, under: roots) else { continue }
                        fixture = checked
                    }
                    if let bytes = webFixture(fixture, kind: request.kind) { return .data(bytes) }
                }
            }
            let reason = "\(request.kind.rawValue): no fixture for \(request.subject)"
            missing.append(reason)
            // nil would fall back to the live network job.
            return .failure(reason)
        }
        virtual.background.setFake(web, for: .webParserPage)
        virtual.background.setFake(web, for: .webParserDownload)
        // Configure the recording's source copies before options and OnRefreshAction can read their inputs.
        try prepare?(skin, recording, virtual)
        try skin.load()
        let volumes = skin.measures.compactMap { $0 as? Win7AudioMeasure }
        if !volumes.isEmpty {
            let output = AudioSelfTests.FakeOutput()
            for volume in volumes { volume.system = output }
            // AppVolume uses the same service kind but has a different backend, which is not replaced here.
            if skin.measures.allSatisfy({ !$0.liveInputs.contains(.volume) || $0 is Win7AudioMeasure }) {
                virtual.background.setFake(.service, for: .volume)
            }
        }
        Fonts.registerFonts(for: skin)
        if let driveUpdates {
            // A synchronous DEBUG harness can observe the first real update with the same installed inputs.
            // Existing callers retain exactly the original two-update history below.
            try driveUpdates(skin, recording, virtual, inputs)
        } else {
            skin.update()
            RenderCommand.step(virtual, until: 1, deadline: Date().addingTimeInterval(5))
            inputs.advance()
            skin.update()
            RenderCommand.step(virtual, until: virtual.now, deadline: Date().addingTimeInterval(5))
        }
        let value = try body(skin, recording, virtual)
        close()
        missing += missingPrograms.current
        for run in skin.measures.compactMap({ $0 as? RunCommandMeasure }) where run.value >= 100 {
            missing.append("RunCommand [\(run.name)] failed (\(run.value)): \(run.string("Program")) \(run.string("Parameter"))")
        }
        missing += virtual.background.unverifiable.map(\.description)
        if virtual.background.outstanding > 0 { missing.append("background work did not settle") }
        return (value, Array(Set(missing)).sorted())
    }

    /// Match WebParserNetwork's regular-file requirement and its 16 MiB page / 64 MiB download limits.
    private static func webFixture(_ path: String, kind: BackgroundWorkKind) -> Data? {
        LegacyRenderWebFixtures.readFixture(path, kind: kind)
    }

    /// A real, partly transparent PNG. FileView still writes it through the recording's normal file path.
    private static func iconPNG(size: Int) -> Data? {
        let side = min(max(size, 1), 256)
        guard let canvas = Images.bitmapContext(width: side, height: side) else { return nil }
        canvas.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        canvas.fill(CGRect(x: side / 2, y: 0, width: side - side / 2, height: side))
        guard let image = canvas.makeImage() else { return nil }
        return FileViewIconWriter.encode(image, pathExtension: "png")
    }

    private static func inputTests(_ t: AppTestRunner) {
        t.suite("Runtime: legacy renderer: preparation configures recorded sources before load") {
            guard let source = Paths.repositoryFolder("TestSkins") else { return }
            let skins = t.temporaryDirectory("legacy-prepared-inputs")
            let folder = skins.appendingPathComponent("Prepared")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("Prepared.ini")
            let options = folder.appendingPathComponent("options.inc")
            let page = folder.appendingPathComponent("page.txt")
            let original = "[Variables]\nFeed=YourFeedHere\nUnrelated=retained\n"
            try original.write(to: options, atomically: true, encoding: .utf8)
            try "marker=prepared".write(to: page, atomically: true, encoding: .utf8)
            try """
            [Rainmeter]
            OnRefreshAction=[!SetVariable SeenAtRefresh "#Feed#"][!UpdateMeasure Page]
            [Variables]
            @Include=#CURRENTPATH#options.inc
            [Page]
            Measure=WebParser
            URL=#Feed#
            RegExp=marker=(.*)
            StringIndex=1
            [Text]
            Meter=String
            MeasureName=Page
            """.write(to: file, atomically: true, encoding: .utf8)
            let data = source.appendingPathComponent("Runtime/Data/mac.json")
            let unprepared = try withInputs(file, skinsDir: skins.path, data: data) { skin, _, _ in
                t.equal(skin.variable("SeenAtRefresh"), "YourFeedHere")
            }
            t.check(unprepared.missing.contains { $0.contains("<not a URL: YourFeedHere>") },
                    "omitting preparation retains the missing-input result")
            var preparations = 0
            let prepared = try withInputs(file, skinsDir: skins.path, data: data, prepare: { skin, recording, virtual in
                preparations += 1
                t.check(skin.measures.isEmpty, "preparation precedes measure creation")
                t.check(skin.sourceProvider === recording, "the installed recording supplies source copies")
                t.check(!virtual.background.allowsUnfakedWork, "preparation retains the strict input gate")
                let copy = URL(fileURLWithPath: recording.files.path(for: options.path, access: .update))
                t.equal(try String(contentsOf: copy, encoding: .utf8), original, "the overlay starts as a real copy")
                try IniWriter.writeValue("file://" + page.path, key: "Feed", section: "Variables", fileURL: copy)
            }) { skin, recording, virtual in
                t.equal(skin.variable("SeenAtRefresh"), "file://" + page.path,
                        "the first refresh action already sees the prepared option")
                t.equal(skin.variable("Unrelated"), "retained")
                t.equal(skin.measure(named: "Page")?.stringValue, "prepared")
                t.equal((skin.meter(named: "Text") as? StringMeter)?.text, "prepared")
                t.equal(virtual.background.outstanding, 0)
                return recording
            }
            t.equal(preparations, 1)
            t.equal(prepared.missing, [], "the configured local page is fully covered")
            t.check(prepared.value.sourceText(for: options)?.contains("Feed=file://" + page.path) == true)
            t.equal(try String(contentsOf: options, encoding: .utf8), original, "the original source is unchanged")
        }

        t.suite("Runtime: legacy renderer: preparation failures restore installed inputs") {
            guard let source = Paths.repositoryFolder("TestSkins") else { return }
            enum PreparationFailure: Error { case expected }
            let skins = t.temporaryDirectory("legacy-failed-preparation")
            let file = skins.appendingPathComponent("Unused.ini")
            try "[Text]\nMeter=String\nText=unused\n".write(to: file, atomically: true, encoding: .utf8)
            let savedSettings = EnvironmentStore.shared.settingsPath, savedCache = MediaUICache.root
            weak var releasedSkin: Skin?
            weak var releasedRecording: RecordingSideEffects?
            weak var releasedExecutor: VirtualTimeExecutor?
            var reachedBody = false
            do {
                try autoreleasepool {
                    _ = try withInputs(file, skinsDir: skins.path,
                                       data: source.appendingPathComponent("Runtime/Data/mac.json"),
                                       prepare: { skin, recording, virtual in
                        releasedSkin = skin
                        releasedRecording = recording
                        releasedExecutor = virtual
                        throw PreparationFailure.expected
                    }) { _, _, _ in reachedBody = true }
                }
                t.check(false, "preparation failure propagates")
            } catch PreparationFailure.expected {
                t.check(true, "preparation failure propagates")
            }
            t.check(!reachedBody, "a failed preparation never runs the body")
            t.equal(EnvironmentStore.shared.settingsPath, savedSettings)
            t.equal(MediaUICache.root, savedCache)
            t.check(releasedSkin == nil, "the unloaded skin is released")
            t.check(releasedRecording == nil, "the recording and its private files are released")
            t.check(releasedExecutor == nil, "the virtual executor is released")
        }

        t.suite("Runtime: legacy renderer: isolated inputs preserve files and draw completed work") {
            guard let source = Paths.repositoryFolder("TestSkins") else { return }
            let skins = t.temporaryDirectory("legacy-inputs").appendingPathComponent("TestSkins")
            try FileManager.default.copyItem(at: source, to: skins)
            let folder = skins.appendingPathComponent("Runtime/LegacyInputs")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("Items"),
                                                    withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("Inputs.ini"), state = folder.appendingPathComponent("state.inc")
            let output = t.temporaryDirectory("legacy-recorded-output").appendingPathComponent("out.txt")
            let image = folder.appendingPathComponent("Items/test.png")
            try "[Variables]\nMarker=original\n".write(to: state, atomically: true, encoding: .utf8)
            try "original\n".write(to: output, atomically: true, encoding: .utf8)
            try "0,255,0,255".write(to: folder.appendingPathComponent("page.txt"), atomically: true, encoding: .utf8)
            try iconPNG(size: 16)?.write(to: image)
            try """
            [Rainmeter]
            Update=1000
            OnRefreshAction=[!SetVariable VolumeAtRefresh [Volume:0]][!CommandMeasure Run "Run"][!WriteKeyValue Variables Marker changed "#CURRENTPATH#state.inc"][!Delay 500][!SetOption Late SolidColor 255,0,0,255][!UpdateMeter Late]
            OnCloseAction=[!WriteKeyValue Variables Marker closed "#CURRENTPATH#state.inc"]
            [Run]
            Measure=Plugin
            Plugin=RunCommand
            Parameter=echo hw.perflevel0.logicalcpu
            OutputFile=\(output.path)
            FinishAction=[!EnableMeasure Overlay][!CommandMeasure Overlay "Update"]
            [Overlay]
            Measure=WebParser
            URL=file://\(output.path)
            Disabled=1
            RegExp=(?s)(.*)
            StringIndex=1
            UpdateRate=1
            [Page]
            Measure=WebParser
            URL=file://#CURRENTPATH#page.txt
            RegExp=(?s)(.*)
            StringIndex=1
            FinishAction=[!SetOption PagePixel SolidColor [Page]][!UpdateMeter PagePixel]
            [Files]
            Measure=Plugin
            Plugin=FileView
            Path=#CURRENTPATH#Items
            ShowDotDot=0
            [Icon]
            Measure=Plugin
            Plugin=FileView
            Path=[Files]
            Type=Icon
            IconPath=#CURRENTPATH#icon.png
            [Ping]
            Measure=Plugin
            Plugin=PingPlugin
            DestAddress=192.0.2.1
            [Cover]
            Measure=NowPlaying
            PlayerName=Music
            PlayerType=Cover
            [Volume]
            Measure=Plugin
            Plugin=Win7AudioPlugin
            [Late]
            Meter=Image
            W=20
            H=20
            SolidColor=0,0,255,255
            [PagePixel]
            Meter=Image
            X=24
            W=20
            H=20
            [Picture]
            Meter=Image
            ImageName=#CURRENTPATH#Items/test.png
            X=48
            [IconPixel]
            Meter=Image
            MeasureName=Icon
            X=72
            W=32
            H=32
            [CoverPixel]
            Meter=Image
            MeasureName=Cover
            X=108
            W=32
            H=32
            """.write(to: file, atomically: true, encoding: .utf8)
            weak var releasedExecutor: VirtualTimeExecutor?
            weak var releasedRecording: RecordingSideEffects?
            weak var releasedWorker: MediaUIWorker?
            try autoreleasepool {
                let checked = try withInputs(file, skinsDir: skins.path, data: skins.appendingPathComponent("Runtime/Data/mac.json")) {
                    skin, recording, virtual -> RecordingSideEffects in
                    releasedExecutor = virtual
                    releasedRecording = recording
                    releasedWorker = NowPlayingCenter.current.worker
                    t.check(NowPlayingCenter.current.worker.runsInline, "a virtual demo player needs no waiting thread")
                    t.check(skin.sourceProvider === recording, "the installed recording supplies the overlay")
                    t.check(recording.records.contains(.launch(executable: "/bin/sh",
                        arguments: ["-c", "echo hw.perflevel0.logicalcpu"], directory: folder.path)))
                    t.check(recording.records.contains(.writeFile(path: output.path)), "the output write is recorded")
                    t.equal(skin.measure(named: "Run")?.stringValue, "6 4\n", "the installed program fixture is retained")
                    t.equal(skin.measure(named: "Overlay")?.stringValue, "6 4\n", "WebParser reads the overlay of an outside path")
                    t.check(recording.sourceText(for: state)?.contains("Marker=changed") == true)
                    t.equal(skin.measure(named: "Ping")?.value, 12, "the fixed ping result")
                    let volume = skin.measure(named: "Volume") as? Win7AudioMeasure
                    t.check(volume?.system is AudioSelfTests.FakeOutput, "volume reads the installed fake controller")
                    t.equal(volume?.value, 50, "the offline volume is nonzero")
                    t.equal(volume?.stringValue, "MacBook Pro Speakers", "the offline output device has a name")
                    t.equal(Double(skin.variable("VolumeAtRefresh") ?? ""), 50,
                            "the first OnRefreshAction already sees the fake volume")
                    t.check(virtual.background.reports.contains { $0.kind == .volume && $0.faked },
                            "volume is covered after its fake controller is installed")
                    let queries = skin.host as? SkinImageQueries
                    t.equal(queries?.imagePixelAlpha(atPath: image.path, x: 0, y: 8, exifOriented: false), 0)
                    t.equal(queries?.imagePixelAlpha(atPath: image.path, x: 12, y: 8, exifOriented: false), 255)
                    let icon = skin.measure(named: "Icon")?.stringValue ?? ""
                    t.check(Images.cgImage(atPath: icon) != nil, "FileView wrote a decodable icon")
                    let cover = skin.measure(named: "Cover")?.stringValue ?? ""
                    t.check(cover.hasPrefix(MediaUICache.root.path + "/") && Images.cgImage(atPath: cover) != nil,
                            "the demo player writes a real cover in this render's cache")
                    let compared = compare(skin, "isolated input canary", t)
                    t.check(compared.hasPixels)
                    let pixels = pngs(skin, scale: 1, colorSpace: .srgb).flatMap { NSBitmapImageRep(data: $0.current) }
                    let late = pixels?.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB)
                    t.check((late?.redComponent ?? 0) > 0.9 && (late?.blueComponent ?? 1) < 0.1, "the delayed color is drawn")
                    for x in [34, 60, 96] {
                        let color = pixels?.colorAt(x: x, y: 8)?.usingColorSpace(.sRGB)
                        t.check((color?.greenComponent ?? 0) > 0.9 && (color?.alphaComponent ?? 0) > 0.9,
                                "the local page, image and icon draw real pixels at \(x)")
                    }
                    t.check((pixels?.colorAt(x: 120, y: 8)?.alphaComponent ?? 0) > 0.9, "the cover is drawn")
                    return recording
                }
                t.equal(checked.missing, [], "all canary inputs are covered")
                t.equal(try String(contentsOf: output, encoding: .utf8), "original\n", "the original output is untouched")
                t.equal(try String(contentsOf: state, encoding: .utf8), "[Variables]\nMarker=original\n", "the original INI is untouched")
                t.check(checked.value.sourceText(for: state)?.contains("Marker=closed") == true,
                        "OnCloseAction runs before the input overlay is restored")
            }
            t.check(releasedExecutor == nil, "the render's virtual executor is released")
            t.check(releasedRecording == nil, "the recording and its scratch files are released")
            t.check(releasedWorker == nil, "the demo player's worker is released")
        }

        t.suite("Runtime: legacy renderer: private generated covers are readable without allowing their parent") {
            guard let source = Paths.repositoryFolder("TestSkins") else {
                return t.check(false, "TestSkins are required for the private cover boundary")
            }
            let skins = t.temporaryDirectory("legacy-cover-inputs")
            let file = skins.appendingPathComponent("Cover.ini")
            try """
            [Cover]
            Measure=NowPlaying
            PlayerName=Music
            PlayerType=Cover
            [Palette]
            Measure=Plugin
            Plugin=Chameleon
            Type=File
            Path=[Cover]
            DynamicVariables=1
            Disabled=1
            [Outside]
            Measure=Plugin
            Plugin=Chameleon
            Type=File
            Disabled=1
            """.write(to: file, atomically: true, encoding: .utf8)
            let checked = try withInputs(file, skinsDir: skins.path,
                data: source.appendingPathComponent("Runtime/Data/mac.json")) { skin, _, virtual -> String in
                guard let palette = skin.measure(named: "Palette") as? ChameleonMeasure,
                      let outside = skin.measure(named: "Outside") as? ChameleonMeasure else {
                    t.check(false, "the actual Chameleon measures must load")
                    return ""
                }
                let cover = skin.measure(named: "Cover")?.stringValue ?? ""
                t.check(cover.hasPrefix(MediaUICache.root.appendingPathComponent("NowPlaying").path + "/"))
                let bytes = try Data(contentsOf: URL(fileURLWithPath: cover))
                t.equal(bytes, try Data(contentsOf: source.appendingPathComponent("Runtime/Data/cover.png")),
                        "the generated cover retains the supplied fake player's image bytes")
                t.check(Images.cgImage(atPath: cover) != nil, "the fake player produced a real decodable cover")
                t.check(palette.palette == nil, "the disabled measure has not analyzed the cover yet")
                skin.execute("[!EnableMeasure Palette][!UpdateMeasure Palette]", from: nil)
                RenderCommand.step(virtual, until: virtual.now, deadline: Date().addingTimeInterval(5))
                t.equal(palette.imagePath, cover)
                t.check(palette.palette != nil, "Chameleon actually analyzed the generated cover")
                t.check(virtual.background.reports.contains { $0.kind == .desktopImage && $0.subject == cover && $0.faked })
                t.equal(virtual.background.unverifiable.count, 0)

                // A readable image beside Caches is still outside the authorized tree. Granting Caches' parent
                // would make this negative control fail, even though both files belong only to this test run.
                let denied = MediaUICache.root.deletingLastPathComponent().appendingPathComponent("outside-cover.png")
                try bytes.write(to: denied)
                t.check(Images.cgImage(atPath: denied.path) != nil, "the denied input is a valid image, not a missing file")
                skin.execute("[!SetOption Outside Path \"\(denied.path)\"][!EnableMeasure Outside][!UpdateMeasure Outside]", from: nil)
                RenderCommand.step(virtual, until: virtual.now, deadline: Date().addingTimeInterval(5))
                t.check(outside.palette == nil, "no palette is supplied for an unauthorized sibling")
                t.check(virtual.background.unverifiable.contains {
                    $0.kind == .desktopImage && $0.subject == denied.path && $0.reason.contains("blocked")
                })
                t.equal(virtual.background.unverifiable.count, 1)
                t.equal(virtual.background.outstanding, 0, "the denied file did not start real work")
                return denied.path
            }
            t.check(!checked.value.isEmpty)
            t.equal(checked.missing.count, 1)
            t.check(checked.missing.first?.contains(checked.value) == true,
                    "only the unauthorized sibling prevents input qualification")
        }

        t.suite("Runtime: legacy renderer: a volume fake does not cover another volume backend") {
            guard let source = Paths.repositoryFolder("TestSkins") else { return }
            let skins = t.temporaryDirectory("legacy-volume-inputs").appendingPathComponent("TestSkins")
            try FileManager.default.copyItem(at: source, to: skins)
            let file = skins.appendingPathComponent("Runtime/VolumeInputs.ini")
            try """
            [Volume]
            Measure=Plugin
            Plugin=Win7AudioPlugin
            [AppVolume]
            Measure=Plugin
            Plugin=AppVolume
            Disabled=1
            """.write(to: file, atomically: true, encoding: .utf8)
            let checked = try withInputs(file, skinsDir: skins.path,
                                         data: skins.appendingPathComponent("Runtime/Data/mac.json")) { skin, _, virtual in
                t.equal(skin.measure(named: "Volume")?.value, 50)
                t.check(skin.measure(named: "AppVolume") is AppVolumeMeasure)
                t.check(virtual.background.unverifiable.contains { $0.kind == .volume },
                        "the shared service kind is not marked covered for a backend that was not replaced")
            }
            t.check(checked.missing.contains { $0.contains("volume") })
        }

        t.suite("Runtime: legacy renderer: Stationery initialization covers only an existing-file no-op") {
            guard let source = Paths.repositoryFolder("TestSkins"),
                  let defaults = Paths.repositoryFolder("DefaultSkins") else { return }
            let skins = t.temporaryDirectory("legacy-stationery-inputs").appendingPathComponent("TestSkins")
            try FileManager.default.copyItem(at: source, to: skins)
            try FileManager.default.copyItem(at: defaults.appendingPathComponent("Stationery"),
                                             to: skins.appendingPathComponent("Stationery"))
            let data = skins.appendingPathComponent("Runtime/Data/mac.json")
            for name in ["ToDo/Medium.ini", "Launcher/Medium.ini"] {
                let checked = try withInputs(skins.appendingPathComponent("Stationery/" + name),
                                             skinsDir: skins.path, data: data) { skin, recording, _ in
                    let file = URL(fileURLWithPath: skin.variable("StationeryFile") ?? "")
                    t.equal(file.lastPathComponent, DefaultSkins.stationeryFileName)
                    t.equal(try String(contentsOf: file, encoding: .utf8), DefaultSkins.stationeryFileHeader,
                            "the app's initial settings file exists before the skin loads")
                    t.check(skin.includedFiles.contains { $0.path == file.path }, "the skin loaded its settings file")
                    let command = "test -e \"\(file.path)\" || : > \"\(file.path)\""
                    t.check(recording.records.contains(.launch(executable: "/bin/sh", arguments: ["-c", command],
                                                              directory: skin.directory.path)))
                    t.equal(skin.measure(named: "MeasureStationeryFile")?.value, 1, "initialization completed")
                    t.equal(skin.measure(named: "MeasureStationeryFile")?.stringValue, "", "the no-op has no output")
                }
                if name.hasPrefix("Launcher/") {
                    t.check(!checked.missing.contains { $0.contains("RunCommand") }, "initialization is covered")
                    t.check(checked.missing.contains { $0.contains("FileView") && $0.contains("blocked") },
                            "the launcher's real folder remains an uncovered input")
                } else {
                    t.equal(checked.missing, [], "\(name): the installed inputs cover initialization")
                }
            }

            let file = skins.appendingPathComponent("Runtime/StationeryPrograms.ini")
            try """
            [Rainmeter]
            Update=-1
            OnRefreshAction=[!CommandMeasure Initial "Run"]
            [Variables]
            StationeryFile=#SETTINGSPATH#Stationery.inc
            [Initial]
            Measure=Plugin
            Plugin=RunCommand
            Parameter=test -e "#StationeryFile#" || : > "#StationeryFile#"
            [Appended]
            Measure=Plugin
            Plugin=RunCommand
            Parameter=test -e "#StationeryFile#" || : > "#StationeryFile#"; echo legacy-uncovered-suffix
            [OtherFile]
            Measure=Plugin
            Plugin=RunCommand
            Parameter=test -e "#SETTINGSPATH#Other.inc" || : > "#SETTINGSPATH#Other.inc"
            """.write(to: file, atomically: true, encoding: .utf8)
            let checked = try withInputs(file, skinsDir: skins.path, data: data) { skin, recording, virtual in
                let stationery = URL(fileURLWithPath: skin.variable("StationeryFile") ?? "")
                t.equal(skin.measure(named: "Initial")?.value, 1)
                skin.execute("[!CommandMeasure Appended Run][!CommandMeasure OtherFile Run]", from: nil)
                t.check(recording.files.remove(stationery.path), "remove only the recording's copy")
                skin.execute("[!CommandMeasure Initial Run]", from: nil)
                RenderCommand.step(virtual, until: virtual.now, deadline: Date().addingTimeInterval(5))
                // Restoring it later must not cover the command that observed it missing.
                try DefaultSkins.stationeryFileHeader.write(to: recording.destination(forWriting: stationery),
                                                            atomically: true, encoding: .utf8)
                t.equal(try String(contentsOf: stationery, encoding: .utf8), DefaultSkins.stationeryFileHeader)
                return ["Initial", "Appended", "OtherFile"].compactMap { skin.measure(named: $0)?.string("Parameter") }
            }
            t.equal(checked.missing.count, 3)
            for command in checked.value {
                t.check(checked.missing.contains("RunCommand: no fixture for \(command)"),
                        "a missing file, extra shell content or another target remains uncovered")
            }
        }

        t.suite("Runtime: legacy renderer: empty or missing extra inputs cannot complete verification") {
            guard let source = Paths.repositoryFolder("TestSkins") else { return }
            let skins = t.temporaryDirectory("legacy-missing-inputs").appendingPathComponent("TestSkins")
            try FileManager.default.copyItem(at: source, to: skins)
            let file = skins.appendingPathComponent("Runtime/Missing.ini")
            let data = skins.appendingPathComponent("Runtime/Data/mac.json")
            let outside = t.temporaryDirectory("legacy-outside-input").appendingPathComponent("outside.txt")
            try "outside fixture".write(to: outside, atomically: true, encoding: .utf8)
            let linked = file.deletingLastPathComponent().appendingPathComponent("linked.txt")
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
            let pipe = file.deletingLastPathComponent().appendingPathComponent("pipe.txt")
            t.equal(mkfifo(pipe.path, 0o600), 0)
            let largePage = file.deletingLastPathComponent().appendingPathComponent("large-page.txt")
            let largeDownload = file.deletingLastPathComponent().appendingPathComponent("large-download.bin")
            for (url, size) in [(largePage, 17), (largeDownload, 65)] {
                try Data().write(to: url)
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: UInt64(size * 1_048_576))
                try handle.close()
            }
            try """
            [Rainmeter]
            Update=1000
            OnRefreshAction=[!CommandMeasure Run "Run"][!CommandMeasure Unsupported "Run"]
            [Run]
            Measure=Plugin
            Plugin=RunCommand
            Parameter=echo legacy-missing-program
            [Unsupported]
            Measure=Plugin
            Plugin=RunCommand
            Program=legacy-only.exe
            Parameter=--missing-input
            [Page]
            Measure=WebParser
            URL=https://example.invalid/legacy-page
            [Download]
            Measure=WebParser
            URL=https://example.invalid/legacy-image.png
            Download=1
            [Outside]
            Measure=WebParser
            URL=file://\(outside.path)
            RegExp=(.*)
            [Linked]
            Measure=WebParser
            URL=file://\(linked.path)
            RegExp=(.*)
            [Pipe]
            Measure=WebParser
            URL=file://\(pipe.path)
            [LargePage]
            Measure=WebParser
            URL=file://\(largePage.path)
            [LargeDownload]
            Measure=WebParser
            URL=file://\(largeDownload.path)
            Download=1
            [OutsideQuote]
            Measure=Plugin
            Plugin=QuotePlugin
            PathName=\(outside.path)
            [OutsideFolder]
            Measure=Plugin
            Plugin=FolderInfo
            Folder=\(outside.deletingLastPathComponent().path)
            InfoType=FileCount
            [OutsideFiles]
            Measure=Plugin
            Plugin=FileView
            Path=\(outside.deletingLastPathComponent().path)
            ShowDotDot=0
            [Pixel]
            Meter=Image
            W=20
            H=20
            SolidColor=255,0,0,255
            """.write(to: file, atomically: true, encoding: .utf8)
            let missing = try withInputs(file, skinsDir: skins.path, data: data) { skin, _, virtual in
                for kind in [BackgroundWorkKind.webParserPage, .webParserDownload, .runCommandProcess] {
                    t.check(virtual.background.reports.contains { $0.kind == kind && $0.faked },
                            "\(kind): requests are intercepted, with no live fallback")
                }
                for kind in [BackgroundWorkKind.quote, .folderInfo, .fileViewListing] {
                    t.check(virtual.background.unverifiable.contains { $0.kind == kind && $0.reason.contains("blocked") },
                            "\(kind): an outside read is blocked and prevents verification")
                }
                t.equal(virtual.background.outstanding, 0, "no real outside job was started")
                t.equal(skin.measure(named: "Outside")?.stringValue, "", "a file outside the fixtures is not read")
                t.equal(skin.measure(named: "Linked")?.stringValue, "", "a symlink cannot escape the fixtures")
                return compare(skin, "missing inputs", t)
            }
            for input in ["https://example.invalid/legacy-page", "https://example.invalid/legacy-image.png",
                          "echo legacy-missing-program", "legacy-only.exe --missing-input", outside.path, linked.path,
                          pipe.path, largePage.path, largeDownload.path] {
                t.check(missing.missing.contains { $0.contains(input) }, "the missing input is named: \(input)")
            }
            t.check(missing.value.hasPixels, "even an equal, visible picture cannot stand in for its missing inputs")
            t.check(!complete(hasPixels: missing.value.hasPixels, missing: missing.missing))
            try "[Rainmeter]\nUpdate=-1\n[Empty]\nMeter=Image\nW=20\nH=20\n"
                .write(to: file, atomically: true, encoding: .utf8)
            let empty = try withInputs(file, skinsDir: skins.path, data: data) { skin, _, _ in compare(skin, "empty extra", t) }
            t.equal(empty.missing, [])
            t.check(!empty.value.hasPixels && !complete(hasPixels: empty.value.hasPixels, missing: empty.missing),
                    "an all-transparent extra cannot complete verification")
        }

        t.suite("Runtime: legacy renderer: late input completion stays incomplete") {
            guard let source = Paths.repositoryFolder("TestSkins") else { return }
            let skins = t.temporaryDirectory("legacy-late-input").appendingPathComponent("TestSkins")
            try FileManager.default.copyItem(at: source, to: skins)
            let file = skins.appendingPathComponent("Runtime/Late.ini")
            try "[Rainmeter]\nUpdate=-1\n[Pixel]\nMeter=Image\nW=20\nH=20\nSolidColor=255,0,0,255\n"
                .write(to: file, atomically: true, encoding: .utf8)
            var deliver: ((Int) -> Void)?
            weak var executor: VirtualTimeExecutor?
            weak var recording: RecordingSideEffects?
            var applied = false
            func finishInput() {
                let completion = deliver
                deliver = nil
                completion?(1)
            }
            defer { finishInput(); executor?.runUntilIdle() }
            let late = try withInputs(file, skinsDir: skins.path,
                                      data: skins.appendingPathComponent("Runtime/Data/mac.json"), closeTimeout: 0) {
                skin, effects, virtual in
                executor = virtual
                recording = effects
                let job = BackgroundJob<Int>(.fileViewIcon, subject: "gated input", start: { deliver = $0 })
                skin.startBackground(job) { _ in applied = true }
                return compare(skin, "late input", t)
            }
            t.check(late.value.hasPixels && late.missing.contains("background work did not settle"))
            t.check(!complete(hasPixels: late.value.hasPixels, missing: late.missing), "an unfinished input is incomplete")
            finishInput()
            // Neither the producer's callback nor its queued hop may retain the executor after returning.
            t.check(executor == nil, "the late hop releases the executor without another owner step")
            t.check(recording == nil, "the late hop releases the recording and its scratch files")
            t.check(!applied, "the closed skin receives no late result")
        }
    }

    /// Draws `skin` both ways and checks the bytes: `--render`'s bitmap in sRGB (the reference images' space) at 1x
    /// and 2x, and at 2x also in device RGB (`--render`'s default) and the skin window's full picture. Returns the
    /// number of pictures compared, and whether it drew anything at all.
    static func compare(_ skin: Skin, _ name: String, _ t: AppTestRunner) -> (drawn: Int, hasPixels: Bool) {
        // Measuring warms only Images. Equal public CGImage pixels can round differently in BGRA after different
        // prior drawing histories, so both paths start this comparison with freshly decoded source images.
        Images.purge()
        LegacyImages.purge()
        var drawn = 0, hasPixels = false
        for scale in [1.0, 2.0] {
            for space in scale == 2 ? [RenderOptions.ColorSpace.srgb, .device] : [.srgb] {
                guard let pair = pngs(skin, scale: scale, colorSpace: space) else {
                    t.check(false, "\(name) is drawn at \(scale)x (\(space.rawValue))")
                    continue
                }
                t.check(pair.current == pair.legacy, "\(name) at \(Int(scale))x (\(space.rawValue)): the same bytes")
                drawn += 1
            }
            // The skin window's picture: glass as its hit areas, in the window's 8-bit BGRA bitmap.
            guard scale == 2 else { continue }
            let w = max(Int((skin.width * scale).rounded(.up)), 1), h = max(Int((skin.height * scale).rounded(.up)), 1)
            guard w <= 8192, h <= 8192, let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let current = SkinBitmapDrawing.fullDrawing(of: skin, w, h, scale: CGFloat(scale), space: space),
                  let legacy = LegacySkinBitmapDrawing.fullDrawing(of: skin, w, h, scale: CGFloat(scale), space: space),
                  let a = current.makeImage(), let b = legacy.makeImage() else {
                t.check(false, "\(name): the window's picture is drawn at \(scale)x")
                continue
            }
            t.check(bytesEqual(a, b), "\(name) at \(Int(scale))x (window): the same bytes")
            if !hasPixels { hasPixels = !isEmpty(a) }
            drawn += 1
        }
        return (drawn, hasPixels)
    }

    /// `--render`'s PNG of `skin` as it stands, through the renderer and through the frozen copy.
    static func pngs(_ skin: Skin, scale: Double, colorSpace: RenderOptions.ColorSpace)
        -> (current: Data, legacy: Data)? {
        let w = min(max(Int(ceil(max(skin.width, 1) * scale)), 1), RenderOptions.maxPixels)
        let h = min(max(Int(ceil(max(skin.height, 1) * scale)), 1), RenderOptions.maxPixels)
        var options = RenderOptions(input: "")
        options.colorSpace = colorSpace
        guard let current = RenderCommand.draw(skin, width: w, height: h, scale: scale, options: options) else {
            return nil
        }
        options.legacy = true
        guard let legacy = RenderCommand.draw(skin, width: w, height: h, scale: scale, options: options) else {
            return nil
        }
        return (current, legacy)
    }

    /// The `.ini` files under `folder` (not in @Resources), sorted.
    static func iniFiles(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "ini" && !$0.path.contains("/@Resources/") }
            .sorted { $0.path < $1.path }
    }

    /// Whether two images have the same size, pixel format and bytes, pixel for pixel.
    static func bytesEqual(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height, a.bitsPerPixel == b.bitsPerPixel,
              a.bitmapInfo == b.bitmapInfo, let pa = rows(a), let pb = rows(b) else { return false }
        return pa == pb
    }

    /// Whether two PNGs hold the same pixels (nil when one cannot be read).
    static func pixelsEqual(_ a: Data, _ b: Data) -> Bool? {
        guard let ra = NSBitmapImageRep(data: a)?.cgImage, let rb = NSBitmapImageRep(data: b)?.cgImage else { return nil }
        return bytesEqual(ra, rb)
    }

    /// Whether every byte of the image is 0 (transparent black in the premultiplied formats drawn here).
    static func isEmpty(_ image: CGImage) -> Bool {
        guard let bytes = rows(image) else { return true }
        return !bytes.contains { $0 != 0 }
    }

    /// The image's rows as stored, without the padding at their ends: two images of one pixel format are the same
    /// pixels exactly when these are equal (copied, never drawn, so no color matching or rounding).
    static func rows(_ image: CGImage) -> [UInt8]? {
        guard let data = image.dataProvider?.data as Data? else { return nil }
        let row = image.width * image.bitsPerPixel / 8
        var out: [UInt8] = []
        out.reserveCapacity(row * image.height)
        for y in 0..<image.height {
            let start = y * image.bytesPerRow
            guard start + row <= data.count else { return nil }
            out.append(contentsOf: data[start..<start + row])
        }
        return out
    }
}
#endif
