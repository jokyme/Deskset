import Foundation

/// Executable scalar expressions of the shared program. These are values, not syntax nodes or host services.
/// Dates and numeric formatting read immutable projection inputs; assignments use the shared action executor.
/// Numeric values use canonical units (percent points, bytes, seconds or length points), never source-unit spellings.
public indirect enum ProgramExpression: Equatable, Sendable {
    case string(String), boolean(Bool)
    case number(Double)
    /// Additive unit entry; the original dimensionless .number(Double) remains unchanged.
    case quantity(ProgramNumber)
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

public enum ProgramNumberDimension: Equatable, Sendable { case plain, percent, bytes, duration, length }

/// The one numeric value of the shared evaluator. Display base is metadata, not a unit conversion or type.
/// A Bytes value without a deciding base uses 1000. Other dimensions cannot carry a display base.
public struct ProgramNumber: Equatable, Sendable {
    public let value: Double
    public let dimension: ProgramNumberDimension
    public let displayBase: Int?

    public init(_ value: Double, dimension: ProgramNumberDimension, displayBase: Int? = nil) {
        self.value = value; self.dimension = dimension; self.displayBase = displayBase
    }

    func validate() throws {
        guard value.isFinite, dimension == .bytes ? (displayBase == nil || displayBase == 1000 || displayBase == 1024) : displayBase == nil else {
            throw ProgramRuntimeError.invalidExpression
        }
    }

    var type: ProgramScalarType { .numeric(dimension, displayBase: displayBase) }
}

enum ProgramScalarType: Equatable, Sendable {
    case string, boolean, date
    case numeric(ProgramNumberDimension, displayBase: Int? = nil)
    static var number: Self { .numeric(.plain) }
    var dimension: ProgramNumberDimension? { if case .numeric(let d, _) = self { return d }; return nil }
    var displayBase: Int? { if case .numeric(_, let b) = self { return b }; return nil }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.string, .string), (.boolean, .boolean), (.date, .date): return true
        case (.numeric(let a, _), .numeric(let b, _)): return a == b
        default: return false
        }
    }
}

enum ProgramScalar: Equatable, Sendable {
    case string(String), boolean(Bool), date(ProgramDateValue)
    case numeric(ProgramNumber), missing(ProgramScalarType), formattedString(ProgramTextValue)
    static func number(_ value: Double) -> Self { .numeric(ProgramNumber(value, dimension: .plain)) }

    var type: ProgramScalarType {
        switch self {
        case .string, .formattedString: return .string
        case .boolean: return .boolean
        case .date: return .date
        case .numeric(let value): return value.type
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
        case (.numeric(let a), .numeric(let b)): return a.dimension == b.dimension && a.value == b.value
        case (.missing(let a), .missing(let b)): return a == b
        default: return false
        }
    }
}

