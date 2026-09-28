import Foundation

// The checker (§4): it walks the lossless tree once per phase-group and produces the checked model and the
// diagnostics of §6. It never throws and never gives up: a problem drops the smallest unit that contains it
// (§4.1 isolation) and every other part of the widget is still checked.
//
// The checker is split over several files by concern: structure and statements (Checker+Structure), names
// (Checker+Names), expressions and types (Checker+Expressions, Checker+Units, Checker+Calls), modifiers, facets and
// styles (Checker+Modifiers), options, info and translations (Checker+Options), actions, security and limits
// (Checker+Actions, Checker+Security), settling by use (Checker+Settle), foreign syntax (Checker+Foreign).

extension Desk {
    /// Checks one file (§4.20). `package.desk` is recognised by its file name and checked as a package.
    public static func check(_ tree: SyntaxTree, context: CheckContext = CheckContext()) -> CheckedFile {
        let needed = StackGuard.bytesNeeded(toWalk: tree)
        return StackGuard.run(needing: needed) {
            let checker = Checker(tree: tree, context: context)
            return checker.run()
        }
    }

    /// Checks a folder: `package.desk` once, then every widget with it, and what only the whole folder can know
    /// (unused package styles, options and translations), reported once in the package's result.
    public static func checkFolder(package: SyntaxTree?, widgets: [SyntaxTree],
                                   context: CheckContext = CheckContext()) -> [DeskFileID: CheckedFile] {
        checkFolder(package: package, checkedPackage: nil, widgets: widgets.map { ($0, nil) }, context: context)
    }

    /// `checkFolder` reusing results already known: the package checked on its own (with no package in its
    /// context), and widgets already checked with that package.
    static func checkFolder(package: SyntaxTree?, checkedPackage: CheckedFile?,
                            widgets: [(tree: SyntaxTree, checked: CheckedFile?)],
                            context: CheckContext) -> [DeskFileID: CheckedFile] {
        var results: [DeskFileID: CheckedFile] = [:]
        var widgetContext = context
        var packageFile: CheckedFile?
        if let package {
            var packageContext = context
            packageContext.package = nil
            let checked = checkedPackage ?? check(package, context: packageContext)
            packageFile = checked
            widgetContext.package = CheckedPackage(file: checked)
        }
        var usedStyles = Set<String>(), usedOptions = Set<String>(), usedKeys = Set<String>()
        for entry in packageFile?.stringTable ?? [] { usedKeys.insert(entry.key) }
        for (widget, known) in widgets {
            let checked = known ?? check(widget, context: widgetContext)
            results[widget.file] = checked
            for (_, symbol) in checked.symbols {
                switch symbol {
                case .style(let id, let file) where file == package?.file:
                    if let name = packageFile?.styles.first(where: { $0.value == id })?.key { usedStyles.insert(name) }
                case .option(let id, let file) where file == package?.file:
                    if let name = packageFile?.options.first(where: { $0.value.node == id })?.key { usedOptions.insert(name) }
                default: break
                }
            }
            for entry in checked.stringTable { usedKeys.insert(entry.key) }
        }
        if let package, let packageFile {
            // Package styles used by a widget use other package styles and options in their bodies.
            (usedStyles, usedOptions) = FolderChecks.reachable(from: usedStyles, options: usedOptions, in: packageFile)
            results[package.file] = FolderChecks.addUnused(packageFile, tree: package, usedStyles: usedStyles,
                                                           usedOptions: usedOptions, usedKeys: usedKeys,
                                                           catalog: context.catalog)
        }
        return results
    }
}

/// Where a statement or expression is.
enum Place: Equatable {
    case topLevel, widget, views, menu, actions, modifiers, options, info, package, translations, style, state
}

/// An element being checked.
final class ElementNode {
    let id: NodeID
    let node: PositionedNode
    let component: ComponentSpec?
    let kind: ElementKind?
    let parent: ElementNode?
    let insideIf: Bool
    let insideFor: Bool
    var name: String?
    var isRoot = false
    var facts: ElementFacts
    /// Names of the modifiers written on it (for DK5021, DK5014…).
    var modifierNames: [String] = []
    /// Its position and size arguments that reference siblings: sibling name → where.
    var geometryRefs: [(name: String, range: Range<Int>, isPosition: Bool)] = []
    var hasPosition = false
    var positionRange: Range<Int>?
    var positionAnchor: String?
    var named: NodeID?
    /// The children elements, in order.
    var children: [ElementNode] = []
    var ownFacetsAvailable = false

