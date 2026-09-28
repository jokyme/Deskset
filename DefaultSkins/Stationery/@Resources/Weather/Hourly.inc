; Stationery · Weather — the detail column of the Medium and Large (x 176 → 344): four columns two hours apart
; (now, +2, +4, +6 h, in the place's own time), centred on x 197, 239, 281 and 323, over a curve of hours 0–6.
; Original work, MIT licensed. Included from [MeterCard]; its measures still update before every meter.

; ---------------------------------------------------------------- measures
[MeasureWxH2Temp]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Temperature
Hour=2
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxH4Temp]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Temperature
Hour=4
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxH6Temp]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Temperature
Hour=6
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxH0Rain]
; a rain chip only from 30 %: 0–29 and missing give "", anything else "40%"
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=PrecipitationChance
Hour=0
Decimals=0
RegExpSubstitute=1
Substitute="^([0-9]|[12][0-9])?$":"","^(\d+)$":"\1%"
Group=Weather

[MeasureWxH2Rain]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=PrecipitationChance
Hour=2
Decimals=0
RegExpSubstitute=1
Substitute="^([0-9]|[12][0-9])?$":"","^(\d+)$":"\1%"
Group=Weather

[MeasureWxH4Rain]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=PrecipitationChance
Hour=4
Decimals=0
RegExpSubstitute=1
Substitute="^([0-9]|[12][0-9])?$":"","^(\d+)$":"\1%"
Group=Weather

[MeasureWxH6Rain]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=PrecipitationChance
Hour=6
Decimals=0
RegExpSubstitute=1
Substitute="^([0-9]|[12][0-9])?$":"","^(\d+)$":"\1%"
Group=Weather

[MeasureWxHourLabel]
; read as [&MeasureWxHourLabel:Hour(n, Time)]: "12", "14" / "12 PM", "2 PM"
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Time
Format=#WxHourFormat#
Group=Weather

[MeasureWxHourFull]
; tooltips: "16:00" / "4:00 PM"
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Time
Format=#WxTimeFormat#
Group=Weather

