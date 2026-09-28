import Foundation

/// What a running instance of a widget has shown so far that its files do not say, as a value: the Calc `Counter`,
/// variables set while it runs (a page turned by a click, a theme picked), what its measures have seen (their values,
/// the samples they average, the range they observed, what a WebParser read) and the samples of its Line and Histogram
/// graphs. Taken on the thread that owns the instance (`Skin.runtimeState`), it can go to another thread and seed a new
/// instance of the same widget there (`Skin.seed(from:)`, `Skin.seedGraphs(from:)`).
///
/// The Studio seeds its own instance of a widget with it: from the widget on the desktop when it opens (the canvas then
/// shows the month the desktop shows, the graphs it drew, the page it downloaded, without fetching it again), and from
/// its previous instance when a step has to load the widget again.
///
/// Not carried (judgment calls): `!SetOption` values and meters hidden or shown by bangs — a widget sets these from
/// hover actions all the time, and the pointer is over the widget when the Studio is opened from it — and the state of
/// measures of other kinds (a Loop's position, a script's own variables).
public struct SkinRuntimeState: Equatable {
    /// How the instance seeded with the state goes on from the one it was taken from.
    public enum Relation: Equatable {
        /// The source keeps running beside it (the widget on the desktop): the first update of the new instance
        /// computes the `Counter` the source's last update computed, so both show the same.
        case mirror
        /// The new instance replaces the source (the Studio's instance loaded again): the counting goes on.
        case successor
    }

    /// What is taken.
    public struct Parts: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let counter = Parts(rawValue: 1)
        public static let variables = Parts(rawValue: 2)
        public static let measures = Parts(rawValue: 4)
        public static let graphs = Parts(rawValue: 8)
        public static let all: Parts = [.counter, .variables, .measures, .graphs]
    }

    /// A variable whose value while the skin ran differs from what its files define (`!SetVariable`).
    public struct Variable: Equatable {
        public var value: String
        /// Its definition in `[Variables]` when the value was taken (nil: not defined there).
        public var definition: String?
    }

    /// The samples a measure averages (`AverageSize`), oldest first as stored, and where the next one goes.
    public struct Average: Equatable {
        public var samples: [Double]
        public var next: Int
    }

    /// What a WebParser measure read: the result it shows and its captures, and — for a parent whose last page
    /// arrived — where it is in its `UpdateRate` cycle, so the new instance fetches when the source would.
    public struct WebParser: Equatable {
        public var result: String
        public var number: Double
        public var captures: [String]
        public var substringCount: Int
        public var observedMin: Double
        public var observedMax: Double
        public var updateCounter: Int?
    }

    /// What a measure has seen. It seeds a measure of the same name, type and class whose own options are written the
    /// same way and read the same variable definitions.
    public struct MeasureState: Equatable {
        /// `Measure.type`.
        public var type: String
        /// The class that runs it.
        public var kind: String
        /// Its own options as written.
        public var own: IniSection
        public var value: Double
        public var rawString: String?
        public var average: Average?
        public var observedMin: Double?
        public var observedMax: Double?
        public var webParser: WebParser?
    }

    /// The samples of a graph meter.
    public enum Graph: Equatable {
        /// A Line meter's lines, in order.
        case line([GraphHistory])
        case histogram(primary: GraphHistory, secondary: GraphHistory)
    }

    public var relation: Relation
    /// The Calc `Counter` (nil: not taken).
    public var counter: Int?
    /// Variables changed while the skin ran, by lowercased name.
    public var variables: [String: Variable] = [:]
    /// Every `[Variables]` definition of the source, by lowercased name (to tell which ones a measure's options read
    /// differently now).
    public var definitions: [String: String] = [:]
    /// Measures by lowercased name.
    public var measures: [String: MeasureState] = [:]
    /// Line and Histogram meters by lowercased name.
    public var graphs: [String: Graph] = [:]

    public init(relation: Relation, counter: Int? = nil) {
        self.relation = relation
        self.counter = counter
    }
}

extension GraphHistory: Equatable {
    public static func == (a: GraphHistory, b: GraphHistory) -> Bool {
        a.capacity == b.capacity && a.samples == b.samples
    }
}

