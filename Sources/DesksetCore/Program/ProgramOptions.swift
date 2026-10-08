import Foundation

/// A complete, typed option value. Local cases keep their owning option's stable name in the effective schema.
public enum ProgramOptionValue: Equatable, Sendable {
    case boolean(Bool), string(String), number(ProgramNumber)
    case localCase(option: String, name: String)
}

public struct ProgramOptionChoice: Equatable, Sendable {
    public let value: ProgramOptionValue
    public let title: ProgramExpression
    public init(value: ProgramOptionValue, title: ProgramExpression) { self.value = value; self.title = title }
}

public enum ProgramOptionControl: Equatable, Sendable {
    case toggle
    case input(placeholder: ProgramExpression?)
    case slider(min: ProgramNumber, max: ProgramNumber, step: ProgramNumber?)
    case stepper(min: ProgramNumber, max: ProgramNumber, step: ProgramNumber)
    case picker(choices: [ProgramOptionChoice])
}

/// The host supplies the instance or installed-package identity; scope does not create a Core value namespace.
public enum ProgramOptionScope: Equatable, Sendable {
    case instance, package
}

public struct ProgramOption: Equatable, Sendable {
    public let name: String
    public let title: ProgramExpression
    public let control: ProgramOptionControl
    public let defaultValue: ProgramOptionValue
    public let help: ProgramExpression?
    public let hiddenIf: ProgramExpression?
    public let scope: ProgramOptionScope

    public init(name: String, title: ProgramExpression, control: ProgramOptionControl,
                defaultValue: ProgramOptionValue, help: ProgramExpression? = nil, hiddenIf: ProgramExpression? = nil,
                scope: ProgramOptionScope = .instance) {
        self.name = name; self.title = title; self.control = control; self.defaultValue = defaultValue
        self.help = help; self.hiddenIf = hiddenIf; self.scope = scope
    }
}

/// Panel order and groups are metadata, never scene elements or layout children.
public indirect enum ProgramOptionNode: Equatable, Sendable {
    case option(ProgramOption)
    case section(title: ProgramExpression, items: [ProgramOptionNode])
}

public struct ProgramOptionsInput: Equatable, Sendable {
    public let values: [String: ProgramOptionValue]
    public init(values: [String: ProgramOptionValue]) { self.values = values }
}

public struct ProgramResolvedOptionChoice: Equatable, Sendable {
    public let value: ProgramOptionValue
    public let title: String
    public init(value: ProgramOptionValue, title: String) { self.value = value; self.title = title }
}

public enum ProgramResolvedOptionControl: Equatable, Sendable {
    case toggle
    case input(placeholder: String?)
    case slider(min: ProgramNumber, max: ProgramNumber, step: ProgramNumber?)
    case stepper(min: ProgramNumber, max: ProgramNumber, step: ProgramNumber)
    case picker(choices: [ProgramResolvedOptionChoice])
}

public struct ProgramResolvedOption: Equatable, Sendable {
    public let name: String
    public let title: String
    public let control: ProgramResolvedOptionControl
    public let value: ProgramOptionValue
    public let help: String?
    public let hidden: Bool
    public let scope: ProgramOptionScope

    public init(name: String, title: String, control: ProgramResolvedOptionControl, value: ProgramOptionValue,
                help: String?, hidden: Bool, scope: ProgramOptionScope = .instance) {
        self.name = name; self.title = title; self.control = control; self.value = value
        self.help = help; self.hidden = hidden; self.scope = scope
    }
}

public indirect enum ProgramResolvedOptionNode: Equatable, Sendable {
    case option(ProgramResolvedOption)
    case section(title: String, items: [ProgramResolvedOptionNode])
}

public struct ProgramOptionsSnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let values: ProgramOptionsInput
    public let items: [ProgramResolvedOptionNode]
    public init(revision: UInt64, values: ProgramOptionsInput, items: [ProgramResolvedOptionNode]) {
        self.revision = revision; self.values = values; self.items = items
    }
}

public struct ProgramOptionsReconciliation: Equatable, Sendable {
    public let input: ProgramOptionsInput
    public let restoredNames: [String]
    public init(input: ProgramOptionsInput, restoredNames: [String]) {
        self.input = input; self.restoredNames = restoredNames
    }
}

/// Validated immutable panel metadata. Loading persisted values does not construct or initialize a runtime.
public struct ProgramOptionsSchema: Sendable {
    public let defaults: ProgramOptionsInput
    let options: [ProgramOptionNode]
    let definitions: [String: ProgramOption]
    let nodeCount: Int
    private let orderedNames: [String]
    private let translations: ProgramTranslations

    public init(options: [ProgramOptionNode], translations: ProgramTranslations = ProgramTranslations()) throws {
        try self.init(structure: options, translations: translations)
        var validation = try ProgramExpressionValidation(declarations: [], translations: translations, options: definitions)
        try validateExpressions(using: &validation)
    }

