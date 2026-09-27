; Stationery · Weather — the header row: the place, and in the Medium and Large the first-run check. Original work,
; MIT licensed. Included from [MeterCard], so it draws right after the card.

[MeterPlaceSymbol]
; mappin.and.ellipse for a named or time-zone city, location.fill for this Mac's location; centred on (26, 23)
Meter=Image
MeterStyle=sSymbolS
ImageName=sf:#WxPlaceSymbol#
ImageTint=#SecondaryTextColor#
X=19
Y=15
W=14
H=16
; the Small's notice has no header
Hidden=((#CardW# < 200) && ([MeasureWxMode:] = 2))
DynamicVariables=1
Group=Weather
UpdateDivider=-1

[MeterPlace]
; "Oslo" (or "Weather" without a place), clipped where the first-run check starts
Meter=String
MeterStyle=sLabel | sHeaderTitle
MeasureName=MeasureWxPlace
W=(#CardW# - 57 - [MeasureWxPrompt:] * 146 * (#CardW# > 200))
Hidden=((#CardW# < 200) && ([MeasureWxMode:] = 2))
DynamicVariables=1
Group=Weather

[MeterPrompt]
; Medium and Large, first run: "Not your city? Change…" in the header's trailing slot (the Small has it on its high/low
; line). Padding makes a 28 pt tall target; the baseline stays on the header's 26.6
Meter=String
MeterStyle=sCaption
StringAlign=Right
X=(#CardW# - 16)
Y=9
Padding=6,7,0,7
SolidColor=0,0,0,1
Text=#WeatherNotYourCity# #WeatherChange#
InlineSetting7=Color | #AccentTextColor#
InlinePattern7=#WeatherChange#
LeftMouseUpAction=#WxOpenCityField#
ToolTipText=#WeatherPromptTip#
Hidden=(([MeasureWxPrompt:] = 0) || (#CardW# < 200))
DynamicVariables=1
Group=Weather
