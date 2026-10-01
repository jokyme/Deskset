import Foundation

/// Live, owner-confined services used by a section's option reads, measurements and bookkeeping.
/// Skin supplies them directly so queries keep their current state and synchronous timing.
protocol SectionContext: AnyObject {
    var settings: SkinSettings { get }
    var sources: IniSourceMap { get }
    var optionsLoaded: Bool { get }
    var runsInVirtualTime: Bool { get }
    var measureValues: MeasureValueOverride? { get }
    var host: SkinHost? { get }
    var system: SystemDataSource { get }
    var counter: Int { get }
    var random: SkinRandom { get }
    var skinClock: SkinClock { get }
    var clock: () -> TimeInterval { get }
    var executor: SkinExecutor { get }
    var locale: Locale { get }
    var directory: URL { get }
    var sideEffects: SideEffects { get }

    func styleSection(named name: String) -> IniSection?
    func styleValues(named name: String) -> [String: String]?
    func resolve(_ text: String, in section: SkinSection?, sectionVariables: Bool) -> String
    func resolveStandardVariables(_ text: String, in section: SkinSection?) -> String
    func mentionsSectionVariable(_ text: String) -> Bool
    func noteSnapshotChange()
    func assertOwned(_ entry: StaticString)
    func log(_ message: String, level: SkinLogLevel)
    func logOnce(_ message: String, level: SkinLogLevel)
    func addIssue(_ issue: String)
    func removeIssue(_ issue: String)
    func currentEnvironment() -> SkinEnvironment
    func readablePath(_ path: String) -> String
    func formulaValue(of identifier: String, from section: SkinSection?) -> Double?
    func noteService(_ kind: BackgroundWorkKind)
    func execute(_ actionText: String, from section: SkinSection?)
    func executePointerAction(_ action: String, from section: SkinSection, x: Double, y: Double,
                              relativeToSkin: Bool)
    func async(_ work: @escaping () -> Void)
    func startBackground<T>(_ job: BackgroundJob<T>, then completion: @escaping (T) -> Void,
                            orElse dropped: ((T) -> Void)?)
}

extension SectionContext {
    func startBackground<T>(_ job: BackgroundJob<T>, then completion: @escaping (T) -> Void) {
        startBackground(job, then: completion, orElse: nil)
    }
}

extension Skin: SectionContext {}

extension Skin {
    /// The current host for app services whose existing hook takes a skin instead of a section.
    package var serviceHost: SkinHost? { (self as any SectionContext).host }
}
