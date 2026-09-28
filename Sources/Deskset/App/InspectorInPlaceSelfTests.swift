import AppKit
import DesksetCore

/// "App: studio in place": the inspector and the layer list following a step in place (InspectorInPlace.swift,
/// LayerListInPlace.swift) look exactly like the page and the list made again — the same pixels and the same views —
/// after each kind of step, its undo and its redo, on the five reference widgets, in light and dark; a change of what
/// the page is made of still makes it again.
enum InspectorInPlaceSelfTests {
    static func run(_ t: AppTestRunner) {
        pixelTests(t)
        structureTests(t)
    }

    /// One kind of step on the selected layer: the value it writes, from the value written before.
    struct Step {
        var key: String
        var value: (_ written: String?, _ m: Meter) -> String
    }

    static let steps: [Step] = [
        Step(key: "FontSize") { written, _ in
            let n = written.flatMap { OptionValue.number($0) } ?? 10
            return GeometryEdit.format(n.isFinite ? min(max(n, 1), 200) + 3 : 13)
        },
        Step(key: "FontColor") { _, _ in "13,121,201,254" },
        Step(key: "X") { _, m in GeometryEdit.format(m.frame.x + 7) },
        Step(key: "Text") { _, _ in "In place %1" },
        // Left ↔ Center, keeping up and down (which is a setting in use, the page's structure, when not Top).
        Step(key: "StringAlign") { written, _ in
            let (h, v) = InspectorWindowController.alignParts(written ?? "")
            return InspectorWindowController.alignValue(h: h == 1 ? 0 : 1, v: v)
        },
        Step(key: "Hidden") { written, _ in (OptionValue.number(written ?? "0") ?? 0) == 0 ? "1" : "0" },
    ]

    /// The inspector's column and the layer list, as drawn and described.
    struct Shown: Equatable {
        var inspector: InspectorWindowController.InspectorPicture
        var list: Data
        /// The list as a PNG, kept when `DESKSET_VERIFY_IN_PLACE_DIR` says where to write a difference.
        var listPNG: Data? = nil

        static func == (a: Shown, b: Shown) -> Bool { a.inspector == b.inspector && a.list == b.list }
    }

    static func shown(_ editor: InspectorWindowController) -> Shown {
        let inspector = editor.inspectorPicture()
        var list = Data()
        let outline = editor.outline
        outline.layoutSubtreeIfNeeded()
        if outline.bounds.width > 0, outline.bounds.height > 0,
           let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(outline.bounds.width * 2),
                                      pixelsHigh: Int(outline.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = outline.bounds.size
            outline.cacheDisplay(in: outline.bounds, to: rep)
            if let data = rep.bitmapData { list = Data(bytes: data, count: rep.bytesPerRow * rep.pixelsHigh) }
            if ProcessInfo.processInfo.environment["DESKSET_VERIFY_IN_PLACE_DIR"] != nil {
                return Shown(inspector: inspector, list: list, listPNG: rep.representation(using: .png, properties: [:]))
            }
        }
        return Shown(inspector: inspector, list: list)
    }

