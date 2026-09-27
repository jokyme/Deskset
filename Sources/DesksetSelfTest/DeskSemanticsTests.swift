import Foundation
@testable import DeskLanguage

// Did-you-mean (§6.2), commands (§8.2), localization (§8.6) and the checker's speed (§0.4, §9.8).

/// A widget of about `lines` lines in the style of the examples: options, declarations, rows, grids, styles, events.
func deskLargeWidget(lines: Int) -> String {
    var text = """
    info { name: "Large", size: .large, permissions: [.music] }

    options {
        accent = ColorPicker("Accent", default: .accent)
        weekStart = Picker("Week starts on", [.sunday, .monday], default: .sunday)
        showSeconds = Toggle("Show seconds")
        threshold = Slider("Alert above", min: 50, max: 100)
    }

    widget {
        variable page = 0
        variable monthsFromNow = 0
        computed month = calendar.month(offset: monthsFromNow, weekStart: options.weekStart)
        computed hot = cpu.usage > options.threshold

        Column(spacing: 12) {

    """
    var block = 0
    while text.split(separator: "\n", omittingEmptySubsequences: false).count < lines - 12 {
        block += 1
        text += """
                Row {
                    Text("CPU \(block)").font(.caption).color(.dim)
                    Text("{cpu.usage}%")
                        .font(.largeNumber)
                        .color(.red, if: hot)
                        .hover { .color(options.accent) }
                    Spacer()
                    Icon("chevron.right").style(arrow).onClick { page = page + 1 }
                }
                Progress(memory.used).track(.faint).hidden(if: page > \(block % 5))
                Grid(columns: 7) {
                    for day in month.days {
                        Text("{day.number}")
                            .style(dateCell)
                            .style(todayCell, if: day.isToday)
                            .hidden(if: not day.inMonth)
                    }
                }
                Text("{music.title, missing: "Nothing playing"} · {time.now, format: "HH:mm"}")
                    .lines(1)
                    .onClick { monthsFromNow = monthsFromNow + 1 }

        """
    }
    text += """
        }
        .padding(18)
        .background(.glass)
    }

    style arrow     { .font(16).color(.dim).hover { .color(options.accent) } }
    style dateCell  { .font(13).size(28, 24) }
    style todayCell { .font(13, .semibold).color(.white).size(24).background(options.accent).rounded(.full) }

    """
    return text
}

