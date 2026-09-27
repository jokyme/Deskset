; Stationery · Spectrum — Bars: Accent Color: the Mac's accent colour. Original work, MIT licensed.
; The header symbol takes the bars' colour, so the accent never sits beside the media colour.

[Variables]
BarTint=#AccentColor#
BarTint2=#AccentColor#

[MeasureAccentRGB]
; the accent without its alpha, for the fade at the top of rounded bars (E20)
Measure=String
String=#AccentColor#
RegExpSubstitute=1
Substitute="^(\d+,\d+,\d+).*$":"\1"
IfMatch=^\d+,\d+,\d+$
IfMatchAction=[!SetOptionGroup Bars MacBarColor2 "[MeasureAccentRGB],153"]
UpdateDivider=-1
