import AppKit
import CoreLocation
import DesksetCore

/// `Deskset --self-test Weather`: the app side of the weather plugins (docs/compat/weather.md), here Location
/// Services through `LocationCenter`, with a fake manager: nothing here asks macOS.
enum WeatherSelfTests {
    static func run(_ t: AppTestRunner) {
        locationCenterTests(t)
    }

    final class FakeLocationManager: LocationManaging {
        var authorizationStatus: CLAuthorizationStatus = .notDetermined
        var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest
        weak var delegate: CLLocationManagerDelegate?
        private(set) var questions = 0
        private(set) var requests = 0
        private(set) var stops = 0

        func requestWhenInUseAuthorization() { questions += 1 }
        func requestLocation() { requests += 1 }
        func stopUpdatingLocation() { stops += 1 }
    }

    // MARK: Location Services

    static func locationCenterTests(_ t: AppTestRunner) {
        t.suite("App: Weather: LocationCenter asks once and shares one request") {
            let fake = FakeLocationManager()
            let center = LocationCenter(makeManager: { fake }, fixTimeout: 0.3, authorizationTimeout: 0.4)
            let logs = SharedServiceThreadingSelfTests.Collected<String>()
            center.log = { logs.add($0) }
            let results = SharedServiceThreadingSelfTests.Collected<Result<RoundedCoordinate, DeviceLocationError>>()
            for _ in 0..<3 { center.requestFix { results.add($0) } }
            t.equal(fake.questions, 1, "asked once for three skins")
            t.equal(fake.requests, 0, "no request before the answer")
            t.equal(fake.desiredAccuracy, kCLLocationAccuracyReduced, "reduced accuracy")
            center.requestIfNeeded()
            t.equal(fake.questions, 1, "never asked twice")
            fake.authorizationStatus = .authorizedAlways
            center.authorizationChanged(.authorizedAlways)
            t.equal(fake.requests, 1, "one request for everyone")
            t.equal(center.authorization, .authorized)
            center.received([CLLocation(latitude: 59.913868, longitude: 10.752245)])
            t.equal(results.count, 3)
            let oslo = RoundedCoordinate(latitude: 59.91, longitude: 10.75)
            t.check(results.all.allSatisfy { if case .success(let c) = $0 { return c == oslo } else { return false } },
                    "every skin gets the rounded fix")
            t.equal(center.cachedFix(maxAge: 60), oslo)
            t.equal(ServiceThreadingSelfTests.offMain { center.cachedFix(maxAge: 60) }, Optional(oslo), "from any thread")
            t.check(logs.all.contains("Location: fix ok"), "\(logs.all)")
            t.check(!logs.all.contains { $0.contains("59.9") || $0.contains("10.75") }, "no coordinates in the log")

            // No fix within the time limit: unavailable, the request stopped.
            let late = SharedServiceThreadingSelfTests.Collected<Result<RoundedCoordinate, DeviceLocationError>>()
            center.requestFix { late.add($0) }
            t.equal(fake.requests, 2)
            t.check(AppSelfTest.spin(timeout: 5) { late.count == 1 }, "the time-out answers")
            t.equal(late.all.first.map { if case .failure(.unavailable) = $0 { return true } else { return false } }, true)
            t.check(fake.stops >= 1, "the request is stopped")
            // A failure from Location Services, and a request from another thread.
            let failed = SharedServiceThreadingSelfTests.Collected<Result<RoundedCoordinate, DeviceLocationError>>()
            DispatchQueue.global().async { center.requestFix { failed.add($0) } }
            t.check(AppSelfTest.spin(timeout: 5) { fake.requests == 3 }, "the request reached the main thread")
            center.failed(CLError(.locationUnknown))
            t.equal(failed.all.first.map { if case .failure(.unavailable) = $0 { return true } else { return false } }, true)
            // Refused: at once, without asking.
            fake.authorizationStatus = .denied
            let refused = SharedServiceThreadingSelfTests.Collected<Result<RoundedCoordinate, DeviceLocationError>>()
            center.requestFix { refused.add($0) }
            t.equal(refused.all.first.map { if case .failure(.denied) = $0 { return true } else { return false } }, true)
            t.equal(fake.requests, 3, "nothing asked when refused")
            t.equal(center.authorization, .denied)
            t.check(center.isDenied)
            // The user never answers: after the time limit, "unavailable" (asked again later by the service).
            let undecided = FakeLocationManager()
            let quiet = LocationCenter(makeManager: { undecided }, fixTimeout: 0.3, authorizationTimeout: 0.3)
            quiet.log = { _ in }
            let waited = SharedServiceThreadingSelfTests.Collected<Result<RoundedCoordinate, DeviceLocationError>>()
            quiet.requestFix { waited.add($0) }
            t.check(AppSelfTest.spin(timeout: 5) { waited.count == 1 }, "no answer is not a hang")
            t.equal(undecided.questions, 1)
        }
    }
}
