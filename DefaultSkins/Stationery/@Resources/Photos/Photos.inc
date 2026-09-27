; Stationery · Photo Frame — what the three sizes share: the settings, every measure, the card and the photo.
; Original work, MIT licensed.
;
; Photos from a folder on this Mac: PhotoFolder (in Stationery.inc, Deskset's settings folder). Until one is chosen the
; frame shows the Choose a Folder notice and reads no folder: Pictures often holds screenshots and other private
; images, which a desktop shows to anyone looking (and to screen sharing). The path field suggests Pictures, which asks
; for nothing. The folder is listed on a background thread, subfolders included; hidden
; files and packages are skipped, so the Photos and Photo Booth libraries are never entered. A random photo shows, and
; a new one comes on each slot of the clock (every 10 minutes, on the hour or at midnight: PhotoInterval) and on a
; click. A folder in Desktop, Documents or Downloads, or on another disk, makes macOS ask once.
;
; MeasureMode: 1 a photo · 2 choose (no folder chosen yet) · 3 none found (a chosen folder shows
; nothing) · 4 loading (at most the first 3 s) · 5 the path field (choosing a folder). The photo has no glass under
; it: the card (MeterCard, the glass) shows only with a Notice.

[Variables]
PhotoDefaultFolder=~/Pictures
PhotoFilter=*.jpg;*.jpeg;*.png;*.heic;*.heif;*.webp
; the same set as a pattern, without square brackets (section variables never read it)
PhotoPattern=(?i)\.(?:jpe?g|png|heic|heif|webp)$
; the file name over a photo: white, with the frameless pieces' text shadow
CaptionInk=255,255,255,230
CaptionShadow=0,0,0,130
; run-time state, never written to a file
HasPhoto=0
PhotoChosen=0
PhotoProtected=0
Pasting=0
DropOver=0
PastedPath=
MenuItem=0
; the Change Photo item: 10 minutes → an hour → a day
PhotoIntervalNext600=3600
PhotoIntervalNext3600=86400
PhotoIntervalNext86400=600
; choosing a folder: the path field, which says how to copy a path. With an Open panel (E19) this becomes
; [!MacChooseFolder PhotoFolder "#StationeryFile#" "[MeasureFolderPath]"]
ChooseFolderAction=[!SetVariable Pasting 1][!DisableMouseAction MeterCard "LeftMouseUpAction"][!UpdateMeasure MeasureMode][!CommandMeasure MeasurePathInput "ExecuteBatch 1"]
; the Notice's symbol by mode, and its natural size at 20 pt Regular (modes 1 and 4 show no Notice)
PhotoSym1=photo
PhotoSym2=photo
PhotoSym3=exclamationmark.triangle.fill
PhotoSym4=photo
PhotoSym5=folder
PhotoSymW1=29
PhotoSymW2=29
PhotoSymW3=25
PhotoSymW4=29
PhotoSymW5=28
PhotoSymH1=21
PhotoSymH2=21
PhotoSymH3=22
PhotoSymH4=21
PhotoSymH5=21
; the words of the modes without a Notice, so every lookup by mode finds a value
PhotoTitleS1=
PhotoTitleS4=
PhotoTitle1=
PhotoTitle4=
PhotoBodyS1=
PhotoBodyS4=
PhotoBody1=
PhotoBody4=
PhotoTipTitle1=
PhotoTipTitle4=
PhotoTip1=
PhotoTip4=
; the right-click items, by whether a photo shows (HasPhoto); each runs through MeasureMenu
PhotoMenu1_1=#PhotoMenuPreview#
PhotoMenu2_1=#PhotoMenuFinder#
PhotoMenu3_1=---
PhotoMenu4_1=#PhotoMenuChoose#
PhotoMenu5_1=[MeasureTitleEvery]
PhotoMenu6_1=[MeasureTitleFileName]
PhotoMenu7_1=---
PhotoMenu8_1=#MenuLookTitle#
PhotoMenu9_1=#MenuCardsTitle#
PhotoMenu10_1=#MenuLanguageTitle#
PhotoMenu1_0=#PhotoMenuChoose#
PhotoMenu2_0=#PhotoMenuFinder#
PhotoMenu3_0=---
PhotoMenu4_0=[MeasureTitleEvery]
PhotoMenu5_0=[MeasureTitleFileName]
PhotoMenu6_0=---
PhotoMenu7_0=#MenuLookTitle#
PhotoMenu8_0=#MenuCardsTitle#
PhotoMenu9_0=#MenuLanguageTitle#
PhotoMenu10_0=

; ---------------------------------------------------------------- the folder
[MeasureChosen]
; 1 once a folder is chosen; until then no folder is read at all
Measure=String
String=#PhotoFolder#
IfMatch=\S
IfMatchAction=[!SetVariable PhotoChosen 1]
IfNotMatchAction=[!SetVariable PhotoChosen 0][!DisableMeasure MeasurePhoto][!DisableMeasure MeasurePhotoWait]
UpdateDivider=-1

[MeasureFolderPath]
; the chosen folder; before one is chosen, Pictures, which the path field suggests
Measure=String
String=#PhotoFolder#
RegExpSubstitute=1
Substitute="^\s*$":"#PhotoDefaultFolder#"
UpdateDivider=-1

[MeasureFolderName]
; "Holiday 2025": the Notice's %1 and the tooltips; the default reads as Pictures in the widget's language
Measure=String
String=[MeasureFolderPath]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^~/Pictures/?$":"#PhotoPictures#","/+$":"","^.*/":""
UpdateDivider=-1

[MeasureProtected]
; places macOS guards: a refusal reads as an empty folder, so the tooltip adds where to allow access
Measure=String
String=[MeasureFolderPath]
DynamicVariables=1
IfMatch=^(?:~|/Users/(?:(?!/).)+)/(?:Desktop|Documents|Downloads|Library/Mobile Documents)(?:/|$)|^/Volumes/
IfMatchAction=[!SetVariable PhotoProtected 1][!UpdateMeasure MeasureHint]
IfNotMatchAction=[!SetVariable PhotoProtected 0][!UpdateMeasure MeasureHint]
UpdateDivider=-1

[MeasureHint]
; the tooltip's second line for those places, empty elsewhere
Measure=String
String=[#PhotoHint[#PhotoProtected]]
DynamicVariables=1
UpdateDivider=-1

; ---------------------------------------------------------------- the photo
[MeasurePhoto]
; a random photo of the folder, never the same one twice in a row: at load, on a new slot, on a click, and every second
; while none shows (MeasurePhotoWait)
Measure=Plugin
Plugin=QuotePlugin
PathName=[MeasureFolderPath]
FileFilter=#PhotoFilter#
Subfolders=1
DynamicVariables=1
UpdateDivider=-1
IfMatch=#PhotoPattern#
IfMatchAction=[!SetVariable HasPhoto 1][!UpdateMeasureGroup Caption][!UpdateMeasure MeasureMode]
IfNotMatchAction=[!SetVariable HasPhoto 0][!UpdateMeasure MeasureMode]
OnChangeAction=[!UpdateMeasureGroup Caption][!UpdateMeterGroup Photo][!Redraw]

[MeasurePhotoWait]
; while no photo shows, the folder is asked again every second: its list is read on a background thread, and a folder
; that fills up shows its first photo within a minute. A measure of its own, because a measure that changes its own
; UpdateDivider still updates once more, and that would replace the first photo a second after it shows
Measure=Calc
Formula=#HasPhoto#
DynamicVariables=1
IfConditionMode=1
IfCondition=MeasurePhotoWait = 0
IfTrueAction=[!UpdateMeasure MeasurePhoto]

[MeasureNow]
; the wall clock (no Format: the number is the timestamp)
Measure=Time
TimeStamp=#TestNow#
UpdateDivider=10

[CalcPhotoSlot]
; the photo's slot on the clock: every 10 minutes (:00, :10…), on the hour, or at midnight; a new slot, also after
; sleep, brings a new photo
Measure=Calc
Formula=Floor(MeasureNow / #PhotoInterval#)
DynamicVariables=1
UpdateDivider=10
OnChangeAction=[!UpdateMeasure MeasurePhoto]

; ---------------------------------------------------------------- phrases that follow the menu
[MeasureEvery]
; "Every 10 minutes"
Measure=String
String=[#PhotoEvery[#PhotoInterval]]
DynamicVariables=1
UpdateDivider=-1
Group=Menu

[MeasureEveryLower]
; "every 10 minutes"
Measure=String
String=[#PhotoEveryLower[#PhotoInterval]]
DynamicVariables=1
UpdateDivider=-1
Group=Menu

[MeasureTitleEvery]
; "Change Photo: Every 10 Min"
Measure=String
String=[#PhotoMenuEvery[#PhotoInterval]]
DynamicVariables=1
UpdateDivider=-1
Group=Menu

[MeasureTitleFileName]
; "File Name: Off"
Measure=String
String=[#PhotoMenuFileName[#ShowPhotoFileName]]
DynamicVariables=1
UpdateDivider=-1
Group=Menu

; ---------------------------------------------------------------- the photo's names
[MeasureCaption]
; the caption: the file name without its extension; a camera-style name (IMG_4821, DSC_0042, PXL_…) gives way to
; its folder's name
Measure=String
String=[MeasurePhoto]
DynamicVariables=1
RegExpSubstitute=1
Substitute="\.[^./]*$":"","^.*/([^/]+)/(?:(?i:IMG|_MG|DSC[FN]?|_DSC|PXL|MVIMG|GOPR|DJI|WP)[_-]?[A-Z]?\d|GX\d{6}|P[1-9A-C]\d{6}|\d{8}[_-]\d{6})[^/]*$":"\1","^.*/":""
UpdateDivider=-1
Group=Caption

[MeasureFileName]
; the photo's tooltip title: "IMG_4821.jpg"
Measure=String
String=[MeasurePhoto]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^.*/":""
UpdateDivider=-1
Group=Caption

[MeasureParentName]
; the photo's own folder, for its tooltip
Measure=String
String=[MeasurePhoto]
DynamicVariables=1
RegExpSubstitute=1
Substitute="/[^/]*$":"","^.*/":""
UpdateDivider=-1
Group=Caption

[MeasurePhotoShell]
; the path single-quoted for the shell (Show in Finder): ' becomes '\''
Measure=String
String=[MeasurePhoto]
DynamicVariables=1
Substitute="'":"'\''"
UpdateDivider=-1
Group=Caption

; ---------------------------------------------------------------- mode
[MeasureTick]
; updates since load, up to 4: the loading window is the first 3 s
Measure=Calc
Formula=Min(MeasureTick + 1, 4)
IfCondition=MeasureTick >= 4
IfTrueAction=[!SetOption MeasureTick UpdateDivider -1][!UpdateMeasure MeasureMode]

[MeasureMode]
; 1 photo · 2 choose · 3 none found · 4 loading · 5 path field
Measure=Calc
Formula=(#Pasting# = 1) ? 5 : ((#PhotoChosen# = 0) ? 2 : ((#HasPhoto# = 1) ? 1 : ((MeasureTick < 4) ? 4 : 3)))
DynamicVariables=1
UpdateDivider=-1
OnChangeAction=[!UpdateMeterGroup Photo][!UpdateMeterGroup Notice][!Redraw]

; ---------------------------------------------------------------- choosing a folder
[MeasurePathInput]
; the path field, over the Notice's action line: an opaque field in FieldColor with the text at full strength (a
; translucent one would fade the typed text with it). The pen is at X + 4 and the baseline at Y + 16
Measure=Plugin
Plugin=InputText
SolidColor=#FieldColor#
FontColor=#TextColor#
FontFace=#FontText#
FontSize=9.75
FocusDismiss=1
X=16
Y=(#CardH# - 35)
W=(#CardW# - 32)
H=24
DefaultValue=[MeasureFolderPath]
Command1=[!SetVariable PastedPath """$UserInput$"""][!UpdateMeasure MeasurePasted][!WriteKeyValue Variables PhotoFolder "[MeasurePasted]" "#StationeryFile#"][!Refresh]
; Escape or a click elsewhere: the Notice returns after 0.5 s, so the click that dismissed the field cannot open it
OnDismissAction=[!SetVariable Pasting 0][!Delay 500][!EnableMouseAction MeterCard "LeftMouseUpAction"][!UpdateMeasure MeasureMode]

[MeasurePasted]
; a typed, pasted or dropped path, cleaned: trimmed, quotes and Terminal's escapes ("My\ Photos") taken away, a
; relative path taken from home, a photo's path giving its folder; "~" or "/" alone chooses nothing
Measure=String
String=#PastedPath#
DynamicVariables=1
RegExpSubstitute=1
Substitute="^\s+|\s+$":"",'^"(.*)"$':'\1',"^'(.*)'$":"\1","\\(.)":"\1","^(?!/|~|$)":"~/","(?i)/(?:(?!/).)+\.(?:jpe?g|png|heic|heif|webp)$":"","^(?:~/?|/)$":""
UpdateDivider=-1

[MeasureReveal]
; Show in Finder: the photo's path single-quoted for the shell, so no character in a file name can run anything
Measure=Plugin
Plugin=RunCommand
Parameter=open -R '[MeasurePhotoShell]'
DynamicVariables=1
UpdateDivider=-1

[MeasureMenu]
; which right-click item ran: 10 × the item + HasPhoto, fixed when the menu opened
Measure=Calc
Formula=#MenuItem#
DynamicVariables=1
UpdateDivider=-1
IfConditionMode=1
IfCondition=MeasureMenu = 11
IfTrueAction=["/System/Applications/Preview.app" "[MeasurePhoto]"]
IfCondition2=MeasureMenu = 21
IfTrueAction2=[!UpdateMeasure MeasurePhotoShell][!UpdateMeasure MeasureReveal][!CommandMeasure MeasureReveal "Run"]
IfCondition3=(MeasureMenu = 41) || (MeasureMenu = 10)
IfTrueAction3=#ChooseFolderAction#
IfCondition4=MeasureMenu = 20
IfTrueAction4=["[MeasureFolderPath]"]
IfCondition5=(MeasureMenu = 51) || (MeasureMenu = 40)
IfTrueAction5=[!WriteKeyValue Variables PhotoInterval "[#PhotoIntervalNext[#PhotoInterval]]" "#@#Variables.inc"][!SetVariable PhotoInterval "[#PhotoIntervalNext[#PhotoInterval]]"][!UpdateMeasureGroup Menu][!UpdateMeasure CalcPhotoSlot][!UpdateMeterGroup Notice][!Redraw]
IfCondition6=(MeasureMenu = 61) || (MeasureMenu = 50)
IfTrueAction6=[!WriteKeyValue Variables ShowPhotoFileName "(1 - #ShowPhotoFileName#)" "#@#Variables.inc"][!SetVariable ShowPhotoFileName "(1 - #ShowPhotoFileName#)"][!UpdateMeasureGroup Menu][!UpdateMeterGroup Photo][!Redraw]
IfCondition7=(MeasureMenu = 81) || (MeasureMenu = 70)
IfTrueAction7=#MenuLookAction#
IfCondition8=(MeasureMenu = 91) || (MeasureMenu = 80)
IfTrueAction8=#MenuCardsAction#
IfCondition9=(MeasureMenu = 101) || (MeasureMenu = 90)
IfTrueAction9=#MenuLanguageAction#

; ---------------------------------------------------------------- meters
[MeterCard]
; the glass card, only under a Notice (a hidden meter has no glass, so the photo sits on none). The whole card chooses
; a folder
Meter=Shape
MeterStyle=sCard
LeftMouseUpAction=#ChooseFolderAction#
ToolTipTitle=[#PhotoTipTitle[&MeasureMode:0]]
ToolTipText=[#PhotoTip[&MeasureMode:0]]
; a folder or a photo dropped on the card (E34; ignored until Deskset takes drops): the ring shows while it hovers
MacDropKinds=Folder,Image
MacDragEnterAction=[!SetVariable DropOver 1][!UpdateMeter MeterDropRing][!Redraw]
MacDragExitAction=[!SetVariable DropOver 0][!UpdateMeter MeterDropRing][!Redraw]
MacDropAction=[!SetVariable DropOver 0][!SetVariable PastedPath """$DroppedPath$"""][!UpdateMeasure MeasurePasted][!WriteKeyValue Variables PhotoFolder "[MeasurePasted]" "#StationeryFile#"][!Refresh]
Hidden=(([MeasureMode:] = 1) || ([MeasureMode:] = 4))
UpdateDivider=-1
Group=Notice

[MeterBacking]
; under the photo: it fills a PNG's transparent parts and the moment before a photo is decoded; while loading it is
; the tile
Meter=Shape
Shape=Rectangle 0,0,#CardW#,#CardH#,#CardRadius# | Fill Color #ControlFillColor# | StrokeWidth 0
ToolTipTitle=#PhotoWidget#
ToolTipText=#PhotoTipLoading#
MacDropKinds=Folder,Image
MacDragEnterAction=[!SetVariable DropOver 1][!UpdateMeter MeterDropRing][!Redraw]
MacDragExitAction=[!SetVariable DropOver 0][!UpdateMeter MeterDropRing][!Redraw]
MacDropAction=[!SetVariable DropOver 0][!SetVariable PastedPath """$DroppedPath$"""][!UpdateMeasure MeasurePasted][!WriteKeyValue Variables PhotoFolder "[MeasurePasted]" "#StationeryFile#"][!Refresh]
Hidden=(([MeasureMode:] <> 1) && ([MeasureMode:] <> 4))
DynamicVariables=1
UpdateDivider=-1
Group=Photo

[MeterLoadingGlyph]
; loading: photo, 28 pt, natural 40 × 30, in the middle
Meter=Image
ImageName=sf:photo
MacSymbolSize=28
MacSymbolWeight=Regular
MacSymbolRendering=Hierarchical
ImageTint=#TertiaryTextColor#
X=(#CardW# / 2 - 20)
Y=(#CardH# / 2 - 15)
W=40
H=30
Hidden=([MeasureMode:] <> 4)
DynamicVariables=1
UpdateDivider=-1
Group=Photo

[MeterPhoto]
; the photo, filling the card (cropped in the middle), turned upright, cut to the card's shape, in full colour in every
; look; decoded at the size it is drawn (MacDecodeSize), not at the camera's. A click shows the next one
Meter=Image
MeasureName=MeasurePhoto
X=0
Y=0
W=#CardW#
H=#CardH#
PreserveAspectRatio=2
UseExifOrientation=1
MaskImageName=#@#Suite/Masks/#CardMask#
MacDecodeSize=Drawn
LeftMouseUpAction=[!UpdateMeasure MeasurePhoto]
ToolTipTitle=[MeasureFileName]
ToolTipText=#PhotoTip#
Hidden=([MeasureMode:] <> 1)
DynamicVariables=1
UpdateDivider=-1
Group=Photo

[MeterScrim]
; File Name: On: a shade at the bottom, 64 tall, its bottom corners the card's
Meter=Shape
Shape=Path ScrimPath | Fill LinearGradient ScrimFill | StrokeWidth 0
ScrimPath=0,(#CardH# - 64) | LineTo #CardW#,(#CardH# - 64) | LineTo #CardW#,(#CardH# - 26) | ArcTo (#CardW# - 26),#CardH#,26,26 | LineTo 26,#CardH# | ArcTo 0,(#CardH# - 26),26,26 | ClosePath 1
ScrimFill=270 | 0,0,0,0 ; 0.0 | 0,0,0,120 ; 0.55 | 0,0,0,150 ; 1.0
Hidden=(([MeasureMode:] <> 1) || (#ShowPhotoFileName# = 0))
DynamicVariables=1
UpdateDivider=-1
Group=Photo

[MeterCaption]
; the file name on the last baseline, white with the frameless pieces' shadow (Padding covers the shadow, which is
; clipped to the meter)
Meter=String
MeterStyle=sLabel
MeasureName=MeasureCaption
FontColor=#CaptionInk#
X=11
Y=(#CardH# - 19 - #Ascent11# - 5)
W=(#CardW# - 32)
Padding=5,5,5,5
ClipString=1
InlineSetting7=Shadow | 0 | 1 | 4 | #CaptionShadow#
InlinePattern7=.*
Hidden=(([MeasureMode:] <> 1) || (#ShowPhotoFileName# = 0))
DynamicVariables=1
UpdateDivider=-1
Group=Photo

[MeterEdge]
; a 0.5 pt edge, so the photo holds on a wallpaper like it
Meter=Shape
Shape=Rectangle 0.25,0.25,(#CardW# - 0.5),(#CardH# - 0.5),25.75 | Fill Color 0,0,0,0 | StrokeWidth 0.5 | Stroke Color #SeparatorColor#
Hidden=(([MeasureMode:] <> 1) && ([MeasureMode:] <> 4))
DynamicVariables=1
UpdateDivider=-1
Group=Photo
