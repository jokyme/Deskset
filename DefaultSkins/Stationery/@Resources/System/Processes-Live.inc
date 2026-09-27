; Stationery · System — the Large's readings, from this Mac: the busiest processes and the number of cores of each
; kind (each core's load is in CoreLoads-Live.inc). Processes-Demo.inc has the same sections with sample values.
; Original work, MIT licensed.

; ---------------------------------------------------------------- the busiest processes
; UsageMonitor ranks the processes once a second (their share of the whole Mac, 0–100, with Alias=CPU; the memory
; they use, in bytes, with Alias=RAM, which macOS gives only for your own processes). Same-named processes are added
; up; the processes of other users and of macOS appear together as "System". Only the sort on show runs.

[MeasureTopCPU1]
Measure=Plugin
Plugin=UsageMonitor
Alias=CPU
Index=1
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU

[MeasureTopCPU2]
Measure=Plugin
Plugin=UsageMonitor
Alias=CPU
Index=2
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU

[MeasureTopCPU3]
Measure=Plugin
Plugin=UsageMonitor
Alias=CPU
Index=3
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU

[MeasureTopCPU4]
Measure=Plugin
Plugin=UsageMonitor
Alias=CPU
Index=4
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU

[MeasureTopMem1]
Measure=Plugin
Plugin=UsageMonitor
Alias=RAM
Index=1
UpdateDivider=2
Disabled=(1 - #SystemSortBy#)
Group=TopMem

[MeasureTopMem2]
Measure=Plugin
Plugin=UsageMonitor
Alias=RAM
Index=2
UpdateDivider=2
Disabled=(1 - #SystemSortBy#)
Group=TopMem

[MeasureTopMem3]
Measure=Plugin
Plugin=UsageMonitor
Alias=RAM
Index=3
UpdateDivider=2
Disabled=(1 - #SystemSortBy#)
Group=TopMem

[MeasureTopMem4]
Measure=Plugin
Plugin=UsageMonitor
Alias=RAM
Index=4
UpdateDivider=2
Disabled=(1 - #SystemSortBy#)
Group=TopMem

; ---------------------------------------------------------------- cores
[MeasureCoreCounts]
; the performance and efficiency cores' counts, "10 4"; an Intel Mac has one kind of core ("16 0")
Measure=Plugin
Plugin=RunCommand
Parameter=p=$(/usr/sbin/sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || /usr/sbin/sysctl -n hw.logicalcpu); e=$(/usr/sbin/sysctl -n hw.perflevel1.logicalcpu 2>/dev/null || echo 0); echo "$p $e"
State=Hide
Timeout=5000
UpdateDivider=-1
; the counts become PCores and ECores; then the core measures, bars and tooltips follow them
FinishAction=[!UpdateMeasureGroup CoreCounts][!SetVariable PCores [MeasureCountP]][!SetVariable ECores [MeasureCountE]][!UpdateMeasureGroup CoreInfo][!UpdateMeasureGroup Cores][!UpdateMeterGroup Cores][!Redraw]

[MeasureCoreCountsRun]
; asks once, at load
Measure=Calc
Formula=1
UpdateDivider=-1
OnUpdateAction=[!CommandMeasure MeasureCoreCounts "Run"]
