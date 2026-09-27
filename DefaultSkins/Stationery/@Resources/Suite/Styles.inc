; Stationery — text styles and the component kit. Original work, MIT licensed.
; Include after Suite/Tokens.inc. Every text meter uses one text style; a meter may add kit styles after it
; (MeterStyle=sValue | sUnit | sMissing). Later styles win, and the meter's own options win over all of them.
;
; Inline slots. The engine reads InlineSetting, InlineSetting2… up to the first one that is missing or empty, so every
; text style fills slots 1–6, with None where it has nothing to do:
;   1–3  the style: digit runs set in SF Pro Rounded with tabular figures, tracking of capitals
;   4–6  the unit kit (sUnit)
;   7    sMissing ("--" in Tertiary); 8–10 sWordValue (a value that is a word, in SF Pro)
; A meter's own inline settings start at 7, or at 8 with sMissing, or at 11 with sWordValue.
;
; Sizes: FontSize = points × 0.75. Weights: 600 for values and names, 500 for supporting text, 700 for eyebrows and
; micro labels. Only capitals are tracked. Words are never in SF Pro Rounded; every run of digits is (sMono aside).

; ================================================================ text styles

; ---------------------------------------------------------------- numbers (SF Pro Rounded, tabular)
[sHero]
; 46 pt: the clock's time, the Calendar's day (on baseline 94: Y 49.53)
FontFace=#FontNumber#
FontSize=34.5
FontWeight=600
FontColor=#TextColor#
AntiAlias=1
InlineSetting=Typography | tnum
InlinePattern=.*
InlineSetting2=None
InlineSetting3=None
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

[sMetricXL]
; 40 pt: one hero value, a temperature, storage available, days (on baseline 83: Y 44.33)
FontFace=#FontNumber#
FontSize=30
FontWeight=600
FontColor=#TextColor#
AntiAlias=1
InlineSetting=Typography | tnum
InlinePattern=.*
InlineSetting2=None
InlineSetting3=None
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

[sMetricM]
; 22 pt: speeds, battery %, world times, the timer
FontFace=#FontNumber#
FontSize=16.5
FontWeight=600
FontColor=#TextColor#
AntiAlias=1
InlineSetting=Typography | tnum
InlinePattern=.*
InlineSetting2=None
InlineSetting3=None
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

[sMetricS]
; 15 pt: the value under a ring
FontFace=#FontNumber#
FontSize=11.25
FontWeight=600
FontColor=#TextColor#
AntiAlias=1
InlineSetting=Typography | tnum
InlinePattern=.*
InlineSetting2=None
InlineSetting3=None
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

[sValue]
; 13 pt: a row's value
FontFace=#FontNumber#
FontSize=9.75
FontWeight=600
FontColor=#TextColor#
AntiAlias=1
InlineSetting=Typography | tnum
InlinePattern=.*
InlineSetting2=None
InlineSetting3=None
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

[sValueS]
; 11 pt: a value in an 11 pt row
FontFace=#FontNumber#
FontSize=8.25
FontWeight=600
FontColor=#TextColor#
AntiAlias=1
InlineSetting=Typography | tnum
InlinePattern=.*
InlineSetting2=None
InlineSetting3=None
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

; ---------------------------------------------------------------- captions in SF Pro Rounded (words inside stay SF Pro)
[sCaptionNum]
; 11 pt: media times, hour labels, offsets, calendar dates ("Now", "AM" and "h" in SF Pro)
FontFace=#FontNumber#
FontSize=8.25
FontWeight=500
FontColor=#TertiaryTextColor#
AntiAlias=1
InlineSetting=Typography | tnum
InlinePattern=.*
InlineSetting2=Face | #FontText#
InlinePattern2=\p{L}+
InlineSetting3=None
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

[sMicroNum]
; 9 pt bold: rain chips, week numbers (meaning given by position; the tooltip says it in full)
FontFace=#FontNumber#
FontSize=6.75
FontWeight=700
FontColor=#TertiaryTextColor#
AntiAlias=1
InlineSetting=Typography | tnum
InlinePattern=.*
InlineSetting2=Face | #FontText#
InlinePattern2=\p{L}+
InlineSetting3=None
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

