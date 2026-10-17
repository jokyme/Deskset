import Foundation

/// How serious a diagnostic is. `error`: the construct is dropped and the rest of the widget runs. `warning`: it runs
/// as written but is probably wrong or wasteful. `info`: a tip, shown lightly and never counted as a problem.
public enum Severity: String, Sendable, Hashable, CaseIterable {
    case error, warning, info
}
