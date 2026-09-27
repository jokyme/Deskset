; Stationery · Network — the Medium's last row: the address the Internet sees (Bottom Row: Public IP). Original work,
; MIT licensed. One HTTPS request to api.ipify.org every 30 minutes and on every change of connection; its answer is
; the address, and nothing is sent but the request. PublicIPURL can point to another service that answers the same way.

[Variables]
BottomSymbol=globe
BottomSymbolW=16
BottomSymbolH=16
BottomLabel=#NetworkIP#
BottomMeasure=MeasurePublicIPText
PublicIPURL=https://api.ipify.org
TipBottom=#NetworkTipPublic#

[MeasurePublicIP]
Measure=WebParser
URL=#PublicIPURL#
RegExp=(?siU)^\s*([0-9a-fA-F:.]+)\s*$
StringIndex=1
; every 30 minutes (1800 updates of 1 s), and on every change of connection (below)
UpdateRate=1800

[MeasurePublicIPTrigger]
Measure=Calc
Formula=MeasureNetState
UpdateDivider=5
OnChangeAction=[!CommandMeasure MeasurePublicIP "Update"]

[MeasurePublicIPText]
; without Internet "--", never an address that may no longer be true
Measure=String
String=[&MeasureNetState:]|[MeasurePublicIP]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^(0|[4-6])\|.*$":"--","^\d\|$":"--","^\d\|(.+)$":"\1"
