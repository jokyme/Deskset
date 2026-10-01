import Foundation

/// Routes one already-resolved bang. Skin performs the result synchronously, retaining its existing action,
/// policy and lifecycle boundaries. No later action is parsed or evaluated here.
internal enum ActionExecutor {
    enum Route: Equatable, Sendable {
        case ignored
        case host(Bang)
        case local(Bang)
        case forward(Bang, toConfig: String)
        case localThenForward(Bang, toConfig: String)
    }

    static func route(_ bang: Bang, currentConfig: String) -> Route {
        let handler = ActionCatalog.handler(for: bang.name)
        guard handler == .engineLocal else {
            return handler == .delayRunOnly ? .ignored : .host(bang)
        }
        var args = bang.args
        if let definition = BangCatalog.definition(for: bang.name), let configIndex = definition.configParameterIndex {
            let target = definition.configArgument(in: args)
            if args.count > configIndex { args = Array(args.prefix(configIndex)) }
            if let target, !isOwnConfig(target, currentConfig: currentConfig) {
                let local = Bang(name: bang.name, args: args)
                if target == "*" {
                    return .localThenForward(local, toConfig: "*")
                } else {
                    return .forward(local, toConfig: target)
                }
            }
        }
        return .local(Bang(name: bang.name, args: args))
    }

    private static func isOwnConfig(_ name: String, currentConfig: String) -> Bool {
        let normalized = name.replacingOccurrences(of: "/", with: "\\")
        return normalized.caseInsensitiveCompare(currentConfig) == .orderedSame
    }

}
