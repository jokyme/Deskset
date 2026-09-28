import AppKit
import DesksetCore

/// The new Studio's sidebar (Layers for an INI widget, its data group, finding a layer, selecting with the canvas),
/// the steps made from it (order, hide and show, add, delete: each one named step, undone byte for byte), Rainmeter
/// details (⌥⌘R, remembered; on by itself for the first Rainmeter skin), the compatibility capsule, the canvas's
/// accessibility and the keyboard's route between the panes.
enum Studio2SidebarSelfTests {
    static func run(_ t: AppTestRunner) {
        layersTests(t)
        stepTests(t)
        detailsTests(t)
        accessibilityTests(t)
        focusTests(t)
        Studio2AddSelfTests.run(t)
    }

    static func open(_ t: AppTestRunner, _ name: String) -> StudioSnapshot.Opened? {
        Studio2PageSelfTests.open(t, name)
    }

    static let ini = """
        [Rainmeter]
        Update=1000

        [Variables]
        Color=255,0,0

        [MeasureCPU]
        Measure=CPU

        [MeterBack]
        Meter=Shape
        Shape=Rectangle 0,0,200,120,8 | Fill Color 30,30,30 | StrokeWidth 0

        [MeterTitle]
        Meter=String
        Text=Hello
        FontSize=12
        FontColor=#Color#
        X=10
        Y=10

        [MeterValue]
        Meter=String
        MeasureName=MeasureCPU
        Text=%1%
        FontSize=14
        X=0R
        Y=0r

        [MeterBar]
        Meter=Bar
        MeasureName=MeasureCPU
        BarColor=0,200,255
        X=10
        Y=60
        W=100
        H=6

        """

    // MARK: Layers