func runDeskSemanticsTests(_ t: TestRunner) {
    t.suite("Desk: did-you-mean") {
        // Three wrong guesses per common name, each leading to the right name.
        let guesses: [(String, String)] = [
            (".textColor(.red)", ".color(.red)"), (".fontColor(.red)", ".color(.red)"), (".foregroundColor(.red)", ".color(.red)"),
            (".backgroundColor(.red)", ".background(.red)"), (".material(.red)", ".background(.red)"), (".bg(.red)", ".background(.red)"),
            (".cornerRadius(8)", ".rounded(8)"), (".borderRadius(8)", ".rounded(8)"), (".radius(8)", ".rounded(8)"),
            (".alpha(0.5)", ".opacity(0.5)"), (".transparency(0.5)", ".opacity(0.5)"), (".transparent(0.5)", ".opacity(0.5)"),
            (".fontSize(13)", ".font(13)"), (".fontFamily(13)", ".font(13)"), (".typeface(13)", ".font(13)"),
            (".onTap { log(\"x\") }", ".onClick { log(\"x\") }"), (".onPress { log(\"x\") }", ".onClick { log(\"x\") }"),
            (".onTapGesture { log(\"x\") }", ".onClick { log(\"x\") }"),
        ]
        for (wrong, right) in guesses {
            let text = "info { name: \"T\" }\nwidget { Text(\"A\")\(wrong) }"
            let checked = deskCheck(text)
            let fixed = checked.diagnostics.first?.fixIts.first.map { TextEdit.apply($0.edits, to: text) }
            t.equal(fixed, "info { name: \"T\" }\nwidget { Text(\"A\")\(right) }", "\(wrong) → \(right)")
        }
        // Data: synonyms and one level down.
        let data: [(String, String)] = [
            ("battery.percent", "battery.level"), ("battery.charge", "battery.level"), ("battery.Percent", "battery.level"),
            ("cpu.load", "cpu.usage"), ("cpu.utilization", "cpu.usage"), ("cpu.busy", "cpu.usage"),
            ("time.hour", "time.now.hour"), ("time.minute", "time.now.minute"), ("time.weekday", "time.now.weekday"),
        ]
        for (wrong, right) in data {
            let text = "info { name: \"T\" }\nwidget { Text(\"{\(wrong)}\") }"
            let checked = deskCheck(text)
            t.equal(checked.diagnostics.map(\.id.rawValue), ["DK3003"], wrong)
            let fixed = checked.diagnostics.first?.fixIts.first.map { TextEdit.apply($0.edits, to: text) }
            t.equal(fixed, "info { name: \"T\" }\nwidget { Text(\"{\(right)}\") }", "\(wrong) → \(right)")
        }
        let weather = "info { name: \"T\", permissions: [.location] }\nwidget { Text(\"{weather.temp}\") }"
        let checkedWeather = deskCheck(weather)
        let temp = checkedWeather.diagnostics.first { $0.id == .unknownMember }
        t.equal(temp?.message(in: .english), "`weather` has no `temp`. Did you mean `weather.now.temperature`?")
        // Components and controls.
        for (wrong, right) in [("ProgressBar", "Progress"), ("Bar", "Progress"), ("Txt", "Text")] {
            let text = "info { name: \"T\" }\nwidget { \(wrong)(cpu.usage) }"
            let checked = deskCheck(text)
            let fixed = checked.diagnostics.first?.fixIts.first.map { TextEdit.apply($0.edits, to: text) }
            t.check(fixed?.contains("\(right)(cpu.usage)") == true, "\(wrong) → \(right): \(checked.diagnostics.map(\.id.rawValue))")
        }
        let dropdown = deskCheck("info { name: \"T\" }\noptions { d = Dropdown(\"Day\", [.sunday, .monday]) }\nwidget { Text(\"{options.d}\") }")
        t.equal(dropdown.diagnostics.map(\.id.rawValue), ["DK8004"])
        t.equal(dropdown.diagnostics.first?.fixIts.first?.edits.first?.replacement, "Picker")
        // No fix-it at distance 2 in a display position; one at distance 1.
        let far = deskCheck("info { name: \"T\" }\nwidget { Text(\"{battery.lvel}\") }")
        t.equal(far.diagnostics.map(\.id.rawValue), ["DK3003"])
        t.equal(far.diagnostics.first?.fixIts.count, 1, "distance 1: fixed")
        let farther = deskCheck("info { name: \"T\" }\nwidget { Text(\"{battery.chrgng}\") }")
        t.equal(farther.diagnostics.first?.fixIts.count, 0, "distance 2 in text: no fix-it")
        t.check(farther.diagnostics.first?.message(in: .english).contains("battery.charging") == true, "but it is suggested")
        // A newer file: DK3023 before any suggestion.
        let newer = deskCheck("info { name: \"T\", requires: \"2.0\" }\nwidget { Text(\"{cpu.usag}\").fontSize(3) }")
        t.equal(newer.diagnostics.map(\.id.rawValue), ["DK3023", "DK3023"])
        // The distance itself.
        t.equal(DidYouMean.distance("colour", "color"), 1)
        t.equal(DidYouMean.distance("hte", "the"), 1, "a transposition is one step")
        t.equal(DidYouMean.distance("kitten", "sitting"), 3)
        t.equal(DidYouMean.suggest("colr", candidates: ["color", "cover", "clip"]).names.first, "color")
    }

    t.suite("Desk: commands") {
        func command(_ template: String, options: String) -> (CheckedFile, CommandFacts?) {
            let text = "info { name: \"T\", permissions: [.commands] }\noptions { \(options) }\nwidget { Text(\"A\").onClick { run(\"\(template)\") } }"
            let checked = deskCheck(text)
            return (checked, checked.requirements.commands.first)
        }
        let (plain, open) = command("open {options.target}", options: "target = Input(\"Target\", default: \"Safari\")")
        t.equal(plain.diagnostics.map(\.id.rawValue), [])
        t.equal(open?.script, "open \"${1}\"")
        t.equal(open?.placeholders, ["target"])
        t.equal(open?.knownValues["target"], ["\"Safari\""], "the install list shows the default")
        t.equal(command("ls --dir={options.folder}", options: "folder = Input(\"Folder\")").1?.script, "ls --dir=\"${1}\"")
        t.equal(command("say \\\"Hello {options.name}\\\"", options: "name = Input(\"Name\")").1?.script, "say \"Hello ${1}\"")
        let quoted = command("open '{options.target}'", options: "target = Input(\"Target\")").0
        t.equal(quoted.diagnostics.map(\.id.rawValue), ["DK8208"])
        let glued = command("cat '~/Notes/{options.name}.txt'", options: "name = Input(\"Name\")").0
        t.equal(glued.diagnostics.map(\.id.rawValue), ["DK8208"])
        let fixedGlued = glued.diagnostics.first?.fixIts.first.map { TextEdit.apply($0.edits, to: glued.tree.text) } ?? ""
        t.check(fixedGlued.contains("'~/Notes/'{options.name}'.txt'"), fixedGlued)
        for code in ["sh -c {options.x}", "osascript -e {options.x}", "eval {options.x}", "bash -c {options.x}"] {
            t.equal(command(code, options: "x = Input(\"X\")").0.diagnostics.map(\.id.rawValue), ["DK8209"], code)
        }
        t.equal(command("sh -c 'say \\\"$1\\\"' _ {options.x}", options: "x = Input(\"X\")").0.diagnostics.map(\.id.rawValue), [],
                "the value after the code is an argument")
        // Live data never reaches a command.
        t.equal(deskCheck("info { name: \"T\", permissions: [.commands, .music] }\nwidget { Text(\"A\").onClick { run(\"say {music.title}\") } }").diagnostics.map(\.id.rawValue), ["DK8202"])
        t.equal(deskCheck("info { name: \"T\", permissions: [.music] }\nwidget { Text(\"A\").onClick { open(\"https://example.com/?q={music.title}\") } }").diagnostics.map(\.id.rawValue), [],
                "a click may open it with data; the user sees it")
        // Hostile values arrive as one literal argument each.
        let (_, echo) = command("printf \\\"[%s]\\\" {options.a} {options.b}", options: "a = Input(\"A\"); b = Input(\"B\")")
        let script = echo?.script ?? ""
        t.equal(script, "printf \"[%s]\" \"${1}\" \"${2}\"")
        let values = ["; echo INJECTED", "$(echo INJECTED)", "`echo INJECTED`", "a \"quoted\" 'value'", "line\nbreak", "Bob's Music"]
        for value in values {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", script, "deskset", value, "x"]
            let pipe = Pipe()
            process.standardOutput = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                t.equal(output, "[\(value)][x]", "the value arrives as written: \(value.debugDescription)")
            } catch {
                t.check(false, "zsh: \(error)")
            }
        }
    }

    t.suite("Desk: localization") {
        // Translatable literals by data flow.
        let text = """
        info { name: "Player", description: "What's playing.", permissions: [.music] }
        options { big = Toggle("Big text") }
        widget {
            variable status = "Idle"
            Column {
                Text(music.playing ? "Playing" : "Paused")
                Text(music.title.ifMissing("Nothing playing"))
                Text("{music.artist, missing: "Unknown artist"}")
                Image(music.cover.ifMissing("cover.png"))
                Text(status).onClick { log("clicked"); status = "Busy" }
                Button("Next").onClick { music.next() }.tooltip("Next track")
            }
            .hidden(if: options.big)
        }
        """
        let checked = deskCheck(text)
        t.equal(checked.diagnostics.map(\.id.rawValue), [])
        let keys = Set(checked.stringTable.map(\.key))
        for key in ["Player", "What's playing.", "Big text", "Playing", "Paused", "Nothing playing",
                    "{music.artist, missing: \"Unknown artist\"}", "Unknown artist", "Next", "Next track"] {
            t.check(keys.contains(key), "translated: \(key) in \(keys.sorted())")
        }
        for key in ["cover.png", "clicked", "Idle", "Busy"] { t.check(!keys.contains(key), "not translated: \(key)") }
        // Keys by token sequence: formatting never changes a key.
        let a = deskCheck("info { name: \"T\" }\nwidget { Text(\"{ cpu.usage }% used\") }")
        let b = deskCheck("info { name: \"T\" }\nwidget { Text(\"{cpu.usage}% used\") }")
        t.equal(a.stringTable.map(\.key), b.stringTable.map(\.key))
        t.equal(b.stringTable.map(\.key), ["T", "{cpu.usage}% used"])
        let notX = deskCheck("info { name: \"T\" }\nwidget {\n    variable x = true\n    variable notx = true\n    Text(\"{not x}\").hidden(if: notx)\n}")
        t.equal(notX.stringTable.map(\.key), ["T", "{not x}"])
        // A translation that moves its placeholder.
        let moved = deskCheck("info { name: \"T\" }\nwidget { Text(\"{cpu.usage}% used\") }\ntranslations {\n    \"zh-Hans\" { \"{ cpu.usage }% used\": \"已用 {cpu.usage}%\" }\n}")
        t.equal(moved.diagnostics.map(\.id.rawValue), [])
        t.equal(moved.translations.languages["zh-Hans"]?["{cpu.usage}% used"], "\"已用 {cpu.usage}%\"")
        // Tags: one per case of §8.6.
        let tags: [(String, [String], String?)] = [
            ("zh-Hans", ["zh-Hans-CN"], "zh-Hans"), ("zh-CN", ["zh-Hans-CN"], "zh-CN"), ("zh-SG", ["zh-Hans-SG"], "zh-SG"),
            ("zh-TW", ["zh-Hant-TW"], "zh-TW"), ("zh-HK", ["zh-Hant-HK"], "zh-HK"), ("zh-MO", ["zh-Hant-MO"], "zh-MO"),
            ("zh_CN", ["zh-Hans-CN"], "zh_CN"), ("zh-Hans-CN", ["zh-Hans"], "zh-Hans-CN"), ("de-DE", ["de-AT"], "de-DE"),
            ("zh-Hant", ["zh-Hans-CN"], nil), ("ja", ["de-DE"], nil), ("pt-BR", ["pt-PT"], "pt-BR"),
        ]
        for (tag, preferred, expected) in tags {
            t.equal(DeskLocalization.displayLanguage(available: [tag], preferred: preferred), expected, "\(tag) on \(preferred)")
        }
        t.equal(DeskLocalization.normalize("zh-CN"), "zh-Hans")
        t.equal(DeskLocalization.normalize("zh_TW"), "zh-Hant")
        t.equal(DeskLocalization.normalize("zh-HK"), "zh-Hant-HK")
        t.equal(DeskLocalization.normalize("sr-RS"), "sr-Cyrl-RS")
        t.equal(DeskLocalization.normalize("pt-BR"), "pt-BR")
        t.equal(deskIDs(of: "widget { Text(\"A\") }\ntranslations {\n    \"zh-CN\" { \"A\": \"甲\" }\n    \"zh-Hans\" { \"A\": \"甲\" }\n}"),
                ["DK8406", "DK8405"])
        t.equal(deskIDs(of: "widget { Text(\"A\") }\ntranslations {\n    \"pt-BR\" { \"A\": \"a\" }\n}"), [])
    }

    t.suite("Desk: checker performance") {
        let text = deskLargeWidget(lines: 2_000)
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let firstTree = Desk.parse(text, fileName: "Large.desk")
        let first = Desk.check(firstTree)
        t.equal(first.diagnostics.filter { $0.severity == .error }.map(\.id.rawValue), [], "the large widget checks without errors")
        func best(_ runs: Int, _ body: () -> Void) -> Double {
            var fastest = Double.infinity
            for _ in 0..<runs {
                let start = ProcessInfo.processInfo.systemUptime
                body()
                fastest = min(fastest, ProcessInfo.processInfo.systemUptime - start)
            }
            return fastest * 1000
        }
        var tree = firstTree
        let parse = best(5) { tree = Desk.parse(text, fileName: "Large.desk") }
        let check = best(5) { _ = Desk.check(tree) }
        let both = best(5) { _ = Desk.check(Desk.parse(text, fileName: "Large.desk")) }
        #if DEBUG
        let build = "debug"
        let factor = 10.0
        #else
        let build = "release"
        let factor = 1.0
        #endif
        let perThousand = both / Double(lineCount) * 1000
        print(String(format: "    Desk checker, %@ build, %d lines: parse %.1f ms, check %.1f ms, parse + check %.1f ms "
                     + "(%.1f ms per 1,000 lines; budget %.0f ms per 1,000 lines for lex, parse and check)",
                     build as NSString, lineCount, parse, check, both, perThousand, 25 * factor))
        print(String(format: "    The editor re-checks 0.3 s after typing stops: parse + check takes %.0f%% of that pause.",
                     both / 300 * 100))
        // A one-character edit of a 300-line widget, the editor's case (§9.8: 10 ms end to end in release).
        let small = deskLargeWidget(lines: 300)
        let edited = small.replacingOccurrences(of: "CPU 1\"", with: "CPU 1!\"")
        let recheck = best(5) { _ = Desk.check(Desk.parse(edited, fileName: "Small.desk")) }
        print(String(format: "    Re-check after a one-character edit of a 300-line widget: %.1f ms (budget %.0f ms).",
                     recheck, 10 * factor))
        // Not a benchmark on CI: only a bound that keeps the editor responsive.
        t.check(both < 300 * factor / 2, String(format: "parse + check of %d lines took %.0f ms", lineCount, both))
    }
}

