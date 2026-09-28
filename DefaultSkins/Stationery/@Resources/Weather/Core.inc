; Stationery · Weather — the measures every size shares. Original work, MIT licensed.
; Forecasts come from MET Norway through MacWeather. The place is the suite's Location: by default the city of this
; Mac's time zone (timezone), found in Deskset's own place table, so nothing asks for a permission; only "Use My
; Location" (Location=auto) asks macOS for Location Services.
;
; Everything here is in group Weather and updates once a minute ([Rainmeter] DefaultUpdateDivider=60), and at once when
; MacWeather has news (FinishAction and the two error actions update the group). Missing values stay empty in the
; plugin (its UnavailableText is left empty on purpose: a child cannot set it back to empty) and read "--" on the card.

; ---------------------------------------------------------------- the forecast
[MeasureWx]
; the current temperature at full precision (today's dot on the Large's first bar); the card shows MeasureWxNow
Measure=Plugin
Plugin=MacWeather
Location=#Location#
; Auto is not a unit: MacWeather then follows the Mac's own setting
TemperatureUnit=#TempUnit#
FormatLocale=#Locale#
; the colours of the weather symbols' layers (Type=SymbolPalette), inherited by every child: clouds (and moons, snow
; and lightning) in the secondary ink, the sun yellow, rain in the rain colour; all white ink in Clear
PaletteInk=#SecondaryTextColor#
PaletteSun=#SunColor#
PaletteRain=#PrecipitationTextColor#
; the colour TemperatureColor gives instead of the scale's (white in Clear; empty: the scale)
ScaleColor=#WxScaleColor#
Type=Temperature
FinishAction=[!UpdateMeasureGroup Weather][!UpdateMeterGroup Weather][!Redraw]
OnConnectErrorAction=[!UpdateMeasureGroup Weather][!UpdateMeterGroup Weather][!Redraw]
OnLocationErrorAction=[!UpdateMeasureGroup Weather][!UpdateMeterGroup Weather][!Redraw]
Group=Weather

[MeasureWxNow]
; "14", "−3", "--"
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Temperature
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxCond]
; MET Norway's condition number (1–50; 0 unknown), the key of the suite's Cond… names
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Condition
Group=Weather

[MeasureWxSymbol]
; the condition's SF Symbol ("cloud.sun.fill"; empty without data)
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Symbol
Group=Weather

[MeasureWxPalette]
; the colours of that symbol's layers for MacSymbolColors ("0,0,0,153|255,204,0" for a sun behind a cloud in Light)
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=SymbolPalette
Group=Weather

[MeasureWxHigh]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=High
Day=0
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxLow]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Low
Day=0
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxFeels]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=FeelsLike
Decimals=0
RegExpSubstitute=1
Substitute="^$":"--","^-(?=\d)":"−"
Group=Weather

[MeasureWxUpdated]
; when the forecast was last confirmed, in this Mac's time: "10:05" / "10:05 AM"
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=UpdatedAt
Format=#WxTimeFormat#
Group=Weather

[MeasureWxPlace]
; "Oslo"; the widget's name while there is no place
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Place
RegExpSubstitute=1
Substitute="^$":"#WeatherTitle#"
Group=Weather

[MeasureWxAttribution]
; "Based on data from MET Norway"
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Attribution
UpdateDivider=-1

[MeasureWxAttributionURL]
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=AttributionURL
UpdateDivider=-1

[MeasureWxSource]
; where the place comes from: 0 none, 1 a named place, 2 coordinates, 3 this Mac's location, 4 this Mac's time zone
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=LocationSource
Group=Weather

