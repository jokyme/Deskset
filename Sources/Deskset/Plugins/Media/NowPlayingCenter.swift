import AppKit
import CryptoKit
import CoreServices
import DesksetCore

// The shared NowPlaying poller: one per app, used by every NowPlaying / iTunesPlugin / WebNowPlaying / MediaKey
// measure of every skin.
//
// - Polls only while at least one measure of a skin running in the app subscribes, once a second, and only the
//   players that are running (NSRunningApplication; never launches a player to query it).
// - All Apple Events run on one background thread (`MediaUIWorker`); results come back to the main thread.
// - Automation permission ("Deskset wants to control Music") is asked the first time a running player is polled,
//   i.e. only when a skin shows NowPlaying data. When it is denied, that player is left alone (re-checked every
//   30 s without asking, in case it is granted in System Settings) and measures show "not running" values.
// - "Whichever is playing": a skin names one player (PlayerName); the measure shows the preferred app when it is
//   playing, otherwise another player that is playing, otherwise the one it showed last if it still has a paused
//   track, otherwise the preferred app when it has a paused track, then any other paused player, then any running
//   player, else the (closed) preferred app.

/// Result of a status poll.
enum NowPlayingPoll: Equatable {
    case notRunning
    case denied
    case failed(String)
    case ok(NowPlayingStatus)
}

/// Artwork of a track: bytes (Music) or a web address to download (Spotify).
enum NowPlayingArtwork: Equatable {
    case data(Data)
    case url(URL)
}

/// Talks to the players. Methods other than `isRunning` run on the worker thread and may block.
protocol NowPlayingBackend: AnyObject {
    /// Main thread; must not send Apple Events.
    func isRunning(_ app: MediaApp) -> Bool
    func status(_ app: MediaApp) -> NowPlayingPoll
    func track(_ app: MediaApp) -> NowPlayingTrack?
    func artwork(_ app: MediaApp, track: NowPlayingTrack) -> NowPlayingArtwork?
    @discardableResult
    func perform(_ command: MediaPlayerCommand, on app: MediaApp) -> Bool
}

// MARK: - AppleScript backend

final class AppleScriptNowPlayingBackend: NowPlayingBackend {
    /// Compiled scripts by source (worker thread only).
    private var compiled: [String: NSAppleScript] = [:]
    /// Sources that failed to compile (e.g. Spotify is not installed, so its terminology is unknown).
    private var broken: Set<String> = []
    /// Apps whose Automation permission was granted (worker thread only).
    private var permitted: Set<MediaApp> = []

