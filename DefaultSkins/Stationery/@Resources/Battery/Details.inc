; Stationery · Battery — the Medium's detail column (x 176 → 344): five rows at baselines 47, 73, 99, 125 and 151, the
; last sharing the status line's. Symbols at their natural 13 pt semibold size, centred on the column's leading slot
; (x 186, baseline − 4.6), outline throughout; labels at X 201; values right-aligned at X 344. Original work, MIT
; licensed. Included from [MeterCard], so the meters draw over the card; the measures come first.

[MeasureHealthShown]
; system_profiler's Maximum Capacity ("92%"); without it MacSensors' battery.health; else "--"
Measure=String
String=[MeasureHealthText]|[MeasureHealthIOKit:0]
DynamicVariables=1
UpdateDivider=10
Group=Profile | Sensors
RegExpSubstitute=1
Substitute="^(\d+%)\|.*$":"\1","^--\|0$":"--","^--\|(\d+)$":"\1%"

[MeasureTempOK]
Measure=Calc
Formula=MeasureBattTemp > 0
UpdateDivider=10
Group=Sensors

[MeasureTempText]
; "31", or "--" without a reading
Measure=String
String=[MeasureTempOK:]|[MeasureBattTemp:0]
DynamicVariables=1
UpdateDivider=10
Group=Sensors
RegExpSubstitute=1
Substitute="^0\|.*$":"--","^1\|":""

[MeasurePowerW]
; into (+) or out of (−) the battery
Measure=Calc
Formula=MeasureBattV * MeasureBattA
UpdateDivider=10
Group=Sensors

[MeasurePowerKey]
; 0 no reading · 1 charging · 2 discharging · 3 idle (less than 0.05 W either way)
Measure=Calc
Formula=(MeasureBattV <= 0) ? 0 : ((MeasurePowerW >= 0.05) ? 1 : ((MeasurePowerW <= -0.05) ? 2 : 3))
UpdateDivider=10
Group=Sensors

[MeasurePowerText]
; "+30.2", "−8.4", "0", "+104" (no decimal from 100 W), "--"
Measure=String
String=[MeasurePowerKey:]|[MeasurePowerW:1]
DynamicVariables=1
UpdateDivider=10
Group=Sensors
RegExpSubstitute=1
Substitute="^0\|.*$":"--","^3\|.*$":"0","^\d\|":"","^-(?=\d)":"−","^(?!0$)(\d)":"+\1","^([+−]\d{3,})\.\d$":"\1"

[MeasurePowerAbs]
; for the tooltip: "30.2"
Measure=String
String=[MeasurePowerW:1]
DynamicVariables=1
UpdateDivider=10
Group=Sensors
RegExpSubstitute=1
Substitute="^-":"","^(\d{3,})\.\d$":"\1"

[MeasureAdapterShown]
; "96 W" on power, "Unplugged" on battery, "-- W" before system_profiler answers
Measure=String
String=[MeasureACLine:]|[MeasureAdapterText]
DynamicVariables=1
UpdateDivider=2
Group=Profile
RegExpSubstitute=1
Substitute="^0\|.*$":"#BatteryUnplugged#","^1\|(.*)$":"\1 W"
OnChangeAction=[!UpdateMeter MeterAdapterValue][!Redraw]

[MeasureDetailsNow]
; MacSensors answers one update late: read the sensors again 2 s after load rather than 10 s later
Measure=Calc
Formula=1
UpdateDivider=-1
OnUpdateAction=[!Delay 2000][!UpdateMeasureGroup Sensors][!UpdateMeterGroup Rows][!Redraw]

; ---------------------------------------------------------------- Health (baseline 47)
[MeterHealthSymbol]
; battery.100, natural 23 × 12: wider than the 20 pt slot, it overhangs evenly
Meter=Image
MeterStyle=sSymbolM
ImageName=sf:battery.100
ImageTint=#BatteryColor#
X=174.5
Y=36.4
W=23
H=12
UpdateDivider=-1
Group=Battery

