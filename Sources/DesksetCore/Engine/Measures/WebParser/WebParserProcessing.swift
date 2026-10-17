import Foundation

/// Options of one WebParser measure, copied on the skin's thread so that parsing can run on a background queue.
struct WebParserOptions {
    var name = ""
    /// Resolved `URL`. For a child measure every reference to the parent is replaced by `WebParserProcessor.parentMark`.
    var url = ""
    /// Name of the parent WebParser measure when `URL` references one (`URL=[Parent]`, `URL=https://host[Parent]`).
    var parentName: String?
    var regExp = ""
    var jsonPointer = ""
    var localeConversion = false
    var stringIndex = 0
    var stringIndex2 = 0
    var decodeCharacterReference = 0
    var decodeCodePoints = false
    var download = false
    var downloadFile = ""
    var errorString: String?
    var logSubstringErrors = true
    var debug = 0
    var debug2File = ""
    var codePage = 0
    var updateRate = 600
    var userAgent = WebParserNetwork.defaultUserAgent
    var headers: [(name: String, value: String)] = []
    var flags = WebParserFlags()
    var proxy = "/auto"

    var hasRegExp: Bool { !regExp.isEmpty || !jsonPointer.isEmpty }
    var hasJsonPointer: Bool { !jsonPointer.isEmpty }
}

/// A parent measure and (recursively) the child measures that read its captures.
struct WebParserNode {
    var options: WebParserOptions
    var children: [WebParserNode] = []
}

struct WebParserLogLine: Equatable {
    var level: SkinLogLevel
    var message: String
}

/// What parsing produced for one measure of the tree.
struct WebParserNodeResult {
    var name: String
    var hasRegExp: Bool
    /// The measure's input was a missing capture ("Not enough substrings"): it and its children become empty and run
    /// no actions.
    var inputMissing = false
    /// Non-nil when `RegExp` failed (invalid pattern, no match, time-out); values stay as they were.
    var regExpError: String?
    /// New captures for child measures (index 0 = whole match); nil = unchanged.
    var captures: [String]?
    /// PCRE's substring count: 1 + the highest capture group that participated in the match.
    var substringCount = 0
    /// New string value (before `Download`); nil = unchanged.
    var value: String?
    /// `Download=1`: the URL to download (the value becomes the local file once that succeeds).
    var downloadSource: String?
    var logs: [WebParserLogLine] = []
    var children: [WebParserNodeResult] = []
}

enum WebParserRegExpOutcome: Equatable {
    case invalid
    case noMatch
    case timedOut
    case matched(captures: [String], substringCount: Int)
}

// Parsing rules (manual: WebParser; tips "WebParser: Using StringIndex2", "Lookahead Assertions in RegExp"):
// - The parent's `RegExp` runs on the downloaded text; each capture is a StringIndex (1, 2, …).
// - A child (`URL=[Parent]`) takes the parent capture given by its `StringIndex`. `[Parent]` may be part of a longer
//   URL (tutorial: `URL=https://browserleaks.com[MeasureSite]` + `Download=1`), so the child's input is its URL with
//   the capture inserted.
// - A child with its own `RegExp` parses that input; its value is its own capture `StringIndex2`, and its captures
//   are what its own children read ("Any WebParser measure that has a RegExp option is a parent, although it can
//   also be a child").
// - A capture that does not exist (lookahead that failed, or a StringIndex beyond the groups) gives an empty value
//   and logs "Not enough substrings" unless the parent has `LogSubstringErrors=0`.
// - `DecodeCharacterReference` / `DecodeCodePoints` apply to the value of the measure that has them.
//
// Judgment calls (the manual is silent):
// - StringIndex 0 (the default) is PCRE's substring 0: the whole match. Without a RegExp the whole text is capture 0,
//   and a child without a RegExp takes its whole input.
// - A child whose own RegExp fails keeps its previous value (like the parent does), and its children are left alone.
// - A capture that is missing makes the child and its whole subtree empty (the lookahead tip says the child "will
//   just return a null value").
enum WebParserProcessor {
    /// Stands for the parent's capture inside a child's resolved URL (a private-use character no URL contains).
    static let parentMark = "\u{F8FF}"
    static let maxDepth = 16
    private static let debugTextLimit = 300

