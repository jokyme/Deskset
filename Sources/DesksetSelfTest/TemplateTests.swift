import Foundation
@testable import DesksetCore

func runTemplateTests(_ t: TestRunner) {
    t.suite("Template: original callbacks: failed candidates reopen delimiters and successful ones consume them") {
        var calls: [String] = []
        let resolver = VariableResolver(variableLookup: { name in
            calls.append("variable:\(name)")
            switch name {
            case "A": return "one"
            case "Held$Pointer$": return "kept"
            default: return nil
            }
        }, eventLookup: { name in
            calls.append("event:\(name)")
            return name == "Pointer" ? "7" : nil
        })
        let cases: [(String, String, [String])] = [
            ("pre #Missing#A#", "pre #Missingone", ["variable:Missing", "variable:A"]),
            ("##A#", "#one", ["variable:A"]),
            ("#Outer$Pointer$#", "#Outer7#", ["variable:Outer$Pointer$", "event:Pointer"]),
            ("#Held$Pointer$#", "kept", ["variable:Held$Pointer$"]),
            ("$Missing$Pointer$", "$Missing7", ["event:Missing", "event:Pointer"]),
            ("#*A*#", "#A#", []),
            ("plain é #unfinished", "plain é #unfinished", []),
        ]
        for (input, expected, expectedCalls) in cases {
            calls = []
            t.equal(Array(resolver.resolve(input).utf8), Array(expected.utf8), input)
            t.equal(calls, expectedCalls, input)
        }
        calls = []
        t.equal(resolver.resolveStandardVariables("#Outer$Pointer$#"), "#Outer$Pointer$#")
        t.equal(calls, ["variable:Outer$Pointer$"])
    }

    t.suite("Template: original callbacks: generated sections follow nesting and literal results stay frozen") {
        var calls: [String] = []
        let resolver = VariableResolver(variableLookup: { name in
            calls.append("variable:\(name)")
            switch name {
            case "Made": return "[M]"
            case "Fmt": return "2"
            case "@": return "/x/#A#[M]/"
            default: return nil
            }
        }, sectionLookup: { name, parameter in
            if parameter == .number(SectionNumberFormat(decimals: 2)) {
                calls.append("section:\(name):2")
                return "12.00"
            }
            calls.append("section:\(name):plain")
            return "12"
        }, eventLookup: { name in
            calls.append("event:\(name)")
            return "#A#[M]"
        })
        t.equal(resolver.resolve("#Made#|[&M:[#Fmt]]"), "12|12.00")
        t.equal(calls, ["variable:Made", "variable:Fmt", "section:M:2", "section:M:plain"])
        calls = []
        t.equal(resolver.resolve("#@#"), "/x/#A#[M]/")
        t.equal(resolver.resolve("$Pointer$"), "#A#[M]")
        t.equal(resolver.resolve(#"[\x23]A[\x23]"#), "#A#")
        t.equal(resolver.resolve("#*A*#"), "#A#")
        t.equal(calls, ["variable:@", "event:Pointer"])
    }

    t.suite("Template: original callbacks: option read and action evaluation observe different current values") {
        var value = "old"
        var section = "first"
        var event = "0"
        var calls: [String] = []
        let resolver = VariableResolver(variableLookup: { name in
            calls.append("variable:\(name)")
            return name == "A" ? value : nil
        }, sectionLookup: { name, _ in
            calls.append("section:\(name)")
            return section
        }, eventLookup: { name in
            calls.append("event:\(name)")
            return event
        })
        let read = resolver.resolveStandardVariables("#A#|#*A*#|[#A]|[M]|$Pointer$")
        t.equal(read, "old|#*A*#|[#A]|[M]|$Pointer$")
        t.equal(calls, ["variable:A"])
        value = "new"
        section = "second"
        event = "9"
        calls = []
        t.equal(resolver.resolve(read), "old|#A#|new|second|9")
        t.equal(calls, ["event:Pointer", "variable:A", "section:M"])
    }

    t.suite("Template: original callbacks: synchronous reentry keeps independent expansion state") {
        var resolver: VariableResolver?
        // This fixture calls the same resolver through its callback; break the local test-only capture cycle.
        defer { resolver = nil }
        var entered = false
        var tail = "before"
        var nested: String?
        var calls: [String] = []
        resolver = VariableResolver(variableLookup: { name in
            calls.append(name)
            if name == "Tail" { return tail }
            guard name == "Outer" else { return nil }
            if entered { return "inner" }
            entered = true
            nested = resolver?.resolve("#Outer#|#Tail#")
            tail = "after"
            return "#Tail#"
        })
        t.equal(resolver?.resolve("#Outer#|#Tail#"), "after|after")
        t.equal(nested, "inner|before")
        t.equal(calls, ["Outer", "Outer", "Tail", "Tail", "Tail"])
        calls = []
        t.equal(resolver?.resolve("#Outer#|#Tail#"), "inner|after")
        t.equal(calls, ["Outer", "Tail"])
    }
}

func runCompiledTemplateTests(_ t: TestRunner) {
    t.suite("Template: input routes: candidate consumption and event modes preserve literal output and callbacks") {
        let input = "#Missing#Made#|#Held$P$#|$Missing$P$|#*A*#|$unfinished"
        let template = Template(input)
        for compiled in [false, true] {
            var calls: [String] = []
            var resolver = VariableResolver(variableLookup: { name in
                calls.append("variable:\(name)")
                switch name {
                case "Made": return "[M]"
                case "Held$P$": return "kept"
                case "A": return "one"
                default: return nil
                }
            }, sectionLookup: { name, _ in
                calls.append("section:\(name)")
                return name == "M" ? "section" : nil
            }, eventLookup: { name in
                calls.append("event:\(name)")
                return name == "P" ? "7" : nil
            })
            let full = compiled ? resolver.resolve(template) : resolver.resolve(input)
            t.equal(full, "#Missingsection|kept|$Missing7|#A#|$unfinished")
            t.equal(calls, ["variable:Missing", "variable:Made", "variable:Held$P$", "event:Missing", "event:P", "section:M"])
            calls = []
            let standard = compiled ? resolver.resolveStandardVariables(template) : resolver.resolveStandardVariables(input)
            t.equal(standard, "#Missing[M]|kept|$Missing$P$|#*A*#|$unfinished")
            t.equal(calls, ["variable:Missing", "variable:Made", "variable:Held$P$"])
            calls = []
            resolver.eventLookup = nil
            let noEvents = compiled ? resolver.resolve(template) : resolver.resolve(input)
            t.equal(noEvents, "#Missingsection|kept|$Missing$P$|#A#|$unfinished")
            t.equal(calls, ["variable:Missing", "variable:Made", "variable:Held$P$", "section:M"])
        }
    }

    t.suite("Template: compiled input: one source is reusable across current lookups and modes") {
        let template = Template("#A#|[M]|$Pointer$")
        var value = "old"
        var calls: [String] = []
        var resolver = VariableResolver(variableLookup: { name in
            calls.append("variable:\(name)")
            return name == "A" ? value : nil
        }, sectionLookup: { name, _ in
            calls.append("section:\(name)")
            return "section"
        }, eventLookup: { name in
            calls.append("event:\(name)")
            return "7"
        })
        t.equal(resolver.resolve(template), "old|section|7")
        t.equal(calls, ["variable:A", "event:Pointer", "section:M"])
        value = "new"
        resolver.sectionLookup = nil
        resolver.eventLookup = nil
        calls = []
        t.equal(resolver.resolve(template), "new|[M]|$Pointer$")
        t.equal(calls, ["variable:A"])
        calls = []
        t.equal(resolver.resolveStandardVariables(template), "new|[M]|$Pointer$")
        t.equal(calls, ["variable:A"])

        let overlapping = Template("#Missing#A#")
        calls = []
        t.equal(resolver.resolve(overlapping), "#Missingnew")
        t.equal(calls, ["variable:Missing", "variable:A"])
        let cycle = Template("#Loop#|#A#")
        let cyclicResolver = VariableResolver(variableLookup: { $0 == "Loop" ? "#Loop#" : value })
        t.equal(cyclicResolver.resolve(cycle), "#Loop#|new")
        value = "later"
        t.equal(cyclicResolver.resolve(cycle), "#Loop#|later")

        // String equality is canonically equivalent; template input/output must still retain original UTF-8.
        for input in ["é|#A#", "e\u{301}|#A#", "\u{0}😀|#A#"] {
            let compiled = Template(input)
            let expected = input.replacingOccurrences(of: "#A#", with: "later")
            t.equal(Array(resolver.resolve(compiled).utf8), Array(expected.utf8))
        }
        value = "4"
        let formulaText = resolver.resolve(Template("(#A# * 2)"))
        t.equal(formulaText, "(4 * 2)", "variable templates still produce text before the option/formula reader")
        t.equal(OptionValue.number(formulaText), 8)
    }

    t.suite("Template: compiled input: reentry is independent and lookup owners are released") {
        let template = Template("#A#|[M]|$Pointer$")
        weak var retired: TemplateLookupOwner?
        do {
            let owner = TemplateLookupOwner("old")
            retired = owner
            let resolver = VariableResolver(variableLookup: { _ in owner.value },
                                            sectionLookup: { _, _ in owner.value },
                                            eventLookup: { _ in owner.value })
            t.equal(resolver.resolve(template), "old|old|old")
        }
        t.check(retired == nil, "compiled source and completed expansion do not retain lookup closures")
        let replacement = VariableResolver(variableLookup: { _ in "new" }, sectionLookup: { _, _ in "next" })
        t.equal(replacement.resolve(template), "new|next|$Pointer$")

        let reentrant = Template("#Outer#|#Tail#")
        var resolver: VariableResolver?
        defer { resolver = nil }
        var entered = false
        var tail = "before"
        var nested: String?
        var calls: [String] = []
        resolver = VariableResolver(variableLookup: { name in
            calls.append(name)
            if name == "Tail" { return tail }
            guard name == "Outer" else { return nil }
            if entered { return "inner" }
            entered = true
            nested = resolver?.resolve(reentrant)
            tail = "after"
            return "#Tail#"
        })
        t.equal(resolver?.resolve(reentrant), "after|after")
        t.equal(nested, "inner|before")
        t.equal(calls, ["Outer", "Outer", "Tail", "Tail", "Tail"])
    }
}

private final class TemplateLookupOwner {
    let value: String
    init(_ value: String) { self.value = value }
}
