; Stationery · World Clock — its words in English. Original work, MIT licensed.
; Strings-Chinese.inc has the same keys. A value with a space at either end is quoted, or the INI reader would trim
; it. Menu titles are Title Case and at most 30 characters.

[Variables]
WorldClockTitle=World Clock
; this Mac's own time zone: the first dial's name without a city, or the line under the city
WorldClockLocal=Local
WorldClockNotFound=Not found
; a city's offset from here: "+7 h", "−3 h 30 min", "+30 min" (below an hour), "+0 h" (another city in this zone)
WorldClockSign0=−
WorldClockSign1=+
WorldClockHour=" h"
WorldClockMin0=
WorldClockMin15=" 15 min"
WorldClockMin30=" 30 min"
WorldClockMin45=" 45 min"
; "+0 h 30 min" → "+30 min" (a pattern without square brackets)
WorldClockZeroHour=^(\+|\x{2212})0 h (.+)$
; the small size's tag under the time: the weekday when the city's date is not today's here, then AM or PM
WorldClockTagAMPM12=" %2"
WorldClockTagAMPM24=
; tooltips: "Tokyo: Saturday 17:09, 7 hours ahead."
WorldClockTipDayFormat=%A
WorldClockTipColon=": "
WorldClockTipComma=", "
WorldClockTipEnd=.
WorldClockTipHours0=hours
WorldClockTipHours1=hour
WorldClockTipMin0=
WorldClockTipMin15=" 15 minutes"
WorldClockTipMin30=" 30 minutes"
WorldClockTipMin45=" 45 minutes"
; by the offset: behind (0), ahead (1), the same time (2)
WorldClockTipBefore0=
WorldClockTipAfter0=" behind"
WorldClockTipBefore1=
WorldClockTipAfter1=" ahead"
WorldClockTipBefore2=same time
WorldClockTipAfter2=
WorldClockTipThisMac=this Mac's time
WorldClockTipZoneOpen=" ("
WorldClockTipZoneClose=)
WorldClockTipNotFoundBefore=Deskset can't find “
WorldClockTipNotFoundAfter=”. Right-click › Edit Cities…
; editing the cities
WorldClockEditTitle=Edit Cities
WorldClockCancel=Cancel
WorldClockDone=Done
WorldClockEditHint=Any language: 东京, NYC
WorldClockEditRowTip=Type a city in any language (Tokyo, 东京, NYC). “Local” is this Mac's time zone.
; "Not found · New York stays"
WorldClockKeepsBefore=
WorldClockKeepsAfter=" stays"
; the right-click menu
WorldClockMenuEdit=Edit Cities…
WorldClockMenuSeconds0=Seconds Hands: Off
WorldClockMenuSeconds1=Seconds Hands: On
