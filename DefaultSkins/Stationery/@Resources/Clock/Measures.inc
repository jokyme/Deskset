; Stationery · Clock — the measures both sizes share. Original work, MIT licensed.
; Everything is worked out on the Mac: the time (Time measures) and the sun and moon (MacSun, from the place's
; position; never the network). Nothing asks for a permission, except Location=auto, which is the user's choice.
;
; Only the clock tick, the place and the load timer run every second. Everything in group Clock updates when the
; minute changes (and when the place arrives), so the widget draws once a minute. The day rolls over with that tick.

[Variables]
; 0 while the place is looked up (at most 2 s), 1 with a place, 2 without one
PlaceState=0

; ---------------------------------------------------------------- time
[MeasureNow]
; seconds since 1601 on the Mac's clock
Measure=Time
TimeStamp=#TestNow#

[MeasureMinute]
Measure=Calc
Formula=Floor(MeasureNow / 60)
OnChangeAction=[!UpdateMeasureGroup Clock][!UpdateMeterGroup Clock][!Redraw]

[MeasureTime]
; "10:09": the digits only; AM/PM is an eyebrow of its own
Measure=Time
TimeStamp=#TestNow#
Format=[#TimeFormat[#Hours]]
FormatLocale=#Locale#
Group=Clock
UpdateDivider=-1

[MeasureAMPM]
Measure=Time
TimeStamp=#TestNow#
Format=%p
FormatLocale=#Locale#
Group=Clock
UpdateDivider=-1

[MeasureWeekday]
Measure=Time
TimeStamp=#TestNow#
Format=%A
FormatLocale=#Locale#
Group=Clock
UpdateDivider=-1

[MeasureDate]
Measure=Time
TimeStamp=#TestNow#
Format=#DateFormat#
FormatLocale=#Locale#
Group=Clock
UpdateDivider=-1

[MeasureDateFull]
Measure=Time
TimeStamp=#TestNow#
Format=#DateFormatFull#
FormatLocale=#Locale#
Group=Clock
UpdateDivider=-1

[MeasureWeekNumber]
; the ISO week; the # flag does not take %V's leading zero away, so a Substitute does
Measure=Time
TimeStamp=#TestNow#
Format=%V
RegExpSubstitute=1
Substitute="^0":""
Group=Clock
UpdateDivider=-1

[MeasureYearDay]
Measure=Time
TimeStamp=#TestNow#
Format=%#j
Group=Clock
UpdateDivider=-1

; ---------------------------------------------------------------- sun and moon
[MeasureSun]
; the place (empty until it is found); the sun measures below follow it. It runs every second only to notice the
; place arriving, which is cheap
Measure=Plugin
Plugin=MacSun
Location=#Location#
Type=Place
FormatLocale=#Locale#
NoEventText=—
IfMatch=.
IfMatchAction=[!SetVariable PlaceState 1][!UpdateMeasureGroup Clock][!UpdateMeterGroup Clock][!Redraw]

[MeasureSunMenu]
; the place's name for the menu title (titles stop at 30 characters)
Measure=String
String=[MeasureSun]
RegExpSubstitute=1
Substitute="^(.{21}).+$":"\1…"
DynamicVariables=1
UpdateDivider=5

[MeasureLoadTimer]
; still no place after 2 s: the widget shows the state without one (not earlier, so nothing flickers at load)
Measure=Calc
Formula=Min(MeasureLoadTimer + 1, 3)
IfCondition=(MeasureLoadTimer = 2) && (#PlaceState# = 0)
IfTrueAction=[!SetVariable PlaceState 2][!UpdateMeasureGroup Clock][!UpdateMeterGroup Clock][!Redraw]
DynamicVariables=1

[MeasureSunState]
; 0 the sun rises and sets, 1 midnight sun, 2 polar night
Measure=Plugin
Plugin=MacSun
Parent=MeasureSun
Type=SunState
Group=Clock
UpdateDivider=-1

[MeasureSunProgress]
; 0 before sunrise, 0…1 by day, 1 after sunset
Measure=Plugin
Plugin=MacSun
Parent=MeasureSun
Type=DaylightProgress
Group=Clock
UpdateDivider=-1

[MeasureSunrise]
; "07:10" or "7:10 AM" in the place's time; "—" when the sun does not rise that day (the number is then 0)
Measure=Plugin
Plugin=MacSun
Parent=MeasureSun
Type=Sunrise
Format=[#CaptionTime[#Hours]]
UnavailableText=--
Group=Clock
UpdateDivider=-1

[MeasureSunset]
Measure=Plugin
Plugin=MacSun
Parent=MeasureSun
Type=Sunset
Format=[#CaptionTime[#Hours]]
UnavailableText=--
Group=Clock
UpdateDivider=-1

[MeasureSunriseTomorrow]
; the evening's line shows tomorrow's sunrise
Measure=Plugin
Plugin=MacSun
Parent=MeasureSun
Type=Sunrise
Day=1
Format=[#CaptionTime[#Hours]]
UnavailableText=--
Group=Clock
UpdateDivider=-1

[MeasureDayLength]
; seconds of daylight (86,400 in polar day, 0 in polar night). MacSun's own string ("11:56") reads as a time of
; day, so the text is built below
Measure=Plugin
Plugin=MacSun
Parent=MeasureSun
Type=DayLength
Group=Clock
UpdateDivider=-1

[MeasureDayMinutes]
Measure=Calc
Formula=Round(MeasureDayLength / 60)
Group=Clock
UpdateDivider=-1

[MeasureDayH]
Measure=Calc
Formula=Floor(MeasureDayMinutes / 60)
Group=Clock
UpdateDivider=-1

[MeasureDayM]
Measure=Calc
Formula=MeasureDayMinutes % 60
Group=Clock
UpdateDivider=-1

[MeasureDayLengthText]
; "11 h 56 min", "24 h", "45 min"
Measure=String
String=[MeasureDayH:0] #UnitHour# [MeasureDayM:0] #UnitMinute#
RegExpSubstitute=1
Substitute="^0 #UnitHour# ":""," 0 #UnitMinute#$":""
DynamicVariables=1
Group=Clock
UpdateDivider=-1

[MeasureMoonPhase]
; 0 new, 0.5 full; the moon needs no place
Measure=Plugin
Plugin=MacSun
Type=MoonPhase
UpdateDivider=300

[MeasureMoonEighth]
; the key of Moon0…Moon7 (names, in the Strings) and MoonSymbol0…MoonSymbol7 (symbols, in Tokens.inc)
Measure=Calc
Formula=Round(MeasureMoonPhase * 8) % 8
UpdateDivider=300

[MeasureMoonIllum]
; 0–100
Measure=Plugin
Plugin=MacSun
Type=MoonIllumination
UpdateDivider=300

; ---------------------------------------------------------------- the card's sentence and the city field
[MeasureTipState]
; the sentence's middle: 0 loading, 1 sun, 2 midnight sun, 3 polar night, 4 no place
Measure=Calc
Formula=(#PlaceState# = 0) ? 0 : ((#PlaceState# = 2) ? 4 : ((MeasureSunState = 1) ? 2 : ((MeasureSunState = 2) ? 3 : 1)))
DynamicVariables=1
Group=Clock
UpdateDivider=-1

[MeasureCityInput]
; "City…" in the menu (and "Choose City…" in the Medium) opens this field where the size puts it (CityField…).
; Return writes the suite's Location (a city, "latitude,longitude" or auto) and refreshes every Stationery widget;
; Escape cancels
Measure=Plugin
Plugin=InputText
X=#CityFieldX#
Y=#CityFieldY#
W=#CityFieldW#
H=24
SolidColor=#FieldColor#
FontColor=#TextColor#
FontFace=#FontText#
FontSize=9.75
DefaultValue=[MeasureSun]
FocusDismiss=1
Command1=[!WriteKeyValue Variables Location "$UserInput$" "#@#Variables.inc"][!RefreshGroup Stationery]
DynamicVariables=1
