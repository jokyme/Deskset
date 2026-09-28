; Stationery · World Clock — the measures both sizes share. Original work, MIT licensed.
; Each city is a place (its name and its offset from here) and a time. MacSun finds the city on the Mac, in Deskset's
; own place table (never the network), and gives its offset from UTC now, daylight saving time included; the city's
; time is this Mac's clock moved by the difference. Nothing asks for a permission.
;
; Every second: this Mac's clock and the city lookups (cheap once a name is known). Once a minute, and when a city is
; found: everything else (group Cities), then the meters. A measure reads what the measures above it worked out in
; the same update, so the order below matters.
;
; City states (MeasureCityNState): 0 looking the city up, 1 found, 2 not found (still no place two seconds after the
; load: MacSun says "loading" and "not found" the same way), 3 this Mac's own zone (the first city, "Local").

[Variables]
City1Ready=0
City2Ready=0
City3Ready=0
City4Ready=0
HomeReady=0
Settled=0
; the first city is this Mac's own zone (Local, 本地 or empty); set when the widget loads
Dial1Local=1
; the time, and its ink, by the city's state
TimeText0=--:--
TimeText1=%1
TimeText2=--:--
TimeText3=%1
TimeInk0=#TertiaryTextColor#
TimeInk1=#TextColor#
TimeInk2=#TertiaryTextColor#
TimeInk3=#TextColor#
; day and night beside a city's time, by MacSun's IsDaylight there: a yellow sun, the moon in the caption's ink (the
; symbols' palettes)
DayGlyph0=moon.fill
DayGlyph1=sun.max.fill
DayPalette0=#TertiaryTextColor#
DayPalette1=#SunColor#
; the weekday shows (%1) only when the city's date is not today's here
TagDay0=%1
TagDay1=
; the tag's first word: the weekday (text-safe accent) when it shows, else AM or PM, which stays Secondary
TagDayInk0=#AccentTextColor#
TagDayInk1=#SecondaryTextColor#
; this Mac's own zone: named by the suite's place when that place keeps this Mac's time, else "Local" over "UTC+2"
HomeName0=#WorldClockLocal#
HomeName1=[MeasureHome]
HomeLine0=[MeasureLocalUTC]
HomeLine1=#WorldClockLocal#
HomeTip0=[MeasureLocalTipDay] [MeasureLocalTipTime]#WorldClockTipComma##WorldClockTipThisMac##WorldClockTipZoneOpen#[MeasureLocalZoneName]#WorldClockTipZoneClose##WorldClockTipEnd#
HomeTip1=[MeasureHome]#WorldClockTipColon#[MeasureLocalTipDay] [MeasureLocalTipTime]#WorldClockTipComma##WorldClockTipThisMac##WorldClockTipZoneOpen#[MeasureLocalZoneName]#WorldClockTipZoneClose##WorldClockTipEnd#
; city 1: its name, offset line, sentence and card entry by its state (3: this Mac's own zone)
City1Name0=#City1#
City1Name1=[MeasureCity1Place]
City1Name2=#City1#
City1Name3=[MeasureHomeName]
Offset1Text0=#Missing#
Offset1Text1=[MeasureCity1OffsetText]
Offset1Text2=#WorldClockNotFound#
Offset1Text3=[MeasureHomeLine]
City1Tip0=
City1Tip1=[MeasureCity1Name]#WorldClockTipColon#[MeasureCity1TipDay] [MeasureCity1TipTime]#WorldClockTipComma#[MeasureCity1TipOffset]#WorldClockTipEnd#
City1Tip2=#WorldClockTipNotFoundBefore#[MeasureCity1Name]#WorldClockTipNotFoundAfter#
City1Tip3=[MeasureHomeTip]
City1Card0=[MeasureCity1Name] --:--
City1Card1=[MeasureCity1Name] [MeasureCity1TipTime]
City1Card2=[MeasureCity1Name] --:--
City1Card3=[MeasureHomeName] [MeasureCity1TipTime]
; city 2: its name, offset line, sentence and card entry by its state
City2Name0=#City2#
City2Name1=[MeasureCity2Place]
City2Name2=#City2#
Offset2Text0=#Missing#
Offset2Text1=[MeasureCity2OffsetText]
Offset2Text2=#WorldClockNotFound#
City2Tip0=
City2Tip1=[MeasureCity2Name]#WorldClockTipColon#[MeasureCity2TipDay] [MeasureCity2TipTime]#WorldClockTipComma#[MeasureCity2TipOffset]#WorldClockTipEnd#
City2Tip2=#WorldClockTipNotFoundBefore#[MeasureCity2Name]#WorldClockTipNotFoundAfter#
City2Card0=[MeasureCity2Name] --:--
City2Card1=[MeasureCity2Name] [MeasureCity2TipTime]
City2Card2=[MeasureCity2Name] --:--
; city 3: its name, offset line, sentence and card entry by its state
City3Name0=#City3#
City3Name1=[MeasureCity3Place]
City3Name2=#City3#
Offset3Text0=#Missing#
Offset3Text1=[MeasureCity3OffsetText]
Offset3Text2=#WorldClockNotFound#
City3Tip0=
City3Tip1=[MeasureCity3Name]#WorldClockTipColon#[MeasureCity3TipDay] [MeasureCity3TipTime]#WorldClockTipComma#[MeasureCity3TipOffset]#WorldClockTipEnd#
City3Tip2=#WorldClockTipNotFoundBefore#[MeasureCity3Name]#WorldClockTipNotFoundAfter#
City3Card0=[MeasureCity3Name] --:--
City3Card1=[MeasureCity3Name] [MeasureCity3TipTime]
City3Card2=[MeasureCity3Name] --:--
; city 4: its name, offset line, sentence and card entry by its state
City4Name0=#City4#
City4Name1=[MeasureCity4Place]
City4Name2=#City4#
Offset4Text0=#Missing#
Offset4Text1=[MeasureCity4OffsetText]
Offset4Text2=#WorldClockNotFound#
City4Tip0=
City4Tip1=[MeasureCity4Name]#WorldClockTipColon#[MeasureCity4TipDay] [MeasureCity4TipTime]#WorldClockTipComma#[MeasureCity4TipOffset]#WorldClockTipEnd#
City4Tip2=#WorldClockTipNotFoundBefore#[MeasureCity4Name]#WorldClockTipNotFoundAfter#
City4Card0=[MeasureCity4Name] --:--
City4Card1=[MeasureCity4Name] [MeasureCity4TipTime]
City4Card2=[MeasureCity4Name] --:--
; ---------------------------------------------------------------- Edit Cities: the typed names, and the rows' looks
EditMode=0
EditLocal1=0
EditCity1=#City1#
EditChanged1=0
EditWait1=0
Edit1Ready=0
EditCity2=#City2#
EditChanged2=0
EditWait2=0
Edit2Ready=0
EditCity3=#City3#
EditChanged3=0
EditWait3=0
Edit3Ready=0
EditCity4=#City4#
EditChanged4=0
EditWait4=0
Edit4Ready=0
; a row's kind (MeasureEditNKind): 0 a saved city being looked up, 1 this Mac's zone, 2 a saved city by day, 3 by
; night, 4 a new city found (not saved yet), 5 a saved city not found, 6 a new city being looked up, 7 a new city not
; found (the saved one stays)
EditGlyph0=
EditGlyph1=location.fill
EditGlyph2=sun.max.fill
EditGlyph3=moon.fill
EditGlyph4=
EditGlyph5=exclamationmark.triangle.fill
EditGlyph6=
EditGlyph7=exclamationmark.triangle.fill
EditGlyphInk0=#SecondaryTextColor#
EditGlyphInk1=#AccentColor#
EditGlyphInk2=#SecondaryTextColor#
EditGlyphInk3=#SecondaryTextColor#
EditGlyphInk4=#SecondaryTextColor#
EditGlyphInk5=#SecondaryTextColor#
EditGlyphInk6=#SecondaryTextColor#
EditGlyphInk7=#SecondaryTextColor#
EditNameInk0=#TextColor#
EditNameInk1=#TextColor#
EditNameInk2=#TextColor#
EditNameInk3=#TextColor#
EditNameInk4=#TextColor#
EditNameInk5=#SecondaryTextColor#
EditNameInk6=#TextColor#
EditNameInk7=#SecondaryTextColor#
Edit1Name0=[MeasureEdit1Typed]
Edit1Name1=[MeasureHomeName]
Edit1Name2=[MeasureEdit1Typed]
Edit1Name3=[MeasureEdit1Typed]
Edit1Name4=[MeasureEdit1Typed]
Edit1Name5=[MeasureEdit1Typed]
Edit1Name6=[MeasureEdit1Typed]
Edit1Name7=[MeasureEdit1Typed]
; what a new name matched: its time zone ("Asia/Shanghai"), or why it is not kept
Edit1Match0=
Edit1Match1=
Edit1Match2=
Edit1Match3=
Edit1Match4=[MeasureEdit1Zone]
Edit1Match5=#WorldClockNotFound#
Edit1Match6=
Edit1Match7=#WorldClockNotFound# · #WorldClockKeepsBefore##City1##WorldClockKeepsAfter#
Edit2Name0=[MeasureEdit2Typed]
Edit2Name1=[MeasureHomeName]
Edit2Name2=[MeasureEdit2Typed]
Edit2Name3=[MeasureEdit2Typed]
Edit2Name4=[MeasureEdit2Typed]
Edit2Name5=[MeasureEdit2Typed]
Edit2Name6=[MeasureEdit2Typed]
Edit2Name7=[MeasureEdit2Typed]
; what a new name matched: its time zone ("Asia/Shanghai"), or why it is not kept
Edit2Match0=
Edit2Match1=
Edit2Match2=
Edit2Match3=
Edit2Match4=[MeasureEdit2Zone]
Edit2Match5=#WorldClockNotFound#
Edit2Match6=
Edit2Match7=#WorldClockNotFound# · #WorldClockKeepsBefore##City2##WorldClockKeepsAfter#
Edit3Name0=[MeasureEdit3Typed]
Edit3Name1=[MeasureHomeName]
Edit3Name2=[MeasureEdit3Typed]
Edit3Name3=[MeasureEdit3Typed]
Edit3Name4=[MeasureEdit3Typed]
Edit3Name5=[MeasureEdit3Typed]
Edit3Name6=[MeasureEdit3Typed]
Edit3Name7=[MeasureEdit3Typed]
; what a new name matched: its time zone ("Asia/Shanghai"), or why it is not kept
Edit3Match0=
Edit3Match1=
Edit3Match2=
Edit3Match3=
Edit3Match4=[MeasureEdit3Zone]
Edit3Match5=#WorldClockNotFound#
Edit3Match6=
Edit3Match7=#WorldClockNotFound# · #WorldClockKeepsBefore##City3##WorldClockKeepsAfter#
Edit4Name0=[MeasureEdit4Typed]
Edit4Name1=[MeasureHomeName]
Edit4Name2=[MeasureEdit4Typed]
Edit4Name3=[MeasureEdit4Typed]
Edit4Name4=[MeasureEdit4Typed]
Edit4Name5=[MeasureEdit4Typed]
Edit4Name6=[MeasureEdit4Typed]
Edit4Name7=[MeasureEdit4Typed]
; what a new name matched: its time zone ("Asia/Shanghai"), or why it is not kept
Edit4Match0=
Edit4Match1=
Edit4Match2=
Edit4Match3=
Edit4Match4=[MeasureEdit4Zone]
Edit4Match5=#WorldClockNotFound#
Edit4Match6=
Edit4Match7=#WorldClockNotFound# · #WorldClockKeepsBefore##City4##WorldClockKeepsAfter#

; ---------------------------------------------------------------- this Mac's time
[MeasureLocalTime]
; seconds since 1601 on this Mac's clock (wall time)
Measure=Time
TimeStamp=#TestNow#

[MeasureMinute]
; the minute's work: every city, then the meters
Measure=Calc
Formula=Floor(MeasureLocalTime / 60)
OnChangeAction=[!UpdateMeasureGroup Cities][!UpdateMeterGroup CitiesFirst][!UpdateMeterGroup Cities][!UpdateMeasureGroup Edit][!UpdateMeterGroup EditFirst][!UpdateMeterGroup Edit][!Redraw]

[MeasureLoadTimer]
; two seconds after the load, a city still without a place is not found (not earlier, so nothing flickers while the
; place table loads)
Measure=Calc
Formula=Min(MeasureLoadTimer + 1, 3)
IfCondition=MeasureLoadTimer = 2
IfTrueAction=[!SetVariable Settled 1][!UpdateMeasureGroup Cities][!UpdateMeterGroup CitiesFirst][!UpdateMeterGroup Cities][!UpdateMeasure MeasureSeed][!Redraw]

[MeasureLocalZone]
; this Mac's offset from UTC now, in hours (daylight saving time included); its string is the zone's name. The
; coordinate is only there because MacSun needs one: TimeZone=Local makes the zone this Mac's
Measure=Plugin
Plugin=MacSun
Location=0,0
TimeZone=Local
Type=TimeZone
Group=Cities
UpdateDivider=-1

[MeasureLocalHour]
Measure=Calc
Formula=Floor((MeasureLocalTime % 86400) / 3600)
Group=Cities
UpdateDivider=-1

[MeasureLocalTipDay]
Measure=Time
TimeStamp=#TestNow#
Format=#WorldClockTipDayFormat#
FormatLocale=#Locale#
Group=Cities
UpdateDivider=-1

[MeasureLocalTipTime]
; "10:09" or "10:09 AM"
Measure=Time
TimeStamp=#TestNow#
Format=[#CaptionTime[#Hours]]
FormatLocale=#Locale#
Group=Cities
UpdateDivider=-1

[MeasureLocalZoneName]
; the zone's name in this Mac's language ("Central European Summer Time")
Measure=Time
TimeStamp=#TestNow#
Format=%Z
Group=Cities
UpdateDivider=-1

[MeasureLocalUTC]
; "+0200" → "UTC+2", "+0530" → "UTC+5:30", "-0330" → "UTC−3:30", "+0000" → "UTC"
Measure=Time
TimeStamp=#TestNow#
Format=%z
RegExpSubstitute=1
Substitute="^\+0000$":"UTC","^([+-])0?(\d{1,2})00$":"UTC\1\2","^([+-])0?(\d{1,2})(\d\d)$":"UTC\1\2:\3","-":"−"
Group=Cities
UpdateDivider=-1

; ---------------------------------------------------------------- the suite's place: it names this Mac's own dial
[MeasureHome]
; the suite's Location (by default the city of this Mac's time zone)
Measure=Plugin
Plugin=MacSun
Location=#Location#
Type=Place
UnavailableText=
IfMatch=.
IfMatchAction=[!SetVariable HomeReady 1][!UpdateMeasureGroup Cities][!UpdateMeterGroup CitiesFirst][!UpdateMeterGroup Cities][!Redraw]
IfNotMatchAction=[!SetVariable HomeReady 0][!UpdateMeasureGroup Cities][!UpdateMeterGroup CitiesFirst][!UpdateMeterGroup Cities][!Redraw]

[MeasureHomeZone]
Measure=Plugin
Plugin=MacSun
Parent=MeasureHome
Type=TimeZone
Group=Cities
UpdateDivider=-1

[MeasureHomeDay]
Measure=Plugin
Plugin=MacSun
Parent=MeasureHome
Type=IsDaylight
Group=Cities
UpdateDivider=-1

[MeasureHomeHere]
; 1 when the place is found and keeps this Mac's time
Measure=Calc
Formula=(#HomeReady# = 1) && (Abs(MeasureHomeZone - MeasureLocalZone) < 0.01)
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureHomeName]
; "Oslo", or "Local" without a place in this zone
Measure=String
String=[#HomeName[&MeasureHomeHere:0]]
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureHomeLine]
; the line under it: "Local", or the zone's offset ("UTC+2")
Measure=String
String=[#HomeLine[&MeasureHomeHere:0]]
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureHomeTip]
Measure=String
String=[#HomeTip[&MeasureHomeHere:0]]
DynamicVariables=1
Group=Cities
UpdateDivider=-1

; ---------------------------------------------------------------- the first city: this Mac's own zone, or a city
[MeasureCity1IsLocal]
; "Local", 本地 or nothing: the first dial is this Mac's time. Else it is a city like the others
Measure=String
String=#City1#
IfMatch=(?i)^\s*(local|本地)?\s*$
IfMatchAction=[!SetVariable Dial1Local 1]
IfNotMatchAction=[!SetVariable Dial1Local 0][!EnableMeasure MeasureCity1Place][!EnableMeasure MeasureCity1Zone][!EnableMeasure MeasureCity1Day]
UpdateDivider=-1

; ---------------------------------------------------------------- city 1
[MeasureCity1Place]
; looked up only when the first city is not this Mac's own zone
; the city as found ("New York": MacSun keeps the spelling it was given when that is another name of the place);
; empty while it is looked up or when it is not found. Every second: cheap once the name is known, and it notices
; the place arriving
Measure=Plugin
Plugin=MacSun
Location=#City1#
Type=Place
UnavailableText=
IfMatch=.
IfMatchAction=[!SetVariable City1Ready 1][!UpdateMeasureGroup Cities][!UpdateMeterGroup CitiesFirst][!UpdateMeterGroup Cities][!Redraw]
IfNotMatchAction=[!SetVariable City1Ready 0][!UpdateMeasureGroup Cities][!UpdateMeterGroup CitiesFirst][!UpdateMeterGroup Cities][!Redraw]
Disabled=1

[MeasureCity1Zone]
; its offset from UTC now, in hours (0 while it is looked up); its string is the zone's name
Measure=Plugin
Plugin=MacSun
Parent=MeasureCity1Place
Type=TimeZone
Group=Cities
UpdateDivider=-1
Disabled=1

[MeasureCity1Day]
; 1 while the sun is up there
Measure=Plugin
Plugin=MacSun
Parent=MeasureCity1Place
Type=IsDaylight
Group=Cities
UpdateDivider=-1
Disabled=1

[MeasureCity1State]
Measure=Calc
Formula=(#Dial1Local# = 1) ? 3 : ((#City1Ready# = 1) ? 1 : ((#Settled# = 1) ? 2 : 0))
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity1Name]
Measure=String
String=[#City1Name[&MeasureCity1State:0]]
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity1Offset]
; hours from here, in quarters (every real offset is a multiple of 15 minutes): −1, 7, 3.5, 5.75
Measure=Calc
Formula=(#Dial1Local# = 1) ? 0 : (Round((MeasureCity1Zone - MeasureLocalZone) * 4) / 4)
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity1Wall]
; the city's wall-clock time, in seconds since 1601
Measure=Calc
Formula=Floor(MeasureLocalTime) + MeasureCity1Offset * 3600
Group=Cities
UpdateDivider=-1

[MeasureCity1Time]
; "04:09", or "4:09" in 12-hour time (AM and PM go elsewhere)
Measure=Time
TimeStamp=[MeasureCity1Wall]
Format=[#TimeFormat[#Hours]]
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity1AMPM]
Measure=Time
TimeStamp=[MeasureCity1Wall]
Format=%p
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity1Weekday]
; "Sun" (周日); the meters set it in capitals
Measure=Time
TimeStamp=[MeasureCity1Wall]
Format=%a
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity1SameDay]
; 1 when the city's date is today's here
Measure=Calc
Formula=Floor(MeasureCity1Wall / 86400) = Floor(Floor(MeasureLocalTime) / 86400)
Group=Cities
UpdateDivider=-1

