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
; The player the music widgets prefer: Music or Spotify (they show whichever of the two is playing)
Player=Music

; ---------------------------------------------------------------- Clock
; The small clock's bottom line: Sun (the next sunrise or sunset), Week (week and day of the year) or None
ClockBottomLine=Sun

; ---------------------------------------------------------------- Sentence Clock
; Background: Glass (the words on a glass card) or Frameless (straight on the wallpaper, in the Ink above)
SentenceCard=Glass
; Unlit words: 0 subtle, 1 visible (for more contrast)
SentenceGrid=0
; A soft glow on the lit words in the Dark look: 1 on, 0 off
SentenceGlow=1
; The time in the footer: 1 shown, 0 hidden (the date stays)
SentenceShowTime=1

; ---------------------------------------------------------------- Almanac
; Size: Small, Regular or Large (0.8, 1 and 1.25 times 411 × 148)
AlmanacSize=Regular
; Sunrise and sunset on the second data line: 1 shown, 0 hidden (the year and the weeks left instead)
AlmanacShowSun=1

; ---------------------------------------------------------------- Daybreak
; The base of the digits takes the sky's colour in twilight, the golden hours and at night: 1 on, 0 off (plain ink)
DaybreakSkyTint=1

; ---------------------------------------------------------------- Chronograph
; The dial at 3 o'clock: 0 automatic (the battery, or the CPU on a Mac without one), 1 battery, 2 CPU
ChronoRightDial=0
; The running seconds at 6 o'clock: 1 on, 0 off (the register stays as a dial)
ChronoSeconds=1

; ---------------------------------------------------------------- Turntable
; The record's colour: 1 pressed in the cover's own colour, 0 classic black
TurntableVinyl=1
; After a pause the arm goes back to its rest: 1Min, 5Min or Never
TurntableRest=1Min
; A click on the grooves drops the needle there: 1 on, 0 off (every click on the record plays or pauses)
TurntableSeek=1

; ---------------------------------------------------------------- Studio VU
; The meters' faces: Auto (ivory in the Light look, amber in the Dark), Ivory or Amber
StudioFace=Auto
; Needle sensitivity: Normal (0 VU at −12 dBFS), High (−18, for quiet recordings) or Low (−8, for loud masters)
StudioSens=Normal
; Needle speed: VU (about 300 ms) or Slow (about 750 ms, calmer)
StudioSpeed=VU
; The PEAK lamps light at −1, −3 or −6 dBFS
StudioPeak=1
