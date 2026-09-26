import AppKit
import CoreLocation
import CoreWLAN
import DesksetCore

// WiFiStatus measure (manual: /manual/measures/wifistatus/) on CoreWLAN.
//
// - Values come from a shared cache refreshed off the main thread (at most every 2 s for the current connection,
//   every 30 s for the LIST scan, which takes a few seconds); a measure shows the latest cached values.
// - SSIDs (the SSID type and network names in LIST) need the Location Services permission on current macOS, just
//   as Windows 11 24H2 needs "Let desktop apps access your location". It is requested the first time a skin running
//   in the app uses SSID or LIST; without it SSID is "" and LIST is empty. Everything else works without it.

/// What CoreWLAN reports about the current connection (or a visible network), already mapped to the manual's words.
struct WiFiNetworkInfo: Equatable {
    var ssid = ""
    /// dBm (0 = unknown).
    var rssi = 0
    /// Mbps.
    var transmitRate = 0.0
    var encryption = "???"
    var auth = "???"
    var phy = "???"
}

enum WiFiStatusFormat {
    /// Quality 0…100 from the signal strength: -100 dBm → 0, -50 dBm or better → 100 (linear, the scale Windows
    /// uses for its signal quality; Judgment: the manual only says "percentage of the maximum dBm").
    static func quality(rssi: Int) -> Int {
        guard rssi < 0 else { return 0 }
        return min(max(2 * (rssi + 100), 0), 100)
    }

    /// `WiFiListStyle` 0…7 (manual): SSID, then @PHY (1, 3, 5, 7), (Encryption:AUTH) (2, 3, 6, 7), [Quality] (4…7).
    /// Judgment: Quality in the list is written "[80%]".
    static func listLine(_ n: WiFiNetworkInfo, style: Int) -> String {
        let s = min(max(style, 0), 7)
        var line = n.ssid
        if s & 1 != 0 { line += " @\(n.phy)" }
        if s & 2 != 0 { line += " (\(n.encryption):\(n.auth))" }
        if s & 4 != 0 { line += " [\(quality(rssi: n.rssi))%]" }
        return line
    }

    /// Visible networks: named ones only, one line per SSID (the strongest), strongest first, at most `limit`.
    static func list(_ networks: [WiFiNetworkInfo], style: Int, limit: Int) -> String {
        var best: [String: WiFiNetworkInfo] = [:]
        for n in networks where !n.ssid.isEmpty {
            if let b = best[n.ssid], b.rssi >= n.rssi { continue }
            best[n.ssid] = n
        }
        let sorted = best.values.sorted { $0.rssi != $1.rssi ? $0.rssi > $1.rssi : $0.ssid < $1.ssid }
        return sorted.prefix(max(limit, 0)).map { listLine($0, style: style) }.joined(separator: "\n")
    }

    /// Cipher names of the manual (NONE, WEP, TKIP, AES, …) for a CoreWLAN security mode.
    static func encryption(_ security: CWSecurity) -> String {
        switch security {
        case .none: return "NONE"
        case .WEP, .dynamicWEP: return "WEP"
        case .wpaPersonal, .wpaPersonalMixed, .wpaEnterprise, .wpaEnterpriseMixed: return "TKIP"
        case .wpa2Personal, .personal, .wpa2Enterprise, .enterprise, .wpa3Personal, .wpa3Transition,
             .wpa3Enterprise, .OWE, .oweTransition: return "AES"
        default: return "???"
        }
    }

    /// Authentication names of the manual (Open, WPA2-Personal, …).
    static func auth(_ security: CWSecurity) -> String {
        switch security {
        case .none, .OWE, .oweTransition: return "Open"
        case .WEP: return "Open"
        case .dynamicWEP: return "Shared"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA-Personal"
        case .wpaEnterprise, .wpaEnterpriseMixed: return "WPA-Enterprise"
        case .wpa2Personal, .personal: return "WPA2-Personal"
        case .wpa2Enterprise, .enterprise: return "WPA2-Enterprise"
        case .wpa3Personal, .wpa3Transition: return "WPA3-Personal"
        case .wpa3Enterprise: return "WPA3-Enterprise"
        default: return "???"
        }
    }

    static func phy(_ mode: CWPHYMode) -> String {
        switch mode {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "802.11n"
        case .mode11ac: return "802.11ac"
        case .mode11ax: return "802.11ax"
        default:
            // 802.11be (Wi-Fi 7) has raw value 7 on systems that know it.
            return mode.rawValue == 7 ? "802.11be" : "???"
        }
    }

    /// Strongest security a scanned network supports.
    static func bestSecurity(_ network: CWNetwork) -> CWSecurity {
        let order: [CWSecurity] = [.wpa3Enterprise, .wpa3Personal, .wpa3Transition, .wpa2Enterprise, .wpa2Personal,
                                   .enterprise, .personal, .wpaEnterpriseMixed, .wpaEnterprise, .wpaPersonalMixed,
                                   .wpaPersonal, .dynamicWEP, .WEP, .OWE, .oweTransition, .none]
        return order.first { network.supportsSecurity($0) } ?? .unknown
    }

