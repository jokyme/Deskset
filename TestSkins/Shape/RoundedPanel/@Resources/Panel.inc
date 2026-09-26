; Rounded panel background for Deskset example skins (original).
;
; Usage: @Include=#@#Panel.inc, set PanelWidth / PanelHeight (and optionally the colors) in [Variables],
; then add a meter with MeterStyle=StylePanel as the FIRST meter of the skin:
;
;   [MeterBackground]
;   Meter=Shape
;   MeterStyle=StylePanel
;
; The outline sits on half pixels so the 1 px border is crisp; the meter is exactly PanelWidth x PanelHeight.

[Variables]
PanelWidth=220
PanelHeight=120
PanelRadius=12
PanelTop=46,50,62,235
PanelBottom=28,31,39,235
PanelBorder=255,255,255,38
PanelHighlight=255,255,255,22
PanelAccent=94,168,255,255
PanelTrack=255,255,255,28

[StylePanel]
Shape=Rectangle 0.5,0.5,(#PanelWidth#-1),(#PanelHeight#-1),#PanelRadius# | Fill LinearGradient PanelFill | StrokeWidth 1 | Stroke Color #PanelBorder#
PanelFill=270 | #PanelTop# ; 0.0 | #PanelBottom# ; 1.0
; Soft highlight along the top edge, inset by the corner radius.
Shape2=Line (#PanelRadius#),1.5,(#PanelWidth#-#PanelRadius#),1.5 | StrokeWidth 1 | Stroke Color #PanelHighlight#

; A rounded progress track, PanelWidth-32 wide and 8 high. Needs DynamicVariables=1 on the meter and a
; measure named BarValue whose value is 0…100 (e.g. a Calc measure: Formula=MeasureCPU).
[StyleTrack]
Shape=Rectangle 0,0,(#PanelWidth#-32),8,4 | Fill Color #PanelTrack# | StrokeWidth 0
Shape2=Rectangle 0,0,(Max(8,(#PanelWidth#-32)*[&BarValue]/100)),8,4 | Fill LinearGradient TrackFill | StrokeWidth 0
TrackFill=180 | #PanelAccent# ; 0.0 | 160,120,255,255 ; 1.0
