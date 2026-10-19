import AppKit
import Darwin

enum DebugSystemInfoSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Debug system info: logical and physical display coordinates") {
            let screens = [
                DebugSystemInfo.DisplaySnapshot(displayID: 7, name: "Built-in Display",
                    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                    workArea: CGRect(x: 0, y: 30, width: 1512, height: 927), dpiFactor: 2,
                    pixelSize: CGSize(width: 3024, height: 1964)),
                DebugSystemInfo.DisplaySnapshot(displayID: 42, name: "External Display",
                    frame: CGRect(x: -1920, y: 200, width: 1920, height: 1080),
                    workArea: CGRect(x: -1920, y: 200, width: 1920, height: 1040), dpiFactor: 1,
                    pixelSize: CGSize(width: 1920, height: 1080))
            ]
            let groups = DebugSystemInfo.displayGroups(screens: screens)
            t.equal(groups.map(\.title), ["Overview", "Device 1", "Device 2"])
            t.equal(value("Primary device", groups[0]), "Built-in Display (CGDirectDisplayID 7)")
            t.equal(value("Display count", groups[0]), "2")
            t.equal(value("Virtual screen", groups[0]), "(-1920, -298) - (1512, 982)")
            t.check(value("Physical virtual screen", groups[0]).hasPrefix("Unavailable"),
                    "mixed-DPI displays do not invent a shared physical coordinate space")
            t.equal(value("Device number", groups[1]), "7 (CGDirectDisplayID)")
            t.equal(value("Display number", groups[1]), "1 (Deskset)")
            t.equal(value("Screen area", groups[1]), "(0, 0) - (1512, 982)")
            t.equal(value("Work area", groups[1]), "(0, 25) - (1512, 952)")
            t.equal(value("DPI factor", groups[1]), "2")
            t.equal(value("Physical screen area", groups[1]), "(0, 0) - (3024, 1964) (display-local pixels)")
            t.equal(value("Physical work area", groups[1]), "(0, 50) - (3024, 1904) (display-local pixels)")
            t.equal(value("Screen area", groups[2]), "(-1920, -298) - (0, 782)")
            t.equal(value("Physical work area", groups[2]), "(0, 40) - (1920, 1080) (display-local pixels)")
        }

        t.suite("App: Debug system info: unavailable display facts remain unavailable") {
            let empty = DebugSystemInfo.displayGroups(screens: [])
            t.equal(empty.count, 1)
            t.equal(value("Display count", empty[0]), "0")
            t.equal(value("Primary device", empty[0]), "Unavailable")
            t.equal(value("Virtual screen", empty[0]), "Unavailable")
            let unknown = DebugSystemInfo.DisplaySnapshot(displayID: nil, name: "", frame: .zero,
                workArea: .zero, dpiFactor: 1, pixelSize: nil, isActive: false)
            let group = DebugSystemInfo.displayGroups(screens: [unknown])[1]
            t.equal(value("Active", group), "No")
            t.equal(value("Device number", group), "Unavailable")
            t.equal(value("Device name", group), "Unnamed display")
            t.equal(value("Physical screen area", group), "Unavailable")
            t.equal(value("Physical work area", group), "Unavailable")
        }

        t.suite("App: Debug system info: inactive interfaces, virtual filter and native indices") {
            let interfaces = [
                SystemMonitor.DebugNetworkInterface(name: "en7", index: 22, description: "USB Ethernet",
                    alias: "Office LAN", type: "Ethernet", status: "Down", isVirtual: false),
                SystemMonitor.DebugNetworkInterface(name: "utun2", index: 30, description: "utun2",
                    alias: "utun2", type: "Other", status: "Up", isVirtual: true),
                SystemMonitor.DebugNetworkInterface(name: "en0", index: 14, description: "Wi-Fi",
                    alias: "Wi-Fi", type: "Wireless", status: "Up", isVirtual: false),
                SystemMonitor.DebugNetworkInterface(name: "lo0", index: 1, description: "lo0",
                    alias: "lo0", type: "Loopback", status: "Up", isVirtual: true)
            ]
            let physical = DebugSystemInfo.networkGroups(interfaces: interfaces, showVirtualInterfaces: false)
            t.equal(physical.map(\.title), ["en0", "en7"])
            t.equal(physical[0].fields.map(\.label), ["Interface index", "Description", "Alias", "Type", "Status"])
            t.equal(value("Interface index", physical[0]), "14 (BSD)", "index is not its position in the visible list")
            t.equal(value("Interface index", physical[1]), "22 (BSD)")
            t.equal(value("Status", physical[1]), "Down", "inactive hardware is still listed")
            t.equal(value("Alias", physical[1]), "Office LAN")
            let all = DebugSystemInfo.networkGroups(interfaces: interfaces, showVirtualInterfaces: true)
            t.equal(all.map(\.title), ["lo0", "en0", "en7", "utun2"])
            t.equal(DebugSystemInfo.networkGroups(interfaces: [], showVirtualInterfaces: true), [])
            let missing = SystemMonitor.DebugNetworkInterface(name: "en9", index: 0, description: "",
                alias: "", type: "", status: "", isVirtual: false)
            let missingGroup = DebugSystemInfo.networkGroups(interfaces: [missing], showVirtualInterfaces: false)[0]
            t.check(missingGroup.fields.allSatisfy { $0.value == "Unavailable" },
                    "missing metadata is not fabricated")
        }

        t.suite("App: Debug system info: native network flags and adapter metadata") {
            let adapter = SystemMonitor.AdapterInfo(bsdName: "en7", displayName: "USB Ethernet",
                isWireless: false, isEthernet: true, serviceName: "Office LAN")
            let disconnected = SystemMonitor.debugNetworkInterface(name: "en7", index: 22,
                flags: IFF_UP | IFF_RUNNING, adapter: adapter, mediaActive: false)
            t.equal(disconnected.status, "Down", "a disconnected medium overrides the running flag")
            t.equal(disconnected.index, 22)
            t.equal(disconnected.description, "USB Ethernet")
            t.equal(disconnected.alias, "Office LAN")
            t.equal(disconnected.type, "Ethernet")
            t.equal(disconnected.isVirtual, false)
            let administrativelyDown = SystemMonitor.debugNetworkInterface(name: "en7", index: 22,
                flags: IFF_RUNNING, adapter: adapter, mediaActive: true)
            t.equal(administrativelyDown.status, "Down", "media activity does not override an interface being down")
            let loopback = SystemMonitor.debugNetworkInterface(name: "lo0", index: 1,
                flags: IFF_UP | IFF_RUNNING | IFF_LOOPBACK, adapter: nil, mediaActive: nil)
            t.equal(loopback.type, "Loopback")
            t.equal(loopback.status, "Up")
            t.equal(loopback.isVirtual, true)
            let tunnel = SystemMonitor.debugNetworkInterface(name: "utun2", index: 30,
                flags: IFF_UP | IFF_RUNNING, adapter: nil, mediaActive: nil)
            t.equal(tunnel.isVirtual, true)
            t.equal(tunnel.status, "Up")
            let unavailable = SystemMonitor.debugNetworkInterface(name: "en7", index: 0,
                flags: nil, adapter: adapter, mediaActive: nil)
            t.equal(unavailable.status, "Unavailable")
            t.equal(unavailable.isVirtual, false, "known hardware is retained when its flags cannot be read")
        }

        t.suite("App: Debug system info: live network facts can be collected off main") {
            let result = SkinRuntimeSelfTests.onAnotherThread {
                let interfaces = SystemMonitor.shared.debugNetworkInterfaces()
                return !Thread.isMainThread && Set(interfaces.map(\.name)).count == interfaces.count
                    && interfaces.allSatisfy { !$0.name.isEmpty && ["Up", "Down", "Unavailable"].contains($0.status) }
            }
            t.equal(result, true)
        }
    }

    private static func value(_ label: String, _ group: DebugSystemInfo.Group) -> String {
        group.fields.first(where: { $0.label == label })?.value ?? "<missing>"
    }
}