    /// Parses a downloaded page for a whole parent tree. Runs on a background queue.
    static func process(_ root: WebParserNode, text: String) -> WebParserNodeResult {
        var result = processNode(root, input: text, jsonContext: nil, isRoot: true, depth: 0)
        if root.options.debug == 1 {
            result.logs.insert(WebParserLogLine(level: .debug,
                                                message: "WebParser [\(root.options.name)]: read \(text.count) characters"),
                               at: 0)
        }
        return result
    }

    static func processNode(_ node: WebParserNode, input: String?, jsonContext: Any? = nil,
                            isRoot: Bool, depth: Int) -> WebParserNodeResult {
        let o = node.options
        var r = WebParserNodeResult(name: o.name, hasRegExp: o.hasRegExp)
        guard let input else {
            r.inputMissing = true
            r.value = ""
            r.captures = []
            r.substringCount = 0
            r.children = depth < maxDepth
                ? node.children.map { processNode($0, input: nil, jsonContext: nil, isRoot: false, depth: depth + 1) } : []
            return r
        }

        if o.hasJsonPointer {
            return processJsonPointer(node, &r, input: input, jsonContext: jsonContext, isRoot: isRoot, depth: depth)
        }

        var captures: [String]
        var count: Int
        if !o.regExp.isEmpty {
            switch match(o.regExp, in: input) {
            case .invalid:
                r.regExpError = "RegExp is not a valid regular expression"
            case .noMatch:
                r.regExpError = "RegExp matching error (no match)"
            case .timedOut:
                r.regExpError = "RegExp matching took too long and was abandoned"
            case .matched(let c, let n):
                captures = c
                count = n
                r.captures = c
                r.substringCount = n
                return finish(node, &r, captures: captures, count: count, input: input, isRoot: isRoot, depth: depth)
            }
            r.logs.append(WebParserLogLine(level: .error, message: "WebParser [\(o.name)]: \(r.regExpError ?? "")"))
            return r
        }
        captures = [input]
        count = 1
        r.captures = captures
        r.substringCount = count
        return finish(node, &r, captures: captures, count: count, input: input, isRoot: isRoot, depth: depth)
    }

    private static func processJsonPointer(_ node: WebParserNode, _ r: inout WebParserNodeResult,
                                           input: String, jsonContext: Any?,
                                           isRoot: Bool, depth: Int) -> WebParserNodeResult {
        let o = node.options
        let baseNode: Any
        if let jsonContext {
            baseNode = jsonContext
        } else {
            guard let data = input.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                r.regExpError = "JSON parsing error"
                r.logs.append(WebParserLogLine(level: .error, message: "WebParser [\(o.name)]: JSON parsing error"))
                return r
            }
            baseNode = parsed
        }

        let pointer = o.jsonPointer.trimmingCharacters(in: .whitespaces)
        let isEnableOnly = (pointer == "1")
        let selected: Any?
        if isEnableOnly || pointer.isEmpty {
            selected = baseNode
        } else {
            selected = evaluateJsonPointer(pointer, in: baseNode)
        }

        guard let selectedNode = selected else {
            if o.logSubstringErrors {
                r.logs.append(WebParserLogLine(level: .error,
                                               message: "WebParser [\(o.name)]: JsonPointer \(pointer) not found"))
            }
            r.value = ""
            r.captures = []
            r.substringCount = 0
            r.children = depth < maxDepth
                ? node.children.map { processNode($0, input: nil, jsonContext: nil, isRoot: false, depth: depth + 1) } : []
            return r
        }

        var raw = isEnableOnly ? "" : stringifyJsonNode(selectedNode)
        if o.decodeCodePoints { raw = WebParserText.decodeCodePoints(raw) }
        if o.decodeCharacterReference != 0 {
            raw = WebParserText.decodeCharacterReferences(raw, mode: o.decodeCharacterReference)
        }
        r.captures = [raw]
        r.substringCount = 1
        if o.download {
            r.downloadSource = raw
        } else {
            r.value = raw
        }

