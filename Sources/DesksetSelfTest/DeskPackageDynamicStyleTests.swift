import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private enum PackageDynamicStyleError: Error { case missing(String) }

private enum PackageDynamicStyleFixture {
    static func checked(_ widget: String, package: String) -> (CheckedFile, CheckedFile) {
        let shared = deskCheck(package, file: "package.desk")
        let member = deskCheck(widget, file: "Member.desk",
            context: CheckContext(package: CheckedPackage(file: shared)))
        return (member, shared)
    }

    static func compile(_ t: TestRunner, _ widget: String, package: String,
                        catalog: DeskCatalog = .current) throws -> DeskCompilationResult {
        let (member, shared) = checked(widget, package: package)
        t.check(shared.diagnostics(.error).isEmpty, deskDescribe(shared))
        t.check(member.diagnostics(.error).isEmpty, deskDescribe(member))
        let result = Desk.compile(member, catalog: catalog, package: shared)
        t.equal(result.diagnostics, member.diagnostics + shared.diagnostics)
        t.check(result.issues.isEmpty, "\(widget)\n\(result.issues)")
        guard result.program != nil else { throw PackageDynamicStyleError.missing("program") }
        return result
    }

    static func program(_ result: DeskCompilationResult) throws -> WidgetProgram {
        guard let program = result.program else { throw PackageDynamicStyleError.missing("program") }
        return program
    }

    static func reject(_ t: TestRunner, _ widget: String, package: String,
                       catalog: DeskCatalog = .current, checkedClean: Bool = true,
                       kind: DeskCompilationIssue.Kind? = nil) {
        let (member, shared) = checked(widget, package: package)
        if checkedClean {
            t.check(shared.diagnostics(.error).isEmpty, deskDescribe(shared))
            t.check(member.diagnostics(.error).isEmpty, deskDescribe(member))
        } else {
            t.check(!shared.diagnostics(.error).isEmpty || !member.diagnostics(.error).isEmpty,
                    "The real invalid source must fail semantic checking")
        }
        let result = Desk.compile(member, catalog: catalog, package: shared)
        t.check(result.program == nil && result.packageOptions == nil,
                "Invalid or unsupported package style must publish nothing: \(widget)")
        t.check(result.elementRefs.isEmpty && result.imageSources.isEmpty)
        t.check(!result.issues.isEmpty || result.diagnostics.contains { $0.severity == .error })
        t.equal(result.diagnostics, member.diagnostics + shared.diagnostics)
        if let kind { t.equal(result.issues.first?.kind, kind, "\(result.issues)") }
    }

    static func environment(_ dark: Bool = false) -> EnvironmentStamp {
        EnvironmentStamp(scale: 1, fontGeneration: 1,
            appearance: AppearanceStamp(value: dark ? .dark : .light, name: "package-dynamic-styles"),
            imageGeneration: 0)
    }

    static func date(_ seconds: Double = 0) -> ProgramDateInput {
        ProgramDateInput(instant: Date(timeIntervalSince1970: seconds),
                         timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US"))
    }

    static func measure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
        SkinSize(width: Double(text.utf16.count) * 5, height: TextStyle.pixelSize(points: style.fontSize))
    }

    static func texts(_ scene: WidgetScene) -> [TextDraw] {
        scene.drawingItems.compactMap { if case .text(let draw) = $0 { return draw }; return nil }
    }

    static func input(_ runtime: ProgramRuntime, _ edits: [String: ProgramOptionValue]) -> ProgramOptionsInput {
        ProgramOptionsInput(values: runtime.optionValues.values.merging(edits) { _, new in new })
    }
}

