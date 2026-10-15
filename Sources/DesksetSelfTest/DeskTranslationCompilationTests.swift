import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private enum TranslationFixtureError: Error { case program, receipt }

private func translationProgram(_ t: TestRunner, _ source: String, catalog: DeskCatalog = .current,
                                package: CheckedFile? = nil) throws -> (CheckedFile, WidgetProgram) {
    let checked = deskCheck(source, context: CheckContext(catalog: catalog))
    let result = Desk.compile(checked, catalog: catalog, package: package)
    t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
    t.check(result.issues.isEmpty, "\(source)\n\(result.issues)")
    guard let program = result.program else { throw TranslationFixtureError.program }
    return (checked, program)
}

private func translationEnvironment(_ dark: Bool = false) -> EnvironmentStamp {
    EnvironmentStamp(scale: 1, fontGeneration: 1,
        appearance: AppearanceStamp(value: dark ? .dark : .light, name: "translation"), imageGeneration: 0)
}

private func translationDate(_ locale: String = "en_US") -> ProgramDateInput {
    ProgramDateInput(instant: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!,
                     locale: Locale(identifier: locale))
}

private func translationMeasure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
    SkinSize(width: 100, height: 20)
}

private func translationTexts(_ scene: WidgetScene) -> [String] {
    scene.drawingItems.compactMap { item in if case .text(let draw) = item { return draw.text }; return nil }
}

private func translationFacts(_ checked: CheckedFile, strings: [StringEntry]? = nil,
                              translations: TranslationTable? = nil) -> CheckedFile {
    var result = CheckedFile(tree: checked.tree, diagnostics: checked.diagnostics,
        symbols: checked.symbols, types: checked.types, elements: checked.elements, dataUses: checked.dataUses,
        dependencies: checked.dependencies, reactions: checked.reactions, freeformOrders: checked.freeformOrders,
        stringTable: strings ?? checked.stringTable, requirements: checked.requirements,
        options: checked.options, styles: checked.styles, translations: translations ?? checked.translations, root: checked.root)
    result.loopIdentities = checked.loopIdentities; result.assets = checked.assets
    result.declarationTypes = checked.declarationTypes; result.canonicalNumericValues = checked.canonicalNumericValues
    result.numericCoercions = checked.numericCoercions
    return result
}

