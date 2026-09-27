; Stationery · System — the widget's words in Simplified Chinese. Original work, MIT licensed.
; The same keys as Strings-English.inc. A value with a space at either end is quoted, or the INI reader would trim it.

[Variables]
; ---------------------------------------------------------------- menu
SystemMenuOpen=打开活动监视器
SystemMenuFourthGPU=第四个圆环：GPU
SystemMenuFourthSwap=第四个圆环：交换
SystemMenuCPUHistory=CPU：历史记录
SystemMenuCPUCores=CPU：各个核心
SystemMenuSort0=排序方式：CPU
SystemMenuSort1=排序方式：内存

; ---------------------------------------------------------------- the card
SystemCPU=CPU
SystemMemory=内存
SystemDisk=磁盘
SystemGPU=GPU
SystemSwap=交换
; "运行 23 小时 59 分钟" is 106.5 pt
SystemUp=运行 %1
UptimeReserve=110
SystemBytes=字节
SystemCPUHistory=CPU 历史记录
SystemHistoryWindow=5 分钟
SystemCoresTitleP0=CPU 核心
SystemCoresTitleP1=性能核心
SystemCoresTitleE=能效核心
SystemTopProcesses=主要进程
SystemSortCPU=CPU
SystemSortMemory=内存
SystemOtherUsers=其他用户
SystemWebContent=网页内容
SystemWebGraphics=网页图形
SystemWebNetworking=网页网络

; ---------------------------------------------------------------- tooltips
SystemTipCard="CPU [MeasureCPUText] · 内存已用 [MeasureMemUsed:/1073741824,1] GB，共 [MeasureMemTotalText] GB · 磁盘已用 [MeasureDiskText]，可用 [MeasureDiskAvailText] · "
SystemTipFourthGPU=GPU [MeasureGPUText]
SystemTipFourthSwap=交换 [MeasureSwapText]
SystemTipCardEnd=" · 运行 [MeasureUptimeText]"
SystemTipCPU=CPU 占用 [MeasureCPUText]（2 秒平均值）。
SystemTipCPUCores0=CPU 占用 [MeasureCPUText]（2 秒平均值），共 [MeasureCoresAll:0] 个核心。
SystemTipCPUCores1=CPU 占用 [MeasureCPUText]（2 秒平均值），共 [MeasureCoresAll:0] 个核心（[MeasureCoresP:0] 个性能核心，[MeasureCoresE:0] 个能效核心）。
SystemTipMemory=已用 [MeasureMemText]，共 [MeasureMemTotalText] GB：App 内存、联动内存和被压缩内存，与“活动监视器”的算法相同。
SystemTipDisk0=可用 [MeasureDiskAvailText]，共 [MeasureDiskTotalText]（已用 [MeasureDiskText]）。可用空间包括 macOS 可以释放的空间，与“访达”一致。
SystemTipDisk1=可用 [MeasureDiskAvailText]，共 [MeasureDiskTotalText]（已用 [MeasureDiskText]）。磁盘快满了。可用空间包括 macOS 可以释放的空间，与“访达”一致。
SystemTipGPU=GPU 占用 [MeasureGPUText]。
SystemTipSwap0=有 [MeasureSwapText] 内存被交换到磁盘。
SystemTipSwap1=有 [MeasureSwapText] 内存被交换到磁盘。这台 Mac 无法读取 GPU 占用。
SystemTipHistory=最近 5 分钟的 CPU 占用，每秒一个采样。当前 [MeasureCPUText]。
SystemTipCoresP0=[MeasureCoresP:0] 个核心，平均占用 [MeasurePAvg:0]%。
SystemTipCoresP1=[MeasureCoresP:0] 个性能核心，平均占用 [MeasurePAvg:0]%。
SystemTipCoresE=[MeasureCoresE:0] 个能效核心，平均占用 [MeasureEAvg:0]%。
SystemTipCoresShown0=
SystemTipCoresShown1=显示其中 [MeasureCoreShownP:0] 个。
SystemCoreP0=核心
SystemCoreP1=性能核心
SystemCoreE=能效核心
SystemCoreSep=：
SystemTipTop0=每个进程占全部 [MeasureCoresAll:0] 个核心的份额，与 CPU 圆环的刻度相同。“活动监视器”以一个核心为 100%，所以它显示的是这些数值 × [MeasureCoresAll:0]。
SystemTipTop1=你自己的进程所用的内存，与“活动监视器”的“内存”列一致。macOS 不允许 App 读取其他用户的进程。
SystemTipSortCPU=按 CPU 排序
SystemTipSortMemory=按内存排序
SystemTipCPURow=：占全部 {cores} 个核心的 {pct}，在“活动监视器”中约为一个核心的 {core}%。
SystemTipMemRow=" 使用 {mem} 内存。"
SystemTipOtherUsers=其他用户和 macOS 自身的进程，例如 WindowServer 和 kernel_task。macOS 只允许 Deskset 将它们作为一个整体读取。
