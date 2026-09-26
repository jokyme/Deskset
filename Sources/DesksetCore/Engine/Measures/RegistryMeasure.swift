import Foundation

// MARK: - Registry

/// `Measure=Registry` (manual: /manual/measures/registry/): `RegHKey` (default `HKEY_CURRENT_USER`), `RegKey`,
/// `RegValue` (empty = the key's default value), `OutputType` (`Value`, `SubKeyList`, `ValueList`) and
/// `OutputDelimiter` (default `#CRLF#`).
///
/// macOS has no registry. Skins read it almost only for facts about the machine (Windows version and build, CPU
/// and GPU names, processor count, the user's folders), so those values are emulated with their macOS equivalents
/// (`RegistryMeasure.emulatedValue`). The desktop wallpaper (`HKCU\Control Panel\Desktop` `Wallpaper`) is the
/// current desktop picture from the data source (`SystemDataSource.desktopPicturePath()`), read again at every
/// update because it changes while the skin runs. Every other value reads as 0 / "" — like a value that does not
/// exist — and is listed once as a compatibility issue.
///
/// Types follow the manual: string values (REG_SZ) set the string, and "numeric strings populate both string and
/// number"; REG_DWORD / REG_QWORD values are numbers without a string of their own (a String meter formats them
/// with its NumOfDecimals / AutoScale options).
public final class RegistryMeasure: Measure {
    /// One emulated registry value.
    public enum Value: Equatable {
        case string(String)
        case number(Double)
    }

    private var hive = "HKEY_CURRENT_USER"
    private var key = ""
    private var valueName = ""
    private var outputType = "value"
    private var delimiter = "\r\n"
    /// The looked-up result for the current options. The machine facts do not change while the skin runs; a `live`
    /// value (the wallpaper) is looked up again at every update.
    private var cached: (options: [String], result: Value?, live: Bool)?

    /// The value read is not one of the emulated ones.
    public override var valueUnavailable: Bool {
        guard let cached else { return false }
        return cached.result == nil
    }

    public override func readMeasureOptions() {
        hive = string("RegHKey", "HKEY_CURRENT_USER").trimmingCharacters(in: .whitespaces)
        key = string("RegKey").trimmingCharacters(in: .whitespaces)
        valueName = string("RegValue").trimmingCharacters(in: .whitespaces)
        outputType = string("OutputType", "Value").trimmingCharacters(in: .whitespaces).lowercased()
        delimiter = option("OutputDelimiter") ?? "\r\n"
        // Looked up when the options are read, so the compatibility note is there as soon as the skin is loaded.
        _ = currentResult()
    }

    /// The value for the current options (looked up again only when they change, or at every call for a live value).
    private func currentResult() -> Value? {
        let options = [hive, key, valueName, outputType, delimiter]
        if let cached, cached.options == options, !cached.live { return cached.result }
        let live = outputType == "value" && RegistryMeasure.isWallpaperValue(hive: hive, key: key, value: valueName)
        let result = live ? skin.system.desktopPicturePath().map(Value.string) : lookup()
        cached = (options, result, live)
        if result == nil {
            skin.addIssue("Registry value \(RegistryMeasure.displayName(hive: hive, key: key, value: valueName)) "
                          + "does not exist on macOS (only a few Windows version / hardware values are emulated)")
        }
        return result
    }

    public override func computeValue() -> Double {
        switch currentResult() {
        case .string(let s)?:
            rawString = s
            return Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
        case .number(let n)?:
            rawString = nil
            return n.isFinite ? n : 0
        case nil:
            rawString = ""
            return 0
        }
    }

    private func lookup() -> Value? {
        let facts = RegistryMeasure.Facts.current(system: skin.system)
        switch outputType {
        case "subkeylist":
            let names = RegistryMeasure.subKeys(hive: hive, key: key, facts: facts)
            return names.map { .string($0.joined(separator: delimiter)) }
        case "valuelist":
            let names = RegistryMeasure.valueNames(hive: hive, key: key)
            return names.map { .string($0.joined(separator: delimiter)) }
        default:
            return RegistryMeasure.emulatedValue(hive: hive, key: key, value: valueName, facts: facts)
        }
    }

