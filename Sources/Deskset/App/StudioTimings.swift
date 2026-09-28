import Foundation
import os

/// Where the time of a Studio step goes (design §9.5): the phases of the Studio's last reload, measured as it runs, for
/// `EditingSession.lastTimings` and the "App: studio latency" suite.
///
/// Phases (milliseconds): `studio.patch` (the step given to the running instance, `Skin.patch(sources:)`; also timed
/// when it had to load again instead), `studio.reload` (loading the Studio's instance again instead, with its parts
/// `studio.load` — reading it from the text in memory — and `studio.update`, its first update), `window` (the Studio
/// window following the instance), and `window.<part>` for each part of that (`InspectorWindowController.attachParts`:
/// widget, canvas, layers, inspector, live values, code).
final class StudioPhaseClock {
    private(set) var phases: [String: Double] = [:]

    /// Runs `work`, adding its time to `phase`.
    func measure<T>(_ phase: String, _ work: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { phases[phase, default: 0] += Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e6 }
        return try work()
    }

    /// A new reload starts: what the last one took is forgotten.
    func reset() { phases = [:] }

    /// Adds times measured elsewhere (or before a `reset`).
    func add(_ times: [String: Double]) {
        for (phase, time) in times { phases[phase, default: 0] += time }
    }

    /// What was measured since the last reset, which it now is.
    func take() -> [String: Double] {
        defer { phases = [:] }
        return phases
    }

    /// Runs one part of the Studio window following a reload, as `window.<label>`, inside its signpost.
    func run(windowPart part: MainThreadSteps.Step) {
        measure("window." + part.label) { StudioSignposts.windowPart(part.label, part.work) }
    }
}

/// The Studio's signposts, for Instruments (subsystem app.deskset.Deskset, category Studio): `inspector.update`,
/// `layers.update`, `code.sync` (the window following a reload) and `canvas.paint` (each draw of the canvas), next to
/// the editing session's own (`edit.plan`, `runtime.apply`, `disk.flush`, `desktop.refresh`).
enum StudioSignposts {
    static let signposter = OSSignposter(subsystem: "app.deskset.Deskset", category: "Studio")

    /// Runs `work` inside the interval `name`.
    static func interval<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try work()
    }

    /// Runs a part of the window following a reload inside its interval, when it has one.
    static func windowPart<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        switch label {
        case "inspector": return try interval("inspector.update", work)
        case "layers": return try interval("layers.update", work)
        case "code": return try interval("code.sync", work)
        default: return try work()
        }
    }
}