    init(id: NodeID, node: PositionedNode, component: ComponentSpec?, parent: ElementNode?, insideIf: Bool,
         insideFor: Bool) {
        self.id = id
        self.node = node
        self.component = component
        self.kind = component?.kind
        self.parent = parent
        self.insideIf = insideIf
        self.insideFor = insideFor
        self.facts = ElementFacts(component: component?.name ?? "", kind: component?.kind ?? .column, parent: parent?.id,
                                  insideIf: insideIf, insideFor: insideFor)
    }
}

/// The context of an action block.
struct ActionContext {
    /// The event or timing modifier (or `after`, `menu item`) whose block this is.
    var owner: String
    /// Whether actions here are caused by the user (clicks, menu items).
    var userInitiated: Bool
    /// Whether `event` exists here.
    var eventAvailable: Bool
    /// The event record `event` holds.
    var eventRecord: String?
    var element: ElementNode?
    /// The action statement being checked, when a diagnostic needs it (a modifier written on an action call).
    var statement: PositionedNode? = nil
}

/// The context of an expression.
struct ExprContext {
    var place: Place = .views
    var action: ActionContext?
    var element: ElementNode?
    /// References to named siblings are allowed (the x:/y: of `.position`, `.width`, `.height`, `.size`).
    var geometry = false
    /// Inside `.position(…)`'s x: or y: (`4R` means Rainmeter's relative position there).
    var positionAxis: String?
    /// A display position: values become text (§4.5).
    var display = false
    /// Inside a style body: variables, computed values, loop variables, `event` and element names are not allowed.
    var styleName: String?
    /// Inside a declaration initializer: its index in declaration order and keyword.
    var declaration: Decl?
    /// Only literals, lists of literals and implicit members (info fields, `saved` initializers).
    var constantOnly = false
    /// Only options may be read (`.hidden(if:)` on an option control).
    var optionsOnly = false
    /// The modifier the expression is an argument of.
    var modifier: String?
    /// The component, function, modifier or action the expression is an argument of (`open`, `Image`, `.style`).
    var callee: String?
    /// A translatable `info` field (`name`, `description`).
    var translatableField = false
    /// The base of a member access or call (`month` in `month.days`): never the text itself, even where text is
    /// expected (no DK3034 for it).
    var isBase = false
    /// The parameter the expression is passed to.
    var param: ParamSpec?
    var usage: DataUsage = .display
    /// Inside `.onChange(of:)`, `.when(…)`, a `computed` value: logic.
    var loopScope: [NodeID] = []
}

/// A declaration of the widget body.
final class Decl {
    let name: String
    let keyword: String
    let node: PositionedNode
    let nameRange: Range<Int>
    let id: NodeID
    let index: Int
    var val: Val?
    var poisoned = false
    var used = false
    var assigned = false
    var assignedValues: [String] = []
    var open: Int?
    var checking = false
    var initializerDeps: Set<DepKey> = []

    init(name: String, keyword: String, node: PositionedNode, nameRange: Range<Int>, id: NodeID, index: Int) {
        self.name = name
        self.keyword = keyword
        self.node = node
        self.nameRange = nameRange
        self.id = id
        self.index = index
    }
}

/// A loop variable in scope.
struct LoopVariable {
    let name: String
    let id: NodeID
    let forID: NodeID
    var val: Val
    let range: Range<Int>
    let inAction: Bool
}

/// An option of `options { }`.
final class OptionInfo {
    let name: String
    let control: String
    let node: PositionedNode
    let id: NodeID
    let nameRange: Range<Int>
    let file: DeskFileID
    let fromPackage: Bool
    var val: Val
    var used = false
    var assignedNonConstant = false
    var assignedValues: [String] = []
    var defaultText: String?
    var open: Int?
    var localEnum: String?
    var choices: [String] = []
    var userOnly: Bool { ["Secret", "FolderPicker", "ImagePicker"].contains(control) || wholeCommand }
    var wholeCommand = false

