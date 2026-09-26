import AppKit
import CoreAudio
import DesksetCore

// NowPlaying, iTunesPlugin, WebNowPlaying and MediaKey measures on top of `NowPlayingCenter`.

// MARK: - Shared base

/// A measure reading `NowPlayingCenter`: subscribes (so the center polls) as long as it lives.
class NowPlayingClientMeasure: MediaUIMeasure {
    /// A compatibility note for every player of `apps` Deskset may not control (asked by macOS, not needed on
    /// Windows). NowPlaying and WebNowPlaying show whichever player plays, so every refused player matters to them;
    /// the iTunes plugin reads Music only.
    func noteRefusedAutomation(_ center: NowPlayingCenter, apps: [MediaApp] = MediaApp.allCases) {
        guard runsInApp else { return }
        NowPlayingClientMeasure.applyAutomationNotes(center, apps: apps, to: skin)
    }

    /// Adds the note of every player of `apps` Deskset may not control and takes back the note of a player it may
    /// control again (the user allowed it in System Settings; the center re-checks every 30 s).
    static func applyAutomationNotes(_ center: NowPlayingCenter, apps: [MediaApp] = MediaApp.allCases,
                                     to skin: Skin) {
        for app in apps {
            if center.isDenied(app) {
                skin.addIssue(automationNote(app))
            } else {
                skin.removeIssue(automationNote(app))
            }
        }
    }

    static func automationNote(_ app: MediaApp) -> String {
        "NowPlaying: Deskset is not allowed to control \(app.displayName), so the skin shows nothing for it. "
            + "Allow it in System Settings → Privacy & Security → Automation."
    }

    static func refusedAutomationNotes(_ center: NowPlayingCenter,
                                       apps: [MediaApp] = MediaApp.allCases) -> [String] {
        apps.filter(center.isDenied).map(automationNote)
    }

    var center: NowPlayingCenter = .shared
    private var subscription: NowPlayingSubscription?
    private weak var subscribedCenter: NowPlayingCenter?
    /// Whether this measure shows the cover (cover art is only fetched while someone shows it).
    var wantsCover = false {
        didSet { subscription?.wantsCover = wantsCover }
    }

    /// The string meters last saw: the last one read on demand or set by an update (nil = none yet; `.some(nil)` = a
    /// number-only value).
    private var lastLiveString: String??

    /// Judgment (see docs/compat/media-ui.md, "Strings between the measure's updates"): `read` gives the player's data
    /// as it is now, so meters and section variables show a new track at their next update even when the measure
    /// itself updates rarely (Monstercat Visualizer reads its title with UpdateDivider=100, every 10–20 s). Before the
    /// first update, the update's string. A disabled or paused measure keeps the string meters last saw ("a disabled
    /// measure may still return a previously obtained string value").
    func liveString(_ read: () -> String?) -> String? {
        guard updateCount > 0 else { return rawString }
        guard !disabled, !paused else { return lastLiveString ?? rawString }
        let string = read()
        lastLiveString = .some(string)
        return string
    }

    override func publishString(_ s: String?) {
        super.publishString(s)
        lastLiveString = .some(s)
    }

    /// The center's snapshot for a read on demand. It counts as a read (the poller keeps going) only while the skin
    /// runs: a paused skin's meters, read by the Studio's live values during sleep, must not keep the players polled.
    func currentSnapshot(preferring preferred: MediaApp?) -> NowPlayingSnapshot {
        controller?.areUpdatesPaused == true ? center.peek(preferring: preferred) : center.snapshot(preferring: preferred)
    }

    /// Subscribes to the current center (again when it was replaced, e.g. by a test).
    func ensureSubscribed() {
        if subscription == nil || subscribedCenter !== center {
            subscription = center.subscribe(live: runsInApp, wantsCover: wantsCover)
            subscribedCenter = center
        }
    }
}

// MARK: - NowPlaying

