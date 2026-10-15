import Foundation
@testable import DesksetCore

private final class CatalogDecisionHost: FakeHost {
    let accepted: Set<String> = ["resetstats", "execute", "unknownbang"]

    override func skin(_ skin: Skin, handle bang: Bang) -> Bool {
        handled.append(bang)
        return accepted.contains(bang.name)
    }
}

func runActionCatalogTests(_ t: TestRunner) {
    t.suite("Action: execution catalog: the table covers the documented directory without extra names") {
        let names = ActionCatalog.all.map(\.name)
        let actual = Set(names)
        let documented = Set(BangCatalog.all.map(\.name))
        t.equal(documented.subtracting(actual), [], "every documented bang has an explicit dispatch owner")
        t.equal(actual.subtracting(documented), [], "the table invents no bang names")
        t.equal(names.count, actual.count, "each name has exactly one classification")
        t.check(documented.allSatisfy { ActionCatalog.handler(for: $0) != nil }, "the lookup covers the directory")

        let known: [(String, ActionCatalog.Handler)] = [
            ("setvariable", .engineLocal), ("writekeyvalue", .engineLocal),
            ("commandmeasure", .engineLocal), ("pluginbang", .engineLocal),
            ("move", .host(.window)), ("showgroup", .host(.window)),
            ("refresh", .host(.lifecycle)), ("refreshgroup", .host(.lifecycle)),
            ("setvariablegroup", .host(.group)), ("togglemouseactionskingroup", .host(.group)),
            ("manage", .host(.ui)), ("play", .host(.system)),
            ("delay", .delayRunOnly), ("execute", .parserOnly),
        ]
        for (name, expected) in known { t.equal(ActionCatalog.handler(for: name), expected, name) }
        for name in ["resetstats", "loadlayout", "showblur", "hideblur", "toggleblur", "addblur", "removeblur",
                     "setanchor"] {
            t.equal(ActionCatalog.handler(for: name), .currentlyUnsupported, name)
        }
        t.equal(ActionCatalog.handler(for: "unknownbang"), nil)
        t.check(documented.allSatisfy { ActionCatalog.handler(for: $0.uppercased()) == nil },
                "runtime lookup does not canonicalize direct names")
        t.equal(ActionCatalog.handler(for: "!SetVariable"), nil)
        t.equal(ActionCatalog.handler(for: "rainmetermove"), nil)
    }

    t.suite("Action: execution catalog: unsupported and parser-only entries still ask the real host") {
        let host = CatalogDecisionHost()
        let (skin, _) = try makeSkin(t, "[Rainmeter]\nUpdate=-1\n", host: host)
        defer { skin.close() }
        let accepted = [
            Bang(name: "resetstats", args: ["kept", "*"]),
            Bang(name: "execute", args: ["[!SetVariable NotParsed 1]"]),
            Bang(name: "unknownbang", args: ["host chooses"]),
        ]
        for bang in accepted { skin.perform(bang) }
        t.equal(host.handled, accepted, "metadata does not consume a bang the host may accept")
        t.equal(skin.variable("NotParsed"), nil, "direct Execute remains one host request")
        t.equal(skin.issues, [])
        t.equal(host.logs, [])

        skin.perform(Bang(name: "loadlayout", args: ["layout"]))
        skin.perform(Bang(name: "nosuchbang", args: ["unchanged"]))
        t.equal(host.handled, accepted + [Bang(name: "loadlayout", args: ["layout"]),
                                         Bang(name: "nosuchbang", args: ["unchanged"])])
        t.check(skin.issues.contains { $0.contains("!loadlayout") }, "known unsupported is an issue after rejection")
        t.check(!skin.issues.contains { $0.contains("nosuchbang") }, "unknown is only logged")
        t.equal(host.logs, ["Warning: Unsupported bang: !loadlayout", "Warning: Unknown bang: !nosuchbang"])

        skin.perform(Bang(name: "delay", args: ["1"]))
        t.equal(host.handled.count, 5, "direct Delay remains distinct from parser-only Execute")
        skin.execute("[!Execute [!SetVariable Wrapped 7]]", from: nil)
        t.equal(skin.variable("Wrapped"), "7", "the existing parser still unwraps Execute before dispatch")
        t.equal(host.handled.count, 5)
    }
}
