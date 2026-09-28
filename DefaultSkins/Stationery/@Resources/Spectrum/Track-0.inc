; Stationery · Spectrum — no track name (Show Track: Off). Original work, MIT licensed.
;
; The same measure names as Track-1.inc, but nothing reads a player, so nothing asks for Automation. The card opens
; the preferred player by its path, which asks for nothing either.

[Variables]
OpenAction=["[#PlayerApp[#Player]]"]

[MeasureTitle]
Measure=String
String=

[MeasureArtist]
Measure=String
String=

[MeasureState]
Measure=Calc
Formula=0

[MeasureStatus]
Measure=Calc
Formula=0

[MeasureTrackText]
Measure=String
String=

; no player is read, so none can refuse (Media/Permission.inc's measures, always 0)
[MeasureAccess]
Measure=Calc
Formula=0

[MeasureAccessOn]
Measure=Calc
Formula=0

[MeasureAccessPlayer]
Measure=String
String=
