; Stationery — the shared ink of the pieces without a card. Original work, MIT licensed.
;
; A frameless piece sits straight on the wallpaper, so its ink follows what is under it: white ink on dark
; wallpapers, dark ink (with a letterpress edge, never a glow) on light ones. Every frameless piece includes this file
; after Tokens.inc and Styles.inc, so two pieces side by side always agree. It sets, and keeps up to date:
;   InkRGB, InkA1 / InkA2 / InkA3   the ink and its primary, secondary and tertiary alphas (#InkRGB#,#InkA1#)
;   HaloRGB                          the colour of text shadows and shape halos
;   InkShadowDisplay, InkShadowText  an InlineSetting shadow for type of 40 pt and more, and for smaller text; a meter
;                                    with a shadow needs Padding of at least blur + offset (shadows are clipped to it)
;   HaloOuterA, HaloInnerA           shapes cannot cast shadows: copies under each static shape, +5 pt wide at the
;                                    outer alpha and +2.4 pt at the inner one, in HaloRGB
;   InkScrimA                        large white type only: a radial ellipse of black at this alpha at its centre, to 0
;   MoonSuffix                       the moon symbols' suffix for this ink
;   MeasureInkDark                   0 white ink, 1 dark ink
; Read them in options with DynamicVariables=1. InkChangeAction (a piece sets it in its [Variables], below the
; @Include lines: the last value read wins) runs after each switch; by default it updates the meters of group Ink and
; redraws.
;
; The switch: the mean luminance of the wallpaper under the piece (Chameleon's CropDesktop=Skin: the part of the
; picture that lies under the window, as macOS lays it on the screen; in dark mode a dynamic wallpaper's dark picture),
; with hysteresis: below 0.32 white ink, above 0.36 dark ink, in between the ink stays. It is checked every 5 s (the
; picture is decoded only when it changes, or when the Mac switches between light and dark) and again as soon as the
; piece has been moved. A piece starts in white ink. A wallpaper kept in Desktop, Documents or Downloads is not read
; (macOS would ask first), so the piece keeps white ink there. The suite setting Ink=Auto|White|Dark overrides it.

[Variables]
InkChangeAction=[!UpdateMeterGroup Ink][!Redraw]
; seconds between samples, as an UpdateDivider (a piece with Update other than 1000 sets its own)
InkDivider=5
InkModeAuto=0
InkModeWhite=1
InkModeDark=2
InkMode=[#InkMode[#Ink]]
InkLow=0.32
InkHigh=0.36
; white ink until the first sample says otherwise
InkRGB=255,255,255
HaloRGB=0,0,0
InkA1=255
InkA2=230
InkA3=150
InkShadowDisplay=Shadow | 0 | 2 | 16 | 0,0,0,105
InkShadowText=Shadow | 0 | 1 | 4 | 0,0,0,130
HaloOuterA=31
HaloInnerA=66
InkScrimA=46
MoonSuffix=

[MeasureInkWall]
Measure=Plugin
Plugin=Chameleon
Type=Desktop
CropDesktop=Skin
UpdateDivider=#InkDivider#

[MeasureInkLuminance]
; updated at once when a new sample is in (the piece moved, the wallpaper changed), and the ink with it
Measure=Plugin
Plugin=Chameleon
Parent=MeasureInkWall
Color=Luminance
UpdateDivider=#InkDivider#
OnChangeAction=[!UpdateMeasure MeasureInkDark]

[MeasureInkDark]
; reads its own previous value for the hysteresis; the Ink setting wins
Measure=Calc
Formula=(#InkMode# = 2) ? 1 : ((#InkMode# = 1) ? 0 : (MeasureInkDark ? (MeasureInkLuminance > #InkLow#) : (MeasureInkLuminance > #InkHigh#)))
UpdateDivider=#InkDivider#
IfCondition=MeasureInkDark = 1
IfTrueAction=[!SetVariable InkRGB "28,28,30"][!SetVariable HaloRGB "255,255,255"][!SetVariable InkA1 255][!SetVariable InkA2 200][!SetVariable InkA3 140][!SetVariable InkShadowDisplay "Shadow | 0 | 1.5 | 0 | 255,255,255,110"][!SetVariable InkShadowText "Shadow | 0 | 1 | 0 | 255,255,255,125"][!SetVariable HaloOuterA 26][!SetVariable HaloInnerA 56][!SetVariable InkScrimA 0][!SetVariable MoonSuffix ".inverse"]#InkChangeAction#
IfFalseAction=[!SetVariable InkRGB "255,255,255"][!SetVariable HaloRGB "0,0,0"][!SetVariable InkA1 255][!SetVariable InkA2 230][!SetVariable InkA3 150][!SetVariable InkShadowDisplay "Shadow | 0 | 2 | 16 | 0,0,0,105"][!SetVariable InkShadowText "Shadow | 0 | 1 | 4 | 0,0,0,130"][!SetVariable HaloOuterA 31][!SetVariable HaloInnerA 66][!SetVariable InkScrimA 46][!SetVariable MoonSuffix ""]#InkChangeAction#
