/// Live, owner-confined services used by a section's option reads and bookkeeping.
/// Skin supplies them directly so queries keep their current state and synchronous timing.
protocol SectionContext: AnyObject {
    var settings: SkinSettings { get }
    var sources: IniSourceMap { get }
    var optionsLoaded: Bool { get }
    var runsInVirtualTime: Bool { get }
    var measureValues: MeasureValueOverride? { get }

    func styleSection(named name: String) -> IniSection?
    func styleValues(named name: String) -> [String: String]?
    func resolve(_ text: String, in section: SkinSection?, sectionVariables: Bool) -> String
    func resolveStandardVariables(_ text: String, in section: SkinSection?) -> String
    func mentionsSectionVariable(_ text: String) -> Bool
    func noteSnapshotChange()
    func assertOwned(_ entry: StaticString)
    func log(_ message: String, level: SkinLogLevel)
    func formulaValue(of identifier: String, from section: SkinSection?) -> Double?
    func noteService(_ kind: BackgroundWorkKind)
    func execute(_ actionText: String, from section: SkinSection?)
}

extension Skin: SectionContext {}