    func isRunning(_ app: MediaApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).isEmpty
    }

    /// errAEEventNotPermitted: the user said no (System Settings → Privacy & Security → Automation).
    static let notPermitted = -1743
    /// errAEEventWouldRequireUserConsent: not decided yet and the check did not ask.
    static let wouldRequireConsent = -1744

    /// Tests replace the permission check and the script runner, so the permission logic runs without Apple Events.
    var permissionCheck: (MediaApp) -> OSStatus = AppleScriptNowPlayingBackend.determinePermission
    var scriptRunner: ((String) -> (NSAppleEventDescriptor?, Int))?

    /// Asks for the Automation permission (the system shows its prompt once; later calls answer from the stored
    /// decision). Blocks until the user answers, which is why it runs on the worker thread.
    static func determinePermission(_ app: MediaApp) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: app.bundleIdentifier)
        guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, true)
    }

    /// Whether scripts may be sent to `app`: `noErr` when allowed or not decided yet, else the reason.
    ///
    /// The check uses wildcard event codes ("every event"), which the SDK documents for checking permission but not
    /// for asking. When it answers `wouldRequireConsent` (no prompt was shown) the script is sent anyway: its own
    /// Apple Event makes the system ask. Treating that answer as a refusal would mean the prompt never appears and
    /// NowPlaying never works.
    private func permission(_ app: MediaApp) -> Int {
        if permitted.contains(app) { return 0 }
        let status = Int(permissionCheck(app))
        switch status {
        case 0:
            permitted.insert(app)
            return 0
        case AppleScriptNowPlayingBackend.wouldRequireConsent:
            return 0
        default:
            return status
        }
    }

    /// Runs a script and keeps `permitted` in step with what the player answered.
    private func runChecked(_ source: String, _ app: MediaApp) -> (NSAppleEventDescriptor?, Int) {
        let (result, error) = run(source)
        if error == AppleScriptNowPlayingBackend.notPermitted || error == AppleScriptNowPlayingBackend.wouldRequireConsent {
            permitted.remove(app)
        } else if error == 0 {
            permitted.insert(app)
        }
        return (result, error)
    }

    private func run(_ source: String) -> (NSAppleEventDescriptor?, Int) {
        if let scriptRunner { return scriptRunner(source) }
        if broken.contains(source) { return (nil, -2740) }
        let script: NSAppleScript
        if let s = compiled[source] {
            script = s
        } else {
            guard let s = NSAppleScript(source: source) else { return (nil, -2740) }
            var error: NSDictionary?
            if !s.compileAndReturnError(&error) {
                broken.insert(source)
                return (nil, (error?[NSAppleScript.errorNumber] as? Int) ?? -2740)
            }
            compiled[source] = s
            script = s
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error { return (nil, (error[NSAppleScript.errorNumber] as? Int) ?? -1) }
        return (result, 0)
    }

    func status(_ app: MediaApp) -> NowPlayingPoll {
        switch permission(app) {
        case 0: break
        case Int(procNotFound): return .notRunning
        case AppleScriptNowPlayingBackend.notPermitted: return .denied
        case let other: return .failed("permission check \(other)")
        }
        let (result, error) = runChecked(NowPlayingScripts.status(app), app)
        if error == AppleScriptNowPlayingBackend.notPermitted || error == AppleScriptNowPlayingBackend.wouldRequireConsent {
            return .denied
        }
        guard let result else { return .failed("status script error \(error)") }
        switch NowPlayingScripts.parseStatus(Self.values(result)) {
        case .notRunning: return .notRunning
        case .status(let s): return .ok(s)
        case .malformed: return .failed("unexpected reply")
        }
    }

    func track(_ app: MediaApp) -> NowPlayingTrack? {
        guard permitted.contains(app), let result = runChecked(NowPlayingScripts.track(app), app).0 else { return nil }
        return NowPlayingScripts.parseTrack(Self.values(result))
    }

    func artwork(_ app: MediaApp, track: NowPlayingTrack) -> NowPlayingArtwork? {
        if app == .spotify {
            guard let url = URL(string: track.artworkURL), url.scheme == "https" || url.scheme == "http" else {
                return nil
            }
            return .url(url)
        }
        guard permitted.contains(app), let source = NowPlayingScripts.artwork(app),
              let result = runChecked(source, app).0 else { return nil }
        let data = result.data
        return data.count > 8 ? .data(data) : nil
    }

    func perform(_ command: MediaPlayerCommand, on app: MediaApp) -> Bool {
        guard let source = NowPlayingScripts.command(command, app) else { return false }
        guard permission(app) == 0 else { return false }
        return runChecked(source, app).1 == 0
    }

    /// Script reply → values (a list's items, or the single value).
    static func values(_ d: NSAppleEventDescriptor) -> [AppleScriptValue] {
        if d.descriptorType == fourCC("list") {
            guard d.numberOfItems > 0 else { return [] }
            return (1...d.numberOfItems).map { d.atIndex($0).map(value) ?? .missing }
        }
        return [value(d)]
    }

    static func value(_ d: NSAppleEventDescriptor) -> AppleScriptValue {
        switch d.descriptorType {
        case fourCC("utxt"), fourCC("utf8"), fourCC("TEXT"):
            return .text(d.stringValue ?? "")
        case fourCC("long"), fourCC("shor"), fourCC("comp"), fourCC("doub"), fourCC("sing"), fourCC("magn"),
             fourCC("ldbl"):
            if let n = d.coerce(toDescriptorType: fourCC("doub")) { return .number(n.doubleValue) }
            return .number(Double(d.int32Value))
        case fourCC("true"): return .number(1)
        case fourCC("fals"): return .number(0)
        case fourCC("bool"): return .number(d.booleanValue ? 1 : 0)
        case fourCC("type") where d.typeCodeValue == fourCC("msng"): return .missing
        case fourCC("null"): return .missing
        default:
            if let s = d.stringValue, d.descriptorType == fourCC("enum") { return .text(s) }
            return .data(d.data)
        }
    }

    static func fourCC(_ s: String) -> FourCharCode {
        s.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}

// MARK: - Demo backend

/// Fixed data for `--render` previews and tests (`DESKSET_NOWPLAYING_DEMO=1`): never talks to a real player.
final class DemoNowPlayingBackend: NowPlayingBackend {
    var running: Set<MediaApp> = [.music]
    var statuses: [MediaApp: NowPlayingStatus] = [
        .music: NowPlayingStatus(state: 1, volume: 70, shuffle: true, repeatMode: .all, position: 83, trackID: "DEMO1",
                                 rating: 80),
    ]
    var tracks: [MediaApp: NowPlayingTrack] = [
        .music: NowPlayingTrack(title: "Rain on Glass", artist: "Deskset Ensemble", album: "Desktop Weather",
                                albumArtist: "Deskset Ensemble", genre: "Ambient", number: 3, year: 2026,
                                trackCount: 9, bitRate: 256, sampleRate: 44_100, duration: 245),
    ]
    var artworkData: Data?
    var artworkEnabled = true
    /// Tests: answers returned (in order) before the ones above.
    var artworkQueue: [NowPlayingArtwork?] = []
    private(set) var artworkAsks = 0
    private(set) var performed: [(MediaPlayerCommand, MediaApp)] = []
    private(set) var statusPolls = 0

    func isRunning(_ app: MediaApp) -> Bool { running.contains(app) }

    func status(_ app: MediaApp) -> NowPlayingPoll {
        statusPolls += 1
        guard running.contains(app) else { return .notRunning }
        return .ok(statuses[app] ?? NowPlayingStatus())
    }

    func track(_ app: MediaApp) -> NowPlayingTrack? { tracks[app] }

    func artwork(_ app: MediaApp, track: NowPlayingTrack) -> NowPlayingArtwork? {
        artworkAsks += 1
        if !artworkQueue.isEmpty { return artworkQueue.removeFirst() }
        guard artworkEnabled else { return nil }
        if let artworkData { return .data(artworkData) }
        return .data(DemoNowPlayingBackend.demoCover())
    }

    func perform(_ command: MediaPlayerCommand, on app: MediaApp) -> Bool {
        performed.append((command, app))
        var s = statuses[app] ?? NowPlayingStatus()
        switch command {
        case .play: s.state = 1
        case .pause, .stop: s.state = command == .stop ? 0 : 2
        case .playPause: s.state = s.state == 1 ? 2 : 1
        case .setVolume(let v): s.volume = Double(v)
        case .setShuffle(let on): s.shuffle = on
        case .setRepeat(let m): s.repeatMode = m
        case .setRating(let r): s.rating = Double(r)
        case .setPosition(let p): s.position = p
        default: break
        }
        statuses[app] = s
        return true
    }

    /// A small original gradient cover (PNG).
    static func demoCover() -> Data {
        let size = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return Data() }
        let cg = context.cgContext
        let colors = [CGColor(red: 0.16, green: 0.35, blue: 0.62, alpha: 1), CGColor(red: 0.45, green: 0.78, blue: 0.86, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                     locations: [0, 1]) {
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
        }
        cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        for i in 0..<5 {
            cg.fillEllipse(in: CGRect(x: 10 + i * 9, y: 40 - (i % 2) * 14, width: 4, height: 10))
        }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

// MARK: - Center

/// Keeps a measure subscribed to the center; polling stops when the last subscription goes away.
final class NowPlayingSubscription {
    fileprivate weak var center: NowPlayingCenter?
    let live: Bool
    var wantsCover: Bool {
        didSet { if wantsCover != oldValue { center?.subscriptionsChanged() } }
    }

    fileprivate init(center: NowPlayingCenter, live: Bool, wantsCover: Bool) {
        self.center = center
        self.live = live
        self.wantsCover = wantsCover
    }

    deinit {
        let center = self.center
        let live = self.live
        MediaUIMainHop.async { center?.unsubscribe(live: live) }
    }
}

final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    /// `DESKSET_NOWPLAYING_DEMO=1`: fixed demo data (for `--render` previews), never Apple Events.
    static let demoMode = ProcessInfo.processInfo.environment["DESKSET_NOWPLAYING_DEMO"] == "1"

    var backend: NowPlayingBackend
    /// Tests: treat every subscriber as live (with a fake backend).
    var forceLive = false
    /// Tests: receives open / quit / show-hide instead of NSWorkspace.
    var appControl: ((MediaPlayerCommand, MediaApp) -> Void)?
    let worker = MediaUIWorker(name: "Deskset NowPlaying")
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Seconds between polls.
    var interval: TimeInterval = 1
    /// Cover files go here (tests use a temporary folder).
    var coverFolder: URL { MediaUICache.folder("NowPlaying") }

    private(set) var snapshots: [MediaApp: NowPlayingSnapshot] = [:]
    private var liveSubscribers = 0
    private var coverSubscribers = 0
    private var subscriptions: [WeakSubscription] = []
    private var timer: Timer?
    private var polling: Set<MediaApp> = []
    /// Track id whose metadata is being fetched, per app.
    private var fetchingTrack: [MediaApp: String] = [:]
    /// Track id whose metadata failed, and when (retried after 10 s).
    private var failedTrack: [MediaApp: (id: String, at: TimeInterval)] = [:]
    /// Cover work for each player's current track (see "Covers").
    private var coverJobs: [MediaApp: CoverJob] = [:]
    /// Pictures Music gave for recent tracks (the stale check, see "Covers").
    private var playerPictures: [MediaApp: [PlayerPicture]] = [:]
    /// Seconds between asks while Music's artwork of a streamed track is awaited: asked at 0, 1, 2, 3, 5, 8, 12, 20
    /// and 30 s (it arrives late, if at all).
    static let coverAskDelays: [TimeInterval] = [1, 1, 1, 2, 3, 4, 8, 10]
    /// A file without artwork (or a failed ask): asked twice more; the online lookup runs meanwhile.
    static let fileCoverAskDelays: [TimeInterval] = [1, 2]
    /// Music's picture of a streamed track is looked at again this long after it was shown, then once more: it may
    /// still have been the previous track's picture.
    static let coverRecheckDelays: [TimeInterval] = [5, 10]
    /// Looks a cover up online (see `NowPlayingCoverLookup`); nil = off. Only the real players' center has it (not
    /// demo mode or tests, which set their own). The `OnlineCoverLookup` preference is read at every lookup.
    var coverLookup: ((NowPlayingTrack, @escaping (URL?) -> Void) -> Void)? = { track, done in
        guard NowPlayingCoverLookup.isEnabled else { return done(nil) }
        NowPlayingCoverLookup.find(track, log: NowPlayingCenter.writeDebugLog, completion: done)
    }
    /// Downloads a cover picture (tests replace it).
    var coverDownload: (URL, @escaping (Data?) -> Void) -> Void = NowPlayingCoverCache.download
    /// Cover diagnostics (tests replace it).
    var debugLog: (String) -> Void = NowPlayingCenter.writeDebugLog

    /// `defaults write app.deskset.Deskset NowPlayingDebug -bool YES`: every cover step goes to the log (support).
    static func writeDebugLog(_ message: String) {
        guard UserDefaults.standard.bool(forKey: "NowPlayingDebug") else { return }
        Log.write(message, level: .debug, source: "NowPlaying")
    }
    private var deniedUntil: [MediaApp: TimeInterval] = [:]
    private var lastChoice: [String: MediaApp] = [:]
    /// When a measure last read a snapshot (energy: see `poll`).
    private var lastReadAt: TimeInterval = -1e9
    /// Polling pauses when no measure has read anything for this long (skins paused while the Mac sleeps or the
    /// screens are locked, or updating very rarely) and resumes on the next read.
    static let idleAfter: TimeInterval = 30
    private var loggedMessages: Set<String> = []
    /// Called with log lines (the app log by default).
    var log: (String) -> Void = { Log.write($0, level: .warning, source: "NowPlaying") }

    private struct WeakSubscription {
        weak var value: NowPlayingSubscription?
    }

    init(backend: NowPlayingBackend? = nil) {
        self.backend = backend ?? (NowPlayingCenter.demoMode ? DemoNowPlayingBackend() : AppleScriptNowPlayingBackend())
        if backend != nil || NowPlayingCenter.demoMode { coverLookup = nil }
    }

    // MARK: Subscriptions

    /// `live`: the skin runs in the app (so Apple Events and permission prompts are fine). Measures of `--render`
    /// and self-test skins subscribe with `live: false` and see closed players, unless demo mode is on.
    func subscribe(live: Bool, wantsCover: Bool = false) -> NowPlayingSubscription {
        let s = NowPlayingSubscription(center: self, live: live || forceLive || NowPlayingCenter.demoMode,
                                       wantsCover: wantsCover)
        if s.live { liveSubscribers += 1 }
        subscriptions.removeAll { $0.value == nil }
        subscriptions.append(WeakSubscription(value: s))
        subscriptionsChanged()
        if s.live {
            lastReadAt = clock()
            if liveSubscribers == 1 { startPolling() }
        }
        return s
    }

    fileprivate func unsubscribe(live: Bool) {
        if live { liveSubscribers = max(liveSubscribers - 1, 0) }
        subscriptionsChanged()
        if liveSubscribers == 0 { stopPolling() }
    }

    fileprivate func subscriptionsChanged() {
        subscriptions.removeAll { $0.value == nil }
        coverSubscribers = subscriptions.filter { $0.value?.wantsCover == true && $0.value?.live == true }.count
    }

    var isPolling: Bool { timer != nil }

    /// Deskset was refused the Automation permission for `app` (it is asked again only from System Settings).
    func isDenied(_ app: MediaApp) -> Bool { deniedUntil[app] != nil }

    private func startPolling() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    /// The last snapshots are kept: a refreshed skin subscribes again right away and shows them until the next poll.
    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Polling

    /// One polling round (main thread): every running player's status, off the main thread.
    func poll() {
        guard liveSubscribers > 0 else { return }
        let now = clock()
        guard now - lastReadAt < NowPlayingCenter.idleAfter else { return }
        for app in MediaApp.allCases {
            guard backend.isRunning(app) else {
                snapshots[app] = NowPlayingSnapshot(app: app)
                coverJobs[app] = nil
                continue
            }
            if polling.contains(app) { continue }
            if let until = deniedUntil[app], now < until { continue }
            polling.insert(app)
            let backend = self.backend
            worker.async { [weak self] in
                let result = backend.status(app)
                MediaUIMainHop.async { self?.apply(result, for: app) }
            }
        }
    }

    private func logOnce(_ message: String) {
        guard loggedMessages.count < 100, loggedMessages.insert(message).inserted else { return }
        log(message)
    }

    private func apply(_ result: NowPlayingPoll, for app: MediaApp) {
        polling.remove(app)
        let now = clock()
        switch result {
        case .notRunning:
            snapshots[app] = NowPlayingSnapshot(app: app)
            coverJobs[app] = nil
        case .denied:
            deniedUntil[app] = now + 30
            snapshots[app] = NowPlayingSnapshot(app: app)
            logOnce("Deskset is not allowed to control \(app.displayName); NowPlaying shows nothing for it. "
                    + "Allow it in System Settings → Privacy & Security → Automation.")
        case .failed(let why):
            logOnce("\(app.displayName) did not answer (\(why)); NowPlaying keeps the last values")
        case .ok(let status):
            deniedUntil[app] = nil
            var snap = snapshots[app] ?? NowPlayingSnapshot(app: app)
            let previousID = snap.status.trackID
            snap.running = true
            snap.status = status
            snap.polledAt = now
            snap.statusKnown = true
            if status.trackID != previousID {
                snap.track = nil
                snap.coverPath = ""
                coverJobs[app] = nil
            }
            if status.trackID.isEmpty { snap.track = nil }
            snapshots[app] = snap
            guard !status.trackID.isEmpty else { return }
            if let track = snap.track {
                guard coverSubscribers > 0 else { return }
                if coverJobs[app]?.id != status.trackID {
                    startCover(app, id: status.trackID, track: track)
                } else if let job = coverJobs[app], !job.asking, let due = job.nextAskAt, now >= due {
                    askPlayer(app, job)
                }
            } else {
                fetchTrack(app, id: status.trackID, now: now)
            }
        }
    }

    private func fetchTrack(_ app: MediaApp, id: String, now: TimeInterval) {
        if fetchingTrack[app] == id { return }
        if let failed = failedTrack[app], failed.id == id, now - failed.at < 10 { return }
        fetchingTrack[app] = id
        let backend = self.backend
        worker.async { [weak self] in
            let track = backend.track(app)
            MediaUIMainHop.async {
                guard let self else { return }
                if self.fetchingTrack[app] == id { self.fetchingTrack[app] = nil }
                guard var snap = self.snapshots[app], snap.status.trackID == id else { return }
                guard let track else {
                    self.failedTrack[app] = (id, self.clock())
                    return
                }
                snap.track = track
                self.snapshots[app] = snap
                if self.coverSubscribers > 0, self.coverJobs[app]?.id != id {
                    self.startCover(app, id: id, track: track)
                }
            }
        }
    }

    // MARK: Covers
    //
    // A file's cover is Music's artwork, asked for at once; the online lookup runs only when the file has none.
    // A streamed track (no file) is looked up online first: Music's artwork of streamed tracks arrives seconds late or
    // not at all, and right after a change Music often still hands out the previous track's picture. Music's artwork
    // is the fallback when the lookup finds nothing (or is off): asked for over 30 s, never a picture it gave for
    // another track of another album, and looked at again after it is shown. Spotify's cover is its web address.

    /// Where a shown cover came from.
    enum CoverSource: String {
        case player, online
    }

    private enum OnlineState {
        case idle, running, done
    }

    /// The cover of one player's current track (main thread).
    private final class CoverJob {
        let id: String
        let track: NowPlayingTrack
        let seenAt: TimeInterval
        /// The player's artwork comes first (a file, Spotify, or no online lookup); else the online lookup does.
        let playerFirst: Bool
        /// A Music track without a file: its artwork may be stale (see "Covers").
        let stream: Bool
        var shown: CoverSource?
        var shownDigest = ""
        /// Pictures shown so far: each gets a new file name, so no Image meter keeps the replaced one.
        var shownCount = 0
        var asks = 0
        var asking = false
        /// When the player is asked next (nil: not planned).
        var nextAskAt: TimeInterval?
        var rechecks = 0
        var online = OnlineState.idle

        init(id: String, track: NowPlayingTrack, seenAt: TimeInterval, playerFirst: Bool, stream: Bool) {
            self.id = id
            self.track = track
            self.seenAt = seenAt
            self.playerFirst = playerFirst
            self.stream = stream
        }
    }

    /// A picture Music gave for a track.
    private struct PlayerPicture {
        let digest: String
        let trackID: String
        let album: String
    }

    private func startCover(_ app: MediaApp, id: String, track: NowPlayingTrack) {
        let stream = app == .music && track.file.isEmpty
        let job = CoverJob(id: id, track: track, seenAt: clock(), playerFirst: !stream || coverLookup == nil,
                           stream: stream)
        coverJobs[app] = job
        if app == .music {
            debugLog("\"\(track.title)\" – \(track.artist) – \(track.album) (\(stream ? "streamed" : "file"), "
                     + "\(track.kind)): " + (job.playerFirst ? "Music's artwork first" : "online lookup first"))
        }
        if job.playerFirst { askPlayer(app, job) } else { lookUpOnline(app, job) }
    }

    private func askPlayer(_ app: MediaApp, _ job: CoverJob) {
        job.asking = true
        job.asks += 1
        job.nextAskAt = nil
        let track = job.track
        let backend = self.backend
        let download = coverDownload
        worker.async { [weak self] in
            switch backend.artwork(app, track: track) {
            case .data(let data):
                MediaUIMainHop.async { self?.playerAnswered(app, job, data: data) }
            case .url(let url):
                download(url) { data in MediaUIMainHop.async { self?.playerAnswered(app, job, data: data) } }
            case nil:
                MediaUIMainHop.async { self?.playerAnswered(app, job, data: nil) }
            }
        }
    }

    private func playerAnswered(_ app: MediaApp, _ job: CoverJob, data: Data?) {
        job.asking = false
        guard coverJobs[app] === job else { return }
        var picture: (data: Data, digest: String)?
        if let data, NowPlayingCoverCache.imageExtension(data) != nil {
            let digest = NowPlayingCenter.digest(data)
            if job.stream, isStale(digest, app: app, job: job) {
                debugLog("Music ask \(job.asks): another track's picture (\(digest.prefix(8))), ignored")
            } else {
                picture = (data, digest)
                if app == .music {
                    debugLog("Music ask \(job.asks): " + (digest == job.shownDigest ? "the picture shown"
                        : "picture \(digest.prefix(8)), \(data.count) bytes"))
                }
            }
        } else if app == .music {
            debugLog("Music ask \(job.asks): no artwork")
        }
        if let picture {
            if app == .music { rememberPicture(picture.digest, app: app, job: job) }
            // A newer picture of the player replaces its earlier one, and a file's own artwork an online one.
            if job.shown == nil || (picture.digest != job.shownDigest && (job.shown == .player || job.playerFirst)) {
                show(picture.data, digest: picture.digest, source: .player, app: app, job: job)
            }
        }
        let now = clock()
        if job.shown == nil {
            // Nothing yet: a file without artwork is looked up online now; the player is asked again later.
            if app == .music, job.playerFirst { lookUpOnline(app, job) }
            let delays = job.stream ? NowPlayingCenter.coverAskDelays : NowPlayingCenter.fileCoverAskDelays
            job.nextAskAt = job.asks <= delays.count ? now + delays[job.asks - 1] : nil
        } else if job.shown == .player, job.stream, job.rechecks < NowPlayingCenter.coverRecheckDelays.count {
            job.nextAskAt = now + NowPlayingCenter.coverRecheckDelays[job.rechecks]
            job.rechecks += 1
        } else {
            job.nextAskAt = nil
        }
    }

    private func lookUpOnline(_ app: MediaApp, _ job: CoverJob) {
        guard job.online == .idle else { return }
        job.online = .running
        guard let lookup = coverLookup else { return onlineFinished(app, job, data: nil) }
        let download = coverDownload
        lookup(job.track) { [weak self] url in
            guard let url else { return MediaUIMainHop.async { self?.onlineFinished(app, job, data: nil) } }
            download(url) { data in MediaUIMainHop.async { self?.onlineFinished(app, job, data: data) } }
        }
    }

    private func onlineFinished(_ app: MediaApp, _ job: CoverJob, data: Data?) {
        job.online = .done
        guard coverJobs[app] === job else { return }
        if let data, NowPlayingCoverCache.imageExtension(data) != nil {
            if job.shown == nil {
                show(data, digest: NowPlayingCenter.digest(data), source: .online, app: app, job: job)
            }
            return
        }
        debugLog("online lookup: no cover")
        // Nothing online for a streamed track: Music's artwork is the fallback.
        if job.shown == nil, !job.playerFirst, !job.asking, job.nextAskAt == nil { askPlayer(app, job) }
    }

    private func show(_ data: Data, digest: String, source: CoverSource, app: MediaApp, job: CoverJob) {
        let name = job.shownCount == 0 ? job.id : "\(job.id)v\(job.shownCount)"
        guard var snap = snapshots[app], snap.status.trackID == job.id,
              let path = NowPlayingCoverCache.write(data, app: app, trackID: name, folder: coverFolder) else { return }
        snap.coverPath = path
        snapshots[app] = snap
        job.shown = source
        job.shownDigest = digest
        job.shownCount += 1
        debugLog(String(format: "cover shown (%@) %.1f s after the track was seen", source.rawValue,
                        clock() - job.seenAt))
    }

    /// A picture Music gave for another track of another album — and never for this track or its album — is that
    /// track's picture, not this one's (tracks of one album share their artwork).
    private func isStale(_ digest: String, app: MediaApp, job: CoverJob) -> Bool {
        let album = NowPlayingCenter.albumKey(job.track)
        let seen = playerPictures[app, default: []].filter { $0.digest == digest }
        return seen.contains { $0.trackID != job.id && $0.album != album }
            && !seen.contains { $0.trackID == job.id || $0.album == album }
    }

    private func rememberPicture(_ digest: String, app: MediaApp, job: CoverJob) {
        var list = playerPictures[app, default: []]
        guard !list.contains(where: { $0.digest == digest && $0.trackID == job.id }) else { return }
        list.append(PlayerPicture(digest: digest, trackID: job.id, album: NowPlayingCenter.albumKey(job.track)))
        playerPictures[app] = Array(list.suffix(16))
    }

    /// Album identity for artwork comparisons: album and album artist (the artist when there is none).
    static func albumKey(_ track: NowPlayingTrack) -> String {
        let artist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
        return NowPlayingCoverLookup.normalized(track.album) + "|" + NowPlayingCoverLookup.normalized(artist)
    }

    /// Content digest of a picture (SHA-256, hex).
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Reading

    /// The snapshot a measure shows (see the "whichever is playing" rule above). `preferred` nil = no preference
    /// (WebNowPlaying, MediaKey): the last player shown, else Music.
    func snapshot(preferring preferred: MediaApp?) -> NowPlayingSnapshot {
        let now = clock()
        let wasIdle = now - lastReadAt >= NowPlayingCenter.idleAfter
        lastReadAt = now
        if wasIdle, liveSubscribers > 0 { poll() }
        let (key, chosen) = choice(preferring: preferred)
        if snapshots[chosen]?.running == true { lastChoice[key] = chosen }
        return snapshots[chosen] ?? NowPlayingSnapshot(app: chosen)
    }

    /// What `snapshot(preferring:)` shows, without counting as a read: no idle bookkeeping, no poll, the last choice
    /// kept. For reads that are not a running skin's, such as a paused skin's meters read by the Studio's live values.
    func peek(preferring preferred: MediaApp?) -> NowPlayingSnapshot {
        let chosen = choice(preferring: preferred).app
        return snapshots[chosen] ?? NowPlayingSnapshot(app: chosen)
    }

    private func choice(preferring preferred: MediaApp?) -> (key: String, app: MediaApp) {
        let key = preferred?.rawValue ?? "any"
        let first = preferred ?? lastChoice[key] ?? .music
        return (key, NowPlayingCenter.choose(preferred: first, last: lastChoice[key],
                                             snapshots: MediaApp.allCases.map { snapshots[$0] ?? NowPlayingSnapshot(app: $0) }))
    }

    /// The selection rule (pure, tested).
    static func choose(preferred: MediaApp, last: MediaApp?, snapshots: [NowPlayingSnapshot]) -> MediaApp {
        func snap(_ app: MediaApp) -> NowPlayingSnapshot? { snapshots.first { $0.app == app && $0.running } }
        let others = MediaApp.allCases.filter { $0 != preferred }
        if snap(preferred)?.status.state == 1 { return preferred }
        if let playing = others.first(where: { snap($0)?.status.state == 1 }) { return playing }
        if let last, let s = snap(last), s.status.state == 2, s.hasTrack { return last }
        if let s = snap(preferred), s.status.state == 2, s.hasTrack { return preferred }
        if let paused = others.first(where: { snap($0)?.status.state == 2 && snap($0)?.hasTrack == true }) {
            return paused
        }
        if snap(preferred) != nil { return preferred }
        if let running = others.first(where: { snap($0) != nil }) { return running }
        return preferred
    }

    // MARK: Commands

    /// Performs a skin's command on the player the measure currently shows. `playerPath`: NowPlaying's PlayerPath
    /// (used for OpenPlayer when it names a Mac application).
    func perform(_ request: NowPlayingRequest, preferring preferred: MediaApp?, playerPath: String = "",
                 live: Bool) {
        guard live || forceLive || NowPlayingCenter.demoMode else { return }
        refreshRunningState()
        let snap = snapshot(preferring: preferred)
        // A player seen running only just now: a relative value or toggle would be computed from an unknown state
        // (SetVolume +10 → 10 %); it is dropped and the player polled, so the next click works.
        if snap.running, !snap.statusKnown, request.dependsOnPlayerState {
            if liveSubscribers > 0 { pollSoon() }
            return
        }
        guard let command = MediaPlayerCommand.resolve(request, snap, now: clock()) else { return }
        perform(command, on: snap.app, running: snap.running, playerPath: playerPath)
    }

    func perform(_ command: MediaPlayerCommand, on app: MediaApp, running: Bool, playerPath: String = "") {
        if let appControl, [.open, .quit, .toggleOpen, .toggleVisible].contains(command) {
            appControl(command, app)
            return
        }
        switch command {
        case .open:
            open(app, playerPath: playerPath)
            return
        case .quit:
            quit(app)
            return
        case .toggleOpen:
            if running { quit(app) } else { open(app, playerPath: playerPath) }
            return
        case .toggleVisible:
            toggleVisible(app, playerPath: playerPath)
            return
        default:
            break
        }
        // Judgment: playback commands do not launch a closed player (only OpenPlayer / TogglePlayer do).
        guard running else { return }
        let backend = self.backend
        worker.async { [weak self] in
            backend.perform(command, on: app)
            MediaUIMainHop.async { self?.pollSoon() }
        }
    }

    /// Which players run, checked again right before a command (main thread, no Apple Event): the snapshots only
    /// change when the center polls, which it does only while a NowPlaying-type measure subscribes. A MediaKey
    /// measure never subscribes, so without this its PlayPause / Next / Previous would find every player "closed"
    /// and do nothing in a skin without NowPlaying measures; a player launched or quit since the last poll is also
    /// seen right away. A newly seen player has no status yet (stopped, no track), which is enough to choose it.
    private func refreshRunningState() {
        for app in MediaApp.allCases {
            let running = backend.isRunning(app)
            let known = snapshots[app]?.running ?? false
            guard running != known else { continue }
            var snap = NowPlayingSnapshot(app: app)
            snap.running = running
            snapshots[app] = snap
            coverJobs[app] = nil
        }
    }

    private var pollSoonScheduled = false

    /// A poll shortly after a command, so the skin shows the new state without waiting for the next second.
    private func pollSoon() {
        guard !pollSoonScheduled else { return }
        pollSoonScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pollSoonScheduled = false
            self?.poll()
        }
    }

    private func runningApp(_ app: MediaApp) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).first
    }

    private func open(_ app: MediaApp, playerPath: String) {
        if let running = runningApp(app) {
            running.unhide()
            running.activate()
            return
        }
        var url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier)
        let path = playerPath.muiTrimmed.replacingOccurrences(of: "\\", with: "/")
        if path.lowercased().hasSuffix(".app"), FileManager.default.fileExists(atPath: path) {
            url = URL(fileURLWithPath: path)
        }
        guard let url else {
            logOnce("\(app.displayName) is not installed")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func quit(_ app: MediaApp) {
        runningApp(app)?.terminate()
    }

    private func toggleVisible(_ app: MediaApp, playerPath: String) {
        guard let running = runningApp(app) else {
            open(app, playerPath: playerPath)
            return
        }
        if running.isActive && !running.isHidden {
            running.hide()
        } else {
            running.unhide()
            running.activate()
        }
    }
}

