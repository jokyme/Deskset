; Stationery · To Do — the measures every size shares. Original work, MIT licensed.
;
; Nothing runs on a timer: the skin updates once at load, and every click, scroll and edit updates what it changes.
; A relayout (#Relayout#) updates group List, whose measures give each slot its row in the window, then the meters.
; #Cap# is the size's number of rows.

[MeasureStationeryFile]
; Deskset makes Stationery.inc at every launch, and !WriteKeyValue writes only into a file that exists: this makes
; it again (empty) if it was deleted since. An empty file changes nothing in memory, so nothing needs a refresh.
Measure=Plugin
Plugin=RunCommand
Parameter=test -e "#StationeryFile#" || : > "#StationeryFile#"
UpdateDivider=-1

[MeasureNow]
; UTC seconds since 1601: the order stamp of a new item (newest first), so a clock change never reorders the list
Measure=Time
TimeZone=0
DaylightSavingTime=0
TimeStamp=#TestNow#
UpdateDivider=-1

[MeasureInput]
; The edit box, over the text of the row being edited or over the add row. Its fill is opaque: today's input box
; is square, fades its text with its fill's alpha and opens with the text selected. The Mac keys below make it a
; transparent box over the pad the skin draws, with the text at its own alpha and weight, the caret at the end, a
; placeholder, and a click elsewhere keeping what was typed; Deskset ignores them until it has them.
Measure=Plugin
Plugin=InputText
SolidColor=#FieldColor#
FontColor=#TextColor#
FontFace=#FontText#
FontSize=9.75
InputLimit=200
FocusDismiss=1
MacStyle=1
MacFillColor=0,0,0,1
FontWeight=500
MacPlaceholder=#ToDoNewItem#
MacPlaceholderColor=#SecondaryTextColor#
MacCommitOnDismiss=1
X=[MeterText[#EditSlot]:X]
Y=([MeterText[#EditSlot]:Y] + 4.57)
W=[MeterText[#EditSlot]:W]
H=24
DefaultValue=[#Todo[#EditSlot]]
; Escape (and, today, a click elsewhere): nothing is written; a relayout held back while the box was open runs now
OnDismissAction=[!SetVariable Editing 0][!SetVariable Adding 0]#Relayout#
; 1: the item in slot #EditSlot#, edited in place; an empty text frees the slot (that is how an item is deleted)
Command1=[!UpdateMeasure MeasureTyped][!SetVariable Todo[#EditSlot] "[MeasureTyped]"][!WriteKeyValue Variables Todo[#EditSlot] "[MeasureTyped]" "#StationeryFile#"][!SetVariable Editing 0]#Relayout#[!SetVariable Typed """$UserInput$"""]
; 2: a new item in the free slot, stamped now so it goes to the top; the box sits on the add row
Command2=[!UpdateMeasure MeasureTyped][!UpdateMeasure MeasureNow][!SetVariable Todo[#EditSlot] "[MeasureTyped]"][!SetVariable TodoDone[#EditSlot] 0][!SetVariable TodoOrder[#EditSlot] [MeasureNow:0]][!WriteKeyValue Variables Todo[#EditSlot] "[MeasureTyped]" "#StationeryFile#"][!WriteKeyValue Variables TodoDone[#EditSlot] 0 "#StationeryFile#"][!WriteKeyValue Variables TodoOrder[#EditSlot] [MeasureNow:0] "#StationeryFile#"][!SetVariable Adding 0][!SetVariable Offset 0]#Relayout#[!SetVariable Typed """$UserInput$"""] X=37 Y=(#AddBaseline# - 16) W=#AddFieldW# DefaultValue=""

[MeasureTyped]
; The typed text, made inert before it is stored. Line breaks become spaces and the ends are trimmed; then
; [ becomes [\x5B], # becomes [\x23], and a leading (, " or ' becomes [\x28], [\x22] or [\x27]. Stored that
; way an item can never be read as a variable, a section variable or a formula, nor lose its quotes when the file
; is read back, and every meter shows it as typed. [*…*] keeps each replacement from being read here.
Measure=String
String=[MeasureInput]
DynamicVariables=1
RegExpSubstitute=1
Substitute="\r|\n":" ","^\s+|\s+$":"","\[":"[*\x5B*]","#":"[*\x23*]","^\(":"[*\x28*]",'^"':"[*\x22*]","^'":"[*\x27*]"
UpdateDivider=-1

[MeasureState1]
; slot 1: 0 empty, 1 open, 2 done
Measure=String
String=#TodoDone1#|#Todo1#
DynamicVariables=1
RegExpSubstitute=1
Substitute="^[^|]*\|\s*$":"0","^1\|.+$":"2","^[^|]*\|.+$":"1"
UpdateDivider=-1
Group=List

[MeasureState2]
; slot 2
Measure=String
String=#TodoDone2#|#Todo2#
DynamicVariables=1
RegExpSubstitute=1
Substitute="^[^|]*\|\s*$":"0","^1\|.+$":"2","^[^|]*\|.+$":"1"
UpdateDivider=-1
Group=List

[MeasureState3]
; slot 3
Measure=String
String=#TodoDone3#|#Todo3#
DynamicVariables=1
RegExpSubstitute=1
Substitute="^[^|]*\|\s*$":"0","^1\|.+$":"2","^[^|]*\|.+$":"1"
UpdateDivider=-1
Group=List

[MeasureState4]
; slot 4
Measure=String
String=#TodoDone4#|#Todo4#
DynamicVariables=1
RegExpSubstitute=1
Substitute="^[^|]*\|\s*$":"0","^1\|.+$":"2","^[^|]*\|.+$":"1"
UpdateDivider=-1
Group=List

[MeasureState5]
; slot 5
Measure=String
String=#TodoDone5#|#Todo5#
DynamicVariables=1
RegExpSubstitute=1
Substitute="^[^|]*\|\s*$":"0","^1\|.+$":"2","^[^|]*\|.+$":"1"
UpdateDivider=-1
Group=List

[MeasureState6]
; slot 6
Measure=String
String=#TodoDone6#|#Todo6#
DynamicVariables=1
RegExpSubstitute=1
Substitute="^[^|]*\|\s*$":"0","^1\|.+$":"2","^[^|]*\|.+$":"1"
UpdateDivider=-1
Group=List

[MeasureState7]
; slot 7
Measure=String
String=#TodoDone7#|#Todo7#
DynamicVariables=1
RegExpSubstitute=1
Substitute="^[^|]*\|\s*$":"0","^1\|.+$":"2","^[^|]*\|.+$":"1"
UpdateDivider=-1
Group=List

[MeasureState8]
; slot 8
Measure=String
String=#TodoDone8#|#Todo8#
DynamicVariables=1
RegExpSubstitute=1
Substitute="^[^|]*\|\s*$":"0","^1\|.+$":"2","^[^|]*\|.+$":"1"
UpdateDivider=-1
Group=List

[MeasureState9]
; slot 9
Measure=String
String=#TodoDone9#|#Todo9#
DynamicVariables=1
RegExpSubstitute=1
Substitute="^[^|]*\|\s*$":"0","^1\|.+$":"2","^[^|]*\|.+$":"1"
UpdateDivider=-1
Group=List

[MeasureState10]
; slot 10
Measure=String
String=#TodoDone10#|#Todo10#
DynamicVariables=1
RegExpSubstitute=1
Substitute="^[^|]*\|\s*$":"0","^1\|.+$":"2","^[^|]*\|.+$":"1"
UpdateDivider=-1
Group=List

[MeasureState11]
; slot 11
Measure=String
String=#TodoDone11#|#Todo11#
DynamicVariables=1
RegExpSubstitute=1
Substitute="^[^|]*\|\s*$":"0","^1\|.+$":"2","^[^|]*\|.+$":"1"
UpdateDivider=-1
Group=List

[MeasureState12]
; slot 12
Measure=String
String=#TodoDone12#|#Todo12#
DynamicVariables=1
RegExpSubstitute=1
Substitute="^[^|]*\|\s*$":"0","^1\|.+$":"2","^[^|]*\|.+$":"1"
UpdateDivider=-1
Group=List

[MeasureShown]
; the items shown: the open ones, and the done ones while Completed Items is Shown
Measure=Calc
Formula=(([MeasureState1]=1)+([MeasureState1]=2)*#ToDoShowCompleted#)+(([MeasureState2]=1)+([MeasureState2]=2)*#ToDoShowCompleted#)+(([MeasureState3]=1)+([MeasureState3]=2)*#ToDoShowCompleted#)+(([MeasureState4]=1)+([MeasureState4]=2)*#ToDoShowCompleted#)+(([MeasureState5]=1)+([MeasureState5]=2)*#ToDoShowCompleted#)+(([MeasureState6]=1)+([MeasureState6]=2)*#ToDoShowCompleted#)+(([MeasureState7]=1)+([MeasureState7]=2)*#ToDoShowCompleted#)+(([MeasureState8]=1)+([MeasureState8]=2)*#ToDoShowCompleted#)+(([MeasureState9]=1)+([MeasureState9]=2)*#ToDoShowCompleted#)+(([MeasureState10]=1)+([MeasureState10]=2)*#ToDoShowCompleted#)+(([MeasureState11]=1)+([MeasureState11]=2)*#ToDoShowCompleted#)+(([MeasureState12]=1)+([MeasureState12]=2)*#ToDoShowCompleted#)
DynamicVariables=1
UpdateDivider=-1
Group=List

[MeasureMaxOffset]
; the last scroll position, in whole steps (a column of 3 in the Medium, so its columns stay aligned)
Measure=Calc
Formula=#ScrollStep# * Ceil(Max(0, MeasureShown - #Cap#) / #ScrollStep#)
UpdateDivider=-1
Group=List

[MeasureOffset]
; the scroll position, clamped (the list may have shrunk since it was set)
Measure=Calc
Formula=Clamp(#Offset#, 0, MeasureMaxOffset)
DynamicVariables=1
UpdateDivider=-1
Group=List

[MeasureRow1]
; slot 1's row in the window, or -1 when it is not shown: the shown items with a newer stamp (a tie puts the lower
; slot first), less the scroll position. While Clear Completed runs, a done slot is blanked here.
Measure=Calc
Formula=(([MeasureState1]=1)+([MeasureState1]=2)*#ToDoShowCompleted#) ? ((([MeasureState2]=1)+([MeasureState2]=2)*#ToDoShowCompleted#)*(#TodoOrder2#>#TodoOrder1#)+(([MeasureState3]=1)+([MeasureState3]=2)*#ToDoShowCompleted#)*(#TodoOrder3#>#TodoOrder1#)+(([MeasureState4]=1)+([MeasureState4]=2)*#ToDoShowCompleted#)*(#TodoOrder4#>#TodoOrder1#)+(([MeasureState5]=1)+([MeasureState5]=2)*#ToDoShowCompleted#)*(#TodoOrder5#>#TodoOrder1#)+(([MeasureState6]=1)+([MeasureState6]=2)*#ToDoShowCompleted#)*(#TodoOrder6#>#TodoOrder1#)+(([MeasureState7]=1)+([MeasureState7]=2)*#ToDoShowCompleted#)*(#TodoOrder7#>#TodoOrder1#)+(([MeasureState8]=1)+([MeasureState8]=2)*#ToDoShowCompleted#)*(#TodoOrder8#>#TodoOrder1#)+(([MeasureState9]=1)+([MeasureState9]=2)*#ToDoShowCompleted#)*(#TodoOrder9#>#TodoOrder1#)+(([MeasureState10]=1)+([MeasureState10]=2)*#ToDoShowCompleted#)*(#TodoOrder10#>#TodoOrder1#)+(([MeasureState11]=1)+([MeasureState11]=2)*#ToDoShowCompleted#)*(#TodoOrder11#>#TodoOrder1#)+(([MeasureState12]=1)+([MeasureState12]=2)*#ToDoShowCompleted#)*(#TodoOrder12#>#TodoOrder1#) - MeasureOffset) : -1
IfCondition=(#Clearing# = 1) && ([MeasureState1] = 2)
IfTrueAction=[!SetVariable Todo1 ""][!SetVariable TodoDone1 0][!WriteKeyValue Variables Todo1 "" "#StationeryFile#"][!WriteKeyValue Variables TodoDone1 0 "#StationeryFile#"]
IfConditionMode=1
DynamicVariables=1
UpdateDivider=-1
Group=List

[MeasureRow2]
; slot 2
Measure=Calc
Formula=(([MeasureState2]=1)+([MeasureState2]=2)*#ToDoShowCompleted#) ? ((([MeasureState1]=1)+([MeasureState1]=2)*#ToDoShowCompleted#)*(#TodoOrder1#>=#TodoOrder2#)+(([MeasureState3]=1)+([MeasureState3]=2)*#ToDoShowCompleted#)*(#TodoOrder3#>#TodoOrder2#)+(([MeasureState4]=1)+([MeasureState4]=2)*#ToDoShowCompleted#)*(#TodoOrder4#>#TodoOrder2#)+(([MeasureState5]=1)+([MeasureState5]=2)*#ToDoShowCompleted#)*(#TodoOrder5#>#TodoOrder2#)+(([MeasureState6]=1)+([MeasureState6]=2)*#ToDoShowCompleted#)*(#TodoOrder6#>#TodoOrder2#)+(([MeasureState7]=1)+([MeasureState7]=2)*#ToDoShowCompleted#)*(#TodoOrder7#>#TodoOrder2#)+(([MeasureState8]=1)+([MeasureState8]=2)*#ToDoShowCompleted#)*(#TodoOrder8#>#TodoOrder2#)+(([MeasureState9]=1)+([MeasureState9]=2)*#ToDoShowCompleted#)*(#TodoOrder9#>#TodoOrder2#)+(([MeasureState10]=1)+([MeasureState10]=2)*#ToDoShowCompleted#)*(#TodoOrder10#>#TodoOrder2#)+(([MeasureState11]=1)+([MeasureState11]=2)*#ToDoShowCompleted#)*(#TodoOrder11#>#TodoOrder2#)+(([MeasureState12]=1)+([MeasureState12]=2)*#ToDoShowCompleted#)*(#TodoOrder12#>#TodoOrder2#) - MeasureOffset) : -1
IfCondition=(#Clearing# = 1) && ([MeasureState2] = 2)
IfTrueAction=[!SetVariable Todo2 ""][!SetVariable TodoDone2 0][!WriteKeyValue Variables Todo2 "" "#StationeryFile#"][!WriteKeyValue Variables TodoDone2 0 "#StationeryFile#"]
IfConditionMode=1
DynamicVariables=1
UpdateDivider=-1
Group=List

[MeasureRow3]
; slot 3
Measure=Calc
Formula=(([MeasureState3]=1)+([MeasureState3]=2)*#ToDoShowCompleted#) ? ((([MeasureState1]=1)+([MeasureState1]=2)*#ToDoShowCompleted#)*(#TodoOrder1#>=#TodoOrder3#)+(([MeasureState2]=1)+([MeasureState2]=2)*#ToDoShowCompleted#)*(#TodoOrder2#>=#TodoOrder3#)+(([MeasureState4]=1)+([MeasureState4]=2)*#ToDoShowCompleted#)*(#TodoOrder4#>#TodoOrder3#)+(([MeasureState5]=1)+([MeasureState5]=2)*#ToDoShowCompleted#)*(#TodoOrder5#>#TodoOrder3#)+(([MeasureState6]=1)+([MeasureState6]=2)*#ToDoShowCompleted#)*(#TodoOrder6#>#TodoOrder3#)+(([MeasureState7]=1)+([MeasureState7]=2)*#ToDoShowCompleted#)*(#TodoOrder7#>#TodoOrder3#)+(([MeasureState8]=1)+([MeasureState8]=2)*#ToDoShowCompleted#)*(#TodoOrder8#>#TodoOrder3#)+(([MeasureState9]=1)+([MeasureState9]=2)*#ToDoShowCompleted#)*(#TodoOrder9#>#TodoOrder3#)+(([MeasureState10]=1)+([MeasureState10]=2)*#ToDoShowCompleted#)*(#TodoOrder10#>#TodoOrder3#)+(([MeasureState11]=1)+([MeasureState11]=2)*#ToDoShowCompleted#)*(#TodoOrder11#>#TodoOrder3#)+(([MeasureState12]=1)+([MeasureState12]=2)*#ToDoShowCompleted#)*(#TodoOrder12#>#TodoOrder3#) - MeasureOffset) : -1
IfCondition=(#Clearing# = 1) && ([MeasureState3] = 2)
IfTrueAction=[!SetVariable Todo3 ""][!SetVariable TodoDone3 0][!WriteKeyValue Variables Todo3 "" "#StationeryFile#"][!WriteKeyValue Variables TodoDone3 0 "#StationeryFile#"]
IfConditionMode=1
DynamicVariables=1
UpdateDivider=-1
Group=List

[MeasureRow4]
; slot 4
Measure=Calc
Formula=(([MeasureState4]=1)+([MeasureState4]=2)*#ToDoShowCompleted#) ? ((([MeasureState1]=1)+([MeasureState1]=2)*#ToDoShowCompleted#)*(#TodoOrder1#>=#TodoOrder4#)+(([MeasureState2]=1)+([MeasureState2]=2)*#ToDoShowCompleted#)*(#TodoOrder2#>=#TodoOrder4#)+(([MeasureState3]=1)+([MeasureState3]=2)*#ToDoShowCompleted#)*(#TodoOrder3#>=#TodoOrder4#)+(([MeasureState5]=1)+([MeasureState5]=2)*#ToDoShowCompleted#)*(#TodoOrder5#>#TodoOrder4#)+(([MeasureState6]=1)+([MeasureState6]=2)*#ToDoShowCompleted#)*(#TodoOrder6#>#TodoOrder4#)+(([MeasureState7]=1)+([MeasureState7]=2)*#ToDoShowCompleted#)*(#TodoOrder7#>#TodoOrder4#)+(([MeasureState8]=1)+([MeasureState8]=2)*#ToDoShowCompleted#)*(#TodoOrder8#>#TodoOrder4#)+(([MeasureState9]=1)+([MeasureState9]=2)*#ToDoShowCompleted#)*(#TodoOrder9#>#TodoOrder4#)+(([MeasureState10]=1)+([MeasureState10]=2)*#ToDoShowCompleted#)*(#TodoOrder10#>#TodoOrder4#)+(([MeasureState11]=1)+([MeasureState11]=2)*#ToDoShowCompleted#)*(#TodoOrder11#>#TodoOrder4#)+(([MeasureState12]=1)+([MeasureState12]=2)*#ToDoShowCompleted#)*(#TodoOrder12#>#TodoOrder4#) - MeasureOffset) : -1
IfCondition=(#Clearing# = 1) && ([MeasureState4] = 2)
IfTrueAction=[!SetVariable Todo4 ""][!SetVariable TodoDone4 0][!WriteKeyValue Variables Todo4 "" "#StationeryFile#"][!WriteKeyValue Variables TodoDone4 0 "#StationeryFile#"]
IfConditionMode=1
DynamicVariables=1
UpdateDivider=-1
Group=List

[MeasureRow5]
; slot 5
Measure=Calc
Formula=(([MeasureState5]=1)+([MeasureState5]=2)*#ToDoShowCompleted#) ? ((([MeasureState1]=1)+([MeasureState1]=2)*#ToDoShowCompleted#)*(#TodoOrder1#>=#TodoOrder5#)+(([MeasureState2]=1)+([MeasureState2]=2)*#ToDoShowCompleted#)*(#TodoOrder2#>=#TodoOrder5#)+(([MeasureState3]=1)+([MeasureState3]=2)*#ToDoShowCompleted#)*(#TodoOrder3#>=#TodoOrder5#)+(([MeasureState4]=1)+([MeasureState4]=2)*#ToDoShowCompleted#)*(#TodoOrder4#>=#TodoOrder5#)+(([MeasureState6]=1)+([MeasureState6]=2)*#ToDoShowCompleted#)*(#TodoOrder6#>#TodoOrder5#)+(([MeasureState7]=1)+([MeasureState7]=2)*#ToDoShowCompleted#)*(#TodoOrder7#>#TodoOrder5#)+(([MeasureState8]=1)+([MeasureState8]=2)*#ToDoShowCompleted#)*(#TodoOrder8#>#TodoOrder5#)+(([MeasureState9]=1)+([MeasureState9]=2)*#ToDoShowCompleted#)*(#TodoOrder9#>#TodoOrder5#)+(([MeasureState10]=1)+([MeasureState10]=2)*#ToDoShowCompleted#)*(#TodoOrder10#>#TodoOrder5#)+(([MeasureState11]=1)+([MeasureState11]=2)*#ToDoShowCompleted#)*(#TodoOrder11#>#TodoOrder5#)+(([MeasureState12]=1)+([MeasureState12]=2)*#ToDoShowCompleted#)*(#TodoOrder12#>#TodoOrder5#) - MeasureOffset) : -1
IfCondition=(#Clearing# = 1) && ([MeasureState5] = 2)
IfTrueAction=[!SetVariable Todo5 ""][!SetVariable TodoDone5 0][!WriteKeyValue Variables Todo5 "" "#StationeryFile#"][!WriteKeyValue Variables TodoDone5 0 "#StationeryFile#"]
IfConditionMode=1
DynamicVariables=1
UpdateDivider=-1
Group=List

[MeasureRow6]
; slot 6
Measure=Calc
Formula=(([MeasureState6]=1)+([MeasureState6]=2)*#ToDoShowCompleted#) ? ((([MeasureState1]=1)+([MeasureState1]=2)*#ToDoShowCompleted#)*(#TodoOrder1#>=#TodoOrder6#)+(([MeasureState2]=1)+([MeasureState2]=2)*#ToDoShowCompleted#)*(#TodoOrder2#>=#TodoOrder6#)+(([MeasureState3]=1)+([MeasureState3]=2)*#ToDoShowCompleted#)*(#TodoOrder3#>=#TodoOrder6#)+(([MeasureState4]=1)+([MeasureState4]=2)*#ToDoShowCompleted#)*(#TodoOrder4#>=#TodoOrder6#)+(([MeasureState5]=1)+([MeasureState5]=2)*#ToDoShowCompleted#)*(#TodoOrder5#>=#TodoOrder6#)+(([MeasureState7]=1)+([MeasureState7]=2)*#ToDoShowCompleted#)*(#TodoOrder7#>#TodoOrder6#)+(([MeasureState8]=1)+([MeasureState8]=2)*#ToDoShowCompleted#)*(#TodoOrder8#>#TodoOrder6#)+(([MeasureState9]=1)+([MeasureState9]=2)*#ToDoShowCompleted#)*(#TodoOrder9#>#TodoOrder6#)+(([MeasureState10]=1)+([MeasureState10]=2)*#ToDoShowCompleted#)*(#TodoOrder10#>#TodoOrder6#)+(([MeasureState11]=1)+([MeasureState11]=2)*#ToDoShowCompleted#)*(#TodoOrder11#>#TodoOrder6#)+(([MeasureState12]=1)+([MeasureState12]=2)*#ToDoShowCompleted#)*(#TodoOrder12#>#TodoOrder6#) - MeasureOffset) : -1
IfCondition=(#Clearing# = 1) && ([MeasureState6] = 2)
IfTrueAction=[!SetVariable Todo6 ""][!SetVariable TodoDone6 0][!WriteKeyValue Variables Todo6 "" "#StationeryFile#"][!WriteKeyValue Variables TodoDone6 0 "#StationeryFile#"]
IfConditionMode=1
DynamicVariables=1
UpdateDivider=-1
Group=List

[MeasureRow7]
; slot 7
Measure=Calc
Formula=(([MeasureState7]=1)+([MeasureState7]=2)*#ToDoShowCompleted#) ? ((([MeasureState1]=1)+([MeasureState1]=2)*#ToDoShowCompleted#)*(#TodoOrder1#>=#TodoOrder7#)+(([MeasureState2]=1)+([MeasureState2]=2)*#ToDoShowCompleted#)*(#TodoOrder2#>=#TodoOrder7#)+(([MeasureState3]=1)+([MeasureState3]=2)*#ToDoShowCompleted#)*(#TodoOrder3#>=#TodoOrder7#)+(([MeasureState4]=1)+([MeasureState4]=2)*#ToDoShowCompleted#)*(#TodoOrder4#>=#TodoOrder7#)+(([MeasureState5]=1)+([MeasureState5]=2)*#ToDoShowCompleted#)*(#TodoOrder5#>=#TodoOrder7#)+(([MeasureState6]=1)+([MeasureState6]=2)*#ToDoShowCompleted#)*(#TodoOrder6#>=#TodoOrder7#)+(([MeasureState8]=1)+([MeasureState8]=2)*#ToDoShowCompleted#)*(#TodoOrder8#>#TodoOrder7#)+(([MeasureState9]=1)+([MeasureState9]=2)*#ToDoShowCompleted#)*(#TodoOrder9#>#TodoOrder7#)+(([MeasureState10]=1)+([MeasureState10]=2)*#ToDoShowCompleted#)*(#TodoOrder10#>#TodoOrder7#)+(([MeasureState11]=1)+([MeasureState11]=2)*#ToDoShowCompleted#)*(#TodoOrder11#>#TodoOrder7#)+(([MeasureState12]=1)+([MeasureState12]=2)*#ToDoShowCompleted#)*(#TodoOrder12#>#TodoOrder7#) - MeasureOffset) : -1
IfCondition=(#Clearing# = 1) && ([MeasureState7] = 2)
IfTrueAction=[!SetVariable Todo7 ""][!SetVariable TodoDone7 0][!WriteKeyValue Variables Todo7 "" "#StationeryFile#"][!WriteKeyValue Variables TodoDone7 0 "#StationeryFile#"]
IfConditionMode=1
DynamicVariables=1
UpdateDivider=-1
Group=List

[MeasureRow8]
; slot 8
Measure=Calc
Formula=(([MeasureState8]=1)+([MeasureState8]=2)*#ToDoShowCompleted#) ? ((([MeasureState1]=1)+([MeasureState1]=2)*#ToDoShowCompleted#)*(#TodoOrder1#>=#TodoOrder8#)+(([MeasureState2]=1)+([MeasureState2]=2)*#ToDoShowCompleted#)*(#TodoOrder2#>=#TodoOrder8#)+(([MeasureState3]=1)+([MeasureState3]=2)*#ToDoShowCompleted#)*(#TodoOrder3#>=#TodoOrder8#)+(([MeasureState4]=1)+([MeasureState4]=2)*#ToDoShowCompleted#)*(#TodoOrder4#>=#TodoOrder8#)+(([MeasureState5]=1)+([MeasureState5]=2)*#ToDoShowCompleted#)*(#TodoOrder5#>=#TodoOrder8#)+(([MeasureState6]=1)+([MeasureState6]=2)*#ToDoShowCompleted#)*(#TodoOrder6#>=#TodoOrder8#)+(([MeasureState7]=1)+([MeasureState7]=2)*#ToDoShowCompleted#)*(#TodoOrder7#>=#TodoOrder8#)+(([MeasureState9]=1)+([MeasureState9]=2)*#ToDoShowCompleted#)*(#TodoOrder9#>#TodoOrder8#)+(([MeasureState10]=1)+([MeasureState10]=2)*#ToDoShowCompleted#)*(#TodoOrder10#>#TodoOrder8#)+(([MeasureState11]=1)+([MeasureState11]=2)*#ToDoShowCompleted#)*(#TodoOrder11#>#TodoOrder8#)+(([MeasureState12]=1)+([MeasureState12]=2)*#ToDoShowCompleted#)*(#TodoOrder12#>#TodoOrder8#) - MeasureOffset) : -1
IfCondition=(#Clearing# = 1) && ([MeasureState8] = 2)
IfTrueAction=[!SetVariable Todo8 ""][!SetVariable TodoDone8 0][!WriteKeyValue Variables Todo8 "" "#StationeryFile#"][!WriteKeyValue Variables TodoDone8 0 "#StationeryFile#"]
IfConditionMode=1
DynamicVariables=1
UpdateDivider=-1
Group=List

[MeasureRow9]
; slot 9
Measure=Calc
Formula=(([MeasureState9]=1)+([MeasureState9]=2)*#ToDoShowCompleted#) ? ((([MeasureState1]=1)+([MeasureState1]=2)*#ToDoShowCompleted#)*(#TodoOrder1#>=#TodoOrder9#)+(([MeasureState2]=1)+([MeasureState2]=2)*#ToDoShowCompleted#)*(#TodoOrder2#>=#TodoOrder9#)+(([MeasureState3]=1)+([MeasureState3]=2)*#ToDoShowCompleted#)*(#TodoOrder3#>=#TodoOrder9#)+(([MeasureState4]=1)+([MeasureState4]=2)*#ToDoShowCompleted#)*(#TodoOrder4#>=#TodoOrder9#)+(([MeasureState5]=1)+([MeasureState5]=2)*#ToDoShowCompleted#)*(#TodoOrder5#>=#TodoOrder9#)+(([MeasureState6]=1)+([MeasureState6]=2)*#ToDoShowCompleted#)*(#TodoOrder6#>=#TodoOrder9#)+(([MeasureState7]=1)+([MeasureState7]=2)*#ToDoShowCompleted#)*(#TodoOrder7#>=#TodoOrder9#)+(([MeasureState8]=1)+([MeasureState8]=2)*#ToDoShowCompleted#)*(#TodoOrder8#>=#TodoOrder9#)+(([MeasureState10]=1)+([MeasureState10]=2)*#ToDoShowCompleted#)*(#TodoOrder10#>#TodoOrder9#)+(([MeasureState11]=1)+([MeasureState11]=2)*#ToDoShowCompleted#)*(#TodoOrder11#>#TodoOrder9#)+(([MeasureState12]=1)+([MeasureState12]=2)*#ToDoShowCompleted#)*(#TodoOrder12#>#TodoOrder9#) - MeasureOffset) : -1
IfCondition=(#Clearing# = 1) && ([MeasureState9] = 2)
IfTrueAction=[!SetVariable Todo9 ""][!SetVariable TodoDone9 0][!WriteKeyValue Variables Todo9 "" "#StationeryFile#"][!WriteKeyValue Variables TodoDone9 0 "#StationeryFile#"]
IfConditionMode=1
DynamicVariables=1
UpdateDivider=-1
Group=List

[MeasureRow10]
; slot 10
Measure=Calc
Formula=(([MeasureState10]=1)+([MeasureState10]=2)*#ToDoShowCompleted#) ? ((([MeasureState1]=1)+([MeasureState1]=2)*#ToDoShowCompleted#)*(#TodoOrder1#>=#TodoOrder10#)+(([MeasureState2]=1)+([MeasureState2]=2)*#ToDoShowCompleted#)*(#TodoOrder2#>=#TodoOrder10#)+(([MeasureState3]=1)+([MeasureState3]=2)*#ToDoShowCompleted#)*(#TodoOrder3#>=#TodoOrder10#)+(([MeasureState4]=1)+([MeasureState4]=2)*#ToDoShowCompleted#)*(#TodoOrder4#>=#TodoOrder10#)+(([MeasureState5]=1)+([MeasureState5]=2)*#ToDoShowCompleted#)*(#TodoOrder5#>=#TodoOrder10#)+(([MeasureState6]=1)+([MeasureState6]=2)*#ToDoShowCompleted#)*(#TodoOrder6#>=#TodoOrder10#)+(([MeasureState7]=1)+([MeasureState7]=2)*#ToDoShowCompleted#)*(#TodoOrder7#>=#TodoOrder10#)+(([MeasureState8]=1)+([MeasureState8]=2)*#ToDoShowCompleted#)*(#TodoOrder8#>=#TodoOrder10#)+(([MeasureState9]=1)+([MeasureState9]=2)*#ToDoShowCompleted#)*(#TodoOrder9#>=#TodoOrder10#)+(([MeasureState11]=1)+([MeasureState11]=2)*#ToDoShowCompleted#)*(#TodoOrder11#>#TodoOrder10#)+(([MeasureState12]=1)+([MeasureState12]=2)*#ToDoShowCompleted#)*(#TodoOrder12#>#TodoOrder10#) - MeasureOffset) : -1
IfCondition=(#Clearing# = 1) && ([MeasureState10] = 2)
IfTrueAction=[!SetVariable Todo10 ""][!SetVariable TodoDone10 0][!WriteKeyValue Variables Todo10 "" "#StationeryFile#"][!WriteKeyValue Variables TodoDone10 0 "#StationeryFile#"]
IfConditionMode=1
DynamicVariables=1
UpdateDivider=-1
Group=List

[MeasureRow11]
; slot 11
Measure=Calc
Formula=(([MeasureState11]=1)+([MeasureState11]=2)*#ToDoShowCompleted#) ? ((([MeasureState1]=1)+([MeasureState1]=2)*#ToDoShowCompleted#)*(#TodoOrder1#>=#TodoOrder11#)+(([MeasureState2]=1)+([MeasureState2]=2)*#ToDoShowCompleted#)*(#TodoOrder2#>=#TodoOrder11#)+(([MeasureState3]=1)+([MeasureState3]=2)*#ToDoShowCompleted#)*(#TodoOrder3#>=#TodoOrder11#)+(([MeasureState4]=1)+([MeasureState4]=2)*#ToDoShowCompleted#)*(#TodoOrder4#>=#TodoOrder11#)+(([MeasureState5]=1)+([MeasureState5]=2)*#ToDoShowCompleted#)*(#TodoOrder5#>=#TodoOrder11#)+(([MeasureState6]=1)+([MeasureState6]=2)*#ToDoShowCompleted#)*(#TodoOrder6#>=#TodoOrder11#)+(([MeasureState7]=1)+([MeasureState7]=2)*#ToDoShowCompleted#)*(#TodoOrder7#>=#TodoOrder11#)+(([MeasureState8]=1)+([MeasureState8]=2)*#ToDoShowCompleted#)*(#TodoOrder8#>=#TodoOrder11#)+(([MeasureState9]=1)+([MeasureState9]=2)*#ToDoShowCompleted#)*(#TodoOrder9#>=#TodoOrder11#)+(([MeasureState10]=1)+([MeasureState10]=2)*#ToDoShowCompleted#)*(#TodoOrder10#>=#TodoOrder11#)+(([MeasureState12]=1)+([MeasureState12]=2)*#ToDoShowCompleted#)*(#TodoOrder12#>#TodoOrder11#) - MeasureOffset) : -1
IfCondition=(#Clearing# = 1) && ([MeasureState11] = 2)
IfTrueAction=[!SetVariable Todo11 ""][!SetVariable TodoDone11 0][!WriteKeyValue Variables Todo11 "" "#StationeryFile#"][!WriteKeyValue Variables TodoDone11 0 "#StationeryFile#"]
IfConditionMode=1
DynamicVariables=1
UpdateDivider=-1
Group=List

[MeasureRow12]
; slot 12
Measure=Calc
Formula=(([MeasureState12]=1)+([MeasureState12]=2)*#ToDoShowCompleted#) ? ((([MeasureState1]=1)+([MeasureState1]=2)*#ToDoShowCompleted#)*(#TodoOrder1#>=#TodoOrder12#)+(([MeasureState2]=1)+([MeasureState2]=2)*#ToDoShowCompleted#)*(#TodoOrder2#>=#TodoOrder12#)+(([MeasureState3]=1)+([MeasureState3]=2)*#ToDoShowCompleted#)*(#TodoOrder3#>=#TodoOrder12#)+(([MeasureState4]=1)+([MeasureState4]=2)*#ToDoShowCompleted#)*(#TodoOrder4#>=#TodoOrder12#)+(([MeasureState5]=1)+([MeasureState5]=2)*#ToDoShowCompleted#)*(#TodoOrder5#>=#TodoOrder12#)+(([MeasureState6]=1)+([MeasureState6]=2)*#ToDoShowCompleted#)*(#TodoOrder6#>=#TodoOrder12#)+(([MeasureState7]=1)+([MeasureState7]=2)*#ToDoShowCompleted#)*(#TodoOrder7#>=#TodoOrder12#)+(([MeasureState8]=1)+([MeasureState8]=2)*#ToDoShowCompleted#)*(#TodoOrder8#>=#TodoOrder12#)+(([MeasureState9]=1)+([MeasureState9]=2)*#ToDoShowCompleted#)*(#TodoOrder9#>=#TodoOrder12#)+(([MeasureState10]=1)+([MeasureState10]=2)*#ToDoShowCompleted#)*(#TodoOrder10#>=#TodoOrder12#)+(([MeasureState11]=1)+([MeasureState11]=2)*#ToDoShowCompleted#)*(#TodoOrder11#>=#TodoOrder12#) - MeasureOffset) : -1
IfCondition=(#Clearing# = 1) && ([MeasureState12] = 2)
IfTrueAction=[!SetVariable Todo12 ""][!SetVariable TodoDone12 0][!WriteKeyValue Variables Todo12 "" "#StationeryFile#"][!WriteKeyValue Variables TodoDone12 0 "#StationeryFile#"]
IfConditionMode=1
DynamicVariables=1
UpdateDivider=-1
Group=List

[MeasureOpen]
; open items: "8 left"
Measure=Calc
Formula=([MeasureState1]=1)+([MeasureState2]=1)+([MeasureState3]=1)+([MeasureState4]=1)+([MeasureState5]=1)+([MeasureState6]=1)+([MeasureState7]=1)+([MeasureState8]=1)+([MeasureState9]=1)+([MeasureState10]=1)+([MeasureState11]=1)+([MeasureState12]=1)
DynamicVariables=1
UpdateDivider=-1
Group=List | Counts

[MeasureDone]
; done items: the Clear Completed title
Measure=Calc
Formula=([MeasureState1]=2)+([MeasureState2]=2)+([MeasureState3]=2)+([MeasureState4]=2)+([MeasureState5]=2)+([MeasureState6]=2)+([MeasureState7]=2)+([MeasureState8]=2)+([MeasureState9]=2)+([MeasureState10]=2)+([MeasureState11]=2)+([MeasureState12]=2)
DynamicVariables=1
UpdateDivider=-1
Group=List | Counts

[MeasureMore]
; open items outside the window, above or below it: "+N more" (done items never count)
Measure=Calc
Formula=([MeasureState1]=1)*((MeasureRow1<0)+(MeasureRow1>=#Cap#))+([MeasureState2]=1)*((MeasureRow2<0)+(MeasureRow2>=#Cap#))+([MeasureState3]=1)*((MeasureRow3<0)+(MeasureRow3>=#Cap#))+([MeasureState4]=1)*((MeasureRow4<0)+(MeasureRow4>=#Cap#))+([MeasureState5]=1)*((MeasureRow5<0)+(MeasureRow5>=#Cap#))+([MeasureState6]=1)*((MeasureRow6<0)+(MeasureRow6>=#Cap#))+([MeasureState7]=1)*((MeasureRow7<0)+(MeasureRow7>=#Cap#))+([MeasureState8]=1)*((MeasureRow8<0)+(MeasureRow8>=#Cap#))+([MeasureState9]=1)*((MeasureRow9<0)+(MeasureRow9>=#Cap#))+([MeasureState10]=1)*((MeasureRow10<0)+(MeasureRow10>=#Cap#))+([MeasureState11]=1)*((MeasureRow11<0)+(MeasureRow11>=#Cap#))+([MeasureState12]=1)*((MeasureRow12<0)+(MeasureRow12>=#Cap#))
DynamicVariables=1
UpdateDivider=-1
Group=List

[MeasureOldestDone]
; the done item added longest ago (the smallest stamp; a tie: the lower slot), 0 when nothing is done
Measure=Calc
Formula=(([MeasureState1]=2)*((([MeasureState2]=2)*(#TodoOrder2#<#TodoOrder1#)+([MeasureState3]=2)*(#TodoOrder3#<#TodoOrder1#)+([MeasureState4]=2)*(#TodoOrder4#<#TodoOrder1#)+([MeasureState5]=2)*(#TodoOrder5#<#TodoOrder1#)+([MeasureState6]=2)*(#TodoOrder6#<#TodoOrder1#)+([MeasureState7]=2)*(#TodoOrder7#<#TodoOrder1#)+([MeasureState8]=2)*(#TodoOrder8#<#TodoOrder1#)+([MeasureState9]=2)*(#TodoOrder9#<#TodoOrder1#)+([MeasureState10]=2)*(#TodoOrder10#<#TodoOrder1#)+([MeasureState11]=2)*(#TodoOrder11#<#TodoOrder1#)+([MeasureState12]=2)*(#TodoOrder12#<#TodoOrder1#))=0)) ? 1 : ((([MeasureState2]=2)*((([MeasureState1]=2)*(#TodoOrder1#<=#TodoOrder2#)+([MeasureState3]=2)*(#TodoOrder3#<#TodoOrder2#)+([MeasureState4]=2)*(#TodoOrder4#<#TodoOrder2#)+([MeasureState5]=2)*(#TodoOrder5#<#TodoOrder2#)+([MeasureState6]=2)*(#TodoOrder6#<#TodoOrder2#)+([MeasureState7]=2)*(#TodoOrder7#<#TodoOrder2#)+([MeasureState8]=2)*(#TodoOrder8#<#TodoOrder2#)+([MeasureState9]=2)*(#TodoOrder9#<#TodoOrder2#)+([MeasureState10]=2)*(#TodoOrder10#<#TodoOrder2#)+([MeasureState11]=2)*(#TodoOrder11#<#TodoOrder2#)+([MeasureState12]=2)*(#TodoOrder12#<#TodoOrder2#))=0)) ? 2 : ((([MeasureState3]=2)*((([MeasureState1]=2)*(#TodoOrder1#<=#TodoOrder3#)+([MeasureState2]=2)*(#TodoOrder2#<=#TodoOrder3#)+([MeasureState4]=2)*(#TodoOrder4#<#TodoOrder3#)+([MeasureState5]=2)*(#TodoOrder5#<#TodoOrder3#)+([MeasureState6]=2)*(#TodoOrder6#<#TodoOrder3#)+([MeasureState7]=2)*(#TodoOrder7#<#TodoOrder3#)+([MeasureState8]=2)*(#TodoOrder8#<#TodoOrder3#)+([MeasureState9]=2)*(#TodoOrder9#<#TodoOrder3#)+([MeasureState10]=2)*(#TodoOrder10#<#TodoOrder3#)+([MeasureState11]=2)*(#TodoOrder11#<#TodoOrder3#)+([MeasureState12]=2)*(#TodoOrder12#<#TodoOrder3#))=0)) ? 3 : ((([MeasureState4]=2)*((([MeasureState1]=2)*(#TodoOrder1#<=#TodoOrder4#)+([MeasureState2]=2)*(#TodoOrder2#<=#TodoOrder4#)+([MeasureState3]=2)*(#TodoOrder3#<=#TodoOrder4#)+([MeasureState5]=2)*(#TodoOrder5#<#TodoOrder4#)+([MeasureState6]=2)*(#TodoOrder6#<#TodoOrder4#)+([MeasureState7]=2)*(#TodoOrder7#<#TodoOrder4#)+([MeasureState8]=2)*(#TodoOrder8#<#TodoOrder4#)+([MeasureState9]=2)*(#TodoOrder9#<#TodoOrder4#)+([MeasureState10]=2)*(#TodoOrder10#<#TodoOrder4#)+([MeasureState11]=2)*(#TodoOrder11#<#TodoOrder4#)+([MeasureState12]=2)*(#TodoOrder12#<#TodoOrder4#))=0)) ? 4 : ((([MeasureState5]=2)*((([MeasureState1]=2)*(#TodoOrder1#<=#TodoOrder5#)+([MeasureState2]=2)*(#TodoOrder2#<=#TodoOrder5#)+([MeasureState3]=2)*(#TodoOrder3#<=#TodoOrder5#)+([MeasureState4]=2)*(#TodoOrder4#<=#TodoOrder5#)+([MeasureState6]=2)*(#TodoOrder6#<#TodoOrder5#)+([MeasureState7]=2)*(#TodoOrder7#<#TodoOrder5#)+([MeasureState8]=2)*(#TodoOrder8#<#TodoOrder5#)+([MeasureState9]=2)*(#TodoOrder9#<#TodoOrder5#)+([MeasureState10]=2)*(#TodoOrder10#<#TodoOrder5#)+([MeasureState11]=2)*(#TodoOrder11#<#TodoOrder5#)+([MeasureState12]=2)*(#TodoOrder12#<#TodoOrder5#))=0)) ? 5 : ((([MeasureState6]=2)*((([MeasureState1]=2)*(#TodoOrder1#<=#TodoOrder6#)+([MeasureState2]=2)*(#TodoOrder2#<=#TodoOrder6#)+([MeasureState3]=2)*(#TodoOrder3#<=#TodoOrder6#)+([MeasureState4]=2)*(#TodoOrder4#<=#TodoOrder6#)+([MeasureState5]=2)*(#TodoOrder5#<=#TodoOrder6#)+([MeasureState7]=2)*(#TodoOrder7#<#TodoOrder6#)+([MeasureState8]=2)*(#TodoOrder8#<#TodoOrder6#)+([MeasureState9]=2)*(#TodoOrder9#<#TodoOrder6#)+([MeasureState10]=2)*(#TodoOrder10#<#TodoOrder6#)+([MeasureState11]=2)*(#TodoOrder11#<#TodoOrder6#)+([MeasureState12]=2)*(#TodoOrder12#<#TodoOrder6#))=0)) ? 6 : ((([MeasureState7]=2)*((([MeasureState1]=2)*(#TodoOrder1#<=#TodoOrder7#)+([MeasureState2]=2)*(#TodoOrder2#<=#TodoOrder7#)+([MeasureState3]=2)*(#TodoOrder3#<=#TodoOrder7#)+([MeasureState4]=2)*(#TodoOrder4#<=#TodoOrder7#)+([MeasureState5]=2)*(#TodoOrder5#<=#TodoOrder7#)+([MeasureState6]=2)*(#TodoOrder6#<=#TodoOrder7#)+([MeasureState8]=2)*(#TodoOrder8#<#TodoOrder7#)+([MeasureState9]=2)*(#TodoOrder9#<#TodoOrder7#)+([MeasureState10]=2)*(#TodoOrder10#<#TodoOrder7#)+([MeasureState11]=2)*(#TodoOrder11#<#TodoOrder7#)+([MeasureState12]=2)*(#TodoOrder12#<#TodoOrder7#))=0)) ? 7 : ((([MeasureState8]=2)*((([MeasureState1]=2)*(#TodoOrder1#<=#TodoOrder8#)+([MeasureState2]=2)*(#TodoOrder2#<=#TodoOrder8#)+([MeasureState3]=2)*(#TodoOrder3#<=#TodoOrder8#)+([MeasureState4]=2)*(#TodoOrder4#<=#TodoOrder8#)+([MeasureState5]=2)*(#TodoOrder5#<=#TodoOrder8#)+([MeasureState6]=2)*(#TodoOrder6#<=#TodoOrder8#)+([MeasureState7]=2)*(#TodoOrder7#<=#TodoOrder8#)+([MeasureState9]=2)*(#TodoOrder9#<#TodoOrder8#)+([MeasureState10]=2)*(#TodoOrder10#<#TodoOrder8#)+([MeasureState11]=2)*(#TodoOrder11#<#TodoOrder8#)+([MeasureState12]=2)*(#TodoOrder12#<#TodoOrder8#))=0)) ? 8 : ((([MeasureState9]=2)*((([MeasureState1]=2)*(#TodoOrder1#<=#TodoOrder9#)+([MeasureState2]=2)*(#TodoOrder2#<=#TodoOrder9#)+([MeasureState3]=2)*(#TodoOrder3#<=#TodoOrder9#)+([MeasureState4]=2)*(#TodoOrder4#<=#TodoOrder9#)+([MeasureState5]=2)*(#TodoOrder5#<=#TodoOrder9#)+([MeasureState6]=2)*(#TodoOrder6#<=#TodoOrder9#)+([MeasureState7]=2)*(#TodoOrder7#<=#TodoOrder9#)+([MeasureState8]=2)*(#TodoOrder8#<=#TodoOrder9#)+([MeasureState10]=2)*(#TodoOrder10#<#TodoOrder9#)+([MeasureState11]=2)*(#TodoOrder11#<#TodoOrder9#)+([MeasureState12]=2)*(#TodoOrder12#<#TodoOrder9#))=0)) ? 9 : ((([MeasureState10]=2)*((([MeasureState1]=2)*(#TodoOrder1#<=#TodoOrder10#)+([MeasureState2]=2)*(#TodoOrder2#<=#TodoOrder10#)+([MeasureState3]=2)*(#TodoOrder3#<=#TodoOrder10#)+([MeasureState4]=2)*(#TodoOrder4#<=#TodoOrder10#)+([MeasureState5]=2)*(#TodoOrder5#<=#TodoOrder10#)+([MeasureState6]=2)*(#TodoOrder6#<=#TodoOrder10#)+([MeasureState7]=2)*(#TodoOrder7#<=#TodoOrder10#)+([MeasureState8]=2)*(#TodoOrder8#<=#TodoOrder10#)+([MeasureState9]=2)*(#TodoOrder9#<=#TodoOrder10#)+([MeasureState11]=2)*(#TodoOrder11#<#TodoOrder10#)+([MeasureState12]=2)*(#TodoOrder12#<#TodoOrder10#))=0)) ? 10 : ((([MeasureState11]=2)*((([MeasureState1]=2)*(#TodoOrder1#<=#TodoOrder11#)+([MeasureState2]=2)*(#TodoOrder2#<=#TodoOrder11#)+([MeasureState3]=2)*(#TodoOrder3#<=#TodoOrder11#)+([MeasureState4]=2)*(#TodoOrder4#<=#TodoOrder11#)+([MeasureState5]=2)*(#TodoOrder5#<=#TodoOrder11#)+([MeasureState6]=2)*(#TodoOrder6#<=#TodoOrder11#)+([MeasureState7]=2)*(#TodoOrder7#<=#TodoOrder11#)+([MeasureState8]=2)*(#TodoOrder8#<=#TodoOrder11#)+([MeasureState9]=2)*(#TodoOrder9#<=#TodoOrder11#)+([MeasureState10]=2)*(#TodoOrder10#<=#TodoOrder11#)+([MeasureState12]=2)*(#TodoOrder12#<#TodoOrder11#))=0)) ? 11 : ((([MeasureState12]=2)*((([MeasureState1]=2)*(#TodoOrder1#<=#TodoOrder12#)+([MeasureState2]=2)*(#TodoOrder2#<=#TodoOrder12#)+([MeasureState3]=2)*(#TodoOrder3#<=#TodoOrder12#)+([MeasureState4]=2)*(#TodoOrder4#<=#TodoOrder12#)+([MeasureState5]=2)*(#TodoOrder5#<=#TodoOrder12#)+([MeasureState6]=2)*(#TodoOrder6#<=#TodoOrder12#)+([MeasureState7]=2)*(#TodoOrder7#<=#TodoOrder12#)+([MeasureState8]=2)*(#TodoOrder8#<=#TodoOrder12#)+([MeasureState9]=2)*(#TodoOrder9#<=#TodoOrder12#)+([MeasureState10]=2)*(#TodoOrder10#<=#TodoOrder12#)+([MeasureState11]=2)*(#TodoOrder11#<=#TodoOrder12#))=0)) ? 12 : (0))))))))))))
DynamicVariables=1
UpdateDivider=-1
Group=List

[MeasureFree]
; where a new item goes: the first empty slot, else the oldest done item's slot (it makes room), else 0
Measure=Calc
Formula=([MeasureState1]=0) ? 1 : (([MeasureState2]=0) ? 2 : (([MeasureState3]=0) ? 3 : (([MeasureState4]=0) ? 4 : (([MeasureState5]=0) ? 5 : (([MeasureState6]=0) ? 6 : (([MeasureState7]=0) ? 7 : (([MeasureState8]=0) ? 8 : (([MeasureState9]=0) ? 9 : (([MeasureState10]=0) ? 10 : (([MeasureState11]=0) ? 11 : (([MeasureState12]=0) ? 12 : (MeasureOldestDone))))))))))))
DynamicVariables=1
UpdateDivider=-1
Group=List

[MeasureFull]
; 12 open items: New Item gives way to "List Full"
Measure=Calc
Formula=MeasureFree = 0
UpdateDivider=-1
Group=List

[MeasureEmptyKind]
; nothing shown, so a message: 1 "Nothing to do", 2 "All done" (only completed items, hidden)
Measure=Calc
Formula=(MeasureShown = 0) * (1 + (MeasureDone > 0))
UpdateDivider=-1
Group=List

[MeasureAtEnd]
; 1 when the window shows the last rows ("+N more" then goes back to the top)
Measure=Calc
Formula=MeasureOffset >= MeasureMaxOffset
UpdateDivider=-1
Group=List

[MeasureRelayoutIfIdle]
; #Relayout#, unless an edit box is open: rows must not move under it. A check's delayed relayout, the pointer
; leaving and scrolling come through here; the edit's own end (the commands, OnDismissAction) relayouts anyway.
Measure=Calc
Formula=(#Editing# + #Adding#) = 0
IfCondition=MeasureRelayoutIfIdle = 1
IfTrueAction=#Relayout#
IfConditionMode=1
DynamicVariables=1
UpdateDivider=-1
