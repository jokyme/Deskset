; Stationery · Battery — the Medium's sample sensor readings (BatterySource=Demo). Original work, MIT licensed.
; The same sections as Sensors-Live.inc, for screenshots: 31°, charging at 30.2 W. DemoTemp is in the suite's unit.

[Variables]
DemoTemp=31
; watts into (+) or out of (−) the battery; 0 reads as no power flowing
DemoWatts=30.2
; the battery's voltage; 0 reads as no reading yet (and DemoTemp=0 as no temperature)
DemoVolts=12.6
; MacSensors' own health figure, shown only while system_profiler has none (0: no reading yet)
DemoHealthIOKit=90

[MeasureBattTemp]
Measure=Calc
Formula=#DemoTemp#
UpdateDivider=10
Group=Sensors

[MeasureBattV]
Measure=Calc
Formula=#DemoVolts#
UpdateDivider=10
Group=Sensors

[MeasureBattA]
Measure=Calc
Formula=#DemoWatts# / Max(#DemoVolts#, 1)
UpdateDivider=10
Group=Sensors

[MeasureHealthIOKit]
Measure=Calc
Formula=#DemoHealthIOKit#
UpdateDivider=600
Group=Sensors
