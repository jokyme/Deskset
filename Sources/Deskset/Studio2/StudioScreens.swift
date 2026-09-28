import AppKit
import DesksetCore

/// The screens `--snapshot-ui studio2 --screen NAME` renders, named after the designed screens they are compared with:
/// which widget (a fixture copied into a temporary Skins folder), how its files are (edits made to the copy, such as
/// the typos a screen shows), and how the window is (sidebar, inspector, zoom, what is selected or open).
struct StudioScreen {
    /// A widget the screen shows: a root folder copied from the repository, and the config and file loaded from it.
    struct Fixture: Equatable {
        /// The repository folder the root folder comes from ("DefaultSkins", "TestSkins/Studio2").
        var source: String
        /// The root folder ("Stationery", "Nocturne").
        var root: String
        var config: String
        var file: String

        static let system = Fixture(source: "DefaultSkins", root: "Stationery", config: "Stationery\\System",
                                    file: "Medium.ini")
        static let weather = Fixture(source: "DefaultSkins", root: "Stationery", config: "Stationery\\Weather",
                                     file: "Medium.ini")
        static let nocturne = Fixture(source: "TestSkins/Studio2", root: "Nocturne", config: "Nocturne",
                                      file: "Nocturne.ini")
        static let cpu = Fixture(source: "TestSkins/Studio2", root: "CPU", config: "CPU", file: "CPU.ini")
    }

    /// A text replaced in a file of the copy (a path under the root folder), before the widget loads.
    struct FileEdit: Equatable {
        var path: String
        var find: String
        var replace: String
    }

    let name: String
    var fixture: Fixture
    var edits: [FileEdit] = []
    var depth = StudioDepth.customize
    var inspectorShown = true
    /// The canvas zoom (nil: fit).
    var zoom: CGFloat?
    /// The part selected: its page shows.
    var selection: String?
    /// Every Setting is open on the selected part.
    var everySetting = false
    /// The pointer is on the scope sentence's link (the canvas outlines what it would reach).
    var scopeHover = false
    /// ⌥ is held: the distances show.
    var distances = false
    /// A row whose label is being dragged (drawn with ↔).
    var scrubbing: String?
    /// The backdrop (a sample, or "Your Desktop": the procedural hills in snapshots).
    var backdrop = StudioBackdropKind.desktop
    /// Sample data shown as a preset (the preview bar says so), and the time frozen at 10:09.
    var data: MeasureValueOverride.Data?
    var frozen = false
    /// The "Preview only" popover is open.
    var previewPopover = false
    /// How many updates the Studio's instance makes before the picture (sample readings settle over a few).
    var updates = 1
    /// Readings pinned by measure name (the design's numbers on the widget's live measures, so the page names the
    /// data as the widget reads it).
    var pinned: [String: (value: Double, text: String?)] = [:]
    /// The swatch the color popover is open on ("part:1": the second part color).
    var colorPopover: String?
    /// The swatch the pointer is on (the canvas frames what it paints).
    var hoverSwatch: String?
    /// The recent colors the popover lists.
    var recentColors: [RGBA] = []
    /// The sidebar's page at the Build depth.
    var sidebarPage = StudioSidebarViewController.Page.layers
    /// The data row of Layers the pointer is on (the canvas outlines the parts that use it).
    var pointedData: String?
    /// Texts replaced through the code pane once the window is open (typed and committed: the desktop copy keeps the
    /// last working version when they break a part).
    var codeEdits: [FileEdit] = []
    /// The code pane.
    var code = StudioCodeState.Mode.hidden
    /// The caret in the code: a file (a path under the root folder) and a line.
    var caret: (path: String, line: Int)?
    /// The code header's file menu is open.
    var fileMenu = false
    /// What the design shows that the window does not have yet: listed with the differences.
    var later: [String] = []

    /// The System widget on the suite's own sample readings (the design's: CPU 21 %, memory 20.4 GB, up 14 d 5 h).
    static let systemDemo = FileEdit(path: "@Resources/System/Settings.inc", find: "SystemSource=Live",
                                     replace: "SystemSource=Demo")

    /// The design's readings for System on its live measures: CPU 21 %, 20.4 of 24 GB, 88 % of the disk used, the GPU
    /// at 34 %, up 14 days 5 hours, a MacBook Pro.
    static let systemReadings: [String: (value: Double, text: String?)] = [
        "measurecpu": (21, nil),
        "measurememused": (20.4 * 1_073_741_824, nil),
        "measurememtotal": (24 * 1_073_741_824, nil),
        "measureswapall": (20.4 * 1_073_741_824, nil),
        "measurediskavail": (117_520_000_000, nil),
        "measuredisktotal": (994_662_584_320, nil),
        "measurediskname": (0, "Macintosh HD"),
        "measuregpu": (34, "34"),
        "measureuptime": (1_228_320, nil),
        "measurecomputername": (0, "MacBook Pro"),
        "measurebattery": (1, nil),
    ]

    /// The design's readings for Nocturne: CPU 23 %, GPU 34 %, 20.4 GB of memory, 2.7 MB/s down, 553 kB/s up.
    static let nocturneReadings: [String: (value: Double, text: String?)] = [
        "measurecpu": (23, nil),
        "measuregpuusage": (34, nil),
        "measuregpu": (34, nil),
        "measureram": (20.4 * 1_073_741_824, nil),
        "measurenetin": (2.7 * 1_048_576, nil),
        "measurenetout": (553 * 1024, nil),
    ]

