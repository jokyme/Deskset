import Foundation
import DesksetCore

// NowPlaying data model, value formatting and command parsing (no AppKit, no Apple Events: unit-tested).
//
// Clean-room from the public documentation only:
//   https://docs.rainmeter.net/manual/measures/nowplaying/          (NowPlaying measure)
//   https://docs.rainmeter.net/manual/plugins/deprecated/itunes/   (iTunesPlugin)
//   https://wnp.keifufu.dev/rainmeter/usage                        (WebNowPlaying, third-party)
//   https://docs.rainmeter.net/manual/measures/mediakey/            (MediaKey)
// and Music.app's scripting dictionary (`sdef /System/Applications/Music.app`). Judgment calls are listed in
// docs/compat/media-ui.md.

/// Media players Deskset reads on macOS.
enum MediaApp: String, CaseIterable {
    case music, spotify

    var bundleIdentifier: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    var displayName: String {
        switch self {
        case .music: return "Music"
        case .spotify: return "Spotify"
        }
    }

    /// The other supported player (for the "whichever is playing" rule).
    var other: MediaApp { self == .music ? .spotify : .music }
}

/// `PlayerName=` → the macOS player to prefer.
enum NowPlayingPlayerNames {
    /// Windows player interfaces (and a few Mac spellings) that stand for "the music player": Music.app.
    static let musicNames: Set<String> = [
        "", "itunes", "wmp", "aimp", "cad", "foobar2000", "foobar", "winamp", "wlm", "mediamonkey", "musicbee",
        "jriver", "mediacenter", "mediajukebox", "zune", "lastfm", "last.fm", "ttplayer", "openpandora", "music",
        "applemusic", "apple music", "itunes.exe",
    ]

    /// Preferred app and whether the name is one of the documented / known names.
    static func preference(for rawName: String) -> (app: MediaApp, known: Bool) {
        let name = rawName.muiTrimmed.lowercased()
        if name == "spotify" || name == "spotify.exe" { return (.spotify, true) }
        return (.music, musicNames.contains(name))
    }

    /// Names of players that exist on the Mac (Music, formerly iTunes, and Spotify); every other player interface is
    /// a Windows player shown with Music / Spotify instead.
    static let macPlayerNames: Set<String> = [
        "", "itunes", "itunes.exe", "music", "applemusic", "apple music", "spotify", "spotify.exe",
    ]

    /// Whether the player a `PlayerName` names exists on the Mac.
    static func hasMacPlayer(_ rawName: String) -> Bool {
        macPlayerNames.contains(rawName.muiTrimmed.lowercased())
    }

    /// `PlayerName=[MeasureName]` → `MeasureName`; nil for a player interface name.
    static func referencedMeasure(_ rawName: String) -> String? {
        let t = rawName.muiTrimmed
        guard t.count >= 3, t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        let inner = String(t.dropFirst().dropLast()).muiTrimmed
        return inner.isEmpty || inner.contains("[") || inner.contains("]") ? nil : inner
    }
}

// MARK: - Snapshot

enum PlayerRepeatMode: Int, Equatable {
    case off = 0, all = 1, one = 2
}

/// The part of a player's state polled every second.
struct NowPlayingStatus: Equatable {
    /// 0 stopped, 1 playing, 2 paused.
    var state = 0
    /// 0…100.
    var volume = 0.0
    var shuffle = false
    var repeatMode = PlayerRepeatMode.off
    /// Seconds into the current track.
    var position = 0.0
    /// Identity of the current track ("" = no current track): Music's persistent ID, Spotify's track id.
    var trackID = ""
    /// 0…100 (Music's rating; 0 for players without ratings).
    var rating = 0.0
}

/// Track metadata, read once per track.
struct NowPlayingTrack: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var albumArtist = ""
    var genre = ""
    var composer = ""
    var comment = ""
    var kind = ""
    var eq = ""
    var lyrics = ""
    /// POSIX path of the media file ("" for streams).
    var file = ""
    var number = 0.0
    var year = 0.0
    var trackCount = 0.0
    var bitRate = 0.0
    var bpm = 0.0
    var sampleRate = 0.0
    var size = 0.0
    /// Seconds.
    var duration = 0.0
    /// Web address of the cover (Spotify).
    var artworkURL = ""
}

