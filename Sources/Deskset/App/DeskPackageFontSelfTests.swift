import AppKit
import CoreText
import DeskLanguage
import DesksetCore
import DesksetDraw

/// Real, locally renamed system-font bytes; no third-party font fixture is stored in the repository.
enum DeskPackageFontSelfTests {
    private static let worker = DispatchQueue(label: "desk.package.font.tests")
    private enum Failure: Error { case fixture }

    private static func fixture(_ t: AppTestRunner, family: String) throws -> URL {
        let root = t.temporaryDirectory("package-fonts")
        guard AppSelfTest.makeTestFont(family: family, at: root.appendingPathComponent("Fonts/Face.ttf")) else {
            t.check(false, "required real font fixture could not be constructed")
            throw Failure.fixture
        }
        try Data(#"widget { Text("Actual font").font("\#(family)", 18) }"#.utf8)
            .write(to: root.appendingPathComponent("Main.desk"))
        return root
    }

    private static func capture(_ root: URL) throws -> DeskPackageCapture {
        try worker.sync { try DeskPackageCapture.read(root: root) }
    }

    private static func prepare(_ capture: DeskPackageCapture) -> DeskProgramResources.Prepared {
        worker.sync { DeskProgramResources.prepare(capture: capture, literals: []) }
    }

    static func run(_ t: AppTestRunner) {
        t.suite("App: Desk package fonts: real package preview and activated desktop release their independent leases") {
            let family = "DesksetPkgC", source = try fixture(t, family: family)
            let root = t.temporaryDirectory("package-font-owners")
            let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                skinsDirectory: root.appendingPathComponent("Skins"), layoutsDirectory: root.appendingPathComponent("Layouts"),
                backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
                settingsDirectory: root.appendingPathComponent("Settings"), widgetsDirectory: root.appendingPathComponent("Widgets"),
                presentsWindows: false)
            t.atSuiteEnd {
                for window in app.codeFileWindows { window.window?.close() }
                _ = app.stopAllForTermination()
                _ = AppSelfTest.spin(timeout: 10) { app.deskWidgetWindows.values.allSatisfy(\.isClosed) }
                app.endEngineThread()
            }
            let input = try worker.sync { try DeskCodePackageInput(capture: DeskPackageCapture.read(root: source),
                                                                  member: DeskFileID(path: "Main.desk")) }
            let controller = try app.showCodePackage(input, line: nil)
            t.check(AppSelfTest.spin(timeout: 10) { controller.deskPreview?.state == .ready })
            guard let preview = controller.deskPreview, preview.state == .ready else { throw Failure.fixture }
            t.check(controller.window?.isVisible == false)
            t.equal(DeskConditionalTestSupport.texts(preview.scene), ["Actual font"])
            t.equal(Fonts.installedFamily(named: family), family)
            let packageID = UUID()
            let directory = app.widgetsDirectory.appendingPathComponent(packageID.uuidString.lowercased())
            try FileManager.default.createDirectory(at: app.widgetsDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: directory)
            let state = DeskWidgetSourceState(id: UUID(), entry: packageID.uuidString.lowercased() + "/Main.desk", packageID: packageID)
            let instance = DeskWidgetInstanceState(id: UUID(), sourceID: state.id)
            try app.state.registerDeskInstallation(sources: [state], instances: [instance])
            var result: Result<DeskWidgetWindowController, Error>?
            app.activateDeskWidgetAsync(instanceID: instance.id, preferredLanguages: { ["en"] }) { result = $0 }
            t.check(AppSelfTest.spin(timeout: 10) { result != nil })
            guard let result else { throw Failure.fixture }
            let desktop = try result.get()
            t.check(AppSelfTest.spin(timeout: 10) { desktop.isStarted && desktop.latestPresented != nil })
            t.check(!desktop.window.isVisible)
            t.equal(DeskConditionalTestSupport.texts(desktop.latestPresented?.scene), ["Actual font"])
            for scene in [preview.scene, desktop.latestPresented?.scene] {
                var pending = scene?.drawingItems ?? [], count = 0
                while let item = pending.popLast() {
                    switch item {
                    case .text(let draw):
                        count += 1
                        t.equal(draw.style.fontFace, family)
                        t.equal(CTFontCopyFamilyName(Fonts.resolve(Fonts.request(for: draw.style)).font) as String, family)
                    case .transformed(_, let children), .antialias(_, let children): pending += children
                    default: break
                    }
                }
                t.equal(count, 1, "actual owner scenes carry the native font, not an empty success")
            }
            controller.window?.close()
            t.equal(Fonts.installedFamily(named: family), family, "closing preview leaves desktop's registration alive")
            _ = app.stopAllForTermination()
            t.check(AppSelfTest.spin(timeout: 10) { desktop.isClosed && Fonts.installedFamily(named: family) == nil })
        }
        t.suite("App: Desk package fonts: cancellation after native registration releases the worker result") {
            let family = "DesksetPkgD", source = try fixture(t, family: family)
            let widgets = t.temporaryDirectory("cancelled-font-activation"), id = UUID()
            let directory = widgets.appendingPathComponent(id.uuidString.lowercased())
            try FileManager.default.copyItem(at: source, to: directory)
            let state = DeskWidgetSourceState(id: UUID(), entry: id.uuidString.lowercased() + "/Main.desk", packageID: id)
            let generation = Fonts.generation
            var observedRegistered = false
            do {
                let completed = DispatchSemaphore(value: 0)
                let result = Guarded<Result<DeskWidgetActivation.Prepared, Error>?>(nil)
                worker.async {
                    let prepared = Result {
                        try DeskWidgetActivation.prepare(source: .init(state), widgetsRoot: widgets,
                            options: DeskServiceOptions(fonts: DeskFontCatalog()), isCancelled: {
                                let registered = Fonts.installedFamily(named: family) != nil
                                if registered { observedRegistered = true }
                                return registered
                            })
                    }
                    result.access { $0 = prepared }
                    completed.signal()
                }
                completed.wait()
                guard let result = result.current else { throw Failure.fixture }
                let ready = try result.get()
                ready.resources.removeCopies()
                t.check(false, "activation must not hand off a cancelled font lease")
            } catch DeskWidgetActivation.Failure.cancelled {
                t.check(observedRegistered, "cancellation was injected after actual registration, not before preparation")
            }
            t.equal(Fonts.installedFamily(named: family), nil)
            t.check(Fonts.generation >= generation + 2, "both registration and cancellation release invalidate old layouts")
        }

        t.suite("App: Desk package fonts: captured bytes register for preview and desktop owners and release by generation") {
            let family = "DesksetPkgA", root = try fixture(t, family: family)
            let captured = try capture(root)
            let input = try worker.sync { try DeskCodePackageInput(capture: captured, member: DeskFileID(path: "Main.desk")) }
            t.equal(input.package.file(at: "Fonts/Face.ttf")?.fontFamilies, [family])
            t.equal(Fonts.installedFamily(named: family), nil, "metadata inspection is not registration")
            let generation = Fonts.generation
            var style = TextStyle(); style.fontFace = family; style.fontSize = 18; style.accurateText = true
            let preview = TextLayoutCache(), desktop = TextLayoutCache()
            let fallback = preview.layout("Actual font", style: style, wrapWidth: nil, cycle: 0)
            let first = prepare(captured), second = prepare(captured)
            defer { first.removeCopies(); second.removeCopies() }
            t.equal(first.failure, nil); t.equal(second.failure, nil)
            t.check(Fonts.generation > generation)
            let registered = Fonts.generation
            t.equal(Fonts.installedFamily(named: family), family)
            for cache in [preview, desktop] {
                let layout = cache.layout("Actual font", style: style, wrapWidth: nil, cycle: 0)
                let font = layout.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                t.equal(font?.familyName, family, "both drawing caches consume the captured native font")
                t.check(layout !== fallback)
            }
            let resolved = Fonts.resolve(.init(face: family, size: 18)).font
            let copy = CTFontCopyAttribute(resolved, kCTFontURLAttribute) as? URL
            t.check(copy != nil && copy?.path.hasPrefix(root.path + "/") == false)
            try FileManager.default.removeItem(at: root)
            t.check(first.copiesUnchanged() && second.copiesUnchanged(), "drawing never reopens original fonts")
            first.removeCopies(); first.removeCopies()
            t.check(!first.copiesUnchanged() && second.copiesUnchanged())
            t.equal(Fonts.generation, registered, "one owner cannot unregister another owner's identical bytes")
            t.equal(Fonts.installedFamily(named: family), family)
            second.removeCopies()
            t.check(Fonts.generation > registered)
            t.equal(Fonts.installedFamily(named: family), nil)
            if let copy { t.check(!FileManager.default.fileExists(atPath: copy.path), "last release removes the registration copy") }
            let after = preview.layout("Actual font", style: style, wrapWidth: nil, cycle: 0)
            t.check(after !== fallback, "a previously cached generation is not reused after release")
            let font = after.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            t.check(font?.familyName != family)
            let replacement = prepare(captured)
            defer { replacement.removeCopies() }
            t.equal(replacement.failure, nil)
            t.check(!first.copiesUnchanged(), "a new lease cannot revive a released generation")
            t.equal(Fonts.installedFamily(named: family), family)
        }

        t.suite("App: Desk package fonts: invalid bytes warn and fall back without claiming registration") {
            let root = t.temporaryDirectory("invalid-package-font")
            try Data("not a font".utf8).write(to: root.appendingPathComponent("Missing.ttf"))
            try Data(#"widget { Text("Fallback").font("DesksetBadF", 18) }"#.utf8)
                .write(to: root.appendingPathComponent("Main.desk"))
            let captured = try capture(root)
            let input = try worker.sync { try DeskCodePackageInput(capture: captured, member: DeskFileID(path: "Main.desk")) }
            t.equal(input.package.file(at: "Missing.ttf")?.fontFamilies, nil)
            let service = DeskLanguageService(package: input.package, openFile: input.member,
                                              options: DeskServiceOptions(fonts: DeskFontCatalog()))
            t.check(service.snapshot.packageCheck().allDiagnostics.contains { $0.id == .fontNotInstalled })
            let generation = Fonts.generation, prepared = prepare(captured)
            defer { prepared.removeCopies() }
            t.equal(prepared.failure, nil)
            t.equal(prepared.fonts?.invalidPaths, ["Missing.ttf"])
            t.equal(Fonts.generation, generation)
            t.check(CTFontCopyFamilyName(Fonts.resolve(.init(face: "DesksetBadF", size: 18)).font) as String != "DesksetBadF")
            prepared.removeCopies()
            t.check(!prepared.copiesUnchanged(), "even a font-only empty registration lease expires")
        }

        t.suite("App: Desk package fonts: duplicate paths share ownership and rejected versions do not steal registrations") {
            let family = "DesksetPkgB", root = try fixture(t, family: family)
            let data = try Data(contentsOf: root.appendingPathComponent("Fonts/Face.ttf"))
            let first = Fonts.acquirePackageFonts([(path: "first.ttf", bytes: data), (path: "alias.ttf", bytes: data)])
            defer { first.release() }
            t.equal(first.failedPaths, [])
            t.equal(Fonts.installedFamily(named: family), family)
            let generation = Fonts.generation
            // Same PostScript face with different captured bytes cannot silently resolve to the live old copy.
            let rejected = Fonts.acquirePackageFonts([(path: "changed.ttf", bytes: data + Data([0]))])
            defer { rejected.release() }
            t.equal(rejected.failedPaths, ["changed.ttf"])
            rejected.release()
            t.equal(Fonts.generation, generation)
            t.equal(Fonts.installedFamily(named: family), family)
            first.release()
            t.equal(Fonts.installedFamily(named: family), nil, "duplicate paths did not leak an extra reference")
            do {
                let abandoned = Fonts.acquirePackageFonts([(path: "cancelled.ttf", bytes: data)])
                t.check(abandoned.isActive)
                t.equal(Fonts.installedFamily(named: family), family)
            }
            t.equal(Fonts.installedFamily(named: family), nil, "abandoned worker results release through ARC")
        }
    }
}