    // MARK: Emulation table

    /// Machine facts the emulated values are made of (read once per process; tests pass their own).
    public struct Facts: Equatable {
        public var productName: String
        /// `major.minor`, e.g. `26.5`.
        public var version: String
        /// `major.minor[.patch]`.
        public var fullVersion: String
        public var majorVersion: Int
        public var minorVersion: Int
        public var patchVersion: Int
        /// macOS build, e.g. `25F71`.
        public var build: String
        /// CPU brand string, e.g. `Apple M2 Pro`.
        public var processorName: String
        /// `arm64` / `x86_64`.
        public var architecture: String
        public var processorCount: Int
        /// CPU frequency in MHz (0 when unknown, as on Apple Silicon).
        public var processorMHz: Double
        public var userFullName: String
        public var userName: String
        public var computerName: String
        public var homeDirectory: String
        /// An Intel Mac's graphics processor (`SystemDataSource.graphicsAdapterName`), "" when unknown. Unused on
        /// Apple silicon, where the GPU is named like the chip.
        public var graphicsName: String

        public init(productName: String, version: String, fullVersion: String, majorVersion: Int, minorVersion: Int,
                    patchVersion: Int, build: String, processorName: String, architecture: String,
                    processorCount: Int, processorMHz: Double, userFullName: String, userName: String,
                    computerName: String, homeDirectory: String, graphicsName: String = "") {
            self.productName = productName
            self.version = version
            self.fullVersion = fullVersion
            self.majorVersion = majorVersion
            self.minorVersion = minorVersion
            self.patchVersion = patchVersion
            self.build = build
            self.processorName = processorName
            self.architecture = architecture
            self.processorCount = processorCount
            self.processorMHz = processorMHz
            self.userFullName = userFullName
            self.userName = userName
            self.computerName = computerName
            self.homeDirectory = homeDirectory
            self.graphicsName = graphicsName
        }

        private static var shared: Facts?
        private static let lock = NSLock()

        /// The facts of this Mac. An Intel Mac's graphics processor comes from the skin's data source every time
        /// (the app's keeps it); everything else is computed once.
        static func current(system: SystemDataSource) -> Facts {
            var facts = machine(system: system)
            if !facts.processorName.hasPrefix("Apple") { facts.graphicsName = system.graphicsAdapterName() ?? "" }
            return facts
        }

        /// Computed once; the product name comes from the data source's OS_PRODUCT_NAME, like SysInfo, so both
        /// measures agree.
        private static func machine(system: SystemDataSource) -> Facts {
            lock.lock()
            defer { lock.unlock() }
            if let shared { return shared }
            let v = ProcessInfo.processInfo.operatingSystemVersion
            let version = "\(v.majorVersion).\(v.minorVersion)"
            let full = version + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
            let product = system.sysInfo(type: "OS_PRODUCT_NAME", data: "")?.string.flatMap { $0.isEmpty ? nil : $0 }
                ?? "macOS \(full)"
            let mhz = (system.cpuFrequency() ?? 0) / 1_000_000
            let facts = Facts(productName: product, version: version, fullVersion: full,
                              majorVersion: v.majorVersion, minorVersion: v.minorVersion, patchVersion: v.patchVersion,
                              build: sysctlString("kern.osversion") ?? "",
                              processorName: sysctlString("machdep.cpu.brand_string") ?? "",
                              architecture: sysctlString("hw.machine") ?? "",
                              processorCount: system.processorCount,
                              processorMHz: mhz.isFinite ? mhz.rounded() : 0,
                              userFullName: NSFullUserName(), userName: NSUserName(),
                              computerName: system.sysInfo(type: "COMPUTER_NAME", data: "")?.string
                                ?? ProcessInfo.processInfo.hostName,
                              homeDirectory: NSHomeDirectory())
            shared = facts
            return facts
        }