func runDeskSemanticEditTests(_ t: TestRunner) {
    t.suite("Desk: edits — setModifier and rename") {
        func element(_ checked: CheckedFile, _ component: String) -> NodeID? {
            checked.elements.first { $0.value.component == component }?.key
        }
        // Inline chain: inserted by sort key.
        let inline = deskCheck("info { name: \"T\" }\nwidget { Text(\"A\").font(.caption).padding(4) }")
        let color = Desk.apply(.setModifier(element(inline, "Text")!, name: "color", argumentsText: ".dim", condition: nil), to: inline)
        t.equal(color.tree.text, "info { name: \"T\" }\nwidget { Text(\"A\").font(.caption).color(.dim).padding(4) }")
        // Replacing the arguments of the same modifier; a conditional one is separate.
        let replaced = Desk.apply(.setModifier(element(inline, "Text")!, name: "font", argumentsText: ".headline", condition: nil), to: inline)
        t.equal(replaced.tree.text, "info { name: \"T\" }\nwidget { Text(\"A\").font(.headline).padding(4) }")
        let conditional = Desk.apply(.setModifier(element(inline, "Text")!, name: "font", argumentsText: ".title", condition: "cpu.usage > 80"), to: inline)
        t.equal(conditional.tree.text, "info { name: \"T\" }\nwidget { Text(\"A\").font(.caption).font(.title, if: cpu.usage > 80).padding(4) }")
        // A multi-line chain: on its own line, at the chain's indentation.
        let lines = deskCheck("info { name: \"T\" }\nwidget {\n    Text(\"A\")\n        .font(.caption)\n        .padding(4)\n}")
        let added = Desk.apply(.setModifier(element(lines, "Text")!, name: "background", argumentsText: ".glass", condition: nil), to: lines)
        t.equal(added.tree.text, "info { name: \"T\" }\nwidget {\n    Text(\"A\")\n        .font(.caption)\n        .padding(4)\n        .background(.glass)\n}")
        t.equal(Desk.check(added.tree).diagnostics.map(\.id.rawValue), [])
        // A stale reference is refused.
        let stale = Desk.apply(.setModifier(element(inline, "Text")!, name: "bold", argumentsText: "", condition: nil), to: deskCheck(inline.tree.text))
        t.equal(stale.failure, .staleReference)
        // Rename: the declaration and every use, not a field of the same spelling nor text.
        let source = "info { name: \"T\" }\nwidget {\n    variable title = 0\n    computed month = calendar.month()\n    Text(\"{title} title {month.title}\").onClick { title = title + 1 }\n}"
        let file = deskCheck(source)
        let decl = file.symbols.values.compactMap { symbol -> NodeID? in
            if case .declaration(let id) = symbol, file.tree.resolve(id).map({ DeclarationSyntax(unchecked: $0).name.token.text }) == "title" { return id }
            return nil
        }.first!
        let renamed = Desk.apply(.rename(decl, to: "count"), to: file)
        t.equal(renamed.tree.text, "info { name: \"T\" }\nwidget {\n    variable count = 0\n    computed month = calendar.month()\n    Text(\"{count} title {month.title}\").onClick { count = count + 1 }\n}")
        t.equal(Desk.apply(.rename(decl, to: "if"), to: file).failure, .notApplicable("if is not an own name"))
        // Styles and options.
        let styled = deskCheck("info { name: \"T\" }\noptions { accent = ColorPicker(\"Accent\") }\nwidget { Text(\"A\").style(card).color(options.accent) }\nstyle card { .bold() }")
        let card = styled.styles["card"]!
        t.equal(Desk.apply(.rename(card, to: "panel"), to: styled).tree.text,
                "info { name: \"T\" }\noptions { accent = ColorPicker(\"Accent\") }\nwidget { Text(\"A\").style(panel).color(options.accent) }\nstyle panel { .bold() }")
        let accent = styled.options["accent"]!.node
        t.equal(Desk.apply(.rename(accent, to: "tint"), to: styled).tree.text,
                "info { name: \"T\" }\noptions { tint = ColorPicker(\"Accent\") }\nwidget { Text(\"A\").style(card).color(options.tint) }\nstyle card { .bold() }")
    }
}

