; Stationery · Daybreak — the ruler's and the sky's colours for each ink. Original work, MIT licensed.
;
; The ink itself is the suite's frameless ink (Suite/Ink.inc): the clock in InkRGB at InkA1, the date and the labels at
; InkA2, the shadows InkShadowDisplay and InkShadowText, the scrim InkScrimA. These are the piece's own values on top
; of it, one set per ink: W (white ink, dark wallpapers) and D (dark ink, light ones). Meters read them as
; [#[#InkKey]Name], and InkKey follows the suite's ink.

[Variables]
InkKey=W

; ---------------------------------------------------------------- night dots, and the copies under the ruler's parts
; the dots of the night that is over and of the night to come (alphas of the ink)
WADotPast=210
WADotFuture=100
DADotPast=150
DADotFuture=72
; a copy under each part, in HaloRGB: a soft drop edge under white ink (1 pt lower, 1.4 pt wider), a crisp light edge
; under dark ink (1 pt lower, the same width; letterpress, never a glow)
WAUnder=64
WAUnderF=34
WAUnderSym=90
WGrow=1.4
WUnderY=1
DAUnder=120
DAUnderF=70
DAUnderSym=120
DGrow=0
DUnderY=1
; the sunrise and sunset symbols: a yellow sun under white ink (drawn in the symbol's own colours), the ink's own tone
; under dark ink
WSymMode=Multicolor
DSymMode=Hierarchical

; ---------------------------------------------------------------- the sky band (the piece's signature)
; the colour at civil twilight, sunrise, the end of the morning's golden hour, plain day, the start of the evening's
; golden hour, its middle and sunset
WTwi=168,146,255
WRise=255,150,122
WGE=255,224,182
WDay=255,255,255
WGS=255,234,196
WGold=255,190,92
WSet=255,124,90
DTwi=92,64,204
DRise=196,70,50
DGE=150,80,30
DDay=28,28,30
DGS=120,64,14
DGold=204,104,0
DSet=196,52,44
; alphas: the part of the day that is over (bright), and the rest of the day (faint), by stop
WAPast=255
WATwi=200
WATwiF=90
WARiseF=128
WAGEF=108
WADayF=90
WAGSF=108
WAGoldF=180
WASetF=170
DAPast=235
DATwi=190
DATwiF=80
DARiseF=120
DAGEF=100
DADayF=66
DAGSF=100
DAGoldF=160
DASetF=150

; ---------------------------------------------------------------- the digits take the sky's colour at their base
; by phase: 0 night, 1 civil twilight, 2 golden hour, 3 day (plain ink)
WTint0=196,208,255,255
WTint1=255,196,186,255
WTint2=255,202,134,255
WTint3=255,255,255,255
DTint0=48,64,184,238
DTint1=176,52,96,238
DTint2=210,100,10,248
DTint3=28,28,30,255
; where the tint starts and ends (0 top, 1 bottom of the text box): white ink fills the lower half softly; dark ink
; keeps the top plain and pools the colour at the base (a long blend from near-black to orange reads as mud)
WG1=0.22
WG2=0.82
DG1=0.46
DG2=0.78

; ---------------------------------------------------------------- the sun and the moon on the ruler
WSunGlow=255,200,80
DSunGlow=255,150,0
WMoonGlow=170,190,255
DMoonGlow=60,80,170
; the moon's lit part is always the lighter tone: under white ink a pale disc on the dark wallpaper; under dark ink a
; pale disc over its shadow in the ink (a full moon is an outlined disc with a pale inside)
WMoonHi=255,255,255
WMoonLo=212,220,240
WAMoonShadow=0
DMoonHi=255,255,255
DMoonLo=236,238,244
DAMoonShadow=210
; the sun's core by phase: deeper in twilight and the golden hours
SunHi3=255,232,110
SunLo3=255,140,13
SunHi2=255,214,96
SunLo2=255,100,20
SunHi1=255,214,96
SunLo1=255,100,20
SunHi0=255,214,96
SunLo0=255,100,20