/// Everything known about one player.
struct NowPlayingSnapshot: Equatable {
    var app: MediaApp
    var running = false
    var status = NowPlayingStatus()
    /// nil while there is no current track (or its metadata has not arrived yet).
    var track: NowPlayingTrack?
    /// Cached cover file ("" when none).
    var coverPath = ""
    /// `ProcessInfo.systemUptime` when `status` was read.
    var polledAt: TimeInterval = 0
    /// False until the player answered a poll (a player seen running right before a command has no status yet).
    var statusKnown = false

    init(app: MediaApp) {
        self.app = app
    }

    var hasTrack: Bool { running && !status.trackID.isEmpty }
    var duration: Double { hasTrack ? max(track?.duration ?? 0, 0) : 0 }

    /// Position now: the polled position plus the time since, while playing (so skins that update faster than the
    /// one-second poll see smooth progress), never past the end of the track.
    func position(at now: TimeInterval) -> Double {
        guard hasTrack else { return 0 }
        var p = status.position.isFinite ? max(status.position, 0) : 0
        if status.state == 1, now > polledAt { p += min(now - polledAt, 5) }
        let d = duration
        return d > 0 ? min(p, d) : p
    }

    /// Identity used for TrackChangeAction (nil when there is no track).
    var trackKey: String? { hasTrack ? "\(app.rawValue):\(status.trackID)" : nil }
}

// MARK: - Values

/// What a NowPlaying / iTunes / WebNowPlaying measure shows.
enum NowPlayingField: Equatable {
    // NowPlaying PlayerType
    case artist, album, title, number, year, genre, cover, file, duration, lyrics, position, progress, rating
    case repeatState, shuffle, state, status, volume
    // iTunesPlugin Command=Get…
    case albumArtist, composer, comment, kind, eq, bitRate, bpm, sampleRate, size, trackCount
    /// Rating 0…100.
    case ratingPercent
    /// Track length as "M:SS" text, seconds as the number (GetCurrentTrackTime).
    case trackTime
    /// Position in seconds, number only (GetPlayerPosition).
    case positionSeconds
    // WebNowPlaying
    case player, remaining, coverWebAddress
    /// 0 off, 1 repeat one, 2 repeat all (WebNowPlaying's numbering).
    case repeatMode3
    case supportsPlayPause, supportsSkipPrevious, supportsSkipNext, supportsSetPosition, supportsSetVolume
    case supportsToggleRepeat, supportsToggleShuffle, supportsSetRating, ratingSystem, usesNativeAPIs

    /// `PlayerType=` of the NowPlaying measure (case-insensitive).
    static func nowPlaying(_ raw: String) -> NowPlayingField? {
        switch raw.muiTrimmed.lowercased() {
        case "artist": return .artist
        case "album": return .album
        case "title": return .title
        case "number": return .number
        case "year": return .year
        case "genre": return .genre
        case "cover", "coverpath": return .cover
        case "file": return .file
        case "duration": return .duration
        case "lyrics": return .lyrics
        case "position": return .position
        case "progress": return .progress
        case "rating": return .rating
        case "repeat": return .repeatState
        case "shuffle": return .shuffle
        case "state": return .state
        case "status": return .status
        case "volume": return .volume
        default: return nil
        }
    }

    /// `PlayerType=` of WebNowPlaying: the NowPlaying types plus its own.
    static func webNowPlaying(_ raw: String) -> NowPlayingField? {
        switch raw.muiTrimmed.lowercased() {
        case "player": return .player
        case "remaining": return .remaining
        case "coverwebaddress": return .coverWebAddress
        case "repeat": return .repeatMode3
        case "supportsplaypause": return .supportsPlayPause
        case "supportsskipprevious": return .supportsSkipPrevious
        case "supportsskipnext": return .supportsSkipNext
        case "supportssetposition": return .supportsSetPosition
        case "supportssetvolume": return .supportsSetVolume
        case "supportstogglerepeatmode": return .supportsToggleRepeat
        case "supportstoggleshuffleactive": return .supportsToggleShuffle
        case "supportssetrating": return .supportsSetRating
        case "ratingsystem": return .ratingSystem
        case "isusingnativeapis": return .usesNativeAPIs
        default: return nowPlaying(raw)
        }
    }

    /// `Command=Get…` of the iTunes plugin; nil for bang commands.
    static func iTunes(_ raw: String) -> NowPlayingField? {
        switch raw.muiTrimmed.lowercased() {
        case "getsoundvolume": return .volume
        case "getplayerposition": return .positionSeconds
        case "getplayerpositionpercent": return .progress
        case "getcurrenttrackalbum": return .album
        case "getcurrenttrackartist": return .artist
        case "getcurrenttrackbitrate": return .bitRate
        case "getcurrenttrackbpm": return .bpm
        case "getcurrenttrackcomment": return .comment
        case "getcurrenttrackcomposer": return .composer
        case "getcurrenttrackeq": return .eq
        case "getcurrenttrackgenre": return .genre
        case "getcurrenttrackkindasstring": return .kind
        case "getcurrenttrackname": return .title
        case "getcurrenttrackrating": return .ratingPercent
        case "getcurrenttracksamplerate": return .sampleRate
        case "getcurrenttracksize": return .size
        case "getcurrenttracktime": return .trackTime
        case "getcurrenttracktrackcount": return .trackCount
        case "getcurrenttracktracknumber": return .number
        case "getcurrenttrackyear": return .year
        case "getcurrenttrackartwork": return .cover
        default: return nil
        }
    }

    /// Automatic MaxValue for bars / rotators (MinValue stays 0).
    func maxValue(_ snapshot: NowPlayingSnapshot) -> Double {
        switch self {
        case .progress, .volume, .ratingPercent: return 100
        case .rating: return 5
        case .state, .repeatMode3: return 2
        case .ratingSystem: return 3
        case .position, .duration, .positionSeconds, .trackTime, .remaining:
            let d = snapshot.duration
            return d > 0 ? d : 1
        default: return 1
        }
    }

    /// True for types whose value is only a number (meters format it with NumOfDecimals etc.).
    var isNumeric: Bool { NowPlayingValues.value(self, NowPlayingSnapshot(app: .music), now: 0).string == nil }
}

enum NowPlayingValues {
    /// Duration / position text: "MM:SS" ("M:SS" with DisableLeadingZero), "H:MM:SS" from one hour on.
    /// Judgment: the manual only documents MM:SS; hours are added rather than showing "75:00".
    static func clock(_ seconds: Double, leadingZero: Bool = true) -> String {
        let total = Int(min(max(seconds.isFinite ? seconds : 0, 0), 359_999_999))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : String(v) }
        if h > 0 { return "\(h):\(two(m)):\(two(s))" }
        return "\(leadingZero ? two(m) : String(m)):\(two(s))"
    }

    /// Number and string (nil = number only) of `field` for a snapshot.
    static func value(_ field: NowPlayingField, _ snap: NowPlayingSnapshot, now: TimeInterval,
                      leadingZero: Bool = true) -> (number: Double, string: String?) {
        let track = snap.hasTrack ? snap.track : nil
        func text(_ s: String?) -> (Double, String?) { (0, s ?? "") }
        func num(_ v: Double) -> (Double, String?) { (v.isFinite ? v : 0, nil) }
        let position = snap.position(at: now)
        let duration = snap.duration
        switch field {
        case .artist: return text(track?.artist)
        case .album: return text(track?.album)
        case .title: return text(track?.title)
        case .genre: return text(track?.genre)
        case .lyrics: return text(track?.lyrics)
        case .file: return text(track?.file)
        case .cover: return text(snap.hasTrack ? snap.coverPath : "")
        case .albumArtist: return text(track?.albumArtist)
        case .composer: return text(track?.composer)
        case .comment: return text(track?.comment)
        case .kind: return text(track?.kind)
        case .eq: return text(track?.eq)
        case .number: return num(track?.number ?? 0)
        case .year: return num(track?.year ?? 0)
        case .trackCount: return num(track?.trackCount ?? 0)
        case .bitRate: return num(track?.bitRate ?? 0)
        case .bpm: return num(track?.bpm ?? 0)
        case .sampleRate: return num(track?.sampleRate ?? 0)
        case .size: return num(track?.size ?? 0)
        case .duration: return (duration, clock(duration, leadingZero: leadingZero))
        case .position: return (position, clock(position, leadingZero: leadingZero))
        case .positionSeconds: return num(position)
        case .remaining:
            let left = max(duration - position, 0)
            return (left, clock(left, leadingZero: leadingZero))
        case .trackTime: return (duration, clock(duration, leadingZero: false))
        case .progress: return num(duration > 0 ? min(max(position / duration * 100, 0), 100) : 0)
        case .rating: return num(snap.hasTrack ? (snap.status.rating / 20).rounded() : 0)
        case .ratingPercent: return num(snap.hasTrack ? snap.status.rating : 0)
        case .repeatState: return num(snap.running && snap.status.repeatMode != .off ? 1 : 0)
        case .repeatMode3:
            guard snap.running else { return num(0) }
            switch snap.status.repeatMode {
            case .off: return num(0)
            case .one: return num(1)
            case .all: return num(2)
            }
        case .shuffle: return num(snap.running && snap.status.shuffle ? 1 : 0)
        case .state: return num(snap.running ? Double(snap.status.state) : 0)
        case .status: return num(snap.running ? 1 : 0)
        case .volume: return num(snap.running ? min(max(snap.status.volume, 0), 100) : 0)
        case .player: return text(snap.running ? snap.app.displayName : "")
        case .coverWebAddress: return text(snap.hasTrack ? track?.artworkURL : "")
        case .supportsPlayPause, .supportsSkipPrevious, .supportsSkipNext, .supportsSetPosition,
             .supportsSetVolume, .supportsToggleRepeat, .supportsToggleShuffle:
            return num(snap.running ? 1 : 0)
        case .supportsSetRating: return num(snap.running && snap.app == .music ? 1 : 0)
        case .ratingSystem: return num(snap.running && snap.app == .music ? 3 : 0)
        case .usesNativeAPIs: return num(1)
        }
    }
}

