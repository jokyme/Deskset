; Stationery · Photo Frame — the Medium's and Large's Notice (choose a folder, none found, the path field), under the
; header row; then the drop ring. Original work, MIT licensed. The card under it takes the click, so the whole card is
; the action. The Large keeps the Medium's top and puts the action (or the path field) on its last baseline.

[MeterHeaderSymbol]
; photo, 11 pt, natural 16 × 13 on the leading slot (26, 23), in the accent colour: a tool with no data category
Meter=Image
MeterStyle=sSymbolS
ImageName=sf:photo
ImageTint=#AccentColor#
X=18
Y=16.5
W=16
H=13
Hidden=(([MeasureMode:] <> 2) && ([MeasureMode:] <> 3) && ([MeasureMode:] <> 5))
DynamicVariables=1
UpdateDivider=-1
Group=Notice

[MeterHeaderTitle]
; "Photo Frame"
Meter=String
MeterStyle=sLabel | sHeaderTitle
Text=#PhotoWidget#
Hidden=(([MeasureMode:] <> 2) && ([MeasureMode:] <> 3) && ([MeasureMode:] <> 5))
DynamicVariables=1
UpdateDivider=-1
Group=Notice

[MeterNoticeSymbol]
; photo, exclamationmark.triangle.fill or folder, 20 pt, at x 16, its natural box centred on y 53.5
Meter=Image
MeterStyle=sNoticeSymbol
ImageName=sf:[#PhotoSym[&MeasureMode:0]]
X=16
Y=(53.5 - [#PhotoSymH[&MeasureMode:0]] / 2)
W=[#PhotoSymW[&MeasureMode:0]]
H=[#PhotoSymH[&MeasureMode:0]]
Hidden=(([MeasureMode:] <> 2) && ([MeasureMode:] <> 3) && ([MeasureMode:] <> 5))
DynamicVariables=1
UpdateDivider=-1
Group=Notice

[MeterNoticeTitle]
; "Choose a Folder of Photos", "No Photos Found" or "Choose a Folder" on baseline 86
Meter=String
MeterStyle=sBodyStrong | sNoticeTitle
Text=[#PhotoTitle[&MeasureMode:0]]
Hidden=(([MeasureMode:] <> 2) && ([MeasureMode:] <> 3) && ([MeasureMode:] <> 5))
DynamicVariables=1
UpdateDivider=-1
Group=Notice

[MeterNoticeBody]
; from baseline 103, two lines in English and Chinese; %1 is the folder's name
Meter=String
MeterStyle=sCaption | sNoticeBody
MeasureName=MeasureFolderName
Text=[#PhotoBody[&MeasureMode:0]]
H=39
Hidden=(([MeasureMode:] <> 2) && ([MeasureMode:] <> 3) && ([MeasureMode:] <> 5))
DynamicVariables=1
UpdateDivider=-1
Group=Notice

[MeterNoticeAction]
; "Choose Folder…" on the last baseline; the path field takes its place while it is open
Meter=String
MeterStyle=sLabel | sNoticeAction
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