    static func bestPHY(_ network: CWNetwork) -> CWPHYMode {
        let order: [CWPHYMode] = [.mode11ax, .mode11ac, .mode11n, .mode11g, .mode11a, .mode11b]
        if let raw = CWPHYMode(rawValue: 7), network.supportsPHYMode(raw) { return raw }
        return order.first { network.supportsPHYMode($0) } ?? .modeNone
    }
}

/// Shared CoreWLAN reader (one per app).
final class WiFiCenter {
    static let shared = WiFiCenter()

    let worker = MediaUIWorker(name: "Deskset WiFiStatus")
    private var current: [Int: WiFiNetworkInfo?] = [:]
    private var scans: [Int: [WiFiNetworkInfo]] = [:]
    private var lastRefresh: [Int: TimeInterval] = [:]
    private var lastScan: [Int: TimeInterval] = [:]
    private var refreshing: Set<Int> = []
    private var scanning: Set<Int> = []
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Tests replace the reader.
    var reader: (Int) -> WiFiNetworkInfo? = WiFiCenter.readCurrent
    var scanner: (Int) -> [WiFiNetworkInfo] = WiFiCenter.scan

    /// Latest info of interface `index` (nil = no such interface / Wi-Fi off); refreshes in the background.
    func info(interface index: Int) -> WiFiNetworkInfo? {
        let now = clock()
        if !refreshing.contains(index), now - (lastRefresh[index] ?? -1e9) >= 2 {
            refreshing.insert(index)
            lastRefresh[index] = now
            let reader = self.reader
            worker.async { [weak self] in
                let info = reader(index)
                MediaUIMainHop.async {
                    self?.current[index] = .some(info)
                    self?.refreshing.remove(index)
                }
            }
        }
        return current[index] ?? nil
    }

    /// Latest scan of interface `index`; scans again after 30 s.
    func networks(interface index: Int) -> [WiFiNetworkInfo] {
        let now = clock()
        if !scanning.contains(index), now - (lastScan[index] ?? -1e9) >= 30 {
            scanning.insert(index)
            lastScan[index] = now
            let scanner = self.scanner
            worker.async { [weak self] in
                let found = scanner(index)
                MediaUIMainHop.async {
                    self?.scans[index] = found
                    self?.scanning.remove(index)
                }
            }
        }
        return scans[index] ?? []
    }

    /// `WiFiIntfID`: 0-based index into the Wi-Fi interfaces (0 = the default one).
    private static func interface(_ index: Int) -> CWInterface? {
        let client = CWWiFiClient.shared()
        if index == 0, let i = client.interface() { return i }
        let all = client.interfaces() ?? []
        return index >= 0 && index < all.count ? all[index] : nil
    }

    static func readCurrent(_ index: Int) -> WiFiNetworkInfo? {
        guard let i = interface(index), i.powerOn() else { return nil }
        var n = WiFiNetworkInfo()
        n.ssid = i.ssid() ?? ""
        n.rssi = i.rssiValue()
        n.transmitRate = i.transmitRate()
        let associated = n.rssi != 0 || i.transmitRate() > 0
        n.encryption = associated ? WiFiStatusFormat.encryption(i.security()) : "???"
        n.auth = associated ? WiFiStatusFormat.auth(i.security()) : "???"
        n.phy = associated ? WiFiStatusFormat.phy(i.activePHYMode()) : "???"
        return n
    }

    /// Seconds between active scans of one interface, and between active scans while the system has no cached
    /// results (worker thread only).
    static let activeScanInterval: TimeInterval = 300
    static let emptyCacheScanInterval: TimeInterval = 60
    private static var lastActiveScan: [Int: TimeInterval] = [:]

    /// Whether an active scan is due: the system's cached results are used otherwise (pure, tested).
    static func needsActiveScan(cachedCount: Int, lastScan: TimeInterval?, now: TimeInterval) -> Bool {
        let since = lastScan.map { now - $0 } ?? .infinity
        return since >= (cachedCount == 0 ? emptyCacheScanInterval : activeScanInterval)
    }

    /// Visible networks: the results of the system's own latest scan (`cachedScanResults`, free), with an active
    /// scan only now and then. An active scan takes seconds and briefly takes the Wi-Fi radio off its channel
    /// (latency spikes in calls and games), so a LIST skin must not force one every 30 s.
    static func scan(_ index: Int) -> [WiFiNetworkInfo] {
        guard let i = interface(index), i.powerOn() else { return [] }
        var found = i.cachedScanResults() ?? []
        let now = ProcessInfo.processInfo.systemUptime
        if needsActiveScan(cachedCount: found.count, lastScan: lastActiveScan[index], now: now) {
            lastActiveScan[index] = now
            if let scanned = try? i.scanForNetworks(withName: nil, includeHidden: false) { found = scanned }
        }
        return found.map { network in
            var n = WiFiNetworkInfo()
            n.ssid = network.ssid ?? ""
            n.rssi = network.rssiValue
            let security = WiFiStatusFormat.bestSecurity(network)
            n.encryption = WiFiStatusFormat.encryption(security)
            n.auth = WiFiStatusFormat.auth(security)
            n.phy = WiFiStatusFormat.phy(WiFiStatusFormat.bestPHY(network))
            return n
        }
    }
}

