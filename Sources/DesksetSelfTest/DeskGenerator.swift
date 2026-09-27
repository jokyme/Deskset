import Foundation

/// Generates random valid Desk files from the grammar (§9.3 "grammar-based generation"): every production, several
/// layouts (one line or several, modifiers inline or on their own lines), comments and blank lines.
struct DeskGenerator {
    var random: DeskRandom
    var depth = 0
    var counter = 0

    init(seed: UInt64) { random = DeskRandom(seed: seed) }

    static let components = ["Text", "Label", "Icon", "Image", "Progress", "Gauge", "Graph", "Rectangle", "Circle",
                             "Capsule", "Button", "Toggle", "Slider", "Input"]
    static let containers = ["Column", "Row", "Grid", "Freeform", "Scroll"]
    static let modifiers = ["font", "color", "padding", "background", "rounded", "opacity", "offset", "size", "width",
                            "hidden", "style", "tooltip", "shadow", "border", "align", "lines", "digits", "scale"]
    static let events = ["onClick", "onDoubleClick", "onMouseEnter", "every", "when", "onLoad"]
    static let names = ["cpu", "memory", "disk", "battery", "time", "music", "weather", "page", "count", "day", "item",
                        "options", "month", "network", "volume"]
    static let members = ["usage", "used", "free", "level", "now", "title", "number", "isToday", "inMonth", "next",
                          "highlight", "weekStart", "days", "hour"]
    static let cases = ["caption", "dim", "glass", "left", "right", "center", "small", "red", "accent", "fill", "fit",
                        "headline", "sunday", "monday", "bold", "semibold"]
    static let units = ["", "", "", "%", "s", "ms", "min", "pt", "GB", "MB/s", "°C", "°", "h", "rpm", "km/h"]

    mutating func name() -> String { random.pick(DeskGenerator.names) }

    mutating func ownName() -> String {
        counter += 1
        return "v\(counter)"
    }

    mutating func pad(_ level: Int) -> String { String(repeating: " ", count: level * 4) }

    // MARK: Expressions

    mutating func number() -> String {
        let whole = String(random.int(500))
        let fraction = random.chance(20) ? "." + String(random.int(100)) : ""
        return whole + fraction + random.pick(DeskGenerator.units)
    }

    mutating func string() -> String {
        var parts: [String] = []
        for _ in 0..<(1 + random.int(3)) {
            switch random.int(5) {
            case 0: parts.append("{" + path() + "}")
            case 1: parts.append("{" + path() + ", decimals: " + String(random.int(3)) + "}")
            case 2: parts.append("{" + path() + ", format: \"HH:mm\"}")
            case 3: parts.append("{{x}} \\n \\\" \\u{1F600}")
            default: parts.append(random.pick(["CPU", "Month View", "已用", "Hello, world", "a % b"]))
            }
        }
        return "\"" + parts.joined(separator: " ") + "\""
    }

    mutating func path() -> String {
        var p = name()
        for _ in 0..<random.int(3) { p += "." + random.pick(DeskGenerator.members) }
        return p
    }

    mutating func primary() -> String {
        switch random.int(9) {
        case 0: return number()
        case 1: return string()
        case 2: return random.pick(["true", "false"])
        case 3: return "." + random.pick(DeskGenerator.cases)
        case 4: return path()
        case 5: return path() + "(" + arguments(max: 2) + ")"
        case 6: return "[" + (0..<(1 + random.int(3))).map { _ in "." + random.pick(DeskGenerator.cases) }.joined(separator: ", ") + "]"
        case 7: return ##"#"^\d{3}$"#"##
        default: return "(" + expression() + ")"
        }
    }

    mutating func expression() -> String {
        depth += 1
        defer { depth -= 1 }
        if depth > 3 { return primary() }
        switch random.int(10) {
        case 0: return primary() + " + " + primary()
        case 1: return primary() + " * " + primary()
        case 2: return path() + " > " + number()
        case 3: return "not " + path()
        case 4: return "(" + path() + " > 1 and " + path() + ") or " + path()
        case 5: return path() + " ? ." + random.pick(DeskGenerator.cases) + " : ." + random.pick(DeskGenerator.cases)
        case 6: return "1..." + String(1 + random.int(12))
        case 7: return "-" + primary()
        case 8: return path() + ".ifMissing(" + string() + ")"
        default: return primary()
        }
    }

