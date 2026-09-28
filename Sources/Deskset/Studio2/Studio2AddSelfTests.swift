import AppKit
import DesksetCore

/// The Add page of the new Studio's sidebar: what it offers, finding things on it, and what a click or a drop adds —
/// each one named step, undone byte for byte.
enum Studio2AddSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("Studio2: add: what the page offers") {
            Studio2SelfTests.prepare(t)
            guard let opened = Studio2PageSelfTests.open(t, "08-add") else { return }
            defer { opened.close() }
            let studio = opened.controller, add = studio.sidebarController.addView, content = add.content
            t.equal(studio.sidebarController.page, .add)
            t.equal(studio.toolbar.state.addOn, true, "the toolbar's Add shows the page is open")
            t.equal(add.searchField.placeholderString, "Data, parts, symbols")
            t.equal(content.dataRows.map(\.title), ["CPU usage", "Memory used", "Disk used", "GPU usage", "Download speed",
                                                    "Upload speed", "Battery"])
            t.equal(content.dataRows.first?.value, "21%", "live values (the sample ones off screen)")
            t.equal(content.categoryChips.map(\.title), ["Time", "Weather", "Music"])
            t.equal(content.tiles.map(\.title), ["Text", "Symbol", "Picture", "Bar", "Ring", "Graph", "Shape", "Button"])
            t.equal(content.symbolChips.map(\.title), ["Chip", "Umbrella", "Rain"])
            t.check(content.colorChips.map(\.title).contains("CPU ring"), "this widget's colors: \(content.colorChips.map(\.title))")
            t.check(content.fontChips.map(\.title).contains("System Rounded"), "and fonts")
            // A category.
            content.categoryChips.first?.onClick?()
            t.equal(content.dataRows.map(\.item.id), ["time", "date", "uptime"])
            t.check(content.categoryChips.first?.isOn == true)
            content.categoryChips.first?.onClick?()
            t.equal(content.dataRows.first?.item.id, "cpu", "again: this Mac")
            // Finding.
            add.setQuery("ring")
            t.equal(content.tiles.map(\.part), [.ring])
            add.setQuery("umbrella")
            t.equal(content.symbolChips.first?.title, "Umbrella")
            add.setQuery("网速")
            t.equal(content.dataRows.map(\.item.id), ["download", "upload"])
            add.setQuery("zzzz")
            t.check(!content.emptyLabel.isHidden)
            add.setQuery("")
            t.check(content.emptyLabel.isHidden)
        }

        t.suite("Studio2: add: a click or a drop adds, one step undone byte for byte") {
            Studio2SelfTests.prepare(t)
            guard let (app, c, url) = try Studio2SelfTests.loadSkin(t, "Add", Studio2SidebarSelfTests.ini),
                  let studio = Studio2SelfTests.openNew(app, c) else { return }
            studio.addAction(nil)
            t.check(!studio.sidebarItem.isCollapsed)
            t.equal(studio.sidebarController.page, .add, "the toolbar's Add opens the Add page")
            let undo = studio.session!.undoStack
            let original = Studio2PageSelfTests.data(url)
            func names() -> [String] { studio.skin?.meters.map(\.name) ?? [] }
            func measures() -> [String] { studio.skin?.measures.map(\.name) ?? [] }
            // Data: how to show it, then a pick.
            studio.select(part: "MeterTitle")
            studio.addEvent(.data("cpu"))
            guard let menu = studio.sidebarState.lookMenu else { return t.check(false, "the looks") }
            t.equal(menu.items.map(\.title), ["Show CPU usage as…", "Number", "Bar", "Ring", "Graph"])
            menu.performActionForItem(at: 3)
            t.equal(undo.undoActionName, "Add CPU usage")
            t.equal(measures(), ["MeasureCPU"], "the widget's own CPU measure is read, not a second one")
            t.check(names().contains("MeterCPURing"), "\(names())")
            t.equal(studio.canvasController.canvas.selectedNames.first, "MeterCPURingTrack", "the new part is selected")
            t.equal(names().firstIndex(of: "MeterCPURingTrack"), 3,
                    "after the selection and the part placed relative to it: \(names())")
            undo.undo()
            t.equal(Studio2PageSelfTests.data(url), original)
            // Data this widget does not read: a measure of its own.
            t.check(studio.addData("memory", look: .number))
            t.equal(measures(), ["MeasureCPU", "MeasureMemory"])
            undo.undo()
            t.equal(Studio2PageSelfTests.data(url), original)
            // A part, a symbol.
            studio.addEvent(.part(.button))
            t.equal(undo.undoActionName, "Add Button")
            t.check(names().contains("MeterButton"))
            undo.undo()
            studio.addEvent(.symbol("umbrella.fill"))
            t.equal(undo.undoActionName, "Add Umbrella")
            t.equal(studio.skin?.meter(named: "MeterSymbol")?.fileOption("ImageName"), "sf:umbrella.fill")
            t.equal(StudioAddView.recentSymbols.first, "umbrella.fill", "the last used symbol first")
            undo.undo()
            t.equal(Studio2PageSelfTests.data(url), original)
            // A drop: where the ghost was.
            StudioAddView.currentDrag = .part(.text)
            studio.canvasController.canvas.onDropComponent?("text", SkinRect(x: 30, y: 90, width: 46, height: 20))
            t.equal(undo.undoActionName, "Add Text")
            t.equal(studio.skin?.meter(named: "MeterText")?.rawOption("X"), "30")
            t.equal(studio.skin?.meter(named: "MeterText")?.rawOption("Y"), "90")
            t.equal(StudioAddView.currentDrag, nil)
            undo.undo()
            // A dropped data item asks how to show it, at the drop.
            StudioAddView.currentDrag = .data("download")
            studio.canvasController.canvas.onDropComponent?("labelvalue", SkinRect(x: 12, y: 70, width: 160, height: 20))
            guard let looks = studio.sidebarState.lookMenu else { return t.check(false, "the looks") }
            t.equal(looks.items.map(\.title), ["Show Download speed as…", "Number", "Graph"])
            looks.performActionForItem(at: 2)
            t.equal(studio.skin?.meter(named: "MeterNetInGraph")?.rawOption("X"), "12")
            undo.undo()
            t.equal(Studio2PageSelfTests.data(url), original)
            // The browser of symbols.
            let browse = studio.browseSymbols()
            t.equal(browse.items.count, StudioSymbolIndex.all.count)
            // One of the widget's colors on the selected part.
            studio.widgetPage.rebuild()
            studio.refreshAddPage()
            studio.select(part: "MeterValue")
            let colors = studio.sidebarController.addView.content.colorChips
            guard let red = colors.first(where: { $0.title == "Text" }) ?? colors.first else {
                return t.check(false, "the widget's colors: \(colors.map(\.title))")
            }
            red.onClick?()
            t.equal(undo.undoActionName, "Color")
            t.check(Studio2PageSelfTests.text(url).contains("FontColor="), "written on the part")
            undo.undo()
            t.equal(Studio2PageSelfTests.data(url), original)
        }
    }
}