[MeasureCity1Face]
; the dial's face: 0 night, 1 day, 2 still looked up or not found
Measure=Calc
Formula=(MeasureCity1State = 3) ? ((MeasureHomeHere = 1) ? MeasureHomeDay : ((MeasureLocalHour >= 6) && (MeasureLocalHour < 18))) : ((MeasureCity1State = 1) ? MeasureCity1Day : 2)
Group=Cities
UpdateDivider=-1

[MeasureCity1OffsetH]
Measure=Calc
Formula=Trunc(Abs(MeasureCity1Offset))
Group=Cities
UpdateDivider=-1

[MeasureCity1OffsetM]
Measure=Calc
Formula=Round((Abs(MeasureCity1Offset) - MeasureCity1OffsetH) * 60)
Group=Cities
UpdateDivider=-1

[MeasureCity1OffsetSign]
Measure=Calc
Formula=(MeasureCity1Offset < 0) ? 0 : 1
Group=Cities
UpdateDivider=-1

[MeasureCity1OffsetText]
; "+7 h", "−3 h 30 min", "+30 min", "+0 h"
Measure=String
String=[#WorldClockSign[&MeasureCity1OffsetSign:0]][MeasureCity1OffsetH:0][#WorldClockHour][#WorldClockMin[&MeasureCity1OffsetM:0]]
RegExpSubstitute=1
Substitute="#WorldClockZeroHour#":"\1\2"
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity1HourAngle]
Measure=Calc
Formula=(MeasureCity1Wall % 43200) / 120
Group=Cities
UpdateDivider=-1

