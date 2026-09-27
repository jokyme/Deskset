; Stationery · Calendar — the measures both sizes share: today, the month shown, its weeks and weekday initials, the
; moon, and the way back to today. Original work, MIT licensed.
; Everything is worked out on the Mac; nothing asks for a permission. Nothing here runs every second except the day
; key: the month's measures update when the month shown changes (group Month) and at the day change.
; A Calc reads what the measures above it worked out in the same update, so the order below matters.

[Variables]
; the month shown, in months from this one: the scroll moves it; never written to a file
MonthOffset=0
; the pointer is over the card (1) or not; when it left (a Windows timestamp); and how long the calendar waits
; after that before it turns back to this month by itself (seconds)
MouseInside=0
LastTouch=0
BrowseTimeout=120
BackToToday=[!SetVariable MonthOffset 0][!DisableMeasure MeasureBrowseIdle][!UpdateMeasureGroup Month][!UpdateMeterGroup Grid][!Redraw]
; text on a solid category fill (today's number on the red disc): white, or black on the Clear look's white disc
InverseTextColorRegular=255,255,255,255
InverseTextColorClear=0,0,0,216
InverseTextColor=[#InverseTextColor[#Glass]]

; ---------------------------------------------------------------- today
[MeasureTodayY]
Measure=Time
TimeStamp=#TestNow#
Format=%Y
Group=Month
UpdateDivider=-1

[MeasureTodayM]
Measure=Time
TimeStamp=#TestNow#
Format=%m
Group=Month
UpdateDivider=-1

[MeasureTodayD]
; "26": the Medium's day and today's number on the disc
Measure=Time
TimeStamp=#TestNow#
Format=%#d
Group=Month
UpdateDivider=-1

[MeasureWeekday]
Measure=Time
TimeStamp=#TestNow#
Format=%A
FormatLocale=#Locale#
Group=Month
UpdateDivider=-1

[MeasureWeekNow]
; the ISO week; the # flag does not take %V's leading zero away, so a Substitute does
Measure=Time
TimeStamp=#TestNow#
Format=%V
RegExpSubstitute=1
Substitute="^0":""
Group=Month
UpdateDivider=-1

[MeasureDayOfYear]
Measure=Time
TimeStamp=#TestNow#
Format=%#j
Group=Month
UpdateDivider=-1

[MeasureDateFull]
; "Saturday, September 26, 2026": the card's and today's tooltips
Measure=Time
TimeStamp=#TestNow#
Format=#DateFormatFull#
FormatLocale=#Locale#
Group=Month
UpdateDivider=-1

[MeasureDayKey]
; the day: its number changes once a day, at 00:00, and the calendar turns to the new day (and month). Its time
; stamp is also the clock the way back to today counts with
Measure=Time
TimeStamp=#TestNow#
Format=%Y%j
OnChangeAction=#BackToToday#[!UpdateMeasureGroup Moon]

; ---------------------------------------------------------------- the month shown
[MeasureShownIndex]
; months since year 0: this month plus MonthOffset
Measure=Calc
Formula=MeasureTodayY * 12 + MeasureTodayM - 1 + #MonthOffset#
DynamicVariables=1
Group=Month
UpdateDivider=-1

[MeasureShownY]
Measure=Calc
Formula=Floor(MeasureShownIndex / 12)
Group=Month
UpdateDivider=-1

[MeasureShownM]
Measure=Calc
Formula=MeasureShownIndex % 12 + 1
Group=Month
UpdateDivider=-1

[MeasureShownFirst]
; the 1st of the month shown; its number is its weekday (0 Sunday … 6 Saturday)
Measure=Time
TimeStamp=[MeasureShownY]-[MeasureShownM]-1
TimeStampFormat=%Y-%m-%d
Format=%w
DynamicVariables=1
Group=Month
UpdateDivider=-1

[MeasureFirstCol]
; the column of the 1st, counted from the first day of the week (Week Starts: FirstWeekday)
Measure=Calc
Formula=(MeasureShownFirst - #FirstWeekday# + 7) % 7
Group=Month
UpdateDivider=-1

[MeasureShownDays]
; days in the month shown
Measure=Calc
Formula=(MeasureShownM = 2) ? (28 + ((((MeasureShownY % 4) = 0) && ((MeasureShownY % 100) <> 0)) || ((MeasureShownY % 400) = 0))) : (30 + ((MeasureShownM + Floor(MeasureShownM / 8)) % 2))
Group=Month
UpdateDivider=-1

[MeasureRows]
; 4, 5 or 6 rows; the first row never moves
Measure=Calc
Formula=Floor((MeasureFirstCol + MeasureShownDays + 6) / 7)
Group=Month
UpdateDivider=-1

[MeasureTodayCell]
; today's cell, counted from the first row's first cell
Measure=Calc
Formula=MeasureFirstCol + MeasureTodayD - 1
Group=Month
UpdateDivider=-1

[MeasureOtherYear]
; 1 when the month shown is in another year (the Small's eyebrow then adds the year)
Measure=Calc
Formula=MeasureShownY <> MeasureTodayY
Group=Month
UpdateDivider=-1

[MeasureYearDays]
Measure=Calc
Formula=365 + ((((MeasureTodayY % 4) = 0) && ((MeasureTodayY % 100) <> 0)) || ((MeasureTodayY % 400) = 0))
Group=Month
UpdateDivider=-1

; ---------------------------------------------------------------- the weeks: each row's ISO week, from its fourth day
; (Thursday when the week starts on Monday, which is ISO's own rule; with Sunday or Saturday first, a day of the same
; Monday-to-Friday run). The rows' tooltips and the Medium's week numbers read these.
[MeasureRow1Day]
Measure=Calc
Formula=[MeasureShownFirst:Timestamp] + 86400 * (3 - MeasureFirstCol)
DynamicVariables=1
Group=Month
UpdateDivider=-1

[MeasureWeekRow1]
Measure=Time
TimeStamp=[MeasureRow1Day]
Format=%V
RegExpSubstitute=1
Substitute="^0":""
DynamicVariables=1
Group=Month
UpdateDivider=-1

[MeasureRow2Day]
Measure=Calc
Formula=[MeasureShownFirst:Timestamp] + 86400 * (10 - MeasureFirstCol)
DynamicVariables=1
Group=Month
UpdateDivider=-1

[MeasureWeekRow2]
Measure=Time
TimeStamp=[MeasureRow2Day]
Format=%V
RegExpSubstitute=1
Substitute="^0":""
DynamicVariables=1
Group=Month
UpdateDivider=-1

[MeasureRow3Day]
Measure=Calc
Formula=[MeasureShownFirst:Timestamp] + 86400 * (17 - MeasureFirstCol)
DynamicVariables=1
Group=Month
UpdateDivider=-1

[MeasureWeekRow3]
Measure=Time
TimeStamp=[MeasureRow3Day]
Format=%V
RegExpSubstitute=1
Substitute="^0":""
DynamicVariables=1
Group=Month
UpdateDivider=-1

[MeasureRow4Day]
Measure=Calc
Formula=[MeasureShownFirst:Timestamp] + 86400 * (24 - MeasureFirstCol)
DynamicVariables=1
Group=Month
UpdateDivider=-1

[MeasureWeekRow4]
Measure=Time
TimeStamp=[MeasureRow4Day]
Format=%V
RegExpSubstitute=1
Substitute="^0":""
DynamicVariables=1
Group=Month
UpdateDivider=-1

[MeasureRow5Day]
Measure=Calc
Formula=[MeasureShownFirst:Timestamp] + 86400 * (31 - MeasureFirstCol)
DynamicVariables=1
Group=Month
UpdateDivider=-1

[MeasureWeekRow5]
Measure=Time
TimeStamp=[MeasureRow5Day]
Format=%V
RegExpSubstitute=1
Substitute="^0":""
DynamicVariables=1
Group=Month
UpdateDivider=-1

[MeasureRow6Day]
Measure=Calc
Formula=[MeasureShownFirst:Timestamp] + 86400 * (38 - MeasureFirstCol)
DynamicVariables=1
Group=Month
UpdateDivider=-1

[MeasureWeekRow6]
Measure=Time
TimeStamp=[MeasureRow6Day]
Format=%V
RegExpSubstitute=1
Substitute="^0":""
DynamicVariables=1
Group=Month
UpdateDivider=-1

; ---------------------------------------------------------------- weekday initials, in the week's order and the Locale's language
; 1–7 January 2023 are Sunday to Saturday; the name is shortened to its first letter (周六 and 星期六 → 六)
[MeasureInitialDay1]
Measure=Calc
Formula=1 + (#FirstWeekday# + 0) % 7
UpdateDivider=-1

[MeasureInitial1]
Measure=Time
TimeStamp=2023-01-[MeasureInitialDay1]
TimeStampFormat=%Y-%m-%d
Format=%a
FormatLocale=#Locale#
RegExpSubstitute=1
Substitute="^(?:周|星期)(.)$":"\1","^(.).*$":"\1"
DynamicVariables=1
UpdateDivider=-1

[MeasureInitialDay2]
Measure=Calc
Formula=1 + (#FirstWeekday# + 1) % 7
UpdateDivider=-1

[MeasureInitial2]
Measure=Time
TimeStamp=2023-01-[MeasureInitialDay2]
TimeStampFormat=%Y-%m-%d
Format=%a
FormatLocale=#Locale#
RegExpSubstitute=1
Substitute="^(?:周|星期)(.)$":"\1","^(.).*$":"\1"
DynamicVariables=1
UpdateDivider=-1

[MeasureInitialDay3]
Measure=Calc
Formula=1 + (#FirstWeekday# + 2) % 7
UpdateDivider=-1

[MeasureInitial3]
Measure=Time
TimeStamp=2023-01-[MeasureInitialDay3]
TimeStampFormat=%Y-%m-%d
Format=%a
FormatLocale=#Locale#
RegExpSubstitute=1
Substitute="^(?:周|星期)(.)$":"\1","^(.).*$":"\1"
DynamicVariables=1
UpdateDivider=-1

[MeasureInitialDay4]
Measure=Calc
Formula=1 + (#FirstWeekday# + 3) % 7
UpdateDivider=-1

[MeasureInitial4]
Measure=Time
TimeStamp=2023-01-[MeasureInitialDay4]
TimeStampFormat=%Y-%m-%d
Format=%a
FormatLocale=#Locale#
RegExpSubstitute=1
Substitute="^(?:周|星期)(.)$":"\1","^(.).*$":"\1"
DynamicVariables=1
UpdateDivider=-1

[MeasureInitialDay5]
Measure=Calc
Formula=1 + (#FirstWeekday# + 4) % 7
UpdateDivider=-1

[MeasureInitial5]
Measure=Time
TimeStamp=2023-01-[MeasureInitialDay5]
TimeStampFormat=%Y-%m-%d
Format=%a
FormatLocale=#Locale#
RegExpSubstitute=1
Substitute="^(?:周|星期)(.)$":"\1","^(.).*$":"\1"
DynamicVariables=1
UpdateDivider=-1

[MeasureInitialDay6]
Measure=Calc
Formula=1 + (#FirstWeekday# + 5) % 7
UpdateDivider=-1

[MeasureInitial6]
Measure=Time
TimeStamp=2023-01-[MeasureInitialDay6]
TimeStampFormat=%Y-%m-%d
Format=%a
FormatLocale=#Locale#
RegExpSubstitute=1
Substitute="^(?:周|星期)(.)$":"\1","^(.).*$":"\1"
DynamicVariables=1
UpdateDivider=-1

[MeasureInitialDay7]
Measure=Calc
Formula=1 + (#FirstWeekday# + 6) % 7
UpdateDivider=-1

[MeasureInitial7]
Measure=Time
TimeStamp=2023-01-[MeasureInitialDay7]
TimeStampFormat=%Y-%m-%d
Format=%a
FormatLocale=#Locale#
RegExpSubstitute=1
Substitute="^(?:周|星期)(.)$":"\1","^(.).*$":"\1"
DynamicVariables=1
UpdateDivider=-1

; ---------------------------------------------------------------- the moon (needs no place)
[MeasureMoonPhase]
; 0 new, 0.5 full
Measure=Plugin
Plugin=MacSun
Type=MoonPhase
UpdateDivider=300
Group=Moon

[MeasureMoonEighth]
; the key of Moon0…Moon7 (names, in the Strings) and MoonSymbol0…MoonSymbol7 (symbols, in Tokens.inc)
Measure=Calc
Formula=Round(MeasureMoonPhase * 8) % 8
OnChangeAction=[!UpdateMeterGroup Moon][!UpdateMeter MeterCard][!Redraw]
UpdateDivider=300
Group=Moon

; ---------------------------------------------------------------- back to today
[MeasureBrowseIdle]
; while another month is shown and the pointer is away: seconds since it left. A scroll turns this on; the way back
; turns it off
Measure=Calc
Formula=((#MonthOffset# <> 0) && (#MouseInside# = 0)) ? ([MeasureDayKey:Timestamp] - #LastTouch#) : 0
IfCondition=MeasureBrowseIdle >= #BrowseTimeout#
IfTrueAction=#BackToToday#
Disabled=1
DynamicVariables=1