func runDeskTranslationCompilationTests(_ t: TestRunner) {
    let point = SkinPoint(x: 1, y: 1)

    t.suite("Desk: translations: literal display fields and own names share canonical keys with source fallback") {
        let source = #"""
            info { name: "Title" }
            widget { Text("Hello").size(100, 20).voiceOver("Label").tooltip("Body", title: "Heading").menu {
                Item("Item"); Menu("More") { Item("Nested") }
            } }
            translations { "zh-CN" {
                "Title": "标题"; "Hello": "你好"; "Label": "标签"; "Body": "说明"; "Heading": "标题行"
                "Item": "菜单项"; "More": "更多"; "Nested": "子菜单项"
            } }
            """#
        let (checked, program) = try translationProgram(t, source)
        t.equal(program.name, "Title"); t.equal(program.nameKey, "Title")
        t.equal(program.translations.languages.keys.sorted(), ["zh-Hans"])
        let result = Desk.compile(checked)
        t.equal(result.diagnostics, checked.diagnostics)
        t.check(checked.diagnostics.contains { $0.id == .regionLanguageTag })
        for language in [nil, "de", "zh-Hans"] as [String?] {
            var runtime = try ProgramRuntime(program: program, language: language)
            let translated = language == "zh-Hans"
            let scene = try runtime.project(environment: translationEnvironment(), dateInput: translationDate(), measure: translationMeasure)
            t.equal(runtime.displayName, translated ? "标题" : "Title")
            t.equal(translationTexts(scene), [translated ? "你好" : "Hello"])
            t.equal(scene.elements.first?.accessibilityLabel, translated ? "标签" : "Label")
            t.equal(scene.hitMap.toolTipInfo(at: 1, 1, images: nil),
                    ToolTipInfo(text: translated ? "说明" : "Body", title: translated ? "标题行" : "Heading"))
            let menu = try runtime.resolveMenu(program.root.id, expectedGeneration: scene.generation,
                environment: translationEnvironment(), dateInput: translationDate())
            guard let menu, case .item(_, let title, _, _) = menu.items[0],
                  case .submenu(let submenuTitle, let children) = menu.items[1],
                  case .item(_, let nested, _, _) = children[0] else { throw TranslationFixtureError.receipt }
            t.equal(title, translated ? "菜单项" : "Item"); t.equal(submenuTitle, translated ? "更多" : "More")
            t.equal(nested, translated ? "子菜单项" : "Nested")
        }
        let plain = try translationProgram(t, #"widget { Text("Hello").tooltip("Body") }"#).1
        guard case .text(let text) = plain.root.content else { throw TranslationFixtureError.receipt }
        t.equal(text.value, .string("Hello")); t.equal(plain.root.tooltip?.text, .string("Body"))
        t.equal(plain.translations, ProgramTranslations()); t.check(plain.nameKey == nil)
        let emptyLanguage = try translationProgram(t, "widget { Text(\"Hello\") }\ntranslations { \"ja\" { } }").1
        t.equal(emptyLanguage.translations.languages, ["ja": [:]])
        t.check(emptyLanguage.translations.source.isEmpty)
    }

    t.suite("Desk: translations: placeholders reorder original formats with duplicate occurrences and UTF16 numeric spans") {
        let source = #"""
            widget { Text("😀 { cpu.usage, decimals: 1 } / {time.now, format: "HH:mm:ss"} / {cpu.usage, decimals: 1}") }
            translations { "zh-Hans" {
                "😀 {cpu.usage, decimals: 1} / {time.now, format: "HH:mm:ss"} / {cpu.usage, decimals: 1}":
                    "时间 {time.now, format: "HH:mm:ss"}，😀 {cpu.usage, decimals: 1} 与 {cpu.usage, decimals: 1}"
            } }
            """#
        let (checked, program) = try translationProgram(t, source)
        let key = checked.stringTable.first!.key
        t.equal(program.translations.languages["zh-Hans"]?[key],
            [.text("时间 "), .placeholder(1), .text("，😀 "), .placeholder(0), .text(" 与 "), .placeholder(2)])
        guard case .text(let text) = program.root.content, case .localized(let loweredKey, let values) = text.value else {
            throw TranslationFixtureError.receipt
        }
        t.equal(loweredKey, key); t.equal(values.count, 3)
        for language in [nil, "zh-Hans"] as [String?] {
            var runtime = try ProgramRuntime(program: program, language: language)
            let scene = try runtime.project(environment: translationEnvironment(), dateInput: translationDate(),
                systemInput: ProgramSystemInput(cpuUsage: 25.5), measure: translationMeasure)
            let expected = language == nil ? "😀 25.5 / 00:00:00 / 25.5" : "时间 00:00:00，😀 25.5 与 25.5"
            t.equal(translationTexts(scene), [expected]); t.equal(runtime.clockPrecision, .second)
            guard case .text(let draw)? = scene.drawingItems.first else { throw TranslationFixtureError.receipt }
            let spans = draw.style.inlineSpans
            let numbers = (expected as NSString).range(of: "25.5")
            t.check(spans.contains { $0.location == numbers.location && $0.length == numbers.length })
            t.equal(spans.filter { $0.length == 4 }.count, 2)
        }
        let escaped = try translationProgram(t, #"""
            widget { Text("Line\n{{😀}}") }
            translations { "zh-Hans" { "Line\n{{😀}}": "行\n{{😀}}" } }
            """#).1
        var runtime = try ProgramRuntime(program: escaped, language: "zh-Hans")
        t.equal(translationTexts(try runtime.project(environment: translationEnvironment(), measure: translationMeasure)), ["行\n{😀}"])
        t.check(escaped.translations.source["Line\\n{{😀}}"] != nil, "keys retain escapes while pattern text is cooked")
    }

    t.suite("Desk: translations: conditional parentheses and numeric missing words retain captured scalar formatting") {
        let source = #"""
            widget { Text((battery.charging ? "Charging" : "Idle")).size(100, 20)
                .tooltip("{cpu.usage, decimals: 1, missing: "Unavailable"}", title: "Status")
                .voiceOver("Label").onClick { copy("Charging") } }
            translations { "zh-Hans" {
                "Charging": "充电中"; "Idle": "空闲"; "Unavailable": "不可用"; "Status": "状态"; "Label": "标签"
                "{cpu.usage, decimals: 1, missing: "Unavailable"}": "用量 {cpu.usage, decimals: 1, missing: "Unavailable"}"
            } }
            """#
        let program = try translationProgram(t, source).1
        var runtime = try ProgramRuntime(program: program, language: "zh-Hans")
        for (charging, value, expected) in [(true, Optional<Double>.none, "用量 不可用"), (false, 25.5, "用量 25.5")] {
            let input = ProgramSystemInput(cpuUsage: value, batteryCharging: charging)
            let scene = try runtime.project(environment: translationEnvironment(), dateInput: translationDate(), systemInput: input, measure: translationMeasure)
            t.equal(translationTexts(scene), [charging ? "充电中" : "空闲"])
            t.equal(scene.hitMap.toolTipInfo(at: 1, 1, images: nil)?.text, expected)
            let clicked = try runtime.clickWithEffects(at: point, expectedGeneration: scene.generation,
                environment: translationEnvironment(), dateInput: translationDate(), systemInput: input, measure: translationMeasure)
            t.equal(clicked?.effects, [.copy("Charging")], "copy displays values without translating authored words")
        }
        let fallback = try translationProgram(t, #"""
            widget { Text("Present".ifMissing("Fallback")) }
            translations { "zh-Hans" { "Present": "存在"; "Fallback": "回退" } }
            """#).1
        var fallbackRuntime = try ProgramRuntime(program: fallback, language: "zh-Hans")
        t.equal(translationTexts(try fallbackRuntime.project(environment: translationEnvironment(), measure: translationMeasure)), ["存在"])
    }

    t.suite("Desk: translations: stored values resource names comparisons and user effects never use display tables") {
        let source = #"""
            widget { variable state = "Idle"; Column(spacing: 0) {
                Text(state).size(100, 20).onClick { copy("Idle"); open("https://example.com") }
                Icon("wifi"); Text(state == "Idle" ? "Shown" : "Other")
            } }
            translations { "zh-Hans" {
                "Idle": "空闲"; "wifi": "网络"; "https://example.com": "https://invalid.example"
                "Shown": "显示"; "Other": "其它"
            } }
            """#
        let (checked, program) = try translationProgram(t, source)
        t.check(!checked.stringTable.contains { $0.key == "Idle" || $0.key == "wifi" || $0.key == "https://example.com" })
        t.check(program.translations.source["Idle"] == nil && program.translations.source["wifi"] == nil)
        var requests: [String] = []
        var runtime = try ProgramRuntime(program: program, language: "zh-Hans")
        let scene = try runtime.project(environment: translationEnvironment(), dateInput: translationDate(),
            measureIcon: { request in requests.append(request.name); return SkinSize(width: 12, height: 12) }, measure: translationMeasure)
        t.equal(translationTexts(scene), ["Idle", "显示"]); t.equal(requests, ["wifi"])
        let clicked = try runtime.clickWithEffects(at: point, expectedGeneration: scene.generation,
            environment: translationEnvironment(), dateInput: translationDate(),
            measureIcon: { _ in SkinSize(width: 12, height: 12) }, measure: translationMeasure)
        t.equal(clicked?.effects, [.copy("Idle"), .open("https://example.com")])
        let raw = try translationProgram(t, #"""
            widget { Text(#"Raw"#) }
            translations { "zh-Hans" { "Raw": "原始" } }
            """#).1
        var rawRuntime = try ProgramRuntime(program: raw, language: "zh-Hans")
        t.equal(translationTexts(try rawRuntime.project(environment: translationEnvironment(), measure: translationMeasure)), ["Raw"])
        t.check(raw.translations.source.isEmpty, "raw strings keep the current checker's unmarked-literal behavior")
    }

    t.suite("Desk: translations: package entries merge through the same compiler entry and widget entries win") {
        let folder = CheckedDeskPackage(package: deskMemoryPackage([
            "package.desk": #"""
                package { name: "Shared" }
                translations { "zh-CN" { "Greeting": "共享问候"; "Title": "共享标题" }; "ja" { "Greeting": "挨拶" } }
                """#,
            "A.desk": #"""
                info { name: "Title" }
                widget { Text("Greeting") }
                translations { "zh-Hans" { "Greeting": "自己的问候" } }
                """#,
            "B.desk": "info { name: \"Title\" }\nwidget { Text(\"Greeting\") }"
        ]))
        guard let packageID = folder.packageFile, let package = folder.files[packageID] else { throw TranslationFixtureError.receipt }
        let locales = DeskPackageLocales(folder)
        for (file, expected) in [("A.desk", "自己的问候"), ("B.desk", "共享问候")] {
            let id = DeskFileID(file)
            guard let checked = folder.files[id] else { throw TranslationFixtureError.receipt }
            let result = Desk.compile(checked, package: package)
            t.check(result.issues.isEmpty, "\(result.issues)")
            guard let program = result.program else { throw TranslationFixtureError.program }
            let language = DeskLocalization.displayLanguage(available: program.translations.languages.keys.sorted(), preferred: ["zh_CN"])
            t.equal(language, locales.displayLanguage(of: id, preferred: ["zh_CN"]))
            var runtime = try ProgramRuntime(program: program, language: language)
            t.equal(runtime.displayName, "共享标题")
            t.equal(translationTexts(try runtime.project(environment: translationEnvironment(), measure: translationMeasure)), [expected])
            var japanese = try ProgramRuntime(program: program, language: "ja")
            t.equal(japanese.displayName, "Title")
            t.equal(translationTexts(try japanese.project(environment: translationEnvironment(), measure: translationMeasure)), ["挨拶"])
        }
        let standalone = try translationProgram(t, "widget { Text(\"Greeting\") }").1
        t.equal(standalone.translations, ProgramTranslations())
        let invalidPackage = deskCheck(#"translations { "zh-Hans" { "Greeting": "Hello" }; "zh-CN" { "Greeting": "Other" } }"#, file: "package.desk")
        t.check(invalidPackage.diagnostics.contains { $0.id == .duplicateLanguage && $0.severity == .error })
        t.check(!invalidPackage.diagnostics(.error).isEmpty)
        let checked = deskCheck(#"widget { Text("Greeting") }"#)
        let denied = Desk.compile(checked, package: invalidPackage)
        t.check(denied.program == nil && denied.elementRefs.isEmpty)
        t.equal(denied.diagnostics, checked.diagnostics + invalidPackage.diagnostics)
        t.equal(Desk.compile(checked, package: checked).issues.first?.kind, .invalidCheckedModel)
        let unknownPackage = deskCheck(#"translations { "unknown-QQ" { "Greeting": "Hello" } }"#, file: "package.desk")
        t.check(unknownPackage.diagnostics(.error).isEmpty)
        t.check(unknownPackage.diagnostics.contains { $0.id == .unknownLanguage && $0.severity == .warning })
        let warning = Desk.compile(checked, package: unknownPackage)
        t.equal(warning.diagnostics, checked.diagnostics + unknownPackage.diagnostics)
        t.check(warning.issues.isEmpty)
        guard let warningProgram = warning.program else { throw TranslationFixtureError.program }
        var warningRuntime = try ProgramRuntime(program: warningProgram)
        t.equal(translationTexts(try warningRuntime.project(environment: translationEnvironment(), measure: translationMeasure)), ["Greeting"])
    }

    t.suite("Desk: translations: forged tables keys ranges tree versions and catalog roles reject publication") {
        let source = "widget { Text(\"Hello\") }\ntranslations { \"zh-Hans\" { \"Hello\": \"你好\" } }"
        let (checked, _) = try translationProgram(t, source)
        func rejected(_ value: CheckedFile, catalog: DeskCatalog = .current) {
            let result = Desk.compile(value, catalog: catalog)
            t.check(result.program == nil && result.elementRefs.isEmpty && result.imageSources.isEmpty)
            t.check(!result.issues.isEmpty, "\(result.issues)")
        }
        var table = checked.translations; table.languages["zh-Hans"]?["Hello"] = "\"Other\""
        rejected(translationFacts(checked, translations: table))
        table = checked.translations; table.languages["de"] = ["Hello": "\"Hallo\""]
        rejected(translationFacts(checked, translations: table))
        var entries = checked.stringTable; entries[0].key = "Other"; rejected(translationFacts(checked, strings: entries))
        entries = checked.stringTable; entries[0].range = 0..<0; rejected(translationFacts(checked, strings: entries))
        entries = checked.stringTable; entries[0].translatable = false; rejected(translationFacts(checked, strings: entries))
        rejected(translationFacts(checked, strings: []))
        let fresh = deskCheck(source); rejected(translationFacts(fresh, strings: checked.stringTable))
        let stored = deskCheck("widget { variable state = \"Hello\"; Text(state) }\ntranslations { \"zh-Hans\" { \"Hello\": \"你好\" } }")
        guard let declaration = stored.tree.rootNode.childNodes.first(where: { $0.kind == .widgetBlock })?.firstChild(.block)?.childNodes.first,
              let syntax = DeclarationSyntax(declaration), let literal = StringLiteralSyntax(syntax.initializer.node) else {
            throw TranslationFixtureError.receipt
        }
        rejected(translationFacts(stored, strings: [StringEntry(range: literal.node.textRange, node: stored.tree.id(of: literal.node), key: "Hello", translatable: true)]))
        let storedReceipt = StringEntry(range: literal.node.textRange, node: stored.tree.id(of: literal.node), key: "Hello", translatable: false)
        let storedResult = Desk.compile(translationFacts(stored, strings: [storedReceipt]))
        t.check(storedResult.program != nil && storedResult.issues.isEmpty)
        t.check(storedResult.program?.translations.source.isEmpty == true)
        var catalog = DeskCatalog.current
        guard let index = catalog.components.firstIndex(where: { $0.name == "Text" }) else { throw TranslationFixtureError.receipt }
        catalog.components[index].signatures[0].params[0].translatable = false
        rejected(checked, catalog: catalog)
    }

    t.suite("Desk: translations: all authored patterns are guarded and existing formatting limits stay explicit") {
        for source in [
            "widget { Text(\"{cpu.usage}\") }\ntranslations { \"zh-Hans\" { \"{cpu.usage}\": \"{battery.level}\" } }",
            "widget { Text(\"Hello\") }\ntranslations { \"zh-Hans\" { \"Unused {cpu.usage}\": \"No data\" } }",
            "widget { Text(\"Hello\") }\ntranslations { \"zh-Hans\" { \"Hello\": 42 } }"
        ] {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(result.program == nil && result.elementRefs.isEmpty, source)
            t.check(!checked.diagnostics(.error).isEmpty || result.issues.first?.kind == .invalidCheckedModel, "\(deskDescribe(checked))\n\(result.issues)")
        }
        for source in [#"widget { Text("{time.now, format: .relative}") }"#,
                       #"widget { Text("{time.now, missing: "Unavailable"}") }"#,
                       #"widget { Text("{battery.timeRemaining, decimals: 1}") }"#] {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            t.check(result.program == nil); t.equal(result.issues.first?.kind, .unsupported)
        }
        let (checked, _) = try translationProgram(t, "widget { Text(\"Hello\") }\ntranslations { \"zh-Hans\" { \"Hello\": \"你好\" } }")
        var catalog = DeskCatalog.current; catalog.limits.maximumTextLength = 3
        t.equal(Desk.compile(checked, catalog: catalog).issues.first?.kind, .resourceLimit)
        catalog = .current; catalog.limits.maximumTokens = 2
        t.equal(Desk.compile(checked, catalog: catalog).issues.first?.kind, .resourceLimit)
    }
}
