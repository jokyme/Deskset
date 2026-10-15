/// A reusable source template. Only source syntax is retained: evaluation supplies current lookups and
/// creates its own expansion state. Standard substitutions can generate new bracket syntax, so nested and
/// classic section references still pass through the shared evaluator after the standard stage.
package struct Template: Equatable, Sendable {
    package let source: String
    let bytes: [UInt8]
    let standard: StandardPlan

    package init(_ source: String) {
        self.source = source
        bytes = Array(source.utf8)
        standard = StandardPlan(bytes)
    }

    /// Every possible standard opener, including ones inside another candidate. A failed lookup leaves its
    /// closing delimiter available to open the next reference; only evaluation knows which candidates to skip.
    struct StandardPlan: Equatable, Sendable {
        struct Reference: Equatable, Sendable {
            let start: Int
            let end: Int
        }

        let references: [Reference]
        let hasHash: Bool
        let hasDollar: Bool
        let hasBracket: Bool

        init(_ bytes: [UInt8]) {
            var nextHash: Int?
            var nextDollar: Int?
            var bracket = false
            var found: [Reference] = []
            for i in bytes.indices.reversed() {
                switch bytes[i] {
                case VarByte.hash:
                    if let end = nextHash { found.append(Reference(start: i, end: end)) }
                    nextHash = i
                case VarByte.dollar:
                    if let end = nextDollar { found.append(Reference(start: i, end: end)) }
                    nextDollar = i
                case VarByte.open:
                    bracket = true
                default:
                    break
                }
            }
            references = found.reversed()
            hasHash = nextHash != nil
            hasDollar = nextDollar != nil
            hasBracket = bracket
        }
    }
}
