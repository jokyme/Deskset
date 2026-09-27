; Stationery · Spectrum — the Strip's Bars: Ink (the default): white or dark, as the suite's ink under the Strip.
; Original work, MIT licensed.

[MeasureStripTint]
; 0 white ink, 1 dark ink (Ink.inc); the bars follow every switch, the first one included
Measure=Calc
Formula=MeasureInkDark
UpdateDivider=#InkDivider#
IfCondition=MeasureStripTint = 1
IfTrueAction=[!SetOptionGroup Bars BarColor "28,28,30,255"][!UpdateMeterGroup Bars][!Redraw]
IfFalseAction=[!SetOptionGroup Bars BarColor "255,255,255,255"][!UpdateMeterGroup Bars][!Redraw]
