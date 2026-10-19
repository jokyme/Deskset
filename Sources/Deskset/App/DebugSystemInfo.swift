import AppKit

/// Value-only rows shared by the Debug window's display and network pages and their clipboard actions.
enum DebugSystemInfo {
    struct Field: Equatable {
        var label: String
        var value: String
    }

    struct Group: Equatable {
        var title: String
        var fields: [Field]
    }

    struct DisplaySnapshot: Equatable {
        var displayID: CGDirectDisplayID?
        var name: String
        var frame: CGRect
        var workArea: CGRect
        var dpiFactor: CGFloat
        /// Current display mode's rendering pixels, not the panel's advertised native resolution.
        var pixelSize: CGSize?
        var isActive: Bool = true
    }

    /// AppKit's current displays, primary first. AppKit screen reads stay on the main thread.
    static func displayGroups() -> [Group] {
        dispatchPrecondition(condition: .onQueue(.main))
        let screens = NSScreen.screens.map { screen -> DisplaySnapshot in
            let id = DesktopInputs.displayID(of: screen)
            let mode = id.flatMap(CGDisplayCopyDisplayMode)
            let pixels = mode.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
            return DisplaySnapshot(displayID: id, name: screen.localizedName, frame: screen.frame,
                                   workArea: screen.visibleFrame, dpiFactor: screen.backingScaleFactor,
                                   pixelSize: pixels, isActive: id.map { CGDisplayIsActive($0) != 0 } ?? true)
        }
        return displayGroups(screens: screens)
    }

    /// Pure formatting of macOS display facts. Logical coordinates use the same primary-screen top-left origin as
    /// skins. Physical areas are local to each display: macOS has no global physical-pixel desktop coordinate space.
    static func displayGroups(screens: [DisplaySnapshot]) -> [Group] {
        let primaryTop = screens.first?.frame.maxY ?? 0
        func logical(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
        }
        let virtual = screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let primary = screens.first.map { screen in
            let name = screen.name.isEmpty ? "Unnamed display" : screen.name
            return screen.displayID.map { "\(name) (CGDirectDisplayID \($0))" } ?? name
        } ?? "Unavailable"
        var groups = [Group(title: "Overview", fields: [
            Field(label: "Primary device", value: primary),
            Field(label: "Device count", value: "\(screens.count) (available macOS displays)"),
            Field(label: "Display count", value: String(screens.count)),
            Field(label: "Virtual screen", value: virtual.isNull ? "Unavailable" : area(logical(virtual))),
            Field(label: "Physical virtual screen", value: "Unavailable (no shared physical-pixel coordinates on macOS)")
        ])]
        for (index, screen) in screens.enumerated() {
            let name = screen.name.isEmpty ? "Unnamed display" : screen.name
            let physical = physicalAreas(screen)
            groups.append(Group(title: "Device \(index + 1)", fields: [
                Field(label: "Active", value: screen.isActive ? "Yes" : "No"),
                Field(label: "Device number", value: screen.displayID.map { "\($0) (CGDirectDisplayID)" } ?? "Unavailable"),
                Field(label: "Device name", value: name),
                Field(label: "Display number", value: "\(index + 1) (Deskset)"),
                Field(label: "Display name", value: name),
                Field(label: "DPI factor", value: number(screen.dpiFactor)),
                Field(label: "Screen area", value: area(logical(screen.frame))),
                Field(label: "Work area", value: area(logical(screen.workArea))),
                Field(label: "Physical screen area", value: physical.map { area($0.screen) + " (display-local pixels)" } ?? "Unavailable"),
                Field(label: "Physical work area", value: physical.map { area($0.work) + " (display-local pixels)" } ?? "Unavailable")
            ]))
        }
        return groups
    }

    /// Any thread. The live collector includes inactive interfaces; filtering only changes what this page shows.
    static func networkGroups(showVirtualInterfaces: Bool, monitor: SystemMonitor = .shared) -> [Group] {
        networkGroups(interfaces: monitor.debugNetworkInterfaces(), showVirtualInterfaces: showVirtualInterfaces)
    }

    static func networkGroups(interfaces: [SystemMonitor.DebugNetworkInterface],
                              showVirtualInterfaces: Bool) -> [Group] {
        interfaces.filter { showVirtualInterfaces || !$0.isVirtual }.sorted {
            if $0.index != $1.index { return $0.index < $1.index }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.map { interface in
            Group(title: interface.name, fields: [
                Field(label: "Interface index", value: interface.index == 0 ? "Unavailable" : "\(interface.index) (BSD)"),
                Field(label: "Description", value: available(interface.description)),
                Field(label: "Alias", value: available(interface.alias)),
                Field(label: "Type", value: available(interface.type)),
                Field(label: "Status", value: available(interface.status))
            ])
        }
    }

    private static func available(_ value: String) -> String { value.isEmpty ? "Unavailable" : value }

    private static func physicalAreas(_ screen: DisplaySnapshot) -> (screen: CGRect, work: CGRect)? {
        guard let pixels = screen.pixelSize, pixels.width > 0, pixels.height > 0,
              screen.frame.width > 0, screen.frame.height > 0 else { return nil }
        let sx = pixels.width / screen.frame.width
        let sy = pixels.height / screen.frame.height
        let work = screen.workArea.intersection(screen.frame)
        guard !work.isNull else { return nil }
        return (CGRect(origin: .zero, size: pixels),
                CGRect(x: (work.minX - screen.frame.minX) * sx,
                       y: (screen.frame.maxY - work.maxY) * sy,
                       width: work.width * sx, height: work.height * sy))
    }

    private static func area(_ rect: CGRect) -> String {
        "(\(number(rect.minX)), \(number(rect.minY))) - (\(number(rect.maxX)), \(number(rect.maxY)))"
    }

    private static func number(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value)).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}
