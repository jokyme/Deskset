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
MenuLanguageEnglish=Language: English
MenuLanguageChinese=Language: Chinese
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

; ---------------------------------------------------------------- Sentence Clock
SentenceMenuOpen=Open Clock
SentenceMenuCardGlass=Background: Card
SentenceMenuCardFrameless=Background: None
SentenceMenuGrid0=Unlit Words: Subtle
SentenceMenuGrid1=Unlit Words: Visible
SentenceMenuGlow1=Glow in Dark Mode: On
SentenceMenuGlow0=Glow in Dark Mode: Off
SentenceMenuTime1=Footer Time: Show
SentenceMenuTime0=Footer Time: Hide

; ---------------------------------------------------------------- Almanac
AlmanacMenuOpen=Open Calendar
AlmanacMenuSizeSmall=Size: Small
AlmanacMenuSizeRegular=Size: Regular
AlmanacMenuSizeLarge=Size: Large
AlmanacMenuSun1=Sunrise and Sunset: Show
AlmanacMenuSun0=Sunrise and Sunset: Hide
; the masthead's weekday ends with this ("Saturday,")
AlmanacWeekdaySuffix=,
; the data lines (capitals from the style); %1 is the number. The bold figure in the "to go" slot is its digits, or
; the whole last-day text
AlmanacWeekText=WEEK %1
AlmanacDayText=DAY %1
AlmanacToGoText=%1 TO GO
AlmanacDoneText=[MeasureDaysPercent:0]% DONE
AlmanacLastDay=LAST DAY
AlmanacSunriseText=SUNRISE %1
AlmanacSunsetText=SUNSET %1
AlmanacYearText=YEAR %1
AlmanacWeeksLeftText=%1 WEEKS LEFT
AlmanacTipDay=[MeasureDateFull]#CRLF#Week [MeasureWeekNumber] · day [MeasureDayOfYearNumber] of [MeasureDaysInYear:0]
AlmanacTipSun0=
AlmanacTipSun1=#CRLF#Sunrise [MeasureSunriseTip] · sunset [MeasureSunsetTip]
AlmanacTipProgress=[MeasureDaysPercent:0]% of the year done · [MeasureDaysTo:0] days to go#CRLF#Each dot is one week left.

; ---------------------------------------------------------------- Daybreak
DaybreakMenuOpen=Open Clock
DaybreakMenuTint1=Sky-Tinted Digits: On
DaybreakMenuTint0=Sky-Tinted Digits: Off
; the City item by the place's state: looking it up, found (the name, at most 21 characters), none
DaybreakMenuCity0=City…
DaybreakMenuCity1=City: [MeasurePlaceMenu]…
DaybreakMenuCity2=Choose City…
DaybreakNeedPlace=Choose a city for sunrise and sunset
; the line in place of the date while the pointer is over the ruler
DaybreakNextSunrise=Sunrise in [MeasureNextText]
DaybreakNextSunset=Sunset in [MeasureNextText]
DaybreakGoldenPrefix="Golden hour · "
; the ruler's tooltip by state: 0 no place, 1 sunrise and sunset, 2 midnight sun, 3 polar night
DaybreakTip0=Choose a city for sunrise and sunset.
DaybreakTip1=Sunrise [MeasureSunriseTip] · sunset [MeasureSunsetTip]#CRLF#[MeasureDayLengthText] of daylight · golden hour from [MeasureGoldenStartTip]
DaybreakTip2=Midnight sun: the sun does not set today.
DaybreakTip3=Polar night: the sun does not rise today.

