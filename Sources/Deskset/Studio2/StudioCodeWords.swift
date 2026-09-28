import AppKit
import DesksetCore

/// The code pane's sentences for the INI diagnostics, in the Studio's words: what is wrong in INI terms, what the widget
/// does meanwhile, and which parts it touches ("The 3 bars don’t draw.").
enum StudioCodeWords {
    /// What a group of parts is called: "bars", "numbers", "parts" when they are of different kinds.
    static func noun(for meters: [Meter], plural: Bool) -> String {
        let kinds = Set(meters.map(kind))
        let k = kinds.count == 1 ? kinds.first! : "part"
        return StudioText[key(k, plural: plural)]
    }

    /// The kind of part a meter is, as the sentences name it.
    static func kind(_ m: Meter) -> String {
        switch m.type {
        case "string":
            let shows = m.rawOption("MeasureName").map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
            return shows ? "number" : "text"
        case "bar": return "bar"
        case "image", "bitmap": return "picture"
        case "line", "histogram": return "graph"
        case "roundline": return "ring"
        case "rotator": return "hand"
        case "button": return "button"
        case "shape": return "shape"
        default: return "part"
        }
    }

    private static func key(_ kind: String, plural: Bool) -> StudioText.Key {
        switch kind {
        case "bar": return plural ? .nounBars : .nounBar
        case "number": return plural ? .nounNumbers : .nounNumber
        case "text": return plural ? .nounTexts : .nounText
        case "picture": return plural ? .nounPictures : .nounPicture
        case "graph": return plural ? .nounGraphs : .nounGraph
        case "ring": return plural ? .nounRings : .nounRing
        case "hand": return plural ? .nounHands : .nounHand
        case "button": return plural ? .nounButtons : .nounButton
        case "shape": return plural ? .nounShapes : .nounShape
        default: return plural ? .nounParts : .nounPart
        }
    }

    /// A color's everyday name when it has a common one (the defaults: black, white).
    static func colorName(_ value: String?) -> String {
        guard let value, let c = OptionValue.color(value) else { return StudioText[.diagColor] }
        if c.r == 0, c.g == 0, c.b == 0 { return StudioText[.diagBlack] }
        if c.r == 255, c.g == 255, c.b == 255 { return StudioText[.diagWhite] }
        return StudioText[.diagColor]
    }

    /// The whole sentence under the line.
    static func message(_ d: IniDiagnostic, skin: Skin?, partTitle: (Meter) -> String) -> String {
        let meters = d.meters.compactMap { skin?.meter(named: $0) }
        var parts: [String] = []
        switch d.kind {
        case .unknownKey(let key, let type, let suggestion):
            let isMeter = EditorSchema.meterTypes.contains { $0.caseInsensitiveCompare(type) == .orderedSame }
            parts.append(StudioText.format(isMeter ? .diagUnknownMeterKey : .diagUnknownMeasureKey, key, type, suggestion))
            parts.append(meanwhile(key: suggestion, defaultValue: d.defaultValue, meters: meters))
        case .badColor(let key, let value):
            parts.append(StudioText.format(.diagBadColor, "\(key)=\(value)"))
            parts.append(meanwhile(key: key, defaultValue: d.defaultValue, meters: meters))
        case .badFormula(let key, let value, let reason):
            parts.append(StudioText.format(.diagBadFormula, "\(key)=\(value)", reasonText(reason)))
            parts.append(cantDraw(meters, partTitle: partTitle))
        case .missingMeasure(let name):
            parts.append(StudioText.format(.diagMissingMeasure, name))
            parts.append(cantDraw(meters, partTitle: partTitle))
        case .missingStyle(let name):
            parts.append(StudioText.format(.diagMissingStyle, name))
        case .missingInclude(let path):
            parts.append(StudioText.format(.diagMissingInclude, path))
        case .missingImage(let path):
            parts.append(StudioText.format(.diagMissingImage, path))
            parts.append(cantDraw(meters, partTitle: partTitle))
        case .unknownBang(let name, let suggestion):
            if let suggestion {
                parts.append(StudioText.format(.diagUnknownBang, name, suggestion))
            } else {
                parts.append(StudioText.format(.diagUnknownBangNoGuess, name))
            }
        }
        let separator = StudioText.language == .chinese ? "" : " "
        return parts.filter { !$0.isEmpty }.joined(separator: separator)
    }

    static func reasonText(_ reason: IniDiagnostic.FormulaReason) -> String {
        switch reason {
        case .missingNumber(let op): return StudioText.format(.diagMissingNumber, op)
        case .missingParenthesis: return StudioText[.diagMissingParen]
        case .unknownFunction(let name): return StudioText.format(.diagUnknownFunction, name)
        case .empty: return StudioText[.diagEmptyFormula]
        case .other(let message): return message
        }
    }

    /// "The numbers draw in the default black until then." — or, for an option that is not a color, which default
    /// applies.
    static func meanwhile(key: String, defaultValue: String?, meters: [Meter]) -> String {
        guard let defaultValue, !defaultValue.isEmpty else { return "" }
        if !meters.isEmpty, OptionValue.color(defaultValue) != nil, key.lowercased().contains("color") {
            let plural = meters.count > 1
            return StudioText.format(plural ? .diagMeanwhileColorMany : .diagMeanwhileColorOne,
                                     noun(for: meters, plural: plural), colorName(defaultValue))
        }
        return StudioText.format(.diagMeanwhileDefault, "\(key)=\(defaultValue)")
    }

    /// "The 3 bars don’t draw." / "The CPU bar doesn’t draw."
    static func cantDraw(_ meters: [Meter], partTitle: (Meter) -> String) -> String {
        if meters.count > 1 { return StudioText.format(.diagCantDrawMany, meters.count, noun(for: meters, plural: true)) }
        if let m = meters.first { return StudioText.format(.diagCantDrawOne, partTitle(m)) }
        return ""
    }

    /// The capsule over the canvas while red problems are open: "The bars can’t draw · your desktop keeps the last
    /// working version", or "1 problem · the rest still draws".
    static func capsule(problems: [IniDiagnostic], skin: Skin?, holding: Bool, partTitle: (Meter) -> String) -> String? {
        guard !problems.isEmpty else { return nil }
        var names: [String] = []
        for d in problems { for m in d.meters where !names.contains(m) { names.append(m) } }
        let meters = names.compactMap { skin?.meter(named: $0) }
        var text: String
        if meters.isEmpty {
            text = StudioText.format(problems.count == 1 ? .capsuleProblems : .capsuleProblemsMany, problems.count)
        } else if meters.count == 1 {
            text = StudioText.format(.capsuleCantDraw, partTitle(meters[0]))
        } else if Set(meters.map(kind)).count == 1 {
            text = StudioText.format(.capsuleCantDraw, noun(for: meters, plural: true))
        } else {
            text = StudioText.format(.capsuleCantDrawNamed, "\(meters.count) \(noun(for: meters, plural: true))")
        }
        if StudioText.language == .chinese, text.hasPrefix(" ") { text.removeFirst() }
        if holding { text += " · " + StudioText[.capsuleKeeps] }
        return text
    }
}
