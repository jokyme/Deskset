import Foundation

/// Executable scalar expressions of the shared program. These are values, not syntax nodes or host services.
/// Dates read an immutable projection input; assignments use the shared action executor. Numeric data stays unsupported.
public indirect enum ProgramExpression: Equatable, Sendable {
    case string(String), boolean(Bool)
    /// Declaration occurrence in WidgetProgram.declarations, in original source order.
    case declaration(Int)
    case appearanceDark
    case timeNow
    case dateIn(ProgramExpression, timeZone: String)
    case formatDate(ProgramExpression, ProgramDateFormat)
    case concatenate([ProgramExpression])
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
    case string(String), boolean(Bool), date(ProgramDateValue)
}

/// Validate all branches and declaration initializers once, including ones a lazy expression will not read.
/// Memoized declaration heights retain the expanded reference depth rather than hiding a long cached chain.
struct ProgramExpressionValidation {
    enum ScalarType { case string, boolean, date }
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
            case .dateIn(let child, let zone):
                guard !zone.isEmpty, zone.utf16.count <= ProgramLimits.maximumTextLength,
                      TimeZone(identifier: zone) != nil else { throw ProgramRuntimeError.invalidExpression }
                pending.append((child, depth + 1))
            case .formatDate(let child, let format):
                _ = try format.precision
                pending.append((child, depth + 1))
            case .concatenate(let parts):
                guard parts.count <= ProgramLimits.maximumExpressions else { throw ProgramRuntimeError.expressionLimit }
                pending.append(contentsOf: parts.reversed().map { ($0, depth + 1) })
            case .boolean, .appearanceDark, .timeNow: break
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
        case .timeNow: result = Info(type: .date, height: 1)
        case .dateIn(let child, _), .formatDate(let child, _):
            let value = try expressionInfo(child, depth: depth + 1)
            guard value.type == .date else { throw ProgramRuntimeError.invalidExpression }
            if case .dateIn = expression { result = Info(type: .date, height: value.height + 1) }
            else { result = Info(type: .string, height: value.height + 1) }
        case .concatenate(let parts):
            var height = 1
            for part in parts {
                let value = try expressionInfo(part, depth: depth + 1)
                guard value.type == .string || value.type == .boolean else { throw ProgramRuntimeError.invalidExpression }
                height = max(height, value.height + 1)
            }
            result = Info(type: .string, height: height)
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
    private struct Value {
        let scalar: ProgramScalar
        var precision: ProgramClockPrecision? = nil
        // Only a freshly pulled date remains live. A variable/assignment freezes the scalar, as appearance does.
        var currentDate = false
    }

    let declarations: [ProgramDeclaration]
    let dark: Bool
    let dateInput: ProgramDateInput?
    var variables: [ProgramScalar?]
    private var computed: [Int: Value] = [:]
    private(set) var clockPrecision: ProgramClockPrecision?

    init(declarations: [ProgramDeclaration], dark: Bool, variables: [ProgramScalar?]?, dateInput: ProgramDateInput? = nil) {
        self.declarations = declarations
        self.dark = dark
        self.dateInput = dateInput
        self.variables = variables ?? Array(repeating: nil, count: declarations.count)
    }

    mutating func initialize() throws {
        for (index, declaration) in declarations.enumerated() where declaration.kind == .variable {
            variables[index] = try evaluate(declaration.initial, depth: 1).scalar
            computed.removeAll(keepingCapacity: true)
        }
    }

    mutating func text(_ expression: ProgramExpression, displayed: Bool = true) throws -> String {
        let result = try evaluate(expression, depth: 1)
        guard case .string(let value) = result.scalar,
              value.utf16.count <= ProgramLimits.maximumTextLength else { throw ProgramRuntimeError.invalidExpression }
        if displayed { clockPrecision = .combined(clockPrecision, result.precision) }
        return value
    }