; ---------------------------------------------------------------- words (SF Pro; their digit runs in SF Pro Rounded)
[sTitle]
; 15 pt: a track's title
FontFace=#FontText#
FontSize=11.25
FontWeight=600
FontColor=#TextColor#
AntiAlias=1
InlineSetting=Face | #FontNumber#
InlinePattern=#DigitRun#
InlineSetting2=Typography | tnum
InlinePattern2=#DigitRun#
InlineSetting3=None
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

[sSubhead]
; 15 pt: the date under a clock, a month and year
FontFace=#FontText#
FontSize=11.25
FontWeight=500
FontColor=#SecondaryTextColor#
AntiAlias=1
InlineSetting=Face | #FontNumber#
InlinePattern=#DigitRun#
InlineSetting2=Typography | tnum
InlinePattern2=#DigitRun#
InlineSetting3=None
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

[sBodyStrong]
; 13 pt: names (a volume, a city, an item)
FontFace=#FontText#
FontSize=9.75
FontWeight=600
FontColor=#TextColor#
AntiAlias=1
InlineSetting=Face | #FontNumber#
InlinePattern=#DigitRun#
InlineSetting2=Typography | tnum
InlinePattern2=#DigitRun#
InlineSetting3=None
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

[sBody]
; 13 pt: an artist, row labels, list items
FontFace=#FontText#
FontSize=9.75
FontWeight=500
FontColor=#SecondaryTextColor#
AntiAlias=1
InlineSetting=Face | #FontNumber#
InlinePattern=#DigitRun#
InlineSetting2=Typography | tnum
InlinePattern2=#DigitRun#
InlineSetting3=None
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

[sItem]
; 13 pt: text the user typed (to-do items). It is not data, so its digits stay SF Pro ("Call Mum at 5")
FontFace=#FontText#
FontSize=9.75
FontWeight=500
FontColor=#TextColor#
AntiAlias=1
InlineSetting=None
InlineSetting2=None
InlineSetting3=None
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

[sLabel]
; 11 pt: header titles, control labels, actions
FontFace=#FontText#
FontSize=8.25
FontWeight=600
FontColor=#SecondaryTextColor#
AntiAlias=1
InlineSetting=Face | #FontNumber#
InlinePattern=#DigitRun#
InlineSetting2=Typography | tnum
InlinePattern2=#DigitRun#
InlineSetting3=None
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

[sCaption]
; 11 pt: sub-lines, status, a condition
FontFace=#FontText#
FontSize=8.25
FontWeight=500
FontColor=#SecondaryTextColor#
AntiAlias=1
InlineSetting=Face | #FontNumber#
InlinePattern=#DigitRun#
InlineSetting2=Typography | tnum
InlinePattern2=#DigitRun#
InlineSetting3=None
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

[sFineprint]
; 9 pt regular: data attribution only
FontFace=#FontText#
FontSize=6.75
FontWeight=400
FontColor=#SecondaryTextColor#
AntiAlias=1
InlineSetting=Face | #FontNumber#
InlinePattern=#DigitRun#
InlineSetting2=Typography | tnum
InlinePattern2=#DigitRun#
InlineSetting3=None
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

; ---------------------------------------------------------------- capitals (tracked)
[sEyebrow]
; 11 pt bold capitals: a weekday or a month above a clock or a calendar. AccentTextColor; inside the Calendar,
; CalendarTextColor
FontFace=#FontText#
FontSize=8.25
FontWeight=700
FontColor=#AccentTextColor#
StringCase=Upper
AntiAlias=1
InlineSetting=Face | #FontNumber#
InlinePattern=#DigitRun#
InlineSetting2=Typography | tnum
InlinePattern2=#DigitRun#
InlineSetting3=CharacterSpacing | 0 | 0.6
InlinePattern3=.*
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

[sLabelCaps]
; 11 pt capitals: ring labels (CPU, MEMORY)
FontFace=#FontText#
FontSize=8.25
FontWeight=600
FontColor=#SecondaryTextColor#
StringCase=Upper
AntiAlias=1
InlineSetting=Face | #FontNumber#
InlinePattern=#DigitRun#
InlineSetting2=Typography | tnum
InlinePattern2=#DigitRun#
InlineSetting3=CharacterSpacing | 0 | 0.4
InlinePattern3=.*
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

