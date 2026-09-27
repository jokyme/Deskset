; Stationery · Temperature — the header row, the CPU temperature and the thermal state under it: the top of both
; sizes. Original work, MIT licensed. Included from [MeterCard], so it draws right after the card.

[MeterHeaderSymbol]
; thermometer.medium in the temperature's orange; thermometer.high in the warning colour when the Mac is hot, the
; critical colour when macOS slows it down (the caption says the same in words). Centred on the leading slot (26, 23)
Meter=Image
MeterStyle=sSymbolS
ImageName=sf:[#ThermalGlyph[&MeasureThermal:0]]
ImageTint=[#ThermalTint[&MeasureThermal:0]]
X=21
Y=15.5
W=10
H=15
; the Small's notice has no header
Hidden=((#CardW# < 200) && ([&MeasureNotice:] = 1))
DynamicVariables=1
UpdateDivider=-1
Group=Thermal | Rows

[MeterHeaderTitle]
; "Temperature"; in the Medium the chart's window owns the header's right
Meter=String
MeterStyle=sLabel | sHeaderTitle
Text=#TemperatureTitle#
W=((#CardW# < 200) ? 113 : 150)
Hidden=((#CardW# < 200) && ([&MeasureNotice:] = 1))
DynamicVariables=1
UpdateDivider=-1
Group=Rows

[MeterHero]
; 40 pt on baseline 83: "52° CPU" (the label in the unit's style); "--° CPU" in the tertiary ink until the first reading
Meter=String
MeterStyle=sMetricXL | sUnit | sMissing
MeasureName=MeasureCPU
Text=%1 #TemperatureCPU#
X=16
Y=(#HeroBaselineXL# - #Ascent40#)
Hidden=([&MeasureNotice:] = 1)
DynamicVariables=1
Group=Readings

[MeterCaption]
; the thermal state on baseline 101: "Normal", "Warm", "Hot, may slow down", "Too hot, slowed down". Hidden while Deskset
; cannot read it
Meter=String
MeterStyle=sCaption
Text=[#TemperatureThermal[&MeasureThermal:0]]
FontColor=[#ThermalInk[&MeasureThermal:0]]
X=16
Y=(101 - #Ascent11#)
W=138
ClipString=1
Hidden=((#ThermalKnown# = 0) || ([&MeasureNotice:] = 1))
DynamicVariables=1
UpdateDivider=-1
Group=Thermal