        private static func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 4096 else { return nil }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
            let text = String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    /// `HKEY_LOCAL_MACHINE` / `HKLM` → `hklm` (nil for an unknown hive).
    static func normalizedHive(_ hive: String) -> String? {
        switch hive.trimmingCharacters(in: .whitespaces).uppercased() {
        case "HKEY_LOCAL_MACHINE", "HKLM": return "hklm"
        case "HKEY_CURRENT_USER", "HKCU", "": return "hkcu"
        case "HKEY_CLASSES_ROOT", "HKCR": return "hkcr"
        case "HKEY_CURRENT_CONFIG", "HKCC": return "hkcc"
        case "HKEY_USERS", "HKU": return "hku"
        default: return nil
        }
    }

    /// `SOFTWARE/Microsoft\\Windows NT\CurrentVersion\` → `software\microsoft\windows nt\currentversion`; the
    /// 32-bit view (`WOW6432Node`) and the numbered control sets read like the current ones.
    static func normalizedKey(_ key: String) -> String {
        var parts = key.replacingOccurrences(of: "/", with: "\\").split(separator: "\\")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        if parts.count > 1, parts[0] == "software", parts[1] == "wow6432node" { parts.remove(at: 1) }
        if parts.count > 1, parts[0] == "system", parts[1].hasPrefix("controlset") { parts[1] = "currentcontrolset" }
        return parts.joined(separator: "\\")
    }

    private static let currentVersionKey = "software\\microsoft\\windows nt\\currentversion"
    private static let processorKey = "hardware\\description\\system\\centralprocessor"
    private static let environmentKey = "system\\currentcontrolset\\control\\session manager\\environment"
    private static let desktopKey = "control panel\\desktop"
    private static let computerNameKeys: Set<String> = [
        "system\\currentcontrolset\\control\\computername\\computername",
        "system\\currentcontrolset\\control\\computername\\activecomputername",
    ]
    private static let shellFolderKeys: Set<String> = [
        "software\\microsoft\\windows\\currentversion\\explorer\\shell folders",
        "software\\microsoft\\windows\\currentversion\\explorer\\user shell folders",
    ]

    /// The emulated value, or nil when the value is not emulated (reads as 0 / "").
    public static func emulatedValue(hive rawHive: String, key rawKey: String, value rawValue: String,
                                     facts f: Facts) -> Value? {
        guard let hive = normalizedHive(rawHive) else { return nil }
        let key = normalizedKey(rawKey)
        let value = rawValue.trimmingCharacters(in: .whitespaces).lowercased()
        if hive == "hklm" {
            switch key {
            case currentVersionKey:
                switch value {
                case "productname": return .string(f.productName)
                case "currentversion": return .string(f.version)
                case "currentmajorversionnumber": return .number(Double(f.majorVersion))
                case "currentminorversionnumber": return .number(Double(f.minorVersion))
                case "currentbuild", "currentbuildnumber", "buildlab", "buildlabex": return .string(f.build)
                case "displayversion", "releaseid": return .string(f.fullVersion)
                case "ubr": return .number(Double(f.patchVersion))
                case "registeredowner": return .string(f.userFullName)
                case "registeredorganization": return .string("")
                case "installationtype": return .string("Client")
                case "systemroot": return .string("/System")
                default: return nil
                }
            case currentVersionKey + "\\winsat":
                // The GPU of an Apple silicon Mac is part of the chip: System Information names it like the CPU. An
                // Intel Mac's is a chip of its own, named by the data source.
                let adapter = f.processorName.hasPrefix("Apple") ? f.processorName : f.graphicsName
                if value == "primaryadapterstring", !adapter.isEmpty { return .string(adapter) }
                return nil
            case environmentKey:
                switch value {
                case "number_of_processors": return .string(String(f.processorCount))
                case "processor_architecture": return .string(windowsArchitecture(f.architecture))
                // Windows: "Intel64 Family 6 Model 158 Stepping 10, GenuineIntel" — the Mac's CPU brand string.
                case "processor_identifier": return f.processorName.isEmpty ? nil : .string(f.processorName)
                default: return nil
                }
            default:
                break
            }
            if key.hasPrefix(processorKey + "\\"), let index = Int(key.dropFirst(processorKey.count + 1)),
               index >= 0, index < max(f.processorCount, 1) {
                switch value {
                case "processornamestring": return .string(f.processorName)
                case "~mhz": return .number(f.processorMHz)
                case "vendoridentifier": return .string(f.processorName.hasPrefix("Apple") ? "Apple" : "")
                case "identifier": return .string(f.architecture)
                default: return nil
                }
            }
            if computerNameKeys.contains(key), value == "computername" { return .string(f.computerName) }
            return nil
        }
        if hive == "hkcu" {
            if key == "volatile environment" {
                switch value {
                case "username": return .string(f.userName)
                case "userprofile", "homepath": return .string(f.homeDirectory)
                default: return nil
                }
            }
            if shellFolderKeys.contains(key), let folder = userFolder(value) {
                return .string((f.homeDirectory as NSString).appendingPathComponent(folder))
            }
        }
        return nil
    }