    /// Runtime uses the same structural checks, then registers metadata in its shared expression budget.
    init(structure options: [ProgramOptionNode], translations: ProgramTranslations) throws {
        var definitions: [String: ProgramOption] = [:], names: [String] = []
        var pending = options.reversed().map { ($0, 1) }, count = 0
        guard pending.count <= ProgramLimits.maximumElements else { throw ProgramRuntimeError.elementLimit }
        while let (node, depth) = pending.popLast() {
            count += 1
            guard count <= ProgramLimits.maximumElements else { throw ProgramRuntimeError.elementLimit }
            guard depth <= ProgramLimits.maximumDepth else { throw ProgramRuntimeError.depthLimit }
            switch node {
            case .section(_, let items):
                guard items.count <= ProgramLimits.maximumElements - count - pending.count else {
                    throw ProgramRuntimeError.elementLimit
                }
                pending.append(contentsOf: items.reversed().map { ($0, depth + 1) })
            case .option(let option):
                guard !option.name.isEmpty, option.name.utf16.count <= ProgramLimits.maximumTextLength,
                      definitions[option.name] == nil else { throw ProgramRuntimeError.invalidOption(option.name) }
                try Self.validateControl(option)
                definitions[option.name] = option
                names.append(option.name)
            }
        }
        self.options = options; self.definitions = definitions; self.nodeCount = count
        self.orderedNames = names; self.translations = translations
        self.defaults = ProgramOptionsInput(values: definitions.mapValues(\.defaultValue))
    }

    /// Explicit input is a complete replacement. Byte display bases are metadata owned by the current schema.
    @discardableResult
    public func validate(_ input: ProgramOptionsInput) throws -> ProgramOptionsInput {
        if let unknown = input.values.keys.filter({ definitions[$0] == nil }).sorted().first {
            throw ProgramRuntimeError.invalidOption(unknown)
        }
        var result: [String: ProgramOptionValue] = [:]
        for name in orderedNames {
            guard let value = input.values[name], let option = definitions[name] else {
                throw ProgramRuntimeError.invalidOption(name)
            }
            result[name] = try Self.validated(value, for: option)
        }
        return ProgramOptionsInput(values: result)
    }

    /// Missing new options use their defaults quietly; only invalid stored entries and removed names are reported.
    public func reconcilePersisted(_ values: [String: ProgramOptionValue]) -> ProgramOptionsReconciliation {
        var result = defaults.values, restored: [String] = []
        for name in orderedNames {
            guard let stored = values[name], let option = definitions[name] else { continue }
            if let value = try? Self.validated(stored, for: option) { result[name] = value }
            else { restored.append(name) }
        }
        restored += values.keys.filter { definitions[$0] == nil }.sorted()
        return ProgramOptionsReconciliation(input: ProgramOptionsInput(values: result), restoredNames: restored)
    }

    func validateExpressions(using validation: inout ProgramExpressionValidation) throws {
        var pending = options.reversed().map { $0 }
        while let node = pending.popLast() {
            switch node {
            case .section(let title, let items):
                try validation.validateOptionText(title)
                pending.append(contentsOf: items.reversed())
            case .option(let option):
                try validation.validateOptionText(option.title)
                if let help = option.help { try validation.validateOptionText(help) }
                if let condition = option.hiddenIf { try validation.validateOptionCondition(condition) }
                switch option.control {
                case .input(let placeholder):
                    if let placeholder { try validation.validateOptionText(placeholder) }
                case .picker(let choices):
                    for choice in choices { try validation.validateOptionText(choice.title) }
                case .toggle, .slider, .stepper: break
                }
            }
        }
    }

    /// Resolves a complete input without creating a runtime. Scope and stored values remain separate from labels.
    public func resolve(_ input: ProgramOptionsInput, revision: UInt64, language: String?,
                        dateInput: ProgramDateInput?) throws -> ProgramOptionsSnapshot {
        let input = try validate(input)
        var evaluation = ProgramExpressionEvaluation(declarations: [], dark: false, variables: nil,
            dateInput: dateInput, translations: translations, language: language, options: definitions, optionValues: input.values)
        func nodes(_ items: [ProgramOptionNode]) throws -> [ProgramResolvedOptionNode] {
            try items.map { node in
                switch node {
                case .section(let title, let items):
                    return .section(title: try evaluation.text(title, displayed: false).text, items: try nodes(items))
                case .option(let option):
                    let control: ProgramResolvedOptionControl
                    switch option.control {
                    case .toggle: control = .toggle
                    case .input(let placeholder):
                        control = .input(placeholder: try placeholder.map { try evaluation.text($0, displayed: false).text })
                    case .slider(let min, let max, let step): control = .slider(min: min, max: max, step: step)
                    case .stepper(let min, let max, let step): control = .stepper(min: min, max: max, step: step)
                    case .picker(let choices):
                        control = .picker(choices: try choices.map { choice in
                            ProgramResolvedOptionChoice(value: try Self.validated(choice.value, for: option),
                                title: try evaluation.text(choice.title, displayed: false).text)
                        })
                    }
                    guard let value = input.values[option.name] else { throw ProgramRuntimeError.invalidOption(option.name) }
                    return .option(ProgramResolvedOption(name: option.name,
                        title: try evaluation.text(option.title, displayed: false).text, control: control, value: value,
                        help: try option.help.map { try evaluation.text($0, displayed: false).text },
                        hidden: try option.hiddenIf.map { try evaluation.condition($0, displayed: false) } ?? false,
                        scope: option.scope))
                }
            }
        }
        return ProgramOptionsSnapshot(revision: revision, values: input, items: try nodes(options))
    }

