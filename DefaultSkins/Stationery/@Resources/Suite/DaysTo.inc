; Stationery — whole local calendar days from today to a date. Original work, MIT licensed.
;
; One shared count, so every widget that counts days agrees (on 26 September 2026, New Year is 97 days away). Include
; it last in [Variables], after the widget sets its inputs; its measures then come before the widget's own.
;
; Inputs (the widget's [Variables], before the include):
;   DaysToDate    YYYY-MM-DD ("2027-3-7" works too)
;   DaysToYearly  1: the next time that month and day come round (the year is ignored); 0: that date
;   DaysToSince   YYYY-MM-DD: a one-off event's start of the wait (the day it was set); unused when yearly
; Results:
;   MeasureDaysTo       days from today: 0 today, negative once a one-off date has passed
;   MeasureDTTarget     the event's day number (Floor(Windows timestamp ÷ 86400) on the Mac's clock)
;   MeasureDTToday      today's day number
;   MeasureDTStart      the wait's first day: the previous occurrence (yearly) or DaysToSince (one-off)
;   MeasureDaysPercent  how much of the wait is behind, 0–100, rounded down
;   MeasureDTValid      1 when every date involved can be read
; A yearly 29 February counts to 1 March in common years. The measures of the other kind of event are off (so an
; unused date is never read); a change of DaysToYearly needs a refresh. TestNow (Tokens.inc) pins "today" for
; screenshots.

[Variables]
; a common year's 29 February: the year is not divisible by 4, or is a century not divisible by 400
DTCommonFeb29=^(?!\d\d(?:[02468][48]|[13579][26]|[2468]0)-|(?:[02468][048]|[13579][26])00-)(\d{4})-0?2-29$

[MeasureDTNow]
Measure=Time
TimeStamp=#TestNow#
Group=DaysTo

[MeasureDTYear]
Measure=Time
TimeStamp=#TestNow#
Format=%Y
Group=DaysTo

[MeasureDTToday]
Measure=Calc
Formula=Floor(MeasureDTNow / 86400)
Group=DaysTo

[MeasureDTYearPrev]
Measure=Calc
Formula=MeasureDTYear - 1
Group=DaysTo

[MeasureDTYearNext]
Measure=Calc
Formula=MeasureDTYear + 1
Group=DaysTo

[MeasureDTMonthDay]
; "-01-01" from "2000-01-01"
Measure=String
String=#DaysToDate#
RegExpSubstitute=1
Substitute="^\s*\d{1,4}-(\d{1,2})-(\d{1,2})\s*$":"-\1-\2"
Group=DaysTo

[MeasureDTThisText]
Measure=String
String=[MeasureDTYear][MeasureDTMonthDay]
RegExpSubstitute=1
Substitute="#DTCommonFeb29#":"\1-03-01"
DynamicVariables=1
Disabled=(1 - #DaysToYearly#)
Group=DaysTo

[MeasureDTPrevText]
Measure=String
String=[MeasureDTYearPrev:0][MeasureDTMonthDay]
RegExpSubstitute=1
Substitute="#DTCommonFeb29#":"\1-03-01"
DynamicVariables=1
Disabled=(1 - #DaysToYearly#)
Group=DaysTo

[MeasureDTNextText]
Measure=String
String=[MeasureDTYearNext:0][MeasureDTMonthDay]
RegExpSubstitute=1
Substitute="#DTCommonFeb29#":"\1-03-01"
DynamicVariables=1
Disabled=(1 - #DaysToYearly#)
Group=DaysTo

[MeasureDTThis]
Measure=Time
TimeStamp=[MeasureDTThisText]
TimeStampFormat=%Y-%m-%d
DynamicVariables=1
Disabled=(1 - #DaysToYearly#)
Group=DaysTo

[MeasureDTPrev]
Measure=Time
TimeStamp=[MeasureDTPrevText]
TimeStampFormat=%Y-%m-%d
DynamicVariables=1
Disabled=(1 - #DaysToYearly#)
Group=DaysTo

[MeasureDTNext]
Measure=Time
TimeStamp=[MeasureDTNextText]
TimeStampFormat=%Y-%m-%d
DynamicVariables=1
Disabled=(1 - #DaysToYearly#)
Group=DaysTo

[MeasureDTFixed]
Measure=Time
TimeStamp=#DaysToDate#
TimeStampFormat=%Y-%m-%d
Disabled=#DaysToYearly#
Group=DaysTo

[MeasureDTSince]
Measure=Time
TimeStamp=#DaysToSince#
TimeStampFormat=%Y-%m-%d
Disabled=#DaysToYearly#
Group=DaysTo

[MeasureDTValid]
Measure=Calc
Formula=#DaysToYearly# ? ((MeasureDTThis > 0) && (MeasureDTPrev > 0) && (MeasureDTNext > 0)) : ((MeasureDTFixed > 0) && (MeasureDTSince > 0))
Group=DaysTo

[MeasureDTTarget]
Measure=Calc
Formula=#DaysToYearly# ? ((Floor(MeasureDTThis / 86400) >= MeasureDTToday) ? Floor(MeasureDTThis / 86400) : Floor(MeasureDTNext / 86400)) : Floor(MeasureDTFixed / 86400)
Group=DaysTo

[MeasureDTStart]
Measure=Calc
Formula=#DaysToYearly# ? ((Floor(MeasureDTThis / 86400) >= MeasureDTToday) ? Floor(MeasureDTPrev / 86400) : Floor(MeasureDTThis / 86400)) : Min(Floor(MeasureDTSince / 86400), MeasureDTTarget)
Group=DaysTo

[MeasureDaysTo]
Measure=Calc
Formula=MeasureDTTarget - MeasureDTToday
Group=DaysTo

[MeasureDaysPercent]
Measure=Calc
Formula=Floor(100 * Clamp((MeasureDTToday - MeasureDTStart) / Max(MeasureDTTarget - MeasureDTStart, 1), 0, 1))
Group=DaysTo
