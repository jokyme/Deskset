; Stationery · System — the widget's words in English. Original work, MIT licensed.
; Strings-Chinese.inc has the same keys. A value with a space at either end is quoted, or the INI reader would trim it.
; Menu titles are Title Case and at most 30 characters.

[Variables]
; ---------------------------------------------------------------- menu
SystemMenuOpen=Open Activity Monitor
SystemMenuFourthGPU=Fourth Ring: GPU
SystemMenuFourthSwap=Fourth Ring: Swap
SystemMenuCPUHistory=CPU: History
SystemMenuCPUCores=CPU: Cores
SystemMenuSort0=Sort By: CPU
SystemMenuSort1=Sort By: Memory

; ---------------------------------------------------------------- the card
; the rings' labels (Latin labels are shown in capitals)
SystemCPU=CPU
SystemMemory=Memory
SystemDisk=Disk
SystemGPU=GPU
SystemSwap=Swap
; the header's uptime (%1: "14 d 5 h"), and the width it keeps beside the Mac's name ("Up 23 h 59 min" is 81.9 pt)
SystemUp=Up %1
UptimeReserve=90
SystemBytes=bytes
; the Large
SystemCPUHistory=CPU History
SystemHistoryWindow=5 min
SystemCoresTitleP0=CPU Cores
SystemCoresTitleP1=Performance Cores
SystemCoresTitleE=Efficiency Cores
SystemTopProcesses=Top Processes
SystemSortCPU=CPU
SystemSortMemory=Memory
; process names said in words: macOS's processes of other users and of the system, as one group, and Safari's
; pages and helpers
SystemOtherUsers=Other Users
SystemWebContent=Web Content
SystemWebGraphics=Web Graphics
SystemWebNetworking=Web Networking

; ---------------------------------------------------------------- tooltips (the card's is also its accessibility text)
SystemTipCard="CPU [MeasureCPUText] · Memory [MeasureMemUsed:/1073741824,1] of [MeasureMemTotalText] GB used · Disk [MeasureDiskText] used, [MeasureDiskAvailText] available · "
SystemTipFourthGPU=GPU [MeasureGPUText]
SystemTipFourthSwap=Swap [MeasureSwapText]
SystemTipCardEnd=" · Up [MeasureUptimeText]"
SystemTipCPU=[MeasureCPUText] busy, averaged over 2 seconds.
SystemTipCPUCores0=[MeasureCPUText] busy, averaged over 2 seconds, across all [MeasureCoresAll:0] cores.
SystemTipCPUCores1=[MeasureCPUText] busy, averaged over 2 seconds, across all [MeasureCoresAll:0] cores ([MeasureCoresP:0] performance, [MeasureCoresE:0] efficiency).
SystemTipMemory=[MeasureMemText] of [MeasureMemTotalText] GB used: app, wired and compressed memory, as Activity Monitor counts it.
SystemTipDisk0=[MeasureDiskAvailText] available of [MeasureDiskTotalText] ([MeasureDiskText] used). Available includes space macOS can free, as in Finder.
SystemTipDisk1=[MeasureDiskAvailText] available of [MeasureDiskTotalText] ([MeasureDiskText] used). Nearly full. Available includes space macOS can free, as in Finder.
SystemTipGPU=[MeasureGPUText] busy.
SystemTipSwap0=[MeasureSwapText] of memory is swapped to disk.
SystemTipSwap1=[MeasureSwapText] of memory is swapped to disk. GPU usage isn’t available on this Mac.
SystemTipHistory=CPU use over the last 5 minutes, one sample a second. Now [MeasureCPUText].
SystemTipCoresP0=[MeasureCoresP:0] cores, [MeasurePAvg:0]% busy on average.
SystemTipCoresP1=[MeasureCoresP:0] performance cores, [MeasurePAvg:0]% busy on average.
SystemTipCoresE=[MeasureCoresE:0] efficiency cores, [MeasureEAvg:0]% busy on average.
SystemTipCoresShown0=
SystemTipCoresShown1=" [MeasureCoreShownP:0] of [MeasureCoresP:0] shown."
; one core's bar: "Performance core 3: 11%"
SystemCoreP0=Core
SystemCoreP1=Performance core
SystemCoreE=Efficiency core
SystemCoreSep=": "
SystemTipTop0=Each process’s share of all [MeasureCoresAll:0] cores, on the same scale as the CPU ring. Activity Monitor counts one core as 100%, so it shows these values × [MeasureCoresAll:0].
SystemTipTop1=Memory used by your own processes, as in Activity Monitor’s Memory column. macOS doesn’t let apps read other users’ processes.
SystemTipSortCPU=Sort by CPU
SystemTipSortMemory=Sort by Memory
; a process row, after the process's own name: {pct} its share ("7%"), {cores} the number of cores, {core} Activity
; Monitor's figure (one core = 100 %), {mem} its memory ("3.1 GB")
SystemTipCPURow=: {pct} of all {cores} cores, about {core}% of one core in Activity Monitor.
SystemTipMemRow=" uses {mem} of memory."
SystemTipOtherUsers=Processes of other users and of macOS itself, such as WindowServer and kernel_task. macOS lets Deskset read them only as a group.
