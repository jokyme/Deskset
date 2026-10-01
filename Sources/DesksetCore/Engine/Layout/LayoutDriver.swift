import Foundation

/// Owns the existing Skin layout schedule. Skin owns this object; it holds no Skin, Meter or escaping callback.
/// Every pass has a local cursor, so an action or option read can synchronously re-enter layout without replacing
/// the outer pass's cursor. The current adapter still operates on Skin meters, on their owner.
final class LayoutDriver {
    private var pending = false
    private var framesReady = false
    private var sizeComputed = false

    /// Loading only resets frame readiness, as the original Skin load path did.
    func resetFrameReadiness() { framesReady = false }

    func markPending() { pending = true }

    func layoutIfPending(_ body: () -> Void) {
        if pending { body() }
    }

    /// Updates and places meters in file order. The callback is synchronous and is never retained. False means an
    /// action closed the skin: no remaining placements, readiness changes or size calculation are performed.
    func updateMeterPass(in skin: Skin, updateMeter: (Meter) -> Void) -> Bool {
        resolveContainers(in: skin)
        var needsSecondPass = false
        var placement = Cursor()
        for m in skin.meters {
            if m.consumeUpdateTick() { updateMeter(m) }
            if skin.isClosed { return false }
            if placement.place(m) { needsSecondPass = true }
        }
        framesReady = true
        // Keep the original extra layoutMeters call, including its own second pass for a later container.
        if needsSecondPass { layoutMeters(in: skin) }
        pending = false
        return true
    }

    /// The public Skin.layout wrapper still owns its assert/work boundary and the following size calculation.
    func layout(in skin: Skin) {
        pending = false
        resolveContainers(in: skin)
        layoutMeters(in: skin)
    }

    /// Before the first update, geometry readers get provisional frames without fixing the window size early.
    func ensureMeterGeometry(in skin: Skin) {
        guard !framesReady, !skin.isClosed else { return }
        // Set before option reads: inline Lua or another section variable may ask for geometry synchronously.
        framesReady = true
        if !skin.optionsLoaded {
            for m in skin.meters where m.needsOptionRead { m.readOptionsIfNeeded() }
        }
        for m in skin.meters { m.prepareProvisionalLayout() }
        resolveContainers(in: skin)
        layoutMeters(in: skin)
    }

    /// Original relative-position cursor. References deliberately read current geometry after nested actions; a
    /// cached Output could be stale when a later meter's OnUpdateAction moves an already placed meter.
    private struct Cursor {
        var previous: Meter?
        var previousContent: [ObjectIdentifier: Meter] = [:]
        var placed: Set<ObjectIdentifier> = []

        mutating func place(_ m: Meter) -> Bool {
            var stale = false
            if let c = m.container {
                let key = ObjectIdentifier(c)
                m.layout(after: previousContent[key], in: c)
                previousContent[key] = m
                stale = !placed.contains(key)
            } else {
                m.layout(after: previous)
                previous = m
            }
            placed.insert(ObjectIdentifier(m))
            return stale
        }
    }

    private func layoutMeters(in skin: Skin) {
        framesReady = true
        var needsSecondPass = false
        var state = Cursor()
        for m in skin.meters where state.place(m) { needsSecondPass = true }
        if needsSecondPass {
            state = Cursor()
            for m in skin.meters { _ = state.place(m) }
        }
    }

    /// Validates Container names at the original call sites, before an ordinary update reads dynamic options.
    private func resolveContainers(in skin: Skin) {
        var anyContainer = false
        for m in skin.meters where !m.containerName.isEmpty {
            anyContainer = true
            break
        }
        guard anyContainer || skin.meters.contains(where: { $0.container != nil || $0.isContainer }) else { return }
        // Assign once each; the snapshot follows these setters. Read skin.meters again at the original defer point.
        var containers: Set<ObjectIdentifier> = []
        defer { for m in skin.meters { m.isContainer = containers.contains(ObjectIdentifier(m)) } }
        for m in skin.meters {
            guard !m.containerName.isEmpty else {
                m.container = nil
                continue
            }
            if let target = skin.meter(named: m.containerName), target !== m, target.containerName.isEmpty {
                m.container = target
                containers.insert(ObjectIdentifier(target))
            } else {
                m.container = nil
                skin.logOnce("Container=\(m.containerName) on [\(m.name)] is invalid (missing, itself, or nested)",
                             level: .warning)
            }
        }
    }

    /// Returns a new window size only at the original size-policy points. Background resources are queried after
    /// the frames have been read, then the current fixed dimensions are read. The callback is never stored.
    func windowSize(in skin: Skin, force: Bool = false,
                    backgroundSize: () -> (width: Double, height: Double)?) -> SkinSize? {
        guard force || !sizeComputed || skin.settings.dynamicWindowSize else { return nil }
        guard skin.updateCount > 0 else { return nil }
        sizeComputed = true
        let extent = RainmeterLayout.extentFromOrigin(
            skin.meters.lazy.filter { !$0.hidden && $0.container == nil }.map(\.frame))
        let background = backgroundSize().map { SkinSize(width: $0.width, height: $0.height) }
        return RainmeterLayout.windowSize(extent: extent, background: background,
                                          fixedWidth: skin.settings.skinWidth, fixedHeight: skin.settings.skinHeight)
    }

    func contentBounds(in skin: Skin, backgroundSize: () -> (width: Double, height: Double)?) -> SkinRect {
        let frames = visibleFrames(in: skin)
        let background = backgroundSize().map { SkinSize(width: $0.width, height: $0.height) }
        return RainmeterLayout.contentBounds(frames, background: background)
    }

    private func visibleFrames(in skin: Skin) -> [SkinRect] {
        skin.meters.compactMap { meter in
            guard !meter.hidden && meter.container == nil else { return nil }
            return meter.frame
        }
    }
}