[MeasureWxCurve]
; a Shape path of hours 0–6 (seven points, so each column's temperature sits over its point), 126 × 20, the lowest
; at the bottom
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=TemperatureCurve
Hours=7
CurveWidth=126
CurveHeight=20
Smooth=1
; before the first forecast, a flat line (the meter is hidden then; this only keeps the path valid)
RegExpSubstitute=1
Substitute="^0?$":"0,20 | LineTo 126,20"
Group=Weather

[MeasureWxHighColor]
; the temperature scale's colour ("R,G,B"): [&MeasureWxHighColor:Hour(n, TemperatureColor)] of hour n,
; [&MeasureWxHighColor:Day(n, TemperatureColor)] of day n's high. Black until there is a forecast, so gradients built
; from it stay valid
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=TemperatureColor
ColorOf=High
UnavailableText=0,0,0
Group=Weather

; ---------------------------------------------------------------- the columns' hit boxes (under the column meters)
[MeterHourHit0]
Meter=Image
MeterStyle=sHit
X=176
Y=40
W=42
H=80
LeftMouseUpAction=#OpenAction#
ToolTipText=[&MeasureWxHourFull:Hour(0, Time)] · [MeasureWxNow]° · #WeatherRainPre#[&MeasureWx:Hour(0, PrecipitationChance, 0)]%#WeatherRainPost#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterHourHit1]
Meter=Image
MeterStyle=sHit
X=218
Y=40
W=42
H=80
LeftMouseUpAction=#OpenAction#
ToolTipText=[&MeasureWxHourFull:Hour(2, Time)] · [MeasureWxH2Temp]° · #WeatherRainPre#[&MeasureWx:Hour(2, PrecipitationChance, 0)]%#WeatherRainPost#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterHourHit2]
Meter=Image
MeterStyle=sHit
X=260
Y=40
W=42
H=80
LeftMouseUpAction=#OpenAction#
ToolTipText=[&MeasureWxHourFull:Hour(4, Time)] · [MeasureWxH4Temp]° · #WeatherRainPre#[&MeasureWx:Hour(4, PrecipitationChance, 0)]%#WeatherRainPost#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterHourHit3]
Meter=Image
MeterStyle=sHit
X=302
Y=40
W=42
H=80
LeftMouseUpAction=#OpenAction#
ToolTipText=[&MeasureWxHourFull:Hour(6, Time)] · [MeasureWxH6Temp]° · #WeatherRainPre#[&MeasureWx:Hour(6, PrecipitationChance, 0)]%#WeatherRainPost#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

; ---------------------------------------------------------------- hour labels (baseline 55)
[MeterHourLabel0]
Meter=String
MeterStyle=sCaptionNum
StringAlign=Center
Text=#WeatherNow#
X=197
Y=(55 - #Ascent11#)
FontColor=#SecondaryTextColor#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterHourLabel1]
Meter=String
MeterStyle=sCaptionNum
StringAlign=Center
Text=[&MeasureWxHourLabel:Hour(2, Time)]
X=239
Y=(55 - #Ascent11#)
FontColor=#SecondaryTextColor#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterHourLabel2]
Meter=String
MeterStyle=sCaptionNum
StringAlign=Center
Text=[&MeasureWxHourLabel:Hour(4, Time)]
X=281
Y=(55 - #Ascent11#)
FontColor=#SecondaryTextColor#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterHourLabel3]
Meter=String
MeterStyle=sCaptionNum
StringAlign=Center
Text=[&MeasureWxHourLabel:Hour(6, Time)]
X=323
Y=(55 - #Ascent11#)
FontColor=#SecondaryTextColor#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

; ---------------------------------------------------------------- symbols: 17 pt in a 26 × 26 box centred on (cx, 73)
[MeterHourSymbol0]
Meter=Image
ImageName=sf:[&MeasureWx:Hour(0, Symbol)]
MacSymbolSize=17
MacSymbolWeight=Regular
MacSymbolRendering=Palette
ImageAlpha=([MeasureWxStale:] ? 153 : 255)
MacSymbolColors=[&MeasureWx:Hour(0, SymbolPalette)]
PreserveAspectRatio=1
X=184
Y=60
W=26
H=26
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterHourSymbol1]
Meter=Image
ImageName=sf:[&MeasureWx:Hour(2, Symbol)]
MacSymbolSize=17
MacSymbolWeight=Regular
MacSymbolRendering=Palette
ImageAlpha=([MeasureWxStale:] ? 153 : 255)
MacSymbolColors=[&MeasureWx:Hour(2, SymbolPalette)]
PreserveAspectRatio=1
X=226
Y=60
W=26
H=26
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterHourSymbol2]
Meter=Image
ImageName=sf:[&MeasureWx:Hour(4, Symbol)]
MacSymbolSize=17
MacSymbolWeight=Regular
MacSymbolRendering=Palette
ImageAlpha=([MeasureWxStale:] ? 153 : 255)
MacSymbolColors=[&MeasureWx:Hour(4, SymbolPalette)]
PreserveAspectRatio=1
X=268
Y=60
W=26
H=26
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterHourSymbol3]
Meter=Image
ImageName=sf:[&MeasureWx:Hour(6, Symbol)]
MacSymbolSize=17
MacSymbolWeight=Regular
MacSymbolRendering=Palette
ImageAlpha=([MeasureWxStale:] ? 153 : 255)
MacSymbolColors=[&MeasureWx:Hour(6, SymbolPalette)]
PreserveAspectRatio=1
X=310
Y=60
W=26
H=26
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

; ---------------------------------------------------------------- temperatures (baseline 100), "--°" while waiting
[MeterHourTemp0]
Meter=String
MeterStyle=sValue | sMissing
MeasureName=MeasureWxNow
Text=%1°
StringAlign=Center
X=197
Y=(100 - #Ascent13#)
FontColor=#InkRGB#,([MeasureWxStale:] ? #Alpha2# : #Alpha1#)
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather

[MeterHourTemp1]
Meter=String
MeterStyle=sValue | sMissing
MeasureName=MeasureWxH2Temp
Text=%1°
StringAlign=Center
X=239
Y=(100 - #Ascent13#)
FontColor=#InkRGB#,([MeasureWxStale:] ? #Alpha2# : #Alpha1#)
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather

[MeterHourTemp2]
Meter=String
MeterStyle=sValue | sMissing
MeasureName=MeasureWxH4Temp
Text=%1°
StringAlign=Center
X=281
Y=(100 - #Ascent13#)
FontColor=#InkRGB#,([MeasureWxStale:] ? #Alpha2# : #Alpha1#)
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather

[MeterHourTemp3]
Meter=String
MeterStyle=sValue | sMissing
MeasureName=MeasureWxH6Temp
Text=%1°
StringAlign=Center
X=323
Y=(100 - #Ascent13#)
FontColor=#InkRGB#,([MeasureWxStale:] ? #Alpha2# : #Alpha1#)
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather

; ---------------------------------------------------------------- rain chips (baseline 113), only from 30 %
[MeterHourRain0]
Meter=String
MeterStyle=sMicroNum
MeasureName=MeasureWxH0Rain
StringAlign=Center
X=197
Y=(113 - #Ascent9#)
FontColor=#PrecipitationTextColor#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterHourRain1]
Meter=String
MeterStyle=sMicroNum
MeasureName=MeasureWxH2Rain
StringAlign=Center
X=239
Y=(113 - #Ascent9#)
FontColor=#PrecipitationTextColor#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterHourRain2]
Meter=String
MeterStyle=sMicroNum
MeasureName=MeasureWxH4Rain
StringAlign=Center
X=281
Y=(113 - #Ascent9#)
FontColor=#PrecipitationTextColor#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterHourRain3]
Meter=String
MeterStyle=sMicroNum
MeasureName=MeasureWxH6Rain
StringAlign=Center
X=323
Y=(113 - #Ascent9#)
FontColor=#PrecipitationTextColor#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

; ---------------------------------------------------------------- the curve
[MeterCurve]
; x 197 → 323, y 120 → 140 (Offset 1,1 keeps the round caps inside the meter); an area in the temperature scale's
; colour of hour 3 fades from WxAreaAlpha to nothing down to y 145, under a 1.5 pt line in the secondary ink.
; Gradient angles follow the manual: 270 runs top to bottom
Meter=Shape
X=196
Y=119
Shape=Path WxArea | Offset 1,1 | Fill LinearGradient WxAreaFill | StrokeWidth 0
WxArea=[MeasureWxCurve] | LineTo 126,25 | LineTo 0,25 | ClosePath 1
WxAreaFill=270 | [&MeasureWxHighColor:Hour(3, TemperatureColor)],(#WxAreaAlpha# * ([MeasureWxStale:] ? 0.5 : 1)) ; 0.0 | [&MeasureWxHighColor:Hour(3, TemperatureColor)],0 ; 1.0
Shape2=Path WxLine | Offset 1,1 | StrokeWidth 1.5 | Stroke Color #InkRGB#,([MeasureWxStale:] ? #Alpha3# : #Alpha2#) | StrokeStartCap Round | StrokeEndCap Round | StrokeLineJoin Round | Fill Color 0,0,0,0
WxLine=[MeasureWxCurve]
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather
