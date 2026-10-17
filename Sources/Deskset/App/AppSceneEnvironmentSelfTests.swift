import AppKit
import DesksetCore

enum AppSceneEnvironmentSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("Runtime: scene environment: file versions preserve replacements and the existing recording") {
            let folder = t.temporaryDirectory("scene-file-stamps")
            let file = folder.appendingPathComponent("image.bin")
            let replacement = folder.appendingPathComponent("replacement.bin")
            let date = Date(timeIntervalSince1970: 1_700_000_000.125)
            try Data([1, 2, 3, 4]).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
            let environment: any SceneEnvironment = AppSceneEnvironment(scale: 2, appearance: .light,
                                                                       appearanceName: "NSAppearanceNameAqua")
            guard let first = environment.imageStamp(file.path) else {
                return t.check(false, "a regular file has a version before it has been decoded")
            }
            t.equal(first.size, 4)
            t.equal(environment.imageStamp(file.path), first)
            let frozen = ImageDependency(path: file.path, stamp: first)
            let recorded = Images.recordingFiles { _ = environment.imageStamp(file.path) }
            t.equal(recorded.paths, [file.path])
            t.check(Images.filesUnchanged(recorded))

            // An editor can replace a file while preserving both its size and its modification time.
            try Data([4, 3, 2, 1]).write(to: replacement)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: replacement.path)
            guard rename(replacement.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            guard let replaced = environment.imageStamp(file.path) else {
                return t.check(false, "the replacement has a version")
            }
            t.equal(replaced.seconds, first.seconds)
            t.equal(replaced.nanoseconds, first.nanoseconds)
            t.equal(replaced.size, first.size)
            t.check(replaced.inode != first.inode, "the inode identifies a replacement with identical time and size")
            t.check(ImageDependency(path: file.path, stamp: replaced) != frozen)
            t.equal(frozen.stamp, first, "a captured dependency does not follow later filesystem changes")
            t.check(!Images.filesUnchanged(recorded), "scene lookups join the existing drawing's file recording")

            try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(5)],
                                                  ofItemAtPath: file.path)
            let modified = environment.imageStamp(file.path)
            t.equal(modified?.inode, replaced.inode)
            t.check(modified != replaced, "an edit of the same inode also changes its version")
            try FileManager.default.removeItem(at: file)
            t.check(environment.imageStamp(file.path) == nil)
            t.check(environment.imageStamp(folder.path) == nil, "directories are not image files")
        }

        t.suite("Runtime: scene environment: missing images, decode aliases and symbols keep their dependencies") {
            let file = t.temporaryDirectory("scene-missing-image").appendingPathComponent("image.png")
            let environment = AppSceneEnvironment(scale: 2, appearance: .light, appearanceName: "NSAppearanceNameAqua")
            let missing = ImageDependency(path: file.path, stamp: environment.imageStamp(file.path))
            let recorded = Images.recordingFiles { _ = environment.imageStamp(file.path) }
            t.check(missing.stamp == nil)
            t.equal(recorded.paths, [file.path], "missing files still participate in invalidation")
            t.check(Images.filesUnchanged(recorded))

            try SharedServiceThreadingSelfTests.writePNG(to: file.path, width: 128, height: 64)
            let present = ImageDependency(path: file.path, stamp: environment.imageStamp(file.path))
            t.check(present.stamp != nil && present != missing, "a file appearing invalidates the missing dependency")
            t.equal(present.path, missing.path)
            t.check(missing.stamp == nil, "the old dependency remains an immutable missing value")
            t.check(!Images.filesUnchanged(recorded))
            t.check(Images.cachedImage(file.path) == nil, "version queries do not decode the image")

            let alias = Images.drawnPath(file.path, maxPixelSide: 32)
            t.check(alias != file.path, "the fixture has a distinct smaller-decode path")
            let aliasRecording = Images.recordingFiles {
                t.equal(environment.imageStamp(alias), present.stamp)
            }
            t.equal(aliasRecording.paths, [file.path], "a decode alias records the original source file")
            t.check(Images.cachedImage(file.path) == nil && Images.cachedImage(alias) == nil)

            let symbol = MacSymbol(name: "cpu.fill").path
            let otherSymbol = MacSymbol(name: "cpu.fill", style: .init(weight: .bold)).path
            let symbols = Images.recordingFiles {
                t.check(environment.imageStamp(symbol) == nil)
                t.check(environment.imageStamp(otherSymbol) == nil)
            }
            t.check(symbols.paths.isEmpty, "canonical symbols never enter filesystem lookup or recording")
            t.check(ImageDependency(path: symbol, stamp: nil) != ImageDependency(path: otherSymbol, stamp: nil),
                    "a symbol's complete style remains its dependency identity without a file stamp")
            defer { Images.purge() }
            t.check(Images.cgImage(atPath: file.path) != nil, "the undecoded fixture is a valid image")
        }

        t.suite("Runtime: scene environment: image purges advance a live epoch without changing file versions") {
            let file = t.temporaryDirectory("scene-image-epoch").appendingPathComponent("image.bin")
            try Data([1]).write(to: file)
            let environment = AppSceneEnvironment(scale: 1.5, appearance: .dark,
                                                  appearanceName: "NSAppearanceNameDarkAqua")
            let fileStamp = environment.imageStamp(file.path)
            let before = environment.stamp
            t.equal(before.imageGeneration, Images.purgeGeneration)
            Images.purge()
            let after = environment.stamp
            t.equal(after.imageGeneration, before.imageGeneration + 1)
            t.check(after != before, "an existing environment observes an explicit cache invalidation")
            t.equal(after.scale, before.scale)
            t.equal(after.appearance, before.appearance)
            t.equal(after.fontGeneration, before.fontGeneration)
            t.equal(environment.imageStamp(file.path), fileStamp)
            t.equal(environment.stamp, after, "reading a version has no invalidation side effect")
        }

        t.suite("Runtime: scene environment: font registration and removal advance an existing environment") {
            let folder = t.temporaryDirectory("scene-font-epoch").appendingPathComponent("Fonts")
            guard AppSelfTest.makeTestFont(family: "DesksetEnvA", at: folder.appendingPathComponent("A.ttf")) else {
                print("    (skipped: Courier New not found)")
                return
            }
            defer {
                try? FileManager.default.removeItem(at: folder)
                Fonts.rescanFolder(folder.path)
            }
            let environment = AppSceneEnvironment(scale: 2, appearance: .light, appearanceName: "NSAppearanceNameAqua")
            let before = environment.stamp
            t.equal(before.fontGeneration, UInt64(Fonts.generation))
            t.check(Fonts.rescanFolder(folder.path), "the fixture font registers through the existing app service")
            let registered = environment.stamp
            t.check(registered.fontGeneration > before.fontGeneration)
            t.equal(registered.fontGeneration, UInt64(Fonts.generation))
            t.equal(registered.appearance, before.appearance)
            t.equal(registered.imageGeneration, before.imageGeneration)
            try FileManager.default.removeItem(at: folder)
            t.check(Fonts.rescanFolder(folder.path), "the removed fixture font is unregistered")
            t.check(environment.stamp.fontGeneration > registered.fontGeneration)
            t.check(registered != before, "captured versions remain independent of later registrations")
        }

        t.suite("Runtime: scene environment: every appearance fact and the view name participate in equality") {
            var appearance = SkinAppearance.light
            let environment = AppSceneEnvironment(scale: 2, appearance: appearance, appearanceName: "NSAppearanceNameAqua")
            let first = environment.stamp
            t.equal(first.appearance.value, appearance)
            t.equal(first.appearance.name, "NSAppearanceNameAqua")
            t.equal(first.scale, 2)
            appearance.accentColor = RGBA(r: 15, g: 25, b: 35, a: 45)
            t.equal(environment.stamp, first, "the environment captures appearance by value")

            let changes: [(String, (inout SkinAppearance) -> Void)] = [
                ("dark mode", { $0.isDark.toggle() }),
                ("accent", { $0.accentColor = RGBA(r: 1, g: 2, b: 3, a: 4) }),
                ("label", { $0.labelColor = RGBA(r: 2, g: 3, b: 4, a: 5) }),
                ("secondary label", { $0.secondaryLabelColor = RGBA(r: 3, g: 4, b: 5, a: 6) }),
                ("tertiary label", { $0.tertiaryLabelColor = RGBA(r: 4, g: 5, b: 6, a: 7) }),
                ("separator", { $0.separatorColor = RGBA(r: 5, g: 6, b: 7, a: 8) }),
                ("clock", { $0.regional.clockHours = 12 }),
                ("first weekday", { $0.regional.firstWeekday = 1 }),
                ("temperature", { $0.regional.temperatureUnit = .fahrenheit }),
            ]
            for (name, change) in changes {
                var changed = first.appearance.value
                change(&changed)
                let next = AppSceneEnvironment(scale: 2, appearance: changed, appearanceName: first.appearance.name).stamp
                t.check(next != first, "the \(name) is part of the environment version")
                t.equal(next.appearance.value, changed, "the \(name) reaches the scene without normalization")
            }
            let named = AppSceneEnvironment(scale: 2, appearance: first.appearance.value,
                                             appearanceName: "NSAppearanceNameAccessibilityHighContrastAqua").stamp
            t.check(named != first, "the view's appearance name matters even with identical semantic colors")
            let scaled = AppSceneEnvironment(scale: 1, appearance: first.appearance.value,
                                              appearanceName: first.appearance.name).stamp
            t.check(scaled != first, "backing scale is part of the version")
            let same = AppSceneEnvironment(scale: 2, appearance: first.appearance.value,
                                            appearanceName: first.appearance.name).stamp
            t.equal(same, first, "equivalent captured facts and resource versions have equal stamps")
        }
    }
}
