; Stationery · System — the Large's sample readings (SystemSource=Demo, screenshots). Original work, MIT licensed.
; The same sections as Processes-Live.inc. A process's measure gives its share (or bytes) as its number and its name
; as its text, as UsageMonitor does; "System" stands for the processes of other users and of macOS.

[Variables]
DemoTopCPU1Name=com.apple.WebKit.WebContent
DemoTopCPU1=7.2
DemoTopCPU2Name=System
DemoTopCPU2=4.8
DemoTopCPU3Name=Safari
DemoTopCPU3=2.1
DemoTopCPU4Name=Music
DemoTopCPU4=1.2
DemoTopMem1Name=com.apple.WebKit.WebContent
DemoTopMem1=3328599654
DemoTopMem2Name=Mail
DemoTopMem2=717225984
DemoTopMem3Name=Safari
DemoTopMem3=546308096
DemoTopMem4Name=Music
DemoTopMem4=327155712
DemoPCores=10
DemoECores=4

[MeasureTopCPU1]
Measure=String
String=#DemoTopCPU1#
RegExpSubstitute=1
Substitute="^.*$":"#DemoTopCPU1Name#"
UpdateDivider=4
Disabled=#SystemSortBy#
Group=TopCPU

[MeasureTopCPU2]
Measure=String
String=#DemoTopCPU2#
RegExpSubstitute=1
Substitute="^.*$":"#DemoTopCPU2Name#"
UpdateDivider=4
Disabled=#SystemSortBy#
Group=TopCPU

[MeasureTopCPU3]
Measure=String
String=#DemoTopCPU3#
RegExpSubstitute=1
Substitute="^.*$":"#DemoTopCPU3Name#"
UpdateDivider=4
Disabled=#SystemSortBy#
Group=TopCPU

[MeasureTopCPU4]
Measure=String
String=#DemoTopCPU4#
RegExpSubstitute=1
Substitute="^.*$":"#DemoTopCPU4Name#"
UpdateDivider=4
Disabled=#SystemSortBy#
Group=TopCPU

[MeasureTopMem1]
Measure=String
String=#DemoTopMem1#
RegExpSubstitute=1
Substitute="^.*$":"#DemoTopMem1Name#"
UpdateDivider=4
Disabled=(1 - #SystemSortBy#)
Group=TopMem

[MeasureTopMem2]
Measure=String
String=#DemoTopMem2#
RegExpSubstitute=1
Substitute="^.*$":"#DemoTopMem2Name#"
UpdateDivider=4
Disabled=(1 - #SystemSortBy#)
Group=TopMem

[MeasureTopMem3]
Measure=String
String=#DemoTopMem3#
RegExpSubstitute=1
Substitute="^.*$":"#DemoTopMem3Name#"
UpdateDivider=4
Disabled=(1 - #SystemSortBy#)
Group=TopMem

[MeasureTopMem4]
Measure=String
String=#DemoTopMem4#
RegExpSubstitute=1
Substitute="^.*$":"#DemoTopMem4Name#"
UpdateDivider=4
Disabled=(1 - #SystemSortBy#)
Group=TopMem

[MeasureCoreCounts]
Measure=Plugin
Plugin=RunCommand
Parameter=echo "#DemoPCores# #DemoECores#"
State=Hide
Timeout=5000
UpdateDivider=-1
FinishAction=[!UpdateMeasureGroup CoreCounts][!SetVariable PCores [MeasureCountP]][!SetVariable ECores [MeasureCountE]][!UpdateMeasureGroup CoreInfo][!UpdateMeasureGroup Cores][!UpdateMeterGroup Cores][!Redraw]

[MeasureCoreCountsRun]
Measure=Calc
Formula=1
UpdateDivider=-1
OnUpdateAction=[!CommandMeasure MeasureCoreCounts "Run"]
