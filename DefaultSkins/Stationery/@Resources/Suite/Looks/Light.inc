; Stationery — the Light look: dark ink on light glass. Original work, MIT licensed.
;
; Colours are R,G,B,A (0–255). The system colours and the data categories are R,G,B only, so an alpha can follow
; (#CPUColor#,#TrackAlpha#); the ink is InkRGB plus an alpha, so a formula can pick the alpha
; (#InkRGB#,(#Selected# ? #Alpha1# : #Alpha2#)). Every look defines the same names.

[Variables]
; what the window's appearance should be (read by [Rainmeter] MacAppearance once Deskset has it), the theme of the
; pieces that keep their own theme files, and the moon symbols' suffix (the lit part stays the lighter tone)
LookAppearance=Light
LookTheme=Light
MoonSuffix=.inverse

; ---------------------------------------------------------------- ink
InkRGB=0,0,0
Alpha1=216
Alpha2=153
Alpha3=122
Alpha4=46
; primary text (values, names), secondary (labels, dates, units), tertiary (supporting lines, missing values),
; faint (disabled glyphs, media tracks, live graphics at rest)
TextColor=#InkRGB#,#Alpha1#
SecondaryTextColor=#InkRGB#,#Alpha2#
TertiaryTextColor=#InkRGB#,#Alpha3#
FaintColor=#InkRGB#,#Alpha4#
SeparatorColor=0,0,0,26
HoverColor=0,0,0,20
PressedColor=0,0,0,41
; tiles, segmented tracks, placeholders; the selected segment's knob
ControlFillColor=0,0,0,18
KnobColor=255,255,255,235
; an InputText field's SolidColor (opaque: its alpha would fade the typed text too), and the pad under a line being
; edited in place
FieldColor=255,255,255,255
EditPadColor=255,255,255,140

; ---------------------------------------------------------------- the card
Glass=Regular
GlassTint=255,255,255,77
; the veil is drawn over the glass: 0 with glass cards, 1 with "Cards: Solid"
Veil0=255,255,255,26
Veil1=246,246,248,235
; ring and bar tracks: a category colour at this alpha
TrackAlpha=56

; ---------------------------------------------------------------- system colours (macOS 26, light)
Red=255,56,60
Orange=255,141,40
Yellow=255,204,0
Green=52,199,89
Mint=0,200,179
Teal=0,195,208
Cyan=0,192,232
Blue=0,136,255
Indigo=97,85,245
Purple=203,48,224
Pink=255,45,85
Brown=172,127,94
Gray=142,142,147

; ---------------------------------------------------------------- data categories
; One hue per kind of data, on graphics only (rings, bars, graphs, symbols); the numbers beside them stay ink.
CPUColor=#Blue#
MemoryColor=#Green#
StorageColor=#Orange#
GPUColor=#Purple#
DownloadColor=#Blue#
UploadColor=#Orange#
TemperatureColor=#Orange#
FanColor=#Teal#
PowerColor=#Yellow#
BatteryColor=#Green#
MediaColor=#Pink#
CalendarColor=#Red#
ClockHandColor=#Orange#
TimerColor=#Orange#
PrecipitationColor=#Cyan#
SunColor=#Yellow#

; ---------------------------------------------------------------- status (only when a rule fires)
WarningColor=#Yellow#
CriticalColor=#Red#

; ---------------------------------------------------------------- accent
; graphics that mean "interaction" or "now": header symbols of widgets without a category, checked boxes, focus rings
AccentColor=#MACACCENTCOLOR#

; ---------------------------------------------------------------- coloured text
; The only text that is not ink; each reads at 4.5:1 on the glass. Accent: links, actions, and weekdays and months
; outside the Calendar; Calendar: the Calendar's month and weekday; Critical: a level that is critical; Precipitation:
; rain chips.
AccentTextColor=0,76,160
CalendarTextColor=160,0,20
CriticalTextColor=160,0,20
PrecipitationTextColor=0,82,118