; ---------------------------------------------------------------- Chronograph
ChronoMenuOpen=Open Clock
ChronoMenuDial0=Right Dial: Automatic
ChronoMenuDial1=Right Dial: Battery
ChronoMenuDial2=Right Dial: CPU
ChronoMenuSeconds1=Running Seconds: On
ChronoMenuSeconds0=Running Seconds: Off
ChronoMenuDialText=Dial Text…
; the City item by the weather's place: looking it up, found (the name, at most 21 characters), none
ChronoMenuCity0=City…
ChronoMenuCity1=City: [MeasureWxPlaceMenu]…
ChronoMenuCity2=Choose City…
; the wordmark under 12 until Dial Text… sets another (empty hides it)
ChronoDialTextDefault=Deskset
; the time with seconds, in the seconds register's tooltip and the dial's
ChronoTimeSeconds24=%H:%M:%S
ChronoTimeSeconds12=%#I:%M:%S %p
ChronoTipDate=[MeasureDateFull] · Week [MeasureWeekNumber]
; the weather register's tooltip by state: 0 ready, 1 no forecast yet, 2 no place, 3 location off, 4 not up to date
ChronoTipWeather0=[#Cond[&MeasureWxCondition:0]], [MeasureWx:0]° (feels like [MeasureWxFeels:0]°). Today [MeasureWxLow:0]° to [MeasureWxHigh:0]°; the dot marks now.
ChronoTipWeather1=[#Status[&MeasureWxStatus:0]]
ChronoTipWeather2=[#Status[&MeasureWxStatus:0]]. Click to choose a city.
ChronoTipWeather3=[#Status[&MeasureWxStatus:0]]. Click to open Privacy Settings.
ChronoTipWeather4=[#Cond[&MeasureWxCondition:0]], [MeasureWx:0]° (feels like [MeasureWxFeels:0]°). Today [MeasureWxLow:0]° to [MeasureWxHigh:0]°.#CRLF#[#Status[&MeasureWxStatus:0]]
; the power reserve's tooltip by state: 0 on battery, 1 charging, 2 plugged in, 3 CPU, 4 on battery (time unknown)
ChronoTipReserve0=Battery [CalcReserveValue:0]% · [MeasureBattLifeText] left
ChronoTipReserve1=Battery [CalcReserveValue:0]% · charging
ChronoTipReserve2=Battery [CalcReserveValue:0]% · plugged in
ChronoTipReserve3=CPU [CalcReserveValue:0]%
ChronoTipReserve4=Battery [CalcReserveValue:0]%

; ---------------------------------------------------------------- Turntable
TurntableMenuVinyl1=Record Color: From the Cover
TurntableMenuVinyl0=Record Color: Classic Black
TurntableMenuRest1Min=Arm Rests: After 1 Min
TurntableMenuRest5Min=Arm Rests: After 5 Min
TurntableMenuRestNever=Arm Rests: Never
TurntableMenuSeek1=Click a Groove to Seek: On
TurntableMenuSeek0=Click a Groove to Seek: Off
TurntableSpeed=33⅓ RPM
TurntableSideA=Side A
TurntableTipPlay=Play
TurntableTipPause=Pause
TurntableTipPrevious=Previous Track
TurntableTipNext=Next Track
TurntableTipSeek=Play from [MeasureSeekMin:0]:[MeasureSeekSec]
TurntableTipTrack=[MeasureLastTitle] — [MeasureLastArtist]

; ---------------------------------------------------------------- Studio VU
StudioMenuFaceAuto=Face: Follow Appearance
StudioMenuFaceIvory=Face: Always Ivory
StudioMenuFaceAmber=Face: Always Amber
StudioMenuSensNormal=Needle Sensitivity: Normal
StudioMenuSensHigh=Needle Sensitivity: High
StudioMenuSensLow=Needle Sensitivity: Low
StudioMenuSpeedVU=Needle Speed: VU
StudioMenuSpeedSlow=Needle Speed: Slow
StudioMenuPeak1=Peak LED: −1 dBFS
StudioMenuPeak3=Peak LED: −3 dBFS
StudioMenuPeak6=Peak LED: −6 dBFS
StudioPeakLabel=PEAK
StudioTipLeft=Left channel
StudioTipRight=Right channel
StudioTipLevelL=[MeasureVUL:1] VU · peak [MeasurePeakDbL:1] dBFS
StudioTipLevelR=[MeasureVUR:1] VU · peak [MeasurePeakDbR:1] dBFS
StudioTipPlay=Play
StudioTipPause=Pause
StudioTipPrevious=Previous Track
StudioTipNext=Next Track
StudioTipTrack=[MeasurePlayer] — [MeasureArtist]
