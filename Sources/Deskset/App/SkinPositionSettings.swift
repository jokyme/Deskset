import AppKit

/// The existing WindowX/Y representation controls, shared by Manage and the skin's Position menu.
enum SkinPositionSettings {
    enum Change {
        case monitor(Int?)
        case automaticMonitor(Bool)
        case fromRight(Bool)
        case fromBottom(Bool)
        case xAsPercentage(Bool)
        case yAsPercentage(Bool)
    }

    struct Result {
        var state: SkinState
        var destination: (x: Double, y: Double)?
    }

    static func applying(_ change: Change, to original: SkinState, position: (x: Double, y: Double),
                         size: CGSize, screens: [WindowGeometry.Screen], zoomFactor: Double) -> Result {
        var state = original
        // A representation edit must not commit a session-only drag when SavePosition is off.
        let saved = WindowPosition.resolve(x: original.windowX ?? "0", y: original.windowY ?? "0",
            anchorX: original.anchorX ?? "0", anchorY: original.anchorY ?? "0", skinSize: size,
            screens: screens, zoomFactor: zoomFactor)
        let reference = !original.savePosition
            ? ((original.windowX != nil || original.windowY != nil ? saved : nil)
                ?? (original.x.flatMap { x in original.y.map { (x: x, y: $0) } }) ?? position)
            : position
        let fallback = WindowPosition.moved(x: reference.x, y: reference.y, windowX: original.windowX,
            windowY: original.windowY, anchorX: original.anchorX, anchorY: original.anchorY,
            skinSize: size, screens: screens, autoSelectScreen: false, zoomFactor: zoomFactor)
        let rawX = original.windowX ?? fallback.x
        let rawY = original.windowY ?? fallback.y
        var x = WindowPosition.parse(rawX, endLetter: "R") ?? .init(value: 0)
        var y = WindowPosition.parse(rawY, endLetter: "B") ?? .init(value: 0)
        var destination: (x: Double, y: Double)?
        switch change {
        case .monitor(let monitor):
            if let monitor, !(0...32).contains(monitor) { return Result(state: original) }
            state.autoSelectScreen = false
            state.windowX = replacingMonitor(in: rawX, with: monitor)
            state.windowY = replacingMonitor(in: rawY, with: monitor)
            // Keep the live screen-relative offset when selecting another monitor. Saved coordinates remain
            // separate from a session-only move; normal KeepOnScreen handling is applied by the window.
            let live = WindowPosition.moved(x: position.x, y: position.y, windowX: rawX, windowY: rawY,
                anchorX: state.anchorX, anchorY: state.anchorY, skinSize: size, screens: screens,
                autoSelectScreen: false, zoomFactor: zoomFactor)
            destination = WindowPosition.resolve(x: replacingMonitor(in: live.x, with: monitor),
                y: replacingMonitor(in: live.y, with: monitor), anchorX: state.anchorX ?? "0",
                anchorY: state.anchorY ?? "0", skinSize: size, screens: screens, zoomFactor: zoomFactor)
        case .automaticMonitor(let enabled):
            state.autoSelectScreen = enabled
            if enabled, let index = WindowGeometry.screenIndex(for: WindowGeometry.frame(
                topLeftX: position.x, y: position.y, size: size,
                primaryHeight: WindowGeometry.primaryHeight(screens)), screens: screens), index < 32 {
                x.screen = index + 1
                y.screen = index + 1
                let encoded = WindowPosition.moved(x: reference.x, y: reference.y,
                    windowX: x.expression(endLetter: "R"), windowY: y.expression(endLetter: "B"),
                    anchorX: state.anchorX, anchorY: state.anchorY, skinSize: size, screens: screens,
                    autoSelectScreen: false, zoomFactor: zoomFactor)
                state.windowX = encoded.x
                state.windowY = encoded.y
            }
        case .fromRight(let enabled), .xAsPercentage(let enabled):
            if case .fromRight = change { x.fromEnd = enabled } else { x.percent = enabled }
            state.windowX = WindowPosition.moved(x: reference.x, y: reference.y,
                windowX: x.expression(endLetter: "R"), windowY: rawY, anchorX: state.anchorX,
                anchorY: state.anchorY, skinSize: size, screens: screens, autoSelectScreen: false,
                zoomFactor: zoomFactor).x
            state.windowY = original.windowY ?? fallback.y
        case .fromBottom(let enabled), .yAsPercentage(let enabled):
            if case .fromBottom = change { y.fromEnd = enabled } else { y.percent = enabled }
            state.windowY = WindowPosition.moved(x: reference.x, y: reference.y,
                windowX: rawX, windowY: y.expression(endLetter: "B"), anchorX: state.anchorX,
                anchorY: state.anchorY, skinSize: size, screens: screens, autoSelectScreen: false,
                zoomFactor: zoomFactor).y
            state.windowX = original.windowX ?? fallback.x
        }
        return Result(state: state, destination: destination)
    }

    /// Changing the display directive retains a formula and all other modifiers verbatim.
    private static func replacingMonitor(in raw: String, with monitor: Int?) -> String {
        let expression = raw.lastIndex(of: "@").map { String(raw[..<$0]) } ?? raw
        return expression.trimmingCharacters(in: .whitespaces) + (monitor.map { "@\($0)" } ?? "")
    }
}
