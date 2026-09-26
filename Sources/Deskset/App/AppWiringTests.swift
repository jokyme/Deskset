import AppKit
import CoreAudio
import CoreText
import ImageIO
import DesksetCore

/// Checks of the app wiring around the compatibility round: Info.plist, installing ZIPs and folders, font folders,
/// FileView icons, audio capture pausing, Lua FadeWindow, permission notes (added, and taken back once granted).
extension AppSelfTest {
    static func wiringTests(_ t: AppTestRunner) {
        infoPlistTests(t)
        installFormatTests(t)
        fontTests(t)
        fileViewIconTests(t)
        audioPauseTests(t)
        fadeWindowTests(t)
        permissionNoteTests(t)
        registrationTests(t)
        desktopPictureTests(t)
    }

    // MARK: Info.plist

    static func infoPlistTests(_ t: AppTestRunner) {
        t.suite("App: Info.plist usage descriptions and document types") {
            guard let script = Paths.repositoryFolder("scripts")?.appendingPathComponent("build-app.sh"),
                  FileManager.default.fileExists(atPath: script.path) else {
                print("    (skipped: scripts/build-app.sh not found; run from the repository)")
                return
            }
            let out = t.temporaryDirectory("plist").appendingPathComponent("Info.plist")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, "--plist", out.path]
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            t.equal(process.terminationStatus, 0, "the script writes a plist that passes plutil -lint")
            guard let data = try? Data(contentsOf: out),
                  let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else {
                t.check(false, "Info.plist readable")
                return
            }
            for key in ["NSAudioCaptureUsageDescription", "NSMicrophoneUsageDescription", "NSAppleEventsUsageDescription",
                        "NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription",
                        "NSDesktopFolderUsageDescription", "NSDocumentsFolderUsageDescription",
                        "NSDownloadsFolderUsageDescription", "NSRemovableVolumesUsageDescription",
                        "NSNetworkVolumesUsageDescription", "NSLocalNetworkUsageDescription"] {
                let text = plist[key] as? String ?? ""
                t.check(text.count > 40 && !text.contains("Rainmeter"), "\(key): \(text)")
            }
            t.check((plist["NSAudioCaptureUsageDescription"] as? String)?.contains("never recorded") == true)
            let ats = plist["NSAppTransportSecurity"] as? [String: Any]
            t.equal(ats?["NSAllowsArbitraryLoads"] as? Bool, true)
            t.equal(plist["LSUIElement"] as? Bool, true)
            let types = plist["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
            func rank(_ type: String) -> String? {
                types.first { ($0["LSItemContentTypes"] as? [String])?.contains(type) == true }?["LSHandlerRank"] as? String
            }
            t.equal(rank("app.deskset.rmskin"), "Owner")
            t.equal(rank("com.pkware.zip-archive"), "Alternate", "never the default .zip handler")
            t.equal(rank("public.folder"), "Alternate")
            let name = plist["CFBundleName"] as? String ?? ""
            t.check(!name.lowercased().contains("rainmeter"))

            // (review) A relative output path is relative to the caller, not to the repository.
            let callerDir = t.temporaryDirectory("plist-relative")
            let relative = Process()
            relative.executableURL = URL(fileURLWithPath: "/bin/bash")
            relative.arguments = [script.path, "--plist", "Relative.plist"]
            relative.currentDirectoryURL = callerDir
            relative.standardOutput = FileHandle.nullDevice
            try relative.run()
            relative.waitUntilExit()
            t.equal(relative.terminationStatus, 0)
            t.check(FileManager.default.fileExists(atPath: callerDir.appendingPathComponent("Relative.plist").path))
            t.check(!FileManager.default.fileExists(
                atPath: script.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("Relative.plist").path), "nothing written into the repository")
        }
    }

    // MARK: Installing archives and folders

    /// A ZIP (no .rmskin footer) of `files`.
    static func makeZip(_ t: AppTestRunner, name: String, files: [String: Data]) throws -> URL {
        try makeZip(in: t.temporaryDirectory("zip"), name: name, files: files)
    }