    init(name: String, control: String, node: PositionedNode, id: NodeID, nameRange: Range<Int>, file: DeskFileID,
         fromPackage: Bool, val: Val) {
        self.name = name
        self.control = control
        self.node = node
        self.id = id
        self.nameRange = nameRange
        self.file = file
        self.fromPackage = fromPackage
        self.val = val
    }
}

/// A style declaration.
final class StyleInfo {
    let name: String
    let node: PositionedNode
    let id: NodeID
    let nameRange: Range<Int>
    let file: DeskFileID
    let fromPackage: Bool
    var used = false
    /// The modifier apps of its body, in order.
    var modifiers: [PositionedNode] = []
    /// The styles it includes, in order.
    var includes: [StyleInclude] = []
    var hasState = false
    /// Its modifiers as applied (facets, conditions), for expansion at elements.
    var applied: [AppliedModifier] = []

    init(name: String, node: PositionedNode, id: NodeID, nameRange: Range<Int>, file: DeskFileID, fromPackage: Bool) {
        self.name = name
        self.node = node
        self.id = id
        self.nameRange = nameRange
        self.file = file
        self.fromPackage = fromPackage
    }
}

/// An element name given with `.name(…)`.
struct ElementNameInfo {
    let name: String
    let element: ElementNode
    let range: Range<Int>
    let id: NodeID
    let quoted: Bool
}

final class Checker {
    let tree: SyntaxTree
    let file: DeskFileID
    let catalog: DeskCatalog
    let index: CatalogIndex
    let context: CheckContext
    let isPackage: Bool
    let lines: LineTable

    // Output
    var diagnostics: [Diagnostic] = []
    var reportedKeys = Set<String>()
    var symbols: [NodeID: Symbol] = [:]
    var types: [NodeID: SemType] = [:]
    var elementFacts: [NodeID: ElementFacts] = [:]
    var dataUses: [DataUse] = []
    var dependencies: [NodeID: Set<DepKey>] = [:]
    var reactions: [ReactionFacts] = []
    var freeformOrders: [NodeID: [NodeID]] = [:]
    var stringTable: [StringEntry] = []
    var requirements = Requirements()
    var translationTable = TranslationTable()
    var assetUses = AssetUses()

    /// Diagnostics are not recorded while this is above zero (speculative typing of overloads).
    var mute = 0

    // Top level
    var infoBlock: PositionedNode?
    var optionsBlock: PositionedNode?
    var widgetBlock: PositionedNode?
    var translationsBlock: PositionedNode?
    var packageBlock: PositionedNode?
    var infoFields: [String: (node: PositionedNode, value: PositionedNode)] = [:]

    // Names
    var decls: [String: Decl] = [:]
    var declOrder: [Decl] = []
    var options: [String: OptionInfo] = [:]
    var optionOrder: [OptionInfo] = []
    var styles: [String: StyleInfo] = [:]
    var styleOrder: [StyleInfo] = []
    var elementNames: [String: ElementNameInfo] = [:]
    var loopStack: [LoopVariable] = []
    var rootElements: [ElementNode] = []
    var allElements: [ElementNode] = []
    var freeforms: [ElementNode] = []

    // Settling by use
    var openSlots: [OpenSlot] = []

    // Security and requirements
    var neededPermissions: [String: Range<Int>] = [:]
    var neededPermissionOrder: [String] = []
    var usedHosts: [String] = []
    var hostUses: [(host: String, range: Range<Int>)] = []
    var minimumVersion = AppVersion.deskFirstRelease
    var commandFacts: [CommandFacts] = []

    // Misc
    var preset: String = "fit"
    var convertedFile = false
    var requiresNewer: AppVersion?
    var estimatedElements = 0
    var translatableStrings: [String: [Range<Int>]] = [:]
    var pendingLiteralReachesTranslatable: [NodeID] = []
    var foreignLineCount = 0
    var computedDepsCache: [String: Set<DepKey>] = [:]
    var preNames: [PreName] = [] {
        didSet { preNameIndex = nil }
    }
    /// The first `PreName` of each name (built on first lookup: references are looked up once per use).
    var preNameIndex: [String: Int]?

