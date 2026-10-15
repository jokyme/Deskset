import Foundation
import DesksetCore

/// Stable, versioned records for an installed instance or package. Values are checked against the current schema after
/// decoding; this format never stores a compiler slot, translated title or syntax identity.
enum DeskProgramOptionStore {
    static let maximumValueBytes = 64 * 1024
    /// An independent engineering bound for one instance record or one installed package record.
    static let maximumTotalBytes = 1024 * 1024

    struct Decoded {
        let values: [String: ProgramOptionValue]
        let invalidNames: Set<String>
    }

    struct Restored {
        let input: ProgramOptionsInput
        let defaults: ProgramOptionsInput
        let restoredNames: Set<String>
    }

    struct ScopedValues {
        let instance: ProgramOptionsInput
        /// Only shared names visible to this member, not a changed-name diff. The caller selects the edited names
        /// and merges them into the latest authoritative package input; this subset must never replace the full record.
        let packagePatch: [String: ProgramOptionValue]
    }

    static func restore(_ records: [String: JSONValue], for program: WidgetProgram,
                        live: ProgramOptionsInput? = nil) throws -> Restored {
        let schema = try ProgramOptionsSchema(options: program.options, translations: program.translations)
        return restore(records, schema: schema, live: live)
    }

    /// A package caller supplies its complete package-only schema, including names overridden by some members.
    /// Reconciliation is a read: it never writes recovered defaults back to either durable scope.
    static func restore(_ records: [String: JSONValue], schema: ProgramOptionsSchema,
                        live: ProgramOptionsInput? = nil) -> Restored {
        let decoded = decode(records)
        let reconciled = schema.reconcilePersisted(live?.values ?? decoded.values)
        return Restored(input: reconciled.input, defaults: schema.defaults,
                        restoredNames: Set(reconciled.restoredNames).union(decoded.invalidNames))
    }

    /// The package input has already been reconciled against the independent, complete package schema.
    /// A same-name widget override is instance scope and therefore cannot read or alter that package value.
    static func restoreInstance(_ records: [String: JSONValue], for program: WidgetProgram,
                                package: ProgramOptionsInput, live: ProgramOptionsInput? = nil) throws -> Restored {
        let schema = try ProgramOptionsSchema(options: program.options, translations: program.translations)
        let scopes = optionScopes(program.options)
        let decoded = decode(records)
        let stored = live?.values ?? decoded.values
        let local = stored.filter { scopes[$0.key] == .instance }
        let reconciled = schema.reconcilePersisted(local)
        var values = reconciled.input.values
        for (name, scope) in scopes where scope == .package {
            guard let value = package.values[name] else { throw ProgramRuntimeError.invalidOption(name) }
            values[name] = value
        }
        // A mismatched shared schema is an error, never a member-specific fallback for an authoritative value.
        let input = try schema.validate(ProgramOptionsInput(values: values))
        let removed = stored.keys.filter { scopes[$0] != .instance }
        return Restored(input: input, defaults: schema.defaults,
                        restoredNames: Set(reconciled.restoredNames).union(decoded.invalidNames).union(removed))
    }

    static func split(_ input: ProgramOptionsInput, for program: WidgetProgram) throws -> ScopedValues {
        let schema = try ProgramOptionsSchema(options: program.options, translations: program.translations)
        let input = try schema.validate(input)
        let scopes = optionScopes(program.options)
        return ScopedValues(instance: ProgramOptionsInput(values: input.values.filter { scopes[$0.key] == .instance }),
                            packagePatch: input.values.filter { scopes[$0.key] == .package })
    }

    /// Called only after schema validation has checked uniqueness, size and depth.
    private static func optionScopes(_ options: [ProgramOptionNode]) -> [String: ProgramOptionScope] {
        var pending = options, scopes: [String: ProgramOptionScope] = [:]
        while let node = pending.popLast() {
            switch node {
            case .section(_, let items): pending.append(contentsOf: items)
            case .option(let option): scopes[option.name] = option.scope
            }
        }
        return scopes
    }

