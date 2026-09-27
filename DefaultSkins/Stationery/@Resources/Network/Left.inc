; Stationery · Network — the left column (x 16 → 154), which is the whole Small: the connection, the download and
; upload rates, and a two-minute graph of the download that owns the bottom band. Original work, MIT licensed.
; Included from [MeterCard], so it draws right after the card.

[MeterHeaderSymbol]
; wifi, wifi.exclamationmark (no Internet), wifi.slash (offline) or point.3.connected.trianglepath.dotted (wired and
; other adapters), in the secondary ink like every connection glyph; 15 wide, centred on (26, 23)
Meter=Image
MeterStyle=sSymbolS
ImageName=sf:[#NetSymbol[&MeasureNetState:]]
ImageTint=#SecondaryTextColor#
X=18.5
Y=(#BandCenterY# - [#NetSymbolH[&MeasureNetState:]] / 2)
W=15
H=[#NetSymbolH[&MeasureNetState:]]
DynamicVariables=1
UpdateDivider=5

[MeterHeaderTitle]
; "Wi-Fi" (or the network's name), "Ethernet", "No Internet", "Offline"…, clipped at TitleW
Meter=String
MeterStyle=sLabel | sHeaderTitle
MeasureName=MeasureHeaderTitle
W=#TitleW#
UpdateDivider=5

[MeterDownSymbol]
; 15 pt, centred on (26, 48.25): the download line's cap centre
Meter=Image
ImageName=sf:arrow.down.circle.fill
MacSymbolSize=15
MacSymbolWeight=Regular
ImageTint=#DownloadColor#
X=17
Y=39.75
W=18
H=17
UpdateDivider=-1

[MeterDown]
; 22 pt on baseline 56, its unit 11 pt: "2.7 MB/s". "--" in the tertiary ink until the second update (MeasureReady)
Meter=String
MeterStyle=sMetricM | sUnit
MeasureName=MeasureDownText
Text=--
FontColor=#TertiaryTextColor#
X=41
Y=(56 - #Ascent22#)
Group=Rate

[MeterUpSymbol]
Meter=Image
ImageName=sf:arrow.up.circle.fill
MacSymbolSize=15
MacSymbolWeight=Regular
ImageTint=#UploadColor#
X=17
Y=72.75
W=18
H=17
UpdateDivider=-1

[MeterUp]
; baseline 89
Meter=String
MeterStyle=sMetricM | sUnit
MeasureName=MeasureUpText
Text=--
FontColor=#TertiaryTextColor#
X=41
Y=(89 - #Ascent22#)
Group=Rate

[MeterChartCaption]
; over the graph's right end, baseline 110: "Peak 3.1 MB/s · 2 min", the graph's top and its window
Meter=String
MeterStyle=sCaptionNum
MeasureName=MeasurePeakText
Text=#NetworkPeak# -- · #NetworkChartWindow#
StringAlign=Right
X=154
Y=(110 - #Ascent11#)

[MeterChartArea]
; 138 samples, one a second (the graph's window, 2 min): keep UpdateDivider 1 on both, or the caption is wrong
Meter=Histogram
MeasureName=MeasureDownChart
X=16
Y=118
W=138
H=34
PrimaryColor=#DownloadColor#,51
AutoScale=0
AntiAlias=1

[MeterChartLine]
Meter=Line
MeasureName=MeasureDownChart
X=16
Y=118
W=138
H=34
LineCount=1
LineColor=#DownloadColor#
LineWidth=1.5
AutoScale=0
AntiAlias=1