func runDeskPackageDynamicStyleTests(_ t: TestRunner) {
    typealias F = PackageDynamicStyleFixture

    t.suite("Desk: package dynamic styles: forged original receipts cannot be repaired by rechecking") {
        let source = #"options { size = Stepper("Size", min: 8pt, max: 40pt, default: 12pt) }; style live { .font(options.size).tooltip(cpu.usage) }"#
        let (member, shared) = F.checked(#"widget { Text("A").style(live).font(14).tooltip("Own") }"#, package: source)
        let (_, other) = F.checked(#"widget { Text("A").style(live) }"#, package: source)
        guard let read = shared.symbols.first(where: { if case .option = $0.value { return true }; return false })?.key,
              let otherOption = other.options["size"] else { throw PackageDynamicStyleError.missing("option receipt") }
        for mutation in 0..<5 {
            var symbols = shared.symbols
            if mutation == 0 { symbols.removeValue(forKey: read) }
            if mutation == 1 { symbols[read] = .option(otherOption.node, file: other.tree.file) }
            var bad = CheckedFile(tree: shared.tree, diagnostics: shared.diagnostics,
                symbols: symbols, types: shared.types, elements: shared.elements,
                dataUses: mutation == 4 ? [] : shared.dataUses, dependencies: shared.dependencies,
                reactions: shared.reactions, freeformOrders: shared.freeformOrders, stringTable: shared.stringTable,
                requirements: shared.requirements, options: shared.options, styles: shared.styles,
                translations: shared.translations, root: shared.root)
            bad.canonicalNumericValues = shared.canonicalNumericValues
            bad.numericCoercions = shared.numericCoercions
            if mutation == 2 { bad.canonicalNumericValues[read] = 12 }
            if mutation == 3 { bad.numericCoercions[read] = .percentAsFraction }
            let result = Desk.compile(member, package: bad)
            t.check(result.program == nil && result.packageOptions == nil)
            t.equal(result.issues.first?.kind, .invalidCheckedModel)
        }
    }

    t.suite("Desk: package dynamic styles: nested includes use member enum and style replacements") {
        let package = ##"""
            options { mode = Picker("Mode", [.day, .night], default: .day) }
            style base { .color("#FF0000") }
            style remote { .style(base, if: options.mode == .night) }
            """##
        for own in [false, true] {
            let prefix = own ? ##"options { mode = Picker("Local", [.night, .day], default: .night) }; style base { .color("#0000FF") }"## : ""
            let result = try F.compile(t, prefix + "\n" + #"widget { Text("A").style(remote) }"#, package: package)
            var runtime = try ProgramRuntime(program: F.program(result))
            let scene = try runtime.project(environment: F.environment(), measure: F.measure)
            t.equal(F.texts(scene).first?.style.color, own ? RGBA(r: 0, g: 0, b: 255) : SkinAppearance.light.labelColor)
            let next = try runtime.updateOptions(F.input(runtime, ["mode": .localCase(option: "mode", name: "night")]),
                expectedRevision: 0, environment: F.environment(), measure: F.measure)
            if !own { t.equal(next.flatMap { F.texts($0).first?.style.color }, RGBA(r: 255, g: 0, b: 0)) }
        }
    }

    t.suite("Desk: package dynamic styles: shared reads use effective member values across updates") {
        let package = ##"""
            package { name: "Shared" }
            options {
                size = Stepper("Size", min: 8pt, max: 40pt, default: 12pt)
                note = Input("Note", default: "Package")
                hide = Toggle("Hide")
                alert = Toggle("Alert")
            }
            style live {
                .font(options.size)
                .tooltip("Tip {options.note}", title: "Size {options.size}")
                .voiceOver("Speak {options.note}")
                .hidden(if: options.hide)
                .color("#FF0000", if: options.alert)
            }
            """##
        let widget = ##"widget { Text("A").size(80, 40).style(live).color("#0000FF") }"##
        let overrides = ##"""
            options {
                size = Stepper("Local size", min: 8pt, max: 40pt, default: 18pt)
                note = Input("Local note", default: "Member")
                alert = Toggle("Local alert", default: true)
            }
            """##
        for local in [false, true] {
            let result = try F.compile(t, (local ? overrides + "\n" : "") + widget, package: package)
            guard let schema = result.packageOptions else { throw PackageDynamicStyleError.missing("shared schema") }
            t.equal(schema.defaults.values["size"], .number(ProgramNumber(12, dimension: .length)))
            t.equal(schema.defaults.values["note"], .string("Package"))
            t.equal(schema.defaults.values["alert"], .boolean(false))
            var runtime = try ProgramRuntime(program: F.program(result))
            let first = try runtime.project(environment: F.environment(), measure: F.measure)
            t.equal(F.texts(first).map { TextStyle.pixelSize(points: $0.style.fontSize) }, [local ? 18 : 12])
            t.equal(F.texts(first).map { $0.style.color }, [local ? RGBA(r: 255, g: 0, b: 0) : RGBA(r: 0, g: 0, b: 255)])
            t.equal(first.elements.first?.accessibilityLabel, local ? "Speak Member" : "Speak Package")
            t.equal(first.hitMap.toolTipInfo(at: 1, 1, images: nil),
                    ToolTipInfo(text: local ? "Tip Member" : "Tip Package", title: local ? "Size 18" : "Size 12"))
            guard let updated = try runtime.updateOptions(F.input(runtime, [
                "size": .number(ProgramNumber(24, dimension: .length)), "note": .string("Changed"),
                "alert": .boolean(false)
            ]), expectedRevision: 0, environment: F.environment(), measure: F.measure) else {
                throw PackageDynamicStyleError.missing("effective update")
            }
            t.equal(F.texts(updated).map { TextStyle.pixelSize(points: $0.style.fontSize) }, [24])
            t.equal(F.texts(updated).map { $0.style.color }, [RGBA(r: 0, g: 0, b: 255)])
            t.equal(updated.elements.first?.accessibilityLabel, "Speak Changed")
            t.equal(updated.hitMap.toolTipInfo(at: 1, 1, images: nil), ToolTipInfo(text: "Tip Changed", title: "Size 24"))
            let hidden = try runtime.updateOptions(F.input(runtime, ["hide": .boolean(true)]),
                expectedRevision: 1, environment: F.environment(), measure: F.measure)
            t.equal(hidden?.size, first.size)
            t.equal(hidden?.elements.first?.visibility, .hiddenKeepsSpace)
            t.equal(hidden?.elements.first?.accessibilityLabel, nil)
            t.check(hidden?.drawingItems.isEmpty == true && hidden?.hitMap.entries.isEmpty == true)
            let restored = try runtime.updateOptions(F.input(runtime, ["hide": .boolean(false)]),
                expectedRevision: 2, environment: F.environment(), measure: F.measure)
            t.equal(restored?.elements.map(\.id), first.elements.map(\.id))
            t.equal(restored?.elements.first?.accessibilityLabel, "Speak Changed")
            t.equal(runtime.clockPrecision, nil)
            t.equal(schema.defaults.values["note"], .string("Package"), "Member updates never mutate package defaults")
        }
    }

    t.suite("Desk: package dynamic styles: system fonts labels visibility and clock demand remain live") {
        let package = ##"""
            style telemetry {
                .font(system.dark ? 18 : 12)
                .tooltip(cpu.usage, title: "{time.now, format: "HH:mm:ss"}")
                .voiceOver(battery.charging)
                .hidden(if: battery.charging)
            }
            """##
        var runtime = try ProgramRuntime(program: F.program(F.compile(t,
            ##"widget { Text("A").size(80, 40).style(telemetry) }"##, package: package)))
        t.equal(runtime.neededSystemProperties, [.cpuUsage, .batteryCharging])
        let first = try runtime.project(environment: F.environment(), dateInput: F.date(),
            systemInput: ProgramSystemInput(cpuUsage: 25, batteryCharging: false), measure: F.measure)
        t.equal(F.texts(first).map { TextStyle.pixelSize(points: $0.style.fontSize) }, [12])
        t.equal(first.elements.first?.accessibilityLabel, "No")
        t.equal(first.hitMap.toolTipInfo(at: 1, 1, images: nil), ToolTipInfo(text: "25", title: "00:00:00"))
        t.equal(runtime.clockPrecision, .second)
        let hidden = try runtime.project(environment: F.environment(true), dateInput: F.date(2),
            systemInput: ProgramSystemInput(cpuUsage: 50, batteryCharging: true), measure: F.measure)
        t.equal(hidden.size, first.size)
        t.equal(hidden.elements.first?.visibility, .hiddenKeepsSpace)
        t.equal(hidden.elements.first?.accessibilityLabel, nil)
        t.check(hidden.drawingItems.isEmpty && hidden.hitMap.entries.isEmpty)
        let restored = try runtime.project(environment: F.environment(true), dateInput: F.date(3),
            systemInput: ProgramSystemInput(cpuUsage: 75, batteryCharging: false), measure: F.measure)
        t.equal(F.texts(restored).map { TextStyle.pixelSize(points: $0.style.fontSize) }, [18])
        t.equal(restored.hitMap.toolTipInfo(at: 1, 1, images: nil), ToolTipInfo(text: "75", title: "00:00:03"))
        t.equal(restored.elements.map(\.id), first.elements.map(\.id))
    }

    t.suite("Desk: package dynamic styles: package translations fall back while member keys override") {
        let package = ##"""
            options { note = Input("Note", default: "Package") }
            style live {
                .tooltip("Tip {options.note}", title: "Title {options.note}")
                .voiceOver("Speak {options.note}")
            }
            translations { "zh-Hans" {
                "Tip {options.note}": "包提示 {options.note}"
                "Title {options.note}": "包标题 {options.note}"
                "Speak {options.note}": "包朗读 {options.note}"
            } }
            """##
        let widget = ##"""
            options { note = Input("Local", default: "Member") }
            widget { Text("A").size(100, 30).style(live) }
            """##
        let translations = ##"""
            translations { "zh-Hans" {
                "Tip {options.note}": "成员提示 {options.note}"
                "Speak {options.note}": "{options.note} 成员朗读"
            } }
            """##
        for own in [false, true] {
            let program = try F.program(F.compile(t, widget + (own ? "\n" + translations : ""), package: package))
            var runtime = try ProgramRuntime(program: program, language: "zh-Hans")
            let first = try runtime.project(environment: F.environment(), measure: F.measure)
            t.equal(first.hitMap.toolTipInfo(at: 1, 1, images: nil),
                    ToolTipInfo(text: own ? "成员提示 Member" : "包提示 Member", title: "包标题 Member"))
            t.equal(first.elements.first?.accessibilityLabel, own ? "Member 成员朗读" : "包朗读 Member")
            let next = try runtime.updateOptions(F.input(runtime, ["note": .string("Next")]),
                expectedRevision: 0, environment: F.environment(), measure: F.measure)
            t.equal(next?.hitMap.toolTipInfo(at: 1, 1, images: nil),
                    ToolTipInfo(text: own ? "成员提示 Next" : "包提示 Next", title: "包标题 Next"))
            t.equal(next?.elements.first?.accessibilityLabel, own ? "Next 成员朗读" : "包朗读 Next")
        }
    }

    t.suite("Desk: package dynamic styles: inactive and losing real sources are checked without live demand") {
        let package = ##"""
            style losing {
                .font(cpu.coreCount)
                .tooltip(cpu.usage, title: "{time.now, format: "HH:mm:ss"}")
                .voiceOver(battery.charging)
            }
            style inactive { .color("#FF0000", if: battery.charging) }
            """##
        let widget = ##"""
            widget { Text("A").size(80, 30).style(losing).style(inactive, if: false)
                .font(14).tooltip("Own", title: "Own title").voiceOver("Own label").color("#0000FF") }
            """##
        var runtime = try ProgramRuntime(program: F.program(F.compile(t, widget, package: package)))
        let scene = try runtime.project(environment: F.environment(), dateInput: F.date(),
            systemInput: ProgramSystemInput(cpuUsage: 90, cpuCoreCount: 32, batteryCharging: true), measure: F.measure)
        t.equal(F.texts(scene).map { TextStyle.pixelSize(points: $0.style.fontSize) }, [14])
        t.equal(F.texts(scene).map { $0.style.color }, [RGBA(r: 0, g: 0, b: 255)])
        t.equal(scene.elements.first?.accessibilityLabel, "Own label")
        t.equal(scene.hitMap.toolTipInfo(at: 1, 1, images: nil), ToolTipInfo(text: "Own", title: "Own title"))
        t.equal(runtime.clockPrecision, nil, "A losing tooltip never subscribes to its clock")
        t.check(!runtime.neededSystemProperties.contains(.cpuUsage) && !runtime.neededSystemProperties.contains(.cpuCoreCount))

        // These invalid references remain invalid even when an identically named member variable exists.
        for (modifier, element) in [
            (".font(secret)", ##"Text("A").style(remote).font(14)"##),
            (".tooltip(secret)", ##"Text("A").style(remote).tooltip("Own")"##),
            (".voiceOver(secret)", ##"Text("A").style(remote).voiceOver("Own")"##),
            (".color(\"#FF0000\", if: secret)", ##"Text("A").style(remote, if: false).color("#0000FF")"##),
            (".hidden(if: secret)", ##"Text("A").style(remote, if: false)"##)
        ] {
            F.reject(t, "widget { variable secret = true; \(element) }",
                     package: "style remote { \(modifier) }", checkedClean: false)
        }
        // Well-typed but unsupported leaves also cannot disappear behind a winner or false condition.
        F.reject(t, ##"widget { Text("A").style(remote).width(40) }"##,
                 package: "style remote { .width(system.dark ? 30 : 20) }", kind: .unsupported)
        F.reject(t, ##"widget { Text("A").style(remote, if: false).font(14) }"##,
                 package: "style remote { .font(system.dark ? 18 : 12) }", kind: .unsupported)
    }

    t.suite("Desk: package dynamic styles: repeated losers and inactive expressions share bounded budgets") {
        let package = "style remote { .font(system.dark ? 18 : 12).tooltip(cpu.usage) }"
        let small = ##"widget { Text("A").style(remote).font(14).tooltip("Own") }"##
        var catalog = DeskCatalog.current
        catalog.limits.maximumTokens = 128
        let admitted = try F.compile(t, small, package: package, catalog: catalog)
        var runtime = try ProgramRuntime(program: F.program(admitted))
        let scene = try runtime.project(environment: F.environment(), measure: F.measure)
        t.equal(F.texts(scene).map { TextStyle.pixelSize(points: $0.style.fontSize) }, [14])
        let repeated = ##"widget { Text("A")"## + String(repeating: ".style(remote)", count: 80) +
            ##".font(14).tooltip("Own") }"##
        _ = try F.compile(t, repeated, package: package)
        F.reject(t, repeated, package: package, catalog: catalog, kind: .resourceLimit)

        let nested = ##"style remote { .color("#FF0000", if: ((((system.dark))))) }"##
        let inactive = ##"widget { Text("A").style(remote, if: false).color("#0000FF") }"##
        _ = try F.compile(t, inactive, package: nested)
        catalog = .current
        catalog.limits.maximumExpressionNesting = 2
        F.reject(t, inactive, package: nested, catalog: catalog, kind: .resourceLimit)

        let long = ##"style remote { .tooltip("A very long losing tooltip {cpu.usage}") }"##
        _ = try F.compile(t, small, package: long)
        catalog = .current
        catalog.limits.maximumTextLength = 12
        F.reject(t, small, package: long, catalog: catalog, kind: .resourceLimit)
    }
}
