import AppKit
import Darwin
import IOKit
import IOKit.ps
import DesksetCore
import SystemConfiguration

/// System readings for all skins. Everything is read on demand and cached briefly, so many measures in many skins
/// share one system call and nothing runs while no skin asks (no background timers).
///
/// Any thread (docs/skin-threading.md §4.5): skins on different threads ask at the same time. Each cache group has a
/// lock of its own (`Guarded`); the quick readings (CPU ticks, memory, the interface list, the mount list) are taken
/// with the lock held, so one thread reads them and the others use its reading, while the slower ones (configd,
/// the process list, the power sources, SysInfo's lookups) are taken between two accesses, so no thread waits for
/// another's system call. The configd session is created at once and its calls are serialized, the utmpx walk is
/// serialized, and the desktop picture, which only AppKit knows, is published by the main thread. A network volume's
/// background reading is stored on the main thread, as before.
///
/// Readings were checked against the system tools: CPU against `top -l 2` (user + sys), memory against `vm_stat`
/// and Activity Monitor ("Memory Used" = app memory + wired + compressed), swap against `sysctl vm.swapusage`,
/// network counters against `netstat -ib`, disk space against `df -k`, battery against `pmset -g batt`, uptime
/// against `sysctl kern.boottime`.
final class SystemMonitor: SystemDataSource {
    static let shared = SystemMonitor()

    /// The last CPU tick sample and the usage worked out from it.
    private struct CPUState {
        var previousTicks: [[UInt32]] = []
        var usageByCore: [Double] = []
        var usageTotal = 0.0
        var lastSample: TimeInterval = 0
    }

    private let cpu = Guarded(CPUState())
    /// CPU usage is a difference between two tick samples; samples closer than this reuse the last result.
    static let minimumCPUSampleInterval: TimeInterval = 0.25

    private let cachedMemory = Guarded<(MemoryStatus, TimeInterval)?>(nil)
    private let cachedNet = Guarded<(NetSnapshot, TimeInterval)?>(nil)
    private let cachedBattery = Guarded<(BatteryStatus?, TimeInterval)?>(nil)
    private let cachedProcesses = Guarded<(Set<String>, TimeInterval)?>(nil)
    private let cachedAdapters = Guarded<([String: AdapterInfo], TimeInterval)?>(nil)
    private let cachedBest = Guarded<(String?, TimeInterval)?>(nil)
    private let cachedText = Guarded<[String: (value: (Double, String?)?, time: TimeInterval)]>([:])

    /// What every cache's age is measured with.
    private let clock: () -> TimeInterval

