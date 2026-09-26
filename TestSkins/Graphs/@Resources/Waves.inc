; Deskset test fixture (original). Known waveforms driven by the update counter, so a render with
; `--updates 60 --interval 0` always produces the same graphs.

[MeasureSine]
; 0…100, period 30 updates.
Measure=Calc
Formula=50 + 50 * Sin(Counter * PI / 15)
MinValue=0
MaxValue=100

[MeasureSaw]
; 0, 5, 10 … 100, 0, 5 … (period 21 updates).
Measure=Loop
StartValue=0
EndValue=100
Increment=5

[MeasureSquare]
; 20 / 80 alternating every 10 updates.
Measure=Calc
Formula=(Floor(Counter / 10) % 2 = 0) ? 80 : 20
MinValue=0
MaxValue=100

[MeasureSmall]
; Tiny values with a huge MaxValue: flat without AutoScale.
Measure=Calc
Formula=3 + 2 * Sin(Counter * PI / 10)
MinValue=0
MaxValue=1000

[MeasureSigned]
; -1…1 with MinValue=-1: exercises MinValue.
Measure=Calc
Formula=Sin(Counter * PI / 12)
MinValue=-1
MaxValue=1
