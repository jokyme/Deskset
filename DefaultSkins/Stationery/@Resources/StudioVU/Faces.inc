; Stationery · Studio VU — the meters' two printed faces. Original work, MIT licensed.
; The face is a printed instrument, so its colours follow the face (Ivory or Amber), not the look; the skin picks one
; (StudioFace in Variables.inc: Auto is Ivory in the Light look and Amber in the Dark) and reads its values under the
; plain names (PlateLit1…) when it loads.

[Variables]
; ---------------------------------------------------------------- Ivory: warm paper, lit from the pivot
; the plate with the lamp on (radial stops 0 / 0.55 / 1) and down; the lamp-down veil over the print
IvoryPlateLit1=255,250,236
IvoryPlateLit2=253,246,229
IvoryPlateLit3=241,230,204
IvoryPlateIdle1=248,247,243
IvoryPlateIdle2=242,240,234
IvoryPlateIdle3=227,223,213
IvoryFaceVeil=0,0,0,0
; the window's lip (an inner shade at the top), the lens's sheen, the face's hairline
IvoryLipTop=90,66,30,52
IvoryLipClear=90,66,30,0
IvorySheenTop=255,255,255,115
IvoryBezel=70,52,24,56
; the print: scale, numerals and needle; the red above 0 VU; "L"/"R" and PEAK
IvoryFaceInk=30,26,21
IvoryScaleRed=200,50,31
IvoryChanInk=30,26,21,153
IvoryPeakInk=30,26,21,128
IvoryNeedleShadow=70,50,20,40
; the pivot's cap (smoked acrylic), its rim and highlight; the VU wordmark; the PEAK lamp when off
IvoryCapTop=168,124,60,30
IvoryCapBottom=150,108,50,68
IvoryCapRim=140,100,48,92
IvoryCapHighlight=255,255,255,150
IvoryVUInk=59,48,39,225
IvoryLedOff=122,43,34,140

; ---------------------------------------------------------------- Amber: backlit, dimmed under a warm veil at rest
AmberPlateLit1=255,235,181
AmberPlateLit2=247,192,98
AmberPlateLit3=179,107,39
AmberPlateIdle1=255,235,181
AmberPlateIdle2=247,192,98
AmberPlateIdle3=179,107,39
AmberFaceVeil=80,36,0,110
AmberLipTop=60,28,0,110
AmberLipClear=60,28,0,0
AmberSheenTop=255,255,255,38
AmberBezel=36,18,0,170
AmberFaceInk=30,26,21
; a deeper oxblood on amber: the red numerals read 3.9:1
AmberScaleRed=160,30,18
AmberChanInk=30,26,21,153
AmberPeakInk=30,26,21,128
AmberNeedleShadow=110,55,0,70
AmberCapTop=96,48,0,50
AmberCapBottom=70,34,0,100
AmberCapRim=70,34,0,125
AmberCapHighlight=255,255,255,80
AmberVUInk=42,26,8,225
AmberLedOff=122,43,34,140
