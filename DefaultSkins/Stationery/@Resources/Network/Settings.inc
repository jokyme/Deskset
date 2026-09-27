; Stationery · Network — defaults for the network's own settings. Original work, MIT licensed.
; Both Network sizes include this file before @Resources/Variables.inc, so a value the menus wrote there wins; these
; only fill in what Variables.inc does not have yet.

[Variables]
; speeds in bytes (Bytes: KB/s, MB/s, as Activity Monitor) or bits (Bits: Kbit/s, Mbit/s); totals stay in bytes
NetUnit=Bytes
; 1 shows the Wi-Fi network's name in the header, which macOS allows only with Location Services (it asks once)
ShowWiFiName=0
; the Medium's last row: IP (this Mac's address), Router (the latency to the router, pinged every 5 s) or Public (the
; address the Internet sees, asked of api.ipify.org every 30 minutes)
NetworkBottomRow=IP
