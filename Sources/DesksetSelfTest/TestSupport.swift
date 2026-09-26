import Foundation
@testable import DesksetCore

// Shared fakes and helpers for engine-level tests. Test files may use but should not edit these.

class FakeHost: SkinHost {
    /// Image sizes by file name (last path component); `*100x50.png` is always 100×50.
    var imageSizes: [String: (width: Double, height: Double)] = [:]
    /// Custom text metrics; default is 7 pt per character, 14 pt per line.
    var textSizer: ((String, TextStyle, Double?) -> (width: Double, height: Double))?
    var redraws = 0
    var handled: [Bang] = []
    var forwarded: [(Bang, String)] = []
    var executed: [String] = []
    var logs: [String] = []
    /// `skinWindowTakesPointer`: false stands for a hidden or click-through skin window.
    var windowTakesPointer = true

    func skinNeedsDisplay(_ skin: Skin) { redraws += 1 }
    func skin(_ skin: Skin, handle bang: Bang) -> Bool {
        handled.append(bang)
        return bang.name != "unknownbang"
    }
    func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) { forwarded.append((bang, config)) }
    func skin(_ skin: Skin, execute target: String, arguments: [String]) { executed.append(target) }
    func skin(_ skin: Skin, log message: String, level: SkinLogLevel) { logs.append("\(level.rawValue): \(message)") }
    /// Deterministic metrics: 7 points per character, 14 points per line.
    func textSize(_ text: String, style: TextStyle, wrapWidth: Double?, for skin: Skin) -> (width: Double, height: Double) {
        if let textSizer { return textSizer(text, style, wrapWidth) }
        return text.isEmpty ? (0, 0) : (Double(text.count) * 7, 14)
    }
    func imageSize(atPath path: String) -> (width: Double, height: Double)? {
        if let size = imageSizes[(path as NSString).lastPathComponent] { return size }
        return path.hasSuffix("100x50.png") ? (100, 50) : nil
    }
    func environment(for skin: Skin) -> SkinEnvironment { SkinEnvironment() }
    func skinWindowTakesPointer(_ skin: Skin) -> Bool { windowTakesPointer }
}

class FakeSystem: SystemDataSource {
    var cpu = 42.0
    var memory = MemoryStatus(physicalTotal: 16 * 1_073_741_824, physicalUsed: 8 * 1_073_741_824,
                              swapTotal: 2 * 1_073_741_824, swapUsed: 1_073_741_824)
    var net = NetworkCounters(received: 1000, sent: 500)

    var processorCount: Int { 8 }
    func cpuUsage(processor: Int) -> Double { processor == 0 ? cpu : Double(processor) }
    func memoryStatus() -> MemoryStatus { memory }
    func networkInterfaces() -> [String] { ["en0"] }
    func networkCounters(interface: String?) -> NetworkCounters { net }
    func diskSpace(path: String) -> (total: Double, free: Double)? { (1000, 250) }
    func uptime() -> TimeInterval { 90061 }  // 1d 1h 1m 1s
    func battery() -> BatteryStatus? { BatteryStatus(percent: 80, isCharging: false, isPluggedIn: false, minutesRemaining: 90) }
    func isProcessRunning(_ name: String) -> Bool { name.lowercased() == "finder" }
    func sysInfo(type: String, data: String) -> (number: Double, string: String?)? {
        type == "USER_NAME" ? (0, "tester") : nil
    }
}

private var retainedHosts: [FakeHost] = []

/// Writes `files` (relative path → contents) under a temporary Skins folder and loads `Root\Sub\Skin.ini`.
func makeSkin(_ t: TestRunner, _ ini: String, files: [String: String] = [:],
                      host: FakeHost = FakeHost(), system: FakeSystem = FakeSystem()) throws -> (Skin, FakeHost) {
    let skins = t.temporaryDirectory("engine").appendingPathComponent("Skins")
    let dir = skins.appendingPathComponent("Root/Sub")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: skins.appendingPathComponent("Root/@Resources"),
                                            withIntermediateDirectories: true)
    try ini.write(to: dir.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
    for (path, text) in files {
        let url = skins.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    let skin = Skin(config: "Root\\Sub", fileURL: dir.appendingPathComponent("Skin.ini"), skinsDirectory: skins,
                    system: system, host: host)
    retainedHosts.append(host)  // Skin.host is weak; keep fakes alive for the whole run.
    try skin.load()
    return (skin, host)
}

/// Text of a String meter (for assertions).
func text(_ skin: Skin, _ meter: String) -> String {
    (skin.meter(named: meter) as? StringMeter)?.text ?? "<no meter \(meter)>"
}
