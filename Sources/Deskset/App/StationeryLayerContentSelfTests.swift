#if DEBUG
import AppKit
import CryptoKit
import DesksetCore
import DesksetDraw
import DesksetRuntime
import Metal

/// Original Stationery files, sampled on their virtual owner with the existing isolated inputs. Only scene values
/// and immutable image snapshots cross to a real C worker. This does not activate three real skin windows or glass.
enum StationeryLayerContentSelfTests {
    private typealias Rect = InkBounds.DeviceRect
    private static let names = ["Clock/Small.ini", "System/Large.ini", "NowPlaying/Medium.ini"]
    // An explicit fixture allocation budget, not a process-memory claim or the pending four-times policy.
    private static let budget = 16 * 1024 * 1024

    static func run(_ t: AppTestRunner) {
        rawTests(t)
        workerTests(t)
        uncoveredTests(t)
    }

    private struct Sample {
        let scene: WidgetScene
        let cycle: Int
        let legacy: CGImage
        let scale: Int
        let dark: Bool
        let glass: GlassPaint
        let appearance: String

        var window: Rect {
            get throws {
                let w = scene.size.width * Double(scale), h = scene.size.height * Double(scale)
                guard w.isFinite, h.isFinite, w > 0, h > 0,
                      w <= Double(Rasterizer.maximumDimension), h <= Double(Rasterizer.maximumDimension),
                      let rect = Rect(minX: 0, minY: 0, maxX: Int(w.rounded(.up)), maxY: Int(h.rounded(.up))) else {
                    throw CocoaError(.coderInvalidValue)
                }
                return rect
            }
        }
    }

    private static func rawTests(_ t: AppTestRunner) {
        t.suite("Runtime: Stationery C content: real default recipes match legacy and fresh Single") {
            let skins = try copiedSkins(t, "stationery-c-raw")
            let saved = NSApp.appearance
            defer { NSApp.appearance = saved; MacAppearance.current.refresh(); DesktopInputs.appearance.refresh() }
            for dark in [false, true] {
                RenderCommand.applyAppearance(dark ? .dark : .light)
                for name in names {
                    Images.purge()
                    LegacyImages.purge()
                    let checked = try LegacyRenderSelfTests.withInputs(skins.appendingPathComponent("Stationery/" + name),
                        skinsDir: skins.path, data: skins.appendingPathComponent("Runtime/Data/mac.json"),
                        prepare: { skin, recording, virtual in
                            try prepareApplications(name, skin, recording, virtual, t)
                        }) { skin, _, virtual in
                        let samples = try sampleHistory(skin, name, virtual, dark, t)
                        for scale in [1, 2] {
                            let context = DrawContext(fonts: AppFontResolver())
                            for sample in samples[scale] ?? [] {
                                let single = try freshSingle(sample, context)
                                checkImage(single, sample.legacy, sample, t,
                                           "\(name) \(scale)x: fresh Single / frozen legacy active BGRA")
                            }
                            // The window's hit fill is a separate destination contract from the G2 stand-in.
                            let hit = try capture(skin, SceneProjector(), scale, dark, .hitArea)
                            t.equal(hit.scene.glass, skin.glassRegions)
                            checkImage(try freshSingle(hit, context), hit.legacy, hit, t,
                                       "\(name) \(scale)x: published hit area / frozen window bitmap")
                        }
                    }
                    t.equal(checked.missing, [], "\(name): every observed input is faked and settled")
                }
            }
        }
    }