[MeasureCity1MinuteAngle]
Measure=Calc
Formula=(MeasureCity1Wall % 3600) / 10
Group=Cities
UpdateDivider=-1

[MeasureCity1TipDay]
Measure=Time
TimeStamp=[MeasureCity1Wall]
Format=#WorldClockTipDayFormat#
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity1TipTime]
Measure=Time
TimeStamp=[MeasureCity1Wall]
Format=[#CaptionTime[#Hours]]
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity1TipKind]
; behind (0), ahead (1), the same time (2)
Measure=Calc
Formula=(MeasureCity1Offset > 0) ? 1 : ((MeasureCity1Offset < 0) ? 0 : 2)
Group=Cities
UpdateDivider=-1

[MeasureCity1TipPlural]
Measure=Calc
Formula=MeasureCity1OffsetH = 1
Group=Cities
UpdateDivider=-1

[MeasureCity1TipOffset]
; "7 hours ahead", "3 hours 30 minutes behind", "30 minutes ahead", "same time"
Measure=String
String=[#WorldClockTipBefore[&MeasureCity1TipKind:0]][MeasureCity1OffsetH:0] [#WorldClockTipHours[&MeasureCity1TipPlural:0]][#WorldClockTipMin[&MeasureCity1OffsetM:0]][#WorldClockTipAfter[&MeasureCity1TipKind:0]]
RegExpSubstitute=1
Substitute="(^|\s)0 \S+( |$)":"\1","\s+$":""
DynamicVariables=1
Group=Cities
UpdateDivider=-1

; ---------------------------------------------------------------- city 2
[MeasureCity2Place]
; the city as found ("New York": MacSun keeps the spelling it was given when that is another name of the place);
; empty while it is looked up or when it is not found. Every second: cheap once the name is known, and it notices
; the place arriving
Measure=Plugin
Plugin=MacSun
Location=#City2#
Type=Place
UnavailableText=
IfMatch=.
IfMatchAction=[!SetVariable City2Ready 1][!UpdateMeasureGroup Cities][!UpdateMeterGroup CitiesFirst][!UpdateMeterGroup Cities][!Redraw]
IfNotMatchAction=[!SetVariable City2Ready 0][!UpdateMeasureGroup Cities][!UpdateMeterGroup CitiesFirst][!UpdateMeterGroup Cities][!Redraw]

[MeasureCity2Zone]
; its offset from UTC now, in hours (0 while it is looked up); its string is the zone's name
Measure=Plugin
Plugin=MacSun
Parent=MeasureCity2Place
Type=TimeZone
Group=Cities
UpdateDivider=-1

[MeasureCity2Day]
; 1 while the sun is up there
Measure=Plugin
Plugin=MacSun
Parent=MeasureCity2Place
Type=IsDaylight
Group=Cities
UpdateDivider=-1

[MeasureCity2State]
Measure=Calc
Formula=(#City2Ready# = 1) ? 1 : ((#Settled# = 1) ? 2 : 0)
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity2Name]
Measure=String
String=[#City2Name[&MeasureCity2State:0]]
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity2Offset]
; hours from here, in quarters (every real offset is a multiple of 15 minutes): −1, 7, 3.5, 5.75
Measure=Calc
Formula=Round((MeasureCity2Zone - MeasureLocalZone) * 4) / 4
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity2Wall]
; the city's wall-clock time, in seconds since 1601
Measure=Calc
Formula=Floor(MeasureLocalTime) + MeasureCity2Offset * 3600
Group=Cities
UpdateDivider=-1

