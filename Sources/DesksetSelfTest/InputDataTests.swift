import Foundation
@testable import DesksetCore

// What a skin reads about the Mac, given as data (the runtime design, "same inputs on both sides"): JSON values, and
// the `--render --data` fixtures that stand in for the system readings, the battery and the sensors.

func runInputDataTests(_ t: TestRunner) {
    t.suite("Seams: JSON values") {
        let v = try JSONValue.parse(#"{"a": 1, "b": [true, false, null, "x", 2.5], "c": {"d": "e"}, "f": 0}"#)
        t.equal(v["a"], .number(1))
        t.equal(v["b"], .array([.bool(true), .bool(false), .null, .string("x"), .number(2.5)]))
        t.equal(v["c"]?["d"]?.string, "e")
        t.equal(v["f"], .number(0), "0 and 1 stay numbers")
        t.equal(v["missing"], nil)
        t.equal(JSONValue.string("4.5").number, 4.5)
        t.equal(JSONValue.number(4.5)["a"], nil)
        t.equal(try JSONValue.parse("7"), .number(7), "any value at the top")
        t.equal(try JSONValue.parse("null"), .null)
        t.check((try? JSONValue.parse("{nope")) == nil, "bad JSON is an error")
        // Round trip: what is read is written back the same.
        let data = try JSONEncoder().encode(v)
        t.equal(try JSONValue.parse(data), v)
        t.equal(JSONValue.object(["b": .number(1), "a": .string("x/y")]).description, #"{"a":"x/y","b":1}"#)

        // Unknown keys of a type that knows only some.
        struct Known: Codable, Equatable {
            var name = ""
            var unknown: [String: JSONValue] = [:]
            enum CodingKeys: String, CodingKey { case name }
            init(name: String) { self.name = name }
            init(from decoder: Decoder) throws {
                unknown = try decoder.container(keyedBy: AnyCodingKey.self).unknownValues(besides: ["name"])
                name = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .name)
            }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(name, forKey: .name)
                var other = encoder.container(keyedBy: AnyCodingKey.self)
                try other.encodeUnknown(unknown, besides: ["name"])
            }
        }
        let known = try JSONDecoder().decode(Known.self, from: Data(#"{"name": "n", "later": {"x": [1]}}"#.utf8))
        t.equal(known.name, "n")
        t.equal(known.unknown, ["later": .object(["x": .array([.number(1)])])])
        let written = try JSONValue.parse(try JSONEncoder().encode(known))
        t.equal(written, .object(["name": .string("n"), "later": .object(["x": .array([.number(1)])])]))
        var clash = Known(name: "mine")
        clash.unknown = ["name": .string("theirs")]
        t.equal(try JSONValue.parse(try JSONEncoder().encode(clash))["name"], .string("mine"),
                "a kept key never overrides one the type writes")
    }
}
