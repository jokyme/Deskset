; Stationery · Network — the network's words in English. Original work, MIT licensed.
; Strings-Chinese.inc has the same keys. A value with a space at either end is quoted, or the INI reader would trim
; it. Menu titles are Title Case and at most 30 characters.

[Variables]
; ---------------------------------------------------------------- menu
NetworkMenuOpen=Open Activity Monitor
NetworkMenuSettings=Open Network Settings
NetworkMenuSpeedBytes=Speed Units: MB/s
NetworkMenuSpeedBits=Speed Units: Mbit/s
NetworkMenuWiFiName0=Show Wi-Fi Name: Off
NetworkMenuWiFiName1=Show Wi-Fi Name: On
NetworkMenuBottomIP=Bottom Row: IP Address
NetworkMenuBottomRouter=Bottom Row: Router Latency
NetworkMenuBottomPublic=Bottom Row: Public IP

; ---------------------------------------------------------------- the card
; the header's title by the connection (the network's name replaces "Wi-Fi" with Show Wi-Fi Name)
NetworkWiFi=Wi-Fi
NetworkEthernet=Ethernet
NetworkOther=Network
NetworkNoInternet=No Internet
NetworkOffline=Offline
; the graph's caption: "Peak 3.1 MB/s · 2 min"
NetworkPeak=Peak
NetworkChartWindow=2 min
; the Medium's detail column
NetworkSinceStartup=Since startup
NetworkReceived=Received
NetworkSent=Sent
NetworkSignal=signal
NetworkLinkSpeed=Link speed
NetworkNotConnected=Not connected
NetworkIP=IP
NetworkRouter=Router

; ---------------------------------------------------------------- the card's sentence
; the connection, by MeasureNetState (0 offline, 1–3 Wi-Fi / Ethernet / another adapter, 4–6 the same without Internet)
NetworkTipLink0=Offline.
NetworkTipLink1=[MeasureWiFiPHY], signal [MeasureWiFiQualityText].
NetworkTipLink2=Ethernet, [MeasureLinkText] link.
NetworkTipLink3=[MeasureAdapterAlias].
NetworkTipLink4=Wi-Fi without Internet access.
NetworkTipLink5=Ethernet without Internet access.
NetworkTipLink6=[MeasureAdapterAlias] without Internet access.
NetworkTipRates=Downloading [MeasureDownText], uploading [MeasureUpText]; peak [MeasurePeakText] in the last 2 minutes. Since startup: [MeasureReceivedText] received, [MeasureSentText] sent.
; the last sentence, by the bottom row
NetworkTipIP=IP [MeasureIP].
NetworkTipRouter=Router [MeasureGateway]: [MeasureRouterText].
NetworkTipPublic=Public IP [MeasurePublicIPText], from api.ipify.org every 30 minutes.
