import Foundation
import DesksetCore

/// A lowering failure is separate from a catalog/checker diagnostic. It names the exact unsupported construct;
/// no guessed DK code and no partially executable program is returned.
public struct DeskCompilationIssue: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case unsupported, invalidCheckedModel, resourceLimit, invalidProgram }
    public let kind: Kind
    public let file: DeskFileID
    public let range: Range<Int>
    public let message: String

    public init(kind: Kind, file: DeskFileID, range: Range<Int>, message: String) {
        self.kind = kind
        self.file = file
        self.range = range
        self.message = message
    }
}

public struct DeskCompilationResult: Sendable {
    public let program: WidgetProgram?
    /// Original checker diagnostics, including useful warnings and notes; never rewritten or suppressed.
    public let diagnostics: [Diagnostic]
    public let issues: [DeskCompilationIssue]
}

public extension Desk {
    /// Checked source → the shared Core program. It supports String/Bool declarations and text expressions,
    /// system.dark, root onLoad variable assignments, rigid Column/Row, fixed solid Rectangle and constant box/style properties.
    /// Other semantics fail explicitly.
    /// Use the same catalog that checked the file (not a second interpretation of its names).
    static func compile(_ checked: CheckedFile, catalog: DeskCatalog = .current) -> DeskCompilationResult {
        guard !checked.diagnostics.contains(where: { $0.severity == .error }) else {
            return DeskCompilationResult(program: nil, diagnostics: checked.diagnostics, issues: [])
        }
        do {
            var compiler = StaticProgramCompiler(checked: checked, catalog: catalog)
            return DeskCompilationResult(program: try compiler.compile(), diagnostics: checked.diagnostics, issues: [])
        } catch let issue as DeskCompilationIssue {
            return DeskCompilationResult(program: nil, diagnostics: checked.diagnostics, issues: [issue])
        } catch {
            return DeskCompilationResult(program: nil, diagnostics: checked.diagnostics,
                                         issues: [DeskCompilationIssue(kind: .invalidProgram, file: checked.tree.file,
                                                                       range: checked.tree.rootNode.textRange,
                                                                       message: "Invalid shared program: \(error)")])
        }
    }
}
