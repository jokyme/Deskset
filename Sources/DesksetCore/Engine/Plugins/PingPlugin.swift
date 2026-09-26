import Darwin
import Foundation

// Clean-room implementation from the public manual only: https://docs.rainmeter.net/manual/plugins/ping/

/// `Plugin=PingPlugin`: round-trip time to `DestAddress` in milliseconds.
/// - Pings on the first update and then every `UpdateRate` updates (default 32), like WebParser's UpdateRate.
/// - `Timeout` (ms, default 30000): no reply by then → the value is `TimeoutValue` (default 30000).
/// - `FinishAction` runs after every ping, when the reply arrives or the time-out is reached.
/// - Mac: an unprivileged ICMP echo (`SOCK_DGRAM` + `IPPROTO_ICMP` / `IPPROTO_ICMPV6`, which macOS allows without
///   root), on a background thread; the skin never waits. Judgment calls: a name that cannot be resolved or a network
///   that cannot be reached counts as a time-out (TimeoutValue, FinishAction) — reported once in the log; the value is
///   rounded to whole milliseconds like Windows' ICMP API; before the first reply the value is 0.
public final class PingMeasure: Measure, PluginLifecycle {
    private var destination = ""
    private var updateRate = 32
    private var timeout = 30_000.0
    private var timeoutValue = 30_000.0
    private var finishAction = ""
    private var counter = 0
    private var result = 0.0
    private var inFlight: CancellationFlag?
    private var generation = 0
    private var closed = false
    private var reportedFailure = false

    /// Pings started so far (tests).
    public private(set) var pingCount = 0
    public var isPinging: Bool { inFlight != nil }

    override var tracksValueRange: Bool { true }

    deinit {
        inFlight?.cancel()
    }

    public func skinWillClose() {
        closed = true
        inFlight?.cancel()
        inFlight = nil
    }

    public override func readMeasureOptions() {
        destination = string("DestAddress").trimmingCharacters(in: .whitespaces)
        updateRate = int("UpdateRate", 32)
        timeout = min(max(double("Timeout", 30_000), 1), 600_000)
        timeoutValue = double("TimeoutValue", 30_000)
        finishAction = actionOption("FinishAction")
    }

    public override func computeValue() -> Double {
        if counter == 0 { startPing() }
        if counter < Int.max - 1 { counter += 1 }
        if updateRate > 0 && counter >= updateRate { counter = 0 }
        return result
    }

    private func startPing() {
        guard !closed, inFlight == nil else { return }
        guard !destination.isEmpty else {
            if !reportedFailure {
                reportedFailure = true
                skin.log("Ping [\(name)]: DestAddress is empty", level: .warning)
            }
            return
        }
        let flag = CancellationFlag()
        inFlight = flag
        generation += 1
        pingCount += 1
        let current = generation
        let host = destination, limit = timeout / 1000
        let hop = skin.hop()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = ICMPEcho.ping(host: host, timeout: limit, cancel: flag)
            hop.post {
                guard let self, self.generation == current, !flag.isCancelled else { return }
                self.finish(outcome)
            }
        }
    }

    private func finish(_ outcome: Result<Double, ICMPEcho.Failure>) {
        inFlight = nil
        guard !closed else { return }
        switch outcome {
        case .success(let ms):
            result = ms.rounded()
        case .failure(let failure):
            result = timeoutValue
            if failure != .timeout && !reportedFailure {
                reportedFailure = true
                skin.log("Ping [\(name)]: \(destination): \(failure.description); using TimeoutValue", level: .notice)
            }
        }
        publishAsyncResult(number: result, string: nil)
        if !finishAction.isEmpty { skin.execute(finishAction, from: self) }
    }
}

/// One ICMP echo request without privileges.
enum ICMPEcho {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case timeout
        case resolve(String)
        case socket(Int32)
        case send(Int32)
        case cancelled

