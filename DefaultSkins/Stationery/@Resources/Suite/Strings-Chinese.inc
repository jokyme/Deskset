; Stationery — the widgets' words in Simplified Chinese. Original work, MIT licensed.
; The same keys as Strings-English.inc. Use it with Locale=zh_CN in Variables.inc, so day and month names are Chinese
; too. A value with a space at either end is quoted, or the INI reader would trim it.

[Variables]
; ---------------------------------------------------------------- dates and times
DateFormat=%#m月%#d日
DateFormatLong=%#m月%#d日 %A
DateFormatFull=%Y年%#m月%#d日 %A
CaptionTime24=%H:%M
CaptionTime12=%p %#I:%M
UnitDay=天
UnitHour=小时
UnitMinute=分钟

; ---------------------------------------------------------------- words several widgets share
StrSunrise=日出
StrSunset=日落
StrDaylight=昼长
StrMidnightSun=极昼
StrPolarNight=极夜
StrAllDay=全天
StrNone=无
StrChooseCity=选择城市…
StrOpenPrivacySettings=打开隐私设置

; ---------------------------------------------------------------- the suite's menu items
MenuLookAuto=外观：跟随系统
MenuLookLight=外观：浅色
MenuLookDark=外观：深色
MenuLookClear=外观：透明
MenuCards0=卡片：玻璃
MenuCards1=卡片：实色
MenuInkAuto=墨色：自动
MenuInkWhite=墨色：白色
MenuInkDark=墨色：深色
MenuClockAuto=时钟：自动
MenuClock24=时钟：24 小时制
MenuClock12=时钟：12 小时制
MenuWeekStartAuto=每周起始日：自动
MenuWeekStart0=每周起始日：星期日
MenuWeekStart1=每周起始日：星期一
MenuWeekStart2=每周起始日：星期二
MenuWeekStart3=每周起始日：星期三
MenuWeekStart4=每周起始日：星期四
MenuWeekStart5=每周起始日：星期五
MenuWeekStart6=每周起始日：星期六
MenuTempAuto=温度：自动
MenuTempC=温度：°C
MenuTempF=温度：°F

; ---------------------------------------------------------------- the moon
Moon0=新月
Moon1=蛾眉月
Moon2=上弦月
Moon3=盈凸月
Moon4=满月
Moon5=亏凸月
Moon6=下弦月
Moon7=残月

; ---------------------------------------------------------------- weather conditions
Cond0=未知
Cond1=晴
Cond2=大部晴朗
Cond3=局部多云
Cond4=阴
Cond5=阵雨
Cond6=雷阵雨
Cond7=阵雨夹雪
Cond8=阵雪
Cond9=雨
Cond10=大雨
Cond11=大雨伴雷
Cond12=雨夹雪
Cond13=雪
Cond14=雪伴雷
Cond15=雾
Cond20=阵雨夹雪伴雷
Cond21=阵雪伴雷
Cond22=雨伴雷
Cond23=雨夹雪伴雷
Cond24=小阵雨伴雷
Cond25=强雷阵雨
Cond26=小阵雨夹雪伴雷
Cond27=强阵雨夹雪伴雷
Cond28=小阵雪伴雷
Cond29=强阵雪伴雷
Cond30=小雨伴雷
Cond31=小雨夹雪伴雷
Cond32=强雨夹雪伴雷
Cond33=小雪伴雷
Cond34=大雪伴雷
Cond40=小阵雨
Cond41=强阵雨
Cond42=小阵雨夹雪
Cond43=强阵雨夹雪
Cond44=小阵雪
Cond45=强阵雪
Cond46=小雨
Cond47=小雨夹雪
Cond48=强雨夹雪
Cond49=小雪
Cond50=大雪