    static func layersTests(_ t: AppTestRunner) {
        t.suite("Studio2: sidebar: the Layers list of an INI widget") {
            Studio2SelfTests.prepare(t)
            guard let opened = open(t, "13b-compat") else { return }
            defer { opened.close() }
            let studio = opened.controller
            let layers = studio.sidebarController.layersView
            t.check(!studio.sidebarItem.isCollapsed, "Build: the sidebar is open")
            t.equal(studio.sidebarController.page, .layers)
            t.equal(studio.sidebarController.tabs.label(forSegment: 0), "Add")
            t.equal(studio.sidebarController.tabs.label(forSegment: 1), "Layers")
            t.equal(studio.sidebarController.tabs.selectedSegmentBezelColor, .controlAccentColor,
                    "the chosen page in the accent color")
            guard let lists = layers.lists, let skin = studio.skin else { return t.check(false, "the lists") }
            t.equal(lists.widget.title, "Nocturne")
            t.equal(lists.widget.word, "free layout", "never “free” alone")
            t.equal(lists.parts.map(\.name), skin.meters.map(\.name), "every part, in file order")
            func part(_ name: String) -> StudioLayerItem? { lists.parts.first { $0.name == name } }
            t.equal(part("MeterTitle")?.title, "“NOCTURNE”", "static text by its words")
            t.equal(part("MeterCPU")?.title, "CPU usage", "live data by its data")
            t.equal(part("MeterCPU")?.chip?.text, "23%")
            t.equal(part("MeterCPUBar")?.title, "CPU bar")
            t.equal(part("MeterCPUBar")?.chip?.text, "23%")
            t.equal(part("MeterCPU")?.subtitle, "MeterCPU", "Rainmeter details: the meter's name under it")
            t.check(part("MeterCPUTemp")?.issue?.contains("HWiNFO") == true, "an amber dot: HWiNFO only runs on Windows")
            t.equal(part("MeterCPUTemp")?.chip?.text, nil, "no value it cannot read")
            t.check(part("MeterSteam")?.issue?.contains("steam") == true, "an amber dot: it opens a Windows program")
            t.equal(part("MeterSteam")?.glyph, "button.horizontal")
            t.equal(part("MeterCPU")?.issue, nil)
            t.equal(layers.dataHeader.stringValue, "Measures")
            t.equal(lists.data.map(\.name), skin.measures.map(\.name), "every data item")
            let cpu = lists.data.first { $0.name == "MeasureCPU" }
            t.equal(cpu?.title, "MeasureCPU")
            t.equal(cpu?.subtitle, "CPU usage")
            t.equal(cpu?.value, "23%")
            t.check(lists.data.first { $0.name == "MeasureCPUTemp" }?.subtitle?.hasSuffix("· HWiNFO") == true)
            t.equal(lists.data.first { $0.name == "MeasureGPU" }?.subtitle, "GPU usage",
                    "a formula named after the data it is built from")
            // The hint of the first Rainmeter skin.
            t.equal(studio.sidebarController.hint.text, "Rainmeter names on · ⌥⌘R to hide")
            t.check(!studio.sidebarController.hint.isHidden)
            // The rows as drawn.
            t.check(layers.partsOutline.numberOfRows == lists.parts.count + 1, "the widget's row and its parts")
            t.check(layers.dataOutline.numberOfRows == lists.data.count)
            t.check(layers.partsScroll.frame.height > 100 && layers.dataScroll.frame.height > 100,
                    "both lists have room: \(layers.partsScroll.frame.height), \(layers.dataScroll.frame.height)")
            // Rainmeter details off: plain names, "Data".
            studio.toggleRainmeterDetails(nil)
            guard let plain = layers.lists else { return }
            t.equal(layers.dataHeader.stringValue, "Data")
            t.equal(plain.parts.first { $0.name == "MeterCPU" }?.subtitle, nil)
            t.equal(plain.data.first { $0.name == "MeasureCPU" }?.title, "CPU usage")
            t.equal(plain.data.first { $0.name == "MeasureCPU" }?.subtitle, nil)
            t.check(studio.sidebarController.hint.isHidden, "the hint goes")
        }

        t.suite("Studio2: sidebar: finding a layer") {
            Studio2SelfTests.prepare(t)
            guard let opened = open(t, "13b-compat") else { return }
            defer { opened.close() }
            let layers = opened.controller.sidebarController.layersView
            t.equal(layers.searchField.placeholderString, "Find a layer")
            layers.setFilter("cpu")
            let parts = layers.lists?.parts ?? []
            t.check(!parts.isEmpty && parts.allSatisfy { ($0.title + $0.name).lowercased().contains("cpu") },
                    "every row found says CPU: \(parts.map(\.name))")
            t.check(layers.lists?.data.contains { $0.name == "MeasureCPU" } == true, "data too")
            layers.setFilter("MeterSteam")
            t.equal(layers.lists?.parts.map(\.name), ["MeterSteamFrame", "MeterSteam"], "by the meter's name")
            layers.setFilter("zzzz")
            t.equal(layers.lists?.parts.count, 0)
            t.check(!layers.emptyLabel.isHidden)
            t.equal(layers.emptyLabel.stringValue, "Nothing matches “zzzz”")
            layers.setFilter("")
            t.equal(layers.lists?.parts.count, opened.controller.skin?.meters.count)
            t.check(layers.emptyLabel.isHidden)
        }

        t.suite("Studio2: sidebar: selecting with the canvas") {
            Studio2SelfTests.prepare(t)
            guard let opened = open(t, "13b-compat") else { return }
            defer { opened.close() }
            let studio = opened.controller
            let layers = studio.sidebarController.layersView
            layers.setHoveredData(nil)
            // A row: the canvas selects the part and the inspector shows its page.
            layers.onEvent?(.selectPart("MeterCPUBar"))
            t.equal(studio.canvasController.canvas.selectedNames, ["MeterCPUBar"])
            t.equal(studio.partPage.focus, .part("MeterCPUBar"))
            t.equal(studio.partPage.page?.title, "CPU bar", "the same name as the list's")
            // The canvas: the row follows.
            studio.select(part: "MeterRAM")
            t.equal(layers.selectedPartNames, ["MeterRAM"])
            // A data row: its page, and its users outlined on the canvas and in the list.
            layers.select(data: "MeasureCPU", notify: true)
            t.equal(studio.partPage.focus, .data("MeasureCPU"))
            t.equal(studio.canvasController.canvas.selectedNames, [])
            t.equal(Set(studio.canvasController.overlay.frames?.names ?? []), ["MeterCPU", "MeterCPUBar"])
            t.equal(studio.canvasController.overlay.frames?.tag, "MeasureCPU · used by 2 parts")
            t.equal(layers.outlinedParts, ["metercpu", "metercpubar"])
            // Pointing at another data row outlines its users; leaving it, the selected one's again.
            layers.setHoveredData("MeasureRAM")
            t.equal(studio.canvasController.overlay.frames?.names, ["MeterRAM", "MeterRAMBar"])
            layers.setHoveredData(nil)
            t.equal(studio.canvasController.overlay.frames?.tag, "MeasureCPU · used by 2 parts")
            // A part again: the outlines go.
            layers.onEvent?(.selectPart("MeterTitle"))
            t.equal(layers.outlinedParts, [])
            // The widget's row: the widget page.
            layers.onEvent?(.selectPart(nil))
            t.equal(studio.partPage.focus, nil)
            t.equal(studio.canvasController.canvas.selectedNames, [])
            t.equal(layers.partsOutline.selectedRow, 0, "the widget's row is selected")
        }
    }

