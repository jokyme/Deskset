import AppKit
import CryptoKit
import Darwin
import DesksetCore
import DesksetDraw
import DesksetRuntime
import Metal

/// Local measurements only, selected by one exact self-test name. A normal self-test run never enters here.
/// These two fixed, idle-pixel recipes are not the ten-window, screen-arrival or WindowServer acceptance gates.
enum LayerPerformanceMeasurements {
    private enum Recipe: String, CaseIterable { case clock, design }
    private enum Backend: String, CaseIterable { case bitmap, c, e }
    // Explicit fixture budgets, not new product limits or a total process/CA-memory cap.
    private static let bitmapBudget = 16 * 1024 * 1024
    private static let warmSeconds: TimeInterval = 20
    private static let observationSeconds: TimeInterval = 10
    private static let fixedDate = Date(timeIntervalSince1970: 1_790_417_340)

    /// No substring/prefix opt-in: even the ordinary "App:" or "layer" filters do not run a measurement.
    @discardableResult
    static func runIfRequested(_ t: AppTestRunner, filter: String?) -> Bool {
        guard let filter else { return false }
        for recipe in Recipe.allCases {
            for backend in Backend.allCases {
                let name = "App: layer performance: \(recipe.rawValue) \(backend.rawValue)"
                if filter.lowercased() == name.lowercased() {
                    t.suite(name) { measure(t, recipe, backend) }
                    return true
                }
            }
        }
        return false
    }

    private enum Unavailable: Error {
        case qualification(String)
        case systemCall(String, status: Int32, errno: Int32)
    }

    private struct Usage: Codable {
        let wall: Double
        let userTimeRaw: UInt64
        let systemTimeRaw: UInt64
        let userCPUSeconds: Double
        let systemCPUSeconds: Double
        let interruptWakeups: UInt64
        let packageIdleWakeups: UInt64
        let residentBytes: UInt64
        let physicalFootprintBytes: UInt64
        let instructions: UInt64
        let cycles: UInt64
        let processStart: UInt64

        static func read() throws -> Usage {
            var usage = rusage_info_v6()
            let status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
                }
            }
            let error = errno
            guard status == 0 else { throw Unavailable.systemCall("proc_pid_rusage(v6)", status: status, errno: error) }
            var cpu = rusage()
            let cpuStatus = getrusage(RUSAGE_SELF, &cpu)
            let cpuError = errno
            guard cpuStatus == 0 else { throw Unavailable.systemCall("getrusage(self)", status: cpuStatus, errno: cpuError) }
            let userSeconds = Double(cpu.ru_utime.tv_sec) + Double(cpu.ru_utime.tv_usec) / 1_000_000
            let systemSeconds = Double(cpu.ru_stime.tv_sec) + Double(cpu.ru_stime.tv_usec) / 1_000_000
            guard userSeconds.isFinite, systemSeconds.isFinite, userSeconds >= 0, systemSeconds >= 0 else {
                throw Unavailable.qualification("getrusage CPU times are not finite nonnegative seconds")
            }
            // Keep libproc time counters raw. CPU seconds come from the existing benchmark's timeval interface,
            // with an explicit success guard rather than assuming the ri_*_time fields' unit.
            return Usage(wall: ProcessInfo.processInfo.systemUptime, userTimeRaw: usage.ri_user_time,
                systemTimeRaw: usage.ri_system_time, userCPUSeconds: userSeconds, systemCPUSeconds: systemSeconds,
                interruptWakeups: usage.ri_interrupt_wkups,
                packageIdleWakeups: usage.ri_pkg_idle_wkups, residentBytes: usage.ri_resident_size,
                physicalFootprintBytes: usage.ri_phys_footprint, instructions: usage.ri_instructions,
                cycles: usage.ri_cycles, processStart: usage.ri_proc_start_abstime)
        }
    }

    private struct OwnerSample: Codable {
        let updates: Int
        let framesDrawn: Int
        let framesSkipped: Int
        let frameWorkWallSeconds: Double
        let commits: Int
        let keptRuns: Int
        let layerSequence: UInt64?
        let nativeSequence: UInt64?
        let layers: Int
        let plan: [String]
        let fallback: String?
        let frozenCWriter: Bool
        let callbacks: [Int]
        let nativeDestinations: [String]
        let actualPhysicalOwner: Bool
    }

    private struct WindowSample: Codable {
        let orderedIn: Bool
        let actualOcclusion: UInt
        let unoccluded: Bool
        let activeSpace: Bool
        let appActive: Bool
        let panelGeneration: UInt64
        let widthPoints: Double
        let heightPoints: Double
        let scale: Double
        let profileSHA256: String?
        let profileName: String?
        let appearance: String
    }

    private struct Report: Codable {
        let recipe: String
        let requestedBackend: String
        let pid: Int32
        let executable: String
        let os: String
        let warmRequestedSeconds: Double
        let observationRequestedSeconds: Double
        let ownedBitmapBudget: Int?
        let callbackBitmapBudget: Int?
        let qualificationReadbackBudget: Int
        let referenceBitmapBudget: Int
        var status = "unavailable"
        var reason: String?
        var inputSHA256: String?
        var setupReadyWallSeconds: Double?
        var warmActualSeconds: Double?
        var emptyAppUsage: Usage?
        var warmUsage: Usage?
        var before: Usage?
        var after: Usage?
        var closedUsage: Usage?
        var ownerBefore: OwnerSample?
        var ownerAfter: OwnerSample?
        var windowBefore: WindowSample?
        var windowAfter: WindowSample?
        var processSingleCorePercent: Double?
        var interruptWakeupsPerSecond: Double?
        var packageIdleWakeupsPerSecond: Double?
        var pixelSHA256Before: String?
        var pixelSHA256After: String?
        var pixelComparisonBefore: String?
        var pixelComparisonAfter: String?
        var cleanupClosed: Bool?
        var cleanupDetached: Bool?
        var cleanupWorkerExited: Bool?
        // ri_phys_footprint is not footprint --vmObjectDirty, WindowServer memory, or unique CA buffer bytes.
        let scope = "two idle-pixel recipes; real engine timer; finite native qualification; no performance acceptance"
    }

    private static func measure(_ t: AppTestRunner, _ recipe: Recipe, _ backend: Backend) {
        var report = Report(recipe: recipe.rawValue, requestedBackend: backend.rawValue, pid: getpid(),
            executable: CommandLine.arguments.first ?? "", os: ProcessInfo.processInfo.operatingSystemVersionString,
            warmRequestedSeconds: warmSeconds, observationRequestedSeconds: observationSeconds,
            ownedBitmapBudget: backend == .bitmap ? nil : bitmapBudget,
            callbackBitmapBudget: backend == .e ? bitmapBudget : nil,
            qualificationReadbackBudget: bitmapBudget, referenceBitmapBudget: bitmapBudget)
        var app: AppController?, window: SkinWindowController?, worker: SkinThreadExecutor?
        let oldWeather = WeatherService.shared.environment, oldAppearance = NSApp.appearance
        let oldRegional = MacRegional.fixed
        defer {
            if let app {
                let late = app.stopAllForTermination()
                report.cleanupClosed = late.isEmpty
                t.equal(late, [], "ordinary close completes within the existing termination budget")
                if let window {
                    let detached = AppSelfTest.spin(timeout: 30) { window.content.state.tornDown }
                    report.cleanupDetached = detached && window.content.installedLayerRoot == nil &&
                        window.content.stagedNativeHost == nil && !window.window.isVisible
                    t.equal(report.cleanupDetached, Optional(true), "owner release precedes actual Main detach/window close")
                }
                app.endEngineThread()
                if let worker {
                    report.cleanupWorkerExited = AppSelfTest.spin(timeout: 30) { worker.hasExited }
                    t.equal(report.cleanupWorkerExited, Optional(true), "the actual engine worker exits")
                }
                do { report.closedUsage = try Usage.read() }
                catch {
                    report.status = "unavailable"
                    report.reason = (report.reason.map { $0 + "; " } ?? "") + "closed usage unavailable: \(error)"
                    t.check(false, "closed proc_pid_rusage unavailable: \(error)")
                }
                if report.cleanupClosed != true || report.cleanupDetached == false || report.cleanupWorkerExited == false {
                    report.status = "unavailable"
                    report.reason = (report.reason.map { $0 + "; " } ?? "") + "cleanup qualification failed"
                }
            }
            WeatherService.install(oldWeather)
            NSApp.appearance = oldAppearance
            MacRegional.fix(oldRegional)
            MacAppearance.current.refresh()
            DesktopInputs.appearance.refresh()
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(report)
                print("LAYER-PERFORMANCE " + String(decoding: data, as: UTF8.self))
            } catch { t.check(false, "measurement report encoding failed: \(error)") }
        }
        do {
            guard Thread.isMainThread, FrameTimingLog.period == 0, !SkinBitmapDrawing.verifies else {
                throw Unavailable.qualification("Main owner and disabled per-frame diagnostics are required")
            }
            let root = t.temporaryDirectory("layer-performance")
            let skins = root.appendingPathComponent("Skins", isDirectory: true)
            let (config, file) = try prepare(recipe, skins: skins)
            report.inputSHA256 = try fingerprint(skins)
            MacRegional.fix(.standard)
            RenderCommand.applyAppearance(.light)
            var weather = WeatherWiring.previewEnvironment(demo: false, demoNow: fixedDate, locale: Locale(identifier: "en_US"))
            weather.localTimeZone = { TimeZone(secondsFromGMT: 0)! }
            WeatherService.install(weather)
            let instance = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                skinsDirectory: skins, layoutsDirectory: root.appendingPathComponent("Layouts"),
                backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
                settingsDirectory: root.appendingPathComponent("Settings"), presentsWindows: true, threading: .engine)
            app = instance
            report.emptyAppUsage = try Usage.read()
            let began = ProcessInfo.processInfo.systemUptime
            let activated = instance.activate(config: config, file: file, fade: false, contentMode: mode(recipe, backend))
            worker = instance.engineThread
            guard let actual = activated else {
                throw Unavailable.qualification("actual AppController activation failed")
            }
            window = actual
            guard AppSelfTest.spin(timeout: 30, until: { actual.isStarted || actual.loadFailed }),
                  actual.isStarted, !actual.loadFailed,
                  let physical = actual.runtime.executor as? SkinThreadExecutor,
                  instance.engineThread === physical else { throw Unavailable.qualification("shared engine activation did not start") }
            worker = physical
            report.setupReadyWallSeconds = ProcessInfo.processInfo.systemUptime - began
            // Observe actual facts first. In particular, ordered-in with occlusion=8192 is NOT visible qualification.
            report.windowBefore = windowSample(actual)
            try requireVisible(actual)
            guard AppSelfTest.spin(timeout: 30, until: {
                switch backend {
                case .bitmap: return actual.content.shown.image != nil
                case .c: return actual.content.installedLayerRoot != nil
                case .e: return actual.content.visibleNativeStage != nil
                }
            }) else { throw Unavailable.qualification("requested backend did not publish an actual frame") }
            if backend == .e {
                // Publication ack enables the persistent owner; require its first actual ordinary native frame,
                // not merely the attachment's older staging callback count.
                _ = try requestNativeFrame(actual, physical)
            }
            _ = try sample(actual, physical, backend)
            let initialPixels = try autoreleasepool { try qualifyPixels(actual, physical, backend) }
            report.pixelSHA256Before = initialPixels.hash
            report.pixelComparisonBefore = initialPixels.comparison
            let warmBegan = ProcessInfo.processInfo.systemUptime
            try eventLoopWait(warmSeconds)
            report.warmActualSeconds = ProcessInfo.processInfo.systemUptime - warmBegan
            try requireVisible(actual)
            report.warmUsage = try Usage.read()
            // All initial GPU qualification and its autorelease pool precede the full 20-second warm wait. Only
            // owner/value samples occur here, so an immediate readback cannot leave delayed GPU/CA cleanup in the
            // CPU interval. The final readback occurs after both process samples. The timer is never substituted.
            report.ownerBefore = try sample(actual, physical, backend)
            report.windowBefore = windowSample(actual)
            let observedSpace = actual.facts.colorSpace
            report.before = try Usage.read()
            try eventLoopWait(observationSeconds)
            report.after = try Usage.read()
            report.ownerAfter = try sample(actual, physical, backend)
            report.windowAfter = windowSample(actual)
            try requireVisible(actual)
            guard let observedSpace, let finalSpace = actual.facts.colorSpace, CFEqual(observedSpace, finalSpace),
                  report.windowBefore?.panelGeneration == report.windowAfter?.panelGeneration,
                  report.windowBefore?.profileSHA256 == report.windowAfter?.profileSHA256,
                  report.windowBefore?.scale == report.windowAfter?.scale,
                  report.windowBefore?.widthPoints == report.windowAfter?.widthPoints,
                  report.windowBefore?.heightPoints == report.windowAfter?.heightPoints,
                  report.windowBefore?.appearance == report.windowAfter?.appearance else {
                throw Unavailable.qualification("actual destination changed during observation")
            }
            let finalPixels = try autoreleasepool { try qualifyPixels(actual, physical, backend) }
            report.pixelSHA256After = finalPixels.hash
            report.pixelComparisonAfter = finalPixels.comparison
            guard report.pixelSHA256Before == report.pixelSHA256After else {
                throw Unavailable.qualification("the idle-pixel recipe changed across qualification/warm/observation")
            }
            guard let before = report.before, let after = report.after, let first = report.ownerBefore,
                  let last = report.ownerAfter, last.updates > first.updates else {
                throw Unavailable.qualification("actual runtime timer did not produce positive updates")
            }
            try calculate(before, after, into: &report)
            report.status = "observed"
            t.check(true, "actual requested backend/visible destination/idle pixels and process samples qualify")
        } catch {
            report.reason = String(describing: error)
            t.check(false, "measurement unavailable: \(error)")
        }
    }

    private static func eventLoopWait(_ seconds: TimeInterval) throws {
        let began = ProcessInfo.processInfo.systemUptime
        let result = CFRunLoopRunInMode(.defaultMode, seconds, false)
        guard result == .timedOut, ProcessInfo.processInfo.systemUptime - began >= seconds else {
            throw Unavailable.qualification("native run loop ended before its single \(seconds)s observation: \(result.rawValue)")
        }
    }

    private static func calculate(_ before: Usage, _ after: Usage, into report: inout Report) throws {
        let seconds = after.wall - before.wall
        guard seconds >= observationSeconds, before.processStart == after.processStart,
              after.userCPUSeconds >= before.userCPUSeconds, after.systemCPUSeconds >= before.systemCPUSeconds,
              after.interruptWakeups >= before.interruptWakeups, after.packageIdleWakeups >= before.packageIdleWakeups else {
            throw Unavailable.qualification("usage counters are not a monotonic same-process interval")
        }
        let cpu = after.userCPUSeconds - before.userCPUSeconds + after.systemCPUSeconds - before.systemCPUSeconds
        report.processSingleCorePercent = cpu / seconds * 100
        report.interruptWakeupsPerSecond = Double(after.interruptWakeups - before.interruptWakeups) / seconds
        report.packageIdleWakeupsPerSecond = Double(after.packageIdleWakeups - before.packageIdleWakeups) / seconds
        // No performance thresholds are asserted from one cell or from a debug binary.
    }

    private static func windowSample(_ window: SkinWindowController) -> WindowSample {
        let facts = window.facts
        let profile = facts.colorSpace.flatMap { $0.copyICCData() }.map { $0 as Data }
        return WindowSample(orderedIn: window.window.isVisible, actualOcclusion: window.window.occlusionState.rawValue,
            unoccluded: window.window.occlusionState.contains(.visible), activeSpace: window.window.isOnActiveSpace,
            appActive: NSApp.isActive, panelGeneration: facts.panelGeneration,
            widthPoints: Double(window.view.bounds.width), heightPoints: Double(window.view.bounds.height),
            scale: Double(facts.scale), profileSHA256: profile.map(digest), profileName: facts.colorSpace?.name.map { $0 as String },
            appearance: facts.appearance)
    }

    private static func requireVisible(_ window: SkinWindowController) throws {
        guard window.visibilityForTesting == nil, window.window.isVisible, window.window.occlusionState.contains(.visible),
              window.facts.isVisible, window.facts.isOrderedIn, !window.isStopped,
              let space = window.facts.colorSpace, space.model == .rgb,
              window.facts.scale.isFinite, window.facts.scale > 0 else {
            throw Unavailable.qualification("real ordered-in/unoccluded RGB-profile window required: \(windowSample(window))")
        }
    }

    private static func onOwner<T>(_ worker: SkinThreadExecutor, _ work: @escaping () throws -> T) throws -> T {
        let result = Guarded<Result<T, Error>?>(nil)
        worker.async {
            result.access { value in value = Result {
                guard worker.isOnThread, SkinThreadExecutor.isSkinThread, !Thread.isMainThread else {
                    throw Unavailable.qualification("query did not run on the physical skin owner")
                }
                return try work()
            } }
        }
        guard AppSelfTest.spin(timeout: 30, until: { result.current != nil }), let answer = result.current else {
            throw Unavailable.qualification("physical owner completion fence unavailable")
        }
        return try answer.get()
    }

    /// A normal owner turn, not drawFirstFrame (which deliberately does nothing after the first frame).
    /// Used only outside the timed waits; callbacks and the matched owner record must both advance.
    private static func requestNativeFrame(_ window: SkinWindowController, _ worker: SkinThreadExecutor) throws -> OwnerSample {
        guard let attachment = window.content.visibleNativeStage else {
            throw Unavailable.qualification("the actual native attachment is not published")
        }
        let previous = try onOwner(worker) { () -> (sequence: UInt64, callbacks: [Int]) in
            guard !window.runtime.isClosing, !window.runtime.isClosed, window.runtime.skin != nil else {
                throw Unavailable.qualification("owner closed before the native frame request")
            }
            let sequence = window.runtime.frames.layerRuntime?.nativeFrame(attachment)?.sequence ?? attachment.sourceSequence
            let callbacks = attachment.callbackReport.observation.callbacks
            guard window.runtime.send(.frameWanted) == true else {
                throw Unavailable.qualification("the actual owner declined its normal frame request")
            }
            return (sequence, callbacks)
        }
        guard AppSelfTest.spin(timeout: 30, until: {
            let current = attachment.callbackReport.observation
            return window.content.visibleNativeStage !== attachment || current.failure != nil ||
                zip(previous.callbacks, current.callbacks).contains { $1 > $0 }
        }), window.content.visibleNativeStage === attachment, attachment.callbackReport.observation.failure == nil else {
            throw Unavailable.qualification("the next actual native callback did not qualify")
        }
        // The queued physical-owner query is a completion fence after the callback, not a Main-side cache read.
        let current = try sample(window, worker, .e)
        guard let sequence = current.nativeSequence, sequence > previous.sequence else {
            throw Unavailable.qualification("the matched native frame record did not advance after its callback")
        }
        return current
    }

    private static func sample(_ window: SkinWindowController, _ worker: SkinThreadExecutor, _ backend: Backend) throws -> OwnerSample {
        let attachment = window.content.visibleNativeStage, facts = window.facts
        return try onOwner(worker) {
            guard !window.runtime.isClosing, !window.runtime.isClosed, let skin = window.runtime.skin else {
                throw Unavailable.qualification("owner closed before the value sample")
            }
            let frames = window.runtime.frames
            guard skin.settings.update == 1000,
                  window.runtime.model.facts?.isVisible == true, window.runtime.model.facts?.isOrderedIn == true,
                  let space = facts.colorSpace, CFEqual(frames.space, space), frames.scale == facts.scale,
                  frames.nativeFrameFailure == nil, frames.layerFailure == nil else {
                throw Unavailable.qualification("owner timer/destination/backend failure differs from actual window")
            }
            let frame = frames.layerRuntime?.currentFrame
            let native = attachment.flatMap { frames.layerRuntime?.nativeFrame($0) }
            if let frame {
                guard frame.scale == facts.scale, CFEqual(frame.colorSpace, space),
                      frame.contents.allSatisfy({ $0.image.colorSpace.map { CFEqual($0, space) } == true }) else {
                    throw Unavailable.qualification("accepted C anchor/profile differs from actual destination")
                }
            }
            switch backend {
            case .bitmap:
                guard frame == nil, !frames.hasNativeStage else { throw Unavailable.qualification("bitmap unexpectedly owns layer/native content") }
            case .c:
                guard frame != nil, frames.layerInstalled, frames.lastLayerDrawWasOnSkinThread, !frames.hasNativeStage else {
                    throw Unavailable.qualification("C was not accepted on the actual physical owner")
                }
            case .e:
                guard let attachment, let native, frames.hasNativeFrameOwner,
                      attachment.scale == facts.scale, CFEqual(attachment.colorSpace, space),
                      native.sequence > attachment.sourceSequence, native.cycle <= skin.updateCount,
                      native.observation.failure == nil, attachment.callbackReport.observation.failure == nil,
                      attachment.callbackReport.observation.callbacks.contains(where: { $0 > 0 }) else {
                    throw Unavailable.qualification("persistent E did not qualify; C fallback is not an E measurement")
                }
            }
            return OwnerSample(updates: skin.updateCount, framesDrawn: frames.framesDrawn, framesSkipped: frames.framesSkipped,
                frameWorkWallSeconds: frames.drawingTime, commits: SkinFrameBatch.threadCommits, keptRuns: frames.drawing.keptRuns,
                layerSequence: frame?.sequence, nativeSequence: native?.sequence,
                layers: frame?.plan.layers.count ?? 1,
                plan: frame?.plan.layers.map { "\($0.id): \($0.rect) \($0.content)" } ?? ["bitmap"],
                fallback: frame?.fallback.map { String(describing: $0) },
                frozenCWriter: frames.layerRuntime?.nativePublicationHoldsWriter ?? false,
                callbacks: attachment?.callbackReport.observation.callbacks ?? [],
                nativeDestinations: attachment?.callbackReport.observation.destinations.map { destination in
                    guard let destination else { return "base copy" }
                    return "\(destination.layer): \(destination.width)x\(destination.height), stride \(destination.bytesPerRow), bpc \(destination.bitsPerComponent), bpp \(destination.bitsPerPixel), info \(destination.bitmapInfo.rawValue), windowProfile \(destination.target?.colorSpace.map { CFEqual($0, space) } == true), map \(String(describing: destination.target?.userToDevice))"
                } ?? [], actualPhysicalOwner: worker.isOnThread)
        }
    }

    /// Independent full-scene raster storage on the worker. It uses the actual scene's associated drawing caches,
    /// as existing native controls do, and does not replace the producer or freeze its real timer.
    private static func qualifyPixels(_ window: SkinWindowController, _ worker: SkinThreadExecutor,
                                     _ backend: Backend) throws -> (hash: String, comparison: String) {
        try requireVisible(window)
        let facts = window.facts, size = window.view.bounds.size
        guard let space = facts.colorSpace else { throw Unavailable.qualification("no actual profile") }
        let width = (size.width * facts.scale).rounded(.up), height = (size.height * facts.scale).rounded(.up)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= CGFloat(Rasterizer.maximumDimension), height <= CGFloat(Rasterizer.maximumDimension),
              let rect = InkBounds.DeviceRect(minX: 0, minY: 0, maxX: Int(width), maxY: Int(height)) else {
            throw Unavailable.qualification("actual window dimensions are not canonical")
        }
        let reference = try onOwner(worker) { () -> LayerContentBuilder.Content in
            guard !window.runtime.isClosing, !window.runtime.isClosed, let skin = window.runtime.skin else {
                throw Unavailable.qualification("owner closed before the independent Single query")
            }
            let context = SkinRenderContext.of(skin)
            let scene = context.sceneProjector.project(skin, environment: AppSceneEnvironment(scale: Double(facts.scale),
                appearance: skin.host?.environment(for: skin).appearance ?? .light, appearanceName: facts.appearance), glassSource: .published)
            let builder = try LayerContentBuilder(plan: SinglePartition.plan(in: rect), scale: facts.scale,
                colorSpace: space, maximumOwnedBitmapBytes: bitmapBudget)
            guard let content = try builder.build(scene, context: context.drawing, cycle: skin.updateCount, glass: .hitArea).first else {
                throw Unavailable.qualification("independent Single is empty")
            }
            return content
        }
        guard reference.image.colorSpace.map({ CFEqual($0, space) }) == true else {
            throw Unavailable.qualification("reference image profile differs")
        }
        let renderer = try OffscreenRenderer(width: rect.width, height: rect.height, device: MTLCreateSystemDefaultDevice(),
            maximumReadbackBytes: bitmapBudget, colorSpace: space)
        let readback = window.runtime.exclusive(timeout: 30) { _ -> Result<([UInt8], String), Error> in
            Result {
                guard Thread.isMainThread, worker.isCurrent, !worker.isOnThread else {
                    throw Unavailable.qualification("actual Main exclusive lease unavailable")
                }
                let tree: CALayer
                if backend == .e {
                    guard let host = window.content.stagedNativeHost, let attachment = window.content.visibleNativeStage,
                          host.opacity == 1, window.content.contentOpacity == 0 else {
                        throw Unavailable.qualification("real E publication is not visible")
                    }
                    tree = host
                    guard attachment.partition == .single || attachment.partition == .acceptedComponents else {
                        throw Unavailable.qualification("unexpected native partition")
                    }
                } else {
                    guard window.content.visibleNativeStage == nil, let layer = window.view.layer else {
                        throw Unavailable.qualification("expected actual bitmap/C tree missing")
                    }
                    tree = layer
                }
                // Native components require their actual flipped ancestor. Single E uses its neutral host.
                var observedRoot = tree
                if backend == .e, window.content.visibleNativeStage?.partition == .acceptedComponents {
                    guard let parent = tree.superlayer, let ancestor = parent.superlayer, ancestor.isGeometryFlipped,
                          ancestor.contentsAreFlipped() == parent.contentsAreFlipped(), ancestor.bounds == parent.bounds,
                          ancestor.frame == parent.frame, CATransform3DIsIdentity(parent.transform),
                          CATransform3DIsIdentity(parent.sublayerTransform), CATransform3DIsIdentity(ancestor.transform),
                          CATransform3DIsIdentity(ancestor.sublayerTransform) else {
                        throw Unavailable.qualification("actual component observer ancestry is incompatible")
                    }
                    observedRoot = ancestor
                }
                let originalParent = observedRoot.superlayer
                let originalIndex = originalParent?.sublayers?.firstIndex { $0 === observedRoot }
                let originalBounds = observedRoot.bounds, originalPosition = observedRoot.position
                let originalTransform = observedRoot.transform
                if originalParent != nil, originalIndex.flatMap(UInt32.init(exactly:)) == nil {
                    throw Unavailable.qualification("observer parent index is not restorable")
                }
                let leaves = window.content.visibleNativeStage?.root.sublayers ?? []
                let flips = leaves.map { $0.contentsAreFlipped() }
                var restored = false
                func restore() {
                    guard !restored else { return }
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    if let originalParent, let originalIndex, let slot = UInt32(exactly: originalIndex) {
                        observedRoot.removeFromSuperlayer()
                        originalParent.insertSublayer(observedRoot, at: slot)
                    }
                    CATransaction.commit()
                    restored = true
                }
                defer { restore() }
                let actual = try renderer.render(observedRoot, at: 0, deadline: .now() + .seconds(30))
                let expected = try renderer.render(singleTree(reference.image, size: size, scale: facts.scale),
                    at: 0, deadline: .now() + .seconds(30))
                restore()
                guard renderer.hasVerifiedCanary, leaves.map({ $0.contentsAreFlipped() }) == flips,
                      observedRoot.bounds == originalBounds, observedRoot.position == originalPosition,
                      CATransform3DEqualToTransform(observedRoot.transform, originalTransform),
                      observedRoot.superlayer === originalParent,
                      originalParent?.sublayers?.firstIndex(where: { $0 === observedRoot }) == originalIndex,
                      stride(from: 3, to: actual.rgba.count, by: 4).contains(where: { actual.rgba[$0] > 0 }) else {
                    throw Unavailable.qualification("native canary/nonempty ink/observer geometry failed")
                }
                let difference = try PixelComparison.compare(reference: expected.rgba, candidate: actual.rgba,
                    width: rect.width, height: rect.height)
                // C/E remain exact. Bitmap keeps its existing B+kept per-channel contract; report the real count
                // and maximum difference rather than claiming B+kept is byte-identical to direct Single.
                func qualifies(_ difference: PixelComparison.Difference) -> Bool {
                    backend == .bitmap ? difference.maxChannelDifference <= SkinBitmapDrawing.tolerance : difference.isExact
                }
                guard qualifies(difference) else { throw Unavailable.qualification("requested backend/Single pixels differ: \(difference)") }
                var wrong = expected.rgba
                // This literal endpoint flip differs by >=128, exceeding the unchanged bitmap channel limit 8.
                wrong[0] = expected.rgba[0] < 128 ? 255 : 0
                guard !qualifies(try PixelComparison.compare(reference: expected.rgba, candidate: wrong,
                    width: rect.width, height: rect.height)) else {
                    throw Unavailable.qualification("pixel comparison negative control failed")
                }
                return (actual.rgba, "\(backend == .bitmap ? "existing B+kept channel limit" : "exact Single"): \(difference)")
            }
        }
        guard let readback else { throw Unavailable.qualification("native exclusive observation timed out") }
        let (pixels, comparison) = try readback.get()
        if backend == .e {
            // After observer restoration, require a real ordinary frame and its matched ready record.
            _ = try requestNativeFrame(window, worker)
        } else {
            _ = try sample(window, worker, backend)
        }
        return (digest(Data(pixels)), comparison)
    }

    private static func singleTree(_ image: CGImage, size: CGSize, scale: CGFloat) -> CALayer {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let tree = CALayer(), leaf = CALayer()
        tree.anchorPoint = .zero
        tree.bounds = CGRect(origin: .zero, size: size)
        tree.isGeometryFlipped = true
        leaf.anchorPoint = .zero
        leaf.frame = tree.bounds
        leaf.contents = image
        leaf.contentsScale = scale
        leaf.contentsGravity = .resize
        leaf.minificationFilter = .nearest
        leaf.magnificationFilter = .nearest
        tree.addSublayer(leaf)
        return tree
    }

    private static func mode(_ recipe: Recipe, _ backend: Backend) -> SkinFrameContentMode {
        let partition: LayerRuntime.Partition = recipe == .clock ? .single : .candidateComponents
        switch backend {
        case .bitmap: return .bitmap
        case .c: return .layers(partition: partition, maximumOwnedBitmapBytes: bitmapBudget)
        case .e:
            let native: SkinLayerFrameBackend = recipe == .clock ? .nativeSingle(maximumCallbackBitmapBytes: bitmapBudget)
                : .nativeComponents(maximumCallbackBitmapBytes: bitmapBudget)
            return .layers(partition: partition, maximumOwnedBitmapBytes: bitmapBudget, backend: native)
        }
    }

    private static func prepare(_ recipe: Recipe, skins: URL) throws -> (String, String) {
        try FileManager.default.createDirectory(at: skins, withIntermediateDirectories: true)
        switch recipe {
        case .clock:
            guard let original = Paths.repositoryFolder("DefaultSkins")?.appendingPathComponent("Stationery") else {
                throw Unavailable.qualification("repository Stationery source unavailable")
            }
            // Reject source symlinks BEFORE any private-copy override could follow one back into a source file.
            _ = try fingerprint(original)
            let copy = skins.appendingPathComponent("Stationery", isDirectory: true)
            try FileManager.default.copyItem(at: original, to: copy)
            _ = try fingerprint(copy)
            let resources = copy.appendingPathComponent("@Resources")
            let timestamp = TimeFormatting.measureValue(for: fixedDate, timeZone: TimeZone(secondsFromGMT: 0)!)
            try replace("TestNow=", with: "TestNow=\(NumberFormatting.plain(timestamp))",
                in: resources.appendingPathComponent("Suite/Tokens.inc"))
            for (old, new) in [("Look=Auto", "Look=Light"), ("UseSolidCards=0", "UseSolidCards=1"),
                               ("Ink=Auto", "Ink=Dark"), ("ClockHours=Auto", "ClockHours=24"),
                               ("Location=timezone", "Location=59.91,10.75"), ("ClockBottomLine=Sun", "ClockBottomLine=None")] {
                try replace(old, with: new, in: resources.appendingPathComponent("Variables.inc"))
            }
            return ("Stationery\\Clock", "Small.ini")
        case .design:
            let folder = skins.appendingPathComponent("Measurements/Design", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try design.write(to: folder.appendingPathComponent("Design.ini"), atomically: true, encoding: .utf8)
            return ("Measurements\\Design", "Design.ini")
        }
    }

    private static func replace(_ old: String, with new: String, in file: URL) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        let matches = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == old }
        guard matches.count == 1, let index = matches.first else { throw Unavailable.qualification("fixture key is not unique: \(old)") }
        lines[index] = new
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private static func fingerprint(_ folder: URL) throws -> String {
        guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw Unavailable.qualification("fixture root is a symlink")
        }
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw Unavailable.qualification("fixture inventory unavailable")
        }
        var records: [String] = []
        for case let file as URL in items {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw Unavailable.qualification("fixture contains a symlink") }
            if values.isRegularFile == true {
                let relative = String(file.path.dropFirst(folder.path.count))
                records.append(relative + " " + digest(try Data(contentsOf: file)))
            }
        }
        return digest(Data(records.sorted().joined(separator: "\n").utf8))
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A >=300-point recipe with a full base and two disjoint known groups; no live measures, files or user services.
    private static let design = """
    [Rainmeter]
    Update=1000
    SkinWidth=360
    SkinHeight=180
    DynamicWindowSize=0
    MacAppearance=Light
    [Back]
    Meter=Shape
    Shape=Rectangle 0,0,360,180 | Fill Color 31,89,151,100 | StrokeWidth 0
    AntiAlias=1
    [Left]
    Meter=Shape
    Shape=Rectangle 14,18,92,104 | Fill Color 217,42,91,140 | StrokeWidth 0
    AntiAlias=1
    [Right]
    Meter=Shape
    Shape=Rectangle 240,28,92,98 | Fill Color 23,211,73,180 | StrokeWidth 0
    AntiAlias=1
    """
}
