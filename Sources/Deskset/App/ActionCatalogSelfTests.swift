import DesksetCore

// Uses the existing HostBangs API so the same fixture runs before and after the shared table is installed.
enum ActionCatalogSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: action catalog: host classification keeps its existing dispatch boundary") {
            let supported: [(String, HostBangs.Kind)] = [
                ("move", .window), ("setwindowposition", .window), ("showgroup", .window),
                ("zposgroup", .window), ("fadedurationgroup", .window),
                ("refresh", .lifecycle), ("refreshgroup", .lifecycle), ("activateconfig", .lifecycle),
                ("quit", .lifecycle),
                ("updategroup", .group), ("setvariablegroup", .group), ("togglemouseactionskingroup", .group),
                ("manage", .ui), ("editskin", .ui),
                ("setclip", .system), ("play", .system), ("playstop", .system),
            ]
            for (name, expected) in supported {
                t.equal(HostBangs.kind(of: name), expected, name)
            }
            for name in ["setvariable", "updatemeasure", "update", "delay", "execute", "showblur", "resetstats",
                         "loadlayout", "setanchor", "unknownbang"] {
                t.equal(HostBangs.kind(of: name), nil, "\(name) is not a supported host operation")
            }
            t.check(BangCatalog.all.allSatisfy { HostBangs.kind(of: $0.name.uppercased()) == nil },
                    "direct uppercase names are not normalized")
            t.check(BangCatalog.all.allSatisfy { HostBangs.kind(of: "!" + $0.name) == nil },
                    "the host boundary does not strip a bang prefix")
            t.equal(HostBangs.kind(of: "rainmetermove"), nil, "legacy aliases belong to the parser")
            t.equal(BangCatalog.canonicalName("!RainmeterMove"), "move", "the parser's separate normalization remains")
        }
    }
}