    // MARK: Steps

    static func stepTests(_ t: AppTestRunner) {
        t.suite("Studio2: sidebar: order, hide, add and delete are named steps undone byte for byte") {
            Studio2SelfTests.prepare(t)
            guard let (app, c, url) = try Studio2SelfTests.loadSkin(t, "Layers", ini),
                  let studio = Studio2SelfTests.openNew(app, c) else { return }
            studio.showSidebarPage(.layers)
            let undo = studio.session!.undoStack
            let original = Studio2PageSelfTests.data(url)
            let layers = studio.sidebarController.layersView
            func names() -> [String] { studio.skin?.meters.map(\.name) ?? [] }
            t.equal(layers.lists?.parts.map(\.name), ["MeterBack", "MeterTitle", "MeterValue", "MeterBar"])

            // Order: a drag in the list puts the bar behind the title.
            let valueFrame = studio.skin?.meter(named: "MeterValue")?.frame
            t.check(layers.drop(["MeterBar"], at: 1), "the drop is taken")
            t.equal(names(), ["MeterBack", "MeterBar", "MeterTitle", "MeterValue"])
            t.equal(undo.undoActionName, "Change Order")
            t.equal(studio.toolbar.state.canUndo, true)
            // The title moves away from in front of the value: the value, placed relative to it, keeps its place.
            layers.drop(["MeterTitle"], at: 4)
            t.equal(names(), ["MeterBack", "MeterBar", "MeterValue", "MeterTitle"])
            t.equal(studio.skin?.meter(named: "MeterValue")?.frame, valueFrame, "nothing moved on the canvas")
            undo.undo()
            undo.undo()
            t.equal(Studio2PageSelfTests.data(url), original, "undone: the file's bytes as they were")
            t.check(!layers.drop(["MeterBar"], at: 4), "where it is: nothing to do")

            // Bring Forward and Send Backward.
            t.check(studio.bringForward("MeterBack"))
            t.equal(undo.undoActionName, "Bring Forward")
            t.equal(names().first, "MeterTitle")
            t.check(studio.sendBackward("MeterBack"))
            t.equal(undo.undoActionName, "Send Backward")
            undo.undo()
            undo.undo()
            t.equal(Studio2PageSelfTests.data(url), original)

            // Hide with the eye, then show it again: the file as it was.
            layers.onEvent?(.toggleHidden("MeterTitle"))
            t.equal(studio.skin?.meter(named: "MeterTitle")?.hidden, true)
            t.equal(undo.undoActionName, "Hide")
            t.check(layers.lists?.parts.first { $0.name == "MeterTitle" }?.hidden == true, "the row says so")
            layers.onEvent?(.toggleHidden("MeterTitle"))
            t.equal(studio.skin?.meter(named: "MeterTitle")?.hidden, false)
            t.equal(undo.undoActionName, "Show")
            t.equal(Studio2PageSelfTests.data(url), original, "shown again: its own Hidden=1 went")
            undo.undo()
            undo.undo()
            t.equal(Studio2PageSelfTests.data(url), original)

            // Lock: the Studio's own, not a step.
            layers.onEvent?(.toggleLock("MeterBar"))
            t.check(studio.lockedParts.contains("meterbar"))
            t.check(studio.canvasController.canvas.isLocked("MeterBar"), "the canvas does not drag it")
            t.equal(undo.undoActionName, "")
            t.equal(Studio2PageSelfTests.data(url), original, "nothing written")
            layers.onEvent?(.toggleLock("MeterBar"))
            t.check(!studio.lockedParts.contains("meterbar"))

            // Add after the selection: after the value, which is placed relative to the title before it.
            studio.select(part: "MeterTitle")
            let sections = EditorComponents.sections(for: "text", x: 10, y: 90, existing: studio.skin!.sectionNames,
                                                     variables: studio.skin!.variableNames)
            t.check(studio.insert(sections, title: "Text"))
            t.equal(undo.undoActionName, "Add Text")
            t.equal(names(), ["MeterBack", "MeterTitle", "MeterValue", "MeterText", "MeterBar"],
                    "after the selection and the part placed relative to it")
            t.equal(studio.canvasController.canvas.selectedNames, ["MeterText"], "the new part is selected")
            undo.undo()
            t.equal(Studio2PageSelfTests.data(url), original)

            // Delete (the key in the list).
            layers.onEvent?(.delete("MeterBar"))
            t.equal(names(), ["MeterBack", "MeterTitle", "MeterValue"])
            t.equal(undo.undoActionName, "Delete")
            studio.setSidebarOpen(false)
            t.equal(studio.toolbar.undoButton.title, "Undo Delete", "Customize: the Undo button names it")
            undo.undo()
            t.equal(Studio2PageSelfTests.data(url), original)
            t.equal(names(), ["MeterBack", "MeterTitle", "MeterValue", "MeterBar"])
        }
    }

