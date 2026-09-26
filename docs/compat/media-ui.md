# Media, network-info and UI plugins (Mac vs Windows)

Area `media-ui`: NowPlaying, the deprecated iTunesPlugin, WebNowPlaying, MediaKey, WiFiStatus, InputText, FrostedGlass,
Chameleon, IsFullScreen, GetActiveTitle and SysColor. Code: `Sources/Deskset/Plugins/Media/*`, `Sources/Deskset/Plugins/UI/*`;
tests: `Deskset --self-test MediaUI`; original test skins: `TestSkins/MediaUI/*`.

Sources used (public documentation only — no Rainmeter or plugin source code):
- Rainmeter manual: [NowPlaying](https://docs.rainmeter.net/manual/measures/nowplaying/),
  [WiFiStatus](https://docs.rainmeter.net/manual/measures/wifistatus/),
  [MediaKey](https://docs.rainmeter.net/manual/measures/mediakey/),
  [InputText](https://docs.rainmeter.net/manual/plugins/inputtext/), [iTunes
  (deprecated)](https://docs.rainmeter.net/manual/plugins/deprecated/itunes/).
- Third-party usage pages: WebNowPlaying ([wnp.keifufu.dev/rainmeter/usage](https://wnp.keifufu.dev/rainmeter/usage)),
  FrostedGlass (the "[v1.2.0] FrostedGlass" usage post on the Rainmeter forums and the project README), Chameleon
  (github.com/socks-the-fox/Chameleon `Readme.md`), SysColor (github.com/brianferguson/SysColor.dll `README.md`),
  IsFullScreen (the "IsFullScreen 3.0" forum post, prose only — the post also embeds the plugin's source, which was not
  used), GetActiveTitle (github.com/jsmorley/GetActiveTitle description).
- macOS: Music.app's scripting dictionary (`sdef /System/Applications/Music.app`), Spotify's public AppleScript terms,
  CoreWLAN, CoreLocation, CoreAudio and AppKit documentation.

How the plugins are hooked up: `MediaUIPlugins.register()` registers every type with `MeasureRegistry`
(`Measure=NowPlaying|WiFiStatus|MediaKey` and `Plugin=` for all of them, with or without `Plugins\` and `.dll`).

---

## Permissions and privacy (applies to several plugins)

### macOS permissions are asked lazily, only for skins running in the app
- Windows (Rainmeter): plugins read players, Wi-Fi and windows without asking (Windows 11 24H2 needs "Let desktop apps
  access your location" for WiFiStatus).
- Mac (Deskset): three permissions can come up, each only the first time a *loaded skin in the app* needs it:
  **Automation** ("Deskset wants to control Music/Spotify") the first time a NowPlaying/iTunes/WebNowPlaying measure
  polls a *running* player or a command (including a MediaKey track key without Accessibility) is sent to one;
  **Location Services** the first time a WiFiStatus measure of type SSID or LIST loads.
  **Accessibility** is never requested; when the user has granted it, MediaKey sends real media keys and GetActiveTitle
  reads real window titles. `--render`, self-tests and skins checked by the Manage window never trigger a prompt.
- Why: macOS privacy (TCC). Nothing may block: the permission prompts are waited for on background threads.
- Skin impact: when a permission is denied the measures show "closed player" / empty values and one line is written to
  the log with the System Settings path to change it; nothing crashes or hangs. The skin also gets a compatibility note
  (Automation refused for Music or Spotify, Location Services off for an SSID / LIST measure, a MediaKey track key sent
  without Accessibility), which is taken back once the permission is granted: Automation when the player answers again
  (re-checked every 30 s), Location Services at the measure's next update, Accessibility at the MediaKey measure's next
  update or key. The full list of
  permission notes is in [`app.md`](app.md#refused-permissions-become-compatibility-notes).
- Status: emulated

### How the Automation permission is checked
- Windows (Rainmeter): no equivalent.
- Mac (Deskset): before the first Apple Event to a player, Deskset checks the permission with "any event" wildcard codes
  and asks the user if needed (on the background thread). The SDK documents the wildcard codes for *checking*, not for
  *asking*. So when the check answers "would require consent" (no prompt was shown), Deskset sends the script anyway:
  that Apple Event makes macOS show the prompt. Only an explicit refusal ("not permitted") stops polling for that
  player. It is then re-checked every 30 s without asking, so granting it later in System Settings works without a
  restart. A refusal that comes back from a script also stops the metadata/cover reads until the permission is
  granted.
- Why: if a "would require consent" answer were treated as a refusal, no Apple Event would ever be sent, so the prompt
  would never appear and NowPlaying could never work.
- Skin impact: none. The prompt appears the first time a skin with NowPlaying data (or a MediaKey/NowPlaying command)
  meets a running player.
- Status: emulated

---

## NowPlaying (`Measure=NowPlaying`, `Plugin=NowPlaying`)

### PlayerName → macOS player
- Windows (Rainmeter): selects a player interface: AIMP, CAD (foobar2000, MusicBee, J. River), iTunes, Winamp, WMP,
  Spotify (partial), WLM (Last.fm, TTPlayer, OpenPandora, Zune), or `[MainMeasure]`.
- Mac (Deskset): only Music.app and Spotify can be read. `Spotify` prefers Spotify; every other name (iTunes, WMP, AIMP,
  CAD, Winamp, WLM, foobar2000, MediaMonkey, MusicBee, Music, AppleMusic, empty…) prefers Music.app. An unknown name
  also prefers Music.app and logs a notice once.
- Why: those are the scriptable players on macOS; Windows player APIs do not exist.
- Skin impact: skins written for any player work with whatever the user plays on the Mac.
- Status: emulated

### Other players (QQ Music, NetEase Cloud Music, browsers, VLC…)
- Windows (Rainmeter): each supported player is read through its own interface; others are not supported either.
- Mac (Deskset): not read. These players have no scripting interface, and since macOS 15.4 the system-wide Now Playing
  information (what Control Center shows) can only be read by Apple-signed processes; ordinary apps get nothing
  (verified on macOS 26.5: an ad-hoc-signed process receives an empty dictionary). Deskset does not work around that
  restriction (for example by borrowing an Apple-signed helper such as `osascript` or `perl`): product decision of
  2026-09-24, because it circumvents a platform privacy restriction that Apple can close at any time.
- Why: no public API; the private one is restricted by the system.
- Skin impact: while only such a player plays, NowPlaying measures show nothing (skins show their placeholder, e.g.
  `Substitute="":"#@#NoCover.png"`); Music or Spotify is shown when running.
- Status: not supported

### "Whichever is playing" rule
- Windows (Rainmeter): a measure reads exactly the named player.
- Mac (Deskset): the named (preferred) player is shown when it is playing; otherwise another running player that is
  playing; otherwise the player shown last if it still has a paused track; otherwise the preferred player if it has a
  paused track; then another paused player; then any running player; else the (closed) preferred player. All measures of
  a skin that share the same preference see the same player, and commands go to the player being shown.
- Why: a Windows skin hard-codes e.g. `PlayerName=WMP`, but a Mac user may listen in Spotify; showing nothing would make
  most music skins useless.
- Skin impact: `PlayerName=Spotify` still shows Music.app while only Music plays. Two skins set up for two different
  players both show the one that plays.
- Status: emulated (judgment call)

### `PlayerName=[MainMeasure]`
- Windows (Rainmeter): secondary measures name the main measure; PlayerPath, TrackChangeAction and DisableLeadingZero
  are valid on the main measure only.
- Mac (Deskset): same. The reference is followed up to 8 levels; a missing or non-NowPlaying target makes the measure
  its own main measure (Music.app preferred). Judgment: PlayerName resolves variables in both forms (`#Player#` and
  the nested `[#Player]`) but never section variables, so `[MainMeasure]` is never mistaken for a section variable,
  even with `DynamicVariables=1`. `[[#Main]]` names the measure held by the variable `Main`.
- Why: —
- Skin impact: none. Skins that repeat `PlayerName=#Player#` on every measure (Nelamint, Simple Clean) share one poller
  anyway.
- Status: identical

### PlayerType values
- Windows (Rainmeter): Artist, Album, Title, Number, Year, Genre, Cover, File, Duration, Lyrics, Position, Progress,
  Rating (0–5), Repeat (0/1), Shuffle (0/1), State (0 stopped, 1 playing, 2 paused), Status (0/1), Volume (0–100).
  Duration/Position: string MM:SS, number = seconds.
- Mac (Deskset): all of them. Text types have number 0; number types have no string of their own (meters format the
  number). Details:
  - Duration / Position: `MM:SS`, `M:SS` with DisableLeadingZero; Judgment: from one hour on `H:MM:SS` (the manual
    only shows MM:SS). Closed player: `00:00`.
  - Position is interpolated between polls while playing (polled position + time since the poll, never past the end),
    so skins updating faster than once a second move smoothly.
  - Progress = position / duration × 100 (0 without a duration).
  - Rating = Music's 0–100 rating / 20, rounded (half stars round up). Spotify has no ratings: 0.
  - Repeat = 1 for "repeat one" and "repeat all" (Music) or `repeating` (Spotify).
  - State: Music's fast-forwarding / rewinding count as playing (1).
  - Status = 1 while the player app runs (even when it has no track).
  - Genre, Year, Lyrics: Music only (Spotify exposes none of them: "", 0, "").
  - File: POSIX path of the track's file (Music library files); "" for Apple Music / Spotify streams.
  - Cover: see "Cover art" below. `CoverPath` is accepted as a synonym (older skins).
  - Automatic MaxValue: Progress/Volume 100, Rating 5, State 2, Position/Duration = the track length (1 without a
    track); others 1. Judgment: lets `Meter=Bar` + `PlayerType=Position` work without MaxValue.
  - Unknown PlayerType: logs a warning once and shows the title.
- Why: macOS player data.
- Skin impact: identical for Music.app; Spotify lacks genre/year/lyrics/rating like on Windows ("partially supported").
- Status: identical (Music) / partial (Spotify)

### Lyrics
- Windows (Rainmeter): downloaded from letras.mus.br using the ID3 Artist and Title.
- Mac (Deskset): the lyrics stored with the track in Music.app (`lyrics` property); no web lookup.
- Why: no network scraping of a third-party site from the app; Music.app already has lyrics for many tracks.
- Skin impact: empty for tracks without embedded lyrics and for Spotify.
- Status: partial

### Cover art
- Windows (Rainmeter): path to a cover image file.
- Mac (Deskset): Music's first artwork of the current track (original bytes) or Spotify's `artwork url` (downloaded,
  ≤ 10 MB, 15 s timeout) is written to `~/Library/Caches/Deskset/NowPlaying/cover-<player>-<track id>.<jpg|png|…>`; a
  new file name per track (so Image meters never keep a stale cached picture) and older covers of that player are
  deleted. "" while there is no cover, so `Substitute="":"#@#NoCover.png"` works. Covers are fetched only while at
  least one measure of type Cover exists.
  - Local files: Music's artwork, asked for as soon as the track is seen.
  - Tracks streamed from Apple Music (no file): Music's scripting interface is no reliable source for them — their
    artwork arrives seconds late or not at all, and right after a track change Music often still hands out the
    previous track's picture (observed on macOS 26.5). So they are looked up online at once with Apple's public
    iTunes Search API (`https://itunes.apple.com/search`, songs by artist + title, 600 × 600): first in the storefront
    of the user's region, then in one more (Taiwan for Chinese names, else the US; the public search serves nothing
    for the China storefront). A result must match the artist — one of the credited names ("A, B & C", "A feat. B"),
    with Traditional and Simplified Chinese, width and accents folded; its romanization ("Yusheng Lin" for 林雨声, as
    some storefronts write Chinese names); or, when the storefront writes the name in another script ("Jay Chou" for
    周杰伦), an exact title — and the song: its title (also without decorations such as "(Live)" or a subtitle in
    brackets) or its exact album (tracks of one album share the cover). Another song of the same artist is never
    taken: a track the search does not know gets no online cover rather than a wrong one. The best match by artist,
    title and album wins. At most 15 requests a minute (Apple's limit is about 20).
  - Music's artwork is the fallback when the lookup finds nothing (or is off), and for files without artwork the
    lookup is: Music is asked over 30 s (0, 1, 2, 3, 5, 8, 12, 20, 30 s); a picture it gave for another track of
    another album — and never for this track or its album — is ignored (tracks of one album share artwork); its
    picture of a streamed track is looked at again 5 and 15 s after it is shown and replaced by a newer one.
  - Privacy: the lookup sends the artist and title of the playing track to Apple — for streamed tracks, and for files
    without artwork — only while a skin shows a cover. Off with
    `defaults write app.deskset.Deskset OnlineCoverLookup -bool NO` (read at every lookup; no restart needed).
  - Diagnostics: `defaults write app.deskset.Deskset NowPlayingDebug -bool YES` logs every cover step to
    `~/Library/Logs/Deskset/Deskset.log`; `Deskset --cover-lookup ARTIST TITLE [ALBUM]` runs the lookup and prints each
    request.
- Why: players hand out data, not files; Music's artwork of streamed tracks is late, missing or stale.
- Skin impact: covers of streamed tracks appear about 1–3 s after the track changes (the placeholder until then; the
  time is the lookup's round trip); a track Apple's search does not know shows Music's artwork if it has one, else
  the placeholder. The online picture is the catalog's cover of that release (for a streamed track, the same picture
  Music shows).
- Status: identical (library tracks, Spotify) / emulated (streamed Apple Music tracks)

### Polling, performance and "never launch a player"
- Windows (Rainmeter): each update reads the player.
- Mac (Deskset): one shared poller for the whole app, on a background thread, once a second, only while a measure of a
  skin running in the app exists and only for players that are running (checked with NSRunningApplication; every
  script also starts with `if application id "…" is not running then return`, so no Apple Event can launch a player).
  The poll reads state/volume/shuffle/repeat/position/track id/rating (~8 Apple Events); track metadata is read once
  per track, the cover once per track. Each script has a 4 s timeout. Polling pauses when no measure has read a value
  for 30 s (skins paused during sleep / locked screens) and resumes on the next read. Values appear one update after
  the skin loads (the first poll is asynchronous). Judgment: AppleScript runs on one dedicated background thread
  (never the main thread). Apple's older NSAppleScript notes recommend the main thread, but one thread that is always
  the same is safe in practice. A player that quits in the instant between the "is running" check and the Apple
  Event could be relaunched by that event (a window of a few milliseconds that AppleScript cannot close).
- Why: Apple Events are slow and can block; the main thread must never wait for a player.
- Skin impact: data can be up to one second old (position is interpolated).
- Status: emulated

### Strings between the measure's updates
- Windows (Rainmeter): the plugin documentation says GetString is called on demand, whenever the string is needed and
  possibly several times per update, and advises plugins to return the string they computed in Update. When a
  NowPlaying measure's string is refreshed between its own updates is not documented. Song-information skins rely on
  it happening: Monstercat Visualizer reads its title, artist and cover with UpdateDivider=100 (every 10–20 s) and
  shows a new track at once, its player being read by a State measure every 2 updates.
- Mac (Deskset): NowPlaying, iTunesPlugin and WebNowPlaying measures answer meters, section variables and Lua's
  GetStringValue with the player's current data (at most a second old, see Polling), Substitute included
  (`Measure.currentRawString`). The number, IfConditions, IfMatch, OnChangeAction and TrackChangeAction follow the
  measure's own updates. A disabled or paused measure keeps the string meters last saw (general options: a disabled
  measure "may still return a previously obtained string value"). Reads made while the skin is paused (sleep, locked
  screens) do not keep the players polled. Judgment: every string follows the player, whatever the UpdateDivider.
- Why: a new track would otherwise show 10–20 s late in such skins.
- Skin impact: title, artist and cover follow a track change within about a second. Position, Remaining and
  Progress strings change every second even on a measure updated every few seconds (the numbers do not).
- Status: emulated

### TrackChangeAction
- Windows (Rainmeter): "Action to execute when the track changes."
- Mac (Deskset): runs (on the main measure) when the track identity (Music persistent ID / Spotify track id, per player)
  changes to another track. Judgment: not for the first track seen after the skin loads, and not when playback stops or
  the player quits (it runs when the next track appears).
- Why: the manual does not define these edge cases.
- Skin impact: none expected.
- Status: identical (judgment on edge cases)

### DisableLeadingZero, PlayerPath
- Windows (Rainmeter): `DisableLeadingZero=1` → M:SS (main measure). `PlayerPath` launches the player for OpenPlayer.
- Mac (Deskset): DisableLeadingZero as documented. PlayerPath is used only when it names an existing `.app` bundle;
  Windows `.exe` paths are ignored and the Mac player (found by bundle id) is opened.
- Why: Windows paths do not exist on the Mac.
- Skin impact: none.
- Status: identical / emulated

### Commands (`!CommandMeasure`)
- Windows (Rainmeter): Play, Pause, PlayPause, Stop, Next, Previous, OpenPlayer, ClosePlayer, TogglePlayer,
  SetPosition n / +n / -n (percent), SetRating 0–5, SetShuffle 1/0/-1, SetRepeat 1/0/-1, SetVolume n / +n / -n.
- Mac (Deskset): all of them, sent to the player being shown (commands on child measures work too). Values are clamped
  (position 0–100 %, volume 0–100, rating 0–5); relative values use the current state; arguments may be formulas
  `(…)`. SetRepeat 1 = repeat all; -1 toggles off ↔ all. Spotify: Stop = pause (Spotify has no stop), SetRating is
  ignored. OpenPlayer launches / activates the player, ClosePlayer quits it politely, TogglePlayer does either.
  Judgment: playback commands never launch a closed player (only OpenPlayer/TogglePlayer do). After a command the
  player is polled again after 0.25 s. An unknown command logs a warning.
  Right before a command, Deskset checks again which players are running (NSRunningApplication, no Apple Event), so a
  command works without a recent poll. This covers MediaKey measures, which never poll, and a player launched or quit
  in the last second. Judgment: a player seen running only at that moment has no known state yet. Commands that
  depend on the state (relative SetVolume/SetPosition, SetShuffle -1, SetRepeat -1, the WebNowPlaying Repeat/Shuffle/
  thumbs toggles, iTunes SoundVolumeUp/Down) are dropped once and the player is polled. Otherwise `SetVolume +10`
  would set 10 %. The next click works.
- Why: AppleScript commands of Music.app / Spotify.
- Skin impact: none.
- Status: identical (Music) / partial (Spotify: no ratings)

---

## iTunesPlugin (deprecated, `Plugin=iTunesPlugin`)

### Command=Get… values
- Windows (Rainmeter): GetSoundVolume, GetPlayerPosition, GetPlayerPositionPercent, GetCurrentTrackAlbum/Artist/Bitrate/
  BPM/Comment/Composer/EQ/Genre/KindAsString/Name/Rating (0–100)/SampleRate/Size/Time/TrackCount/TrackNumber/Year/
  Artwork from iTunes.
- Mac (Deskset): the same values from the NowPlaying backend with Music.app preferred ("whichever is playing" applies).
  GetPlayerPosition is a number (seconds). GetCurrentTrackTime: string `M:SS` (Judgment: the format of iTunes' own
  "time" property), number = seconds. GetCurrentTrackRating: 0–100. Bitrate (kbps), BPM, SampleRate (Hz), Size (bytes),
  TrackCount, Comment, Composer, EQ and KindAsString come from Music.app (0 / "" for Spotify).
- Why: iTunes became Music.app.
- Skin impact: PogPack's iTunes tabs work with Music.app.
- Status: identical

### DefaultArtwork
- Windows (Rainmeter): "Path of the artwork folder relative to the skin folder. Used with
  Command=GetCurrentTrackArtwork."
- Mac (Deskset): Judgment: the path (relative to the skin folder) returned by GetCurrentTrackArtwork when the track has
  no cover; the cover itself is the NowPlaying cache file.
- Why: the documentation is ambiguous; this keeps the skin's placeholder image visible.
- Skin impact: none expected.
- Status: emulated

### Bang commands
- Windows (Rainmeter): Backtrack, FastForward, NextTrack, Pause, Play, PlayPause, PreviousTrack, Resume, Rewind, Stop,
  Power, Quit, SoundVolumeUp/Down (±5 %), ToggleiTunes (show/hide the window).
- Mac (Deskset): all of them. Power = open/quit, Quit = quit, ToggleiTunes = hide Music when it is the active app,
  otherwise show/activate it. On Spotify: Backtrack = previous track, FastForward/Rewind = ±10 s, Resume = play.
  Judgment: a measure with `Command=<bang>` runs that bang for `!CommandMeasure Measure ""` and for the old
  `!PluginBang "Measure"` with no argument (PogPack: `LeftMouseDownAction=!RainmeterPluginBang mPlayPause`).
- Why: old skins bind a measure per button.
- Skin impact: none.
- Status: identical

---

## WebNowPlaying (third-party, `Plugin=WebNowPlaying`)

### Data source
- Windows: a browser extension / desktop adapters send the media of web players (YouTube, SoundCloud, Spotify web…) to
  the plugin.
- Mac (Deskset): the WebNowPlaying browser extension is not supported; the measures show Music.app / Spotify through the
  NowPlaying backend (no PlayerName: whichever player is playing, the last one shown otherwise).
- Why: the extension protocol is not documented publicly; web media on macOS is not readable without private APIs.
- Skin impact: WebNowPlaying skins work as music widgets for Music / Spotify, but not for browser media.
- Status: partial

### PlayerType values and bangs
- Windows: Status, Player, Title, Artist, Album, Cover (+ DefaultPath), CoverWebAddress, Duration, Position, Remaining,
  Progress, Volume, State, Rating, Repeat (0 off, 1 one, 2 all), Shuffle, Supports* flags, RatingSystem,
  IsUsingNativeAPIs; bangs Play, Pause, PlayPause, Next, Previous, Repeat, Shuffle, ToggleThumbsUp/Down, SetRating,
  SetPosition, SetVolume.
- Mac (Deskset): all. Player = "Music" / "Spotify"; CoverWebAddress = Spotify's artwork URL ("" for Music);
  Supports* = 1 while a player runs (SupportsSetRating only for Music); RatingSystem = 3 (scale) for Music, 0 for
  Spotify; IsUsingNativeAPIs = 1. Judgment: the Repeat bang cycles off → all → one → off (the players' own button
  order); ToggleThumbsUp sets 5 stars or 0, ToggleThumbsDown 1 star or 0. Duration/Position/Remaining strings use the
  NowPlaying format (`MM:SS`, `H:MM:SS`).
- Why: —
- Skin impact: none beyond the data source.
- Status: emulated

---

## MediaKey (`Measure=MediaKey`)

### Commands
- Windows (Rainmeter): sends multimedia keystrokes: NextTrack, PrevTrack, Stop, PlayPause, VolumeMute, VolumeDown,
  VolumeUp (Windows shows its volume indicator).
- Mac (Deskset): when the user has given Deskset the Accessibility permission, NextTrack/PrevTrack/PlayPause/Volume* are
  posted as real media-key events (they reach whatever app plays, and the volume keys show the system volume HUD).
  Otherwise (the default; the permission is never requested) the track keys go to Music / Spotify through the NowPlaying
  backend (Automation permission) and the volume keys change the default output device's volume directly through
  CoreAudio (on a background queue: audio-server calls can stall while devices switch): Judgment: ±2 % per key (like one
  press of the Windows volume keys); VolumeMute toggles mute; raising the volume unmutes. A device without a settable
  volume (e.g. some HDMI/DisplayPort outputs) is left alone. Stop always goes to the player (there is no Stop media key
  on the Mac). The track keys find the running player at the moment of the click (Music first, else Spotify; the one
  that is playing wins), even when no skin shows NowPlaying data. The first track key sent to a player can bring up the
  Automation prompt.
- Why: posting keyboard events requires Accessibility on macOS.
- Skin impact: without Accessibility the track keys control only Music / Spotify (not browsers) and no volume HUD is
  shown; the first track key sent without it adds a compatibility note, removed once Accessibility is granted.
- Status: emulated

---

## WiFiStatus (`Measure=WiFiStatus`, `Plugin=WiFiStatus`)

### SSID and Location Services
- Windows (Rainmeter): SSID of the current connection ("connecting…" while connecting). Windows 11 24H2+ needs the
  location setting.
- Mac (Deskset): from CoreWLAN. macOS returns network names only to apps with Location Services permission; Deskset asks
  for it the first time a skin with an SSID or LIST measure loads in the app. Without it SSID is "" (a notice is logged
  once, and the skin gets a compatibility note until Location Services are allowed) — use `Substitute="":"…"` for a
  placeholder. No "connecting…" states (CoreWLAN reports only associated
  networks).
- Why: macOS privacy (Sonoma and later).
- Skin impact: the user sees a Location Services prompt; denying it hides network names only.
- Status: emulated

### Quality, TXRate, RXRate
- Windows (Rainmeter): Quality = percentage of the maximum dBm signal strength; TXRate / RXRate = theoretical maximum
  speeds in SI kilobits per second.
- Mac (Deskset): Judgment: Quality = 2 × (RSSI + 100) clamped to 0–100 (−50 dBm or better = 100, −100 dBm = 0; the linear
  scale Windows uses for its signal quality); 0 when not connected. TXRate = CoreWLAN transmit rate (Mbps) × 1000.
  RXRate: macOS reports a single link rate, used for RXRate too. Automatic MaxValue of Quality is 100.
- Why: CoreWLAN exposes RSSI and one rate.
- Skin impact: RXRate equals TXRate.
- Status: emulated (RXRate partial)

### Encryption, AUTH, PHY
- Windows (Rainmeter): Encryption NONE/WEP40/TKIP/AES/WEP104/WPA_GROUP/WEP/BIP/GCMP; AUTH Open/Shared/WPA-NONE/
  WPA-Enterprise/WPA-Personal/WPA2-…/WPA3-…; PHY 802.11a/ac/ad/ax/b/be/g/n, DSSS, FHSSS, IR-Band; unknown → `???`.
- Mac (Deskset): mapped from CoreWLAN's security mode and PHY mode: none → NONE/Open; WEP → WEP/Open; dynamic WEP →
  WEP/Shared; WPA(-mixed) → TKIP + WPA-Personal/Enterprise; WPA2 → AES + WPA2-…; WPA3 (and transition) → AES +
  WPA3-…; OWE (enhanced open) → AES/Open; PHY 802.11a/b/g/n/ac/ax/be. Not connected / unknown → `???`.
- Why: macOS reports a combined security mode, not separate cipher and authentication algorithms; WEP40/WEP104,
  WPA_GROUP, BIP, GCMP, DSSS, FHSSS, IR-Band, 802.11ad are never reported.
- Skin impact: rarely-used values never appear.
- Status: emulated

### LIST, WiFiListStyle, WiFiListLimit
- Windows (Rainmeter): visible networks, one per line, styles 0–7 (SSID, @PHY, (Encryption:AUTH), [Quality]), limit
  default 5, strongest first.
- Mac (Deskset): read on a background thread at most every 30 s from the system's latest scan results
  (`cachedScanResults`, free). Judgment: Deskset forces an active scan only once when the list is first used, then at
  most every 5 minutes (every minute while the system has no cached results). An active scan takes seconds and briefly
  moves the radio off its channel, which causes latency spikes in calls and games, so forcing one every 30 s would hurt
  the user's connection. Networks without a name are skipped. There is one line per SSID (the strongest), strongest
  first, up to `WiFiListLimit` lines. Judgment: quality in the list is written `[80%]`; for a scanned network
  PHY/Encryption/AUTH are the best modes it supports. The number value is the number of networks found. Needs Location
  Services (without it the list is empty).
- Why: scanning is slow and disruptive on macOS, and SSIDs need Location Services.
- Skin impact: the list is as fresh as the system's own scans (macOS rescans on its own, e.g. when the Wi-Fi menu is
  opened); it can lag a few minutes behind networks appearing or disappearing.
- Status: emulated

### WiFiIntfID and refresh
- Windows (Rainmeter): index of the wireless interface (0 = first).
- Mac (Deskset): 0 = the default Wi-Fi interface, N = the N-th entry (0-based) of CoreWLAN's interface list; a missing
  index gives empty values. Readings are shared by all measures and refreshed off the main thread at most every 2 s;
  values appear one measure update after load.
- Why: CoreWLAN calls can block.
- Skin impact: a measure with a large UpdateDivider shows 0 until its second update.
- Status: emulated

---

## InputText (`Plugin=InputText`)

### The input box and keyboard focus
- Windows (Rainmeter): a free-floating edit box at the measure's X/Y/W/H; incompatible with Stay Topmost skins.
- Mac (Deskset): a borderless *non-activating* panel positioned over the skin window (skin coordinates from the window's
  top-left), holding a native text field that takes the keyboard without activating Deskset — the app the user was in
  stays frontmost and gets the keyboard back when the box closes (a skin window that had the focus gets it back). The
  box follows the skin window if it moves and closes if the skin unloads (no action runs then). Judgment: TopMost unset
  → the skin's own level, ordered just above the skin (so it also works with Stay Topmost skins); TopMost=1 → above
  floating and Stay Topmost windows; TopMost=0 → a normal window. `W` missing → the rest of the skin's width (≥ 40); `H`
  missing → the font's line height + 6 (the manual gives no defaults). Relative `r`/`R` positions are not supported (as
  documented). The text is vertically centred with 2-point side margins; the DefaultValue is selected. Judgment: X and Y
  are limited to ±100000 points from the skin window (AppKit rejects window frames outside the 32-bit range, which a
  runaway formula such as `X=(1/0.0000000001)` can produce).
- Why: skin windows are non-activating panels and cannot host a field.
- Skin impact: works on Stay Topmost skins, unlike Windows.
- Status: emulated

### Options
- Windows (Rainmeter): SolidColor (default white; its alpha applies to the whole box), FontColor (default black, alpha
  ignored), FontFace, FontSize, StringStyle, StringAlign (Left/Right/Center), DefaultValue, Password, InputLimit,
  InputNumber, TopMost, FocusDismiss, OnDismissAction, X/Y/W/H.
- Mac (Deskset): all, read when the bang runs (with the current `#Variables#`). Fonts are resolved like the String meter
  (same face matching and 96-DPI size conversion); a face that is not installed falls back to the system font.
  Password shows bullets instead of asterisks. InputNumber: ASCII digits, one leading `-`, one `.`. InputLimit counts
  characters. Judgment: FontSize defaults to 10 and FontFace to Arial (as the String meter).
- Why: —
- Skin impact: none.
- Status: identical

### Keys and dismissal
- Windows (Rainmeter): Enter submits; Escape dismisses; Ctrl+Enter inserts a new line (two characters `\r\n` toward
  InputLimit); FocusDismiss=1 (default) → clicking elsewhere dismisses; FocusDismiss=0 → "the mouse is disabled until
  Enter or Escape is pressed"; OnDismissAction runs when dismissed without Enter.
- Mac (Deskset): Enter submits; Escape dismisses; Ctrl+Enter or Option+Enter inserts a line break `\n` (one character).
  FocusDismiss=1: a click anywhere outside the box (in a skin or another app) or moving the focus away (⌘Tab) dismisses.
  FocusDismiss=0: clicks on Deskset's own windows are swallowed and the box keeps the keyboard; clicks in other apps
  cannot be blocked on macOS (the box stays open and takes the keyboard back when clicked). OnDismissAction's documented
  default `0` means "no action".
- Why: macOS cannot disable the mouse globally.
- Skin impact: minor.
- Status: emulated

### Commands, $UserInput$ and ExecuteBatch
- Windows (Rainmeter): `Command1…N` actions; `$UserInput$` is replaced by the typed text; several `$UserInput$`
  commands in one series create input boxes in sequence; `Option="Value"` pairs after a command override the measure's
  options for that box; `!CommandMeasure M "ExecuteBatch All | N | N-M"`; "When all input has been submitted, the
  commands are carried out"; `[MeasureName]` is the measure's string value.
- Mac (Deskset): as documented: all inputs of the batch are asked first (each command with `$UserInput$` shows its own
  box with its overrides), then all commands run in order. Escape/dismiss cancels the whole batch (no command runs) and
  runs OnDismissAction. The measure's string value is the last submitted input (updated as each input is submitted, so
  `[MeasureName]` in a later command is the latest input); its number is that text as a number. Judgments: one box per
  command even if `$UserInput$` appears twice in it (both are replaced); `$UserInput$` is matched case-insensitively;
  overrides are recognised only after the action and only for InputText option names (so `!SetVariable A B=C` keeps its
  argument), and a value may contain spaces inside quotes or parentheses (`DefaultValue="Type here"`, `X=(#W# - 10)`);
  `ExecuteBatch` with no number = All, `N-M` may be reversed, missing commands in a range are skipped, `All` stops at
  the first missing CommandN; a second ExecuteBatch while a box is open is ignored (a click elsewhere dismisses the open
  box first, so clicking the skin again starts a new batch as on Windows); any other `!CommandMeasure` argument is run
  as one command (older skins pass the bang itself). The typed text is inserted literally; a `"` typed inside a quoted
  argument breaks the quoting exactly as on Windows.
- Why: the manual does not cover these details.
- Skin impact: none expected (tested with the manual's example and the Enigma search / options patterns).
- Status: identical (judgment on edge cases)

---

## FrostedGlass (third-party, `Plugin=FrostedGlass`)

### Effect types
- Windows: DWM accent behind the whole skin window: None, Backdrop (opaque Backdrop color), TraslucentBackdrop (Backdrop
  color with its alpha), Blur, Acrylic, Mica, MicaAcrylic, MicaAlt (Windows 11). Default Type=Blur. Needs "Transparency
  effects" on.
- Mac (Deskset): an NSVisualEffectView (behind-window blending) in a borderless, mouse-transparent child window exactly
  behind the skin window (same frame, level and alpha; it moves with the skin and follows resizes, window replacement
  and unloading). Judgment on materials: Blur → HUD window material, Acrylic → popover material + Backdrop tint, Mica →
  under window background, MicaAcrylic → sidebar + tint, MicaAlt → window background; Backdrop/TraslucentBackdrop →
  plain color layer, no blur (`TranslucentBackdrop` spelling accepted too). `Effect=Luminance|Fullscreen` is ignored.
  macOS's "Reduce transparency" setting turns the blur into a solid color automatically.
- Why: macOS has no DWM accents; visual-effect materials are the native equivalent.
- Skin impact: the look is close but not identical (macOS vibrancy tints). The blur is not visible in `--render` PNGs.
- Status: emulated

### Corner, Border, BorderVisible, BorderColor, Backdrop
- Windows: Corner Round (8 px) / RoundWs / RoundSmall (4 px) round the window (Windows 11) and draw a 1 px border
  (BorderVisible, BorderColor or `Backdrop`); Border=Top|Left|Right|Bottom|All draws square borders with a small shadow,
  only without a Corner; Backdrop `R,G,B,A` or hex (`#` ignored), alpha default 0; deprecated named backdrops.
- Mac (Deskset): corners 8 / 8 / 4 points; the skin's own drawing is clipped to the rounded rectangle too (the skin
  view's layer), as Windows 11 rounds the whole window; the rounded 1-point border uses BorderColor (alpha forced
  opaque) or a subtle default (white 16 % in dark mode, black 16 % in light); square borders are 1-point lines on the
  requested sides (no shadow). Backdrop as documented; deprecated names (Dark…, Light…, [BWC]…) map to greys at 50 %
  alpha.
- Why: —
- Skin impact: no drop shadow on square borders.
- Status: emulated

### DarkMode, MicaOnFocus, Disabled, BlurEnabled, commands
- Windows: DarkMode (Mica dark theme), MicaOnFocus (solid color while unfocused), Disabled=1 / BlurEnabled=0 disable all
  effects; commands Toggle/Enable/DisableBlur, …Corner, …Borders, …Focus, ToggleMode/LightMode/DarkMode.
- Mac (Deskset): DarkMode=1 forces the dark appearance for every type (otherwise the system appearance applies);
  MicaOnFocus=1 shows the inactive (flat) material while the skin window is not key; BlurEnabled=0 disables everything;
  `Disabled=1` is the general measure option, so the measure never runs and no effect is added. All commands are
  supported; their state survives option re-reads (until the skin is refreshed). The measure's number is 1 while a
  background is drawn, else 0. Limitation: `!DisableMeasure` on a running FrostedGlass measure keeps the current effect
  until the skin is refreshed (use `!CommandMeasure … DisableBlur`).
- Why: plugin measures are not told when the engine disables them.
- Skin impact: see limitation.
- Status: emulated

### Skin window alpha / fades
- Windows: DWM composes the blur with the window.
- Mac (Deskset): the backdrop window copies the skin window's alpha when it syncs (on every update of the measure and on
  window notifications), so during a FadeDuration fade the blur fades in steps.
- Why: separate windows.
- Skin impact: cosmetic.
- Status: partial

---

## Chameleon (third-party, `Plugin=Chameleon`)

### Colors from the wallpaper or a file
- Windows: parent measure `Type=Desktop` (the wallpaper of the skin's monitor) or `Type=File` + `Path` (may be another
  measure's value); returns the image path. Children `Parent=` + `Color=` Background1/2, Foreground1/2, Light1–4,
  Dark1–4, Average, Luminance (0–1). `Format=Hex|Dec`, no alpha. CropX/Y/W/H, CropDesktop, ContextAwareColors,
  ContextX/Y/W/H, FallbackBG1/BG2/FG1/FG2 (hex), ForceIcon.
- Mac (Deskset): Desktop reads `NSWorkspace.desktopImageURL` of the screen the skin is on (a folder of rotating
  wallpapers → its first image); File resolves `Path` with section variables on every check (so `Path=[CoverMeasure]`
  works without DynamicVariables). The image is decoded at ≤ 96 px on a background queue (HEIC, JPEG, PNG, TIFF, GIF,
  BMP…), re-sampled when the path or its modification date changes (checked every 2 s; the folder listing, the
  modification date and the decoding run on a background queue, so a `Path` on a slow or network volume cannot stall the
  skins; the parent's string is the configured path at once and becomes the chosen image of a wallpaper folder after the
  check). CropDesktop (default 1) crops the centre to the screen's aspect ratio (what "fill screen" shows); CropX/Y/W/H
  in the image's pixels. Judgment (original method, the plugin's algorithm is not documented): colors are clustered from
  a 4-bit-per-channel histogram (≤ 8 clusters); Background1 = the largest cluster, Background2 = the next clearly
  different one; Foreground1/2 = the clusters with the most contrast against Background1, pushed toward white/black
  until 4.5:1 / 3:1 contrast; Light/Dark = those four by luminance; Average = mean color; Luminance = mean relative
  luminance. Default format Hex (`RRGGBB`), Dec = `R,G,B`. Until an image is sampled (or when it cannot be read) the
  fallback colors are used (FallbackXX options, else dark grey backgrounds and white/light grey foregrounds).
  ContextAwareColors, ContextX/Y/W/H and ForceIcon are ignored; non-image files (icons of .exe) are not supported.
- Why: no access to the plugin's method; macOS dynamic wallpapers are HEIC collections.
- Skin impact: colors are similar in spirit, not identical; dynamic/aerial wallpapers that are not image files give the
  fallback colors.
- Status: emulated

---

## IsFullScreen (third-party, `Plugin=IsFullScreen`)

### Full-screen detection and process name
- Windows: 1 when the focused window is full screen on the primary monitor, else 0; string = the process name of the
  focused window (e.g. `chrome.exe`), "" when the desktop has focus.
- Mac (Deskset): 1 when the frontmost app's front normal-level window has exactly the primary display's bounds (native
  full-screen spaces and borderless full-screen games), else 0; maximized ("zoomed") windows are not full screen. String
  = the frontmost app's executable name (e.g. `Safari`, `Google Chrome`, `Finder`). Read off the main thread at most
  twice a second (CGWindowList, no permission needed).
- Why: macOS names apps differently; the desktop belongs to Finder.
- Skin impact: `IfMatch=chrome.exe`-style tests never match; full-screen detection works.
- Status: partial

## GetActiveTitle (third-party, `Plugin=GetActiveTitle`)

### Window title
- Windows: the title of the focused window; number = its length (v1.3).
- Mac (Deskset): with the Accessibility permission (never requested by Deskset) the focused window's AXTitle; otherwise
  the window name from the window server (available only with the Screen Recording permission); otherwise the frontmost
  app's name. Number = length of the string.
- Why: window titles are private data on macOS.
- Skin impact: shows the app name unless the user grants a permission.
- Status: partial

## SysColor (third-party, `Plugin=SysColor`)

### System colors
- Windows: ColorType (Accent default, Aero, Desktop, Window, WindowFrame, WindowText, captions, borders, Highlight,
  HightlightText, buttons, Menu*, 3D*, GrayText, ToolTip*, AppWorkspace, Scrollbar, Hyperlink, WIN8, DWM_* raw values),
  DisplayType (All, RGB, Red, Green, Blue, Alpha), Hex=0/1; number 1 = found, -1 = not.
- Mac (Deskset): mapped to macOS semantic colors resolved for the current light/dark appearance: Accent/Aero/WIN8/
  DWM_COLOR/DWM_AFTERGLOW/MenuHighlight → accent color; Highlight → selected content background; HightlightText /
  HighlightText → selected menu item text; Window, Menu, MenuBar, captions, ToolTipBackground → window background;
  ButtonFace → control color; *Text → label color; GrayText / InActiveCaptionText → disabled text; WindowFrame and
  borders → separator; ButtonHighlight/3DLight → highlight; ButtonShadow/3DDarkShadow → shadow; AppWorkspace →
  under-page background; Scrollbar → control background; Hyperlink → link color; Desktop → the desktop's solid fill
  color (window background when a picture is used). Output: `r,g,b,a` / `RRGGBBAA` (All), `r,g,b` / `RRGGBB` (RGB), one
  channel. DWM_OPAQUE_BLEND = 1 when "Reduce transparency" is on, else 0; the other DWM balance/intensity values are 0.
- Why: Windows system color slots do not exist on macOS.
- Skin impact: accent-colored skins follow the Mac accent color; the others get sensible equivalents.
- Status: emulated

---

## Not implemented in this area

### Other Windows-only media/UI plugins
- Windows: plugins such as Win7AudioPlugin, AudioLevel (audio area), ActiveNet (network adapters), iTunes COM-only
  features (EQ presets, playlists), Winamp/foobar-specific bangs.
- Mac (Deskset): not part of this area; unregistered plugins keep the engine's "not supported" placeholder (0 / "") and
  compatibility hint.
- Why: —
- Skin impact: see the respective areas.
- Status: not supported (here)