    /// The app has one monitor (`shared`). The threading self-tests make their own with a clock that runs an hour
    /// ahead at every look, so every reading is stale for every thread: all threads then take the readings and fill
    /// the caches at the same time, which the caches' short lifetimes otherwise make rare.
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        cpu.access { state in
            SystemMonitor.sampleCPU(&state)
            state.lastSample = clock()
        }
    }

    private func now() -> TimeInterval { clock() }

    // MARK: CPU

    var processorCount: Int { max(cpu.access { $0.usageByCore.count }, ProcessInfo.processInfo.processorCount) }

    func cpuUsage(processor: Int) -> Double {
        let t = now()
        return cpu.access { state in
            if t - state.lastSample >= SystemMonitor.minimumCPUSampleInterval {
                state.lastSample = t
                SystemMonitor.sampleCPU(&state)
            }
            if processor <= 0 { return state.usageTotal }
            return processor <= state.usageByCore.count ? state.usageByCore[processor - 1] : 0
        }
    }

    /// Takes a tick sample (with the CPU lock held: one thread samples, the others read its result).
    private static func sampleCPU(_ state: inout CPUState) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        let cores = min(Int(count), Int(infoCount) / max(states, 1))
        var ticks: [[UInt32]] = []
        ticks.reserveCapacity(cores)
        for core in 0..<cores {
            let base = core * states
            ticks.append((0..<states).map { UInt32(bitPattern: info[base + $0]) })
        }
        // First sample: the average since boot (zero ticks as the previous sample) instead of 0, so a skin's first
        // update — which fixes the window size of skins without DynamicWindowSize — sees a realistic value.
        let before = state.previousTicks.isEmpty ? ticks.map { Array(repeating: UInt32(0), count: $0.count) }
            : state.previousTicks
        let usage = SystemMonitor.cpuUsage(now: ticks, before: before)
        state.usageByCore = usage.perCore
        state.usageTotal = usage.total
        state.previousTicks = ticks
    }

    /// Busy share of the ticks between two samples (user + system + nice over all states), per core and overall.
    /// Counters wrap around at 2³²; a core count change resets to 0.
    static func cpuUsage(now: [[UInt32]], before: [[UInt32]]) -> (perCore: [Double], total: Double) {
        guard now.count == before.count, !now.isEmpty else { return (Array(repeating: 0, count: now.count), 0) }
        var usages: [Double] = []
        var busyAll = 0.0, totalAll = 0.0
        let idleIndex = Int(CPU_STATE_IDLE)
        for (n, b) in zip(now, before) {
            guard n.count == b.count, idleIndex < n.count else {
                usages.append(0)
                continue
            }
            let d = zip(n, b).map { Double($0 &- $1) }
            let total = d.reduce(0, +)
            let busy = total - d[idleIndex]
            usages.append(total > 0 ? min(max(busy / total * 100, 0), 100) : 0)
            busyAll += busy
            totalAll += total
        }
        return (usages, totalAll > 0 ? min(max(busyAll / totalAll * 100, 0), 100) : 0)
    }

    // MARK: Memory

    /// Read with the memory lock held (a few microseconds).
    func memoryStatus() -> MemoryStatus {
        cachedMemory.access { cache in
            if let c = cache, now() - c.1 < 0.5 { return c.0 }
            let status = SystemMonitor.readMemory()
            cache = (status, now())
            return status
        }
    }

    private static func readMemory() -> MemoryStatus {
        var status = MemoryStatus(physicalTotal: Double(ProcessInfo.processInfo.physicalMemory))
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            status.physicalUsed = SystemMonitor.usedMemory(stats, pageSize: Double(vm_kernel_page_size),
                                                           total: status.physicalTotal)
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            status.swapTotal = Double(swap.xsu_total)
            status.swapUsed = Double(swap.xsu_used)
        }
        return status
    }

    /// Activity Monitor's "Memory Used": app memory (anonymous pages minus purgeable) + wired + compressed.
    static func usedMemory(_ stats: vm_statistics64, pageSize: Double, total: Double) -> Double {
        let appPages = max(Double(stats.internal_page_count) - Double(stats.purgeable_count), 0)
        let used = (appPages + Double(stats.wire_count) + Double(stats.compressor_page_count)) * pageSize
        return min(max(used, 0), total)
    }

    // MARK: Network

    private struct NetSnapshot {
        var counters: [String: NetworkCounters] = [:]
        /// Up, physical (not loopback or virtual) interfaces that carried traffic, in interface-index order: the
        /// numbering of `Interface=N` / `SysInfoData=N`.
        var active: [String] = []
        var flags: [String: Int32] = [:]
        var baudRate: [String: UInt64] = [:]
    }

    /// The interface list, read with the network lock held (two sysctls): the counters of one reading are what every
    /// skin sees for half a second, and a reading builds on the previous one (see `fallback`).
    private func readNetwork() -> NetSnapshot {
        cachedNet.access { cache in
            if let c = cache, now() - c.1 < 0.5 { return c.0 }
            // When the interface list cannot be read (it can grow between the size query and the read, e.g. while a
            // VPN or AirDrop interface comes up), the last good snapshot is kept: an empty one would make every counter
            // drop to 0 and the next reading jump by all the traffic since boot — a huge NetIn / NetOut spike that
            // would also become the measure's automatic MaxValue.
            let fallback = cache?.0 ?? NetSnapshot()
            guard let snapshot = SystemMonitor.readInterfaces(fallback: fallback) else { return fallback }
            cache = (snapshot, now())
            return snapshot
        }
    }

    /// nil when the interface list cannot be read.
    private static func readInterfaces(fallback: NetSnapshot) -> NetSnapshot? {
        var snapshot = NetSnapshot()
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0, length < 64 * 1024 * 1024 else { return nil }
        length += 4096
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0, length <= buffer.count else { return nil }

        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if header.ifm_type == UInt8(RTM_IFINFO2), offset + MemoryLayout<if_msghdr2>.size <= length {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(msg.ifm_index), &nameBuffer) != nil {
                        let name = String(cString: nameBuffer)
                        let isLoopback = (msg.ifm_flags & IFF_LOOPBACK) != 0
                        let isUp = (msg.ifm_flags & IFF_UP) != 0
                        snapshot.flags[name] = msg.ifm_flags
                        snapshot.baudRate[name] = msg.ifm_data.ifi_baudrate
                        if !isLoopback {
                            // The byte counters in this list wrap at 4 GiB on current macOS (checked against
                            // `netstat -ib`); the interface MIB has the full 64-bit values. Should that read fail,
                            // the previous 64-bit value is kept rather than mixing in a wrapped one (which would
                            // look like a drop followed by a jump of several GiB).
                            let counters = SystemMonitor.interfaceCounters(index: Int32(msg.ifm_index))
                                ?? fallback.counters[name]
                                ?? NetworkCounters(received: msg.ifm_data.ifi_ibytes, sent: msg.ifm_data.ifi_obytes)
                            snapshot.counters[name] = counters
                            if isUp && (counters.received > 0 || counters.sent > 0)
                                && !SystemMonitor.isVirtualInterface(name) {
                                snapshot.active.append(name)
                            }
                        }
                    }
                }
                offset += messageLength
            }
        }
        return snapshot
    }

    /// 64-bit byte counters of one interface (`net.link.generic.ifdata.<index>.general`).
    static func interfaceCounters(index: Int32) -> NetworkCounters? {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, index, IFDATA_GENERAL]
        var data = ifmibdata()
        var size = MemoryLayout<ifmibdata>.size
        guard sysctl(&mib, 6, &data, &size, nil, 0) == 0 else { return nil }
        return NetworkCounters(received: data.ifmd_data.ifi_ibytes, sent: data.ifmd_data.ifi_obytes)
    }

    /// Virtual interfaces left out of "all interfaces": VPN tunnels (their traffic is also counted on the physical
    /// interface), AirDrop / low-latency WLAN, bridges, 6to4 / gif tunnels, Apple internal network adapters.
    static func isVirtualInterface(_ name: String) -> Bool {
        ["utun", "awdl", "llw", "bridge", "gif", "stf", "anpi", "ipsec", "ppp", "ap"].contains { name.hasPrefix($0) }
            && !name.hasPrefix("en")
    }

    func networkInterfaces() -> [String] { readNetwork().active }

    /// The interface `Interface=Best` / `SysInfoData=Best` measures (wired preferred over wireless, see
    /// `bestInterface`). Newer engines ask the data source for it directly.
    func bestNetworkInterface() -> String? { resolveAdapter("Best") }

    /// `interface`: nil = all physical interfaces; a BSD name (`en0`), an adapter name (`Wi-Fi`, `Ethernet`) or
    /// `Best` (the manual's default: the active interface, wired preferred over wireless).
    func networkCounters(interface: String?) -> NetworkCounters {
        let snapshot = readNetwork()
        guard let interface else {
            var total = NetworkCounters()
            for (name, c) in snapshot.counters where !SystemMonitor.isVirtualInterface(name) {
                total.received &+= c.received
                total.sent &+= c.sent
            }
            return total
        }
        guard let name = resolveAdapter(interface) else { return NetworkCounters() }
        return snapshot.counters[name] ?? NetworkCounters()
    }

    // MARK: Adapters (names, types, addresses)

    struct AdapterInfo {
        var bsdName: String
        var displayName: String
        var isWireless: Bool
        var isEthernet: Bool
        /// Name of the network service using the interface (System Settings → Network), if any.
        var serviceName: String?
    }

    /// SystemConfiguration's view of the network hardware, cached for 30 s. Read without the lock (configd round
    /// trips): two threads that find it stale at once both read it, and the later reading is kept.
    private func adapters() -> [String: AdapterInfo] {
        if let c = cachedAdapters.current, now() - c.1 < 30 { return c.0 }
        let result = SystemMonitor.readAdapters()
        cachedAdapters.access { $0 = (result, now()) }
        return result
    }

    private static func readAdapters() -> [String: AdapterInfo] {
        var result: [String: AdapterInfo] = [:]
        if let list = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for item in list {
                guard let bsd = SCNetworkInterfaceGetBSDName(item) as String? else { continue }
                let type = SCNetworkInterfaceGetInterfaceType(item) as String? ?? ""
                let display = SCNetworkInterfaceGetLocalizedDisplayName(item) as String? ?? bsd
                result[bsd] = AdapterInfo(bsdName: bsd, displayName: display,
                                          isWireless: type == (kSCNetworkInterfaceTypeIEEE80211 as String),
                                          isEthernet: type == (kSCNetworkInterfaceTypeEthernet as String))
            }
        }
        if let prefs = SCPreferencesCreate(nil, "Deskset" as CFString, nil),
           let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] {
            for service in services.prefix(256) {
                guard let interface = SCNetworkServiceGetInterface(service),
                      let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                      let name = SCNetworkServiceGetName(service) as String?, result[bsd]?.serviceName == nil
                else { continue }
                result[bsd]?.serviceName = name
            }
        }
        return result
    }

    /// BSD name of the primary interface (the one carrying the default route).
    private func primaryInterface() -> String? {
        globalNetworkValue("State:/Network/Global/IPv4", "PrimaryInterface") as? String
            ?? globalNetworkValue("State:/Network/Global/IPv6", "PrimaryInterface") as? String
    }

    /// One configd session for all lookups (creating a store per reading opened a new connection every time). Created
    /// with the monitor, not on first use by whichever thread asks first; its calls go through `withDynamicStore`.
    private let dynamicStore: SCDynamicStore? = SCDynamicStoreCreate(nil, "Deskset" as CFString, nil, nil)
    private let dynamicStoreLock = NSLock()

    /// Runs `body` with the configd session, one thread at a time: the session is shared by every skin, and
    /// SystemConfiguration does not say that one session may be used from several threads at once. The lookups are
    /// rare (their results are cached) and quick.
    private func withDynamicStore<T>(_ body: (SCDynamicStore) -> T?) -> T? {
        guard let store = dynamicStore else { return nil }
        dynamicStoreLock.lock()
        defer { dynamicStoreLock.unlock() }
        return body(store)
    }

    private func globalNetworkValue(_ key: String, _ field: String) -> Any? {
        guard let dict = withDynamicStore({ SCDynamicStoreCopyValue($0, key as CFString) as? [String: Any] })
        else { return nil }
        return dict[field]
    }

    /// Resolves SysInfoData / Interface values: empty or `Best` → the best active interface; a number N → the Nth
    /// active interface (1-based, as `Interface=N`); otherwise a BSD name or adapter name (case-insensitive).
    func resolveAdapter(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespaces)
        let snapshot = readNetwork()
        if key.isEmpty || key.caseInsensitiveCompare("Best") == .orderedSame {
            // NetIn/NetOut with Interface=Best ask on every update: the choice is kept for a few seconds. It is worked
            // out without the lock (it asks configd); two threads may both do it, the later choice is kept.
            if let c = cachedBest.current, now() - c.1 < 3 { return c.0 }
            let best = bestInterface(snapshot)
            cachedBest.access { $0 = (best, now()) }
            return best
        }
        if let n = Int(key) {
            return n >= 1 && n <= snapshot.active.count ? snapshot.active[n - 1] : (n == 0 ? resolveAdapter("Best") : nil)
        }
        if let exact = snapshot.flags.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
            return exact
        }
        let adapters = self.adapters()
        let matches = adapters.values.filter { $0.displayName.caseInsensitiveCompare(key) == .orderedSame }
            .map(\.bsdName).sorted()
        return matches.first { snapshot.active.contains($0) } ?? matches.first
    }

    /// "Best": "will select a 'wired' network connection in preference to a 'wireless' one, if both are active";
    /// otherwise the primary interface, otherwise the first active one.
    private func bestInterface(_ snapshot: NetSnapshot) -> String? {
        let adapters = self.adapters()
        let connected = snapshot.active.filter { name in
            let flags = snapshot.flags[name] ?? 0
            return (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0 && !SystemMonitor.isVirtualInterface(name)
                && !ipv4Addresses(interface: name).isEmpty
        }
        if let wired = connected.first(where: { adapters[$0]?.isEthernet == true }) { return wired }
        if let primary = primaryInterface(), snapshot.counters[primary] != nil { return primary }
        return connected.first ?? snapshot.active.first { !SystemMonitor.isVirtualInterface($0) }
    }

    private struct InterfaceAddress {
        var name: String
        var family: Int32
        var address: String
        var netmask: String
        var flags: Int32
    }

    private func interfaceAddresses() -> [InterfaceAddress] {
        var result: [InterfaceAddress] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var guardCount = 0
        while let entry = cursor, guardCount < 10_000 {
            guardCount += 1
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            let name = String(cString: entry.pointee.ifa_name)
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            if family == AF_LINK {
                let mac = SystemMonitor.linkAddress(addr)
                result.append(InterfaceAddress(name: name, family: family, address: mac, netmask: "", flags: flags))
            } else if family == AF_INET || family == AF_INET6 {
                result.append(InterfaceAddress(name: name, family: family, address: SystemMonitor.numericHost(addr),
                                               netmask: entry.pointee.ifa_netmask.map(SystemMonitor.numericHost) ?? "",
                                               flags: flags))
            }
        }
        return result
    }

    private static func numericHost(_ addr: UnsafeMutablePointer<sockaddr>) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(addr.pointee.sa_len)
        guard length > 0, getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return ""
        }
        return String(cString: host)
    }

    /// `AA:BB:CC:DD:EE:FF` from an AF_LINK sockaddr.
    private static func linkAddress(_ addr: UnsafeMutablePointer<sockaddr>) -> String {
        addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl -> String in
            let nameLength = Int(dl.pointee.sdl_nlen), addressLength = Int(dl.pointee.sdl_alen)
            guard addressLength == 6 else { return "" }
            let base = UnsafeRawPointer(dl).advanced(by: MemoryLayout.offset(of: \sockaddr_dl.sdl_data) ?? 8)
            let bytes = (0..<addressLength).map { base.load(fromByteOffset: nameLength + $0, as: UInt8.self) }
            return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
        }
    }

    private func ipv4Addresses(interface: String? = nil) -> [String] {
        interfaceAddresses().filter {
            $0.family == AF_INET && ($0.flags & IFF_LOOPBACK) == 0 && ($0.flags & IFF_UP) != 0
                && (interface == nil || $0.name == interface)
        }.map(\.address)
    }

    /// Routable (not link-local) addresses of one family on an interface, or on any interface when nil.
    private func hasRoutableAddress(family: Int32, interface: String?) -> Bool {
        interfaceAddresses().contains {
            $0.family == family && ($0.flags & IFF_LOOPBACK) == 0 && ($0.flags & IFF_UP) != 0
                && ($0.flags & IFF_RUNNING) != 0 && (interface == nil || $0.name == interface)
                && !$0.address.hasPrefix("169.254.") && !$0.address.lowercased().hasPrefix("fe80")
                && !SystemMonitor.isVirtualInterface($0.name)
        }
    }

    // MARK: Disk

    /// Local volumes are read directly. Network volumes (SMB, AFP, NFS, WebDAV, autofs…) are read on a background
    /// queue and answered from the last reading: `statfs` on a share whose server went away (a laptop that left the
    /// home network) blocks for tens of seconds, and on the main thread that froze every skin and menu on each update.
    func diskSpace(path: String) -> (total: Double, free: Double)? {
        guard SystemMonitor.mountIsLocal(path, mounts: mounts()) == false else { return SystemMonitor.statfsSpace(path) }
        return networkVolume(path)?.space
    }

    /// FreeDiskSpace `Type=1` / `Label=1`: the volume's name and kind. Local volumes are read at most every few
    /// seconds (the measure asks on every update); network volumes come from the background reading `diskSpace`
    /// uses, so an unreachable server never blocks the main thread (until the first reading arrives the volume
    /// counts as removed).
    func volumeInfo(path: String) -> VolumeInfo? {
        guard SystemMonitor.mountIsLocal(path, mounts: mounts()) == false else {
            let t = now()
            if let hit = disk.access({ $0.localVolumes[path] }), t - hit.time < 3 { return hit.info }
            let info = SystemMonitor.readVolumeInfo(path)
            disk.access { state in
                if state.localVolumes.count >= 64 { state.localVolumes.removeAll() }
                state.localVolumes[path] = (info, t)
            }
            return info
        }
        return networkVolume(path)?.info
    }

    /// The last background reading of a network volume; starts a new one when it is older than 5 seconds. The
    /// reading is stored under the lock on the main thread, as before skins could leave it: between the updates of
    /// the skins that run there (today every skin), so a volume's size and free space come from one reading.
    private func networkVolume(_ path: String) -> NetworkVolume? {
        let t = now()
        let (hit, start) = disk.access { state -> ((value: NetworkVolume, time: TimeInterval)?, Bool) in
            let hit = state.networkVolumes[path]
            let start = (hit == nil || t - (hit?.time ?? 0) >= 5) && !state.pending.contains(path)
                && state.pending.count < 16
            if start { state.pending.insert(path) }
            return (hit, start)
        }
        if start {
            diskQueue.async { [weak self] in
                let value = NetworkVolume(space: SystemMonitor.statfsSpace(path),
                                          info: SystemMonitor.readVolumeInfo(path))
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.disk.access { state in
                        state.pending.remove(path)
                        if state.networkVolumes.count >= 64 { state.networkVolumes.removeAll() }
                        state.networkVolumes[path] = (value, self.now())
                    }
                }
            }
        }
        return hit?.value
    }

    private struct NetworkVolume {
        var space: (total: Double, free: Double)?
        var info: VolumeInfo?
    }

    /// Volume readings: network volumes' background readings and those in flight, local volumes' names and kinds.
    private struct DiskState {
        var networkVolumes: [String: (value: NetworkVolume, time: TimeInterval)] = [:]
        var pending: Set<String> = []
        var localVolumes: [String: (info: VolumeInfo?, time: TimeInterval)] = [:]
    }

    private let disk = Guarded(DiskState())
    private let diskQueue = DispatchQueue(label: "deskset.disk", qos: .utility)

    /// Name and kind of the volume holding `path` (nil when `path` does not exist). Blocks on unreachable network
    /// volumes: call it for those only off the main thread.
    static func readVolumeInfo(_ path: String) -> VolumeInfo? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let fileSystem = withUnsafeBytes(of: s.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }.lowercased()
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
            .volumeLocalizedNameKey, .volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
        ])
        let label = values?.volumeLocalizedName ?? values?.volumeName ?? ""
        return VolumeInfo(label: label, kind: volumeKind(fileSystem: fileSystem, local: (s.f_flags & UInt32(MNT_LOCAL)) != 0,
                                                         removable: values?.volumeIsRemovable == true
                                                             || values?.volumeIsEjectable == true))
    }

    /// FreeDiskSpace `Type`: network unless the mount is local; optical discs by their file systems; RAM disks
    /// (tmpfs); removable / ejectable media; otherwise fixed.
    static func volumeKind(fileSystem: String, local: Bool, removable: Bool) -> VolumeInfo.Kind {
        if !local { return .network }
        if ["cd9660", "udf", "cddafs"].contains(fileSystem) { return .cdRom }
        if fileSystem == "tmpfs" { return .ram }
        return removable ? .removable : .fixed
    }
    private let cachedMounts = Guarded<([(path: String, local: Bool)], TimeInterval)?>(nil)

    static func statfsSpace(_ path: String) -> (total: Double, free: Double)? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let block = Double(s.f_bsize)
        return (Double(s.f_blocks) * block, Double(s.f_bavail) * block)
    }

    /// Mount points and whether they are local, from the kernel's cached list (`MNT_NOWAIT` never waits for a file
    /// server), refreshed every few seconds, with the lock held (one quick system call).
    private func mounts() -> [(path: String, local: Bool)] {
        cachedMounts.access { cache in
            if let c = cache, now() - c.1 < 5 { return c.0 }
            let result = SystemMonitor.readMounts()
            cache = (result, now())
            return result
        }
    }

    private static func readMounts() -> [(path: String, local: Bool)] {
        var result: [(path: String, local: Bool)] = []
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        if count > 0 && count < 4096 {
            let empty = statfs()
            var buffer = Array(repeating: empty, count: Int(count) + 16)
            let n = buffer.withUnsafeMutableBufferPointer {
                getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
            }
            for i in 0..<min(max(Int(n), 0), buffer.count) {
                let path = withUnsafeBytes(of: buffer[i].f_mntonname) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                result.append((path, (buffer[i].f_flags & UInt32(MNT_LOCAL)) != 0))
            }
        }
        return result
    }

    /// Whether the volume holding `path` is local: the mount point with the longest matching prefix decides. nil
    /// when no mount matches (treated as local).
    static func mountIsLocal(_ path: String, mounts: [(path: String, local: Bool)]) -> Bool? {
        let p = (path as NSString).standardizingPath
        var best: (length: Int, local: Bool)?
        for m in mounts where !m.path.isEmpty {
            let matches = m.path == "/" || p == m.path || p.hasPrefix(m.path.hasSuffix("/") ? m.path : m.path + "/")
            if matches, best == nil || m.path.count > best!.length { best = (m.path.count, m.local) }
        }
        return best?.local
    }

    // MARK: Uptime

    func uptime() -> TimeInterval {
        guard let boot = SystemMonitor.sysctlTime("kern.boottime") else { return ProcessInfo.processInfo.systemUptime }
        return max(Date().timeIntervalSince1970 - boot, 0)
    }

    /// A `struct timeval` sysctl (kern.boottime, kern.sleeptime, kern.waketime) as seconds since 1970; nil when 0.
    static func sysctlTime(_ name: String) -> TimeInterval? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }

    // MARK: CPU frequency

    /// PowerPlugin `PowerState=Hz` / `MHz`: the rated CPU frequency (`hw.cpufrequency`, Intel Macs only; Apple
    /// Silicon has no public value, so nil there). Read once.
    func cpuFrequency() -> Double? { SystemMonitor.ratedCPUFrequency }

    private static let ratedCPUFrequency: Double? = {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.cpufrequency", &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Double(value)
    }()

    // MARK: Graphics processor

    /// Registry `…\WinSat` `PrimaryAdapterString` on an Intel Mac. Read once.
    func graphicsAdapterName() -> String? { SystemMonitor.graphicsName }

    /// The PCI display controllers' names from the I/O Registry, a discrete GPU (AMD, NVIDIA) before an integrated
    /// Intel one, as WinSAT would name the adapter it rated. Reading the registry never wakes a graphics processor,
    /// unlike creating a Metal device. Apple silicon has none here: its GPU is part of the chip.
    private static let graphicsName: String? = {
        guard let matching = IOServiceMatching("IOPCIDevice") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        func data(_ service: io_object_t, _ key: String) -> Data? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
        }
        var names: [String] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            // PCI class code, little-endian: programming interface, subclass, class. Class 3 is a display controller.
            guard let code = data(service, "class-code"), code.count >= 3, code[code.startIndex + 2] == 0x03,
                  let model = data(service, "model") else { continue }
            let name = String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Rosetta shows an Intel build a placeholder display controller named "Unknown Unknown".
            guard !name.lowercased().split(separator: " ").allSatisfy({ $0 == "unknown" }) else { continue }
            names.append(name)
        }
        return names.first { !$0.lowercased().hasPrefix("intel") } ?? names.first
    }()

    // MARK: Desktop picture

    /// Registry `HKCU\Control Panel\Desktop` `Wallpaper`: the desktop picture of the primary screen (the one with the
    /// menu bar), "" when there is none. Any thread: AppKit is asked on the main thread only, and other threads get
    /// what the main thread found last (see `DesktopPictureCache.published`).
    func desktopPicturePath() -> String? {
        desktopPicture.published.value()
    }

    private let desktopPicture = DesktopPictureCache()

    // MARK: Battery

    /// Read without the lock (IOKit asks the power management daemon).
    func battery() -> BatteryStatus? {
        if let c = cachedBattery.current, now() - c.1 < 5 { return c.0 }
        let result = SystemMonitor.readBattery()
        cachedBattery.access { $0 = (result, now()) }
        return result
    }

    private static func readBattery() -> BatteryStatus? {
        var result: BatteryStatus?
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                      (d[kIOPSIsPresentKey] as? Bool) != false else { continue }
                result = SystemMonitor.batteryStatus(d)
            }
        }
        return result
    }

    /// Reads an IOPowerSources description (`pmset -g batt` shows the same values).
    static func batteryStatus(_ d: [String: Any]) -> BatteryStatus {
        func number(_ key: String) -> Double? { (d[key] as? NSNumber)?.doubleValue }
        let current = number(kIOPSCurrentCapacityKey) ?? 0
        let maxCap = number(kIOPSMaxCapacityKey) ?? 100
        let charging = d[kIOPSIsChargingKey] as? Bool ?? false
        let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let minutes = number(kIOPSTimeToEmptyKey)
        let percent = maxCap > 0 ? min(max(current / maxCap * 100, 0), 100) : 0
        return BatteryStatus(percent: percent, isCharging: charging, isPluggedIn: plugged,
                             minutesRemaining: !plugged && (minutes ?? -1) > 0 ? minutes : nil)
    }

    // MARK: Processes

    /// The process list is read without the lock (it takes a few milliseconds). `NSWorkspace.runningApplications`
    /// may be called from any thread ("the result is returned atomically", NSRunningApplication.h).
    func isProcessRunning(_ name: String) -> Bool {
        let names: Set<String>
        if let c = cachedProcesses.current, now() - c.1 < 2 {
            names = c.0
        } else {
            var set = Set<String>()
            for app in NSWorkspace.shared.runningApplications {
                if let n = app.localizedName { set.insert(n.lowercased()) }
                if let n = app.executableURL?.lastPathComponent { set.insert(n.lowercased()) }
            }
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            var size = 0
            if sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0, size < 256 * 1024 * 1024 {
                let count = size / MemoryLayout<kinfo_proc>.stride + 16
                var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
                size = count * MemoryLayout<kinfo_proc>.stride
                if sysctl(&mib, 4, &procs, &size, nil, 0) == 0 {
                    for i in 0..<min(size / MemoryLayout<kinfo_proc>.stride, count) {
                        let comm = procs[i].kp_proc.p_comm
                        let n = withUnsafeBytes(of: comm) { raw in
                            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                        }
                        set.insert(n.lowercased())
                    }
                }
            }
            names = set
            cachedProcesses.access { $0 = (set, now()) }
        }
        let key = name.lowercased()
        // The kernel keeps only the first 16 bytes of a command name (MAXCOMLEN).
        return names.contains(key) || (key.utf8.count > Int(MAXCOMLEN) && names.contains(String(decoding: key.utf8.prefix(Int(MAXCOMLEN)), as: UTF8.self)))
    }

    // MARK: SysInfo

    /// SysInfo measure (https://docs.rainmeter.net/manual/measures/sysinfo/): the types that need the system. The
    /// engine answers the ones it can compute itself (`engineSysInfoTypes`: monitors, time zone, OS_BITS, PAGESIZE)
    /// before asking, so they are not answered here. Network values take SysInfoData = Best (default), an index, a
    /// BSD name or an adapter name. Timestamps are Windows timestamps (seconds since 1601-01-01, local time).
    func sysInfo(type: String, data: String) -> (number: Double, string: String?)? {
        // Network details change rarely but skins read them on every update: each one used to cost a configd
        // round trip or a full getifaddrs walk per update and measure.
        if SystemMonitor.shortCachedTypes.contains(type) {
            return cached(type + "|" + data, seconds: 2) { self.uncachedSysInfo(type: type, data: data) }
        }
        return uncachedSysInfo(type: type, data: data)
    }

    /// SysInfo types answered from a 2-second cache.
    static let shortCachedTypes: Set<String> = [
        "IP_ADDRESS", "NET_MASK", "MAC_ADDRESS", "ADAPTER_DESCRIPTION", "ADAPTER_ALIAS", "ADAPTER_TYPE",
        "ADAPTER_STATE", "ADAPTER_STATUS", "ADAPTER_TRANSMIT_SPEED", "ADAPTER_RECEIVE_SPEED", "GATEWAY_ADDRESS",
        "GATEWAY_ADDRESS_V4", "GATEWAY_ADDRESS_V6", "DNS_SERVER", "DOMAIN_NAME", "DOMAIN_WORKGROUP",
        "LAN_CONNECTIVITY", "LAN_CONNECTIVITY_V4", "LAN_CONNECTIVITY_V6",
    ]

    /// SysInfo types the engine computes itself (`SysInfoMeasure`); the data source is not asked for them.
    static let engineSysInfoTypes: Set<String> = [
        "OS_BITS", "PAGESIZE", "NUM_MONITORS", "SCREEN_SIZE", "SCREEN_WIDTH", "SCREEN_HEIGHT", "VIRTUAL_SCREEN_TOP",
        "VIRTUAL_SCREEN_LEFT", "VIRTUAL_SCREEN_WIDTH", "VIRTUAL_SCREEN_HEIGHT", "WORK_AREA", "WORK_AREA_TOP",
        "WORK_AREA_LEFT", "WORK_AREA_WIDTH", "WORK_AREA_HEIGHT", "TIMEZONE_ISDST", "TIMEZONE_BIAS",
        "TIMEZONE_STANDARD_BIAS", "TIMEZONE_DAYLIGHT_BIAS", "TIMEZONE_STANDARD_NAME", "TIMEZONE_DAYLIGHT_NAME",
    ]

    private func uncachedSysInfo(type: String, data: String) -> (number: Double, string: String?)? {
        switch type {
        // "The computer's name as specified in the system settings" / "network host name": configd lookups, kept
        // for a minute (never `ProcessInfo.hostName`, which can wait for a DNS reply).
        case "COMPUTER_NAME":
            return cached(type, seconds: 60) {
                (0, SCDynamicStoreCopyComputerName(nil, nil) as String? ?? SystemMonitor.unixHostName())
            }
        case "HOST_NAME":
            return cached(type, seconds: 60) {
                let local = SCDynamicStoreCopyLocalHostName(nil) as String?
                return (0, local ?? SystemMonitor.unixHostName())
            }
        case "USER_NAME":
            return (0, NSUserName())
        case "USER_LOGONTIME":
            return cached(type, seconds: 60) { (self.logonTime().map(SystemMonitor.windowsTimestamp) ?? 0, nil) }
        case "LAST_SLEEP_TIME", "LAST_WAKE_TIME":
            let t = SystemMonitor.sysctlTime(type == "LAST_SLEEP_TIME" ? "kern.sleeptime" : "kern.waketime")
            // Whole seconds, like the other timestamps.
            return (t.map { SystemMonitor.windowsTimestamp($0).rounded(.down) } ?? 0, nil)
        case "OS_PRODUCT_NAME":
            return (0, SystemMonitor.productName())
        case "OS_VERSION":
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return (0, "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : ""))
        case "IDLE_TIME":
            return (idleSeconds(), nil)

        // Network
        case "IP_ADDRESS", "NET_MASK":
            guard let name = resolveAdapter(data) else { return (0, "") }
            let entry = interfaceAddresses().first { $0.name == name && $0.family == AF_INET }
            return (0, (type == "IP_ADDRESS" ? entry?.address : entry?.netmask) ?? "")
        case "MAC_ADDRESS":
            guard let name = resolveAdapter(data) else { return (0, "") }
            return (0, interfaceAddresses().first { $0.name == name && $0.family == AF_LINK }?.address ?? "")
        case "ADAPTER_DESCRIPTION":
            // "The description (name) of the network adapter": the hardware's name ("Wi-Fi", "USB 10/100/1000 LAN").
            guard let name = resolveAdapter(data) else { return (0, "") }
            return (0, adapters()[name]?.displayName ?? name)
        case "ADAPTER_ALIAS":
            // "The network interface connected to by the network adapter": the network service using it, as named
            // in System Settings → Network (its alias on Windows: "Ethernet 1", "WiFi 3").
            guard let name = resolveAdapter(data) else { return (0, "") }
            return (0, adapters()[name]?.serviceName ?? adapters()[name]?.displayName ?? name)
        case "ADAPTER_TYPE":
            guard let name = resolveAdapter(data), let info = adapters()[name] else { return (1, "Other") }
            if info.isWireless { return (71, "Wireless") }
            if info.isEthernet { return (6, "Ethernet") }
            return (1, "Other")
        case "ADAPTER_STATE":
            // "The 'media connected state' … 1 for connected, and -1 for disconnected … Any other state returns 0 and
            // Unknown." Interfaces with a medium (Ethernet, Wi-Fi) report its link; others (tunnels) count as
            // connected while up and running.
            guard let name = resolveAdapter(data), let flags = readNetwork().flags[name] else { return (0, "Unknown") }
            let connected = SystemMonitor.mediaActive(name)
                ?? ((flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0)
            return connected ? (1, "Connected") : (-1, "Disconnected")
        case "ADAPTER_STATUS":
            // Operational status: Up needs the interface up and, where there is a medium, a link.
            guard let name = resolveAdapter(data), let flags = readNetwork().flags[name] else { return (-3, "Not Present") }
            let up = (flags & IFF_UP) != 0 && (SystemMonitor.mediaActive(name) ?? ((flags & IFF_RUNNING) != 0))
            return up ? (1, "Up") : (-1, "Down")
        case "ADAPTER_TRANSMIT_SPEED", "ADAPTER_RECEIVE_SPEED":
            guard let name = resolveAdapter(data) else { return (0, nil) }
            return (Double(readNetwork().baudRate[name] ?? 0), nil)
        case "GATEWAY_ADDRESS", "GATEWAY_ADDRESS_V4", "GATEWAY_ADDRESS_V6":
            let v6 = type.hasSuffix("V6")
            let name = resolveAdapter(data)
            let router = routerAddress(ipv6: v6, interface: name)
                ?? (type == "GATEWAY_ADDRESS" ? routerAddress(ipv6: true, interface: name) : nil)
            return (0, router ?? "")
        case "DNS_SERVER":
            let servers = globalNetworkValue("State:/Network/Global/DNS", "ServerAddresses") as? [String]
            return (0, servers?.first ?? "")
        case "DOMAIN_NAME":
            let domain = globalNetworkValue("State:/Network/Global/DNS", "DomainName") as? String
                ?? (globalNetworkValue("State:/Network/Global/DNS", "SearchDomains") as? [String])?.first
            return (0, domain ?? "")
        case "DOMAIN_WORKGROUP":
            let smb = UserDefaults(suiteName: "/Library/Preferences/SystemConfiguration/com.apple.smb.server")
            return (0, smb?.string(forKey: "Workgroup") ?? "WORKGROUP")
        case "LAN_CONNECTIVITY", "LAN_CONNECTIVITY_V4", "LAN_CONNECTIVITY_V6":
            let adapter = data.trimmingCharacters(in: .whitespaces).isEmpty ? nil : resolveAdapter(data)
            let families: [Int32] = type.hasSuffix("V4") ? [AF_INET] : type.hasSuffix("V6") ? [AF_INET6] : [AF_INET, AF_INET6]
            let up = families.contains { hasRoutableAddress(family: $0, interface: adapter) }
            return up ? (1, nil) : (-1, nil)
        case "INTERNET_CONNECTIVITY", "INTERNET_CONNECTIVITY_V4", "INTERNET_CONNECTIVITY_V6":
            return cached(type + data, seconds: 5) {
                let v6Only = type.hasSuffix("V6"), v4Only = type.hasSuffix("V4")
                let ok = (!v6Only && self.internetReachable(ipv6: false)) || (!v4Only && self.internetReachable(ipv6: true))
                return ok ? (1, nil) : (-1, nil)
            }

        default:
            return nil
        }
    }

    /// A SysInfo value kept for `seconds`. It is worked out without the lock (configd, reachability): two threads
    /// that find it stale at once both work it out, and the later value is kept.
    private func cached(_ key: String, seconds: TimeInterval,
                        _ compute: () -> (Double, String?)?) -> (number: Double, string: String?)? {
        if let hit = cachedText.access({ $0[key] }), now() - hit.time < seconds { return hit.value.map { ($0.0, $0.1) } }
        let value = compute()
        cachedText.access { $0[key] = (value, now()) }
        return value.map { ($0.0, $0.1) }
    }

    /// Windows timestamp (seconds since 1601-01-01, local wall clock, like the Time measure's value).
    static func windowsTimestamp(_ unix: TimeInterval) -> Double {
        let local = unix + Double(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: unix)))
        return local + 11_644_473_600
    }

    static func productName() -> String {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let names = [13: "Ventura", 14: "Sonoma", 15: "Sequoia", 26: "Tahoe"]
        return names[major].map { "macOS \($0)" } ?? "macOS"
    }

    /// `gethostname` (no network lookup).
    static func unixHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "" }
        return String(cString: buffer)
    }

    /// Link state of an interface with a medium (`ifconfig`'s "status: active"); nil when the interface has no
    /// media information (loopback, tunnels) or does not exist.
    static func mediaActive(_ interface: String) -> Bool? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var request = ifmediareq()
        let name = Array(interface.utf8.prefix(Int(IFNAMSIZ) - 1))
        withUnsafeMutableBytes(of: &request.ifm_name) { raw in
            for (i, byte) in name.enumerated() where i < raw.count { raw[i] = byte }
        }
        // SIOCGIFMEDIA = _IOWR('i', 56, struct ifmediareq) (the C macro is not imported into Swift).
        let command = UInt(0xC000_0000) | (UInt(MemoryLayout<ifmediareq>.size & 0x1FFF) << 16)
            | (UInt(UInt8(ascii: "i")) << 8) | 56
        guard ioctl(fd, command, &request) == 0 else { return nil }
        let valid: Int32 = 0x1, active: Int32 = 0x2   // IFM_AVALID, IFM_ACTIVE
        guard request.ifm_status & valid != 0 else { return nil }
        return request.ifm_status & active != 0
    }

    /// Seconds since the last keyboard / mouse input (IOHIDSystem `HIDIdleTime`, nanoseconds).
    private func idleSeconds() -> Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber else { return 0 }
        return value.doubleValue / 1_000_000_000
    }

    /// `getutxent` walks one database position shared by the whole process: two walks at once would skip each other's
    /// entries.
    private static let utmpxLock = NSLock()

    /// Login time of the current console user (utmpx), one walk at a time. (Not private: the threading self-tests
    /// walk it from several threads at once.)
    func logonTime() -> TimeInterval? {
        let user = NSUserName()
        var earliest: TimeInterval?
        SystemMonitor.utmpxLock.lock()
        defer { SystemMonitor.utmpxLock.unlock() }
        setutxent()
        defer { endutxent() }
        var count = 0
        while let entry = getutxent(), count < 100_000 {
            count += 1
            guard entry.pointee.ut_type == USER_PROCESS else { continue }
            let name = withUnsafeBytes(of: entry.pointee.ut_user) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard name == user else { continue }
            let t = Double(entry.pointee.ut_tv.tv_sec)
            if earliest == nil || t < earliest! { earliest = t }
        }
        return earliest
    }

    /// Router of the primary interface (or of `interface` when it has its own service).
    private func routerAddress(ipv6: Bool, interface: String?) -> String? {
        let family = ipv6 ? "IPv6" : "IPv4"
        if let global = withDynamicStore({
               SCDynamicStoreCopyValue($0, "State:/Network/Global/\(family)" as CFString) as? [String: Any]
           }),
           interface == nil || (global["PrimaryInterface"] as? String) == interface,
           let router = global["Router"] as? String {
            return router
        }
        guard let interface,
              let values = withDynamicStore({
                  SCDynamicStoreCopyMultiple($0, nil, ["State:/Network/Service/[^/]+/\(family)"] as CFArray)
                      as? [String: Any]
              })
        else { return nil }
        for case let dict as [String: Any] in values.values where (dict["InterfaceName"] as? String) == interface {
            if let router = dict["Router"] as? String { return router }
        }
        return nil
    }

    /// Internet connectivity over one IP version: the family needs a primary service (a default route, what
    /// `scutil --nwi` lists), and that route must be usable. SCNetworkReachability alone is not enough: for the
    /// unspecified IPv6 address it answers "reachable" whenever IPv4 works, even on networks without IPv6.
    private func internetReachable(ipv6: Bool) -> Bool {
        guard globalNetworkValue("State:/Network/Global/\(ipv6 ? "IPv6" : "IPv4")", "PrimaryInterface") != nil
        else { return false }
        return SystemMonitor.reachable(ipv6: ipv6)
    }

    /// Whether the default route can reach the Internet (no connection needs to be established first).
    private static func reachable(ipv6: Bool) -> Bool {
        var flags = SCNetworkReachabilityFlags()
        let ok: Bool
        if ipv6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            ok = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    guard let target = SCNetworkReachabilityCreateWithAddress(nil, sa) else { return false }
                    return SCNetworkReachabilityGetFlags(target, &flags)
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            ok = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    guard let target = SCNetworkReachabilityCreateWithAddress(nil, sa) else { return false }
                    return SCNetworkReachabilityGetFlags(target, &flags)
                }
            }
        }
        return ok && flags.contains(.reachable) && !flags.contains(.connectionRequired)
    }
}