    /// Value names of an emulated key (`OutputType=ValueList`), nil when the key is not emulated.
    static func valueNames(hive rawHive: String, key rawKey: String) -> [String]? {
        guard let hive = normalizedHive(rawHive) else { return nil }
        let key = normalizedKey(rawKey)
        switch (hive, key) {
        case ("hklm", currentVersionKey):
            return ["ProductName", "CurrentVersion", "CurrentMajorVersionNumber", "CurrentMinorVersionNumber",
                    "CurrentBuild", "CurrentBuildNumber", "DisplayVersion", "ReleaseId", "UBR", "RegisteredOwner",
                    "RegisteredOrganization", "InstallationType"]
        case ("hklm", environmentKey): return ["NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE", "PROCESSOR_IDENTIFIER"]
        case ("hkcu", "volatile environment"): return ["USERNAME", "USERPROFILE"]
        default:
            if hive == "hklm", key.hasPrefix(processorKey + "\\") {
                return ["~MHz", "Identifier", "ProcessorNameString", "VendorIdentifier"]
            }
            return nil
        }
    }

    /// `HKCU\Control Panel\Desktop` `Wallpaper`: the desktop picture (a live value, see `currentResult`).
    static func isWallpaperValue(hive: String, key: String, value: String) -> Bool {
        normalizedHive(hive) == "hkcu" && normalizedKey(key) == desktopKey
            && value.trimmingCharacters(in: .whitespaces).lowercased() == "wallpaper"
    }

    /// Subkeys of an emulated key (`OutputType=SubKeyList`): only the processor list is emulated.
    static func subKeys(hive rawHive: String, key rawKey: String, facts: Facts) -> [String]? {
        guard normalizedHive(rawHive) == "hklm", normalizedKey(rawKey) == processorKey else { return nil }
        return (0..<min(max(facts.processorCount, 1), 1024)).map(String.init)
    }

    private static func windowsArchitecture(_ machine: String) -> String {
        switch machine.lowercased() {
        case "arm64", "arm64e": return "ARM64"
        case "x86_64": return "AMD64"
        default: return machine.uppercased()
        }
    }

    /// Shell Folders value names → folder in the home directory.
    private static func userFolder(_ value: String) -> String? {
        switch value {
        case "desktop": return "Desktop"
        case "personal", "{f42ee2d3-909f-4907-8871-4c22fc0bf756}": return "Documents"
        case "my music", "{4bd8d571-6d19-48d3-be97-422220080e43}": return "Music"
        case "my pictures", "{33e28130-4e1e-4676-835a-98395c3bc3bb}": return "Pictures"
        case "my video", "{18989b1d-99b5-455b-841c-ab7c74e4ddfc}": return "Movies"
        case "{374de290-123f-4565-9164-39c4925e467b}": return "Downloads"
        default: return nil
        }
    }

    static func displayName(hive: String, key: String, value: String) -> String {
        let h = normalizedHive(hive)?.uppercased() ?? hive
        let path = key.replacingOccurrences(of: "/", with: "\\")
        return value.isEmpty ? "\(h)\\\(path) (default value)" : "\(h)\\\(path)\\\(value)"
    }
}