        guard depth < maxDepth else { return r }
        for child in node.children {
            let url = child.options.url
            let childInput = url.contains(parentMark) ? url.replacingOccurrences(of: parentMark, with: raw) : raw
            let childJson = child.options.hasJsonPointer ? selectedNode : nil
            r.children.append(processNode(child, input: childInput, jsonContext: childJson, isRoot: false, depth: depth + 1))
        }
        return r
    }

    /// Evaluates RFC 6901 JSON Pointer (`/a/b/0`) against `root`.
    static func evaluateJsonPointer(_ pointer: String, in root: Any) -> Any? {
        guard pointer.hasPrefix("/") else { return nil }
        let rawTokens = pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        var current: Any = root
        for rawToken in rawTokens {
            let token = String(rawToken)
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            if let dict = current as? [String: Any] {
                guard let next = dict[token] else { return nil }
                current = next
            } else if let arr = current as? [Any] {
                guard token == "0" || (!token.hasPrefix("0") && token.allSatisfy(\.isNumber)),
                      let idx = Int(token), idx >= 0, idx < arr.count else { return nil }
                current = arr[idx]
            } else {
                return nil
            }
        }
        return current
    }

    private static func stringifyJsonNode(_ node: Any) -> String {
        if let s = node as? String { return s }
        if node is NSNull { return "" }
        if let n = node as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            return NumberFormatting.plain(n.doubleValue, maxDecimals: 15)
        }
        if JSONSerialization.isValidJSONObject(node),
           let data = try? JSONSerialization.data(withJSONObject: node, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: node)
    }

    private static func finish(_ node: WebParserNode, _ r: inout WebParserNodeResult, captures: [String], count: Int,
                               input: String, isRoot: Bool, depth: Int) -> WebParserNodeResult {
        let o = node.options
        if o.debug == 1 && !o.regExp.isEmpty {
            for index in 1..<max(count, 1) where index < captures.count {
                var shown = captures[index]
                if shown.count > debugTextLimit { shown = String(shown.prefix(debugTextLimit)) + "…" }
                r.logs.append(WebParserLogLine(level: .debug, message: "WebParser [\(o.name)]: (Index \(index)) \(shown)"))
            }
        }

        // The measure's own value.
        var raw: String
        if !isRoot && o.regExp.isEmpty {
            raw = input
        } else {
            let index = isRoot ? o.stringIndex : o.stringIndex2
            if index >= 0 && index < count && index < captures.count {
                raw = captures[index]
            } else {
                raw = ""
                if o.logSubstringErrors {
                    r.logs.append(WebParserLogLine(level: .error,
                                                   message: "WebParser [\(o.name)]: Not enough substrings (index \(index))"))
                }
            }
        }
        if o.decodeCodePoints { raw = WebParserText.decodeCodePoints(raw) }
        if o.decodeCharacterReference != 0 {
            raw = WebParserText.decodeCharacterReferences(raw, mode: o.decodeCharacterReference)
        }
        if o.download {
            r.downloadSource = raw
        } else {
            r.value = raw
        }

        guard depth < maxDepth else { return r }
        for child in node.children {
            let index = child.options.stringIndex
            var childInput: String?
            if index >= 0 && index < count && index < captures.count {
                let capture = captures[index]
                let url = child.options.url
                childInput = url.contains(parentMark) ? url.replacingOccurrences(of: parentMark, with: capture) : capture
            } else if o.logSubstringErrors {
                r.logs.append(WebParserLogLine(level: .error, message:
                    "WebParser [\(child.options.name)]: Not enough substrings (StringIndex \(index) of [\(o.name)])"))
            }
            r.children.append(processNode(child, input: childInput, jsonContext: nil, isRoot: false, depth: depth + 1))
        }
        return r
    }

    /// Runs a PCRE pattern (converted for ICU by `PCRE`) and returns the first match's groups.
    static func match(_ pattern: String, in text: String) -> WebParserRegExpOutcome {
        guard let regex = PCRE.regex(pattern) else { return .invalid }
        guard let found = PCRE.findMatches(regex, in: text, maxCount: 1) else { return .timedOut }
        guard let m = found.first else { return .noMatch }
        let ns = text as NSString
        var captures: [String] = []
        captures.reserveCapacity(m.numberOfRanges)
        var count = 0
        for index in 0..<m.numberOfRanges {
            let range = m.range(at: index)
            if range.location == NSNotFound {
                captures.append("")
            } else {
                captures.append(ns.substring(with: range))
                count = index + 1
            }
        }
        return .matched(captures: captures, substringCount: count)
    }
}
