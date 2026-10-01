import Foundation

/// Executable scalar expressions of the shared program. These are values, not syntax nodes or host services.
/// Dates and numeric formatting read immutable projection inputs; assignments use the shared action executor.
/// Numbers here are dimensionless. A language producer must reject unsupported units before lowering.
public indirect enum ProgramExpression: Equatable, Sendable {
    case string(String), boolean(Bool)
    case number(Double)
    /// Declaration occurrence in WidgetProgram.declarations, in original source order.
    case declaration(Int)
    case appearanceDark
    case timeNow
    case dateIn(ProgramExpression, timeZone: String)
    case formatDate(ProgramExpression, ProgramDateFormat)
    case formatNumber(ProgramExpression, ProgramNumberFormat)
    case concatenate([ProgramExpression])
    case not(ProgramExpression)
    case negate(ProgramExpression)
    case add(ProgramExpression, ProgramExpression), subtract(ProgramExpression, ProgramExpression)
    case multiply(ProgramExpression, ProgramExpression), divide(ProgramExpression, ProgramExpression), remainder(ProgramExpression, ProgramExpression)
    case and(ProgramExpression, ProgramExpression), or(ProgramExpression, ProgramExpression)
    case equal(ProgramExpression, ProgramExpression), notEqual(ProgramExpression, ProgramExpression)
    case less(ProgramExpression, ProgramExpression), lessOrEqual(ProgramExpression, ProgramExpression)
    case greater(ProgramExpression, ProgramExpression), greaterOrEqual(ProgramExpression, ProgramExpression)
    case isMissing(ProgramExpression), ifMissing(ProgramExpression, ProgramExpression)
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

enum ProgramScalarType: Equatable, Sendable { case string, boolean, date, number }

enum ProgramScalar: Equatable, Sendable {
    case string(String), boolean(Bool), date(ProgramDateValue)
    case number(Double), missing(ProgramScalarType), formattedString(ProgramTextValue)

    var type: ProgramScalarType {
        switch self {
        case .string, .formattedString: return .string
        case .boolean: return .boolean
        case .date: return .date
        case .number: return .number
        case .missing(let type): return type
        }
    }

    var isMissing: Bool { if case .missing = self { return true }; return false }
    var text: ProgramTextValue? {
        switch self {
        case .string(let text): return ProgramTextValue(text: text)
        case .formattedString(let text): return text
        default: return nil
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Formatting metadata is deliberately not String equality, including after a frozen assignment.
        if let a = lhs.text, let b = rhs.text { return a.text == b.text }
        switch (lhs, rhs) {
        case (.boolean(let a), .boolean(let b)): return a == b
        case (.date(let a), .date(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.missing(let a), .missing(let b)): return a == b
        default: return false
        }
    }
}

/// Validate all branches and declaration initializers once, including ones a lazy expression will not read.
/// Memoized declaration heights retain the expanded reference depth rather than hiding a long cached chain.
struct ProgramExpressionValidation {
    private struct Info { let type: ProgramScalarType; let height: Int }
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
            case .number(let value):
                guard value.isFinite else { throw ProgramRuntimeError.invalidExpression }
            case .declaration(let index):
                guard declarations.indices.contains(index) else { throw ProgramRuntimeError.invalidDeclaration(index) }
            case .not(let child), .negate(let child), .isMissing(let child): pending.append((child, depth + 1))
            case .and(let left, let right), .or(let left, let right), .equal(let left, let right), .notEqual(let left, let right),
                 .add(let left, let right), .subtract(let left, let right), .multiply(let left, let right),
                 .divide(let left, let right), .remainder(let left, let right), .less(let left, let right),
                 .lessOrEqual(let left, let right), .greater(let left, let right), .greaterOrEqual(let left, let right),
                 .ifMissing(let left, let right):
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
            case .formatNumber(let child, let format):
                try format.validate()
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
        case .number: result = Info(type: .number, height: 1)
        case .boolean, .appearanceDark: result = Info(type: .boolean, height: 1)
        case .timeNow: result = Info(type: .date, height: 1)
        case .dateIn(let child, _), .formatDate(let child, _):
            let value = try expressionInfo(child, depth: depth + 1)
            guard value.type == .date else { throw ProgramRuntimeError.invalidExpression }
            if case .dateIn = expression { result = Info(type: .date, height: value.height + 1) }
            else { result = Info(type: .string, height: value.height + 1) }
        case .formatNumber(let child, _), .negate(let child):
            let value = try expressionInfo(child, depth: depth + 1)
            guard value.type == .number else { throw ProgramRuntimeError.invalidExpression }
            if case .formatNumber = expression { result = Info(type: .string, height: value.height + 1) }
            else { result = Info(type: .number, height: value.height + 1) }
        case .concatenate(let parts):
            var height = 1
            for part in parts {
                let value = try expressionInfo(part, depth: depth + 1)
                guard value.type == .string || value.type == .boolean || value.type == .number else { throw ProgramRuntimeError.invalidExpression }
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
        case .add(let left, let right), .subtract(let left, let right), .multiply(let left, let right),
             .divide(let left, let right), .remainder(let left, let right), .less(let left, let right),
             .lessOrEqual(let left, let right), .greater(let left, let right), .greaterOrEqual(let left, let right):
            let a = try expressionInfo(left, depth: depth + 1), b = try expressionInfo(right, depth: depth + 1)
            guard a.type == .number, b.type == .number else { throw ProgramRuntimeError.invalidExpression }
            switch expression {
            case .less, .lessOrEqual, .greater, .greaterOrEqual: result = Info(type: .boolean, height: max(a.height, b.height) + 1)
            default: result = Info(type: .number, height: max(a.height, b.height) + 1)
            }
        case .isMissing(let child):
            let value = try expressionInfo(child, depth: depth + 1)
            result = Info(type: .boolean, height: value.height + 1)
        case .ifMissing(let left, let right):
            let a = try expressionInfo(left, depth: depth + 1), b = try expressionInfo(right, depth: depth + 1)
            guard a.type == b.type else { throw ProgramRuntimeError.invalidExpression }
            result = Info(type: a.type, height: max(a.height, b.height) + 1)
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

    mutating func text(_ expression: ProgramExpression, displayed: Bool = true) throws -> ProgramTextValue {
        let result = try evaluate(expression, depth: 1)
        guard let value = result.scalar.text,
              value.text.utf16.count <= ProgramLimits.maximumTextLength else { throw ProgramRuntimeError.invalidExpression }
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
        guard previous.type == value.type else { throw ProgramRuntimeError.invalidAssignment(index) }
        switch value {
        case .string(let text):
            guard text.utf16.count <= ProgramLimits.maximumTextLength else { throw ProgramRuntimeError.invalidExpression }
        case .formattedString(let value):
            guard value.text.utf16.count <= ProgramLimits.maximumTextLength else { throw ProgramRuntimeError.invalidExpression }
        case .date(let date):
            guard date.instant.timeIntervalSince1970.isFinite else { throw ProgramRuntimeError.invalidDateInput }
        case .number(let number):
            guard number.isFinite else { throw ProgramRuntimeError.invalidExpression }
        case .boolean, .missing: break
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
        case .number(let value): return Value(scalar: .number(value))
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
        case .formatNumber(let child, let format):
            let value = try evaluate(child, depth: depth + 1)
            guard value.scalar.type == .number else { throw ProgramRuntimeError.invalidExpression }
            let number: Double?
            if case .number(let n) = value.scalar { number = n } else { number = nil }
            let text = try format.string(from: number, locale: dateInput?.locale ?? Locale(identifier: "en_US_POSIX"))
            return Value(scalar: .formattedString(text), precision: value.precision)
        case .concatenate(let parts):
            var text = "", length = 0, ranges: [Range<Int>] = [], precision: ProgramClockPrecision?
            for part in parts {
                let value = try evaluate(part, depth: depth + 1)
                let addition: ProgramTextValue
                switch value.scalar {
                case .string(let string): addition = ProgramTextValue(text: string)
                case .formattedString(let string): addition = string
                case .boolean(let boolean):
                    let chinese = dateInput?.locale.languageCode == "zh"
                    addition = ProgramTextValue(text: chinese ? (boolean ? "是" : "否") : (boolean ? "Yes" : "No"))
                case .number(let number):
                    addition = try ProgramNumberFormat().string(from: number, locale: dateInput?.locale ?? Locale(identifier: "en_US_POSIX"))
                case .missing: addition = ProgramTextValue(text: "–")
                case .date: throw ProgramRuntimeError.invalidExpression
                }
                let count = addition.text.utf16.count
                guard count <= ProgramLimits.maximumTextLength - length else { throw ProgramRuntimeError.invalidExpression }
                ranges += addition.numberRanges.map { ($0.lowerBound + length)..<($0.upperBound + length) }
                length += count; text += addition.text
                precision = .combined(precision, value.precision)
            }
            return Value(scalar: .formattedString(ProgramTextValue(text: text, numberRanges: ranges)), precision: precision)
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
            if value.scalar == .missing(.boolean) { return value }
            guard case .boolean(let boolean) = value.scalar else { throw ProgramRuntimeError.invalidExpression }
            return Value(scalar: .boolean(!boolean), precision: value.precision)
        case .negate(let child):
            let value = try evaluate(child, depth: depth + 1)
            if value.scalar == .missing(.number) { return value }
            guard case .number(let number) = value.scalar else { throw ProgramRuntimeError.invalidExpression }
            return Value(scalar: .number(-number), precision: value.precision)
        case .isMissing(let child):
            let value = try evaluate(child, depth: depth + 1)
            return Value(scalar: .boolean(value.scalar.isMissing), precision: value.precision)
        case .ifMissing(let child, let fallback):
            let value = try evaluate(child, depth: depth + 1)
            if !value.scalar.isMissing { return value }
            var result = try evaluate(fallback, depth: depth + 1)
            result.precision = .combined(value.precision, result.precision)
            return result
        case .and(let left, let right), .or(let left, let right):
            let a = try evaluate(left, depth: depth + 1)
            guard a.scalar.type == .boolean else { throw ProgramRuntimeError.invalidExpression }
            if case .and = expression, a.scalar == .boolean(false) { return a }
            if case .or = expression, a.scalar == .boolean(true) { return a }
            let b = try evaluate(right, depth: depth + 1)
            guard b.scalar.type == .boolean else { throw ProgramRuntimeError.invalidExpression }
            let result: ProgramScalar
            if !a.scalar.isMissing { result = b.scalar }
            else if case .and = expression, b.scalar == .boolean(false) { result = .boolean(false) }
            else if case .or = expression, b.scalar == .boolean(true) { result = .boolean(true) }
            else { result = .missing(.boolean) }
            return Value(scalar: result, precision: .combined(a.precision, b.precision))
        case .equal(let left, let right), .notEqual(let left, let right):
            let a = try evaluate(left, depth: depth + 1), b = try evaluate(right, depth: depth + 1)
            if a.scalar.isMissing || b.scalar.isMissing {
                return Value(scalar: .missing(.boolean), precision: .combined(a.precision, b.precision))
            }
            let equal: Bool
            if case .date(let first) = a.scalar, case .date(let second) = b.scalar { equal = first.instant == second.instant }
            else { equal = a.scalar == b.scalar }
            let precision = ProgramClockPrecision.combined(.combined(a.precision, b.precision),
                                                           a.currentDate || b.currentDate ? .second : nil)
            if case .equal = expression { return Value(scalar: .boolean(equal), precision: precision) }
            return Value(scalar: .boolean(!equal), precision: precision)
        case .add(let left, let right), .subtract(let left, let right), .multiply(let left, let right),
             .divide(let left, let right), .remainder(let left, let right), .less(let left, let right),
             .lessOrEqual(let left, let right), .greater(let left, let right), .greaterOrEqual(let left, let right):
            let a = try evaluate(left, depth: depth + 1), b = try evaluate(right, depth: depth + 1)
            let precision = ProgramClockPrecision.combined(a.precision, b.precision)
            let comparison: Bool
            switch expression { case .less, .lessOrEqual, .greater, .greaterOrEqual: comparison = true; default: comparison = false }
            if a.scalar.isMissing || b.scalar.isMissing {
                return Value(scalar: .missing(comparison ? .boolean : .number), precision: precision)
            }
            guard case .number(let first) = a.scalar, case .number(let second) = b.scalar else { throw ProgramRuntimeError.invalidExpression }
            let result: ProgramScalar
            switch expression {
            case .less: result = .boolean(first < second)
            case .lessOrEqual: result = .boolean(first <= second)
            case .greater: result = .boolean(first > second)
            case .greaterOrEqual: result = .boolean(first >= second)
            default:
                let number: Double
                switch expression {
                case .add: number = first + second
                case .subtract: number = first - second
                case .multiply: number = first * second
                case .divide: number = first / second
                case .remainder: number = first.truncatingRemainder(dividingBy: second)
                default: throw ProgramRuntimeError.invalidExpression
                }
                result = number.isFinite ? .number(number) : .missing(.number)
            }
            return Value(scalar: result, precision: precision)
        case .conditional(let condition, let yes, let no):
            let value = try evaluate(condition, depth: depth + 1)
            guard value.scalar.type == .boolean else { throw ProgramRuntimeError.invalidExpression }
            let boolean = value.scalar == .boolean(true) // Only this outer condition maps missing to false.
            var branch = try evaluate(boolean ? yes : no, depth: depth + 1)
            branch.precision = .combined(branch.precision, value.precision)
            return branch
        }
    }
}
