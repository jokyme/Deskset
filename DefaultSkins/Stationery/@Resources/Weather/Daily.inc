; Stationery · Weather — the Large's lower half: a details row, a separator and six days. Original work, MIT licensed.
; Included from [MeterCard] after Hourly.inc. Rows sit on baselines 205 + 24·n; each row's centre line is 4.58 above
; its baseline (the cap centre of 13 pt text), and its symbol, rain chip and range bar are centred on it.

; ---------------------------------------------------------------- measures

[MeasureWxD0Low]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Low
Day=0
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxD0High]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=High
Day=0
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxD0Rain]
; the day's highest chance of rain, as a chip from 30 %
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=PrecipitationChance
Day=0
Decimals=0
RegExpSubstitute=1
Substitute="^([0-9]|[12][0-9])?$":"","^(\d+)$":"\1%"
Group=Weather

[MeasureWxD1Low]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Low
Day=1
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxD1High]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=High
Day=1
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxD1Rain]
; the day's highest chance of rain, as a chip from 30 %
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=PrecipitationChance
Day=1
Decimals=0
RegExpSubstitute=1
Substitute="^([0-9]|[12][0-9])?$":"","^(\d+)$":"\1%"
Group=Weather

[MeasureWxD2Low]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Low
Day=2
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxD2High]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=High
Day=2
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxD2Rain]
; the day's highest chance of rain, as a chip from 30 %
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=PrecipitationChance
Day=2
Decimals=0
RegExpSubstitute=1
Substitute="^([0-9]|[12][0-9])?$":"","^(\d+)$":"\1%"
Group=Weather

[MeasureWxD3Low]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Low
Day=3
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxD3High]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=High
Day=3
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxD3Rain]
; the day's highest chance of rain, as a chip from 30 %
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=PrecipitationChance
Day=3
Decimals=0
RegExpSubstitute=1
Substitute="^([0-9]|[12][0-9])?$":"","^(\d+)$":"\1%"
Group=Weather

[MeasureWxD4Low]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Low
Day=4
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxD4High]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=High
Day=4
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxD4Rain]
; the day's highest chance of rain, as a chip from 30 %
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=PrecipitationChance
Day=4
Decimals=0
RegExpSubstitute=1
Substitute="^([0-9]|[12][0-9])?$":"","^(\d+)$":"\1%"
Group=Weather

[MeasureWxD5Low]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Low
Day=5
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxD5High]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=High
Day=5
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxD5Rain]
; the day's highest chance of rain, as a chip from 30 %
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=PrecipitationChance
Day=5
Decimals=0
RegExpSubstitute=1
Substitute="^([0-9]|[12][0-9])?$":"","^(\d+)$":"\1%"
Group=Weather

[MeasureWxDayLabel]
; read as [&MeasureWxDayLabel:Day(n, Time)]: "Sun" / "周日" (names from Locale)
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Time
Day=0
Format=%a
Group=Weather

[MeasureWxDayFull]
; tooltips: "Sunday"
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Time
Day=0
Format=%A
Group=Weather

[MeasureWxLowColor]
; [&MeasureWxLowColor:Day(n, TemperatureColor)] is the colour of day n's low (MeasureWxHighColor's, in Hourly.inc, of
; its high); black until there is a forecast
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=TemperatureColor
ColorOf=Low
Day=0
UnavailableText=0,0,0
Group=Weather

[MeasureWxWeekLow]
; the bars' range: the six days drawn (MacWeather's own range spans every day it has, up to ten)
Measure=Calc
Formula=Min(Min(Min(MeasureWxD0Low, MeasureWxD1Low), Min(MeasureWxD2Low, MeasureWxD3Low)), Min(MeasureWxD4Low, MeasureWxD5Low))
Group=Weather

[MeasureWxWeekHigh]
Measure=Calc
Formula=Max(Max(Max(MeasureWxD0High, MeasureWxD1High), Max(MeasureWxD2High, MeasureWxD3High)), Max(MeasureWxD4High, MeasureWxD5High))
Group=Weather

