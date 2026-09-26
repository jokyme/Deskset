import Foundation

// AppleScript sources for Music.app and Spotify, and parsing of their replies (pure functions: unit-tested).
//
// Rules:
// - Every script first checks `application id "…" is running` and does nothing otherwise, so polling never
//   launches a player (the `tell` block sends no event when the app is not running).
// - Every script has a `with timeout` so an unresponsive player cannot hold the worker thread for the AppleScript
//   default of two minutes.
// - Scripts only contain constants built here: numbers are formatted in Swift ("." decimal separator) and enums
//   become keywords, so no text from a skin ever ends up inside a script.
// - Polling is split in two: `status` (every second: state, volume, shuffle, repeat, position, track id, rating) and
//   `track` (only when the track id changes: title, artist, album, …), plus `artwork` for Music's cover data.
//   Spotify's cover is a web address (`artwork url`) downloaded by the center.

/// One item of a script's reply list.
enum AppleScriptValue: Equatable {
    case text(String)
    case number(Double)
    case data(Data)
    case missing

    var text: String {
        switch self {
        case .text(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        default: return ""
        }
    }

    var number: Double {
        switch self {
        case .number(let n): return n.isFinite ? n : 0
        case .text(let s): return Double(s.muiTrimmed) ?? 0
        default: return 0
        }
    }
}

enum NowPlayingScripts {
    // MARK: Sources

    private static func guarded(_ app: MediaApp, notRunning: String, _ body: String) -> String {
        """
        if application id "\(app.bundleIdentifier)" is not running then return \(notRunning)
        tell application id "\(app.bundleIdentifier)"
        \twith timeout of 4 seconds
        \(indent(body, 2))
        \tend timeout
        end tell
        return \(notRunning)
        """
    }

    private static func indent(_ text: String, _ tabs: Int) -> String {
        let prefix = String(repeating: "\t", count: tabs)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
    }

    /// Helpers shared by the track scripts (called with `my` inside the `tell` block).
    private static let handlers = """

    on textOf(x)
    \tif x is missing value then return ""
    \ttry
    \t\treturn x as text
    \ton error
    \t\treturn ""
    \tend try
    end textOf

    on numOf(x)
    \tif x is missing value then return 0
    \ttry
    \t\treturn x as real
    \ton error
    \t\treturn 0
    \tend try
    end numOf
    """

    /// Reply: `{0}` when not running, else `{1, state (0/1/2), volume, shuffle (0/1), repeat (0 off/1 all/2 one),
    /// position, track id, rating (0…100)}`.
    static func status(_ app: MediaApp) -> String {
        switch app {
        case .music:
            return guarded(app, notRunning: "{0}", """
            set vState to 0
            try
            \tset vPlayerState to player state
            \tif vPlayerState is playing or vPlayerState is fast forwarding or vPlayerState is rewinding then
            \t\tset vState to 1
            \telse if vPlayerState is paused then
            \t\tset vState to 2
            \tend if
            end try
            set vVolume to 0
            try
            \tset vVolume to sound volume
            end try
            set vShuffle to 0
            try
            \tif shuffle enabled then set vShuffle to 1
            end try
            set vRepeat to 0
            try
            \tset vRepeatMode to song repeat
            \tif vRepeatMode is all then
            \t\tset vRepeat to 1
            \telse if vRepeatMode is one then
            \t\tset vRepeat to 2
            \tend if
            end try
            set vPosition to 0
            try
            \tset vPosition to player position
            \tif vPosition is missing value then set vPosition to 0
            end try
            set vTrackID to ""
            set vRating to 0
            try
            \tset vTrack to current track
            \tset vTrackID to persistent ID of vTrack
            \ttry
            \t\tset vRating to rating of vTrack
            \tend try
            end try
            return {1, vState, vVolume, vShuffle, vRepeat, vPosition, vTrackID, vRating}
            """)
        case .spotify:
            return guarded(app, notRunning: "{0}", """
            set vState to 0
            try
            \tset vPlayerState to player state
            \tif vPlayerState is playing then
            \t\tset vState to 1
            \telse if vPlayerState is paused then
            \t\tset vState to 2
            \tend if
            end try
            set vVolume to 0
            try
            \tset vVolume to sound volume
            end try
            set vShuffle to 0
            try
            \tif shuffling then set vShuffle to 1
            end try
            set vRepeat to 0
            try
            \tif repeating then set vRepeat to 1
            end try
            set vPosition to 0
            try
            \tset vPosition to player position
            \tif vPosition is missing value then set vPosition to 0
            end try
            set vTrackID to ""
            try
            \tset vTrackID to id of current track
            \tif vTrackID is missing value then set vTrackID to ""
            end try
            return {1, vState, vVolume, vShuffle, vRepeat, vPosition, vTrackID, 0}
            """)
        }
    }

