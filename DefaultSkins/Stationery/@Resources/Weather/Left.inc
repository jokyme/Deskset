; Stationery · Weather — the left column (x 16 → 154), which is the whole Small: the temperature, the condition's symbol,
; the condition and today's high and low. Original work, MIT licensed. Included from [MeterCard].
;
; What shows follows MeasureWxMode (0 data, 1 waiting, 2 a notice) through Hidden formulas; values that are not up to
; date (MeasureWxStale) dim to the secondary ink.

[MeterTemp]
; 40 pt on baseline 83: "14°", or "--°" in the tertiary ink while waiting
Meter=String
MeterStyle=sMetricXL | sMissing
MeasureName=MeasureWxNow
Text=%1°
X=16
Y=(#HeroBaselineXL# - #Ascent40#)
FontColor=#InkRGB#,([MeasureWxStale:] ? #Alpha2# : #Alpha1#)
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather

[MeterHeroSymbol]
; 20 pt, left-aligned at x 16 and centred on y 102. The symbol changes with the weather and symbols differ in size, so
; it is fitted to the largest one's box (30 × 31); once Deskset can draw a symbol at its natural size in a box, it will.
; Its layers in their colours (the cloud in the secondary ink, a yellow sun, rain in the rain colour, §8); faded while
; the forecast is not up to date
Meter=Image
ImageName=sf:[MeasureWxSymbol]
MacSymbolSize=20
MacSymbolWeight=Regular
MacSymbolRendering=Palette
ImageAlpha=([MeasureWxStale:] ? 153 : 255)
MacSymbolColors=[MeasureWxPalette]
PreserveAspectRatio=1
X=16
Y=86.5
W=30
H=31
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterCondition]
; "Partly cloudy" on baseline 130, from the language's table (MET Norway's longest names clip; the tooltip has them)
Meter=String
MeterStyle=sCaption
Text=[#Cond[&MeasureWxCond:]]
X=16
Y=(130 - #Ascent11#)
W=138
ClipString=1
FontColor=#InkRGB#,([MeasureWxStale:] ? #Alpha2# : #Alpha1#)
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterWaitLine]
; while waiting, the condition's line says why ("Loading weather…", "Offline · retrying")
Meter=String
MeterStyle=sCaption
Text=[#Status[&MeasureWxStatus:]]
X=16
Y=(130 - #Ascent11#)
W=138
ClipString=1
FontColor=#TertiaryTextColor#
Hidden=([MeasureWxMode:] <> 1)
DynamicVariables=1
Group=Weather

[MeterHighLow]
; "H:16° L:8°" on baseline 145; "H:--° L:--°" in the tertiary ink while waiting. Not up to date, the stale line takes
; its place; on first run the Small shows its city check here
Meter=String
MeterStyle=sCaption
MeasureName=MeasureWxHigh
MeasureName2=MeasureWxLow
Text=#WeatherHigh#%1° #WeatherLow#%2°
X=16
Y=(145 - #Ascent11#)
W=138
ClipString=1
FontColor=#InkRGB#,([MeasureWxMode:] = 1 ? #Alpha3# : #Alpha2#)
Hidden=(([MeasureWxMode:] = 2) || ([MeasureWxStale:] = 1) || (([MeasureWxPrompt:] = 1) * (#CardW# < 200)))
DynamicVariables=1
Group=Weather

[MeterStaleSymbol]
; 9 pt, centred on (22, 141.1): wifi.slash when offline, clock when the service was busy or the data expired
Meter=Image
MacSymbolSize=9
MacSymbolWeight=Semibold
ImageName=sf:[#WxStaleSymbol[#WxStaleKey]]
ImageTint=#TertiaryTextColor#
X=16
Y=135.1
W=12
H=12
Hidden=([MeasureWxStale:] = 0)
DynamicVariables=1
Group=Weather

[MeterStaleLine]
; "Offline · 09:30" / "Updated 09:30"
Meter=String
MeterStyle=sCaption
Text=[#WeatherStale[#WxStaleKey]]
X=32
Y=(145 - #Ascent11#)
W=122
ClipString=1
FontColor=#TertiaryTextColor#
Hidden=([MeasureWxStale:] = 0)
DynamicVariables=1
Group=Weather
