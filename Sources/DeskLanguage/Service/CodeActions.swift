import Foundation

// Code actions (§6.1, the Studio's light bulb): the fix-its of the diagnostics under the cursor or selection, a
// "Fix all" for each group of fix-its the file has more than one of, one action per language that fixes everything
// written in that language's way (the foreign-syntax detections, DK9xxx), and the source actions: format the
// document and add every permission the file needs. The folder's own checks (DK86xx) offer their fix-its too. Every
// action is a workspace edit; titles are in the service's language.

/// What a code action does.
public enum DeskCodeActionKind: String, Sendable, Hashable, CaseIterable {
    /// One fix-it of one diagnostic.
    case quickFix = "quickfix"
    /// Every fix-it of one group in the file ("Fix all").
    case fixAll = "quickfix.fixAll"
    /// Every fix-it of the code written in one other language's way.
    case fixForeign = "quickfix.foreign"
    /// Formats the whole file.
    case formatDocument = "source.formatDocument"
    /// Adds every permission the file needs to `info { permissions: […] }`.
    case addMissingPermissions = "source.addMissingPermissions"

    /// A source action: offered for the file, not for a diagnostic.
    public var isSource: Bool { rawValue.hasPrefix("source.") }
}

/// A change the editor can offer.
public struct DeskCodeAction: Sendable, Hashable, CustomStringConvertible {
    public var title: String
    public var kind: DeskCodeActionKind
    public var edit: DeskWorkspaceEdit
    /// The one to take when the person asks for "the" fix: the first fix-it of each diagnostic.
    public var isPreferred: Bool
    /// The diagnostics it fixes (a quick fix: its own; a "Fix all": every one it takes a fix-it from).
    public var diagnostics: [DeskServiceDiagnostic]
    /// The fix-it group of a "Fix all".
    public var group: String?
    /// The language of a `fixForeign` action.
    public var family: ForeignFamily?

    public init(title: String, kind: DeskCodeActionKind, edit: DeskWorkspaceEdit, isPreferred: Bool = false,
                diagnostics: [DeskServiceDiagnostic] = [], group: String? = nil, family: ForeignFamily? = nil) {
        self.title = title
        self.kind = kind
        self.edit = edit
        self.isPreferred = isPreferred
        self.diagnostics = diagnostics
        self.group = group
        self.family = family
    }

    public var description: String {
        "\(kind.rawValue)\(isPreferred ? "*" : "") \(title)"
    }
}

extension DeskSnapshot {
    /// The actions for a range of the open file (an empty range: its position): the fix-its of the diagnostics that
    /// meet it, each diagnostic's first preferred; a "Fix all" for each group among them that has more than one
    /// fix-it in the file; for code written in another language's way, one action that fixes all of that language
    /// in the file; then, with `source`, the source actions. With `folder`, the folder's own checks are included
    /// (this checks the other widgets once per snapshot: `packageCheck`).
    public func codeActions(in range: DeskRange, source: Bool = true, folder: Bool = true) -> [DeskCodeAction] {
        guard hasStackRoom else { return onLargeStack { codeActions(in: range, source: source, folder: folder) } }
        let all = actionableDiagnostics(folder: folder)
        let touching = all.filter { $0.diagnostic.range.meets(range) }
        var out: [DeskCodeAction] = []
        for (d, _) in touching {
            var first = true
            for fix in d.fixIts where !fix.edit.isEmpty {
                out.append(DeskCodeAction(title: fix.title, kind: .quickFix, edit: fix.edit, isPreferred: first,
                                          diagnostics: [d], group: fix.group))
                first = false
            }
        }
        // "Fix all" for the groups under the range.
        var groups: [String] = []
        for (d, _) in touching {
            for fix in d.fixIts { if let group = fix.group, !groups.contains(group) { groups.append(group) } }
        }
        for group in groups {
            if let action = fixAllAction(group: group, in: all.map(\.diagnostic)) { out.append(action) }
        }
        // Everything written in the way of the languages under the range.
        var families: [ForeignFamily] = []
        for (d, family) in touching {
            if let family, !d.fixIts.isEmpty, !families.contains(family) { families.append(family) }
        }
        for family in families {
            if let action = foreignAction(family, in: all) { out.append(action) }
        }
        if source { out += sourceActions() }
        return out
    }