; ---------------------------------------------------------------- the widget's state
[MeasureWxStatus]
; 0 ready, 1 loading, 2 not up to date, 3 no place, 4 place not found, 5 Location Services off, 6 no fix, 7 not
; covered, 8 refused, 9 busy, 10 offline, 11 turned off, 12 preview, 13 too many places. Not up to date (2) after a
; network failure reads "Offline · 09:30"; the number alone cannot tell it from a busy service or expired data, so
; WxStaleKey picks the stale line's glyph and words from MacWeather's own status text
Measure=Plugin
Plugin=MacWeather
Parent=MeasureWx
Type=Status
IfMatch=^Offline
IfMatchAction=[!SetVariable WxStaleKey Offline]
IfNotMatchAction=[!SetVariable WxStaleKey Updated]
Group=Weather

[MeasureWxMode]
; 0 data (ready, not up to date) · 2 a notice (no place, not found, Location off, no fix, turned off)
; · 1 waiting (loading, not covered, refused, busy, offline, preview, too many places)
Measure=Calc
Formula=((MeasureWxStatus = 0) || (MeasureWxStatus = 2)) ? 0 : ((((MeasureWxStatus >= 3) && (MeasureWxStatus <= 6)) || (MeasureWxStatus = 11)) ? 2 : 1)
Group=Weather

[MeasureWxStale]
Measure=Calc
Formula=MeasureWxStatus = 2
Group=Weather

[MeasureWxPrompt]
; the first-run check (a place taken from the Mac's time zone covers whole countries): only with data on screen, until
; the user keeps or changes the place
Measure=Calc
Formula=((MeasureWxMode = 0) && (MeasureWxSource = 4)) && (#LocationConfirmed# = 0)
Group=Weather

[MeasureWxNoticeKind]
; what a notice's click does (Vars.inc WxNoticeKind…): 1 the city field, 2 Location Services settings, 0 nothing
Measure=Calc
Formula=(MeasureWxMode = 2) ? [#WxNoticeKind[&MeasureWxStatus:]] : 0
DynamicVariables=1
Group=Weather

[MeasureWxTip]
; the card's sentence, by MeasureWxMode (WeatherCardTip0…2 in the Strings); a state that ends in "…" ("Loading
; weather…") takes no full stop after it
Measure=String
String=[#WeatherCardTip[&MeasureWxMode:]]
DynamicVariables=1
RegExpSubstitute=1
Substitute="…\.$":"…","…。$":"…"
Group=Weather

; ---------------------------------------------------------------- the place
[MeasureLocationKind]
; Location=auto: the header's glyph is location.fill, and the menu offers to stop using this Mac's location
Measure=String
String=#Location#
UpdateDivider=-1
IfMatch=(?i)^\s*(auto|current|here)\s*$
IfMatchAction=[!SetVariable WxPlaceSymbol location.fill][!SetOption Rainmeter ContextTitle4 "#WeatherMenuStopMyLocation#"][!SetOption Rainmeter ContextAction4 """[!WriteKeyValue Variables Location "#LastCity#" "#@#Variables.inc"][!RefreshGroup StationeryPlace]"""]
IfNotMatchAction=[!SetVariable WxPlaceSymbol mappin.and.ellipse]

[MeasureCityInput]
; "Location…", "Not your city? Change…" and the notices open this field over the header row. Return keeps or changes
; the place (a city, "latitude,longitude", timezone or auto) for the whole suite and confirms it; Escape or a click
; elsewhere closes it and changes nothing
Measure=Plugin
Plugin=InputText
X=12
Y=11
W=(#CardW# - 24)
H=24
SolidColor=#FieldColor#
FontColor=#TextColor#
FontFace=#FontText#
FontSize=9.75
FocusDismiss=1
; the plugin's own place ("" without one), not MeasureWxPlace, which says "Weather"
DefaultValue=[&MeasureWx:Now(Place)]
Command1=[!WriteKeyValue Variables Location "$UserInput$" "#@#Variables.inc"][!WriteKeyValue Variables LastCity "$UserInput$" "#@#Variables.inc"][!WriteKeyValue Variables LocationConfirmed 1 "#@#Variables.inc"][!RefreshGroup StationeryPlace]
DynamicVariables=1