    static func validated(_ value: ProgramOptionValue, for option: ProgramOption) throws -> ProgramOptionValue {
        try validateValue(value, owner: option.name)
        guard value.scalar.type == option.defaultValue.scalar.type else { throw ProgramRuntimeError.invalidOption(option.name) }
        switch option.control {
        case .toggle, .input: break
        case .slider(let min, let max, _), .stepper(let min, let max, _):
            guard case .number(let number) = value, number.value >= min.value, number.value <= max.value else {
                throw ProgramRuntimeError.invalidOption(option.name)
            }
        case .picker(let choices):
            guard choices.contains(where: { $0.value.scalar == value.scalar }) else { throw ProgramRuntimeError.invalidOption(option.name) }
        }
        if case .number(let number) = value, case .number(let prototype) = option.defaultValue {
            return .number(ProgramNumber(number.value, dimension: prototype.dimension, displayBase: prototype.displayBase))
        }
        return value
    }

    private static func validateControl(_ option: ProgramOption) throws {
        try validateValue(option.defaultValue, owner: option.name)
        switch option.control {
        case .toggle:
            guard case .boolean = option.defaultValue else { throw ProgramRuntimeError.invalidOption(option.name) }
        case .input:
            guard case .string = option.defaultValue else { throw ProgramRuntimeError.invalidOption(option.name) }
        case .slider(let min, let max, let step): try validateRange(min: min, max: max, step: step, option: option)
        case .stepper(let min, let max, let step): try validateRange(min: min, max: max, step: step, option: option)
        case .picker(let choices):
            guard !choices.isEmpty else { throw ProgramRuntimeError.invalidOption(option.name) }
            guard choices.count <= ProgramLimits.maximumExpressions else { throw ProgramRuntimeError.expressionLimit }
            guard option.defaultValue.scalar.type != .boolean else { throw ProgramRuntimeError.invalidOption(option.name) }
            for choice in choices {
                try validateValue(choice.value, owner: option.name)
                guard choice.value.scalar.type == option.defaultValue.scalar.type else { throw ProgramRuntimeError.invalidOption(option.name) }
            }
        }
        _ = try validated(option.defaultValue, for: option)
    }

    private static func validateRange(min: ProgramNumber, max: ProgramNumber, step: ProgramNumber?, option: ProgramOption) throws {
        try min.validate(); try max.validate(); try step?.validate()
        guard case .number(let value) = option.defaultValue, min.type == value.type, max.type == value.type,
              min.value <= max.value, step.map({ $0.type == value.type && $0.value > 0 }) ?? true else {
            throw ProgramRuntimeError.invalidOption(option.name)
        }
    }

    private static func validateValue(_ value: ProgramOptionValue, owner: String) throws {
        switch value {
        case .boolean: break
        case .string(let text):
            guard text.utf16.count <= ProgramLimits.maximumTextLength else { throw ProgramRuntimeError.invalidOption(owner) }
        case .number(let number): try number.validate()
        case .localCase(let option, let name):
            guard option == owner, !name.isEmpty, name.utf16.count <= ProgramLimits.maximumTextLength else {
                throw ProgramRuntimeError.invalidOption(owner)
            }
        }
    }
}

extension ProgramOptionValue {
    var scalar: ProgramScalar {
        switch self {
        case .boolean(let value): return .boolean(value)
        case .string(let value): return .string(value)
        case .number(let value): return .numeric(value)
        case .localCase(let option, let name): return .localCase(option: option, name: name)
        }
    }

    init?(_ scalar: ProgramScalar) {
        switch scalar {
        case .boolean(let value): self = .boolean(value)
        case .string(let value): self = .string(value)
        case .formattedString(let value): self = .string(value.text)
        case .numeric(let value): self = .number(value)
        case .localCase(let option, let name): self = .localCase(option: option, name: name)
        case .date, .missing: return nil
        }
    }
}