    /// Track fields, in reply order (text fields first, then numbers).
    static let trackTextFields = ["title", "artist", "album", "albumArtist", "genre", "composer", "comment", "kind",
                                  "eq", "lyrics", "file", "artworkURL"]
    static let trackNumberFields = ["number", "year", "trackCount", "bitRate", "bpm", "sampleRate", "size", "duration"]

    /// Reply: `{}` when there is no current track, else the text fields then the number fields (see above).
    static func track(_ app: MediaApp) -> String {
        switch app {
        case .music:
            // One Apple Event for all properties, then local record access.
            let text: [(String, String)] = [
                ("vTitle", "name of vProps"), ("vArtist", "artist of vProps"), ("vAlbum", "album of vProps"),
                ("vAlbumArtist", "album artist of vProps"), ("vGenre", "genre of vProps"),
                ("vComposer", "composer of vProps"), ("vComment", "comment of vProps"), ("vKind", "kind of vProps"),
                ("vEQ", "EQ of vProps"), ("vLyrics", "lyrics of vProps"),
                ("vFile", "POSIX path of (location of vProps)"), ("vArtworkURL", "\"\""),
            ]
            let numbers: [(String, String)] = [
                ("vNumber", "track number of vProps"), ("vYear", "year of vProps"),
                ("vTrackCount", "track count of vProps"), ("vBitRate", "bit rate of vProps"),
                ("vBPM", "bpm of vProps"), ("vSampleRate", "sample rate of vProps"), ("vSize", "size of vProps"),
                ("vDuration", "duration of vProps"),
            ]
            var body = """
            try
            \tset vProps to properties of current track
            on error
            \treturn {}
            end try
            """
            body += fieldAssignments(text: text, numbers: numbers)
            return guarded(app, notRunning: "{}", body) + handlers
        case .spotify:
            let text: [(String, String)] = [
                ("vTitle", "name of vTrack"), ("vArtist", "artist of vTrack"), ("vAlbum", "album of vTrack"),
                ("vAlbumArtist", "album artist of vTrack"), ("vGenre", "\"\""), ("vComposer", "\"\""),
                ("vComment", "\"\""), ("vKind", "\"\""), ("vEQ", "\"\""), ("vLyrics", "\"\""), ("vFile", "\"\""),
                ("vArtworkURL", "artwork url of vTrack"),
            ]
            let numbers: [(String, String)] = [
                ("vNumber", "track number of vTrack"), ("vYear", "0"), ("vTrackCount", "0"), ("vBitRate", "0"),
                ("vBPM", "0"), ("vSampleRate", "0"), ("vSize", "0"),
                // Spotify reports milliseconds.
                ("vDuration", "(duration of vTrack) / 1000"),
            ]
            var body = """
            try
            \tset vTrack to current track
            on error
            \treturn {}
            end try
            """
            body += fieldAssignments(text: text, numbers: numbers)
            return guarded(app, notRunning: "{}", body) + handlers
        }
    }

    private static func fieldAssignments(text: [(String, String)], numbers: [(String, String)]) -> String {
        var s = ""
        for (name, expression) in text {
            s += "\nset \(name) to \"\"\ntry\n\tset \(name) to my textOf(\(expression))\nend try"
        }
        for (name, expression) in numbers {
            s += "\nset \(name) to 0\ntry\n\tset \(name) to my numOf(\(expression))\nend try"
        }
        let names = (text + numbers).map(\.0).joined(separator: ", ")
        s += "\nreturn {\(names)}"
        return s
    }

    /// Music: the current track's first artwork in its original format (JPEG / PNG bytes); nil for Spotify (its
    /// cover is `artworkURL`).
    static func artwork(_ app: MediaApp) -> String? {
        guard app == .music else { return nil }
        return guarded(app, notRunning: "missing value", """
        try
        \treturn raw data of artwork 1 of current track
        end try
        """)
    }