    func preName(named name: String) -> PreName? {
        if preNameIndex == nil {
            var index: [String: Int] = [:]
            for (i, pre) in preNames.enumerated() where index[pre.name] == nil { index[pre.name] = i }
            preNameIndex = index
        }
        return preNameIndex![name].map { preNames[$0] }
    }
    var pendingVariableFromData: [Decl] = []
    /// Picker choices that form a local enum (`Theme` → its cases).
    var localEnums: [String: [String]] = [:]
    var localEnumNames: Set<String> { Set(localEnums.keys) }
    var pendingAmbiguous: (name: String, candidates: [String], range: Range<Int>)?
    var manualConversionReported: [Range<Int>] = []
    var optionAssignmentDeps: [String: Set<DepKey>] = [:]
    var variableAssignmentDeps: [String: Set<DepKey>] = [:]
    var pickerChoiceRanges: [String: [(String, Range<Int>)]] = [:]
    var declaredPermissions: [(String, Range<Int>, PositionedNode)] = []
    var declaredHosts: [(String, Range<Int>)] = []
    var packageReplaced: [String: OptionInfo] = [:]
    var pendingOptionSources: [(ParamRole, [String], Range<Int>)] = []
    var stateStyleCalls: [(String, CandidateCondition, PositionedNode, ElementNode?)] = []
    var duplicateDropped = Set<Int>()
    var trailingActionBlocks = Set<Int>()
    /// DK3015 diagnostics whose rename fix-it is completed at the end, when every use of the name is known:
    /// the diagnostic's index, the declaration's range, the new name and the symbol the uses resolve to.
    var reservedRenames: [(index: Int, declaration: Range<Int>, newName: String, target: Symbol)] = []
    /// Set by `checkOwnName` when it refused a reserved or block word (the name is still registered so that its
    /// uses resolve to it and are renamed with it).
    var lastRefusedAsReserved = false
    var pendingReservedName: (index: Int, declaration: Range<Int>, newName: String)?
    /// Names with a foreign-table row keyed on their arguments: modifiers (`.padding(.horizontal, …)`) and
    /// components (`Image(systemName:)`); most calls have none, so the rows are only read for these.
    lazy var foreignArgumentNames: (modifiers: Set<String>, components: Set<String>) = {
        var modifiers = Set<String>(), components = Set<String>()
        for row in catalog.foreign {
            switch row.pattern {
            case .modifierWithArgument(let name, let argument) where argument.hasPrefix("."): modifiers.insert(name)
            case .call(let name, let label) where !label.isEmpty: components.insert(name)
            default: break
            }
        }
        return (modifiers, components)
    }()
    /// Implicit members (by start) whose foreign spelling an enclosing fix-it already rewrites (`.leading` in
    /// `VStack(alignment: .leading)`): not reported again.
    var foreignArgumentsHandled = Set<Int>()
    /// Names assigned without a declaration (DK3035): their reads are not reported again (DK3002).
    var provisionalNames = Set<String>()
    /// Cases assigned to a declaration whose type was still open (`side = .right`), checked once it settles.
    var casesForOpenSlots: [(slot: Int, name: String, range: Range<Int>)] = []
    /// DK5007 fix-its completed at the end: the diagnostic, the style, the condition and where it is removed.
    var styleConditionMoves: [(index: Int, style: String, condition: String, removal: Range<Int>)] = []
    /// Diagnostics left to the folder check (see `CheckedFile.folderPending`).
    var folderPending: [Diagnostic] = []
    /// Names the DK7016 fix-its have declared so far (each fix-it gets its own).
    var looksVariables: [String] = []
    var loopIdentities: [NodeID: String] = [:]

    init(tree: SyntaxTree, context: CheckContext) {
        self.tree = tree
        self.file = tree.file
        self.catalog = context.catalog
        self.index = context.catalog.index
        self.context = context
        self.isPackage = (tree.file.path as NSString).lastPathComponent == "package.desk"
        self.lines = tree.lines
    }

    /// Completes the rename fix-its of DK3015: the declaration and every use that resolved to it (§1.5, §9.4).
    func completeReservedRenames() {
        for pending in reservedRenames where pending.index < diagnostics.count {
            var ranges: Set<Range<Int>> = [pending.declaration]
            let length = pending.declaration.count
            for (use, symbol) in symbols where symbol == pending.target {
                ranges.insert(use.utf8Start..<(use.utf8Start + length))
            }
            let edits = ranges.sorted { $0.lowerBound < $1.lowerBound }.map { edit($0, pending.newName) }
            let title = pending.newName == "item" ? "renameTo" : "rename"
            diagnostics[pending.index].fixIts = [fix(title, edits, ["text": .code(pending.newName)])]
        }
    }