[MeasureWxWeekSpan]
Measure=Calc
Formula=Max(MeasureWxWeekHigh - MeasureWxWeekLow, 1)
Group=Weather

; ---------------------------------------------------------------- details and separator
[MeterDetails]
; "Feels like 12° · Humidity 71% · Wind 14 km/h" on baseline 167
Meter=String
MeterStyle=sCaption
MeasureName=MeasureWxFeels
Text=#WeatherFeelsLike# %1° · #WeatherHumidity# [&MeasureWx:Now(Humidity, 0)]% · #WeatherWind# [&MeasureWx:Now(WindSpeed, 0)] [&MeasureWx:Now(WindUnit)]
X=16
Y=(167 - #Ascent11#)
W=328
ClipString=1
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterSeparator]
; 0.5 pt at y 181, x 16 → 344; it stays while waiting, so nothing moves when the data arrives
Meter=Shape
X=16
Y=180
Shape=Line 0,1,328,1 | StrokeWidth 0.5 | Stroke Color #SeparatorColor#
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather
UpdateDivider=-1

; ---------------------------------------------------------------- the days' hit boxes (under the rows)

[MeterDayHit0]
Meter=Image
MeterStyle=sHit
X=8
Y=188.5
W=344
H=24
LeftMouseUpAction=#OpenAction#
ToolTipText=#WeatherToday##WeatherColon#[MeasureWxD0Low]°#WeatherTo#[MeasureWxD0High]° · #WeatherRainPre#[&MeasureWx:Day(0, PrecipitationChance, 0)]%#WeatherRainPost#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayHit1]
Meter=Image
MeterStyle=sHit
X=8
Y=212.5
W=344
H=24
LeftMouseUpAction=#OpenAction#
ToolTipText=[&MeasureWxDayFull:Day(1, Time)]#WeatherColon#[MeasureWxD1Low]°#WeatherTo#[MeasureWxD1High]° · #WeatherRainPre#[&MeasureWx:Day(1, PrecipitationChance, 0)]%#WeatherRainPost#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayHit2]
Meter=Image
MeterStyle=sHit
X=8
Y=236.5
W=344
H=24
LeftMouseUpAction=#OpenAction#
ToolTipText=[&MeasureWxDayFull:Day(2, Time)]#WeatherColon#[MeasureWxD2Low]°#WeatherTo#[MeasureWxD2High]° · #WeatherRainPre#[&MeasureWx:Day(2, PrecipitationChance, 0)]%#WeatherRainPost#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayHit3]
Meter=Image
MeterStyle=sHit
X=8
Y=260.5
W=344
H=24
LeftMouseUpAction=#OpenAction#
ToolTipText=[&MeasureWxDayFull:Day(3, Time)]#WeatherColon#[MeasureWxD3Low]°#WeatherTo#[MeasureWxD3High]° · #WeatherRainPre#[&MeasureWx:Day(3, PrecipitationChance, 0)]%#WeatherRainPost#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayHit4]
Meter=Image
MeterStyle=sHit
X=8
Y=284.5
W=344
H=24
LeftMouseUpAction=#OpenAction#
ToolTipText=[&MeasureWxDayFull:Day(4, Time)]#WeatherColon#[MeasureWxD4Low]°#WeatherTo#[MeasureWxD4High]° · #WeatherRainPre#[&MeasureWx:Day(4, PrecipitationChance, 0)]%#WeatherRainPost#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayHit5]
Meter=Image
MeterStyle=sHit
X=8
Y=308.5
W=344
H=24
LeftMouseUpAction=#OpenAction#
ToolTipText=[&MeasureWxDayFull:Day(5, Time)]#WeatherColon#[MeasureWxD5Low]°#WeatherTo#[MeasureWxD5High]° · #WeatherRainPre#[&MeasureWx:Day(5, PrecipitationChance, 0)]%#WeatherRainPost#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