    static func makeZip(in dir: URL, name: String, files: [String: Data]) throws -> URL {
        let content = dir.appendingPathComponent("content")
        for (path, data) in files {
            let url = content.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let zip = dir.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", content.path, zip.path]
        try process.run()
        process.waitUntilExit()
        return zip
    }

    static func installFormatTests(_ t: AppTestRunner) {
        t.suite("App: installing ZIP archives and folders") {
            guard let app = try makeApp(t) else { return }
            let skins = app.skinsDirectory
            let skin = Data("[Rainmeter]\nUpdate=1000\n[M]\nMeter=String\nText=Zip\n".utf8)

            // What open() accepts.
            let folder = t.temporaryDirectory("folder").appendingPathComponent("Loose Skin", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try skin.write(to: folder.appendingPathComponent("Loose.ini"))
            let text = t.temporaryDirectory("text").appendingPathComponent("notes.txt")
            try Data("x".utf8).write(to: text)
            func disposition(_ url: URL) -> SkinInstallFlow.Disposition {
                SkinInstallFlow.disposition(of: url, skinsDirectory: skins)
            }
            t.equal(disposition(URL(fileURLWithPath: "/tmp/x.rmskin")), .install)
            t.equal(disposition(URL(fileURLWithPath: "/tmp/x.ZIP")), .install)
            t.equal(disposition(folder), .install)
            t.equal(disposition(text), .unsupported)
            t.equal(disposition(skins), .alreadyInSkinsFolder)
            t.equal(disposition(skins.appendingPathComponent("App")), .alreadyInSkinsFolder)
            t.equal(disposition(skins.deletingLastPathComponent()), .containsSkinsFolder, "a folder holding Skins")
            t.equal(disposition(URL(fileURLWithPath: "/")), .containsSkinsFolder)
            t.equal(disposition(skins.appendingPathComponent("../Skins/App/")), .alreadyInSkinsFolder)
            let types = SkinInstallFlow.openPanelTypes.map(\.identifier)
            t.check(types.contains("public.zip-archive") && types.contains("public.folder"), "\(types)")

            // A folder inside the Skins folder is refused before anything is copied.
            app.installer.open([skins.appendingPathComponent("App")])
            t.check(app.installer.isIdle)
            t.check(app.lastAlert?.title.contains("already in the Skins folder") == true, "\(String(describing: app.lastAlert))")
            // A folder holding it (review): refused with a message that says so, not "already in the Skins folder".
            app.installer.open([skins.deletingLastPathComponent()])
            t.check(app.installer.isIdle)
            t.equal(app.lastAlert?.title,
                    "“\(skins.deletingLastPathComponent().lastPathComponent)” contains Deskset’s Skins folder")
            t.equal(app.lastAlert?.text, SkinInstallFlow.containsSkinsFolderMessage)

            // Messages.
            t.equal(SkinInstallFlow.message(for: .nothingToInstall),
                    "This file or folder doesn’t contain any Rainmeter skins.")
            t.check(SkinInstallFlow.message(for: .severalPackages(["A.rmskin", "B.rmskin"])).contains("“B.rmskin”"))
            t.check(SkinInstallFlow.message(for: .alreadyInSkinsFolder).contains("Refresh All"))

            // An archive without skins.
            let photos = try makeZip(t, name: "Photos.zip", files: ["a.jpg": Data([0xFF, 0xD8, 0xFF])])
            app.installer.open([photos])
            spin { app.installer.isIdle }
            t.equal(app.lastAlert?.text, "This file or folder doesn’t contain any Rainmeter skins.")

            // A plain ZIP of one root config: summary wording, installed, its skin loaded.
            let zip = try makeZip(t, name: "Zipped Clock.zip", files: [
                "Zipped Clock/Clock.ini": skin,
                "Zipped Clock/Fonts/Face.otc": Data("not really a font".utf8),
            ])
            let inspection = try RmskinPackage.inspect(zip)
            let summary = InstallSummary(inspection, packageName: zip.lastPathComponent, skinsDirectory: skins)
            inspection.cleanup()
            t.equal(summary.title, "Install “Zipped Clock”?")
            t.equal(summary.subtitle, "A plain archive: no author or version information.")
            t.check(summary.formatNote?.contains("not a skin package made with") == true)
            t.check(summary.formatNote?.contains("folder is copied") == false)
            t.equal(summary.fonts, ["Face.otc"])
            let view = SkinInstallFlow.accessoryView(summary, headerImage: nil)
            t.check(view.frame.height > 40)
            app.installer.open([zip])
            spin { app.installer.isIdle && app.controller(for: "Zipped Clock") != nil }
            t.check(app.controller(for: "Zipped Clock") != nil, "the only skin of a plain archive is loaded")
            t.check(FileManager.default.fileExists(
                atPath: skins.appendingPathComponent("Zipped Clock/@Resources/Fonts/Face.otc").path),
                    "a root config's Fonts folder goes to @Resources/Fonts")

            // A folder: copied, the original kept.
            let folderInspection = try RmskinPackage.inspect(folder)
            let folderSummary = InstallSummary(folderInspection, packageName: folder.lastPathComponent,
                                               skinsDirectory: skins)
            folderInspection.cleanup()
            t.equal(folderSummary.title, "Install “Loose Skin”?")
            t.equal(folderSummary.subtitle, "A plain folder: no author or version information.")
            t.check(folderSummary.formatNote?.contains("The folder is copied") == true)
            app.installer.open([folder])
            spin { app.installer.isIdle && app.controller(for: "Loose Skin") != nil }
            t.check(app.controller(for: "Loose Skin") != nil)
            t.check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Loose.ini").path),
                    "the original folder stays")
        }
    }

    // MARK: Fonts

    /// A copy of Courier New renamed to `family` (exactly 11 characters), so a test can register a family that no
    /// Mac has. Nil when the system font is missing.
    static func makeTestFont(family: String, at url: URL) -> Bool {
        guard family.utf8.count == 11,
              var data = try? Data(contentsOf: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Courier New.ttf"))
        else { return false }
        func utf16(_ s: String) -> [UInt8] { s.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } }
        func replace(_ a: [UInt8], _ b: [UInt8]) {
            var bytes = [UInt8](data)
            var i = 0
            while i + a.count <= bytes.count {
                if bytes[i] == a[0], Array(bytes[i..<(i + a.count)]) == a {
                    bytes.replaceSubrange(i..<(i + a.count), with: b)
                    i += a.count
                } else {
                    i += 1
                }
            }
            data = Data(bytes)
        }
        let ps = family + "P"
        for (a, b) in [("Courier New", family), ("CourierNewPS", ps)] {
            replace(Array(a.utf8), Array(b.utf8))
            replace(utf16(a), utf16(b))
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    static func familyAvailable(_ family: String) -> Bool {
        (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []).contains(family)
    }

    static func fontTests(_ t: AppTestRunner) {
        t.suite("App: font folders") {
            let root = t.temporaryDirectory("fonts")
            let folder = root.appendingPathComponent("@Resources/Fonts").path
            // Font file types.
            let listing = root.appendingPathComponent("listing")
            try FileManager.default.createDirectory(at: listing, withIntermediateDirectories: true)
            for name in ["a.ttf", "b.OTF", "c.ttc", "d.otc", "e.woff", ".f.ttf", "g.txt"] {
                try Data().write(to: listing.appendingPathComponent(name))
            }
            t.equal(Fonts.fontFiles(in: listing.path)?.map { ($0 as NSString).lastPathComponent },
                    ["a.ttf", "b.OTF", "c.ttc", "d.otc"])
            t.check(Fonts.fontFiles(in: folder) == nil, "a missing folder is nil, not empty")

            // A missing folder is looked for again later, not remembered for good.
            Fonts.registerFolder(folder, now: 1000)
            t.check(Fonts.isRememberedAsMissing(folder))
            guard makeTestFont(family: "DesksetTstA", at: URL(fileURLWithPath: folder).appendingPathComponent("A.ttf"))
            else {
                print("    (skipped: Courier New not found)")
                return
            }
            Fonts.registerFolder(folder, now: 1001)
            t.check(!familyAvailable("DesksetTstA"), "not looked for again right away")
            let before = Fonts.generation
            Fonts.registerFolder(folder, now: 1000 + Fonts.missingFolderRecheck + 1)
            t.check(familyAvailable("DesksetTstA"), "registered once the folder exists")
            t.check(Fonts.generation != before)
            t.check(!Fonts.isRememberedAsMissing(folder))

            // Removing the file and the folder unregisters the font; Refresh All reads known folders again.
            try FileManager.default.removeItem(atPath: folder)
            t.check(Fonts.rescanAllFolders(), "a removed font changes the fonts")
            t.check(!familyAvailable("DesksetTstA"))
            t.check(Fonts.isRememberedAsMissing(folder))
            t.check(!Fonts.rescanFolders([folder, folder]), "nothing changed")
        }

        t.suite("App: font copies (review): location, cleaners, long names, the same font in two skins") {
            // The app keeps its copies out of the temporary folder (emptied nightly of files older than 3 days).
            let appBase = Fonts.copiesBase(appBundle: true).path
            t.check(appBase.hasSuffix("/Library/Caches/Deskset/Fonts"), appBase)
            t.check(Fonts.copiesBase(appBundle: false).path.hasPrefix(FileManager.default.temporaryDirectory.path))

            let root = t.temporaryDirectory("fontcopies")
            let folder = root.appendingPathComponent("A/@Resources/Fonts")
            let long = String(repeating: "L", count: 250) + ".ttf"
            let fontPath = folder.appendingPathComponent(long).path
            guard makeTestFont(family: "DesksetTstG", at: URL(fileURLWithPath: fontPath)) else {
                print("    (skipped: Courier New not found)")
                return
            }
            t.check(Fonts.rescanFolder(folder.path))
            t.check(familyAvailable("DesksetTstG"), "a font whose file name is 254 bytes long registers")
            guard let copy = Fonts.registeredCopy(ofFile: fontPath) else {
                t.check(false, "a copy is registered")
                return
            }
            t.check(copy.lastPathComponent.utf8.count < 24, copy.lastPathComponent)
            // A cleaning utility deletes the copy: it is made again from the unchanged original…
            try FileManager.default.removeItem(at: copy)
            t.check(!Fonts.rescanFolder(folder.path), "an unchanged font is not registered again")
            t.check(FileManager.default.fileExists(atPath: copy.path), "the deleted copy is made again")
            // …so the font can still be unregistered when the original goes away.
            try FileManager.default.removeItem(atPath: fontPath)
            t.check(Fonts.rescanFolder(folder.path))
            t.check(!familyAvailable("DesksetTstG"), "unregistered through the restored copy")

            // The same font in two skins: when the skin that registered it loses it, the other one's file takes over.
            let x = root.appendingPathComponent("X/@Resources/Fonts")
            let y = root.appendingPathComponent("Y/@Resources/Fonts")
            let yFont = y.appendingPathComponent("H.ttf").path
            guard makeTestFont(family: "DesksetTstH", at: x.appendingPathComponent("H.ttf")),
                  makeTestFont(family: "DesksetTstH", at: URL(fileURLWithPath: yFont)) else { return }
            Fonts.rescanFolder(x.path)
            Fonts.rescanFolder(y.path)
            t.check(familyAvailable("DesksetTstH"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("X"))
            Fonts.rescanFolder(x.path)
            Fonts.rescanFolder(y.path)
            t.check(familyAvailable("DesksetTstH"), "the second skin's copy of the font is registered")
            t.check(Fonts.registeredCopy(ofFile: yFont) != nil)
            t.check(!Fonts.rescanFolder(y.path), "and not registered again after that")
            try FileManager.default.removeItem(at: root.appendingPathComponent("Y"))
            Fonts.rescanFolder(y.path)
            t.check(!familyAvailable("DesksetTstH"))
        }

        t.suite("App: fonts added later re-measure running skins") {
            guard let app = try makeApp(t) else { return }
            let dir = app.skinsDirectory.appendingPathComponent("FontRoot/Widget", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ini = "[Rainmeter]\nUpdate=1000\n[Text]\nMeter=String\nFontFace=DesksetTstC\nFontSize=20\n"
                + "Text=iiiiiiiiiiii\n"
            try ini.write(to: dir.appendingPathComponent("Widget.ini"), atomically: true, encoding: .utf8)
            app.rescanLibrary()
            guard let c = app.activate(config: "FontRoot\\Widget", file: "Widget.ini"),
                  let meter = c.skin.meter(named: "Text") else {
                t.check(false, "skin loaded")
                return
            }
            let fallbackWidth = meter.frame.width
            let fonts = app.skinsDirectory.appendingPathComponent("FontRoot/@Resources/Fonts")
            guard makeTestFont(family: "DesksetTstC", at: fonts.appendingPathComponent("C.ttf")) else {
                print("    (skipped: Courier New not found)")
                return
            }
            // What an installation does: rescan the root config's font folder, then AppController.fontsChanged().
            t.check(Fonts.rescanFolders([fonts.path]))
            app.fontsChanged()
            t.check(meter.frame.width > fallbackWidth * 1.5,
                    "monospaced i's are wider than the fallback's: \(fallbackWidth) → \(meter.frame.width)")
            t.check(c.skin.width >= meter.frame.width, "the window size follows")

            // An installed package's fonts are registered before its skin loads; Refresh All picks up a font file
            // replaced afterwards.
            let fontD = t.temporaryDirectory("fontD").appendingPathComponent("D.ttf")
            guard makeTestFont(family: "DesksetTstD", at: fontD) else { return }
            let skin = "[Rainmeter]\nUpdate=1000\n[Text]\nMeter=String\nFontFace=DesksetTstD\nText=x\n"
            let package = try makePackage(t, name: "Fonts.rmskin", files: [
                "RMSKIN.ini": Data("[rmskin]\nName=Fonts\nLoadType=Skin\nLoad=FontPkg\\Main\\Main.ini\n".utf8),
                "Skins/FontPkg/Main/Main.ini": Data(skin.utf8),
                "Skins/FontPkg/@Resources/Fonts/D.ttf": try Data(contentsOf: fontD),
            ])
            app.installer.open([package])
            spin { app.installer.isIdle && app.controller(for: "FontPkg\\Main") != nil }
            t.check(app.controller(for: "FontPkg\\Main") != nil)
            t.check(familyAvailable("DesksetTstD"), "the package's font is registered")
            let installed = app.skinsDirectory.appendingPathComponent("FontPkg/@Resources/Fonts/D.ttf")
            try FileManager.default.removeItem(at: installed)
            guard makeTestFont(family: "DesksetTstE", at: installed) else { return }
            app.refreshAll(rescan: true)
            t.check(familyAvailable("DesksetTstE"), "Refresh All registers a font replaced in @Resources/Fonts")
            t.check(!familyAvailable("DesksetTstD"), "and drops the one it replaced")
        }
    }

    // MARK: FileView icons

    static func fileViewIconTests(_ t: AppTestRunner) {
        t.suite("App: FileView icons") {
            // Real icons from the system's icon service: allowed here, asked for off the main thread with a time-out.
            IconServiceGuard.beginAllowing()
            defer { IconServiceGuard.endAllowing() }
            t.check(FileViewIcons.writer != nil, "installed at startup")
            let dir = t.temporaryDirectory("icons")
            let file = dir.appendingPathComponent("document.txt")
            try Data("hello".utf8).write(to: file)
            let ico = dir.appendingPathComponent("icon1.ico").path
            var ok = false
            var onMain = true
            // Called on a background thread, like FileView does (a sync dispatch could run on this thread).
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                onMain = Thread.isMainThread
                ok = FileViewIconWriter.write(source: file.path, pixelSize: 48, destination: ico)
                done.signal()
            }
            // The icons are drawn by the system's icon service. On CI's Intel runner it has not answered (the main thread
            // waited for it forever): without an answer in 30 s the icons cannot be checked here.
            guard done.wait(timeout: .now() + 30) == .success else {
                print("    (skipped: the system's icon service did not answer within 30 s)")
                return
            }
            t.check(ok && !onMain)
            let image = Images.cgImage(atPath: ico)
            t.equal(image?.width, 48, "the Image meter loads the written icon")
            if FileViewIconWriter.canWriteICO,
               let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: ico) as CFURL, nil) {
                t.equal(CGImageSourceGetType(source) as String?, "com.microsoft.ico", "a real .ico file")
            }
            // Other extensions and large sizes are PNG data; missing folders are created; odd sizes are clamped.
            let png = dir.appendingPathComponent("sub/folder icon.png").path
            t.check(FileViewIconWriter.write(source: dir.path, pixelSize: 256, destination: png))
            t.equal(Images.cgImage(atPath: png)?.width, 256)
            let big = dir.appendingPathComponent("big.ico").path
            t.check(FileViewIconWriter.write(source: file.path, pixelSize: 100_000, destination: big))
            t.equal(Images.cgImage(atPath: big)?.width, FileViewIconWriter.maxPixelSize)
            t.check(FileViewIconWriter.write(source: file.path, pixelSize: -5, destination: dir.appendingPathComponent("tiny.ico").path))
            t.check(!FileViewIconWriter.write(source: file.path, pixelSize: 16, destination: ""))
            // Rewritten in place (atomically): the cache sees the new file.
            t.check(FileViewIconWriter.write(source: file.path, pixelSize: 16, destination: ico))
            t.equal(Images.cgImage(atPath: ico)?.width, 16)
            // (review) Several children write at once on FileView's concurrent queue, often the same folder icon.
            let results = NSMutableArray()
            DispatchQueue.concurrentPerform(iterations: 12) { i in
                let ok = FileViewIconWriter.write(source: i % 2 == 0 ? dir.path : file.path, pixelSize: 32 + i,
                                                  destination: dir.appendingPathComponent("many/icon\(i).ico").path)
                objc_sync_enter(results); results.add(ok); objc_sync_exit(results)
            }
            t.equal(results.count, 12)
            t.check(results.allSatisfy { ($0 as? Bool) == true })
            t.equal(Images.cgImage(atPath: dir.appendingPathComponent("many/icon11.ico").path)?.width, 43)

            // End to end: a FileView child with Type=Icon in a running skin.
            guard let app = try makeApp(t) else { return }
            let skinDir = app.skinsDirectory.appendingPathComponent("IconRoot/Files", isDirectory: true)
            try FileManager.default.createDirectory(at: skinDir.appendingPathComponent("Items"),
                                                    withIntermediateDirectories: true)
            try Data("x".utf8).write(to: skinDir.appendingPathComponent("Items/readme.txt"))
            let ini = """
            [Rainmeter]
            Update=100
            [P]
            Measure=Plugin
            Plugin=FileView
            Path=#CURRENTPATH#Items
            ShowDotDot=0
            Count=1
            [I]
            Measure=Plugin
            Plugin=FileView
            Path=[P]
            Type=Icon
            Index=1
            IconSize=Medium
            [Img]
            Meter=Image
            MeasureName=I
            """
            try ini.write(to: skinDir.appendingPathComponent("Files.ini"), atomically: true, encoding: .utf8)
            app.rescanLibrary()
            guard let c = app.activate(config: "IconRoot\\Files", file: "Files.ini"),
                  let measure = c.skin.measure(named: "I") else {
                t.check(false, "skin loaded")
                return
            }
            spin {
                c.skin.update()
                return !measure.stringValue.isEmpty
            }
            t.equal(measure.stringValue, skinDir.appendingPathComponent("icon1.ico").path)
            t.equal(Images.cgImage(atPath: measure.stringValue)?.width, 32, "IconSize=Medium is 32 pixels")
        }
    }

    // MARK: Audio capture while updates are paused

    /// A backend that runs, flags itself as silenced by a refused permission, and lets the test feed samples.
    final class SilenceBackend: AudioCaptureBackend {
        let deviceID: AudioObjectID? = 7
        var deliversSilenceWhenRefused: Bool { true }
        private(set) var ring: AudioRingBuffer?

        func start(ring: AudioRingBuffer, events: AudioBackendEvents) -> AudioSourceStatus {
            self.ring = ring
            return AudioSourceStatus(running: true, deviceName: "Fake", deviceUID: "Fake", format: "", sampleRate: 48000,
                                     channels: 2)
        }

        func stop() {}

        func feed(_ value: Float) {
            let samples = [Float](repeating: value, count: 512 * 2)
            samples.withUnsafeBufferPointer { ring?.write(interleaved: $0.baseAddress!, frames: 512, channels: 2) }
        }
    }

    static func audioPauseTests(_ t: AppTestRunner) {
        t.suite("App: audio capture is suspended while skin updates are paused") {
            guard let app = try makeApp(t) else { return }
            var backends: [AudioSourceKey: AudioSelfTests.FakeBackend] = [:]
            var created: [AudioSourceKey: Int] = [:]
            let lock = NSLock()
            let engine = AudioSelfTests.makeEngine { key in
                let b = AudioSelfTests.FakeBackend()
                lock.lock(); backends[key] = b; created[key, default: 0] += 1; lock.unlock()
                return b
            }
            app.audioEngine = engine
            let output = AudioSourceKey(kind: .output, deviceID: nil)
            let input = AudioSourceKey(kind: .input, deviceID: nil)
            let a = AudioAnalyzer(settings: AudioAnalysisSettings())
            engine.subscribe(a, to: output)
            engine.drain()
            t.equal(backends[output]?.starts, 1)
            t.check(engine.status(for: output).running)

            app.simulatePause(screensAsleep: true)
            engine.drain()
            t.check(engine.isSuspended)
            t.equal(backends[output]?.stops, 1, "the capture stops while the displays sleep")
            t.check(!engine.status(for: output).running)
            // A skin loaded meanwhile subscribes, but nothing captures until the resume.
            let b = AudioAnalyzer(settings: AudioAnalysisSettings())
            engine.subscribe(b, to: input)
            engine.drain()
            t.check(backends[input] == nil)
            app.simulatePause(systemAsleep: true)
            app.simulatePause(screensAsleep: false)
            engine.drain()
            t.check(engine.isSuspended, "still asleep")

            app.simulatePause(systemAsleep: false)
            engine.drain()
            t.check(!engine.isSuspended)
            t.equal(created[output], 2, "started again on wake")
            t.equal(backends[output]?.starts, 1)
            t.equal(created[input], 1, "the subscription made while paused starts too")
            t.check(engine.status(for: output).running && engine.status(for: input).running)
            engine.unsubscribe(a)
            engine.unsubscribe(b)
            engine.drain()
        }

        t.suite("App: audio silence watchdog notes a refused permission") {
            let backend = SilenceBackend()
            let engine = AudioCaptureEngine()
            engine.isCaptureAllowed = true
            engine.stopDelay = 0
            engine.silenceCheckInterval = 0.05
            var playing = true
            engine.otherProcessPlaysAudio = { playing }
            engine.makeBackend = { _ in backend }
            let key = AudioSourceKey(kind: .output, deviceID: nil)
            let a = AudioAnalyzer(settings: AudioAnalysisSettings())
            engine.subscribe(a, to: key)
            engine.drain()
            t.check(AudioSelfTests.wait { engine.status(for: key).permissionNote != nil },
                    "silence while another app plays")
            t.equal(engine.status(for: key).permissionNote, AudioCaptureEngine.silenceNote)
            // Sound arrives (permission granted meanwhile): the note goes away.
            backend.feed(0.25)
            t.check(AudioSelfTests.wait { engine.status(for: key).permissionNote == nil }, "cleared by sound")
            engine.unsubscribe(a)
            engine.drain()

            // Nothing playing elsewhere: silence is just silence.
            playing = false
            let quiet = SilenceBackend()
            engine.makeBackend = { _ in quiet }
            let b = AudioAnalyzer(settings: AudioAnalysisSettings())
            engine.subscribe(b, to: key)
            engine.drain()
            Thread.sleep(forTimeInterval: 0.3)
            t.check(engine.status(for: key).permissionNote == nil)
            engine.unsubscribe(b)
            engine.drain()

            // An AudioLevel parent turns the note into a compatibility note of its skin.
            let skin = try AudioSelfTests.makeSkin(t, "[Rainmeter]\nUpdate=1000\n[Audio]\nMeasure=Plugin\n"
                                                   + "Plugin=AudioLevel\nPort=Input\n")
            guard let section = skin.document.section(named: "Audio") else { return }
            let denied = AudioSelfTests.makeEngine { _ in
                let f = AudioSelfTests.FakeBackend()
                f.running = false
                return f
            }
            denied.makeBackend = { _ in DeniedMicrophone() }
            let m = AudioLevelMeasure(name: "Audio", section: section, skin: skin, type: "audiolevel")
            m.engine = denied
            m.system = { AudioSelfTests.fakeSnapshot() }
            m.prepareSystem = {}
            m.mayCapture = { _ in true }
            m.readOptions()
            _ = m.computeValue()   // the first update subscribes
            denied.drain()
            _ = m.computeValue()
            t.check(skin.issues.contains(AudioPermissions.microphoneNote), "\(skin.issues)")
        }

        t.suite("App: audio permission notes are taken back once they no longer apply") {
            // The microphone allowed later in System Settings (macOS sends no notification): the refused source is
            // started again every `permissionRetryInterval` seconds, runs once allowed, and the note goes away.
            let microphone = GrantableMicrophone()
            let engine = AudioCaptureEngine()
            engine.isCaptureAllowed = true
            engine.stopDelay = 0
            engine.permissionRetryInterval = 0.05
            engine.makeBackend = { _ in microphone }
            let skin = try AudioSelfTests.makeSkin(t, "[Rainmeter]\nUpdate=1000\n[Mic]\nMeasure=Plugin\n"
                                                   + "Plugin=AudioLevel\nPort=Input\n[Out]\nMeasure=Plugin\n"
                                                   + "Plugin=AudioLevel\n", config: "AudioNotes")
            guard let micSection = skin.document.section(named: "Mic"),
                  let outSection = skin.document.section(named: "Out") else { return }
            func parent(_ section: IniSection, _ engine: AudioCaptureEngine) -> AudioLevelMeasure {
                let m = AudioLevelMeasure(name: section.name, section: section, skin: skin, type: "audiolevel")
                m.engine = engine
                m.system = { AudioSelfTests.fakeSnapshot() }
                m.prepareSystem = {}
                m.mayCapture = { _ in true }
                m.readOptions()
                _ = m.computeValue()   // the first update subscribes
                return m
            }
            let mic = parent(micSection, engine)
            engine.drain()
            _ = mic.computeValue()
            t.check(skin.issues.contains(AudioPermissions.microphoneNote), "refused: \(skin.issues)")
            // The first retry is due after 0.05 s on the HAL queue, which a busy CI runner may run late.
            t.check(AudioSelfTests.wait { microphone.starts >= 2 }, "retried: \(microphone.starts)")
            _ = mic.computeValue()
            t.check(skin.issues.contains(AudioPermissions.microphoneNote), "still refused after retries")
            microphone.granted = true
            guard let micKey = mic.parentOptions?.sourceKey else { return }
            t.check(AudioSelfTests.wait { engine.status(for: micKey).running }, "runs once allowed")
            let startsWhenRunning = microphone.starts
            _ = mic.computeValue()
            t.check(!skin.issues.contains(AudioPermissions.microphoneNote), "allowed later: \(skin.issues)")
            Thread.sleep(forTimeInterval: 0.15)
            t.equal(microphone.starts, startsWhenRunning, "a running source is not restarted")

            // The silence watchdog's note goes away once sound arrives.
            let silent = SilenceBackend()
            let watch = AudioCaptureEngine()
            watch.isCaptureAllowed = true
            watch.stopDelay = 0
            watch.silenceCheckInterval = 0.05
            watch.otherProcessPlaysAudio = { true }
            watch.makeBackend = { _ in silent }
            let out = parent(outSection, watch)
            watch.drain()
            guard let outKey = out.parentOptions?.sourceKey else { return }
            t.check(AudioSelfTests.wait { watch.status(for: outKey).permissionNote != nil }, "silence noted")
            _ = out.computeValue()
            t.check(skin.issues.contains(AudioCaptureEngine.silenceNote), "\(skin.issues)")
            silent.feed(0.25)
            t.check(AudioSelfTests.wait { watch.status(for: outKey).permissionNote == nil }, "cleared by sound")
            _ = out.computeValue()
            t.check(!skin.issues.contains(AudioCaptureEngine.silenceNote), "sound arrived: \(skin.issues)")
            withExtendedLifetime((mic, out)) {}
        }
    }

    final class DeniedMicrophone: AudioCaptureBackend {
        let deviceID: AudioObjectID? = nil
        func start(ring: AudioRingBuffer, events: AudioBackendEvents) -> AudioSourceStatus {
            AudioSourceStatus(message: "microphone access is off", permissionNote: AudioPermissions.microphoneNote)
        }
        func stop() {}
    }

    /// A microphone that is refused until `granted` (HAL queue and test thread).
    final class GrantableMicrophone: AudioCaptureBackend {
        let deviceID: AudioObjectID? = nil
        private let lock = NSLock()
        private var _granted = false
        private var _starts = 0
        var granted: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _granted }
            set { lock.lock(); _granted = newValue; lock.unlock() }
        }
        var starts: Int { lock.lock(); defer { lock.unlock() }; return _starts }

        func start(ring: AudioRingBuffer, events: AudioBackendEvents) -> AudioSourceStatus {
            lock.lock(); _starts += 1; lock.unlock()
            guard granted else {
                return AudioSourceStatus(message: "microphone access is off",
                                         permissionNote: AudioPermissions.microphoneNote)
            }
            return AudioSourceStatus(running: true, deviceName: "Fake Mic", deviceUID: "FakeMic", format: "",
                                     sampleRate: 48000, channels: 1)
        }
        func stop() {}
    }

