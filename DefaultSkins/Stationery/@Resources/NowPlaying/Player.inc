; Stationery · Now Playing — the measures both sizes share. Original work, MIT licensed.
;
; What Music or Spotify is playing: Deskset reads those two players only (web browsers and other apps can't be read),
; and shows whichever of them plays, the preferred one (Player, Variables.inc) first. It polls a player only while it
; runs, and the first poll of a running player makes macOS ask once for permission (Automation); a refusal shows as
; the Notice (Media/Permission.inc tells it). Commands never open a closed player; only OpenPlayer does. The cover is
; fetched only while this widget shows it.
;
; Every NowPlaying measure updates once a second. The meters decide what they show from MeasureMode (and MeasureView,
; which tells a live stream apart), in the groups State (on a change of mode), Player (on a new track) and Progress.

[Variables]
; MeasureAccess and MeasureAccessPlayer: whether macOS lets Deskset read the player
@IncludeMediaPermission=#@#Media/Permission.inc

; ---------------------------------------------------------------- run-time state (never written to a file)
; the player shown: 1 Music, 2 Spotify (MeasurePlayerNow sets it every second); the preferred one until then
PlayerNow=[#PlayerIndex[#Player]]
; the pointer on the card (Small: Next shows) and on the bar (Medium)
CardHover=0
BarHover=0
; 1 for 1.5 s after a scroll: the bar shows the player's volume, VolumeTarget (0-100)
VolumeRow=0
VolumeTarget=0

; ---------------------------------------------------------------- by mode (MeasureMode)
; 0 not playing · 1 playing · 2 paused · 3 access refused · 4 loading (or macOS is asking for access)
PlayGlyph0=play.fill
PlayGlyph1=pause.fill
PlayGlyph2=play.fill
PlayGlyph3=play.fill
PlayGlyph4=play.fill
; nothing plays: play opens the player (commands never launch a closed player)
PlayCommand0=OpenPlayer
PlayCommand1=PlayPause
PlayCommand2=PlayPause
PlayCommand3=OpenPlayer
PlayCommand4=OpenPlayer
PlayTip0=#NowPlayingOpen#
PlayTip1=#NowPlayingPause#
PlayTip2=#NowPlayingPlay#
PlayTip3=#NowPlayingOpen#
PlayTip4=#NowPlayingOpen#
TitleText0=#NowPlayingNotPlaying#
TitleText1=[MeasurePlayer]
TitleText2=[MeasurePlayer]
TitleText3=
TitleText4=
ArtistText0=#NowPlayingIdleLines#
ArtistText1=[MeasureArtist]
ArtistText2=[MeasureArtist]
ArtistText3=
ArtistText4=

; ---------------------------------------------------------------- by view (MeasureView): the modes, and 5 a live stream
ElapsedText0=
ElapsedText1=[MeasurePosition]
ElapsedText2=[MeasurePosition]
ElapsedText3=
ElapsedText4=
ElapsedText5=#NowPlayingLive#
TipTitle0=#NowPlayingNotPlaying#
TipTitle1=[MeasurePlayer]
TipTitle2=[MeasurePlayer]
TipTitle3=#NowPlayingAllowAccess#
TipTitle4=#NowPlayingWidget#
TipTitle5=[MeasurePlayer]

; ---------------------------------------------------------------- the Background item (NowPlayingBackground, Variables.inc)
BackgroundNextGlass=Artwork
BackgroundNextArtwork=Glass

; ---------------------------------------------------------------- screenshots
; 0-4 shows that mode whatever the player does. -1 (always, in a released file): the player's own
TestMode=-1

; ---------------------------------------------------------------- the player
[MeasurePlayer]
; the track's title; every command goes here
Measure=NowPlaying
PlayerName=#Player#
PlayerType=Title
DisableLeadingZero=1
TrackChangeAction=[!UpdateMeterGroup Player][!Redraw]
Group=Player

[MeasureArtist]
Measure=NowPlaying
PlayerName=[MeasurePlayer]
PlayerType=Artist
Group=Player

[MeasureAlbum]
Measure=NowPlaying
PlayerName=[MeasurePlayer]
PlayerType=Album
Group=Player

[MeasureCover]
; Deskset's copy of the cover ("" without a track). The card's background comes right after it, so its measures
; follow the cover, and its [Variables] come after the look's and win (Background-Glass.inc or Background-Artwork.inc)
Measure=NowPlaying
PlayerName=[MeasurePlayer]
PlayerType=Cover
Group=Player
@IncludeBackground=#@#NowPlaying/Background-#NowPlayingBackground#.inc

[MeasurePosition]
; "1:21" (H:MM:SS from one hour); its number is seconds
Measure=NowPlaying
PlayerName=[MeasurePlayer]
PlayerType=Position
Group=Player

[MeasureDuration]
; "3:13"; 0 for a live stream
Measure=NowPlaying
PlayerName=[MeasurePlayer]
PlayerType=Duration
Group=Player

[MeasureProgress]
; 0-100
Measure=NowPlaying
PlayerName=[MeasurePlayer]
PlayerType=Progress
Group=Player

[MeasureState]
; 0 stopped, 1 playing, 2 paused
Measure=NowPlaying
PlayerName=[MeasurePlayer]
PlayerType=State
Group=Player

[MeasureStatus]
; 1 while a player runs
Measure=NowPlaying
PlayerName=[MeasurePlayer]
PlayerType=Status
Group=Player

[MeasureVolume]
; the player's own volume (0-100), not the Mac's
Measure=NowPlaying
PlayerName=[MeasurePlayer]
PlayerType=Volume
Group=Player

[MeasureRemaining]
; "1:52": the time left ("0:01:52" loses its "0:0"; "1:02:05" stays)
Measure=Uptime
SecondsValue=(Max([MeasureDuration:] - [MeasurePosition:], 0))
Format=%3!i!:%2!02i!:%1!02i!
AddDaysToHours=1
RegExpSubstitute=1
Substitute="^0:0?":""
DynamicVariables=1
Group=Player

; ---------------------------------------------------------------- which player is shown, its name and its icon
; Deskset shows the preferred player while it plays, else the other one that plays (or waits paused). Until Deskset
; names the player it shows, the one that runs alone is taken for it, else the preferred one (wrong only while both run
; and the other one plays). With nothing to show it is the preferred player, which the play button opens; with access
; refused (or being asked for), the player it is about (MeasureAccess). Checking which apps run asks for nothing.
[MeasureMusicRunning]
Measure=Process
ProcessName=Music
UpdateDivider=2

[MeasureSpotifyRunning]
Measure=Process
ProcessName=Spotify
UpdateDivider=2

[MeasurePlayerNow]
; 1 Music, 2 Spotify; every update (OnChangeAction would skip the first one)
Measure=Calc
Formula=(MeasureAccess > 0) ? [MeasureAccess] : ((MeasureState = 0) ? [#PlayerIndex[#Player]] : (((MeasureSpotifyRunning = 1) && (MeasureMusicRunning = -1)) ? 2 : (((MeasureMusicRunning = 1) && (MeasureSpotifyRunning = -1)) ? 1 : [#PlayerIndex[#Player]])))
DynamicVariables=1
OnUpdateAction=[!SetVariable PlayerNow [MeasurePlayerNow:0]]

[MeasurePlayerName]
; "Music": the words that name the player read it ([MeasurePlayerName] in the Strings)
Measure=String
String=[#PlayerName[#PlayerNow]]
DynamicVariables=1

[MeasureIconList1]
; the players' app icons, read once (FileView lists the app, its Icon child writes the icon, 48 px, drawn at 18 pt)
Measure=Plugin
Plugin=FileView
Path=/System/Applications/
WildcardSearch=Music.app
ShowDotDot=0
ShowFile=0
Count=1
UpdateDivider=-1

[MeasureIcon1]
Measure=Plugin
Plugin=FileView
Path=[MeasureIconList1]
Type=Icon
Index=1
IconSize=Large
IconPath=#SETTINGSPATH#Cache/Stationery/Music.png
UpdateDivider=-1

[MeasureIconList2]
; Spotify may not be installed: then the icon stays empty and the pink note under it shows
Measure=Plugin
Plugin=FileView
Path=/Applications/
WildcardSearch=Spotify.app
ShowDotDot=0
ShowFile=0
Count=1
UpdateDivider=-1

[MeasureIcon2]
Measure=Plugin
Plugin=FileView
Path=[MeasureIconList2]
Type=Icon
Index=1
IconSize=Large
IconPath=#SETTINGSPATH#Cache/Stationery/Spotify.png
UpdateDivider=-1

; ---------------------------------------------------------------- mode
[MeasureTick]
; updates since load: the first one is the loading moment
Measure=Calc
Formula=Min(MeasureTick + 1, 3)

[MeasureMode]
; 0 not playing (no player runs, or it has no track) · 1 playing · 2 paused · 3 access refused (the Notice) · 4 loading,
; also while macOS asks for access (its prompt waits for an answer)
Measure=Calc
Formula=(#TestMode# >= 0) ? #TestMode# : ((MeasureTick < 2) ? 4 : ((MeasureAccess = 1) ? 3 : ((MeasureAccess = 2) ? 4 : ((MeasureState = 1) ? 1 : ((MeasureState = 2) ? 2 : 0)))))
OnChangeAction=[!UpdateMeterGroup State][!UpdateMeterGroup Progress][!Redraw]

[MeasureView]
; the mode, or 5 while a live stream (no duration) plays or waits paused
Measure=Calc
Formula=(((MeasureMode = 1) || (MeasureMode = 2)) && (MeasureDuration = 0)) ? 5 : MeasureMode

; ---------------------------------------------------------------- the card's sentence
[MeasureTipArtist]
; "Erik Satie, Gymnopédies. ": the artist and the album, either left out when empty
Measure=String
String=[MeasureArtist]␟[MeasureAlbum]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^␟$":"","^␟(.+)$":"\1#NowPlayingEnd#","^(.+)␟$":"\1#NowPlayingEnd#","^(.+?)␟(.+)$":"\1#NowPlayingComma#\2#NowPlayingEnd#"
Group=Player

[MeasureTipArtistOnly]
; "Erik Satie. " (a live stream has no album)
Measure=String
String=[MeasureArtist]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^(.+)$":"\1#NowPlayingEnd#"
Group=Player

; ---------------------------------------------------------------- the volume row
[MeasureVolumeTimer]
; a scroll shows the volume row; 1.5 s after the last one it goes
Measure=Plugin
Plugin=ActionTimer
ActionList1=Wait 1500 | VolumeRowOff
VolumeRowOff=[!SetVariable VolumeRow 0][!UpdateMeterGroup Progress][!Redraw]