; ---------------------------------------------------------------- day 0: baseline 205, centre line 200.42
; today's bar is 7 tall, so the dot at the current temperature fits inside the meter
[MeterDay0]
Meter=String
MeterStyle=sBodyStrong
Text=#WeatherToday#
X=16
Y=(205 - #Ascent13#)
W=52
ClipString=1
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDaySymbol0]
Meter=Image
ImageName=sf:[&MeasureWx:Day(0, Symbol)]
MacSymbolSize=17
MacSymbolWeight=Regular
MacSymbolRendering=#WxSymbolRendering#
ImageTint=#WxSymbolTint#
ImageAlpha=(#WxSymbolAlpha# * ([MeasureWxStale:] ? 0.6 : 1))
MacSymbolColors=[&MeasureWx:Day(0, SymbolPalette)]
PreserveAspectRatio=1
X=72
Y=(205 - 4.58 - 13)
W=26
H=26
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayRain0]
Meter=String
MeterStyle=sMicroNum
MeasureName=MeasureWxD0Rain
X=100
Y=(205 - 4.58 + #CapHeight9# / 2 - #Ascent9#)
FontColor=#PrecipitationTextColor#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayLow0]
Meter=String
MeterStyle=sValue | sMissing
MeasureName=MeasureWxD0Low
Text=%1°
StringAlign=Right
X=172
Y=(205 - #Ascent13#)
FontColor=#SecondaryTextColor#
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather

[MeterDayTrack0]
Meter=Shape
X=180
Y=(205 - 4.58 - 2.5)
Shape=Rectangle 0,0,120,5,2.5 | Fill Color #ControlFillColor# | StrokeWidth 0
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather
UpdateDivider=-1

[MeterDayFill0]
; from the day's low to its high within the six days' range, at least a dot wide; 180 = left to right
Meter=Shape
X=180
Y=(205 - 4.58 - 4.25)
Shape=Rectangle (Min(115, 120 * ([MeasureWxD0Low:] - [MeasureWxWeekLow:]) / [MeasureWxWeekSpan:])),1.75,(Max(5, 120 * ([MeasureWxD0High:] - [MeasureWxD0Low:]) / [MeasureWxWeekSpan:])),5,2.5 | Fill LinearGradient WxBar0 | StrokeWidth 0
Shape2=Ellipse (Clamp(120 * ([MeasureWx:] - [MeasureWxWeekLow:]) / [MeasureWxWeekSpan:], 4.25, 115.75)),4.25,3.5 | Fill Color 255,255,255 | StrokeWidth 1.5 | Stroke Color #WxDotRingColor#
WxBar0=180 | [&MeasureWxLowColor:Day(0, TemperatureColor)] ; 0.0 | [&MeasureWxHighColor:Day(0, TemperatureColor)] ; 1.0
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayHigh0]
Meter=String
MeterStyle=sValue | sMissing
MeasureName=MeasureWxD0High
Text=%1°
StringAlign=Right
X=344
Y=(205 - #Ascent13#)
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather

; ---------------------------------------------------------------- day 1: baseline 229, centre line 224.42
[MeterDay1]
Meter=String
MeterStyle=sBodyStrong
Text=[&MeasureWxDayLabel:Day(1, Time)]
X=16
Y=(229 - #Ascent13#)
W=52
ClipString=1
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDaySymbol1]
Meter=Image
ImageName=sf:[&MeasureWx:Day(1, Symbol)]
MacSymbolSize=17
MacSymbolWeight=Regular
MacSymbolRendering=#WxSymbolRendering#
ImageTint=#WxSymbolTint#
ImageAlpha=(#WxSymbolAlpha# * ([MeasureWxStale:] ? 0.6 : 1))
MacSymbolColors=[&MeasureWx:Day(1, SymbolPalette)]
PreserveAspectRatio=1
X=72
Y=(229 - 4.58 - 13)
W=26
H=26
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayRain1]
Meter=String
MeterStyle=sMicroNum
MeasureName=MeasureWxD1Rain
X=100
Y=(229 - 4.58 + #CapHeight9# / 2 - #Ascent9#)
FontColor=#PrecipitationTextColor#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayLow1]
Meter=String
MeterStyle=sValue | sMissing
MeasureName=MeasureWxD1Low
Text=%1°
StringAlign=Right
X=172
Y=(229 - #Ascent13#)
FontColor=#SecondaryTextColor#
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather

[MeterDayTrack1]
Meter=Shape
X=180
Y=(229 - 4.58 - 2.5)
Shape=Rectangle 0,0,120,5,2.5 | Fill Color #ControlFillColor# | StrokeWidth 0
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather
UpdateDivider=-1

[MeterDayFill1]
; from the day's low to its high within the six days' range, at least a dot wide; 180 = left to right
Meter=Shape
X=180
Y=(229 - 4.58 - 2.5)
Shape=Rectangle (Min(115, 120 * ([MeasureWxD1Low:] - [MeasureWxWeekLow:]) / [MeasureWxWeekSpan:])),0,(Max(5, 120 * ([MeasureWxD1High:] - [MeasureWxD1Low:]) / [MeasureWxWeekSpan:])),5,2.5 | Fill LinearGradient WxBar1 | StrokeWidth 0
WxBar1=180 | [&MeasureWxLowColor:Day(1, TemperatureColor)] ; 0.0 | [&MeasureWxHighColor:Day(1, TemperatureColor)] ; 1.0
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayHigh1]
Meter=String
MeterStyle=sValue | sMissing
MeasureName=MeasureWxD1High
Text=%1°
StringAlign=Right
X=344
Y=(229 - #Ascent13#)
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather

; ---------------------------------------------------------------- day 2: baseline 253, centre line 248.42
[MeterDay2]
Meter=String
MeterStyle=sBodyStrong
Text=[&MeasureWxDayLabel:Day(2, Time)]
X=16
Y=(253 - #Ascent13#)
W=52
ClipString=1
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDaySymbol2]
Meter=Image
ImageName=sf:[&MeasureWx:Day(2, Symbol)]
MacSymbolSize=17
MacSymbolWeight=Regular
MacSymbolRendering=#WxSymbolRendering#
ImageTint=#WxSymbolTint#
ImageAlpha=(#WxSymbolAlpha# * ([MeasureWxStale:] ? 0.6 : 1))
MacSymbolColors=[&MeasureWx:Day(2, SymbolPalette)]
PreserveAspectRatio=1
X=72
Y=(253 - 4.58 - 13)
W=26
H=26
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayRain2]
Meter=String
MeterStyle=sMicroNum
MeasureName=MeasureWxD2Rain
X=100
Y=(253 - 4.58 + #CapHeight9# / 2 - #Ascent9#)
FontColor=#PrecipitationTextColor#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayLow2]
Meter=String
MeterStyle=sValue | sMissing
MeasureName=MeasureWxD2Low
Text=%1°
StringAlign=Right
X=172
Y=(253 - #Ascent13#)
FontColor=#SecondaryTextColor#
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather

[MeterDayTrack2]
Meter=Shape
X=180
Y=(253 - 4.58 - 2.5)
Shape=Rectangle 0,0,120,5,2.5 | Fill Color #ControlFillColor# | StrokeWidth 0
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather
UpdateDivider=-1

[MeterDayFill2]
; from the day's low to its high within the six days' range, at least a dot wide; 180 = left to right
Meter=Shape
X=180
Y=(253 - 4.58 - 2.5)
Shape=Rectangle (Min(115, 120 * ([MeasureWxD2Low:] - [MeasureWxWeekLow:]) / [MeasureWxWeekSpan:])),0,(Max(5, 120 * ([MeasureWxD2High:] - [MeasureWxD2Low:]) / [MeasureWxWeekSpan:])),5,2.5 | Fill LinearGradient WxBar2 | StrokeWidth 0
WxBar2=180 | [&MeasureWxLowColor:Day(2, TemperatureColor)] ; 0.0 | [&MeasureWxHighColor:Day(2, TemperatureColor)] ; 1.0
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayHigh2]
Meter=String
MeterStyle=sValue | sMissing
MeasureName=MeasureWxD2High
Text=%1°
StringAlign=Right
X=344
Y=(253 - #Ascent13#)
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather

; ---------------------------------------------------------------- day 3: baseline 277, centre line 272.42
[MeterDay3]
Meter=String
MeterStyle=sBodyStrong
Text=[&MeasureWxDayLabel:Day(3, Time)]
X=16
Y=(277 - #Ascent13#)
W=52
ClipString=1
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDaySymbol3]
Meter=Image
ImageName=sf:[&MeasureWx:Day(3, Symbol)]
MacSymbolSize=17
MacSymbolWeight=Regular
MacSymbolRendering=#WxSymbolRendering#
ImageTint=#WxSymbolTint#
ImageAlpha=(#WxSymbolAlpha# * ([MeasureWxStale:] ? 0.6 : 1))
MacSymbolColors=[&MeasureWx:Day(3, SymbolPalette)]
PreserveAspectRatio=1
X=72
Y=(277 - 4.58 - 13)
W=26
H=26
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayRain3]
Meter=String
MeterStyle=sMicroNum
MeasureName=MeasureWxD3Rain
X=100
Y=(277 - 4.58 + #CapHeight9# / 2 - #Ascent9#)
FontColor=#PrecipitationTextColor#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayLow3]
Meter=String
MeterStyle=sValue | sMissing
MeasureName=MeasureWxD3Low
Text=%1°
StringAlign=Right
X=172
Y=(277 - #Ascent13#)
FontColor=#SecondaryTextColor#
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather

[MeterDayTrack3]
Meter=Shape
X=180
Y=(277 - 4.58 - 2.5)
Shape=Rectangle 0,0,120,5,2.5 | Fill Color #ControlFillColor# | StrokeWidth 0
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather
UpdateDivider=-1

[MeterDayFill3]
; from the day's low to its high within the six days' range, at least a dot wide; 180 = left to right
Meter=Shape
X=180
Y=(277 - 4.58 - 2.5)
Shape=Rectangle (Min(115, 120 * ([MeasureWxD3Low:] - [MeasureWxWeekLow:]) / [MeasureWxWeekSpan:])),0,(Max(5, 120 * ([MeasureWxD3High:] - [MeasureWxD3Low:]) / [MeasureWxWeekSpan:])),5,2.5 | Fill LinearGradient WxBar3 | StrokeWidth 0
WxBar3=180 | [&MeasureWxLowColor:Day(3, TemperatureColor)] ; 0.0 | [&MeasureWxHighColor:Day(3, TemperatureColor)] ; 1.0
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayHigh3]
Meter=String
MeterStyle=sValue | sMissing
MeasureName=MeasureWxD3High
Text=%1°
StringAlign=Right
X=344
Y=(277 - #Ascent13#)
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather

; ---------------------------------------------------------------- day 4: baseline 301, centre line 296.42
[MeterDay4]
Meter=String
MeterStyle=sBodyStrong
Text=[&MeasureWxDayLabel:Day(4, Time)]
X=16
Y=(301 - #Ascent13#)
W=52
ClipString=1
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDaySymbol4]
Meter=Image
ImageName=sf:[&MeasureWx:Day(4, Symbol)]
MacSymbolSize=17
MacSymbolWeight=Regular
MacSymbolRendering=#WxSymbolRendering#
ImageTint=#WxSymbolTint#
ImageAlpha=(#WxSymbolAlpha# * ([MeasureWxStale:] ? 0.6 : 1))
MacSymbolColors=[&MeasureWx:Day(4, SymbolPalette)]
PreserveAspectRatio=1
X=72
Y=(301 - 4.58 - 13)
W=26
H=26
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayRain4]
Meter=String
MeterStyle=sMicroNum
MeasureName=MeasureWxD4Rain
X=100
Y=(301 - 4.58 + #CapHeight9# / 2 - #Ascent9#)
FontColor=#PrecipitationTextColor#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayLow4]
Meter=String
MeterStyle=sValue | sMissing
MeasureName=MeasureWxD4Low
Text=%1°
StringAlign=Right
X=172
Y=(301 - #Ascent13#)
FontColor=#SecondaryTextColor#
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather

[MeterDayTrack4]
Meter=Shape
X=180
Y=(301 - 4.58 - 2.5)
Shape=Rectangle 0,0,120,5,2.5 | Fill Color #ControlFillColor# | StrokeWidth 0
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather
UpdateDivider=-1

[MeterDayFill4]
; from the day's low to its high within the six days' range, at least a dot wide; 180 = left to right
Meter=Shape
X=180
Y=(301 - 4.58 - 2.5)
Shape=Rectangle (Min(115, 120 * ([MeasureWxD4Low:] - [MeasureWxWeekLow:]) / [MeasureWxWeekSpan:])),0,(Max(5, 120 * ([MeasureWxD4High:] - [MeasureWxD4Low:]) / [MeasureWxWeekSpan:])),5,2.5 | Fill LinearGradient WxBar4 | StrokeWidth 0
WxBar4=180 | [&MeasureWxLowColor:Day(4, TemperatureColor)] ; 0.0 | [&MeasureWxHighColor:Day(4, TemperatureColor)] ; 1.0
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayHigh4]
Meter=String
MeterStyle=sValue | sMissing
MeasureName=MeasureWxD4High
Text=%1°
StringAlign=Right
X=344
Y=(301 - #Ascent13#)
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather

; ---------------------------------------------------------------- day 5: baseline 325, centre line 320.42
[MeterDay5]
Meter=String
MeterStyle=sBodyStrong
Text=[&MeasureWxDayLabel:Day(5, Time)]
X=16
Y=(325 - #Ascent13#)
W=52
ClipString=1
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDaySymbol5]
Meter=Image
ImageName=sf:[&MeasureWx:Day(5, Symbol)]
MacSymbolSize=17
MacSymbolWeight=Regular
MacSymbolRendering=#WxSymbolRendering#
ImageTint=#WxSymbolTint#
ImageAlpha=(#WxSymbolAlpha# * ([MeasureWxStale:] ? 0.6 : 1))
MacSymbolColors=[&MeasureWx:Day(5, SymbolPalette)]
PreserveAspectRatio=1
X=72
Y=(325 - 4.58 - 13)
W=26
H=26
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayRain5]
Meter=String
MeterStyle=sMicroNum
MeasureName=MeasureWxD5Rain
X=100
Y=(325 - 4.58 + #CapHeight9# / 2 - #Ascent9#)
FontColor=#PrecipitationTextColor#
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayLow5]
Meter=String
MeterStyle=sValue | sMissing
MeasureName=MeasureWxD5Low
Text=%1°
StringAlign=Right
X=172
Y=(325 - #Ascent13#)
FontColor=#SecondaryTextColor#
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather

[MeterDayTrack5]
Meter=Shape
X=180
Y=(325 - 4.58 - 2.5)
Shape=Rectangle 0,0,120,5,2.5 | Fill Color #ControlFillColor# | StrokeWidth 0
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather
UpdateDivider=-1

[MeterDayFill5]
; from the day's low to its high within the six days' range, at least a dot wide; 180 = left to right
Meter=Shape
X=180
Y=(325 - 4.58 - 2.5)
Shape=Rectangle (Min(115, 120 * ([MeasureWxD5Low:] - [MeasureWxWeekLow:]) / [MeasureWxWeekSpan:])),0,(Max(5, 120 * ([MeasureWxD5High:] - [MeasureWxD5Low:]) / [MeasureWxWeekSpan:])),5,2.5 | Fill LinearGradient WxBar5 | StrokeWidth 0
WxBar5=180 | [&MeasureWxLowColor:Day(5, TemperatureColor)] ; 0.0 | [&MeasureWxHighColor:Day(5, TemperatureColor)] ; 1.0
Hidden=([MeasureWxMode:] <> 0)
DynamicVariables=1
Group=Weather

[MeterDayHigh5]
Meter=String
MeterStyle=sValue | sMissing
MeasureName=MeasureWxD5High
Text=%1°
StringAlign=Right
X=344
Y=(325 - #Ascent13#)
Hidden=([MeasureWxMode:] = 2)
DynamicVariables=1
Group=Weather