/// Problems the checker has with one input: a crash is a crash; otherwise sorted, deterministic, renderable
/// diagnostics whose ranges and fix-its lie inside the file, within the time budget (§9.3).
func deskCheckFuzzProblems(_ text: String) -> (problems: [String], elapsed: Double) {
    #if DEBUG
    let budget = 1.0
    #else
    let budget = 0.1
    #endif
    func timed() -> (CheckedFile, Double) {
        let start = ProcessInfo.processInfo.systemUptime
        let checked = Desk.check(Desk.parse(text, fileName: "F.desk"))
        return (checked, ProcessInfo.processInfo.systemUptime - start)
    }
    let (checked, first) = timed()
    let elapsed = first > budget ? min(first, timed().1) : first
    var problems: [String] = []
    let length = text.utf8.count
    let keys = checked.diagnostics.map { ($0.file.path, $0.range.lowerBound) }
    if !zip(keys, keys.dropFirst()).allSatisfy({ $0.0 < $0.1 || ($0.0 == $0.1) || ($0.0.0 == $0.1.0 && $0.0.1 <= $0.1.1) }) {
        problems.append("diagnostics not sorted")
    }
    for d in checked.diagnostics {
        if d.range.lowerBound < 0 || d.range.upperBound > length { problems.append("\(d.id.rawValue) outside the file") }
        for f in d.fixIts {
            for e in f.edits where e.range.lowerBound < 0 || e.range.upperBound > length || e.range.lowerBound > e.range.upperBound {
                problems.append("\(d.id.rawValue) fix-it outside the file")
            }
            _ = f.title(in: .english)
        }
        if d.message(in: .english).isEmpty || d.message(in: .simplifiedChinese).isEmpty { problems.append("\(d.id.rawValue) empty message") }
    }
    let again = Desk.check(Desk.parse(text, fileName: "F.desk"))
    if again.diagnostics.map(\.description) != checked.diagnostics.map(\.description) { problems.append("not deterministic") }
    if elapsed > budget { problems.append("took \(elapsed) s") }
    return (problems, elapsed)
}