    /// The actions of one diagnostic: its fix-its, then the "Fix all" of their groups.
    public func codeActions(for diagnostic: DeskServiceDiagnostic) -> [DeskCodeAction] {
        guard hasStackRoom else { return onLargeStack { codeActions(for: diagnostic) } }
        return codeActions(in: diagnostic.range, source: false).filter { action in
            action.diagnostics.contains(diagnostic)
        }
    }

    /// The actions for the whole file: format it, and add every permission it needs.
    public func sourceActions() -> [DeskCodeAction] {
        guard hasStackRoom else { return onLargeStack { sourceActions() } }
        var out: [DeskCodeAction] = []
        let format = formatDocument()
        if !format.isEmpty {
            out.append(DeskCodeAction(title: DeskActionWords.formatDocument.text(in: options.messageLanguage),
                                      kind: .formatDocument, edit: DeskWorkspaceEdit([file: format])))
        }
        if let permissions = addMissingPermissionsAction() { out.append(permissions) }
        return out
    }

    /// Every fix-it of `group` in the file as one action; edits that would overlap an earlier one are left out.
    /// Nil when the file has fewer than two such fix-its (the quick fix already does it).
    public func fixAllAction(group: String) -> DeskCodeAction? {
        guard hasStackRoom else { return onLargeStack { fixAllAction(group: group) } }
        return fixAllAction(group: group, in: actionableDiagnostics(folder: false).map(\.diagnostic))
    }

    // MARK: Pieces

    /// The diagnostics of the open file, the folder's own checks of it when asked, each with the language it
    /// was written in when it is foreign syntax.
    private func actionableDiagnostics(folder: Bool) -> [(diagnostic: DeskServiceDiagnostic, family: ForeignFamily?)] {
        var list = diagnostics.map { ($0, foreignFamily(of: $0)) }
        if folder, self.folder.count > 1 || model != nil {
            let own = Set(diagnostics)
            for d in packageCheck().folderDiagnostics where d.file == file {
                let service = serviceDiagnostic(d)
                if !own.contains(service) { list.append((service, nil)) }
            }
        }
        return list
    }

    private func fixAllAction(group: String, in list: [DeskServiceDiagnostic]) -> DeskCodeAction? {
        var edits: [DeskFileID: [DeskTextEditU16]] = [:]
        var fixed: [DeskServiceDiagnostic] = []
        var titles: [String] = []
        for d in list {
            var took = false
            for fix in d.fixIts where fix.group == group {
                for (file, e) in fix.edit.files { edits[file, default: []] += e }
                titles.append(fix.title)
                took = true
            }
            if took { fixed.append(d) }
        }
        guard titles.count >= 2 else { return nil }
        let language = options.messageLanguage
        let title = Set(titles).count == 1
            ? DeskActionWords.fixAllLike(titles[0], count: titles.count, language: language)
            : DeskActionWords.fixAll(count: titles.count, language: language)
        return DeskCodeAction(title: title, kind: .fixAll, edit: DeskWorkspaceEdit(edits), diagnostics: fixed, group: group)
    }

    private func foreignAction(_ family: ForeignFamily,
                               in list: [(diagnostic: DeskServiceDiagnostic, family: ForeignFamily?)]) -> DeskCodeAction? {
        var edits: [DeskFileID: [DeskTextEditU16]] = [:]
        var fixed: [DeskServiceDiagnostic] = []
        var count = 0
        for (d, f) in list where f == family && !d.fixIts.isEmpty {
            // A diagnostic's fix-its of one group each fix a line of a run; otherwise they are alternatives, and
            // the first is taken.
            let grouped = d.fixIts.filter { $0.group != nil }
            let chosen = grouped.count >= 2 ? grouped : [d.fixIts[0]]
            for fix in chosen {
                for (file, e) in fix.edit.files { edits[file, default: []] += e }
            }
            count += chosen.count
            fixed.append(d)
        }
        guard count >= 2 else { return nil }
        let title = DeskActionWords.fixForeign(family, count: count, language: options.messageLanguage)
        return DeskCodeAction(title: title, kind: .fixForeign, edit: DeskWorkspaceEdit(edits), diagnostics: fixed, family: family)
    }

