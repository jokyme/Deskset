; Stationery · System — the readings, from this Mac. Original work, MIT licensed.
; Source-Demo.inc has the same sections with the suite's sample values (SystemSource=Demo, for screenshots). Nothing
; here asks for a permission.

[MeasureCPU]
; the whole CPU, 0–100, averaged over two readings: the ring, its value and the Large's history
Measure=CPU
Processor=0
AverageSize=2

[MeasureMemUsed]
; app, wired and compressed memory: Activity Monitor's "Memory Used"
Measure=PhysicalMemory
UpdateDivider=2

[MeasureMemTotal]
Measure=PhysicalMemory
Total=1
UpdateDivider=-1

[MeasureSwapAll]
; memory plus swap in use (Deskset's SwapMemory, like Rainmeter's RAM plus page file), read only while the Swap
; ring is on the card
Measure=SwapMemory
UpdateDivider=2
Disabled=(1 - #FourthSwap#)
Group=Swap

[MeasureDiskAvail]
; the startup disk's available space as Finder counts it (space macOS can free included); -1 until the first reading
Measure=FreeDiskSpace
Drive=/
MacAvailable=1
IgnoreRemovable=0
UpdateDivider=30

[MeasureDiskTotal]
Measure=FreeDiskSpace
Drive=/
Total=1
IgnoreRemovable=0
UpdateDivider=30

[MeasureDiskName]
; "Macintosh HD"
Measure=FreeDiskSpace
Drive=/
Label=1
IgnoreRemovable=0
UpdateDivider=-1

[MeasureGPU]
; the graphics processor's load, 0–100 (IOKit's accelerator statistics). Empty until the first reading, which comes
; one update late
Measure=Plugin
Plugin=MacSensors
Sensor=gpu.usage
UpdateDivider=2
IfMatch=^$
IfMatchAction=[!SetVariable GPUReady 0]
IfNotMatchAction=[!SetVariable GPUReady 1]

[MeasureUptime]
; seconds since this Mac started
Measure=Uptime
UpdateDivider=60

[MeasureComputerName]
; the name in System Settings › General › Sharing
Measure=SysInfo
SysInfoType=COMPUTER_NAME
UpdateDivider=-1

[MeasureBattery]
; 0 on a Mac without a battery (the header then shows a desktop Mac)
Measure=Plugin
Plugin=PowerPlugin
PowerState=Status
UpdateDivider=-1