/// `Measure=NowPlaying` / `Plugin=NowPlaying` (manual: /manual/measures/nowplaying/).
///
/// - `PlayerName`: a player interface name (see `NowPlayingPlayerNames`: Spotify → Spotify, everything else →
///   Music.app) or `[MainMeasure]` to share the main measure's player, DisableLeadingZero and PlayerPath.
///   Judgment: the name is read with `#Variables#` only, so `[MainMeasure]` also works with DynamicVariables=1.
/// - `PlayerType`: see `NowPlayingField.nowPlaying`; an unknown type logs a warning and shows the title.
/// - `TrackChangeAction` (main measure): runs when the playing track changes to another track (not for the track
///   found by the first poll after the skin loads, and not when playback stops).
final class NowPlayingMeasure: NowPlayingClientMeasure {
    private(set) var field = NowPlayingField.title
    private(set) var preferredApp = MediaApp.music
    private(set) var parentName: String?
    private(set) var disableLeadingZero = false
    private(set) var playerPath = ""
    private var trackChangeAction = ""
    private var lastTrackKey: String?
    private var lastSnapshot = NowPlayingSnapshot(app: .music)

    override var automaticMaxValue: Double { field.maxValue(lastSnapshot) }

    override func readMeasureOptions() {
        // Variables in both forms (`#Player#`, nested `[#Player]`), never section variables, so `[MainMeasure]`
        // stays a reference even with DynamicVariables=1 and `[[#Main]]` names the measure a variable holds.
        let rawName = rawOption("PlayerName").map { skin.resolve($0, in: self, sectionVariables: false) } ?? ""
        if let parent = NowPlayingPlayerNames.referencedMeasure(rawName) {
            parentName = parent
        } else {
            parentName = nil
            let (app, known) = NowPlayingPlayerNames.preference(for: rawName)
            preferredApp = app
            if !known { logOnce("NowPlaying [\(name)]: PlayerName=\(rawName) is shown with Music.app", level: .notice) }
            if !NowPlayingPlayerNames.hasMacPlayer(rawName) {
                // Bounded: the name comes from the skin (a variable may hold anything).
                let shown = rawName.muiTrimmed.count > 40 ? String(rawName.muiTrimmed.prefix(40)) + "…"
                    : rawName.muiTrimmed
                skin.addIssue("NowPlaying: PlayerName=\(shown) has no Mac version; the skin shows "
                              + "Music (or Spotify while it plays) instead.")
            }
        }
        let type = string("PlayerType")
        if let f = NowPlayingField.nowPlaying(type) {
            field = f
        } else {
            field = .title
            logOnce("NowPlaying [\(name)]: unknown PlayerType=\(type)")
        }
        disableLeadingZero = bool("DisableLeadingZero", false)
        playerPath = string("PlayerPath")
        trackChangeAction = actionOption("TrackChangeAction")
        wantsCover = field == .cover
        ensureSubscribed()
    }

    /// The measure that names the player: this one, or the one `PlayerName=[…]` points to (followed at most 8 times).
    var mainMeasure: NowPlayingMeasure {
        var current: NowPlayingMeasure = self
        for _ in 0..<8 {
            guard let parent = current.parentName, let next = skin.measure(named: parent) as? NowPlayingMeasure,
                  next !== current else { break }
            current = next
        }
        return current
    }

    override func computeValue() -> Double {
        ensureSubscribed()
        let main = mainMeasure
        let snap = center.snapshot(preferring: main.preferredApp)
        lastSnapshot = snap
        noteRefusedAutomation(center)
        if main === self, !trackChangeAction.isEmpty {
            let key = snap.trackKey
            if let key, let last = lastTrackKey, key != last {
                lastTrackKey = key
                skin.execute(trackChangeAction, from: self)
            } else if key != nil {
                lastTrackKey = key
            }
        }
        let v = values(snap, main: main)
        publishString(v.string)
        return v.number
    }

    /// The player's current data whenever a meter or section variable reads the measure (`liveString`).
    override var currentRawString: String? {
        liveString {
            let main = mainMeasure
            return values(currentSnapshot(preferring: main.preferredApp), main: main).string
        }
    }

