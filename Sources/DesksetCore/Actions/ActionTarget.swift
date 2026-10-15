/// A selector is resolved against the target's current sections when the action is applied.
internal enum ActionSelection: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case name, group }
    case name(String)
    case group(String)
}

internal enum ActionStateChange: Equatable, Sendable {
    case set(Bool)
    case toggle
}

/// Resolution of variables has already happened; formula evaluation remains an effect-time operation.
internal struct ActionValue: Equatable, Sendable {
    let text: String
    let isLiteral: Bool
}

internal enum ActionMouseOperation: String, Equatable, Sendable {
    case disable = "disablemouseaction"
    case clear = "clearmouseaction"
    case enable = "enablemouseaction"
    case toggle = "togglemouseaction"
}

/// Named operands for the engine's local bangs. Text retained here (including coordinates and formulas) is read
/// by the same option/formula helpers as before; packing an action never reads or changes a live section.
internal enum ResolvedLocalAction: Equatable, Sendable {
    case setOption(target: ActionSelection, key: String, value: ActionValue)
    case setVariable(name: String, value: ActionValue)
    case writeKeyValue(section: String, key: String, value: ActionValue, file: String)
    case update
    case redraw
    case updateMeter(ActionSelection)
    case updateMeasure(ActionSelection)
    case moveMeter(name: String, x: String, y: String)
    case meterHidden(ActionStateChange, target: ActionSelection)
    case measureDisabled(ActionStateChange, target: ActionSelection)
    case measurePaused(ActionStateChange, target: ActionSelection)
    case commandMeasure(name: String, command: String)
    case mouseAction(ActionMouseOperation, target: ActionSelection, actions: String)
    case log(message: String, level: SkinLogLevel)
}

/// Borrowed synchronously for one action. Ownership, policy, and lifecycle remain the caller's responsibility.
internal protocol ActionTarget: AnyObject {
    var config: String { get }
    func performLocalAction(_ action: ResolvedLocalAction)
    func handleHostAction(_ bang: Bang)
    func forwardAction(_ bang: Bang, toConfig: String)
}