    /// Script performing `command`; nil when the command is not a scripting command (open / quit / show-hide are
    /// done with NSWorkspace) or the player cannot do it (Spotify has no ratings).
    static func command(_ command: MediaPlayerCommand, _ app: MediaApp) -> String? {
        let statement: String?
        switch (command, app) {
        case (.play, _), (.resume, .spotify): statement = "play"
        case (.pause, _): statement = "pause"
        case (.playPause, _): statement = "playpause"
        case (.stop, .music): statement = "stop"
        case (.stop, .spotify): statement = "pause"
        case (.next, _): statement = "next track"
        case (.previous, _), (.backTrack, .spotify): statement = "previous track"
        case (.backTrack, .music): statement = "back track"
        case (.fastForward, .music): statement = "fast forward"
        case (.rewind, .music): statement = "rewind"
        case (.resume, .music): statement = "resume"
        case (.fastForward, .spotify): statement = "set player position to (player position + 10)"
        case (.rewind, .spotify): statement = "set player position to (player position - 10)"
        case (.setPosition(let s), _): statement = "set player position to \(literal(max(s, 0)))"
        case (.setVolume(let v), _): statement = "set sound volume to \(min(max(v, 0), 100))"
        case (.setRating(let r), .music): statement = "set rating of current track to \(min(max(r, 0), 100))"
        case (.setRating, .spotify): statement = nil
        case (.setShuffle(let on), .music): statement = "set shuffle enabled to \(on)"
        case (.setShuffle(let on), .spotify): statement = "set shuffling to \(on)"
        case (.setRepeat(let mode), .music):
            let word: String
            switch mode {
            case .off: word = "off"
            case .all: word = "all"
            case .one: word = "one"
            }
            statement = "set song repeat to \(word)"
        case (.setRepeat(let mode), .spotify): statement = "set repeating to \(mode != .off)"
        case (.open, _), (.quit, _), (.toggleOpen, _), (.toggleVisible, _): statement = nil
        }
        guard let statement else { return nil }
        return guarded(app, notRunning: "0", "\(statement)\nreturn 1")
    }

    /// AppleScript number literal (always "." as the decimal separator).
    static func literal(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        let clamped = min(max(v, -1e9), 1e9)
        if clamped == clamped.rounded() { return String(Int64(clamped)) }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), clamped)
    }

    // MARK: Replies

    enum StatusReply: Equatable {
        case notRunning
        case status(NowPlayingStatus)
        case malformed
    }

    static func parseStatus(_ items: [AppleScriptValue]) -> StatusReply {
        guard let first = items.first else { return .malformed }
        if first.number == 0 { return .notRunning }
        guard items.count >= 8 else { return .malformed }
        var s = NowPlayingStatus()
        let state = Int(items[1].number)
        s.state = (0...2).contains(state) ? state : 0
        s.volume = min(max(items[2].number, 0), 100)
        s.shuffle = items[3].number != 0
        s.repeatMode = PlayerRepeatMode(rawValue: Int(items[4].number)) ?? .off
        s.position = max(items[5].number, 0)
        s.trackID = items[6].text
        s.rating = min(max(items[7].number, 0), 100)
        return .status(s)
    }

    /// nil when the reply says there is no current track.
    static func parseTrack(_ items: [AppleScriptValue]) -> NowPlayingTrack? {
        let textCount = trackTextFields.count
        guard items.count >= textCount + trackNumberFields.count else { return nil }
        func text(_ i: Int) -> String { items[i].text }
        func number(_ i: Int) -> Double { items[textCount + i].number }
        var t = NowPlayingTrack()
        t.title = text(0)
        t.artist = text(1)
        t.album = text(2)
        t.albumArtist = text(3)
        t.genre = text(4)
        t.composer = text(5)
        t.comment = text(6)
        t.kind = text(7)
        t.eq = text(8)
        t.lyrics = text(9)
        t.file = text(10)
        t.artworkURL = text(11)
        t.number = number(0)
        t.year = number(1)
        t.trackCount = number(2)
        t.bitRate = number(3)
        t.bpm = number(4)
        t.sampleRate = number(5)
        t.size = number(6)
        t.duration = max(number(7), 0)
        return t
    }
}
