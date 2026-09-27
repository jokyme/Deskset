import Foundation

/// The entry points of the Desk language (§0.4). This file holds the syntax-only ones: loading bytes, parsing,
/// formatting and text-only edits; checking and lowering are added by the semantic layers.
public enum Desk {
    /// Bytes → text (§1.1). Invalid UTF-8 is rejected as a whole (DK1008); valid UTF-8 is decoded without
    /// dropping a byte order mark, so the text's bytes are exactly the file's.
    public static func load(_ data: Data, fileName: String) -> LoadResult {
        let file = DeskFileID(path: fileName)
        let bytes = [UInt8](data)
        if let bad = firstInvalidUTF8Offset(bytes) {
            let diagnostic = Diagnostic(id: .invalidEncoding, severity: .error, file: file,
                                        range: bad..<min(bad + 1, bytes.count))
            return .rejected(diagnostic)
        }
        return .text(String(decoding: bytes, as: UTF8.self), file: file)
    }

    /// Text → lossless syntax tree (§2, §3). Never fails: any text gives a tree whose printout is the text, with
    /// the lexical and syntax diagnostics in `tree.diagnostics`.
    public static func parse(_ text: String, file: DeskFileID) -> SyntaxTree {
        SyntaxParsing.parse(text, file: file, version: SyntaxParsing.nextVersion())
    }

    /// `parse(_:file:)` with a file name.
    public static func parse(_ text: String, fileName: String) -> SyntaxTree {
        parse(text, file: DeskFileID(path: fileName))
    }
}

/// The parse pipeline: lex, match braces, parse, read the header.
enum SyntaxParsing {
    private static let versionLock = NSLock()
    private static var lastVersion = 0

    /// A new tree version; versions increase with every parse in the process.
    static func nextVersion() -> Int {
        versionLock.lock()
        defer { versionLock.unlock() }
        lastVersion += 1
        return lastVersion
    }

    static func parse(_ text: String, file: DeskFileID, version: Int) -> SyntaxTree {
        let bytes = Array(text.utf8)
        let needed = StackGuard.nestingEstimate(bytes) * StackGuard.bytesPerNestingLevel
        return StackGuard.run(needing: needed) { parse(bytes: bytes, text: text, file: file, version: version) }
    }

    private static func parse(bytes: [UInt8], text: String, file: DeskFileID, version: Int) -> SyntaxTree {
        let lines = LineTable(bytes: bytes)
        let lexed = Lexer.lex(bytes, file: file)
        let braces = BraceMatching.match(lexed, lines: lines)
        var parser = Parser(lexed: lexed, braces: braces, file: file, lines: lines, bytes: bytes)
        let root = parser.parseSourceFile()
        parser.foreignRunRanges.sort { $0.lowerBound < $1.lowerBound }
        let lexical = lexed.diagnostics.filter { !parser.isInForeignRun($0.range.lowerBound) }
        var diagnostics = lexical + parser.diagnostics
        // Sorted by position; the sort is stable, so diagnostics at one position keep the order they were found.
        diagnostics = diagnostics.enumerated().sorted { a, b in
            if a.element.range.lowerBound != b.element.range.lowerBound {
                return a.element.range.lowerBound < b.element.range.lowerBound
            }
            return a.offset < b.offset
        }.map(\.element)
        let header = readHeader(root)
        return SyntaxTree(file: file, root: root, text: text, version: version, diagnostics: diagnostics,
                          header: header, lines: lines, repair: BraceRepair(segments: braces.repairedSegments))
    }

    /// `deskVersion` and `requires` of the file's `info` or `package` block, when written as literals (§8.5).
    static func readHeader(_ root: SyntaxNode) -> FileHeader {
        var header = FileHeader()
        for item in root.children {
            guard let block = item.node, block.kind == .infoBlock || block.kind == .packageBlock,
                  let body = block.children.last?.node, body.kind == .block else { continue }
            for statement in body.children {
                guard let field = statement.node, field.kind == .field,
                      let label = field.children.first?.node?.children.first?.token,
                      let value = field.children.last?.node else { continue }
                switch label.text {
                case "deskVersion" where header.deskVersion == nil:
                    if value.kind == .numberLiteral, value.children.count == 1, let token = value.children[0].token,
                       token.unit == nil, !token.text.contains("."), let n = Int(token.text) {
                        header.deskVersion = n
                    }
                case "requires" where header.requires == nil:
                    if let text = StringLiteralSyntax.literalValue(of: value) {
                        header.requires = AppVersion(text)
                    }
                default:
                    break
                }
            }
            break
        }
        return header
    }
}
