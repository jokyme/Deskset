import AppKit
import DesksetCore

/// The fool-proof inspector (docs/editor-design.md §3) and the Shape editor (§4): one control per value kind, the
/// text each control writes, invalid values kept, variable pills, inherited values, the Shape editor's operations.
extension AppSelfTest {
    /// An original test skin with one option of every kind.
    static let kindsSkin = """
        [Rainmeter]
        Update=1000

        [Variables]
        Size=12
        Accent=255,128,0,255

        [StyleBig]
        FontSize=20
        FontColor=10,20,30,255

        [MeasureTime]
        Measure=Time
        Format=%H:%M

        [MeasureCalc]
        Measure=Calc
        Formula=1+2
        IfCondition=MeasureCalc > 2
        IfTrueAction=[!Log yes]

        [MeasureLoad]
        Measure=Calc
        Formula=50
        MaxValue=100

        [Text]
        Meter=String
        MeasureName=MeasureTime
        MeterStyle=StyleBig
        X=10
        Y=10
        Text=%1
        FontFace=Helvetica
        StringEffect=aaaa
        Angle=0
        Padding=1,1,1,1
        AntiAlias=1
        LeftMouseUpAction=[!Log click]
        InlineSetting=Case | Upper

        [VarText]
        Meter=String
        X=10
        Y=40
        FontSize=#Size#
        Text=Hi

        [Bar]
        Meter=Bar
        MeasureName=MeasureLoad
        X=10
        Y=70
        W=100
        H=10
        BarColor=#Accent#
        BarOrientation=Vertical

        [Pic]
        Meter=Image
        ImageName=#@#dot.png
        X=10
        Y=90
        W=10
        H=10
        ImageAlpha=255
        ImageRotate=0

        [Shapes]
        Meter=Shape
        X=10
        Y=110
        Shape=Rectangle 0,0,40,20,4 | Fill Color 255,0,0,255 | StrokeWidth 2
        Shape2=Ellipse 20,10,5
        Shape3=Combine Shape | Union Shape2

        [BadShape]
        Meter=Shape
        X=60
        Y=110
        Shape=aaaa 0,0,10,10
        Shape2=(12) 34

        """

