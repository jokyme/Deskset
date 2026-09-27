; Stationery · System — each core's load, from this Mac (the Large's CPU: Cores view). Original work, MIT licensed.
; One block per core, the same but for its number: performance cores P1…P32, efficiency cores E1…E8 (an Intel Mac's
; cores are all "P"). macOS numbers the efficiency cores first, so performance core n is Processor ECores + n. They
; run only in the Cores view. CoreLoads-Demo.inc has the same sections with sample loads.

[MeasureP1]
Measure=CPU
Processor=(#ECores# + 1)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP2]
Measure=CPU
Processor=(#ECores# + 2)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP3]
Measure=CPU
Processor=(#ECores# + 3)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP4]
Measure=CPU
Processor=(#ECores# + 4)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP5]
Measure=CPU
Processor=(#ECores# + 5)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP6]
Measure=CPU
Processor=(#ECores# + 6)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP7]
Measure=CPU
Processor=(#ECores# + 7)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP8]
Measure=CPU
Processor=(#ECores# + 8)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP9]
Measure=CPU
Processor=(#ECores# + 9)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP10]
Measure=CPU
Processor=(#ECores# + 10)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP11]
Measure=CPU
Processor=(#ECores# + 11)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP12]
Measure=CPU
Processor=(#ECores# + 12)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP13]
Measure=CPU
Processor=(#ECores# + 13)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP14]
Measure=CPU
Processor=(#ECores# + 14)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP15]
Measure=CPU
Processor=(#ECores# + 15)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP16]
Measure=CPU
Processor=(#ECores# + 16)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP17]
Measure=CPU
Processor=(#ECores# + 17)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP18]
Measure=CPU
Processor=(#ECores# + 18)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP19]
Measure=CPU
Processor=(#ECores# + 19)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP20]
Measure=CPU
Processor=(#ECores# + 20)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP21]
Measure=CPU
Processor=(#ECores# + 21)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP22]
Measure=CPU
Processor=(#ECores# + 22)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP23]
Measure=CPU
Processor=(#ECores# + 23)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP24]
Measure=CPU
Processor=(#ECores# + 24)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP25]
Measure=CPU
Processor=(#ECores# + 25)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP26]
Measure=CPU
Processor=(#ECores# + 26)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP27]
Measure=CPU
Processor=(#ECores# + 27)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP28]
Measure=CPU
Processor=(#ECores# + 28)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP29]
Measure=CPU
Processor=(#ECores# + 29)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP30]
Measure=CPU
Processor=(#ECores# + 30)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP31]
Measure=CPU
Processor=(#ECores# + 31)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureP32]
Measure=CPU
Processor=(#ECores# + 32)
DynamicVariables=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureE1]
Measure=CPU
Processor=1
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureE2]
Measure=CPU
Processor=2
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureE3]
Measure=CPU
Processor=3
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureE4]
Measure=CPU
Processor=4
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureE5]
Measure=CPU
Processor=5
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureE6]
Measure=CPU
Processor=6
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureE7]
Measure=CPU
Processor=7
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureE8]
Measure=CPU
Processor=8
Disabled=(1 - #CoresView#)
Group=Cores