extension Skin {
    /// What this instance has shown so far (`SkinRuntimeState`), for a new instance of the widget that goes on from it
    /// (`relation`). On the thread that owns the skin.
    public func runtimeState(as relation: SkinRuntimeState.Relation,
                             including parts: SkinRuntimeState.Parts = .all) -> SkinRuntimeState {
        assertOwned()
        var state = SkinRuntimeState(relation: relation, counter: parts.contains(.counter) ? counter : nil)
        if parts.contains(.variables) || parts.contains(.measures) {
            let (values, definitions) = runtimeVariables
            state.definitions = definitions
            if parts.contains(.variables) {
                for (key, value) in values where definitions[key] != value {
                    state.variables[key] = SkinRuntimeState.Variable(value: value, definition: definitions[key])
                }
            }
        }
        if parts.contains(.measures) {
            for measure in measures {
                let key = measure.name.lowercased()
                guard state.measures[key] == nil else { continue }
                var s = measure.runtimeSnapshot
                if let parser = measure as? WebParserMeasure { s.webParser = parser.runtimeWebParserState }
                state.measures[key] = s
            }
        }
        if parts.contains(.graphs) {
            for meter in meters {
                let key = meter.name.lowercased()
                if let line = meter as? LineMeter {
                    state.graphs[key] = .line(line.lines.map(\.history))
                } else if let histogram = meter as? HistogramMeter {
                    state.graphs[key] = .histogram(primary: histogram.primaryHistory,
                                                   secondary: histogram.secondaryHistory)
                }
            }
        }
        return state
    }

    /// Seeds this instance, loaded and not updated yet, with what another instance of the widget has shown (`state`):
    /// the Calc `Counter`, the variables set while it ran — each one only while its definition in the files is still
    /// the one it was set over — and the state of each measure of the same name, type and class whose own options are
    /// written the same way and read no variable defined differently now. Its first update then goes on from there.
    /// The graphs follow after that update (`seedGraphs(from:)`). On the thread that owns the skin.
    public func seed(from state: SkinRuntimeState) {
        assertOwned()
        if let counter = state.counter { seedCounter(counter, mirroring: state.relation == .mirror) }
        let defined = runtimeVariables.definitions
        for (key, variable) in state.variables where defined[key] == variable.definition {
            seedVariable(key, variable.value)
        }
        guard !state.measures.isEmpty else { return }
        // Variables whose definition is not the one the source read: a measure whose options use one reads another
        // value now (a WebParser's URL), so it starts afresh.
        let redefined = Set(Set(defined.keys).union(state.definitions.keys).filter { defined[$0] != state.definitions[$0] })
        for measure in measures {
            guard let s = state.measures[measure.name.lowercased()], s.type == measure.type,
                  s.kind == String(describing: Swift.type(of: measure)), s.own == measure.own,
                  !measure.own.entries.contains(where: { Skin.mentions($0.value, redefined) }) else { continue }
            measure.seed(s)
            if let parser = measure as? WebParserMeasure, let w = s.webParser { parser.seed(webParser: w) }
        }
    }

    /// Seeds the Line and Histogram meters with the samples of the meters of the same name and kind in `state`, after
    /// this instance's first update (which already added a sample of its own): the graphs show what the source showed.
    /// On the thread that owns the skin.
    public func seedGraphs(from state: SkinRuntimeState) {
        assertOwned()
        guard !state.graphs.isEmpty else { return }
        for meter in meters {
            switch state.graphs[meter.name.lowercased()] {
            case .line(let histories)?:
                (meter as? LineMeter)?.seedHistory(histories)
            case .histogram(let primary, let secondary)?:
                (meter as? HistogramMeter)?.seedHistory(primary: primary, secondary: secondary)
            case nil:
                continue
            }
        }
    }

    /// Takes the graphs of an instance of the same widget that is already running: the samples of every Line and
    /// Histogram meter of the same name and kind. Both skins must be owned by the calling thread.
    public func takeGraphs(from running: Skin) {
        seedGraphs(from: running.runtimeState(as: .mirror, including: .graphs))
    }
}
