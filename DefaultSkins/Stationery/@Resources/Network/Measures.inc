; Stationery · Network — the lookups and every measure both sizes use. Original work, MIT licensed.
; Included in [Variables], so its measures come right after it, ahead of every meter. Nothing here sends anything
; anywhere or asks for a permission: interface counters, SystemConfiguration and the Wi-Fi signal (CoreWLAN). The
; network's name (Show Wi-Fi Name) needs Location Services; its measure stays disabled until the option is on.

[Variables]
; ---------------------------------------------------------------- units (NetUnit in Variables.inc: Bytes or Bits)
NetBitFactor=[#NetBitFactor[#NetUnit]]
NetBitFactorBytes=1
NetBitFactorBits=8
SpeedDivBytes1=1000
SpeedDivBytes2=1000000
SpeedDivBytes3=1000000000
SpeedDivBits1=125
SpeedDivBits2=125000
SpeedDivBits3=125000000
SpeedUnitBytes1=KB/s
SpeedUnitBytes2=MB/s
SpeedUnitBytes3=GB/s
SpeedUnitBits1=Kbit/s
SpeedUnitBits2=Mbit/s
SpeedUnitBits3=Gbit/s
ByteDiv1=1000
ByteDiv2=1000000
ByteDiv3=1000000000
ByteDiv4=1000000000000
ByteUnit1=KB
ByteUnit2=MB
ByteUnit3=GB
ByteUnit4=TB
LinkDiv1=1000000
LinkDiv2=1000000000
LinkUnit1=Mbit/s
LinkUnit2=Gbit/s
; a rate before the first reading ("-- MB/s"), the unit kept so the line does not jump when the value comes
SpeedMissing=#Missing# [#SpeedUnit[#NetUnit]2]
; the graph: 138 samples at 1 s (2 min); its scale never drops below 1 Mbit/s (125 KB/s)
ChartFloor=125000

; ---------------------------------------------------------------- the header, by MeasureNetState
; 0 offline · 1 Wi-Fi · 2 Ethernet · 3 another adapter · 4–6 the same without Internet
NetSymbol0=wifi.slash
NetSymbol1=wifi
NetSymbol2=point.3.connected.trianglepath.dotted
NetSymbol3=point.3.connected.trianglepath.dotted
NetSymbol4=wifi.exclamationmark
NetSymbol5=point.3.connected.trianglepath.dotted
NetSymbol6=point.3.connected.trianglepath.dotted
; their heights at 11 pt (all 15 wide)
NetSymbolH0=14
NetSymbolH1=12
NetSymbolH2=12
NetSymbolH3=12
NetSymbolH4=14
NetSymbolH5=12
NetSymbolH6=12
; the network's name goes through SSIDPart, empty while the option is off (a disabled measure would read "0")
SSIDPart=[#SSIDPart[#ShowWiFiName]]
SSIDPart0=
SSIDPart1=[&MeasureSSID]

; ---------------------------------------------------------------- the Medium's third row, by MeasureLinkKind
; 0 not connected · 1 Wi-Fi (its standard and signal) · 2 wired or another adapter (its link speed)
LinkSymbol0=wifi.slash
LinkSymbol1=wifi
LinkSymbol2=point.3.connected.trianglepath.dotted
LinkSymbolH0=16
LinkSymbolH1=13
LinkSymbolH2=14
LinkLabel0=#NetworkNotConnected#
LinkLabel1=[MeasureWiFiPHY] #NetworkSignal#
LinkLabel2=#NetworkLinkSpeed#
LinkValue0=--
LinkValue1=[MeasureWiFiQualityText]
LinkValue2=[MeasureLinkText]
; the tooltip's last sentence (Bottom-Router.inc and Bottom-Public.inc set their own)
TipBottom=#NetworkTipIP#

; ---------------------------------------------------------------- the menu
NetUnitNextBytes=Bits
NetUnitNextBits=Bytes
Toggle0=1
Toggle1=0
BottomRowNextIP=Router
BottomRowNextRouter=Public
BottomRowNextPublic=IP

; ---------------------------------------------------------------- rates and totals
[MeasureDown]
; bytes/s over every physical interface (Wi-Fi and Ethernet; the engine leaves out VPN tunnels, AirDrop and loopback)
Measure=NetIn
Interface=0

[MeasureUp]
Measure=NetOut
Interface=0

[MeasureReady]
; a Net measure reads 0 on its first update (it has no earlier sample): the rates say "-- MB/s" until the second. The
; Wi-Fi signal, read in the background since the first update, is read again then, rather than 5 s after load
Measure=Calc
Formula=Min(MeasureReady + 1, 2)
IfCondition=MeasureReady >= 2
IfTrueAction=[!SetOptionGroup Rate Text "%1"][!SetOptionGroup Rate FontColor "#TextColor#"][!SetOption MeterChartCaption Text "#NetworkPeak# %1 · #NetworkChartWindow#"][!UpdateMeterGroup Rate][!UpdateMeter MeterChartCaption][!UpdateMeasure MeasureWiFiQuality][!UpdateMeasure MeasureWiFiPHY][!UpdateMeasure MeasureWiFiQualityText][!UpdateMeterGroup Link]

[MeasureReceived]
; bytes since the Mac started (the interfaces' own 64-bit counters)
Measure=NetIn
Interface=0
Cumulative=1
UpdateDivider=5

[MeasureSent]
Measure=NetOut
Interface=0
Cumulative=1
UpdateDivider=5

; ---------------------------------------------------------------- the graph's scale and the peak
; The graph is pinned: both graph meters show MeasureDownChart on 0 … its MaxValue, which is the peak of the last
; 139–161 s (six blocks of 23 s and the block in progress), never below ChartFloor. The caption prints the same peak,
; so it is always the graph's top. A Calc reading a measure below it gets that measure's previous value: at a block
; boundary each block takes the one before it, then the block in progress starts again.
[MeasureBlockTick]
Measure=Calc
Formula=(MeasureBlockTick + 1) % 23

[MeasurePeak6]
Measure=Calc
Formula=(MeasureBlockTick = 0) ? MeasurePeak5 : MeasurePeak6

[MeasurePeak5]
Measure=Calc
Formula=(MeasureBlockTick = 0) ? MeasurePeak4 : MeasurePeak5

[MeasurePeak4]
Measure=Calc
Formula=(MeasureBlockTick = 0) ? MeasurePeak3 : MeasurePeak4

[MeasurePeak3]
Measure=Calc
Formula=(MeasureBlockTick = 0) ? MeasurePeak2 : MeasurePeak3

[MeasurePeak2]
Measure=Calc
Formula=(MeasureBlockTick = 0) ? MeasurePeak1 : MeasurePeak2

[MeasurePeak1]
Measure=Calc
Formula=(MeasureBlockTick = 0) ? MeasurePeak0 : MeasurePeak1

[MeasurePeak0]
Measure=Calc
Formula=(MeasureBlockTick = 0) ? MeasureDown : Max(MeasurePeak0, MeasureDown)

[MeasurePeak]
Measure=Calc
Formula=Max(Max(MeasurePeak0, Max(MeasurePeak1, MeasurePeak2)), Max(Max(MeasurePeak3, MeasurePeak4), Max(MeasurePeak5, MeasurePeak6)))

[MeasureChartMax]
Measure=Calc
Formula=Max(MeasurePeak, #ChartFloor#)

[MeasureDownChart]
; the graph's data: bytes/s, on 0 … the pinned scale
Measure=Calc
Formula=MeasureDown
MinValue=0
MaxValue=[MeasureChartMax:]
DynamicVariables=1

; ---------------------------------------------------------------- formatters
; Speeds: decimal units, one decimal below 10, the unit chosen on the rounded value (999.6 KB/s is "1.0 MB/s"), the
; floor "0 KB/s"; in bits with NetUnit=Bits. Two Calcs pick the unit and the decimals, and a String measure writes it,
; so the tooltip can say the same.
[MeasureDownUnit]
; 1 K · 2 M · 3 G
Measure=Calc
Formula=((MeasureDown * #NetBitFactor#) < 999500) ? 1 : (((MeasureDown * #NetBitFactor#) < 999500000) ? 2 : 3)

[MeasureDownDec]
Measure=Calc
Formula=(((MeasureDown * #NetBitFactor#) / (1000 ** MeasureDownUnit)) < 9.95) ? 1 : 0

[MeasureDownText]
; "2.7 MB/s", "553 KB/s", "22 Mbit/s"
Measure=String
String=[&MeasureDown:/[#SpeedDiv[#NetUnit][&MeasureDownUnit:]],[&MeasureDownDec:]] [#SpeedUnit[#NetUnit][&MeasureDownUnit:]]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^0\.0 ":"0 "

[MeasureUpUnit]
Measure=Calc
Formula=((MeasureUp * #NetBitFactor#) < 999500) ? 1 : (((MeasureUp * #NetBitFactor#) < 999500000) ? 2 : 3)

[MeasureUpDec]
Measure=Calc
Formula=(((MeasureUp * #NetBitFactor#) / (1000 ** MeasureUpUnit)) < 9.95) ? 1 : 0

[MeasureUpText]
Measure=String
String=[&MeasureUp:/[#SpeedDiv[#NetUnit][&MeasureUpUnit:]],[&MeasureUpDec:]] [#SpeedUnit[#NetUnit][&MeasureUpUnit:]]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^0\.0 ":"0 "

[MeasurePeakUnit]
Measure=Calc
Formula=((MeasurePeak * #NetBitFactor#) < 999500) ? 1 : (((MeasurePeak * #NetBitFactor#) < 999500000) ? 2 : 3)

[MeasurePeakDec]
Measure=Calc
Formula=(((MeasurePeak * #NetBitFactor#) / (1000 ** MeasurePeakUnit)) < 9.95) ? 1 : 0

[MeasurePeakText]
Measure=String
String=[&MeasurePeak:/[#SpeedDiv[#NetUnit][&MeasurePeakUnit:]],[&MeasurePeakDec:]] [#SpeedUnit[#NetUnit][&MeasurePeakUnit:]]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^0\.0 ":"0 "

; Totals: always bytes, decimal, one decimal below 100 (like every byte count in the suite)
[MeasureReceivedUnit]
; 1 KB · 2 MB · 3 GB · 4 TB
Measure=Calc
Formula=(MeasureReceived < 999500) ? 1 : ((MeasureReceived < 999500000) ? 2 : ((MeasureReceived < 999500000000) ? 3 : 4))
UpdateDivider=5

[MeasureReceivedDec]
Measure=Calc
Formula=((MeasureReceived / (1000 ** MeasureReceivedUnit)) < 99.95) ? 1 : 0
UpdateDivider=5

[MeasureReceivedText]
; "12.4 GB"
Measure=String
String=[&MeasureReceived:/[#ByteDiv[&MeasureReceivedUnit:]],[&MeasureReceivedDec:]] [#ByteUnit[&MeasureReceivedUnit:]]
DynamicVariables=1
UpdateDivider=5

[MeasureSentUnit]
Measure=Calc
Formula=(MeasureSent < 999500) ? 1 : ((MeasureSent < 999500000) ? 2 : ((MeasureSent < 999500000000) ? 3 : 4))
UpdateDivider=5

[MeasureSentDec]
Measure=Calc
Formula=((MeasureSent / (1000 ** MeasureSentUnit)) < 99.95) ? 1 : 0
UpdateDivider=5

[MeasureSentText]
Measure=String
String=[&MeasureSent:/[#ByteDiv[&MeasureSentUnit:]],[&MeasureSentDec:]] [#ByteUnit[&MeasureSentUnit:]]
DynamicVariables=1
UpdateDivider=5

; ---------------------------------------------------------------- the connection
[MeasureAdapterType]
; the active adapter (wired preferred over wireless): 71 wireless, 6 Ethernet, 1 other
Measure=SysInfo
SysInfoType=ADAPTER_TYPE
UpdateDivider=5

[MeasureAdapterAlias]
; the network service's name, as in System Settings › Network ("iPhone USB", "Thunderbolt Bridge")
Measure=SysInfo
SysInfoType=ADAPTER_ALIAS
UpdateDivider=5

[MeasureLAN]
; 1 when some physical interface has a routable address, else -1
Measure=SysInfo
SysInfoType=LAN_CONNECTIVITY
UpdateDivider=5

[MeasureInternet]
; a default route that can reach the Internet (no probe is sent; a captive portal reads as connected)
Measure=SysInfo
SysInfoType=INTERNET_CONNECTIVITY
UpdateDivider=5

[MeasureNetState]
; 0 offline · 1 Wi-Fi · 2 Ethernet · 3 another adapter · 4–6 the same without Internet
Measure=Calc
Formula=(MeasureLAN < 1) ? 0 : (((MeasureAdapterType = 71) ? 1 : ((MeasureAdapterType = 6) ? 2 : 3)) + ((MeasureInternet < 1) ? 3 : 0))
UpdateDivider=5

[MeasureLinkKind]
; the Medium's third row: 0 not connected · 1 Wi-Fi · 2 wired or another adapter
Measure=Calc
Formula=(MeasureNetState = 0) ? 0 : (((MeasureNetState = 1) || (MeasureNetState = 4)) ? 1 : 2)
UpdateDivider=5

[MeasureSSID]
; the network's name, only with Show Wi-Fi Name: a disabled measure never reads its options, so macOS never asks for
; Location Services before the user turns the option on
Measure=Plugin
Plugin=WiFiStatus
WiFiInfoType=SSID
Disabled=(1 - #ShowWiFiName#)
UpdateDivider=5

[MeasureHeaderTitle]
; the state, the network's name and the service's name, joined by ␟ (U+241F, which no network name uses), give the
; header's title: "Wi-Fi" (or the network's name), "Ethernet", the service's name ("iPhone USB", else "Network"),
; "No Internet" or "Offline"
Measure=String
String=[&MeasureNetState:][\x241F]#SSIDPart#[\x241F][&MeasureAdapterAlias]
DynamicVariables=1
UpdateDivider=5
RegExpSubstitute=1
Substitute="^1\x{241F}\x{241F}.*$":"#NetworkWiFi#","^1\x{241F}([^\x{241F}]+)\x{241F}.*$":"\1","^0\x{241F}.*$":"#NetworkOffline#","^2\x{241F}.*$":"#NetworkEthernet#","^3\x{241F}[^\x{241F}]*\x{241F}(.+)$":"\1","^3\x{241F}.*$":"#NetworkOther#","^[4-6]\x{241F}.*$":"#NetworkNoInternet#"

; ---------------------------------------------------------------- the detail rows (the tooltip reads them in both sizes)
[MeasureWiFiQuality]
; 0–100 from the signal strength (−100 dBm → 0, −50 dBm → 100); needs no permission
Measure=Plugin
Plugin=WiFiStatus
WiFiInfoType=QUALITY
UpdateDivider=5

[MeasureWiFiPHY]
; the Wi-Fi standard by its common name (6 GHz Wi-Fi 6E reads as Wi-Fi 6)
Measure=Plugin
Plugin=WiFiStatus
WiFiInfoType=PHY
UpdateDivider=5
RegExpSubstitute=1
Substitute="^802\.11be$":"Wi-Fi 7","^802\.11ax$":"Wi-Fi 6","^802\.11ac$":"Wi-Fi 5","^802\.11n$":"Wi-Fi 4","^(802\.11[abg]|\?\?\?)$":"Wi-Fi"

[MeasureWiFiQualityText]
; "80%"; "--" until the first reading (the signal is read in the background, a moment after the widget loads)
Measure=String
String=[&MeasureWiFiQuality:0]
DynamicVariables=1
UpdateDivider=5
RegExpSubstitute=1
Substitute="^0$":"--","^(\d+)$":"\1%"

[MeasureLinkSpeed]
; bits/s of the active adapter (1000000000 for gigabit Ethernet); 0 when unknown
Measure=SysInfo
SysInfoType=ADAPTER_RECEIVE_SPEED
UpdateDivider=5

[MeasureLinkUnit]
; 1 Mbit/s · 2 Gbit/s
Measure=Calc
Formula=(MeasureLinkSpeed < 999500000) ? 1 : 2
UpdateDivider=5

[MeasureLinkDec]
Measure=Calc
Formula=(Frac(MeasureLinkSpeed / (1000000 * (1000 ** (MeasureLinkUnit - 1)))) >= 0.05) ? 1 : 0
UpdateDivider=5

[MeasureLinkText]
; "1 Gbit/s", "2.5 Gbit/s", "100 Mbit/s"; nothing known: "--"
Measure=String
String=[&MeasureLinkSpeed:/[#LinkDiv[&MeasureLinkUnit:]],[&MeasureLinkDec:]] [#LinkUnit[&MeasureLinkUnit:]]
DynamicVariables=1
UpdateDivider=5
RegExpSubstitute=1
Substitute="^0 .*$":"--"

[MeasureIP]
; the active adapter's IPv4 address
Measure=SysInfo
SysInfoType=IP_ADDRESS
UpdateDivider=5
RegExpSubstitute=1
Substitute="^$":"--"

[MeasureSentence]
; the card's tooltip: the connection, the rates and totals, and the bottom row's reading
Measure=String
String=[#NetworkTipLink[&MeasureNetState:]] #NetworkTipRates# #TipBottom#
DynamicVariables=1
