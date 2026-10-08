import Foundation
@testable import DeskLanguage

/// The outline of the first node of a kind in `text` (parsed as a file).
private func first(_ kind: SyntaxKind, in text: String) -> String {
    deskParse(text).root.firstNode(kind)?.outline ?? "‹none›"
}

/// The outline of the only statement of `widget { … }` wrapped around `body`.
private func statement(_ body: String) -> String {
    let tree = deskParse("widget {\n" + body + "\n}\n")
    guard let block = tree.root.firstNode(.widgetBlock)?.children.last?.node else { return "‹no block›" }
    return block.children.compactMap(\.node).map(\.outline).joined(separator: " | ")
}

/// The outline of an expression used as `x = <expr>` in an action.
private func expression(_ source: String) -> String {
    let tree = deskParse("widget {\n    computed x = " + source + "\n}\n")
    return tree.root.firstNode(.declaration)?.children.last?.node?.outline ?? "‹none›"
}

func runDeskParserTests(_ t: TestRunner) {
    t.suite("Desk: parser — file structure") {
        let file = """
        info { name: "A", deskVersion: 1, requires: "1.2" }
        package { name: "P" }
        options { a = Toggle("A") }
        widget { Text("A") }
        style s { .bold() }
        translations { "zh-Hans" { "A": "甲" } }
        component Card(title: String = "x") { Text(title) }
        script { const x = 1 }
        Text("stray")
        """
        let tree = deskParse(file)
        let kinds = tree.root.children.compactMap(\.node).map(\.kind)
        t.equal(kinds, [.infoBlock, .packageBlock, .optionsBlock, .widgetBlock, .styleDecl, .translationsBlock,
                        .componentDecl, .scriptBlock, .strayStatement])
        t.equal(deskErrorIDs(tree), [])
        t.equal(tree.header.deskVersion, 1)
        t.equal(tree.header.requires, AppVersion(major: 1, minor: 2))
        t.equal(first(.componentDecl, in: file),
                "componentDecl[component Card parameterClause[( parameter[title : String = stringLiteral[\" stringText[x] \"]] )] block[{ callStmt[callee[Text] argumentClause[( argument[identifierExpr[title]] )]] }]]")
        t.equal(first(.scriptBlock, in: file), "scriptBlock[script { const x = 1 }]")
        // Only the file's own items are stray: the block of a stray statement holds ordinary statements.
        t.equal(deskParse("Row {\n    Text(\"A\")\n    if a { Text(\"B\") }\n}\n{ Text(\"C\") }\n").root.outline,
                "sourceFile[strayStatement[callStmt[callee[Row] block[{ callStmt[callee[Text] argumentClause[( argument[stringLiteral[\" stringText[A] \"]] )]] ifStmt[if identifierExpr[a] block[{ callStmt[callee[Text] argumentClause[( argument[stringLiteral[\" stringText[B] \"]] )]] }]] }]]] unexpected[block[{ callStmt[callee[Text] argumentClause[( argument[stringLiteral[\" stringText[C] \"]] )]] }]]]")
        t.equal(deskParse("settings { a: 1 }").root.allNodes(.strayStatement).count, 1)
        // The header reads only literals.
        t.equal(deskParse("info { deskVersion: 1.5, requires: \"1.{x}\" }").header, FileHeader())
        t.equal(deskParse("package { deskVersion: 2 }").header.deskVersion, 2)
        // A block word may be followed by its block on the next line.
        t.equal(first(.widgetBlock, in: "widget\n{\n    Text(\"A\")\n}"),
                "widgetBlock[widget block[{ callStmt[callee[Text] argumentClause[( argument[stringLiteral[\" stringText[A] \"]] )]] }]]")
        // `style` and `options` are also ordinary names where they are not block starts.
        t.equal(statement("style = 1"), "assignment[target[style] = numberLiteral[1]]")
        t.equal(first(.optionDecl, in: "options { style = Picker(\"Style\", [.a, .b]) }"),
                "optionDecl[target[style] = callStmt[callee[Picker] argumentClause[( argument[stringLiteral[\" stringText[Style] \"]] , argument[listLiteral[[ implicitMemberExpr[. a] , implicitMemberExpr[. b] ]]] )]]]")
    }

    t.suite("Desk: parser — statements") {
        t.equal(statement("variable page = 0"), "declaration[variable page = numberLiteral[0]]")
        t.equal(statement("saved note = \"\""), "declaration[saved note = stringLiteral[\" \"]]")
        t.equal(statement("computed m = calendar.month(offset: 0)"),
                "declaration[computed m = callExpr[memberExpr[identifierExpr[calendar] . month] argumentClause[( argument[label[offset] : numberLiteral[0]] )]]]")
        t.equal(statement("if a { Text(\"A\") } else if b { Text(\"B\") } else { Text(\"C\") }"),
                "ifStmt[if identifierExpr[a] block[{ callStmt[callee[Text] argumentClause[( argument[stringLiteral[\" stringText[A] \"]] )]] }] elseClause[else ifStmt[if identifierExpr[b] block[{ callStmt[callee[Text] argumentClause[( argument[stringLiteral[\" stringText[B] \"]] )]] }] elseClause[else block[{ callStmt[callee[Text] argumentClause[( argument[stringLiteral[\" stringText[C] \"]] )]] }]]]]]")
        t.equal(statement("for day in month.days { Text(\"{day.number}\") }"),
                "forStmt[for day in memberExpr[identifierExpr[month] . days] block[{ callStmt[callee[Text] argumentClause[( argument[stringLiteral[\" interpolation[{ memberExpr[identifierExpr[day] . number] }] \"]] )]] }]]")
        t.equal(statement("page = page + 1"), "assignment[target[page] = binaryExpr[identifierExpr[page] + numberLiteral[1]]]")
        t.equal(statement("options.weekStart = .monday"),
                "assignment[target[options . weekStart] = implicitMemberExpr[. monday]]")
        t.equal(statement("music.next()"), "callStmt[callee[music . next] argumentClause[( )]]")
        t.equal(statement("after(1s) { hide(toast) }"),
                "callStmt[callee[after] argumentClause[( argument[numberLiteral[1s]] )] block[{ callStmt[callee[hide] argumentClause[( argument[identifierExpr[toast]] )]] }]]")
        t.equal(statement(".font(.caption).color(.dim)"),
                "modifierStmt[modifierApp[. font argumentClause[( argument[implicitMemberExpr[. caption]] )]] modifierApp[. color argumentClause[( argument[implicitMemberExpr[. dim]] )]]]")
        t.equal(statement("Row { Text(\"A\"); Spacer(); Text(\"B\") }"),
                "callStmt[callee[Row] block[{ callStmt[callee[Text] argumentClause[( argument[stringLiteral[\" stringText[A] \"]] )]] ; callStmt[callee[Spacer] argumentClause[( )]] ; callStmt[callee[Text] argumentClause[( argument[stringLiteral[\" stringText[B] \"]] )]] }]]")
        // Commas separate statements in any block (D4); fields in info; entries and groups in translations.
        t.equal(first(.block, in: "info { name: \"CPU\", size: .small }"),
                "block[{ field[label[name] : stringLiteral[\" stringText[CPU] \"]] , field[label[size] : implicitMemberExpr[. small]] }]")
        t.equal(first(.group, in: "translations { \"zh-Hans\": { \"A\" = \"甲\" } }"),
                "group[stringLiteral[\" stringText[zh-Hans] \"] : block[{ entry[stringLiteral[\" stringText[A] \"] = stringLiteral[\" stringText[甲] \"]] }]]")
        // In options, a control is a call statement with its own modifiers, also inside a Section.
        t.equal(first(.block, in: "options {\n    Section(\"Colors\") {\n        accent = ColorPicker(\"Accent\")\n            .help(\"x\")\n    }\n}"),
                "block[{ callStmt[callee[Section] argumentClause[( argument[stringLiteral[\" stringText[Colors] \"]] )] block[{ optionDecl[target[accent] = callStmt[callee[ColorPicker] argumentClause[( argument[stringLiteral[\" stringText[Accent] \"]] )] modifierApp[. help argumentClause[( argument[stringLiteral[\" stringText[x] \"]] )]]]] }]] }]")
        // Outside options the same text is an assignment.
        t.equal(statement("accent = ColorPicker(\"Accent\")"),
                "assignment[target[accent] = callExpr[identifierExpr[ColorPicker] argumentClause[( argument[stringLiteral[\" stringText[Accent] \"]] )]]]")
        // Keyword labels (`if:`) and member names (`music.repeat`).
        t.equal(statement("Text(\"A\").color(.red, if: hot)"),
                "callStmt[callee[Text] argumentClause[( argument[stringLiteral[\" stringText[A] \"]] )] modifierApp[. color argumentClause[( argument[implicitMemberExpr[. red]] , argument[label[if] : identifierExpr[hot]] )]]]")
        t.equal(expression("music.repeat"), "memberExpr[identifierExpr[music] . repeat]")
        t.equal(expression("event.x"), "memberExpr[identifierExpr[event] . x]")
        // `Row { … }` needs no parentheses before a block (D5).
        t.equal(statement("Row { }"), "callStmt[callee[Row] block[{ }]]")
    }

    t.suite("Desk: parser — expressions and precedence") {
        t.equal(expression("a or b and c"),
                "binaryExpr[identifierExpr[a] or binaryExpr[identifierExpr[b] and identifierExpr[c]]]")
        t.equal(expression("not a == b"), "prefixExpr[not binaryExpr[identifierExpr[a] == identifierExpr[b]]]")
        t.equal(expression("a + b * c"), "binaryExpr[identifierExpr[a] + binaryExpr[identifierExpr[b] * identifierExpr[c]]]")
        t.equal(expression("a - b - c"), "binaryExpr[binaryExpr[identifierExpr[a] - identifierExpr[b]] - identifierExpr[c]]")
        t.equal(expression("1...a + 2"), "rangeExpr[numberLiteral[1] ... binaryExpr[identifierExpr[a] + numberLiteral[2]]]")
        t.equal(expression("-x.y"), "prefixExpr[- memberExpr[identifierExpr[x] . y]]")
        t.equal(expression("- -40°F"), "prefixExpr[- prefixExpr[- numberLiteral[40°F]]]")
        t.equal(expression("a < b ? c : d ? e : f"),
                "ternaryExpr[binaryExpr[identifierExpr[a] < identifierExpr[b]] ? identifierExpr[c] : ternaryExpr[identifierExpr[d] ? identifierExpr[e] : identifierExpr[f]]]")
        t.equal(expression("hot ?.red : .blue"),
                "ternaryExpr[identifierExpr[hot] ? implicitMemberExpr[. red] : implicitMemberExpr[. blue]]")
        t.equal(expression(".text.opacity(50%)"),
                "callExpr[memberExpr[implicitMemberExpr[. text] . opacity] argumentClause[( argument[numberLiteral[50%]] )]]")
        t.equal(expression(".color(light: .black, dark: .white)"),
                "implicitMemberExpr[. color argumentClause[( argument[label[light] : implicitMemberExpr[. black]] , argument[label[dark] : implicitMemberExpr[. white]] )]]")
        t.equal(expression("[1, 2,]"), "listLiteral[[ numberLiteral[1] , numberLiteral[2] , ]]")
        t.equal(expression("(a + b) * 2"),
                "binaryExpr[parenExpr[( binaryExpr[identifierExpr[a] + identifierExpr[b]] )] * numberLiteral[2]]")
        t.equal(expression("true"), "boolLiteral[true]")
        t.equal(expression(##"#"\d+"#"##), ##"stringLiteral[#"\d+"#]"##)
        t.equal(expression("\"{x, decimals: 1, unit: .gb}\""),
                "stringLiteral[\" interpolation[{ identifierExpr[x] formatOption[, label[decimals] : numberLiteral[1]] formatOption[, label[unit] : implicitMemberExpr[. gb]] }] \"]")
        // A value may continue on the next line after an operator or before a `.member` (N3, N4).
        t.equal(expression("a +\n        b"), "binaryExpr[identifierExpr[a] + identifierExpr[b]]")
        t.equal(expression("a\n        + b"), "binaryExpr[identifierExpr[a] + identifierExpr[b]]")
        t.equal(expression("a\n        or b"), "binaryExpr[identifierExpr[a] or identifierExpr[b]]")
        t.equal(deskErrorIDs(deskParse("widget {\n    computed x = a > 1\n        ? b\n        : c\n}")), [])
    }

    t.suite("Desk: parser — newline rules and §2.10") {
        // Modifier on the next line (N3).
        t.equal(statement("Text(month.title)\n    .font(.headline)"),
                "callStmt[callee[Text] argumentClause[( argument[memberExpr[identifierExpr[month] . title]] )] modifierApp[. font argumentClause[( argument[implicitMemberExpr[. headline]] )]]]")
        t.equal(statement("Column { }\n.padding(18)"),
                "callStmt[callee[Column] block[{ }] modifierApp[. padding argumentClause[( argument[numberLiteral[18]] )]]]")
        // Member access in a declaration's initializer.
        t.equal(statement("computed m = calendar\n    .month(offset: 0)"),
                "declaration[computed m = callExpr[memberExpr[identifierExpr[calendar] . month] argumentClause[( argument[label[offset] : numberLiteral[0]] )]]]")
        t.equal(statement("Text(calendar\n    .month(offset: 0).title)"),
                "callStmt[callee[Text] argumentClause[( argument[memberExpr[callExpr[memberExpr[identifierExpr[calendar] . month] argumentClause[( argument[label[offset] : numberLiteral[0]] )]] . title]] )]]")
        t.equal(statement("Picker(\"Day\",\n    [.sunday, .monday])"),
                "callStmt[callee[Picker] argumentClause[( argument[stringLiteral[\" stringText[Day] \"]] , argument[listLiteral[[ implicitMemberExpr[. sunday] , implicitMemberExpr[. monday] ]]] )]]")
        t.equal(statement(".hover {\n    .color(.accent)\n    .scale(104%)\n}"),
                "modifierStmt[modifierApp[. hover block[{ modifierStmt[modifierApp[. color argumentClause[( argument[implicitMemberExpr[. accent]] )]] modifierApp[. scale argumentClause[( argument[numberLiteral[104%]] )]]] }]]]")
        // N7: `(` never continues across a line; inside brackets it is reported (DK2012).
        let paren = deskParse("widget {\n    Text(\"A\")\n    (x)\n}")
        t.equal(deskIDs(paren), ["DK2006"])
        let inside = deskParse("widget {\n    Text(round\n    (cpu.usage))\n}")
        t.equal(deskIDs(inside), ["DK2012"])
        t.equal(TextEdit.apply(inside.diagnostics[0].fixIts[0].edits, to: inside.text), "widget {\n    Text(round(cpu.usage))\n}")
        let bareNext = deskParse("widget {\n    Text\n    (\"A\")\n}")
        t.equal(deskIDs(bareNext), ["DK2012"])
        // An identifier is not a continuation token.
        t.equal(statement("computed a = b\nText(\"x\")"),
                "declaration[computed a = identifierExpr[b]] | callStmt[callee[Text] argumentClause[( argument[stringLiteral[\" stringText[x] \"]] )]]")
        // A line break inside a comment counts.
        let comment = deskParse("widget {\n    Text(\"A\") /* old label\n*/ Text(\"B\")\n}")
        t.equal(deskIDs(comment), [])
        t.equal(comment.root.allNodes(.callStmt).count, 2)
        // `;` and `,` are hard: a modifier after them has no element (the checker reports DK2013).
        t.equal(statement("Row { Text(\"A\"); .bold() }"),
                "callStmt[callee[Row] block[{ callStmt[callee[Text] argumentClause[( argument[stringLiteral[\" stringText[A] \"]] )]] ; modifierStmt[modifierApp[. bold argumentClause[( )]]] }]]")
        // Modifiers after the `}` of an `if` belong to the `if` (the checker reports DK2032).
        t.equal(deskParse("widget {\n    if ok { Text(\"A\") } else { Text(\"B\") }\n    .font(.caption)\n}").root
                    .firstNode(.ifStmt)?.children.last?.node?.kind, .modifierApp)
        // In options the control is a call statement: `.help` is its modifier.
        t.equal(first(.optionDecl, in: "options {\n    showSeconds = Toggle(\"Seconds\")\n        .help(\"…\")\n}"),
                "optionDecl[target[showSeconds] = callStmt[callee[Toggle] argumentClause[( argument[stringLiteral[\" stringText[Seconds] \"]] )] modifierApp[. help argumentClause[( argument[stringLiteral[\" stringText[…] \"]] )]]]]")
        // An assignment's value is an expression: a `.` on the next line is member access (DK7016 by the checker).
        t.equal(first(.assignment, in: "widget {\n    Text(\"x\").onClick {\n        page = page + 1\n        .color(.red)\n    }\n}"),
                "assignment[target[page] = binaryExpr[identifierExpr[page] + callExpr[memberExpr[numberLiteral[1] . color] argumentClause[( argument[implicitMemberExpr[. red]] )]]]]")
        // A list over several lines without commas reads `.sunday.monday` (the checker reports DK2007).
        t.equal(first(.listLiteral, in: "widget {\n    Picker(\"D\", [\n        .sunday\n        .monday\n    ])\n}"),
                "listLiteral[[ memberExpr[implicitMemberExpr[. sunday] . monday] ]]")
        // N5: a `{` on the next line attaches to the call or modifier before it.
        t.equal(statement("Row\n{\n    Text(\"A\")\n}"),
                "callStmt[callee[Row] block[{ callStmt[callee[Text] argumentClause[( argument[stringLiteral[\" stringText[A] \"]] )]] }]]")
        t.equal(statement("Text(\"A\").onClick\n{ x = 1 }"),
                "callStmt[callee[Text] argumentClause[( argument[stringLiteral[\" stringText[A] \"]] )] modifierApp[. onClick block[{ assignment[target[x] = numberLiteral[1]] }]]]")
        // N6: `else` on the next line continues the `if`; after a `;` it does not (DK2006).
        t.equal(deskIDs(deskParse("widget {\n    if a { }\n    else { }\n}")), [])
        t.equal(deskIDs(deskParse("widget {\n    if a { }; else { }\n}")), ["DK2006"])
        // Two statements on one line need a separator (DK2031).
        let two = deskParse("widget {\n    Row { Icon(\"wifi\") Text(wifi.name) }\n}")
        t.equal(deskIDs(two), ["DK2031"])
        t.equal(two.diagnostics[0].fixIts.map(\.titleKey), ["newLine", "insert"])
        t.equal(TextEdit.apply(two.diagnostics[0].fixIts[1].edits, to: two.text),
                "widget {\n    Row { Icon(\"wifi\"), Text(wifi.name) }\n}")
    }

    t.suite("Desk: parser — positions, references and wrappers") {
        let text = "widget {\n    Text(\"日本語\") // 😀\n    Progress(cpu.usage)\n}\n"
        let tree = deskParse(text)
        let progress = Array(text.utf8).count - "Progress(cpu.usage)\n}\n".utf8.count
        t.equal(tree.location(of: progress), SourceLocation(utf8Offset: progress, line: 3, column: 5, utf16Column: 5))
        let closeParen = Array(text.utf8).firstIndex(of: 0x29)!
        let location = tree.location(of: closeParen)
        t.equal(location.line, 2)
        t.equal(location.column, 15, "graphemes: 4 spaces, Text(\", 3 CJK, \" → the `)` is the 15th")
        t.equal(location.utf16Column, 15)
        let emoji = tree.location(of: text.utf8.count - "\n    Progress(cpu.usage)\n}\n".utf8.count)
        t.equal(emoji.column, 21, "the end of the line: 20 graphemes before it, the emoji one of them")
        t.equal(emoji.utf16Column, 22, "the emoji is two UTF-16 code units")
        t.equal(tree.node(at: progress)?.kind, .callee)
        // References: a node's id resolves to it; an id from another version is refused.
        let call = tree.rootNode.childNodes[0].childNodes[0].childNodes[1]
        t.equal(call.kind, .callStmt)
        let id = tree.id(of: call)
        t.equal(tree.resolve(id)?.textRange, call.textRange)
        let other = deskParse(text)
        t.check(other.version > tree.version, "versions increase")
        t.check(other.resolve(id) == nil, "a reference from another version is refused")
        // Typed wrappers.
        let wrapper = CallStmtSyntax(call)!
        t.equal(wrapper.callee.path, ["Progress"])
        t.equal(wrapper.arguments?.arguments.count, 1)
        t.equal(wrapper.modifiers.count, 0)
        let month = deskParse(try String(contentsOf: deskFixtures.appendingPathComponent("Acceptance/MonthView.desk"), encoding: .utf8))
        let styles = SourceFileSyntax(month.rootNode)!.items.compactMap(StyleDeclSyntax.init)
        t.equal(styles.map(\.name.token.text), ["arrow", "weekdayLabel", "dateCell", "todayCell"])
        let today = styles[3].block.statements.compactMap(ModifierStmtSyntax.init).first!
        t.equal(today.modifiers.map(\.name.token.text), ["font", "color", "size", "background", "rounded"])
        let declarations = month.rootNode.childNodes.compactMap(TopLevelBlockSyntax.init)
            .first { $0.keyword.token.text == "widget" }!.block.statements.compactMap(DeclarationSyntax.init)
        t.equal(declarations.map { "\($0.keyword.token.text) \($0.name.token.text)" }, ["variable monthsFromNow", "computed month"])
        let entries = month.root.allNodes(.entry)
        t.equal(entries.count, 4)
        let firstEntry = EntrySyntax(PositionedNode(node: entries[0], offset: 0))!
        t.equal(firstEntry.key.literalValue, "Month View")
        // Cooked strings, number values, units after a space.
        let literal = deskParse(#"widget { Text("a\n{{b}} \u{1F600}") }"#).root.firstNode(.stringLiteral)!
        t.equal(StringLiteralSyntax.literalValue(of: literal), "a\n{b} 😀")
        let spaced = deskParse("widget { x.every(2 s) { } }").root.firstNode(.numberLiteral)!
        t.equal(NumberLiteralSyntax(PositionedNode(node: spaced, offset: 0))?.unit?.text, "s")
        // Slots filled by recovery: a value that is no expression (a bare hex color, indexing) still fills its slot,
        // and a skipped `else if` chain is the else's body.
        let broken = deskParse("widget {\n    variable x = #FF0000\n    Text(#FFF, a: list[0])\n    if #FFF { }\n"
                               + "    for d in #FFF { }\n    y = 0xFF6B00\n    Text(\"{x, decimals: #FFF}\")\n}\n"
                               + "info { name: #FFF }\ntranslations { \"de\" { \"A\": #FFF } }\n")
        t.equal(deskWrapperProblems(broken), [])
        let initializer = broken.rootNode.childNodes[0].childNodes[0].childNodes.compactMap(DeclarationSyntax.init)[0]
            .initializer
        t.equal(initializer.node.kind, .unexpected)
        t.equal(initializer.node.node.trimmedText, "#FF0000")
        let deepElse = deskParse("widget {\n    if a { }" + String(repeating: " else if a { }", count: 80) + "\n}\n")
        t.equal(deskWrapperProblems(deepElse), [])
        // Every grammar slot the parser names is a display-name id.
        t.check(SyntaxSlot.allCases.allSatisfy { $0.rawValue.hasPrefix("slot:") })
    }

    t.suite("Desk: parser — direct child lookup preserves positions and identity") {
        let prefix = Token(kind: .identifier, text: "甲😀", leadingTrivia: [.newline(.crlf)], trailingTrivia: [.spaces(2)])
        let nested = SyntaxNode(kind: .identifierExpr, children: [.token(Token(kind: .identifier, text: "inside"))])
        let recovery = SyntaxNode(kind: .unexpected, children: [.node(nested)])
        let empty = SyntaxNode(kind: .callee, children: [])
        let missing = SyntaxNode(kind: .numberLiteral, children: [.token(.missing(.number))])
        let present = SyntaxNode(kind: .numberLiteral,
                                 children: [.token(Token(kind: .number, text: "13", leadingTrivia: [.spaces(1)]))])
        let parent = PositionedNode(node: SyntaxNode(kind: .block, children: [
            .token(prefix), .node(recovery), .token(.missing(.comma)), .node(empty), .node(missing), .node(present),
        ]), offset: 17)
        t.equal(prefix.utf8Length, 11, "CRLF, Unicode and trailing trivia all count in UTF-8 bytes")
        t.check(parent.firstChild(.unexpected)?.node === recovery, "recovery nodes remain selectable")
        t.equal(parent.firstChild(.unexpected)?.offset, 28)
        t.check(parent.firstChild(.callee)?.node === empty, "empty direct nodes remain selectable")
        t.equal(parent.firstChild(.callee)?.range, 34..<34)
        t.check(parent.firstChild(.numberLiteral)?.node === missing, "the first same-kind node wins even if missing")
        t.equal(parent.firstChild(.numberLiteral)?.range, 34..<34)
        t.equal(parent.firstChild(.identifierExpr)?.kind, nil, "a matching descendant is not a direct child")
        t.equal(parent.firstChild(.argumentClause)?.kind, nil)
        let repeated = PositionedNode(node: SyntaxNode(kind: .block, children: [
            .token(prefix), .node(present), .node(missing),
        ]), offset: 17)
        t.check(repeated.firstChild(.numberLiteral)?.node === present, "the existing first node is returned, not copied")
        t.equal(repeated.firstChild(.numberLiteral)?.range, 28..<31)
        t.equal(repeated.firstChild(.numberLiteral)?.textRange, 29..<31)
        t.equal(PositionedNode(node: empty, offset: 17).firstChild(.callee)?.kind, nil)
        let tokenOnly = PositionedNode(node: SyntaxNode(kind: .block, children: [.token(prefix)]), offset: 17)
        t.equal(tokenOnly.firstChild(.identifierExpr)?.kind, nil)

        let source = "widget {\r\n    Text(\"甲😀\").font(13)\r\n    Text(\"second\")\r\n}\r\n"
        let tree = deskParse(source)
        let version = tree.version
        guard let widget = tree.rootNode.firstChild(.widgetBlock), let block = widget.firstChild(.block),
              let call = block.firstChild(.callStmt), let modifier = call.firstChild(.modifierApp),
              let clause = modifier.firstChild(.argumentClause), let argument = clause.firstChild(.argument),
              let number = argument.firstChild(.numberLiteral) else {
            t.check(false, "the parsed direct-child slots remain available")
            return
        }
        t.equal(tree.diagnostics.map(\.description), [])
        t.check(call.node === block.childNodes.first?.node, "the first parsed call keeps its node identity")
        t.equal(CallStmtSyntax(call)?.callee.path, ["Text"])
        let start = "widget {\r\n    Text(\"甲😀\").font(".utf8.count
        t.equal(number.offset, start)
        t.equal(number.textRange, start..<(start + 2))
        let id = tree.id(of: number)
        t.equal(id, NodeID(kind: .numberLiteral, utf8Start: start, treeVersion: version, utf8End: start + 2))
        t.check(tree.resolve(id)?.node === number.node)
        t.equal(tree.resolve(id)?.range, number.range)
        t.equal(tree.quickResolve(id)?.range, number.range)
        t.equal(block.firstChild(.numberLiteral)?.kind, nil, "parsed lookups also stop at direct children")
        t.equal(tree.version, version)
        let other = deskParse(source)
        t.check(other.version > version)
        t.equal(other.resolve(id)?.kind, nil, "lookup does not weaken the source version boundary")
    }

    t.suite("Desk: parser — canonical expression references and types") {
        func nodes(_ tree: SyntaxTree, kind: SyntaxKind) -> [PositionedNode] {
            var found: [PositionedNode] = []
            var stack = [tree.rootNode]
            while let node = stack.popLast() {
                if node.kind == kind { found.append(node) }
                stack.append(contentsOf: node.childNodes.reversed())
            }
            return found
        }
        func verify(_ tree: SyntaxTree, _ selected: [PositionedNode]) {
            let table = DeskNodeTable(tree: tree)
            let ids = selected.map(tree.id)
            t.equal(Set(ids).count, selected.count, "these legal nested expressions have distinct canonical keys")
            for node in selected {
                let id = tree.id(of: node)
                t.equal(node.quickTextRange, node.textRange)
                t.equal(id.utf8Start, node.textRange.lowerBound)
                t.equal(id.utf8End, node.textRange.upperBound)
                t.equal(tree.resolve(id)?.range, node.range, "resolve must return this node, not its enclosing expression")
                t.equal(tree.quickResolve(id)?.range, node.range)
                let indexes = table.indexes(of: id)
                t.equal(indexes.count, 1)
                if let index = indexes.first {
                    t.equal(table.id(index), id)
                    t.equal(table.entries[index].positioned.range, node.range)
                }
            }
        }

        let prefix = "widget {\n    computed result = ("
        let text = prefix + "1 / 0 < 1)\n    Text(\"{result}\")\n}\n"
        let checked = deskCheck(text)
        let tree = checked.tree
        t.equal(checked.diagnostics.filter { $0.severity == .error }.map(\.id), [])
        let binary = nodes(tree, kind: .binaryExpr)
        let start = prefix.utf8.count
        t.equal(binary.map(\.textRange), [start..<(start + 9), start..<(start + 5)])
        t.equal(binary.map { checked.types[tree.id(of: $0)]?.type }, [.bool, .number(.plain)])
        verify(tree, binary)
        if let outer = binary.first, let inner = binary.last, binary.count == 2 {
            let outerID = tree.id(of: outer), innerID = tree.id(of: inner)
            let legacy = NodeID(kind: .binaryExpr, utf8Start: start, treeVersion: tree.version)
            t.equal(legacy.utf8End, nil)
            t.equal(legacy.description, "binaryExpr@\(start)#\(tree.version)")
            t.equal(innerID.description, "binaryExpr@\(start)..<\(start + 5)#\(tree.version)")
            t.equal(Set([legacy, innerID, outerID]).count, 3, "nil is a distinct key, never an equality wildcard")
            t.equal(tree.resolve(legacy)?.range, outer.range, "the old start-only locator keeps its outermost behavior")
            t.equal(tree.quickResolve(legacy)?.range, outer.range)
            t.equal(DeskNodeTable(tree: tree).indexes(of: legacy), [])
            t.equal(checked.types[legacy], nil)
            let absent = NodeID(kind: .binaryExpr, utf8Start: start, treeVersion: tree.version, utf8End: start + 6)
            t.check(tree.resolve(absent) == nil && tree.quickResolve(absent) == nil)
            t.equal(DeskNodeTable(tree: tree).indexes(of: absent), [])
            let otherVersion = NodeID(kind: innerID.kind, utf8Start: innerID.utf8Start,
                                      treeVersion: tree.version + 1, utf8End: start + 5)
            t.check(innerID != otherVersion)
            t.check(tree.resolve(otherVersion) == nil && tree.quickResolve(otherVersion) == nil)
        }
        let declarations = nodes(tree, kind: .declaration)
        t.equal(declarations.count, 1)
        if let declaration = declarations.first {
            t.equal(tree.id(of: declaration), NodeID(kind: .declaration, utf8Start: declaration.textRange.lowerBound,
                                                    treeVersion: tree.version))
            t.equal(tree.id(of: declaration).utf8End, nil, "non-expression keys keep the three-part contract")
        }

        // Real catalog value members and methods. Each nested member/call must keep its own metadata and locator.
        let chains: [(String, SyntaxKind, [String], [DeskType])] = [
            ("system.name.trimmed.length", .memberExpr,
             ["system.name.trimmed.length", "system.name.trimmed", "system.name"], [.number(.plain), .string, .string]),
            (#"time.now.in("UTC").in("UTC")"#, .callExpr,
             [#"time.now.in("UTC").in("UTC")"#, #"time.now.in("UTC")"#], [.date, .date]),
        ]
        for (expression, kind, spans, types) in chains {
            let prefix = "widget {\n    computed value = "
            let checked = deskCheck(prefix + expression + "\n    Text(\"{value}\")\n}\n")
            t.equal(checked.diagnostics.filter { $0.severity == .error }.map(\.id), [], expression)
            let chain = nodes(checked.tree, kind: kind)
            t.equal(chain.map(\.textRange), spans.map { prefix.utf8.count..<(prefix.utf8.count + $0.utf8.count) })
            t.equal(chain.map { checked.types[checked.tree.id(of: $0)]?.type }, types.map(Optional.some))
            verify(checked.tree, chain)
        }

        let broken = deskParse("widget { computed result = 1 / }")
        t.equal(broken.diagnostics.filter { $0.severity == .error }.map(\.id), [.missingOperand])
        let incomplete = nodes(broken, kind: .binaryExpr)
        t.equal(incomplete.count, 1)
        verify(broken, incomplete)
        let number = nodes(broken, kind: .numberLiteral)
        t.equal(number.count, 1)
        verify(broken, number)
    }
}