    private func values(_ snap: NowPlayingSnapshot, main: NowPlayingMeasure) -> (number: Double, string: String?) {
        NowPlayingValues.value(field, snap, now: center.clock(), leadingZero: !main.disableLeadingZero)
    }

    override func execute(command: String) {
        guard let request = NowPlayingRequest.nowPlaying(command) else {
            skin.log("NowPlaying [\(name)]: unknown command \"\(command)\"", level: .warning)
            return
        }
        let main = mainMeasure
        center.perform(request, preferring: main.preferredApp, playerPath: main.playerPath, live: runsInApp)
    }
}

// MARK: - iTunesPlugin (deprecated)

/// `Plugin=iTunesPlugin` (manual: /manual/plugins/deprecated/itunes/), on the NowPlaying backend with Music.app
/// preferred.
///
/// - `Command=Get…` selects the value (see `NowPlayingField.iTunes`); any other `Command` is a bang command run by
///   `!CommandMeasure Measure ""` / the old `!PluginBang "Measure"` with no argument (Judgment: skins such as
///   `Command=PlayPause` + `!RainmeterPluginBang mPlayPause` rely on that).
/// - `DefaultArtwork`: Judgment: the image (relative to the skin folder) shown by GetCurrentTrackArtwork when the
///   track has no artwork.
final class ITunesMeasure: NowPlayingClientMeasure {
    private(set) var field: NowPlayingField?
    private(set) var bangCommand = ""
    private var defaultArtwork = ""
    private var lastSnapshot = NowPlayingSnapshot(app: .music)

    override var automaticMaxValue: Double { field?.maxValue(lastSnapshot) ?? 1 }

    override func readMeasureOptions() {
        let command = string("Command").muiTrimmed
        field = NowPlayingField.iTunes(command)
        bangCommand = field == nil ? command : ""
        if field == nil, !command.isEmpty, NowPlayingRequest.iTunes(command) == nil {
            logOnce("iTunesPlugin [\(name)]: unknown Command=\(command)")
        }
        let artwork = string("DefaultArtwork").muiTrimmed
        defaultArtwork = artwork.isEmpty ? "" : skin.absolutePath(artwork, relativeTo: skin.directory)
        wantsCover = field == .cover
        ensureSubscribed()
    }

    override func computeValue() -> Double {
        ensureSubscribed()
        let snap = center.snapshot(preferring: .music)
        lastSnapshot = snap
        noteRefusedAutomation(center, apps: [.music])
        guard let v = values(snap) else {
            publishString(nil)
            return 0
        }
        publishString(v.string)
        return v.number
    }

    /// The player's current data whenever a meter reads the measure (`liveString`); a bang-only measure has none.
    override var currentRawString: String? {
        guard field != nil else { return rawString }
        return liveString { values(currentSnapshot(preferring: .music))?.string }
    }

    private func values(_ snap: NowPlayingSnapshot) -> (number: Double, string: String?)? {
        guard let field else { return nil }
        var v = NowPlayingValues.value(field, snap, now: center.clock())
        if field == .cover, v.string?.isEmpty ?? true, !defaultArtwork.isEmpty { v.string = defaultArtwork }
        return v
    }

    override func execute(command: String) {
        let text = command.muiTrimmed.isEmpty ? bangCommand : command
        guard let request = NowPlayingRequest.iTunes(text) else {
            skin.log("iTunesPlugin [\(name)]: unknown command \"\(text)\"", level: .warning)
            return
        }
        center.perform(request, preferring: .music, live: runsInApp)
    }
}

// MARK: - WebNowPlaying (third-party)

/// `Plugin=WebNowPlaying` (https://wnp.keifufu.dev/rainmeter/usage): the same data as NowPlaying from the Mac's
/// players (the browser extension it pairs with on Windows is not supported). No PlayerName: whichever player is
/// playing. `Cover` measures take `DefaultPath` when there is no cover.
final class WebNowPlayingMeasure: NowPlayingClientMeasure {
    /// The browser extension exists for Mac browsers too; what is missing is Deskset's side of the connection.
    static let note = "WebNowPlaying: Deskset does not connect to the WebNowPlaying browser extension, so browser "
        + "players are not shown; the skin shows Music or Spotify instead."

