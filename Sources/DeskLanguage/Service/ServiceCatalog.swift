import Foundation

// What the service reads from the catalog for one built-in name: its documentation, its title, its signatures, and
// the member or field it stands for. Semantic tokens, hover cards and signature help all ask through these, so they
// agree on what a name is.

extension DeskCatalog {
    /// The documentation of a built-in name. A namespace that is also a value (`uptime`) and a function that reads
    /// data (`files(…)`) have two; a case of an enum whose cases have their own entries (a color, a permission, a
    /// feature) has the case's first, then the enum's.
    func serviceDocs(for path: CatalogPath, call: Bool? = nil) -> [Doc] {
        var docs: [Doc] = []
        func add(_ doc: Doc?) {
            guard let doc, !docs.contains(where: { $0.en == doc.en && $0.zh == doc.zh }) else { return }
            docs.append(doc)
        }
        switch path {
        case .component(let name): add(component(named: name)?.doc)
        case .modifier(let name): add(modifier(named: name)?.doc)
        case .namespace(let name):
            let ns = namespace(named: name)
            add(ns?.doc)
            add(ns?.value?.doc)
        case .member, .recordField, .typeMember:
            add(serviceMember(for: path, call: call)?.doc)
        case .record(let id): add(record(id)?.doc)
        case .function(let name):
            let f = function(named: name)
            add(f?.doc)
            add(f?.data?.doc)
        case .control(let name): add(control(named: name)?.doc)
        case .enumeration(let id): add(enumeration(id)?.doc)
        case .enumCase(let type, let name):
            add(index.namedValues["\(type).\(name)"]?.doc)
            if type == "Permission" { add(index.permissions[name]?.doc) }
            if type == "Feature" { add(index.features[name]?.doc) }
            add(enumeration(type)?.doc)
        case .namedValue(let type, let name): add(index.namedValues["\(type).\(name)"]?.doc)
        case .infoField(let name): add(index.infoFields[name]?.doc ?? index.packageFields[name]?.doc)
        case .packageField(let name): add(index.packageFields[name]?.doc ?? index.infoFields[name]?.doc)
        case .formatOption(let label):
            for row in index.formatOptions[label] ?? [] { add(row.doc) }
        case .permission(let id):
            add(index.permissions[id]?.doc)
            add(enumeration("Permission")?.doc)
        case .feature(let id):
            add(index.features[id]?.doc)
            add(enumeration("Feature")?.doc)
        }
        return docs
    }

    /// How pickers and menus name a built-in item ("Progress bar" / "进度条"), when the catalog gives it a title.
    func serviceTitle(for path: CatalogPath, call: Bool? = nil) -> LocalizedText? {
        switch path {
        case .component(let name): return component(named: name)?.title
        case .modifier(let name): return modifier(named: name)?.title
        case .namespace(let name): return namespace(named: name)?.title
        case .member, .recordField, .typeMember: return serviceMember(for: path, call: call)?.title
        case .function(let name): return function(named: name)?.title
        case .control(let name): return control(named: name)?.title
        case .enumCase(let type, let name):
            if let value = index.namedValues["\(type).\(name)"] { return value.title }
            return enumeration(type)?.enumCase(named: name)?.title
        case .namedValue(let type, let name): return index.namedValues["\(type).\(name)"]?.title
        case .record, .enumeration, .infoField, .packageField, .formatOption, .permission, .feature: return nil
        }
    }

    /// The member, record field or member of a value type a path names.
    func serviceMember(for path: CatalogPath, call: Bool? = nil) -> MemberSpec? {
        switch path {
        case .member(let ns, let name): return index.member(ns, name)
        case .recordField(let record, let name): return self.record(record)?.field(named: name)
        case .typeMember(let type, let name):
            let asCall = call ?? false
            return index.typeMember(type, name, call: asCall) ?? index.typeMember(type, name, call: !asCall)
        case .namespace(let name): return namespace(named: name)?.value
        case .function(let name): return function(named: name)?.data
        default: return nil
        }
    }