[sMicro]
; 9 pt bold capitals: weekday initials, axis ticks, AM/PM tags (meaning given by position)
FontFace=#FontText#
FontSize=6.75
FontWeight=700
FontColor=#TertiaryTextColor#
StringCase=Upper
AntiAlias=1
InlineSetting=Face | #FontNumber#
InlinePattern=#DigitRun#
InlineSetting2=Typography | tnum
InlinePattern2=#DigitRun#
InlineSetting3=CharacterSpacing | 0 | 0.2
InlinePattern3=.*
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

[sMono]
; 10 pt SF Mono capitals, digits included: almanac data lines only
FontFace=#FontMono#
FontSize=7.5
FontWeight=500
FontColor=#SecondaryTextColor#
StringCase=Upper
AntiAlias=1
InlineSetting=CharacterSpacing | 0 | 1.2
InlinePattern=.*
InlineSetting2=None
InlineSetting3=None
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

; ================================================================ value styling (add after a text style)

[sUnit]
; slots 4–6: the unit after a value ("2.7 MB/s", "11 h 56 min", "7:10 AM") in 11 pt SF Pro, Secondary, at the
; value's weight; the space before it takes the unit's size too. The value and its unit are one String meter, so they
; share a baseline. "--", "73%" and "52°" have no unit.
InlineSetting4=Face | #FontText#
InlinePattern4=#UnitRun#
InlineSetting5=Size | 8.25
InlinePattern5=#UnitRunSpaced#
InlineSetting6=Color | #SecondaryTextColor#
InlinePattern6=#UnitRun#

[sNoUnit]
; slots 4–6 empty (every text style already has them empty; kept so a list of styles can say so)
InlineSetting4=None
InlineSetting5=None
InlineSetting6=None

[sMissing]
; slot 7: a missing or loading value ("--", "--°", "--%"), or an event that does not happen ("—"), in Tertiary; a
; unit after it keeps the unit's colour
InlineSetting7=Color | #TertiaryTextColor#
InlinePattern7=^((?:--|—)(?:°|%)?)

[sWordValue]
; slots 7–10: a value that is a word ("Unplugged", "All day") is supporting text: SF Pro 500 in Secondary. It brings
; sMissing's slot 7 along, so it works with or without it.
InlineSetting7=Color | #TertiaryTextColor#
InlinePattern7=^((?:--|—)(?:°|%)?)
InlineSetting8=Face | #FontText#
InlinePattern8=^(\p{L}[\p{L} ]*)$
InlineSetting9=Weight | 500
InlinePattern9=^(\p{L}[\p{L} ]*)$
InlineSetting10=Color | #SecondaryTextColor#
InlinePattern10=^(\p{L}[\p{L} ]*)$

; ================================================================ components

