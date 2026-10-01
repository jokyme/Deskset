/// Executable scalar expressions of the shared program. These are values, not syntax nodes or host services.
/// Scalar bindings have no numeric formatting or subscriptions; assignments use the shared action executor.
public indirect enum ProgramExpression: Equatable, Sendable {
    case string(String), boolean(Bool)
    /// Declaration occurrence in WidgetProgram.declarations, in original source order.
    case declaration(Int)
    case appearanceDark
    case not(ProgramExpression)
    case and(ProgramExpression, ProgramExpression), or(ProgramExpression, ProgramExpression)
    case equal(ProgramExpression, ProgramExpression), notEqual(ProgramExpression, ProgramExpression)
    case conditional(ProgramExpression, then: ProgramExpression, otherwise: ProgramExpression)
}

public struct ProgramDeclaration: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case variable, computed }
    public let name: String
    public let kind: Kind
    public let initial: ProgramExpression

    public init(name: String, kind: Kind, initial: ProgramExpression) {
        self.name = name
        self.kind = kind
        self.initial = initial
    }
}

enum ProgramScalar: Equatable, Sendable {
    case string(String), boolean(Bool)
}

/// Validate all branches and declaration initializers once, including ones a lazy expression will not read.
/// Memoized declaration heights retain the expanded reference depth rather than hiding a long cached chain.
struct ProgramExpressionValidation {
    enum ScalarType { case string, boolean }
    private struct Info { let type: ScalarType; let height: Int }
    private let declarations: [ProgramDeclaration]
    private var info: [Info?]
    private var visiting: Set<Int> = []
    private var count = 0

    init(declarations: [ProgramDeclaration]) throws {
        guard declarations.count <= ProgramLimits.maximumExpressions else { throw ProgramRuntimeError.expressionLimit }
        self.declarations = declarations
        info = Array(repeating: nil, count: declarations.count)
        var names = Set<String>()
        for (index, declaration) in declarations.enumerated() {
            guard !declaration.name.isEmpty, names.insert(declaration.name).inserted else {
                throw ProgramRuntimeError.invalidDeclaration(index)
            }
            try register(declaration.initial)
        }
        for index in declarations.indices { _ = try declarationInfo(index, depth: 1) }
    }

    mutating func validateText(_ expression: ProgramExpression) throws {
        try register(expression)
        guard try expressionInfo(expression, depth: 1).type == .string else { throw ProgramRuntimeError.invalidExpression }
    }

    mutating func validateAssignment(_ assignment: ProgramAssignment) throws {
        let index = assignment.declaration
        guard declarations.indices.contains(index) else { throw ProgramRuntimeError.invalidDeclaration(index) }
        guard declarations[index].kind == .variable else { throw ProgramRuntimeError.invalidAssignment(index) }
        try register(assignment.value)
        let target = try declarationInfo(index, depth: 1)
        let value = try expressionInfo(assignment.value, depth: 1)
        guard target.type == value.type else { throw ProgramRuntimeError.invalidAssignment(index) }
    }

    private mutating func register(_ expression: ProgramExpression) throws {
        var pending = [(expression, 1)]
        while let (value, depth) = pending.popLast() {
            count += 1
            guard count <= ProgramLimits.maximumExpressions else { throw ProgramRuntimeError.expressionLimit }
            guard depth <= ProgramLimits.maximumExpressionDepth else { throw ProgramRuntimeError.expressionDepth }
            switch value {
            case .string(let text):
                guard text.utf16.count <= ProgramLimits.maximumTextLength else { throw ProgramRuntimeError.invalidExpression }
            case .declaration(let index):
                guard declarations.indices.contains(index) else { throw ProgramRuntimeError.invalidDeclaration(index) }
            case .not(let child): pending.append((child, depth + 1))
            case .and(let left, let right), .or(let left, let right), .equal(let left, let right), .notEqual(let left, let right):
                pending.append(contentsOf: [(right, depth + 1), (left, depth + 1)])
            case .conditional(let condition, let yes, let no):
                pending.append(contentsOf: [(no, depth + 1), (yes, depth + 1), (condition, depth + 1)])
            case .boolean, .appearanceDark: break
            }
        }
    }

    private mutating func declarationInfo(_ index: Int, depth: Int) throws -> Info {
        guard declarations.indices.contains(index) else { throw ProgramRuntimeError.invalidDeclaration(index) }
        guard depth <= ProgramLimits.maximumExpressionDepth else { throw ProgramRuntimeError.expressionDepth }
        if let known = info[index] { return known }
        guard visiting.insert(index).inserted else { throw ProgramRuntimeError.cyclicDeclaration(index) }
        defer { visiting.remove(index) }
        let result = try expressionInfo(declarations[index].initial, depth: depth)
        info[index] = result
        return result
    }