    /// A headless app with Studio\Kinds (the skin above, a 4 × 4 image in @Resources) loaded in the editor.
    static func makeKindsEditor(_ t: AppTestRunner) throws -> (AppController, InspectorWindowController, URL)? {
        guard let app = try makeApp(t) else { return nil }
        let folder = app.skinsDirectory.appendingPathComponent("Studio/Kinds")
        let resources = app.skinsDirectory.appendingPathComponent("Studio/@Resources")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let ini = folder.appendingPathComponent("Kinds.ini")
        try kindsSkin.write(to: ini, atomically: true, encoding: .utf8)
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: resources.appendingPathComponent("dot.png"))
        }
        guard let c = app.activate(config: "Studio\\Kinds", file: "Kinds.ini") else {
            t.check(false, "Studio\\Kinds loads")
            return nil
        }
        app.showInspector(for: c)
        guard let editor = app.inspector else {
            t.check(false, "editor opens")
            return nil
        }
        // Every "More … Options" open, so each control of every kind is on the page (the friendly pages keep the
        // settings that are not in use behind them: docs/editor-friendly.md §7.2).
        editor.inspectorState.disclosures.insert("open/more:*")
        editor.rebuildInspector()
        return (app, editor, ini)
    }

    static func inspectorControlTests(_ t: AppTestRunner) {
        t.suite("App: inspector controls per kind") {
            guard let (app, editor, ini) = try makeKindsEditor(t) else { return }
            func find(_ id: String) -> NSView? { editor.inspectorStack.findSubview { $0.identifier?.rawValue == id } }
            func control(_ key: String) -> NSView? { editor.inspectorControl(for: key) }
            func check<T>(_ key: String, is type: T.Type, line: UInt = #line) {
                t.check(control(key) is T, "\(key) → \(T.self), got \(control(key).map { String(describing: Swift.type(of: $0)) } ?? "nothing")",
                        line: line)
            }
            editor.select(section: "Text")
            check("MeasureName", is: NSPopUpButton.self)
            check("FontFace", is: NSPopUpButton.self)
            check("FontSize", is: NumberControl.self)
            t.check((control("FontSize") as? NumberControl)?.stepper != nil, "a stepper for the font size")
            check("FontColor", is: SwatchButton.self)
            check("StringAlign", is: NSSegmentedControl.self)
            check("StringAlign.vertical", is: NSSegmentedControl.self)
            check("Angle", is: AngleControl.self)
            t.check((control("Angle") as? AngleControl)?.dial != nil, "a circular slider for a rotation")
            check("Padding", is: InsetsControl.self)
            check("AntiAlias", is: NSButton.self)
            t.equal((control("AntiAlias") as? NSButton)?.state, .on, "AntiAlias=1 is checked")
            // Text showing live data: the token field, its %1 a tag.
            let tokens = editor.inspectorStack.findSubview { $0.identifier?.rawValue == "text-tokens" } as? DataTokenField
            t.equal(tokens?.tokens, [1], "Text=%1: one data tag")
            t.equal(tokens?.stringValue, "%1")
            // A click action: the picker; one it can't read back stays a sentence.
            check("LeftMouseUpAction.choice", is: NSPopUpButton.self)
            t.equal((control("LeftMouseUpAction.choice") as? NSPopUpButton)?.selectedItem?.representedObject as? String,
                    InspectorWindowController.ClickChoice.custom.rawValue)
            check("MeterStyle", is: StyleListControl.self)
            check("ClipString", is: NSPopUpButton.self)
            t.check(editor.inspectorStack.findSubview { $0.identifier?.rawValue == "style-token-StyleBig" } != nil, "style token")

            editor.select(section: "Bar")
            check("BarOrientation", is: ChoiceSegmentedControl.self)
            check("BarColor", is: SwatchButton.self)
            editor.select(section: "Pic")
            check("ImageName", is: ImageControl.self)
            t.check((control("ImageName") as? ImageControl)?.thumbnail.image?.size.width ?? 0 > 0, "thumbnail of the file")
            t.equal(((control("ImageName") as? ImageControl)?.popup.selectedItem?.representedObject as? String), "#@#dot.png",
                    "the file is selected among the images of @Resources")
            check("ImageAlpha", is: PercentControl.self)
            t.equal((control("ImageAlpha") as? PercentControl)?.field.stringValue, "100", "255 is 100 %")
            check("ImageRotate", is: AngleControl.self)
            // The hour before and after building the preview: the check holds when the hour turns in between.
            let hourBefore = TimeFormatting.format(Date(), format: "%H")
            editor.select(section: "MeasureTime")
            // Format: examples rendered now; Custom… opens the format itself with its live preview.
            t.check(find("time-format") is NSPopUpButton, "a menu of rendered examples")
            editor.inspectorState.disclosures.insert("time-custom/measuretime")
            editor.rebuildInspector()
            check("Format", is: FormatControl.self)
            let preview = (control("Format") as? FormatControl)?.preview.stringValue ?? ""
            let hourAfter = TimeFormatting.format(Date(), format: "%H")
            t.check(preview.contains(hourBefore) || preview.contains(hourAfter), "live preview of the format: \(preview)")
            editor.select(section: "MeasureCalc")
            // A formula: its value, "calculated", and [Edit Formula…] for the formula itself.
            t.check(find("edit-formula") is NSButton, "Edit Formula…")
            editor.inspectorState.disclosures.insert("formula/measurecalc")
            editor.rebuildInspector()
            check("Formula", is: ValueField.self)
            t.equal((control("Formula") as? ValueField)?.font?.isFixedPitch, true, "a formula is code: the code font")
            // Its rule reads as a sentence.
            t.equal((find("rule-0") as? NSTextField)?.stringValue, "When the value is above 2 → writes to the log")
            editor.select(section: "Shapes")
            check("Shape", is: ShapeEditorView.self)
            editor.select(section: "VarText")
            check("FontSize", is: NumberControl.self)
            t.equal((control("FontSize") as? NumberControl)?.field.stringValue, "12", "a #Var# value shows the variable's value")
            t.check(editor.inspectorStack.findSubview { $0 is PillView } != nil, "and a pill naming the variable")

            // INI names only in tooltips, unless Settings says otherwise.
            editor.select(section: "Text")
            func showsKeyLabel() -> Bool {
                editor.inspectorStack.findSubview { ($0 as? NSTextField)?.stringValue == "StringCase" } != nil
            }
            t.check(!showsKeyLabel(), "INI names hidden")
            app.state.updateEditor { $0.showIniNames = true }
            editor.rebuildInspector()
            t.check(showsKeyLabel(), "INI names shown when the setting is on")
            app.state.updateEditor { $0.showIniNames = false }

            // Lines the controls can't show (with Rainmeter Details): only what the schema does not cover.
            app.state.updateEditor { $0.showIniNames = true }
            editor.rebuildInspector()
            let unshown = find("card-unshown")
            t.check(unshown?.findSubview { $0.identifier?.rawValue == "Text/InlineSetting" } != nil, "InlineSetting listed")
            let listed = unshown?.subviewsMatching { ($0.identifier?.rawValue ?? "").hasPrefix("Text/") && $0 is NSTextField && !($0 is ValueField) }
                .compactMap { $0.identifier?.rawValue } ?? []
            t.equal(listed, ["Text/InlineSetting"], "covered options are not repeated")
            t.check(unshown?.findSubview { $0.identifier?.rawValue == "edit-in-code" } != nil, "Edit in Code")
            app.state.updateEditor { $0.showIniNames = false }
            withExtendedLifetime(ini) {}
            editor.window?.close()
        }

        t.suite("App: inspector controls write the right text") {
            guard let (app, editor, ini) = try makeKindsEditor(t) else { return }
            func text() -> String { (try? String(contentsOf: ini, encoding: .utf8)) ?? "" }
            func section(_ name: String) -> String {
                let t = text()
                guard let r = t.range(of: "[\(name)]") else { return "" }
                let rest = t[r.upperBound...]
                return String(rest[..<(rest.range(of: "\n[")?.lowerBound ?? rest.endIndex)])
            }
            func skin() -> Skin? { app.controller(for: "Studio\\Kinds")?.skin }
            func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            func control(_ key: String) -> NSView? { editor.inspectorControl(for: key) }

            // Bool: a checkbox writes 1 / 0.
            editor.select(section: "Text")
            t.check(editor.chooseOption("AntiAlias", value: "0"), "checkbox")
            t.check(section("Text").contains("AntiAlias=0\n"), "unchecked writes 0")
            settle()

            // An invalid choice stays, selected and disabled, with a warning; nothing replaces it.
            guard let effect = control("StringEffect") as? NSPopUpButton else { return t.check(false, "effect menu") }
            t.equal(effect.selectedItem?.title, "“aaaa”")
            t.equal(effect.selectedItem?.isEnabled, false, "shown disabled")
            t.equal(effect.itemArray.dropFirst(2).compactMap { $0.representedObject as? String }, ["None", "Shadow", "Border"],
                    "then the valid choices")
            let warnings = editor.inspectorStack.subviewsMatching { $0.identifier?.rawValue == "issue" }
                .map { $0.accessibilityLabel() ?? "" }
            t.check(warnings.contains { $0.contains("“aaaa” is not one of the choices for Effect") }, "warning: \(warnings)")
            t.check(section("Text").contains("StringEffect=aaaa\n"), "not replaced by a refresh")

            // Align (Left | Center | Right) and Up and down (Top | Middle | Bottom) map to the nine values.
            func segments(_ key: String) -> NSSegmentedControl? { control(key) as? NSSegmentedControl }
            guard let horizontal = segments("StringAlign") else { return t.check(false, "alignment") }
            horizontal.selectedSegment = 2
            horizontal.sendAction(horizontal.action, to: horizontal.target)
            t.check(section("Text").contains("StringAlign=Right\n"), "Right (and Top)")
            settle()
            if let vertical = segments("StringAlign.vertical") {
                vertical.selectedSegment = 2
                vertical.sendAction(vertical.action, to: vertical.target)
            }
            t.check(section("Text").contains("StringAlign=RightBottom\n"), "Right + Bottom")
            settle()
            t.equal([segments("StringAlign")?.selectedSegment, segments("StringAlign.vertical")?.selectedSegment], [2, 2], "read back")
            if let horizontal = segments("StringAlign"), let vertical = segments("StringAlign.vertical") {
                vertical.selectedSegment = 0
                vertical.sendAction(vertical.action, to: vertical.target)
                settle()
                segments("StringAlign")?.selectedSegment = 1
                segments("StringAlign").map { $0.sendAction($0.action, to: $0.target) }
                _ = horizontal
            }
            t.check(section("Text").contains("StringAlign=Center\n"), "Center + Top is written short")
            settle()

            // Insets: linked fields write one value four times; unlinked, each its own.
            guard let insets = control("Padding") as? InsetsControl else { return t.check(false, "insets") }
            t.check(insets.isLinked, "equal sides start linked")
            insets.fields[0].type("3")
            t.check(section("Text").contains("Padding=3,3,3,3\n"), "linked: \(section("Text"))")
            settle()
            if let insets = control("Padding") as? InsetsControl {
                insets.link.performClick(nil)
                t.check(!insets.isLinked, "unlinked")
                insets.fields[1].type("5")
            }
            t.check(section("Text").contains("Padding=3,5,3,3\n"), "unlinked")
            settle()
            t.equal((control("Padding") as? InsetsControl)?.isLinked, false, "the link state survives the refresh")

            // Angle in radians: degrees shown, (Rad(n)) written and read back.
            (control("Angle") as? AngleControl)?.field.type("90")
            t.check(section("Text").contains("Angle=(Rad(90))\n"), "radians written as (Rad(90))")
            settle()
            t.equal((control("Angle") as? AngleControl)?.field.stringValue, "90", "(Rad(90)) shows 90°")
            t.close(Double((skin()?.meter(named: "Text") as? StringMeter)?.double("Angle", 0) ?? 0), .pi / 2, accuracy: 1e-6,
                    "the engine reads π/2")

            // Segmented choice.
            editor.select(section: "Bar")
            // Fills toward → (BarOrientation and Flip in one control).
            t.check(editor.chooseOption("BarOrientation", value: "Right"), "segment")
            t.check(section("Bar").contains("BarOrientation=Horizontal\n"))
            settle()

            // Percent: the field writes 0–255; the slider previews and writes once, on release.
            editor.select(section: "Pic")
            (control("ImageAlpha") as? PercentControl)?.field.type("50")
            t.check(section("Pic").contains("ImageAlpha=128\n"), "50 % = 128")
            settle()
            guard let percent = control("ImageAlpha") as? PercentControl else { return t.check(false, "percent") }
            percent.slider.doubleValue = 25
            percent.slider.sendAction(percent.slider.action, to: percent.slider.target)
            t.check(editor.isPreviewingProperty, "previewing while dragging")
            t.check(section("Pic").contains("ImageAlpha=128\n"), "nothing written while dragging")
            t.equal(skin()?.meter(named: "Pic")?.rawOption("ImageAlpha"), "64", "the skin shows the preview")
            percent.slider.onTrackingEnded?()
            t.check(section("Pic").contains("ImageAlpha=64\n"), "written on release")
            t.check(!editor.isPreviewingProperty)
            settle()
            editor.window?.undoManager?.undo()
            t.check(section("Pic").contains("ImageAlpha=128\n"), "one undo step for the drag")
            settle()
            (control("ImageRotate") as? AngleControl)?.field.type("45")
            t.check(section("Pic").contains("ImageRotate=45\n"), "degrees written as they are")
            settle()

            // A held stepper previews each step and writes the last one where the value is defined (the style).
            editor.select(section: "Text")
            guard let size = control("FontSize") as? NumberControl, let stepper = size.stepper else { return t.check(false, "stepper") }
            stepper.doubleValue = 22
            stepper.sendAction(stepper.action, to: stepper.target)
            t.check(section("StyleBig").contains("FontSize=20\n"), "not written while held")
            stepper.onTrackingEnded?()
            t.check(section("StyleBig").contains("FontSize=22\n"), "written to StyleBig on release")
            t.check(!section("Text").contains("FontSize"), "not on the layer")
            settle()
            editor.window?.undoManager?.undo()
            settle()

            // Typing a number: clamped to the option's limits; letters refused.
            (control("FontSize") as? NumberControl)?.field.type("big")
            t.check(section("StyleBig").contains("FontSize=20\n"), "letters are not written")
            t.check(editor.toastText.contains("not a number"), "and explained: \(editor.toastText)")
            t.equal((control("FontSize") as? NumberControl)?.field.stringValue, "20", "the written value is back")
            (control("FontSize") as? NumberControl)?.field.type("5000")
            t.check(section("StyleBig").contains("FontSize=1000\n"), "clamped to 1000")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            // A color's code can be typed with Rainmeter Details on (the default shows its name).
            app.state.updateEditor { $0.showIniNames = true }
            editor.rebuildInspector()
            defer { app.state.updateEditor { $0.showIniNames = false } }
            if let color = editor.inspectorStack.findSubview(where: { $0.identifier?.rawValue == "StyleBig/FontColor" || $0.identifier?.rawValue == "Text/FontColor" }) as? ValueField {
                color.type("purple")
                t.check(section("StyleBig").contains("FontColor=10,20,30,255\n"), "an invalid color is refused")
                t.check(editor.toastText.contains("not a color"), "and explained: \(editor.toastText)")
            } else {
                t.check(false, "color field")
            }
            settle()

            // A preview still pending (a keyboard step waits for a pause) is written when the window closes.
            editor.select(section: "Pic")
            if let percent = control("ImageAlpha") as? PercentControl {
                percent.slider.doubleValue = 10
                percent.slider.sendAction(percent.slider.action, to: percent.slider.target)
            }
            t.check(editor.isPreviewingProperty, "pending")
            editor.window?.close()
            t.check(section("Pic").contains("ImageAlpha=26\n"), "written on close: \(section("Pic"))")
        }

        t.suite("App: inspector pills, inherited values, reset") {
            guard let (app, editor, ini) = try makeKindsEditor(t) else { return }
            func text() -> String { (try? String(contentsOf: ini, encoding: .utf8)) ?? "" }
            func section(_ name: String) -> String {
                let t = text()
                guard let r = t.range(of: "[\(name)]") else { return "" }
                let rest = t[r.upperBound...]
                return String(rest[..<(rest.range(of: "\n[")?.lowerBound ?? rest.endIndex)])
            }
            func skin() -> Skin? { app.controller(for: "Studio\\Kinds")?.skin }
            func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

            // Edit Variable writes the variable; the option keeps using it.
            editor.select(section: "VarText")
            guard let field = editor.editPill("FontSize") else { return t.check(false, "Edit Variable opens a field") }
            t.equal(field.stringValue, "12", "the variable's value")
            field.type("14")
            t.check(section("Variables").contains("Size=14\n"), "variable written")
            t.check(section("VarText").contains("FontSize=#Size#\n"), "the option still uses it")
            t.equal(skin()?.meter(named: "VarText").flatMap { ($0 as? StringMeter)?.double("FontSize", 0) }, 14)
            settle()
            // Editing the control of a #Var# value writes the variable too.
            (editor.inspectorControl(for: "FontSize") as? NumberControl)?.field.type("16")
            t.check(section("Variables").contains("Size=16\n"), "the control writes the variable")
            settle()
            // "Use a Fixed Number Here" writes the value itself.
            t.check(editor.choosePillMenuItem("FontSize", "Use a Fixed Number Here"), "Use a Fixed Number Here")
            t.check(section("VarText").contains("FontSize=16\n"), "literal written: \(section("VarText"))")
            t.check(section("Variables").contains("Size=16\n"), "the variable is left alone")
            settle()

            // Inherited: badge, Override on this layer, then reset to the style's value.
            editor.select(section: "Text")
            t.check(editor.inspectorStack.findSubview { $0.identifier?.rawValue == "look-badge" } != nil, "the look's badge")
            t.check(editor.chooseRowMenuItem("FontSize", "Override"), "Override on This Layer")
            t.check(section("Text").contains("FontSize=20\n"), "written on the layer")
            t.check(section("StyleBig").contains("FontSize=20\n"), "the style keeps its value")
            settle()
            t.check(editor.chooseRowMenuItem("FontSize", "Use StyleBig"), "reset offers the style's value")
            t.check(!section("Text").contains("FontSize"), "own key removed")
            settle()
            // Reset to Default removes a key the layer sets itself.
            t.check(editor.chooseRowMenuItem("Angle", "Reset to Default"), "Reset to Default")
            t.check(!section("Text").contains("Angle="), "Angle removed")
            settle()
            editor.window?.undoManager?.undo()
            t.check(section("Text").contains("Angle=0\n"), "undo puts it back")
            settle()

            // A formula shows its value with a "calculated" tag; "Use a Fixed Number Here" writes the number.
            editor.select(section: "Pic")
            editor.writeProperty(section: "Pic", key: "ImageRotate", value: "(10 * 3)", variable: nil, label: "Rotate")
            settle()
            guard let pill = editor.inspectorStack.findSubview(where: { ($0 as? PillView)?.identifier?.rawValue == "Pic/ImageRotate/pill" })
                    as? PillView else { return t.check(false, "formula tag") }
            t.equal(pill.nameLabel.stringValue, "calculated")
            t.equal((editor.inspectorStack.findSubview { $0.identifier?.rawValue == "Pic/ImageRotate" } as? NSTextField)?.stringValue, "30")
            t.check(editor.choosePillMenuItem("ImageRotate", "Use a Fixed Number Here"), "Use a Fixed Number Here")
            t.check(section("Pic").contains("ImageRotate=30\n"), "number written: \(section("Pic"))")
            settle()

            // Styles: remove a token, add one from the menu.
            editor.select(section: "Text")
            guard let styles = editor.inspectorControl(for: "MeterStyle") as? StyleListControl else { return t.check(false, "styles") }
            styles.onChange?([])
            t.check(!section("Text").contains("MeterStyle"), "removing the last style removes the option")
            settle()
            (editor.inspectorControl(for: "MeterStyle") as? StyleListControl)?.onChange?(["StyleBig"])
            t.check(section("Text").contains("MeterStyle=StyleBig\n"), "added back")
            settle()

            // An image from outside the skin is copied into @Resources and written with #@#.
            editor.select(section: "Pic")
            let outside = t.temporaryDirectory("image").appendingPathComponent("photo.png")
            try FileManager.default.copyItem(at: skin()!.resourcesDirectory.appendingPathComponent("dot.png"), to: outside)
            editor.useImageFile(outside, section: "Pic", key: "ImageName", variable: nil, label: "File")
            t.check(section("Pic").contains("ImageName=#@#Images/photo.png\n"), "written: \(section("Pic"))")
            t.check(FileManager.default.fileExists(atPath: skin()!.resourcesDirectory.appendingPathComponent("Images/photo.png").path),
                    "copied")
            settle()
            t.equal((editor.inspectorControl(for: "ImageName") as? ImageControl)?.popup.selectedItem?.representedObject as? String,
                    "#@#Images/photo.png", "listed and selected after the refresh")
            // A file inside the skin is referred to where it is.
            let inside = skin()!.resourcesDirectory.appendingPathComponent("dot.png")
            t.equal(InspectorWindowController.imageReference(for: inside, skin: skin()!).value, "#@#dot.png")
            t.equal(InspectorWindowController.imageReference(for: inside, skin: skin()!).copy, nil)
            settle()

            // A committed field keeps the inspector's scroll position.
            editor.select(section: "VarText")
            editor.inspectorScroll.layoutSubtreeIfNeeded()
            let document = editor.inspectorScroll.documentView?.frame.height ?? 0
            let visible = editor.inspectorScroll.contentView.bounds.height
            if document > visible + 150 {
                editor.inspectorScroll.contentView.scroll(to: NSPoint(x: 0, y: 150))
                (editor.inspectorControl(for: "Text") as? ValueField)?.type("Hello")
                settle()
                t.check(section("VarText").contains("Text=Hello\n"), "written")
                t.close(Double(editor.inspectorScroll.contentView.bounds.origin.y), 150, accuracy: 1, "scroll position kept")
            }
            editor.window?.close()
        }

        t.suite("App: inspector focus across refreshes") {
            guard let (app, editor, ini) = try makeKindsEditor(t) else { return }
            func text() -> String { (try? String(contentsOf: ini, encoding: .utf8)) ?? "" }
            func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            guard let window = editor.window else { return t.check(false, "window") }
            editor.select(section: "VarText")
            // Typing in a field, then Tab: the value is written, the skin refreshes, and the next field keeps the focus.
            guard let field = editor.inspectorControl(for: "Text") as? ValueField,
                  let next = editor.inspectorStack.findSubview(where: { $0.identifier?.rawValue == "VarText/Prefix" }) as? ValueField
            else { return t.check(false, "fields") }
            t.check(window.makeFirstResponder(field), "field focused")
            field.currentEditor()?.string = "Typed"
            t.check(window.makeFirstResponder(next), "Tab to the next field")
            settle()
            t.check(text().contains("Text=Typed\n"), "written when editing ended")
            let focused = editor.focusedInspectorIdentifier()
            t.equal(focused, "VarText/Prefix", "the focus is back on the same option's field after the rebuild")
            t.check(editor.inspectorStack.findSubview(where: { $0 === next }) == nil, "(the inspector was rebuilt)")

            // While a field is being edited, live ticks do not rebuild the inspector, even when an option changes.
            guard let editing = editor.inspectorStack.findSubview(where: { $0.identifier?.rawValue == "VarText/Prefix" }) as? ValueField
            else { return t.check(false, "prefix field") }
            window.makeFirstResponder(editing)
            app.controller(for: "Studio\\Kinds")?.skin.execute("[!SetOption VarText Postfix \"!\"]", from: nil)
            editor.refreshLiveValues()
            t.check(editor.inspectorStack.findSubview(where: { $0 === editing }) != nil, "not rebuilt while typing")
            window.makeFirstResponder(nil)
            editor.window?.close()
        }

        t.suite("App: Shape editor") {
            guard let (app, editor, ini) = try makeKindsEditor(t) else { return }
            func text() -> String { (try? String(contentsOf: ini, encoding: .utf8)) ?? "" }
            func value(_ section: String, _ key: String) -> String? {
                app.controller(for: "Studio\\Kinds")?.skin.document.section(named: section)?.value(forKey: key)
            }
            func skin() -> Skin? { app.controller(for: "Studio\\Kinds")?.skin }
            func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            func find(_ id: String) -> NSView? { editor.inspectorStack.findSubview { $0.identifier?.rawValue == id } }

            // The whole Shape editor (with Rainmeter Details; without, More Shape Options leaves out what the card shows).
            app.state.updateEditor { $0.showIniNames = true }
            editor.select(section: "Shapes")
            guard let view = editor.inspectorControl(for: "Shape") as? ShapeEditorView else { return t.check(false, "Shape editor") }
            t.equal(view.items.map(\.key), ["Shape", "Shape2", "Shape3"])
            t.equal(view.items.map(ShapeEditorView.summary),
                    ["Rounded rectangle 40 × 20", "Circle ⌀ 10", "2 shapes joined"])
            t.equal(view.selectedKey, "Shape", "the first shape is expanded")

            // Geometry fields write the parameter, keeping the rest as written.
            (find("Shapes/Shape/Size/W") as? NumberField)?.type("60")
            t.equal(value("Shapes", "Shape"), "Rectangle 0,0,60,20,4 | Fill Color 255,0,0,255 | StrokeWidth 2", "width")
            settle()
            (find("shape-radius-link") as? NSButton)?.performClick(nil)
            t.equal(value("Shapes", "Shape"), "Rectangle 0,0,60,20,4,4 | Fill Color 255,0,0,255 | StrokeWidth 2",
                    "unlinking the corner radius writes its vertical radius")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            editor.window?.undoManager?.undo()
            settle()
            t.equal(value("Shapes", "Shape"), "Rectangle 0,0,40,20,4 | Fill Color 255,0,0,255 | StrokeWidth 2", "undone")

            // Changing the type converts the geometry and keeps the modifiers; the engine draws it.
            guard let type = find("shape-type") as? NSPopUpButton else { return t.check(false, "type menu") }
            type.selectItem(at: ShapeSpec.Kind.allCases.firstIndex(of: .ellipse) ?? 1)
            type.sendAction(type.action, to: type.target)
            let ellipse = value("Shapes", "Shape") ?? ""
            t.equal(ellipse, "Ellipse 20,10,20,10 | Fill Color 255,0,0,255 | StrokeWidth 2", "converted")
            t.equal(ShapeSpec.parse(ellipse)?.problem, nil)
            t.equal(skin()?.issues.filter { $0.contains("Shapes") }, [], "no issue")
            t.close(skin()?.meter(named: "Shapes")?.frame.width ?? 0, 42, accuracy: 1.01, "drawn: the ellipse (and its stroke) sizes the meter")
            settle()

            // Stroke off writes StrokeWidth 0.
            (find("shape-stroke") as? NSButton).map { box in
                box.state = .off
                box.sendAction(box.action, to: box.target)
            }
            t.check(value("Shapes", "Shape")?.contains("StrokeWidth 0") == true, "stroke off: \(value("Shapes", "Shape") ?? "")")
            settle()

            // Fill color writes Fill Color.
            guard let swatch = find("shape-fill-color") as? SwatchButton else { return t.check(false, "fill swatch") }
            ShapeColorPicker.shared.pick(RGBA(r: 0, g: 0, b: 255, a: 255), for: swatch)
            t.check(value("Shapes", "Shape")?.contains("Fill Color 0,0,255,255") == true, "fill color: \(value("Shapes", "Shape") ?? "")")
            settle()

            // A linear gradient creates its named option next to the shape.
            editor.setShapeFillMode(.linear, key: "Shape", meter: "Shapes")
            t.check(value("Shapes", "Shape")?.contains("Fill LinearGradient ShapeFill") == true, "gradient fill")
            t.equal(value("Shapes", "ShapeFill"), "270 | 0,0,255,255 ; 0.0 | 0,0,0,255 ; 1.0", "gradient option")
            settle()
            editor.window?.undoManager?.undo()
            settle()

            // Reordering renumbers and rewrites the Combine references, as one undo step.
            let before = text()
            editor.inspectorState.expandedShapes["shapes"] = "Shape2"
            editor.rebuildInspector()
            if let up = find("shape-up") as? NSButton { up.sendAction(up.action, to: up.target) }
            t.equal(value("Shapes", "Shape"), "Ellipse 20,10,5", "moved back")
            t.equal(value("Shapes", "Shape2"), "Ellipse 20,10,20,10 | Fill Color 0,0,255,255 | StrokeWidth 0")
            t.equal(value("Shapes", "Shape3"), "Combine Shape2 | Union Shape", "Combine follows")
            t.equal(editor.inspectorState.expandedShapes["shapes"], "Shape", "the moved shape stays selected")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(text(), before, "one undo step")
            settle()

            // Add and remove.
            editor.addShape(.rectangle, meter: "Shapes")
            t.check(value("Shapes", "Shape4")?.hasPrefix("Rectangle 0,0,") == true, "added: \(value("Shapes", "Shape4") ?? "")")
            t.equal(editor.inspectorState.expandedShapes["shapes"], "Shape4", "and selected")
            settle()
            editor.removeShape("Shape", meter: "Shapes")
            t.equal(value("Shapes", "Shape4"), nil, "the last key is gone")
            t.equal(value("Shapes", "Shape"), "Ellipse 20,10,5", "the others moved up")
            t.equal(value("Shapes", "Shape2"), "Combine Shape", "the step with the removed shape is dropped, the parent follows")
            t.check(value("Shapes", "Shape3")?.hasPrefix("Rectangle 0,0,") == true, "the added one is Shape3 now")
            settle()

            // A type word that is not a type (the classic example): the Type menu shows it — first, selected, disabled —
            // with a warning, and the rest of the shape as usual; choosing a type replaces only the word.
            editor.select(section: "BadShape")
            t.check(find("shape-unreadable") == nil, "not the can't-show view")
            guard let badType = find("shape-type") as? NSPopUpButton else { return t.check(false, "a Type menu for aaaa") }
            t.equal(badType.selectedItem?.title, "“aaaa”", "the written word, selected")
            t.equal(badType.selectedItem?.isEnabled, false, "and disabled")
            t.equal(badType.itemArray.compactMap { $0.representedObject as? String }, ShapeSpec.Kind.allCases.map(\.rawValue),
                    "then every valid type")
            let warnings = editor.inspectorStack.subviewsMatching { $0.identifier?.rawValue == "issue" }.map { $0.accessibilityLabel() ?? "" }
            t.check(warnings.contains { $0.contains("“aaaa” is not a shape type") }, "warning: \(warnings)")
            t.equal((find("BadShape/Shape/Parameters") as? ValueField)?.stringValue, "0,0,10,10", "the parameters as written")
            t.check(find("shape-fill") is NSPopUpButton && find("shape-stroke") is NSButton, "fill and stroke as for any shape")
            t.equal(editor.shapeItem("Shape", of: "BadShape").map(ShapeEditorView.summary), "“aaaa” is not a type",
                    "the list says so")
            t.equal(value("BadShape", "Shape"), "aaaa 0,0,10,10", "kept as written until a type is chosen")
            if let rectangle = badType.itemArray.firstIndex(where: { ($0.representedObject as? String) == "rectangle" }) {
                badType.selectItem(at: rectangle)
                badType.sendAction(badType.action, to: badType.target)
            }
            t.equal(value("BadShape", "Shape"), "Rectangle 0,0,10,10", "the typo fixed, the parameters kept")
            t.check((skin()?.meter(named: "BadShape")?.frame.width ?? 0) >= 10, "and the engine draws it (with its outline)")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(value("BadShape", "Shape"), "aaaa 0,0,10,10", "one undo step")
            settle()
            // Text that is not even a word still shows the can't-show view, with a way to the code.
            editor.inspectorState.expandedShapes["badshape"] = "Shape2"
            editor.rebuildInspector()
            t.check(find("shape-unreadable") != nil, "can't show message")
            t.check(find("shape-show-in-code") != nil, "Show in Code")
            t.equal(value("BadShape", "Shape2"), "(12) 34", "kept as written")

            // MeterBackground of Deskset\System: its shapes come from StylePanel, and edits go there.
            guard let c = app.activate(config: "Deskset\\System", file: nil) else { return t.check(false, "System") }
            app.showInspector(for: c)
            guard let system = app.inspector else { return t.check(false, "editor") }
            system.select(section: "MeterBackground")
            guard let panel = system.inspectorControl(for: "Shape") as? ShapeEditorView else { return t.check(false, "shapes") }
            t.equal(panel.items.count, 2)
            t.check(ShapeEditorView.summary(panel.items[0]).hasPrefix("Rounded rectangle"), ShapeEditorView.summary(panel.items[0]))
            t.check(system.inspectorStack.findSubview { $0.identifier?.rawValue == "origin-badge" } != nil, "from StylePanel")
            system.setShapeStroke(false, key: "Shape2", meter: "MeterBackground")
            let styles = c.skin.resourcesDirectory.appendingPathComponent("Styles.inc")
            let written = (try? String(contentsOf: styles, encoding: .utf8)) ?? ""
            // StylePanel is shared with the other widgets: this widget's panel changes (docs/editor-friendly.md §7.5).
            let own = (try? String(contentsOf: c.skin.fileURL, encoding: .utf8)) ?? ""
            t.check(own.contains("Shape2=Line (#PanelRadius#),1.5,(#PanelWidth# - #PanelRadius#),1.5 | StrokeWidth 0 | Stroke Color #PanelHighlight#"),
                    "written for this widget, formulas kept")
            t.check(!written.contains("StrokeWidth 0 | Stroke Color #PanelHighlight#"), "the shared look is left alone")
            system.window?.close()
        }

        t.suite("App: Shape editor color panel and focus") {
            guard let (app, editor, ini) = try makeKindsEditor(t) else { return }
            func text() -> String { (try? String(contentsOf: ini, encoding: .utf8)) ?? "" }
            func value(_ section: String, _ key: String) -> String? {
                app.controller(for: "Studio\\Kinds")?.skin.document.section(named: section)?.value(forKey: key)
            }
            func settle(_ seconds: Double = 0.02) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
            func find(_ id: String) -> NSView? { editor.inspectorStack.findSubview { $0.identifier?.rawValue == id } }
            let picker = ShapeColorPicker.shared
            guard let window = editor.window else { return t.check(false, "window") }

            // A shape color is being picked when an inspector swatch takes the panel: closing the panel writes the
            // inspector's color to its option, and the shape keeps the color picked for it. (The whole Shape editor,
            // with Rainmeter Details.)
            app.state.updateEditor { $0.showIniNames = true }
            editor.select(section: "Shapes")
            guard let fill = find("shape-fill-color") as? SwatchButton else { return t.check(false, "fill swatch") }
            t.check(picker.activate(fill), "the shape's swatch takes the panel")
            t.equal(picker.activeIdentity, "shapes/shape/shape-fill-color")
            picker.pickColor(RGBA(r: 0, g: 255, b: 0, a: 255))
            t.check(editor.isPreviewingProperty, "previewed, not written yet")
            editor.revealedGroups.insert("Shapes/Box Behind It")  // Box Behind It (nothing set yet), shown
            editor.rebuildInspector()
            t.equal(picker.activeIdentity, "shapes/shape/shape-fill-color", "a rebuild showing the color keeps the pick")
            guard let solid = editor.inspectorControl(for: "SolidColor") as? SwatchButton else { return t.check(false, "SolidColor swatch") }
            // An inspector swatch opens its color menu; its Custom Color… takes the panel from the shape picker.
            t.check(solid.target is ColorControl && solid.action == #selector(ColorControl.openMenu(_:)),
                    "inspector swatches open their color menu")
            picker.relinquish()  // what inspectorSwatchClicked does before opening the panel for itself
            editor.beginColorEdit(section: "Shapes", key: "SolidColor", raw: "", variable: nil)
            editor.pickColor(RGBA(r: 10, g: 20, b: 30, a: 255))
            picker.panelClosed()
            editor.colorPanelClosed()
            // The shape's preview is written by its own timer (fired here: waiting on the clock is what made this
            // suite fail on a busy machine).
            t.check(editor.inspectorState.previewTimer?.isValid == true, "the shape's preview waits for its timer")
            editor.inspectorState.previewTimer?.fire()
            t.equal(value("Shapes", "SolidColor"), "10,20,30", "the inspector's color")
            t.check(value("Shapes", "Shape")?.contains("Fill Color 0,255,0,255") == true,
                    "the shape keeps its own color: \(value("Shapes", "Shape") ?? "")")
            t.check(value("Shapes", "Shape")?.contains("10,20,30") == false, "the inspector's color is not written into the shape")
            t.equal(picker.activeIdentity, nil)

            // Opening the panel and closing it without picking writes nothing (and no undo step).
            editor.select(section: "Shapes")
            let untouched = text()
            let undoName = window.undoManager?.undoActionName
            if let swatch = find("shape-fill-color") as? SwatchButton { picker.activate(swatch) }
            picker.panelClosed()
            settle()
            t.equal(text(), untouched, "nothing written")
            t.equal(window.undoManager?.undoActionName, undoName, "no undo step")

            // The picked color follows the rebuilt swatch after each write; selecting another layer ends the pick, and
            // edits always go to the meter they were made for.
            if let swatch = find("shape-fill-color") as? SwatchButton { picker.activate(swatch) }
            picker.pickColor(RGBA(r: 0, g: 0, b: 255, a: 255))
            editor.commitPendingPreview()
            t.check(value("Shapes", "Shape")?.contains("Fill Color 0,0,255,255") == true, "written")
            t.equal(picker.activeIdentity, "shapes/shape/shape-fill-color", "the rebuilt swatch keeps the pick")
            picker.pickColor(RGBA(r: 0, g: 128, b: 255, a: 255))
            editor.commitPendingPreview()
            t.check(value("Shapes", "Shape")?.contains("Fill Color 0,128,255,255") == true, "picked again after the rebuild")
            let shapes = value("Shapes", "Shape")
            editor.select(section: "BadShape")
            t.equal(picker.activeIdentity, nil, "another layer: the pick ended")
            picker.pickColor(RGBA(r: 255, g: 255, b: 0, a: 255))
            settle()
            t.equal(value("Shapes", "Shape"), shapes, "the panel no longer changes the first meter")
            t.equal(value("BadShape", "Shape"), "aaaa 0,0,10,10", "nor the selected one")
            t.check(editor.shapeItem("Shape", of: "Shapes")?.spec?.kind == .rectangle, "shapes read from their own meter")
            editor.setShapeStroke(false, key: "Shape", meter: "Shapes")
            t.check(value("Shapes", "Shape")?.hasPrefix("Rectangle 0,0,40,20,4 | Fill Color 0,128,255,255") == true,
                    "an edit for another meter writes that meter's shape: \(value("Shapes", "Shape") ?? "")")
            t.equal(value("BadShape", "Shape"), "aaaa 0,0,10,10")
            settle()

            // Every field of the expanded shape has its own identifier (captions repeat between rows).
            editor.select(section: "Shapes")
            for kind in [ShapeSpec.Kind.line, .curve, .arc, .ellipse, .rectangle] {
                editor.setShapeKind(kind, key: "Shape", meter: "Shapes")
                settle()
                editor.inspectorState.disclosures.insert("shapes/shape/transform")
                editor.rebuildKeepingScroll()
                let ids = editor.inspectorStack.subviewsMatching { $0 is NSTextField && ($0 as? NSTextField)?.isEditable == true }
                    .compactMap { $0.identifier?.rawValue }
                t.equal(ids.count, Set(ids).count, "\(kind.title): no identifier twice (\(ids.sorted()))")
            }
            t.check(find("Shapes/Shape/Rotate/degrees") is NumberField, "the rotation field has an identifier")

            // Changing Start Y, then Tab to End X: after the rebuild the focus is on End X, not on Start X.
            editor.setShapeKind(.line, key: "Shape", meter: "Shapes")
            settle()
            guard let startY = find("Shapes/Shape/Start/Y") as? NumberField, let endX = find("Shapes/Shape/End/X") as? NumberField
            else { return t.check(false, "line fields") }
            t.check(window.makeFirstResponder(startY), "Start Y focused")
            startY.currentEditor()?.string = "7"
            t.check(window.makeFirstResponder(endX), "Tab to End X")
            settle(0.05)
            t.check(value("Shapes", "Shape")?.hasPrefix("Line 0,7,") == true, "Start Y written: \(value("Shapes", "Shape") ?? "")")
            t.check(editor.inspectorStack.findSubview(where: { $0 === endX }) == nil, "(the inspector was rebuilt)")
            t.equal(editor.focusedInspectorIdentifier(), "Shapes/Shape/End/X", "the focus is back on End X")
            window.makeFirstResponder(nil)
            editor.window?.close()
        }

        t.suite("App: inspector width does not follow the selection") {
            guard let app = try makeApp(t), let c = app.activate(config: "Deskset\\System", file: nil) else { return }
            app.showInspector(for: c)
            guard let editor = app.inspector, let content = editor.window?.contentView else { return t.check(false, "editor") }
            func widths() -> (stack: CGFloat, pane: CGFloat) {
                content.layoutSubtreeIfNeeded()
                return (editor.inspectorStack.bounds.width, editor.inspectorScroll.superview?.frame.width ?? 0)
            }
            editor.canvasSelectionChanged([])
            let start = widths()
            t.check(start.stack > 0, "laid out")
            // A String (the alignment control), a Bar, the Shape editor, the skin, a data source, and back.
            for name in ["MeterCPUValue", "MeterRAMBar", "MeterBackground", "none", "MeasureCPU", "MeterTitle", "MeterCPUValue"] {
                if name == "none" { editor.canvasSelectionChanged([]) } else { editor.select(section: name) }
                let w = widths()
                t.close(w.stack, start.stack, accuracy: 0.5, "inspector column width with \(name)")
                t.close(w.pane, start.pane, accuracy: 0.5, "inspector pane width with \(name)")
                t.close(editor.inspectorControlWidth, EditorStyle.inspectorControlWidth(scrollerStyle: editor.inspectorScroll.scrollerStyle), accuracy: 0.5, "control column with \(name)")
            }
            // The alignment control fits the control column of the narrowest inspector.
            editor.select(section: "MeterCPUValue")
            content.layoutSubtreeIfNeeded()
            if let align = editor.inspectorControl(for: "StringAlign") {
                t.check(align.fittingSize.width <= EditorStyle.minimumControlWidth,
                        "the alignment control fits the narrowest column (\(align.fittingSize.width) of \(EditorStyle.minimumControlWidth))")
            } else {
                t.check(false, "alignment control")
            }
            // No control of any card needs more than the narrowest control column (spanning rows: both columns):
            // what can shrink (titles, text) may; what cannot (fixed-width fields, segments, spacing) must fit.
            func hardMinimumWidth(_ view: NSView) -> CGFloat {
                var saved: [(NSView, NSLayoutConstraint.Priority)] = []
                func soften(_ v: NSView) {
                    let p = v.contentCompressionResistancePriority(for: .horizontal)
                    if p < .required {
                        saved.append((v, p))
                        v.setContentCompressionResistancePriority(.init(49), for: .horizontal)
                    }
                    v.subviews.forEach(soften)
                }
                soften(view)
                defer { for (v, p) in saved { v.setContentCompressionResistancePriority(p, for: .horizontal) } }
                return view.fittingSize.width
            }
            func checkControlsFit(_ editor: InspectorWindowController, _ name: String) {
                editor.window?.contentView?.layoutSubtreeIfNeeded()
                let narrow = EditorStyle.minimumControlWidth
                for case let grid as NSGridView in editor.inspectorStack.subviewsMatching({ $0 is NSGridView }) {
                    for i in 0..<grid.numberOfRows {
                        let row = grid.row(at: i)
                        let merged = row.cell(at: 0).contentView === row.cell(at: 1).contentView || row.cell(at: 1).contentView == nil
                        guard let view = merged ? row.cell(at: 0).contentView : row.cell(at: 1).contentView,
                              view.superview != nil else { continue }
                        let limit = merged ? narrow + EditorStyle.labelColumnWidth + grid.columnSpacing : narrow
                        let width = hardMinimumWidth(view)
                        let what = view.identifier?.rawValue ?? view.subviewsMatching { $0.identifier != nil }.first?.identifier?.rawValue
                            ?? String(describing: type(of: view))
                        t.check(width <= limit + 0.5, "\(name): \(what) is \(width) wide, the column \(limit)")
                    }
                }
            }
            for name in ["none", "MeterCPUValue", "MeterRAMBar", "MeterBackground", "MeasureCPU", "MeterTitle", "MeterCPUFill"] {
                if name == "none" { editor.canvasSelectionChanged([]) } else { editor.select(section: name) }
                checkControlsFit(editor, name)
            }
            editor.inspectorState.disclosures = ["meterbackground/shape/transform", "meterbackground/shape/caps"]
            editor.select(section: "MeterBackground")
            editor.rebuildInspector()
            checkControlsFit(editor, "MeterBackground (open)")
            editor.window?.close()
            if let (_, kinds, _) = try makeKindsEditor(t) {
                for name in ["Text", "VarText", "Bar", "Pic", "Shapes", "BadShape", "MeasureTime", "MeasureCalc", "StyleBig"] {
                    kinds.select(section: name)
                    checkControlsFit(kinds, name)
                }
                for shape in ["Shape2", "Shape3"] {
                    kinds.inspectorState.expandedShapes["shapes"] = shape
                    kinds.select(section: "Shapes")
                    kinds.rebuildInspector()
                    checkControlsFit(kinds, "Shapes/\(shape)")
                }
                kinds.window?.close()
            }
        }

        inspectorSnapshotSuite(t)
    }

    /// DESKSET_INSPECTOR_SNAPSHOTS=<folder>: writes the whole inspector column (light and dark) for a few selections.
    static func inspectorSnapshotSuite(_ t: AppTestRunner) {
        guard let folder = ProcessInfo.processInfo.environment["DESKSET_INSPECTOR_SNAPSHOTS"] else { return }
        t.suite("App: inspector snapshots") {
            guard let app = try makeApp(t), let c = app.activate(config: "Deskset\\System", file: nil) else { return }
            app.showInspector(for: c)
            guard let editor = app.inspector else { return }
            let out = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if let (_, kinds, _) = try makeKindsEditor(t) {
                for dark in [false, true] {
                    kinds.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    for name in ["Bar", "Text"] {
                        kinds.select(section: name)
                        kinds.rebuildInspector()
                        if let png = kinds.inspectorDocumentSnapshot()?.representation(using: .png, properties: [:]) {
                            try png.write(to: out.appendingPathComponent("Kinds-\(name)\(dark ? "-dark" : "").png"))
                        }
                    }
                }
                kinds.window?.close()
            }
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for dark in [false, true] {
                editor.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for name in ["none", "MeterCPUValue", "MeterRAMBar", "MeterBackground", "MeterCPUFill", "MeasureCPU", "MeasureSwapTotal", "MeterTitle"] {
                    if name == "none" { editor.canvasSelectionChanged([]) } else { editor.select(section: name) }
                    editor.advancedOpen = name == "MeterTitle"
                    editor.inspectorState.disclosures = name == "MeterBackground" ? ["meterbackground/shape/transform", "meterbackground/shape/caps"] : []
                    editor.rebuildInspector()
                    guard let rep = editor.inspectorDocumentSnapshot(), let image = rep.cgImage else { continue }
                    // In parts of at most 1600 pixels, so each can be looked at.
                    var y = 0, part = 0
                    while y < image.height {
                        let h = min(1600, image.height - y)
                        if let piece = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: h)),
                           let png = NSBitmapImageRep(cgImage: piece).representation(using: .png, properties: [:]) {
                            try png.write(to: out.appendingPathComponent("\(name)\(dark ? "-dark" : "")-\(part).png"))
                        }
                        y += h
                        part += 1
                    }
                }
            }
            editor.window?.close()
        }
    }
}
