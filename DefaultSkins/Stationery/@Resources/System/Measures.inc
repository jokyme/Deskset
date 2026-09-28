; Stationery · System — what the rings, values and tooltips show, worked out from the readings of Source-Live.inc (or
; Source-Demo.inc). Every size includes it after its source. Original work, MIT licensed.
;
; Loading: the CPU's first value needs a second reading and the GPU answers one update late, so for a second or two
; their values read "--%" and their rings show only the track. The Disk ring waits for Finder's figure the same way.

[Variables]
; the Swap ring's colour: Teal (Sensors uses Teal for fans, but never next to System's rings); white in the Clear
; look, like every data colour
SwapColorRegular=#Teal#
SwapColorClear=255,255,255
SwapColor=[#SwapColor[#Glass]]
; 1 once the CPU and the GPU have a reading
CPUReady=0
GPUReady=0
; the fourth ring (Medium and Large): 0 GPU, 1 Swap. SystemFourthRing picks it; the GPU's ring gives way to Swap for
; the session when the GPU gives no reading within 5 s (GPUMissing)
FourthSwapGPU=0
FourthSwapSwap=1
FourthSwap=[#FourthSwap[#SystemFourthRing]]
FourthRing=#SystemFourthRing#
GPUMissing=0
; the Disk ring's colours: the storage colour, and red (CriticalColor, text CriticalTextColor) at 95 % used or more
DiskColor=#StorageColor#
DiskTextColor=#TextColor#
DiskFull=0

; ---------------------------------------------------------------- CPU
[MeasureCPUWarm]
; CPUReady from the second update on (Counter counts the updates from 0)
Measure=Calc
Formula=Min(Counter, 1)
IfCondition=MeasureCPUWarm >= 1
IfTrueAction=[!SetVariable CPUReady 1]

[MeasureCPUAngle]
; 0 % still shows a dot, 100 % a closed ring
Measure=Calc
Formula=Clamp(MeasureCPU * 3.6, 0.6, 359.4)

[MeasureCPULarge]
Measure=Calc
Formula=MeasureCPUAngle > 180

[MeasureCPUText]
; "21%", or "--%" before the second reading
Measure=String
String=#CPUReady#|[MeasureCPU:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^0\|.*$":"#Missing#%","^1\|(.*)$":"\1%"

; ---------------------------------------------------------------- memory
[MeasureMemAngle]
Measure=Calc
Formula=Clamp(MeasureMemUsed / Max(1, MeasureMemTotal) * 360, 0.6, 359.4)
UpdateDivider=2

[MeasureMemLarge]
Measure=Calc
Formula=MeasureMemAngle > 180
UpdateDivider=2

[MeasureMemText]
; "20.4 GB": binary gigabytes with one decimal, as Activity Monitor
Measure=String
String=[MeasureMemUsed:/1073741824,1] GB
DynamicVariables=1
UpdateDivider=2

[MeasureMemTotalText]
; "24"
Measure=String
String=[MeasureMemTotal:/1073741824,0]
DynamicVariables=1
UpdateDivider=-1

; ---------------------------------------------------------------- swap
[MeasureSwapUsed]
; bytes swapped to disk
Measure=Calc
Formula=Max(0, MeasureSwapAll - MeasureMemUsed)
UpdateDivider=2
Disabled=(1 - #FourthSwap#)
Group=Swap

[MeasureSwapAngle]
; swap in use against the Mac's memory, so light swapping stays calm and heavy swapping fills the ring
Measure=Calc
Formula=Clamp(360 * Min(1, MeasureSwapUsed / Max(1, MeasureMemTotal)), 0.6, 359.4)
UpdateDivider=2
Disabled=(1 - #FourthSwap#)
Group=Swap

[MeasureSwapLarge]
Measure=Calc
Formula=MeasureSwapAngle > 180
UpdateDivider=2
Disabled=(1 - #FourthSwap#)
Group=Swap

[MeasureSwapText]
; "1.2 GB" from a gigabyte, "684 MB" below it
Measure=String
String=[MeasureSwapUsed:/1073741824,1]|[MeasureSwapUsed:/1048576,0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^0\.\d\|(\d+)$":"\1 MB","^(\d+\.\d)\|.*$":"\1 GB"
UpdateDivider=2
Disabled=(1 - #FourthSwap#)
Group=Swap

; ---------------------------------------------------------------- disk
[MeasureDiskUsedPct]
; whole percent used, as Finder counts it; -1 while Finder's figure is not in yet
Measure=Calc
Formula=(MeasureDiskAvail < 0) ? -1 : Round(100 * (1 - MeasureDiskAvail / Max(1, MeasureDiskTotal)))
UpdateDivider=30
Group=Disk
IfCondition=MeasureDiskUsedPct >= 95
IfTrueAction=[!SetVariable DiskColor "#CriticalColor#"][!SetVariable DiskTextColor "#CriticalTextColor#"][!SetVariable DiskFull 1]
IfFalseAction=[!SetVariable DiskColor "#StorageColor#"][!SetVariable DiskTextColor "#TextColor#"][!SetVariable DiskFull 0]

[MeasureDiskAngle]
Measure=Calc
Formula=Clamp(MeasureDiskUsedPct * 3.6, 0.6, 359.4)
UpdateDivider=30
Group=Disk

[MeasureDiskLarge]
Measure=Calc
Formula=MeasureDiskAngle > 180
UpdateDivider=30
Group=Disk

[MeasureDiskText]
; "88%", or "--%" while loading
Measure=String
String=[MeasureDiskUsedPct:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^-\d+$":"#Missing#%","^(\d+)$":"\1%"
UpdateDivider=30
Group=Disk

[MeasureDiskAvailPower]
; bytes as Finder writes them: 1 GB = 10⁹ bytes, one decimal below 100, none from 100 ("118 GB", "38.4 GB", "2 TB").
; The power of 1000 (0 bytes … 4 TB); 0.9995 moves 999.6 GB up to "1 TB"
Measure=Calc
Formula=Clamp(Floor(Log(Max(MeasureDiskAvail, 1) / 0.9995) / 3), 0, 4)
UpdateDivider=30
Group=Disk

[MeasureDiskAvailScaled]
Measure=Calc
Formula=((MeasureDiskAvail / 1000 ** MeasureDiskAvailPower) >= 99.95) ? Round(MeasureDiskAvail / 1000 ** MeasureDiskAvailPower) : Round(MeasureDiskAvail / 1000 ** MeasureDiskAvailPower, 1)
UpdateDivider=30
Group=Disk

[MeasureDiskAvailText]
Measure=String
String=[MeasureDiskAvailScaled:1] U[MeasureDiskAvailPower:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="\.0(?= U)":""," U0$":" #SystemBytes#"," U1$":" KB"," U2$":" MB"," U3$":" GB"," U4$":" TB"
UpdateDivider=30
Group=Disk

[MeasureDiskTotalPower]
Measure=Calc
Formula=Clamp(Floor(Log(Max(MeasureDiskTotal, 1) / 0.9995) / 3), 0, 4)
UpdateDivider=30
Group=Disk

[MeasureDiskTotalScaled]
Measure=Calc
Formula=((MeasureDiskTotal / 1000 ** MeasureDiskTotalPower) >= 99.95) ? Round(MeasureDiskTotal / 1000 ** MeasureDiskTotalPower) : Round(MeasureDiskTotal / 1000 ** MeasureDiskTotalPower, 1)
UpdateDivider=30
Group=Disk

[MeasureDiskTotalText]
Measure=String
String=[MeasureDiskTotalScaled:1] U[MeasureDiskTotalPower:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="\.0(?= U)":""," U0$":" #SystemBytes#"," U1$":" KB"," U2$":" MB"," U3$":" GB"," U4$":" TB"
UpdateDivider=30
Group=Disk

[MeasureDiskShown]
; everything the Disk ring, its value and its tooltip show: they are part of the window's kept picture, and are drawn
; again only when this changes
Measure=String
String=[MeasureDiskText] [MeasureDiskAvailText] [MeasureDiskTotalText] #DiskFull#
DynamicVariables=1
UpdateDivider=30
Group=Disk
OnChangeAction=[!UpdateMeterGroup Disk]

[MeasureDiskLoading]
; Finder's figure can take a moment to arrive: while it is missing, read the disk again every second instead of at the
; next 30 s update, for at most half a minute
Measure=Calc
Formula=(Counter < 31) * (MeasureDiskAvail < 0)
IfConditionMode=1
IfCondition=MeasureDiskLoading = 1
IfTrueAction=[!UpdateMeasure MeasureDiskAvail][!UpdateMeasure MeasureDiskTotal][!UpdateMeasureGroup Disk][!UpdateMeterGroup Disk][!Redraw]

; ---------------------------------------------------------------- GPU
[MeasureGPUAngle]
Measure=Calc
Formula=Clamp(MeasureGPU * 3.6, 0.6, 359.4)
UpdateDivider=2

[MeasureGPULarge]
Measure=Calc
Formula=MeasureGPUAngle > 180
UpdateDivider=2

[MeasureGPUText]
; "34%", or "--%" before the first reading
Measure=String
String=#GPUReady#|[MeasureGPU:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^0\|.*$":"#Missing#%","^1\|(.*)$":"\1%"
UpdateDivider=2

[MeasureGPUWatch]
; still no GPU reading 5 s after loading (some Macs and virtual machines cannot tell): the fourth ring shows Swap
; until the widget is loaded again. Nothing is written to Variables.inc
Measure=Calc
Formula=Min(Counter, 6)
DynamicVariables=1
IfCondition=(MeasureGPUWatch = 5) && (#GPUReady# = 0) && (#FourthSwap# = 0)
IfTrueAction=[!SetVariable FourthSwap 1][!SetVariable FourthRing Swap][!SetVariable GPUMissing 1][!EnableMeasureGroup Swap][!UpdateMeasureGroup Swap][!HideMeterGroup RingGPU][!ShowMeterGroup RingSwap][!UpdateMeterGroup RingSwap][!UpdateMeasure MeasureSentence][!Redraw]

; ---------------------------------------------------------------- the header
[MeasureDesktopMac]
; a Mac without a battery shows a desktop computer in the header
Measure=Calc
Formula=MeasureBattery = 0
UpdateDivider=-1
IfCondition=MeasureDesktopMac = 1
IfTrueAction=[!HideMeter MeterLaptopGlyph][!ShowMeter MeterDesktopGlyph]
IfFalseAction=[!ShowMeter MeterLaptopGlyph][!HideMeter MeterDesktopGlyph]

[MeasureUpD]
Measure=Calc
Formula=Floor(MeasureUptime / 86400)
UpdateDivider=60

[MeasureUpH]
Measure=Calc
Formula=Floor((MeasureUptime % 86400) / 3600)
UpdateDivider=60

[MeasureUpM]
Measure=Calc
Formula=Floor((MeasureUptime % 3600) / 60)
UpdateDivider=60

[MeasureUptimeText]
; "14 d 5 h" from a day, "5 h 12 min" below it, "12 min" below an hour: units, never colons
Measure=String
String=[MeasureUpD:0] #UnitDay# [MeasureUpH:0] #UnitHour# [MeasureUpM:0] #UnitMinute#
DynamicVariables=1
RegExpSubstitute=1
Substitute="^0 \S+ ":"","^(\d+ \S+ \d+ \S+) \d+ \S+$":"\1","^0 \S+ ":""," 0 \S+$":""
UpdateDivider=60
; the header's uptime is part of the window's kept picture: drawn again only when the text changes
OnChangeAction=[!UpdateMeterGroup Uptime]

; ---------------------------------------------------------------- the card's sentence
[MeasureSentence]
; "CPU 21% · Memory 20.4 of 24 GB used · Disk 88% used, 118 GB available · GPU 34% · Up 14 d 5 h": the card's tooltip,
; read when it opens
Measure=String
String=#SystemTipCard#[#SystemTipFourth[#FourthRing]]#SystemTipCardEnd#
DynamicVariables=1
UpdateDivider=5
