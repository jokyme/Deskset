import Foundation

// The value of an expression as the checker sees it (§4.3): its type with the dimension and display base of a number,
// the range data knows, what kind of literal it is (literals adopt dimensions and convert), what it depends on, and
// what it names when it is not a plain value (a namespace, an element, a type written as a qualifier).

/// What a value can be bound to by a control or assigned in an action.
enum BindTarget: Equatable {
    case variable(String), saved(String), computed(String), option(String), settableData(String), readOnlyData(String),
         loopVariable(String), event
}

struct Val {
    var type: DeskType
    /// The error type: never produces further diagnostics.
    var error = false
    /// 1000 or 1024 for amounts of data.
    var base: Int?
    var range: RangeSpec?
    /// A plain number literal (or arithmetic of plain literals): adopts the dimension it meets.
    var plainLiteral: Double?
    /// The value of a number literal, in its dimension's canonical unit.
    var literalValue: Double?
    /// The unit written on a number literal.
    var literalUnit: String?
    /// Made of `KB`…`TB` literals: the display base is settled by what they meet.
    var adoptsBase = false
    /// A string literal without interpolations, cooked.
    var stringLiteral: String?
    /// A string with interpolations.
    var isTemplate = false
    /// A string whose interpolations read only options (allowed in background addresses and commands).
    var templateOfOptions = false
    var boolLiteral: Bool?
    /// An implicit member (`.caption`) that was resolved.
    var implicitName: String?
    /// Only literals, lists of literals and cases (for `saved`, `info`).
    var isConstant = false
    var deps: Set<DepKey> = []
    /// An open declaration or option this value is (settled by use).
    var open: Int?
    /// A data namespace used as a value (`cpu`).
    var namespace: String?
    /// An own element name (`title`), for geometry and show/hide.
    var elementName: String?
    /// A type used as a qualifier (`Weekday`, `Color`, `Theme`).
    var qualifier: String?
    /// A component used as a value (DK3028).
    var component: String?
    var bind: BindTarget?
    /// The data member this value reads directly (`cpu.usage`).
    var dataPath: String?
    /// The option this value is (`options.x`).
    var optionName: String?
    /// A Secret option, or a value built from one.
    var secret = false
    var canBeMissing = false

    init(_ type: DeskType) { self.type = type }

    static var error: Val {
        var v = Val(.any)
        v.error = true
        return v
    }

    static func number(_ d: Dimension) -> Val { Val(.number(d)) }

    var dimension: Dimension? {
        if case .number(let d) = type { return d }
        return nil
    }

    var isNumber: Bool {
        switch type {
        case .number, .anyNumber, .fraction: return true
        default: return false
        }
    }

    var isJson: Bool { type == .json }

    /// A value that is only literals (for `saved` initializers and `info`).
    func withDeps(_ more: Set<DepKey>) -> Val {
        var v = self
        v.deps.formUnion(more)
        return v
    }
}

extension DeskType {
    /// Two types that are the same for equality and assignment, dimension included.
    func sameKind(as other: DeskType) -> Bool {
        switch (self, other) {
        case (.number(let a), .number(let b)): return a == b
        case (.list(let a), .list(let b)): return a.sameKind(as: b)
        case (.enumeration(let a), .enumeration(let b)), (.record(let a), .record(let b)): return a == b
        default: return self == other
        }
    }

    var isNumeric: Bool {
        switch self {
        case .number, .anyNumber, .fraction: return true
        default: return false
        }
    }

    /// String-like types (text, symbol names, pictures, fonts, folders written as text).
    var isStringLike: Bool {
        switch self {
        case .string, .symbolName, .imageSource, .fontFamily, .folderPath: return true
        default: return false
        }
    }

    var listElement: DeskType? {
        if case .list(let t) = self { return t }
        return nil
    }

    var enumID: String? {
        if case .enumeration(let id) = self { return id }
        return nil
    }
}

/// A declaration or option whose type is left open by its initializer and settled by its uses (§4.3 "settling by
/// use", D93).
struct OpenSlot {
    enum Kind { case dimension, base, type }
    enum Owner { case declaration(Decl), option(OptionInfo) }

    struct Use {
        var expected: DeskType
        var base: Int?
        var range: Range<Int>
        /// "compared with a percentage on line 12".
        var description: LocalizedText
    }

    var kind: Kind
    var owner: Owner
    /// The plain literals of the initializer (for DK4011 after settling to time, temperature…).
    var literals: [(range: Range<Int>, value: Double)]
    /// The candidate types of an open implicit member (`.left` → HAlign, Alignment…).
    var candidates: [String]
    /// The implicit member name for a type-open slot.
    var memberName: String?
    var memberRange: Range<Int>?
    var uses: [Use] = []
    /// Linked open slots that settle together.
    var links: [Int] = []
    var settled: DeskType?
    var settledBase: Int?

    var name: String {
        switch owner {
        case .declaration(let d): return d.name
        case .option(let o): return o.name
        }
    }
}
