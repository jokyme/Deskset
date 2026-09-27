; Stationery · Spectrum — the Strip's Bars: Album Art: a colour of the playing track's cover, per ink: Light1 under
; white ink, Dark2 under dark ink. Without a cover the bars are the ink. Original work, MIT licensed.

[MeasureCover]
Measure=NowPlaying
PlayerName=[MeasureTitle]
PlayerType=Cover
Group=Player

[MeasureCoverImage]
; with these fallbacks Light1 is white and Dark2 the dark ink until a cover is read
Measure=Plugin
Plugin=Chameleon
Type=File
Path=[MeasureCover]
Format=Dec
FallbackBG1=FFFFFF
FallbackBG2=FFFFFF
FallbackFG1=1C1C1E
FallbackFG2=1C1C1E

[MeasureCoverLight1]
Measure=Plugin
Plugin=Chameleon
Parent=MeasureCoverImage
Color=Light1

[MeasureCoverDark2]
Measure=Plugin
Plugin=Chameleon
Parent=MeasureCoverImage
Color=Dark2

[MeasureStripTint]
; "231,124,103": the cover's colour for the ink under the Strip
Measure=String
String=[MeasureInkDark:0]␟[MeasureCoverLight1]␟[MeasureCoverDark2]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^0␟([^␟]*)␟.*$":"\1","^1␟[^␟]*␟(.*)$":"\1"
OnChangeAction=[!SetOptionGroup Bars BarColor "[MeasureStripTint],255"][!UpdateMeterGroup Bars][!Redraw]

[MeasureStripTintFirst]
; OnChangeAction skips the first value after load, and the ink may start dark: this applies the first one
Measure=Calc
Formula=1
UpdateDivider=-1
IfCondition=MeasureStripTintFirst = 1
IfTrueAction=[!SetOptionGroup Bars BarColor "[MeasureStripTint],255"][!UpdateMeterGroup Bars][!Redraw]
