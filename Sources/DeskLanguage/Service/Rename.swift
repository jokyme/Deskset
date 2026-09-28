import Foundation

// Renaming own names (§4.2). A name of one file — a declaration, loop variable, element name, or a widget's own style
// or option — goes through `Desk.apply(.rename)`. A package style or option is renamed in `package.desk` and in every
// widget, with the widgets' declarations that replace it (D99). The new name follows the checker's rules for own
// names: an identifier with a lowercase first letter, no reserved word or block word, at most 128 bytes, not hiding a
// built-in value (DK3029), and not already used where the renamed name is.

extension DeskSnapshot {
    /// The name a rename at a position would change, or why nothing there can be renamed.
    public func prepareRename(at position: DeskPosition) -> Result<DeskRenamePlace, DeskRenameRefusal> {
        guard hasStackRoom else { return onLargeStack { prepareRename(at: position) } }
        let offset = index.utf8Offset(ofUTF16: index.clampedUTF16(position.offset))
        guard let o = symbolIndex.occurrence(at: offset) else {
            return .failure(refusal(isInsideText(offset) ? .insideText : .notAName, name: ""))
        }
        switch o.kind {
        case .translationKey, .asset:
            return .failure(refusal(.insideText, name: o.name))
        case _ where !o.kind.isOwnName:
            return .failure(refusal(.builtIn, name: o.name))
        default:
            break
        }
        guard let key = o.key, renameTarget(key) != nil else { return .failure(refusal(.cannotRename, name: o.name)) }
        return .success(DeskRenamePlace(range: index.range(utf8: o.range), name: o.name, kind: o.kind))
    }

