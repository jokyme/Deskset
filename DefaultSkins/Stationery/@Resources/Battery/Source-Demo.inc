; Stationery · Battery — the suite's sample readings (BatterySource=Demo, screenshots). Original work, MIT licensed.
; The same sections as Source-Live.inc: 73 %, charging, on a 96 W adapter; Health 92 %, 312 cycles. The values
; below reproduce the widget's states (PowerPlugin's Status: 0 no battery, 1 charging, 2–4 not charging).

[Variables]
DemoPercent=73
DemoStatus=1
DemoACLine=1
DemoLifetime=-1
; system_profiler's battery_health: Good, Normal, or anything else (service recommended)
DemoCondition=Good
DemoHealth=92
DemoCycles=312
DemoAdapterWatts=96
DemoAdapterName=96W USB-C Power Adapter

[MeasurePercent]
Measure=Calc
Formula=#DemoPercent#
MinValue=0
MaxValue=100
UpdateDivider=10
OnChangeAction=[!UpdateMeasureGroup State][!UpdateMeterGroup Battery][!UpdateMeterGroup Level][!Redraw]

[MeasureStatus]
Measure=Calc
Formula=#DemoStatus#
UpdateDivider=2

[MeasureACLine]
Measure=Calc
Formula=#DemoACLine#
UpdateDivider=2

[MeasureLifetime]
Measure=Calc
Formula=#DemoLifetime#
UpdateDivider=10

[MeasureProfile]
Measure=Plugin
Plugin=RunCommand
Parameter=printf 'battery_cycle_count=#DemoCycles#\nbattery_health=#DemoCondition#\nbattery_health_maximum_capacity=#DemoHealth#%%\nac_charger_name=#DemoAdapterName#\nac_charger_watts=#DemoAdapterWatts#\n'
Timeout=10000
FinishAction=[!UpdateMeasureGroup Profile][!UpdateMeterGroup Rows][!UpdateMeter MeterCard][!Redraw]