    // MARK: Rainmeter details

    static func detailsTests(_ t: AppTestRunner) {
        t.suite("Studio2: sidebar: Rainmeter details are remembered") {
            Studio2SelfTests.prepare(t)
            guard let (app, c, _) = try Studio2SelfTests.loadSkin(t, "Details", ini),
                  let studio = Studio2SelfTests.openNew(app, c) else { return }
            t.check(!studio.isRainmeterSkin, "a widget made here")
            t.check(!studio.showsRainmeterDetails, "off by default")
            t.equal(studio.sidebarState.hint, nil, "no hint")
            // ⌥⌘R.
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                                         timestamp: 0, windowNumber: 0, context: nil, characters: "®",
                                         charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15)!
            t.check(studio.keyEquivalent(event), "⌥⌘R is the window's")
            t.check(studio.showsRainmeterDetails, "on")
            let item = NSMenuItem(title: "Show Rainmeter Details",
                                  action: #selector(StudioWindowController.toggleRainmeterDetails(_:)), keyEquivalent: "")
            t.check(studio.validateMenuItem(item))
            t.equal(item.state, .on, "the View menu's check mark")
            app.state.saveNow()
            let again = AppState(fileURL: app.state.fileURL)
            t.check(again.editor.showIniNames, "kept for the user")
            studio.toggleRainmeterDetails(nil)
            app.state.saveNow()
            t.check(!AppState(fileURL: app.state.fileURL).editor.showIniNames, "and off again")
            t.equal(item.state, .on, "(the item as it was validated)")
            _ = studio.validateMenuItem(item)
            t.equal(item.state, .off)
        }

        t.suite("Studio2: sidebar: the first Rainmeter skin turns Rainmeter details on") {
            Studio2SelfTests.prepare(t)
            guard let opened = open(t, "13b-compat") else { return }
            defer { opened.close() }
            let studio = opened.controller
            t.check(studio.isRainmeterSkin)
            t.check(studio.showsRainmeterDetails, "on by itself")
            t.check(studio.app.state.editor.seenTips.contains(StudioWindowController.rainmeterNamesTip))
            t.equal(studio.sidebarState.hint, "Rainmeter names on · ⌥⌘R to hide")
            // INI names at the right of the rows.
            guard case .row(let accent)? = studio.widgetPage.page?.item("option:AccentColor")?.kind else {
                return t.check(false, "the accent row")
            }
            t.equal(accent.detail, "AccentColor")
            // Closed sidebar: the hint shows over the canvas instead.
            studio.setSidebarOpen(false)
            t.check(!studio.canvasController.hintPill.isHidden)
            t.check(studio.sidebarController.hint.isHidden)
            studio.setSidebarOpen(true)
            t.check(studio.canvasController.hintPill.isHidden)
            // Turned off, it stays off the next time a Rainmeter skin opens.
            studio.toggleRainmeterDetails(nil)
            studio.turnOnRainmeterDetailsTheFirstTime()
            t.check(!studio.showsRainmeterDetails, "only the first time")
            t.equal(studio.sidebarState.hint, nil)
        }

        t.suite("Studio2: sidebar: the compatibility capsule") {
            Studio2SelfTests.prepare(t)
            guard let opened = open(t, "13b-compat") else { return }
            defer { opened.close() }
            let studio = opened.controller, capsule = studio.canvasController.compatCapsule
            t.check(!capsule.isHidden, "a Rainmeter skin says how it is edited")
            t.equal(capsule.titleLabel.stringValue, "Rainmeter skin · compatibility mode")
            t.check(capsule.showsOffer, "the offer, before the first change")
            t.equal(capsule.switchButton.title, "Switch")
            t.equal(capsule.stayButton.title, "Stay with INI")
            t.check(capsule.frame.minY > StudioCanvasViewController.toolbarHeight, "under the toolbar: \(capsule.frame)")
            // A change: the offer goes (switching then would break the undo stack); undone, it is back.
            studio.toggleHidden("MeterTitle")
            t.check(!capsule.showsOffer, "no offer after a change")
            t.check(!capsule.isHidden, "the capsule stays")
            studio.session?.undoStack.undo()
            t.check(capsule.showsOffer, "the offer again once undone")
            // Stay with INI: remembered for this skin.
            capsule.stayClicked()
            t.check(!capsule.showsOffer, "Stay with INI")
            t.check(studio.app.state.editor.seenTips.contains(StudioCompatChoice.tip("Nocturne")))
            // A built-in widget has none.
            guard let system = open(t, "03-customize") else { return }
            defer { system.close() }
            t.check(system.controller.canvasController.compatCapsule.isHidden, "none on a built-in widget")
        }
    }

