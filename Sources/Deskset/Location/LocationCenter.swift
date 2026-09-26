import CoreLocation
import DesksetCore

/// What `LocationCenter` uses of a `CLLocationManager` (a fake in the self-tests, where nothing may ask macOS).
protocol LocationManaging: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var delegate: CLLocationManagerDelegate? { get set }
    func requestWhenInUseAuthorization()
    func requestLocation()
    func stopUpdatingLocation()
}

extension CLLocationManager: LocationManaging {}

/// Location Services for the whole app: the permission (asked once per launch, and only for skins running in skin
/// windows) and this Mac's approximate location for weather and sun skins that say `Location=auto`
/// (docs/compat/weather.md, docs/compat/app.md "Permissions").
///
/// A `CLLocationManager` belongs to the thread that made it (it reports on that thread's run loop), so the manager,
/// the question and the requests live on the main thread; the status and the last fix are published from there for
/// skins on other threads (docs/skin-threading.md §4.6). Accuracy is reduced (about 5 km) and the fix is rounded to
/// two decimals (about 1 km) before anything keeps it: the precise location is never stored, written or logged.
final class LocationCenter: NSObject, CLLocationManagerDelegate, DeviceLocationSource {
    static let shared = LocationCenter()

    /// Makes the manager (main thread). The self-tests pass a fake.
    private let makeManager: () -> LocationManaging
    /// How long a fix may take once asked for (then `.unavailable`: Wi-Fi off, no known networks).
    let fixTimeout: TimeInterval
    /// How long to wait for the user's answer to the permission question before giving up for now.
    let authorizationTimeout: TimeInterval
    /// Log lines ("Location: fix ok"); never coordinates.
    var log: (String) -> Void = { Log.write($0) }

    // Main thread only.
    private var manager: LocationManaging?
    private var asked = false
    private var waiting: [(Result<RoundedCoordinate, DeviceLocationError>) -> Void] = []
    private var locating = false
    private var timeout: DispatchWorkItem?

    /// The status for any thread; before the main thread's first look, "not decided" (no note about a refusal).
    private let published = MainPublished<CLAuthorizationStatus>(maxAge: 2, initial: .notDetermined, compute: {
        .notDetermined
    })
    /// The last fix, rounded, and when it came (memory only).
    private let lastFix = Guarded<(coordinate: RoundedCoordinate, at: Date)?>(nil)
    /// Requests sent to Location Services (tests).
    private let counters = Guarded((questions: 0, fixes: 0))

    init(makeManager: @escaping () -> LocationManaging = { CLLocationManager() }, fixTimeout: TimeInterval = 30,
         authorizationTimeout: TimeInterval = 120) {
        self.makeManager = makeManager
        self.fixTimeout = fixTimeout
        self.authorizationTimeout = authorizationTimeout
        super.init()
        published.compute = { [unowned self] in self.managerOnMain().authorizationStatus }
    }

    /// Any thread: on the main thread the status now, elsewhere the one the main thread saw last (at most about 2 s
    /// old while the main thread is free).
    var status: CLAuthorizationStatus { published.value() }

    var isDenied: Bool { status == .denied || status == .restricted }

    /// Permission questions and location requests made so far (tests).
    var requestCounts: (questions: Int, fixes: Int) { counters.current }

    /// Asks when the user has not decided yet (the Wi-Fi skins): on the main thread, at once when the caller is there,
    /// else queued there.
    func requestIfNeeded() {
        MediaUIMainHop.run { self.askOnMain() }
    }

    // MARK: DeviceLocationSource (any thread)

    var authorization: DeviceLocationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .authorized
        }
    }

    func cachedFix(maxAge: TimeInterval) -> RoundedCoordinate? {
        lastFix.access { fix in
            guard let fix, Date().timeIntervalSince(fix.at) <= maxAge else { return nil }
            return fix.coordinate
        }
    }

    /// One request for every skin at a time: completions wait for the same answer.
    func requestFix(_ completion: @escaping (Result<RoundedCoordinate, DeviceLocationError>) -> Void) {
        MediaUIMainHop.run { self.requestOnMain(completion) }
    }

    // MARK: Main thread

    private func managerOnMain() -> LocationManaging {
        if let manager { return manager }
        let m = makeManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyReduced
        manager = m
        return m
    }

    private func askOnMain() {
        let m = managerOnMain()
        guard !asked, m.authorizationStatus == .notDetermined else { return }
        asked = true
        counters.access { $0.questions += 1 }
        m.requestWhenInUseAuthorization()
    }

    private func requestOnMain(_ completion: @escaping (Result<RoundedCoordinate, DeviceLocationError>) -> Void) {
        let m = managerOnMain()
        let status = m.authorizationStatus
        published.publish(status)
        if status == .denied || status == .restricted {
            completion(.failure(.denied))
            return
        }
        waiting.append(completion)
        if status == .notDetermined {
            askOnMain()
            // The answer arrives in `locationManagerDidChangeAuthorization`.
            if timeout == nil { scheduleTimeout(authorizationTimeout) }
            return
        }
        startLocating()
    }

    private func startLocating() {
        guard !locating, let m = manager else { return }
        locating = true
        counters.access { $0.fixes += 1 }
        m.requestLocation()
        scheduleTimeout(fixTimeout)
    }

    private func scheduleTimeout(_ seconds: TimeInterval) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.timeout = nil
            self.log("Location: failed (time-out)")
            self.finish(.failure(.unavailable))
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func finish(_ result: Result<RoundedCoordinate, DeviceLocationError>) {
        timeout?.cancel()
        timeout = nil
        if locating { manager?.stopUpdatingLocation() }
        locating = false
        let completions = waiting
        waiting = []
        for c in completions { c(result) }
    }

    /// The permission changed (the user answered, or changed it in System Settings).
    func authorizationChanged(_ status: CLAuthorizationStatus) {
        published.publish(status)
        switch status {
        case .denied, .restricted:
            if !waiting.isEmpty { finish(.failure(.denied)) }
        case .notDetermined:
            break
        default:
            if !waiting.isEmpty { startLocating() }
        }
    }

    /// A fix arrived: rounded at once; the precise one is not kept.
    func received(_ locations: [CLLocation]) {
        guard locating, let location = locations.last else { return }
        let c = RoundedCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        let now = Date()
        lastFix.access { $0 = (c, now) }
        log("Location: fix ok")
        finish(.success(c))
    }

    func failed(_ error: Error) {
        guard locating || !waiting.isEmpty else { return }
        let code = (error as? CLError)?.code
        if code == .denied {
            log("Location: refused")
            finish(.failure(.denied))
        } else {
            log("Location: failed (\(code.map { String($0.rawValue) } ?? "unknown"))")
            finish(.failure(.unavailable))
        }
    }

    // MARK: CLLocationManagerDelegate (main thread: the manager was made there)

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationChanged(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        received(locations)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        failed(error)
    }
}