// MARK: - Cover files

enum NowPlayingCoverCache {
    /// Writes cover bytes as `cover-<app>-<id>.<jpg|png|…>` and deletes the app's older covers (a new name per track,
    /// so Image meters never show a stale cached picture). Returns the path, or nil when the bytes are not an image.
    static func write(_ data: Data, app: MediaApp, trackID: String, folder: URL) -> String? {
        guard let ext = imageExtension(data) else { return nil }
        let safeID = String(trackID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init).prefix(40))
        let prefix = "cover-\(app.rawValue)-"
        let url = folder.appendingPathComponent("\(prefix)\(safeID.isEmpty ? "track" : safeID).\(ext)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
                for name in names where name.hasPrefix(prefix) && name != url.lastPathComponent {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                }
            }
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }

    static func imageExtension(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 4 else { return nil }
        if b[0] == 0xFF && b[1] == 0xD8 { return "jpg" }
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return "png" }
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 { return "gif" }
        if b[0] == 0x42 && b[1] == 0x4D { return "bmp" }
        if b.count >= 12, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
        if (b[0] == 0x49 && b[1] == 0x49) || (b[0] == 0x4D && b[1] == 0x4D) { return "tiff" }
        return nil
    }

    /// Downloads a cover (at most 10 MB, 15 s).
    static func download(_ url: URL, completion: @escaping (Data?) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        request.setValue("Deskset", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            guard ok, let data, data.count < 10_000_000 else {
                completion(nil)
                return
            }
            completion(data)
        }.resume()
    }
}
