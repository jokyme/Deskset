; Stationery · Weather — defaults for the weather's own settings. Original work, MIT licensed.
; Each Weather size includes this file before @Resources/Variables.inc, so a value the menus or the city field wrote
; there wins; these only fill in what Variables.inc does not have yet.

[Variables]
; the place to go back to after "Stop Using My Location"; every city typed into the city field is kept here too
LastCity=timezone
; 0 until the user keeps or changes the place: a place taken from this Mac's time zone then asks "Not your city?"
LocationConfirmed=0
