import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private enum TemplateFixtureError: Error { case missing }

private final class TemplateConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DeskCompilationResult] = []
    func append(_ value: DeskCompilationResult) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func snapshot() -> [DeskCompilationResult] { lock.lock(); defer { lock.unlock() }; return values }
}

func runDeskTemplateIdentityTests(_ t: TestRunner) {
    func compile(_ text: String, previous: DeskCompilationResult? = nil,
                 moves: [TextMove] = []) throws -> DeskCompilationResult {
        try compileChecked(deskCheck(text), previous: previous, moves: moves)
    }
    func compileChecked(_ checked: CheckedFile, previous: DeskCompilationResult? = nil,
                        moves: [TextMove] = []) throws -> DeskCompilationResult {
        let result = Desk.compile(checked, previous: previous, moves: moves)
        t.check(result.diagnostics.allSatisfy { $0.severity != .error }, deskDescribe(checked))
        t.check(result.issues.isEmpty, "\(result.issues)")
        guard let program = result.program, let map = result.sourceMap else { throw TemplateFixtureError.missing }
        _ = try ProgramRuntime(program: program)
        var pending = [program.root], ids = Set<ElementID>()
        while let node = pending.popLast() {
            t.check(ids.insert(node.id).inserted)
            switch node.content {
            case .column(_, _, let children), .row(_, _, let children), .freeform(_, let children):
                pending.append(contentsOf: children)
            case .conditional(let value):
                pending.append(contentsOf: value.otherwise)
                for branch in value.branches { pending.append(contentsOf: branch.body) }
            default: break
            }
        }
        t.equal(ids, Set(map.elements.values.map(\.elementID)))
        for site in map.irNodes.values { t.equal(map.nodes[site.reference], site.source) }
        t.equal(Set(map.elements.values.map(\.elementID)).count, map.elements.count)
        t.equal(map.treeVersion, checked.tree.version)
        for (id, ref) in result.elementRefs {
            t.equal(map.elements[TemplateID(id.index)]?.reference, ref)
            t.check(checked.tree.resolve(ref) != nil)
        }
        return result
    }
    func elements(_ result: DeskCompilationResult, component: String? = nil) -> [DeskSourceMap.Element] {
        result.sourceMap!.elements.values.filter { component == nil || $0.component == component }
            .sorted { $0.source.range.lowerBound < $1.source.range.lowerBound }
    }
    func named(_ result: DeskCompilationResult, _ name: String) throws -> DeskSourceMap.Element {
        guard let element = elements(result).first(where: { $0.name == name }) else { throw TemplateFixtureError.missing }
        return element
    }

    t.suite("Desk: template identity: insert delete edit text and declarations") {
        let a = try compile(#"widget { Column { Text("CPU"); Progress(50%) } }"#)
        let b = try compile(#"widget { computed value = 1; Column { Icon("star"); Text("CPU load"); Progress(60%) } }"#, previous: a)
        t.equal(a.program!.root.id, b.program!.root.id)
        t.equal(elements(a, component: "Text")[0].elementID, elements(b, component: "Text")[0].elementID)
        t.equal(elements(a, component: "Progress")[0].elementID, elements(b, component: "Progress")[0].elementID)
        let c = try compile(#"widget { Column { Text("CPU load"); Progress(60%) } }"#, previous: b)
        t.equal(Set(elements(a).map(\.elementID)), Set(elements(c).map(\.elementID)))
        let d = try compile(#"widget { Column { Icon("moon"); Text("CPU load"); Progress(60%) } }"#, previous: c)
        t.check(elements(d, component: "Icon")[0].templateID.rawValue > elements(b, component: "Icon")[0].templateID.rawValue)
    }
    t.suite("Desk: template identity: implicit root appears and disappears without stealing leaf ID") {
        let a = try compile(#"widget { Progress(50%) }"#)
        let b = try compile(#"widget { Text("Load"); Progress(50%) }"#, previous: a)
        let c = try compile(#"widget { Progress(60%) }"#, previous: b)
        t.equal(elements(a, component: "Progress")[0].elementID, elements(b, component: "Progress")[0].elementID)
        t.equal(a.program!.root.id, c.program!.root.id)
        t.check(b.program!.root.id != a.program!.root.id)
    }
    t.suite("Desk: template identity: adjacent unnamed components use argument ties not argument keys") {
        let a = try compile(#"widget { Column { Text("A"); Text("B") } }"#)
        let b = try compile(#"widget { Column { Text("new"); Text("A"); Text("B") } }"#, previous: a)
        let x = elements(a, component: "Text"), y = elements(b, component: "Text")
        t.equal(x.map(\.elementID), Array(y.dropFirst()).map(\.elementID))
        let c = try compile(#"widget { Column { Text("new"); Text("changed"); Text("B") } }"#, previous: b)
        t.equal(y.map(\.elementID), elements(c, component: "Text").map(\.elementID))
        let d = try compile(#"widget { Column { Text("changed"); Text("B") } }"#, previous: c)
        t.equal(x.map(\.elementID), elements(d, component: "Text").map(\.elementID))
    }
    t.suite("Desk: template identity: name LCS outranks arguments and gap fallback keeps renamed elements") {
        let a = try compile(#"widget { Column { Text("A").name(first); Text("B").name(second); Icon("star") } }"#)
        let b = try compile(#"widget { Column { Text("B").name(first); Text("A").name(second); Icon("moon").name(icon) } }"#, previous: a)
        t.equal(try named(a, "first").elementID, try named(b, "first").elementID)
        t.equal(try named(a, "second").elementID, try named(b, "second").elementID)
        t.equal(elements(a, component: "Icon")[0].elementID, try named(b, "icon").elementID)
        let c = try compile(#"widget { Column { Text("B").name(renamed); Text("A").name(second); Icon("moon").name(icon) } }"#, previous: b)
        t.equal(try named(b, "first").elementID, try named(c, "renamed").elementID)
    }
    t.suite("Desk: template identity: parent matching precedes child ties and unmatched parents isolate children") {
        let a = try compile(#"widget { Column { Row { Text("A") }.name(left); Row { Text("B") }.name(right) } }"#)
        let b = try compile(#"widget { Column { Row { Text("B") }.name(left); Row { Text("A") }.name(right) } }"#, previous: a)
        t.equal(elements(a, component: "Text").map(\.elementID), elements(b, component: "Text").map(\.elementID))
        let c = try compile(#"widget { Column { Freeform { Text("B") }; Row { Text("A") }.name(right) } }"#, previous: b)
        t.check(elements(c, component: "Text")[0].elementID != elements(b, component: "Text")[0].elementID)
        t.equal(elements(c, component: "Text")[1].elementID, elements(b, component: "Text")[1].elementID)
    }
    t.suite("Desk: template identity: real wrap unwrap and inverse move undo preserve descendants") {
        let checked = deskCheck("widget {\n    Row {\n        Text(\"甲😀\").name(label)\n    }.name(row)\n    Text(\"B\").name(other)\n}\n")
        let a = try compileChecked(checked)
        let row = try named(a, "row")
        let wrap = Desk.apply(.wrap([row.reference], container: "Column"), to: checked.tree)
        t.equal(wrap.failure, nil); t.check(!wrap.moves.isEmpty)
        let b = try compileChecked(Desk.check(wrap.tree), previous: a, moves: wrap.moves)
        for name in ["row", "label", "other"] { t.equal(try named(a, name).elementID, try named(b, name).elementID) }
        let wrapper = elements(b, component: "Column")[0]
        let unwrap = Desk.apply(.unwrap(wrapper.reference), to: wrap.tree)
        t.equal(unwrap.failure, nil)
        let c = try compileChecked(Desk.check(unwrap.tree), previous: b, moves: unwrap.moves)
        for name in ["row", "label", "other"] { t.equal(try named(a, name).elementID, try named(c, name).elementID) }
        let undo = try compileChecked(Desk.check(checked.tree), previous: b,
                                      moves: wrap.moves.map { TextMove(from: $0.to, to: $0.from) })
        for name in ["row", "label", "other"] { t.equal(try named(a, name).elementID, try named(undo, name).elementID) }
    }
    t.suite("Desk: template identity: cross-parent editor moves outrank identical siblings") {
        let checked = deskCheck("widget {\n    Column {\n        Row {\n            Text(\"same\").name(moving)\n        }.name(left)\n        Row {\n            Text(\"same\").name(staying)\n        }.name(right)\n    }\n}\n")
        let a = try compileChecked(checked)
        let right = try named(a, "right"), moving = try named(a, "moving")
        let block = CallStmtSyntax(checked.tree.resolve(right.reference)!)!.block!
        let edit = Desk.apply(.moveStatement(moving.reference, to: checked.tree.id(of: block.node), index: 1), to: checked.tree)
        t.equal(edit.failure, nil); t.check(!edit.moves.isEmpty)
        let withoutHint = try compileChecked(Desk.check(edit.tree), previous: a)
        t.check(try named(withoutHint, "moving").elementID != moving.elementID)
        let b = try compileChecked(Desk.check(edit.tree), previous: a, moves: edit.moves)
        for name in ["left", "right", "moving", "staying"] { t.equal(try named(a, name).elementID, try named(b, name).elementID) }
        t.equal(try named(b, "moving").parent, try named(b, "right").templateID)
    }
    t.suite("Desk: template identity: branching undo history does not reuse removed or future IDs") {
        let a = try compile(#"widget { Column { Text("A") } }"#)
        let b = try compile(#"widget { Column { Text("A"); Icon("star") } }"#, previous: a)
        let c = try compile(#"widget { Column { Text("A"); Progress(50%) } }"#, previous: a)
        let d = try compile(#"widget { Column { Text("A"); Icon("moon") } }"#, previous: a)
        let ids = [elements(b, component: "Icon")[0].templateID, elements(c, component: "Progress")[0].templateID,
                   elements(d, component: "Icon")[0].templateID]
        t.equal(Set(ids).count, 3)
        t.check(ids[0].rawValue < ids[1].rawValue && ids[1].rawValue < ids[2].rawValue)
    }
    t.suite("Desk: template identity: stable IDs never qualify stale edit or checked receipts") {
        let old = deskCheck(#"widget { Text("A").name(label) }"#)
        let a = try compileChecked(old)
        let current = deskCheck(#"widget { Text("B").name(label) }"#)
        let b = try compileChecked(current, previous: a)
        let oldRef = try named(a, "label").reference, newRef = try named(b, "label").reference
        t.equal(a.program!.root.id, b.program!.root.id); t.check(oldRef != newRef)
        t.check(current.tree.resolve(oldRef) == nil)
        t.equal(Desk.apply(.removeStatement(oldRef), to: current.tree).failure, .staleReference)
        t.equal(Desk.apply(.removeStatement(newRef), to: current.tree).failure, nil)
        let forged = CheckedFile(tree: current.tree, diagnostics: current.diagnostics,
            symbols: current.symbols, types: current.types, elements: old.elements, dataUses: current.dataUses,
            dependencies: current.dependencies, reactions: current.reactions, freeformOrders: current.freeformOrders,
            stringTable: current.stringTable, requirements: current.requirements)
        let rejected = Desk.compile(forged, previous: a)
        t.check(rejected.program == nil); t.check(rejected.sourceMap == nil); t.check(rejected.elementRefs.isEmpty)
        let bad = Desk.compile(deskCheck("widget { Text(unknown) }"), previous: a)
        t.check(bad.program == nil); t.check(bad.sourceMap == nil)
        let recovered = try compileChecked(current, previous: a)
        t.equal(recovered.program!.root.id, a.program!.root.id)
    }
    t.suite("Desk: template identity: conditional branches retain separate parents and all source locations") {
        let a = try compile(#"widget { Column { if true { Text("A") } else { Text("B") }; Icon("star") } }"#)
        let b = try compile(#"widget { Column { if false { Text("B") } else { Text("A") }; Icon("star") } }"#, previous: a)
        t.equal(elements(a).map(\.elementID), elements(b).map(\.elementID))
        t.equal(elements(b, component: "@if").count, 1)
        t.equal(b.sourceMap!.elements.count, 5)
        t.equal(b.elementRefs.count, 4)
    }
    t.suite("Desk: template identity: style origins point to definition and own source not previous snapshots") {
        let text = #"widget { Text("A").style(label).padding(2) }"# + "\n" + #"style label { .font(12).color(.dim) }"#
        let a = try compile(text)
        let b = try compile(text.replacingOccurrences(of: "12", with: "14"), previous: a)
        t.equal(a.program!.root.id, b.program!.root.id)
        let map = b.sourceMap!
        t.check(map.origins.keys.contains { if case .style = $0 { return true }; return false })
        t.check(map.origins.keys.contains { if case .own = $0 { return true }; return false })
        for (origin, range) in map.origins {
            let ref: NodeID
            switch origin { case .own(let id), .style(_, let id, _): ref = id }
            t.equal(map.nodes[ref], range); t.equal(ref.treeVersion, map.treeVersion)
        }
    }

    t.suite("Desk: template identity: fallback never crosses matched neighbours") {
        let a = try compile(#"widget { Column { Text("old").name(before); Icon("star").name(anchor) } }"#)
        let b = try compile(#"widget { Column { Icon("star").name(anchor); Text("new").name(after) } }"#, previous: a)
        t.equal(try named(a, "anchor").elementID, try named(b, "anchor").elementID)
        t.check(try named(a, "before").elementID != named(b, "after").elementID)
    }
    t.suite("Desk: template identity: wrapping a sole root reserves the old root for its moved call") {
        let checked = deskCheck("widget {\n    Row {\n        Text(\"A\").name(child)\n    }.name(root)\n}\n")
        let a = try compileChecked(checked)
        let wrap = Desk.apply(.wrap([try named(a, "root").reference], container: "Column"), to: checked.tree)
        t.equal(wrap.failure, nil)
        let b = try compileChecked(Desk.check(wrap.tree), previous: a, moves: wrap.moves)
        t.equal(try named(a, "root").elementID, try named(b, "root").elementID)
        t.equal(try named(a, "child").elementID, try named(b, "child").elementID)
        t.check(b.program!.root.id != a.program!.root.id)
        let unwrap = Desk.apply(.unwrap(elements(b, component: "Column")[0].reference), to: wrap.tree)
        t.equal(unwrap.failure, nil)
        let c = try compileChecked(Desk.check(unwrap.tree), previous: b, moves: unwrap.moves)
        t.equal(c.program!.root.id, a.program!.root.id)
    }
    t.suite("Desk: template identity: package style origins remain file and version qualified") {
        let package = deskCheck(#"package { name: "Shared" }"# + "\n" + #"style label { .font(12).color(.dim) }"#, file: "package.desk")
        let checked = deskCheck(#"widget { Text("A").style(label) }"#,
                                context: CheckContext(package: CheckedPackage(file: package)))
        let result = Desk.compile(checked, package: package)
        t.check(result.issues.isEmpty, "\(result.issues)")
        guard let map = result.sourceMap else { throw TemplateFixtureError.missing }
        let styles = map.origins.filter { if case .style = $0.key { return true }; return false }
        t.check(!styles.isEmpty)
        for (origin, range) in styles {
            guard case .style(_, let ref, let file) = origin else { continue }
            t.equal(file, package.tree.file); t.equal(range.file, package.tree.file)
            t.equal(map.nodes[ref], range)
            t.check(checked.tree.resolve(ref) == nil)
            t.equal(package.tree.resolve(ref)?.textRange, range.range)
        }
    }
    t.suite("Desk: template identity: hundreds of sibling ties preserve document order and fresh indices") {
        let body = (0..<240).map { "Text(\"item \($0)\")" }.joined(separator: "; ")
        let a = try compile("widget { Column { \(body) } }")
        t.equal(elements(a, component: "Text").map { $0.templateID.rawValue }, Array(1...240))
        let b = try compile("widget { Column { Text(\"new\"); \(body) } }", previous: a)
        t.equal(elements(a, component: "Text").map(\.elementID),
                Array(elements(b, component: "Text").dropFirst()).map(\.elementID))
        t.equal(elements(b, component: "Text")[0].templateID.rawValue, 241)
    }

    t.suite("Desk: template identity: allocation watermark is not the per-program element budget") {
        var catalog = DeskCatalog.current
        catalog.limits.maximumElementInstances = 2
        func small(_ source: String, previous: DeskCompilationResult?) throws -> DeskCompilationResult {
            let checked = deskCheck(source, context: CheckContext(catalog: catalog))
            let result = Desk.compile(checked, catalog: catalog, previous: previous)
            t.check(result.issues.isEmpty, "\(result.issues)")
            guard result.program != nil else { throw TemplateFixtureError.missing }
            return result
        }
        var previous = try small(#"widget { Column { Text("A") } }"#, previous: nil)
        let root = previous.program!.root.id
        var seen = Set<TemplateID>()
        for i in 0..<12 {
            let source = i.isMultiple(of: 2) ? #"widget { Column { Icon("star") } }"# : #"widget { Column { Text("A") } }"#
            previous = try small(source, previous: previous)
            t.equal(previous.program!.root.id, root)
            t.equal(previous.sourceMap!.elements.count, 2)
            let child = elements(previous).first { $0.parent != nil }!
            t.check(seen.insert(child.templateID).inserted)
            t.check(child.templateID.rawValue >= i + 2)
        }
        let rejected = Desk.compile(deskCheck(#"widget { Column { Text("A"); Text("B") } }"#,
            context: CheckContext(catalog: catalog)), catalog: catalog, previous: previous)
        t.check(rejected.program == nil); t.check(rejected.sourceMap == nil)
    }

    t.suite("Desk: template identity: inserting and removing else-if blocks cannot steal another branch ID") {
        let a = try compile(#"widget { Column { if true { Text("A").name(a) } else { Text("B").name(b) } } }"#)
        let b = try compile(#"widget { Column { if true { Text("A").name(a) } else if false { Text("X").name(x) } else { Text("B").name(b) } } }"#, previous: a)
        t.equal(try named(a, "b").elementID, try named(b, "b").elementID)
        t.check(try named(b, "x").elementID != named(a, "b").elementID)
        let c = try compile(#"widget { Column { if true { Text("A").name(a) } else if system.dark { Text("Y").name(y) } else if false { Text("X").name(x) } else { Text("B").name(b) } } }"#, previous: b)
        for name in ["a", "x", "b"] { t.equal(try named(b, name).elementID, try named(c, name).elementID) }
        let d = try compile(#"widget { Column { if true { Text("A").name(a) } else if false { Text("X").name(x) } else { Text("B").name(b) } } }"#, previous: c)
        for name in ["a", "x", "b"] { t.equal(try named(c, name).elementID, try named(d, name).elementID) }
    }
    t.suite("Desk: template identity: lowered declaration action menu and expression paths resolve exact current source") {
        let checked = deskCheck(#"""
        widget {
            variable count = 1 + 2
            Text("A").name(label)
                .onLoad { count = 4 }
                .onClick { count = count + 1; copy("click") }
                .menu {
                    Menu("More") {
                        if true { Item("Same").onClick { copy("first") } }
                        else { Item("Same").onClick { copy("second") } }
                    }
                }
        }
        """#)
        let a = try compileChecked(checked)
        let program = a.program!, map = a.sourceMap!, root = DeskIRNodePath(), element = DeskIRNodePath(element: TemplateID(program.root.id.index))
        func source(_ path: DeskIRNodePath) throws -> String {
            guard let site = map.irNodes[path], let node = checked.tree.resolve(site.reference) else { throw TemplateFixtureError.missing }
            t.equal(site.source.range, node.textRange); t.equal(site.source.file, checked.tree.file)
            return node.node.trimmedText
        }
        t.equal(program.declarations.count, 1)
        t.equal(try source(root.appending("declarations", "0")), "variable count = 1 + 2")
        t.equal(try source(root.appending("declarations", "0", "initial")), "1 + 2")
        t.equal(try source(root.appending("onLoad", "0")), "count = 4")
        t.equal(try source(root.appending("onLoad", "0", "value")), "4")
        t.equal(program.root.onClickActions?.count, 2)
        t.equal(try source(element.appending("onClickActions", "0")), "count = count + 1")
        t.equal(try source(element.appending("onClickActions", "0", "value")), "count + 1")
        t.equal(try source(element.appending("onClickActions", "1")), #"copy("click")"#)
        t.equal(try source(element.appending("content", "value")), #""A""#)
        guard case .submenu(_, let items)? = program.root.menu?.first, case .conditional(let conditional)? = items.first else {
            throw TemplateFixtureError.missing
        }
        t.equal(conditional.branches.count, 1); t.equal(conditional.otherwise.count, 1)
        let first = ProgramMenuItemID(owner: program.root.id, path: [0, 0, 0, 0])
        let second = ProgramMenuItemID(owner: program.root.id, path: [0, 0, 1, 0])
        t.equal(try source(.menuItem(first)), #"Item("Same").onClick { copy("first") }"#)
        t.equal(try source(.menuItem(second)), #"Item("Same").onClick { copy("second") }"#)
        t.equal(try source(element.appending("menu", "0", "items", "0", "otherwise", "0", "actions", "0", "value")), #""second""#)
        let current = deskCheck(checked.tree.text.replacingOccurrences(of: "click", with: "updated"))
        let b = try compileChecked(current, previous: a)
        let key = element.appending("onClickActions", "1")
        t.equal(program.root.id, b.program!.root.id)
        t.check(current.tree.resolve(map.irNodes[key]!.reference) == nil)
        t.equal(current.tree.resolve(b.sourceMap!.irNodes[key]!.reference)?.node.trimmedText, #"copy("updated")"#)
    }
    t.suite("Desk: template identity: different source files start independent lineages and keep source-qualified refs") {
        let a = try compile(#"widget { Text("A").name(before) }"#)
        let checked = deskCheck(#"widget { Text("A").name(after) }"#, file: "Other.desk")
        let b = try compileChecked(checked, previous: a)
        t.equal(b.program!.root.id, ElementID(name: "after", index: 0))
        t.equal(b.sourceMap!.file, checked.tree.file)
        t.check(checked.tree.resolve(a.elementRefs.values.first!) == nil)
    }

    t.suite("Desk: template identity: assignment-only click and nested payload paths remain complete") {
        let checked = deskCheck(#"widget { variable count = 1; Rectangle().stroke(.red).tooltip("tip").name(before).onClick { count = 2 } }"#)
        let a = try compileChecked(checked), path = DeskIRNodePath(element: TemplateID(a.program!.root.id.index))
        t.equal(a.program!.root.onClick?.count, 1); t.check(a.program!.root.onClickActions == nil)
        for components in [["onClick", "0"], ["onClick", "0", "value"], ["stroke"], ["stroke", "color"], ["tooltip"], ["tooltip", "text"]] {
            t.check(a.sourceMap!.irNodes[DeskIRNodePath(element: path.element, components: components)] != nil)
        }
        let valueSite = a.sourceMap!.irNodes[path.appending("onClick", "0", "value")]!
        t.equal(checked.tree.resolve(valueSite.reference)?.node.trimmedText, "2")
        let b = try compile(checked.tree.text.replacingOccurrences(of: "name(before)", with: "name(after)"), previous: a)
        t.equal(a.program!.root.id, b.program!.root.id)
        t.equal(b.program!.root.id.name, "before")
        t.equal(try named(b, "after").name, "after")
    }
    t.suite("Desk: template identity: concurrent branches never allocate the same new template ID") {
        let previous = try compile(#"widget { Column { Text("A") } }"#)
        let results = TemplateConcurrentResults()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let checked = deskCheck(#"widget { Column { Text("A"); Icon("star") } }"#)
            results.append(Desk.compile(checked, previous: previous))
        }
        let values = results.snapshot()
        t.equal(values.count, 8)
        var allocated = Set<TemplateID>()
        for value in values {
            t.check(value.program != nil, "\(value.issues)")
            guard value.sourceMap != nil else { continue }
            t.equal(value.program!.root.id, previous.program!.root.id)
            t.check(allocated.insert(elements(value, component: "Icon")[0].templateID).inserted)
        }
        t.equal(allocated.count, 8)
    }

    t.suite("Desk: template identity: duplicate branch conditions use body ties before matching children") {
        let a = try compile(#"widget { Column { if false { Text("A").name(a) } else if false { Text("B").name(b) } else { Text("C").name(c) } } }"#)
        let b = try compile(#"widget { Column { if false { Text("X").name(x) } else if false { Text("A").name(a) } else if false { Text("B").name(b) } else { Text("C").name(c) } } }"#, previous: a)
        for name in ["a", "b", "c"] { t.equal(try named(a, name).elementID, try named(b, name).elementID) }
        t.check(!Set(elements(a).map(\.elementID)).contains(try named(b, "x").elementID))
    }
    t.suite("Desk: template identity: tooltip title and operand paths use distinct field components") {
        let result = try compile(#"widget { variable n = 2; Text("A").tooltip("tip {n}", title: "title {n}") }"#)
        let map = result.sourceMap!, root = DeskIRNodePath(element: TemplateID(result.program!.root.id.index))
        for field in ["text", "title"] {
            t.check(map.irNodes[root.appending("tooltip", field)] != nil)
            t.check(map.irNodes[root.appending("tooltip", field, "children", "0")] != nil)
            t.check(map.irNodes[root.appending("tooltip." + field)] == nil)
        }
    }
    t.suite("Desk: template identity: effective option IR paths retain nested section and override sources") {
        let package = deskCheck(#"""
        package { name: "Shared" }
        options {
            Section("Package") {
                same = Toggle("Shared", default: false)
                Section("Nested") { keep = Input("Keep", default: "shared") }
                Section("Empty") { replaced = Toggle("Replaced", default: false) }
            }
        }
        """#, file: "package.desk")
        let checked = deskCheck(#"""
        options { Section("Own") { same = Toggle("Local", default: true); replaced = Toggle("Own replacement", default: true) } }
        widget { Text(options.keep) }
        """#, context: CheckContext(package: CheckedPackage(file: package)))
        let result = Desk.compile(checked, package: package)
        t.check(result.diagnostics.allSatisfy { $0.severity != .error }, deskDescribe(checked) + deskDescribe(package))
        t.check(result.issues.isEmpty, "\(result.issues)")
        guard let map = result.sourceMap, let program = result.program else { throw TemplateFixtureError.missing }
        t.equal(program.options.count, 2)
        func site(_ path: [String], source: CheckedFile, expected: String) throws {
            guard let site = map.irNodes[DeskIRNodePath(components: path)], let node = source.tree.resolve(site.reference) else { throw TemplateFixtureError.missing }
            t.equal(site.source.file, source.tree.file); t.equal(site.reference.treeVersion, source.tree.version)
            t.equal(node.node.trimmedText, expected)
        }
        try site(["options", "0", "items", "0", "title"], source: checked, expected: #""Local""#)
        try site(["options", "1", "items", "0", "title"], source: package, expected: #""Nested""#)
        try site(["options", "1", "items", "0", "items", "0", "title"], source: package, expected: #""Keep""#)
        try site(["options", "1", "items", "1", "title"], source: package, expected: #""Empty""#)
        t.check(map.irNodes[DeskIRNodePath(components: ["options", "1", "items", "1", "items", "0"])] == nil)
        guard case .section(_, let items) = program.options[1], case .section(_, let empty) = items[1] else { throw TemplateFixtureError.missing }
        t.check(empty.isEmpty)
    }

    t.suite("Desk: template identity: invalid conflicting move ranges cannot duplicate identities") {
        let a = try compile(#"widget { Column { Text("A"); Text("B") } }"#)
        let checked = deskCheck(#"widget { Column { Text("A"); Text("B"); Icon("star") } }"#)
        let fresh = try compileChecked(checked)
        let old = elements(a, component: "Text"), next = elements(fresh, component: "Text")
        let moves = [TextMove(from: old[0].source.range, to: next[0].source.range),
                     TextMove(from: old[0].source.range, to: next[1].source.range),
                     TextMove(from: -1..<0, to: 0..<1)]
        let b = try compileChecked(checked, previous: a, moves: moves)
        t.equal(elements(b, component: "Text").map(\.elementID), old.map(\.elementID))
    }
}
