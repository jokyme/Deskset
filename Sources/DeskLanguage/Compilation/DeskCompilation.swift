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
    /// Source calls of a published program in this checked tree version. A synthetic widget root has no source call.
    /// Element IDs do not qualify references across compilations; use the reference only with its checked snapshot.
    public let elementRefs: [ElementID: ElementRef]

    init(program: WidgetProgram?, diagnostics: [Diagnostic], issues: [DeskCompilationIssue], imageSources: [String],
         elementRefs: [ElementID: ElementRef] = [:]) {
        self.program = program
        self.diagnostics = diagnostics
        self.issues = issues
        self.imageSources = imageSources
        self.elementRefs = program == nil ? [:] : elementRefs
    }
}

public extension Desk {
    /// Checked source → the shared Core program. It supports String/Bool/Date/plain/Percent/Bytes/Duration/Length/Angle declarations,
    /// scalar text templates, checked time.now/Date.in/date formats, numeric and Date/Duration arithmetic,
    /// typed missing/three-valued logic, isMissing/ifMissing, locale numeric formats and digits policies,
    /// system.dark and checked CPU/memory/battery scalar fields, including presence and remaining Duration, root onLoad variable assignments,
    /// ordered Text/Icon/Progress/Gauge/basic-shape/Row/Column/Freeform onClick/onRightClick assignments/copy/open actions,
    /// including empty handlers and event-specific innermost selection without bubbling,
    /// copy display formatting for the supported scalar types (open remains String-only),
    /// proposal-based Column/Row, constant-minimum Spacer and Freeform with literal positions and nine-point anchors, solid Rectangle/Circle/Ellipse/Capsule,
    /// their solid centered outlines, static box colors/glass and uniform corner radii, literal local Images with imageMode, dynamic inherited
    /// font sizes, dynamic hidden(if:) and conditional solid color/fill/track with inherited color fallbacks,
    /// and constant other box/style properties, including checked pt lengths. Unconditional local and supplied package styles expand
    /// with own/style precedence, nested includes, repeated applications and widget replacements. Local style definitions support
    /// checked dynamic font sizes, hidden/solid-color conditions and tooltip/voiceOver display expressions; package definitions retain constant values.
    /// Style expressions keep their definition-tree receipts and the merged translation tables.
    /// Missing/invalid font sizes fail the current scene transaction;
    /// this finite program input path does not define missing-value policy for every dynamic facet.
    /// All named Color cases stay typed; platform hosts supply a complete immutable palette at projection time.
    /// Dynamic Progress consumes checked numeric operands and proven memory owner ranges; missing values or nonpositive totals draw an empty track.
    /// Gauge shares those ranges across ring/arc/pie/needle, with dynamic checked Angle start/sweep and Length thickness.
    /// Angles retain canonical degrees through arithmetic/assignments and use integer-degree defaults in display formatting.
    /// Direct battery.timeRemaining displays with its catalog short style (including transparent parentheses); explicit style options override it.
    /// Display-position conditionals format each branch independently, and Bool text uses the shared localized Yes/No conversion.
    /// Own voiceOver labels on supported views use those same checked display expressions and do not inherit.
    /// Ordinary tooltip text and optional bold titles use those display expressions without inheritance. Explicit
    /// empty text is preserved; a title may stand alone. Conditional tooltip modifiers and state sources remain unsupported.
    /// Ordinary menus lower Item/Divider/nested Menu and menu-level if/else-if/else, with supported display titles,
    /// Bool checked/enabled values and Item onClick assignments/copy/open. Menu entries have no view geometry or source element refs.
    /// Local per-instance Toggle/Input/Slider/Stepper/Picker options retain Bool/String/supported numeric dimensions
    /// and nominal local cases, constant defaults/constraints, ordered Sections, localized panel text, and options-only hidden conditions.
    /// Checked local option reads and primary/secondary/menu assignments use independent persistent option identities;
    /// root onLoad remains session-variable-only. Slider steps are optional; off-grid values within bounds are valid.
    /// Package options, catalog-enum/Color and other controls, dynamic option metadata, menu-level for and saved values,
    /// other menu actions and view modifiers remain unsupported.
    /// Checked translations localize display literals and reorder their original formatted placeholders. Package
    /// translations are shared; a widget's own entry wins. Stored literals, copy/open and resource names retain their source values.
    /// Icons use checked String/SymbolName expressions without display conversion, dynamic inherited font sizes,
    /// complete supported font families/designs and weights, alignment and the three static IconColors modes.
    /// An Icon with a fixed box fills it unless it has an own or applied-style font; inherited fonts and bold/italic alone preserve fitting.
    /// View-level if/else-if/else expands only the selected branch into its real container, without retaining space.
    /// Every branch is checked and lowered; source references and literal image demands include inactive branches.
    /// A lone top-level if uses the same implicit Column and preset proposal as several top-level views.
    /// This slice keeps existing generic Duration formatting for scalar declarations/arithmetic; it introduces no member-style propagation through them.
    /// Fit/fill, catalog ideals, min/max and info.size presets use the shared runtime, including proportional preset overflow scaling.
    /// Conditional stroke/background/tint, other conditional facets, dynamic package styles, conditional style applications and hover/pressed states remain unsupported.
    /// View-level for, branch mount actions, dynamic layout and sibling geometry references, other numeric dimensions,
    /// Duration decimals, relative/subsecond Date formats and
    /// other semantics fail explicitly. Numeric lowering consumes final checked types, canonical constants and coercion receipts.
    /// Use the same catalog that checked the file (not a second interpretation of its names).
    static func compile(_ checked: CheckedFile, catalog: DeskCatalog = .current, package: CheckedFile? = nil) -> DeskCompilationResult {
        let needed = max(StackGuard.bytesNeeded(toWalk: checked.tree), package.map { StackGuard.bytesNeeded(toWalk: $0.tree) } ?? 0)
        let diagnostics = checked.diagnostics + (package?.tree.file == checked.tree.file ? [] : package?.diagnostics ?? [])
        return StackGuard.run(needing: needed) {
            let errors = checked.diagnostics.filter { $0.severity == .error }
            guard errors.allSatisfy({ $0.id == .fileNotFound }),
                  package?.diagnostics.contains(where: { $0.severity == .error }) != true else {
                return DeskCompilationResult(program: nil, diagnostics: diagnostics, issues: [], imageSources: [])
            }
            do {
                var compiler = try StaticProgramCompiler(checked: checked, catalog: catalog, package: package)
                let program = try compiler.compile()
                var pending = [program.root], images = Set<String>()
                while let node = pending.popLast() {
                    switch node.content {
                    case .image(let image): images.insert(image.source)
                    case .column(_, _, let children), .row(_, _, let children), .freeform(_, let children): pending.append(contentsOf: children)
                    case .conditional(let conditional):
                        pending.append(contentsOf: conditional.otherwise)
                        for branch in conditional.branches { pending.append(contentsOf: branch.body) }
                    default: break
                    }
                }
                return DeskCompilationResult(program: errors.isEmpty ? program : nil, diagnostics: diagnostics,
                                             issues: [], imageSources: images.sorted(by: DeskPackagePath.precedes),
                                             elementRefs: compiler.elementRefs)
            } catch let issue as DeskCompilationIssue {
                return DeskCompilationResult(program: nil, diagnostics: diagnostics, issues: [issue], imageSources: [])
            } catch {
                return DeskCompilationResult(program: nil, diagnostics: diagnostics,
                                             issues: [DeskCompilationIssue(kind: .invalidProgram, file: checked.tree.file,
                                                                           range: checked.tree.rootNode.textRange,
                                                                           message: "Invalid shared program: \(error)")], imageSources: [])
            }
        }
    }
}
