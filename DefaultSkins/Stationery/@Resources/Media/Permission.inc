; Stationery — whether macOS lets Deskset read the player. Original work, MIT licensed.
;
; The media widgets include this file in their [Variables], after Media/Media.inc:
;     @IncludeMediaPermission=#@#Media/Permission.inc
; Reading the permission never asks for it (Deskset's PlayerType=MacPermission): macOS asks once, at the first poll of
; a running Music or Spotify, as it always does.
;
; MeasureAccess is 1 while a running player refused Deskset (Automation) and there is no other track to show, 2 while a
; running player has not been asked yet (macOS's prompt may be on screen), else 0. Its string is the player it is about
; (the one the widget shows when 0), turned into 1 (Music) or 2 (Spotify), the index the Strings name players by.
; MeasureAccessPlayer is that player's name in the widget's language ([MeasureAccessPlayer] in the Strings).

[MeasureAccess]
Measure=NowPlaying
PlayerName=#Player#
PlayerType=MacPermission
Substitute="Music":"1","Spotify":"2"
Group=Player

[MeasureAccessPlayer]
; "Music"
Measure=String
String=[#PlayerName[&MeasureAccess]]
DynamicVariables=1
Group=Player

[MeasureAccessOn]
; 1 while the widget shows that access is refused; its number picks the state's words and clicks ([#…[&MeasureAccessOn:0]])
Measure=Calc
Formula=MeasureAccess = 1
Group=Player
