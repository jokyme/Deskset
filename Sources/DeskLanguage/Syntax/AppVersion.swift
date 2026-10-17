import Foundation

/// A Deskset release (`1.0`, `1.2.1`). Catalog items carry the release that introduced them, and a file's
/// `info { requires: "1.2" }` names the oldest Deskset that can run it. It lives with the syntax so that a file's
/// header can be read without the catalog.
public struct AppVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// `"1"`, `"1.2"` or `"1.2.3"`: one to three groups of ASCII digits separated by dots; nil for anything else.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(part) else { return nil }
            numbers.append(n)
        }
        self.init(major: numbers[0], minor: numbers.count > 1 ? numbers[1] : 0,
                  patch: numbers.count > 2 ? numbers[2] : 0)
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    /// `"1.0"`, `"1.2.3"`: the patch only when it is not 0.
    public var description: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }
}
