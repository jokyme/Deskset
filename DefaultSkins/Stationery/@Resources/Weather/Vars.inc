; Stationery · Weather — the widget's own variables, for all three sizes. Original work, MIT licensed.
; Included in [Variables] after the suite's files and Weather/Strings-<Language>.inc.

[Variables]
; the header's glyph: a named or time-zone city; MeasureLocationKind switches it to location.fill for Location=auto
WxPlaceSymbol=mappin.and.ellipse

; ---------------------------------------------------------------- times, by the suite's 12/24-hour setting (Hours)
; hour labels over the detail column ("14" / "2 PM") and times in tooltips and the stale line ("16:00" / "4:00 PM")
WxHourFormat=[#WeatherHourFormat[#Hours]]
WxTimeFormat=[#CaptionTime[#Hours]]

; ---------------------------------------------------------------- the stale line (the high/low line while the data is old)
; MeasureWxStatus sets WxStaleKey: Offline when MacWeather says the Mac is offline, else Updated
WxStaleKey=Updated
WxStaleSymbolOffline=wifi.slash
WxStaleSymbolUpdated=clock

; ---------------------------------------------------------------- the curve and the range bars by look
; the top alpha of the curve's area (raised in Light, where the scale's pastels sit on light glass) and the ring of
; today's dot on the first range bar
WxAreaAlphaLightRegular=90
WxAreaAlphaDarkRegular=64
WxAreaAlphaDarkClear=51
WxDotRingColorLightRegular=0,0,0,90
WxDotRingColorDarkRegular=0,0,0,150
WxDotRingColorDarkClear=0,0,0,120
WxAreaAlpha=[#WxAreaAlpha[#LookTheme][#Glass]]
WxDotRingColor=[#WxDotRingColor[#LookTheme][#Glass]]
; the colour TemperatureColor gives instead of the scale (MacWeather's ScaleColor): Clear's bars and curve area white
WxScaleColorLightRegular=
WxScaleColorDarkRegular=
WxScaleColorDarkClear=255,255,255
WxScaleColor=[#WxScaleColor[#LookTheme][#Glass]]

; ---------------------------------------------------------------- notices, by MacWeather's Status (0–13)
; the symbol and its natural size at 20 pt (so it is drawn at its own size: left-aligned in the Medium and Large,
; centred in the Small); states without a notice have none
WxNoticeSymbol3=mappin.and.ellipse
WxNoticeSymbol4=exclamationmark.triangle.fill
WxNoticeSymbol5=location.slash.fill
WxNoticeSymbol6=location.slash.fill
WxNoticeSymbol11=cloud.fill
WxNoticeSymbolW3=22
WxNoticeSymbolH3=27
WxNoticeSymbolW4=25
WxNoticeSymbolH4=22
WxNoticeSymbolW5=24
WxNoticeSymbolH5=24
WxNoticeSymbolW6=24
WxNoticeSymbolH6=24
WxNoticeSymbolW11=26
WxNoticeSymbolH11=19
WxNoticeSymbol0=
WxNoticeSymbol1=
WxNoticeSymbol2=
WxNoticeSymbol7=
WxNoticeSymbol8=
WxNoticeSymbol9=
WxNoticeSymbol10=
WxNoticeSymbol12=
WxNoticeSymbol13=
WxNoticeSymbolW0=1
WxNoticeSymbolW1=1
WxNoticeSymbolW2=1
WxNoticeSymbolW7=1
WxNoticeSymbolW8=1
WxNoticeSymbolW9=1
WxNoticeSymbolW10=1
WxNoticeSymbolW12=1
WxNoticeSymbolW13=1
WxNoticeSymbolH0=1
WxNoticeSymbolH1=1
WxNoticeSymbolH2=1
WxNoticeSymbolH7=1
WxNoticeSymbolH8=1
WxNoticeSymbolH9=1
WxNoticeSymbolH10=1
WxNoticeSymbolH12=1
WxNoticeSymbolH13=1
; what a notice's action (and a click anywhere on the card) does: 1 open the city field, 2 open Location Services in
; System Settings, 0 nothing of its own (the card opens Weather)
WxNoticeKind3=1
WxNoticeKind4=1
WxNoticeKind5=2
WxNoticeKind6=1
WxNoticeKind0=0
WxNoticeKind1=0
WxNoticeKind2=0
WxNoticeKind7=0
WxNoticeKind8=0
WxNoticeKind9=0
WxNoticeKind10=0
WxNoticeKind11=0
WxNoticeKind12=0
WxNoticeKind13=0
WxOpenCityField=[!CommandMeasure MeasureCityInput "ExecuteBatch 1"]
WxOpenPrivacySettings=["x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"]