    /// The ways a built-in name can be called.
    func serviceSignatures(for path: CatalogPath) -> [Signature] {
        switch path {
        case .component(let name): return component(named: name)?.signatures ?? []
        case .modifier(let name): return modifier(named: name)?.signatures ?? []
        case .function(let name): return function(named: name)?.signatures ?? []
        case .control(let name): return control(named: name)?.signatures ?? []
        case .member(let ns, let name): return index.member(ns, name)?.signatures ?? []
        case .recordField(let record, let name): return self.record(record)?.field(named: name)?.signatures ?? []
        case .typeMember(let type, let name):
            return (index.typeMember(type, name, call: true) ?? index.typeMember(type, name, call: false))?.signatures ?? []
        default: return []
        }
    }

    /// Whether a built-in name is an action (`open`, `music.play`), a function that computes or reads a value
    /// (`round`, `calendar.month`), or a field (`cpu.usage`).
    func serviceMemberKind(for path: CatalogPath) -> MemberSpec.Kind? {
        switch path {
        case .function(let name): return function(named: name)?.kind
        case .member, .recordField, .typeMember:
            return serviceMember(for: path)?.kind
        default: return nil
        }
    }

    /// The member a dotted path written in code names: `music.play`, `audio.microphone.level` (the longest
    /// namespace that the path starts with, then its member).
    func serviceMember(dotted parts: [String]) -> (path: CatalogPath, spec: MemberSpec)? {
        guard parts.count >= 2 else { return nil }
        for split in stride(from: parts.count - 1, through: 1, by: -1) {
            let ns = parts[0..<split].joined(separator: ".")
            guard namespace(named: ns) != nil else { continue }
            guard split == parts.count - 1 else { return nil }
            if let member = index.member(ns, parts[split]) { return (.member(namespace: ns, name: parts[split]), member) }
            return nil
        }
        return nil
    }

    /// The anchor of a built-in name in the language reference: `component-progress`, `modifier-padding`,
    /// `data-cpu-usage`. Lower case, with `-` for dots and spaces.
    static func referenceAnchor(for path: CatalogPath) -> String {
        func slug(_ parts: String...) -> String {
            parts.joined(separator: "-").lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        }
        switch path {
        case .component(let n): return slug("component", n)
        case .modifier(let n): return slug("modifier", n)
        case .namespace(let n): return slug("data", n)
        case .member(let ns, let n): return slug("data", ns, n)
        case .record(let id): return slug("record", id)
        case .recordField(let r, let n): return slug("record", r, n)
        case .typeMember(let t, let n): return slug("member", t, n)
        case .function(let n): return slug("function", n)
        case .control(let n): return slug("control", n)
        case .enumeration(let id): return slug("choices", id)
        case .enumCase(let t, let n), .namedValue(let t, let n): return slug("choices", t, n)
        case .infoField(let n): return slug("info", n)
        case .packageField(let n): return slug("package", n)
        case .formatOption(let l): return slug("format", l)
        case .permission(let id): return slug("permission", id)
        case .feature(let id): return slug("feature", id)
        }
    }
}

/// Words the service puts in hover cards and signature help, in both languages.
enum DeskServiceWords {
    typealias L = LocalizedText

    /// A default that is not Desk text, in words.
    static func systemDefault(_ value: SystemDefault) -> L {
        switch value {
        case .weekStart: return L("the first day of the week in the Mac's settings", "Mac 设置里每周的第一天")
        case .today: return L("today", "今天")
        case .systemFont: return L("the system font", "系统字体")
        case .accent: return L("your accent color", "你的强调色")
        case .regionSpeedUnit: return L("km/h or mph, by your region", "按地区用 km/h 或 mph")
        case .fileName: return L("the file's name", "文件名")
        case .firstChoice: return L("the first choice", "第一个选项")
        case .bindingMinimum: return L("the lowest value it can change to", "所连的值能取的最小值")
        case .bindingMaximum: return L("the highest value it can change to", "所连的值能取的最大值")
        case .perData: return L("each data's own pace", "每项数据自己的更新频率")
        }
    }

    /// A parameter's or field's default, in words (Desk text in backquotes).
    static func defaultValue(_ value: DefaultValue) -> L {
        switch value {
        case .source(let text): return L("`\(text)`", "`\(text)`")
        case .system(let s): return systemDefault(s)
        case .parameter(let other): return L("the same as `\(other):`", "和 `\(other):` 一样")
        }
    }

