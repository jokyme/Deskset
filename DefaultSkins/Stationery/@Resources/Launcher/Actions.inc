; Stationery · Launcher — the measures both sizes share: the Trash, the dispatcher and the edit field.
; Original work, MIT licensed.

[MeasureStationeryFile]
; Deskset makes Stationery.inc at every launch, and !WriteKeyValue writes only into a file that exists: this makes it
; again (empty) if it was deleted since
Measure=Plugin
Plugin=RunCommand
Parameter=test -e "#StationeryFile#" || : > "#StationeryFile#"
UpdateDivider=-1

[MeasureTrash]
; only when a cell is the Trash (the item's kind turns it on). Counting needs no permission; every 2 s, so the bin
; fills within 2 s of a file going to the Trash. The icon and the sentence change at 0, 1 and more (IfCondition fires
; when its result changes); the count in the sentence changes with the number
Measure=Plugin
Plugin=RecycleManager
RecycleType=Count
UpdateDivider=2
Disabled=1
IfCondition=MeasureTrash = 0
IfTrueAction=[!SetVariable TrashIcon "#TrashEmptyIcon#"][!SetVariable LaunchTipTrash "#LaunchTipTrashEmpty#"][!UpdateMeasure MeasureTrashText][!UpdateMeasureGroup Tips][!UpdateMeterGroup Trash][!UpdateMeterGroup Cells][!Redraw]
IfCondition2=MeasureTrash = 1
IfTrueAction2=[!SetVariable TrashIcon "#TrashFullIcon#"][!SetVariable LaunchTipTrash "#LaunchTipTrashOne#"][!UpdateMeasure MeasureTrashText][!UpdateMeasureGroup Tips][!UpdateMeterGroup Trash][!UpdateMeterGroup Cells][!Redraw]
IfCondition3=MeasureTrash > 1
IfTrueAction3=[!SetVariable TrashIcon "#TrashFullIcon#"][!SetVariable LaunchTipTrash "#LaunchTipTrashMany#"][!UpdateMeasure MeasureTrashText][!UpdateMeasureGroup Tips][!UpdateMeterGroup Trash][!UpdateMeterGroup Cells][!Redraw]
OnChangeAction=[!UpdateMeasure MeasureTrashText][!UpdateMeasureGroup Tips][!UpdateMeterGroup Cells][!Redraw]

[MeasureTrashText]
; "12", "1,248"
Measure=String
String=[MeasureTrash:0]
DynamicVariables=1
UpdateDivider=-1
RegExpSubstitute=1
Substitute="(\d)(?=(\d{3})+(?!\d))":"\1#DigitGroup#"

[MeasureAct]
; One dispatcher for clicks, drops, the tiles' menus and the card's menu, so what a cell does follows its kind at the
; time. Its value is the act × 10 + the kind of the cell (0 while idle, so the load-time update does nothing). Acts:
; 1 a click or a menu's first item … 6 its sixth, 7 a drop. Kinds: 0 empty, 1 path, 2 link, 3 Trash, 4 shortcut,
; 5 missing or not an item, 8 the Small's card, 9 the Medium's card
Measure=Calc
Formula=#Fired# * (#FiredAct# * 10 + #FiredKind#)
DynamicVariables=1
UpdateDivider=-1
IfConditionMode=1
; open a path, then list its folder again (a deleted app turns missing)
IfCondition=MeasureAct = 11
IfTrueAction=["[#Launch[#FiredCell]]"][!CommandMeasure MeasureLaunch#FiredCell#Parent "Update"]
; open a link
IfCondition2=MeasureAct = 12
IfTrueAction2=["[#Launch[#FiredCell]]"]
; open the Trash
IfCondition3=MeasureAct = 13
IfTrueAction3=[!CommandMeasure MeasureTrash "OpenBin"]
; run a shortcut
IfCondition4=MeasureAct = 14
IfTrueAction4=[!CommandMeasure MeasureLaunch#FiredCell#Run "Run"]
; Add Item… (an empty cell), Change Item… (every kind; the click on what is not an item). With a file picker in
; Deskset this becomes one: until then a field for a path, a link, shortcut:<name> or trash
IfCondition5=(MeasureAct = 10) || (MeasureAct = 15) || ((MeasureAct >= 51) && (MeasureAct <= 54))
IfTrueAction5=[!SetVariable EditCell #FiredCell#][!CommandMeasure MeasureEdit "ExecuteBatch 1"]
; Show in Finder
IfCondition6=MeasureAct = 21
IfTrueAction6=[!CommandMeasure MeasureLaunch#FiredCell#Icon "ContextMenu"]
; Copy Link
IfCondition7=MeasureAct = 22
IfTrueAction7=[!SetClip "[#Launch[#FiredCell]]"]
; Empty Trash… (asks once whether Deskset may control Finder; Finder then confirms)
IfCondition8=MeasureAct = 23
IfTrueAction8=[!CommandMeasure MeasureTrash "EmptyBin"]
; Edit in Shortcuts
IfCondition9=MeasureAct = 24
IfTrueAction9=[!CommandMeasure MeasureLaunch#FiredCell#Edit "Run"]
; Rename…
IfCondition10=(MeasureAct >= 41) && (MeasureAct <= 44)
IfTrueAction10=[!SetVariable EditCell #FiredCell#][!CommandMeasure MeasureEdit "ExecuteBatch 2"]
; Remove Item (every kind's sixth item; the second of what is missing)
IfCondition11=((MeasureAct >= 61) && (MeasureAct <= 64)) || (MeasureAct = 25)
IfTrueAction11=[!WriteKeyValue Variables Launch#FiredCell# "" "#StationeryFile#"][!WriteKeyValue Variables LaunchLabel#FiredCell# "" "#StationeryFile#"][!WriteKeyValue Variables LaunchSymbol#FiredCell# "" "#StationeryFile#"][!WriteKeyValue Variables LaunchColor#FiredCell# "" "#StationeryFile#"][!Refresh]
; a drop (once Deskset takes them): files dropped on the Trash go to the Trash
IfCondition12=MeasureAct = 73
IfTrueAction12=[!MacMoveToTrash]
; …and on any other cell the first dropped item becomes the cell's item
IfCondition13=(MeasureAct = 70) || (MeasureAct = 71) || (MeasureAct = 72) || (MeasureAct = 74) || (MeasureAct = 75)
IfTrueAction13=[!WriteKeyValue Variables Launch#FiredCell# "[#DropItem]" "#StationeryFile#"][!WriteKeyValue Variables LaunchLabel#FiredCell# "" "#StationeryFile#"][!WriteKeyValue Variables LaunchSymbol#FiredCell# "" "#StationeryFile#"][!WriteKeyValue Variables LaunchColor#FiredCell# "" "#StationeryFile#"][!Refresh]
; the card (cell 0): kind 9 in the Medium, 8 in the Small. Labels: On / Off
IfCondition14=MeasureAct = 91
IfTrueAction14=[!WriteKeyValue Variables LaunchShowLabels [#LaunchShowLabelsNext[#LaunchShowLabels]] "#@#Variables.inc"][!Refresh]
; Edit Items as Text…
IfCondition15=(MeasureAct = 81) || (MeasureAct = 92)
IfTrueAction15=["#CONFIGEDITOR#" "#StationeryFile#"]
; the suite's Look item (82 and 93 are separators)
IfCondition16=(MeasureAct = 83) || (MeasureAct = 94)
IfTrueAction16=#MenuLookAction#
; the suite's Cards item
IfCondition17=(MeasureAct = 84) || (MeasureAct = 95)
IfTrueAction17=#MenuCardsAction#

[MeasureEdit]
; Change Item… and Rename…: a field over the cell's label row, for the cell that asked (#EditCell# is read when the
; field opens). Its fill is opaque: today's input box fades its text with its fill's alpha. Every change of an item
; empties its label, symbol and colour, so the new item never shows the old one's
Measure=Plugin
Plugin=InputText
SolidColor=#FieldColor#
FontColor=#InkRGB#,255
FontFace=#FontText#
FontSize=9.75
FocusDismiss=1
X=16
W=#EditW#
H=24
Command1=[!WriteKeyValue Variables Launch#EditCell# "$UserInput$" "#StationeryFile#"][!WriteKeyValue Variables LaunchLabel#EditCell# "" "#StationeryFile#"][!WriteKeyValue Variables LaunchSymbol#EditCell# "" "#StationeryFile#"][!WriteKeyValue Variables LaunchColor#EditCell# "" "#StationeryFile#"][!Refresh] Y=(#EditCell# > #EditRowSplit# ? #EditY2# : #EditY1#) DefaultValue="[#Launch[#EditCell]]"
Command2=[!WriteKeyValue Variables LaunchLabel#EditCell# "$UserInput$" "#StationeryFile#"][!Refresh] Y=(#EditCell# > #EditRowSplit# ? #EditY2# : #EditY1#) DefaultValue="[MeasureLaunch#EditCell#Label]"
