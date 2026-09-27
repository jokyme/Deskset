; Stationery · Network — the Medium's last row: the round trip to the router (Bottom Row: Router Latency).
; Original work, MIT licensed. One echo to the default gateway every 5 s, 1 s time-out: the local network only, never
; a third party (on macOS 15 and later, macOS may ask for Local Network access the first time).

[Variables]
BottomSymbol=wifi.router
BottomSymbolW=22
BottomSymbolH=15
BottomLabel=#NetworkRouter#
BottomMeasure=MeasureRouterText
RouterDone=0
TipBottom=#NetworkTipRouter#

[MeasureGateway]
; the IPv4 router of the active adapter
Measure=SysInfo
SysInfoType=GATEWAY_ADDRESS_V4
UpdateDivider=5

[MeasureRouterPing]
Measure=Plugin
Plugin=PingPlugin
DestAddress=[MeasureGateway]
DynamicVariables=1
UpdateRate=5
Timeout=1000
TimeoutValue=-1
FinishAction=[!SetVariable RouterDone 1]

[MeasureRouterText]
; the state | answered yet | the round trip in whole ms: "3 ms", "<1 ms" (a LAN reply rounds to 0), else "--"
Measure=String
String=[&MeasureNetState:]|#RouterDone#|[&MeasureRouterPing:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^0\|.*$":"--","^\d\|0\|.*$":"--","^\d\|1\|-1$":"--","^\d\|1\|0$":"<1 ms","^\d\|1\|(\d+)$":"\1 ms"