    // MARK: Lua FadeWindow

    static func fadeWindowTests(_ t: AppTestRunner) {
        t.suite("App: Lua SKIN:FadeWindow fades without saving AlphaValue") {
            guard let app = try makeApp(t) else { return }
            let dir = app.skinsDirectory.appendingPathComponent("FadeRoot/Fader", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ini = """
            [Rainmeter]
            Update=1000
            [Script]
            Measure=Script
            ScriptFile=#CURRENTPATH#Fade.lua
            [M]
            Meter=String
            Text=Fade
            """
            let lua = """
            function Update() return 0 end
            function Out() SKIN:Bang('!SetVariable', 'Before', '1'); SKIN:FadeWindow(255, 64) end
            function Clamp() SKIN:FadeWindow(-10, 999) end
            """
            try ini.write(to: dir.appendingPathComponent("Fader.ini"), atomically: true, encoding: .utf8)
            try lua.write(to: dir.appendingPathComponent("Fade.lua"), atomically: true, encoding: .utf8)
            app.rescanLibrary()
            guard let c = app.activate(config: "FadeRoot\\Fader", file: "Fader.ini") else {
                t.check(false, "skin loaded")
                return
            }
            func command(_ code: String) {
                c.skin.perform(Bang(name: "commandmeasure", args: ["Script", code]))
            }
            t.close(c.window.alphaValue, 1)
            command("Out()")
            t.equal(c.fadedAlpha?.value, 64)
            t.equal(c.effectiveAlphaValue, 64)
            t.close(c.window.alphaValue, 64.0 / 255, accuracy: 0.01)
            t.equal(app.state.skin("FadeRoot\\Fader")?.alphaValue, 255, "AlphaValue is not saved")
            t.equal(c.skin.variable("Before"), "1", "queued in order with the script's bangs")

            // !Hide / !Show keep the faded value.
            c.skin.perform(Bang(name: "hide", args: []))
            t.close(c.window.alphaValue, 0)
            c.skin.perform(Bang(name: "show", args: []))
            t.close(c.window.alphaValue, 64.0 / 255, accuracy: 0.01)

            // !SetTransparency (even to the saved value) ends it.
            c.skin.perform(Bang(name: "settransparency", args: ["255"]))
            t.check(c.fadedAlpha == nil)
            t.close(c.window.alphaValue, 1)
            command("Clamp()")
            t.equal(c.fadedAlpha?.value, 255, "clamped to 0…255")

            // A refresh starts from the saved AlphaValue again.
            command("Out()")
            app.refresh(c)
            guard let refreshed = app.controller(for: "FadeRoot\\Fader") else { return }
            t.check(refreshed.fadedAlpha == nil)
            t.close(refreshed.window.alphaValue, 1)
        }
    }

    // MARK: Permission notes

    static func permissionNoteTests(_ t: AppTestRunner) {
        t.suite("App: permission and player compatibility notes") {
            // Players without a Mac version.
            t.check(NowPlayingPlayerNames.hasMacPlayer("Spotify"))
            t.check(NowPlayingPlayerNames.hasMacPlayer(" iTunes "))
            t.check(NowPlayingPlayerNames.hasMacPlayer(""))
            t.check(!NowPlayingPlayerNames.hasMacPlayer("Winamp"))
            t.check(!NowPlayingPlayerNames.hasMacPlayer("foobar2000"))
            let (skin, _) = try MediaUITests.bareSkin(t)
            let winamp = NowPlayingMeasure(name: "Player", section: MediaUITests.section("Player", [
                ("Measure", "NowPlaying"), ("PlayerName", "Winamp"), ("PlayerType", "Title")]),
                                          skin: skin, type: "nowplaying")
            winamp.center = NowPlayingCenter(backend: DemoNowPlayingBackend())
            winamp.readOptions()
            t.check(skin.issues.contains { $0.contains("PlayerName=Winamp has no Mac version") }, "\(skin.issues)")
            let spotify = NowPlayingMeasure(name: "Spotify", section: MediaUITests.section("Spotify", [
                ("Measure", "NowPlaying"), ("PlayerName", "Spotify"), ("PlayerType", "Title")]),
                                           skin: skin, type: "nowplaying")
            spotify.center = winamp.center
            let count = skin.issues.count
            spotify.readOptions()
            t.equal(skin.issues.count, count, "Spotify exists on the Mac")

            // Refused Automation: a note for skins running in the app.
            let center = NowPlayingCenter(backend: MediaUITests.DeniedBackend())
            center.forceLive = true
            center.interval = 3600
            MediaUITests.inline([center.worker]) {
                let s = center.subscribe(live: true)
                center.poll()
                withExtendedLifetime(s) {}
            }
            t.check(center.isDenied(.music))
            t.check(!center.isDenied(.spotify))
            // (Checked without a skin running in the app: such a skin would poll the real players.)
            let notes = NowPlayingClientMeasure.refusedAutomationNotes(center)
            t.equal(notes.count, 1)
            t.check(notes.first?.contains("not allowed to control Music") == true, "\(notes)")
            // (review) The iTunes plugin reads Music only: a refused Spotify is not its concern.
            t.equal(NowPlayingClientMeasure.refusedAutomationNotes(center, apps: [.spotify]), [])
            t.equal(NowPlayingClientMeasure.refusedAutomationNotes(center, apps: [.music]), notes)

            // (review) A player name from the skin is shown bounded.
            let longName = String(repeating: "W", count: 5000)
            let odd = NowPlayingMeasure(name: "Odd", section: MediaUITests.section("Odd", [
                ("Measure", "NowPlaying"), ("PlayerName", longName), ("PlayerType", "Title")]),
                                        skin: skin, type: "nowplaying")
            odd.center = winamp.center
            odd.readOptions()
            let oddNote = skin.issues.first { $0.hasPrefix("NowPlaying: PlayerName=WWW") }
            t.check(oddNote != nil && oddNote!.count < 200, "\(oddNote?.count ?? -1)")
            t.check(WebNowPlayingMeasure.note.contains("does not connect to the WebNowPlaying browser extension"))

            // Wi-Fi names without Location Services, as shown to the user.
            t.check(WiFiStatusMeasure.locationNote.contains("Location Services"))
        }

        t.suite("App: permission notes are taken back once the permission is granted") {
            let (skin, _) = try MediaUITests.bareSkin(t)

            // Automation: refused, then allowed in System Settings (the center re-checks after 30 s).
            let backend = GrantLaterBackend()
            let center = NowPlayingCenter(backend: backend)
            center.forceLive = true
            center.interval = 3600
            var now: TimeInterval = 1000
            center.clock = { now }
            let musicNote = NowPlayingClientMeasure.automationNote(.music)
            MediaUITests.inline([center.worker]) {
                let subscription = center.subscribe(live: true)
                center.poll()
                t.check(center.isDenied(.music))
                NowPlayingClientMeasure.applyAutomationNotes(center, to: skin)
                t.equal(skin.issues.filter { $0.hasPrefix("NowPlaying: Deskset is not allowed") }, [musicNote])
                NowPlayingClientMeasure.applyAutomationNotes(center, apps: [.spotify], to: skin)
                t.check(skin.issues.contains(musicNote), "a measure reading only Spotify leaves Music's note alone")
                backend.denied = false
                now += 31
                _ = center.snapshot(preferring: .music)
                t.check(!center.isDenied(.music), "re-checked and allowed")
                NowPlayingClientMeasure.applyAutomationNotes(center, to: skin)
                t.check(!skin.issues.contains(musicNote), "allowed later: \(skin.issues)")
                withExtendedLifetime(subscription) {}
            }

            // Location Services: a WiFiStatus measure takes its note back once they are allowed.
            let savedDenied = WiFiStatusMeasure.locationDenied
            defer { WiFiStatusMeasure.locationDenied = savedDenied }
            var locationDenied = true
            WiFiStatusMeasure.locationDenied = { locationDenied }
            let wifiCenter = WiFiCenter()
            wifiCenter.reader = { _ in WiFiNetworkInfo(ssid: "", rssi: -60, transmitRate: 100, encryption: "AES",
                                                       auth: "WPA2-Personal", phy: "802.11ac") }
            wifiCenter.scanner = { _ in [] }
            let wifi = WiFiStatusMeasure(name: "SSID", section: MediaUITests.section("SSID", [("WiFiInfoType", "SSID")]),
                                         skin: skin, type: "wifistatus")
            wifi.center = wifiCenter
            wifi.readOptions()
            MediaUITests.inline([wifiCenter.worker]) {
                wifi.noteMissingLocation()   // (what a skin running in the app gets while they are off)
                _ = wifi.computeValue()
                t.check(skin.issues.contains(WiFiStatusMeasure.locationNote), "still refused")
                locationDenied = false
                _ = wifi.computeValue()
                t.check(!skin.issues.contains(WiFiStatusMeasure.locationNote), "allowed later: \(skin.issues)")
                t.check(!wifi.notedLocation)
            }

            // Accessibility: a MediaKey measure takes its note back once Deskset may post key events.
            let savedTrust = MediaKeyMeasure.canPostEvents
            defer { MediaKeyMeasure.canPostEvents = savedTrust }
            var trusted = false
            MediaKeyMeasure.canPostEvents = { trusted }
            let key = MediaKeyMeasure(name: "Key", section: MediaUITests.section("Key", [("Measure", "MediaKey")]),
                                      skin: skin, type: "mediakey")
            key.readOptions()
            key.noteMissingAccessibility()   // (a track key sent without Accessibility, in the app)
            _ = key.computeValue()
            t.check(skin.issues.contains(MediaKeyMeasure.accessibilityNote))
            trusted = true
            _ = key.computeValue()
            t.check(!skin.issues.contains(MediaKeyMeasure.accessibilityNote), "granted later: \(skin.issues)")
        }
    }

    /// Music refuses Automation until `denied` is false; Spotify is not running.
    final class GrantLaterBackend: NowPlayingBackend {
        var denied = true
        func isRunning(_ app: MediaApp) -> Bool { app == .music }
        func status(_ app: MediaApp) -> NowPlayingPoll {
            denied ? .denied : .ok(NowPlayingStatus(state: 2, volume: 50, trackID: ""))
        }
        func track(_ app: MediaApp) -> NowPlayingTrack? { nil }
        func artwork(_ app: MediaApp, track: NowPlayingTrack) -> NowPlayingArtwork? { nil }
        func perform(_ command: MediaPlayerCommand, on app: MediaApp) -> Bool { false }
    }

    // MARK: Desktop picture (Registry Wallpaper)

    static func desktopPictureTests(_ t: AppTestRunner) {
        t.suite("App: desktop picture for the Registry Wallpaper value") {
            let dir = t.temporaryDirectory("desktop")
            let walls = dir.appendingPathComponent("Rotating", isDirectory: true)
            let empty = dir.appendingPathComponent("No Pictures", isDirectory: true)
            try FileManager.default.createDirectory(at: walls, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            for name in ["b 10.jpg", "b 9.HEIC", ".hidden.png", "a notes.txt"] {
                try Data([0]).write(to: walls.appendingPathComponent(name))
            }
            try Data([0]).write(to: empty.appendingPathComponent("readme.txt"))
            let first = walls.appendingPathComponent("b 9.HEIC").path
            t.check(DesktopPicture.isPictureFile("/Library/Desktop Pictures/Lake.heic"))
            t.check(DesktopPicture.isPictureFile("/x/Photo.JPG"))
            t.check(!DesktopPicture.isPictureFile(walls.path))
            t.equal(DesktopPicture.picture(forSetting: walls.path), first,
                    "a folder of rotating pictures → its first picture by name (numbers in natural order)")
            t.equal(DesktopPicture.picture(forSetting: empty.path), "", "a folder without pictures")
            let other = dir.appendingPathComponent("Aerial.madesktop")
            try Data([0]).write(to: other)
            t.equal(DesktopPicture.picture(forSetting: other.path), other.path, "another existing file, as it is")
            t.equal(DesktopPicture.picture(forSetting: dir.appendingPathComponent("Unmounted/Rotating").path), "",
                    "a folder that is not there (its volume is not mounted) is no picture")
            t.equal(DesktopPicture.picture(forSetting: ""), "")
            t.equal(ChameleonMeasure.wallpaperFile(walls.path), first, "Chameleon picks the same picture")

            let cache = DesktopPictureCache()
            var setting = "/Library/Desktop Pictures/Lake.heic"
            var asked = 0
            cache.setting = { asked += 1; return setting }
            var now: TimeInterval = 100
            cache.clock = { now }
            t.equal(cache.path(), "/Library/Desktop Pictures/Lake.heic", "a picture file, answered as is")
            now += 1.9
            _ = cache.path()
            t.equal(asked, 1, "the setting is looked at every 2 s at most")
            now += 0.1
            setting = walls.path
            t.equal(cache.path(), "", "a folder: nothing until it has been looked into (off the main thread)")
            t.check(spin(timeout: 5) { cache.path() == first }, "then its first picture")
            try Data([0]).write(to: walls.appendingPathComponent("a new.png"))
            now += 10
            t.equal(cache.path(), first, "the folder's answer is reused for a while")
            RenderCommand.wait(milliseconds: 50)
            t.equal(cache.path(), first)
            now += DesktopPictureCache.folderInterval
            t.equal(cache.path(), first, "the old answer while the folder is looked into again")
            let added = walls.appendingPathComponent("a new.png").path
            t.check(spin(timeout: 5) { cache.path() == added }, "a picture added to the folder")
            now += 2
            setting = ""
            t.equal(cache.path(), "", "no desktop picture")

            // The real data source answers on the main thread (a path, or "" without a picture file), and the
            // Registry measure shows it without a compatibility note.
            let real = SystemMonitor.shared.desktopPicturePath()
            t.check(real != nil, "the app's data source knows the desktop picture")
            let skin = try AudioSelfTests.makeSkin(t, """
            [Rainmeter]
            Update=1000
            [Wallpaper]
            Measure=Registry
            RegHKey=HKEY_CURRENT_USER
            RegKey=Control Panel\\Desktop
            RegValue=Wallpaper
            """, config: "Wallpaper")
            skin.update()
            if let real, !real.isEmpty, DesktopPicture.isPictureFile(real) {
                t.equal(skin.measure(named: "Wallpaper")?.stringValue, real)
            }
            t.equal(skin.issues, [], "Wallpaper is emulated in the app")
            // Another thread (a skin running on a thread of its own) gets the main thread's answer, without waiting
            // for the main thread, which is blocked here.
            var fromOtherThread: String?? = .none
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                fromOtherThread = .some(SystemMonitor.shared.desktopPicturePath())
                done.signal()
            }
            done.wait()
            t.check(fromOtherThread == .some(SystemMonitor.shared.desktopPicturePath()),
                    "another thread gets what the main thread found: \(String(describing: fromOtherThread))")

            // What the main thread publishes, and when another thread makes it look again.
            let published = DesktopPictureCache()
            var picture = "/Library/Desktop Pictures/Lake.heic"
            var looks = 0
            published.setting = { looks += 1; return picture }
            var clock: TimeInterval = 500
            published.clock = { clock }
            func readOffMain() -> String? {
                var answer: String?
                let read = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    answer = published.published.value()
                    read.signal()
                }
                read.wait()
                return answer
            }
            t.equal(readOffMain(), "", "nothing looked at yet: no picture")
            t.check(spin(timeout: 60) { looks == 1 }, "the main thread is asked to look")
            t.equal(readOffMain(), picture, "then its answer")
            picture = "/Library/Desktop Pictures/Dunes.heic"
            clock += 1
            t.equal(readOffMain(), "/Library/Desktop Pictures/Lake.heic", "an answer younger than 2 s is used as is")
            clock += 1
            t.equal(readOffMain(), "/Library/Desktop Pictures/Lake.heic", "an older one too, while the main thread looks")
            t.check(spin(timeout: 60) { published.published.lastPublished == picture }, "which it does")
            t.equal(looks, 2)
            t.equal(readOffMain(), picture)
            t.equal(published.path(), picture, "the main thread answers itself")
        }
    }

