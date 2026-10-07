import AppKit
import DeskLanguage
import DesksetCore
import DesksetDraw

/// Preview-only transactions: controlled vector resources qualify ordering, and the native case uses Main's
/// actual SF Symbol PDF preparation. No widget, filesystem editor or Mac action is activated.
enum DeskIconPreviewSelfTests {
    private enum Failure: Error { case fixture, bitmap, pdf, compilation(String), missingRequest(index: Int, count: Int) }

    private final class Preparations {
        struct Request {
            let demands: [DeskIconResources.Demand]
            let completion: (Result<DeskIconResources.Batch, Error>) -> Void
            let ticket: DeskIconResources.Ticket
        }
        var requests: [Request] = []
        func prepare(_ demands: [DeskIconResources.Demand], completion: @escaping (Result<DeskIconResources.Batch, Error>) -> Void) -> DeskIconResources.Ticket {
            let ticket = DeskIconResources.Ticket()
            requests.append(Request(demands: demands, completion: completion, ticket: ticket))
            return ticket
        }
        func finish(_ index: Int, unknown: Bool = false, size: SkinSize = SkinSize(width: 20, height: 20)) throws {
            guard requests.indices.contains(index) else { throw Failure.missingRequest(index: index, count: requests.count) }
            let request = requests[index]
            request.completion(.success(DeskIconResources.Batch(entries: try request.demands.map {
                DeskIconResources.Entry(demand: $0, prepared: unknown ? nil : try DeskIconPreviewSelfTests.vector(size))
            })))
        }
    }

    private final class SystemFixture: SystemDataSource {
        var cpu: Double = 25
        var cpuCalls = 0
        let processorCount = 4
        func cpuUsage(processor: Int) -> Double { cpuCalls += 1; return cpu }
        func memoryStatus() -> MemoryStatus { MemoryStatus(physicalTotal: 16, physicalUsed: 8) }
        func networkInterfaces() -> [String] { [] }
        func networkCounters(interface: String?) -> NetworkCounters { NetworkCounters() }
        func diskSpace(path: String) -> (total: Double, free: Double)? { nil }
        func uptime() -> TimeInterval { 3600 }
        func battery() -> BatteryStatus? { nil }
        func isProcessRunning(_ name: String) -> Bool { false }
        func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { nil }
    }

    private struct Fixture {
        let service: DeskLanguageService
        let preview: DeskProgramPreviewController
        let window: NSWindow
        let time: VirtualTimeExecutor
        let system: SystemFixture
    }

    private static func fixture(_ t: AppTestRunner, _ source: String,
                                prepare: @escaping DeskProgramPreviewController.IconPreparation = DeskIconResources.prepare) throws -> Fixture {
        let file = DeskFileID(path: "Icon.desk")
        let service = DeskLanguageService(openFile: file, files: [file: source])
        guard !service.snapshot.diagnostics.contains(where: { $0.severity == .error }) else { throw Failure.fixture }
        let compilation = Desk.compile(service.snapshot.checked, catalog: service.snapshot.options.catalog)
        guard compilation.program != nil else {
            throw Failure.compilation(compilation.issues.map(\.message).joined(separator: "; "))
        }
        let time = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
        let system = SystemFixture()
        let preview = DeskProgramPreviewController(clock: time.clock, executor: time,
            dateLocale: { Locale(identifier: "en_US_POSIX") }, system: system, prepareIcons: prepare) {
                $0.file == service.snapshot.file && $0.generation == service.snapshot.generation
                    && $0.tree.version == service.snapshot.tree.version && service.snapshot.isChecked
            }
        let window = NSWindow(contentViewController: preview)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.layoutSubtreeIfNeeded()
        t.atSuiteEnd { preview.close(); window.close(); time.runUntilIdle() }
        preview.show(service.snapshot, readError: nil)
        return Fixture(service: service, preview: preview, window: window, time: time, system: system)
    }

    static func run(_ t: AppTestRunner) {
        t.suite("Desk: icon preview: Main prepares native PDF asynchronously before a real canvas paints") {
            let f = try fixture(t, #"widget { Icon("cloud.sun.fill").iconColors(.multicolor).size(48) }"#)
            let p = f.preview
            t.check(p.isPreparingIcons)
            t.equal(p.state, .checking)
            t.check(p.scene == nil, "the 1x1 collection scene is never exposed")
            t.equal(p.iconResources.count, 0)
            t.check(AppSelfTest.spin(timeout: 10) {
                f.time.runUntilIdle()
                return !p.isPreparingIcons
            })
            t.equal(p.state, .ready)
            t.equal(p.iconResources.count, 1)
            t.check(p.iconResources.pdfBytes > 0, "native immutable PDF has been installed")
            t.equal(icons(p.scene).map(\.request.name), ["cloud.sun.fill"])
            for scale in [1, 2] { t.check(try paintedInk(p.canvas, scale: scale) > 100, "real canvas has symbol pixels at \(scale)x") }
            t.equal(p.recordedEffects, [])
        }

        t.suite("Desk: icon preview: pending clicks retain old pixels and commit captured input and effects once") {
            let preparations = Preparations()
            let source = #"widget { variable name = "wifi"; variable count = 0; Column { Icon(name).size(40).onClick { count = count + 1; name = "sun.max.fill"; copy("{count}|{time.now, format: "HH:mm:ss"}|{cpu.usage}") }; Text("{count}|{time.now, format: "HH:mm:ss"}|{cpu.usage}") } }"#
            let f = try fixture(t, source, prepare: preparations.prepare), p = f.preview
            t.equal(preparations.requests.count, 1)
            try preparations.finish(0); f.time.runUntilIdle()
            p.setVisible(true)
            guard let old = p.scene else { throw Failure.fixture }
            var commits: [[String]] = []
            p.onRecordedEffects = { _ in commits.append(texts(p.scene)) }
            try click(p, in: f.window)
            t.check(p.isPreparingIcons)
            t.equal(preparations.requests.count, 2)
            t.equal(p.scene?.generation, old.generation)
            t.equal(icons(p.scene).map(\.request.name), ["wifi"])
            t.check(try paintedInk(p.canvas) > 0, "committed old resources remain draw-able while waiting")
            t.equal(p.recordedEffects, [])
            let sampled = f.system.cpuCalls
            f.time.setWallClock(Date(timeIntervalSince1970: 30)); f.system.cpu = 90
            p.updateForTick(); p.updateForTick()
            t.equal(f.system.cpuCalls, sampled, "coalesced ticks do not resample the pending transaction")
            // Further input cannot replay the held click while its resource transaction is incomplete.
            try click(p, in: f.window)
            t.equal(preparations.requests.count, 2)
            try preparations.finish(1); f.time.runUntilIdle()
            t.check(!p.isPreparingIcons)
            t.equal(p.recordedEffects, [.copy("1|00:00:00|25")])
            t.equal(commits, [["1|00:00:00|25"]], "effect publication sees the original click's immutable inputs")
            t.equal(texts(p.scene), ["1|00:00:30|90"], "one deferred projection refreshes the newer clock/system values")
            t.equal(icons(p.scene).map(\.request.name), ["sun.max.fill"])
            t.equal(p.scene?.generation, old.generation + 2)
            let accepted = p.scene?.generation
            try preparations.finish(1); f.time.runUntilIdle()
            t.equal(p.scene?.generation, accepted, "a duplicate batch callback cannot rerun the assignment")
            t.equal(p.recordedEffects.count, 1); t.equal(commits.count, 1)
        }

        t.suite("Desk: icon preview: source rechecks checking and close cancel stale batches") {
            let preparations = Preparations()
            let source = #"widget { Icon("wifi").size(40) }"#
            let f = try fixture(t, source, prepare: preparations.prepare), p = f.preview
            let first = preparations.requests[0]
            // Equal text is still a different checked tree/session.
            let next = f.service.replaceText(source, version: 1)
            p.show(next, readError: nil)
            t.check(first.ticket.isCancelled)
            t.equal(preparations.requests.count, 2)
            try preparations.finish(0); f.time.runUntilIdle()
            t.check(p.isPreparingIcons && p.scene == nil)
            t.equal(p.iconResources.count, 0, "retired source resources are not installed")
            try preparations.finish(1); f.time.runUntilIdle()
            t.equal(p.state, .ready)
            let replacement = f.service.replaceText(#"widget { Icon("sun.max.fill").size(40) }"#, version: 2)
            p.show(replacement, readError: nil)
            t.check(p.scene == nil && p.canvas.isHidden, "new source cannot borrow the previous source's picture")
            t.equal(preparations.requests.count, 3)
            p.show(replacement, readError: "read failed")
            t.check(preparations.requests[2].ticket.isCancelled)
            try preparations.finish(2); f.time.runUntilIdle()
            t.equal(p.state, .unavailable("read failed")); t.check(p.scene == nil)
            p.show(replacement, readError: nil)
            t.equal(preparations.requests.count, 4)
            p.close()
            t.check(preparations.requests[3].ticket.isCancelled)
            try preparations.finish(3); f.time.runUntilIdle()
            t.equal(p.state, .closed); t.check(p.scene == nil && !p.isPreparingIcons)
            t.equal(p.recordedEffects, [])
        }

        t.suite("Desk: icon preview: destination changes cancel old requests and empty symbols discard provisional geometry") {
            let preparations = Preparations()
            let f = try fixture(t, #"widget { Icon("wifi") }"#, prepare: preparations.prepare), p = f.preview
            let first = preparations.requests[0]
            p.canvas.appearance = NSAppearance(named: .darkAqua)
            p.refreshEnvironment()
            t.check(first.ticket.isCancelled)
            t.equal(preparations.requests.count, 2)
            t.check(preparations.requests[1].demands.allSatisfy { $0.request.appearance.value.isDark })
            try preparations.finish(0); f.time.runUntilIdle()
            t.check(p.scene == nil && p.isPreparingIcons)
            try preparations.finish(1, unknown: true); f.time.runUntilIdle()
            t.equal(p.state, .empty)
            t.equal(p.scene?.size, SkinSize(width: 0, height: 0), "unknown means zero natural size, not the collector's 1x1")
            t.equal(icons(p.scene).count, 0)
            t.equal(p.iconResources.count, 1)
        }

        t.suite("Desk: icon preview: exact batches synchronous callbacks and mode cancellation preserve the transaction") {
            let preparations = Preparations()
            let f = try fixture(t, #"widget { variable name = "wifi"; Icon(name).size(40).onClick { name = "sun.max.fill"; copy("done") } }"#,
                                prepare: preparations.prepare), p = f.preview
            preparations.requests[0].completion(.success(DeskIconResources.Batch(entries: [])))
            f.time.runUntilIdle()
            t.equal(p.state, .unavailable(StudioText[.deskWidgetPreparationFailed]), "incomplete batch fails with readable feedback")
            t.check(p.scene == nil); t.equal(p.recordedEffects, [])
            p.show(f.service.snapshot, readError: nil)
            try preparations.finish(1); f.time.runUntilIdle(); p.setVisible(true)
            try click(p, in: f.window)
            t.check(p.isPreparingIcons)
            let pending = preparations.requests.last!
            p.setInspecting(true)
            t.check(pending.ticket.isCancelled)
            pending.completion(.success(DeskIconResources.Batch(entries: try pending.demands.map {
                .init(demand: $0, prepared: try vector())
            })))
            f.time.runUntilIdle()
            t.equal(icons(p.scene).map(\.request.name), ["wifi"])
            t.equal(p.recordedEffects, [])
            t.check(!p.isPreparingIcons)

            let synchronous = try fixture(t, #"widget { Icon("wifi").size(40) }"#) { demands, completion in
                completion(.success(DeskIconResources.Batch(entries: demands.map { .init(demand: $0, prepared: nil) })))
                return DeskIconResources.Ticket()
            }
            t.check(synchronous.preview.isPreparingIcons && synchronous.preview.scene == nil,
                    "an injected synchronous completion still returns through the owner queue")
            synchronous.time.runUntilIdle()
            t.equal(synchronous.preview.state, .empty); t.check(!synchronous.preview.isPreparingIcons)
        }

        t.suite("Desk: icon preview: actual magnification raster budget is qualified before click effects") {
            // The original fixture used dynamic size, which the static layout IR deliberately cannot lower.
            let file = DeskFileID(path: "DynamicSize.desk")
            let unsupported = DeskLanguageService(openFile: file, files: [file:
                #"widget { variable edge = 10; Icon("wifi").size(edge).onClick { edge = 1100; copy("done") } }"#])
            t.check(!unsupported.snapshot.diagnostics.contains(where: { $0.severity == .error }))
            t.check(Desk.compile(unsupported.snapshot.checked, catalog: unsupported.snapshot.options.catalog).program == nil,
                    "dynamic size remains an unsupported layout contract")
            let preparations = Preparations()
            let f = try fixture(t, #"widget { variable points = 20; Icon("wifi").font(points).onClick { points = 1100; copy("done") } }"#,
                                prepare: preparations.prepare), p = f.preview
            try preparations.finish(0); f.time.runUntilIdle(); p.setVisible(true)
            p.scrollView.setMagnification(2, centeredAt: .zero)
            t.close(p.scrollView.magnification, 2)
            let generation = p.scene?.generation
            try click(p, in: f.window)
            t.check(p.isPreparingIcons)
            t.equal(preparations.requests.count, 2)
            t.equal(p.scene?.generation, generation); t.equal(p.recordedEffects, [])
            // The supported dynamic font supplies the changed request; its real natural size is not scaled to a fixed box.
            try preparations.finish(1, size: SkinSize(width: 1100, height: 1100)); f.time.runUntilIdle()
            // 1100×1100 at 2x exceeds the existing whole-frame 16MiB icon budget, even at a 1x window density.
            t.equal(p.state, .unavailable(StudioText[.deskWidgetPreparationFailed]), "raster budget fails before commit with readable feedback")
            t.check(p.scene == nil); t.equal(p.recordedEffects, [])
            t.check(!p.isPreparingIcons, "the new PDF is ready; this is a raster budget failure")
            t.equal(preparations.requests.count, 2)
            p.show(f.service.snapshot, readError: nil)
            t.equal(p.state, .ready, "a fresh source session recovers with its original small icon")
            t.equal(p.recordedEffects, [])
        }
    }

    /// A deterministic vector document for transaction controls, independently of native symbol preparation.
    private static func vector(_ size: SkinSize = SkinSize(width: 20, height: 20)) throws -> DeskIconResources.Prepared {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw Failure.pdf }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 0.15, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(bounds.insetBy(dx: bounds.width / 10, dy: bounds.height / 10))
        context.endPDFPage(); context.closePDF()
        return .init(size: size, pdf: data as Data)
    }

    private static func click(_ p: DeskProgramPreviewController, in window: NSWindow) throws {
        guard let rect = p.scene?.hitMap.entries.first?.frame else { throw Failure.fixture }
        let point = p.canvas.convert(NSPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2), to: nil)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { throw Failure.fixture }
        p.canvas.mouseDown(with: down); p.canvas.mouseUp(with: up)
    }

    private static func icons(_ scene: WidgetScene?) -> [IconDraw] {
        var result: [IconDraw] = [], pending = scene?.drawingItems ?? []
        while let item = pending.popLast() {
            if case .icon(let icon) = item { result.append(icon) }
            if case .transformed(_, let children) = item { pending += children }
            if case .antialias(_, let children) = item { pending += children }
        }
        return Array(result.reversed())
    }

    private static func texts(_ scene: WidgetScene?) -> [String] {
        var result: [String] = [], pending = scene?.drawingItems ?? []
        while let item = pending.popLast() {
            if case .text(let text) = item { result.append(text.text) }
            if case .transformed(_, let children) = item { pending += children }
            if case .antialias(_, let children) = item { pending += children }
        }
        return Array(result.reversed())
    }

    private static func paintedInk(_ view: NSView, scale: Int = 1) throws -> Int {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, bounds.width <= 512, bounds.height <= 512,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(bounds.width * Double(scale))),
                pixelsHigh: Int(ceil(bounds.height * Double(scale))), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bytes = rep.bitmapData else { throw Failure.bitmap }
        rep.size = bounds.size
        bytes.initialize(repeating: 0, count: rep.bytesPerRow * rep.pixelsHigh)
        view.cacheDisplay(in: bounds, to: rep)
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { throw Failure.bitmap }
                if color.alphaComponent > 0.01 { count += 1 }
            }
        }
        return count
    }
}
