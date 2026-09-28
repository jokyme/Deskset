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
    /// The layer selected (later: the part's page).
    var selection: String?
    /// What the design shows that the window does not have yet: listed with the differences.
    var later: [String] = []

    /// The designed screens, in the order of the design.
    static let all: [StudioScreen] = [
        StudioScreen(name: "03-customize", fixture: .system, zoom: 1.65,
                     later: ["wallpaper backdrop", "caption", "preview bar", "zoom capsule", "widget page",
                             "color popover", "search field"]),
        // A city picked (the design's), and the sample forecast of `DESKSET_WEATHER_DEMO`.
        StudioScreen(name: "03b-weather", fixture: .weather,
                     edits: [FileEdit(path: "@Resources/Variables.inc", find: "Location=timezone",
                                      replace: "Location=Hangzhou"),
                             FileEdit(path: "@Resources/Variables.inc", find: "LocationConfirmed=0",
                                      replace: "LocationConfirmed=1")],
                     zoom: 1.65,
                     later: ["wallpaper backdrop", "widget page with options", "scope sentence",
                             "what-it-paints outline"]),
        StudioScreen(name: "04-part", fixture: .system, zoom: 1.65, selection: "MeterCPUValue",
                     later: ["part page", "scope sentence", "breadcrumb"]),
        StudioScreen(name: "07-layers", fixture: .system, depth: .build, zoom: 1.9,
                     later: ["layers", "connect menu"]),
        StudioScreen(name: "09-every-setting", fixture: .cpu, zoom: 3,
                     later: ["workbench backdrop", "every-setting page", "distances"]),
        StudioScreen(name: "10-preview", fixture: .cpu, zoom: 2.5,
                     later: ["sample backdrop", "data preset", "preview popover", "contrast card"]),
        StudioScreen(name: "12b-code-ini", fixture: .nocturne,
                     edits: [FileEdit(path: "@Resources/Styles.inc", find: "FontColor=#TextColor#",
                                      replace: "FontColr=#TextColor#"),
                             FileEdit(path: "@Resources/Styles.inc", find: "W=(#BarWidth#)",
                                      replace: "W=(#BarWidth# *)")],
                     zoom: 1.5, later: ["code pane in place of the inspector", "INI diagnostics", "log count",
                                        "last working version capsule"]),
        StudioScreen(name: "13b-compat", fixture: .nocturne, depth: .build, zoom: 1.5,
                     later: ["compatibility capsule", "needs attention", "measures in the layers"]),
        StudioScreen(name: "17-show-on-desktop", fixture: .system, zoom: 1,
                     later: ["show on desktop: the window fades and the widget on the desktop comes up"]),
    ]

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
