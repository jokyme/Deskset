; Stationery · Temperature — the measures both sizes share. Original work, MIT licensed.
; Every reading comes from MacSensors (the Mac's own sensors: nothing asks for a permission) every 2 s, the skin's
; update. A sensor's string is empty until its first reading, one update after load, and stays empty on a Mac that
; lacks the sensor; a stopped fan reads "0 RPM". So a row is chosen by its sensor's string, never by a 0. Every sensor
; but the CPU's is missing on some Macs (no fans, one fan, no battery), so they are MacOptional: a Mac without one
; logs nothing about it.

; ---------------------------------------------------------------- sensors
[MeasureCPU]
; "52°" (the scale follows the suite's TempUnit); the chart's range is fixed (Rows.inc)
Measure=Plugin
Plugin=MacSensors
Sensor=cpu
Scale=#TempScale#
MinValue=#ChartMin#
MaxValue=#ChartMax#
RegExpSubstitute=1
Substitute="^(-?\d+) °[CFK]$":"\1°","^$":"--°"
IfMatch=^\d
IfMatchAction=[!SetVariable SeenCPU 1][!UpdateMeasureGroup Slots][!UpdateMeterGroup Rows][!Redraw]
IfNotMatchAction=[!SetVariable SeenCPU 0][!UpdateMeasureGroup Slots][!UpdateMeterGroup Rows][!Redraw]
Group=Sensors

[MeasureGPU]
Measure=Plugin
Plugin=MacSensors
Sensor=gpu
MacOptional=1
Scale=#TempScale#
RegExpSubstitute=1
Substitute="^(-?\d+) °[CFK]$":"\1°","^$":"--°"
IfMatch=^\d
IfMatchAction=[!SetVariable Seen3 1][!UpdateMeasureGroup Slots][!UpdateMeterGroup Rows][!Redraw]
IfNotMatchAction=[!SetVariable Seen3 0][!UpdateMeasureGroup Slots][!UpdateMeterGroup Rows][!Redraw]
Group=Sensors

[MeasureSSD]
Measure=Plugin
Plugin=MacSensors
Sensor=ssd
MacOptional=1
Scale=#TempScale#
RegExpSubstitute=1
Substitute="^(-?\d+) °[CFK]$":"\1°","^$":"--°"
IfMatch=^\d
IfMatchAction=[!SetVariable Seen4 1][!UpdateMeasureGroup Slots][!UpdateMeterGroup Rows][!Redraw]
IfNotMatchAction=[!SetVariable Seen4 0][!UpdateMeasureGroup Slots][!UpdateMeterGroup Rows][!Redraw]
Group=Sensors

[MeasureBattery]
Measure=Plugin
Plugin=MacSensors
Sensor=battery
MacOptional=1
Scale=#TempScale#
RegExpSubstitute=1
Substitute="^(-?\d+) °[CFK]$":"\1°","^$":"--°"
IfMatch=^\d
IfMatchAction=[!SetVariable Seen5 1][!UpdateMeasureGroup Slots][!UpdateMeterGroup Rows][!Redraw]
IfNotMatchAction=[!SetVariable Seen5 0][!UpdateMeasureGroup Slots][!UpdateMeterGroup Rows][!Redraw]
Group=Sensors

[MeasureFan1]
; "2317 RPM"; its range is the fan's own minimum and maximum speed
Measure=Plugin
Plugin=MacSensors
Sensor=fan.1
MacOptional=1
IfMatch=.
IfMatchAction=[!SetVariable Seen1 1][!UpdateMeasureGroup Slots][!UpdateMeterGroup Rows][!Redraw]
IfNotMatchAction=[!SetVariable Seen1 0][!UpdateMeasureGroup Slots][!UpdateMeterGroup Rows][!Redraw]
Group=Sensors

[MeasureFan2]
; only to say "Fans" rather than "Fan" (it reads 0 on a Mac with one fan)
Measure=Plugin
Plugin=MacSensors
Sensor=fan.2
MacOptional=1
IfMatch=.
IfMatchAction=[!SetVariable HasFan2 1][!UpdateMeasureGroup Slots][!UpdateMeterGroup Rows][!Redraw]
IfNotMatchAction=[!SetVariable HasFan2 0][!UpdateMeasureGroup Slots][!UpdateMeterGroup Rows][!Redraw]
Group=Sensors

[MeasurePower]
; the whole Mac: "18.4 W", "112 W" (MacSensors writes one decimal below 100)
Measure=Plugin
Plugin=MacSensors
Sensor=power.system
MacOptional=1
RegExpSubstitute=1
Substitute="^$":"-- W"
IfMatch=^\d
IfMatchAction=[!SetVariable Seen2 1][!UpdateMeasureGroup Slots][!UpdateMeterGroup Rows][!Redraw]
IfNotMatchAction=[!SetVariable Seen2 0][!UpdateMeasureGroup Slots][!UpdateMeterGroup Rows][!Redraw]
Group=Sensors

[MeasureThermal]
; the Mac's thermal state (0 nominal, 1 fair, 2 serious, 3 critical), once Deskset reads it (Sensor=thermal); until
; then its string is empty, and the caption under the hero stays hidden
Measure=Plugin
Plugin=MacSensors
Sensor=thermal
IfMatch=.
IfMatchAction=[!SetVariable ThermalKnown 1][!UpdateMeasureGroup Slots][!UpdateMeterGroup Thermal][!Redraw]
IfNotMatchAction=[!SetVariable ThermalKnown 0][!UpdateMeasureGroup Slots][!UpdateMeterGroup Thermal][!Redraw]
OnChangeAction=[!UpdateMeasureGroup Slots][!UpdateMeterGroup Thermal][!Redraw]
Group=Sensors

[MeasureNone]
; the value of an empty row
Measure=String
String=
UpdateDivider=-1

; ---------------------------------------------------------------- readings made from them
[MeasureFanFast]
; the faster fan (fan 2 reads 0 on a one-fan Mac)
Measure=Calc
Formula=Max(MeasureFan1, MeasureFan2)
Group=Sensors

[MeasureFansText]
; "2,317 rpm", a stopped fan "0 rpm", no reading "-- rpm"
Measure=String
String=[&MeasureFan1]|[&MeasureFanFast:0]
RegExpSubstitute=1
Substitute="^\|.*$":"-- rpm","^[^|]*\|(\d+)$":"\1 rpm","(\d)(?=(\d{3})+(?!\d))":"\1#DigitGroup#"
DynamicVariables=1
Group=Sensors

[MeasureFanShare]
; where the fan is between the hardware's minimum and maximum speed (MacSensors' own range for fans), 0–1
Measure=Calc
Formula=([MeasureFan1:MaxValue] - [MeasureFan1:MinValue] > 1) ? Clamp((MeasureFanFast - [MeasureFan1:MinValue]) / ([MeasureFan1:MaxValue] - [MeasureFan1:MinValue]), 0, 1) : 0
DynamicVariables=1
Group=Sensors

[MeasureSensorUpdates]
; counts the sensors' updates since the skin loaded: at the third (4 s) the rows settle on the sensors that answered
Measure=Calc
Formula=Min(MeasureSensorUpdates + 1, 9)
IfCondition=MeasureSensorUpdates >= 3
IfTrueAction=[!SetVariable Settled 1][!UpdateMeasureGroup Slots][!UpdateMeterGroup Rows][!UpdateMeterGroup Thermal][!Redraw]
Group=Sensors

[MeasureComputerName]
; the card's tooltip title: "Joky’s MacBook Pro"
Measure=SysInfo
SysInfoType=COMPUTER_NAME
UpdateDivider=-1

[MeasureChartMinutes]
; the chart's window in minutes, from its divider (168 samples × ChartDivider × 2 s), so the label stays true
Measure=Calc
Formula=Round(168 * #ChartDivider# * 2000 / 60000)
UpdateDivider=-1

; ---------------------------------------------------------------- which rows show (updated when a reading comes or goes)
[MeasureHasFan2]
Measure=Calc
Formula=#HasFan2#
DynamicVariables=1
UpdateDivider=-1
Group=Slots

[MeasureH1]
; candidate i is available: before settling every candidate is (its row shows "--"); after, only one with a reading
Measure=Calc
Formula=(#Settled# ? #Seen1# : 1) * #ProRows#
DynamicVariables=1
UpdateDivider=-1
Group=Slots

[MeasureH2]
Measure=Calc
Formula=(#Settled# ? #Seen2# : 1) * #ProRows#
DynamicVariables=1
UpdateDivider=-1
Group=Slots

[MeasureH3]
Measure=Calc
Formula=#Settled# ? #Seen3# : 1
DynamicVariables=1
UpdateDivider=-1
Group=Slots

[MeasureH4]
Measure=Calc
Formula=#Settled# ? #Seen4# : 1
DynamicVariables=1
UpdateDivider=-1
Group=Slots

[MeasureH5]
Measure=Calc
Formula=#Settled# ? #Seen5# : 1
DynamicVariables=1
UpdateDivider=-1
Group=Slots

[MeasureP1]
; how many candidates are available up to i
Measure=Calc
Formula=MeasureH1
UpdateDivider=-1
Group=Slots

[MeasureP2]
Measure=Calc
Formula=MeasureP1 + MeasureH2
UpdateDivider=-1
Group=Slots

[MeasureP3]
Measure=Calc
Formula=MeasureP2 + MeasureH3
UpdateDivider=-1
Group=Slots

[MeasureP4]
Measure=Calc
Formula=MeasureP3 + MeasureH4
UpdateDivider=-1
Group=Slots

[MeasureP5]
Measure=Calc
Formula=MeasureP4 + MeasureH5
UpdateDivider=-1
Group=Slots

[MeasureSmallRows]
; the Small: the first two available of 1…5
Measure=Calc
Formula=Min(MeasureP5, 2)
UpdateDivider=-1
Group=Slots

[MeasureSmallA]
Measure=Calc
Formula=1*MeasureH1*(MeasureP1 = 1) + 2*MeasureH2*(MeasureP2 = 1) + 3*MeasureH3*(MeasureP3 = 1) + 4*MeasureH4*(MeasureP4 = 1) + 5*MeasureH5*(MeasureP5 = 1)
UpdateDivider=-1
Group=Slots

[MeasureSmallB]
Measure=Calc
Formula=1*MeasureH1*(MeasureP1 = 2) + 2*MeasureH2*(MeasureP2 = 2) + 3*MeasureH3*(MeasureP3 = 2) + 4*MeasureH4*(MeasureP4 = 2) + 5*MeasureH5*(MeasureP5 = 2)
UpdateDivider=-1
Group=Slots

[MeasureQ3]
; the Medium's left: the first two available temperatures (3…5)
Measure=Calc
Formula=MeasureH3
UpdateDivider=-1
Group=Slots

[MeasureQ4]
Measure=Calc
Formula=MeasureQ3 + MeasureH4
UpdateDivider=-1
Group=Slots

[MeasureQ5]
Measure=Calc
Formula=MeasureQ4 + MeasureH5
UpdateDivider=-1
Group=Slots

[MeasureLeftRows]
Measure=Calc
Formula=Min(MeasureQ5, 2)
UpdateDivider=-1
Group=Slots

[MeasureLeftA]
Measure=Calc
Formula=3*MeasureH3*(MeasureQ3 = 1) + 4*MeasureH4*(MeasureQ4 = 1) + 5*MeasureH5*(MeasureQ5 = 1)
UpdateDivider=-1
Group=Slots

[MeasureLeftB]
Measure=Calc
Formula=3*MeasureH3*(MeasureQ3 = 2) + 4*MeasureH4*(MeasureQ4 = 2) + 5*MeasureH5*(MeasureQ5 = 2)
UpdateDivider=-1
Group=Slots

[MeasureRight1]
; the Medium's right: fans, else the next spare temperature (after the two on the left)
Measure=Calc
Formula=MeasureH1 ? 1 : (3*MeasureH3*(MeasureQ3 = 3) + 4*MeasureH4*(MeasureQ4 = 3) + 5*MeasureH5*(MeasureQ5 = 3))
UpdateDivider=-1
Group=Slots

[MeasureRight2]
; power, else the next spare temperature after that
Measure=Calc
Formula=MeasureH2 ? 2 : (3*MeasureH3*(MeasureQ3 = (4 - MeasureH1)) + 4*MeasureH4*(MeasureQ4 = (4 - MeasureH1)) + 5*MeasureH5*(MeasureQ5 = (4 - MeasureH1)))
UpdateDivider=-1
Group=Slots

[MeasureNotice]
; 1 when the sensors have settled without a CPU reading (a virtual machine, a chip Deskset does not know yet): the card
; shows the "No Readings" notice instead of its content
Measure=Calc
Formula=(#Settled# = 1) && (#SeenCPU# = 0)
DynamicVariables=1
UpdateDivider=-1
Group=Slots

[MeasureThermalKey]
; the tooltip's first sentence: the thermal state 0–3 (11 or 12 on a Mac without fans), 9 while it cannot be read
Measure=Calc
Formula=(#ThermalKnown# = 0) ? 9 : (MeasureThermal + ((((#Seen1# = 0) && (#Settled# = 1)) && ((MeasureThermal = 1) || (MeasureThermal = 2))) ? 10 : 0))
DynamicVariables=1
UpdateDivider=-1
Group=Slots

; ---------------------------------------------------------------- the card's sentence
[MeasureTip]
; "Thermal state normal: no cooling action is needed. CPU 52°, GPU 47°, SSD 38°, battery 31°. Fans 2,317 rpm. Power
; 18.4 W." Clauses of readings this Mac lacks are cut out (the patterns are the language's)
Measure=String
String=[#TemperatureTip[&MeasureThermalKey:]]#TemperatureTipReadings#
RegExpSubstitute=1
Substitute="#TemperatureTipCut1#":"","#TemperatureTipCut2#":"","#TemperatureTipCut3#":""
DynamicVariables=1
Group=Sensors
