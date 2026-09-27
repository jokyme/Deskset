import Foundation

// The diagnostics, one entry per id, in id order. Templates use `{placeholder}`s; `placeholders` says what each one
// stands for. Messages say where, what and how to fix it, in plain words.

extension CatalogData {
    /// Every diagnostic, in id order.
    static let diagnostics: [DiagnosticSpec] =
        lexicalDiagnostics + structureDiagnostics + namesDiagnostics + valuesDiagnostics + modifiersDiagnostics
        + layoutDiagnostics + actionsDiagnostics + infoAndSecurityDiagnostics + foreignDiagnostics

    /// DK1xxx — lexical.
    static let lexicalDiagnostics: [DiagnosticSpec] = [
        DiagnosticSpec(
            id: .fullWidthQuote, severity: .error,
            trigger: #"`Text(“CPU”)`"#,
            template: LocalizedText(
                #"These are Chinese quotation marks; use straight quotes `"`."#,
                #"这里用了中文引号，要换成英文的 `"`。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("fix"),
                FixItSpec("fixAll", fixAll: true),
            ]
        ),
        DiagnosticSpec(
            id: .fullWidthPunctuation, severity: .error,
            trigger: #"`Text("CPU")。font(.caption)`"#,
            template: LocalizedText(
                #"`{char}` is a full-width character; use `{ascii}`."#,
                #"这里用了中文的 `{char}`，要换成英文的 `{ascii}`。"#),
            placeholders: ["char": .code, "ascii": .code],
            fixIts: [
                FixItSpec("fix"),
                FixItSpec("fixAll", fixAll: true),
            ]
        ),
        DiagnosticSpec(
            id: .wrongQuoteStyle, severity: .error,
            trigger: #"`Text('CPU')`"#,
            template: LocalizedText(
                #"Text is written between double quotes: `"{text}"`."#,
                #"文字要写在英文双引号里：`"{text}"`。"#),
            placeholders: ["text": .code],
            fixIts: [
                FixItSpec("fix"),
            ]
        ),
        DiagnosticSpec(
            id: .unusualSpace, severity: .warning,
            trigger: #"a no-break or full-width space"#,
            template: LocalizedText(
                #"This is not a normal space ({name})."#,
                #"这里不是普通空格（{name}）。"#),
            placeholders: ["name": .text],
            fixIts: [
                FixItSpec("replaceWithSpace"),
                FixItSpec("fixAll", fixAll: true),
            ]
        ),
        DiagnosticSpec(
            id: .invisibleCharacter, severity: .warning,
            trigger: #"U+200B"#,
            template: LocalizedText(
                #"There is an invisible character here ({name})."#,
                #"这里有一个看不见的字符（{name}）。"#),
            placeholders: ["name": .text],
            fixIts: [
                FixItSpec("remove"),
                FixItSpec("fixAll", fixAll: true),
            ]
        ),
        DiagnosticSpec(
            id: .invalidCharacter, severity: .error,
            trigger: #"`§` outside text"#,
            template: LocalizedText(
                #"`{char}` can't be used here."#,
                #"这里不能用 `{char}`。"#),
            placeholders: ["char": .code],
            fixIts: [
                FixItSpec("remove"),
            ]
        ),
        DiagnosticSpec(
            id: .nonAsciiName, severity: .error,
            trigger: #"`variable 页码 = 0`"#,
            template: LocalizedText(
                #"Names use English letters, digits and `_`; put other languages in text and translations."#,
                #"名字只能用英文字母、数字和 `_`；其他语言写在文字和翻译里。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .invalidEncoding, severity: .error,
            trigger: #"a file in GBK"#,
            template: LocalizedText(
                #"This file is not UTF-8 text."#,
                #"这个文件不是 UTF-8 文本。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .nameTooLong, severity: .error,
            trigger: #"a 200-letter name"#,
            template: LocalizedText(
                #"Names can be at most 128 characters long."#,
                #"名字最多 128 个字符。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .unterminatedString, severity: .error,
            trigger: #"`Text("CPU)`"#,
            template: LocalizedText(
                #"This text has no closing `"`."#,
                #"这段文字缺少结尾的 `"`。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #"""#]),
            ]
        ),
        DiagnosticSpec(
            id: .unterminatedComment, severity: .error,
            trigger: #"`/* note`"#,
            template: LocalizedText(
                #"This comment has no closing `*/`."#,
                #"这段注释缺少结尾的 `*/`。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #"*/"#]),
            ]
        ),
        DiagnosticSpec(
            id: .invalidEscape, severity: .error,
            trigger: #"`Text("a\qb")`; a Windows path in display text (§1.8)"#,
            template: LocalizedText(
                #"`\{c}` has no special meaning in Desk text. To show a backslash, write `\\`; for a line break `\n`, for a quote `\"`."#,
                #"Desk 的文字里 `\{c}` 没有特殊含义。要显示反斜杠写 `\\`，要换行写 `\n`，要写引号写 `\"`。"#),
            placeholders: ["c": .code],
            fixIts: [
                FixItSpec("showBackslash"),
                FixItSpec("fixAll", fixAll: true),
            ]
        ),
        DiagnosticSpec(
            id: .loneClosingBrace, severity: .warning,
            trigger: #"`"a } b"`"#,
            template: LocalizedText(
                #"A `}` in text is written `}}`."#,
                #"文字里的 `}` 要写成 `}}`。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("replaceWith", arguments: ["text": #"}}"#]),
            ]
        ),
        DiagnosticSpec(
            id: .unterminatedInterpolation, severity: .error,
            trigger: #"`"{cpu.usage%"`"#,
            template: LocalizedText(
                #"`{` in text starts data and needs a matching `}`; to show `{`, write `{{`."#,
                #"文字里的 `{` 表示放数据，要有配对的 `}`；想显示 `{` 就写 `{{`。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #"}"#]),
                FixItSpec("replaceWith", arguments: ["text": #"{{"#]),
            ]
        ),
        DiagnosticSpec(
            id: .emptyInterpolation, severity: .error,
            trigger: #"`"a {} b"`"#,
            template: LocalizedText(
                #"`{}` is empty: put data inside, or write `{{}}` to show braces."#,
                #"`{}` 里是空的：放入数据，或者写 `{{}}` 显示花括号。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("replaceWith", arguments: ["text": #"{{}}"#]),
            ]
        ),
        DiagnosticSpec(
            id: .newlineInString, severity: .error,
            trigger: #"text broken over two lines"#,
            template: LocalizedText(
                #"Text can't continue on the next line; write `\n` for a line break."#,
                #"文字不能跨行；要换行请写 `\n`。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .tripleQuote, severity: .error,
            trigger: #"`"""long text"""`"#,
            template: LocalizedText(
                #"Desk text is one line between two `"`; use `\n` for line breaks."#,
                #"Desk 的文字写在一对 `"` 之间，只有一行；换行用 `\n`。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .numberInPattern, severity: .error,
            trigger: #"`.matches("\\d{3}")`"#,
            template: LocalizedText(
                #"In a pattern, `{text}` would put in a number instead of meaning "repeat": write the pattern as `{raw}`, or write `{escaped}`."#,
                #"在匹配规则里，`{text}` 会插入一个数字，而不是表示“重复”：把规则写成 `{raw}`，或者写 `{escaped}`。"#),
            placeholders: ["text": .code, "raw": .code, "escaped": .code],
            fixIts: [
                FixItSpec("writeAsRaw"),
                FixItSpec("replaceWith"),
            ]
        ),
        DiagnosticSpec(
            id: .directionMark, severity: .warning,
            trigger: #"a right-to-left mark inside text"#,
            template: LocalizedText(
                #"This text contains an invisible direction mark ({name}) that can make it look different from what it is."#,
                #"这段文字里有一个看不见的方向控制符（{name}），它会让文字看起来和实际内容不一样。"#),
            placeholders: ["name": .text],
            fixIts: [
                FixItSpec("remove"),
                FixItSpec("fixAll", fixAll: true),
            ]
        ),
        DiagnosticSpec(
            id: .leadingDotNumber, severity: .error,
            trigger: #"`.opacity(.5)`"#,
            template: LocalizedText(
                #"Write a 0 before the dot: `0.{digits}`."#,
                #"小数点前要写 0：`0.{digits}`。"#),
            placeholders: ["digits": .code],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #"0"#]),
            ]
        ),
        DiagnosticSpec(
            id: .pxUnit, severity: .error,
            trigger: #"`.padding(18px)`"#,
            template: LocalizedText(
                #"Lengths are plain numbers in points: `{number}`."#,
                #"长度直接写数字，单位是点：`{number}`。"#),
            placeholders: ["number": .code],
            fixIts: [
                FixItSpec("removeText", arguments: ["text": #"px"#]),
            ]
        ),
        DiagnosticSpec(
            id: .cssUnit, severity: .error,
            trigger: #"`.width(10em)`"#,
            template: LocalizedText(
                #"`{unit}` is a CSS unit; Desk lengths are plain numbers in points."#,
                #"`{unit}` 是 CSS 的单位；Desk 的长度直接写数字，单位是点。"#),
            placeholders: ["unit": .code]
        ),
        DiagnosticSpec(
            id: .unitSpelling, severity: .error,
            trigger: #"`.every(5m)`"#,
            template: LocalizedText(
                #"Did you mean `{number}{unit}`?"#,
                #"是不是想写 `{number}{unit}`？"#),
            placeholders: ["number": .code, "unit": .code],
            fixIts: [
                FixItSpec("replace"),
            ]
        ),
        DiagnosticSpec(
            id: .unknownUnit, severity: .error,
            trigger: #"`12pc`"#,
            template: LocalizedText(
                #"`{unit}` is not a unit Desk knows. Units: {list}."#,
                #"不认识单位 `{unit}`。可用的单位：{list}。"#),
            placeholders: ["unit": .code, "list": .list],
            fixIts: [
                FixItSpec("didYouMean", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .numberTooLarge, severity: .error,
            trigger: #"`1e400`-sized digits"#,
            template: LocalizedText(
                #"This number is too large."#,
                #"这个数字太大了。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .bareHexColor, severity: .error,
            trigger: #"`.color(#FF6B00)`"#,
            template: LocalizedText(
                ##"Colors go in quotes: `"#{hex}"`."##,
                ##"颜色要写在引号里：`"#{hex}"`。"##),
            placeholders: ["hex": .code],
            fixIts: [
                FixItSpec("addQuotes"),
            ]
        ),
        DiagnosticSpec(
            id: .bitsUnit, severity: .error,
            trigger: #"`100Mb`"#,
            template: LocalizedText(
                #"Desk counts bytes: `{number}{bytes}`; to show bits, use `{x, bits: true}`."#,
                #"Desk 按字节计：`{number}{bytes}`；要显示比特，用 `{x, bits: true}`。"#),
            placeholders: ["number": .code, "bytes": .code],
            fixIts: [
                FixItSpec("replace"),
            ]
        ),
        DiagnosticSpec(
            id: .spaceBeforeUnit, severity: .error,
            trigger: #"`.every(2 s)`"#,
            template: LocalizedText(
                #"Write the unit right after the number: `{number}{unit}`."#,
                #"单位要紧跟在数字后面：`{number}{unit}`。"#),
            placeholders: ["number": .code, "unit": .code],
            fixIts: [
                FixItSpec("removeSpace"),
            ]
        ),
    ]

    /// DK2xxx — structure.
    static let structureDiagnostics: [DiagnosticSpec] = [
        DiagnosticSpec(
            id: .unclosedBlock, severity: .error,
            trigger: #"a `}` missing"#,
            template: LocalizedText(
                #"The `{` of `{opener}` on line {line} has no matching `}`."#,
                #"第 {line} 行 `{opener}` 的 `{` 没有配对的 `}`。"#),
            placeholders: ["opener": .code, "line": .number],
            fixIts: [
                FixItSpec("jumpToLine"),
                FixItSpec("insert", arguments: ["text": #"}"#]),
            ]
        ),
        DiagnosticSpec(
            id: .extraClosingBrace, severity: .error,
            trigger: #"one `}` too many"#,
            template: LocalizedText(
                #"This `}` has no matching `{`."#,
                #"这个 `}` 没有配对的 `{`。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("remove"),
            ]
        ),
        DiagnosticSpec(
            id: .unclosedParen, severity: .error,
            trigger: #"`Text("A"`"#,
            template: LocalizedText(
                #"The `(` on line {line} has no matching `)`."#,
                #"第 {line} 行的 `(` 没有配对的 `)`。"#),
            placeholders: ["line": .number],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #")"#]),
            ]
        ),
        DiagnosticSpec(
            id: .unclosedBracket, severity: .error,
            trigger: #"`[.sunday, .monday`"#,
            template: LocalizedText(
                #"The `[` on line {line} has no matching `]`."#,
                #"第 {line} 行的 `[` 没有配对的 `]`。"#),
            placeholders: ["line": .number],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #"]"#]),
            ]
        ),
        DiagnosticSpec(
            id: .expected, severity: .error,
            trigger: #"`variable = 3`"#,
            template: LocalizedText(
                #"Expected {expected} here."#,
                #"这里应该写{expected}。"#),
            placeholders: ["expected": .displayName],
            fixIts: [
                FixItSpec("insert", offeredWhen: LocalizedText(#"When only one thing fits here"#, #"只有一种写法合适时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .unexpected, severity: .error,
            trigger: #"`Text("A") )`"#,
            template: LocalizedText(
                #"`{text}` doesn't belong here."#,
                #"这里不该出现 `{text}`。"#),
            placeholders: ["text": .code],
            fixIts: [
                FixItSpec("remove"),
            ]
        ),
        DiagnosticSpec(
            id: .missingComma, severity: .error,
            trigger: #"`Picker("Day" [.sunday])`"#,
            template: LocalizedText(
                #"Put a comma between these two."#,
                #"这两项之间要加逗号。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #","#]),
            ]
        ),
        DiagnosticSpec(
            id: .missingColon, severity: .error,
            trigger: #"`info { name "CPU" }`"#,
            template: LocalizedText(
                #"Put `:` after `{label}`."#,
                #"`{label}` 后面要加 `:`。"#),
            placeholders: ["label": .code],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #":"#]),
            ]
        ),
        DiagnosticSpec(
            id: .missingParens, severity: .error,
            trigger: #"`Spacer`, `.bold`"#,
            template: LocalizedText(
                #"Write `{name}()` with parentheses."#,
                #"要写成 `{name}()`，带上括号。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #"()"#]),
            ]
        ),
        DiagnosticSpec(
            id: .unexpectedBlock, severity: .error,
            trigger: #"`Text("A") { … }`"#,
            template: LocalizedText(
                #"`{name}` doesn't take `{ }`."#,
                #"`{name}` 后面不能接 `{ }`。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("removeBlock", offeredWhen: LocalizedText(#"When the block holds no actions or elements"#, #"花括号里没有动作或元素时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .blockNeeded, severity: .error,
            trigger: #"`.onClick` alone"#,
            template: LocalizedText(
                #"`{name}` needs `{ … }` holding {what}."#,
                #"`{name}` 后面要接 `{ … }`，里面写{what}。"#),
            placeholders: ["name": .code, "what": .displayName],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #" { }"#]),
            ]
        ),
        DiagnosticSpec(
            id: .callOnNextLine, severity: .error,
            trigger: #"`Text`↵`("A")`"#,
            template: LocalizedText(
                #"`(` must be on the same line as `{name}`."#,
                #"`(` 要和 `{name}` 写在同一行。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("joinLines"),
            ]
        ),
        DiagnosticSpec(
            id: .modifierWithoutElement, severity: .error,
            trigger: #"a block starting with `.font(…)`"#,
            template: LocalizedText(
                #"A modifier needs an element before it."#,
                #"修饰符前面要有一个元素。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .notAllowedHere, severity: .error,
            trigger: #"`info { }`, `options { }` or `style big { … }` inside `widget`; a field outside `info`"#,
            template: LocalizedText(
                #"{what} can't be written in {place}. {hint}"#,
                #"{place}里不能写{what}。{hint}"#),
            placeholders: ["what": .displayName, "place": .displayName, "hint": .text],
            hints: [
                HintSpec(key: "moveOut", text: LocalizedText(#"Move it out of `widget`, to the top level of the file."#, #"把它挪到 `widget` 外面，放在文件的最外层。"#)),
                HintSpec(key: "fieldOutsideInfo", text: LocalizedText(#"Fields such as `name:` belong in `info { }`."#, #"`name:` 这类字段要写在 `info { }` 里。"#)),
            ],
            fixIts: [
                FixItSpec("moveOutOfWidget", offeredWhen: LocalizedText(#"For blocks and declarations of the top level"#, #"对应该写在最外层的块和声明"#)),
            ]
        ),
        DiagnosticSpec(
            id: .unknownBlock, severity: .error,
            trigger: #"`settings { … }`"#,
            template: LocalizedText(
                #"`{word}` is not a block of a Desk file; blocks are `info`, `options`, `widget`, `style`, `translations`."#,
                #"`{word}` 不是 Desk 文件里的块；可用的块：info、options、widget、style、translations。"#),
            placeholders: ["word": .code],
            fixIts: [
                FixItSpec("didYouMean", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .duplicateBlock, severity: .error,
            trigger: #"two `widget` blocks"#,
            template: LocalizedText(
                #"There can be only one `{block}` block."#,
                #"`{block}` 块只能有一个。"#),
            placeholders: ["block": .code]
        ),
        DiagnosticSpec(
            id: .missingWidget, severity: .error,
            trigger: #"no `widget` block and nothing at the top level to put in one"#,
            template: LocalizedText(
                #"This file has no `widget { … }`."#,
                #"这个文件没有 `widget { … }`。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #"widget { }"#]),
            ]
        ),
        DiagnosticSpec(
            id: .widgetInPackage, severity: .error,
            trigger: #"`widget` in package.desk"#,
            template: LocalizedText(
                #"`package.desk` holds shared options, styles and translations; each widget has its own file."#,
                #"package.desk 只放共用的选项、样式和翻译；每个组件有自己的文件。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .packageInWidget, severity: .error,
            trigger: #"`package { }` in a widget file"#,
            template: LocalizedText(
                #"`package { }` belongs in `package.desk`."#,
                #"`package { }` 要写在 package.desk 里。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .declarationAfterView, severity: .error,
            trigger: #"`variable x = 0` after `Column { }`, or inside a `Column`"#,
            template: LocalizedText(
                #"`{keyword} {name}` must come before the elements; move it to the top of `widget`."#,
                #"`{keyword} {name}` 要写在界面元素前面，挪到 widget 的最上面。"#),
            placeholders: ["keyword": .code, "name": .code],
            fixIts: [
                FixItSpec("moveToTop"),
            ]
        ),
        DiagnosticSpec(
            id: .multipleRoots, severity: .warning,
            trigger: #"two top-level views"#,
            template: LocalizedText(
                #"The widget has {count} elements at the top; they are stacked like a Column. Wrap them in `Column { … }`."#,
                #"widget 最外层有 {count} 个元素，会像 Column 一样竖着排。请用 `Column { … }` 包起来。"#),
            placeholders: ["count": .number],
            fixIts: [
                FixItSpec("wrapIn", arguments: ["text": #"Column { }"#]),
            ]
        ),
        DiagnosticSpec(
            id: .namedWidget, severity: .error,
            trigger: #"`widget CPU { … }`"#,
            template: LocalizedText(
                #"The widget's name goes in `info { name: "{name}" }`."#,
                #"组件的名字写在 `info { name: "{name}" }` 里。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("moveNameToInfo"),
            ]
        ),
        DiagnosticSpec(
            id: .reservedBlock, severity: .error,
            trigger: #"`component StatRow(…) { }`"#,
            template: LocalizedText(
                #"`{block}` blocks come in a later version of Desk."#,
                #"`{block}` 块要到以后的版本才有。"#),
            placeholders: ["block": .code]
        ),
        DiagnosticSpec(
            id: .emptyWidget, severity: .warning,
            trigger: #"`widget { }`"#,
            template: LocalizedText(
                #"This widget doesn't show anything yet."#,
                #"这个组件还什么都没有显示。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .chainedComparison, severity: .error,
            trigger: #"`if 0 < x < 10`"#,
            template: LocalizedText(
                #"Compare two things at a time: `{a} and {b}`."#,
                #"一次只能比较两个：`{a} and {b}`。"#),
            placeholders: ["a": .code, "b": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .assignmentInCondition, severity: .error,
            trigger: #"`if page = 3`"#,
            template: LocalizedText(
                #"To compare, write `==`: `{fixed}`."#,
                #"比较要写 `==`：`{fixed}`。"#),
            placeholders: ["fixed": .code],
            fixIts: [
                FixItSpec("replaceWith", arguments: ["text": #"=="#]),
            ]
        ),
        DiagnosticSpec(
            id: .missingOperand, severity: .error,
            trigger: #"`cpu.usage >`"#,
            template: LocalizedText(
                #"Put a value after `{op}`."#,
                #"`{op}` 后面要有一个值。"#),
            placeholders: ["op": .code]
        ),
        DiagnosticSpec(
            id: .nestingTooDeep, severity: .error,
            trigger: #"70 nested blocks"#,
            template: LocalizedText(
                #"This is nested more than {limit} levels deep."#,
                #"嵌套超过了 {limit} 层。"#),
            placeholders: ["limit": .number]
        ),
        DiagnosticSpec(
            id: .tooManyProblems, severity: .info,
            trigger: #"> 500 diagnostics"#,
            template: LocalizedText(
                #"{count} more problems in this file are not listed."#,
                #"这个文件还有 {count} 个问题没有列出。"#),
            placeholders: ["count": .number]
        ),
        DiagnosticSpec(
            id: .missingSeparator, severity: .error,
            trigger: #"`Row { Icon("wifi") Text(wifi.name) }`"#,
            template: LocalizedText(
                #"Two things are written on one line; put each on its own line, or separate them with `,`."#,
                #"一行里写了两样东西；请分成两行，或者用 `,` 隔开。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("newLine"),
                FixItSpec("insert", arguments: ["text": #","#]),
            ]
        ),
        DiagnosticSpec(
            id: .modifierAfterIfOrFor, severity: .error,
            trigger: #"`for d in disks { … }`↵`.padding(4)`"#,
            template: LocalizedText(
                #"`.{name}` has nothing to apply to after the `}` of `{construct}`."#,
                #"`{construct}` 的 `}` 后面没有可以加 `.{name}` 的元素。"#),
            placeholders: ["name": .code, "construct": .code],
            fixIts: [
                FixItSpec("moveIntoEachBranch", offeredWhen: LocalizedText(#"After `if` and `else`"#, #"跟在 `if`、`else` 后面时"#)),
                FixItSpec("moveOntoElement", offeredWhen: LocalizedText(#"After a `for` whose body is one element"#, #"跟在只有一个元素的 `for` 后面时"#)),
                FixItSpec("wrapIn", arguments: ["text": #"Column { }"#]),
            ]
        ),
        DiagnosticSpec(
            id: .mixedAndOr, severity: .warning,
            trigger: #"`if a or b and c`"#,
            template: LocalizedText(
                #"`and` is worked out first, so this means `{fixed}`; add parentheses to say what you mean."#,
                #"`and` 先算，所以这里的意思是 `{fixed}`；请加上括号写清楚。"#),
            placeholders: ["fixed": .code],
            fixIts: [
                FixItSpec("insertParentheses"),
            ]
        ),
        DiagnosticSpec(
            id: .strayTopLevel, severity: .error,
            trigger: #"a file that is only `Text("Hello")`; `variable page = 0` above `widget`"#,
            template: LocalizedText(
                #"Elements and declarations go inside `widget { … }`."#,
                #"元素和声明要写在 `widget { … }` 里面。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("wrapIn", arguments: ["text": #"widget { }"#], offeredWhen: LocalizedText(#"When the file has no `widget` block"#, #"文件里没有 `widget` 块时"#)),
                FixItSpec("moveInto", arguments: ["text": #"widget"#], offeredWhen: LocalizedText(#"When the file has a `widget` block"#, #"文件里已经有 `widget` 块时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .equalsInField, severity: .error,
            trigger: #"`info { name = "CPU" }`, `{x, decimals = 1}`"#,
            template: LocalizedText(
                #"`{label}` is filled in with `:`: `{fixed}`."#,
                #"`{label}` 要用 `:` 填写：`{fixed}`。"#),
            placeholders: ["label": .code, "fixed": .code],
            fixIts: [
                FixItSpec("replaceWith", arguments: ["text": #":"#]),
                FixItSpec("fixAll", fixAll: true),
            ]
        ),
        DiagnosticSpec(
            id: .colonInOption, severity: .error,
            trigger: #"`accent: ColorPicker("Accent")` in `options`"#,
            template: LocalizedText(
                #"Options are named with `=`: `{fixed}`."#,
                #"选项用 `=` 起名：`{fixed}`。"#),
            placeholders: ["fixed": .code],
            fixIts: [
                FixItSpec("replaceWith", arguments: ["text": #"="#]),
            ]
        ),
        DiagnosticSpec(
            id: .blockInParentheses, severity: .error,
            trigger: #"`.onClick(page = page + 1)`, `.hover(.color(.accent))`"#,
            template: LocalizedText(
                #"`.{name}` takes {what} in braces: `{fixed}`."#,
                #"`.{name}` 后面的{what}要写在花括号里：`{fixed}`。"#),
            placeholders: ["name": .code, "what": .displayName, "fixed": .code],
            fixIts: [
                FixItSpec("useBraces"),
            ]
        ),
    ]

    /// DK3xxx — names.
    static let namesDiagnostics: [DiagnosticSpec] = [
        DiagnosticSpec(
            id: .unknownModifier, severity: .error,
            trigger: #"`.colour(.red)`"#,
            template: LocalizedText(
                #"There's no `.{name}`. Did you mean `.{suggestion}`?"#,
                #"没有 `.{name}`，是不是想写 `.{suggestion}`？"#),
            placeholders: ["name": .code, "suggestion": .code],
            fixIts: [
                FixItSpec("fix", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .unknownName, severity: .error,
            trigger: #"`Text("{cpuu.usage}")`"#,
            template: LocalizedText(
                #"There's no `{name}`. Did you mean `{suggestion}`?"#,
                #"没有 `{name}`，是不是想写 `{suggestion}`？"#),
            placeholders: ["name": .code, "suggestion": .code],
            fixIts: [
                FixItSpec("fix", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .unknownMember, severity: .error,
            trigger: #"`music.playpause()`"#,
            template: LocalizedText(
                #"`{base}` has no `{name}`. Did you mean `{suggestion}`?"#,
                #"`{base}` 没有 `{name}`，是不是想写 `{suggestion}`？"#),
            placeholders: ["base": .code, "name": .code, "suggestion": .code],
            fixIts: [
                FixItSpec("fix", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .unknownComponent, severity: .error,
            trigger: #"`Txt("A")`"#,
            template: LocalizedText(
                #"There's no component `{name}`. Did you mean `{suggestion}`?"#,
                #"没有 `{name}` 这个组件，是不是想写 `{suggestion}`？"#),
            placeholders: ["name": .code, "suggestion": .code],
            fixIts: [
                FixItSpec("fix", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .unknownChoice, severity: .error,
            trigger: #"`.font(.cation)`"#,
            template: LocalizedText(
                #"`.{name}` is not one of the choices for {what}: {choices}."#,
                #"`.{name}` 不是{what}可选的值。可选：{choices}。"#),
            placeholders: ["name": .code, "what": .displayName, "choices": .list],
            fixIts: [
                FixItSpec("didYouMean", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .unknownLabel, severity: .error,
            trigger: #"`Grid(colums: 7)`; `.size(width: 28, height: 24)`; `.color(.red, if: hot, else: .green)`"#,
            template: LocalizedText(
                #"`{component}` has no `{label}:`. {hint}"#,
                #"`{component}` 没有 `{label}:` 这一项。{hint}"#),
            placeholders: ["component": .code, "label": .code, "hint": .text, "labels": .list, "fixed": .code],
            hints: [
                HintSpec(key: "takes", text: LocalizedText(#"It takes: {labels}."#, #"可用：{labels}。"#)),
                HintSpec(key: "noLabelsNeeded", text: LocalizedText(#"It takes its values without labels: `{fixed}`."#, #"它的值不带名字：`{fixed}`。"#)),
                HintSpec(key: "noLabels", text: LocalizedText(#"It takes no labels."#, #"它不带任何名字。"#)),
                HintSpec(key: "elseLabel", text: LocalizedText(#"Write a plain value and the conditional one: `{fixed}`."#, #"先写不带条件的值，再写带条件的：`{fixed}`。"#)),
            ],
            fixIts: [
                FixItSpec("didYouMean", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
                FixItSpec("removeLabels", offeredWhen: LocalizedText(#"When the values take no labels"#, #"值不带名字时"#)),
                FixItSpec("rewrite", offeredWhen: LocalizedText(#"For `else:`"#, #"对 `else:`"#)),
            ]
        ),
        DiagnosticSpec(
            id: .unknownStyle, severity: .error,
            trigger: #"`.style(dateCel)`"#,
            template: LocalizedText(
                #"There's no style `{name}`."#,
                #"没有叫 `{name}` 的样式。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("didYouMean", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
                FixItSpec("createStyle"),
            ]
        ),
        DiagnosticSpec(
            id: .unknownOption, severity: .error,
            trigger: #"`options.weekstart`"#,
            template: LocalizedText(
                #"`options` has no `{name}`."#,
                #"options 里没有 `{name}`。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("didYouMean", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .unknownElementName, severity: .error,
            trigger: #"`show(detials)`"#,
            template: LocalizedText(
                #"No element is named `{name}`."#,
                #"没有叫 `{name}` 的元素。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("didYouMean", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .missingDot, severity: .error,
            trigger: #"`.font(caption)`"#,
            template: LocalizedText(
                #"Built-in names start with a dot: `.{name}`."#,
                #"内置的名字前面要加点：`.{name}`。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #"."#]),
            ]
        ),
        DiagnosticSpec(
            id: .missingOptionsPrefix, severity: .error,
            trigger: #"`Text(weekStart)`"#,
            template: LocalizedText(
                #"`{name}` is an option; write `options.{name}`."#,
                #"`{name}` 是选项，要写成 `options.{name}`。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #"options."#]),
            ]
        ),
        DiagnosticSpec(
            id: .dotOnOwnStyle, severity: .error,
            trigger: #"`.style(.todayCell)`"#,
            template: LocalizedText(
                #"Your own style names have no dot: `.style({name})`."#,
                #"自己起的样式名前面不加点：`.style({name})`。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("removeDot"),
            ]
        ),
        DiagnosticSpec(
            id: .wrongCase, severity: .error,
            trigger: #"`Cpu.usage`, `If`, `AND`"#,
            template: LocalizedText(
                #"Desk is case-sensitive. Did you mean `{suggestion}`?"#,
                #"Desk 区分大小写。是不是想写 `{suggestion}`？"#),
            placeholders: ["suggestion": .code],
            fixIts: [
                FixItSpec("fix"),
            ]
        ),
        DiagnosticSpec(
            id: .nameAlreadyUsed, severity: .error,
            trigger: #"`variable title = 0` and `.name(title)`; two `variable page`"#,
            template: LocalizedText(
                #"`{name}` is already used by {other}; choose another name."#,
                #"`{name}` 已经被{other}用了，请换一个名字。"#),
            placeholders: ["name": .code, "other": .text],
            fixIts: [
                FixItSpec("renameThisOneEverywhere"),
            ]
        ),
        DiagnosticSpec(
            id: .reservedName, severity: .error,
            trigger: #"`variable if = 0`, `for event in …`"#,
            template: LocalizedText(
                #"`{name}` is a reserved word; choose another name."#,
                #"`{name}` 是保留字，请换一个名字。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("rename"),
                FixItSpec("renameTo", arguments: ["text": #"item"#], offeredWhen: LocalizedText(#"For `event`"#, #"对 `event`"#)),
            ]
        ),
        DiagnosticSpec(
            id: .nameStartsUppercase, severity: .error,
            trigger: #"`variable Page = 0`"#,
            template: LocalizedText(
                #"Names you make start with a small letter: `{suggestion}`."#,
                #"自己起的名字要用小写字母开头：`{suggestion}`。"#),
            placeholders: ["suggestion": .code],
            fixIts: [
                FixItSpec("renameEverywhere"),
            ]
        ),
        DiagnosticSpec(
            id: .componentLowercase, severity: .error,
            trigger: #"`text("A")`"#,
            template: LocalizedText(
                #"Components start with a capital letter: `{suggestion}`."#,
                #"组件名要用大写字母开头：`{suggestion}`。"#),
            placeholders: ["suggestion": .code],
            fixIts: [
                FixItSpec("fix"),
            ]
        ),
        DiagnosticSpec(
            id: .ambiguousChoice, severity: .error,
            trigger: #"`variable side = .left` when no use settles it (§4.3)"#,
            template: LocalizedText(
                #"`.{name}` could be {candidates}; write the one you mean in full."#,
                #"`.{name}` 可能是{candidates}，请写完整。"#),
            placeholders: ["name": .code, "candidates": .list],
            fixIts: [
                FixItSpec("qualifyChoice", offeredWhen: LocalizedText(#"One for each type it could be"#, #"每种可能的类型各一个"#)),
            ]
        ),
        DiagnosticSpec(
            id: .choiceNeedsContext, severity: .error,
            trigger: #"`computed x = .glass`"#,
            template: LocalizedText(
                #"Desk can't tell what `.{name}` is here."#,
                #"这里看不出 `.{name}` 是什么。"#),
            placeholders: ["name": .code]
        ),
        DiagnosticSpec(
            id: .unusedDeclaration, severity: .warning,
            trigger: #"a variable never read"#,
            template: LocalizedText(
                #"`{name}` is never used."#,
                #"`{name}` 没有用到。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("remove"),
            ]
        ),
        DiagnosticSpec(
            id: .unusedStyle, severity: .warning,
            trigger: #"a style never applied"#,
            template: LocalizedText(
                #"Style `{name}` is never used."#,
                #"样式 `{name}` 没有用到。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("remove"),
            ]
        ),
        DiagnosticSpec(
            id: .unusedOption, severity: .warning,
            trigger: #"an option never read"#,
            template: LocalizedText(
                #"Option `{name}` is never used; it still appears in the Options panel."#,
                #"选项 `{name}` 没有用到，但仍会出现在选项面板里。"#),
            placeholders: ["name": .code]
        ),
        DiagnosticSpec(
            id: .newerName, severity: .error,
            trigger: #"an unknown name in a file with `info { requires: "1.2" }`, checked by Deskset 1.0"#,
            template: LocalizedText(
                #"`{name}` isn't in this version of Deskset; this widget needs Deskset {version} or later. Update Deskset."#,
                #"这个版本的 Deskset 没有 `{name}`；这个组件需要 Deskset {version} 或更新的版本。请更新 Deskset。"#),
            placeholders: ["name": .code, "version": .plain]
        ),
        DiagnosticSpec(
            id: .eventOutsideEvent, severity: .error,
            trigger: #"`event.x` in `.every`"#,
            template: LocalizedText(
                #"`event` is only available in `.onClick`, `.onDoubleClick`, `.onRightClick`, `.onDrag`, `.onDrop` and `.onScroll`."#,
                #"`event` 只能在 .onClick、.onDoubleClick、.onRightClick、.onDrag、.onDrop、.onScroll 里用。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .optionReplacesPackage, severity: .info,
            trigger: #"same option name as package.desk"#,
            template: LocalizedText(
                #"Option `{name}` replaces the package's option of the same name."#,
                #"选项 `{name}` 会替代包里同名的选项。"#),
            placeholders: ["name": .code]
        ),
        DiagnosticSpec(
            id: .styleReplacesPackage, severity: .info,
            trigger: #"same style name as package.desk"#,
            template: LocalizedText(
                #"Style `{name}` replaces the package's style of the same name."#,
                #"样式 `{name}` 会替代包里同名的样式。"#),
            placeholders: ["name": .code]
        ),
        DiagnosticSpec(
            id: .componentAsValue, severity: .error,
            trigger: #"`computed c = Column`"#,
            template: LocalizedText(
                #"`{name}` is a component; it can't be used as a value."#,
                #"`{name}` 是组件，不能当作值用。"#),
            placeholders: ["name": .code]
        ),
        DiagnosticSpec(
            id: .hidesBuiltIn, severity: .info,
            trigger: #"`variable time = 0`"#,
            template: LocalizedText(
                #"Your `{name}` hides the built-in `{name}` in this widget; a clearer name is `{suggestion}`."#,
                #"你起的 `{name}` 会在这个组件里盖住内置的 `{name}`；换成 `{suggestion}` 更清楚。"#),
            placeholders: ["name": .code, "suggestion": .code],
            fixIts: [
                FixItSpec("renameEverywhereTo"),
            ]
        ),
        DiagnosticSpec(
            id: .replacedOptionTypeDiffers, severity: .error,
            trigger: #"`accent = ColorPicker(…)` in package.desk, `accent = Toggle(…)` in the widget"#,
            template: LocalizedText(
                #"Option `{name}` replaces the package's option of the same name, so it must hold {expected} too; this one holds {actual}."#,
                #"选项 `{name}` 会替代包里同名的选项，所以它的值也要是{expected}；这里是{actual}。"#),
            placeholders: ["name": .code, "expected": .displayName, "actual": .displayName]
        ),
        DiagnosticSpec(
            id: .declaredLater, severity: .error,
            trigger: #"`variable total = count * 2` above `variable count = 0`"#,
            template: LocalizedText(
                #"`{name}` is declared further down, so it has no value yet here; move this line below it."#,
                #"`{name}` 在后面才声明，这里还没有值；请把这一行挪到它下面。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("moveBelow"),
            ]
        ),
        DiagnosticSpec(
            id: .localChoices, severity: .info,
            trigger: #"`side = Picker("Side", [.left, .right])` used nowhere that needs a built-in"#,
            template: LocalizedText(
                #"These choices are also {candidates}; they stay this option's own choices. Write `{fixed}` to use them with a built-in."#,
                #"这些选项同时也是{candidates}；现在它们是这个选项自己的选项。写成 `{fixed}` 才能和内置的功能一起用。"#),
            placeholders: ["candidates": .list, "fixed": .code],
            fixIts: [
                FixItSpec("qualifyChoice", offeredWhen: LocalizedText(#"One for each type the choices belong to"#, #"选项所属的每种类型各一个"#)),
            ]
        ),
        DiagnosticSpec(
            id: .missingModifierDot, severity: .error,
            trigger: #"`font(.caption)` on the line after an element"#,
            template: LocalizedText(
                #"`{name}` is a modifier: write `.{name}(…)`."#,
                #"`{name}` 是修饰符，要写成 `.{name}(…)`。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #"."#]),
                FixItSpec("fixAll", fixAll: true),
            ]
        ),
        DiagnosticSpec(
            id: .textWithoutQuotes, severity: .error,
            trigger: #"`Text(CPU)`"#,
            template: LocalizedText(
                #"Put words in quotes: `{fixed}`."#,
                #"文字要放在引号里：`{fixed}`。"#),
            placeholders: ["fixed": .code],
            fixIts: [
                FixItSpec("addQuotes"),
                FixItSpec("fix", offeredWhen: LocalizedText(#"When the name differs only in case"#, #"名字只差大小写时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .undeclaredAssignment, severity: .error,
            trigger: #"`page = 0` directly in `widget`"#,
            template: LocalizedText(
                #"`{name}` isn't declared yet. Declare it: `variable {name} = …`."#,
                #"`{name}` 还没有声明，请先声明：`variable {name} = …`。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("declareWith", arguments: ["text": #"variable"#]),
                FixItSpec("declareWith", arguments: ["text": #"saved"#]),
                FixItSpec("declareWith", arguments: ["text": #"computed"#]),
            ]
        ),
        DiagnosticSpec(
            id: .quotedOwnName, severity: .warning,
            trigger: #"`.name("title")`, `show("details")`, `.style("todayCell")`"#,
            template: LocalizedText(
                #"Names you give are written without quotes: `{fixed}`."#,
                #"自己起的名字不加引号：`{fixed}`。"#),
            placeholders: ["fixed": .code],
            fixIts: [
                FixItSpec("removeQuotes"),
                FixItSpec("fixAll", fixAll: true),
            ]
        ),
        DiagnosticSpec(
            id: .namespaceAsValue, severity: .error,
            trigger: #"`Text(cpu)`, `Text(time)`"#,
            template: LocalizedText(
                #"`{name}` is a group of data; pick one of them, such as `{suggestion}`."#,
                #"`{name}` 是一组数据，要选其中一项，比如 `{suggestion}`。"#),
            placeholders: ["name": .code, "suggestion": .code],
            fixIts: [
                FixItSpec("replaceWith"),
            ]
        ),
    ]

    /// DK4xxx — types, units and values.
    static let valuesDiagnostics: [DiagnosticSpec] = [
        DiagnosticSpec(
            id: .typeMismatch, severity: .error,
            trigger: #"`.font(true)`"#,
            template: LocalizedText(
                #"{what} needs {expected}, but this is {actual}."#,
                #"{what}要的是{expected}，这里是{actual}。"#),
            placeholders: ["what": .displayName, "expected": .displayName, "actual": .displayName],
            fixIts: [
                FixItSpec("convert", offeredWhen: LocalizedText(#"When the value can be converted"#, #"值可以转换时"#)),
                FixItSpec("replaceWith", arguments: ["text": #"x = not x"#], offeredWhen: LocalizedText(#"For `showOrHide(x)` or `toggle(x)` with a yes/no value"#, #"对带是/否值的 `showOrHide(x)` 或 `toggle(x)`"#)),
            ]
        ),
        DiagnosticSpec(
            id: .missingArgument, severity: .error,
            trigger: #"`Grid { }`, `.padding()`"#,
            template: LocalizedText(
                #"`{name}` needs {what}."#,
                #"`{name}` 需要{what}。"#),
            placeholders: ["name": .code, "what": .displayName],
            fixIts: [
                FixItSpec("insert"),
            ]
        ),
        DiagnosticSpec(
            id: .tooManyArguments, severity: .error,
            trigger: #"`Text("A", "B")`; `.hidden(not day.inMonth)`; `Line(cpu.usage)`"#,
            template: LocalizedText(
                #"`{name}` takes {count} value(s) here. {hint}"#,
                #"`{name}` 这里只能写 {count} 个值。{hint}"#),
            placeholders: ["name": .code, "count": .number, "hint": .text, "fixed": .code],
            hints: [
                HintSpec(key: "addLabel", text: LocalizedText(#"Write `{fixed}`."#, #"写成 `{fixed}`。"#)),
                HintSpec(key: "lineMeter", text: LocalizedText(#"Rainmeter's Line meter is `Graph` in Desk."#, #"Rainmeter 的 Line 在 Desk 里是 `Graph`。"#)),
                HintSpec(key: "colorNumbers", text: LocalizedText(#"For a color from red, green and blue, write `{fixed}`."#, #"要用红绿蓝数值写颜色，写成 `{fixed}`。"#)),
            ],
            fixIts: [
                FixItSpec("insert", offeredWhen: LocalizedText(#"When the value fits exactly one label"#, #"值正好符合一个名字时"#)),
                FixItSpec("replaceWith", arguments: ["text": #"Graph(…)"#], offeredWhen: LocalizedText(#"For `Line` with a value"#, #"对带值的 `Line`"#)),
                FixItSpec("replaceWith", arguments: ["text": #"rgb(…)"#], offeredWhen: LocalizedText(#"For three or four numbers given to a color"#, #"给颜色写了三四个数时"#)),
                FixItSpec("removeExtra", offeredWhen: LocalizedText(#"Only when nothing else fits"#, #"没有别的写法合适时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .duplicateLabel, severity: .error,
            trigger: #"`.padding(top: 4, top: 8)`"#,
            template: LocalizedText(
                #"`{label}:` is given twice."#,
                #"`{label}:` 写了两次。"#),
            placeholders: ["label": .code],
            fixIts: [
                FixItSpec("removeOne"),
            ]
        ),
        DiagnosticSpec(
            id: .positionalAfterLabel, severity: .error,
            trigger: #"`Picker(default: .sunday, "Day")`"#,
            template: LocalizedText(
                #"Values without a label come first."#,
                #"不带名字的值要写在前面。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("reorder"),
            ]
        ),
        DiagnosticSpec(
            id: .notAssignable, severity: .error,
            trigger: #"`month = 0` (computed); `music.playing = true`"#,
            template: LocalizedText(
                #"`{name}` can't be changed: {reason}. {hint}"#,
                #"`{name}` 不能改：{reason}。{hint}"#),
            placeholders: ["name": .code, "reason": .text, "hint": .text, "fixed": .code],
            hints: [
                HintSpec(key: "computed", placeholder: "reason", text: LocalizedText(#"it is worked out from other values"#, #"它是由其他值算出来的"#)),
                HintSpec(key: "loopVariable", placeholder: "reason", text: LocalizedText(#"it is the item of a `for`"#, #"它是 `for` 的每一项"#)),
                HintSpec(key: "event", placeholder: "reason", text: LocalizedText(#"`event` describes what just happened"#, #"`event` 描述的是刚发生的事"#)),
                HintSpec(key: "readOnlyData", placeholder: "reason", text: LocalizedText(#"this data can only be read"#, #"这项数据只能读"#)),
                HintSpec(key: "useTwin", text: LocalizedText(#"Write `{fixed}` instead."#, #"请改写成 `{fixed}`。"#)),
            ],
            fixIts: [
                FixItSpec("replaceWith", offeredWhen: LocalizedText(#"When there is a settable twin or an action"#, #"有可以赋值的同名数据或对应的动作时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .notBindable, severity: .error,
            trigger: #"`Toggle("A", cpu.usage > 5)`"#,
            template: LocalizedText(
                #"A control needs a `variable`, a `saved` value, an option or adjustable data such as `volume.level`; this is {kind}."#,
                #"控件要绑定 variable、saved、选项，或 volume.level 这类可调的数据；这里是{kind}。"#),
            placeholders: ["kind": .displayName]
        ),
        DiagnosticSpec(
            id: .unitMismatch, severity: .error,
            trigger: #"`cpu.usage + memory.used`"#,
            template: LocalizedText(
                #"Can't {op} {a} and {b}: they measure different things."#,
                #"{a}和{b}量的不是同一种东西，不能{op}。"#),
            placeholders: ["op": .text, "a": .displayName, "b": .displayName]
        ),
        DiagnosticSpec(
            id: .unitNeeded, severity: .error,
            trigger: #"`.every(500)`, `info { refresh: 1000 }`, `sensors.cpuTemperature > 80`, `variable delay = 500` used in `after(delay)`"#,
            template: LocalizedText(
                #"`{number}` needs a unit here: {readings}."#,
                #"`{number}` 这里要写单位：{readings}。"#),
            placeholders: ["number": .code, "readings": .text, "milliseconds": .text, "seconds": .text],
            hints: [
                HintSpec(key: "time", placeholder: "readings", text: LocalizedText(#"`{number}ms` {milliseconds}, `{number}s` {seconds}"#, #"`{number}ms` {milliseconds}，`{number}s` {seconds}"#)),
                HintSpec(key: "temperature", placeholder: "readings", text: LocalizedText(#"`{number}°C` or `{number}°F`"#, #"`{number}°C` 或 `{number}°F`"#)),
                HintSpec(key: "speed", placeholder: "readings", text: LocalizedText(#"`{number}km/h` or `{number}mph`"#, #"`{number}km/h` 或 `{number}mph`"#)),
                HintSpec(key: "rainfall", placeholder: "readings", text: LocalizedText(#"`{number}mm` or `{number}inch`"#, #"`{number}mm` 或 `{number}inch`"#)),
                HintSpec(key: "pressure", placeholder: "readings", text: LocalizedText(#"`{number}hPa` or `{number}inHg`"#, #"`{number}hPa` 或 `{number}inHg`"#)),
                HintSpec(key: "frequency", placeholder: "readings", text: LocalizedText(#"`{number}MHz` or `{number}GHz`"#, #"`{number}MHz` 或 `{number}GHz`"#)),
                HintSpec(key: "angle", placeholder: "readings", text: LocalizedText(#"`* 1°` for degrees or `* 1rad` for radians"#, #"角度写 `* 1°`，弧度写 `* 1rad`"#)),
            ],
            fixIts: [
                FixItSpec("writeUnit", offeredWhen: LocalizedText(#"The likelier reading first"#, #"更可能的读法在前"#)),
                FixItSpec("writeUnit"),
            ]
        ),
        DiagnosticSpec(
            id: .lengthAsText, severity: .error,
            trigger: #"`.padding("18px")`"#,
            template: LocalizedText(
                #"Lengths are plain numbers in points: `{number}`."#,
                #"长度直接写数字，单位是点：`{number}`。"#),
            placeholders: ["number": .code],
            fixIts: [
                FixItSpec("replace"),
            ]
        ),
        DiagnosticSpec(
            id: .fractionOver1, severity: .warning,
            trigger: #"`.opacity(60)`"#,
            template: LocalizedText(
                #"{what} goes from 0 to 1, or 0% to 100%. Did you mean `{number}%`?"#,
                #"{what}的范围是 0 到 1，或者 0% 到 100%。是不是想写 `{number}%`？"#),
            placeholders: ["what": .displayName, "number": .code],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #"%"#]),
            ]
        ),
        DiagnosticSpec(
            id: .outOfRange, severity: .error,
            trigger: #"`Grid(columns: 0)`"#,
            template: LocalizedText(
                #"{what} must be between {min} and {max}."#,
                #"{what}要在 {min} 到 {max} 之间。"#),
            placeholders: ["what": .displayName, "min": .plain, "max": .plain],
            fixIts: [
                FixItSpec("clamp"),
            ]
        ),
        DiagnosticSpec(
            id: .notWholeNumber, severity: .error,
            trigger: #"`.lines(1.5)`"#,
            template: LocalizedText(
                #"{what} must be a whole number."#,
                #"{what}要是整数。"#),
            placeholders: ["what": .displayName],
            fixIts: [
                FixItSpec("round"),
            ]
        ),
        DiagnosticSpec(
            id: .invalidColor, severity: .error,
            trigger: ##"`.color("#FF6B0")`, `.color("255,255,255")`, `.color("FF6B00")`"##,
            template: LocalizedText(
                ##"`"{text}"` is not a color: write `"#RRGGBB"`, `"#RRGGBBAA"` or a name such as `.red`."##,
                ##"`"{text}"` 不是颜色：写 `"#RRGGBB"`、`"#RRGGBBAA"`，或 `.red` 这样的名字。"##),
            placeholders: ["text": .code],
            fixIts: [
                FixItSpec("didYouMean", offeredWhen: LocalizedText(#"For color names"#, #"对颜色名"#)),
                FixItSpec("convert", offeredWhen: LocalizedText(#"For a Rainmeter color or bare hex digits"#, #"对 Rainmeter 颜色或不带 # 的十六进制"#)),
            ]
        ),
        DiagnosticSpec(
            id: .notDisplayable, severity: .error,
            trigger: #"`Text(month.days)`"#,
            template: LocalizedText(
                #"`{text}` is {type}, which can't be shown as text. {hint}"#,
                #"`{text}` 是{type}，不能直接显示成文字。{hint}"#),
            placeholders: ["text": .code, "type": .displayName, "hint": .text, "fixed": .code],
            hints: [
                HintSpec(key: "joinList", text: LocalizedText(#"To show a list, join it: `{fixed}`."#, #"要显示一组值，先把它们连起来：`{fixed}`。"#)),
            ],
            fixIts: [
                FixItSpec("append", arguments: ["text": #".joined(", ")"#], offeredWhen: LocalizedText(#"For lists"#, #"对列表"#)),
            ]
        ),
        DiagnosticSpec(
            id: .conditionNotBool, severity: .error,
            trigger: #"`if count { … }`"#,
            template: LocalizedText(
                #"A condition must be yes or no; compare it, for example `{text} > 0`."#,
                #"条件要是“是/否”；请比较一下，比如 `{text} > 0`。"#),
            placeholders: ["text": .code]
        ),
        DiagnosticSpec(
            id: .textPlus, severity: .error,
            trigger: #"`"CPU " + cpu.usage`"#,
            template: LocalizedText(
                #"Put values inside the text instead: `"{fixed}"`."#,
                #"把值直接放进文字里：`"{fixed}"`。"#),
            placeholders: ["fixed": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .unknownRange, severity: .error,
            trigger: #"`Progress(web.json(url).count)`"#,
            template: LocalizedText(
                #"This value has no known range, so {component} doesn't know what full is: add `total:`."#,
                #"这个值没有已知的范围，{component}不知道满格是多少：加上 `total:`。"#),
            placeholders: ["component": .displayName],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #", total: "#]),
            ]
        ),
        DiagnosticSpec(
            id: .listTooLong, severity: .error,
            trigger: #"a 2,000-item list literal"#,
            template: LocalizedText(
                #"This list has {count} items; at most {limit}."#,
                #"这个列表有 {count} 项，最多 {limit} 项。"#),
            placeholders: ["count": .number, "limit": .number]
        ),
        DiagnosticSpec(
            id: .emptyRange, severity: .warning,
            trigger: #"`for i in 5...1`"#,
            template: LocalizedText(
                #"`{a}...{b}` is empty because {a} is larger than {b}."#,
                #"`{a}...{b}` 是空的，因为 {a} 比 {b} 大。"#),
            placeholders: ["a": .code, "b": .code],
            fixIts: [
                FixItSpec("swap"),
            ]
        ),
        DiagnosticSpec(
            id: .notOrdered, severity: .error,
            trigger: #"`if music.title < "M"`"#,
            template: LocalizedText(
                #"`{text}` is {type}, which can only be compared with `==` and `!=`."#,
                #"`{text}` 是{type}，只能用 `==` 和 `!=` 比较。"#),
            placeholders: ["text": .code, "type": .displayName]
        ),
        DiagnosticSpec(
            id: .formatOptionNotApplicable, severity: .error,
            trigger: #"`"{music.title, decimals: 1}"`"#,
            template: LocalizedText(
                #"`{label}:` is not a format option for {type}. Options: {list}."#,
                #"`{label}:` 不是{type}的格式选项。可用：{list}。"#),
            placeholders: ["label": .code, "type": .displayName, "list": .list],
            fixIts: [
                FixItSpec("didYouMean", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .invalidDatePattern, severity: .error,
            trigger: #"`format: "HH:mm:"` with an unknown letter"#,
            template: LocalizedText(
                #"`"{pattern}"` is not a valid date format: {reason}."#,
                #"`"{pattern}"` 不是有效的日期格式：{reason}。"#),
            placeholders: ["pattern": .code, "reason": .text]
        ),
        DiagnosticSpec(
            id: .invalidPattern, severity: .error,
            trigger: #"`.match("(abc")`"#,
            template: LocalizedText(
                #"This pattern is not valid: {reason}."#,
                #"这个匹配规则写得不对：{reason}。"#),
            placeholders: ["reason": .text]
        ),
        DiagnosticSpec(
            id: .invalidPathData, severity: .error,
            trigger: #"`Path("M 0 0 X 5")`"#,
            template: LocalizedText(
                #"Path data error at "{snippet}": {reason}."#,
                #"路径数据在 "{snippet}" 处有错：{reason}。"#),
            placeholders: ["snippet": .plain, "reason": .text]
        ),
        DiagnosticSpec(
            id: .fileNotFound, severity: .error,
            trigger: #"`Image("pasue.png")`"#,
            template: LocalizedText(
                #"Can't find `{path}` in the widget's folder. {suggestion}"#,
                #"在组件文件夹里找不到 `{path}`。{suggestion}"#),
            placeholders: ["path": .code, "suggestion": .text],
            fixIts: [
                FixItSpec("replaceWithSimilarFile", offeredWhen: LocalizedText(#"When a similar file exists"#, #"有相近的文件时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .fileOutsideWidget, severity: .error,
            trigger: #"`Image("../x.png")`, `Image("/Users/…")`"#,
            template: LocalizedText(
                #"Files must be inside the widget's folder."#,
                #"文件要放在组件文件夹里。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .unknownSymbol, severity: .warning,
            trigger: #"`Icon("wifi.slashh")`"#,
            template: LocalizedText(
                #"macOS has no SF Symbol named "{name}". Did you mean "{suggestion}"?"#,
                #"macOS 没有叫 "{name}" 的 SF 符号，是不是想写 "{suggestion}"？"#),
            placeholders: ["name": .plain, "suggestion": .plain],
            fixIts: [
                FixItSpec("fix", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .fontNotInstalled, severity: .warning,
            trigger: #"`.font("Futur", 13)`"#,
            template: LocalizedText(
                #"The font "{name}" isn't installed; the system font is used."#,
                #"没有安装字体 "{name}"，会用系统字体显示。"#),
            placeholders: ["name": .plain],
            fixIts: [
                FixItSpec("didYouMean", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .windowsFont, severity: .info,
            trigger: #"`.font("Segoe UI", 13)`"#,
            template: LocalizedText(
                #""{name}" is a Windows font; the Mac shows it as {substitute}."#,
                #""{name}" 是 Windows 字体，Mac 上会用 {substitute} 显示。"#),
            placeholders: ["name": .plain, "substitute": .plain],
            fixIts: [
                FixItSpec("replaceWith"),
            ]
        ),
        DiagnosticSpec(
            id: .secretShown, severity: .error,
            trigger: #"`Text(options.apiKey)`"#,
            template: LocalizedText(
                #"A secret option can't be shown, copied or logged."#,
                #"密钥类的选项不能显示、复制或写进日志。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .savedNotConstant, severity: .error,
            trigger: #"`saved start = time.now`"#,
            template: LocalizedText(
                #"A `saved` value starts from a fixed value; `{text}` changes."#,
                #"saved 的初始值要写死；`{text}` 会变。"#),
            placeholders: ["text": .code]
        ),
        DiagnosticSpec(
            id: .notSavable, severity: .error,
            trigger: #"`saved m = calendar.month()`"#,
            template: LocalizedText(
                #"`{name}` can't be saved: it holds {type}. Saved values are numbers, text, yes/no, colors, dates, choices and lists of them."#,
                #"`{name}` 不能保存：它的值是{type}。能保存的是数字、文字、是/否、颜色、日期、选项，以及它们的列表。"#),
            placeholders: ["name": .code, "type": .displayName]
        ),
        DiagnosticSpec(
            id: .randomOutsideAction, severity: .error,
            trigger: #"`Text("{random(1, 6)}")`"#,
            template: LocalizedText(
                #"A random number here would keep changing; set a variable in `.every` or `.onClick`."#,
                #"这里的随机数会不停变化；请在 .every 或 .onClick 里给变量赋值。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .ternaryTip, severity: .info,
            trigger: #"`.color(cpu.usage > 80 ? .red : .text)`"#,
            template: LocalizedText(
                #"This can be written `.{name}({b}).{name}({a}, if: {cond})`."#,
                #"可以写成 `.{name}({b}).{name}({a}, if: {cond})`。"#),
            placeholders: ["name": .code, "b": .code, "a": .code, "cond": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .computedCycle, severity: .error,
            trigger: #"`computed a = b + 1` / `computed b = a`"#,
            template: LocalizedText(
                #"These values depend on each other: {cycle}."#,
                #"这些值互相依赖：{cycle}。"#),
            placeholders: ["cycle": .list]
        ),
        DiagnosticSpec(
            id: .usesDisagree, severity: .error,
            trigger: #"`saved threshold = 80` compared with `cpu.usage` and used in `.font(threshold)`"#,
            template: LocalizedText(
                #"Desk can't tell what `{name}` is: it is {uses}."#,
                #"看不出 `{name}` 是什么：它{uses}。"#),
            placeholders: ["name": .code, "uses": .list],
            fixIts: [
                FixItSpec("writeUnit", arguments: ["text": #"80%"#]),
                FixItSpec("qualifyChoice", arguments: ["text": #"HAlign.left"#]),
            ]
        ),
        DiagnosticSpec(
            id: .byteBaseDisagrees, severity: .warning,
            trigger: #"`computed low = 2GB` compared with `memory.free` and `disk.free`"#,
            template: LocalizedText(
                #"`{name}` is compared with memory, counted in 1024s, and with disk space, counted in 1000s; it uses 1000s. Write `{fixed}` to mean 1024s everywhere."#,
                #"`{name}` 既和按 1024 计的内存比较，又和按 1000 计的磁盘空间比较；现在按 1000 计。写成 `{fixed}` 就处处按 1024 计。"#),
            placeholders: ["name": .code, "fixed": .code],
            fixIts: [
                FixItSpec("replaceWith", arguments: ["text": #"GiB"#]),
            ]
        ),
        DiagnosticSpec(
            id: .notWithMissing, severity: .info,
            trigger: #"`if not (music.player == "Spotify")`"#,
            template: LocalizedText(
                #"While `{text}` is missing, this condition is false too. To count "missing" as a match, write `{fixed}`."#,
                #"`{text}` 取不到值的时候，这个条件也是“否”。想把取不到也算成符合，写成 `{fixed}`。"#),
            placeholders: ["text": .code, "fixed": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .manualConversion, severity: .info,
            trigger: #"`memory.used / 1024 / 1024`, `cpu.usage / 100`"#,
            template: LocalizedText(
                #"Desk keeps the unit through arithmetic, so this converts twice. Write `{fixed}`."#,
                #"Desk 计算时会保留单位，这样会换算两次。请写成 `{fixed}`。"#),
            placeholders: ["fixed": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .quotedChoice, severity: .error,
            trigger: #"`.font("headline")`, `info { size: "small" }`"#,
            template: LocalizedText(
                #"`"{text}"` is a built-in choice: write `.{text}` without quotes."#,
                #"`"{text}"` 是内置的选项：去掉引号，写成 `.{text}`。"#),
            placeholders: ["text": .code],
            fixIts: [
                FixItSpec("replaceWith"),
            ]
        ),
        DiagnosticSpec(
            id: .variableFromData, severity: .info,
            escalation: Escalation(severity: .warning, when: LocalizedText("when it is never assigned", "从不赋值时")),
            trigger: #"`variable used = memory.used`"#,
            template: LocalizedText(
                #"`{name}` keeps the value from when the widget opened; to follow `{source}`, write `computed {name} = {source}`."#,
                #"`{name}` 只记住组件打开时的值；想让它跟着 `{source}` 变，写成 `computed {name} = {source}`。"#),
            placeholders: ["name": .code, "source": .code],
            fixIts: [
                FixItSpec("changeTo", arguments: ["text": #"computed"#]),
            ]
        ),
        DiagnosticSpec(
            id: .jsonTypeUnclear, severity: .error,
            trigger: #"`.font(web.json(u).size)`"#,
            template: LocalizedText(
                #"Desk can't tell whether this web value is a number or text here; add `.asNumber()` or `.asText()`."#,
                #"看不出这个网上的值在这里是数字还是文字；请加上 `.asNumber()` 或 `.asText()`。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("append", arguments: ["text": #".asNumber()"#]),
                FixItSpec("append", arguments: ["text": #".asText()"#]),
            ]
        ),
        DiagnosticSpec(
            id: .monthInTimePattern, severity: .warning,
            trigger: #"`format: "HH:MM"`"#,
            template: LocalizedText(
                #"`MM` is the month; minutes are `mm`. You can also use `.time`."#,
                #"`MM` 表示月份，分钟要写 `mm`。也可以直接用 `.time`。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("replaceWith", arguments: ["text": #"mm"#]),
            ]
        ),
    ]

    /// DK5xxx — modifiers, styles, elements.
    static let modifiersDiagnostics: [DiagnosticSpec] = [
        DiagnosticSpec(
            id: .duplicateModifier, severity: .error,
            trigger: #"`.color(.red).color(.blue)`"#,
            template: LocalizedText(
                #"`.{name}` is written twice; keep one. To change it when something is true, write `.{name}(…, if: …)`."#,
                #"`.{name}` 写了两次，只能留一个。想按条件变化，写 `.{name}(…, if: …)`。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("removeThisOne"),
            ]
        ),
        DiagnosticSpec(
            id: .duplicateFacet, severity: .error,
            trigger: #"`.size(28, 24).width(30)`"#,
            template: LocalizedText(
                #"{facet} is set twice, by `.{a}` and `.{b}`; keep one."#,
                #"{facet}被 `.{a}` 和 `.{b}` 设了两次，只能留一个。"#),
            placeholders: ["facet": .displayName, "a": .code, "b": .code],
            fixIts: [
                FixItSpec("removeOne"),
            ]
        ),
        DiagnosticSpec(
            id: .notApplicable, severity: .error,
            trigger: #"`Progress(cpu.usage).font(.caption)`"#,
            template: LocalizedText(
                #"`.{name}` doesn't apply to {component}. {hint}"#,
                #"`.{name}` 不能用在{component}上。{hint}"#),
            placeholders: ["name": .code, "component": .displayName, "hint": .text],
            fixIts: [
                FixItSpec("replace", offeredWhen: LocalizedText(#"When another modifier does it (`.tint` → `.color` on an Icon)"#, #"有对应的修饰符时（Icon 上 `.tint` → `.color`）"#)),
            ]
        ),
        DiagnosticSpec(
            id: .conditionNotAllowed, severity: .error,
            trigger: #"`.onClick(if: a) { … }`"#,
            template: LocalizedText(
                #"`.{name}` can't take `if:`; put the condition inside: `if … { … }`."#,
                #"`.{name}` 不能加 `if:`；把条件写进 `{ }` 里：`if … { … }`。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .styleHasNoEffect, severity: .warning,
            trigger: #"a text-only style on a `Rectangle`"#,
            template: LocalizedText(
                #"Style `{style}` has nothing that applies to {component}."#,
                #"样式 `{style}` 里没有能用在{component}上的修饰符。"#),
            placeholders: ["style": .code, "component": .displayName]
        ),
        DiagnosticSpec(
            id: .styleCycle, severity: .error,
            trigger: #"`style a { .style(b) }` / `style b { .style(a) }`"#,
            template: LocalizedText(
                #"These styles use each other: {cycle}."#,
                #"这些样式互相引用：{cycle}。"#),
            placeholders: ["cycle": .list]
        ),
        DiagnosticSpec(
            id: .styleUsesVariable, severity: .error,
            trigger: #"`style s { .hidden(if: page > 0) }`"#,
            template: LocalizedText(
                #"Styles can use options and data, not `{name}`. Put the condition where the style is used: `{fixed}`."#,
                #"样式里只能用选项和数据，不能用 `{name}`。把条件写在使用样式的地方：`{fixed}`。"#),
            placeholders: ["name": .code, "fixed": .code],
            fixIts: [
                FixItSpec("moveConditionToStyle"),
            ]
        ),
        DiagnosticSpec(
            id: .notAllowedInStyle, severity: .error,
            trigger: #"`style s { .onClick { … } }`"#,
            template: LocalizedText(
                #"`.{name}` can't be in a style; write it on the element."#,
                #"`.{name}` 不能写在样式里，请写在元素上。"#),
            placeholders: ["name": .code]
        ),
        DiagnosticSpec(
            id: .notAllowedInState, severity: .error,
            trigger: #"`.hover { .onClick { … } }`, `.hover { .hidden(if: false) }`"#,
            template: LocalizedText(
                #"`.{name}` can't be inside `.{state} { }`. {hint}"#,
                #"`.{name}` 不能写在 `.{state} { }` 里面。{hint}"#),
            placeholders: ["name": .code, "state": .code, "hint": .text],
            hints: [
                HintSpec(key: "forHidden", text: LocalizedText(#"To show something only while the pointer is over it, write `.opacity(0%).hover { .opacity(100%) }`, or `.onMouseEnter { show(x) }` with `.onMouseLeave { hide(x) }`."#, #"想在鼠标移上来时才显示，写 `.opacity(0%).hover { .opacity(100%) }`，或者用 `.onMouseEnter { show(x) }` 加 `.onMouseLeave { hide(x) }`。"#)),
                HintSpec(key: "nestedState", text: LocalizedText(#"A style with `.hover` or `.pressed` can't be used inside another state."#, #"带 `.hover` 或 `.pressed` 的样式不能用在另一个状态里面。"#)),
            ],
            fixIts: [
                FixItSpec("rewrite", offeredWhen: LocalizedText(#"For `.hidden`, with `.opacity`"#, #"对 `.hidden`，改用 `.opacity`"#)),
            ]
        ),
        DiagnosticSpec(
            id: .childNotAllowed, severity: .error,
            trigger: #"`Item("A")` in a `Column`; `Text` in a `.menu`"#,
            template: LocalizedText(
                #"{parent} can't contain {child}."#,
                #"{parent}里不能放{child}。"#),
            placeholders: ["parent": .displayName, "child": .displayName]
        ),
        DiagnosticSpec(
            id: .spacerOutsideStack, severity: .warning,
            trigger: #"`Freeform { Spacer() }`"#,
            template: LocalizedText(
                #"`Spacer()` only makes room in a Row, Column or Grid."#,
                #"Spacer() 只在 Row、Column、Grid 里起作用。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("remove"),
            ]
        ),
        DiagnosticSpec(
            id: .alignOnContainer, severity: .info,
            trigger: #"`Column { … }.align(.left)`"#,
            template: LocalizedText(
                #"`.align()` lines up the text inside each element; to line up the elements, write `{container}(align: .{value})`."#,
                #"`.align()` 调的是每个元素里文字的对齐；要让这些元素对齐，写 `{container}(align: .{value})`。"#),
            placeholders: ["container": .code, "value": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .buttonWithoutAction, severity: .warning,
            trigger: #"`Button("Next")`"#,
            template: LocalizedText(
                #"This button does nothing yet: add `.onClick { … }`."#,
                #"这个按钮还没有动作：加上 `.onClick { … }`。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #".onClick { }"#]),
            ]
        ),
        DiagnosticSpec(
            id: .rootSizeIgnored, severity: .warning,
            trigger: #"`.size(200, 100)` on the root of a `.small` widget"#,
            template: LocalizedText(
                #"The widget's size comes from `info { size: .{preset} }`; `.{name}` on the outermost element is ignored."#,
                #"组件的尺寸由 `info { size: .{preset} }` 决定；最外层元素上的 `.{name}` 不起作用。"#),
            placeholders: ["preset": .code, "name": .code],
            fixIts: [
                FixItSpec("remove"),
            ]
        ),
        DiagnosticSpec(
            id: .compatibilityOnly, severity: .error,
            trigger: #"`.rainmeter("X", "1")` in a hand-written widget"#,
            template: LocalizedText(
                #"`.rainmeter(…)` only works in widgets converted from Rainmeter."#,
                #"`.rainmeter(…)` 只能用在从 Rainmeter 转换来的组件里。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .unknownRainmeterOption, severity: .warning,
            trigger: #"`.rainmeter("FontColr", "…")`"#,
            template: LocalizedText(
                #"Deskset knows no Rainmeter option `{name}`."#,
                #"Deskset 不认识 Rainmeter 选项 `{name}`。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("didYouMean", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .menuHiddenByRightClick, severity: .warning,
            trigger: #"`.onRightClick { … }` with `.menu { … }`"#,
            template: LocalizedText(
                #"`.onRightClick` replaces the menu, so these menu items never show."#,
                #".onRightClick 会代替右键菜单，这些菜单项不会出现。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .controlInWrongPlace, severity: .error,
            trigger: #"`Toggle("Show seconds")` among the elements; `Picker(…)` as an element"#,
            template: LocalizedText(
                #"In the widget a control changes a value: `{widgetForm}`. To add a setting, declare it in `options { }`: `{optionForm}`."#,
                #"在组件里，控件用来改一个值：`{widgetForm}`。想加一个设置项，请在 `options { }` 里声明：`{optionForm}`。"#),
            placeholders: ["widgetForm": .code, "optionForm": .code],
            fixIts: [
                FixItSpec("moveInto", arguments: ["text": #"options"#]),
                FixItSpec("addBinding"),
            ]
        ),
        DiagnosticSpec(
            id: .combinedStyles, severity: .error,
            trigger: #"`.style(dateCell | todayCell)`, `.style(dateCell, todayCell)`"#,
            template: LocalizedText(
                #"Apply one style per `.style`; later ones win: `{fixed}`."#,
                #"每个 `.style` 只套一个样式，后写的优先：`{fixed}`。"#),
            placeholders: ["fixed": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .backgroundOnShape, severity: .warning,
            trigger: #"`Circle().background(.red)`"#,
            template: LocalizedText(
                #"`.background` paints the square box behind this shape; shapes are painted with `.fill(…)`."#,
                #"`.background` 画的是这个形状后面的方框；形状要用 `.fill(…)` 上色。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("replaceWith", arguments: ["text": #".fill"#]),
            ]
        ),
        DiagnosticSpec(
            id: .rootTakesOverPointer, severity: .warning,
            trigger: #"`.onRightClick { … }` or `.onDrag { … }` on the root"#,
            template: LocalizedText(
                #"People can no longer {what} this widget ({reason}); put it on a smaller element, or use `.menu { }`."#,
                #"用户没法再{what}这个组件（{reason}）；请把它放到更小的元素上，或者改用 `.menu { }`。"#),
            placeholders: ["what": .text, "reason": .text],
            hints: [
                HintSpec(key: "rightClickWhat", placeholder: "what", text: LocalizedText(#"right-click"#, #"右键点按"#)),
                HintSpec(key: "rightClickReason", placeholder: "reason", text: LocalizedText(#"for Options, Edit or Remove"#, #"打开选项、编辑或移除"#)),
                HintSpec(key: "dragWhat", placeholder: "what", text: LocalizedText(#"drag"#, #"拖动"#)),
                HintSpec(key: "dragReason", placeholder: "reason", text: LocalizedText(#"to move it"#, #"来移动它"#)),
            ]
        ),
        DiagnosticSpec(
            id: .textBoxSize, severity: .info,
            trigger: #"`Text("A").size(13)` with no `.font` in the same source"#,
            template: LocalizedText(
                #"`.size` sets the box, not the letters; for the letters write `.font({number})`."#,
                #"`.size` 设的是框的大小，不是字的大小；字号要写 `.font({number})`。"#),
            placeholders: ["number": .code],
            fixIts: [
                FixItSpec("replaceWith"),
            ]
        ),
        DiagnosticSpec(
            id: .rainmeterDetailNotKept, severity: .warning,
            trigger: #"`.rainmeter("BarBorder", "2")`"#,
            template: LocalizedText(
                #"Desk widgets can't keep the Rainmeter option `{name}`; it is ignored."#,
                #"Desk 组件保留不了 Rainmeter 选项 `{name}`，它会被忽略。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("remove"),
            ]
        ),
    ]

    /// DK6xxx — layout and references.
    static let layoutDiagnostics: [DiagnosticSpec] = [
        DiagnosticSpec(
            id: .positionOutsideFreeform, severity: .error,
            trigger: #"`.position(x: 10)` in a Column"#,
            template: LocalizedText(
                #"`.position()` works only inside a `Freeform`; in {container}, use `.offset()` or `.margin()`."#,
                #".position() 只能用在自由容器 Freeform 里；在{container}里用 .offset() 或 .margin()。"#),
            placeholders: ["container": .displayName],
            fixIts: [
                FixItSpec("useText", arguments: ["text": #".offset()"#]),
                FixItSpec("wrapIn", arguments: ["text": #"Freeform { }"#]),
            ]
        ),
        DiagnosticSpec(
            id: .referenceNotSibling, severity: .error,
            trigger: #"`.position(x: title.right)`, `title` in another container"#,
            template: LocalizedText(
                #"You can only refer to elements in the same Freeform: `{name}` is in another container."#,
                #"只能引用同一个自由容器里的元素：`{name}` 在另一个容器里。"#),
            placeholders: ["name": .code]
        ),
        DiagnosticSpec(
            id: .referenceIntoIfOrFor, severity: .error,
            trigger: #"referring to a named element inside `if`"#,
            template: LocalizedText(
                #"`{name}` is inside `{construct}`, so it can't be referred to."#,
                #"`{name}` 在 `{construct}` 里面，不能被引用。"#),
            placeholders: ["name": .code, "construct": .code]
        ),
        DiagnosticSpec(
            id: .referenceCycle, severity: .error,
            trigger: #"two elements positioned by each other"#,
            template: LocalizedText(
                #"These positions depend on each other: {cycle}."#,
                #"这些位置互相依赖：{cycle}。"#),
            placeholders: ["cycle": .list]
        ),
        DiagnosticSpec(
            id: .referenceNotAllowedHere, severity: .error,
            trigger: #"`.opacity(title.width / 100)`"#,
            template: LocalizedText(
                #"Other elements' edges can be used only in `.position`, `.width`, `.height` and `.size`."#,
                #"其他元素的边只能用在 .position、.width、.height、.size 里。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .nameInFor, severity: .error,
            trigger: #"`.name(cell)` inside `for`"#,
            template: LocalizedText(
                #"Elements made by `for` can't have names."#,
                #"for 生成的元素不能起名字。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("remove"),
            ]
        ),
        DiagnosticSpec(
            id: .duplicateElementName, severity: .error,
            trigger: #"two `.name(title)`"#,
            template: LocalizedText(
                #"Two elements are named `{name}`."#,
                #"有两个元素都叫 `{name}`。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("renameThisOne"),
            ]
        ),
        DiagnosticSpec(
            id: .nameNotReferable, severity: .warning,
            trigger: #"`.name("my title")` then `.position(x: …)`"#,
            template: LocalizedText(
                #""{name}" works with `show`/`hide`, but positions can only use names made of letters and digits."#,
                #""{name}" 能用于 show/hide，但定位里只能引用由字母和数字组成的名字。"#),
            placeholders: ["name": .plain],
            fixIts: [
                FixItSpec("rename"),
            ]
        ),
        DiagnosticSpec(
            id: .marginWithPosition, severity: .warning,
            trigger: #"`.position(x: 4).margin(8)`"#,
            template: LocalizedText(
                #"`.margin()` has no effect on an element placed with `.position()`; change x and y instead."#,
                #"用 .position() 摆放的元素，.margin() 不起作用；请改 x 和 y。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("remove"),
            ]
        ),
        DiagnosticSpec(
            id: .widgetSizeInFitWidget, severity: .error,
            trigger: #"`.width(widget.size.width / 2)` with `size: .fit`"#,
            template: LocalizedText(
                #"`widget.size` can't be used for the layout of a widget whose size follows its content."#,
                #"尺寸跟随内容（size: .fit）的组件，排版里不能用 widget.size。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .alignOnPositionedText, severity: .warning,
            trigger: #"`Text("{cpu.usage}%").position(x: 160, y: 10).align(.right)`"#,
            template: LocalizedText(
                #"`.align` moves text inside its own box; to put the {edge} of the text at x, write `{fixed}`."#,
                #"`.align` 只在文字自己的框里挪动；想让文字的{edge}对准 x，写成 `{fixed}`。"#),
            placeholders: ["edge": .text, "fixed": .code],
            fixIts: [
                FixItSpec("useText"),
            ]
        ),
        DiagnosticSpec(
            id: .scrollGrowsWithContent, severity: .warning,
            trigger: #"`Scroll { … }` in a `.fit` widget with no height"#,
            template: LocalizedText(
                #"This Scroll grows with its content, so it never scrolls; give it `.height(200)` or use `size: .medium`."#,
                #"这个 Scroll 会跟着内容一起变长，永远不会滚动；给它加 `.height(200)`，或者改用 `size: .medium`。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #".height(200)"#]),
            ]
        ),
        DiagnosticSpec(
            id: .contentTooLarge, severity: .warning,
            trigger: #"the layout pass finds overflow"#,
            template: LocalizedText(
                #"The content is about {amount} pt {direction} than {preset}: use `size: .{bigger}`, or make the content smaller."#,
                #"内容比{preset}{direction}了约 {amount} 点：换成 `size: .{bigger}`，或者把内容调小。"#),
            placeholders: ["amount": .number, "direction": .text, "preset": .displayName, "bigger": .code],
            hints: [
                HintSpec(key: "taller", placeholder: "direction", text: LocalizedText(#"taller"#, #"高"#)),
                HintSpec(key: "wider", placeholder: "direction", text: LocalizedText(#"wider"#, #"宽"#)),
            ],
            fixIts: [
                FixItSpec("useText"),
            ]
        ),
    ]

    /// DK7xxx — actions, events, timing.
    static let actionsDiagnostics: [DiagnosticSpec] = [
        DiagnosticSpec(
            id: .assignmentOutsideEvent, severity: .error,
            trigger: #"`page = 1` directly in a Row"#,
            template: LocalizedText(
                #"Values change in events: put `{text}` inside `.onClick { … }` or another event."#,
                #"改值要写在事件里：把 `{text}` 放进 `.onClick { … }` 这类事件。"#),
            placeholders: ["text": .code]
        ),
        DiagnosticSpec(
            id: .actionOutsideEvent, severity: .error,
            trigger: #"`open("Calendar")` in a Column"#,
            template: LocalizedText(
                #"`{name}(…)` does something, so it goes inside an event such as `.onClick { … }`."#,
                #"`{name}(…)` 是动作，要写在 `.onClick { … }` 这类事件里。"#),
            placeholders: ["name": .code]
        ),
        DiagnosticSpec(
            id: .viewInAction, severity: .error,
            trigger: #"`Text("A")` in `.onClick`"#,
            template: LocalizedText(
                #"Elements can't be made inside an event; use a variable and `if`."#,
                #"事件里不能创建元素；用一个变量加 if。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .compoundAssignment, severity: .error,
            trigger: #"`page += 1`"#,
            template: LocalizedText(
                #"Write `{name} = {name} {op} {value}`."#,
                #"写成 `{name} = {name} {op} {value}`。"#),
            placeholders: ["name": .code, "op": .code, "value": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .incrementOperator, severity: .error,
            trigger: #"`page++`"#,
            template: LocalizedText(
                #"Write `{name} = {name} {op} 1`."#,
                #"写成 `{name} = {name} {op} 1`。"#),
            placeholders: ["name": .code, "op": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .userActionOnly, severity: .error,
            trigger: #"`open(…)` in `.every`"#,
            template: LocalizedText(
                #"`{name}` must come from a click or a menu item, not from `{event}`."#,
                #"`{name}` 只能由点击或菜单项触发，不能放在 `{event}` 里。"#),
            placeholders: ["name": .code, "event": .code]
        ),
        DiagnosticSpec(
            id: .everyTooFast, severity: .error,
            trigger: #"`.every(5ms)`"#,
            template: LocalizedText(
                #"`.every` runs at most every 16ms."#,
                #".every 最短 16ms。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("replaceWith", arguments: ["text": #"16ms"#]),
            ]
        ),
        DiagnosticSpec(
            id: .everyVeryOften, severity: .info,
            trigger: #"`.every(100ms)`"#,
            template: LocalizedText(
                #"`.every({interval})` runs very often and costs battery; 250ms or more is usually enough."#,
                #"`.every({interval})` 太频繁，费电；一般 250ms 以上就够了。"#),
            placeholders: ["interval": .code]
        ),
        DiagnosticSpec(
            id: .afterOutOfRange, severity: .error,
            trigger: #"`after(2d) { … }`"#,
            template: LocalizedText(
                #"`after` waits between 0 and 24 hours."#,
                #"after 的等待时间要在 0 到 24 小时之间。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .valueAsAction, severity: .error,
            trigger: #"`.onClick { cpu.usage }`, `.onClick { command("say hi") }`"#,
            template: LocalizedText(
                #"`{text}` is a value, not an action. {hint}"#,
                #"`{text}` 是一个值，不是动作。{hint}"#),
            placeholders: ["text": .code, "hint": .text, "fixed": .code],
            hints: [
                HintSpec(key: "actionTwin", text: LocalizedText(#"To do it, write `{fixed}`."#, #"要执行它，写成 `{fixed}`。"#)),
            ],
            fixIts: [
                FixItSpec("replaceWith", offeredWhen: LocalizedText(#"When there is an action twin (`command(…)` → `run(…)`)"#, #"有对应的动作时（`command(…)` → `run(…)`）"#)),
            ]
        ),
        DiagnosticSpec(
            id: .whenRarelyChanges, severity: .warning,
            trigger: #"`.when(options.showSeconds) { … }`"#,
            template: LocalizedText(
                #"This condition changes only when the options change (or never), so `.when` rarely runs."#,
                #"这个条件只在选项改变时才会变（或者从不变），.when 很少会执行。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .refreshTooFast, severity: .error,
            trigger: #"`web.json(url, every: 10s)`"#,
            template: LocalizedText(
                #"`every:` for {source} must be at least {min}."#,
                #"{source} 的 every 最短是 {min}。"#),
            placeholders: ["source": .code, "min": .code],
            fixIts: [
                FixItSpec("replaceWith"),
            ]
        ),
        DiagnosticSpec(
            id: .refreshOutOfRange, severity: .error,
            trigger: #"`info { refresh: 100ms }`"#,
            template: LocalizedText(
                #"`refresh` must be between 250ms and 1h."#,
                #"refresh 要在 250ms 到 1h 之间。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("clamp"),
            ]
        ),
        DiagnosticSpec(
            id: .looksInEvent, severity: .error,
            trigger: #"`.onClick { .color(.red) }`; `page = 1`↵`.color(.red)` in an action block"#,
            template: LocalizedText(
                #"Looks can't be set inside an event. Keep a yes/no variable and use `if:` on the element — `.{name}(…, if: {variable})` — then set `{variable} = true` here."#,
                #"事件里不能改外观。用一个是/否变量，在元素上写 `if:`——`.{name}(…, if: {variable})`——然后在这里写 `{variable} = true`。"#),
            placeholders: ["name": .code, "variable": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
    ]

    /// DK8xxx — info, options, translations, security, versions, limits.
    static let infoAndSecurityDiagnostics: [DiagnosticSpec] = [
        DiagnosticSpec(
            id: .unknownField, severity: .error,
            trigger: #"`info { titel: "CPU" }`"#,
            template: LocalizedText(
                #"`{block}` has no `{name}`. Fields: {list}."#,
                #"{block} 里没有 `{name}`。可用：{list}。"#),
            placeholders: ["block": .code, "name": .code, "list": .list],
            fixIts: [
                FixItSpec("didYouMean", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .duplicateField, severity: .error,
            trigger: #"`name:` twice"#,
            template: LocalizedText(
                #"`{name}` is given twice."#,
                #"`{name}` 写了两次。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("removeOne"),
            ]
        ),
        DiagnosticSpec(
            id: .missingName, severity: .info,
            trigger: #"no `info.name`"#,
            template: LocalizedText(
                #"Give the widget a name: `info { name: "…" }`."#,
                #"给组件起个名字：`info { name: "…" }`。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #"name: "…""#]),
            ]
        ),
        DiagnosticSpec(
            id: .unknownControl, severity: .error,
            trigger: #"`weekStart = Dropdown(…)`"#,
            template: LocalizedText(
                #"`{name}` isn't an option control. Controls: {list}."#,
                #"`{name}` 不是选项控件。可用：{list}。"#),
            placeholders: ["name": .code, "list": .list],
            fixIts: [
                FixItSpec("didYouMean", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .optionLabelMissing, severity: .error,
            trigger: #"`Toggle(default: true)`"#,
            template: LocalizedText(
                #"Every option needs a label people understand: `{control}("…")`."#,
                #"每个选项都要有一句用户看得懂的说明：`{control}("…")`。"#),
            placeholders: ["control": .code],
            fixIts: [
                FixItSpec("insert", arguments: ["text": #""""#]),
            ]
        ),
        DiagnosticSpec(
            id: .optionDefaultMismatch, severity: .error,
            trigger: #"`Toggle("A", default: 1)`"#,
            template: LocalizedText(
                #"The default of `{name}` must be {expected}."#,
                #"`{name}` 的默认值要是{expected}。"#),
            placeholders: ["name": .code, "expected": .displayName]
        ),
        DiagnosticSpec(
            id: .pickerChoicesMixed, severity: .error,
            trigger: #"`Picker("A", [.sunday, "Mon"])`"#,
            template: LocalizedText(
                #"A Picker's choices must all be the same kind of value."#,
                #"Picker 的选项要是同一种值。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .pickerDefaultNotAChoice, severity: .error,
            trigger: #"`default: .friday` for `[.sunday, .monday]`"#,
            template: LocalizedText(
                #"The default `{value}` isn't one of the choices."#,
                #"默认值 `{value}` 不在可选项里。"#),
            placeholders: ["value": .code],
            fixIts: [
                FixItSpec("useFirstChoice"),
            ]
        ),
        DiagnosticSpec(
            id: .optionConditionNotOption, severity: .error,
            trigger: #"`seconds = Toggle("Seconds").hidden(if: cpu.usage > 5)` in `options`"#,
            template: LocalizedText(
                #"On an option, `.hidden(if:)` can only use other options."#,
                #"选项上的 `.hidden(if:)` 只能用其他选项。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .duplicateOption, severity: .error,
            trigger: #"two options named `accent`"#,
            template: LocalizedText(
                #"Option `{name}` is declared twice."#,
                #"选项 `{name}` 声明了两次。"#),
            placeholders: ["name": .code]
        ),
        DiagnosticSpec(
            id: .tooManyOptions, severity: .error,
            trigger: #"101 options"#,
            template: LocalizedText(
                #"A widget can have at most {limit} options."#,
                #"一个组件最多 {limit} 个选项。"#),
            placeholders: ["limit": .number]
        ),
        DiagnosticSpec(
            id: .optionWithoutName, severity: .error,
            trigger: #"`options { Toggle("Show seconds") }`"#,
            template: LocalizedText(
                #"Give the option a name, so the widget can read it: `{fixed}`."#,
                #"给选项起个名字，组件才能读到它：`{fixed}`。"#),
            placeholders: ["fixed": .code],
            fixIts: [
                FixItSpec("insertName"),
            ]
        ),
        DiagnosticSpec(
            id: .missingPermission, severity: .error,
            trigger: #"`music.title` without `.music`"#,
            template: LocalizedText(
                #"This widget {needs}, so it needs `permissions: [.{permission}]` in `info`."#,
                #"这个组件要{needs}，需要在 `info` 里加上 `permissions: [.{permission}]`。"#),
            placeholders: ["needs": .text, "permission": .code],
            fixIts: [
                FixItSpec("add"),
            ]
        ),
        DiagnosticSpec(
            id: .unusedPermission, severity: .warning,
            trigger: #"`.calendar` declared, never used"#,
            template: LocalizedText(
                #"`.{permission}` is asked for but not used; people will still be asked to allow it."#,
                #"声明了 `.{permission}` 却没有用到；用户仍会被询问是否允许。"#),
            placeholders: ["permission": .code],
            fixIts: [
                FixItSpec("remove"),
            ]
        ),
        DiagnosticSpec(
            id: .hostNotDeclared, severity: .error,
            trigger: #"`web.json("https://api.x.com/…")` without `network`"#,
            template: LocalizedText(
                #"`{host}` isn't in `info { network: […] }`."#,
                #"`{host}` 不在 info 的 network 列表里。"#),
            placeholders: ["host": .code],
            fixIts: [
                FixItSpec("add"),
            ]
        ),
        DiagnosticSpec(
            id: .unusedHost, severity: .warning,
            trigger: #"a host never used"#,
            template: LocalizedText(
                #"`{host}` is listed in `network` but not used."#,
                #"network 里列了 `{host}`，但没有用到。"#),
            placeholders: ["host": .code],
            fixIts: [
                FixItSpec("remove"),
            ]
        ),
        DiagnosticSpec(
            id: .insecureHttp, severity: .warning,
            trigger: #"`http://…`"#,
            template: LocalizedText(
                #"`http://` is not encrypted; use `https://` if the site supports it."#,
                #"http:// 不加密；网站支持的话请用 https://。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("replaceWith", arguments: ["text": #"https://"#]),
            ]
        ),
        DiagnosticSpec(
            id: .invalidHost, severity: .error,
            trigger: #"`network: ["https://x.com/api"]`"#,
            template: LocalizedText(
                #"Write host names only, like `"api.example.com"` or `"*.example.com"`."#,
                #"只写域名，比如 `"api.example.com"` 或 `"*.example.com"`。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("replaceWithHost"),
            ]
        ),
        DiagnosticSpec(
            id: .liveDataInWebAddress, severity: .error,
            trigger: #"`web.json("https://x.com/?q={music.title}")`"#,
            template: LocalizedText(
                #"Background web addresses can't contain live data, so your information isn't sent anywhere; write the address out, or take it from an option."#,
                #"后台联网的地址里不能放实时数据，免得把你的信息发出去；地址要写死，或者来自选项。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .liveDataInCommand, severity: .error,
            trigger: #"`command("say {music.title}")`"#,
            template: LocalizedText(
                #"Commands can't contain live data or variables; write the command out, or take it from an option."#,
                #"命令里不能放实时数据或变量；命令要写死，或者来自选项。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .liveFolder, severity: .error,
            trigger: #"`files("{music.album}")`"#,
            template: LocalizedText(
                #"Folders read in the background must be written out or chosen in the options."#,
                #"后台读取的文件夹要写死，或者在选项里选。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .variableInWebAddress, severity: .error,
            trigger: #"`web.json("https://x.com/?p={page}")`"#,
            template: LocalizedText(
                #"Background web addresses can't contain variables either; use an option."#,
                #"后台联网的地址里也不能放变量；请用选项。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .userOnlyOption, severity: .error,
            trigger: #"`.onClick { options.folder = "/tmp" }`; `Input(options.script)` for a whole-command option"#,
            template: LocalizedText(
                #"`{name}` can only be chosen by the user in the Options panel."#,
                #"`{name}` 只能由用户在选项面板里选择。"#),
            placeholders: ["name": .code]
        ),
        DiagnosticSpec(
            id: .directionMarkInCommand, severity: .error,
            trigger: #"a right-to-left mark in `run("…")`"#,
            template: LocalizedText(
                #"This {what} contains an invisible direction mark; what runs could differ from what is shown."#,
                #"这个{what}里有看不见的方向控制符，实际执行的内容可能和显示的不一样。"#),
            placeholders: ["what": .displayName],
            fixIts: [
                FixItSpec("remove"),
            ]
        ),
        DiagnosticSpec(
            id: .placeholderInSingleQuotes, severity: .error,
            trigger: #"`run("open '{options.target}'")`"#,
            template: LocalizedText(
                #"Inside `'…'` the shell takes `{text}` literally, so the value would never arrive. End the quotes around it: `{fixed}` — the value always arrives as one piece."#,
                #"在 `'…'` 里，shell 会把 `{text}` 原样当成文字，值根本传不进去。把引号在它两边断开：`{fixed}`——值总是作为一个整体传入。"#),
            placeholders: ["text": .code, "fixed": .code],
            fixIts: [
                FixItSpec("closeQuotes"),
            ]
        ),
        DiagnosticSpec(
            id: .commandRereadsValue, severity: .error,
            trigger: #"`run("eval {options.snippet}")`, `run("sh -c \"say {options.phrase}\"")`"#,
            template: LocalizedText(
                #"`{command}` runs its text as code, so `{text}` could run other commands. Pass the value as an argument after the code instead: `{fixed}`."#,
                #"`{command}` 会把它后面的文字当代码执行，`{text}` 可能会被当成别的命令运行。请把值放在代码后面、作为参数传入：`{fixed}`。"#),
            placeholders: ["command": .code, "text": .code, "fixed": .code]
        ),
        DiagnosticSpec(
            id: .deskVersionTooNew, severity: .error,
            trigger: #"`deskVersion: 2`"#,
            template: LocalizedText(
                #"This widget uses Desk version {version}; this Deskset understands up to version {max}. Update Deskset."#,
                #"这个组件用的是 Desk 第 {version} 版，这个 Deskset 最高支持第 {max} 版。请更新 Deskset。"#),
            placeholders: ["version": .plain, "max": .plain]
        ),
        DiagnosticSpec(
            id: .needsNewerApp, severity: .error,
            trigger: #"a catalog item whose `since` is later than `CheckContext.targetAppVersion` (checking for an older Deskset, §8.5)"#,
            template: LocalizedText(
                #"`{name}` needs Deskset {version} or later; this widget is being checked for Deskset {target}."#,
                #"`{name}` 需要 Deskset {version} 或更新的版本；现在是按 Deskset {target} 检查的。"#),
            placeholders: ["name": .code, "version": .plain, "target": .plain]
        ),
        DiagnosticSpec(
            id: .deprecated, severity: .warning,
            trigger: #"a deprecated name"#,
            template: LocalizedText(
                #"`{name}` is replaced by `{replacement}`."#,
                #"`{name}` 已由 `{replacement}` 取代。"#),
            placeholders: ["name": .code, "replacement": .code],
            fixIts: [
                FixItSpec("replace"),
            ]
        ),
        DiagnosticSpec(
            id: .unknownFeature, severity: .error,
            trigger: #"`supports(.glassy)`"#,
            template: LocalizedText(
                #"`supports()` knows: {list}."#,
                #"supports() 可以检查：{list}。"#),
            placeholders: ["list": .list],
            fixIts: [
                FixItSpec("didYouMean", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .unknownLanguage, severity: .warning,
            trigger: #"`"zh-CN-Hanz" { … }`"#,
            template: LocalizedText(
                #""{tag}" isn't a language Deskset knows (for example "zh-Hans", "ja", "de")."#,
                #"Deskset 不认识语言 "{tag}"（例如 "zh-Hans"、"ja"、"de"）。"#),
            placeholders: ["tag": .plain],
            fixIts: [
                FixItSpec("didYouMean", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .translationDataMismatch, severity: .error,
            trigger: #"`"{cpu.usage}% used": "已用"`"#,
            template: LocalizedText(
                #"The translation must contain the same data as the original: {missing}."#,
                #"翻译里要有和原文相同的数据：{missing}。"#),
            placeholders: ["missing": .list]
        ),
        DiagnosticSpec(
            id: .unusedTranslation, severity: .warning,
            trigger: #"a key no text uses"#,
            template: LocalizedText(
                #"No text in this widget is "{key}"."#,
                #"组件里没有 "{key}" 这段文字。"#),
            placeholders: ["key": .plain],
            fixIts: [
                FixItSpec("didYouMean", offeredWhen: LocalizedText(#"When one close name fits"#, #"只有一个相近的名字符合时"#)),
                FixItSpec("remove"),
            ]
        ),
        DiagnosticSpec(
            id: .duplicateTranslation, severity: .error,
            trigger: #"the same key twice"#,
            template: LocalizedText(
                #""{key}" is translated twice for {language}."#,
                #""{key}" 的 {language} 翻译写了两次。"#),
            placeholders: ["key": .plain, "language": .text],
            fixIts: [
                FixItSpec("removeOne"),
            ]
        ),
        DiagnosticSpec(
            id: .duplicateLanguage, severity: .error,
            trigger: #"two `"zh-Hans"` blocks, or `"zh-CN"` and `"zh-Hans"`"#,
            template: LocalizedText(
                #"The language "{tag}" appears twice."#,
                #"语言 "{tag}" 出现了两次。"#),
            placeholders: ["tag": .plain]
        ),
        DiagnosticSpec(
            id: .regionLanguageTag, severity: .info,
            trigger: #"`"zh-CN" { … }`, `"zh_TW" { … }`"#,
            template: LocalizedText(
                #""{tag}" is used for {language} (Macs set to {macTag} use it); Desk writes it "{canonical}"."#,
                #""{tag}" 会用于{language}（系统设成 {macTag} 的 Mac 会用它）；Desk 里写成 "{canonical}"。"#),
            placeholders: ["tag": .plain, "language": .text, "macTag": .plain, "canonical": .plain],
            fixIts: [
                FixItSpec("replaceWith"),
            ]
        ),
        DiagnosticSpec(
            id: .tooManyElements, severity: .error,
            trigger: #"`for` loops producing > 5,000 elements"#,
            template: LocalizedText(
                #"This widget could make {count} elements; the most is {limit}."#,
                #"这个组件可能生成 {count} 个元素，最多 {limit} 个。"#),
            placeholders: ["count": .number, "limit": .number]
        ),
        DiagnosticSpec(
            id: .forTooLong, severity: .warning,
            trigger: #"`for i in 1...2000`"#,
            template: LocalizedText(
                #"`for` shows at most 1,000 items; the rest are left out."#,
                #"for 最多生成 1000 项，多出来的不显示。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .fileTooLarge, severity: .error,
            trigger: #"a 2 MiB file"#,
            template: LocalizedText(
                #"This file is larger than 1 MiB."#,
                #"文件超过了 1 MiB。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .textTooLong, severity: .error,
            trigger: #"a 40,000-character string"#,
            template: LocalizedText(
                #"This text is longer than 32,768 characters."#,
                #"这段文字超过了 32768 个字符。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .forTooDeep, severity: .error,
            trigger: #"five nested `for`"#,
            template: LocalizedText(
                #"`for` can be nested at most 4 deep."#,
                #"for 最多嵌套 4 层。"#),
            placeholders: [:]
        ),
    ]

    /// DK9xxx — foreign syntax.
    static let foreignDiagnostics: [DiagnosticSpec] = [
        DiagnosticSpec(
            id: .symbolicAnd, severity: .error,
            trigger: #"`if a && b`"#,
            template: LocalizedText(
                #"Desk writes `and`: `{fixed}`."#,
                #"Desk 里写 `and`：`{fixed}`。"#),
            placeholders: ["fixed": .code],
            fixIts: [
                FixItSpec("replace"),
            ]
        ),
        DiagnosticSpec(
            id: .symbolicOr, severity: .error,
            trigger: #"`a || b`"#,
            template: LocalizedText(
                #"Desk writes `or`: `{fixed}`."#,
                #"Desk 里写 `or`：`{fixed}`。"#),
            placeholders: ["fixed": .code],
            fixIts: [
                FixItSpec("replace"),
            ]
        ),
        DiagnosticSpec(
            id: .symbolicNot, severity: .error,
            trigger: #"`!battery.charging`"#,
            template: LocalizedText(
                #"Desk writes `not`: `{fixed}`."#,
                #"Desk 里写 `not`：`{fixed}`。"#),
            placeholders: ["fixed": .code],
            fixIts: [
                FixItSpec("replace"),
            ]
        ),
        DiagnosticSpec(
            id: .nilCoalescing, severity: .error,
            trigger: #"`music.title ?? "–"`"#,
            template: LocalizedText(
                #"Desk writes `.ifMissing(…)`: `{fixed}`."#,
                #"Desk 里写 `.ifMissing(…)`：`{fixed}`。"#),
            placeholders: ["fixed": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .optionalChaining, severity: .error,
            trigger: #"`music?.title`"#,
            template: LocalizedText(
                #"`?.` isn't needed: values that are missing show as "–"."#,
                #"不需要 `?.`：取不到的值会显示“–”。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("replaceWith", arguments: ["text": #"."#]),
            ]
        ),
        DiagnosticSpec(
            id: .indexBrackets, severity: .error,
            trigger: #"`month.days[0]`"#,
            template: LocalizedText(
                #"Desk writes `.item({n})`; the first item is 1."#,
                #"Desk 里写 `.item({n})`，第一项是 1。"#),
            placeholders: ["n": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .powerOperator, severity: .error,
            trigger: #"`x ** 2`"#,
            template: LocalizedText(
                #"Write `math.power({a}, {b})`."#,
                #"写成 `math.power({a}, {b})`。"#),
            placeholders: ["a": .code, "b": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .bitOperator, severity: .error,
            trigger: #"`flags & 4`"#,
            template: LocalizedText(
                #"Write `math.{function}({a}, {b})`."#,
                #"写成 `math.{function}({a}, {b})`。"#),
            placeholders: ["function": .code, "a": .code, "b": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .halfOpenRange, severity: .error,
            trigger: #"`0..<32`"#,
            template: LocalizedText(
                #"Desk ranges include both ends: `{a}...{last}`."#,
                #"Desk 的范围包括两端：`{a}...{last}`。"#),
            placeholders: ["a": .code, "last": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .swiftInterpolation, severity: .error,
            trigger: #"`"\(cpu.usage)%"`"#,
            template: LocalizedText(
                #"Put data in text with braces: `"{fixed}"`."#,
                #"文字里放数据用花括号：`"{fixed}"`。"#),
            placeholders: ["fixed": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .doubleBraces, severity: .warning,
            trigger: #"`"{{ cpu.usage }}%"` — only when the braced text is known data (above)"#,
            template: LocalizedText(
                #"`{{` shows a brace, so this shows `{text}` as written; to put the data in, use single braces: `{fixed}`."#,
                #"`{{` 表示显示花括号，所以这里会原样显示 `{text}`；想放入数据，用一对花括号：`{fixed}`。"#),
            placeholders: ["text": .code, "fixed": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .functionSyntax, severity: .error,
            trigger: #"`x => x * 2`, `func f()`"#,
            template: LocalizedText(
                #"Desk has no functions; use `for`, `if` and `computed`."#,
                #"Desk 没有函数写法；用 for、if 和 computed。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .semicolonComment, severity: .warning,
            trigger: #"`; note` at a line start"#,
            template: LocalizedText(
                #"`;` comments are Rainmeter's; write `// {text}`."#,
                #"`;` 开头的注释是 Rainmeter 的写法；写成 `// {text}`。"#),
            placeholders: ["text": .code],
            fixIts: [
                FixItSpec("replace"),
            ]
        ),
        DiagnosticSpec(
            id: .hashComment, severity: .warning,
            trigger: #"`# note`"#,
            template: LocalizedText(
                #"Comments start with `//`."#,
                #"注释用 `//` 开头。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("replace"),
            ]
        ),
        DiagnosticSpec(
            id: .foreignFile, severity: .error,
            trigger: #"a 300-line pasted INI file, after its first 20 foreign lines"#,
            template: LocalizedText(
                #"This looks like a {language} file; Desk stopped listing its lines here. {hint}"#,
                #"这看起来是一个 {language} 文件，后面的行不再一一列出。{hint}"#),
            placeholders: ["language": .text, "hint": .text],
            hints: [
                HintSpec(key: "rainmeter", text: LocalizedText(#"Install it as a Rainmeter skin, or open it with the converter."#, #"请把它当作 Rainmeter 皮肤安装，或者用转换器打开。"#)),
                HintSpec(key: "other", text: LocalizedText(#"The language reference shows how Desk writes it."#, #"语言参考里有 Desk 的写法。"#)),
            ]
        ),
        DiagnosticSpec(
            id: .swiftUIComponent, severity: .error,
            trigger: #"`VStack { … }`"#,
            template: LocalizedText(
                #"This is SwiftUI; in Desk write `{desk}`."#,
                #"这是 SwiftUI 的写法；Desk 里写 `{desk}`。"#),
            placeholders: ["desk": .code],
            fixIts: [
                FixItSpec("replace"),
            ]
        ),
        DiagnosticSpec(
            id: .swiftUIModifier, severity: .error,
            trigger: #"`.foregroundColor(.red)`, `.resizable()`"#,
            template: LocalizedText(
                #"`.{name}` is SwiftUI; in Desk write `{desk}`."#,
                #"`.{name}` 是 SwiftUI 的写法；Desk 里写 `{desk}`。"#),
            placeholders: ["name": .code, "desk": .code],
            fixIts: [
                FixItSpec("replace"),
                FixItSpec("remove", offeredWhen: LocalizedText(#"For `.resizable()`"#, #"对 `.resizable()`"#)),
            ]
        ),
        DiagnosticSpec(
            id: .swiftPropertyWrapper, severity: .error,
            trigger: #"`@State var page = 0`"#,
            template: LocalizedText(
                #"`@{name}` is SwiftUI; in Desk write `{desk}`."#,
                #"`@{name}` 是 SwiftUI 的写法；Desk 里写 `{desk}`。"#),
            placeholders: ["name": .code, "desk": .code],
            fixIts: [
                FixItSpec("replace"),
            ]
        ),
        DiagnosticSpec(
            id: .swiftDeclaration, severity: .error,
            trigger: #"`let x = 1`, `var x = 0`, `state x = 0`"#,
            template: LocalizedText(
                #"`{keyword}` is not Desk; write `{desk}`."#,
                #"`{keyword}` 不是 Desk 的写法；写成 `{desk}`。"#),
            placeholders: ["keyword": .code, "desk": .code],
            fixIts: [
                FixItSpec("replace"),
            ]
        ),
        DiagnosticSpec(
            id: .swiftStructure, severity: .error,
            trigger: #"`struct CPU: View {`, `var body: some View`, `import SwiftUI`, `return`"#,
            template: LocalizedText(
                #"Desk has no `struct`, `body`, `import` or `return`; a widget is `widget { … }`."#,
                #"Desk 没有 struct、body、import、return；组件写成 `widget { … }`。"#),
            placeholders: [:],
            fixIts: [
                FixItSpec("remove", offeredWhen: LocalizedText(#"For `import`"#, #"对 `import`"#)),
            ]
        ),
        DiagnosticSpec(
            id: .swiftBinding, severity: .error,
            trigger: #"`Toggle("A", isOn: $on)`"#,
            template: LocalizedText(
                #"Pass the variable itself: `{name}`."#,
                #"直接写变量名：`{name}`。"#),
            placeholders: ["name": .code],
            fixIts: [
                FixItSpec("removeText", arguments: ["text": #"$"#]),
                FixItSpec("removeLabels", offeredWhen: LocalizedText(#"For a label such as `isOn:`"#, #"对 `isOn:` 这类名字"#)),
            ]
        ),
        DiagnosticSpec(
            id: .swiftName, severity: .error,
            trigger: #"`.leading`, `.topLeading`, `.secondary`, `.infinity`, `alignment:`"#,
            template: LocalizedText(
                #"Desk writes `{desk}` instead of `{swift}`."#,
                #"Desk 里写 `{desk}`，不写 `{swift}`。"#),
            placeholders: ["desk": .code, "swift": .code],
            fixIts: [
                FixItSpec("replace"),
            ]
        ),
        DiagnosticSpec(
            id: .olderDeskName, severity: .error,
            trigger: #"`Layers`, `.corner(12)`, `music.artwork`, `.fit(.fill)` on an `Image`, `toggle(details)`"#,
            template: LocalizedText(
                #"Desk calls this `{new}`."#,
                #"Desk 里叫 `{new}`。"#),
            placeholders: ["new": .code],
            fixIts: [
                FixItSpec("replace"),
            ]
        ),
        DiagnosticSpec(
            id: .trailingActionBlock, severity: .error,
            trigger: #"`Button("Next") { music.next() }`, `Item("Open") { … }`"#,
            template: LocalizedText(
                #"In Desk the action goes in `.onClick { … }`: `{fixed}`."#,
                #"Desk 里动作要写在 `.onClick { … }` 里：`{fixed}`。"#),
            placeholders: ["fixed": .code],
            fixIts: [
                FixItSpec("moveInto", arguments: ["text": #".onClick"#]),
            ]
        ),
        DiagnosticSpec(
            id: .swiftIfLet, severity: .error,
            trigger: #"`if let t = music.title { Text(t) }`"#,
            template: LocalizedText(
                #"Desk has no `if let`; a missing value is simply missing. Write `{fixed}`."#,
                #"Desk 没有 `if let`，取不到的值就是取不到。写成 `{fixed}`。"#),
            placeholders: ["fixed": .code],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .closureParameter, severity: .error,
            trigger: #"`.onChange(of: x) { newValue in … }`"#,
            template: LocalizedText(
                #"Desk blocks take no parameters; {advice}."#,
                #"Desk 的花括号里不写参数；{advice}。"#),
            placeholders: ["value": .code, "name": .code, "advice": .text],
            hints: [
                HintSpec(key: "useValue", placeholder: "advice", text: LocalizedText(#"use the value itself, `{value}`, inside the block"#, #"在里面直接用 `{value}`"#)),
                HintSpec(key: "remove", placeholder: "advice", text: LocalizedText(#"remove `{name} in`"#, #"去掉 `{name} in`"#)),
            ],
            fixIts: [
                FixItSpec("removeClosureParameter"),
            ]
        ),
        DiagnosticSpec(
            id: .otherFrameworkName, severity: .error,
            trigger: #"`.fontSize(13)`, `.backgroundColor(.red)`, `.borderRadius(8)`, `.alpha(0.5)`, `.onTap { }`, `.onPress { }`, `Stack { }`"#,
            template: LocalizedText(
                #"`{name}` is how {family} writes it; in Desk write `{desk}`."#,
                #"`{name}` 是 {family} 的写法；Desk 里写 `{desk}`。"#),
            placeholders: ["name": .code, "family": .text, "desk": .code],
            fixIts: [
                FixItSpec("replace"),
            ]
        ),
        DiagnosticSpec(
            id: .htmlTag, severity: .error,
            trigger: #"`<div>`, `<span>`, `<img src=…>`"#,
            template: LocalizedText(
                #"This is HTML; in Desk use {desk}."#,
                #"这是 HTML；Desk 里用{desk}。"#),
            placeholders: ["desk": .text]
        ),
        DiagnosticSpec(
            id: .cssDeclaration, severity: .error,
            trigger: #"`flex-direction: row;`, `color: red;`"#,
            template: LocalizedText(
                #"This is CSS; in Desk write `{desk}`."#,
                #"这是 CSS；Desk 里写 `{desk}`。"#),
            placeholders: ["desk": .code],
            fixIts: [
                FixItSpec("replace", offeredWhen: LocalizedText(#"When the Desk spelling is exact"#, #"Desk 的写法完全对应时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .cssSelector, severity: .error,
            trigger: #"`.title { color: red }`, `#clock { … }`"#,
            template: LocalizedText(
                #"Desk has no CSS selectors; write `style {name} { … }` and use `.style({name})`."#,
                #"Desk 没有 CSS 选择器；写 `style {name} { … }`，再用 `.style({name})`。"#),
            placeholders: ["name": .code]
        ),
        DiagnosticSpec(
            id: .htmlAttribute, severity: .error,
            trigger: #"`class="x"`, `onclick="…"`"#,
            template: LocalizedText(
                #"`{attribute}=` is HTML; in Desk write `{desk}`."#,
                #"`{attribute}=` 是 HTML 的写法；Desk 里写 `{desk}`。"#),
            placeholders: ["attribute": .code, "desk": .code]
        ),
        DiagnosticSpec(
            id: .rainmeterOption, severity: .error,
            trigger: #"`FontColor=255,255,255`, `IfCondition=MeasureCPU > 80`"#,
            template: LocalizedText(
                #"This is Rainmeter; in Desk write `{desk}`."#,
                #"这是 Rainmeter 的写法；Desk 里写 `{desk}`。"#),
            placeholders: ["desk": .code],
            fixIts: [
                FixItSpec("replace", offeredWhen: LocalizedText(#"When the Desk spelling is exact"#, #"Desk 的写法完全对应时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .rainmeterSection, severity: .error,
            trigger: #"`[MeterCPU]` at a line start"#,
            template: LocalizedText(
                #"`[{name}]` is a Rainmeter section; in Desk you write the element itself, e.g. `{desk}`."#,
                #"`[{name}]` 是 Rainmeter 的节；Desk 里直接写元素，比如 `{desk}`。"#),
            placeholders: ["name": .code, "desk": .code]
        ),
        DiagnosticSpec(
            id: .rainmeterVariable, severity: .error,
            trigger: #"`#Color#`"#,
            template: LocalizedText(
                #"`#{name}#` is a Rainmeter variable; in Desk write `{desk}`."#,
                #"`#{name}#` 是 Rainmeter 的变量；Desk 里写 `{desk}`。"#),
            placeholders: ["name": .code, "desk": .code],
            fixIts: [
                FixItSpec("replaceWith", offeredWhen: LocalizedText(#"When an option of that name exists"#, #"有同名的选项时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .rainmeterBang, severity: .error,
            trigger: #"`[!SetVariable Page 1]`, `[!SetOption MeterCPU FontColor 255,0,0]`"#,
            template: LocalizedText(
                #"`[!{bang} …]` is a Rainmeter action; in Desk write `{desk}`."#,
                #"`[!{bang} …]` 是 Rainmeter 的动作；Desk 里写 `{desk}`。"#),
            placeholders: ["bang": .code, "desk": .code],
            fixIts: [
                FixItSpec("replace", offeredWhen: LocalizedText(#"When the Desk spelling is exact"#, #"Desk 的写法完全对应时"#)),
            ]
        ),
        DiagnosticSpec(
            id: .rainmeterSectionVariable, severity: .error,
            trigger: #"`[MeasureCPU]` inside text"#,
            template: LocalizedText(
                #"`[{name}]` reads a Rainmeter measure; in Desk use the data directly, e.g. `{desk}`."#,
                #"`[{name}]` 是读取 Rainmeter measure 的写法；Desk 里直接用数据，比如 `{desk}`。"#),
            placeholders: ["name": .code, "desk": .code]
        ),
        DiagnosticSpec(
            id: .rainmeterNotNeeded, severity: .error,
            trigger: #"`DynamicVariables=1`, `UpdateDivider=5`"#,
            template: LocalizedText(
                #"`{option}` isn't needed in Desk: {why}."#,
                #"`{option}` 在 Desk 里不需要：{why}。"#),
            placeholders: ["option": .code, "why": .text],
            fixIts: [
                FixItSpec("remove"),
            ]
        ),
        DiagnosticSpec(
            id: .windowsPath, severity: .error,
            trigger: #"`open("C:\Program Files\Steam\steam.exe")`, `Image("C:\Skins\bg.png")`"#,
            template: LocalizedText(
                #"Windows paths don't exist on a Mac. {hint}"#,
                #"Mac 上没有 Windows 路径。{hint}"#),
            placeholders: ["hint": .text, "app": .code, "file": .code],
            hints: [
                HintSpec(key: "program", text: LocalizedText(#"Open the app by name: `open("{app}")`."#, #"按名字打开 App：`open("{app}")`。"#)),
                HintSpec(key: "file", text: LocalizedText(#"Put it in the widget's folder and write `"{file}"`."#, #"把它放进组件文件夹，写成 `"{file}"`。"#)),
            ],
            fixIts: [
                FixItSpec("replaceWith", offeredWhen: LocalizedText(#"For an `.exe`"#, #"对 `.exe`"#)),
            ]
        ),
        DiagnosticSpec(
            id: .rainmeterDateFormat, severity: .error,
            trigger: #"`{time.now, format: "%H:%M"}`"#,
            template: LocalizedText(
                #"`{text}` is Rainmeter's date format; in Desk write `{fixed}` (or use `.time`, `.weekday`)."#,
                #"`{text}` 是 Rainmeter 的日期格式；Desk 里写 `{fixed}`（也可以用 `.time`、`.weekday`）。"#),
            placeholders: ["text": .code, "fixed": .code],
            fixIts: [
                FixItSpec("replace"),
            ]
        ),
        DiagnosticSpec(
            id: .rainmeterRelativePosition, severity: .error,
            trigger: #"`.position(x: 4R)`"#,
            template: LocalizedText(
                #"`{text}` means "after the previous element"; in Desk write `{fixed}`. {hint}"#,
                #"`{text}` 的意思是“紧跟在前一个元素后面”；Desk 里写 `{fixed}`。{hint}"#),
            placeholders: ["text": .code, "fixed": .code, "hint": .text],
            hints: [
                HintSpec(key: "inStack", text: LocalizedText(#"`spacing:` already does this."#, #"`spacing:` 已经做到了。"#)),
            ],
            fixIts: [
                FixItSpec("rewrite"),
            ]
        ),
        DiagnosticSpec(
            id: .rainmeterPlaceholderInText, severity: .warning,
            trigger: #"`Text("%1%")`, `Text("Hello #UserName#")`"#,
            template: LocalizedText(
                #"`{text}` is Rainmeter's way to put a value in text; it shows as written. Put the value in braces: `{fixed}`."#,
                #"`{text}` 是 Rainmeter 往文字里放值的写法，这里会原样显示。把值放进花括号：`{fixed}`。"#),
            placeholders: ["text": .code, "fixed": .code],
            fixIts: [
                FixItSpec("replaceWith", offeredWhen: LocalizedText(#"When such an option or declaration exists"#, #"有这样的选项或声明时"#)),
            ]
        ),
    ]
}
