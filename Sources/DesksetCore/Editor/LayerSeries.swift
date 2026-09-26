import Foundation

/// A run of repeated layers or live data items that the editor folds into one row ("16 bars", "16 sound bands"):
/// docs/editor-friendly.md §5.2 "Groups (repeated layers)".
public struct Series: Equatable {
    /// Meters (a run of layers) or measures (a run of live data).
    public enum Kind: Equatable {
        case layers, data
    }

    public var kind: Kind
    /// The section names, first to last in file order.
    public var members: [String]

    public init(kind: Kind, members: [String]) {
        self.kind = kind
        self.members = members
    }

    /// Whether `section` is one of the members (case-insensitive, like section names).
    public func contains(_ section: String) -> Bool {
        index(of: section) != nil
    }

    /// The position of `section` among the members (0-based); nil when it is not one.
    public func index(of section: String) -> Int? {
        members.firstIndex { $0.caseInsensitiveCompare(section) == .orderedSame }
    }
}

/// Finds the runs of repeated layers and data in a skin (docs/editor-friendly.md §5.2, §5.3).
///
/// A run of layers is 3 or more meters next to each other in file order that are the same kind of meter, use the same
/// looks (the `MeterStyle` list), are neither in nor of a container, and whose names differ only by a trailing number
/// that counts up by one (`MeterBand0`, `MeterBand1`, … `MeterBand15`). A run of data is the same for measures: the
/// same type (and plugin), the same `Parent=` and the same `Type=` (AudioLevel's kind of value), names counting up.
/// Anything else — another type, another look, a missing number, a section in between — ends the run.
public enum LayerSeries {
    /// The fewest members a run has.
    public static let minimumCount = 3

    /// The runs in `skin`, layers first, each in file order.
    public static func detect(in skin: Skin) -> [Series] {
        let layers = runs(skin.meters.map { m in
            let contained = m.container != nil || m.isContainer
                || !(m.rawOption("Container") ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            return Entry(name: m.name, signature: contained ? nil : layerSignature(m))
        }).map { Series(kind: .layers, members: $0) }
        let data = runs(skin.measures.map { Entry(name: $0.name, signature: dataSignature($0)) })
            .map { Series(kind: .data, members: $0) }
        return layers + data
    }

    /// A section and what must match its neighbours (nil: it never joins a run).
    struct Entry {
        var name: String
        var signature: String?
    }

    /// A name split into the part before its trailing number and that number ("MeterBand12" → ("meterband", 12));
    /// nil without a trailing number (or without anything before it).
    static func numbered(_ name: String) -> (base: String, number: Int)? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.reversed().prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count < trimmed.count, digits.count <= 9,
              let number = Int(String(digits.reversed())) else { return nil }
        return (String(trimmed.dropLast(digits.count)).lowercased(), number)
    }

    /// Runs of `entries` (in order) with the same base name and signature, their numbers counting up by one.
    static func runs(_ entries: [Entry]) -> [[String]] {
        var result: [[String]] = []
        var run: [String] = []
        var key: (base: String, signature: String, number: Int)?
        func flush() {
            if run.count >= minimumCount { result.append(run) }
            run = []
            key = nil
        }
        for e in entries {
            guard let signature = e.signature, let n = numbered(e.name) else {
                flush()
                continue
            }
            if let k = key, k.base == n.base, k.signature == signature, n.number == k.number + 1 {
                run.append(e.name)
                key?.number = n.number
            } else {
                flush()
                run = [e.name]
                key = (n.base, signature, n.number)
            }
        }
        flush()
        return result
    }

    /// Meter type and look list.
    static func layerSignature(_ m: Meter) -> String {
        let looks = (m.rawOption("MeterStyle") ?? "").split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return m.type.lowercased() + "\u{1F}" + looks.joined(separator: "|")
    }

    /// Measure type (and plugin), parent and kind of value.
    static func dataSignature(_ m: Measure) -> String {
        func value(_ key: String) -> String { (m.rawOption(key) ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
        let type = value("Measure")
        let plugin = type == "plugin" ? MeasureRegistry.normalizedPluginName(m.rawOption("Plugin") ?? "") : ""
        return [type, plugin, value("Parent"), value("Type")].joined(separator: "\u{1F}")
    }
}