/// The same unit algebra validates a program and determines the type of arithmetic missing values.
private enum ProgramArithmetic {
    static func result(_ expression: ProgramExpression, _ a: ProgramScalarType, _ b: ProgramScalarType) throws -> ProgramScalarType {
        func invalid() throws -> ProgramScalarType { throw ProgramRuntimeError.invalidExpression }
        switch expression {
        case .less, .lessOrEqual, .greater, .greaterOrEqual:
            guard a.dimension != nil, a == b else { return try invalid() }
            return .boolean
        case .add, .subtract:
            if a == .date && b == .numeric(.duration) { return .date }
            if case .add = expression, a == .numeric(.duration) && b == .date { return .date }
            if case .subtract = expression, a == .date && b == .date { return .numeric(.duration) }
            fallthrough
        case .remainder:
            guard let dimension = a.dimension, a == b else { return try invalid() }
            return .numeric(dimension, displayBase: a.displayBase ?? b.displayBase)
        case .multiply:
            guard let x = a.dimension, let y = b.dimension else { return try invalid() }
            let dimension: ProgramNumberDimension
            if x == .plain { dimension = y }
            else if y == .plain { dimension = x }
            else if x == .percent && y != .percent { dimension = y }
            else if y == .percent && x != .percent { dimension = x }
            else { return try invalid() }
            return .numeric(dimension, displayBase: dimension == .bytes ? a.displayBase ?? b.displayBase : nil)
        case .divide:
            guard let x = a.dimension, let y = b.dimension else { return try invalid() }
            if y == .plain { return .numeric(x, displayBase: a.displayBase) }
            if x == y { return .number }
            return try invalid()
        default: return try invalid()
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

    mutating func validateFontSize(_ expression: ProgramExpression) throws {
        try register(expression)
        let dimension = try expressionInfo(expression, depth: 1).type.dimension
        // The catalog permits any Plain expression as points at a Length parameter, not other units.
        guard dimension == .plain || dimension == .length else { throw ProgramRuntimeError.invalidExpression }
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
            case .quantity(let value): try value.validate()
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
        case .quantity(let number): result = Info(type: number.type, height: 1)
        case .boolean, .appearanceDark: result = Info(type: .boolean, height: 1)
        case .timeNow: result = Info(type: .date, height: 1)
        case .dateIn(let child, _), .formatDate(let child, _):
            let value = try expressionInfo(child, depth: depth + 1)
            guard value.type == .date else { throw ProgramRuntimeError.invalidExpression }
            if case .dateIn = expression { result = Info(type: .date, height: value.height + 1) }
            else { result = Info(type: .string, height: value.height + 1) }
        case .formatNumber(let child, let format):
            let value = try expressionInfo(child, depth: depth + 1)
            guard let dimension = value.type.dimension else { throw ProgramRuntimeError.invalidExpression }
            try format.validate(for: dimension)
            result = Info(type: .string, height: value.height + 1)
        case .negate(let child):
            let value = try expressionInfo(child, depth: depth + 1)
            guard value.type.dimension != nil else { throw ProgramRuntimeError.invalidExpression }
            result = Info(type: value.type, height: value.height + 1)
        case .concatenate(let parts):
            var height = 1
            for part in parts {
                let value = try expressionInfo(part, depth: depth + 1)
                guard value.type == .string || value.type == .boolean || value.type.dimension != nil else { throw ProgramRuntimeError.invalidExpression }
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
            result = Info(type: try ProgramArithmetic.result(expression, a.type, b.type), height: max(a.height, b.height) + 1)
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

    mutating func fontSize(_ expression: ProgramExpression, element: ElementID, displayed: Bool) throws -> Double {
        let result = try evaluate(expression, depth: 1)
        guard case .numeric(let number) = result.scalar,
              number.dimension == .plain || number.dimension == .length,
              number.value.isFinite, number.value > 0 else { throw ProgramRuntimeError.invalidText(element) }
        if displayed {
            clockPrecision = .combined(clockPrecision, .combined(result.precision, result.currentDate ? .second : nil))
        }
        return number.value
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
        case .numeric(let number): try number.validate()
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
        case .quantity(let value): return Value(scalar: .numeric(value))
        case .appearanceDark: return Value(scalar: .boolean(dark))
        case .timeNow:
            guard let dateInput, dateInput.instant.timeIntervalSince1970.isFinite else { throw ProgramRuntimeError.invalidDateInput }
            return Value(scalar: .date(ProgramDateValue(instant: dateInput.instant, timeZone: dateInput.timeZone)), currentDate: true)
        case .dateIn(let child, let identifier):
            let value = try evaluate(child, depth: depth + 1)
            if value.scalar.isMissing && value.scalar.type == .date { return value }
            guard case .date(let date) = value.scalar, let zone = TimeZone(identifier: identifier) else {
                throw ProgramRuntimeError.invalidExpression
            }
            return Value(scalar: .date(ProgramDateValue(instant: date.instant, timeZone: zone)),
                         precision: value.precision, currentDate: value.currentDate)
        case .formatDate(let child, let format):
            let value = try evaluate(child, depth: depth + 1)
            guard let dateInput else { throw ProgramRuntimeError.invalidDateInput }
            let result: String
            if case .date(let date) = value.scalar { result = try format.string(from: date, locale: dateInput.locale) }
            else if value.scalar.isMissing && value.scalar.type == .date { result = "–" }
            else { throw ProgramRuntimeError.invalidExpression }
            let precision = ProgramClockPrecision.combined(value.precision, value.currentDate ? try format.precision : nil)
            return Value(scalar: .string(result), precision: precision)
        case .formatNumber(let child, let format):
            let value = try evaluate(child, depth: depth + 1)
            guard let dimension = value.scalar.type.dimension else { throw ProgramRuntimeError.invalidExpression }
            let number: ProgramNumber?
            if case .numeric(let n) = value.scalar { number = n } else { number = nil }
            let text = try format.string(from: number, dimension: dimension, locale: dateInput?.locale ?? Locale(identifier: "en_US_POSIX"))
            let precision = ProgramClockPrecision.combined(value.precision, value.currentDate ? .second : nil)
            return Value(scalar: .formattedString(text), precision: precision)
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
                case .numeric(let number):
                    addition = try ProgramNumberFormat().string(from: number, dimension: number.dimension, locale: dateInput?.locale ?? Locale(identifier: "en_US_POSIX"))
                case .missing: addition = ProgramTextValue(text: "–")
                case .date: throw ProgramRuntimeError.invalidExpression
                }
                let count = addition.text.utf16.count
                guard count <= ProgramLimits.maximumTextLength - length else { throw ProgramRuntimeError.invalidExpression }
                ranges += addition.numberRanges.map { ($0.lowerBound + length)..<($0.upperBound + length) }
                length += count; text += addition.text
                precision = .combined(precision, value.precision)
                if value.currentDate { precision = .combined(precision, .second) }
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
            if value.scalar.isMissing && value.scalar.type.dimension != nil { return value }
            guard case .numeric(let number) = value.scalar else { throw ProgramRuntimeError.invalidExpression }
            return Value(scalar: .numeric(ProgramNumber(-number.value, dimension: number.dimension, displayBase: number.displayBase)),
                         precision: value.precision, currentDate: value.currentDate)
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
            let precision = ProgramClockPrecision.combined(.combined(a.precision, b.precision),
                                                           a.currentDate || b.currentDate ? .second : nil)
            if a.scalar.isMissing || b.scalar.isMissing {
                return Value(scalar: .missing(.boolean), precision: precision)
            }
            let equal: Bool
            if case .date(let first) = a.scalar, case .date(let second) = b.scalar { equal = first.instant == second.instant }
            else { equal = a.scalar == b.scalar }
            if case .equal = expression { return Value(scalar: .boolean(equal), precision: precision) }
            return Value(scalar: .boolean(!equal), precision: precision)
        case .add(let left, let right), .subtract(let left, let right), .multiply(let left, let right),
             .divide(let left, let right), .remainder(let left, let right), .less(let left, let right),
             .lessOrEqual(let left, let right), .greater(let left, let right), .greaterOrEqual(let left, let right):
            let a = try evaluate(left, depth: depth + 1), b = try evaluate(right, depth: depth + 1)
            let type = try ProgramArithmetic.result(expression, a.scalar.type, b.scalar.type)
            let live = a.currentDate || b.currentDate
            let precision = ProgramClockPrecision.combined(.combined(a.precision, b.precision), type == .boolean && live ? .second : nil)
            if a.scalar.isMissing || b.scalar.isMissing {
                return Value(scalar: .missing(type), precision: precision, currentDate: live)
            }
            if type == .date {
                let date: ProgramDateValue, delta: Double
                if case .date(let value) = a.scalar, case .numeric(let n) = b.scalar {
                    date = value
                    if case .subtract = expression { delta = -n.value } else { delta = n.value }
                } else if case .numeric(let n) = a.scalar, case .date(let value) = b.scalar {
                    date = value; delta = n.value
                } else { throw ProgramRuntimeError.invalidExpression }
                let instant = date.instant.timeIntervalSince1970 + delta
                let scalar: ProgramScalar = instant.isFinite
                    ? .date(ProgramDateValue(instant: Date(timeIntervalSince1970: instant), timeZone: date.timeZone)) : .missing(.date)
                return Value(scalar: scalar, precision: precision, currentDate: live)
            }
            if case .date(let first) = a.scalar, case .date(let second) = b.scalar {
                let difference = first.instant.timeIntervalSince1970 - second.instant.timeIntervalSince1970
                return Value(scalar: difference.isFinite ? .numeric(ProgramNumber(difference, dimension: .duration)) : .missing(type),
                             precision: precision, currentDate: live)
            }
            guard case .numeric(let firstNumber) = a.scalar, case .numeric(let secondNumber) = b.scalar else { throw ProgramRuntimeError.invalidExpression }
            let first = firstNumber.value, second = secondNumber.value
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
                case .multiply:
                    // Percent × plain scales Percent; Percent × a unit quantity takes that percentage.
                    if firstNumber.dimension == .percent && secondNumber.dimension != .plain {
                        number = (first / 100) * second
                    } else if secondNumber.dimension == .percent && firstNumber.dimension != .plain {
                        number = first * (second / 100)
                    } else { number = first * second }
                case .divide: number = first / second
                case .remainder: number = first.truncatingRemainder(dividingBy: second)
                default: throw ProgramRuntimeError.invalidExpression
                }
                guard let dimension = type.dimension else { throw ProgramRuntimeError.invalidExpression }
                result = number.isFinite ? .numeric(ProgramNumber(number, dimension: dimension, displayBase: type.displayBase)) : .missing(type)
            }
            return Value(scalar: result, precision: precision, currentDate: type == .boolean ? false : live)
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
