; Body of the AnalogClock skins. The including .ini defines FixedTime in [Variables].
[Rainmeter]
Update=1000
AccurateText=1

[Metadata]
Name=Analog Clock
Author=Deskset
Information=Original analog clock: Roundline hour and minute hands, Rotator second hand, Roundline face, ticks and seconds ring.
Version=1.0
License=MIT

[Variables]
Face=28,30,38,235
Rim=205,210,222,255
Tick=205,210,222,255
Hand=240,242,248,255
Accent=90,180,255,190

; ---------------------------------------------------------------- measures

; Without a Format the number value is the timestamp in seconds; ValueRemainder turns it into hand positions.
[MeasureTime]
Measure=Time
TimeStamp=#FixedTime#
TimeStampFormat=%H:%M:%S

[MeasureTimeText]
Measure=Time
Format=%H:%M:%S
TimeStamp=#FixedTime#
TimeStampFormat=%H:%M:%S

; ---------------------------------------------------------------- styles

[StyleDial]
X=0
Y=0
W=200
H=200
AntiAlias=1

; Styles cannot chain (MeterStyle is only read from the meter itself), so ticks list StyleDial too.
[StyleTick]
ControlAngle=0
LineStart=74
LineLength=84
LineWidth=2
LineColor=#Tick#

[StyleMajorTick]
LineStart=68
LineWidth=4

[StyleHand]
MeasureName=MeasureTime
StartAngle=4.7124
RotationAngle=6.2832
LineColor=#Hand#

; ---------------------------------------------------------------- face

; No MeasureName = always 100%: a full disc and a full ring.
[MeterFace]
Meter=Roundline
MeterStyle=StyleDial
Solid=1
LineLength=96
LineColor=#Face#

[MeterRim]
Meter=Roundline
MeterStyle=StyleDial
Solid=1
LineStart=92
LineLength=96
LineColor=#Rim#

; Seconds progress ring (ring sector from 12 o'clock).
[MeterSecondsRing]
Meter=Roundline
MeterStyle=StyleDial | StyleHand
Solid=1
LineStart=87
LineLength=90
LineColor=#Accent#
ValueRemainder=60

; Hour ticks: ControlAngle=0 keeps each line at its StartAngle.
[Tick12]
Meter=Roundline
MeterStyle=StyleDial | StyleTick | StyleMajorTick
StartAngle=(PI * 3 / 2)
[Tick1]
Meter=Roundline
MeterStyle=StyleDial | StyleTick
StartAngle=(PI * 3 / 2 + PI / 6 * 1)
[Tick2]
Meter=Roundline
MeterStyle=StyleDial | StyleTick
StartAngle=(PI * 3 / 2 + PI / 6 * 2)
[Tick3]
Meter=Roundline
MeterStyle=StyleDial | StyleTick | StyleMajorTick
StartAngle=0
[Tick4]
Meter=Roundline
MeterStyle=StyleDial | StyleTick
StartAngle=(PI / 6 * 1)
[Tick5]
Meter=Roundline
MeterStyle=StyleDial | StyleTick
StartAngle=(PI / 6 * 2)
[Tick6]
Meter=Roundline
MeterStyle=StyleDial | StyleTick | StyleMajorTick
StartAngle=(PI / 2)
[Tick7]
Meter=Roundline
MeterStyle=StyleDial | StyleTick
StartAngle=(PI / 6 * 4)
[Tick8]
Meter=Roundline
MeterStyle=StyleDial | StyleTick
StartAngle=(PI / 6 * 5)
[Tick9]
Meter=Roundline
MeterStyle=StyleDial | StyleTick | StyleMajorTick
StartAngle=(PI)
[Tick10]
Meter=Roundline
MeterStyle=StyleDial | StyleTick
StartAngle=(PI / 6 * 7)
[Tick11]
Meter=Roundline
MeterStyle=StyleDial | StyleTick
StartAngle=(PI / 6 * 8)

[MeterDigital]
Meter=String
MeasureName=MeasureTimeText
X=100
Y=128
StringAlign=Center
FontFace=Helvetica Neue
FontSize=10
FontColor=150,156,170,255
AntiAlias=1

; ---------------------------------------------------------------- hands

; Hour hand: ValueRemainder=43200 (seconds in 12 hours). A negative LineStart gives the hand a short tail.
[MeterHourHand]
Meter=Roundline
MeterStyle=StyleDial | StyleHand
ValueRemainder=43200
LineStart=-10
LineLength=50
LineWidth=6

; Minute hand: ValueRemainder=3600 (seconds in an hour).
[MeterMinuteHand]
Meter=Roundline
MeterStyle=StyleDial | StyleHand
ValueRemainder=3600
LineStart=-12
LineLength=76
LineWidth=3

; Second hand: a Rotator. The image points right with its pivot at (20,6); OffsetX/OffsetY put that pivot on
; the center of the 200x200 box.
[MeterSecondHand]
Meter=Rotator
MeterStyle=StyleDial | StyleHand
ImagePath=#CURRENTPATH#Images\
ImageName=SecondHand
OffsetX=20
OffsetY=6
ValueRemainder=60
