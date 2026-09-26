import Foundation
import IOKit
import IOKit.hidsystem

/// Temperature sensors of the HID event system (vendor page 0xff00, usage 5), the fallback for Macs whose SMC gives no
/// CPU temperatures. The full client that can read them is private (`IOHIDEventSystemClientCreate`, …): the functions
/// are looked up with dlsym, and when one is missing the reader is simply not available. On an M4 Pro these sensors
/// are the power manager's die sensors, the battery gauge and the SSD (not the cores); M1 / M2 Macs name their CPU
/// cluster sensors here ("pACC MTR Temp Sensor…"). Each sensor appears several times: one per name and location.
///
/// Not thread-safe: the sensor service uses it on its queue only.
final class HIDTemperatureReader {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatching = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    private typealias CopyEvent = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloat = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Double

    /// kIOHIDEventTypeTemperature, and the field holding its value (type << 16).
    private static let temperatureEvent: Int64 = 15

    private let client: UnsafeMutableRawPointer
    private let copyEvent: CopyEvent
    private let getFloat: GetFloat
    private let services: [(name: String, service: IOHIDServiceClient)]

    init?() {
        guard let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func fn<T>(_ name: String, _: T.Type) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: T.self) } }
        guard let create = fn("IOHIDEventSystemClientCreate", ClientCreate.self),
              let setMatching = fn("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = fn("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyEvent = fn("IOHIDServiceClientCopyEvent", CopyEvent.self),
              let getFloat = fn("IOHIDEventGetFloatValue", GetFloat.self),
              let client = create(kCFAllocatorDefault) else { return nil }
        setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let list = (copyServices(client)?.takeRetainedValue() as NSArray?) ?? []
        var seen: Set<String> = []
        var services: [(String, IOHIDServiceClient)] = []
        for case let item as AnyObject in list.prefix(512) {
            let service = unsafeBitCast(item, to: IOHIDServiceClient.self)
            let name = (IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String) ?? ""
            let location = (IOHIDServiceClientCopyProperty(service, "LocationID" as CFString) as? NSNumber)?.int64Value ?? 0
            guard !name.isEmpty, seen.insert("\(name)|\(location)").inserted else { continue }
            services.append((name, service))
        }
        self.client = client
        self.copyEvent = copyEvent
        self.getFloat = getFloat
        self.services = services
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(client).release()
    }

    /// Every sensor's current reading (°C); sensors without one are left out.
    func read() -> [(name: String, celsius: Double)] {
        var result: [(String, Double)] = []
        for (name, service) in services {
            guard let event = copyEvent(Unmanaged.passUnretained(service).toOpaque(), Self.temperatureEvent, 0, 0)
            else { continue }
            let value = getFloat(event, UInt32(Self.temperatureEvent << 16))
            Unmanaged<AnyObject>.fromOpaque(event).release()
            if value.isFinite { result.append((name, value)) }
        }
        return result
    }
}
