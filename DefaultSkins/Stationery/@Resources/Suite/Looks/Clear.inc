; Stationery — the Clear look: white ink on clear glass, like macOS's clear widgets. Original work, MIT licensed.
; It starts from the Dark look. Data colours turn white; album art and app icons keep their colour, and a critical
; level stays red. Clear cards have one veil ("Cards: Solid" does not change them).

[Variables]
@Include=#@#Suite/Looks/Dark.inc
LookAppearance=Dark
LookTheme=Dark
MoonSuffix=

; ---------------------------------------------------------------- ink
Alpha1=245
Alpha2=191
Alpha3=140
Alpha4=64
SeparatorColor=255,255,255,51
HoverColor=255,255,255,38
PressedColor=255,255,255,64
ControlFillColor=255,255,255,38
KnobColor=255,255,255,77
FieldColor=50,50,52,255
EditPadColor=255,255,255,51

; ---------------------------------------------------------------- the card
Glass=Clear
GlassTint=0,0,0,46
Veil0=0,0,0,38
Veil1=0,0,0,38
TrackAlpha=64

; ---------------------------------------------------------------- data categories: white
CPUColor=255,255,255
MemoryColor=255,255,255
StorageColor=255,255,255
GPUColor=255,255,255
DownloadColor=255,255,255
UploadColor=255,255,255
TemperatureColor=255,255,255
FanColor=255,255,255
PowerColor=255,255,255
BatteryColor=255,255,255
MediaColor=255,255,255
CalendarColor=255,255,255
ClockHandColor=255,255,255
TimerColor=255,255,255
PrecipitationColor=255,255,255
SunColor=255,255,255

; ---------------------------------------------------------------- status: only critical keeps its colour
WarningColor=255,255,255
CriticalColor=#Red#

; ---------------------------------------------------------------- accent
AccentColor=255,255,255

; ---------------------------------------------------------------- coloured text
AccentTextColor=255,255,255
CalendarTextColor=255,255,255
CriticalTextColor=255,172,172
PrecipitationTextColor=255,255,255
