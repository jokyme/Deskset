import AppKit
import DesksetCore
import Foundation

/// Original fixtures only. Layout files and state live in temporary directories; these tests never set a wallpaper.
enum LayoutStoreSelfTests {
    static func run(_ t: AppTestRunner) {
        codecTests(t)
        storeTests(t)
        stateTests(t)
    }

    private static func codecTests(_ t: AppTestRunner) {
        t.suite("App: Layouts: native keys, variants and section order") {
            let library = [SkinConfig(name: "Suite\\Clock", directory: URL(fileURLWithPath: "/unused"),
                                      files: ["2.ini", "10.ini", "alpha.ini"])]
            let document = IniDocument.parse("""
            [Rainmeter]
            ConfigEditor=AuthorEditor
            SkinPath=C:\\Author\\Skins
            [TrayMeasure]
            Measure=CPU
            [Suite\\Clock]
            Active=2
            WindowX=(100 / 2)%@2
            WindowY=20B
            AnchorX=50%
            AnchorY=100%
            AlwaysOnTop=1
            LoadOrder=3
            Draggable=0
            ClickThrough=1
            KeepOnScreen=0
            SnapEdges=0
            SavePosition=0
            StartHidden=1
            AutoSelectScreen=1
            AlphaValue=190
            FadeDuration=350
            OnHover=2
            Group=Clock | Suite
            DragGroup=Cards
            Zoom=10
            FutureOption=unchanged
            [Absent\\Config]
            Active=4
            LoadOrder=-2
            [Inactive]
            Active=0
            """)
            let decoded = LayoutStateCodec.decode(document, library: library)
            t.equal(decoded.order, ["Suite\\Clock", "Absent\\Config", "Inactive"])
            let clock = decoded.skins["Suite\\Clock"]!
            t.equal(LayoutStateCodec.variants(in: library[0]), ["10.ini", "2.ini", "alpha.ini"])
            t.equal(clock.file, "2.ini", "layout indices use the app's stable alphabetical ordering")
            t.equal(clock.windowX, "(100 / 2)%@2")
            t.equal(clock.windowY, "20B")
            t.equal(clock.anchorX, "50%")
            t.equal(clock.anchorY, "100%")
            t.equal(clock.group, "Clock | Suite")
            t.equal(clock.dragGroup, "Cards")
            t.equal(clock.zoomFactor, 0.1)
            t.equal(clock.x, nil, "position expressions resolve when the skin's size is known")
            t.equal(clock.alwaysOnTop, 1)
            t.check(!clock.draggable && clock.clickThrough && !clock.keepOnScreen && !clock.snapEdges)
            t.check(!clock.savePosition && clock.startHidden && clock.autoSelectScreen)
            t.equal(clock.alphaValue, 190)
            t.equal(clock.fadeDuration, 350)
            t.equal(clock.onHover, 2)
            t.equal(decoded.skins["Absent\\Config"]?.file, "")
            t.equal(decoded.skins["Absent\\Config"]?.activeVariant, 4)
            t.equal(decoded.skins["Absent\\Config"]?.alwaysOnTop, 0, "native default is Normal")
            t.equal(decoded.skins["Absent\\Config"]?.windowX, "0")
            var data = AppStateData()
            data.skins = decoded.skins
            data.skinOrder = decoded.order
            data.rainmeterOptions = decoded.rainmeterOptions
            data.trayMeasureOptions = decoded.trayMeasureOptions
            let saved = LayoutStateCodec.capture(data, library: library, options: LayoutSaveOptions())
            t.equal(saved.sections.map(\.name), ["Rainmeter", "TrayMeasure"] + decoded.order)
            t.equal(saved.section(named: "Rainmeter")?["ConfigEditor"], "AuthorEditor")
            t.equal(saved.section(named: "Rainmeter")?["SkinPath"], "C:\\Author\\Skins")
            t.equal(saved.section(named: "TrayMeasure")?["Measure"], "CPU")
            t.equal(saved.section(named: "Suite\\Clock")?["Active"], "2")
            t.equal(saved.section(named: "Absent\\Config")?["Active"], "4", "missing configs retain their variant index")
            t.equal(saved.section(named: "Suite\\Clock")?["FutureOption"], "unchanged")
            t.equal(saved.section(named: "Suite\\Clock")?["Zoom"], "10")
            t.equal(saved.section(named: "Suite\\Clock")?["ZoomFactor"], nil)
            t.equal(saved.section(named: "Suite\\Clock")?["WindowX"], "(100 / 2)%@2")
            let active = LayoutStateCodec.capture(data, library: library,
                options: LayoutSaveOptions(empty: false, excludeUnloaded: true, includeWallpaper: false))
            t.equal(active.sections.map(\.name), ["Rainmeter", "TrayMeasure", "Suite\\Clock", "Absent\\Config"])
            let empty = LayoutStateCodec.capture(data, library: library,
                options: LayoutSaveOptions(empty: true, excludeUnloaded: false, includeWallpaper: true))
            t.equal(empty.sections.map(\.name), [])
            t.equal(LayoutStateCodec.decode(IniDocument.parse("; empty layout"), library: []).order, [])
        }

        t.suite("App: Layouts: exclude unloaded compares the saved Active text") {
            let values: [(String, String?)] = [("Absent", nil), ("Empty", ""), ("DoubleZero", "00"),
                                              ("Invalid", "invalid"), ("Zero", "0"), ("FormulaZero", "(0)"),
                                              ("Negative", "-1"), ("MissingVariant", "03")]
            let document = IniDocument(sections: values.map { name, active in
                IniSection(name: name, entries: active.map { [IniEntry(key: "aCtIvE", value: $0)] } ?? [])
            })
            let layout = LayoutStateCodec.decode(document, library: [])
            var data = AppStateData()
            data.skins = layout.skins
            data.skinOrder = layout.order
            // Preserve both an absent key and an empty value through the app's persisted representation.
            data = try JSONDecoder().decode(AppStateData.self, from: JSONEncoder().encode(data))
            let saved = LayoutStateCodec.capture(data, library: [], options: LayoutSaveOptions())
            for (name, active) in values {
                t.check(saved.section(named: name) != nil)
                t.equal(saved.section(named: name)?["Active"], active, name)
            }
            let filtered = LayoutStateCodec.capture(data, library: [], options: LayoutSaveOptions(excludeUnloaded: true))
            t.equal(filtered.sections.map(\.name), ["Rainmeter"] + values.map { $0.0 }.filter { $0 != "Zero" })
            t.equal(layout.skins["DoubleZero"]?.active, false)
            t.equal(layout.skins["MissingVariant"]?.activeVariant, 3)
        }

        t.suite("App: Layouts: Active and LoadOrder read decimal prefixes and formulas") {
            let library = [SkinConfig(name: "Config", directory: URL(fileURLWithPath: "/unused"),
                                      files: ["A.ini", "B.ini"])]
            let cases: [(String, Int, Int)] = [("0x2", 0, 0), ("0b10", 0, 0), ("1e2", 1, 1),
                                               ("+2tail", 2, 2), ("-2tail", 0, -2), ("2.9", 2, 2),
                                               ("(1+1)", 2, 2), ("(2.9)", 2, 2), ("(-2.9)", 0, -2),
                                               ("2147483647", 2147483647, 2147483647),
                                               ("-2147483648", 0, -2147483648), ("2147483648", 0, 0),
                                               ("-2147483649tail", 0, 0), ("999999999999999999999999", 0, 0),
                                               ("invalid", 0, 0), ("", 0, 0), ("(invalid)", 0, 0)]
            for (text, active, order) in cases {
                let document = IniDocument(sections: [IniSection(name: "Config", entries: [
                    IniEntry(key: "Active", value: text), IniEntry(key: "LoadOrder", value: text)
                ])])
                let state = LayoutStateCodec.decode(document, library: library).skins["Config"]
                t.equal(state?.activeVariant, active, text)
                t.equal(state?.loadOrder, order, text)
                t.equal(state?.file, active == 1 ? "A.ini" : active == 2 ? "B.ini" : "", text)
            }
        }

        t.suite("App: Layouts: installed variant order changes update an imported index") {
            let originalLibrary = [SkinConfig(name: "Config", directory: URL(fileURLWithPath: "/unused"),
                                              files: ["A.ini", "B.ini"])]
            let layout = LayoutStateCodec.decode(IniDocument.parse("[Config]\nActive=02\n"), library: originalLibrary)
            var data = AppStateData()
            data.skins = layout.skins
            data.skinOrder = layout.order
            t.equal(LayoutStateCodec.capture(data, library: originalLibrary, options: LayoutSaveOptions())
                .section(named: "Config")?["Active"], "02", "an unchanged index preserves imported text")
            let newLibrary = [SkinConfig(name: "Config", directory: URL(fileURLWithPath: "/unused"),
                                         files: ["0.ini", "A.ini", "B.ini"])]
            let saved = LayoutStateCodec.capture(data, library: newLibrary, options: LayoutSaveOptions())
            t.equal(saved.section(named: "Config")?["Active"], "3")
            t.equal(LayoutStateCodec.decode(saved, library: newLibrary).skins["Config"]?.file, "B.ini",
                    "new variants do not redirect the saved layout to another file")
            t.equal(LayoutStateCodec.capture(data, library: [], options: LayoutSaveOptions())
                .section(named: "Config")?["Active"], "02", "unavailable configs retain their imported index")
        }

        t.suite("App: Layouts: ordinary settings preservation and backup bypass") {
            let keys = ["SkinPath", "ConfigEditor", "Logging", "DisableVersionCheck", "DisableAutoUpdate", "Language",
                        "NormalStayDesktop", "SelectedColor", "HardwareAcceleration"]
            var oldGlobals = IniSection(name: "RAINMETER")
            var targetGlobals = IniSection(name: "rainmeter")
            for key in keys {
                oldGlobals.setValue("old-\(key)", forKey: key.uppercased())
                targetGlobals.setValue("target-\(key)", forKey: key.lowercased())
            }
            for key in ["TrayExecuteM", "TrayExecuteR", "TrayExecuteDM", "TrayExecuteDR", "TrayExecuteL"] {
                oldGlobals.setValue("old-\(key)", forKey: key)
            }
            targetGlobals.setValue("", forKey: "trayexecutem")
            targetGlobals.setValue("target-right", forKey: "TrayExecuteR")
            targetGlobals.setValue("", forKey: "TrayExecuteDR")
            targetGlobals.setValue("target-left", forKey: "TrayExecuteL")
            oldGlobals.setValue("old-only", forKey: "PreviousOnly")
            oldGlobals.setValue("old-future", forKey: "FutureGlobal")
            targetGlobals.setValue("target-future", forKey: "FutureGlobal")
            let previous = LayoutStateCodec.decode(IniDocument(sections: [oldGlobals,
                IniSection(name: "TrayMeasure", entries: [IniEntry(key: "Measure", value: "Memory")])]), library: [])
            let target = LayoutStateCodec.decode(IniDocument(sections: [targetGlobals,
                IniSection(name: "tRaYmEaSuRe", entries: [IniEntry(key: "Measure", value: "CPU"),
                                                        IniEntry(key: "FutureTray", value: "kept")])]), library: [])
            let merged = target.preservingSettings(from: previous)
            let globals = IniSection(name: "Rainmeter", entries: merged.rainmeterOptions.keys.sorted()
                .map { IniEntry(key: $0, value: merged.rainmeterOptions[$0]!) })
            for key in keys {
                t.equal(globals[key], "old-\(key)")
                t.equal(globals.entries.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }.count, 1)
                t.check(merged.rainmeterOptions[key.lowercased()] != nil, "target key spelling survives \(key)")
            }
            t.equal(globals["TrayExecuteM"], "old-TrayExecuteM")
            t.equal(globals["TrayExecuteR"], "target-right")
            t.equal(globals["TrayExecuteDM"], "old-TrayExecuteDM")
            t.equal(globals["TrayExecuteDR"], "old-TrayExecuteDR")
            t.equal(globals["TrayExecuteL"], "target-left")
            t.equal(globals["PreviousOnly"], nil)
            t.equal(globals["FutureGlobal"], "target-future")
            t.equal(merged.trayMeasureOptions, target.trayMeasureOptions)

            let emptyPrevious = LayoutState(skins: [:], order: [], rainmeterOptions: ["Language": "", "ConfigEditor": ""])
            var withoutLogging = target.rainmeterOptions
            withoutLogging.removeValue(forKey: "logging")
            t.equal(target.preservingSettings(from: emptyPrevious).rainmeterOptions, withoutLogging,
                    "absent Logging retains the local default; other absent settings retain existing merge rules")
            t.equal(target.rainmeterOptions["language"], "target-Language", "backup decoding bypasses the ordinary merge")
            let absentTray = LayoutState(skins: [:], order: []).preservingSettings(from: previous)
            t.equal(absentTray.trayMeasureOptions, nil, "an absent target TrayMeasure is not inherited")
            let emptyTray = LayoutState(skins: [:], order: [], trayMeasureOptions: [:]).preservingSettings(from: previous)
            t.equal(emptyTray.trayMeasureOptions, [:], "an empty target TrayMeasure remains present")
        }