        var description: String {
            switch self {
            case .timeout: return "no reply"
            case .resolve(let m): return "cannot resolve the address (\(m))"
            case .socket(let e): return "cannot open an ICMP socket (\(String(cString: strerror(e))))"
            case .send(let e): return "cannot send (\(String(cString: strerror(e))))"
            case .cancelled: return "cancelled"
            }
        }
    }

    /// Round-trip time in milliseconds. Blocks the calling (background) thread for at most `timeout` seconds plus
    /// name resolution; checks `cancel` every 100 ms.
    static func ping(host: String, timeout: TimeInterval, cancel: CancellationFlag) -> Result<Double, Failure> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &list)
        guard status == 0, let first = list else {
            return .failure(.resolve(String(cString: gai_strerror(status))))
        }
        defer { freeaddrinfo(list) }
        // Prefer IPv4 (what Windows' ping plugin uses), else the first IPv6 address.
        var chosen: UnsafeMutablePointer<addrinfo>? = first
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let c = cursor {
            if c.pointee.ai_family == AF_INET { chosen = c; break }
            cursor = c.pointee.ai_next
        }
        guard let address = chosen, let sockaddr = address.pointee.ai_addr else { return .failure(.resolve("no address")) }
        let v6 = address.pointee.ai_family == AF_INET6
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_DGRAM, v6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP)
        guard fd >= 0 else { return .failure(.socket(errno)) }
        defer { close(fd) }

        let identifier = UInt16.random(in: 1...UInt16.max)
        let sequence = UInt16.random(in: 0...UInt16.max)
        var packet = [UInt8](repeating: 0, count: 8 + 32)
        packet[0] = v6 ? 128 : 8   // echo request
        packet[1] = 0
        packet[4] = UInt8(identifier >> 8); packet[5] = UInt8(identifier & 0xFF)
        packet[6] = UInt8(sequence >> 8); packet[7] = UInt8(sequence & 0xFF)
        for i in 8..<packet.count { packet[i] = UInt8(truncatingIfNeeded: i) }
        if !v6 {
            let sum = checksum(packet)
            packet[2] = UInt8(sum >> 8); packet[3] = UInt8(sum & 0xFF)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let sent = packet.withUnsafeBytes { buffer in
            sendto(fd, buffer.baseAddress, buffer.count, 0, sockaddr, address.pointee.ai_addrlen)
        }
        guard sent == packet.count else { return .failure(.send(errno)) }

        let deadline = start + UInt64(max(timeout, 0) * 1_000_000_000)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            if cancel.isCancelled { return .failure(.cancelled) }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { return .failure(.timeout) }
            let slice = Int32(min((deadline - now) / 1_000_000, 100))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, max(slice, 1))
            if ready < 0 && errno != EINTR { return .failure(.timeout) }
            guard ready > 0 else { continue }
            let received = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard received > 0 else { continue }
            let arrival = DispatchTime.now().uptimeNanoseconds
            if isReply(Array(buffer.prefix(received)), v6: v6, identifier: identifier, sequence: sequence) {
                return .success(Double(arrival - start) / 1_000_000)
            }
        }
    }

    /// Echo reply for our identifier and sequence. IPv4 datagram sockets deliver the IP header too.
    static func isReply(_ data: [UInt8], v6: Bool, identifier: UInt16, sequence: UInt16) -> Bool {
        var offset = 0
        if !v6, let first = data.first, first >> 4 == 4 {
            offset = Int(first & 0x0F) * 4
        }
        guard data.count >= offset + 8 else { return false }
        let type = data[offset]
        guard type == (v6 ? 129 : 0) else { return false }
        let id = UInt16(data[offset + 4]) << 8 | UInt16(data[offset + 5])
        let seq = UInt16(data[offset + 6]) << 8 | UInt16(data[offset + 7])
        return id == identifier && seq == sequence
    }

    /// RFC 1071 Internet checksum.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
