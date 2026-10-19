import DesksetCore
import Foundation

/// Immutable snapshot of a loaded skin's live measures and variables for the `About > Skins` inspector.
/// Built on the skin's executor and delivered to the main thread.
struct SkinDebugState: Equatable {
    static let displayCharacterLimit = 512

    let config: String
    let file: String
    let measures: [MeasureDebugItem]
    let variables: [VariableDebugItem]

    static func truncateForDisplay(_ value: String) -> String {
        guard value.count > displayCharacterLimit else { return value }
        let end = value.index(value.startIndex, offsetBy: displayCharacterLimit)
        return String(value[..<end]) + "..."
    }

    /// Evaluates the live measures and variables of `skin`. Must be called on `skin.executor`.
    static func capture(from skin: Skin) -> SkinDebugState {
        assert(skin.executor.isCurrent, "Debug state must be captured on the skin's executor")
        let measures = skin.measures.map { measure -> MeasureDebugItem in
            let numberText = NumberFormatting.plain(measure.value)
            let fullString = measure.stringValue
            let minText = NumberFormatting.plain(measure.minValue)
            let maxText = NumberFormatting.plain(measure.maxValue)
            let rangeText = "\(minText) \u{2013} \(maxText)"
            return MeasureDebugItem(
                name: measure.name,
                range: rangeText,
                number: numberText,
                displayNumber: truncateForDisplay(numberText),
                string: fullString,
                displayString: truncateForDisplay(fullString),
                isDisabled: measure.disabled,
                isPaused: measure.paused
            )
        }

        var originalCaseByLower: [String: String] = [:]
        for item in skin.inspectedVariables() {
            originalCaseByLower[item.name.lowercased()] = item.name
        }

        let variables = skin.runtimeVariables.compactMap { entry -> VariableDebugItem? in
            if isInternalOrBuiltInVariable(entry.name) {
                return nil
            }
            let displayName = originalCaseByLower[entry.name.lowercased()] ?? entry.name
            return VariableDebugItem(
                name: displayName,
                value: entry.value,
                displayValue: truncateForDisplay(entry.value)
            )
        }

        return SkinDebugState(
            config: skin.config,
            file: skin.fileURL.lastPathComponent,
            measures: measures,
            variables: variables
        )
    }

    private static func isInternalOrBuiltInVariable(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == "currentsection" { return true }
        return BuiltInVariables.isBuiltIn(lower)
    }
}

/// A single measure row in the `About > Skins` inspector.
struct MeasureDebugItem: Equatable {
    let name: String
    let range: String
    /// Full untruncated numeric string for clipboard copy.
    let number: String
    /// Truncated to 512 characters (`...`) for table display.
    let displayNumber: String
    /// Full untruncated string value for clipboard copy.
    let string: String
    /// Truncated to 512 characters (`...`) for table display.
    let displayString: String
    let isDisabled: Bool
    let isPaused: Bool
}

/// A single variable row in the `About > Skins` inspector.
struct VariableDebugItem: Equatable {
    let name: String
    /// Full untruncated variable value for clipboard copy.
    let value: String
    /// Truncated to 512 characters (`...`) for table display.
    let displayValue: String
}

/// Cancellable handle for an in-flight `SkinRuntime.requestDebugState` call.
struct SkinDebugRequestTicket: Equatable {
    fileprivate let id: UInt64

    func cancel() {
        SkinDebugProbe.cancel(self)
    }
}

/// Per-runtime coalescing coordinator ensuring at most one queued debug-state closure exists on any `SkinRuntime`'s
/// executor at a time, and dropping stale results when the selection, tab, or window changes.
enum SkinDebugProbe {
    private final class Slot {
        let key: ObjectIdentifier
        weak var runtime: SkinRuntime?
        var latestTicketID: UInt64 = 0
        var pendingCompletion: ((SkinDebugState) -> Void)?
        var isQueued = false
        var inFlightDeliveries = 0

        init(runtime: SkinRuntime) {
            self.key = ObjectIdentifier(runtime)
            self.runtime = runtime
        }
    }

    private struct Metrics {
        var enqueued = 0
        var evaluated = 0
    }

    private static let lock = NSLock()
    private static var nextTicketID: UInt64 = 0
    private static var slots: [ObjectIdentifier: Slot] = [:]
    private static var ticketSlots: [UInt64: Slot] = [:]
    private static var recordingMetrics = false
    private static var metricsByRuntime: [ObjectIdentifier: Metrics] = [:]

    @discardableResult
    static func request(
        for runtime: SkinRuntime,
        completion: @escaping (SkinDebugState) -> Void
    ) -> SkinDebugRequestTicket {
        // Only touch thread-safe `didClose` on the caller thread; executor-owned `isClosing`/`isClosed` are checked on
        // `runtime.executor` inside `runOnExecutor`.
        guard !runtime.didClose else {
            return SkinDebugRequestTicket(id: 0)
        }

        let key = ObjectIdentifier(runtime)
        var shouldSchedule = false
        let ticketID: UInt64
        let slot: Slot

        lock.lock()
        nextTicketID &+= 1
        ticketID = nextTicketID
        if let existing = slots[key], existing.runtime === runtime {
            slot = existing
            if slot.latestTicketID != 0 {
                ticketSlots.removeValue(forKey: slot.latestTicketID)
            }
        } else {
            // A deallocated runtime's address may be reused before its queued probe drains.
            // Retire that subscription without allowing the old closure to consume the new owner's request.
            if let stale = slots[key] {
                ticketSlots.removeValue(forKey: stale.latestTicketID)
                stale.latestTicketID = 0
                stale.pendingCompletion = nil
            }
            let created = Slot(runtime: runtime)
            slots[key] = created
            slot = created
        }
        slot.latestTicketID = ticketID
        slot.pendingCompletion = completion
        ticketSlots[ticketID] = slot
        if !slot.isQueued {
            slot.isQueued = true
            if recordingMetrics {
                metricsByRuntime[key, default: Metrics()].enqueued += 1
            }
            shouldSchedule = true
        }
        lock.unlock()

        if shouldSchedule {
            runtime.executor.async { [weak runtime] in
                runOnExecutor(slot: slot, runtime: runtime)
            }
        }

        return SkinDebugRequestTicket(id: ticketID)
    }