[MeterHealthLabel]
Meter=String
MeterStyle=sBody
Text=#BatteryHealth#
X=#DetailTextX#
Y=(47 - #Ascent13#)
UpdateDivider=-1
Group=Battery

[MeterHealthValue]
; CriticalTextColor when macOS recommends service
Meter=String
MeterStyle=sValue | sNoUnit | sMissing
MeasureName=MeasureHealthShown
FontColor=[#HealthInk[&MeasureServiceKey]]
StringAlign=Right
X=344
Y=(47 - #Ascent13#)
DynamicVariables=1
UpdateDivider=-1
Group=Battery | Rows

; ---------------------------------------------------------------- Cycles (baseline 73)
[MeterCyclesSymbol]
; arrow.triangle.2.circlepath, natural 16 × 16
Meter=Image
MeterStyle=sSymbolM
ImageName=sf:arrow.triangle.2.circlepath
ImageTint=#SecondaryTextColor#
X=178
Y=60.4
W=16
H=16
UpdateDivider=-1
Group=Battery

[MeterCyclesLabel]
Meter=String
MeterStyle=sBody
Text=#BatteryCycles#
X=#DetailTextX#
Y=(73 - #Ascent13#)
UpdateDivider=-1
Group=Battery

[MeterCyclesValue]
Meter=String
MeterStyle=sValue | sNoUnit | sMissing
MeasureName=MeasureCyclesText
StringAlign=Right
X=344
Y=(73 - #Ascent13#)
UpdateDivider=-1
Group=Battery | Rows

; ---------------------------------------------------------------- Temperature (baseline 99)
[MeterTempSymbol]
; thermometer.medium, natural 11 × 17
Meter=Image
MeterStyle=sSymbolM
ImageName=sf:thermometer.medium
ImageTint=#TemperatureColor#
X=180.5
Y=85.9
W=11
H=17
UpdateDivider=-1
Group=Battery

[MeterTempLabel]
Meter=String
MeterStyle=sBody
Text=#BatteryTemperature#
X=#DetailTextX#
Y=(99 - #Ascent13#)
UpdateDivider=-1
Group=Battery

[MeterTempValue]
Meter=String
MeterStyle=sValue | sNoUnit | sMissing
MeasureName=MeasureTempText
Text=%1°
StringAlign=Right
X=344
Y=(99 - #Ascent13#)
UpdateDivider=-1
Group=Battery | Rows

; ---------------------------------------------------------------- Power (baseline 125)
[MeterPowerSymbol]
; bolt, natural 13 × 18
Meter=Image
MeterStyle=sSymbolM
ImageName=sf:bolt
ImageTint=#PowerColor#
X=179.5
Y=111.4
W=13
H=18
UpdateDivider=-1
Group=Battery

[MeterPowerLabel]
Meter=String
MeterStyle=sBody
Text=#BatteryPower#
X=#DetailTextX#
Y=(125 - #Ascent13#)
UpdateDivider=-1
Group=Battery

[MeterPowerValue]
; "+30.2 W", the unit in 11 pt
Meter=String
MeterStyle=sValue | sUnit | sMissing
MeasureName=MeasurePowerText
Text=%1 W
StringAlign=Right
X=344
Y=(125 - #Ascent13#)
UpdateDivider=-1
Group=Battery | Rows

; ---------------------------------------------------------------- Adapter (baseline 151)
[MeterAdapterSymbol]
; powerplug, natural 19 × 13
Meter=Image
MeterStyle=sSymbolM
ImageName=sf:powerplug
ImageTint=#SecondaryTextColor#
X=176.5
Y=139.9
W=19
H=13
UpdateDivider=-1
Group=Battery

[MeterAdapterLabel]
Meter=String
MeterStyle=sBody
Text=#BatteryAdapter#
X=#DetailTextX#
Y=(151 - #Ascent13#)
UpdateDivider=-1
Group=Battery

[MeterAdapterValue]
; "96 W" on power; on battery the word "Unplugged", set as supporting text (words are never in SF Pro Rounded)
Meter=String
MeterStyle=sValue | sUnit | sMissing | sWordValue
MeasureName=MeasureAdapterShown
StringAlign=Right
X=344
Y=(151 - #Ascent13#)
UpdateDivider=-1
Group=Battery | Rows

; ---------------------------------------------------------------- the rows' hit areas: each row's tooltip, and the card's click
; (the rows are not controls: no hover pad)
[MeterPadHealth]
Meter=Image
MeterStyle=sHit
X=#DetailX#
Y=30
W=168
H=26
LeftMouseUpAction=#OpenAction#
ToolTipTitle=#BatteryHealth#
ToolTipText=[#BatteryTipHealthRow[&MeasureServiceKey]]
DynamicVariables=1
UpdateDivider=10
Group=Battery

[MeterPadCycles]
Meter=Image
MeterStyle=sHit
X=#DetailX#
Y=56
W=168
H=26
LeftMouseUpAction=#OpenAction#
ToolTipTitle=#BatteryCycles#
ToolTipText=#BatteryTipCyclesRow#
DynamicVariables=1
UpdateDivider=10
Group=Battery

[MeterPadTemp]
Meter=Image
MeterStyle=sHit
X=#DetailX#
Y=82
W=168
H=26
LeftMouseUpAction=#OpenAction#
ToolTipTitle=#BatteryTemperature#
ToolTipText=#BatteryTipTemperatureRow#
DynamicVariables=1
UpdateDivider=10
Group=Battery

[MeterPadPower]
Meter=Image
MeterStyle=sHit
X=#DetailX#
Y=108
W=168
H=26
LeftMouseUpAction=#OpenAction#
ToolTipTitle=#BatteryPower#
ToolTipText=[#BatteryTipPower[&MeasurePowerKey:]]
DynamicVariables=1
UpdateDivider=10
Group=Battery

[MeterPadAdapter]
Meter=Image
MeterStyle=sHit
X=#DetailX#
Y=134
W=168
H=26
LeftMouseUpAction=#OpenAction#
ToolTipTitle=#BatteryAdapter#
ToolTipText=[#BatteryTipAdapter[&MeasureACLine:]]
DynamicVariables=1
UpdateDivider=10
Group=Battery