    // MARK: Accessibility

    static func accessibilityTests(_ t: AppTestRunner) {
        t.suite("Studio2: accessibility: the canvas's tree") {
            Studio2SelfTests.prepare(t)
            StudioAnnouncer.clear()
            guard let opened = open(t, "13b-compat") else { return }
            defer { opened.close() }
            let studio = opened.controller, canvas = studio.canvasController.canvas
            let lines = StudioCanvasAccessibility.export(canvas)
            t.equal(lines.first, "AXGroup “Widget canvas”")
            t.equal(lines.dropFirst().first, "  AXGroup “Nocturne, the widget”", "the widget holds its parts")
            let parts = lines.filter { $0.hasPrefix("    ") }
            t.equal(parts.count, studio.skin?.meters.filter { !$0.hidden }.count, "one element per part")
            let actions = "[Show in Code, Bring Forward, Send Backward, Delete]"
            t.check(parts.contains("    AXStaticText “CPU usage” = 23% \(actions)"), "\(parts.prefix(8))")
            t.check(parts.contains("    AXProgressIndicator “CPU bar” = 23% \(actions)"))
            t.check(parts.contains("    AXButton ““STEAM”” \(actions)"))
            t.check(parts.contains("    AXStaticText ““NOCTURNE”” \(actions)"))
            let access = studio.canvasAccess!
            guard let cpu = access.parts.first(where: { $0.name == "MeterCPU" }) else { return t.check(false, "MeterCPU") }
            t.equal(cpu.accessibilityRoleDescription(), "number")
            t.check((cpu.accessibilityParent() as AnyObject?) === access.widgetElement, "its parent is the widget")
            t.check(cpu.accessibilityFrame().width > 0, "it has a place")
            t.check(cpu.accessibilityPerformPress(), "pressing selects it")
            t.equal(canvas.selectedNames, ["MeterCPU"])
            t.check(cpu.isAccessibilitySelected())
            // The rotors.
            let rotors = canvas.accessibilityCustomRotors().map(\.label)
            t.equal(rotors, ["Layers", "Problems"])
            let problems = access.items(of: access.problemsRotor).map(\.name)
            t.equal(Set(problems), ["MeterCPUTemp", "MeterGPUTemp", "MeterSteam", "MeterMusic", "MeterFiles"],
                    "the parts that need attention")
            let parameters = NSAccessibilityCustomRotor.SearchParameters()
            parameters.searchDirection = .next
            let first = access.rotor(access.problemsRotor, resultFor: parameters)
            t.equal((first?.targetElement as AnyObject? as? StudioPartElement)?.name, "MeterCPUTemp")
            t.equal(first?.customLabel, "CPU temp")
            parameters.currentItem = first
            let second = access.rotor(access.problemsRotor, resultFor: parameters)
            t.equal((second?.targetElement as AnyObject? as? StudioPartElement)?.name, "MeterGPUTemp")
            // A custom action is a step like any other.
            let url = Studio2PageSelfTests.file(opened, "Nocturne/Nocturne.ini")
            let before = Studio2PageSelfTests.data(url)
            guard let back = cpu.accessibilityCustomActions()?.first(where: { $0.name == "Send Backward" }) else {
                return t.check(false, "Send Backward")
            }
            t.check(back.handler?() == true)
            t.equal(studio.session?.undoStack.undoActionName, "Send Backward")
            t.equal(StudioAnnouncer.recorded.last, "Moved CPU usage", "the change is said")
            studio.session?.undoStack.undo()
            t.equal(StudioAnnouncer.recorded.last, "Undid Send Backward", "and its undo, by name")
            t.equal(Studio2PageSelfTests.data(url), before)
            t.check(StudioAnnouncer.recorded.contains("Customizing “Nocturne”. The inspector shows the widget page."),
                    "opening is said: \(StudioAnnouncer.recorded.prefix(3))")
        }

        t.suite("Studio2: accessibility: a change of scope is said") {
            Studio2SelfTests.prepare(t)
            StudioAnnouncer.clear()
            guard let opened = open(t, "04-part") else { return }
            defer { opened.close() }
            let studio = opened.controller
            t.check(StudioAnnouncer.recorded.first?.hasPrefix("Customizing “") == true,
                    "\(StudioAnnouncer.recorded.first ?? "")")
            studio.partPage.handle(.scopeHover(false))
            studio.partPage.handle(.scopeLink)
            t.check(StudioAnnouncer.recorded.last?.hasPrefix("Now changing: ") == true,
                    "\(StudioAnnouncer.recorded.last ?? "")")
        }
    }