    static func encode(_ input: ProgramOptionsInput) throws -> [String: JSONValue] {
        var records: [String: JSONValue] = [:]
        for (name, value) in input.values {
            var record: [String: JSONValue] = ["version": .number(1)]
            switch value {
            case .boolean(let value):
                record["kind"] = .string("bool"); record["value"] = .bool(value)
            case .string(let value):
                record["kind"] = .string("string"); record["value"] = .string(value)
            case .number(let value):
                record["kind"] = .string("number"); record["value"] = .number(value.value)
                record["dimension"] = .string(dimensionName(value.dimension))
                if let base = value.displayBase { record["base"] = .number(Double(base)) }
            case .localCase(let option, let value):
                record["kind"] = .string("case"); record["option"] = .string(option)
                record["value"] = .string(value)
            }
            records[name] = .object(record)
        }
        try validateSize(records)
        return records
    }

    static func validateSize(_ records: [String: JSONValue]) throws {
        let encoder = JSONEncoder()
        for (name, value) in records {
            guard name.utf8.count <= maximumValueBytes,
                  try encoder.encode(value).count <= maximumValueBytes else {
                throw AppState.DeskOptionsSaveFailure.valueLimit
            }
        }
        guard try encoder.encode(records).count <= maximumTotalBytes else {
            throw AppState.DeskOptionsSaveFailure.totalLimit
        }
    }

    static func decode(_ records: [String: JSONValue]) -> Decoded {
        guard (try? JSONEncoder().encode(records).count).map({ $0 <= maximumTotalBytes }) == true else {
            return Decoded(values: [:], invalidNames: Set(records.keys))
        }
        var values: [String: ProgramOptionValue] = [:], invalid = Set<String>()
        for (name, record) in records {
            guard name.utf8.count <= maximumValueBytes,
                  (try? JSONEncoder().encode(record).count).map({ $0 <= maximumValueBytes }) == true,
                  let value = decodeValue(record) else { invalid.insert(name); continue }
            values[name] = value
        }
        return Decoded(values: values, invalidNames: invalid)
    }

    private static func decodeValue(_ raw: JSONValue) -> ProgramOptionValue? {
        guard case .object(let record) = raw, record["version"] == .number(1),
              case .string(let kind) = record["kind"] else { return nil }
        switch kind {
        case "bool":
            guard case .bool(let value) = record["value"] else { return nil }
            return .boolean(value)
        case "string":
            guard case .string(let value) = record["value"] else { return nil }
            return .string(value)
        case "number":
            guard case .number(let value) = record["value"], value.isFinite,
                  case .string(let name) = record["dimension"], let dimension = dimension(name) else { return nil }
            let base: Int?
            if let rawBase = record["base"] {
                guard dimension == .bytes, case .number(let value) = rawBase,
                      value == 1000 || value == 1024 else { return nil }
                base = Int(value)
            } else { base = nil }
            return .number(ProgramNumber(value, dimension: dimension, displayBase: base))
        case "case":
            guard case .string(let option) = record["option"], !option.isEmpty,
                  case .string(let value) = record["value"], !value.isEmpty else { return nil }
            return .localCase(option: option, name: value)
        default: return nil
        }
    }

    private static func dimensionName(_ value: ProgramNumberDimension) -> String {
        switch value {
        case .plain: return "plain"
        case .percent: return "percent"
        case .bytes: return "bytes"
        case .duration: return "duration"
        case .length: return "length"
        case .angle: return "angle"
        }
    }

    private static func dimension(_ value: String) -> ProgramNumberDimension? {
        switch value {
        case "plain": return .plain
        case "percent": return .percent
        case "bytes": return .bytes
        case "duration": return .duration
        case "length": return .length
        case "angle": return .angle
        default: return nil
        }
    }
}