[sCard]
; The card: the first meter of every widget (Meter=Shape). One piece of glass, with the look's veil drawn over it;
; no outline, no shadow. Set CardW, CardH and OpenAction (the card's click, which opens the widget's Mac app; empty
; for the tools) in the widget's [Variables], the widget's sentence in ToolTipText, and how often the sentence is read
; again: UpdateDivider=60, or -1 in the group the widget updates when its data changes (the Clock's minute tick).
Shape=Rectangle 0,0,#CardW#,#CardH#,#CardRadius# | Fill Color #Veil# | StrokeWidth 0
MacGlass=#Glass#
MacGlassTint=#GlassTint#
LeftMouseUpAction=#OpenAction#
DynamicVariables=1

[sHit]
; the hit box of a control or a row (an Image meter with W and H): clickable everywhere inside
SolidColor=0,0,0,1

[sSymbolS]
; an SF Symbol beside 11 pt text, header rows included: set ImageName=sf:…, ImageTint, and W × H at its natural
; size, centred on its slot (x 26 in the header and rows; y = baseline − 3.9, or 23 in the header)
MacSymbolSize=11
MacSymbolWeight=Semibold
PreserveAspectRatio=1

[sSymbolM]
; an SF Symbol beside 13 pt text (y = baseline − 4.6)
MacSymbolSize=13
MacSymbolWeight=Semibold
PreserveAspectRatio=1

[sHeaderTitle]
; the header's title, after the symbol in the leading slot (MeterStyle=sLabel | sHeaderTitle); leave room for a
; trailing value by setting a smaller W
X=41
Y=16
W=(#CardW# - 57)
ClipString=1

[sHeaderTrailing]
; one short value at the header's right, in Tertiary (MeterStyle=sCaption | sHeaderTrailing)
StringAlign=Right
X=(#CardW# - 16)
Y=16
FontColor=#TertiaryTextColor#

[sEyebrowTrailing]
; a second eyebrow at the top right: AM/PM in Secondary (MeterStyle=sEyebrow | sEyebrowTrailing)
StringAlign=Right
X=(#CardW# - 16)
Y=16
FontColor=#SecondaryTextColor#

[sRowValue]
; a row's value at the right padding (with sValue or sValueS)
StringAlign=Right
X=(#CardW# - 16)

[sArtwork]
; album art and app icons: filled and cropped, full colour in every look. Set W, H and
; MaskImageName=#@#Suite/Masks/Art36.png (corner 8), Art64.png or Art138.png (corner 10). A photo that fills the card
; uses Card-Small.png, Card-Medium.png or Card-Large.png
PreserveAspectRatio=2

[sSparkArea]
; a sparkline's area: a Histogram in the same box as its sSparkLine and bound to the same measures, so their
; automatic ranges agree (PrimaryColor = the category colour at alpha 51)
AutoScale=1
AntiAlias=1

[sSparkLine]
; a sparkline's 1.5 pt line (LineColor = the category colour)
LineCount=1
LineWidth=1.5
AutoScale=1
AntiAlias=1

; ---------------------------------------------------------------- notices: empty, permission and error states
[sNoticeSymbol]
; 20 pt, Hierarchical, Secondary. Small: centred on (85, 48); Medium and Large: from y 40 at x 16
MacSymbolSize=20
MacSymbolWeight=Regular
MacSymbolRendering=Hierarchical
ImageTint=#SecondaryTextColor#
PreserveAspectRatio=1

[sNoticeTitleSmall]
; MeterStyle=sBodyStrong | sNoticeTitleSmall: centred, baseline 82
StringAlign=Center
X=(#CardW# / 2)
Y=(82 - #Ascent13#)
W=(#CardW# - 32)
ClipString=1

[sNoticeBodySmall]
; MeterStyle=sCaption | sNoticeBodySmall: centred, up to three lines from baseline 99 (Deskset's line pitch at 11 pt
; is 12.95, so the next baselines are 112 and 125)
StringAlign=Center
X=(#CardW# / 2)
Y=(99 - #Ascent11#)
W=(#CardW# - 32)
H=42
ClipString=2

[sNoticeActionSmall]
; MeterStyle=sLabel | sNoticeActionSmall: centred on the last baseline, a link (the whole card clicks it too)
StringAlign=Center
X=(#CardW# / 2)
Y=(#CardH# - 19 - #Ascent11#)
FontColor=#AccentTextColor#

[sNoticeTitle]
; Medium and Large: MeterStyle=sBodyStrong | sNoticeTitle, baseline 86 at x 16
X=16
Y=(86 - #Ascent13#)
W=(#CardW# - 32)
ClipString=1

[sNoticeBody]
; Medium and Large: MeterStyle=sCaption | sNoticeBody, from baseline 103
X=16
Y=(103 - #Ascent11#)
W=(#CardW# - 32)
ClipString=2

[sNoticeAction]
; Medium and Large: MeterStyle=sLabel | sNoticeAction, on the last baseline
X=16
Y=(#CardH# - 19 - #Ascent11#)
FontColor=#AccentTextColor#

; ---------------------------------------------------------------- data credit
[sCreditSmall]
; MeterStyle=sFineprint | sCreditSmall: centred on the attribution strip, baseline H − 9
StringAlign=Center
X=(#CardW# / 2)
Y=(#CardH# - 9 - #Ascent9#)

[sCreditMedium]
; right-aligned under the detail column
StringAlign=Right
X=(#CardW# - 16)
Y=(#CardH# - 9 - #Ascent9#)

[sCreditLarge]
; left-aligned
X=16
Y=(#CardH# - 9 - #Ascent9#)
