import Foundation

// Signature help: while the cursor is between a call's parentheses (a component, modifier, function, action, option
// control or data call) or after the first comma of `{value, …}`, the ways it can be called, each parameter with its
// label, its type in words, its default and what it does. The active signature is the one the written labels fit;
// the active parameter is the one the cursor's argument names by its label, or by its place.

/// One parameter of a signature.
public struct DeskParameterHelp: Sendable, Hashable {
    /// The label written before `:`; nil for a value written without one.
    public var label: String?
    public var name: String
    /// Where the parameter is in its signature's `label`, in UTF-16 units.
    public var labelRange: Range<Int>
    /// What it takes, in words ("a length in points, such as `12`").
    public var type: LocalizedText
    /// What it is when left out, in words; nil when it may be left out and then is not set.
    public var defaultValue: LocalizedText?
    public var isRequired: Bool
    /// What it does.
    public var doc: LocalizedText

    public init(label: String?, name: String, labelRange: Range<Int>, type: LocalizedText, defaultValue: LocalizedText?,
                isRequired: Bool, doc: LocalizedText) {
        self.label = label
        self.name = name
        self.labelRange = labelRange
        self.type = type
        self.defaultValue = defaultValue
        self.isRequired = isRequired
        self.doc = doc
    }

    /// `**total:** a number, `1` if left out — The total the value is a part of.` The name is bold for the
    /// parameter being written (`active`), in code style otherwise. What it does is left out when it only says
    /// again what it takes.
    public func markdown(_ language: DiagnosticLanguage, active: Bool = true) -> String {
        let shown = label.map { "\($0):" } ?? name
        let typeText = type.text(in: language)
        var line = (active ? "**\(shown)**" : "`\(shown)`") + " " + typeText
        if let defaultValue {
            line += language == .simplifiedChinese ? "，默认 " + defaultValue.zh : ", " + defaultValue.en + " if left out"
        } else if isRequired {
            line += language == .simplifiedChinese ? "，必填" : ", required"
        }
        let doc = self.doc.text(in: language)
        if !doc.isEmpty, !DeskParameterHelp.repeats(doc, typeText) {
            line += language == .simplifiedChinese ? "。" + doc : " — " + doc
        }
        return line
    }

    /// Whether a parameter's words only say again what its type's words say ("a text style, such as `.caption`"
    /// and "A text style, such as .headline").
    static func repeats(_ doc: String, _ type: String) -> Bool {
        func essence(_ s: String) -> String {
            var t = s.lowercased().replacingOccurrences(of: "`", with: "")
            for marker in ["such as", "比如", "e.g.", "例如"] {
                if let r = t.range(of: marker) { t = String(t[..<r.lowerBound]) }
            }
            return String(t.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
                .map(Character.init))
        }
        let d = essence(doc), t = essence(type)
        return !d.isEmpty && (d == t || t.hasPrefix(d))
    }
}

/// One way to call something.
public struct DeskSignatureHelpItem: Sendable, Hashable {
    /// Desk-like: `Progress(value, total: …)`, `.padding(horizontal: …, vertical: …)`, `{value, digits: …}`.
    public var label: String
    public var parameters: [DeskParameterHelp]

    public init(label: String, parameters: [DeskParameterHelp]) {
        self.label = label
        self.parameters = parameters
    }
}

/// The signatures of the call at a position.
public struct DeskSignatureHelp: Sendable, Hashable {
    /// As written: `Text`, `.padding`, `calendar.month`, `round`, `{…}`.
    public var name: String
    /// How menus name it ("Progress bar" / "进度条").
    public var title: LocalizedText
    /// What it does.
    public var doc: LocalizedText?
    public var signatures: [DeskSignatureHelpItem]
    public var activeSignature: Int
    /// Nil when the cursor's argument fits no parameter of the active signature.
    public var activeParameter: Int?
    /// Between the parentheses (or the braces of `{value, …}`).
    public var range: DeskRange
    /// The reference anchor of the callee.
    public var reference: String?

    public init(name: String, title: LocalizedText, doc: LocalizedText?, signatures: [DeskSignatureHelpItem],
                activeSignature: Int, activeParameter: Int?, range: DeskRange, reference: String?) {
        self.name = name
        self.title = title
        self.doc = doc
        self.signatures = signatures
        self.activeSignature = activeSignature
        self.activeParameter = activeParameter
        self.range = range
        self.reference = reference
    }

    /// The active signature with its parameters in the order they are written, the active one's name in bold (all
    /// in bold when no parameter is active).
    public func markdown(_ language: DiagnosticLanguage) -> String {
        guard signatures.indices.contains(activeSignature) else { return "" }
        let signature = signatures[activeSignature]
        var out = "**\(title.text(in: language))**\n\n```desk\n\(signature.label)\n```\n"
        if let doc, !doc.text(in: language).isEmpty { out += "\n" + doc.text(in: language) + "\n" }
        let active = activeParameter.flatMap { signature.parameters.indices.contains($0) ? $0 : nil }
        if !signature.parameters.isEmpty { out += "\n" }
        for p in signature.parameters.indices {
            out += "- " + signature.parameters[p].markdown(language, active: active == nil || active == p) + "\n"
        }
        if signatures.count > 1 {
            out += "\n" + (language == .simplifiedChinese ? "第 \(activeSignature + 1) 种写法，共 \(signatures.count) 种"
                                                          : "Form \(activeSignature + 1) of \(signatures.count)") + "\n"
        }
        return out
    }
}

