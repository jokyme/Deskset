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
    /// Literal demands of a fully supported program, also before missing assets have been supplied. Missing-file
    /// diagnostics are retained and still prevent program publication; a host can prepare these inputs and recheck.
    public let imageSources: [String]
}

public extension Desk {
    /// Checked source → the shared Core program. It supports String/Bool/Date/plain/Percent/Bytes/Duration/Length declarations,
    /// scalar text templates, checked time.now/Date.in/date formats, numeric and Date/Duration arithmetic,
    /// typed missing/three-valued logic, isMissing/ifMissing, locale numeric formats and digits policies,
    /// system.dark and checked CPU/memory/battery scalar fields, root onLoad variable assignments,
    /// ordered Text/basic-shape onClick assignments/copy/open actions,
    /// proposal-based Column/Row, solid Rectangle/Circle/Ellipse/Capsule,
    /// their solid centered outlines, Rectangle uniform corner radii, literal local Images with imageMode, dynamic inherited
    /// font sizes, and constant other box/style properties. Missing/invalid font sizes fail the current scene transaction;
    /// this finite program input path does not define missing-value policy for every dynamic facet.
    /// All named Color cases stay typed; platform hosts supply a complete immutable palette at projection time.
    /// Fit/fill, catalog ideals and min/max use the shared runtime; preset overflow scaling remains unsupported.
    /// Other numeric dimensions, Duration decimals, relative/subsecond Date formats and
    /// other semantics fail explicitly. Numeric lowering consumes final checked types, canonical constants and coercion receipts.
    /// Use the same catalog that checked the file (not a second interpretation of its names).
    static func compile(_ checked: CheckedFile, catalog: DeskCatalog = .current) -> DeskCompilationResult {
        let needed = StackGuard.bytesNeeded(toWalk: checked.tree)
        return StackGuard.run(needing: needed) {
            let errors = checked.diagnostics.filter { $0.severity == .error }
            guard errors.allSatisfy({ $0.id == .fileNotFound }) else {
                return DeskCompilationResult(program: nil, diagnostics: checked.diagnostics, issues: [], imageSources: [])
            }
            do {
                var compiler = StaticProgramCompiler(checked: checked, catalog: catalog)
                let program = try compiler.compile()
                var pending = [program.root], images = Set<String>()
                while let node = pending.popLast() {
                    switch node.content {
                    case .image(let image): images.insert(image.source)
                    case .column(_, _, let children), .row(_, _, let children): pending.append(contentsOf: children)
                    default: break
                    }
                }
                return DeskCompilationResult(program: errors.isEmpty ? program : nil, diagnostics: checked.diagnostics,
                                             issues: [], imageSources: images.sorted(by: DeskPackagePath.precedes))
            } catch let issue as DeskCompilationIssue {
                return DeskCompilationResult(program: nil, diagnostics: checked.diagnostics, issues: [issue], imageSources: [])
            } catch {
                return DeskCompilationResult(program: nil, diagnostics: checked.diagnostics,
                                             issues: [DeskCompilationIssue(kind: .invalidProgram, file: checked.tree.file,
                                                                           range: checked.tree.rootNode.textRange,
                                                                           message: "Invalid shared program: \(error)")], imageSources: [])
            }
        }
    }
}
