import Foundation
@testable import DesksetCore

// A built-in widget's differences from the copy the app ships (`OriginalCopy`): places changed, and which files count.

func runOriginalCopyTests(_ t: TestRunner) {
    t.suite("Original copy: places changed") {
        let a = "[Variables]\nA=1\nB=2\nC=3\n\n[Meter]\nX=0\n"
        t.equal(OriginalCopy.placesChanged(a, a), 0)
        t.equal(OriginalCopy.placesChanged(a, a.replacingOccurrences(of: "\n", with: "\r\n")), 0, "line endings")
        t.equal(OriginalCopy.placesChanged(a, a.replacingOccurrences(of: "B=2", with: "B=5")), 1, "one line changed")
        t.equal(OriginalCopy.placesChanged(a, a.replacingOccurrences(of: "A=1\nB=2", with: "A=9\nB=9")), 1,
                "two lines together are one place")
        t.equal(OriginalCopy.placesChanged(a, a.replacingOccurrences(of: "A=1", with: "A=9")
            .replacingOccurrences(of: "X=0", with: "X=4")), 2, "two places apart")
        t.equal(OriginalCopy.placesChanged(a, a + "[New]\nMeter=String\nText=Hi\n"), 1, "a section added")
        t.equal(OriginalCopy.placesChanged(a, a.replacingOccurrences(of: "C=3\n", with: "")), 1, "a line removed")
        t.equal(OriginalCopy.placesChanged("", "A=1"), 1)
        t.equal(OriginalCopy.placesChanged("A=1\n", "A=1"), 0, "a final line ending is not a line")
    }

    t.suite("Original copy: the widget's own files against the shipped ones") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DesksetOriginal-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let skins = root.appendingPathComponent("Skins"), shipped = root.appendingPathComponent("Shipped")
        func write(_ base: URL, _ path: String, _ text: String) {
            let url = base.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        for base in [skins, shipped] {
            write(base, "Suite/Clock/Medium.ini", "[Rainmeter]\nUpdate=1000\n[Variables]\nColor=255,0,0\n")
            write(base, "Suite/Clock/Parts.inc", "[Meter]\nMeter=String\n")
            write(base, "Suite/@Resources/Look.inc", "[Variables]\nLook=Auto\n")
        }
        write(skins, "Suite/Clock/Medium.ini", "[Rainmeter]\nUpdate=1000\n[Variables]\nColor=0,255,0\n")
        write(skins, "Suite/@Resources/Look.inc", "[Variables]\nLook=Dark\n")
        let files = ["Suite/Clock/Medium.ini", "Suite/Clock/Parts.inc", "Suite/@Resources/Look.inc", "Suite/Clock/Extra.inc"]
            .map { skins.appendingPathComponent($0) }
        let changes = OriginalCopy.changes(files: files, widgetFolder: skins.appendingPathComponent("Suite/Clock"),
                                           skinsDirectory: skins, originals: shipped) {
            try? String(contentsOf: $0, encoding: .utf8)
        }
        t.equal(changes.map(\.file.lastPathComponent), ["Medium.ini"],
                "only the widget's own changed file (not the suite's shared one, not one the app does not ship)")
        t.equal(changes.first?.places, 1)
        t.equal(changes.first?.originalText, "[Rainmeter]\nUpdate=1000\n[Variables]\nColor=255,0,0\n")
        // The Studio's text of a file counts, not the disk's.
        let buffered = OriginalCopy.changes(files: files, widgetFolder: skins.appendingPathComponent("Suite/Clock"),
                                            skinsDirectory: skins, originals: shipped) { url in
            url.lastPathComponent == "Medium.ini" ? "[Rainmeter]\nUpdate=1000\n[Variables]\nColor=255,0,0\n"
                : try? String(contentsOf: url, encoding: .utf8)
        }
        t.equal(buffered, [], "the buffer says it is back as shipped")
        // No shipped copy: nothing to put back.
        t.equal(OriginalCopy.changes(files: files, widgetFolder: skins.appendingPathComponent("Suite/Clock"),
                                     skinsDirectory: skins, originals: root.appendingPathComponent("None")) { _ in "x" }, [])
    }

    t.suite("Original copy: the widget's settings are not its design") {
        let original = "[Variables]\n@Include=#@#Variables.inc\nCardW=360\nColor=255,0,0\n\n[MeasureTime]\nMeasure=Time\nFormat=%H:%M\n"
        let settings: Set<OriginalCopy.Setting> = [.init(section: "Variables", key: "TempUnit"),
                                                   .init(section: "MeasureTime", key: "Format")]
        // °F added after the includes, the clock made 12-hour: settings only.
        let options = original.replacingOccurrences(of: "CardW=360", with: "CardW=360\nTempUnit=F")
            .replacingOccurrences(of: "%H:%M", with: "%I:%M")
        t.equal(OriginalCopy.placesChanged(OriginalCopy.without(settings, original), OriginalCopy.without(settings, options)),
                0, "no change of the design")
        // A color as well: one place, and restoring keeps the settings.
        let both = options.replacingOccurrences(of: "Color=255,0,0", with: "Color=0,255,0")
        t.equal(OriginalCopy.placesChanged(OriginalCopy.without(settings, original), OriginalCopy.without(settings, both)), 1)
        let restored = OriginalCopy.restored(original, keeping: settings, of: both)
        t.check(restored.contains("Color=255,0,0"), "the color goes back")
        t.check(restored.contains("TempUnit=F"), "°F stays")
        t.check(restored.contains("Format=%I:%M"), "12-hour stays")
        t.equal(OriginalCopy.placesChanged(OriginalCopy.without(settings, original), OriginalCopy.without(settings, restored)),
                0, "nothing of the design is left to revert")
        // A setting the original has and the copy took away is taken away again.
        let removed = original.replacingOccurrences(of: "Format=%H:%M\n", with: "")
        t.check(!OriginalCopy.restored(original, keeping: settings, of: removed).contains("Format="))
        t.equal(OriginalCopy.restored(original, keeping: settings, of: original), original, "nothing to keep")
    }
}
