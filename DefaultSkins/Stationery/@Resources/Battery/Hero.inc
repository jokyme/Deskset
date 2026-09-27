; Stationery · Battery — the ring hero: the Small, and the Medium's left column. Original work, MIT licensed.
; Included from [MeterCard], so these meters draw after (over) the card. A ring hero has no top band: the ring needs
; the card's whole top (y 16 → 102). Every meter here is redrawn by the measures' bangs, never on its own.

[MeterRing]
; Ring L: box 86 at (42, 16), centre (85, 59), radius 39, stroke 8; the charge from 12 o'clock, clockwise, round caps.
; The track takes the level's colour at TrackAlpha
Meter=Shape
X=42
Y=16
Shape=Ellipse 43,43,39 | Fill Color 0,0,0,0 | StrokeWidth 8 | Stroke Color #LevelRGB#,#TrackAlpha#
Shape2=Arc 43,4,(43 + 39 * Sin(Rad([MeasureRingAngle:]))),(43 - 39 * Cos(Rad([MeasureRingAngle:]))),39,39,0,0,[MeasureRingLarge:] | Fill Color 0,0,0,0 | StrokeWidth 8 | Stroke Color #LevelRGB# | StrokeStartCap Round | StrokeEndCap Round
DynamicVariables=1
UpdateDivider=-1
Group=Battery | Level

[MeterDevice]
; laptopcomputer 26 pt regular, natural 43 × 25, centred on (85, 55)
Meter=Image
ImageName=sf:laptopcomputer
MacSymbolSize=26
MacSymbolWeight=Regular
MacSymbolRendering=Hierarchical
ImageTint=#SecondaryTextColor#
X=63.5
Y=42.5
W=43
H=25
UpdateDivider=-1
Group=Battery

[MeterBadgeBolt]
; bolt.fill 11 pt bold, natural 12 × 16, centred on (85, 79): shown while charging
Meter=Image
ImageName=sf:bolt.fill
MacSymbolSize=11
MacSymbolWeight=Bold
ImageTint=#LevelRGB#
X=79
Y=71
W=12
H=16
Hidden=1
DynamicVariables=1
UpdateDivider=-1
Group=Level

[MeterBadgePlug]
; powerplug.fill 11 pt bold, natural 17 × 11, centred on (85, 79): shown on power while not charging
Meter=Image
ImageName=sf:powerplug.fill
MacSymbolSize=11
MacSymbolWeight=Bold
ImageTint=#LevelRGB#
X=76.5
Y=73.5
W=17
H=11
Hidden=1
DynamicVariables=1
UpdateDivider=-1
Group=Level

[MeterPercent]
; "73%", 22 pt, centred on baseline 130
Meter=String
MeterStyle=sMetricM
MeasureName=MeasurePercent
NumOfDecimals=0
Postfix=%
StringAlign=Center
X=85
Y=(130 - #Ascent22#)
UpdateDivider=-1
Group=Battery

[MeterStatus]
; the state in words on the last baseline; %1 is the time left
Meter=String
MeterStyle=sCaption
MeasureName=MeasureDuration
Text=[#BatteryStatus[&MeasureStatusKey:]]
StringAlign=Center
X=85
Y=(#LastBaseline# - #Ascent11#)
W=138
ClipString=1
DynamicVariables=1
UpdateDivider=-1
Group=Battery