    private(set) var field = NowPlayingField.title
    private var defaultPath = ""
    private var lastSnapshot = NowPlayingSnapshot(app: .music)

    override var automaticMaxValue: Double { field.maxValue(lastSnapshot) }

    override func readMeasureOptions() {
        let type = string("PlayerType")
        if let f = NowPlayingField.webNowPlaying(type) {
            field = f
        } else {
            field = .title
            logOnce("WebNowPlaying [\(name)]: unknown PlayerType=\(type)")
        }
        let path = string("DefaultPath").muiTrimmed
        defaultPath = path.isEmpty ? "" : skin.absolutePath(path, relativeTo: skin.directory)
        wantsCover = field == .cover
        ensureSubscribed()
        skin.addIssue(WebNowPlayingMeasure.note)
    }

    override func computeValue() -> Double {
        ensureSubscribed()
        let snap = center.snapshot(preferring: nil)
        lastSnapshot = snap
        noteRefusedAutomation(center)
        let v = values(snap)
        publishString(v.string)
        return v.number
    }

    /// The player's current data whenever a meter reads the measure (`liveString`).
    override var currentRawString: String? {
        liveString { values(currentSnapshot(preferring: nil)).string }
    }

    private func values(_ snap: NowPlayingSnapshot) -> (number: Double, string: String?) {
        var v = NowPlayingValues.value(field, snap, now: center.clock())
        if field == .cover, v.string?.isEmpty ?? true, !defaultPath.isEmpty { v.string = defaultPath }
        return v
    }

    override func execute(command: String) {
        guard let request = NowPlayingRequest.webNowPlaying(command) else {
            skin.log("WebNowPlaying [\(name)]: unknown command \"\(command)\"", level: .warning)
            return
        }
        center.perform(request, preferring: nil, live: runsInApp)
    }
}

// MARK: - MediaKey

/// `Measure=MediaKey` (manual: /manual/measures/mediakey/): NextTrack, PrevTrack, Stop, PlayPause, VolumeMute,
/// VolumeDown, VolumeUp.
///
/// When Deskset has the Accessibility permission (granted by the user; never asked for here) the keys are sent as
/// real media-key events, which reach whatever app plays (browsers too) and show the system volume HUD. Otherwise
/// the track keys go to Music / Spotify through the NowPlaying backend and the volume keys change the default
/// output device's volume directly (Judgment: 2 % per step, like the Windows volume keys; mute toggles).
final class MediaKeyMeasure: MediaUIMeasure {
    var center: NowPlayingCenter = .shared
    /// Tests capture what would be sent instead of touching the system.
    static var sink: ((MediaKeyCommand, _ viaHID: Bool) -> Void)?
    /// Whether Deskset may post key events (Accessibility); replaced in tests.
    static var canPostEvents: () -> Bool = { MediaKeys.canPostEvents }

    /// Compatibility note after a track key was sent without Accessibility (taken back once it is granted).
    static let accessibilityNote = "MediaKey: without the Accessibility permission, play/pause and track keys reach "
        + "only Music and Spotify. Allow Deskset in System Settings → Privacy & Security → Accessibility to control "
        + "every player."

    /// This measure added `accessibilityNote` to its skin.
    private(set) var notedAccessibility = false

    func noteMissingAccessibility() {
        notedAccessibility = true
        skin.addIssue(MediaKeyMeasure.accessibilityNote)
    }

    override func computeValue() -> Double {
        takeBackAccessibilityNote(trusted: notedAccessibility && MediaKeyMeasure.canPostEvents())
        return 0
    }

    /// Accessibility granted since a track key added the note: it no longer applies. Checked at every update (only
    /// while the note is there) and at every key, for MediaKey measures that never update (`UpdateDivider=-1`).
    private func takeBackAccessibilityNote(trusted: Bool) {
        guard notedAccessibility, trusted else { return }
        notedAccessibility = false
        skin.removeIssue(MediaKeyMeasure.accessibilityNote)
    }

