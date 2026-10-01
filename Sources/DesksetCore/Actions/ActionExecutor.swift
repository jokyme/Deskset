import Foundation

/// Routes and applies one already-resolved bang synchronously. The caller retains its existing action, policy
/// and lifecycle boundaries. No later action is parsed or evaluated here, and no live target is retained.
internal enum ActionExecutor {
    enum Route: Equatable, Sendable {
        case ignored
        case host(Bang)
        case local(ResolvedLocalAction)
        case forward(Bang, toConfig: String)
        case localThenForward(ResolvedLocalAction, forwarding: Bang, toConfig: String)
    }

    static func route(_ bang: Bang, currentConfig: String, literalArguments: Set<Int>) -> Route {
        let definition = ActionCatalog.definition(for: bang.name)
        guard case .local(let operation)? = definition else {
            return definition == .delayRunOnly ? .ignored : .host(bang)
        }
        var args = bang.args
        if let definition = BangCatalog.definition(for: bang.name), let configIndex = definition.configParameterIndex {
            let target = definition.configArgument(in: args)
            if args.count > configIndex { args = Array(args.prefix(configIndex)) }
            if let target, !isOwnConfig(target, currentConfig: currentConfig) {
                let local = Bang(name: bang.name, args: args)
                if target == "*" {
                    return .localThenForward(lower(operation, args: args, literal: literalArguments),
                                             forwarding: local, toConfig: "*")
                } else {
                    return .forward(local, toConfig: target)
                }
            }
        }
        return .local(lower(operation, args: args, literal: literalArguments))
    }

    static func perform(_ bang: Bang, literalArguments: Set<Int>, on target: any ActionTarget) {
        switch route(bang, currentConfig: target.config, literalArguments: literalArguments) {
        case .ignored:
            return
        case .host(let bang):
            target.handleHostAction(bang)
        case .local(let action):
            target.performLocalAction(action)
        case .forward(let bang, let config):
            target.forwardAction(bang, toConfig: config)
        case .localThenForward(let action, let bang, let config):
            target.performLocalAction(action)
            // The target reads its current host here, even when the local operation replaced it or closed.
            target.forwardAction(bang, toConfig: config)
        }
    }

    private static func lower(_ operation: ActionCatalog.LocalOperation, args: [String],
                              literal: Set<Int>) -> ResolvedLocalAction {
        func arg(_ i: Int) -> String { i < args.count ? args[i] : "" }
        func value(_ i: Int) -> ActionValue { ActionValue(text: arg(i), isLiteral: literal.contains(i)) }
        func selection(_ kind: ActionSelection.Kind, _ i: Int) -> ActionSelection {
            switch kind {
            case .name: return .name(arg(i))
            case .group: return .group(arg(i))
            }
        }
        switch operation {
        case .setOption(let kind):
            return .setOption(target: selection(kind, 0), key: arg(1), value: value(2))
        case .setVariable:
            return .setVariable(name: arg(0), value: value(1))
        case .writeKeyValue:
            return .writeKeyValue(section: arg(0), key: arg(1), value: value(2), file: arg(3))
        case .update:
            return .update
        case .redraw:
            return .redraw
        case .updateMeter(let kind):
            return .updateMeter(selection(kind, 0))
        case .updateMeasure(let kind):
            return .updateMeasure(selection(kind, 0))
        case .moveMeter:
            return .moveMeter(name: arg(2), x: arg(0), y: arg(1))
        case .meterHidden(let change, let kind):
            return .meterHidden(change, target: selection(kind, 0))
        case .measureDisabled(let change, let kind):
            return .measureDisabled(change, target: selection(kind, 0))
        case .measurePaused(let change, let kind):
            return .measurePaused(change, target: selection(kind, 0))
        case .commandMeasure:
            return .commandMeasure(name: arg(0), command: arg(1))
        case .legacyPluginBang:
            // Deprecated form of !CommandMeasure; also written as one argument "Measure Arguments".
            if args.count >= 2 {
                return .commandMeasure(name: arg(0), command: arg(1))
            } else {
                let parts = arg(0).trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                return .commandMeasure(name: parts.first.map(String.init) ?? "",
                                       command: parts.count > 1 ? String(parts[1]) : "")
            }
        case .mouseAction(let operation, .name):
            return .mouseAction(operation, target: .name(arg(0)), actions: arg(1))
        case .mouseAction(let operation, .group):
            return .mouseAction(operation, target: .group(arg(1)), actions: arg(0))
        case .log:
            let level: SkinLogLevel
            switch arg(1).trimmingCharacters(in: .whitespaces).lowercased() {
            case "warning": level = .warning
            case "error": level = .error
            case "debug": level = .debug
            default: level = .notice
            }
            return .log(message: arg(0), level: level)
        }
    }

    private static func isOwnConfig(_ name: String, currentConfig: String) -> Bool {
        let normalized = name.replacingOccurrences(of: "/", with: "\\")
        return normalized.caseInsensitiveCompare(currentConfig) == .orderedSame
    }
}
