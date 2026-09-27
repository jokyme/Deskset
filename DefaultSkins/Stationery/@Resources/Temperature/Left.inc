; Stationery · Temperature — the left column's two rows (11 pt), under the hero: the Small's fans and power, the
; Medium's GPU and SSD temperatures, or the next candidates this Mac has (Measures.inc). Original work, MIT licensed.
; Included from [MeterCard] after Top.inc. The size sets which slots it shows: SlotA, SlotB and SlotRows (the number
; of rows, 1 or 2). With two rows they sit on baselines 133 and 151; one row takes the last baseline, 151.

[MeterRowASymbol]
Meter=Image
MeterStyle=sSymbolS
ImageName=sf:[#Sym[&Measure#SlotA#:0]]
ImageTint=[#Tint[&Measure#SlotA#:0]]
W=[#SymW[&Measure#SlotA#:0]]
H=[#SymH[&Measure#SlotA#:0]]
X=(26 - [#SymW[&Measure#SlotA#:0]] / 2)
Y=((([&Measure#SlotRows#:0] >= 2) ? 133 : 151) - #CapHeight11# / 2 - [#SymH[&Measure#SlotA#:0]] / 2)
Hidden=(([&Measure#SlotA#:0] = 0) || ([&MeasureNotice:] = 1))
DynamicVariables=1
UpdateDivider=-1
Group=Rows

[MeterRowALabel]
Meter=String
MeterStyle=sCaption
Text=[#Label[&Measure#SlotA#:0]]
X=41
Y=((([&Measure#SlotRows#:0] >= 2) ? 133 : 151) - #Ascent11#)
W=54
ClipString=1
Hidden=(([&Measure#SlotA#:0] = 0) || ([&MeasureNotice:] = 1))
DynamicVariables=1
UpdateDivider=-1
Group=Rows

[MeterRowAValue]
Meter=String
MeterStyle=sValueS | sUnit | sMissing
Text=[&Measure[#Key[&Measure#SlotA#:0]]]
StringAlign=Right
X=154
Y=((([&Measure#SlotRows#:0] >= 2) ? 133 : 151) - #Ascent11#)
Hidden=(([&Measure#SlotA#:0] = 0) || ([&MeasureNotice:] = 1))
DynamicVariables=1
Group=Readings | Rows

[MeterRowBSymbol]
Meter=Image
MeterStyle=sSymbolS
ImageName=sf:[#Sym[&Measure#SlotB#:0]]
ImageTint=[#Tint[&Measure#SlotB#:0]]
W=[#SymW[&Measure#SlotB#:0]]
H=[#SymH[&Measure#SlotB#:0]]
X=(26 - [#SymW[&Measure#SlotB#:0]] / 2)
Y=(151 - #CapHeight11# / 2 - [#SymH[&Measure#SlotB#:0]] / 2)
Hidden=(([&Measure#SlotB#:0] = 0) || ([&MeasureNotice:] = 1))
DynamicVariables=1
UpdateDivider=-1
Group=Rows

[MeterRowBLabel]
Meter=String
MeterStyle=sCaption
Text=[#Label[&Measure#SlotB#:0]]
X=41
Y=(151 - #Ascent11#)
W=54
ClipString=1
Hidden=(([&Measure#SlotB#:0] = 0) || ([&MeasureNotice:] = 1))
DynamicVariables=1
UpdateDivider=-1
Group=Rows

[MeterRowBValue]
Meter=String
MeterStyle=sValueS | sUnit | sMissing
Text=[&Measure[#Key[&Measure#SlotB#:0]]]
StringAlign=Right
X=154
Y=(151 - #Ascent11#)
Hidden=(([&Measure#SlotB#:0] = 0) || ([&MeasureNotice:] = 1))
DynamicVariables=1
Group=Readings | Rows
