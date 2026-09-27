; Stationery · To Do — the twelve rows, a text and a circle per slot. Original work, MIT licensed.
;
; Every size includes this file where its rows are drawn (over the pads, under the add row); the size's
; variables place them. A slot's row R is [&MeasureRow<n>:0] (0 at the top of the window, -1 when not shown):
; its baseline is 58 + Pitch × (R mod Rows), and a row from Rows on goes to the Medium's second column.

[MeterText1]
; the item as typed (its digits stay SF Pro: it is not data), struck through in Tertiary when done;
; the padded box is the row's hit area: 4 left and right, 8 above the line and RowPadBottom below it,
; so the boxes tile the rows (31 = 8 + 16 + 7; the Large's 28.3 = 8 + 16 + 4.3). Click: edit in place
Meter=String
MeterStyle=sItem
Text=#Todo1#
FontColor=#InkRGB#,[#ItemAlpha[#TodoDone1]]
ClipString=1
InlineSetting7=[#Strike[#TodoDone1]]
InlinePattern7=.*
X=((26 + 160 * ([&MeasureRow1:0] >= #Rows#)) + 11)
Y=((58 + #Pitch# * ([&MeasureRow1:0] % #Rows#)) - 8 - #Ascent13#)
W=([&MeasureRow1:0] >= #Rows# ? #TextW2# : #TextW#)
Padding=4,8,4,#RowPadBottom#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow1:0] < 0) || ([&MeasureRow1:0] >= #Cap#) || ((#Editing# = 1) && (#EditSlot# = 1)))
MouseActionCursor=1
MouseActionCursorName=Text
ToolTipText=#Todo1#
LeftMouseUpAction=[!SetVariable EditSlot 1][!SetVariable Editing 1][!UpdateMeter MeterText1][!UpdateMeter MeterEditPad][!Redraw][!CommandMeasure MeasureInput "ExecuteBatch 1"]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot1

[MeterCheck1]
; 15 pt regular (18 × 17) centred on (slot, baseline − 4.6), padded to a 30 × 30 hit box (30 × 28.3 in
; the Large). Click: done or not; the row leaves 1.2 s later
Meter=Image
ImageName=sf:[#CheckSymbol[#TodoDone1]]
MacSymbolSize=15
MacSymbolWeight=Regular
ImageTint=[#CheckTint[#TodoDone1]]
X=((26 + 160 * ([&MeasureRow1:0] >= #Rows#)) - 15)
Y=((58 + #Pitch# * ([&MeasureRow1:0] % #Rows#)) - 13.1 - #CheckPadV#)
W=18
H=17
Padding=6,#CheckPadV#,6,#CheckPadV#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow1:0] < 0) || ([&MeasureRow1:0] >= #Cap#))
ToolTipText=[#ToDoTipCheck[#TodoDone1]]
MouseOverAction=[!SetVariable HoverSlot 1][!SetVariable PadShown 1][!UpdateMeter MeterCheckPad][!Redraw]
MouseLeaveAction=[!SetVariable PadShown 0][!SetVariable PadPressed 0][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseDownAction=[!SetVariable PadPressed 1][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseUpAction=[!SetVariable PadPressed 0][!SetVariable TodoDone1 "(1 - [#TodoDone1])"][!WriteKeyValue Variables TodoDone1 [#TodoDone1] "#StationeryFile#"][!UpdateMeasure MeasureState1][!UpdateMeasureGroup Counts][!UpdateMeterGroup Slot1][!UpdateMeter MeterHeaderTrailing][!UpdateMeter MeterCheckPad][!Redraw][!Delay 1200][!UpdateMeasure MeasureRelayoutIfIdle]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot1

[MeterText2]
Meter=String
MeterStyle=sItem
Text=#Todo2#
FontColor=#InkRGB#,[#ItemAlpha[#TodoDone2]]
ClipString=1
InlineSetting7=[#Strike[#TodoDone2]]
InlinePattern7=.*
X=((26 + 160 * ([&MeasureRow2:0] >= #Rows#)) + 11)
Y=((58 + #Pitch# * ([&MeasureRow2:0] % #Rows#)) - 8 - #Ascent13#)
W=([&MeasureRow2:0] >= #Rows# ? #TextW2# : #TextW#)
Padding=4,8,4,#RowPadBottom#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow2:0] < 0) || ([&MeasureRow2:0] >= #Cap#) || ((#Editing# = 1) && (#EditSlot# = 2)))
MouseActionCursor=1
MouseActionCursorName=Text
ToolTipText=#Todo2#
LeftMouseUpAction=[!SetVariable EditSlot 2][!SetVariable Editing 1][!UpdateMeter MeterText2][!UpdateMeter MeterEditPad][!Redraw][!CommandMeasure MeasureInput "ExecuteBatch 1"]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot2

[MeterCheck2]
Meter=Image
ImageName=sf:[#CheckSymbol[#TodoDone2]]
MacSymbolSize=15
MacSymbolWeight=Regular
ImageTint=[#CheckTint[#TodoDone2]]
X=((26 + 160 * ([&MeasureRow2:0] >= #Rows#)) - 15)
Y=((58 + #Pitch# * ([&MeasureRow2:0] % #Rows#)) - 13.1 - #CheckPadV#)
W=18
H=17
Padding=6,#CheckPadV#,6,#CheckPadV#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow2:0] < 0) || ([&MeasureRow2:0] >= #Cap#))
ToolTipText=[#ToDoTipCheck[#TodoDone2]]
MouseOverAction=[!SetVariable HoverSlot 2][!SetVariable PadShown 1][!UpdateMeter MeterCheckPad][!Redraw]
MouseLeaveAction=[!SetVariable PadShown 0][!SetVariable PadPressed 0][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseDownAction=[!SetVariable PadPressed 1][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseUpAction=[!SetVariable PadPressed 0][!SetVariable TodoDone2 "(1 - [#TodoDone2])"][!WriteKeyValue Variables TodoDone2 [#TodoDone2] "#StationeryFile#"][!UpdateMeasure MeasureState2][!UpdateMeasureGroup Counts][!UpdateMeterGroup Slot2][!UpdateMeter MeterHeaderTrailing][!UpdateMeter MeterCheckPad][!Redraw][!Delay 1200][!UpdateMeasure MeasureRelayoutIfIdle]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot2

[MeterText3]
Meter=String
MeterStyle=sItem
Text=#Todo3#
FontColor=#InkRGB#,[#ItemAlpha[#TodoDone3]]
ClipString=1
InlineSetting7=[#Strike[#TodoDone3]]
InlinePattern7=.*
X=((26 + 160 * ([&MeasureRow3:0] >= #Rows#)) + 11)
Y=((58 + #Pitch# * ([&MeasureRow3:0] % #Rows#)) - 8 - #Ascent13#)
W=([&MeasureRow3:0] >= #Rows# ? #TextW2# : #TextW#)
Padding=4,8,4,#RowPadBottom#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow3:0] < 0) || ([&MeasureRow3:0] >= #Cap#) || ((#Editing# = 1) && (#EditSlot# = 3)))
MouseActionCursor=1
MouseActionCursorName=Text
ToolTipText=#Todo3#
LeftMouseUpAction=[!SetVariable EditSlot 3][!SetVariable Editing 1][!UpdateMeter MeterText3][!UpdateMeter MeterEditPad][!Redraw][!CommandMeasure MeasureInput "ExecuteBatch 1"]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot3

[MeterCheck3]
Meter=Image
ImageName=sf:[#CheckSymbol[#TodoDone3]]
MacSymbolSize=15
MacSymbolWeight=Regular
ImageTint=[#CheckTint[#TodoDone3]]
X=((26 + 160 * ([&MeasureRow3:0] >= #Rows#)) - 15)
Y=((58 + #Pitch# * ([&MeasureRow3:0] % #Rows#)) - 13.1 - #CheckPadV#)
W=18
H=17
Padding=6,#CheckPadV#,6,#CheckPadV#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow3:0] < 0) || ([&MeasureRow3:0] >= #Cap#))
ToolTipText=[#ToDoTipCheck[#TodoDone3]]
MouseOverAction=[!SetVariable HoverSlot 3][!SetVariable PadShown 1][!UpdateMeter MeterCheckPad][!Redraw]
MouseLeaveAction=[!SetVariable PadShown 0][!SetVariable PadPressed 0][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseDownAction=[!SetVariable PadPressed 1][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseUpAction=[!SetVariable PadPressed 0][!SetVariable TodoDone3 "(1 - [#TodoDone3])"][!WriteKeyValue Variables TodoDone3 [#TodoDone3] "#StationeryFile#"][!UpdateMeasure MeasureState3][!UpdateMeasureGroup Counts][!UpdateMeterGroup Slot3][!UpdateMeter MeterHeaderTrailing][!UpdateMeter MeterCheckPad][!Redraw][!Delay 1200][!UpdateMeasure MeasureRelayoutIfIdle]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot3

[MeterText4]
Meter=String
MeterStyle=sItem
Text=#Todo4#
FontColor=#InkRGB#,[#ItemAlpha[#TodoDone4]]
ClipString=1
InlineSetting7=[#Strike[#TodoDone4]]
InlinePattern7=.*
X=((26 + 160 * ([&MeasureRow4:0] >= #Rows#)) + 11)
Y=((58 + #Pitch# * ([&MeasureRow4:0] % #Rows#)) - 8 - #Ascent13#)
W=([&MeasureRow4:0] >= #Rows# ? #TextW2# : #TextW#)
Padding=4,8,4,#RowPadBottom#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow4:0] < 0) || ([&MeasureRow4:0] >= #Cap#) || ((#Editing# = 1) && (#EditSlot# = 4)))
MouseActionCursor=1
MouseActionCursorName=Text
ToolTipText=#Todo4#
LeftMouseUpAction=[!SetVariable EditSlot 4][!SetVariable Editing 1][!UpdateMeter MeterText4][!UpdateMeter MeterEditPad][!Redraw][!CommandMeasure MeasureInput "ExecuteBatch 1"]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot4

[MeterCheck4]
Meter=Image
ImageName=sf:[#CheckSymbol[#TodoDone4]]
MacSymbolSize=15
MacSymbolWeight=Regular
ImageTint=[#CheckTint[#TodoDone4]]
X=((26 + 160 * ([&MeasureRow4:0] >= #Rows#)) - 15)
Y=((58 + #Pitch# * ([&MeasureRow4:0] % #Rows#)) - 13.1 - #CheckPadV#)
W=18
H=17
Padding=6,#CheckPadV#,6,#CheckPadV#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow4:0] < 0) || ([&MeasureRow4:0] >= #Cap#))
ToolTipText=[#ToDoTipCheck[#TodoDone4]]
MouseOverAction=[!SetVariable HoverSlot 4][!SetVariable PadShown 1][!UpdateMeter MeterCheckPad][!Redraw]
MouseLeaveAction=[!SetVariable PadShown 0][!SetVariable PadPressed 0][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseDownAction=[!SetVariable PadPressed 1][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseUpAction=[!SetVariable PadPressed 0][!SetVariable TodoDone4 "(1 - [#TodoDone4])"][!WriteKeyValue Variables TodoDone4 [#TodoDone4] "#StationeryFile#"][!UpdateMeasure MeasureState4][!UpdateMeasureGroup Counts][!UpdateMeterGroup Slot4][!UpdateMeter MeterHeaderTrailing][!UpdateMeter MeterCheckPad][!Redraw][!Delay 1200][!UpdateMeasure MeasureRelayoutIfIdle]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot4

[MeterText5]
Meter=String
MeterStyle=sItem
Text=#Todo5#
FontColor=#InkRGB#,[#ItemAlpha[#TodoDone5]]
ClipString=1
InlineSetting7=[#Strike[#TodoDone5]]
InlinePattern7=.*
X=((26 + 160 * ([&MeasureRow5:0] >= #Rows#)) + 11)
Y=((58 + #Pitch# * ([&MeasureRow5:0] % #Rows#)) - 8 - #Ascent13#)
W=([&MeasureRow5:0] >= #Rows# ? #TextW2# : #TextW#)
Padding=4,8,4,#RowPadBottom#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow5:0] < 0) || ([&MeasureRow5:0] >= #Cap#) || ((#Editing# = 1) && (#EditSlot# = 5)))
MouseActionCursor=1
MouseActionCursorName=Text
ToolTipText=#Todo5#
LeftMouseUpAction=[!SetVariable EditSlot 5][!SetVariable Editing 1][!UpdateMeter MeterText5][!UpdateMeter MeterEditPad][!Redraw][!CommandMeasure MeasureInput "ExecuteBatch 1"]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot5

[MeterCheck5]
Meter=Image
ImageName=sf:[#CheckSymbol[#TodoDone5]]
MacSymbolSize=15
MacSymbolWeight=Regular
ImageTint=[#CheckTint[#TodoDone5]]
X=((26 + 160 * ([&MeasureRow5:0] >= #Rows#)) - 15)
Y=((58 + #Pitch# * ([&MeasureRow5:0] % #Rows#)) - 13.1 - #CheckPadV#)
W=18
H=17
Padding=6,#CheckPadV#,6,#CheckPadV#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow5:0] < 0) || ([&MeasureRow5:0] >= #Cap#))
ToolTipText=[#ToDoTipCheck[#TodoDone5]]
MouseOverAction=[!SetVariable HoverSlot 5][!SetVariable PadShown 1][!UpdateMeter MeterCheckPad][!Redraw]
MouseLeaveAction=[!SetVariable PadShown 0][!SetVariable PadPressed 0][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseDownAction=[!SetVariable PadPressed 1][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseUpAction=[!SetVariable PadPressed 0][!SetVariable TodoDone5 "(1 - [#TodoDone5])"][!WriteKeyValue Variables TodoDone5 [#TodoDone5] "#StationeryFile#"][!UpdateMeasure MeasureState5][!UpdateMeasureGroup Counts][!UpdateMeterGroup Slot5][!UpdateMeter MeterHeaderTrailing][!UpdateMeter MeterCheckPad][!Redraw][!Delay 1200][!UpdateMeasure MeasureRelayoutIfIdle]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot5

[MeterText6]
Meter=String
MeterStyle=sItem
Text=#Todo6#
FontColor=#InkRGB#,[#ItemAlpha[#TodoDone6]]
ClipString=1
InlineSetting7=[#Strike[#TodoDone6]]
InlinePattern7=.*
X=((26 + 160 * ([&MeasureRow6:0] >= #Rows#)) + 11)
Y=((58 + #Pitch# * ([&MeasureRow6:0] % #Rows#)) - 8 - #Ascent13#)
W=([&MeasureRow6:0] >= #Rows# ? #TextW2# : #TextW#)
Padding=4,8,4,#RowPadBottom#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow6:0] < 0) || ([&MeasureRow6:0] >= #Cap#) || ((#Editing# = 1) && (#EditSlot# = 6)))
MouseActionCursor=1
MouseActionCursorName=Text
ToolTipText=#Todo6#
LeftMouseUpAction=[!SetVariable EditSlot 6][!SetVariable Editing 1][!UpdateMeter MeterText6][!UpdateMeter MeterEditPad][!Redraw][!CommandMeasure MeasureInput "ExecuteBatch 1"]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot6

[MeterCheck6]
Meter=Image
ImageName=sf:[#CheckSymbol[#TodoDone6]]
MacSymbolSize=15
MacSymbolWeight=Regular
ImageTint=[#CheckTint[#TodoDone6]]
X=((26 + 160 * ([&MeasureRow6:0] >= #Rows#)) - 15)
Y=((58 + #Pitch# * ([&MeasureRow6:0] % #Rows#)) - 13.1 - #CheckPadV#)
W=18
H=17
Padding=6,#CheckPadV#,6,#CheckPadV#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow6:0] < 0) || ([&MeasureRow6:0] >= #Cap#))
ToolTipText=[#ToDoTipCheck[#TodoDone6]]
MouseOverAction=[!SetVariable HoverSlot 6][!SetVariable PadShown 1][!UpdateMeter MeterCheckPad][!Redraw]
MouseLeaveAction=[!SetVariable PadShown 0][!SetVariable PadPressed 0][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseDownAction=[!SetVariable PadPressed 1][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseUpAction=[!SetVariable PadPressed 0][!SetVariable TodoDone6 "(1 - [#TodoDone6])"][!WriteKeyValue Variables TodoDone6 [#TodoDone6] "#StationeryFile#"][!UpdateMeasure MeasureState6][!UpdateMeasureGroup Counts][!UpdateMeterGroup Slot6][!UpdateMeter MeterHeaderTrailing][!UpdateMeter MeterCheckPad][!Redraw][!Delay 1200][!UpdateMeasure MeasureRelayoutIfIdle]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot6

[MeterText7]
Meter=String
MeterStyle=sItem
Text=#Todo7#
FontColor=#InkRGB#,[#ItemAlpha[#TodoDone7]]
ClipString=1
InlineSetting7=[#Strike[#TodoDone7]]
InlinePattern7=.*
X=((26 + 160 * ([&MeasureRow7:0] >= #Rows#)) + 11)
Y=((58 + #Pitch# * ([&MeasureRow7:0] % #Rows#)) - 8 - #Ascent13#)
W=([&MeasureRow7:0] >= #Rows# ? #TextW2# : #TextW#)
Padding=4,8,4,#RowPadBottom#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow7:0] < 0) || ([&MeasureRow7:0] >= #Cap#) || ((#Editing# = 1) && (#EditSlot# = 7)))
MouseActionCursor=1
MouseActionCursorName=Text
ToolTipText=#Todo7#
LeftMouseUpAction=[!SetVariable EditSlot 7][!SetVariable Editing 1][!UpdateMeter MeterText7][!UpdateMeter MeterEditPad][!Redraw][!CommandMeasure MeasureInput "ExecuteBatch 1"]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot7

[MeterCheck7]
Meter=Image
ImageName=sf:[#CheckSymbol[#TodoDone7]]
MacSymbolSize=15
MacSymbolWeight=Regular
ImageTint=[#CheckTint[#TodoDone7]]
X=((26 + 160 * ([&MeasureRow7:0] >= #Rows#)) - 15)
Y=((58 + #Pitch# * ([&MeasureRow7:0] % #Rows#)) - 13.1 - #CheckPadV#)
W=18
H=17
Padding=6,#CheckPadV#,6,#CheckPadV#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow7:0] < 0) || ([&MeasureRow7:0] >= #Cap#))
ToolTipText=[#ToDoTipCheck[#TodoDone7]]
MouseOverAction=[!SetVariable HoverSlot 7][!SetVariable PadShown 1][!UpdateMeter MeterCheckPad][!Redraw]
MouseLeaveAction=[!SetVariable PadShown 0][!SetVariable PadPressed 0][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseDownAction=[!SetVariable PadPressed 1][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseUpAction=[!SetVariable PadPressed 0][!SetVariable TodoDone7 "(1 - [#TodoDone7])"][!WriteKeyValue Variables TodoDone7 [#TodoDone7] "#StationeryFile#"][!UpdateMeasure MeasureState7][!UpdateMeasureGroup Counts][!UpdateMeterGroup Slot7][!UpdateMeter MeterHeaderTrailing][!UpdateMeter MeterCheckPad][!Redraw][!Delay 1200][!UpdateMeasure MeasureRelayoutIfIdle]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot7

[MeterText8]
Meter=String
MeterStyle=sItem
Text=#Todo8#
FontColor=#InkRGB#,[#ItemAlpha[#TodoDone8]]
ClipString=1
InlineSetting7=[#Strike[#TodoDone8]]
InlinePattern7=.*
X=((26 + 160 * ([&MeasureRow8:0] >= #Rows#)) + 11)
Y=((58 + #Pitch# * ([&MeasureRow8:0] % #Rows#)) - 8 - #Ascent13#)
W=([&MeasureRow8:0] >= #Rows# ? #TextW2# : #TextW#)
Padding=4,8,4,#RowPadBottom#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow8:0] < 0) || ([&MeasureRow8:0] >= #Cap#) || ((#Editing# = 1) && (#EditSlot# = 8)))
MouseActionCursor=1
MouseActionCursorName=Text
ToolTipText=#Todo8#
LeftMouseUpAction=[!SetVariable EditSlot 8][!SetVariable Editing 1][!UpdateMeter MeterText8][!UpdateMeter MeterEditPad][!Redraw][!CommandMeasure MeasureInput "ExecuteBatch 1"]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot8

[MeterCheck8]
Meter=Image
ImageName=sf:[#CheckSymbol[#TodoDone8]]
MacSymbolSize=15
MacSymbolWeight=Regular
ImageTint=[#CheckTint[#TodoDone8]]
X=((26 + 160 * ([&MeasureRow8:0] >= #Rows#)) - 15)
Y=((58 + #Pitch# * ([&MeasureRow8:0] % #Rows#)) - 13.1 - #CheckPadV#)
W=18
H=17
Padding=6,#CheckPadV#,6,#CheckPadV#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow8:0] < 0) || ([&MeasureRow8:0] >= #Cap#))
ToolTipText=[#ToDoTipCheck[#TodoDone8]]
MouseOverAction=[!SetVariable HoverSlot 8][!SetVariable PadShown 1][!UpdateMeter MeterCheckPad][!Redraw]
MouseLeaveAction=[!SetVariable PadShown 0][!SetVariable PadPressed 0][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseDownAction=[!SetVariable PadPressed 1][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseUpAction=[!SetVariable PadPressed 0][!SetVariable TodoDone8 "(1 - [#TodoDone8])"][!WriteKeyValue Variables TodoDone8 [#TodoDone8] "#StationeryFile#"][!UpdateMeasure MeasureState8][!UpdateMeasureGroup Counts][!UpdateMeterGroup Slot8][!UpdateMeter MeterHeaderTrailing][!UpdateMeter MeterCheckPad][!Redraw][!Delay 1200][!UpdateMeasure MeasureRelayoutIfIdle]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot8

[MeterText9]
Meter=String
MeterStyle=sItem
Text=#Todo9#
FontColor=#InkRGB#,[#ItemAlpha[#TodoDone9]]
ClipString=1
InlineSetting7=[#Strike[#TodoDone9]]
InlinePattern7=.*
X=((26 + 160 * ([&MeasureRow9:0] >= #Rows#)) + 11)
Y=((58 + #Pitch# * ([&MeasureRow9:0] % #Rows#)) - 8 - #Ascent13#)
W=([&MeasureRow9:0] >= #Rows# ? #TextW2# : #TextW#)
Padding=4,8,4,#RowPadBottom#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow9:0] < 0) || ([&MeasureRow9:0] >= #Cap#) || ((#Editing# = 1) && (#EditSlot# = 9)))
MouseActionCursor=1
MouseActionCursorName=Text
ToolTipText=#Todo9#
LeftMouseUpAction=[!SetVariable EditSlot 9][!SetVariable Editing 1][!UpdateMeter MeterText9][!UpdateMeter MeterEditPad][!Redraw][!CommandMeasure MeasureInput "ExecuteBatch 1"]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot9

[MeterCheck9]
Meter=Image
ImageName=sf:[#CheckSymbol[#TodoDone9]]
MacSymbolSize=15
MacSymbolWeight=Regular
ImageTint=[#CheckTint[#TodoDone9]]
X=((26 + 160 * ([&MeasureRow9:0] >= #Rows#)) - 15)
Y=((58 + #Pitch# * ([&MeasureRow9:0] % #Rows#)) - 13.1 - #CheckPadV#)
W=18
H=17
Padding=6,#CheckPadV#,6,#CheckPadV#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow9:0] < 0) || ([&MeasureRow9:0] >= #Cap#))
ToolTipText=[#ToDoTipCheck[#TodoDone9]]
MouseOverAction=[!SetVariable HoverSlot 9][!SetVariable PadShown 1][!UpdateMeter MeterCheckPad][!Redraw]
MouseLeaveAction=[!SetVariable PadShown 0][!SetVariable PadPressed 0][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseDownAction=[!SetVariable PadPressed 1][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseUpAction=[!SetVariable PadPressed 0][!SetVariable TodoDone9 "(1 - [#TodoDone9])"][!WriteKeyValue Variables TodoDone9 [#TodoDone9] "#StationeryFile#"][!UpdateMeasure MeasureState9][!UpdateMeasureGroup Counts][!UpdateMeterGroup Slot9][!UpdateMeter MeterHeaderTrailing][!UpdateMeter MeterCheckPad][!Redraw][!Delay 1200][!UpdateMeasure MeasureRelayoutIfIdle]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot9

[MeterText10]
Meter=String
MeterStyle=sItem
Text=#Todo10#
FontColor=#InkRGB#,[#ItemAlpha[#TodoDone10]]
ClipString=1
InlineSetting7=[#Strike[#TodoDone10]]
InlinePattern7=.*
X=((26 + 160 * ([&MeasureRow10:0] >= #Rows#)) + 11)
Y=((58 + #Pitch# * ([&MeasureRow10:0] % #Rows#)) - 8 - #Ascent13#)
W=([&MeasureRow10:0] >= #Rows# ? #TextW2# : #TextW#)
Padding=4,8,4,#RowPadBottom#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow10:0] < 0) || ([&MeasureRow10:0] >= #Cap#) || ((#Editing# = 1) && (#EditSlot# = 10)))
MouseActionCursor=1
MouseActionCursorName=Text
ToolTipText=#Todo10#
LeftMouseUpAction=[!SetVariable EditSlot 10][!SetVariable Editing 1][!UpdateMeter MeterText10][!UpdateMeter MeterEditPad][!Redraw][!CommandMeasure MeasureInput "ExecuteBatch 1"]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot10

[MeterCheck10]
Meter=Image
ImageName=sf:[#CheckSymbol[#TodoDone10]]
MacSymbolSize=15
MacSymbolWeight=Regular
ImageTint=[#CheckTint[#TodoDone10]]
X=((26 + 160 * ([&MeasureRow10:0] >= #Rows#)) - 15)
Y=((58 + #Pitch# * ([&MeasureRow10:0] % #Rows#)) - 13.1 - #CheckPadV#)
W=18
H=17
Padding=6,#CheckPadV#,6,#CheckPadV#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow10:0] < 0) || ([&MeasureRow10:0] >= #Cap#))
ToolTipText=[#ToDoTipCheck[#TodoDone10]]
MouseOverAction=[!SetVariable HoverSlot 10][!SetVariable PadShown 1][!UpdateMeter MeterCheckPad][!Redraw]
MouseLeaveAction=[!SetVariable PadShown 0][!SetVariable PadPressed 0][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseDownAction=[!SetVariable PadPressed 1][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseUpAction=[!SetVariable PadPressed 0][!SetVariable TodoDone10 "(1 - [#TodoDone10])"][!WriteKeyValue Variables TodoDone10 [#TodoDone10] "#StationeryFile#"][!UpdateMeasure MeasureState10][!UpdateMeasureGroup Counts][!UpdateMeterGroup Slot10][!UpdateMeter MeterHeaderTrailing][!UpdateMeter MeterCheckPad][!Redraw][!Delay 1200][!UpdateMeasure MeasureRelayoutIfIdle]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot10

[MeterText11]
Meter=String
MeterStyle=sItem
Text=#Todo11#
FontColor=#InkRGB#,[#ItemAlpha[#TodoDone11]]
ClipString=1
InlineSetting7=[#Strike[#TodoDone11]]
InlinePattern7=.*
X=((26 + 160 * ([&MeasureRow11:0] >= #Rows#)) + 11)
Y=((58 + #Pitch# * ([&MeasureRow11:0] % #Rows#)) - 8 - #Ascent13#)
W=([&MeasureRow11:0] >= #Rows# ? #TextW2# : #TextW#)
Padding=4,8,4,#RowPadBottom#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow11:0] < 0) || ([&MeasureRow11:0] >= #Cap#) || ((#Editing# = 1) && (#EditSlot# = 11)))
MouseActionCursor=1
MouseActionCursorName=Text
ToolTipText=#Todo11#
LeftMouseUpAction=[!SetVariable EditSlot 11][!SetVariable Editing 1][!UpdateMeter MeterText11][!UpdateMeter MeterEditPad][!Redraw][!CommandMeasure MeasureInput "ExecuteBatch 1"]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot11

[MeterCheck11]
Meter=Image
ImageName=sf:[#CheckSymbol[#TodoDone11]]
MacSymbolSize=15
MacSymbolWeight=Regular
ImageTint=[#CheckTint[#TodoDone11]]
X=((26 + 160 * ([&MeasureRow11:0] >= #Rows#)) - 15)
Y=((58 + #Pitch# * ([&MeasureRow11:0] % #Rows#)) - 13.1 - #CheckPadV#)
W=18
H=17
Padding=6,#CheckPadV#,6,#CheckPadV#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow11:0] < 0) || ([&MeasureRow11:0] >= #Cap#))
ToolTipText=[#ToDoTipCheck[#TodoDone11]]
MouseOverAction=[!SetVariable HoverSlot 11][!SetVariable PadShown 1][!UpdateMeter MeterCheckPad][!Redraw]
MouseLeaveAction=[!SetVariable PadShown 0][!SetVariable PadPressed 0][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseDownAction=[!SetVariable PadPressed 1][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseUpAction=[!SetVariable PadPressed 0][!SetVariable TodoDone11 "(1 - [#TodoDone11])"][!WriteKeyValue Variables TodoDone11 [#TodoDone11] "#StationeryFile#"][!UpdateMeasure MeasureState11][!UpdateMeasureGroup Counts][!UpdateMeterGroup Slot11][!UpdateMeter MeterHeaderTrailing][!UpdateMeter MeterCheckPad][!Redraw][!Delay 1200][!UpdateMeasure MeasureRelayoutIfIdle]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot11

[MeterText12]
Meter=String
MeterStyle=sItem
Text=#Todo12#
FontColor=#InkRGB#,[#ItemAlpha[#TodoDone12]]
ClipString=1
InlineSetting7=[#Strike[#TodoDone12]]
InlinePattern7=.*
X=((26 + 160 * ([&MeasureRow12:0] >= #Rows#)) + 11)
Y=((58 + #Pitch# * ([&MeasureRow12:0] % #Rows#)) - 8 - #Ascent13#)
W=([&MeasureRow12:0] >= #Rows# ? #TextW2# : #TextW#)
Padding=4,8,4,#RowPadBottom#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow12:0] < 0) || ([&MeasureRow12:0] >= #Cap#) || ((#Editing# = 1) && (#EditSlot# = 12)))
MouseActionCursor=1
MouseActionCursorName=Text
ToolTipText=#Todo12#
LeftMouseUpAction=[!SetVariable EditSlot 12][!SetVariable Editing 1][!UpdateMeter MeterText12][!UpdateMeter MeterEditPad][!Redraw][!CommandMeasure MeasureInput "ExecuteBatch 1"]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot12

[MeterCheck12]
Meter=Image
ImageName=sf:[#CheckSymbol[#TodoDone12]]
MacSymbolSize=15
MacSymbolWeight=Regular
ImageTint=[#CheckTint[#TodoDone12]]
X=((26 + 160 * ([&MeasureRow12:0] >= #Rows#)) - 15)
Y=((58 + #Pitch# * ([&MeasureRow12:0] % #Rows#)) - 13.1 - #CheckPadV#)
W=18
H=17
Padding=6,#CheckPadV#,6,#CheckPadV#
SolidColor=0,0,0,1
Hidden=(([&MeasureRow12:0] < 0) || ([&MeasureRow12:0] >= #Cap#))
ToolTipText=[#ToDoTipCheck[#TodoDone12]]
MouseOverAction=[!SetVariable HoverSlot 12][!SetVariable PadShown 1][!UpdateMeter MeterCheckPad][!Redraw]
MouseLeaveAction=[!SetVariable PadShown 0][!SetVariable PadPressed 0][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseDownAction=[!SetVariable PadPressed 1][!UpdateMeter MeterCheckPad][!Redraw]
LeftMouseUpAction=[!SetVariable PadPressed 0][!SetVariable TodoDone12 "(1 - [#TodoDone12])"][!WriteKeyValue Variables TodoDone12 [#TodoDone12] "#StationeryFile#"][!UpdateMeasure MeasureState12][!UpdateMeasureGroup Counts][!UpdateMeterGroup Slot12][!UpdateMeter MeterHeaderTrailing][!UpdateMeter MeterCheckPad][!Redraw][!Delay 1200][!UpdateMeasure MeasureRelayoutIfIdle]
DynamicVariables=1
UpdateDivider=-1
Group=Items | Slot12
