import Foundation

public struct MemoryStatus: Equatable {
    /// Bytes.
    public var physicalTotal: Double
    public var physicalUsed: Double
    public var swapTotal: Double
    public var swapUsed: Double

    public init(physicalTotal: Double = 0, physicalUsed: Double = 0, swapTotal: Double = 0, swapUsed: Double = 0) {
        self.physicalTotal = physicalTotal
        self.physicalUsed = physicalUsed
        self.swapTotal = swapTotal
        self.swapUsed = swapUsed
    }
}

public struct BatteryStatus: Equatable {
    public var percent: Double
    public var isCharging: Bool
    public var isPluggedIn: Bool
    /// Minutes of battery life left; nil while unknown / calculating / on AC.
    public var minutesRemaining: Double?

    public init(percent: Double, isCharging: Bool, isPluggedIn: Bool, minutesRemaining: Double? = nil) {
        self.percent = percent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.minutesRemaining = minutesRemaining
    }
}

public struct NetworkCounters: Equatable {
    /// Cumulative bytes since boot.
    public var received: UInt64
    public var sent: UInt64

    public init(received: UInt64 = 0, sent: UInt64 = 0) {
        self.received = received
        self.sent = sent
    }
}

/// Facts about the volume a FreeDiskSpace measure looks at.
public struct VolumeInfo: Equatable {
    public enum Kind: Equatable {
        /// Internal or otherwise fixed disk.
        case fixed
        /// Removable media (USB flash drive, SD card…).
        case removable
        /// Network volume (SMB, AFP, NFS…).
        case network
        /// Optical disc.
        case cdRom
        /// RAM disk.
        case ram
    }

    /// Volume name (`Label=1`).
    public var label: String
    public var kind: Kind

    public init(label: String, kind: Kind) {
        self.label = label
        self.kind = kind
    }
}

/// System readings used by measures. The app implements it with Mach/BSD/IOKit calls; tests use fakes.
/// Implementations should sample on their own schedule and answer quickly from cached values.
///
/// Requirements added after the first version have default implementations in an extension (so existing
/// conformers keep compiling); the app should implement them properly where noted.
public protocol SystemDataSource: AnyObject {
    var processorCount: Int { get }
    /// 0…100. `processor` 0 = all cores, N = core N (1-based).
    func cpuUsage(processor: Int) -> Double
    func memoryStatus() -> MemoryStatus
    /// Active interface names (e.g. `en0`) in a stable order; `Interface=N` picks the Nth.
    func networkInterfaces() -> [String]
    /// Counters for one interface, or all non-loopback interfaces when `interface` is nil.
    func networkCounters(interface: String?) -> NetworkCounters
    /// Bytes for the volume containing `path`.
    func diskSpace(path: String) -> (total: Double, free: Double)?
    func uptime() -> TimeInterval
    /// nil when the machine has no battery.
    func battery() -> BatteryStatus?
    func isProcessRunning(_ name: String) -> Bool
    /// SysInfo measure `SysInfoType=` (upper-case), with `SysInfoData=`. nil when unsupported (the engine then
    /// answers the types it can compute itself, see `SysInfoMeasure`). A nil `string` means "number only".
    func sysInfo(type: String, data: String) -> (number: Double, string: String?)?

    /// The interface Net measures use for `Interface=Best` (manual: the active interface, wired preferred over
    /// wireless). nil when no interface is active.
    func bestNetworkInterface() -> String?
    /// Label and kind of the volume containing `path`; nil when `path` does not exist (FreeDiskSpace `Type=1`
    /// reports it as "Removed").
    func volumeInfo(path: String) -> VolumeInfo?
    /// Rated CPU frequency in Hz (PowerPlugin `PowerState=Hz` / `MHz`); nil when unknown (Apple Silicon has no
    /// public API for it).
    func cpuFrequency() -> Double?
    /// Absolute path of the desktop picture of the main screen, or "" when the desktop has no picture file; nil when
    /// this source cannot tell. Read by the Registry measure for `HKCU\Control Panel\Desktop` `Wallpaper` at every
    /// update of that measure, on whichever thread updates the skin, so it must answer quickly and from any thread:
    /// nothing slow (such as listing a folder) may happen in the call, and the call never waits for another thread.
    /// Default: nil. The app's `SystemMonitor` answers with `NSWorkspace.desktopImageURL(for:)` of the primary screen,
    /// looked at every 2 s at most; for a folder of rotating pictures — macOS does not say which one is showing — the
    /// folder's first picture by name, found on a background queue ("" until then). Only the main thread asks AppKit;
    /// another thread gets the main thread's latest answer ("" before its first one; an answer older than 2 s makes
    /// the main thread look again, for a later read). See `DesktopPictureCache`.
    func desktopPicturePath() -> String?
    /// Name of an Intel Mac's graphics processor as System Information shows it (for example "AMD Radeon Pro 5500M"
    /// or "Intel Iris Plus Graphics 655"); nil when unknown. Read by the Registry measure for `…\WinSat`
    /// `PrimaryAdapterString`, which on Apple silicon is the chip's name instead (its GPU is part of the chip).
    /// Default: nil. The app's `SystemMonitor` reads the PCI display controllers from the I/O Registry, once.
    func graphicsAdapterName() -> String?
}

extension SystemDataSource {
    /// Default: unknown.
    public func graphicsAdapterName() -> String? { nil }

    /// Default: the first active interface.
    public func bestNetworkInterface() -> String? {
        networkInterfaces().first
    }

    /// Default: Foundation's volume resource values (network / removable / optical / RAM disk by file system).
    public func volumeInfo(path: String) -> VolumeInfo? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        var keys: Set<URLResourceKey> = [.volumeNameKey, .volumeLocalizedNameKey, .volumeIsRemovableKey,
                                         .volumeIsLocalKey]
        if #available(macOS 13.3, *) { keys.insert(.volumeTypeNameKey) }
        let values = try? url.resourceValues(forKeys: keys)
        let label = values?.volumeLocalizedName ?? values?.volumeName ?? ""
        var fileSystem = ""
        if #available(macOS 13.3, *) { fileSystem = (values?.volumeTypeName ?? "").lowercased() }
        let kind: VolumeInfo.Kind
        if values?.volumeIsLocal == false {
            kind = .network
        } else if fileSystem == "cd9660" || fileSystem == "udf" || fileSystem == "cddafs" {
            kind = .cdRom
        } else if fileSystem == "tmpfs" {
            kind = .ram
        } else if values?.volumeIsRemovable == true {
            kind = .removable
        } else {
            kind = .fixed
        }
        return VolumeInfo(label: label, kind: kind)
    }

    /// Default: unknown.
    public func cpuFrequency() -> Double? { nil }

    /// Default: unknown (the Registry measure then reports the Wallpaper value as not emulated).
    public func desktopPicturePath() -> String? { nil }
}
