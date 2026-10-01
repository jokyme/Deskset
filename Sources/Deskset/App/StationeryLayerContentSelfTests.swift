#if DEBUG
import AppKit
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
}
#endif