[MeasureCity2Time]
; "04:09", or "4:09" in 12-hour time (AM and PM go elsewhere)
Measure=Time
TimeStamp=[MeasureCity2Wall]
Format=[#TimeFormat[#Hours]]
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity2AMPM]
Measure=Time
TimeStamp=[MeasureCity2Wall]
Format=%p
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity2Weekday]
; "Sun" (周日); the meters set it in capitals
Measure=Time
TimeStamp=[MeasureCity2Wall]
Format=%a
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity2SameDay]
; 1 when the city's date is today's here
Measure=Calc
Formula=Floor(MeasureCity2Wall / 86400) = Floor(Floor(MeasureLocalTime) / 86400)
Group=Cities
UpdateDivider=-1

[MeasureCity2Face]
; the dial's face: 0 night, 1 day, 2 still looked up or not found
Measure=Calc
Formula=(MeasureCity2State = 1) ? MeasureCity2Day : 2
Group=Cities
UpdateDivider=-1

[MeasureCity2OffsetH]
Measure=Calc
Formula=Trunc(Abs(MeasureCity2Offset))
Group=Cities
UpdateDivider=-1

[MeasureCity2OffsetM]
Measure=Calc
Formula=Round((Abs(MeasureCity2Offset) - MeasureCity2OffsetH) * 60)
Group=Cities
UpdateDivider=-1

[MeasureCity2OffsetSign]
Measure=Calc
Formula=(MeasureCity2Offset < 0) ? 0 : 1
Group=Cities
UpdateDivider=-1

[MeasureCity2OffsetText]
; "+7 h", "−3 h 30 min", "+30 min", "+0 h"
Measure=String
String=[#WorldClockSign[&MeasureCity2OffsetSign:0]][MeasureCity2OffsetH:0][#WorldClockHour][#WorldClockMin[&MeasureCity2OffsetM:0]]
RegExpSubstitute=1
Substitute="#WorldClockZeroHour#":"\1\2"
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity2HourAngle]
Measure=Calc
Formula=(MeasureCity2Wall % 43200) / 120
Group=Cities
UpdateDivider=-1

[MeasureCity2MinuteAngle]
Measure=Calc
Formula=(MeasureCity2Wall % 3600) / 10
Group=Cities
UpdateDivider=-1

[MeasureCity2TipDay]
Measure=Time
TimeStamp=[MeasureCity2Wall]
Format=#WorldClockTipDayFormat#
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity2TipTime]
Measure=Time
TimeStamp=[MeasureCity2Wall]
Format=[#CaptionTime[#Hours]]
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity2TipKind]
; behind (0), ahead (1), the same time (2)
Measure=Calc
Formula=(MeasureCity2Offset > 0) ? 1 : ((MeasureCity2Offset < 0) ? 0 : 2)
Group=Cities
UpdateDivider=-1

[MeasureCity2TipPlural]
Measure=Calc
Formula=MeasureCity2OffsetH = 1
Group=Cities
UpdateDivider=-1