// MARK: - Commands

/// A `!CommandMeasure` argument, before it is resolved against the player's current state.
enum NowPlayingRequest: Equatable {
    case play, pause, playPause, stop, next, previous
    case openPlayer, closePlayer, togglePlayer
    /// Percent of the track (relative: + / - percent).
    case setPosition(Double, relative: Bool)
    /// 0…5.
    case setRating(Double)
    /// 1 on, 0 off, -1 toggle.
    case setShuffle(Int)
    case setRepeat(Int)
    /// Percent (relative: + / - percent).
    case setVolume(Double, relative: Bool)
    // iTunesPlugin
    case backTrack, fastForward, rewind, resume, showHidePlayer
    // WebNowPlaying
    case cycleRepeat, toggleShuffle, thumbsUp, thumbsDown

    /// Requests computed from the player's current state (relative values, toggles): they wait for a polled status.
    var dependsOnPlayerState: Bool {
        switch self {
        case .setPosition: return true
        case .setVolume(_, let relative): return relative
        case .setShuffle(let mode), .setRepeat(let mode): return mode < 0
        case .cycleRepeat, .toggleShuffle, .thumbsUp, .thumbsDown: return true
        default: return false
        }
    }

    /// NowPlaying measure commands (manual: Bangs).
    static func nowPlaying(_ text: String) -> NowPlayingRequest? {
        let (verb, argument) = split(text)
        switch verb {
        case "play": return .play
        case "pause": return .pause
        case "playpause": return .playPause
        case "stop": return .stop
        case "next": return .next
        case "previous": return .previous
        case "openplayer": return .openPlayer
        case "closeplayer": return .closePlayer
        case "toggleplayer": return .togglePlayer
        case "setposition": return number(argument).map { .setPosition($0.value, relative: $0.relative) }
        case "setvolume": return number(argument).map { .setVolume($0.value, relative: $0.relative) }
        case "setrating": return number(argument).map { .setRating(min(max($0.value, 0), 5)) }
        case "setshuffle": return number(argument).map { .setShuffle(toggleValue($0.value)) }
        case "setrepeat": return number(argument).map { .setRepeat(toggleValue($0.value)) }
        default: return nil
        }
    }

    /// iTunesPlugin bang commands (manual, deprecated plugins: iTunes → Bangs).
    static func iTunes(_ text: String) -> NowPlayingRequest? {
        switch split(text).verb {
        case "backtrack": return .backTrack
        case "fastforward": return .fastForward
        case "nexttrack": return .next
        case "pause": return .pause
        case "play": return .play
        case "playpause": return .playPause
        case "previoustrack": return .previous
        case "resume": return .resume
        case "rewind": return .rewind
        case "stop": return .stop
        case "power": return .togglePlayer
        case "quit": return .closePlayer
        case "soundvolumeup": return .setVolume(5, relative: true)
        case "soundvolumedown": return .setVolume(-5, relative: true)
        case "toggleitunes": return .showHidePlayer
        default: return nil
        }
    }

    /// WebNowPlaying bangs (its usage page): NowPlaying's plus Repeat / Shuffle toggles and thumbs.
    static func webNowPlaying(_ text: String) -> NowPlayingRequest? {
        switch split(text).verb {
        case "repeat": return .cycleRepeat
        case "shuffle": return .toggleShuffle
        case "togglethumbsup": return .thumbsUp
        case "togglethumbsdown": return .thumbsDown
        default: return nowPlaying(text)
        }
    }

    private static func split(_ text: String) -> (verb: String, argument: String) {
        let t = text.muiTrimmed
        guard let space = t.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return (t.lowercased(), "") }
        return (String(t[..<space]).lowercased(), String(t[space...]).muiTrimmed)
    }

    /// "50" → (50, false), "+5" → (5, true), "-10" → (-10, true). Formulas in parentheses are evaluated.
    static func number(_ argument: String) -> (value: Double, relative: Bool)? {
        let t = argument.muiTrimmed
        guard !t.isEmpty else { return nil }
        let relative = t.hasPrefix("+") || t.hasPrefix("-")
        let body = t.hasPrefix("+") ? String(t.dropFirst()) : t
        guard let v = OptionValue.number(body), v.isFinite else { return nil }
        return (v, relative)
    }

    private static func toggleValue(_ v: Double) -> Int {
        v < 0 ? -1 : (v >= 1 ? 1 : (v > 0 ? 1 : 0))
    }
}

/// A command for one player, with absolute values.
enum MediaPlayerCommand: Equatable {
    case play, pause, playPause, stop, next, previous, backTrack, fastForward, rewind, resume
    /// Seconds.
    case setPosition(Double)
    /// 0…100.
    case setVolume(Int)
    /// 0…100.
    case setRating(Int)
    case setShuffle(Bool)
    case setRepeat(PlayerRepeatMode)
    /// Launch (or bring to the front).
    case open
    case quit
    /// Open when closed, quit when open.
    case toggleOpen
    /// Show / hide the player's windows (iTunes plugin's ToggleiTunes).
    case toggleVisible

    /// Resolves a request against the player's current state (relative values, toggles).
    static func resolve(_ request: NowPlayingRequest, _ snap: NowPlayingSnapshot, now: TimeInterval) -> MediaPlayerCommand? {
        switch request {
        case .play: return .play
        case .pause: return .pause
        case .playPause: return .playPause
        case .stop: return .stop
        case .next: return .next
        case .previous: return .previous
        case .backTrack: return .backTrack
        case .fastForward: return .fastForward
        case .rewind: return .rewind
        case .resume: return .resume
        case .openPlayer: return .open
        case .closePlayer: return .quit
        case .togglePlayer: return .toggleOpen
        case .showHidePlayer: return .toggleVisible
        case let .setPosition(v, relative):
            let d = snap.duration
            guard d > 0 else { return nil }
            let current = snap.position(at: now) / d * 100
            let percent = min(max(relative ? current + v : v, 0), 100)
            return .setPosition(percent / 100 * d)
        case let .setVolume(v, relative):
            let base = relative ? snap.status.volume : 0
            return .setVolume(Int(min(max(base + v, 0), 100).rounded()))
        case let .setRating(stars):
            return .setRating(Int((min(max(stars, 0), 5) * 20).rounded()))
        case let .setShuffle(mode):
            return .setShuffle(mode < 0 ? !snap.status.shuffle : mode == 1)
        case let .setRepeat(mode):
            if mode < 0 { return .setRepeat(snap.status.repeatMode == .off ? .all : .off) }
            return .setRepeat(mode == 1 ? .all : .off)
        case .cycleRepeat:
            // Judgment: off → all → one → off, the order of the players' own repeat buttons.
            switch snap.status.repeatMode {
            case .off: return .setRepeat(.all)
            case .all: return .setRepeat(.one)
            case .one: return .setRepeat(.off)
            }
        case .toggleShuffle: return .setShuffle(!snap.status.shuffle)
        case .thumbsUp: return .setRating(snap.status.rating >= 100 ? 0 : 100)
        case .thumbsDown: return .setRating(snap.status.rating == 20 ? 0 : 20)
        }
    }
}

/// `!CommandMeasure` arguments of the MediaKey measure.
enum MediaKeyCommand: String, CaseIterable {
    case nextTrack = "nexttrack", prevTrack = "prevtrack", stop = "stop", playPause = "playpause"
    case volumeMute = "volumemute", volumeDown = "volumedown", volumeUp = "volumeup"

    /// Manual names (case-insensitive) plus spellings seen in skins (Next, Prev, Previous, Play, Pause, Mute).
    init?(argument: String) {
        let text = argument.muiTrimmed.lowercased()
        switch text {
        case "next": self = .nextTrack
        case "prev", "previous", "previoustrack": self = .prevTrack
        case "play", "pause": self = .playPause
        case "mute": self = .volumeMute
        default: self.init(rawValue: text)
        }
    }
}