    /// Renames the own name at a position everywhere it is declared and read, in every file that has it.
    public func rename(at position: DeskPosition, to newName: String) -> Result<DeskRename, DeskRenameRefusal> {
        guard hasStackRoom else { return onLargeStack { rename(at: position, to: newName) } }
        let place: DeskRenamePlace
        switch prepareRename(at: position) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let p): place = p
        }
        let offset = index.utf8Offset(ofUTF16: place.range.start.offset)
        guard let o = symbolIndex.occurrence(at: offset), let key = o.key, let target = renameTarget(key) else {
            return .failure(refusal(.cannotRename, name: place.name))
        }
        if newName == o.name { return .success(DeskRename(edit: DeskWorkspaceEdit())) }
        if let refused = validate(newName, kind: o.kind) { return .failure(refused) }
        var notes: [String] = []
        if o.kind == .option {
            notes.append(LocalizedText(
                "People who changed “\(o.name)” in the Options panel get its default back: saved values are kept by the option’s name.",
                "改过“\(o.name)”的人会回到默认值：选项的设置按名字保存。").text(in: options.messageLanguage))
        }
        if o.kind == .saved {
            notes.append(LocalizedText(
                "Values people’s widgets saved under “\(o.name)” are not carried over: saved values are kept by name.",
                "各人的小组件以“\(o.name)”保存的值不会带过去：保存的值按名字存放。").text(in: options.messageLanguage))
        }
        switch target {
        case .inFile(let ref):
            // A widget's own style or option must not take a name the package uses: it would replace the package's.
            if !isPackage, case .style = key, packageNames.styles.contains(newName) {
                return .failure(refusal(.alreadyUsed, name: newName, where: packageFile))
            }
            if !isPackage, case .option = key, packageNames.options.contains(newName) {
                return .failure(refusal(.alreadyUsed, name: newName, where: packageFile))
            }
            let result = Desk.apply(.rename(ref, to: newName), to: checked, catalog: options.catalog)
            if let failure = result.failure {
                if case .notApplicable = failure { return .failure(refusal(.alreadyUsed, name: newName, where: nil)) }
                return .failure(refusal(.cannotRename, name: o.name))
            }
            var edits = result.edits
            // Uses the checker left unresolved in wrong code (a variable read in a style, a `computed` cycle).
            for occurrence in symbolIndex.occurrences(of: key) where occurrence.inferred {
                edits.append(TextEdit(file: file, range: occurrence.range, replacement: newName))
            }
            if case .option = key { edits += localEnumEdits(option: o.name, to: newName, in: [file]) }
            if o.kind == .element, !Checker.isIdentifier(o.name) { edits += quotedTargetEdits(element: o.name, to: newName) }
            edits += translationEdits(renaming: o.name, kind: o.kind, to: newName, after: edits)
            return .success(DeskRename(edit: workspaceEdit(edits), notes: notes))
        case .shared:
            let files = files(searchedFor: key)
            // Styles and options clash only with their own kind (§4.2), in the package and in every widget.
            for file in files {
                guard let other = checkedFile(file) else { continue }
                let taken: Bool
                if case .style = key { taken = other.styles[newName] != nil } else { taken = other.options[newName] != nil }
                if taken { return .failure(refusal(.alreadyUsed, name: newName, where: file)) }
            }
            var edits: [TextEdit] = []
            for file in files {
                guard let fileIndex = symbolIndex(of: file) else { continue }
                for occurrence in fileIndex.occurrences(of: key) {
                    edits.append(TextEdit(file: file, range: occurrence.range, replacement: newName))
                }
            }
            if case .option = key { edits += localEnumEdits(option: o.name, to: newName, in: files) }
            edits += translationEdits(renaming: o.name, kind: o.kind, to: newName, after: edits)
            return .success(DeskRename(edit: workspaceEdit(edits), notes: notes))
        }
    }

    // MARK: Pieces

    enum RenameTarget {
        /// Renamed by `Desk.apply(.rename)` from its declaring node.
        case inFile(NodeID)
        /// A package style or option, renamed in every file.
        case shared
    }

    func renameTarget(_ key: DeskSymbolKey) -> RenameTarget? {
        switch key {
        case .local:
            return symbolIndex.declaringNodes[key].map { .inFile($0) }
        case .style(_, let group), .option(_, let group):
            if group == packageFile && (isPackage || package != nil) { return .shared }
            return symbolIndex.declaringNodes[key].map { .inFile($0) }
        default:
            return nil
        }
    }

    /// The checked file of a file of the folder.
    func checkedFile(_ file: DeskFileID) -> CheckedFile? {
        if file == self.file { return checked }
        if file == packageFile, let package { return package }
        return folderResults()[file]
    }

    /// Whether a UTF-8 offset is inside the text of a string (not in an interpolation's code).
    func isInsideText(_ offset: Int) -> Bool {
        let table = nodeTable
        guard let i = table.innermost(at: offset) else { return false }
        let kind = table.entries[i].kind
        return kind == .stringLiteral || kind == .stringText
    }

    /// The checker's rules for a new own name.
    func validate(_ name: String, kind: DeskNameKind) -> DeskRenameRefusal? {
        guard Checker.isIdentifier(name), let first = name.unicodeScalars.first, !("A"..."Z").contains(first) else {
            return refusal(.invalidName, name: name)
        }
        if Chars.reservedWords[name] != nil { return refusal(.reservedWord, name: name) }
        // The checker lets a style or an option take a block word; `Desk.apply(.rename)` never gives one.
        if Chars.blockWords.contains(name) { return refusal(.reservedWord, name: name) }
        if name.utf8.count > 128 { return refusal(.tooLong, name: name) }
        switch kind {
        case .variable, .saved, .computed, .loopVariable, .element:
            if options.catalog.namespace(named: name) != nil { return refusal(.hidesBuiltIn, name: name) }
        default:
            break
        }
        return nil
    }

    /// A Picker option's own choices are an enum named after it (`look` → `Look`, §4.13); a rename renames the enum
    /// where it is written (`Look.calm`).
    func localEnumEdits(option: String, to newName: String, in files: [DeskFileID]) -> [TextEdit] {
        var edits: [TextEdit] = []
        for file in files {
            guard let fileIndex = symbolIndex(of: file), let oldEnum = localEnumName(of: option, in: file) else { continue }
            let newEnum = DeskSnapshot.localEnumName(for: newName, catalog: options.catalog)
            guard oldEnum != newEnum else { continue }
            let table = fileIndex.table
            for entry in table.entries where entry.kind == .identifierExpr && entry.parent >= 0 {
                let parent = table.entries[entry.parent]
                guard parent.kind == .memberExpr, parent.textStart == entry.textStart else { continue }
                let token = IdentifierExprSyntax(unchecked: entry.positioned).token
                guard token.token.name == oldEnum else { continue }
                edits.append(TextEdit(file: file, range: token.textRange, replacement: newEnum))
            }
        }
        return edits
    }

    /// `show("my title")`, `hide(…)` and `showOrHide(…)` naming an element whose quoted name is not a name
    /// (`.name("my title")`, §4.10): the checker leaves such text to be looked up while the widget runs, so it is no
    /// use of the element; a rename changes it with the element's name, or the button would stop working.
    func quotedTargetEdits(element name: String, to newName: String) -> [TextEdit] {
        let table = nodeTable
        var edits: [TextEdit] = []
        for entry in table.entries where entry.kind == .stringLiteral {
            guard let inner = RenamePlan.quotedName(entry.positioned),
                  StringLiteralSyntax(unchecked: entry.positioned).literalValue == name else { continue }
            // The first argument of a call of show, hide or showOrHide.
            let argument = entry.parent
            guard argument >= 0, table.entries[argument].kind == .argument else { continue }
            let clause = table.entries[argument].parent
            guard clause >= 0, table.entries[clause].kind == .argumentClause,
                  table.children(of: clause).first(where: { table.entries[$0].kind == .argument }) == argument else { continue }
            let call = table.entries[clause].parent
            guard call >= 0, let callee = table.children(of: call).first, callee != clause else { continue }
            let calleeName: String?
            switch table.entries[callee].kind {
            case .callee:
                let target = TargetSyntax(unchecked: table.entries[callee].positioned)
                calleeName = target.members.isEmpty && !target.name.token.isMissing ? target.name.token.name : nil
            case .identifierExpr:
                let token = IdentifierExprSyntax(unchecked: table.entries[callee].positioned).token
                calleeName = token.token.isMissing ? nil : token.token.name
            default:
                calleeName = nil
            }
            guard let calleeName, ["show", "hide", "showOrHide"].contains(calleeName) else { continue }
            edits.append(TextEdit(file: file, range: inner, replacement: newName))
        }
        return edits
    }

    /// The `translations` entries a rename must change with the texts it changes (`"Weather in {options.city}"`):
    /// a translation is found by its text (§8.6), so the names read in its interpolations are no uses, and an entry
    /// left alone would stop matching. A widget's own entries serve its texts, the package's serve every file's; an
    /// entry is changed only when no text left unchanged still has its key.
    func translationEdits(renaming name: String, kind: DeskNameKind, to newName: String, after edits: [TextEdit]) -> [TextEdit] {
        switch kind {
        case .variable, .saved, .computed, .loopVariable, .option: break
        default: return []
        }
        var edited: [DeskFileID: [Range<Int>]] = [:]
        for edit in edits { edited[edit.file, default: []].append(edit.range) }
        var changed: [DeskFileID: Set<String>] = [:]
        var kept: [DeskFileID: Set<String>] = [:]
        for (file, ranges) in edited {
            guard let checkedFile = checkedFile(file) else { continue }
            for entry in checkedFile.stringTable {
                if ranges.contains(where: { entry.range.lowerBound <= $0.lowerBound && $0.upperBound <= entry.range.upperBound }) {
                    changed[file, default: []].insert(entry.key)
                } else {
                    kept[file, default: []].insert(entry.key)
                }
            }
        }
        guard !changed.isEmpty else { return [] }
        var out: [TextEdit] = []
        for (file, keys) in changed where file != packageFile {
            out += translationRewrites(in: file, keys: keys.subtracting(kept[file] ?? []), name: name, kind: kind, to: newName)
        }
        if (isPackage || package != nil), let packageText = folder[packageFile], packageText.contains("translations") {
            let keys = changed.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            var keptKeys = kept.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            for (file, result) in folderResults() where edited[file] == nil {
                keptKeys.formUnion(result.stringTable.map(\.key))
            }
            if edited[packageFile] == nil, let checkedPackage = checkedFile(packageFile) {
                keptKeys.formUnion(checkedPackage.stringTable.map(\.key))
            }
            out += translationRewrites(in: packageFile, keys: keys.subtracting(keptKeys), name: name, kind: kind, to: newName)
        }
        let made = Set(edits.map { "\($0.file.path) \($0.range)" })
        return out.filter { !made.contains("\($0.file.path) \($0.range)") }
    }

    /// The name's reads in the interpolations of a file's `translations` entries whose key is one of `keys`:
    /// `options.<name>` for an option, the bare name otherwise.
    func translationRewrites(in file: DeskFileID, keys: Set<String>, name: String, kind: DeskNameKind, to newName: String) -> [TextEdit] {
        guard !keys.isEmpty, let tree = checkedFile(file)?.tree else { return [] }
        var out: [TextEdit] = []
        for block in tree.rootNode.childNodes where block.kind == .translationsBlock {
            guard let body = block.firstChild(.block) else { continue }
            for group in BlockSyntax(unchecked: body).statements where group.kind == .group {
                guard let groupBlock = group.firstChild(.block) else { continue }
                for entryNode in BlockSyntax(unchecked: groupBlock).statements where entryNode.kind == .entry {
                    let entry = EntrySyntax(unchecked: entryNode)
                    guard keys.contains(Checker.translationKey(of: entry.key)) else { continue }
                    var strings = [entry.key]
                    if let value = StringLiteralSyntax(entry.value.node) { strings.append(value) }
                    for string in strings {
                        for segment in string.segments {
                            guard case .interpolation(let interpolation) = segment else { continue }
                            let tokens = Array(interpolation.node.tokens.dropFirst().dropLast().filter { !$0.token.isMissing })
                            for range in DeskSnapshot.reads(of: name, isOption: kind == .option, in: tokens) {
                                out.append(TextEdit(file: file, range: range, replacement: newName))
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Where an interpolation's tokens read a name: `options.<name>` (not after a `.`) for an option; otherwise the
    /// bare name, not after a `.` and not a call's label.
    static func reads(of name: String, isOption: Bool, in tokens: [PositionedToken]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for (k, token) in tokens.enumerated() where token.kind == .identifier {
            let afterDot = k > 0 && tokens[k - 1].kind == .dot
            if isOption {
                guard !afterDot, token.token.name == "options", k + 2 < tokens.count, tokens[k + 1].kind == .dot,
                      tokens[k + 2].kind == .identifier, tokens[k + 2].token.name == name else { continue }
                out.append(tokens[k + 2].textRange)
            } else {
                guard !afterDot, token.token.name == name else { continue }
                let isLabel = k + 1 < tokens.count && tokens[k + 1].kind == .colon && k > 0
                    && [.lParen, .comma].contains(tokens[k - 1].kind)
                if !isLabel { out.append(token.textRange) }
            }
        }
        return out
    }

    /// The local enum of an option as a file sees it: its own option's, else the package's.
    func localEnumName(of option: String, in file: DeskFileID) -> String? {
        if let own = checkedFile(file)?.options[option] { return own.localEnum }
        return (isPackage ? checked : package)?.options[option]?.localEnum
    }

    /// The name of an option's local enum (the checker's rule): its name capitalized, with `Choice` added when a
    /// built-in type or component has that name.
    static func localEnumName(for option: String, catalog: DeskCatalog) -> String {
        let base = option.prefix(1).uppercased() + option.dropFirst()
        if catalog.component(named: base) != nil || catalog.control(named: base) != nil || catalog.enumeration(base) != nil
            || catalog.record(base) != nil || base == "Color" || base == "Paint" {
            return base + "Choice"
        }
        return base
    }

    /// UTF-8 edits of files of the folder as a workspace edit.
    func workspaceEdit(_ edits: [TextEdit]) -> DeskWorkspaceEdit {
        var files: [DeskFileID: [DeskTextEditU16]] = [:]
        for edit in edits {
            guard let fileIndex = index(of: edit.file) else { continue }
            files[edit.file, default: []].append(DeskTextEditU16(range: fileIndex.range(utf8: edit.range), newText: edit.replacement))
        }
        return DeskWorkspaceEdit(files)
    }

    func refusal(_ reason: DeskRenameRefusal.Reason, name: String, where file: DeskFileID? = nil) -> DeskRenameRefusal {
        let text: LocalizedText
        let place = file.map { $0.path.isEmpty ? "" : $0.path } ?? ""
        switch reason {
        case .notAName:
            text = LocalizedText("Put the cursor on a name you gave, such as a variable, a style or an option.",
                                 "把光标放在自己起的名字上，比如变量、样式或选项。")
        case .builtIn:
            text = LocalizedText("“\(name)” is a built-in name. Only names you gave can be renamed.",
                                 "“\(name)”是内置的名字，只能给自己起的名字改名。")
        case .insideText:
            text = LocalizedText("This is text in quotes, not a name: edit it where it is.",
                                 "这是引号里的文字，不是名字，直接在原处修改。")
        case .invalidName:
            text = LocalizedText("“\(name)” can’t be a name: start with a lowercase letter and use only letters, digits and _.",
                                 "“\(name)”不能做名字：以小写字母开头，只用字母、数字和 _。")
        case .reservedWord:
            text = LocalizedText("“\(name)” is a word of the language and can’t be a name here.",
                                 "“\(name)”是语言本身的词，不能在这里做名字。")
        case .tooLong:
            text = LocalizedText("A name can be at most 128 bytes long.", "名字最长 128 个字节。")
        case .alreadyUsed:
            text = place.isEmpty
                ? LocalizedText("“\(name)” is already used here.", "“\(name)”已经在这里用过了。")
                : LocalizedText("“\(name)” is already used in \(place).", "“\(name)”已经在 \(place) 里用过了。")
        case .hidesBuiltIn:
            text = LocalizedText("“\(name)” would hide the built-in “\(name)”. Choose another name.",
                                 "“\(name)”会遮住内置的“\(name)”，换一个名字吧。")
        case .cannotRename:
            text = LocalizedText("“\(name)” can’t be renamed here. Fix the problem on this line first.",
                                 "这里的“\(name)”不能改名，先改正这一行的问题。")
        }
        return DeskRenameRefusal(reason: reason, message: text.text(in: options.messageLanguage))
    }
}