[MeasureCity2TipOffset]
; "7 hours ahead", "3 hours 30 minutes behind", "30 minutes ahead", "same time"
Measure=String
String=[#WorldClockTipBefore[&MeasureCity2TipKind:0]][MeasureCity2OffsetH:0] [#WorldClockTipHours[&MeasureCity2TipPlural:0]][#WorldClockTipMin[&MeasureCity2OffsetM:0]][#WorldClockTipAfter[&MeasureCity2TipKind:0]]
RegExpSubstitute=1
Substitute="(^|\s)0 \S+( |$)":"\1","\s+$":""
DynamicVariables=1
Group=Cities
UpdateDivider=-1

; ---------------------------------------------------------------- city 3
[MeasureCity3Place]
; the city as found ("New York": MacSun keeps the spelling it was given when that is another name of the place);
; empty while it is looked up or when it is not found. Every second: cheap once the name is known, and it notices
; the place arriving
Measure=Plugin
Plugin=MacSun
Location=#City3#
Type=Place
UnavailableText=
IfMatch=.
IfMatchAction=[!SetVariable City3Ready 1][!UpdateMeasureGroup Cities][!UpdateMeterGroup CitiesFirst][!UpdateMeterGroup Cities][!Redraw]
IfNotMatchAction=[!SetVariable City3Ready 0][!UpdateMeasureGroup Cities][!UpdateMeterGroup CitiesFirst][!UpdateMeterGroup Cities][!Redraw]

[MeasureCity3Zone]
; its offset from UTC now, in hours (0 while it is looked up); its string is the zone's name
Measure=Plugin
Plugin=MacSun
Parent=MeasureCity3Place
Type=TimeZone
Group=Cities
UpdateDivider=-1

[MeasureCity3Day]
; 1 while the sun is up there
Measure=Plugin
Plugin=MacSun
Parent=MeasureCity3Place
Type=IsDaylight
Group=Cities
UpdateDivider=-1

[MeasureCity3State]
Measure=Calc
Formula=(#City3Ready# = 1) ? 1 : ((#Settled# = 1) ? 2 : 0)
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity3Name]
Measure=String
String=[#City3Name[&MeasureCity3State:0]]
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity3Offset]
; hours from here, in quarters (every real offset is a multiple of 15 minutes): −1, 7, 3.5, 5.75
Measure=Calc
Formula=Round((MeasureCity3Zone - MeasureLocalZone) * 4) / 4
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity3Wall]
; the city's wall-clock time, in seconds since 1601
Measure=Calc
Formula=Floor(MeasureLocalTime) + MeasureCity3Offset * 3600
Group=Cities
UpdateDivider=-1

[MeasureCity3Time]
; "04:09", or "4:09" in 12-hour time (AM and PM go elsewhere)
Measure=Time
TimeStamp=[MeasureCity3Wall]
Format=[#TimeFormat[#Hours]]
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity3AMPM]
Measure=Time
TimeStamp=[MeasureCity3Wall]
Format=%p
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity3Weekday]
; "Sun" (周日); the meters set it in capitals
Measure=Time
TimeStamp=[MeasureCity3Wall]
Format=%a
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity3SameDay]
; 1 when the city's date is today's here
Measure=Calc
Formula=Floor(MeasureCity3Wall / 86400) = Floor(Floor(MeasureLocalTime) / 86400)
Group=Cities
UpdateDivider=-1

[MeasureCity3Face]
; the dial's face: 0 night, 1 day, 2 still looked up or not found
Measure=Calc
Formula=(MeasureCity3State = 1) ? MeasureCity3Day : 2
Group=Cities
UpdateDivider=-1

[MeasureCity3OffsetH]
Measure=Calc
Formula=Trunc(Abs(MeasureCity3Offset))
Group=Cities
UpdateDivider=-1

[MeasureCity3OffsetM]
Measure=Calc
Formula=Round((Abs(MeasureCity3Offset) - MeasureCity3OffsetH) * 60)
Group=Cities
UpdateDivider=-1

[MeasureCity3OffsetSign]
Measure=Calc
Formula=(MeasureCity3Offset < 0) ? 0 : 1
Group=Cities
UpdateDivider=-1

[MeasureCity3OffsetText]
; "+7 h", "−3 h 30 min", "+30 min", "+0 h"
Measure=String
String=[#WorldClockSign[&MeasureCity3OffsetSign:0]][MeasureCity3OffsetH:0][#WorldClockHour][#WorldClockMin[&MeasureCity3OffsetM:0]]
RegExpSubstitute=1
Substitute="#WorldClockZeroHour#":"\1\2"
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity3HourAngle]
Measure=Calc
Formula=(MeasureCity3Wall % 43200) / 120
Group=Cities
UpdateDivider=-1

[MeasureCity3MinuteAngle]
Measure=Calc
Formula=(MeasureCity3Wall % 3600) / 10
Group=Cities
UpdateDivider=-1

[MeasureCity3TipDay]
Measure=Time
TimeStamp=[MeasureCity3Wall]
Format=#WorldClockTipDayFormat#
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity3TipTime]
Measure=Time
TimeStamp=[MeasureCity3Wall]
Format=[#CaptionTime[#Hours]]
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity3TipKind]
; behind (0), ahead (1), the same time (2)
Measure=Calc
Formula=(MeasureCity3Offset > 0) ? 1 : ((MeasureCity3Offset < 0) ? 0 : 2)
Group=Cities
UpdateDivider=-1

[MeasureCity3TipPlural]
Measure=Calc
Formula=MeasureCity3OffsetH = 1
Group=Cities
UpdateDivider=-1

[MeasureCity3TipOffset]
; "7 hours ahead", "3 hours 30 minutes behind", "30 minutes ahead", "same time"
Measure=String
String=[#WorldClockTipBefore[&MeasureCity3TipKind:0]][MeasureCity3OffsetH:0] [#WorldClockTipHours[&MeasureCity3TipPlural:0]][#WorldClockTipMin[&MeasureCity3OffsetM:0]][#WorldClockTipAfter[&MeasureCity3TipKind:0]]
RegExpSubstitute=1
Substitute="(^|\s)0 \S+( |$)":"\1","\s+$":""
DynamicVariables=1
Group=Cities
UpdateDivider=-1

; ---------------------------------------------------------------- city 4
[MeasureCity4Place]
; the city as found ("New York": MacSun keeps the spelling it was given when that is another name of the place);
; empty while it is looked up or when it is not found. Every second: cheap once the name is known, and it notices
; the place arriving
Measure=Plugin
Plugin=MacSun
Location=#City4#
Type=Place
UnavailableText=
IfMatch=.
IfMatchAction=[!SetVariable City4Ready 1][!UpdateMeasureGroup Cities][!UpdateMeterGroup CitiesFirst][!UpdateMeterGroup Cities][!Redraw]
IfNotMatchAction=[!SetVariable City4Ready 0][!UpdateMeasureGroup Cities][!UpdateMeterGroup CitiesFirst][!UpdateMeterGroup Cities][!Redraw]

[MeasureCity4Zone]
; its offset from UTC now, in hours (0 while it is looked up); its string is the zone's name
Measure=Plugin
Plugin=MacSun
Parent=MeasureCity4Place
Type=TimeZone
Group=Cities
UpdateDivider=-1

[MeasureCity4Day]
; 1 while the sun is up there
Measure=Plugin
Plugin=MacSun
Parent=MeasureCity4Place
Type=IsDaylight
Group=Cities
UpdateDivider=-1

[MeasureCity4State]
Measure=Calc
Formula=(#City4Ready# = 1) ? 1 : ((#Settled# = 1) ? 2 : 0)
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity4Name]
Measure=String
String=[#City4Name[&MeasureCity4State:0]]
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity4Offset]
; hours from here, in quarters (every real offset is a multiple of 15 minutes): −1, 7, 3.5, 5.75
Measure=Calc
Formula=Round((MeasureCity4Zone - MeasureLocalZone) * 4) / 4
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity4Wall]
; the city's wall-clock time, in seconds since 1601
Measure=Calc
Formula=Floor(MeasureLocalTime) + MeasureCity4Offset * 3600
Group=Cities
UpdateDivider=-1

