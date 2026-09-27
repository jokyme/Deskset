; Stationery · Weather — the notice of the Medium and Large (no place, place not found, Location off, no fix, weather
; turned off): the kit's notice, left-aligned under the header row, which stays. Original work, MIT licensed.
; Included from [MeterCard] last. The whole card is the notice's action: one invisible target per kind of action.

[MeterNoticeHitCity]
Meter=Image
MeterStyle=sHit
X=0
Y=0
W=#CardW#
H=#CardH#
LeftMouseUpAction=#WxOpenCityField#
Hidden=([MeasureWxNoticeKind:] <> 1)
DynamicVariables=1
Group=Weather

[MeterNoticeHitPrivacy]
Meter=Image
MeterStyle=sHit
X=0
Y=0
W=#CardW#
H=#CardH#
LeftMouseUpAction=#WxOpenPrivacySettings#
Hidden=([MeasureWxNoticeKind:] <> 2)
DynamicVariables=1
Group=Weather

[MeterNoticeSymbol]
; 20 pt at its natural size, from y 40 at x 16
Meter=Image
MeterStyle=sNoticeSymbol
ImageName=sf:[#WxNoticeSymbol[&MeasureWxStatus:]]
X=16
Y=40
W=[#WxNoticeSymbolW[&MeasureWxStatus:]]
H=[#WxNoticeSymbolH[&MeasureWxStatus:]]
Hidden=([MeasureWxMode:] <> 2)
DynamicVariables=1
Group=Weather

[MeterNoticeTitle]
Meter=String
MeterStyle=sBodyStrong | sNoticeTitle
Text=[#WeatherNoticeTitle[&MeasureWxStatus:]]
Hidden=([MeasureWxMode:] <> 2)
DynamicVariables=1
Group=Weather

[MeterNoticeBody]
Meter=String
MeterStyle=sCaption | sNoticeBody
Text=[#WeatherNoticeBody[&MeasureWxStatus:]]
H=39
Hidden=([MeasureWxMode:] <> 2)
DynamicVariables=1
Group=Weather

[MeterNoticeAction]
; on the last baseline, in the link colour; the card's targets above take the click
Meter=String
MeterStyle=sLabel | sNoticeAction
Text=[#WeatherNoticeAction[&MeasureWxStatus:]]
Hidden=([MeasureWxMode:] <> 2)
DynamicVariables=1
Group=Weather