    func run() -> CheckedFile {
        var root: NodeID?
        let versionOK = checkDeskVersion()
        if versionOK {
            let size = tree.text.utf8.count
            if size > catalog.limits.maximumFileBytes, !tree.diagnostics.contains(where: { $0.id == .fileTooLarge }) {
                report(.fileTooLarge, catalog.limits.maximumFileBytes..<size)
            }
            checkStructure()
            completeReservedRenames()
            completeStyleConditionMoves()
            enrichParserDiagnostics()
            root = rootElements.count == 1 ? rootElements[0].id : nil
            finish()
        } else {
            enrichParserDiagnostics()
        }
        return result(root: root)
    }

    private func result(root: NodeID?) -> CheckedFile {
        var all = tree.diagnostics.filter { !droppedParserDiagnostics.contains(diagnosticKey($0)) }
        all = all.map { d in replacedParserDiagnostics[diagnosticKey(d)] ?? d }
        all += diagnostics
        all = all.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            if x.file.path != y.file.path { return x.file.path < y.file.path }
            if x.range.lowerBound != y.range.lowerBound { return x.range.lowerBound < y.range.lowerBound }
            return a.offset < b.offset
        }.map(\.element)
        let limit = catalog.limits.maximumDiagnosticsPerFile
        if all.count > limit {
            let extra = all.count - limit
            let last = all[limit - 1]
            all = Array(all.prefix(limit))
            all.append(Diagnostic(id: .tooManyProblems, severity: .info, file: file, range: last.range,
                                  arguments: ["count": .number(extra)]))
        }
        requirements.minimumAppVersion = minimumVersion
        requirements.commands = commandFacts
        requirements.hosts = usedHosts
        var optionFacts: [String: OptionFacts] = [:]
        for option in optionOrder where !option.fromPackage {
            optionFacts[option.name] = OptionFacts(name: option.name, control: option.control, type: option.val.type,
                                                   displayBase: option.val.base, defaultText: option.defaultText,
                                                   scope: isPackage ? .package : .widget, node: option.id,
                                                   localEnum: option.localEnum, choices: option.choices)
        }
        var styleIDs: [String: NodeID] = [:]
        for style in styleOrder where !style.fromPackage { styleIDs[style.name] = style.id }
        var checked = CheckedFile(tree: tree, diagnostics: all, symbols: symbols, types: types, elements: elementFacts,
                                  dataUses: dataUses, dependencies: dependencies, reactions: reactions,
                                  freeformOrders: freeformOrders, stringTable: stringTable, requirements: requirements,
                                  options: optionFacts, styles: styleIDs, translations: translationTable, root: root)
        checked.loopIdentities = loopIdentities
        checked.assets = assetUses
        checked.folderPending = folderPending
        for decl in declOrder where !decl.poisoned {
            guard let val = decl.val, !val.error, val.open == nil else { continue }
            checked.declarationTypes[decl.id] = SemType(type: val.type, displayBase: val.base, range: val.range)
        }
        return checked
    }

    var droppedParserDiagnostics = Set<String>()
    var replacedParserDiagnostics: [String: Diagnostic] = [:]

    func diagnosticKey(_ d: Diagnostic) -> String { "\(d.id.rawValue)@\(d.range.lowerBound)-\(d.range.upperBound)" }

    // MARK: - Reporting

    /// Records a diagnostic (unless muted). The severity comes from the catalog unless given.
    @discardableResult
    func report(_ id: DiagnosticID, _ range: Range<Int>, _ arguments: [String: DiagnosticArgument] = [:],
                notes: [Note] = [], fixIts: [FixIt] = [], dropped: DroppedUnit? = nil, severity: Severity? = nil,
                file: DeskFileID? = nil) -> Bool {
        guard mute == 0 else { return false }
        let key = "\(id.rawValue)@\(range.lowerBound)-\(range.upperBound)"
        guard reportedKeys.insert(key).inserted else { return false }
        let severity = severity ?? catalog.diagnostic(id)?.severity ?? .error
        // A fix-it that changes nothing is never offered (§9.4).
        let fixIts = fixIts.filter { fix in fix.edits.contains { !($0.range.isEmpty && $0.replacement.isEmpty) } }
        diagnostics.append(Diagnostic(id: id, severity: severity, file: file ?? self.file, range: range,
                                      arguments: arguments, notes: notes, fixIts: fixIts, dropped: dropped))
        return true
    }

    /// Whether an error was reported at exactly this range.
    func hasReported(_ id: DiagnosticID, at range: Range<Int>) -> Bool {
        reportedKeys.contains("\(id.rawValue)@\(range.lowerBound)-\(range.upperBound)")
    }

    func edit(_ range: Range<Int>, _ replacement: String) -> TextEdit {
        TextEdit(file: file, range: range, replacement: replacement)
    }

    func fix(_ titleKey: String, _ edits: [TextEdit], _ arguments: [String: DiagnosticArgument] = [:],
             group: String? = nil) -> FixIt {
        FixIt(titleKey: titleKey, titleArguments: arguments, edits: edits, group: group)
    }

    func note(_ key: String, _ range: Range<Int>, _ arguments: [String: DiagnosticArgument] = [:],
              file: DeskFileID? = nil) -> Note {
        Note(file: file ?? self.file, range: range, messageKey: key, arguments: arguments)
    }

    /// Runs `body` with diagnostics and use-recording switched off.
    func speculate<T>(_ body: () -> T) -> T {
        mute += 1
        defer { mute -= 1 }
        return body()
    }

    // MARK: - Positions and text

    func id(_ node: PositionedNode) -> NodeID {
        NodeID(kind: node.kind, utf8Start: textStart(node), treeVersion: tree.version)
    }

    /// Start of the first present token's text (fast: stops at that token).
    func textStart(_ node: PositionedNode) -> Int {
        var result: Int?
        node.node.walkTokens(base: node.offset) { token, at in
            if token.isMissing { return true }
            result = at + token.leadingTrivia.utf8Length
            return false
        }
        return result ?? node.offset
    }

    /// End of the last present token's text, walking backwards.
    func textEnd(_ node: PositionedNode) -> Int {
        func last(_ n: SyntaxNode, end: Int) -> Int? {
            var at = end
            for child in n.children.reversed() {
                switch child {
                case .token(let t):
                    if !t.isMissing { return at - t.trailingTrivia.utf8Length }
                    at -= t.utf8Length
                case .node(let c):
                    if let r = last(c, end: at) { return r }
                    at -= c.byteLength
                }
            }
            return nil
        }
        return last(node.node, end: node.offset + node.node.byteLength) ?? textStart(node)
    }

    func range(_ node: PositionedNode) -> Range<Int> {
        let start = textStart(node)
        return start..<max(start, textEnd(node))
    }

    func range(_ token: PositionedToken) -> Range<Int> { token.textRange }

    func text(_ node: PositionedNode) -> String { node.node.trimmedText }

    func text(_ range: Range<Int>) -> String {
        let utf8 = tree.text.utf8
        let lower = utf8.index(utf8.startIndex, offsetBy: max(0, min(range.lowerBound, utf8.count)))
        let upper = utf8.index(utf8.startIndex, offsetBy: max(0, min(range.upperBound, utf8.count)))
        return String(tree.text[lower..<upper])
    }

    func line(_ offset: Int) -> Int { lines.location(of: offset).line }

    /// The indentation of the line `offset` is on.
    func indentation(at offset: Int) -> String {
        let bytes = Array(tree.text.utf8)
        var start = min(offset, bytes.count)
        while start > 0, bytes[start - 1] != 0x0A, bytes[start - 1] != 0x0D { start -= 1 }
        var end = start
        while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// The file's most frequent line break (LF when tied).
    var lineBreak: String { lines.newline }

    // MARK: - Version

    /// DK8301: a newer language version is the only diagnostic (§8.5).
    func checkDeskVersion() -> Bool {
        if let version = tree.header.deskVersion, version > catalog.limits.deskVersion {
            var range = 0..<0
            for item in tree.rootNode.childNodes where item.kind == .infoBlock || item.kind == .packageBlock {
                if let block = item.firstChild(.block) {
                    for field in block.children(.field) where field.firstChild(.label)?.childTokens.first?.token.text == "deskVersion" {
                        range = self.range(field)
                    }
                }
            }
            report(.deskVersionTooNew, range, ["version": .code(String(version)),
                                               "max": .code(String(catalog.limits.deskVersion))])
            return false
        }
        if let requires = tree.header.requires, requires > context.appVersion { requiresNewer = requires }
        return true
    }

    /// Notes a catalog item's `since` for the minimum App version, and reports it when the target is older (DK8302).
    func noteSince(_ since: AppVersion, name: String, at range: Range<Int>) {
        if since > minimumVersion { minimumVersion = since }
        if since > context.targetAppVersion {
            report(.needsNewerApp, range, ["name": .code(name), "version": .code(since.description),
                                           "target": .code(context.targetAppVersion.description)])
        }
        // Deprecation is looked up by the caller.
    }
}

