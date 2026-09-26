; Deskset example skins — shared meter styles. Original work, MIT licensed.
; Include after Variables.inc. A meter may list several styles: MeterStyle=StyleText | StyleLabel.

; ---------------------------------------------------------------- panel
; Rounded panel background: the FIRST meter of a skin, named MeterBackground (the hover effect updates it).
; Set PanelHeight in the skin's [Variables]; PanelWidth comes from Variables.inc. The outline sits on half pixels,
; so the 1 px border is crisp and the meter is exactly PanelWidth x PanelHeight.
[StylePanel]
Shape=Rectangle 0.5,0.5,(#PanelWidth# - 1),(#PanelHeight# - 1),#PanelRadius# | Fill LinearGradient PanelFill | StrokeWidth 1 | Stroke Color #PanelBorderNow#
PanelFill=270 | #PanelTop# ; 0.0 | #PanelBottom# ; 1.0
; Soft highlight along the top edge, inset by the corner radius.
Shape2=Line (#PanelRadius#),1.5,(#PanelWidth# - #PanelRadius#),1.5 | StrokeWidth 1 | Stroke Color #PanelHighlight#
DynamicVariables=1

; ---------------------------------------------------------------- text
[StyleText]
FontFace=#FontFace#
FontSize=10
FontColor=#TextColor#
AntiAlias=1

; Skin title (top left).
[StyleTitle]
X=#Padding#
Y=14
FontSize=11
FontWeight=600

; Small uppercase caption.
[StyleLabel]
FontSize=8
FontWeight=600
FontColor=#SubtleColor#
StringCase=Upper
InlineSetting=CharacterSpacing | 0.8

; Right-aligned value on the same line as the meter before it.
[StyleValueRight]
X=(#PanelWidth# - #Padding#)
Y=0r
StringAlign=Right

; Clickable text: set LeftMouseUpAction (and ToolTipText) on the meter. It turns the accent color under the
; pointer. !SetOption with "" removes the option from the meter again, so the FontColor of its styles (StyleText)
; comes back: do not set FontColor on the meter itself, it would be lost after the first hover.
[StyleLink]
MouseOverAction=[!SetOption #CURRENTSECTION# FontColor "#AccentColor#"][!UpdateMeter #CURRENTSECTION#][!Redraw]
MouseLeaveAction=[!SetOption #CURRENTSECTION# FontColor ""][!UpdateMeter #CURRENTSECTION#][!Redraw]

; Tabular (fixed-width) digits, so changing numbers do not wiggle.
[StyleDigits]
InlineSetting=Typography | tnum

; ---------------------------------------------------------------- tracks
; Rounded progress track, ContentWidth x TrackHeight (set Y on the meter). The meter adds the filled part itself
; (Shape2), because each track shows a different measure. The fill is at least TrackHeight wide, so it stays a
; round dot at small values, e.g.:
;   Shape2=Rectangle 0,0,(Max(#TrackHeight#, #ContentWidth# * [MeasureRAM:%] / 100)),#TrackHeight#,(#TrackHeight# / 2) | Fill LinearGradient RAMFill | StrokeWidth 0
;   RAMFill=180 | #MemoryColor# ; 0.0 | #MemoryColor2# ; 1.0
; DynamicVariables=1 (set here) keeps [MeasureRAM:%] current.
[StyleTrack]
X=#Padding#
Shape=Rectangle 0,0,#ContentWidth#,#TrackHeight#,(#TrackHeight# / 2) | Fill Color #TrackColor# | StrokeWidth 0
DynamicVariables=1
