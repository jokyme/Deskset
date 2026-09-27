; Stationery · Battery — the readings, from this Mac. Original work, MIT licensed.
; Source-Demo.inc has the same sections with the suite's sample values (BatterySource=Demo, for screenshots). Nothing
; here asks for a permission.

[MeasurePercent]
; the charge, 0–100 (100 on a Mac without a battery)
Measure=Plugin
Plugin=PowerPlugin
PowerState=Percent
UpdateDivider=10
OnChangeAction=[!UpdateMeasureGroup State][!UpdateMeterGroup Battery][!UpdateMeterGroup Level][!Redraw]

[MeasureStatus]
; 0 no battery · 1 charging · 2 critical (< 5 %) · 3 low (< 33 %) · 4 above low. Read every 2 s, so a plug-in shows
; within a few seconds (Deskset keeps the reading 5 s, so this costs a dictionary lookup)
Measure=Plugin
Plugin=PowerPlugin
PowerState=Status
UpdateDivider=2

[MeasureACLine]
; 1 on power (also on a Mac without a battery), 0 on battery; a change reads the adapter again
Measure=Plugin
Plugin=PowerPlugin
PowerState=ACLine
UpdateDivider=2
OnChangeAction=[!CommandMeasure MeasureProfile "Run"]

[MeasureLifetime]
; seconds left on battery; -1 while macOS estimates, and on power
Measure=Plugin
Plugin=PowerPlugin
PowerState=Lifetime
UpdateDivider=10

[MeasureProfile]
; Health as System Settings shows it (Maximum Capacity), the condition, the cycles and the adapter: one run of
; system_profiler (0.15 s, no permission) at load, when the plug changes and every 30 minutes. Its JSON keys are not
; translated, unlike its text. DynamicVariables stays off: [^",] is not a section variable
Measure=Plugin
Plugin=RunCommand
Parameter=/usr/sbin/system_profiler SPPowerDataType -json | /usr/bin/sed -nE 's/^ *"sppower_(battery_health_maximum_capacity|battery_health|battery_cycle_count|ac_charger_watts|ac_charger_name)" : "?([^",]*)"?,?$/\1=\2/p'
Timeout=10000
FinishAction=[!UpdateMeasureGroup Profile][!UpdateMeterGroup Rows][!UpdateMeter MeterCard][!Redraw]
