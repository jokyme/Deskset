; Stationery · Temperature — the widget's words in English. Original work, MIT licensed.
; Strings-Chinese.inc has the same keys. A value with a space at either end is quoted, or the INI reader would trim
; it. Menu titles are Title Case and at most 30 characters.

[Variables]
TemperatureMenuOpen=Open Activity Monitor
TemperatureTitle=Temperature
; after the hero ("52° CPU") and in the Medium's header ("CPU · 11 min")
TemperatureCPU=CPU
TemperatureChartLabel=CPU · %1 min
; the rows: fans (one or two, by MeasureHasFan2), power, GPU, SSD and battery temperatures
TemperatureFans0=Fan
TemperatureFans1=Fans
TemperaturePower=Power
TemperatureGPU=GPU
TemperatureSSD=SSD
TemperatureBattery=Battery
; the Mac's thermal state (ProcessInfo.thermalState: 0 nominal, 1 fair, 2 serious, 3 critical), under the hero
TemperatureThermal0=Normal
TemperatureThermal1=Warm
TemperatureThermal2=Hot, may slow down
TemperatureThermal3=Too hot, slowed down
TemperatureThermalWord0=normal
TemperatureThermalWord1=fair
TemperatureThermalWord2=serious
TemperatureThermalWord3=critical
; the notice when this Mac's sensors cannot be read
TemperatureNoReadings=No Readings
TemperatureNoReadingsBody=Deskset can’t read this Mac’s sensors.
TemperatureNoReadingsState=Thermal state: [#TemperatureThermalWord[&MeasureThermal:0]]

; ---------------------------------------------------------------- the card's sentence
; the thermal state (by MeasureThermalKey: 0–3, 11 and 12 on a Mac without fans, 9 when Deskset cannot read it), then
; every reading; the clauses of readings this Mac lacks are cut out by TemperatureTipCut1…3 (regular expressions)
TemperatureTip0="Thermal state normal: no cooling action is needed. "
TemperatureTip1="Thermal state fair: the fans may become audible. "
TemperatureTip2="Thermal state serious: the fans are at full speed and performance may be reduced. "
TemperatureTip3="Thermal state critical: performance is reduced until the Mac cools down. "
TemperatureTip11="Thermal state fair: the Mac is warm. "
TemperatureTip12="Thermal state serious: performance may be reduced. "
TemperatureTip9=
TemperatureTipReadings=CPU [MeasureCPU], GPU [MeasureGPU], SSD [MeasureSSD], battery [MeasureBattery]. [#TemperatureFans[&MeasureHasFan2:]] [MeasureFansText]. Power [MeasurePower].
TemperatureTipCut1=, [A-Za-z]+ --°
TemperatureTipCut2=\s*Fans? -- rpm\.
TemperatureTipCut3=\s*Power -- W\.
