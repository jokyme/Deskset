/// One ordered primary-click statement. Core resolves these values without calling host services.
public enum ProgramAction: Equatable, Sendable {
    case assign(ProgramAssignment)
    case copy(ProgramExpression)
    case open(ProgramExpression)

    var expression: ProgramExpression {
        switch self {
        case .assign(let assignment): return assignment.value
        case .copy(let value), .open(let value): return value
        }
    }
}

/// A frozen request for the host. Returning an effect does not execute clipboard or opening operations.
public enum ProgramEffect: Equatable, Sendable {
    case copy(String)
    case open(String)
}

/// A successful click transaction. Scene publication and external execution remain the host's responsibility.
/// Failed expression evaluation or projection returns no result and commits neither variables nor effects.
public struct ProgramClickResult: Sendable {
    public let scene: WidgetScene
    public let effects: [ProgramEffect]

    public init(scene: WidgetScene, effects: [ProgramEffect]) {
        self.scene = scene
        self.effects = effects
    }
}