    /// What the step shows now, compared with the page and the list made again (in the same turn of the run loop, so
    /// the widget's live values are the same).
    static func compare(_ t: AppTestRunner, _ editor: InspectorWindowController, _ what: String) {
        let followed = shown(editor)
        let rebuilds = editor.inspectorRebuildCount
        editor.rebuildInspectorKeepingFocus(keepScroll: true)
        editor.reloadList()
        let made = shown(editor)
        editor.inspectorRebuildCount = rebuilds
        t.check(followed.inspector.pixels == made.inspector.pixels && !made.inspector.pixels.isEmpty,
                "\(what): the inspector's pixels are the page made again")
        if followed.inspector.views != made.inspector.views {
            let i = zip(followed.inspector.views, made.inspector.views).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            t.check(false, "\(what): the inspector's views: " + (i.map { "#\($0) \(followed.inspector.views[$0]) · made again \(made.inspector.views[$0])" }
                                                                   ?? "\(followed.inspector.views.count) / \(made.inspector.views.count) views"))
        }
        t.check(followed.list == made.list && !made.list.isEmpty, "\(what): the layer list's pixels are the list loaded again")
        if followed.list != made.list, let folder = ProcessInfo.processInfo.environment["DESKSET_VERIFY_IN_PLACE_DIR"] {
            let base = URL(fileURLWithPath: folder).appendingPathComponent(what.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "\\", with: "-"))
            try? followed.listPNG?.write(to: base.appendingPathExtension("list-in-place.png"))
            try? made.listPNG?.write(to: base.appendingPathExtension("list-made.png"))
        }
    }

    /// Makes a step and checks that the inspector followed it in place (not built again).
    static func step(_ t: AppTestRunner, _ editor: InspectorWindowController, _ what: String, _ make: () -> Void) {
        // A time format's choices show the time now: the step and the page made again are not a minute apart.
        let deadline = Date().addingTimeInterval(5)
        while Calendar.current.component(.second, from: Date()) >= 58, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let updates = editor.inPlace.updates, rebuilds = editor.inspectorRebuildCount
        make()
        t.check(editor.inPlace.updates > updates && editor.inspectorRebuildCount == rebuilds,
                "\(what): followed in place (\(editor.inPlace.lastFallback ?? "no fallback"))")
        compare(t, editor, what)
    }

    static func pixelTests(_ t: AppTestRunner) {
        t.suite("App: studio in place: the same pixels as the page made again") {
            // `DESKSET_STUDIO_LATENCY_ONLY` narrows these to the widgets it names too.
            let only = ProcessInfo.processInfo.environment["DESKSET_STUDIO_LATENCY_ONLY"]?.lowercased()
            for reference in StudioLatencySelfTests.references where only.map({ reference.config.lowercased().contains($0) }) ?? true {
                for dark in [false, true] {
                    guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: reference.config, from: reference.folder)
                    else { continue }
                    defer { editor.window?.close() }
                    editor.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let name = "\(reference.config) \(dark ? "dark" : "light")"
                    guard let skin = editor.skin, let target = skin.meters.first(where: { $0 is StringMeter })?.name else {
                        t.check(false, "\(name): a text layer")
                        continue
                    }
                    editor.select(section: target)
                    EditorWindowSelfTests.settle()
                    for s in steps {
                        guard let m = editor.skin?.meter(named: target) else { break }
                        let written = m.rawOption(s.key)
                        let value = s.value(written, m)
                        let what = "\(name) · \(s.key) \(written ?? "(unset)") → \(value)"
                        step(t, editor, what) {
                            editor.commit([.init(section: target, key: s.key, value: value, own: true)], name: "Change \(s.key)")
                        }
                        step(t, editor, "\(what), undone") { editor.window?.undoManager?.undo() }
                        step(t, editor, "\(what), redone") { editor.window?.undoManager?.redo() }
                        // The next kind starts from the widget as it was.
                        editor.window?.undoManager?.undo()
                        EditorWindowSelfTests.settle()
                    }
                    // A shared color on the widget page.
                    editor.canvasSelectionChanged([])
                    EditorWindowSelfTests.settle()
                    // (A color with others of the same value would leave them: the page lists those elsewhere, its
                    // structure changes.)
                    let groups = editor.skin.map { editor.widgetColorGroups($0) } ?? []
                    guard let group = groups.first(where: { $0.members.count == 1 && !$0.variables.isEmpty })
                            ?? groups.first(where: { !$0.variables.isEmpty }),
                          let variable = group.variables.first else {
                        t.check(false, "\(name): a shared color")
                        continue
                    }
                    let color = group.color == OptionValue.color("13,121,201,255") ? "201,81,13,255" : "13,121,201,255"
                    let what = "\(name) · widget page, [Variables] \(variable) → \(color)"
                    step(t, editor, what) {
                        editor.commit([.init(section: "Variables", key: variable, value: color, own: false)], name: "Change Color")
                    }
                    step(t, editor, "\(what), undone") { editor.window?.undoManager?.undo() }
                }
            }
        }
    }

    static func structureTests(_ t: AppTestRunner) {
        t.suite("App: studio in place: a change of what the page is made of builds it again") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Deskset\\Clock", from: "TestSkins"),
                  let target = editor.skin?.meters.first(where: { $0 is StringMeter })?.name else { return }
            defer { editor.window?.close() }
            editor.select(section: target)
            EditorWindowSelfTests.settle()
            func rebuilt(_ what: String, _ make: () -> Void) {
                let rebuilds = editor.inspectorRebuildCount
                make()
                t.equal(editor.inspectorRebuildCount, rebuilds + 1, "\(what): built again")
                t.check(editor.inPlace.lastFallback != nil, "\(what): because what the page is made of changed")
                compare(t, editor, what)
            }
            // A setting under "More" set: its dot and "· 1 in use".
            rebuilt("capitals set") {
                editor.commit([.init(section: target, key: "StringCase", value: "Upper", own: true)], name: "Change Capitals")
            }
            rebuilt("capitals set, undone") { editor.window?.undoManager?.undo() }
            // The effect's color shows only with an effect.
            rebuilt("an effect") {
                editor.commit([.init(section: target, key: "StringEffect", value: "Shadow", own: true)], name: "Change Effect")
            }
            editor.window?.undoManager?.undo()
            // Up and down: a setting in use.
            let align = editor.skin?.meter(named: target)?.rawOption("StringAlign") ?? ""
            let (h, v) = InspectorWindowController.alignParts(align)
            rebuilt("up and down") {
                editor.commit([.init(section: target, key: "StringAlign", value: InspectorWindowController.alignValue(h: h, v: v == 2 ? 0 : 2),
                                      own: true)], name: "Change Align")
            }
            editor.window?.undoManager?.undo()
            // Another layer selected: another page.
            if let other = editor.skin?.meters.first(where: { $0.name.caseInsensitiveCompare(target) != .orderedSame })?.name {
                let rebuilds = editor.inspectorRebuildCount
                editor.select(section: other)
                t.equal(editor.inspectorRebuildCount, rebuilds + 1, "another layer: built again")
            }
            // Loaded again (a new skin object): the page's controls keep the old one's layers, so the next value step makes
            // it again (a load that changes nothing it shows keeps it, as before).
            editor.select(section: target)
            editor.session?.reloadStudioSkin()
            let rebuilds = editor.inspectorRebuildCount
            editor.commit([.init(section: target, key: "FontSize", value: "15", own: true)], name: "Change Font Size")
            t.equal(editor.inspectorRebuildCount, rebuilds + 1, "a step after the widget's instance was loaded again: built again")
            t.equal(editor.inPlace.lastFallback, "not built", "because the page shows the old instance")
            let updates = editor.inPlace.updates
            editor.commit([.init(section: target, key: "FontSize", value: "16", own: true)], name: "Change Font Size")
            t.equal(editor.inPlace.updates, updates + 1, "and the next one follows in place again")
            // Off: every step builds the page again.
            InspectorInPlace.isOffForTests = true
            defer { InspectorInPlace.isOffForTests = false }
            let before = editor.inspectorRebuildCount
            editor.commit([.init(section: target, key: "FontSize", value: "17", own: true)], name: "Change Font Size")
            t.equal(editor.inspectorRebuildCount, before + 1, "with in-place updates off, a value step builds the page again")
        }
    }
}
