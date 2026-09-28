import Foundation

/// Any JSON value, kept as it was read: settings files keep the keys a newer version wrote (`SkinState`), and the
/// `--render --data` fixtures are read with it. Numbers are `Double` (JSON has one number type).
public enum JSONValue: Hashable, Sendable, Codable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Parses JSON text (any value at the top, not only an object or an array).
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    /// The value of `key` in an object; nil for another kind of value or a missing key.
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var isNull: Bool { self == .null }

    public var bool: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    /// A number, or a string holding one.
    public var number: Double? {
        switch self {
        case .number(let v): return v
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var string: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    /// Compact JSON text (keys sorted).
    public var description: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

/// A coding key for any name: reads and writes the keys a type does not know itself.
public struct AnyCodingKey: CodingKey, Hashable, Sendable {
    public let stringValue: String
    public let intValue: Int?

    public init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    public init?(stringValue: String) { self.init(stringValue) }

    public init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    /// Every key of the container but `known`, with its value as JSON (a value that cannot be read is left out).
    public func unknownValues(besides known: Set<String>) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            if let v = try? decode(JSONValue.self, forKey: key) { result[key.stringValue] = v }
        }
        return result
    }
}

extension KeyedEncodingContainer where Key == AnyCodingKey {
    /// Writes `values` back, leaving out the keys the type writes itself (`known`).
    public mutating func encodeUnknown(_ values: [String: JSONValue], besides known: Set<String>) throws {
        for (key, value) in values where !known.contains(key) {
            try encode(value, forKey: AnyCodingKey(key))
        }
    }
}
