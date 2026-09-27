; Stationery · Weather — the weather's words in Simplified Chinese. Original work, MIT licensed.
; The same keys as Strings-English.inc. A value with a space at either end is quoted, or the INI reader would trim it.

[Variables]
; ---------------------------------------------------------------- menu
WeatherMenuOpen=打开“天气”
WeatherMenuLocation=地点…
WeatherMenuUseMyLocation=使用我的位置
WeatherMenuStopMyLocation=停止使用我的位置
WeatherMenuRefresh=刷新天气

; ---------------------------------------------------------------- the card
WeatherTitle=天气
WeatherNow=现在
WeatherToday=今天
WeatherHigh="最高 "
WeatherLow="最低 "
WeatherFeelsLike=体感
WeatherHumidity=湿度
WeatherWind=风速
WeatherNotYourCity=不是这个城市？
WeatherChange=更改…
WeatherPromptTip=Deskset 按这台 Mac 的时区选了[MeasureWxPlace]。点按可更改。
WeatherStaleOffline=离线 · [MeasureWxUpdated]
WeatherStaleUpdated=[MeasureWxUpdated] 更新
WeatherCredit=数据来自 MET Norway
WeatherCreditTip=打开 api.met.no（挪威气象局，CC BY 4.0）
WeatherHourFormat24=%H
; 12-hour labels leave out 上午/下午: "下午12时" is wider than a column (the tooltips give the full time)
WeatherHourFormat12=%#I时
WeatherRainPre="降水概率 "
WeatherRainPost=
WeatherTo=" 至 "
WeatherColon=：
WeatherCardTip0=[#Cond[&MeasureWxCond:]]，[MeasureWxNow]°（体感 [MeasureWxFeels]°）。今天 [MeasureWxLow]° 至 [MeasureWxHigh]°。[MeasureWxUpdated] 更新。数据来自 MET Norway。
WeatherCardTip1=[#Status[&MeasureWxStatus:]]。
WeatherCardTip2=[#WeatherNoticeTitle[&MeasureWxStatus:]]。[#WeatherNoticeBody[&MeasureWxStatus:]]

; ---------------------------------------------------------------- notices, by MacWeather's Status
WeatherNoticeTitle3=选择城市
WeatherNoticeBody3=选一个城市即可查看天气，无需定位权限。
WeatherNoticeAction3=选择城市…
WeatherNoticeTitle4=找不到地点
WeatherNoticeBody4=找不到“#Location#”。试试附近较大的城镇。
WeatherNoticeAction4=更改地点…
WeatherNoticeTitle5=定位服务已关闭
WeatherNoticeBody5=请在定位服务中允许 Deskset，或选一个城市。
WeatherNoticeAction5=打开隐私设置
WeatherNoticeTitle6=无法获取位置
WeatherNoticeBody6=暂时无法获取这台 Mac 的位置。
WeatherNoticeAction6=选择城市…
WeatherNoticeTitle11=天气已关闭
WeatherNoticeBody11=Deskset 已关闭天气请求。
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