[MeasureCity4Time]
; "04:09", or "4:09" in 12-hour time (AM and PM go elsewhere)
Measure=Time
TimeStamp=[MeasureCity4Wall]
Format=[#TimeFormat[#Hours]]
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity4AMPM]
Measure=Time
TimeStamp=[MeasureCity4Wall]
Format=%p
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity4Weekday]
; "Sun" (周日); the meters set it in capitals
Measure=Time
TimeStamp=[MeasureCity4Wall]
Format=%a
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity4SameDay]
; 1 when the city's date is today's here
Measure=Calc
Formula=Floor(MeasureCity4Wall / 86400) = Floor(Floor(MeasureLocalTime) / 86400)
Group=Cities
UpdateDivider=-1

[MeasureCity4Face]
; the dial's face: 0 night, 1 day, 2 still looked up or not found
Measure=Calc
Formula=(MeasureCity4State = 1) ? MeasureCity4Day : 2
Group=Cities
UpdateDivider=-1

[MeasureCity4OffsetH]
Measure=Calc
Formula=Trunc(Abs(MeasureCity4Offset))
Group=Cities
UpdateDivider=-1

[MeasureCity4OffsetM]
Measure=Calc
Formula=Round((Abs(MeasureCity4Offset) - MeasureCity4OffsetH) * 60)
Group=Cities
UpdateDivider=-1

[MeasureCity4OffsetSign]
Measure=Calc
Formula=(MeasureCity4Offset < 0) ? 0 : 1
Group=Cities
UpdateDivider=-1

[MeasureCity4OffsetText]
; "+7 h", "−3 h 30 min", "+30 min", "+0 h"
Measure=String
String=[#WorldClockSign[&MeasureCity4OffsetSign:0]][MeasureCity4OffsetH:0][#WorldClockHour][#WorldClockMin[&MeasureCity4OffsetM:0]]
RegExpSubstitute=1
Substitute="#WorldClockZeroHour#":"\1\2"
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity4HourAngle]
Measure=Calc
Formula=(MeasureCity4Wall % 43200) / 120
Group=Cities
UpdateDivider=-1

[MeasureCity4MinuteAngle]
Measure=Calc
Formula=(MeasureCity4Wall % 3600) / 10
Group=Cities
UpdateDivider=-1