    mutating func resolveAssignmentValue(_ expression: ProgramExpression) throws -> ProgramScalar {
        try evaluate(expression, depth: 1).scalar
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
        case (.date, .date(let date)):
            guard date.instant.timeIntervalSince1970.isFinite else { throw ProgramRuntimeError.invalidDateInput }
        default: throw ProgramRuntimeError.invalidAssignment(index)
        }
        variables[index] = value
        // The next statement pulls computed values from these new variables, even after an equal assignment.
        computed.removeAll(keepingCapacity: true)
    }

    private mutating func evaluate(_ expression: ProgramExpression, depth: Int) throws -> Value {
        guard depth <= ProgramLimits.maximumExpressionDepth else { throw ProgramRuntimeError.expressionDepth }
        switch expression {
        case .string(let value): return Value(scalar: .string(value))
        case .boolean(let value): return Value(scalar: .boolean(value))
        case .appearanceDark: return Value(scalar: .boolean(dark))
        case .timeNow:
            guard let dateInput, dateInput.instant.timeIntervalSince1970.isFinite else { throw ProgramRuntimeError.invalidDateInput }
            return Value(scalar: .date(ProgramDateValue(instant: dateInput.instant, timeZone: dateInput.timeZone)), currentDate: true)
        case .dateIn(let child, let identifier):
            let value = try evaluate(child, depth: depth + 1)
            guard case .date(let date) = value.scalar, let zone = TimeZone(identifier: identifier) else {
                throw ProgramRuntimeError.invalidExpression
            }
            return Value(scalar: .date(ProgramDateValue(instant: date.instant, timeZone: zone)),
                         precision: value.precision, currentDate: value.currentDate)
        case .formatDate(let child, let format):
            let value = try evaluate(child, depth: depth + 1)
            guard case .date(let date) = value.scalar else { throw ProgramRuntimeError.invalidExpression }
            guard let dateInput else { throw ProgramRuntimeError.invalidDateInput }
            let result = try format.string(from: date, locale: dateInput.locale)
            let precision = ProgramClockPrecision.combined(value.precision, value.currentDate ? try format.precision : nil)
            return Value(scalar: .string(result), precision: precision)
        case .concatenate(let parts):
            var text = "", length = 0, precision: ProgramClockPrecision?
            for part in parts {
                let value = try evaluate(part, depth: depth + 1)
                let addition: String
                switch value.scalar {
                case .string(let string): addition = string
                case .boolean(let boolean):
                    let chinese = dateInput?.locale.languageCode == "zh"
                    addition = chinese ? (boolean ? "是" : "否") : (boolean ? "Yes" : "No")
                case .date: throw ProgramRuntimeError.invalidExpression
                }
                let count = addition.utf16.count
                guard count <= ProgramLimits.maximumTextLength - length else { throw ProgramRuntimeError.invalidExpression }
                length += count; text += addition
                precision = .combined(precision, value.precision)
            }
            return Value(scalar: .string(text), precision: precision)
        case .declaration(let index):
            guard declarations.indices.contains(index) else { throw ProgramRuntimeError.invalidDeclaration(index) }
            if declarations[index].kind == .variable {
                guard let value = variables[index] else { throw ProgramRuntimeError.uninitializedDeclaration(index) }
                return Value(scalar: value)
            }
            if let value = computed[index] { return value }
            let value = try evaluate(declarations[index].initial, depth: depth + 1)
            computed[index] = value
            return value
        case .not(let child):
            let value = try evaluate(child, depth: depth + 1)
            guard case .boolean(let boolean) = value.scalar else { throw ProgramRuntimeError.invalidExpression }
            return Value(scalar: .boolean(!boolean), precision: value.precision)
        case .and(let left, let right), .or(let left, let right):
            let a = try evaluate(left, depth: depth + 1)
            guard case .boolean(let first) = a.scalar else { throw ProgramRuntimeError.invalidExpression }
            if case .and = expression, !first { return a }
            if case .or = expression, first { return a }
            let b = try evaluate(right, depth: depth + 1)
            guard case .boolean = b.scalar else { throw ProgramRuntimeError.invalidExpression }
            return Value(scalar: b.scalar, precision: .combined(a.precision, b.precision))
        case .equal(let left, let right), .notEqual(let left, let right):
            let a = try evaluate(left, depth: depth + 1), b = try evaluate(right, depth: depth + 1)
            let equal: Bool
            if case .date(let first) = a.scalar, case .date(let second) = b.scalar { equal = first.instant == second.instant }
            else { equal = a.scalar == b.scalar }
            let precision = ProgramClockPrecision.combined(.combined(a.precision, b.precision),
                                                           a.currentDate || b.currentDate ? .second : nil)
            if case .equal = expression { return Value(scalar: .boolean(equal), precision: precision) }
            return Value(scalar: .boolean(!equal), precision: precision)
        case .conditional(let condition, let yes, let no):
            let value = try evaluate(condition, depth: depth + 1)
            guard case .boolean(let boolean) = value.scalar else { throw ProgramRuntimeError.invalidExpression }
            var branch = try evaluate(boolean ? yes : no, depth: depth + 1)
            branch.precision = .combined(branch.precision, value.precision)
            return branch
        }
    }
}
