; Stationery · Weather — the weather's words in English. Original work, MIT licensed.
; Strings-Chinese.inc has the same keys. A value with a space at either end is quoted, or the INI reader would trim
; it. Menu titles are Title Case and at most 30 characters. Conditions (Cond…) and states (Status…) are the suite's.

[Variables]
; ---------------------------------------------------------------- menu
WeatherMenuOpen=Open Weather
WeatherMenuLocation=Location…
WeatherMenuUseMyLocation=Use My Location
WeatherMenuStopMyLocation=Stop Using My Location
WeatherMenuRefresh=Refresh Weather

; ---------------------------------------------------------------- the card
; the header's title while there is no place
WeatherTitle=Weather
WeatherNow=Now
WeatherToday=Today
; "H:16° L:8°"
WeatherHigh=H:
WeatherLow=L:
WeatherFeelsLike=Feels like
WeatherHumidity=Humidity
WeatherWind=Wind
; the first-run check of a place taken from the Mac's time zone: "Not your city? Change…"
WeatherNotYourCity=Not your city?
WeatherChange=Change…
WeatherPromptTip=Deskset picked [MeasureWxPlace] from this Mac’s time zone. Click to change it.
; the high/low line while the data is not up to date (by WxStaleKey)
WeatherStaleOffline=Offline · [MeasureWxUpdated]
WeatherStaleUpdated=Updated [MeasureWxUpdated]
; the data credit (MET Norway's own words in English)
WeatherCredit=[MeasureWxAttribution]
WeatherCreditTip=Open api.met.no (MET Norway, CC BY 4.0)
; hour labels over the detail column: 24-hour "14", 12-hour "2 PM"; times in tooltips
WeatherHourFormat24=%H
WeatherHourFormat12=%#I %p
; tooltips: "16:00 · 14° · 40% chance of rain", "Sunday: 7° to 12° · 70% chance of rain"
WeatherRainPre=
WeatherRainPost=" chance of rain"
WeatherTo=" to "
WeatherColon=": "
; the card's sentence, by MeasureWxMode: 0 data, 1 waiting (the state's words), 2 a notice (its title)
WeatherCardTip0=[#Cond[&MeasureWxCond:]], [MeasureWxNow]° (feels like [MeasureWxFeels]°). Today [MeasureWxLow]° to [MeasureWxHigh]°. Updated [MeasureWxUpdated]. [MeasureWxAttribution].
WeatherCardTip1=[#Status[&MeasureWxStatus:]].
WeatherCardTip2=[#WeatherNoticeTitle[&MeasureWxStatus:]]. [#WeatherNoticeBody[&MeasureWxStatus:]]

; ---------------------------------------------------------------- notices, by MacWeather's Status
; 3 no place, 4 place not found, 5 Location Services off, 6 no fix, 11 weather turned off; the others show no notice
WeatherNoticeTitle3=Choose a City
WeatherNoticeBody3=Pick a city to see its weather. No location access needed.
WeatherNoticeAction3=Choose City…
WeatherNoticeTitle4=Place Not Found
WeatherNoticeBody4=No town called “#Location#”. Try a larger town nearby.
WeatherNoticeAction4=Change Location…
WeatherNoticeTitle5=Location Is Off
WeatherNoticeBody5=Allow Deskset in Location Services, or pick a city.
WeatherNoticeAction5=Open Privacy Settings
WeatherNoticeTitle6=Location Unavailable
WeatherNoticeBody6=This Mac’s location isn’t known right now.
WeatherNoticeAction6=Choose City…
WeatherNoticeTitle11=Weather Is Off
WeatherNoticeBody11=Weather requests are turned off in Deskset.
WeatherNoticeAction11=
WeatherNoticeTitle0=
WeatherNoticeBody0=
WeatherNoticeAction0=
WeatherNoticeTitle1=
WeatherNoticeBody1=
WeatherNoticeAction1=
WeatherNoticeTitle2=
WeatherNoticeBody2=
WeatherNoticeAction2=
WeatherNoticeTitle7=
WeatherNoticeBody7=
WeatherNoticeAction7=
WeatherNoticeTitle8=
WeatherNoticeBody8=
WeatherNoticeAction8=
WeatherNoticeTitle9=
WeatherNoticeBody9=
WeatherNoticeAction9=
WeatherNoticeTitle10=
WeatherNoticeBody10=
WeatherNoticeAction10=
WeatherNoticeTitle12=
WeatherNoticeBody12=
WeatherNoticeAction12=
WeatherNoticeTitle13=
WeatherNoticeBody13=
WeatherNoticeAction13=