    override func execute(command: String) {
        guard let key = MediaKeyCommand(argument: command) else {
            skin.log("MediaKey [\(name)]: unknown command \"\(command)\"", level: .warning)
            return
        }
        // There is no Stop media key on the Mac: Stop always goes to the player.
        let trusted = MediaKeyMeasure.canPostEvents()
        let viaHID = key != .stop && trusted
        if let sink = MediaKeyMeasure.sink {
            sink(key, viaHID)
            return
        }
        guard runsInApp else { return }
        takeBackAccessibilityNote(trusted: trusted)
        if viaHID {
            MediaKeys.post(key)
            return
        }
        if key != .stop && key != .volumeUp && key != .volumeDown && key != .volumeMute {
            noteMissingAccessibility()
        }
        switch key {
        case .nextTrack: center.perform(.next, preferring: nil, live: true)
        case .prevTrack: center.perform(.previous, preferring: nil, live: true)
        case .stop: center.perform(.stop, preferring: nil, live: true)
        case .playPause: center.perform(.playPause, preferring: nil, live: true)
        case .volumeMute: MediaUISystemVolume.toggleMute()
        case .volumeUp: MediaUISystemVolume.change(by: 0.02)
        case .volumeDown: MediaUISystemVolume.change(by: -0.02)
        }
    }
}

/// Media-key events (the same events the keyboard's media keys produce).
enum MediaKeys {
    /// Posting keyboard events needs the Accessibility permission; checked without asking.
    static var canPostEvents: Bool { AXIsProcessTrusted() }

    /// NX key types (IOKit ev_keymap.h): sound up 0, sound down 1, mute 7, play 16, next 17, previous 18.
    static func keyType(_ key: MediaKeyCommand) -> Int32 {
        switch key {
        case .volumeUp: return 0
        case .volumeDown: return 1
        case .volumeMute: return 7
        case .playPause, .stop: return 16   // .stop is never posted (see MediaKeyMeasure)
        case .nextTrack: return 17
        case .prevTrack: return 18
        }
    }

    /// Posts the key's down and up events: built on the main thread (an `NSEvent`), at once when the caller is there,
    /// else queued there.
    static func post(_ key: MediaKeyCommand) {
        MediaUIMainHop.run { postOnMain(key) }
    }

    private static func postOnMain(_ key: MediaKeyCommand) {
        let type = keyType(key)
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((type << 16) | ((down ? 0xA : 0xB) << 8))
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// Volume of the default output device (CoreAudio; no permission needed). `change(by:)` and `toggleMute()` run on a
/// serial background queue: HAL calls are requests to the audio server and can stall (Bluetooth / AirPlay devices
/// switching), which must never freeze the skins.
enum MediaUISystemVolume {
    private static let queue = DispatchQueue(label: "Deskset MediaKey volume", qos: .userInitiated)

    private static func run(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size,
                                                &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// "Virtual main volume" ('vmvc', AudioHardwareService): the volume the menu bar slider shows.
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

    static func volume() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var a = address(virtualMainVolume)
        guard AudioObjectHasProperty(device, &a),
              AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func change(by delta: Float) {
        run {
            guard delta.isFinite, let device = defaultOutputDevice(), let current = volume() else { return }
            var value = Float32(min(max(current + delta, 0), 1))
            var a = address(virtualMainVolume)
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(device, &a, &settable) == noErr, settable.boolValue else { return }
            AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
            if value > 0 { setMute(device, false) }
        }
    }

    static func toggleMute() {
        run {
            guard let device = defaultOutputDevice() else { return }
            var muted = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            var a = address(kAudioDevicePropertyMute)
            guard AudioObjectHasProperty(device, &a),
                  AudioObjectGetPropertyData(device, &a, 0, nil, &size, &muted) == noErr else { return }
            setMute(device, muted == 0)
        }
    }

    private static func setMute(_ device: AudioDeviceID, _ on: Bool) {
        var value = UInt32(on ? 1 : 0)
        var a = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &a) else { return }
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
