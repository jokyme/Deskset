; Stationery — the media widgets' words in English. Original work, MIT licensed.
; Strings-Chinese.inc has the same keys. A value with a space at either end is quoted, or the INI reader would trim
; it. Menu titles are Title Case and at most 30 characters. A value may name a measure ([MeasurePlayerName]): it is
; read when the text is shown, so it follows the player.

[Variables]
; ---------------------------------------------------------------- the players (the suite's Player item)
PlayerName1=Music
PlayerName2=Spotify
MenuPlayerMusic=Player: Music
MenuPlayerSpotify=Player: Spotify
; opening the preferred player, by its index
MediaOpen1=Open Music
MediaOpen2=Open Spotify

; ---------------------------------------------------------------- Now Playing
NowPlayingWidget=Now Playing
; the media family's one "not playing" state (Now Playing, Spectrum, Turntable, Studio VU): this title, and the idle
; line, which also says which players can be read. NowPlayingIdleLines is the same line broken in two, for Now
; Playing's two-line box; keep the two in step.
NowPlayingNotPlaying=Not Playing
NowPlayingIdleLine=Play something in Music or Spotify
NowPlayingIdleLines=Play something in Music#CRLF#or Spotify
NowPlayingLive=Live
NowPlayingVolume=[MeasurePlayerName] volume
NowPlayingOpen=Open [MeasurePlayerName]
NowPlayingPlay=Play
NowPlayingPause=Pause
NowPlayingPrevious=Previous Track
NowPlayingNext=Next Track
NowPlayingAllowAccess=Allow Access
NowPlayingAllowBody=Deskset needs permission to read what [MeasurePlayerName] is playing.
NowPlayingMenuBackgroundGlass=Background: Glass
NowPlayingMenuBackgroundArtwork=Background: Artwork
; the card's sentence, by what the card shows: 0 not playing, 1 playing, 2 paused, 3 access refused, 4 loading,
; 5 a live stream. [MeasureTipArtist] is "Erik Satie, Gymnopédies. " (or nothing)
NowPlayingTip0=Deskset shows what Music or Spotify is playing. Other apps, such as web browsers, can’t be shown. If [MeasurePlayerName] is playing, allow Deskset in System Settings › Privacy & Security › Automation.
NowPlayingTip1=[MeasureTipArtist][MeasurePosition] of [MeasureDuration]. [MeasurePlayerName] volume [MeasureVolume:0]%.
NowPlayingTip2=[MeasureTipArtist]Paused at [MeasurePosition] of [MeasureDuration]. [MeasurePlayerName] volume [MeasureVolume:0]%.
NowPlayingTip3=Deskset needs permission to read what [MeasurePlayerName] is playing. Allow it in System Settings › Privacy & Security › Automation.
NowPlayingTip4=Deskset shows what Music or Spotify is playing.
NowPlayingTip5=[MeasureTipArtistOnly]Live. [MeasurePlayerName] volume [MeasureVolume:0]%.
; the bar's tooltip (Medium): "1:21 of 3:13. Click to jump there."
NowPlayingSeekTip=[MeasurePosition] of [MeasureDuration]. Click to jump there.
; how the artist and the album are joined and ended in the sentence
NowPlayingComma=", "
NowPlayingEnd=". "

; ---------------------------------------------------------------- Spectrum
SpectrumWidget=Spectrum
SpectrumPaused=Paused
SpectrumPlay=Play
SpectrumAllowAudioTitle=Allow System Audio Recording
SpectrumAllowAudioBody=Spectrum needs it to draw the sound your Mac plays.#CRLF#Nothing is recorded or saved.
SpectrumAllowScreenTitle=Allow Screen Recording
SpectrumAllowScreenBody=Spectrum hears system audio through Screen Recording.#CRLF#Allow Deskset, then quit and reopen it.
; the tooltip: live, at rest, paused at rest, and the two permissions
SpectrumTipLive=Showing the sound your Mac plays, from 40 Hz on the left to 16 kHz on the right.
SpectrumTipRest=Nothing is playing.
SpectrumTipPaused=Paused.
SpectrumTipAudio=Deskset can’t hear your Mac’s sound. Allow System Audio Recording for Deskset in Privacy & Security.
SpectrumTipScreen=Allow Screen Recording for Deskset in Privacy & Security, then quit and reopen Deskset.
SpectrumMenuBarsMedia=Bars: Pink
SpectrumMenuBarsCover=Bars: Album Art
SpectrumMenuBarsAccent=Bars: Accent Color
SpectrumMenuBarsMono=Bars: Mono
SpectrumMenuStripBarsInk=Bars: Ink
SpectrumMenuStripBarsCover=Bars: Album Art
SpectrumMenuMotionFull=Motion: Full
SpectrumMenuMotionCalm=Motion: Calm
SpectrumMenuShowTrack1=Show Track: On
SpectrumMenuShowTrack0=Show Track: Off
SpectrumMenuHideWhenIdle1=Hide When Idle: On
SpectrumMenuHideWhenIdle0=Hide When Idle: Off