[MeasureCity4TipDay]
Measure=Time
TimeStamp=[MeasureCity4Wall]
Format=#WorldClockTipDayFormat#
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity4TipTime]
Measure=Time
TimeStamp=[MeasureCity4Wall]
Format=[#CaptionTime[#Hours]]
FormatLocale=#Locale#
DynamicVariables=1
Group=Cities
UpdateDivider=-1

[MeasureCity4TipKind]
; behind (0), ahead (1), the same time (2)
Measure=Calc
Formula=(MeasureCity4Offset > 0) ? 1 : ((MeasureCity4Offset < 0) ? 0 : 2)
Group=Cities
UpdateDivider=-1

[MeasureCity4TipPlural]
Measure=Calc
Formula=MeasureCity4OffsetH = 1
Group=Cities
UpdateDivider=-1

[MeasureCity4TipOffset]
; "7 hours ahead", "3 hours 30 minutes behind", "30 minutes ahead", "same time"
Measure=String
String=[#WorldClockTipBefore[&MeasureCity4TipKind:0]][MeasureCity4OffsetH:0] [#WorldClockTipHours[&MeasureCity4TipPlural:0]][#WorldClockTipMin[&MeasureCity4OffsetM:0]][#WorldClockTipAfter[&MeasureCity4TipKind:0]]
RegExpSubstitute=1
Substitute="(^|\s)0 \S+( |$)":"\1","\s+$":""
DynamicVariables=1
Group=Cities
UpdateDivider=-1

; ---------------------------------------------------------------- the first run
; a default city (London, New York, Tokyo) in this Mac's own zone gives way to Sydney; checked once, two seconds after
; the first load
[MeasureSeed]
Measure=Calc
Formula=(#WorldClockSeeded# = 0) && (#Settled# = 1)
IfCondition=MeasureSeed = 1
IfTrueAction=[!EnableMeasure MeasureSeed2][!EnableMeasure MeasureSeed3][!EnableMeasure MeasureSeed4][!UpdateMeasure MeasureSeed2][!UpdateMeasure MeasureSeed3][!UpdateMeasure MeasureSeed4][!WriteKeyValue Variables WorldClockSeeded 1 "#StationeryFile#"][!SetVariable WorldClockSeeded 1]
DynamicVariables=1
UpdateDivider=-1

[MeasureSeed2]
; the city's zone and this Mac's, side by side
Measure=String
String=[MeasureCity2Zone]|[MeasureLocalZone]
IfMatch=^(.+)\|\1$
IfMatchAction=[!WriteKeyValue Variables City2 Sydney "#StationeryFile#"][!SetVariable City2 Sydney][!SetVariable EditCity2 Sydney][!SetOption MeasureCity2Place Location Sydney][!UpdateMeasure MeasureCity2Place][!UpdateMeasureGroup Cities][!UpdateMeterGroup CitiesFirst][!UpdateMeterGroup Cities][!Redraw]
DynamicVariables=1
Disabled=1
UpdateDivider=-1

[MeasureSeed3]
; the city's zone and this Mac's, side by side
Measure=String
String=[MeasureCity3Zone]|[MeasureLocalZone]
IfMatch=^(.+)\|\1$
IfMatchAction=[!WriteKeyValue Variables City3 Sydney "#StationeryFile#"][!SetVariable City3 Sydney][!SetVariable EditCity3 Sydney][!SetOption MeasureCity3Place Location Sydney][!UpdateMeasure MeasureCity3Place][!UpdateMeasureGroup Cities][!UpdateMeterGroup CitiesFirst][!UpdateMeterGroup Cities][!Redraw]
DynamicVariables=1
Disabled=1
UpdateDivider=-1

[MeasureSeed4]
; the city's zone and this Mac's, side by side
Measure=String
String=[MeasureCity4Zone]|[MeasureLocalZone]
IfMatch=^(.+)\|\1$
IfMatchAction=[!WriteKeyValue Variables City4 Sydney "#StationeryFile#"][!SetVariable City4 Sydney][!SetVariable EditCity4 Sydney][!SetOption MeasureCity4Place Location Sydney][!UpdateMeasure MeasureCity4Place][!UpdateMeasureGroup Cities][!UpdateMeterGroup CitiesFirst][!UpdateMeterGroup Cities][!Redraw]
DynamicVariables=1
Disabled=1
UpdateDivider=-1

; ---------------------------------------------------------------- Edit Cities (off until the menu item turns it on)
; Each row looks its typed name up as it is typed, and nothing is written until Done. The first row's name is this
; Mac's own zone when it says so.
[MeasureEdit1IsLocal]
Measure=String
String=[#EditCity1]
IfMatch=(?i)^\s*(local|本地)?\s*$
IfMatchAction=[!SetVariable EditLocal1 1][!DisableMeasureGroup EditLookup1][!UpdateMeasureGroup Edit][!UpdateMeterGroup EditFirst][!UpdateMeterGroup Edit][!Redraw]
IfNotMatchAction=[!SetVariable EditLocal1 0][!EnableMeasureGroup EditLookup1][!UpdateMeasureGroup EditLookup1][!UpdateMeasureGroup Edit][!UpdateMeterGroup EditFirst][!UpdateMeterGroup Edit][!Redraw]
DynamicVariables=1
Disabled=1
Group=Edit

; ---------------------------------------------------------------- row 1
[MeasureEdit1Typed]
Measure=String
String=[#EditCity1]
DynamicVariables=1
Disabled=1
Group=Edit

[MeasureEdit1Place]
Measure=Plugin
Plugin=MacSun
Location=[#EditCity1]
Type=Place
UnavailableText=
IfMatch=.
IfMatchAction=[!SetVariable Edit1Ready 1][!UpdateMeasureGroup Edit][!UpdateMeterGroup EditFirst][!UpdateMeterGroup Edit][!Redraw]
IfNotMatchAction=[!SetVariable Edit1Ready 0][!UpdateMeasureGroup Edit][!UpdateMeterGroup EditFirst][!UpdateMeterGroup Edit][!Redraw]
DynamicVariables=1
Disabled=1
Group=EditLookup1

[MeasureEdit1Zone]
Measure=Plugin
Plugin=MacSun
Parent=MeasureEdit1Place
Type=TimeZone
UnavailableText=
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit1Day]
Measure=Plugin
Plugin=MacSun
Parent=MeasureEdit1Place
Type=IsDaylight
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit1Kind]
Measure=Calc
Formula=(#EditLocal1# = 1) ? 1 : ((#Edit1Ready# = 1) ? ((#EditChanged1# = 1) ? 4 : (3 - MeasureEdit1Day)) : (((#EditWait1# = 1) || (#Settled# = 0)) ? ((#EditChanged1# = 1) ? 6 : 0) : ((#EditChanged1# = 1) ? 7 : 5)))
DynamicVariables=1
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit1Offset]
Measure=Calc
Formula=Round((MeasureEdit1Zone - MeasureLocalZone) * 4) / 4
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit1OffsetH]
Measure=Calc
Formula=Trunc(Abs(MeasureEdit1Offset))
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit1OffsetM]
Measure=Calc
Formula=Round((Abs(MeasureEdit1Offset) - MeasureEdit1OffsetH) * 60)
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit1OffsetSign]
Measure=Calc
Formula=(MeasureEdit1Offset < 0) ? 0 : 1
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit1OffsetText]
Measure=String
String=[#WorldClockSign[&MeasureEdit1OffsetSign:0]][MeasureEdit1OffsetH:0][#WorldClockHour][#WorldClockMin[&MeasureEdit1OffsetM:0]]
RegExpSubstitute=1
Substitute="#WorldClockZeroHour#":"\1\2"
DynamicVariables=1
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit1Wall]
Measure=Calc
Formula=Floor(MeasureLocalTime) + MeasureEdit1Offset * 3600
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit1Time]
Measure=Time
TimeStamp=[MeasureEdit1Wall]
Format=[#CaptionTime[#Hours]]
FormatLocale=#Locale#
DynamicVariables=1
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureSave1]
; Done: a new city that was found is written; "Local" in the first row brings back this Mac's own zone; a name that
; was not found is never written, so the saved city stays
Measure=Calc
Formula=(#EditChanged1# = 1) ? ((#EditLocal1# = 1) ? 2 : (#Edit1Ready# = 1)) : 0
IfConditionMode=1
IfCondition=MeasureSave1 = 1
IfTrueAction=[!WriteKeyValue Variables City1 "[#EditCity1]" "#StationeryFile#"]
IfCondition2=MeasureSave1 = 2
IfTrueAction2=[!WriteKeyValue Variables City1 Local "#StationeryFile#"]
DynamicVariables=1
Disabled=1
UpdateDivider=-1

; ---------------------------------------------------------------- row 2
[MeasureEdit2Typed]
Measure=String
String=[#EditCity2]
DynamicVariables=1
Disabled=1
Group=Edit

[MeasureEdit2Place]
Measure=Plugin
Plugin=MacSun
Location=[#EditCity2]
Type=Place
UnavailableText=
IfMatch=.
IfMatchAction=[!SetVariable Edit2Ready 1][!UpdateMeasureGroup Edit][!UpdateMeterGroup EditFirst][!UpdateMeterGroup Edit][!Redraw]
IfNotMatchAction=[!SetVariable Edit2Ready 0][!UpdateMeasureGroup Edit][!UpdateMeterGroup EditFirst][!UpdateMeterGroup Edit][!Redraw]
DynamicVariables=1
Disabled=1
Group=EditLookup

[MeasureEdit2Zone]
Measure=Plugin
Plugin=MacSun
Parent=MeasureEdit2Place
Type=TimeZone
UnavailableText=
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit2Day]
Measure=Plugin
Plugin=MacSun
Parent=MeasureEdit2Place
Type=IsDaylight
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit2Kind]
Measure=Calc
Formula=((#Edit2Ready# = 1) ? ((#EditChanged2# = 1) ? 4 : (3 - MeasureEdit2Day)) : (((#EditWait2# = 1) || (#Settled# = 0)) ? ((#EditChanged2# = 1) ? 6 : 0) : ((#EditChanged2# = 1) ? 7 : 5)))
DynamicVariables=1
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit2Offset]
Measure=Calc
Formula=Round((MeasureEdit2Zone - MeasureLocalZone) * 4) / 4
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit2OffsetH]
Measure=Calc
Formula=Trunc(Abs(MeasureEdit2Offset))
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit2OffsetM]
Measure=Calc
Formula=Round((Abs(MeasureEdit2Offset) - MeasureEdit2OffsetH) * 60)
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit2OffsetSign]
Measure=Calc
Formula=(MeasureEdit2Offset < 0) ? 0 : 1
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit2OffsetText]
Measure=String
String=[#WorldClockSign[&MeasureEdit2OffsetSign:0]][MeasureEdit2OffsetH:0][#WorldClockHour][#WorldClockMin[&MeasureEdit2OffsetM:0]]
RegExpSubstitute=1
Substitute="#WorldClockZeroHour#":"\1\2"
DynamicVariables=1
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit2Wall]
Measure=Calc
Formula=Floor(MeasureLocalTime) + MeasureEdit2Offset * 3600
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit2Time]
Measure=Time
TimeStamp=[MeasureEdit2Wall]
Format=[#CaptionTime[#Hours]]
FormatLocale=#Locale#
DynamicVariables=1
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureSave2]
; Done: a new city that was found is written; "Local" in the first row brings back this Mac's own zone; a name that
; was not found is never written, so the saved city stays
Measure=Calc
Formula=(#EditChanged2# = 1) ? ((0 = 1) ? 2 : (#Edit2Ready# = 1)) : 0
IfConditionMode=1
IfCondition=MeasureSave2 = 1
IfTrueAction=[!WriteKeyValue Variables City2 "[#EditCity2]" "#StationeryFile#"]
IfCondition2=MeasureSave2 = 2
IfTrueAction2=[!WriteKeyValue Variables City2 Local "#StationeryFile#"]
DynamicVariables=1
Disabled=1
UpdateDivider=-1

; ---------------------------------------------------------------- row 3
[MeasureEdit3Typed]
Measure=String
String=[#EditCity3]
DynamicVariables=1
Disabled=1
Group=Edit

[MeasureEdit3Place]
Measure=Plugin
Plugin=MacSun
Location=[#EditCity3]
Type=Place
UnavailableText=
IfMatch=.
IfMatchAction=[!SetVariable Edit3Ready 1][!UpdateMeasureGroup Edit][!UpdateMeterGroup EditFirst][!UpdateMeterGroup Edit][!Redraw]
IfNotMatchAction=[!SetVariable Edit3Ready 0][!UpdateMeasureGroup Edit][!UpdateMeterGroup EditFirst][!UpdateMeterGroup Edit][!Redraw]
DynamicVariables=1
Disabled=1
Group=EditLookup

[MeasureEdit3Zone]
Measure=Plugin
Plugin=MacSun
Parent=MeasureEdit3Place
Type=TimeZone
UnavailableText=
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit3Day]
Measure=Plugin
Plugin=MacSun
Parent=MeasureEdit3Place
Type=IsDaylight
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit3Kind]
Measure=Calc
Formula=((#Edit3Ready# = 1) ? ((#EditChanged3# = 1) ? 4 : (3 - MeasureEdit3Day)) : (((#EditWait3# = 1) || (#Settled# = 0)) ? ((#EditChanged3# = 1) ? 6 : 0) : ((#EditChanged3# = 1) ? 7 : 5)))
DynamicVariables=1
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit3Offset]
Measure=Calc
Formula=Round((MeasureEdit3Zone - MeasureLocalZone) * 4) / 4
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit3OffsetH]
Measure=Calc
Formula=Trunc(Abs(MeasureEdit3Offset))
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit3OffsetM]
Measure=Calc
Formula=Round((Abs(MeasureEdit3Offset) - MeasureEdit3OffsetH) * 60)
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit3OffsetSign]
Measure=Calc
Formula=(MeasureEdit3Offset < 0) ? 0 : 1
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit3OffsetText]
Measure=String
String=[#WorldClockSign[&MeasureEdit3OffsetSign:0]][MeasureEdit3OffsetH:0][#WorldClockHour][#WorldClockMin[&MeasureEdit3OffsetM:0]]
RegExpSubstitute=1
Substitute="#WorldClockZeroHour#":"\1\2"
DynamicVariables=1
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit3Wall]
Measure=Calc
Formula=Floor(MeasureLocalTime) + MeasureEdit3Offset * 3600
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit3Time]
Measure=Time
TimeStamp=[MeasureEdit3Wall]
Format=[#CaptionTime[#Hours]]
FormatLocale=#Locale#
DynamicVariables=1
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureSave3]
; Done: a new city that was found is written; "Local" in the first row brings back this Mac's own zone; a name that
; was not found is never written, so the saved city stays
Measure=Calc
Formula=(#EditChanged3# = 1) ? ((0 = 1) ? 2 : (#Edit3Ready# = 1)) : 0
IfConditionMode=1
IfCondition=MeasureSave3 = 1
IfTrueAction=[!WriteKeyValue Variables City3 "[#EditCity3]" "#StationeryFile#"]
IfCondition2=MeasureSave3 = 2
IfTrueAction2=[!WriteKeyValue Variables City3 Local "#StationeryFile#"]
DynamicVariables=1
Disabled=1
UpdateDivider=-1

; ---------------------------------------------------------------- row 4
[MeasureEdit4Typed]
Measure=String
String=[#EditCity4]
DynamicVariables=1
Disabled=1
Group=Edit

[MeasureEdit4Place]
Measure=Plugin
Plugin=MacSun
Location=[#EditCity4]
Type=Place
UnavailableText=
IfMatch=.
IfMatchAction=[!SetVariable Edit4Ready 1][!UpdateMeasureGroup Edit][!UpdateMeterGroup EditFirst][!UpdateMeterGroup Edit][!Redraw]
IfNotMatchAction=[!SetVariable Edit4Ready 0][!UpdateMeasureGroup Edit][!UpdateMeterGroup EditFirst][!UpdateMeterGroup Edit][!Redraw]
DynamicVariables=1
Disabled=1
Group=EditLookup

[MeasureEdit4Zone]
Measure=Plugin
Plugin=MacSun
Parent=MeasureEdit4Place
Type=TimeZone
UnavailableText=
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit4Day]
Measure=Plugin
Plugin=MacSun
Parent=MeasureEdit4Place
Type=IsDaylight
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit4Kind]
Measure=Calc
Formula=((#Edit4Ready# = 1) ? ((#EditChanged4# = 1) ? 4 : (3 - MeasureEdit4Day)) : (((#EditWait4# = 1) || (#Settled# = 0)) ? ((#EditChanged4# = 1) ? 6 : 0) : ((#EditChanged4# = 1) ? 7 : 5)))
DynamicVariables=1
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit4Offset]
Measure=Calc
Formula=Round((MeasureEdit4Zone - MeasureLocalZone) * 4) / 4
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit4OffsetH]
Measure=Calc
Formula=Trunc(Abs(MeasureEdit4Offset))
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit4OffsetM]
Measure=Calc
Formula=Round((Abs(MeasureEdit4Offset) - MeasureEdit4OffsetH) * 60)
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit4OffsetSign]
Measure=Calc
Formula=(MeasureEdit4Offset < 0) ? 0 : 1
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit4OffsetText]
Measure=String
String=[#WorldClockSign[&MeasureEdit4OffsetSign:0]][MeasureEdit4OffsetH:0][#WorldClockHour][#WorldClockMin[&MeasureEdit4OffsetM:0]]
RegExpSubstitute=1
Substitute="#WorldClockZeroHour#":"\1\2"
DynamicVariables=1
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit4Wall]
Measure=Calc
Formula=Floor(MeasureLocalTime) + MeasureEdit4Offset * 3600
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureEdit4Time]
Measure=Time
TimeStamp=[MeasureEdit4Wall]
Format=[#CaptionTime[#Hours]]
FormatLocale=#Locale#
DynamicVariables=1
Disabled=1
Group=Edit
UpdateDivider=-1

[MeasureSave4]
; Done: a new city that was found is written; "Local" in the first row brings back this Mac's own zone; a name that
; was not found is never written, so the saved city stays
Measure=Calc
Formula=(#EditChanged4# = 1) ? ((0 = 1) ? 2 : (#Edit4Ready# = 1)) : 0
IfConditionMode=1
IfCondition=MeasureSave4 = 1
IfTrueAction=[!WriteKeyValue Variables City4 "[#EditCity4]" "#StationeryFile#"]
IfCondition2=MeasureSave4 = 2
IfTrueAction2=[!WriteKeyValue Variables City4 Local "#StationeryFile#"]
DynamicVariables=1
Disabled=1
UpdateDivider=-1
