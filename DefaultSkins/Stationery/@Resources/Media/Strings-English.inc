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

; ---------------------------------------------------------------- Now Playing
NowPlayingWidget=Now Playing
NowPlayingNotPlaying=Not Playing
; the first-run line, on two lines (it also says which players can be read)
NowPlayingIdleLine=Play something in Music#CRLF#or Spotify
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