// MARK: - Desktop picture

/// The desktop picture file for the Registry measure's `Wallpaper` value (`SystemMonitor.desktopPicturePath()`),
/// answered quickly, since a skin asks at every update of such a measure:
/// - the setting (`NSWorkspace.desktopImageURL(for:)` of the primary screen) is looked at most every
///   `settingInterval` seconds;
/// - a picture file is answered as is, without touching the file system;
/// - anything else is probably a folder of rotating pictures. macOS does not say which of its pictures is showing,
///   so the answer is the folder's first picture by name (as for Chameleon `Type=Desktop`), "" for a folder without
///   pictures. The folder is looked into on a background queue (it may be on a slow or unreachable volume); until
///   the first look finishes the answer is "", and the result is reused for `folderInterval` seconds.
///
/// Only the main thread asks AppKit (`path()`); it publishes each answer, and a skin on another thread reads the
/// latest one (`published`). That answer is at most `settingInterval` seconds old when the main thread is free; an
/// older one makes the main thread look again, and a later read sees the change. Before the main thread's first
/// answer, the other threads get "" (like a folder not looked into yet).
final class DesktopPictureCache {
    static let settingInterval: TimeInterval = 2
    static let folderInterval: TimeInterval = 30

    /// The configured desktop picture (file or folder path), "" for none. Main thread; replaced in tests.
    var setting: () -> String = {
        guard let screen = NSScreen.screens.first else { return "" }
        return NSWorkspace.shared.desktopImageURL(for: screen)?.path ?? ""
    }
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime } {
        didSet { published.clock = clock }
    }
    var queue = DispatchQueue(label: "deskset.desktop-picture", qos: .utility)

    /// The answer for any thread: `path()` on the main thread, the latest one published elsewhere.
    let published = MainPublished<String>(maxAge: DesktopPictureCache.settingInterval, initial: "", compute: { "" })

    // Main thread only.
    private var lastSetting: (path: String, time: TimeInterval)?
    private var folder: (path: String, picture: String, time: TimeInterval)?
    private var pendingFolder: String?

    init() {
        published.compute = { [unowned self] in self.path() }
    }

    /// Main thread. Publishes its answer (`published`).
    func path() -> String {
        let answer = lookUp()
        published.publish(answer)
        return answer
    }

    private func lookUp() -> String {
        let now = clock()
        let setting: String
        if let last = lastSetting, now - last.time < DesktopPictureCache.settingInterval {
            setting = last.path
        } else {
            setting = self.setting()
            lastSetting = (setting, now)
        }
        if setting.isEmpty || DesktopPicture.isPictureFile(setting) { return setting }
        let known = folder?.path == setting ? folder : nil
        if (known.map { now - $0.time >= DesktopPictureCache.folderInterval } ?? true) && pendingFolder != setting {
            pendingFolder = setting
            queue.async { [weak self] in
                let picture = DesktopPicture.picture(forSetting: setting)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.pendingFolder == setting { self.pendingFolder = nil }
                    self.folder = (setting, picture, self.clock())
                    // Published at once (it is what `path()` now answers): a skin on another thread need not wait
                    // for the next look.
                    if self.lastSetting?.path == setting { self.published.publish(picture) }
                }
            }
        }
        return known?.picture ?? ""
    }
}

/// Desktop picture files and folders of rotating pictures (Registry `Wallpaper`, Chameleon `Type=Desktop`).
enum DesktopPicture {
    /// Extensions of the picture files macOS offers as desktop pictures.
    static let pictureExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif",
                                                 "webp", "jp2", "pict", "pct"]

    /// Whether `path` names a picture file by its extension (no file system access).
    static func isPictureFile(_ path: String) -> Bool {
        pictureExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// The first picture (by name) of a folder of rotating pictures; nil when `path` is not a folder or holds no
    /// picture. Touches the file system: call it off the main thread.
    static func firstPicture(inFolder path: String) -> String? {
        guard !path.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && isPictureFile($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .first.map { url.appendingPathComponent($0).path }
    }

    /// The picture file for a desktop picture setting: a folder's first picture ("" when it has none), another
    /// existing file as it is, "" for a path that does not exist (a folder on a volume that is not mounted: its path
    /// is no picture a skin could show). Touches the file system: call it off the main thread.
    static func picture(forSetting path: String) -> String {
        guard !path.isEmpty else { return "" }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return "" }
        guard isDir.boolValue else { return path }
        return firstPicture(inFolder: path) ?? ""
    }
}
