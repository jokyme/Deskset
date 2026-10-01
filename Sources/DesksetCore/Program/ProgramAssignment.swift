/// A compiled assignment to a session variable's original declaration occurrence. The shared executor reads
/// its expression at effect time; no source syntax, legacy variable text or host resource is retained here.
public struct ProgramAssignment: Equatable, Sendable {
    public let declaration: Int
    public let value: ProgramExpression

    public init(declaration: Int, value: ProgramExpression) {
        self.declaration = declaration
        self.value = value
    }
}