    // MARK: App-provided measures

    static func registrationTests(_ t: AppTestRunner) {
        t.suite("App: Skin.appProvidedMeasures matches the app's plugin registrations") {
            AudioPlugins.register()
            MediaUIPlugins.register()
            let audio = AudioPlugins.pluginTypes.map { MeasureRegistry.normalizedPluginName($0.name) }
            let registered = Set(audio + MediaUIPlugins.pluginNames + MediaUIPlugins.measureNames)
            t.equal(registered.sorted(), Skin.appProvidedMeasures.sorted(),
                    "the core's list of app plugins (its fallback note) and the app's registrations agree")
            // Every table entry is what the registry holds.
            for entry in AudioPlugins.pluginTypes + MediaUIPlugins.pluginTypes + MediaUIPlugins.measureTypes {
                t.check(MeasureRegistry.plugin(named: entry.name) == entry.type, "plugin \(entry.name)")
            }
            for entry in MediaUIPlugins.measureTypes {
                t.check(MeasureRegistry.measure(named: entry.name) == entry.type, "measure \(entry.name)")
            }
            // Nothing else in the app registers a type (types from DesksetCore are the core's own plugins).
            func fromApp(_ type: Measure.Type) -> Bool { !String(reflecting: type).hasPrefix("DesksetCore.") }
            let appPlugins = MeasureRegistry.registeredPlugins.filter { fromApp($0.value) }.keys
            let appMeasures = MeasureRegistry.registeredMeasures.filter { fromApp($0.value) }.keys
            t.equal(Set(appPlugins).union(appMeasures).sorted(), Skin.appProvidedMeasures.sorted())
            // Only documented measure types are registered as `Measure=` (the rest are plugins only).
            for name in MediaUIPlugins.measureNames {
                t.check(Skin.documentedMeasureTypes.contains(name), "Measure=\(name) is a documented type")
            }
            for name in appMeasures {
                t.check(Skin.documentedMeasureTypes.contains(name), "registered Measure=\(name)")
            }
            t.equal(Set(appMeasures).sorted(), MediaUIPlugins.measureNames.sorted())
        }
    }
}