/// Folder-level checks added to the package's result (§4.20).
enum FolderChecks {
    /// The package styles and options reached from the ones widgets use: a used style's body uses other styles
    /// (`.style(base)`) and options (`options.accent`).
    static func reachable(from styles: Set<String>, options: Set<String>, in package: CheckedFile) -> (Set<String>, Set<String>) {
        let tree = package.tree
        let nameOfStyle = Dictionary(package.styles.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        let nameOfOption = Dictionary(package.options.map { ($0.value.node, $0.key) }, uniquingKeysWith: { a, _ in a })
        // What each style's body refers to.
        var refersTo: [String: (styles: [String], options: [String])] = [:]
        let bodies: [(String, Range<Int>)] = package.styles.compactMap { name, id in tree.resolve(id).map { (name, $0.range) } }
        for (use, symbol) in package.symbols {
            guard let (owner, _) = bodies.first(where: { $0.1.contains(use.utf8Start) }) else { continue }
            switch symbol {
            case .style(let id, let file) where file == tree.file:
                if let name = nameOfStyle[id], name != owner { refersTo[owner, default: ([], [])].styles.append(name) }
            case .option(let id, let file) where file == tree.file:
                if let name = nameOfOption[id] { refersTo[owner, default: ([], [])].options.append(name) }
            default:
                break
            }
        }
        var usedStyles = styles, usedOptions = options
        var work = Array(styles)
        while let style = work.popLast() {
            for option in refersTo[style]?.options ?? [] { usedOptions.insert(option) }
            for next in refersTo[style]?.styles ?? [] where usedStyles.insert(next).inserted { work.append(next) }
        }
        return (usedStyles, usedOptions)
    }

    static func addUnused(_ checked: CheckedFile, tree: SyntaxTree, usedStyles: Set<String>, usedOptions: Set<String>,
                          usedKeys: Set<String>, catalog: DeskCatalog) -> CheckedFile {
        var extra: [Diagnostic] = []
        for (name, id) in checked.styles where !usedStyles.contains(name) {
            let range = id.utf8Start..<(id.utf8Start + 5)
            extra.append(Diagnostic(id: .unusedStyle, severity: .warning, file: tree.file, range: range,
                                    arguments: ["name": .code(name)]))
        }
        for (name, option) in checked.options where !usedOptions.contains(name) {
            extra.append(Diagnostic(id: .unusedOption, severity: .warning, file: tree.file,
                                    range: option.node.utf8Start..<(option.node.utf8Start + name.utf8.count),
                                    arguments: ["name": .code(name)]))
        }
        // Translations no text of the folder uses (DK8403), decided here.
        for d in checked.folderPending where d.id == .unusedTranslation {
            guard case .code(let key)? = d.arguments["key"], !usedKeys.contains(key) else { continue }
            extra.append(d)
        }
        guard !extra.isEmpty else { return checked }
        let all = (checked.diagnostics + extra).sorted { $0.range.lowerBound < $1.range.lowerBound }
        var result = CheckedFile(tree: checked.tree, diagnostics: all, symbols: checked.symbols, types: checked.types,
                                 elements: checked.elements, dataUses: checked.dataUses, dependencies: checked.dependencies,
                                 reactions: checked.reactions, freeformOrders: checked.freeformOrders,
                                 stringTable: checked.stringTable, requirements: checked.requirements,
                                 options: checked.options, styles: checked.styles, translations: checked.translations,
                                 root: checked.root)
        result.loopIdentities = checked.loopIdentities
        result.assets = checked.assets
        result.declarationTypes = checked.declarationTypes
        return result
    }
}