    static func cancel(_ ticket: SkinDebugRequestTicket) {
        guard ticket.id != 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let slot = ticketSlots.removeValue(forKey: ticket.id) else { return }
        if slot.latestTicketID == ticket.id {
            slot.latestTicketID = 0
            slot.pendingCompletion = nil
        }
        cleanupSlotIfIdleLocked(slot)
    }

    private static func runOnExecutor(slot: Slot, runtime: SkinRuntime?) {
        lock.lock()
        slot.isQueued = false
        let ticketID = slot.latestTicketID
        let hasSubscriber = ticketID != 0 && slot.pendingCompletion != nil
        if !hasSubscriber {
            cleanupSlotIfIdleLocked(slot)
            lock.unlock()
            return
        }
        lock.unlock()

        // On `runtime.executor`: safe to read executor-owned `isClosing`, `isClosed`, and `skin`.
        guard let runtime, !runtime.isClosing, !runtime.isClosed, !runtime.didClose, let skin = runtime.skin else {
            lock.lock()
            if slot.latestTicketID == ticketID {
                ticketSlots.removeValue(forKey: ticketID)
                slot.latestTicketID = 0
                slot.pendingCompletion = nil
            }
            cleanupSlotIfIdleLocked(slot)
            lock.unlock()
            return
        }

        let state = SkinDebugState.capture(from: skin)

        lock.lock()
        if recordingMetrics {
            metricsByRuntime[slot.key, default: Metrics()].evaluated += 1
        }
        guard slot.latestTicketID == ticketID, slot.pendingCompletion != nil else {
            cleanupSlotIfIdleLocked(slot)
            lock.unlock()
            return
        }
        slot.inFlightDeliveries += 1
        lock.unlock()

        if MainSkinExecutor.shared.isCurrent {
            deliver(slot: slot, ticketID: ticketID, runtime: runtime, state: state)
        } else {
            MainSkinExecutor.shared.async { [weak runtime] in
                deliver(slot: slot, ticketID: ticketID, runtime: runtime, state: state)
            }
        }
    }

    private static func deliver(slot: Slot, ticketID: UInt64, runtime: SkinRuntime?, state: SkinDebugState) {
        lock.lock()
        slot.inFlightDeliveries = max(0, slot.inFlightDeliveries - 1)
        // On main thread: only check `runtime.didClose` and ticket identity, never executor-owned `isClosing`/`isClosed`.
        guard let runtime, !runtime.didClose,
              slot.latestTicketID == ticketID,
              let callback = slot.pendingCompletion else {
            if slot.latestTicketID == ticketID {
                ticketSlots.removeValue(forKey: ticketID)
                slot.latestTicketID = 0
                slot.pendingCompletion = nil
            }
            cleanupSlotIfIdleLocked(slot)
            lock.unlock()
            return
        }
        ticketSlots.removeValue(forKey: ticketID)
        slot.latestTicketID = 0
        slot.pendingCompletion = nil
        cleanupSlotIfIdleLocked(slot)
        lock.unlock()
        callback(state)
    }

    private static func cleanupSlotIfIdleLocked(_ slot: Slot) {
        guard !slot.isQueued, slot.pendingCompletion == nil, slot.inFlightDeliveries == 0 else { return }
        if slots[slot.key] === slot {
            slots.removeValue(forKey: slot.key)
        }
    }

    // MARK: Self-test inspection

    static var activeSlotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return slots.count
    }

    static var activeTicketCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return ticketSlots.count
    }

    static func setTestMetricsRecording(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        recordingMetrics = enabled
        if !enabled {
            metricsByRuntime.removeAll()
        }
    }

    static func testCounters(for runtime: SkinRuntime) -> (enqueued: Int, evaluated: Int, isQueued: Bool) {
        let key = ObjectIdentifier(runtime)
        lock.lock()
        defer { lock.unlock() }
        let m = metricsByRuntime[key] ?? Metrics()
        let queued = slots[key]?.isQueued ?? false
        return (m.enqueued, m.evaluated, queued)
    }

    static func resetTestCounters() {
        lock.lock()
        defer { lock.unlock() }
        metricsByRuntime.removeAll()
    }
}

extension SkinRuntime {
    /// Requests an asynchronous snapshot of the skin's live measures and variables on its executor, coalescing
    /// concurrent requests for the same runtime so at most one closure is queued on its executor at a time.
    @discardableResult
    func requestDebugState(completion: @escaping (SkinDebugState) -> Void) -> SkinDebugRequestTicket {
        SkinDebugProbe.request(for: self, completion: completion)
    }
}
