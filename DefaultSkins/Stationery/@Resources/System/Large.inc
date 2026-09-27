; Stationery · System — what the Large shows beyond the rings: the core counts and the bars' geometry, the averages
; of each kind of core, and the rows of Top Processes. Original work, MIT licensed.

[Variables]
; the core counts, from MeasureCoreCounts at load (0 until then)
PCores=0
ECores=0
; the middle band: 0 History, 1 Cores (SystemCPUView)
CoresViewHistory=0
CoresViewCores=1
CoresView=[#CoresView[#SystemCPUView]]

; ---------------------------------------------------------------- core counts
[MeasureCountP]
Measure=String
String=[MeasureCoreCounts]
DynamicVariables=1
UpdateDivider=-1
Group=CoreCounts
RegExpSubstitute=1
; "10 4" → "10"; nothing → "0"
Substitute="(?s)^\D*$":"0","(?s)^\D*(\d+).*$":"\1"

[MeasureCountE]
Measure=String
String=[MeasureCoreCounts]
DynamicVariables=1
UpdateDivider=-1
Group=CoreCounts
RegExpSubstitute=1
; "10 4" → "4"; a single count (an Intel Mac) or nothing → "0". The substitutions run in order, so the one-number
; case comes first
Substitute="(?s)^\D*\d*\D*$":"0","(?s)^\D*\d+\D+(\d+).*$":"\1"

[MeasureCoresP]
Measure=Calc
Formula=#PCores#
DynamicVariables=1
UpdateDivider=-1
Group=CoreInfo

[MeasureCoresE]
Measure=Calc
Formula=#ECores#
DynamicVariables=1
UpdateDivider=-1
Group=CoreInfo

[MeasureCoresAll]
Measure=Calc
Formula=#PCores# + #ECores#
DynamicVariables=1
UpdateDivider=-1
Group=CoreInfo

[MeasureCoreKinds]
; 1 when the Mac has performance and efficiency cores, 0 when all its cores are alike (Intel)
Measure=Calc
Formula=#ECores# > 0
DynamicVariables=1
UpdateDivider=-1
Group=CoreInfo

[MeasureCoreShownP]
; at most 32 performance and 8 efficiency levels
Measure=Calc
Formula=Min(32, #PCores#)
DynamicVariables=1
UpdateDivider=-1
Group=CoreInfo

[MeasureCoreShownE]
Measure=Calc
Formula=Min(8, #ECores#)
DynamicVariables=1
UpdateDivider=-1
Group=CoreInfo

[MeasureCoresMany]
; 1 when not every core has a level (more than 32 of one kind)
Measure=Calc
Formula=#PCores# > 32
DynamicVariables=1
UpdateDivider=-1
Group=CoreInfo

[MeasureCoreSlots]
; the levels, plus one empty slot between the kinds
Measure=Calc
Formula=MeasureCoreShownP + MeasureCoreShownE + ((MeasureCoreShownE > 0) ? 1 : 0)
UpdateDivider=-1
Group=CoreInfo

[MeasureCoreW]
; at most 8 wide: the family's strokes are Ring M 7 and Ring L 8
Measure=Calc
Formula=Min(8, 328 / Max(1, 2 * MeasureCoreSlots - 1))
UpdateDivider=-1
Group=CoreInfo

[MeasureCorePitch]
; the last level ends on x 344
Measure=Calc
Formula=(328 - MeasureCoreW) / Max(1, MeasureCoreSlots - 1)
UpdateDivider=-1
Group=CoreInfo

[MeasurePAvg]
Measure=Calc
Formula=(MeasureP1 * (1 <= MeasureCoreShownP) + MeasureP2 * (2 <= MeasureCoreShownP) + MeasureP3 * (3 <= MeasureCoreShownP) + MeasureP4 * (4 <= MeasureCoreShownP) + MeasureP5 * (5 <= MeasureCoreShownP) + MeasureP6 * (6 <= MeasureCoreShownP) + MeasureP7 * (7 <= MeasureCoreShownP) + MeasureP8 * (8 <= MeasureCoreShownP) + MeasureP9 * (9 <= MeasureCoreShownP) + MeasureP10 * (10 <= MeasureCoreShownP) + MeasureP11 * (11 <= MeasureCoreShownP) + MeasureP12 * (12 <= MeasureCoreShownP) + MeasureP13 * (13 <= MeasureCoreShownP) + MeasureP14 * (14 <= MeasureCoreShownP) + MeasureP15 * (15 <= MeasureCoreShownP) + MeasureP16 * (16 <= MeasureCoreShownP) + MeasureP17 * (17 <= MeasureCoreShownP) + MeasureP18 * (18 <= MeasureCoreShownP) + MeasureP19 * (19 <= MeasureCoreShownP) + MeasureP20 * (20 <= MeasureCoreShownP) + MeasureP21 * (21 <= MeasureCoreShownP) + MeasureP22 * (22 <= MeasureCoreShownP) + MeasureP23 * (23 <= MeasureCoreShownP) + MeasureP24 * (24 <= MeasureCoreShownP) + MeasureP25 * (25 <= MeasureCoreShownP) + MeasureP26 * (26 <= MeasureCoreShownP) + MeasureP27 * (27 <= MeasureCoreShownP) + MeasureP28 * (28 <= MeasureCoreShownP) + MeasureP29 * (29 <= MeasureCoreShownP) + MeasureP30 * (30 <= MeasureCoreShownP) + MeasureP31 * (31 <= MeasureCoreShownP) + MeasureP32 * (32 <= MeasureCoreShownP)) / Max(1, MeasureCoreShownP)
Disabled=(1 - #CoresView#)
Group=Cores

[MeasureEAvg]
Measure=Calc
Formula=(MeasureE1 * (1 <= MeasureCoreShownE) + MeasureE2 * (2 <= MeasureCoreShownE) + MeasureE3 * (3 <= MeasureCoreShownE) + MeasureE4 * (4 <= MeasureCoreShownE) + MeasureE5 * (5 <= MeasureCoreShownE) + MeasureE6 * (6 <= MeasureCoreShownE) + MeasureE7 * (7 <= MeasureCoreShownE) + MeasureE8 * (8 <= MeasureCoreShownE)) / Max(1, MeasureCoreShownE)
Disabled=(1 - #CoresView#)
Group=Cores

; ---------------------------------------------------------------- Top Processes
[MeasureSortBy]
; 0 CPU, 1 Memory: the segmented control and the menu set SystemSortBy and update this measure, which switches the
; rows (only the sort on show reads the processes)
Measure=Calc
Formula=#SystemSortBy#
DynamicVariables=1
UpdateDivider=-1
IfConditionMode=1
IfCondition=MeasureSortBy = 0
IfTrueAction=[!DisableMeasureGroup TopMem][!EnableMeasureGroup TopCPU][!UpdateMeasureGroup TopCPU][!HideMeterGroup RowsMem][!ShowMeterGroup RowsCPU][!UpdateMeterGroup RowsCPU][!UpdateMeterGroup Seg][!Redraw]
IfCondition2=MeasureSortBy = 1
IfTrueAction2=[!DisableMeasureGroup TopCPU][!EnableMeasureGroup TopMem][!UpdateMeasureGroup TopMem][!HideMeterGroup RowsCPU][!ShowMeterGroup RowsMem][!UpdateMeterGroup RowsMem][!UpdateMeterGroup Seg][!Redraw]

[MeasureTopCPU1Name]
; the processes of other users and of macOS (UsageMonitor's "System") are "Other Users", Safari's pages and helpers
; are said in words, and Chromium apps' helpers lose "Helper"; the tooltip keeps the process's own name
Measure=String
String=[MeasureTopCPU1]
DynamicVariables=1
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU
RegExpSubstitute=1
Substitute="^System$":"#SystemOtherUsers#","^com\.apple\.WebKit\.WebContent$":"#SystemWebContent#","^com\.apple\.WebKit\.GPU$":"#SystemWebGraphics#","^com\.apple\.WebKit\.Networking$":"#SystemWebNetworking#","^(.+?) Helper \((Renderer|GPU|Plugin)\)$":"\1 (\2)"

[MeasureTopCPU1Pct]
; whole percent; -1 under 0.5 % (shown "<1%": a row never says 0 %)
Measure=Calc
Formula=(MeasureTopCPU1 < 0.5) ? -1 : Round(MeasureTopCPU1)
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU

[MeasureTopCPU1Text]
; "7%", "<1%", or nothing when there is no 1th process
Measure=String
String=[MeasureTopCPU1]|[MeasureTopCPU1Pct:0]
DynamicVariables=1
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU
RegExpSubstitute=1
Substitute="^\|.*$":"","^.*\|-1$":"<1%","^.*\|(\d+)$":"\1%"

[MeasureTopCPU1Core]
; Activity Monitor's figure, where one core is 100 %
Measure=Calc
Formula=Round(MeasureTopCPU1 * MeasureCoresAll)
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU

[MeasureTopCPU1Tip]
Measure=String
String=[MeasureTopCPU1]
DynamicVariables=1
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU
RegExpSubstitute=1
Substitute="^(?!System$)(.+)$":"\1#SystemTipCPURow#","\{pct\}":"[MeasureTopCPU1Text]","\{cores\}":"[MeasureCoresAll:0]","\{core\}":"[MeasureTopCPU1Core:0]","^System$":"#SystemTipOtherUsers#"

[MeasureTopCPU2Name]
Measure=String
String=[MeasureTopCPU2]
DynamicVariables=1
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU
RegExpSubstitute=1
Substitute="^System$":"#SystemOtherUsers#","^com\.apple\.WebKit\.WebContent$":"#SystemWebContent#","^com\.apple\.WebKit\.GPU$":"#SystemWebGraphics#","^com\.apple\.WebKit\.Networking$":"#SystemWebNetworking#","^(.+?) Helper \((Renderer|GPU|Plugin)\)$":"\1 (\2)"

[MeasureTopCPU2Pct]
; whole percent; -1 under 0.5 % (shown "<1%": a row never says 0 %)
Measure=Calc
Formula=(MeasureTopCPU2 < 0.5) ? -1 : Round(MeasureTopCPU2)
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU

[MeasureTopCPU2Text]
; "7%", "<1%", or nothing when there is no 2th process
Measure=String
String=[MeasureTopCPU2]|[MeasureTopCPU2Pct:0]
DynamicVariables=1
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU
RegExpSubstitute=1
Substitute="^\|.*$":"","^.*\|-1$":"<1%","^.*\|(\d+)$":"\1%"

[MeasureTopCPU2Core]
; Activity Monitor's figure, where one core is 100 %
Measure=Calc
Formula=Round(MeasureTopCPU2 * MeasureCoresAll)
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU

[MeasureTopCPU2Tip]
Measure=String
String=[MeasureTopCPU2]
DynamicVariables=1
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU
RegExpSubstitute=1
Substitute="^(?!System$)(.+)$":"\1#SystemTipCPURow#","\{pct\}":"[MeasureTopCPU2Text]","\{cores\}":"[MeasureCoresAll:0]","\{core\}":"[MeasureTopCPU2Core:0]","^System$":"#SystemTipOtherUsers#"

[MeasureTopCPU3Name]
Measure=String
String=[MeasureTopCPU3]
DynamicVariables=1
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU
RegExpSubstitute=1
Substitute="^System$":"#SystemOtherUsers#","^com\.apple\.WebKit\.WebContent$":"#SystemWebContent#","^com\.apple\.WebKit\.GPU$":"#SystemWebGraphics#","^com\.apple\.WebKit\.Networking$":"#SystemWebNetworking#","^(.+?) Helper \((Renderer|GPU|Plugin)\)$":"\1 (\2)"

[MeasureTopCPU3Pct]
; whole percent; -1 under 0.5 % (shown "<1%": a row never says 0 %)
Measure=Calc
Formula=(MeasureTopCPU3 < 0.5) ? -1 : Round(MeasureTopCPU3)
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU

[MeasureTopCPU3Text]
; "7%", "<1%", or nothing when there is no 3th process
Measure=String
String=[MeasureTopCPU3]|[MeasureTopCPU3Pct:0]
DynamicVariables=1
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU
RegExpSubstitute=1
Substitute="^\|.*$":"","^.*\|-1$":"<1%","^.*\|(\d+)$":"\1%"

[MeasureTopCPU3Core]
; Activity Monitor's figure, where one core is 100 %
Measure=Calc
Formula=Round(MeasureTopCPU3 * MeasureCoresAll)
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU

[MeasureTopCPU3Tip]
Measure=String
String=[MeasureTopCPU3]
DynamicVariables=1
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU
RegExpSubstitute=1
Substitute="^(?!System$)(.+)$":"\1#SystemTipCPURow#","\{pct\}":"[MeasureTopCPU3Text]","\{cores\}":"[MeasureCoresAll:0]","\{core\}":"[MeasureTopCPU3Core:0]","^System$":"#SystemTipOtherUsers#"

[MeasureTopCPU4Name]
Measure=String
String=[MeasureTopCPU4]
DynamicVariables=1
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU
RegExpSubstitute=1
Substitute="^System$":"#SystemOtherUsers#","^com\.apple\.WebKit\.WebContent$":"#SystemWebContent#","^com\.apple\.WebKit\.GPU$":"#SystemWebGraphics#","^com\.apple\.WebKit\.Networking$":"#SystemWebNetworking#","^(.+?) Helper \((Renderer|GPU|Plugin)\)$":"\1 (\2)"

[MeasureTopCPU4Pct]
; whole percent; -1 under 0.5 % (shown "<1%": a row never says 0 %)
Measure=Calc
Formula=(MeasureTopCPU4 < 0.5) ? -1 : Round(MeasureTopCPU4)
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU

[MeasureTopCPU4Text]
; "7%", "<1%", or nothing when there is no 4th process
Measure=String
String=[MeasureTopCPU4]|[MeasureTopCPU4Pct:0]
DynamicVariables=1
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU
RegExpSubstitute=1
Substitute="^\|.*$":"","^.*\|-1$":"<1%","^.*\|(\d+)$":"\1%"

[MeasureTopCPU4Core]
; Activity Monitor's figure, where one core is 100 %
Measure=Calc
Formula=Round(MeasureTopCPU4 * MeasureCoresAll)
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU

[MeasureTopCPU4Tip]
Measure=String
String=[MeasureTopCPU4]
DynamicVariables=1
UpdateDivider=2
Disabled=#SystemSortBy#
Group=TopCPU
RegExpSubstitute=1
Substitute="^(?!System$)(.+)$":"\1#SystemTipCPURow#","\{pct\}":"[MeasureTopCPU4Text]","\{cores\}":"[MeasureCoresAll:0]","\{core\}":"[MeasureTopCPU4Core:0]","^System$":"#SystemTipOtherUsers#"

[MeasureTopMem1Name]
Measure=String
String=[MeasureTopMem1]
DynamicVariables=1
UpdateDivider=2
Disabled=(1 - #SystemSortBy#)
Group=TopMem
RegExpSubstitute=1
Substitute="^System$":"#SystemOtherUsers#","^com\.apple\.WebKit\.WebContent$":"#SystemWebContent#","^com\.apple\.WebKit\.GPU$":"#SystemWebGraphics#","^com\.apple\.WebKit\.Networking$":"#SystemWebNetworking#","^(.+?) Helper \((Renderer|GPU|Plugin)\)$":"\1 (\2)"

[MeasureTopMem1Text]
; "3.1 GB" from a gigabyte, "684 MB" below it, nothing when there is no 1th process
Measure=String
String=[MeasureTopMem1]|[MeasureTopMem1:/1073741824,1]|[MeasureTopMem1:/1048576,0]
DynamicVariables=1
UpdateDivider=2
Disabled=(1 - #SystemSortBy#)
Group=TopMem
RegExpSubstitute=1
Substitute="^\|.*$":"","^.*\|0\.\d\|(\d+)$":"\1 MB","^.*\|(\d+\.\d)\|\d+$":"\1 GB"

[MeasureTopMem1Tip]
Measure=String
String=[MeasureTopMem1]
DynamicVariables=1
UpdateDivider=2
Disabled=(1 - #SystemSortBy#)
Group=TopMem
RegExpSubstitute=1
Substitute="^(.+)$":"\1#SystemTipMemRow#","\{mem\}":"[MeasureTopMem1Text]"

[MeasureTopMem2Name]
Measure=String
String=[MeasureTopMem2]
DynamicVariables=1
UpdateDivider=2
Disabled=(1 - #SystemSortBy#)
Group=TopMem
RegExpSubstitute=1
Substitute="^System$":"#SystemOtherUsers#","^com\.apple\.WebKit\.WebContent$":"#SystemWebContent#","^com\.apple\.WebKit\.GPU$":"#SystemWebGraphics#","^com\.apple\.WebKit\.Networking$":"#SystemWebNetworking#","^(.+?) Helper \((Renderer|GPU|Plugin)\)$":"\1 (\2)"

[MeasureTopMem2Text]
; "3.1 GB" from a gigabyte, "684 MB" below it, nothing when there is no 2th process
Measure=String
String=[MeasureTopMem2]|[MeasureTopMem2:/1073741824,1]|[MeasureTopMem2:/1048576,0]
DynamicVariables=1
UpdateDivider=2
Disabled=(1 - #SystemSortBy#)
Group=TopMem
RegExpSubstitute=1
Substitute="^\|.*$":"","^.*\|0\.\d\|(\d+)$":"\1 MB","^.*\|(\d+\.\d)\|\d+$":"\1 GB"

[MeasureTopMem2Tip]
Measure=String
String=[MeasureTopMem2]
DynamicVariables=1
UpdateDivider=2
Disabled=(1 - #SystemSortBy#)
Group=TopMem
RegExpSubstitute=1
Substitute="^(.+)$":"\1#SystemTipMemRow#","\{mem\}":"[MeasureTopMem2Text]"

[MeasureTopMem3Name]
Measure=String
String=[MeasureTopMem3]
DynamicVariables=1
UpdateDivider=2
Disabled=(1 - #SystemSortBy#)
Group=TopMem
RegExpSubstitute=1
Substitute="^System$":"#SystemOtherUsers#","^com\.apple\.WebKit\.WebContent$":"#SystemWebContent#","^com\.apple\.WebKit\.GPU$":"#SystemWebGraphics#","^com\.apple\.WebKit\.Networking$":"#SystemWebNetworking#","^(.+?) Helper \((Renderer|GPU|Plugin)\)$":"\1 (\2)"

[MeasureTopMem3Text]
; "3.1 GB" from a gigabyte, "684 MB" below it, nothing when there is no 3th process
Measure=String
String=[MeasureTopMem3]|[MeasureTopMem3:/1073741824,1]|[MeasureTopMem3:/1048576,0]
DynamicVariables=1
UpdateDivider=2
Disabled=(1 - #SystemSortBy#)
Group=TopMem
RegExpSubstitute=1
Substitute="^\|.*$":"","^.*\|0\.\d\|(\d+)$":"\1 MB","^.*\|(\d+\.\d)\|\d+$":"\1 GB"

[MeasureTopMem3Tip]
Measure=String
String=[MeasureTopMem3]
DynamicVariables=1
UpdateDivider=2
Disabled=(1 - #SystemSortBy#)
Group=TopMem
RegExpSubstitute=1
Substitute="^(.+)$":"\1#SystemTipMemRow#","\{mem\}":"[MeasureTopMem3Text]"

[MeasureTopMem4Name]
Measure=String
String=[MeasureTopMem4]
DynamicVariables=1
UpdateDivider=2
Disabled=(1 - #SystemSortBy#)
Group=TopMem
RegExpSubstitute=1
Substitute="^System$":"#SystemOtherUsers#","^com\.apple\.WebKit\.WebContent$":"#SystemWebContent#","^com\.apple\.WebKit\.GPU$":"#SystemWebGraphics#","^com\.apple\.WebKit\.Networking$":"#SystemWebNetworking#","^(.+?) Helper \((Renderer|GPU|Plugin)\)$":"\1 (\2)"

[MeasureTopMem4Text]
; "3.1 GB" from a gigabyte, "684 MB" below it, nothing when there is no 4th process
Measure=String
String=[MeasureTopMem4]|[MeasureTopMem4:/1073741824,1]|[MeasureTopMem4:/1048576,0]
DynamicVariables=1
UpdateDivider=2
Disabled=(1 - #SystemSortBy#)
Group=TopMem
RegExpSubstitute=1
Substitute="^\|.*$":"","^.*\|0\.\d\|(\d+)$":"\1 MB","^.*\|(\d+\.\d)\|\d+$":"\1 GB"

[MeasureTopMem4Tip]
Measure=String
String=[MeasureTopMem4]
DynamicVariables=1
UpdateDivider=2
Disabled=(1 - #SystemSortBy#)
Group=TopMem
RegExpSubstitute=1
Substitute="^(.+)$":"\1#SystemTipMemRow#","\{mem\}":"[MeasureTopMem4Text]"
