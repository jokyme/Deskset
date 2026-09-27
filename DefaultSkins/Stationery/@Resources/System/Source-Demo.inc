; Stationery · System — the suite's sample readings (SystemSource=Demo, screenshots). Original work, MIT licensed.
; The same sections as Source-Live.inc. A MacBook Pro with 24 GB: CPU 21 %, memory 20.4 GB, Macintosh HD 118 GB
; available of 995 GB, GPU 34 %, up 14 d 5 h. The values below reproduce the widget's states.

[Variables]
DemoName=MacBook Pro
; PowerPlugin's Status: 0 is a Mac without a battery (the desktop glyph)
DemoBattery=1
DemoCPU=21
; 1 draws a CPU history before the last two updates settle on DemoCPU; DemoSteps is the number of updates rendered
; (Counter counts them from 0)
DemoHistory=0
DemoSteps=4
DemoMemUsedGB=20.4
DemoMemTotalGB=24
DemoSwapGB=1.2
DemoDiskAvail=117520000000
DemoDiskTotal=994662584320
DemoDiskName=Macintosh HD
; Finder's figure arrives after this many updates (0: at once)
DemoDiskDelay=0
DemoGPU=34
; the GPU's first reading arrives after this many updates (a large number: never)
DemoGPUDelay=1
; 14 d 5 h 12 min
DemoUptime=1228320

[MeasureDemoTick]
Measure=Calc
Formula=Counter

[MeasureCPU]
Measure=Calc
Formula=(Counter >= #DemoSteps# - 2) ? #DemoCPU# : ((#DemoHistory# = 1) ? (12 + 2.5 * Sin(Counter * 1.9) + 1.5 * Sin(Counter * 0.53) + 1.2 * Sin(Counter * 3.7) + (((Counter > 122) && (Counter < 190)) ? Min(1, Min((Counter - 122) / 8, (190 - Counter) / 8)) * (44 + 3 * Sin(Counter * 2.9)) : 0) + (((Counter > 176) && (Counter < 184)) ? 9 * (1 - Abs(Counter - 180) / 4) : 0)) : #DemoCPU#)
MinValue=0
MaxValue=100
AverageSize=2

[MeasureMemUsed]
Measure=Calc
Formula=#DemoMemUsedGB# * 1073741824
UpdateDivider=2

[MeasureMemTotal]
Measure=Calc
Formula=#DemoMemTotalGB# * 1073741824
UpdateDivider=-1

[MeasureSwapAll]
Measure=Calc
Formula=MeasureMemUsed + #DemoSwapGB# * 1073741824
UpdateDivider=2
Disabled=(1 - #FourthSwap#)
Group=Swap

[MeasureDiskAvail]
Measure=Calc
Formula=(MeasureDemoTick >= #DemoDiskDelay#) ? #DemoDiskAvail# : -1
UpdateDivider=30

[MeasureDiskTotal]
Measure=Calc
Formula=#DemoDiskTotal#
UpdateDivider=30

[MeasureDiskName]
Measure=String
String=#DemoDiskName#
UpdateDivider=-1

[MeasureGPU]
Measure=Calc
Formula=(MeasureDemoTick > #DemoGPUDelay#) ? #DemoGPU# : 0
MinValue=0
MaxValue=100
UpdateDivider=2
IfCondition=MeasureDemoTick > #DemoGPUDelay#
IfTrueAction=[!SetVariable GPUReady 1]
IfFalseAction=[!SetVariable GPUReady 0]

[MeasureUptime]
Measure=Calc
Formula=#DemoUptime#
UpdateDivider=60

[MeasureComputerName]
Measure=String
String=#DemoName#
UpdateDivider=-1

[MeasureBattery]
Measure=Calc
Formula=#DemoBattery#
UpdateDivider=-1