        t.suite("App: Layouts: safe numeric defaults and invalid config paths") {
            let document = IniDocument.parse("""
            [Good]
            Active=1
            AlwaysOnTop=999
            AlphaValue=-100
            FadeDuration=100000
            OnHover=10
            Zoom=900
            [..\\Outside]
            Active=1
            [NUL]
            Active=1
            """)
            let layout = LayoutStateCodec.decode(document, library: [])
            t.equal(layout.order, ["Good"])
            t.equal(layout.skins["Good"]?.alwaysOnTop, 2)
            t.equal(layout.skins["Good"]?.alphaValue, 0)
            t.equal(layout.skins["Good"]?.fadeDuration, SkinState.maxFadeDuration)
            t.equal(layout.skins["Good"]?.onHover, 3)
            t.equal(layout.skins["Good"]?.zoomFactor, 5)
        }
    }

    private static func storeTests(_ t: AppTestRunner) {
        t.suite("App: Layouts: standard files, overwrite and backup round trip") {
            let root = t.temporaryDirectory("layouts-store")
            let trash = root.appendingPathComponent("Trash")
            let store = LayoutStore(directory: root.appendingPathComponent("Layouts"), trash: { source in
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: source, to: trash.appendingPathComponent(source.lastPathComponent))
            })
            t.equal(try store.list(), [])
            let first = LayoutDocument(ini: IniDocument.parse("[Suite\\Clock]\nActive=1\nWindowX=40\n"),
                                       wallpaper: Data([0x42, 0x4d, 1, 2]))
            try store.save(first, named: "Work")
            t.check(store.contains(named: "work"))
            t.equal(try store.list(), ["Work"])
            t.equal(try store.read(named: "WORK"), first)
            let iniURL = try store.iniURL(named: "work")
            t.equal(iniURL.lastPathComponent, "Rainmeter.ini")
            t.equal(Array(try Data(contentsOf: iniURL).prefix(2)), [0xff, 0xfe], "Windows-readable UTF-16 LE BOM")
            let extras = iniURL.deletingLastPathComponent().appendingPathComponent("Extras")
            try FileManager.default.createDirectory(at: extras, withIntermediateDirectories: false)
            let notes = Data("Original layout notes".utf8)
            try notes.write(to: extras.appendingPathComponent("Notes.txt"))
            let target = try store.read(named: "Work")
            let current = LayoutDocument(ini: IniDocument.parse("[Other]\nActive=1\n"))
            try store.save(current, named: "@Backup")
            try store.save(target, named: "@Backup")
            let backup = try store.read(named: "@Backup")
            try store.save(current, named: "@Backup")
            t.equal(backup, first, "reading before replacement preserves a target named @Backup")
            let empty = LayoutDocument(ini: IniDocument(sections: []))
            try store.save(empty, named: "work")
            t.equal(try store.read(named: "Work").ini, empty.ini)
            t.equal(try Data(contentsOf: iniURL), Data(), "an empty layout has no content or encoding marker")
            t.equal(try store.read(named: "Work").wallpaper, first.wallpaper,
                    "saving without wallpaper retains the previous image")
            t.equal(try Data(contentsOf: extras.appendingPathComponent("Notes.txt")), notes,
                    "replacement preserves other saved files and subdirectories")
            let newWallpaper = Data([0x42, 0x4d, 3, 4])
            try store.save(LayoutDocument(ini: empty.ini, wallpaper: newWallpaper), named: "Work")
            t.equal(try store.read(named: "Work").wallpaper, newWallpaper, "an included image replaces the previous one")
            t.equal(try store.list(), ["@Backup", "Work"])
            try store.delete(named: "WORK")
            t.check(!store.contains(named: "Work"))
            t.equal(try store.list(), ["@Backup"])
            t.equal(try Data(contentsOf: trash.appendingPathComponent("Work/Extras/Notes.txt")), notes,
                    "deletion hands the complete layout folder to the trash boundary")
        }

        t.suite("App: Layouts: literal quotes and padding survive repeated saves") {
            let store = LayoutStore(directory: t.temporaryDirectory("layouts-literal-quotes"))
            let values = #"""
            Double='"double"'
            Single="'single'"
            RepeatedDouble="""double"""
            RepeatedSingle='''single'''
            SingleDouble="
            SingleSingle='
            EmptyDouble='""'
            EmptySingle="''"
            Padded="  padded  "
            QuotedPadded='"  padded  "'
            Blank=" "
            Empty=
            """#
            let expected = [
                "Double": "\"double\"", "Single": "'single'",
                "RepeatedDouble": "\"\"double\"\"", "RepeatedSingle": "''single''",
                "SingleDouble": "\"", "SingleSingle": "'", "EmptyDouble": "\"\"", "EmptySingle": "''",
                "Padded": "  padded  ", "QuotedPadded": "\"  padded  \"", "Blank": " ", "Empty": ""
            ]
            let sections = ["Rainmeter", "Config", "TrayMeasure"]
            let original = LayoutDocument(ini: IniDocument.parse(sections.map { "[\($0)]\n\(values)\n" }.joined()))
            for section in sections {
                for key in expected.keys.sorted() {
                    t.equal(original.ini.section(named: section)?[key], expected[key], "fixture \(section).\(key)")
                }
            }
            var current = original
            for pass in 1...2 {
                try store.save(current, named: "Quoted")
                current = try store.read(named: "Quoted")
                t.equal(current, original, "global, config and tray values survive save/read \(pass)")
            }
        }

        t.suite("App: Layouts: names resembling transaction folders remain visible") {
            let store = LayoutStore(directory: t.temporaryDirectory("layouts-visible"))
            let original = LayoutDocument(ini: IniDocument.parse("[Config]\nActive=1\n"))
            let name = ".deskset-layout-personal"
            try store.save(original, named: name)
            t.equal(try store.list(), [name])
            t.equal(try store.read(named: name), original)
        }

        t.suite("App: Layouts: incomplete directories can be replaced and trash failures preserve layouts") {
            let root = t.temporaryDirectory("layouts-incomplete")
            let store = LayoutStore(directory: root, trash: { _ in throw CocoaError(.fileWriteNoPermission) })
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Incomplete"),
                                                     withIntermediateDirectories: false)
            t.equal(try store.list(), ["Incomplete"])
            t.check(store.contains(named: "incomplete"), "an existing folder needs replacement confirmation")
            do { _ = try store.read(named: "Incomplete"); t.check(false, "a missing INI became an empty layout") }
            catch { t.check(true) }
            let layout = LayoutDocument(ini: IniDocument(sections: []))
            try store.save(layout, named: "Incomplete")
            do { try store.delete(named: "Incomplete"); t.check(false, "trash failure was ignored") }
            catch { t.equal(try store.read(named: "Incomplete"), layout, "trash failure never falls back to permanent deletion") }
        }

        t.suite("App: Layouts: wallpaper storage keeps the original image encoding") {
            let root = t.temporaryDirectory("layouts-picture")
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0) else { return t.check(false, "bitmap fixture") }
            bitmap.setColor(.red, atX: 0, y: 0)
            bitmap.setColor(.blue, atX: 1, y: 0)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                return t.check(false, "PNG fixture")
            }
            let picture = root.appendingPathComponent("Original.png")
            try png.write(to: picture)
            let captured = try SystemLayoutWallpaper.readPicture(at: picture)
            t.equal(captured, png, "reading a desktop picture preserves its original bytes")
            let store = LayoutStore(directory: root.appendingPathComponent("Layouts"))
            try store.save(LayoutDocument(ini: IniDocument(sections: []), wallpaper: captured), named: "Picture")
            t.equal(try Data(contentsOf: root.appendingPathComponent("Layouts/Picture/Wallpaper.bmp")), png,
                    "the standard storage name does not force a bitmap transcode")
            let malformed = root.appendingPathComponent("Broken.png")
            try Data("not an image".utf8).write(to: malformed)
            do { _ = try SystemLayoutWallpaper.readPicture(at: malformed); t.check(false, "malformed image was accepted") }
            catch { t.check(true) }
        }

        t.suite("App: Layouts: reading settings can skip an unsafe wallpaper entry") {
            let root = t.temporaryDirectory("layouts-skip-picture")
            let store = LayoutStore(directory: root.appendingPathComponent("Layouts"))
            let original = LayoutDocument(ini: IniDocument.parse("[Config]\nActive=1\n"))
            let outside = root.appendingPathComponent("Outside.bmp")
            try Data([0x42, 0x4D]).write(to: outside)
            for name in ["LinkedWallpaper", "DirectoryWallpaper"] {
                try store.save(original, named: name)
                let image = try store.iniURL(named: name).deletingLastPathComponent().appendingPathComponent("Wallpaper.bmp")
                if name == "LinkedWallpaper" {
                    try FileManager.default.createSymbolicLink(at: image, withDestinationURL: outside)
                } else {
                    try FileManager.default.createDirectory(at: image, withIntermediateDirectories: false)
                }
                let settings = try store.read(named: name, includeWallpaper: false)
                t.equal(settings.ini, original.ini, name)
                t.equal(settings.wallpaper, nil, name)
                do { _ = try store.read(named: name); t.check(false, "accepted unsafe wallpaper in \(name)") }
                catch { t.check(true) }
            }
        }

        t.suite("App: Layouts: rejected names, failed saves and symbolic links") {
            let root = t.temporaryDirectory("layouts-safe")
            let store = LayoutStore(directory: root.appendingPathComponent("Layouts"))
            let original = LayoutDocument(ini: IniDocument.parse("[Safe]\nActive=1\n"))
            try store.save(original, named: "Safe")
            for name in ["", ".", "..", "../outside", "a/b", "a\\b", "Bad:", "Bad?", "NUL", "com1.ini",
                         "End.", "End ", "line\nfeed"] {
                t.check(!LayoutStore.isValidName(name), name)
                do { try store.save(original, named: name); t.check(false, "accepted invalid name \(name)") }
                catch { t.check(true) }
            }
            t.check(LayoutStore.isValidName("@Backup"))
            t.check(LayoutStore.isValidName("Office layout"))
            let invalid = LayoutDocument(ini: IniDocument(sections: [IniSection(name: "bad]section")]))
            do { try store.save(invalid, named: "Safe"); t.check(false, "invalid INI section was written") }
            catch { t.equal(try store.read(named: "Safe"), original, "a failed staging write preserves the previous layout") }
            let outside = root.appendingPathComponent("Outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try "[External]\nActive=1".write(to: outside.appendingPathComponent("Rainmeter.ini"), atomically: true,
                                             encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: store.directory.appendingPathComponent("Linked"),
                                                       withDestinationURL: outside)
            t.check(!store.contains(named: "Linked"))
            do { try store.save(original, named: "Linked"); t.check(false, "followed a symlink") }
            catch { t.check(true) }
            do { try store.delete(named: "Linked"); t.check(false, "deleted a symlink target") }
            catch { t.check(true) }
            t.check(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Rainmeter.ini").path))
            let linkedINI = store.directory.appendingPathComponent("LinkedINI")
            try FileManager.default.createDirectory(at: linkedINI, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linkedINI.appendingPathComponent("Rainmeter.ini"),
                withDestinationURL: outside.appendingPathComponent("Rainmeter.ini"))
            t.check(store.contains(named: "LinkedINI"), "the destination directory exists even if its INI is unsafe")
            t.equal(try store.list(), ["LinkedINI", "Safe"])
            do { _ = try store.read(named: "LinkedINI"); t.check(false, "read a linked INI") }
            catch { t.check(true) }
            do { try store.save(original, named: "LinkedINI"); t.check(false, "replaced a linked INI") }
            catch { t.check(true) }
            let extras = store.directory.appendingPathComponent("Safe/Extras")
            try FileManager.default.createDirectory(at: extras, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: extras.appendingPathComponent("External"),
                                                       withDestinationURL: outside)
            do { try store.save(LayoutDocument(ini: IniDocument(sections: [])), named: "Safe")
                t.check(false, "copied a nested symbolic link") }
            catch { t.equal(try store.read(named: "Safe"), original, "unsafe preservation leaves the original layout intact") }
            t.equal(try TextDecoding.readFile(at: outside.appendingPathComponent("Rainmeter.ini")), "[External]\nActive=1")
            t.check(try FileManager.default.contentsOfDirectory(atPath: store.directory.deletingLastPathComponent().path)
                .allSatisfy { !$0.hasPrefix(".deskset-layout-") }, "failed saves remove their staging folders")
            do { _ = try store.read(named: "Missing"); t.check(false, "missing layout became an empty desktop") }
            catch { t.check(true) }
        }
    }

    private static func stateTests(_ t: AppTestRunner) {
        t.suite("App: Layouts: native globals and TrayMeasure persist without changing app preferences") {
            let file = t.temporaryDirectory("layout-native-settings").appendingPathComponent("state.json")
            let state = AppState(fileURL: file)
            state.updateUpdates { $0.automaticallyChecks = false }
            let editor = state.editor
            let document = IniDocument.parse("""
            [rainmeter]
            ConfigEditor=C:\\Target\\Editor.exe
            Language=Target
            DisableAutoUpdate=0
            FutureGlobal=kept
            [tRaYmEaSuRe]
            Measure=CPU
            FutureTray=kept
            [Config]
            Active=0
            """)
            let target = LayoutStateCodec.decode(document, library: [])
            let previous = LayoutState(skins: [:], order: [], rainmeterOptions: ["Language": "Previous"])
            state.replaceLayout(target.preservingSettings(from: previous))
            state.saveNow()
            let reopened = AppState(fileURL: file)
            let saved = LayoutStateCodec.capture(reopened.data, library: [], options: LayoutSaveOptions())
            t.equal(saved.section(named: "Rainmeter")?["Language"], "Previous")
            t.equal(saved.section(named: "Rainmeter")?["ConfigEditor"], "C:\\Target\\Editor.exe")
            t.equal(saved.section(named: "Rainmeter")?["FutureGlobal"], "kept")
            t.equal(saved.section(named: "TrayMeasure")?["Measure"], "CPU")
            t.equal(saved.section(named: "TrayMeasure")?["FutureTray"], "kept")
            t.equal(reopened.editor, editor)
            t.check(!reopened.updates.automaticallyChecks)
            t.equal(LayoutStateCodec.capture(reopened.data, library: [], options: LayoutSaveOptions(empty: true)).sections, [])

            state.replaceLayout(target)
            t.equal(LayoutStateCodec.capture(state.data, library: [], options: LayoutSaveOptions())
                .section(named: "Rainmeter")?["Language"], "Target", "backup replacement keeps target globals without merging")
            state.replaceLayout(LayoutState(skins: [:], order: [], trayMeasureOptions: [:]))
            state.saveNow()
            t.equal(AppState(fileURL: file).data.trayMeasureOptions, [:], "an empty TrayMeasure section survives JSON")
            state.replaceLayout(LayoutState(skins: [:], order: []))
            state.saveNow()
            let empty = AppState(fileURL: file)
            t.equal(empty.data.rainmeterOptions, [:])
            t.equal(empty.data.trayMeasureOptions, nil)
            let legacy = try JSONDecoder().decode(AppStateData.self, from: Data("{}".utf8))
            t.equal(legacy.rainmeterOptions, [:])
            t.equal(legacy.trayMeasureOptions, nil)
        }

        t.suite("App: Layouts: activation changes replace imported Active text") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let config = "App\\Focus"
            let original = IniDocument.parse("[App\\Focus]\naCtIvE=02\nFutureOption=kept\n")
            func capture(_ options: LayoutSaveOptions = LayoutSaveOptions()) -> IniDocument {
                LayoutStateCodec.capture(app.state.data, library: app.library, options: options)
            }
            app.state.replaceLayout(LayoutStateCodec.decode(original, library: app.library))
            t.check(app.activate(config: config, file: "Focus.ini") != nil)
            app.state.update(config) { $0.x = 25 }
            t.equal(capture().section(named: config)?["Active"], "02", "same-file activation and position changes preserve Active")
            t.equal(app.state.skin(config)?.activeVariant, 2)

            app.deactivate(config: config)
            t.equal(app.state.skin(config)?.activeVariant, nil)
            t.check(app.state.skin(config)?.layoutOptions.keys.contains(where: { $0.lowercased() == "active" }) == false)
            t.equal(capture().section(named: config)?["Active"], "0")
            t.equal(capture(LayoutSaveOptions(excludeUnloaded: true)).section(named: config), nil)
            t.check(app.activate(config: config, file: "Focus.ini") != nil)
            t.equal(capture().section(named: config)?["Active"], "2", "reactivation does not resurrect imported spelling")

            app.state.replaceLayout(LayoutStateCodec.decode(original, library: app.library))
            t.check(app.activate(config: config, file: "Compact.ini") != nil)
            t.equal(app.state.skin(config)?.activeVariant, nil)
            t.equal(capture().section(named: config)?["Active"], "1", "changing the variant writes its current index")
            t.equal(capture().section(named: config)?["FutureOption"], "kept")
            app.state.saveNow()
            let reopened = AppState(fileURL: app.state.fileURL)
            t.equal(LayoutStateCodec.capture(reopened.data, library: app.library, options: LayoutSaveOptions())
                .section(named: config)?["Active"], "1")
        }

        t.suite("App: Layouts: section order, globals and empty state survive restart") {
            let file = t.temporaryDirectory("layout-state").appendingPathComponent("state.json")
            let state = AppState(fileURL: file)
            state.updateUpdates { $0.automaticallyChecks = false; $0.lastNotifiedVersion = "0.2.0" }
            state.setDefaultSkinsInstalled(7)
            let document = IniDocument.parse("""
            [Z]
            Active=1
            LoadOrder=5
            WindowX=50%
            AnchorX=50%
            Group=Test
            Zoom=10
            FutureOption=kept
            [A]
            Active=1
            LoadOrder=5
            [First]
            Active=1
            LoadOrder=-1
            [Sleeping]
            Active=0
            """)
            state.replaceLayout(LayoutStateCodec.decode(document, library: []))
            t.equal(state.orderedConfigs.map(\.config), ["Z", "A", "First", "Sleeping"])
            t.equal(state.activeConfigs.map(\.config), ["First", "Z", "A"])
            t.check(state.data.hasLoadedLayout)
            t.check(!state.updates.automaticallyChecks)
            t.equal(state.data.defaultSkinsInstalled, 7)
            state.saveNow()
            let reopened = AppState(fileURL: file)
            t.equal(reopened.activeConfigs.map(\.config), ["First", "Z", "A"])
            t.equal(reopened.skin("z")?.windowX, "50%")
            t.equal(reopened.skin("z")?.anchorX, "50%")
            t.equal(reopened.skin("z")?.group, "Test")
            t.equal(reopened.skin("z")?.zoomFactor, 0.1)
            t.equal(reopened.skin("z")?.activeVariant, 1)
            t.equal(reopened.skin("z")?.layoutOptions["FutureOption"], "kept")
            state.replaceLayout(LayoutState(skins: [:], order: []))
            state.saveNow()
            let empty = AppState(fileURL: file)
            t.check(empty.data.skins.isEmpty && empty.data.hasLoadedLayout)
            t.equal(empty.updates.lastNotifiedVersion, "0.2.0")
            let legacy = try JSONDecoder().decode(AppStateData.self, from: Data(#"{"skins":{"B":{"file":"B.ini"},"A":{"file":"A.ini"}},"future":5}"#.utf8))
            t.equal(legacy.orderedConfigs.map(\.config), ["A", "B"])
            t.check(!legacy.hasLoadedLayout)
            t.check(legacy.unknownKeys["future"] != nil)
        }
    }
}