    /// How often data updates, in words.
    static func cadence(_ cadence: Cadence) -> L {
        switch cadence {
        case .periodic(let seconds):
            return L("every \(duration(seconds).en)", "每 \(duration(seconds).zh)")
        case .clock: return L("with the clock, as often as it shows (every minute or second)", "跟着时钟，按显示的精度（每分钟或每秒）")
        case .event: return L("when the system reports a change", "系统报告变化时")
        case .eventAndPeriodic(let seconds):
            return L("when the system reports a change, and at least every \(duration(seconds).en)",
                     "系统报告变化时，至少每 \(duration(seconds).zh)")
        case .frame: return L("every frame while it is on screen", "显示在屏幕上时每一帧")
        case .service: return L("when Deskset's shared service updates it", "Deskset 的共享服务更新时")
        case .once: return L("once", "只读一次")
        case .argument(let label, let seconds):
            return L("as `\(label):` says (\(duration(seconds).en) if left out)", "按 `\(label):` 的设置（不写时 \(duration(seconds).zh)）")
        case .ofRecord: return L("with the data it belongs to", "跟着它所属的数据")
        }
    }

    /// `2 s`, `1 min`, `1.5 h` / `2 秒`, `1 分钟`.
    static func duration(_ seconds: Double) -> L {
        if seconds >= 3_600, (seconds / 3_600).rounded() == seconds / 3_600 {
            let n = number(seconds / 3_600)
            return L(n == "1" ? "hour" : "\(n) hours", "\(n) 小时")
        }
        if seconds >= 60, (seconds / 60).rounded() == seconds / 60 {
            let n = number(seconds / 60)
            return L(n == "1" ? "minute" : "\(n) minutes", "\(n) 分钟")
        }
        if seconds < 1 {
            let n = number(seconds * 1_000)
            return L("\(n) ms", "\(n) 毫秒")
        }
        let n = number(seconds)
        return L(n == "1" ? "second" : "\(n) seconds", "\(n) 秒")
    }

    /// A number as people read it: whole numbers without a fraction, others with up to six significant digits,
    /// thousands grouped.
    static func number(_ x: Double) -> String {
        guard x.isFinite else { return String(x) }
        if x == x.rounded(), abs(x) < 1e15 {
            return grouped(String(Int64(x)))
        }
        var text = String(format: "%.6g", x)
        if text.contains("e") { return text }
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        let parts = text.split(separator: ".", maxSplits: 1).map(String.init)
        return grouped(parts[0]) + (parts.count > 1 ? "." + parts[1] : "")
    }

    private static func grouped(_ digits: String) -> String {
        var sign = ""
        var body = digits
        if body.hasPrefix("-") { sign = "-"; body.removeFirst() }
        guard body.count > 4 else { return sign + body }
        var out = ""
        for (k, c) in body.reversed().enumerated() {
            if k > 0, k % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return sign + String(out.reversed())
    }

    /// The author's own text inside a card's Markdown: characters Markdown would read as formatting are escaped
    /// (`*`, `_`, `` ` ``, braces, brackets), so the text shows as written.
    static func quoted(_ text: String) -> L {
        var out = ""
        for c in text {
            if "\\`*_{}[]<>#|".contains(c) { out.append("\\") }
            out.append(c)
        }
        return L("“\(out)”", "“\(out)”")
    }

    static let since = L("Since", "引入版本")
    static let macOnly = L("Mac only", "Mac 专有")
    static let yes = L("Yes", "是")
    static let needsMacOS = L("Needs", "需要")
    static let permission = L("Permission", "权限")
    static let updates = L("Updates", "更新")
    static let value = L("Value", "值")
    static let type = L("Type", "类型")
    static let defaultLabel = L("Default", "默认")
    static let replacedBy = L("Replaced by", "已由它取代")
    static let reference = L("Reference", "参考")
    static let rainmeter = L("Rainmeter", "Rainmeter")
    static let example = L("Example", "例子")
    static let approximate = L(" (approximately)", "（近似）")

    static func macOS(_ version: Int) -> L { L("macOS \(version) or later", "macOS \(version) 或更新") }
}