    // MARK: The keyboard's route

    static func focusTests(_ t: AppTestRunner) {
        t.suite("Studio2: keyboard: ⌃Tab goes round the panes; Return and Esc between a part and its page") {
            Studio2SelfTests.prepare(t)
            guard let opened = open(t, "13b-compat") else { return }
            defer { opened.close() }
            let studio = opened.controller
            studio.focus(.canvas)
            t.equal(studio.focusArea, .canvas)
            t.equal(studio.focusAreas, [.canvas, .inspector, .sidebar], "no code pane yet")
            studio.cycleFocus(backward: false)
            t.equal(studio.focusArea, .inspector)
            studio.cycleFocus(backward: false)
            t.equal(studio.focusArea, .sidebar)
            t.check(studio.window?.firstResponder === studio.sidebarController.layersView.partsOutline)
            studio.cycleFocus(backward: false)
            t.equal(studio.focusArea, .canvas, "round again")
            studio.cycleFocus(backward: true)
            t.equal(studio.focusArea, .sidebar, "⌃⇧Tab: back")
            // ⌃Tab reaches the window before any view.
            let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
                                       windowNumber: studio.window?.windowNumber ?? 0, context: nil, characters: "\t",
                                       charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
            studio.window?.sendEvent(tab)
            t.equal(studio.focusArea, .canvas)
            // Return on a part: its page's first control; Esc: back to the part.
            studio.select(part: "MeterCPU")
            studio.focus(.canvas)
            t.check(studio.returnFromCanvas())
            t.equal(studio.focusArea, .inspector)
            t.check(studio.window?.firstResponder is NSControl || (studio.window?.firstResponder as? NSTextView)?.isFieldEditor == true,
                    "a control: \(String(describing: studio.window?.firstResponder))")
            studio.escapeFromInspector()
            t.equal(studio.focusArea, .canvas)
            t.equal(studio.canvasController.canvas.selectedNames, ["MeterCPU"], "the part stays selected")
            // Esc on the inspector otherwise: one level up.
            studio.focus(.inspector)
            studio.escapeFromInspector()
            t.equal(studio.partPage.focus, nil)
            // Nothing selected: Return does nothing.
            t.check(!studio.returnFromCanvas())
        }
    }
}