    /// The designed screens, in the order of the design.
    static let all: [StudioScreen] = [
        StudioScreen(name: "03-customize", fixture: .system, zoom: 1.65, updates: 4, pinned: systemReadings,
                     colorPopover: "part:1",
                     recentColors: [RGBA(r: 250, g: 115, b: 89), RGBA(r: 92, g: 107, b: 242)],
                     later: ["Different in Dark Mode in the color popover", "the color field shows the file's R,G,B",
                             "Disk reads as free space on Macintosh HD", "look thumbnails over a sample backdrop"]),
        // A city picked (the design's), and the sample forecast of `DESKSET_WEATHER_DEMO`.
        StudioScreen(name: "03b-weather", fixture: .weather,
                     edits: [FileEdit(path: "@Resources/Variables.inc", find: "Location=timezone",
                                      replace: "Location=Hangzhou"),
                             FileEdit(path: "@Resources/Variables.inc", find: "LocationConfirmed=0",
                                      replace: "LocationConfirmed=1")],
                     zoom: 1.65, hoverSwatch: "part:0",
                     later: ["wallpaper backdrop", "the city row (city search)", "the Colors scope sentence for two copies",
                             "Accent among the colors"]),
        StudioScreen(name: "04-part", fixture: .system, zoom: 1.65, selection: "MeterCPUValue",
                     scopeHover: true, updates: 4, pinned: systemReadings,
                     later: ["Position: In the Column · Free (an INI part is free: X and Y instead)",
                             "Shows examples (the number is written by the widget's data, not the part)",
                             "the pointer drawn on the link"]),
        StudioScreen(name: "07-layers", fixture: .system, depth: .build, zoom: 1.9, updates: 4,
                     pinned: systemReadings,
                     later: ["INI layers are flat: no columns or rows, no shared styles or calculated values",
                             "the ring's page (Show as, Center) and the connect menu"]),
        // The Add page (the design's 08 drags "Disk used" onto a row of rings: INI widgets are free, so no drop sentence).
        StudioScreen(name: "08-add", fixture: .system, depth: .build, zoom: 2, updates: 4, pinned: systemReadings,
                     sidebarPage: .add,
                     later: ["the drag under way: its sentence, the row making room, the container's page",
                             "Layout (Column, Row, Grid, Free): INI widgets place parts freely",
                             "Calendar, Web and Command data"]),
        StudioScreen(name: "09-every-setting", fixture: .cpu, zoom: 3, selection: "MeterValue", everySetting: true,
                     distances: true, scrubbing: "every:FontSize", backdrop: .workbench, updates: 2,
                     pinned: ["measurecpu": (23, nil)],
                     later: ["Tracking, Line height, Digits, Nudge, Turn (settings an INI text does not have)",
                             "Pointed at presets", "the rule's source chip on Color"]),
        StudioScreen(name: "10-preview", fixture: .cpu, zoom: 2.5, backdrop: .bright, data: .level(1), frozen: true,
                     previewPopover: true,
                     later: ["part page with the contrast card", "selection of the caption", "Build's layers"]),
        // The two typos are typed in the code (so the desktop keeps the last working version); the caret rests on the
        // first, the file menu is open.
        StudioScreen(name: "12b-code-ini", fixture: .nocturne, zoom: 1.5, pinned: nocturneReadings,
                     codeEdits: [FileEdit(path: "@Resources/Styles.inc", find: "FontColor=#TextColor#",
                                          replace: "FontColr=#TextColor#"),
                                 FileEdit(path: "@Resources/Styles.inc", find: "W=(#BarWidth#)",
                                          replace: "W=(#BarWidth# *)")],
                     code: .alongside, caret: ("@Resources/Styles.inc", 13), fileMenu: true,
                     later: ["the selected block's line numbers in the accent color",
                             "the fixture's clock, temperatures and network text use StyleValue too: they are framed",
                             "the log counts what the fixture logs (1)"]),
        StudioScreen(name: "13b-compat", fixture: .nocturne, depth: .build, zoom: 1.5,
                     pinned: nocturneReadings, pointedData: "MeasureCPU",
                     later: ["needs attention and its marks on the canvas", "Changed to fit the Mac",
                             "the Shows rows the design leaves out", "every part and data item of the fixture listed"]),
        StudioScreen(name: "17-show-on-desktop", fixture: .system, edits: [systemDemo], zoom: 1,
                     updates: 4,
                     later: ["show on desktop: the window fades and the widget on the desktop comes up"]),
    ]

    /// The time snapshots show: 27 September 2026, 10:09.
    static let frozenTime: Date = {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 9
        parts.day = 27
        parts.hour = 10
        parts.minute = 9
        return Calendar.current.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }()

    static func named(_ name: String) -> StudioScreen? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    static var names: [String] { all.map(\.name) }

    /// Copies the screen's fixture into `skins` (a new Skins folder) and makes its file edits. False when the
    /// repository's folder is not found or an edit does not apply (the fixture changed under the screen).
    func install(into skins: URL) throws -> Bool {
        guard let source = Paths.repositoryFolder(fixture.source) else { return false }
        let fm = FileManager.default
        try fm.createDirectory(at: skins, withIntermediateDirectories: true)
        let target = skins.appendingPathComponent(fixture.root, isDirectory: true)
        try fm.copyItem(at: source.appendingPathComponent(fixture.root, isDirectory: true), to: target)
        for edit in edits {
            let url = target.appendingPathComponent(edit.path)
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains(edit.find) else { return false }
            try text.replacingOccurrences(of: edit.find, with: edit.replace).write(to: url, atomically: true,
                                                                                    encoding: .utf8)
        }
        return true
    }
}