func runDeskCheckerFuzzTests(_ t: TestRunner) {
    t.suite("Desk: checker fuzz") {
        // DESK_CHECK_FUZZ_COUNT inputs (default 2,000), seeded like the syntax fuzz (DESK_FUZZ_SEED, the CI run number).
        let environment = ProcessInfo.processInfo.environment
        let seed = UInt64(environment["DESK_FUZZ_SEED"] ?? environment["GITHUB_RUN_NUMBER"] ?? "") ?? 7
        let count = Int(environment["DESK_CHECK_FUZZ_COUNT"] ?? "") ?? 2_000
        var random = DeskRandom(seed: seed)
        let corpus = deskFixtureTexts().map(\.1) + deskExampleCorpus().filter { $0.count > 40 }
            + DeskCatalog.current.documentedItems().map { DeskExampleHarness(catalog: .current).build($0.doc.example, context: $0.doc.exampleContext).text }
        let pieces = ["{", "}", "(", ")", "[", "]", "\"", "“", ".", ",", ";", ":", "=", "==", "if", "else", "for", "in",
                      "Text", "variable", "computed", "saved", "widget", "style", "options", "info", "\n", " ", "#", "\\",
                      "&&", "!", "?", "...", "12px", "2 s", "5min", "50%", "2GB", "°F", ".font(", ".style(", ".name(",
                      "options.", "event.", "cpu.", "music.", "Picker(\"A\", [.a, .b])", "show(", ".onClick {", ".hover {",
                      "not ", " and ", " or ", "Freeform {", ".position(x: ", "title.right", "\"{", "}\"", "{{", "#Name#"]
        var slowest = 0.0
        var failures = 0
        for n in 0..<count {
            var chars = Array(random.pick(corpus).unicodeScalars)
            for _ in 0..<(1 + random.int(6)) where !chars.isEmpty {
                let at = random.int(chars.count)
                switch random.int(5) {
                case 0: chars.removeSubrange(at..<min(chars.count, at + 1 + random.int(12)))
                case 1: chars.insert(contentsOf: Array(random.pick(pieces).unicodeScalars), at: at)
                case 2:
                    let end = min(chars.count, at + 1 + random.int(40))
                    chars.insert(contentsOf: chars[at..<end], at: at)
                case 3: chars.swapAt(at, random.int(chars.count))
                default:
                    if chars[at] == "{" { chars[at] = "}" } else if chars[at] == "}" { chars[at] = "{" } else { chars[at] = "(" }
                }
            }
            let text = String(String.UnicodeScalarView(chars))
            if let dump = environment["DESK_FUZZ_DUMP"] {
                FileManager.default.createFile(atPath: dump + "/check-current.txt", contents: Data(text.utf8))
            }
            let (problems, elapsed) = deskCheckFuzzProblems(text)
            slowest = max(slowest, elapsed)
            if !problems.isEmpty {
                failures += 1
                if failures <= 3 { t.check(false, "seed \(seed) input \(n): \(problems)\n\(text.debugDescription.prefix(600))") }
            }
        }
        t.equal(failures, 0, "checker fuzz failures (seed \(seed))")
        print(String(format: "    checker fuzz: %d inputs, slowest parse + check %.1f ms (seed %llu)", count, slowest * 1000, seed))
    }

    t.suite("Desk: checker fuzz — pathological input") {
        let cases: [(String, String)] = [
            ("deep blocks", "widget {\n" + String(repeating: "Column {\n", count: 200) + String(repeating: "}\n", count: 200) + "}"),
            ("deep expressions", "widget { Text(\"{" + String(repeating: "(", count: 300) + "1" + String(repeating: ")", count: 300) + "}\") }"),
            ("long sums", "widget { Text(\"{" + String(repeating: "cpu.usage + ", count: 3_000) + "1}\") }"),
            ("many modifiers", "widget { Text(\"A\")" + String(repeating: ".color(.red)", count: 3_000) + " }"),
            ("many elements", "widget { Column {\n" + String(repeating: "Text(\"{cpu.usage}\").font(13).name(x)\n", count: 3_000) + "} }"),
            ("style chains", (0..<500).map { "style s\($0) { .style(s\($0 + 1)) }" }.joined(separator: "\n") + "\nstyle s500 { .style(s0) }\nwidget { Text(\"A\").style(s0) }"),
            ("computed chains", "widget {\n" + (0..<800).map { "    computed c\($0) = c\($0 + 1) + 1" }.joined(separator: "\n") + "\n    computed c800 = c0\n    Text(\"{c0}\")\n}"),
            ("ternaries", "widget { Text(\"{" + String(repeating: "cpu.usage > 5 ? 1 : ", count: 400) + "2}\") }"),
            ("nested fors", "widget { Column {" + String(repeating: " for a in 1...3 {", count: 60) + " Text(\"A\")" + String(repeating: " }", count: 60) + " } }"),
            ("overloads", "widget { Text(\"A\")" + String(repeating: ".font(.headline).font(13, .bold).font(\"Futura\", 13)", count: 400) + " }"),
        ]
        for (name, text) in cases {
            let start = ProcessInfo.processInfo.systemUptime
            let checked = Desk.check(Desk.parse(text, fileName: "P.desk"))
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            t.check(elapsed < 10, "\(name): check took \(elapsed) s")
            t.check(!checked.diagnostics.isEmpty || name == "nested fors", "\(name): diagnostics")
        }
    }
}