    /// The language a foreign-syntax diagnostic (DK9xxx) found: the foreign line it is on, else its id's.
    func foreignFamily(of d: DeskServiceDiagnostic) -> ForeignFamily? {
        let raw = d.id.rawValue
        guard raw.hasPrefix("DK9"), d.file == file else { return nil }
        let start = index.utf8Offset(ofUTF16: d.range.start.offset)
        let table = nodeTable
        if let i = table.innermost(at: start, where: { $0.kind == .foreignConstruct }),
           let kind = table.entries[i].node.foreignKind {
            return kind.family
        }
        switch d.id {
        case .semicolonComment: return .rainmeter
        case .htmlTag, .htmlAttribute: return .html
        case .cssDeclaration, .cssSelector: return .css
        case .swiftInterpolation, .functionSyntax: return .swift
        default: break
        }
        if raw.hasPrefix("DK93") { return .rainmeter }
        if raw.hasPrefix("DK91") { return .swift }
        return .other
    }

    /// One edit that adds every permission the missing-permission diagnostics (DK8101) name, where the first one's
    /// fix-it adds its own.
    private func addMissingPermissionsAction() -> DeskCodeAction? {
        let missing = checked.diagnostics.enumerated().filter { $0.element.id == .missingPermission && $0.element.file == file }
        guard let first = missing.first, let fix = first.element.fixIts.first, fix.edits.count == 1,
              case .code(let lead)? = first.element.arguments["permission"] else { return nil }
        var names: [String] = []
        for (_, d) in missing {
            if case .code(let name)? = d.arguments["permission"], !names.contains(name) { names.append(name) }
        }
        let written = "." + lead
        var replacement = fix.edits[0].replacement
        guard let at = DeskActionWords.wordRange(of: written, in: replacement) else { return nil }
        replacement.replaceSubrange(at, with: names.map { "." + $0 }.joined(separator: ", "))
        var edit = fix.edits[0]
        edit.replacement = replacement
        guard let workspace = workspaceEdit([edit]) else { return nil }
        let all = diagnostics
        return DeskCodeAction(title: DeskActionWords.addPermissions(names.count, language: options.messageLanguage),
                              kind: .addMissingPermissions, edit: workspace, diagnostics: missing.map { all[$0.offset] })
    }
}

/// The titles of the actions the service makes itself.
enum DeskActionWords {
    static let formatDocument = LocalizedText("Format the file", "整理文件格式")

    static func fixAllLike(_ title: String, count: Int, language: DiagnosticLanguage) -> String {
        LocalizedText("Fix all \(count): \(title)", "全部改正（\(count) 处）：\(title)").text(in: language)
    }

    static func fixAll(count: Int, language: DiagnosticLanguage) -> String {
        LocalizedText("Fix all \(count)", "全部改正（\(count) 处）").text(in: language)
    }

    static func fixForeign(_ family: ForeignFamily, count: Int, language: DiagnosticLanguage) -> String {
        switch family {
        case .other:
            return LocalizedText("Fix all \(count) things written as in other languages",
                                 "改正所有其他语言的写法（\(count) 处）").text(in: language)
        default:
            let name = family.languageName.text(in: language)
            return LocalizedText("Fix all \(count) things written as in \(name)",
                                 "改正所有 \(name) 写法（\(count) 处）").text(in: language)
        }
    }

    static func addPermissions(_ count: Int, language: DiagnosticLanguage) -> String {
        count == 1
            ? LocalizedText("Add the missing permission", "添加缺少的权限").text(in: language)
            : LocalizedText("Add all \(count) missing permissions", "添加缺少的全部 \(count) 项权限").text(in: language)
    }

    /// Where `word` stands in `text` as a whole word (not followed by a letter, digit or `_`).
    static func wordRange(of word: String, in text: String) -> Range<String.Index>? {
        var from = text.startIndex
        while let found = text.range(of: word, range: from..<text.endIndex) {
            if found.upperBound == text.endIndex { return found }
            let next = text[found.upperBound]
            if !(next.isLetter || next.isNumber || next == "_") { return found }
            from = found.upperBound
        }
        return nil
    }
}