    private mutating func expressionInfo(_ expression: ProgramExpression, depth: Int) throws -> Info {
        guard depth <= ProgramLimits.maximumExpressionDepth else { throw ProgramRuntimeError.expressionDepth }
        let result: Info
        switch expression {
        case .string: result = Info(type: .string, height: 1)
        case .boolean, .appearanceDark: result = Info(type: .boolean, height: 1)
        case .declaration(let index):
            let target = try declarationInfo(index, depth: depth + 1)
            result = Info(type: target.type, height: target.height + 1)
        case .not(let child):
            let value = try expressionInfo(child, depth: depth + 1)
            guard value.type == .boolean else { throw ProgramRuntimeError.invalidExpression }
            result = Info(type: .boolean, height: value.height + 1)
        case .and(let left, let right), .or(let left, let right):
            let a = try expressionInfo(left, depth: depth + 1), b = try expressionInfo(right, depth: depth + 1)
            guard a.type == .boolean, b.type == .boolean else { throw ProgramRuntimeError.invalidExpression }
            result = Info(type: .boolean, height: max(a.height, b.height) + 1)
        case .equal(let left, let right), .notEqual(let left, let right):
            let a = try expressionInfo(left, depth: depth + 1), b = try expressionInfo(right, depth: depth + 1)
            guard a.type == b.type else { throw ProgramRuntimeError.invalidExpression }
            result = Info(type: .boolean, height: max(a.height, b.height) + 1)
        case .conditional(let condition, let yes, let no):
            let c = try expressionInfo(condition, depth: depth + 1)
            let a = try expressionInfo(yes, depth: depth + 1), b = try expressionInfo(no, depth: depth + 1)
            guard c.type == .boolean, a.type == b.type else { throw ProgramRuntimeError.invalidExpression }
            result = Info(type: a.type, height: max(c.height, max(a.height, b.height)) + 1)
        }
        guard result.height <= ProgramLimits.maximumExpressionDepth else { throw ProgramRuntimeError.expressionDepth }
        return result
    }
}

/// A local evaluation transaction. Only variables survive a successful scene publication; computed values are
/// pulled once per projection or assignment. Failed startup, text measurement or layout discards this value.
struct ProgramExpressionEvaluation: ProgramAssignmentTarget {
    let declarations: [ProgramDeclaration]
    let dark: Bool
    var variables: [ProgramScalar?]
    private var computed: [Int: ProgramScalar] = [:]

    init(declarations: [ProgramDeclaration], dark: Bool, variables: [ProgramScalar?]?) {
        self.declarations = declarations
        self.dark = dark
        self.variables = variables ?? Array(repeating: nil, count: declarations.count)
    }

    mutating func initialize() throws {
        for (index, declaration) in declarations.enumerated() where declaration.kind == .variable {
            variables[index] = try evaluate(declaration.initial, depth: 1)
            // A subsequent initializer may pull a computed value that reads the just-initialized variable.
            computed.removeAll(keepingCapacity: true)
        }
    }

    mutating func text(_ expression: ProgramExpression) throws -> String {
        guard case .string(let value) = try evaluate(expression, depth: 1),
              value.utf16.count <= ProgramLimits.maximumTextLength else { throw ProgramRuntimeError.invalidExpression }
        return value
    }

    mutating func resolveAssignmentValue(_ expression: ProgramExpression) throws -> ProgramScalar {
        try evaluate(expression, depth: 1)
    }

    mutating func setProgramVariable(_ value: ProgramScalar, at index: Int) throws {
        guard declarations.indices.contains(index), variables.indices.contains(index) else {
            throw ProgramRuntimeError.invalidDeclaration(index)
        }
        guard declarations[index].kind == .variable else { throw ProgramRuntimeError.invalidAssignment(index) }
        guard let previous = variables[index] else { throw ProgramRuntimeError.uninitializedDeclaration(index) }
        switch (previous, value) {
        case (.string, .string(let text)):
            guard text.utf16.count <= ProgramLimits.maximumTextLength else { throw ProgramRuntimeError.invalidExpression }
        case (.boolean, .boolean): break
        default: throw ProgramRuntimeError.invalidAssignment(index)
        }
        variables[index] = value
        // The next statement must pull computed values from these new variables, even when an earlier RHS
        // populated the cache. Equal-value assignments also begin a new pull interval.
        computed.removeAll(keepingCapacity: true)
    }

    private mutating func boolean(_ expression: ProgramExpression, depth: Int) throws -> Bool {
        guard case .boolean(let value) = try evaluate(expression, depth: depth) else { throw ProgramRuntimeError.invalidExpression }
        return value
    }

    private mutating func evaluate(_ expression: ProgramExpression, depth: Int) throws -> ProgramScalar {
        guard depth <= ProgramLimits.maximumExpressionDepth else { throw ProgramRuntimeError.expressionDepth }
        switch expression {
        case .string(let value): return .string(value)
        case .boolean(let value): return .boolean(value)
        case .appearanceDark: return .boolean(dark)
        case .declaration(let index):
            guard declarations.indices.contains(index) else { throw ProgramRuntimeError.invalidDeclaration(index) }
            if declarations[index].kind == .variable {
                guard let value = variables[index] else { throw ProgramRuntimeError.uninitializedDeclaration(index) }
                return value
            }
            if let value = computed[index] { return value }
            let value = try evaluate(declarations[index].initial, depth: depth + 1)
            computed[index] = value
            return value
        case .not(let value): return .boolean(try !boolean(value, depth: depth + 1))
        case .and(let left, let right):
            guard try boolean(left, depth: depth + 1) else { return .boolean(false) }
            return .boolean(try boolean(right, depth: depth + 1))
        case .or(let left, let right):
            if try boolean(left, depth: depth + 1) { return .boolean(true) }
            return .boolean(try boolean(right, depth: depth + 1))
        case .equal(let left, let right):
            return .boolean(try evaluate(left, depth: depth + 1) == evaluate(right, depth: depth + 1))
        case .notEqual(let left, let right):
            return .boolean(try evaluate(left, depth: depth + 1) != evaluate(right, depth: depth + 1))
        case .conditional(let condition, let yes, let no):
            let branch = try boolean(condition, depth: depth + 1) ? yes : no
            return try evaluate(branch, depth: depth + 1)
        }
    }
}
