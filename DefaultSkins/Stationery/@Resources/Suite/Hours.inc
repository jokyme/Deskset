; Stationery — the Mac's 12/24-hour clock, until the engine has #MACCLOCKHOURS#. Original work, MIT licensed.
;
; Widgets that show times include it after Tokens.inc and Styles.inc, before their own measures. With ClockHours=Auto
; it asks MacSun, whose default time format follows the Mac's clock setting ("6:00 AM" or "06:00": Location=0,0 needs
; no place and no permission), and sets Hours to 12 or 24. Its first answer comes before the widget's measures first
; update; a later change (the Mac's setting changed) runs HoursChangeAction. So read #Hours# in options with
; DynamicVariables=1, and set HoursChangeAction in the widget's [Variables] to update what shows times, for example
; [!UpdateMeasureGroup Clock][!UpdateMeterGroup Clock][!Redraw].
; Once the engine has #MACCLOCKHOURS#, Tokens.inc has the right Hours at load and this file can go.

[Variables]
HoursChangeAction=[!UpdateMeter *][!Redraw]
HoursProbeOffAuto=0
HoursProbeOff24=1
HoursProbeOff12=1

[MeasureHoursProbe]
Measure=Plugin
Plugin=MacSun
Location=0,0
Type=Sunrise
FormatLocale=en_US
Disabled=[#HoursProbeOff[#ClockHours]]
IfMatch=AM|PM
IfMatchAction=[!SetVariable Hours 12]#HoursChangeAction#
IfNotMatchAction=[!SetVariable Hours 24]#HoursChangeAction#
UpdateDivider=600
