; Stationery · Sentence Clock — Background: None. Original work, MIT licensed.
; The same grid straight on the wallpaper, in the suite's shared frameless ink (Suite/Ink.inc): white ink on dark
; wallpapers, dark ink on light ones, chosen from the wallpaper under the piece (the suite's Ink setting overrides it).
; No glass and no veil; the card stays as an invisible shape, so the whole piece still drags and clicks.
; On a wallpaper with strong local contrast the unlit words can fade into bright patches with either ink; the lit
; words stay readable, and the card is then the better choice.

[Variables]
@Include=#@#Suite/Ink.inc
Glass=None
Veil=0,0,0,1
; the words' alphas on the wallpaper: higher than on glass, so the grid still reads as a texture. White ink first,
; dark ink after it (MeasureInkDark is 0 or 1; a section variable in [Variables] is read where it is used)
OnA=255
OffSubtle=(82 - 12 * [MeasureInkDark:])
OffVisible=(110 - 10 * [MeasureInkDark:])
OffHover=(128 - 18 * [MeasureInkDark:])
RuleA=(110 - 20 * [MeasureInkDark:])
; the suite ink's own variables, by name (see Card-Glass.inc): on the wallpaper the words' shadow carries legibility,
; not decoration (a soft dark shadow under white ink, a crisp light letterpress edge under dark ink); the footer
; takes the ink's secondary and tertiary alphas, and the hairline the suite's shape halo (shapes cannot cast shadows)
WordShadow=InkShadowText
FootTimeAlpha=InkA2
FootDateAlpha=InkA3
FootShadow=InkShadowText
RuleHaloOuter=HaloOuterA
RuleHaloInner=HaloInnerA
; after each switch of ink: the resting alpha of the unlit words follows, and the words, footer and rule redraw
InkChangeAction=[!SetVariable OffNow "#OffRest#"][!UpdateMeterGroup Words][!UpdateMeterGroup Footer][!UpdateMeterGroup Rule][!Redraw]
; the menu shows the suite's Ink item instead of Look and Cards, then Language (a blank title ends the list)
SentenceSuiteTitle1=#MenuInkTitle#
SentenceSuiteAction1=#MenuInkAction#
SentenceSuiteTitle2=#MenuLanguageTitle#
SentenceSuiteAction2=#MenuLanguageAction#
SentenceSuiteTitle3=
SentenceSuiteAction3=