    private static func workerTests(_ t: AppTestRunner) {
        t.suite("Runtime: Stationery C content: physical owner history matches fresh Single") {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: the Stationery native worker comparison did not run")
            }
            let skins = try copiedSkins(t, "stationery-c-worker")
            let saved = NSApp.appearance
            defer { NSApp.appearance = saved; MacAppearance.current.refresh(); DesktopInputs.appearance.refresh() }
            for dark in [false, true] {
                RenderCommand.applyAppearance(dark ? .dark : .light)
                for name in names {
                    Images.purge()
                    LegacyImages.purge()
                    let checked = try LegacyRenderSelfTests.withInputs(skins.appendingPathComponent("Stationery/" + name),
                        skinsDir: skins.path, data: skins.appendingPathComponent("Runtime/Data/mac.json"),
                        prepare: { skin, recording, virtual in
                            try prepareApplications(name, skin, recording, virtual, t)
                        }) { skin, _, virtual in
                        let samples = try sampleHistory(skin, name, virtual, dark, t)
                        for scale in [1, 2] {
                            guard let history = samples[scale], history.count == 4 else {
                                throw CocoaError(.coderInvalidValue)
                            }
                            try compareWorker(history, name, device, t)
                        }
                    }
                    t.equal(checked.missing, [], "\(name): native equality has complete observed input coverage")
                }
            }
        }
    }

    private static func copiedSkins(_ t: AppTestRunner, _ label: String) throws -> URL {
        guard let testSkins = Paths.repositoryFolder("TestSkins"), let defaults = Paths.repositoryFolder("DefaultSkins") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let root = t.temporaryDirectory(label).appendingPathComponent("Skins")
        try FileManager.default.copyItem(at: testSkins, to: root)
        try FileManager.default.copyItem(at: defaults.appendingPathComponent("Stationery"),
                                         to: root.appendingPathComponent("Stationery"))
        for name in names {
            t.equal(try Data(contentsOf: root.appendingPathComponent("Stationery/" + name)),
                    try Data(contentsOf: defaults.appendingPathComponent("Stationery/" + name)),
                    "the real shipped \(name) is copied without rewriting its recipe")
        }
        return root
    }

    /// The original player recipe lists two system paths. Its recording maps those paths to entirely synthetic
    /// private folders before loading; FileView's actual queue lists readablePath, and the existing icon seam
    /// writes the fake PNG. No system application directory or application bundle is enumerated or copied.
    private static func prepareApplications(_ name: String, _ skin: Skin, _ recording: RecordingSideEffects,
                                            _ virtual: VirtualTimeExecutor, _ t: AppTestRunner) throws {
        guard name.hasPrefix("NowPlaying/") else { return }
        t.check(skin.measures.isEmpty && skin.sourceProvider === recording && !virtual.background.allowsUnfakedWork)
        for (path, app) in [("/System/Applications/", "Music.app"), ("/Applications/", "Spotify.app")] {
            let folder = recording.files.path(for: path, access: .write)
            guard folder != path, recording.files.contains(folder), skin.readablePath(path) == folder else {
                throw CocoaError(.coderInvalidValue)
            }
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: folder).appendingPathComponent(app),
                                                    withIntermediateDirectories: true)
            t.check(recording.files.contains(folder) && skin.readablePath(path) == folder,
                    "the original application path resolves only to the prepared private fake filesystem")
        }
        // There is no scripted Listing decoder. This job runs against the checked private filesystem above,
        // as a host fake service, with the same actual queue and owner delivery as the original FileView recipe.
        virtual.background.setFake(.service, for: .fileViewListing)
    }

    /// withInputs performed two updates already. Three additional actual updates reach five, but these samples do
    /// not include its first update. A/B/A below replays captured values, not a claim to rewind the Skin's history.
    private static func sampleHistory(_ skin: Skin, _ name: String, _ virtual: VirtualTimeExecutor, _ dark: Bool,
                                      _ t: AppTestRunner) throws -> [Int: [Sample]] {
        t.check(Thread.isMainThread && virtual.isCurrent && skin.executor === virtual && !SkinThreadExecutor.isSkinThread,
                "input execution and projection remain on the original virtual owner")
        t.check(!skin.skinClock.isLive)
        guard let system = skin.system as? ScriptedSystemData else { throw CocoaError(.coderInvalidValue) }
        t.check(system.gives(.system) && system.gives(.battery) && system.gives(.sensors))
        let projectors = [1: SceneProjector(), 2: SceneProjector()]
        var samples: [Int: [Sample]] = [1: [], 2: []]
        for index in 0..<4 {
            if index > 0 {
                system.advance()
                let seconds: Double = name.hasPrefix("Clock/") && index == 2 ? 60 : 1
                RenderCommand.step(virtual, until: virtual.now + seconds, deadline: Date().addingTimeInterval(5))
                skin.update()
                if name.hasPrefix("NowPlaying/") && index == 1 {
                    skin.execute("[!SetVariable VolumeRow 1][!SetVariable VolumeTarget 25][!UpdateMeterGroup Progress][!Redraw]", from: nil)
                }
                RenderCommand.step(virtual, until: virtual.now, deadline: Date().addingTimeInterval(5))
            }
            for scale in [1, 2] {
                guard let projector = projectors[scale] else { throw CocoaError(.coderInvalidValue) }
                let sample = try capture(skin, projector, scale, dark, .placeholder(dark: dark))
                qualify(sample, name, t)
                samples[scale, default: []].append(sample)
            }
        }
        t.check(skin.updateCount >= 5, "the original default skin has received at least five actual updates")
        if name.hasPrefix("System/") {
            t.check(system.frameIndex >= 4, "the CPU source moved through the existing system fixture frames")
            t.check((skin.measure(named: "MeasureCPU")?.value ?? 0) > 0)
        }
        if name.hasPrefix("NowPlaying/") {
            t.check(virtual.background.reports.contains { $0.kind == .fileViewListing && $0.faked },
                    "the original player listing completed through the prepared filesystem fake")
            for measure in ["MeasureIcon1", "MeasureIcon2"] {
                let path = skin.measure(named: measure)?.stringValue ?? ""
                guard let sandbox = skin.sideEffects.fileSandbox, sandbox.contains(path),
                      let image = Images.cgImage(atPath: path) else {
                    t.check(false, "the original \(measure) did not publish a real private fake PNG")
                    continue
                }
                t.check(image.width > 0 && image.height > 0 && !LegacyRenderSelfTests.isEmpty(image),
                        "the original \(measure) wrote, published and decoded nonempty private pixels")
            }
        }
        t.equal(virtual.background.outstanding, 0, "no unavailable background completion is ignored")
        t.equal(virtual.background.unverifiable.count, 0, "no live service was substituted for a missing fake")
        return samples
    }

    private static func capture(_ skin: Skin, _ projector: SceneProjector, _ scale: Int, _ dark: Bool,
                                _ glass: GlassPaint) throws -> Sample {
        guard skin.executor.isCurrent else { throw CocoaError(.coderInvalidValue) }
        let appearance = NSApp.effectiveAppearance.name.rawValue
        let environment = AppSceneEnvironment(scale: Double(scale), appearance: dark ? .dark : .light,
                                              appearanceName: appearance)
        let published: Bool
        if case .hitArea = glass { published = true } else { published = false }
        let scene = projector.project(skin, environment: environment, glassSource: published ? .published : .current)
        let w = scene.size.width * Double(scale), h = scene.size.height * Double(scale)
        guard w.isFinite, h.isFinite, w > 0, h > 0,
              w <= Double(Rasterizer.maximumDimension), h <= Double(Rasterizer.maximumDimension),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw CocoaError(.coderInvalidValue) }
        let width = Int(w.rounded(.up)), height = Int(h.rounded(.up))
        let legacy: CGImage
        if published {
            guard let bitmap = LegacySkinBitmapDrawing.fullDrawing(of: skin, width, height,
                                                                  scale: CGFloat(scale), space: space),
                  let image = bitmap.makeImage() else { throw CocoaError(.coderInvalidValue) }
            legacy = image
        } else {
            // The frozen renderer's existing flipped AppKit bitmap call, with explicit stand-in glass. It is not
            // a candidate bitmap, a crop of one, or a new configuration of the frozen rendering state.
            guard let bitmap = LegacySkinBitmapDrawing.makeContext(width, height, space) else {
                throw CocoaError(.coderInvalidValue)
            }
            bitmap.translateBy(x: 0, y: CGFloat(height))
            bitmap.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
            LegacySkinRenderer.draw(skin, in: bitmap, glass: .placeholder(dark: dark))
            NSGraphicsContext.restoreGraphicsState()
            guard let image = bitmap.makeImage() else { throw CocoaError(.coderInvalidValue) }
            legacy = image
        }
        return Sample(scene: scene, cycle: skin.updateCount, legacy: legacy, scale: scale, dark: dark,
                      glass: glass, appearance: appearance)
    }

    private static func qualify(_ sample: Sample, _ name: String, _ t: AppTestRunner) {
        t.check(!sample.scene.glass.isEmpty, "\(name): the real default has glass regions, not only an empty card")
        t.check(!LegacyRenderSelfTests.isEmpty(sample.legacy), "\(name): native frozen rendering has visible pixels")
        let items = leaves(sample.scene.elements.flatMap(\.items))
        t.check(items.contains { if case .text(let draw) = $0 { return !draw.text.isEmpty }; return false },
                "\(name): real resolved text is present")
        t.check(items.contains { if case .image(let draw) = $0 { return draw.path != nil }; return false },
                "\(name): real image recipes are present")
        if name.hasPrefix("System/") {
            t.check(items.contains { item in
                if case .graph(.line(let draw)) = item { return draw.lines.contains { $0.isBound && $0.history.count > 0 } }
                return false
            }, "System's original Line holds actual bound history")
            t.check(items.contains { item in
                if case .graph(.histogram(let draw)) = item { return draw.primary.isBound && draw.primary.history.count > 0 }
                return false
            }, "System's original Histogram holds actual bound history")
        }
        if name.hasPrefix("NowPlaying/") {
            t.check(items.contains { item in
                guard case .image(let draw) = item, let path = draw.path, let mask = draw.maskPath,
                      FileManager.default.fileExists(atPath: mask), let decoded = Images.cachedImage(path) else { return false }
                return decoded.width > 0 && decoded.height > 0 && !LegacyRenderSelfTests.isEmpty(decoded)
            }, "the private fixture cover and original mask decode actual nonempty image data")
        }
    }

    /// Projected meter recipes isolate even identity transforms. Qualification reads their actual leaves; it does
    /// not replace the wrappers supplied to the renderer or turn a masked image into a container recipe.
    private static func leaves(_ items: [DrawItem]) -> [DrawItem] {
        items.flatMap { item -> [DrawItem] in
            switch item {
            case let .transformed(_, children), let .antialias(_, children): return leaves(children)
            case let .container(_, mask, content): return leaves(mask) + leaves(content)
            default: return [item]
            }
        }
    }

    private static func freshSingle(_ sample: Sample, _ context: DrawContext) throws -> CGImage {
        guard let space = sample.legacy.colorSpace else { throw CocoaError(.coderInvalidValue) }
        let builder = try LayerContentBuilder(plan: SinglePartition.plan(in: sample.window), scale: CGFloat(sample.scale),
                                              colorSpace: space, maximumOwnedBitmapBytes: budget)
        var result: Result<[LayerContentBuilder.Content], Error>?
        SkinFrameProducer.withAppearance(sample.appearance) {
            result = Result { try builder.build(sample.scene, context: context, cycle: sample.cycle, glass: sample.glass) }
        }
        guard let contents = try result?.get(), contents.count == 1 else { throw CocoaError(.coderInvalidValue) }
        return contents[0].image
    }

    private static func checkImage(_ actual: CGImage, _ reference: CGImage, _ sample: Sample, _ t: AppTestRunner,
                                   _ message: String) {
        t.equal(actual.width, reference.width)
        t.equal(actual.height, reference.height)
        t.equal(actual.bitsPerComponent, 8)
        t.equal(actual.bitsPerPixel, 32)
        t.equal(actual.alphaInfo, .premultipliedFirst)
        t.equal(actual.bitmapInfo, reference.bitmapInfo)
        t.check(actual.colorSpace.flatMap { a in reference.colorSpace.map { CFEqual(a, $0) } } == true)
        t.check(!LegacyRenderSelfTests.isEmpty(actual), "actual native C pixels are nonempty")
        t.check(LegacyRenderSelfTests.bytesEqual(actual, reference), message)
    }

    private struct Completion {
        let frame: LayerRuntime.Frame
        let reference: CGImage
        let onWorker: Bool
    }

    /// Private, non-Sendable owner capsule. No live virtual Skin or its cache can be reached from this worker.
    private final class Worker {
        let executor: SkinThreadExecutor
        private var runtime: LayerRuntime?
        private var context: DrawContext?

        init(_ executor: SkinThreadExecutor) { self.executor = executor }

        func draw(_ sample: Sample) throws -> Completion {
            guard executor.isCurrent && executor.isOnThread && SkinThreadExecutor.isSkinThread,
                  !Thread.isMainThread, let space = sample.legacy.colorSpace else { throw CocoaError(.coderInvalidValue) }
            if runtime == nil {
                runtime = try LayerRuntime(executor: executor, maximumOwnedBitmapBytes: budget)
                context = DrawContext(fonts: AppFontResolver())
            }
            guard let runtime, let context else { throw CocoaError(.coderInvalidValue) }
            var frame: LayerRuntime.Frame?
            var failure: Error?
            SkinFrameProducer.withAppearance(sample.appearance) {
                do {
                    let rect = try sample.window
                    guard let bitmap = SkinBitmapDrawing.makeContext(1, 1, space) else { throw CocoaError(.coderInvalidValue) }
                    bitmap.translateBy(x: 0, y: 1)
                    bitmap.scaleBy(x: CGFloat(sample.scale), y: -CGFloat(sample.scale))
                    let target = DrawTarget.prepareOwnedBitmap(bitmap, glass: sample.glass)
                    guard target.userToDevice == CGAffineTransform(scaleX: CGFloat(sample.scale), y: CGFloat(sample.scale)) else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    let prepared = ScenePreparer.prepare(sample.scene, context: context, target: target)
                    let update = try runtime.update(prepared, in: rect, scale: CGFloat(sample.scale), colorSpace: space,
                        partition: .candidateComponents, context: context, cycle: sample.cycle, glass: sample.glass)
                    switch update {
                    case .submitted(let completed): frame = completed
                    case .unchanged, .suppressed: throw CocoaError(.coderInvalidValue)
                    }
                } catch { failure = error }
            }
            if let failure { throw failure }
            guard let frame else { throw CocoaError(.coderInvalidValue) }
            return Completion(frame: frame, reference: try freshSingle(sample, context), onWorker: true)
        }

        func rootForMain() throws -> CALayer {
            guard Thread.isMainThread && executor.isCurrent && !executor.isOnThread, let runtime else {
                throw CocoaError(.coderInvalidValue)
            }
            return runtime.root
        }

        func observeGroups(_ sample: Sample,
                           _ frame: LayerRuntime.Frame) throws -> [InkRecord] {
            guard executor.isCurrent && executor.isOnThread, let space = sample.legacy.colorSpace else {
                throw CocoaError(.coderInvalidValue)
            }
            typealias Owner = StationeryLayerContentSelfTests
            typealias Rect = InkBounds.DeviceRect
            var observations: [Owner.InkRecord] = []
            for layer in frame.plan.layers {
                guard case let .group(ids) = layer.content else { continue }
                let items = try ids.flatMap { id -> [DrawItem] in
                    guard let member = sample.scene.topLevelElements.first(where: { $0.id == id }) else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    return sample.scene.drawingItems(for: member)
                }
                let x0 = layer.rect.minX.subtractingReportingOverflow(4), y0 = layer.rect.minY.subtractingReportingOverflow(4)
                let x1 = layer.rect.maxX.addingReportingOverflow(4), y1 = layer.rect.maxY.addingReportingOverflow(4)
                guard !x0.overflow, !y0.overflow, !x1.overflow, !y1.overflow,
                      let canvas = Rect(minX: x0.partialValue, minY: y0.partialValue, maxX: x1.partialValue, maxY: y1.partialValue) else {
                    throw CocoaError(.coderInvalidValue)
                }
                let bytes = try Rasterizer.requiredBytes(width: canvas.width, height: canvas.height)
                guard bytes <= Owner.budget,
                      let bitmap = CGContext(data: nil, width: canvas.width, height: canvas.height, bitsPerComponent: 8,
                        bytesPerRow: canvas.width * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                    throw CocoaError(.coderInvalidValue)
                }
                bitmap.concatenate(CGAffineTransform(a: CGFloat(sample.scale), b: 0, c: 0, d: -CGFloat(sample.scale),
                                                     tx: -CGFloat(canvas.minX), ty: CGFloat(canvas.maxY)))
                bitmap.clip(to: CGRect(x: 0, y: 0, width: sample.scene.size.width, height: sample.scene.size.height))
                let target = DrawTarget.prepareOwnedBitmap(bitmap, glass: sample.glass)
                let context = DrawContext(fonts: AppFontResolver())
                SkinFrameProducer.withAppearance(sample.appearance) {
                    DesksetDraw.DrawExecutor.draw(items, in: bitmap, context: context, cycle: sample.cycle, target: target)
                }
                guard let image = bitmap.makeImage() else { throw CocoaError(.coderInvalidValue) }
                let scan = try InkEscapeObservation.scan(image, in: canvas, candidate: .rectangle(layer.rect),
                    colorSpace: space, maximumPixels: Owner.budget / 4, maximumBytes: Owner.budget)
                guard case let .counted(escaped, _) = scan.outside else { throw CocoaError(.coderInvalidValue) }
                observations.append(Owner.InkRecord(members: ids.map { "\($0.index):\($0.name)" }, rectangle: Owner.rectangle(layer.rect),
                                                   alphaPixels: scan.alphaPixels, escapedPixels: escaped, edgePixels: scan.edgePixels))
            }
            return observations
        }

        func close() throws -> Bool {
            guard executor.isCurrent && executor.isOnThread && !Thread.isMainThread else { throw CocoaError(.coderInvalidValue) }
            try runtime?.beginClose()
            try runtime?.close()
            let cleared = runtime == nil || runtime?.state == .closed && runtime?.currentFrame == nil &&
                (runtime?.root.sublayers ?? []).isEmpty
            runtime = nil
            context = nil
            return cleared
        }
    }

    private static var retainedFailures: [(Worker, CALayer?)] = []

    private static func compareWorker(_ samples: [Sample], _ name: String, _ device: any MTLDevice,
                                      _ t: AppTestRunner) throws {
        guard let first = samples.first else { throw CocoaError(.coderInvalidValue) }
        let executor = SkinThreadExecutor(name: "Stationery C fixture \(name) \(first.scale)x")
        let worker = Worker(executor)
        var host: CALayer?
        defer {
            var drained = false, detached = false
            do {
                drained = try onWorker(executor, t) { try worker.close() } == true
                t.check(drained, "actual worker cleanup completes before main detaches")
                if drained {
                    // Owner is closed and no longer updates; the previous successful lease established the host.
                    for child in host?.sublayers ?? [] { child.removeFromSuperlayer() }
                    detached = host == nil || (host?.sublayers ?? []).isEmpty
                    t.check(detached)
                }
            } catch { t.check(false, "worker cleanup failed: \(error)") }
            executor.stop()
            let exited = AppSelfTest.spin(timeout: 30) { executor.hasExited }
            t.check(exited, "the physical worker stops only after queued owner cleanup")
            if !drained || !detached || !exited { retainedFailures.append((worker, host)) }
        }
        let window = try first.window
        let bytes = try Rasterizer.requiredBytes(width: window.width, height: window.height)
        let renderer = try OffscreenRenderer(width: window.width, height: window.height, device: device,
                                             maximumReadbackBytes: bytes)
        let bIndex = name.hasPrefix("Clock/") ? 2 : 1
        let replay = [samples[0], samples[bIndex], samples[0]]
        var replayPixels: [[UInt8]] = []
        for (index, sample) in (samples + replay).enumerated() {
            guard let completed = try onWorker(executor, t, { try worker.draw(sample) }) else { return }
            t.check(completed.onWorker)
            t.equal(completed.frame.sequence, UInt64(index + 1))
            t.equal(completed.frame.plan, SinglePartition.plan(in: try sample.window), "real unknown ink selects literal Single")
            if case .some(.unresolvedInk(_, .unresolvedRasterization)) = completed.frame.fallback { t.check(true) }
            else { t.check(false, "text/mask unknown must retain its actual unresolved cause") }
            t.check(completed.frame.contents.count == 1)
            guard let space = sample.legacy.colorSpace else { throw CocoaError(.coderInvalidValue) }
            t.check(completed.frame.contents.allSatisfy { $0.image.colorSpace.map { CFEqual($0, space) } == true })
            let result = executor.exclusive(timeout: 30) { Result<[UInt8], Error> {
                t.check(Thread.isMainThread && executor.isCurrent && !executor.isOnThread && !SkinThreadExecutor.isSkinThread)
                let root = try worker.rootForMain()
                if host == nil { host = hostTree(root, sample) }
                guard let host else { throw CocoaError(.coderInvalidValue) }
                t.check(root.superlayer === host, "main observes the actual owner tree, not a manufactured candidate")
                let actual = try renderer.render(host, at: 0, deadline: .now() + .seconds(30))
                let expected = try renderer.render(imageTree(completed.reference, sample), at: 0, deadline: .now() + .seconds(30))
                let frozen = try renderer.render(imageTree(sample.legacy, sample), at: 0, deadline: .now() + .seconds(30))
                t.check(stride(from: 3, to: actual.rgba.count, by: 4).contains { actual.rgba[$0] > 0 })
                t.equal(actual.rgba, expected.rgba, "\(name): incremental worker C / independently built fresh Single strict RGBA")
                t.equal(expected.rgba, frozen.rgba, "\(name): independently rendered frozen legacy / fresh Single strict RGBA")
                return actual.rgba
            } }
            t.check(result != nil, "the physical worker actually grants main a bounded owner lease")
            guard let result else { return }
            let pixels = try result.get()
            if index >= samples.count { replayPixels.append(pixels) }
        }
        t.equal(replayPixels.count, 3)
        if replayPixels.count == 3 {
            t.check(replayPixels[0] != replayPixels[1], "B is an actually visible default state, not an empty positive control")
            t.equal(replayPixels[0], replayPixels[2], "A returns strictly after B in the same actual worker runtime")
        }
        t.check(renderer.hasVerifiedCanary, "all readbacks use the unchanged native canary and completion fence")
    }

    private static func onWorker<Value>(_ executor: SkinThreadExecutor, _ t: AppTestRunner,
                                        _ work: @escaping () throws -> Value) throws -> Value? {
        let result = Guarded<Result<Value, Error>?>(nil)
        executor.async {
            let completed = Result(catching: work)
            result.access { $0 = completed }
        }
        let completed = AppSelfTest.spin(timeout: 30) { result.current != nil }
        t.check(completed, "physical worker completion arrives before its result is observed")
        guard let result = result.current else { return nil }
        return try result.get()
    }

    private static func hostTree(_ root: CALayer, _ sample: Sample) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let host = CALayer()
        host.anchorPoint = .zero
        host.isGeometryFlipped = true
        host.contentsFormat = .RGBA8Uint
        host.bounds = CGRect(x: 0, y: 0, width: sample.legacy.width, height: sample.legacy.height)
        root.setAffineTransform(CGAffineTransform(scaleX: CGFloat(sample.scale), y: CGFloat(sample.scale)))
        host.addSublayer(root)
        return host
    }

    private static func imageTree(_ image: CGImage, _ sample: Sample) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let root = CALayer(), layer = CALayer()
        root.anchorPoint = .zero
        root.bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        root.isGeometryFlipped = true
        root.contentsFormat = .RGBA8Uint
        layer.anchorPoint = .zero
        layer.frame = root.bounds
        layer.contentsFormat = .RGBA8Uint
        layer.contents = image
        layer.contentsScale = CGFloat(sample.scale)
        layer.contentsGravity = .resize
        layer.minificationFilter = .nearest
        layer.magnificationFilter = .nearest
        root.addSublayer(layer)
        return root
    }

    private static let uncoveredNames = [
        "Almanac/Almanac.ini", "AnalogClock/Small.ini", "Battery/Medium.ini", "Battery/Small.ini",
        "Calendar/Medium.ini", "Calendar/Small.ini", "Chronograph/Large.ini", "Clock/Medium.ini",
        "Countdown/Small.ini", "Daybreak/Daybreak.ini", "Launcher/Medium.ini", "Launcher/Small.ini",
        "Network/Medium.ini", "Network/Small.ini", "NowPlaying/Small.ini", "Photos/Large.ini",
        "Photos/Medium.ini", "Photos/Small.ini", "SentenceClock/Large.ini", "Spectrum/Medium.ini",
        "Spectrum/Strip.ini", "Storage/Large.ini", "Storage/Medium.ini", "Storage/Small.ini",
        "StudioVU/Medium.ini", "System/Medium.ini", "System/Small.ini", "Temperature/Medium.ini",
        "Temperature/Small.ini", "Timer/Small.ini", "ToDo/Large.ini", "ToDo/Medium.ini", "ToDo/Small.ini",
        "Turntable/Large.ini", "Weather/Large.ini", "Weather/Medium.ini", "Weather/Small.ini",
        "WorldClock/Medium.ini", "WorldClock/Small.ini"
    ]

    private enum QualificationFailure: Error { case invalid(String), incomplete(String) }

    private struct Asset: Encodable { let path: String; let sha256: String }
    private struct DirectoryBinding: Encodable {
        let original: String
        let sandbox: String
        let children: [String]
    }
    private struct PreparedInputs: Encodable {
        var directories: [DirectoryBinding] = []
        var operatingSystemImages: [Asset] = []
        var diskSource: String?
        var diskAlias: String?
        var archiveTotal: Double?
        var archiveFree: Double?
        var rootTotal: Double?
    }
    private struct Difference: Encodable {
        let changedPixels: Int
        let maxChannelDifference: Int
        let first: [Int]?
        init(_ value: PixelComparison.Difference) {
            changedPixels = value.changedPixels
            maxChannelDifference = value.maxChannelDifference
            first = value.firstDifference.map { [$0.x, $0.y, $0.channel, Int($0.expected), Int($0.actual)] }
        }
    }
    private struct LayerRecord: Encodable {
        let role: String
        let members: [String]
        let rectangle: [Int]
    }
    private struct InkRecord: Encodable {
        let members: [String]
        let rectangle: [Int]
        let alphaPixels: Int
        let escapedPixels: Int
        let edgePixels: Int
    }
    private struct QualifiedFrame: Encodable {
        let label: String
        let seconds: Double
        let wallClock: Double
        let updateCount: Int
        let counter: Int
        let dataAdvances: Int
        let systemFrame: Int
        let outstandingAtCapture: Int
        let sequence: UInt64
        let fallback: String?
        let firstUnknown: String?
        let layers: [LayerRecord]
        let singleVsCandidate: Difference
        let freshVsIncremental: Difference
        let frozenVsSingle: Difference
        let nativeCanary: Bool
        let hasPixels: Bool
        let resourcesStable: Bool
        let pendingImages: [String]
        let ink: [InkRecord]
        let rgbaSHA256: String
        let validationFailures: [String]
    }
    private struct QualificationReport: Encodable {
        let destinationScope = "independent-fixed-appearance-and-scale-timeline"
        let skin: String
        let sourceSHA256: String
        let dataSHA256: String
        let scale: Int
        let appearance: String
        let initialContent: String
        let requestedPartition = "candidateComponents"
        let timeline = "firstImmediate at count 1/time 0; real Update intervals through 60 seconds; separately labelled forced updates only when fewer than five actual updates occurred"
        var preparation = PreparedInputs()
        var frames: [QualifiedFrame] = []
        var issues: [String] = []
        var missing: [String] = []
        var errors: [String] = []
        var status = "incomplete"
    }

    private static func uncoveredTests(_ t: AppTestRunner) {
        for name in uncoveredNames {
            t.suite("Runtime: Stationery G2 uncovered: \(name)") { try qualifyUncovered(name, t) }
        }
        // The original C-content suites sample these three skins after two updates. These entries qualify their first
        // eligible update and the complete fixed-destination timeline using the same strict native contract.
        for name in names {
            t.suite("Runtime: Stationery G2 first update: \(name)") { try qualifyUncovered(name, t) }
        }
    }

    private static func qualifyUncovered(_ name: String, _ t: AppTestRunner) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return t.check(false, "Metal unavailable: default qualification did not run")
        }
        let skins = try copiedSkins(t, "stationery-g2"), source = skins.appendingPathComponent("Stationery/" + name)
        let data = skins.appendingPathComponent("Runtime/Data/mac.json")
        guard let shipped = Paths.repositoryFolder("DefaultSkins")?.appendingPathComponent("Stationery") else {
            throw QualificationFailure.invalid("DefaultSkins source unavailable")
        }
        var actualNames: [String] = []
        let folders = try FileManager.default.contentsOfDirectory(at: shipped, includingPropertiesForKeys: nil)
        for folder in folders where !folder.lastPathComponent.hasPrefix("@") {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension.lowercased() == "ini" {
                actualNames.append(folder.lastPathComponent + "/" + file.lastPathComponent)
            }
        }
        actualNames.sort()
        t.equal(actualNames, (names + uncoveredNames).sorted(), "the native entry accounts for every shipped INI exactly once")
        t.equal(try Data(contentsOf: source), try Data(contentsOf: shipped.appendingPathComponent(name)),
                "the uncovered INI is copied without changing its original options")
        // These reports intentionally outlive AppTestRunner's disposable fake inputs.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("StationeryG2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("Stationery G2 report: \(output.path)")
        let saved = NSApp.appearance
        defer { NSApp.appearance = saved; MacAppearance.current.refresh(); DesktopInputs.appearance.refresh() }
        for dark in [false, true] {
            RenderCommand.applyAppearance(dark ? .dark : .light)
            // Each fixed destination replays its own Skin and drawing-cache lifetime. The entire first/settled/
            // later-update sequence stays on that destination, just as its candidate worker does. Cross-scale
            // context histories are separate from the independent 1x/2x qualification reported here.
            for scale in [1, 2] {
                Images.purge(); LegacyImages.purge()
                let sourceHash = digest(try Data(contentsOf: source)), dataHash = digest(try Data(contentsOf: data))
                var reports = [scale].map { QualificationReport(skin: name,
                    sourceSHA256: sourceHash, dataSHA256: dataHash,
                    scale: $0, appearance: dark ? "dark" : "light",
                    initialContent: name.hasPrefix("Photos/") ? "original-empty-photo-folder" : "original-defaults") }
                func saveReports() throws {
                    for report in reports { try writeReport(report, to: output.appendingPathComponent("\(report.scale)x-\(report.appearance).json")) }
                }
                let failuresAtStart = t.failures.count
                let sessions = [scale].map { QualificationSession(name: name, scale: $0, device: device) }
                var sessionsClosed = false
                defer { if !sessionsClosed { for session in sessions { session.close(t) } } }
                do {
                    let checked = try LegacyRenderSelfTests.withInputs(source, skinsDir: skins.path, data: data,
                        prepare: { skin, recording, virtual in
                            let prepared = try prepareUncovered(name, skin, recording, virtual, data, t)
                            for i in reports.indices { reports[i].preparation = prepared }
                            try saveReports()
                        }, driveUpdates: { skin, _, virtual, inputs in
                            guard let system = skin.system as? ScriptedSystemData else {
                                throw QualificationFailure.invalid("A scripted system is required")
                            }
                            t.check(virtual.isCurrent && skin.executor === virtual && !skin.skinClock.isLive)
                            t.check(skin.updateCount == 0 && skin.counter == 0 && virtual.now == 0 && system.frameIndex == 0,
                                    "load and fake installation precede the first eligible update")
                            guard skin.updateCount == 0, skin.counter == 0, virtual.now == 0, system.frameIndex == 0 else {
                                throw QualificationFailure.invalid("Load already consumed the first update")
                            }
                            let projectors = [SceneProjector()]
                            var advances = 0
                            func sample(_ label: String) throws {
                                try checkDiskAlias(reports[0].preparation, system, t)
                                for i in sessions.indices {
                                    let sampled = try capture(skin, projectors[i], sessions[i].scale, dark, .placeholder(dark: dark))
                                    let frame = try sessions[i].compare(sampled, label: label, seconds: virtual.now,
                                        wallClock: virtual.wallClock.timeIntervalSince1970, counter: skin.counter,
                                        advances: advances, systemFrame: system.frameIndex,
                                        outstanding: virtual.background.outstanding, t: t,
                                        output: output.appendingPathComponent("\(sampled.scale)x-\(dark ? "dark" : "light")-\(label)"))
                                    reports[i].frames.append(frame)
                                    try saveReports()
                                    guard frame.singleVsCandidate.changedPixels == 0, frame.freshVsIncremental.changedPixels == 0,
                                          frame.frozenVsSingle.changedPixels == 0, frame.resourcesStable,
                                          frame.nativeCanary, frame.hasPixels, frame.validationFailures.isEmpty,
                                          frame.ink.allSatisfy({ $0.escapedPixels == 0 }) else {
                                        throw QualificationFailure.incomplete("Strict native comparison failed at \(label)")
                                    }
                                }
                            }
                            skin.update()
                            t.check(skin.updateCount == 1 && skin.counter == 1 && virtual.now == 0 && advances == 0 && system.frameIndex == 0,
                                    "firstImmediate is the first completed update with payload frame zero, before any time advance")
                            guard skin.updateCount == 1, skin.counter == 1, virtual.now == 0, advances == 0 else {
                                throw QualificationFailure.invalid("The first explicit update reentered a whole update")
                            }
                            try sample("firstImmediate")
                            RenderCommand.step(virtual, until: 0, deadline: Date().addingTimeInterval(5))
                            t.equal(virtual.background.outstanding, 0, "first-update jobs must settle; a pending image is not silently covered")
                            try sample("firstSettled")
                            var tick = 0
                            while let interval = TickScheduler.updateInterval(skin.settings.update) {
                                let next = virtual.now + interval
                                guard next.isFinite, next > virtual.now else {
                                    throw QualificationFailure.invalid("Nonprogressing update interval")
                                }
                                if next > 60 { break }
                                RenderCommand.step(virtual, until: next, deadline: Date().addingTimeInterval(5))
                                inputs.advance(); advances += 1; skin.update(); tick += 1
                                RenderCommand.step(virtual, until: virtual.now, deadline: Date().addingTimeInterval(5))
                                if tick <= 4 { try sample("update\(skin.updateCount)") }
                            }
                            RenderCommand.step(virtual, until: 60, deadline: Date().addingTimeInterval(5))
                            t.equal(virtual.now, 60, "the terminal sample is at sixty virtual seconds")
                            try sample("sixtySeconds")
                            // Update=-1 and 60000 retain their real cadence above. Extra explicit updates are
                            // reported separately; they are not called automatic ticks or first/60s samples.
                            while skin.updateCount < 5 {
                                inputs.advance(); advances += 1; skin.update()
                                RenderCommand.step(virtual, until: virtual.now, deadline: Date().addingTimeInterval(5))
                                try sample("forcedUpdate\(skin.updateCount)")
                            }
                            t.check(skin.updateCount >= 5)
                            t.equal(virtual.background.outstanding, 0)
                            t.equal(virtual.background.unverifiable.count, 0)
                        }) { skin, _, _ -> [String] in
                            for i in reports.indices { reports[i].issues = skin.issues }
                            if name.hasPrefix("Photos/") {
                                t.equal(skin.variable("PhotoFolder"), "", "the original empty-photo-folder state was retained")
                            }
                            let pending = Set(reports.flatMap(\.frames).flatMap(\.pendingImages))
                            return pending.filter { Images.size(atPath: $0) == nil }.sorted().map { "Image: unavailable \($0)" }
                        }
                    for session in sessions { session.close(t) }; sessionsClosed = true
                    for i in reports.indices {
                        reports[i].errors += Array(t.failures.dropFirst(failuresAtStart))
                        reports[i].missing = Array(Set(checked.missing + checked.value)).sorted()
                        reports[i].status = !reports[i].errors.isEmpty ? "notQualified" : reports[i].missing.isEmpty
                            ? (reports[i].frames.contains { $0.fallback != nil } ? "verifiedSingleFallback" : "verifiedComponents") : "inputMissing"
                    }
                    try saveReports()
                    t.check(checked.missing.isEmpty && checked.value.isEmpty, "every observed input is private, provided and settled: \(checked.missing + checked.value)")
                    if !checked.missing.isEmpty || !checked.value.isEmpty || t.failures.count != failuresAtStart {
                        throw QualificationFailure.incomplete("Observed inputs are incomplete")
                    }
                } catch {
                    for i in reports.indices { reports[i].errors.append(String(describing: error)); reports[i].status = "notQualified" }
                    try saveReports()
                    throw error
                }
            }
        }
    }

    private static func prepareUncovered(_ name: String, _ skin: Skin, _ recording: RecordingSideEffects,
                                 _ virtual: VirtualTimeExecutor, _ dataURL: URL, _ t: AppTestRunner) throws -> PreparedInputs {
        guard skin.measures.isEmpty, skin.updateCount == 0, skin.sourceProvider === recording,
              !virtual.background.allowsUnfakedWork else { throw QualificationFailure.invalid("Preparation occurred after load") }
        var result = PreparedInputs()
        func directory(_ original: String, children: [String]) throws -> String {
            let folder = recording.files.path(for: original, access: .write)
            guard folder != original, recording.files.contains(folder), skin.readablePath(original) == folder else {
                throw QualificationFailure.invalid("A fake directory escaped the recording")
            }
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            for child in children {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: folder).appendingPathComponent(child), withIntermediateDirectories: true)
            }
            result.directories.append(DirectoryBinding(original: original, sandbox: folder, children: children))
            return folder
        }
        if name.hasPrefix("NowPlaying/") {
            _ = try directory("/System/Applications/", children: ["Music.app"])
            _ = try directory("/Applications/", children: ["Spotify.app"])
        } else if name.hasPrefix("Launcher/") {
            _ = try directory("/System/Applications/Utilities/", children: ["Screenshot.app"])
            _ = try directory(NSHomeDirectory() + "/", children: ["Documents", "Downloads"])
            _ = try directory("/System/Library/CoreServices/Finder.app/Contents/Applications/", children: ["AirDrop.app"])
            _ = try directory("/System/Applications/", children: ["Shortcuts.app"])
            if name == "Launcher/Medium.ini" {
                for file in ["TrashIcon.icns", "FullTrashIcon.icns"] {
                    let path = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/" + file
                    guard Images.size(atPath: path) != nil else { throw QualificationFailure.incomplete("Missing original OS image: \(path)") }
                    result.operatingSystemImages.append(Asset(path: path, sha256: digest(try Data(contentsOf: URL(fileURLWithPath: path)))))
                }
            }
        } else if name.hasPrefix("Storage/") {
            let folder = try directory("/Volumes/", children: ["Archive"])
            let alias = URL(fileURLWithPath: folder).appendingPathComponent("Archive").path
            var data = try SkinInputData.load(dataURL.path, directory: dataURL.deletingLastPathComponent())
            guard var frames = data.system, let first = frames.first, let disk = first.disks?["/Volumes/Archive"],
                  let rootDisk = first.disks?["/"], let system = skin.system as? ScriptedSystemData else {
                throw QualificationFailure.invalid("The original system fixture has no Archive/root disk")
            }
            for index in frames.indices {
                if let original = frames[index].disks?["/Volumes/Archive"] { frames[index].disks?[alias] = original }
            }
            data.system = frames; system.apply(data)
            result.diskSource = "/Volumes/Archive"; result.diskAlias = alias
            result.archiveTotal = disk.total; result.archiveFree = disk.free; result.rootTotal = rootDisk.total
        }
        if !result.directories.isEmpty { virtual.background.setFake(.service, for: .fileViewListing) }
        t.check(result.directories.allSatisfy { recording.files.contains($0.sandbox) && skin.readablePath($0.original) == $0.sandbox })
        return result
    }

    private static func checkDiskAlias(_ prepared: PreparedInputs, _ system: ScriptedSystemData, _ t: AppTestRunner) throws {
        guard let alias = prepared.diskAlias else { return }
        let archive = system.diskSpace(path: alias), root = system.diskSpace(path: "/")
        t.equal(archive?.total, prepared.archiveTotal, "data.advance preserves the same Archive value at its private alias")
        t.equal(archive?.free, prepared.archiveFree)
        t.equal(root?.total, prepared.rootTotal, "a private Archive alias cannot replace the original root disk")
        guard archive?.total == prepared.archiveTotal, archive?.free == prepared.archiveFree,
              root?.total == prepared.rootTotal else { throw QualificationFailure.invalid("The disk alias lost its fixture identity") }
    }

    private final class QualificationSession {
        let scale: Int
        private let device: any MTLDevice
        private let executor: SkinThreadExecutor
        private let worker: Worker
        private var host: CALayer?
        private var renderer: OffscreenRenderer?
        private var dimensions: Rect?
        private var omissionChecked = false

        init(name: String, scale: Int, device: any MTLDevice) {
            self.scale = scale; self.device = device
            executor = SkinThreadExecutor(name: "Stationery G2 \(name) \(scale)x")
            worker = Worker(executor)
        }

        func compare(_ sample: Sample, label: String, seconds: Double, wallClock: Double, counter: Int,
                     advances: Int, systemFrame: Int, outstanding: Int, t: AppTestRunner, output: URL) throws -> QualifiedFrame {
            let failuresAtStart = t.failures.count
            let window = try sample.window
            if dimensions != window {
                let bytes = try Rasterizer.requiredBytes(width: window.width, height: window.height)
                guard bytes <= budget else { throw QualificationFailure.incomplete("Readback exceeds unchanged 16 MiB test budget") }
                renderer = try OffscreenRenderer(width: window.width, height: window.height, device: device, maximumReadbackBytes: bytes)
                dimensions = window
            }
            guard let renderer else { throw QualificationFailure.invalid("No renderer") }
            let cold = Worker(executor)
            var coldHost: CALayer?
            defer {
                do {
                    let cleared = try onWorker(executor, t) { try cold.close() } == true
                    t.check(cleared)
                    if cleared { for layer in coldHost?.sublayers ?? [] { layer.removeFromSuperlayer() } }
                    else { retainedFailures.append((cold, coldHost)) }
                } catch { t.check(false, "cold candidate cleanup: \(error)"); retainedFailures.append((cold, coldHost)) }
            }
            guard let actual = try onWorker(executor, t, { try self.worker.draw(sample) }),
                  let fresh = try onWorker(executor, t, { try cold.draw(sample) }) else {
                throw QualificationFailure.incomplete("A physical owner did not return its candidate")
            }
            let independent = try freshSingle(sample, DrawContext(fonts: AppFontResolver()))
            checkImage(independent, sample.legacy, sample, t, "uncovered default: independent Single / Frozen active BGRA strict")
            let resources = activeDependencies(sample.scene)
            let pending = resources.filter { Images.size(atPath: $0.path) == nil }.map(\.path)
            let result = executor.exclusive(timeout: 30) { Result<([UInt8], [UInt8], [UInt8], [UInt8]), Error> {
                let root = try self.worker.rootForMain()
                if self.host == nil { self.host = hostTree(root, sample) }
                guard let host = self.host else { throw QualificationFailure.invalid("Missing candidate host") }
                host.bounds = CGRect(x: 0, y: 0, width: sample.legacy.width, height: sample.legacy.height)
                coldHost = hostTree(try cold.rootForMain(), sample)
                guard let coldHost else { throw QualificationFailure.invalid("Missing cold candidate host") }
                let a = try renderer.render(host, at: 0, deadline: .now() + .seconds(30))
                let b = try renderer.render(coldHost, at: 0, deadline: .now() + .seconds(30))
                let c = try renderer.render(imageTree(independent, sample), at: 0, deadline: .now() + .seconds(30))
                let d = try renderer.render(imageTree(sample.legacy, sample), at: 0, deadline: .now() + .seconds(30))
                if !self.omissionChecked {
                    // A negative control of this actual borrowed tree, not another reference built from it.
                    let opacity = root.opacity
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    root.opacity = 0
                    CATransaction.commit()
                    defer {
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        root.opacity = opacity
                        CATransaction.commit()
                    }
                    let omitted = try renderer.render(host, at: 0, deadline: .now() + .seconds(30))
                    t.check(omitted.rgba != a.rgba, "omitting the real candidate's content changes the native pixels")
                    t.check(stride(from: 3, to: omitted.rgba.count, by: 4).allSatisfy { omitted.rgba[$0] == 0 })
                    self.omissionChecked = true
                }
                return (a.rgba, b.rgba, c.rgba, d.rgba)
            } }
            guard let result else { throw QualificationFailure.incomplete("No exclusive native readback lease") }
            let (rgba, coldRGBA, singleRGBA, frozenRGBA) = try result.get()
            let single = try PixelComparison.compare(reference: singleRGBA, candidate: rgba, width: window.width, height: window.height)
            let incremental = try PixelComparison.compare(reference: coldRGBA, candidate: rgba, width: window.width, height: window.height)
            let legacy = try PixelComparison.compare(reference: frozenRGBA, candidate: singleRGBA, width: window.width, height: window.height)
            let visible = stride(from: 3, to: rgba.count, by: 4).contains { rgba[$0] > 0 }
            let environment = AppSceneEnvironment(scale: Double(scale), appearance: sample.dark ? .dark : .light, appearanceName: sample.appearance)
            let stable = resources.allSatisfy { $0.stamp == environment.imageStamp($0.path) }
            t.check(actual.onWorker && fresh.onWorker)
            t.equal(fresh.frame.sequence, 1, "each cold candidate has an independent runtime and context")
            t.check(renderer.hasVerifiedCanary && visible, "real native canary and nonempty pixels are required")
            t.check(single.isExact, "Single/candidate strict: \(single.changedPixels) pixels, max \(single.maxChannelDifference)")
            t.check(incremental.isExact, "cold candidate/incremental strict: \(incremental.changedPixels) pixels")
            t.check(legacy.isExact, "Frozen/Single strict: \(legacy.changedPixels) pixels")
            t.check(stable, "the image resources did not change between projection and all four native paths")
            if !single.isExact || !incremental.isExact || !legacy.isExact || !stable {
                for (suffix, bytes) in [("candidate", rgba), ("fresh", coldRGBA), ("single", singleRGBA), ("frozen", frozenRGBA)] {
                    try Data(bytes).write(to: output.appendingPathExtension(suffix + ".rgba"))
                }
            }
            guard let ink = try onWorker(executor, t, { try self.worker.observeGroups(sample, actual.frame) }) else {
                throw QualificationFailure.incomplete("Ink observation did not return")
            }
            for group in ink { t.equal(group.escapedPixels, 0, "actual foreground group ink remains in its rectangle") }
            let fallback: String?, unknown: String?
            switch actual.frame.fallback {
            case nil: fallback = nil; unknown = nil
            case let .unresolvedInk(id, reason): fallback = "unresolvedInk: \(reason)"; unknown = "\(id.index):\(id.name)"
            case let .elementCountExceeded(actual, limit): fallback = "elementCountExceeded: \(actual)/\(limit)"; unknown = nil
            case let .localizedAntialiasedLine(group): fallback = "localizedAntialiasedLine: \(group)"; unknown = nil
            case let .localizedAntialiasedFullCircle(group): fallback = "localizedAntialiasedFullCircle: \(group)"; unknown = nil
            }
            let layers = actual.frame.plan.layers.map { layer -> LayerRecord in
                let role: String, members: [String]
                switch layer.content {
                case .fullScene: role = "single"; members = []
                case .baseSlice: role = "baseSlice"; members = []
                case let .group(ids): role = "group"; members = ids.map { "\($0.index):\($0.name)" }
                }
                return LayerRecord(role: role, members: members, rectangle: rectangle(layer.rect))
            }
            return QualifiedFrame(label: label, seconds: seconds, wallClock: wallClock, updateCount: sample.cycle,
                counter: counter, dataAdvances: advances, systemFrame: systemFrame, outstandingAtCapture: outstanding,
                sequence: actual.frame.sequence, fallback: fallback, firstUnknown: unknown, layers: layers,
                singleVsCandidate: Difference(single), freshVsIncremental: Difference(incremental), frozenVsSingle: Difference(legacy),
                nativeCanary: renderer.hasVerifiedCanary, hasPixels: visible, resourcesStable: stable,
                pendingImages: pending, ink: ink, rgbaSHA256: digest(Data(rgba)),
                validationFailures: Array(t.failures.dropFirst(failuresAtStart)))
        }

        func close(_ t: AppTestRunner) {
            var cleared = false
            do { cleared = try onWorker(executor, t) { try self.worker.close() } == true }
            catch { t.check(false, "candidate owner cleanup: \(error)") }
            t.check(cleared)
            if cleared { for layer in host?.sublayers ?? [] { layer.removeFromSuperlayer() } }
            executor.stop()
            let exited = AppSelfTest.spin(timeout: 30) { self.executor.hasExited }
            t.check(exited, "the qualification owner has stopped")
            if !cleared || !exited { retainedFailures.append((worker, host)) }
        }
    }

    private static func activeDependencies(_ scene: WidgetScene) -> [ImageDependency] {
        var result = scene.backgroundImageDependencies
        for element in scene.topLevelElements where !scene.drawingItems(for: element).isEmpty {
            result += element.imageDependencies
            if element.isContainer {
                result += scene.elements.filter { $0.container == element.id && $0.visibility == .visible }.flatMap(\.imageDependencies)
            }
        }
        return result
    }
    private static func rectangle(_ rect: Rect) -> [Int] { [rect.minX, rect.minY, rect.maxX, rect.maxY] }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func writeReport<Value: Encodable>(_ value: Value, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: file, options: .atomic)
    }
}

#endif
