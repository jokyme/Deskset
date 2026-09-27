; Stationery · Spectrum — Bars: Album Art: a colour of the playing track's cover. Original work, MIT licensed.
;
; Chameleon picks it per look so it holds on the glass: Dark2 on light glass, Light1 on dark and clear glass (the
; cover's main colour, Background1, measured 2.3:1 on light glass). Without a cover the bars are the media colour.
; Only this option reads the cover, so only it looks covers up online (the artist and title of streamed tracks go to
; Apple's public search).

[Variables]
BarTint=#MediaColor#,255
BarTint2=#MediaColor#,153
; the media colour as Chameleon's fallback wants it (hex), by the look's theme and glass
MediaHexLightRegular=FF2D55
MediaHexDarkRegular=FF375F
MediaHexDarkClear=FFFFFF
MediaHex=[#MediaHex[#LookTheme][#Glass]]

[MeasureCover]
Measure=NowPlaying
PlayerName=[MeasureTitle]
PlayerType=Cover
Group=Player

[MeasureCoverImage]
Measure=Plugin
Plugin=Chameleon
Type=File
Path=[MeasureCover]
Format=Dec
; no cover (or one it cannot read): all four picks are the media colour
FallbackBG1=#MediaHex#
FallbackBG2=#MediaHex#
FallbackFG1=#MediaHex#
FallbackFG2=#MediaHex#

[MeasureCoverTone]
; its first value (the fallback) is the bars' starting colour; a cover's colour replaces it
Measure=Plugin
Plugin=Chameleon
Parent=MeasureCoverImage
Color=[#CoverPick[#LookTheme]]
OnChangeAction=[!SetOptionGroup Bars BarColor "[MeasureCoverTone],255"][!SetOptionGroup Bars MacBarColor2 "[MeasureCoverTone],153"][!SetOption MeterHeaderSymbol ImageTint "[MeasureCoverTone],255"][!UpdateMeterGroup Bars][!UpdateMeter MeterHeaderSymbol][!Redraw]