; ---------------------------------------------------------------- weather states
Status0=已是最新
Status1=正在载入天气…
Status2=不是最新
Status3=请设置地点
Status4=找不到地点
Status5=定位权限已关闭
Status6=暂时无法获取这台 Mac 的位置
Status7=此地没有预报
Status8=天气服务拒绝了请求
Status9=天气服务繁忙
Status10=离线 · 正在重试
Status11=天气已关闭
Status12=在桌面上显示
Status13=天气地点过多

; ---------------------------------------------------------------- Clock
ClockMenuOpen=打开时钟
ClockMenuLineSun=底行：日出日落
ClockMenuLineWeek=底行：周数
ClockMenuLineNone=底行：无
ClockMenuCity0=城市…
ClockMenuCity1=城市：[MeasureSunMenu]…
ClockMenuCity2=选择城市…
ClockNeedCity=日出日落需要城市
ClockWeekLine=第 [MeasureWeekNumber] 周 · 第 [MeasureYearDay] 天
ClockTipTime24=[MeasureTime]
ClockTipTime12=[MeasureAMPM] [MeasureTime]
ClockTipWeek=，第 [MeasureWeekNumber] 周，第 [MeasureYearDay] 天。
ClockTipBody0=
ClockTipBody1=[MeasureSun]：日出 [MeasureSunrise]，日落 [MeasureSunset]，昼长 [MeasureDayLengthText]。
ClockTipBody2=[MeasureSun]：极昼，今天太阳不落。
ClockTipBody3=[MeasureSun]：极夜，今天太阳不升。
ClockTipBody4=选择城市后显示日出和日落。
ClockTipMoon=[#Moon[&MeasureMoonEighth:0]]，亮面 [MeasureMoonIllum:0]%。
ClockTipChooseCity=选择日出日落所用的城市

; ---------------------------------------------------------------- Sentence Clock
SentenceMenuOpen=打开时钟
SentenceMenuCardGlass=背景：卡片
SentenceMenuCardFrameless=背景：无
SentenceMenuGrid0=未亮的词：淡
SentenceMenuGrid1=未亮的词：清晰
SentenceMenuGlow1=深色模式发光：开
SentenceMenuGlow0=深色模式发光：关
SentenceMenuTime1=底部时间：显示
SentenceMenuTime0=底部时间：隐藏

; ---------------------------------------------------------------- Almanac
AlmanacMenuOpen=打开日历
AlmanacMenuSizeSmall=大小：小
AlmanacMenuSizeRegular=大小：中
AlmanacMenuSizeLarge=大小：大
AlmanacMenuSun1=日出日落：显示
AlmanacMenuSun0=日出日落：隐藏
AlmanacWeekdaySuffix=
AlmanacWeekText=第 %1 周
AlmanacDayText=第 %1 天
AlmanacToGoText=还剩 %1 天
AlmanacDoneText=已过 [MeasureDaysPercent:0]%
AlmanacLastDay=最后一天
AlmanacSunriseText=日出 %1
AlmanacSunsetText=日落 %1
AlmanacYearText=%1 年
AlmanacWeeksLeftText=还剩 %1 周
AlmanacTipDay=[MeasureDateFull]#CRLF#第 [MeasureWeekNumber] 周 · 全年第 [MeasureDayOfYearNumber] 天，共 [MeasureDaysInYear:0] 天
AlmanacTipSun0=
AlmanacTipSun1=#CRLF#日出 [MeasureSunriseTip] · 日落 [MeasureSunsetTip]
AlmanacTipProgress=今年已过 [MeasureDaysPercent:0]% · 还剩 [MeasureDaysTo:0] 天#CRLF#每个点代表剩下的一周。

; ---------------------------------------------------------------- Daybreak
DaybreakMenuOpen=打开时钟
DaybreakMenuTint1=数字天色：开
DaybreakMenuTint0=数字天色：关
DaybreakMenuCity0=城市…
DaybreakMenuCity1=城市：[MeasurePlaceMenu]…
DaybreakMenuCity2=选择城市…
DaybreakNeedPlace=选择城市后显示日出和日落
DaybreakNextSunrise=[MeasureNextText]后日出
DaybreakNextSunset=[MeasureNextText]后日落
DaybreakGoldenPrefix="黄金时刻 · "
DaybreakTip0=选择城市后显示日出和日落。
DaybreakTip1=日出 [MeasureSunriseTip] · 日落 [MeasureSunsetTip]#CRLF#昼长 [MeasureDayLengthText] · 黄金时刻从 [MeasureGoldenStartTip] 开始
DaybreakTip2=极昼：今天太阳不落。
DaybreakTip3=极夜：今天太阳不升。

; ---------------------------------------------------------------- Chronograph
ChronoMenuOpen=打开时钟
ChronoMenuDial0=右侧表盘：自动
ChronoMenuDial1=右侧表盘：电池
ChronoMenuDial2=右侧表盘：CPU
ChronoMenuSeconds1=走秒：开
ChronoMenuSeconds0=走秒：关
ChronoMenuDialText=表盘文字…
ChronoMenuCity0=城市…
ChronoMenuCity1=城市：[MeasureWxPlaceMenu]…
ChronoMenuCity2=选择城市…
ChronoDialTextDefault=Deskset
ChronoTimeSeconds24=%H:%M:%S
ChronoTimeSeconds12=%p %#I:%M:%S
ChronoTipDate=[MeasureDateFull] · 第 [MeasureWeekNumber] 周
ChronoTipWeather0=[#Cond[&MeasureWxCondition:0]]，[MeasureWx:0]°（体感 [MeasureWxFeels:0]°）。今天 [MeasureWxLow:0]° 到 [MeasureWxHigh:0]°，圆点表示现在。
ChronoTipWeather1=[#Status[&MeasureWxStatus:0]]
ChronoTipWeather2=[#Status[&MeasureWxStatus:0]]。点按以选择城市。
ChronoTipWeather3=[#Status[&MeasureWxStatus:0]]。点按以打开隐私设置。
ChronoTipWeather4=[#Cond[&MeasureWxCondition:0]]，[MeasureWx:0]°（体感 [MeasureWxFeels:0]°）。今天 [MeasureWxLow:0]° 到 [MeasureWxHigh:0]°。#CRLF#[#Status[&MeasureWxStatus:0]]
ChronoTipReserve0=电池 [CalcReserveValue:0]% · 还可使用 [MeasureBattLifeText]
ChronoTipReserve1=电池 [CalcReserveValue:0]% · 正在充电
ChronoTipReserve2=电池 [CalcReserveValue:0]% · 已接通电源
ChronoTipReserve3=CPU [CalcReserveValue:0]%
ChronoTipReserve4=电池 [CalcReserveValue:0]%

; ---------------------------------------------------------------- the player (Collection/Player.inc)
MenuPlayerMusic=播放器：音乐
MenuPlayerSpotify=播放器：Spotify
MenuOpenPlayerMusic=打开音乐
MenuOpenPlayerSpotify=打开 Spotify

; ---------------------------------------------------------------- Turntable
TurntableMenuVinyl1=唱片颜色：取自封面
TurntableMenuVinyl0=唱片颜色：经典黑
TurntableMenuRest1Min=唱臂复位：1 分钟后
TurntableMenuRest5Min=唱臂复位：5 分钟后
TurntableMenuRestNever=唱臂复位：从不
TurntableMenuSeek1=点按唱纹跳转：开
TurntableMenuSeek0=点按唱纹跳转：关
TurntableSpeed=33⅓ RPM
TurntableSideA=A 面
TurntableNotPlaying=未在播放
TurntablePlaySomething=在“音乐”或 Spotify 中播放点什么
TurntableTipPlay=播放
TurntableTipPause=暂停
TurntableTipPrevious=上一首
TurntableTipNext=下一首
TurntableTipSeek=从 [MeasureSeekMin:0]:[MeasureSeekSec] 开始播放
TurntableTipTrack=[MeasureLastTitle] — [MeasureLastArtist]