/// Location Services permission, asked once and only for skins running in the app.
final class MediaUILocationPermission: NSObject, CLLocationManagerDelegate {
    static let shared = MediaUILocationPermission()
    private var manager: CLLocationManager?
    private var asked = false

    var status: CLAuthorizationStatus {
        (manager ?? CLLocationManager()).authorizationStatus
    }

    var isDenied: Bool { status == .denied || status == .restricted }

    /// Asks when the user has not decided yet (main thread).
    func requestIfNeeded() {
        guard !asked else { return }
        asked = true
        let m = CLLocationManager()
        m.delegate = self
        manager = m
        if m.authorizationStatus == .notDetermined { m.requestWhenInUseAuthorization() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {}
}

/// `Measure=WiFiStatus` / `Plugin=WiFiStatus`.
final class WiFiStatusMeasure: MediaUIMeasure {
    enum InfoType: String {
        case ssid, quality, txrate, rxrate, encryption, auth, phy, list
    }

    /// Compatibility note when Location Services are off for Deskset (Windows shows network names to every app).
    static let locationNote = "WiFiStatus: macOS shows Wi-Fi network names only to apps allowed to use Location "
        + "Services. Allow Deskset in System Settings → Privacy & Security → Location Services to see them."

    /// Whether Location Services are refused for Deskset; replaced in tests.
    static var locationDenied: () -> Bool = { MediaUILocationPermission.shared.isDenied }

    private(set) var infoType: InfoType?
    /// This measure added `locationNote` to its skin (taken back once Location Services are allowed).
    private(set) var notedLocation = false
    private var interfaceIndex = 0
    private var listStyle = 0
    private var listLimit = 5
    var center: WiFiCenter = .shared

    override var automaticMaxValue: Double { infoType == .quality ? 100 : 1 }

    override func readMeasureOptions() {
        let raw = string("WiFiInfoType").muiTrimmed
        infoType = InfoType(rawValue: raw.lowercased())
        if infoType == nil { logOnce("WiFiStatus [\(name)]: WiFiInfoType=\(raw) is not valid") }
        interfaceIndex = max(int("WiFiIntfID", 0), 0)
        listStyle = min(max(int("WiFiListStyle", 0), 0), 7)
        listLimit = min(max(int("WiFiListLimit", 5), 0), 1000)
        if (infoType == .ssid || infoType == .list) && runsInApp {
            MediaUILocationPermission.shared.requestIfNeeded()
        }
    }

    func noteMissingLocation() {
        notedLocation = true
        skin.addIssue(WiFiStatusMeasure.locationNote)
    }

    override func computeValue() -> Double {
        // Allowed since the note was added (System Settings): it no longer applies.
        if notedLocation, !WiFiStatusMeasure.locationDenied() {
            notedLocation = false
            skin.removeIssue(WiFiStatusMeasure.locationNote)
        }
        guard let infoType else {
            publishString("")
            return 0
        }
        if infoType == .list {
            let networks = center.networks(interface: interfaceIndex)
            publishString(WiFiStatusFormat.list(networks, style: listStyle, limit: listLimit))
            if networks.isEmpty, runsInApp, WiFiStatusMeasure.locationDenied() {
                logOnce("WiFiStatus: network names need Location Services for Deskset "
                        + "(System Settings → Privacy & Security → Location Services)", level: .notice)
                noteMissingLocation()
            }
            return Double(networks.count)
        }
        let info = center.info(interface: interfaceIndex)
        switch infoType {
        case .ssid:
            let ssid = info?.ssid ?? ""
            if ssid.isEmpty, info != nil, runsInApp, WiFiStatusMeasure.locationDenied() {
                logOnce("WiFiStatus: the network name needs Location Services for Deskset "
                        + "(System Settings → Privacy & Security → Location Services)", level: .notice)
                noteMissingLocation()
            }
            publishString(ssid)
            return 0
        case .quality:
            publishString(nil)
            return Double(WiFiStatusFormat.quality(rssi: info?.rssi ?? 0))
        case .txrate, .rxrate:
            // "Theoretical maximum … speed in SI (1000) kilobits per second"; macOS reports one link rate (Mbps),
            // used for both directions.
            publishString(nil)
            return (info?.transmitRate ?? 0) * 1000
        case .encryption:
            publishString(info?.encryption ?? "???")
            return 0
        case .auth:
            publishString(info?.auth ?? "???")
            return 0
        case .phy:
            publishString(info?.phy ?? "???")
            return 0
        case .list:
            return 0
        }
    }
}
