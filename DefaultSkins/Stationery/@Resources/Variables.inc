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
