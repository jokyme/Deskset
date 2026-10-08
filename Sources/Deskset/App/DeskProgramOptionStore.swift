import Foundation
import DesksetCore

/// Stable, versioned records for one installed instance. Values are checked against the current program after
/// decoding; this format never stores a compiler slot, translated title or syntax identity.
enum DeskProgramOptionStore {
    static let maximumValueBytes = 64 * 1024
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

    static func restore(_ records: [String: JSONValue], for program: WidgetProgram,
                        live: ProgramOptionsInput? = nil) throws -> Restored {
        let schema = try ProgramOptionsSchema(options: program.options, translations: program.translations)
        let decoded = decode(records)
        let reconciled = schema.reconcilePersisted(live?.values ?? decoded.values)
        return Restored(input: reconciled.input, defaults: schema.defaults,
                        restoredNames: Set(reconciled.restoredNames).union(decoded.invalidNames))
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