extension DeskSnapshot {
    /// The signatures of the call whose parentheses hold a position; nil outside any call.
    public func signatureHelp(at position: DeskPosition) -> DeskSignatureHelp? {
        guard hasStackRoom else { return onLargeStack { signatureHelp(at: position) } }
        let offset = index.utf8Offset(ofUTF16: index.clampedUTF16(position.offset))
        guard let site = callSite(at: offset) else { return nil }
        let catalog = options.catalog
        let k = site.argumentIndex(at: offset)
        let active = activeSignature(site, argument: k)
        let items = site.signatures.map { signatureItem($0, site: site) }
        let parameter = activeParameter(site.signatures[active], site: site, argument: k)
        let docs = site.path.map { catalog.serviceDocs(for: $0) } ?? []
        let title = site.path.flatMap { catalog.serviceTitle(for: $0) } ?? LocalizedText(site.name, site.name)
        return DeskSignatureHelp(name: site.name, title: title, doc: docs.first?.text, signatures: items,
                                 activeSignature: active, activeParameter: parameter, range: index.range(utf8: site.inside),
                                 reference: site.path.map { DeskCatalog.referenceAnchor(for: $0) })
    }

    // MARK: Pieces

    func signatureItem(_ signature: Signature, site: DeskCallSite) -> DeskSignatureHelpItem {
        let catalog = options.catalog
        var label = site.owner == .formatOptions ? "{value" : site.name + "("
        var parameters: [DeskParameterHelp] = []
        for (k, p) in signature.params.enumerated() {
            if k > 0 || site.owner == .formatOptions { label += ", " }
            let start = label.utf16.count
            if let written = p.label { label += "\(written): …" } else { label += p.name + (p.variadic ? "…" : "") }
            let range = start..<label.utf16.count
            parameters.append(DeskParameterHelp(label: p.label, name: p.name, labelRange: range,
                                                type: catalog.displayName(for: p.type),
                                                defaultValue: p.defaultValue.map(DeskServiceWords.defaultValue),
                                                isRequired: p.required, doc: p.doc))
        }
        label += site.owner == .formatOptions ? "}" : ")"
        return DeskSignatureHelpItem(label: label, parameters: parameters)
    }

    /// The signature the written labels fit best (then the positional values' types; ties go to the earliest).
    func activeSignature(_ site: DeskCallSite, argument k: Int) -> Int {
        guard site.signatures.count > 1 else { return 0 }
        let written = site.arguments.compactMap(\.label)
        var positional: [(index: Int, type: DeskType?)] = []
        for (i, argument) in site.arguments.enumerated() where argument.label == nil && (argument.value != nil || i == k) {
            positional.append((i, argument.value.flatMap { recordedType($0)?.type }))
        }
        var best = 0
        var bestScore = Int.max
        for (s, signature) in site.signatures.enumerated() {
            let unknown = written.filter { l in !signature.params.contains { $0.label == l } }.count
            let slots = signature.params.filter { $0.label == nil }
            let capacity = slots.last?.variadic == true ? Int.max : slots.count
            let extra = max(0, positional.count - capacity)
            var misfit = 0
            for (p, value) in positional.enumerated() {
                guard let type = value.type, !slots.isEmpty else { continue }
                let slot = slots[min(p, slots.count - 1)]
                if !DeskSnapshot.fits(type, slot.type) { misfit += 1 }
            }
            // A required label that is not written counts a little.
            let missing = signature.params.filter { $0.required && $0.label != nil && !written.contains($0.label!) }.count
            let score = unknown * 100 + extra * 10 + misfit * 3 + missing
            if score < bestScore { best = s; bestScore = score }
        }
        return best
    }

    /// The parameter the `k`-th argument stands for: the one its label names, else the next positional one, else
    /// the first labelled one not yet written.
    func activeParameter(_ signature: Signature, site: DeskCallSite, argument k: Int) -> Int? {
        let argument = k < site.arguments.count ? site.arguments[k] : nil
        if let label = argument?.label {
            return signature.params.firstIndex { $0.label == label }
        }
        let written = Set(site.arguments.compactMap(\.label))
        func nextLabelled() -> Int? {
            // The first labelled parameter not yet written after the last one written before the cursor, else the
            // first one not yet written.
            let lastWritten = site.arguments.prefix(k).compactMap { a in a.label.flatMap { l in signature.params.firstIndex { $0.label == l } } }.max() ?? -1
            let open = signature.params.indices.filter { signature.params[$0].label != nil && !written.contains(signature.params[$0].label!) }
            return open.first { $0 > lastWritten } ?? open.first
        }
        // After a labelled value, only labelled ones may follow.
        if site.arguments.prefix(k).contains(where: { $0.label != nil }) { return nextLabelled() }
        let before = site.arguments.prefix(k).filter { $0.label == nil && $0.value != nil }.count
        let slots = signature.params.indices.filter { signature.params[$0].label == nil }
        if before < slots.count { return slots[before] }
        if let last = slots.last, signature.params[last].variadic { return last }
        return nextLabelled()
    }

    /// Whether a value of type `t` may be given for a parameter of type `p` (a quick check: the checker decides).
    static func fits(_ t: DeskType, _ p: DeskType) -> Bool {
        switch p {
        case .any, .typeVar: return true
        case .oneOf(let options): return options.contains { fits(t, $0) }
        case .binding(let inner): return fits(t, inner)
        case .anyNumber: return t.isNumeric
        case .fraction:
            if case .number(let d) = t { return d == .percent || d == .plain }
            return t == .anyNumber || t == .fraction
        case .number(let d):
            if case .number(let own) = t { return own == d || own == .plain }
            return t == .anyNumber
        case .lengthSpec:
            if case .enumeration = t { return true }
            return fits(t, .length)
        case .paint: return t == .color || t == .paint
        case .string, .symbolName, .imageSource, .fontFamily, .folderPath:
            return [.string, .symbolName, .imageSource, .fontFamily, .folderPath].contains(t)
        default: return t.sameKind(as: p)
        }
    }
}
