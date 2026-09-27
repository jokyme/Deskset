; Stationery · Battery — the Medium's sensor readings, from this Mac: the battery's temperature, voltage and current
; (MacSensors; the battery's own registry entry, no helper). Sensors-Demo.inc has the same sections with sample values.
; Original work, MIT licensed.

[MeasureBattTemp]
; in the suite's temperature unit (TempUnit)
Measure=Plugin
Plugin=MacSensors
Sensor=battery
Scale=#TempScale#
UpdateDivider=10
Group=Sensors

[MeasureBattV]
Measure=Plugin
Plugin=MacSensors
Sensor=battery.voltage
UpdateDivider=10
Group=Sensors

[MeasureBattA]
; negative while the battery is discharging
Measure=Plugin
Plugin=MacSensors
Sensor=battery.current
UpdateDivider=10
Group=Sensors

[MeasureHealthIOKit]
; only when system_profiler has no figure: full-charge ÷ design capacity reads a few points under System Settings
Measure=Plugin
Plugin=MacSensors
Sensor=battery.health
UpdateDivider=600
Group=Sensors
