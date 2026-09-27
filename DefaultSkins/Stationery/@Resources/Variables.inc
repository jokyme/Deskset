; Stationery (文房), Deskset's default widgets — your settings. Original work, MIT licensed.
;
; Every Stationery widget includes this file, and the right-click menus write the choices below into it. When the
; widgets are updated, the values you chose here are kept. After editing it by hand, refresh the widgets (menu bar
; icon › Refresh All).
;
; Text you type into a widget (to-do items, cities, launcher items…) is kept outside the skins, in Stationery.inc in
; Deskset's settings folder.

[Variables]
; ---------------------------------------------------------------- the whole suite follows these
; Look: Auto follows macOS (Light or Dark). Light, Dark and Clear pick one; until Deskset can set the glass itself,
; a look picked by hand uses solid cards.
Look=Auto
; Cards: 0 glass, 1 solid (near-opaque, for busy wallpapers and Reduce Transparency; the Clear look stays glass)
UseSolidCards=0
; Ink of the pieces without a card: Auto (chosen from the wallpaper under them), White or Dark
Ink=Auto
; Words in the widgets: English or Chinese (Simplified)
Language=English
; Day and month names: en_US for English, zh_CN for Chinese, or Local for this Mac's region
Locale=en_US
; Clock: Auto (as this Mac), 24 or 12 (hours)
ClockHours=Auto
; First day of the week: Auto (as this Mac), or 0 Sunday, 1 Monday … 6 Saturday
WeekStart=Auto
; Temperatures: Auto (as this Mac), C or F
TempUnit=Auto
; Place for the weather, sunrise and sunset: timezone (the city of this Mac's time zone), a city ("Oslo", "北京"),
; latitude,longitude ("59.91,10.75"), or auto (this Mac's location, which asks for Location Services)
Location=timezone
; Separator between thousands in numbers of four digits and more
DigitGroup=,

; ---------------------------------------------------------------- Clock
; The small clock's bottom line: Sun (the next sunrise or sunset), Week (week and day of the year) or None
ClockBottomLine=Sun

; ---------------------------------------------------------------- Now Playing (and the other media widgets)
; The player the media widgets prefer and open: Music or Spotify (whichever of the two is playing is shown)
Player=Music
; Now Playing's card: Glass, or Artwork (the colour of the album cover)
NowPlayingBackground=Glass

; ---------------------------------------------------------------- Spectrum
; The bars' colour: Media (pink), Cover (a colour of the album cover), Accent (the Mac's accent colour) or Mono
SpectrumBars=Media
; The Strip's bars: Ink (white or dark, as the wallpaper under it asks) or Cover
SpectrumStripBars=Ink
; How the bars move: Full, or Calm (they fall twice as slowly)
SpectrumMotion=Full
; 1 shows the playing track's name (Music or Spotify ask once for permission); 0 never reads a player
ShowSpectrumTrack=1
; 1: the Strip fades out after 3 s of quiet and comes back with the sound; 0: it stays, as a row of dots
HideSpectrumWhenIdle=1

; ---------------------------------------------------------------- Photo Frame
; How often a new photo comes, in seconds: 600 (every 10 minutes), 3600 (on the hour) or 86400 (at midnight)
PhotoInterval=600
; 1 shows the photo's file name at the bottom (a camera's name, such as IMG_4821, shows its folder's name)
ShowPhotoFileName=0
