; Stationery · Temperature — the Medium's detail column under the chart (x 176 → 344): fans with a bar showing their
; speed between the hardware's minimum and maximum, and power, each replaced by a spare temperature on a Mac that lacks
; it (Measures.inc). Original work, MIT licensed. Included from the Medium's [MeterCard] after Left.inc.
; The fans row sits on baseline 122 with its bar under it (y 128 → 133); a spare temperature in its place has no bar
; and sits on the left column's baseline, 133. The second row is on the last baseline, 151.

[MeterRight1Symbol]
Meter=Image
MeterStyle=sSymbolS
ImageName=sf:[#Sym[&MeasureRight1:0]]
ImageTint=[#Tint[&MeasureRight1:0]]
W=[#SymW[&MeasureRight1:0]]
H=[#SymH[&MeasureRight1:0]]
X=(186 - [#SymW[&MeasureRight1:0]] / 2)
Y=((([&MeasureRight1:0] = 1) ? 122 : 133) - #CapHeight11# / 2 - [#SymH[&MeasureRight1:0]] / 2)
Hidden=(([&MeasureRight1:0] = 0) || ([&MeasureNotice:] = 1))
DynamicVariables=1
UpdateDivider=-1
Group=Rows

[MeterRight1Label]
Meter=String
MeterStyle=sCaption
Text=[#Label[&MeasureRight1:0]]
X=201
Y=((([&MeasureRight1:0] = 1) ? 122 : 133) - #Ascent11#)
W=70
ClipString=1
Hidden=(([&MeasureRight1:0] = 0) || ([&MeasureNotice:] = 1))
DynamicVariables=1
UpdateDivider=-1
Group=Rows

[MeterRight1Value]
Meter=String
MeterStyle=sValueS | sUnit | sMissing
Text=[&Measure[#Key[&MeasureRight1:0]]]
StringAlign=Right
X=344
Y=((([&MeasureRight1:0] = 1) ? 122 : 133) - #Ascent11#)
Hidden=(([&MeasureRight1:0] = 0) || ([&MeasureNotice:] = 1))
DynamicVariables=1
Group=Readings | Rows

[MeterFanBar]
; a 5 pt capsule: the track in the fan's colour, the fill from the slowest to the fastest speed (at least a dot; clear
; until the first reading)
Meter=Shape
X=176
Y=128
Shape=Rectangle 0,0,168,5,2.5 | Fill Color #FanColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,(Max(5, 168 * [&MeasureFanShare:])),5,2.5 | Fill Color #FanColor#,(#Seen1# * 255) | StrokeWidth 0
Hidden=(([&MeasureRight1:0] <> 1) || ([&MeasureNotice:] = 1))
DynamicVariables=1
Group=Readings | Rows

[MeterRight2Symbol]
Meter=Image
MeterStyle=sSymbolS
ImageName=sf:[#Sym[&MeasureRight2:0]]
ImageTint=[#Tint[&MeasureRight2:0]]
W=[#SymW[&MeasureRight2:0]]
H=[#SymH[&MeasureRight2:0]]
X=(186 - [#SymW[&MeasureRight2:0]] / 2)
Y=(151 - #CapHeight11# / 2 - [#SymH[&MeasureRight2:0]] / 2)
Hidden=(([&MeasureRight2:0] = 0) || ([&MeasureNotice:] = 1))
DynamicVariables=1
UpdateDivider=-1
Group=Rows

[MeterRight2Label]
Meter=String
MeterStyle=sCaption
Text=[#Label[&MeasureRight2:0]]
X=201
Y=(151 - #Ascent11#)
W=70
ClipString=1
Hidden=(([&MeasureRight2:0] = 0) || ([&MeasureNotice:] = 1))
DynamicVariables=1
UpdateDivider=-1
Group=Rows

[MeterRight2Value]
Meter=String
MeterStyle=sValueS | sUnit | sMissing
Text=[&Measure[#Key[&MeasureRight2:0]]]
StringAlign=Right
X=344
Y=(151 - #Ascent11#)
Hidden=(([&MeasureRight2:0] = 0) || ([&MeasureNotice:] = 1))
DynamicVariables=1
Group=Readings | Rows
