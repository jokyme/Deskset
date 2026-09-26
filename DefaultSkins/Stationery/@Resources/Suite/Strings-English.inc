; Stationery — the widgets' words in English. Original work, MIT licensed.
; Strings-Chinese.inc has the same keys, so a widget never branches on the language. A value with a space at either
; end is quoted, or the INI reader would trim it. Menu titles are Title Case and at most 30 characters.

[Variables]
; ---------------------------------------------------------------- dates and times
; the order of a date written as one string; the names come from Locale (Variables.inc)
DateFormat=%B %#d
DateFormatLong=%A, %B %#d
DateFormatFull=%A, %B %#d, %Y
; a time in a caption or a row: 24-hour "07:10", 12-hour "7:10 AM"
CaptionTime24=%H:%M
CaptionTime12=%#I:%M %p
; units after a number (durations are written with units: "11 h 56 min", "14 d 5 h")
UnitDay=d
UnitHour=h
UnitMinute=min

; ---------------------------------------------------------------- words several widgets share
StrSunrise=Sunrise
StrSunset=Sunset
StrDaylight=Daylight
StrMidnightSun=Midnight sun
StrPolarNight=Polar night
StrAllDay=All day
StrNone=None
StrChooseCity=Choose City…
StrOpenPrivacySettings=Open Privacy Settings

; ---------------------------------------------------------------- the suite's menu items
MenuLookAuto=Look: Follow macOS
MenuLookLight=Look: Light
MenuLookDark=Look: Dark
MenuLookClear=Look: Clear
MenuCards0=Cards: Glass
MenuCards1=Cards: Solid
MenuInkAuto=Ink: Automatic
MenuInkWhite=Ink: White
MenuInkDark=Ink: Dark
MenuClockAuto=Clock: Automatic
MenuClock24=Clock: 24-Hour
MenuClock12=Clock: 12-Hour
MenuWeekStartAuto=Week Starts: Automatic
MenuWeekStart0=Week Starts: Sunday
MenuWeekStart1=Week Starts: Monday
MenuWeekStart2=Week Starts: Tuesday
MenuWeekStart3=Week Starts: Wednesday
MenuWeekStart4=Week Starts: Thursday
MenuWeekStart5=Week Starts: Friday
MenuWeekStart6=Week Starts: Saturday
MenuTempAuto=Temperature: Automatic
MenuTempC=Temperature: °C
MenuTempF=Temperature: °F

; ---------------------------------------------------------------- the moon, by the phase's eighth (Round(phase × 8) % 8)
Moon0=New Moon
Moon1=Waxing Crescent
Moon2=First Quarter
Moon3=Waxing Gibbous
Moon4=Full Moon
Moon5=Waning Gibbous
Moon6=Last Quarter
Moon7=Waning Crescent

; ---------------------------------------------------------------- weather conditions, by MET Norway's number
; (MacWeather Type=Condition's number: [#Cond[&MeasureCondition:0]])
Cond0=Unknown
Cond1=Clear
Cond2=Mostly clear
Cond3=Partly cloudy
Cond4=Cloudy
Cond5=Rain showers
Cond6=Showers, thunder
Cond7=Sleet showers
Cond8=Snow showers
Cond9=Rain
Cond10=Heavy rain
Cond11=Heavy rain, thunder
Cond12=Sleet
Cond13=Snow
Cond14=Snow, thunder
Cond15=Fog
Cond20=Sleet showers, thunder
Cond21=Snow showers, thunder
Cond22=Rain, thunder
Cond23=Sleet, thunder
Cond24=Light showers, thunder
Cond25=Heavy showers, thunder
Cond26=Light sleet showers, thunder
Cond27=Heavy sleet showers, thunder
Cond28=Light snow showers, thunder
Cond29=Heavy snow showers, thunder
Cond30=Light rain, thunder
Cond31=Light sleet, thunder
Cond32=Heavy sleet, thunder
Cond33=Light snow, thunder
Cond34=Heavy snow, thunder
Cond40=Light rain showers
Cond41=Heavy rain showers
Cond42=Light sleet showers
Cond43=Heavy sleet showers
Cond44=Light snow showers
Cond45=Heavy snow showers
Cond46=Light rain
Cond47=Light sleet
Cond48=Heavy sleet
Cond49=Light snow
Cond50=Heavy snow

; ---------------------------------------------------------------- weather states, by MacWeather Type=Status's number
Status0=Up to date
Status1=Loading weather…
Status2=Not up to date
Status3=Set a location
Status4=Place not found
Status5=Location access is off
Status6=This Mac’s location is unknown
Status7=No forecast for this place
Status8=Weather service refused
Status9=Weather service busy
Status10=Offline · retrying
Status11=Weather is off
Status12=Shows on the desktop
Status13=Too many weather places

; ---------------------------------------------------------------- Clock
ClockMenuOpen=Open Clock
ClockMenuLineSun=Bottom Line: Sun
ClockMenuLineWeek=Bottom Line: Week
ClockMenuLineNone=Bottom Line: None
; the City item by the place's state: looking it up, found (the name, at most 21 characters), none
ClockMenuCity0=City…
ClockMenuCity1=City: [MeasureSunMenu]…
ClockMenuCity2=Choose City…
ClockNeedCity=Sun times need a city
ClockWeekLine=Week [MeasureWeekNumber] · Day [MeasureYearDay]
; the card's sentence: the time, then the day, the sun (by state: loading, sun, midnight sun, polar night, no place)
; and the moon
ClockTipTime24=[MeasureTime]
ClockTipTime12=[MeasureTime] [MeasureAMPM]
ClockTipWeek=, week [MeasureWeekNumber], day [MeasureYearDay].
ClockTipBody0=
ClockTipBody1=" [MeasureSun]: sunrise [MeasureSunrise], sunset [MeasureSunset], [MeasureDayLengthText] of daylight."
ClockTipBody2=" [MeasureSun]: midnight sun, the sun does not set today."
ClockTipBody3=" [MeasureSun]: polar night, the sun does not rise today."
ClockTipBody4=" Choose a city to see sunrise and sunset."
ClockTipMoon=" [#Moon[&MeasureMoonEighth:0]], [MeasureMoonIllum:0]% lit."
ClockTipChooseCity=Choose the city for sunrise and sunset
