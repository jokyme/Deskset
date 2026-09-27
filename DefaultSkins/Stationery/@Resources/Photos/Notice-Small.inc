; Stationery · Photo Frame — the Small's Notice (choose a folder, none found, the path field), a centred column; then
; the drop ring. Original work, MIT licensed. The card under it takes the click, so the whole card is the action.

[MeterNoticeSymbol]
; photo, exclamationmark.triangle.fill or folder, 20 pt, its natural box centred on (85, 48)
Meter=Image
MeterStyle=sNoticeSymbol
ImageName=sf:[#PhotoSym[&MeasureMode:0]]
X=(85 - [#PhotoSymW[&MeasureMode:0]] / 2)
Y=(48 - [#PhotoSymH[&MeasureMode:0]] / 2)
W=[#PhotoSymW[&MeasureMode:0]]
H=[#PhotoSymH[&MeasureMode:0]]
Hidden=(([MeasureMode:] <> 2) && ([MeasureMode:] <> 3) && ([MeasureMode:] <> 5))
DynamicVariables=1
UpdateDivider=-1
Group=Notice

[MeterNoticeTitle]
; "Choose a Folder" or "No Photos Found" on baseline 82
Meter=String
MeterStyle=sBodyStrong | sNoticeTitleSmall
Text=[#PhotoTitleS[&MeasureMode:0]]
Hidden=(([MeasureMode:] <> 2) && ([MeasureMode:] <> 3) && ([MeasureMode:] <> 5))
DynamicVariables=1
UpdateDivider=-1
Group=Notice

[MeterNoticeBody]
; up to three lines from baseline 99; %1 is the folder's name
Meter=String
MeterStyle=sCaption | sNoticeBodySmall
MeasureName=MeasureFolderName
Text=[#PhotoBodyS[&MeasureMode:0]]
Hidden=(([MeasureMode:] <> 2) && ([MeasureMode:] <> 3) && ([MeasureMode:] <> 5))
DynamicVariables=1
UpdateDivider=-1
Group=Notice

[MeterNoticeAction]
; "Choose Folder…" on the last baseline; the path field takes its place while it is open
Meter=String
MeterStyle=sLabel | sNoticeActionSmall
Text=#PhotoChooseAction#
Hidden=(([MeasureMode:] <> 2) && ([MeasureMode:] <> 3))
DynamicVariables=1
UpdateDivider=-1
Group=Notice

[MeterDropRing]
; a folder or a photo dragged over the card (E34): a 2 pt ring just inside the edge, over any mode
Meter=Shape
Shape=Rectangle 1,1,(#CardW# - 2),(#CardH# - 2),25 | Fill Color 0,0,0,0 | StrokeWidth 2 | Stroke Color #AccentColor#
Hidden=(#DropOver# = 0)
DynamicVariables=1
UpdateDivider=-1
