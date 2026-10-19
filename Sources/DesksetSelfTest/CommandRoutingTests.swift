import Foundation
@testable import DesksetCore

private final class CommandRoutingHost: FakeHost {
    var peers: [String: Skin] = [:]

    override func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {
        super.skin(skin, forward: bang, toConfig: config)
        if config == "*" {
            for peer in peers.values where peer !== skin { peer.perform(bang) }
        } else if let peer = peers[config.lowercased()] {
            peer.perform(bang)
        }
    }
}

private let routingFixture = """
[Variables]
Probe=initial
[MeasureProbe]
Measure=Calc
Formula=21
[LoopA]
Measure=Loop
StartValue=1
EndValue=100
Group=A|B
[LoopB]
Measure=Loop
StartValue=1
EndValue=100
Group=B
[Meter]
Meter=String
Text=initial
[Input]
Meter=TextEdit
InitialText=initial
"""

func runCommandRoutingTests(_ t: TestRunner) {
    t.suite("Command routing: catalog and parser contracts") {
        for (name, parameters) in [
            ("Skin:Move", ["Config", "X", "Y"]),
            ("Skin:SetVariable", ["Config", "Variable", "Value"]),
            ("Skin:SetOption", ["Config", "Meter/Measure", "Option", "Value"]),
            ("Skin:CommandMeasure", ["Config", "Measure", "Arguments"]),
            ("Skin:SetWindowPosition", ["Config", "WindowX", "WindowY", "AnchorX", "AnchorY"]),
            ("Skin:Load", ["Config", "File"]),
            ("Skin:Unload", ["Config"]),
            ("Skin:Toggle", ["Config", "File"]),
            ("Skin:Edit", ["Config", "File"]),
        ] {
            let definition = BangCatalog.definition(for: name)
            t.equal(definition?.parameters.map(\.name), parameters, name)
            t.equal(definition?.configParameterIndex, 0, name)
            let complete = ["/Root/Sub/"] + Array(repeating: "0", count: parameters.count - 1)
            t.equal(definition?.configArgument(in: complete), "Root/Sub", name)
        }
        for (name, required, localArguments) in [
            ("Skin:SetVariable", 2, ["Probe", "value"]),
            ("Skin:SetOption", 3, ["Meter", "Text", "value"]),
            ("Skin:CommandMeasure", 2, ["LoopA", "Reset"]),
            ("Skin:SetZoomFactor", 1, ["1.5"]),
            ("Skin:SetWindowPosition", 2, ["10", "20"]),
        ] {
            let definition = BangCatalog.definition(for: name)
            t.equal(definition?.requiredArgumentCount, required, name)
            t.equal(definition?.acceptsArgumentCount(required - 1), false, name)
            t.equal(definition?.acceptsArgumentCount(required), true, name)
            t.equal(definition?.configArgument(in: localArguments), nil, name)
        }
        t.equal(BangCatalog.definition(for: "Skin:SetWindowPosition")?.configArgument(in: ["10", "20", "50%", "100%"]), nil)
        t.equal(BangCatalog.definition(for: "Skin:SetWindowPosition")?.configArgument(in: ["Other", "10", "20"]), "Other")
        t.equal(BangCatalog.definition(for: "SetVariable")?.requiredArgumentCount, 2)
        t.equal(BangCatalog.definition(for: "Move")?.parameters.map(\.name), ["X", "Y", "Config"])
        t.equal(BangCatalog.definition(for: "SetOption")?.configParameterIndex, 3)
        t.check(!BangCatalog.isKnown("Skin:WriteKeyValue"), "a FilePath is not a Config")
        t.equal(BangCatalog.definition(for: "Loop:Reset")?.configParameterIndex, nil)
        let action = #"[!Skin:SetVariable Other Probe """(1+1)"""]"#
        t.equal(ActionParser.parse(action), [.bang(Bang(name: "skin:setvariable", args: ["Other", "Probe", "(1+1)"]))])
        t.equal(ActionParser.parseDetailed(action).first?.quoting, [.none, .none, .magic])
        t.equal(Bang(name: "setvariable", args: ["Probe", "x"]).literalArguments, [])
    }

    t.suite("Command routing: Skin aliases preserve Config-first arguments") {
        let (skin, host) = try makeSkin(t, routingFixture)
        defer { skin.close() }
        for (name, classic, arguments) in [
            ("load", "activateconfig", ["Other", "Second.ini"]),
            ("unload", "deactivateconfig", ["Other"]),
            ("unload", "deactivateconfig", ["*"]),
            ("unload", "deactivateconfig", []),
            ("toggle", "toggleconfig", ["Other", "Second.ini"]),
            ("edit", "editskin", ["Other", "Second.ini"]),
            ("edit", "editskin", []),
        ] {
            skin.perform(Bang(name: "skin:" + name, args: arguments))
            t.equal(host.handled.last, Bang(name: classic, args: arguments), name)
        }
        skin.perform(Bang(name: "toggle", args: ["Other"]))
        t.equal(host.handled.last, Bang(name: "toggle", args: ["Other"]), "classic Toggle still changes visibility")
        skin.perform(Bang(name: "skin:activateconfig", args: ["Other", "Second.ini"]))
        t.equal(host.handled.last, Bang(name: "activateconfig", args: ["Other", "Second.ini"]))
    }

    t.suite("Command routing: Skin target-first host and positioning payloads") {
        let (skin, host) = try makeSkin(t, routingFixture)
        defer { skin.close() }
        for (namespaced, classic) in [
            (Bang(name: "skin:move", args: ["Other", "123", "234"]),
             Bang(name: "move", args: ["123", "234", "Other"])),
            (Bang(name: "skin:setwindowposition", args: ["Other", "10%R@2", "20%B@2"]),
             Bang(name: "setwindowposition", args: ["10%R@2", "20%B@2", "Other"])),
            (Bang(name: "skin:setwindowposition", args: ["Other", "10%R", "20%B", "50%", "100%"]),
             Bang(name: "setwindowposition", args: ["10%R", "20%B", "50%", "100%", "Other"])),
            (Bang(name: "skin:setwindowposition", args: ["10", "20"]),
             Bang(name: "setwindowposition", args: ["10", "20"])),
            (Bang(name: "skin:setwindowposition", args: ["10", "20", "50%", "100%"]),
             Bang(name: "setwindowposition", args: ["10", "20", "50%", "100%"])),
            (Bang(name: "skin:settransparency", args: ["Other", "128"]),
             Bang(name: "settransparency", args: ["128", "Other"])),
            (Bang(name: "skin:move", args: ["Other", "123", "234", "Extra"]),
             Bang(name: "move", args: ["123", "234", "Other", "Extra"])),
            (Bang(name: "skin:setwindowposition", args: ["Other", "10", "20", "50%", "100%", "Extra"]),
             Bang(name: "setwindowposition", args: ["10", "20", "50%", "100%", "Other", "Extra"])),
        ] {
            skin.perform(namespaced)
            t.equal(host.handled.last, classic)
            skin.perform(classic)
            t.equal(host.handled.last, classic, "classic target-last arguments remain unchanged")
        }
        skin.perform(Bang(name: "skin:move", args: ["Other", "(1+1)", "3"], literalArguments: [0, 1, 99]))
        t.equal(host.handled.last,
                Bang(name: "move", args: ["(1+1)", "3", "Other"], literalArguments: [0, 2]))
        skin.execute("[!Skin:SetZoomFactor 2.0]", from: nil)
        t.equal(host.handled.last, Bang(name: "setzoomfactor", args: ["2"]), "existing omitted Config form remains valid")
    }

    t.suite("Command routing: local target-first values retain magic quoting") {
        let (skin, host) = try makeSkin(t, routingFixture)
        defer { skin.close() }
        skin.update()
        skin.execute(#"[!Skin:SetVariable "Root\Sub" Probe """(1+1)"""]"#, from: nil)
        t.equal(skin.variable("Probe"), "(1+1)")
        skin.execute(#"[!Skin:SetVariable "root/sub/" Probe """[MeasureProbe]"""]"#, from: nil)
        t.equal(skin.variable("Probe"), "[MeasureProbe]")
        skin.execute(#"[!Skin:SetOption "Root\Sub" Meter Text """(MeasureProbe+1)"""]"#, from: nil)
        t.equal(skin.meter(named: "Meter")?.rawOption("Text"), "(MeasureProbe+1)")
        skin.execute(#"[!Skin:SetOption "Root\Sub" Meter Text """(1+1)"""]"#, from: nil)
        t.equal(skin.meter(named: "Meter")?.rawOption("Text"), "(1+1)")
        skin.execute(#"[!Skin:SetOption "Root\Sub" Meter Text """[MeasureProbe]"""]"#, from: nil)
        t.equal(skin.meter(named: "Meter")?.rawOption("Text"), "[MeasureProbe]")
        skin.execute(#"[!Skin:SetVariable "Root\Sub" Probe "(1+1)"]"#, from: nil)
        t.equal(skin.variable("Probe"), "2", "ordinary quotes continue evaluating formulas")
        skin.execute(#"[!Skin:SetOption "Root\Sub" Meter Text "(MeasureProbe+1)"]"#, from: nil)
        t.equal(skin.meter(named: "Meter")?.rawOption("Text"), "22")
        skin.execute(#"[!Skin:CommandMeasure "Root\Sub" LoopA Reset][!UpdateMeasure LoopA]"#, from: nil)
        t.close(skin.measure(named: "LoopA")?.value ?? -1, 1)
        t.check(host.forwarded.isEmpty)
        skin.execute("[!SetOption Text SectionLocal]", from: skin.meter(named: "Meter"))
        t.equal(skin.meter(named: "Meter")?.rawOption("Text"), "SectionLocal", "classic omitted section stays local")
    }

    t.suite("Command routing: peer forwarding preserves and truncates literal indices") {
        let host = CommandRoutingHost()
        let (source, _) = try makeSkin(t, routingFixture, host: host)
        let peer = Skin(config: "Other", fileURL: source.fileURL, skinsDirectory: source.skinsDirectory,
                        system: FakeSystem(), host: host)
        try peer.load()
        host.peers["other"] = peer
        defer { source.close(); peer.close(); host.peers.removeAll() }
        source.update()
        peer.update()
        source.execute(#"[!Skin:SetVariable Other Probe """(1+1)"""]"#, from: nil)
        t.equal(source.variable("Probe"), "initial")
        t.equal(peer.variable("Probe"), "(1+1)")
        t.equal(host.forwarded.last?.0, Bang(name: "setvariable", args: ["Probe", "(1+1)"], literalArguments: [1]))
        source.execute(#"[!Skin:SetVariable """Other""" Probe """[MeasureProbe]"""]"#, from: nil)
        t.equal(peer.variable("Probe"), "[MeasureProbe]")
        t.equal(host.forwarded.last?.0.literalArguments, [1], "removed Config metadata is discarded")
        source.execute(#"[!Skin:SetOption Other Meter Text """(MeasureProbe+1)"""]"#, from: nil)
        t.equal(peer.meter(named: "Meter")?.rawOption("Text"), "(MeasureProbe+1)")
        t.equal(host.forwarded.last?.0.literalArguments, [2])
        source.execute(#"[!SetVariable Probe """(1+1)""" Other]"#, from: nil)
        t.equal(peer.variable("Probe"), "(1+1)", "classic target-last forwarding retains magic quotes too")
        source.execute(#"[!Skin:SetVariable * Probe """[MeasureProbe]"""]"#, from: nil)
        t.equal(source.variable("Probe"), "[MeasureProbe]")
        t.equal(peer.variable("Probe"), "[MeasureProbe]")
        source.execute(#"[!Skin:CommandMeasure Other LoopA Reset][!UpdateMeasure LoopA Other]"#, from: nil)
        t.close(peer.measure(named: "LoopA")?.value ?? -1, 1)
        source.execute(#"[!Skin:SetVariable Group=A|B Probe """(1+1)"""]"#, from: nil)
        t.equal(host.forwarded.last?.1, "Group=A|B")
        t.equal(host.forwarded.last?.0, Bang(name: "setvariable", args: ["Probe", "(1+1)"], literalArguments: [1]))
        source.execute(#"[!Skin:SetOption Group=A&B Meter Text """[MeasureProbe]"""]"#, from: nil)
        t.equal(host.forwarded.last?.1, "Group=A&B")
        t.equal(host.forwarded.last?.0, Bang(name: "setoption", args: ["Meter", "Text", "[MeasureProbe]"], literalArguments: [2]))
        source.perform(Bang(name: "setvariable", args: ["Probe", "(1+1)"], literalArguments: [1]))
        t.equal(source.variable("Probe"), "(1+1)", "public perform respects forwarded metadata")
        source.perform(Bang(name: "skin:setvariable", args: ["Other", "Probe", "(1+1)", "Extra"], literalArguments: [0, 2, 3]))
        t.equal(host.forwarded.last?.1, "Other", "extra arguments cannot replace the intended Config")
        t.equal(host.forwarded.last?.0, Bang(name: "setvariable", args: ["Probe", "(1+1)"], literalArguments: [1]))
        t.equal(peer.variable("Probe"), "(1+1)")
        source.execute(#"[!TextEdit:SetText Input """(1+1)""" Other]"#, from: nil)
        t.equal((peer.meter(named: "Input") as? TextEditMeter)?.inputText, "(1+1)")
        t.equal(host.forwarded.last?.0.literalArguments, [1])
    }

    t.suite("Command routing: implicit matching measure and explicit selectors") {
        let (skin, host) = try makeSkin(t, routingFixture)
        defer { skin.close() }
        func advance() { skin.update(); skin.update(); skin.update() }
        advance()
        let a = skin.measure(named: "LoopA")!
        let b = skin.measure(named: "LoopB")!
        skin.execute("[!Loop:Reset][!UpdateMeasure LoopA]", from: a)
        t.close(a.value, 1, "matching measure section supplies the omitted selector")
        t.close(b.value, 3)
        advance()
        let priorA = a.value
        skin.execute("[!Loop:Reset]", from: skin.measure(named: "MeasureProbe"))
        skin.execute("[!Loop:Reset]", from: nil)
        skin.execute("[!UpdateMeasure LoopA]", from: nil)
        t.close(a.value, priorA + 1, "mismatched sections and no section do not select a measure")
        skin.execute("[!Loop:Reset LoopB][!UpdateMeasure LoopB]", from: a)
        t.close(b.value, 1, "an explicit measure overrides the current section")
        advance()
        skin.execute("[!Loop:Reset Group=A&B][!UpdateMeasure LoopA][!UpdateMeasure LoopB]", from: a)
        t.close(a.value, 1)
        t.close(b.value, 5, "AND selects only the measure in both groups")
        skin.execute("[!Loop:Reset Group=A|B][!UpdateMeasure LoopA][!UpdateMeasure LoopB]", from: a)
        t.close(a.value, 1)
        t.close(b.value, 1)
        advance()
        skin.execute("[!Loop:Reset *][!UpdateMeasure LoopA][!UpdateMeasure LoopB]", from: a)
        t.close(a.value, 1)
        t.close(b.value, 1)
        t.check(host.forwarded.isEmpty, "measure selectors are not Config selectors")
        t.check(host.logs.contains { $0.contains("measure [] not found") })
        let (only, onlyHost) = try makeSkin(t, "[Only]\nMeasure=Loop\n")
        defer { only.close() }
        only.update(); only.update()
        only.execute("[!Loop:Reset][!UpdateMeasure Only]", from: nil)
        t.close(only.measure(named: "Only")?.value ?? -1, 3, "one measure alone is not an implicit target")
        t.check(onlyHost.logs.contains { $0.contains("measure [] not found") })
    }

    t.suite("Command routing: fixed payload omission and legacy plugin names") {
        let (skin, host) = try makeSkin(t, #"""
        [Timer]
        Measure=Plugin
        Plugin=Plugins\ActionTimer.dll
        ActionList1=Wait 10000
        [LegacyWindow]
        Measure=Plugin
        Plugin=Plugins\WindowMessagePlugin.dll
        [Other]
        Measure=Loop
        [Meter]
        Meter=String
        """#)
        defer { skin.close() }
        skin.update()
        let timer = skin.measure(named: "Timer") as? ActionTimerMeasure
        t.check(timer != nil)
        skin.execute("[!ActionTimer:Execute 1]", from: timer)
        t.equal(timer?.runningLists, [1], "one payload is retained after inserting the current measure")
        skin.execute("[!ActionTimer:Stop 1]", from: timer)
        t.equal(timer?.runningLists, [])
        skin.execute("[!ActionTimer:Execute 1]", from: skin.measure(named: "Other"))
        t.equal(timer?.runningLists, [], "a mismatched type cannot supply the selector")
        skin.execute("[!ActionTimer:Execute Timer 1]", from: skin.measure(named: "Other"))
        t.equal(timer?.runningLists, [1])
        skin.execute("[!ActionTimer:Stop Timer 1]", from: nil)
        t.equal(timer?.runningLists, [])
        let window = skin.measure(named: "LegacyWindow")
        t.equal(window?.type, "windowmessageplugin")
        skin.execute("[!WindowMessage:Send 1024 1 2]", from: window)
        t.check(host.logs.contains { $0.contains("WindowMessage [LegacyWindow]: \"SendMessage 1024 1 2\"") },
                "the documented legacy plugin alias matches and keeps all three payload arguments")
        skin.execute("[!WindowMessage:Send 1025 3 4]", from: skin.measure(named: "Other"))
        t.check(!host.logs.contains { $0.contains("SendMessage 1025 3 4") })
        skin.execute("[!WindowMessage:Send LegacyWindow 1026 5 6]", from: nil)
        t.check(host.logs.contains { $0.contains("SendMessage 1026 5 6") })
        skin.execute("[!ActionTimer:Execute]", from: timer)
        t.equal(timer?.runningLists, [], "an incomplete payload does not invent an ActionList")
    }

    t.suite("Command routing: new aliases do not bypass Studio action isolation") {
        let (skin, host) = try makeSkin(t, routingFixture)
        defer { skin.close() }
        let policy = StudioActionPolicy()
        skin.actionPolicy = policy
        skin.execute(#"[!Skin:Load Other Skin.ini][!Skin:Unload *][!Skin:Toggle Other][!Skin:Edit Other]"#, from: nil)
        skin.execute(#"[!Skin:SetVariable Other Probe external][!Skin:SetOption Other Meter Text external]"#, from: nil)
        skin.execute(#"[!Skin:Move Other 10 20][!RunCommand:Run]"#, from: nil)
        t.equal(policy.recorded.map(\.name), ["skin:load", "skin:unload", "skin:toggle", "skin:edit",
                                             "skin:setvariable", "skin:setoption", "skin:move", "runcommand:run"])
        t.check(host.handled.isEmpty)
        t.check(host.forwarded.isEmpty)
        t.check(host.executed.isEmpty)
        t.equal(skin.variable("Probe"), "initial")
        t.equal(skin.meter(named: "Meter")?.rawOption("Text"), "initial")
        skin.execute("[!SetVariable Probe local]", from: nil)
        t.equal(skin.variable("Probe"), "local", "existing local Studio actions still work")
    }
}
