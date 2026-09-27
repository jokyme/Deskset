; Stationery · Temperature — the widget's variables: its state, the chart's range and the tables of the rows.
; Original work, MIT licensed. Included in [Variables] of both sizes.
;
; Rows are picked from five candidates, in this order of preference: 1 fans, 2 power, 3 GPU, 4 SSD, 5 battery (0 is
; an empty slot). The Small shows the first two this Mac has; the Medium shows temperatures on the left (GPU, SSD) and
; fans and power on the right, each replaced by the next spare temperature when the Mac lacks it (Measures.inc).

[Variables]
; ---------------------------------------------------------------- state, set by the measures
; 1 from the sensors' third update: from then on a candidate counts only if its sensor has given a reading
Settled=0
; a reading has come (CPU, and candidates 1–5), the second fan exists, the thermal state can be read
SeenCPU=0
Seen1=0
Seen2=0
Seen3=0
Seen4=0
Seen5=0
HasFan2=0
ThermalKnown=0
; 1: fans and power are offered; 0 leaves them out (the rows fall through to the temperatures)
ProRows=1

; ---------------------------------------------------------------- the Medium's chart
; one sample per ChartDivider skin updates of 2 s: 168 samples × 4 s = 11 minutes. The range is fixed at 30–110 °C
; (110 °C is Apple silicon's nominal maximum), so the line's height says how close the CPU is to its limit
ChartDivider=2
ChartMinC=30
ChartMaxC=110
ChartMinF=86
ChartMaxF=230
ChartMin=[#ChartMin[#TempScale]]
ChartMax=[#ChartMax[#TempScale]]

; ---------------------------------------------------------------- the candidates
; the measure whose string is the value (Measure<Key>), the label, the symbol (11 pt semibold, .fill set) with its
; natural size, and its tint
Key0=None
Key1=FansText
Key2=Power
Key3=GPU
Key4=SSD
Key5=Battery
Label0=
Label1=[#TemperatureFans[&MeasureHasFan2:]]
Label2=#TemperaturePower#
Label3=#TemperatureGPU#
Label4=#TemperatureSSD#
Label5=#TemperatureBattery#
Sym0=
Sym1=fanblades.fill
Sym2=bolt.fill
Sym3=cube.transparent.fill
Sym4=internaldrive.fill
Sym5=battery.100
SymW0=1
SymW1=15
SymW2=12
SymW3=15
SymW4=16
SymW5=20
SymH0=1
SymH1=14
SymH2=15
SymH3=15
SymH4=12
SymH5=10
Tint0=0,0,0,0
Tint1=#FanColor#
Tint2=#PowerColor#
Tint3=#GPUColor#
; the SSD is a device glyph (Storage's orange would be the temperature's orange here)
Tint4=#SecondaryTextColor#
Tint5=#BatteryColor#

; ---------------------------------------------------------------- the thermal state (0 nominal … 3 critical)
; the header's glyph and tint, and the caption's ink: warning and critical are said in words too
ThermalGlyph0=thermometer.medium
ThermalGlyph1=thermometer.medium
ThermalGlyph2=thermometer.high
ThermalGlyph3=thermometer.high
ThermalTint0=#TemperatureColor#
ThermalTint1=#TemperatureColor#
ThermalTint2=#WarningColor#
ThermalTint3=#CriticalColor#
ThermalInk0=#SecondaryTextColor#
ThermalInk1=#SecondaryTextColor#
ThermalInk2=#TextColor#
ThermalInk3=#CriticalTextColor#