    mutating func arguments(max: Int) -> String {
        let count = random.int(max + 1)
        var parts: [String] = []
        for k in 0..<count {
            if k > 0 && random.chance(50) {
                parts.append(random.pick(["if", "align", "spacing", "total", "default", "offset"]) + ": " + expression())
            } else {
                parts.append(expression())
            }
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Statements

    mutating func modifier() -> String {
        let name = random.pick(DeskGenerator.modifiers)
        if random.chance(10) { return ".hover { ." + random.pick(DeskGenerator.modifiers) + "(" + expression() + ") }" }
        if name == "style" { return ".style(" + ownName() + (random.chance(30) ? ", if: " + path() : "") + ")" }
        return "." + name + "(" + arguments(max: 2) + ")"
    }

    mutating func actions(_ level: Int) -> [String] {
        var lines: [String] = []
        for _ in 0..<(1 + random.int(3)) {
            switch random.int(5) {
            case 0: lines.append(pad(level) + path() + " = " + expression())
            case 1: lines.append(pad(level) + path() + "(" + arguments(max: 2) + ")")
            case 2: lines.append(pad(level) + "if " + path() + " > 1 { " + path() + " = 0 } else { " + path() + " = 1 }")
            case 3: lines.append(pad(level) + "for i in 1...3 { log(\"{i}\") }")
            default: lines.append(pad(level) + "after(1s) { hide(" + ownName() + ") }")
            }
        }
        return lines
    }

    mutating func eventModifier(_ level: Int) -> [String] {
        let event = random.pick(DeskGenerator.events)
        let head = "." + event + (event == "every" ? "(1s)" : event == "when" ? "(" + path() + " > 5)" : "")
        if random.chance(50) {
            let inline = actions(0).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "; ")
            return [head + " { " + inline + " }"]
        }
        return [head + " {"] + actions(level + 1) + [pad(level) + "}"]
    }

    /// A view statement's lines at `level`.
    mutating func view(_ level: Int) -> [String] {
        depth += 1
        defer { depth -= 1 }
        let roll = random.int(10)
        if depth < 4 && roll < 3 {
            // A container with children.
            let container = random.pick(DeskGenerator.containers)
            let head = container + (container == "Grid" ? "(columns: \(1 + random.int(7)))" : random.chance(50) ? "(spacing: \(random.int(20)))" : "")
            var lines = [pad(level) + head + " {"]
            if random.chance(20) { lines.append(pad(level + 1) + "// " + random.pick(["note", "说明", "TODO"])) }
            for _ in 0..<(1 + random.int(3)) { lines += view(level + 1) }
            lines.append(pad(level) + "}")
            for _ in 0..<random.int(3) { lines.append(pad(level) + modifier()) }
            return lines
        }
        if depth < 4 && roll == 3 {
            var lines = [pad(level) + "if " + expression() + " {"]
            lines += view(level + 1)
            if random.chance(50) {
                lines.append(pad(level) + "} else {")
                lines += view(level + 1)
            }
            lines.append(pad(level) + "}")
            return lines
        }
        if depth < 4 && roll == 4 {
            var lines = [pad(level) + "for " + ownName() + " in " + path() + " {"]
            lines += view(level + 1)
            lines.append(pad(level) + "}")
            return lines
        }
        let component = random.pick(DeskGenerator.components)
        var head = pad(level) + component + "(" + arguments(max: 2) + ")"
        var lines: [String] = []
        if random.chance(50) {
            for _ in 0..<random.int(3) { head += modifier() }
            if random.chance(20) { head += " // end" }
            lines.append(head)
        } else {
            lines.append(head)
            for _ in 0..<(1 + random.int(3)) { lines.append(pad(level + 1) + modifier()) }
            if random.chance(40) {
                var event = eventModifier(level + 1)
                event[0] = pad(level + 1) + event[0]
                lines += event
            }
        }
        return lines
    }

    mutating func file() -> String {
        var blocks: [String] = []
        if random.chance(70) {
            if random.chance(50) {
                blocks.append("info { name: " + string() + ", size: .small }")
            } else {
                blocks.append("info {\n    name: \"Generated\"\n    description: \"A generated widget.\"\n    category: .time\n    deskVersion: 1\n}")
            }
        }
        if random.chance(50) {
            var lines = ["options {"]
            for _ in 0..<(1 + random.int(3)) {
                lines.append("    " + ownName() + " = " + random.pick(["Toggle(\"Show\")", "Picker(\"Day\", [.sunday, .monday], default: .sunday)",
                                                                   "Slider(\"Size\", min: 1, max: 10)", "ColorPicker(\"Color\", default: .accent)"])
                             + (random.chance(30) ? "\n        .help(\"More\")" : ""))
            }
            if random.chance(30) {
                lines.append("    Section(\"More\") {")
                lines.append("        " + ownName() + " = Input(\"City\", default: \"Oslo\")")
                lines.append("    }")
            }
            lines.append("}")
            blocks.append(lines.joined(separator: "\n"))
        }
        var widget = ["widget {"]
        for _ in 0..<random.int(3) {
            widget.append("    " + random.pick(["variable", "saved", "computed"]) + " " + ownName() + " = " + expression())
        }
        if widget.count > 1 { widget.append("") }
        for _ in 0..<(1 + random.int(3)) { widget += view(1) }
        widget.append("}")
        blocks.append(widget.joined(separator: "\n"))
        for _ in 0..<random.int(3) {
            blocks.append("style " + ownName() + " { " + modifier() + modifier() + " }")
        }
        if random.chance(30) {
            blocks.append("translations {\n    \"zh-Hans\" {\n        \"CPU\": \"处理器\"\n        \"Month View\": \"月历\"\n    }\n}")
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }
}
