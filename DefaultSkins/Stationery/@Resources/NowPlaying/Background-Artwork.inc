; Stationery · Now Playing — Background: Artwork: the card takes the cover's colour. Original work, MIT licensed.
;
; The tint is the cover's darkest colour (Chameleon's Dark1), drawn opaque over the glass, so the glass under it
; cannot change the contrast; like "Cards: Solid" it does not depend on the wallpaper. It is darkened only as far as
; white ink needs (a background of luminance 0.06 at most gives white text 7:1, secondary 4.5:1 and tertiary 3:1): a
; shade over the card, from ArtShadeTop at the top to 38 more at the bottom. The ink is the Dark look's white ink, in
; every look. Without a cover the card is the Dark look's veil colour.

[Variables]
@Include=#@#Suite/Looks/Dark.inc
; the tint (MeasureArtTint sets it): the Dark look's veil colour, opaque, until the cover is read
Veil=28,28,30,255
ArtShadeTop=[MeasureArtShade:0]
ArtShadeBottom=([MeasureArtShade:0] + 38)

[MeasureArt]
Measure=Plugin
Plugin=Chameleon
Type=File
Path=[MeasureCover]
Format=Dec
FallbackBG1=1C1C1E
FallbackBG2=2C2C2E
FallbackFG1=FFFFFF
FallbackFG2=C8C8CC

[MeasureArtTint]
; "74,30,73": the darkest of the cover's two backgrounds and two foregrounds
Measure=Plugin
Plugin=Chameleon
Parent=MeasureArt
Color=Dark1
; every update: a new cover's colour replaces the last one
IfMatch=^\d+,\d+,\d+$
IfMatchAction=[!SetVariable Veil "[MeasureArtTint],255"]
IfMatchMode=1

[MeasureArtTintLum]
; the same colour written as a formula for its luminance (gamma 2.2)
Measure=Plugin
Plugin=Chameleon
Parent=MeasureArt
Color=Dark1
RegExpSubstitute=1
Substitute="^(\d+),(\d+),(\d+)$":"(0.2126 * (\1 / 255) ** 2.2 + 0.7152 * (\2 / 255) ** 2.2 + 0.0722 * (\3 / 255) ** 2.2)"

[MeasureArtShade]
; 0-153: how much black the shade adds at the top (at most 60 %)
Measure=Calc
Formula=Round(255 * Clamp(1 - (0.06 / Max([MeasureArtTintLum], 0.001)) ** 0.4545, 0, 0.6))
DynamicVariables=1
