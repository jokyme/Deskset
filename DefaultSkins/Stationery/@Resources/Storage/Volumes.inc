; Stationery · Storage — the logic every size shares: which volumes the card shows, their space as Finder writes it,
; their colours and sentences, and the Trash's text. Original work, MIT licensed.
;
; Slot 1 is the startup disk. Slots 2–4 are the other mounted volumes in name order (the list leaves out the startup
; disk's own link in /Volumes, Time Machine's snapshot mounts and empty indexes, and closes the gaps). Until Deskset
; can tell internal from external disks, every volume in /Volumes counts as external and ejectable. Each size says
; how many slots it shows (StorageSlots: 0 Small, 2 Medium, 4 Large) and whether it has the Trash
; (StorageShowsTrash).

[Variables]
; FileView's FinishAction (and the demo's first update): the list's logic, then the paths, then the space
VolumesRead=[!SetVariable ListReady 1][!UpdateMeasureGroup VolumeList][!UpdateMeasureGroup SlotPaths][!UpdateMeasureGroup Volumes][!UpdateMeterGroup Volumes][!Redraw]
ListReady=0
Keep1=0
Keep2=0
Keep3=0
Keep4=0
Keep5=0
Keep6=0
Keep7=0
Keep8=0
Cur1=0
Cur2=0
Cur3=0
Cur4=0
Cur5=0
Cur6=0
Cur7=0
Cur8=0
; the volumes' colours in order: the storage colour, then Blue, Teal and Indigo (white in the Clear look, like every
; data colour); a volume 95 % full or more turns red (CriticalColor, its percentage CriticalTextColor)
VolumeColor1=#StorageColor#
VolumeHueRegular2=#Blue#
VolumeHueRegular3=#Teal#
VolumeHueRegular4=#Indigo#
VolumeHueClear2=255,255,255
VolumeHueClear3=255,255,255
VolumeHueClear4=255,255,255
VolumeColor2=[#VolumeHue[#Glass]2]
VolumeColor3=[#VolumeHue[#Glass]3]
VolumeColor4=[#VolumeHue[#Glass]4]
Slot1Color=#VolumeColor1#
Slot1PctColor=#TextColor#
Slot2Color=#VolumeColor2#
Slot2PctColor=#TextColor#
Slot3Color=#VolumeColor3#
Slot3PctColor=#TextColor#
Slot4Color=#VolumeColor4#
Slot4PctColor=#TextColor#
; hover: a volume's pad (and its eject button, when it can be ejected), the eject button's disc, the Trash row's pad
Slot1Hover=0
Slot1PadColor=0,0,0,1
Slot1Ejectable=0
Slot2Hover=0
Slot2PadColor=0,0,0,1
Slot2Ejectable=1
Slot3Hover=0
Slot3PadColor=0,0,0,1
Slot3Ejectable=1
Slot4Hover=0
Slot4PadColor=0,0,0,1
Slot4Ejectable=1
Slot2EjectFill=#HoverColor#
Slot3EjectFill=#HoverColor#
Slot4EjectFill=#HoverColor#
TrashPadColor=0,0,0,1
; the Small: its colours (as the slots'), and its link back to the startup disk when its volume is not connected
SmallColor=#StorageColor#
SmallPctColor=#TertiaryTextColor#
SmallShowStartup=[!WriteKeyValue Variables StorageSmallVolume "" "#@#Variables.inc"][!WriteKeyValue Variables StorageSmallVolumeName "" "#@#Variables.inc"][!Refresh]
; an eject that fails (the volume is in use): the volume's line says so for 5 s
EjectFailed2=[!SetOption MeterSlot2Caption Text "#StorageEjectFailed#"][!UpdateMeter MeterSlot2Caption][!Redraw][!Delay 5000][!SetOption MeterSlot2Caption Text "%1"][!UpdateMeter MeterSlot2Caption][!Redraw]
EjectFailed3=[!SetOption MeterSlot3Caption Text "#StorageEjectFailed#"][!UpdateMeter MeterSlot3Caption][!Redraw][!Delay 5000][!SetOption MeterSlot3Caption Text "%1"][!UpdateMeter MeterSlot3Caption][!Redraw]
EjectFailed4=[!SetOption MeterSlot4Caption Text "#StorageEjectFailed#"][!UpdateMeter MeterSlot4Caption][!Redraw][!Delay 5000][!SetOption MeterSlot4Caption Text "%1"][!UpdateMeter MeterSlot4Caption][!Redraw]

; ---------------------------------------------------------------- the list
; Keep<i> is 1 for an entry the card shows. Cur<i> is 1 for the Small's chosen volume. The entries come before the
; Calcs that read Keep<i>: !SetVariable takes effect at once, and DynamicVariables reads it again in file order.

[MeasureEntry1]
Measure=String
String=[MeasureEntry1Name]
DynamicVariables=1
UpdateDivider=-1
Group=VolumeList
IfMatch=^(?:\Q[MeasureSlot1Label]\E|com\.apple\..*|)$
IfMatchAction=[!SetVariable Keep1 0]
IfNotMatchAction=[!SetVariable Keep1 1]
IfMatch2=^\Q#StorageSmallVolume#\E$
IfMatchAction2=[!SetVariable Cur1 1]
IfNotMatchAction2=[!SetVariable Cur1 0]

[MeasureEntry2]
Measure=String
String=[MeasureEntry2Name]
DynamicVariables=1
UpdateDivider=-1
Group=VolumeList
IfMatch=^(?:\Q[MeasureSlot1Label]\E|com\.apple\..*|)$
IfMatchAction=[!SetVariable Keep2 0]
IfNotMatchAction=[!SetVariable Keep2 1]
IfMatch2=^\Q#StorageSmallVolume#\E$
IfMatchAction2=[!SetVariable Cur2 1]
IfNotMatchAction2=[!SetVariable Cur2 0]

[MeasureEntry3]
Measure=String
String=[MeasureEntry3Name]
DynamicVariables=1
UpdateDivider=-1
Group=VolumeList
IfMatch=^(?:\Q[MeasureSlot1Label]\E|com\.apple\..*|)$
IfMatchAction=[!SetVariable Keep3 0]
IfNotMatchAction=[!SetVariable Keep3 1]
IfMatch2=^\Q#StorageSmallVolume#\E$
IfMatchAction2=[!SetVariable Cur3 1]
IfNotMatchAction2=[!SetVariable Cur3 0]

[MeasureEntry4]
Measure=String
String=[MeasureEntry4Name]
DynamicVariables=1
UpdateDivider=-1
Group=VolumeList
IfMatch=^(?:\Q[MeasureSlot1Label]\E|com\.apple\..*|)$
IfMatchAction=[!SetVariable Keep4 0]
IfNotMatchAction=[!SetVariable Keep4 1]
IfMatch2=^\Q#StorageSmallVolume#\E$
IfMatchAction2=[!SetVariable Cur4 1]
IfNotMatchAction2=[!SetVariable Cur4 0]

[MeasureEntry5]
Measure=String
String=[MeasureEntry5Name]
DynamicVariables=1
UpdateDivider=-1
Group=VolumeList
IfMatch=^(?:\Q[MeasureSlot1Label]\E|com\.apple\..*|)$
IfMatchAction=[!SetVariable Keep5 0]
IfNotMatchAction=[!SetVariable Keep5 1]
IfMatch2=^\Q#StorageSmallVolume#\E$
IfMatchAction2=[!SetVariable Cur5 1]
IfNotMatchAction2=[!SetVariable Cur5 0]

[MeasureEntry6]
Measure=String
String=[MeasureEntry6Name]
DynamicVariables=1
UpdateDivider=-1
Group=VolumeList
IfMatch=^(?:\Q[MeasureSlot1Label]\E|com\.apple\..*|)$
IfMatchAction=[!SetVariable Keep6 0]
IfNotMatchAction=[!SetVariable Keep6 1]
IfMatch2=^\Q#StorageSmallVolume#\E$
IfMatchAction2=[!SetVariable Cur6 1]
IfNotMatchAction2=[!SetVariable Cur6 0]

[MeasureEntry7]
Measure=String
String=[MeasureEntry7Name]
DynamicVariables=1
UpdateDivider=-1
Group=VolumeList
IfMatch=^(?:\Q[MeasureSlot1Label]\E|com\.apple\..*|)$
IfMatchAction=[!SetVariable Keep7 0]
IfNotMatchAction=[!SetVariable Keep7 1]
IfMatch2=^\Q#StorageSmallVolume#\E$
IfMatchAction2=[!SetVariable Cur7 1]
IfNotMatchAction2=[!SetVariable Cur7 0]

[MeasureEntry8]
Measure=String
String=[MeasureEntry8Name]
DynamicVariables=1
UpdateDivider=-1
Group=VolumeList
IfMatch=^(?:\Q[MeasureSlot1Label]\E|com\.apple\..*|)$
IfMatchAction=[!SetVariable Keep8 0]
IfNotMatchAction=[!SetVariable Keep8 1]
IfMatch2=^\Q#StorageSmallVolume#\E$
IfMatchAction2=[!SetVariable Cur8 1]
IfNotMatchAction2=[!SetVariable Cur8 0]

[MeasureOtherCount]
; the mounted volumes besides the startup disk
Measure=Calc
Formula=#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#+#Keep6#+#Keep7#+#Keep8#
DynamicVariables=1
UpdateDivider=-1
Group=VolumeList

[MeasureSlot2Index]
; the index of the 1st kept entry, 0 when there is none: Σ i · Keep_i · (Keep_1 + … + Keep_i = 1).
; An empty slot is hidden (FileView reads entry 1 for an index of 0), and one that empties under the pointer drops its
; hover
Measure=Calc
Formula=1*#Keep1#*((#Keep1#) = 1) + 2*#Keep2#*((#Keep1#+#Keep2#) = 1) + 3*#Keep3#*((#Keep1#+#Keep2#+#Keep3#) = 1) + 4*#Keep4#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#) = 1) + 5*#Keep5#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#) = 1) + 6*#Keep6#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#+#Keep6#) = 1) + 7*#Keep7#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#+#Keep6#+#Keep7#) = 1) + 8*#Keep8#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#+#Keep6#+#Keep7#+#Keep8#) = 1)
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# < 2)
Group=VolumeList
IfCondition=MeasureSlot2Index = 0
IfTrueAction=[!HideMeterGroup Slot2][!SetVariable Slot2Hover 0][!SetVariable Slot2PadColor "0,0,0,1"][!UpdateMeterGroup Eject2]
IfFalseAction=[!ShowMeterGroup Slot2]

[MeasureSlot3Index]
; the index of the 2nd kept entry, 0 when there is none: Σ i · Keep_i · (Keep_1 + … + Keep_i = 2).
; An empty slot is hidden (FileView reads entry 1 for an index of 0), and one that empties under the pointer drops its
; hover
Measure=Calc
Formula=1*#Keep1#*((#Keep1#) = 2) + 2*#Keep2#*((#Keep1#+#Keep2#) = 2) + 3*#Keep3#*((#Keep1#+#Keep2#+#Keep3#) = 2) + 4*#Keep4#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#) = 2) + 5*#Keep5#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#) = 2) + 6*#Keep6#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#+#Keep6#) = 2) + 7*#Keep7#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#+#Keep6#+#Keep7#) = 2) + 8*#Keep8#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#+#Keep6#+#Keep7#+#Keep8#) = 2)
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# < 3)
Group=VolumeList
IfCondition=MeasureSlot3Index = 0
IfTrueAction=[!HideMeterGroup Slot3][!SetVariable Slot3Hover 0][!SetVariable Slot3PadColor "0,0,0,1"][!UpdateMeterGroup Eject3]
IfFalseAction=[!ShowMeterGroup Slot3]

[MeasureSlot4Index]
; the index of the 3rd kept entry, 0 when there is none: Σ i · Keep_i · (Keep_1 + … + Keep_i = 3).
; An empty slot is hidden (FileView reads entry 1 for an index of 0), and one that empties under the pointer drops its
; hover
Measure=Calc
Formula=1*#Keep1#*((#Keep1#) = 3) + 2*#Keep2#*((#Keep1#+#Keep2#) = 3) + 3*#Keep3#*((#Keep1#+#Keep2#+#Keep3#) = 3) + 4*#Keep4#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#) = 3) + 5*#Keep5#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#) = 3) + 6*#Keep6#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#+#Keep6#) = 3) + 7*#Keep7#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#+#Keep6#+#Keep7#) = 3) + 8*#Keep8#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#+#Keep6#+#Keep7#+#Keep8#) = 3)
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# < 4)
Group=VolumeList
IfCondition=MeasureSlot4Index = 0
IfTrueAction=[!HideMeterGroup Slot4][!SetVariable Slot4Hover 0][!SetVariable Slot4PadColor "0,0,0,1"][!UpdateMeterGroup Eject4]
IfFalseAction=[!ShowMeterGroup Slot4]

[MeasureTrashRow]
; the Medium with the startup disk alone shows the Trash in the second volume's place
Measure=Calc
Formula=#ListReady# * (MeasureOtherCount = 0)
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# <> 2)
Group=VolumeList
IfCondition=MeasureTrashRow = 1
IfTrueAction=[!SetVariable TrashRowHidden 0][!UpdateMeterGroup Trash][!Redraw]
IfFalseAction=[!SetVariable TrashRowHidden 1][!UpdateMeterGroup Trash][!Redraw]

[MeasureMore]
; volumes the card has no room for: "+2 more" in the header
Measure=Calc
Formula=MeasureOtherCount - (#StorageSlots# - 1)
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# = 0)
Group=VolumeList

[MeasureMoreText]
Measure=String
String=[MeasureMore:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^(0|-\d+)$":"","^(\d+)$":"#StorageMore#","%1":"[MeasureMore:0]"
UpdateDivider=-1
Disabled=(#StorageSlots# = 0)
Group=VolumeList

[MeasureMoreSentence]
Measure=String
String=[MeasureMore:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^(0|-\d+)$":"","^1$":"#StorageTipMore1#","^(\d+)$":"#StorageTipMoreN#","\{n\}":"[MeasureMore:0]"
UpdateDivider=-1
Disabled=(#StorageSlots# = 0)
Group=VolumeList

; ---------------------------------------------------------------- the Small's volume and its menu item
[MeasureSmallPath]
; "/" for the startup disk, "/Volumes/<name>" for another volume. The name is the user's, so it goes in String=,
; which is taken literally
Measure=String
String=#StorageSmallVolume#
RegExpSubstitute=1
Substitute="^(.+)$":"/Volumes/\1","^$":"/"
UpdateDivider=-1
Disabled=(#StorageSlots# > 0)

[MeasureSmallIndex]
; the chosen volume's entry, 0 for the startup disk (or when it is not in the list)
Measure=Calc
Formula=1*#Keep1#*#Cur1# + 2*#Keep2#*#Cur2# + 3*#Keep3#*#Cur3# + 4*#Keep4#*#Cur4# + 5*#Keep5#*#Cur5# + 6*#Keep6#*#Cur6# + 7*#Keep7#*#Cur7# + 8*#Keep8#*#Cur8#
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# > 0)
Group=VolumeList

[MeasureSmallRank]
; the chosen volume's place among the kept entries (0: the startup disk)
Measure=Calc
Formula=#Keep1#*#Cur1#*(#Keep1#) + #Keep2#*#Cur2#*(#Keep1#+#Keep2#) + #Keep3#*#Cur3#*(#Keep1#+#Keep2#+#Keep3#) + #Keep4#*#Cur4#*(#Keep1#+#Keep2#+#Keep3#+#Keep4#) + #Keep5#*#Cur5#*(#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#) + #Keep6#*#Cur6#*(#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#+#Keep6#) + #Keep7#*#Cur7#*(#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#+#Keep6#+#Keep7#) + #Keep8#*#Cur8#*(#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#+#Keep6#+#Keep7#+#Keep8#)
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# > 0)
Group=VolumeList

[MeasureSmallNextRank]
; "Volume: …" moves on to the next volume, and from the last one back to the startup disk
Measure=Calc
Formula=(MeasureSmallRank + 1) % (MeasureOtherCount + 1)
UpdateDivider=-1
Disabled=(#StorageSlots# > 0)
Group=VolumeList

[MeasureSmallNextIndex]
Measure=Calc
Formula=1*#Keep1#*((#Keep1#) = MeasureSmallNextRank) + 2*#Keep2#*((#Keep1#+#Keep2#) = MeasureSmallNextRank) + 3*#Keep3#*((#Keep1#+#Keep2#+#Keep3#) = MeasureSmallNextRank) + 4*#Keep4#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#) = MeasureSmallNextRank) + 5*#Keep5#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#) = MeasureSmallNextRank) + 6*#Keep6#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#+#Keep6#) = MeasureSmallNextRank) + 7*#Keep7#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#+#Keep6#+#Keep7#) = MeasureSmallNextRank) + 8*#Keep8#*((#Keep1#+#Keep2#+#Keep3#+#Keep4#+#Keep5#+#Keep6#+#Keep7#+#Keep8#) = MeasureSmallNextRank)
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# > 0)
Group=VolumeList

[MeasureSmallNextName]
; the next volume's folder name, empty for the startup disk
Measure=String
String=[MeasureSmallNextIndex:0]|[MeasureSmallNextEntry]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^0\|.*$":"","^\d+\|":""
UpdateDivider=-1
Disabled=(#StorageSlots# > 0)
Group=SlotPaths

[MeasureSmallNextPath]
Measure=String
String=[MeasureSmallNextName]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^(.+)$":"/Volumes/\1","^$":"/"
UpdateDivider=-1
Disabled=(#StorageSlots# > 0)
Group=SlotPaths

[MeasureSmallNameCheck]
; the menu item names the startup disk as it is called now when no volume was chosen
Measure=String
String=#StorageSmallVolumeName#
UpdateDivider=-1
Disabled=(#StorageSlots# > 0)
IfMatch=^$
IfMatchAction=[!SetVariable StorageSmallVolumeName "[MeasureSlot1Label]"]

; ---------------------------------------------------------------- each volume's space, colours and words

[MeasureSlot1Used]
; whole percent used, as shown; -1 while Finder's figure is not in (loading). Three exclusive states, applied at
; every update, so no colour sticks after loading; the level rule reads the number the user reads, so "95%" is red
Measure=Calc
Formula=((MeasureSlot1Total > 0) && (MeasureSlot1Avail >= 0)) ? Round((1 - MeasureSlot1Avail / MeasureSlot1Total) * 100) : -1
UpdateDivider=30
Group=Volumes
IfConditionMode=1
IfCondition=MeasureSlot1Used < 0
IfTrueAction=[!SetVariable Slot1Color "#VolumeColor1#"][!SetVariable Slot1PctColor "#TertiaryTextColor#"]
IfCondition2=(MeasureSlot1Used >= 0) && (MeasureSlot1Used < 95)
IfTrueAction2=[!SetVariable Slot1Color "#VolumeColor1#"][!SetVariable Slot1PctColor "#TextColor#"]
IfCondition3=MeasureSlot1Used >= 95
IfTrueAction3=[!SetVariable Slot1Color "#CriticalColor#"][!SetVariable Slot1PctColor "#CriticalTextColor#"]

[MeasureSlot1PctText]
; "88%", or "--%" while loading
Measure=String
String=[MeasureSlot1Used:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^-\d+$":"#Missing#%","^(\d+)$":"\1%"
UpdateDivider=30
Group=Volumes

[MeasureSlot1AvailPower]
Measure=Calc
Formula=Clamp(Floor(Log(Max(MeasureSlot1Avail, 1) / 0.9995) / 3), 0, 4)
UpdateDivider=30
Group=Volumes

[MeasureSlot1AvailScaled]
Measure=Calc
Formula=((MeasureSlot1Avail / 1000 ** MeasureSlot1AvailPower) >= 99.95) ? Round(MeasureSlot1Avail / 1000 ** MeasureSlot1AvailPower) : Round(MeasureSlot1Avail / 1000 ** MeasureSlot1AvailPower, 1)
UpdateDivider=30
Group=Volumes

[MeasureSlot1AvailText]
Measure=String
String=[MeasureSlot1AvailScaled:1] U[MeasureSlot1AvailPower:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^-.*$":"#Missing# GB","\.0(?= U)":""," U0$":" #StorageBytes#"," U1$":" KB"," U2$":" MB"," U3$":" GB"," U4$":" TB"
UpdateDivider=30
Group=Volumes

[MeasureSlot1TotalPower]
Measure=Calc
Formula=Clamp(Floor(Log(Max(MeasureSlot1Total, 1) / 0.9995) / 3), 0, 4)
UpdateDivider=30
Group=Volumes

[MeasureSlot1TotalScaled]
Measure=Calc
Formula=((MeasureSlot1Total / 1000 ** MeasureSlot1TotalPower) >= 99.95) ? Round(MeasureSlot1Total / 1000 ** MeasureSlot1TotalPower) : Round(MeasureSlot1Total / 1000 ** MeasureSlot1TotalPower, 1)
UpdateDivider=30
Group=Volumes

[MeasureSlot1TotalText]
Measure=String
String=[MeasureSlot1TotalScaled:1] U[MeasureSlot1TotalPower:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^-.*$":"#Missing# GB","\.0(?= U)":""," U0$":" #StorageBytes#"," U1$":" KB"," U2$":" MB"," U3$":" GB"," U4$":" TB"
UpdateDivider=30
Group=Volumes

[MeasureSlot1Caption]
; "118 GB available of 995 GB"
Measure=String
String=#StorageCaption#
Substitute="%1":"[MeasureSlot1AvailText]","%2":"[MeasureSlot1TotalText]"
DynamicVariables=1
UpdateDivider=30
Group=Volumes

[MeasureSlot1Tip]
; the volume's tooltip: "118 GB available of 995 GB (88% used)."
Measure=String
String=[MeasureSlot1Caption]#StorageTipUsed#
Substitute="{used}":"[MeasureSlot1PctText]"
DynamicVariables=1
UpdateDivider=30
Group=Volumes

[MeasureSlot1Sentence]
; the card's sentence: "Macintosh HD: 118 GB available of 995 GB (88% used)."
Measure=String
String=[MeasureSlot1Label]#StorageTipNameSep#[MeasureSlot1Tip]
DynamicVariables=1
UpdateDivider=30
Group=Volumes

[MeasureSlot2Used]
; whole percent used, as shown; -1 while Finder's figure is not in (loading). Three exclusive states, applied at
; every update, so no colour sticks after loading; the level rule reads the number the user reads, so "95%" is red
Measure=Calc
Formula=((MeasureSlot2Total > 0) && (MeasureSlot2Avail >= 0)) ? Round((1 - MeasureSlot2Avail / MeasureSlot2Total) * 100) : -1
UpdateDivider=30
Disabled=(#StorageSlots# < 2)
Group=Volumes
IfConditionMode=1
IfCondition=MeasureSlot2Used < 0
IfTrueAction=[!SetVariable Slot2Color "#VolumeColor2#"][!SetVariable Slot2PctColor "#TertiaryTextColor#"]
IfCondition2=(MeasureSlot2Used >= 0) && (MeasureSlot2Used < 95)
IfTrueAction2=[!SetVariable Slot2Color "#VolumeColor2#"][!SetVariable Slot2PctColor "#TextColor#"]
IfCondition3=MeasureSlot2Used >= 95
IfTrueAction3=[!SetVariable Slot2Color "#CriticalColor#"][!SetVariable Slot2PctColor "#CriticalTextColor#"]

[MeasureSlot2PctText]
; "88%", or "--%" while loading
Measure=String
String=[MeasureSlot2Used:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^-\d+$":"#Missing#%","^(\d+)$":"\1%"
UpdateDivider=30
Disabled=(#StorageSlots# < 2)
Group=Volumes

[MeasureSlot2AvailPower]
Measure=Calc
Formula=Clamp(Floor(Log(Max(MeasureSlot2Avail, 1) / 0.9995) / 3), 0, 4)
UpdateDivider=30
Disabled=(#StorageSlots# < 2)
Group=Volumes

[MeasureSlot2AvailScaled]
Measure=Calc
Formula=((MeasureSlot2Avail / 1000 ** MeasureSlot2AvailPower) >= 99.95) ? Round(MeasureSlot2Avail / 1000 ** MeasureSlot2AvailPower) : Round(MeasureSlot2Avail / 1000 ** MeasureSlot2AvailPower, 1)
UpdateDivider=30
Disabled=(#StorageSlots# < 2)
Group=Volumes

[MeasureSlot2AvailText]
Measure=String
String=[MeasureSlot2AvailScaled:1] U[MeasureSlot2AvailPower:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^-.*$":"#Missing# GB","\.0(?= U)":""," U0$":" #StorageBytes#"," U1$":" KB"," U2$":" MB"," U3$":" GB"," U4$":" TB"
UpdateDivider=30
Disabled=(#StorageSlots# < 2)
Group=Volumes

[MeasureSlot2TotalPower]
Measure=Calc
Formula=Clamp(Floor(Log(Max(MeasureSlot2Total, 1) / 0.9995) / 3), 0, 4)
UpdateDivider=30
Disabled=(#StorageSlots# < 2)
Group=Volumes

[MeasureSlot2TotalScaled]
Measure=Calc
Formula=((MeasureSlot2Total / 1000 ** MeasureSlot2TotalPower) >= 99.95) ? Round(MeasureSlot2Total / 1000 ** MeasureSlot2TotalPower) : Round(MeasureSlot2Total / 1000 ** MeasureSlot2TotalPower, 1)
UpdateDivider=30
Disabled=(#StorageSlots# < 2)
Group=Volumes

[MeasureSlot2TotalText]
Measure=String
String=[MeasureSlot2TotalScaled:1] U[MeasureSlot2TotalPower:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^-.*$":"#Missing# GB","\.0(?= U)":""," U0$":" #StorageBytes#"," U1$":" KB"," U2$":" MB"," U3$":" GB"," U4$":" TB"
UpdateDivider=30
Disabled=(#StorageSlots# < 2)
Group=Volumes

[MeasureSlot2Caption]
; "118 GB available of 995 GB"
Measure=String
String=#StorageCaption#
Substitute="%1":"[MeasureSlot2AvailText]","%2":"[MeasureSlot2TotalText]"
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 2)
Group=Volumes

[MeasureSlot2Tip]
; the volume's tooltip: "118 GB available of 995 GB (88% used)."
Measure=String
String=[MeasureSlot2Caption]#StorageTipUsed#
Substitute="{used}":"[MeasureSlot2PctText]"
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 2)
Group=Volumes

[MeasureSlot2Sentence]
Measure=String
String=[MeasureSlot2Index:0]|[MeasureSlot2Label]#StorageTipNameSep#[MeasureSlot2Tip]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^0\|.*$":"","^\d+\|":"#StorageTipJoin#"
UpdateDivider=30
Disabled=(#StorageSlots# < 2)
Group=Volumes

[MeasureSlot2PathShell]
; the path inside the eject command's double quotes: \ " $ ` escaped, so a volume's name is never read as a command
Measure=String
String=[MeasureSlot2Path]
DynamicVariables=1
Substitute='\':'\\','"':'\"','$':'\$','`':'\`'
UpdateDivider=-1
Disabled=(#StorageSlots# < 2)
Group=SlotPaths

[MeasureEject2Result]
; the eject's outcome, read once per run (only its FinishAction updates it): "in use" shows on the volume's line
Measure=String
String=[MeasureEject2]
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# < 2)
IfMatchMode=1
IfMatch=EJECT_FAILED
IfMatchAction=#EjectFailed2#

[MeasureSlot3Used]
; whole percent used, as shown; -1 while Finder's figure is not in (loading). Three exclusive states, applied at
; every update, so no colour sticks after loading; the level rule reads the number the user reads, so "95%" is red
Measure=Calc
Formula=((MeasureSlot3Total > 0) && (MeasureSlot3Avail >= 0)) ? Round((1 - MeasureSlot3Avail / MeasureSlot3Total) * 100) : -1
UpdateDivider=30
Disabled=(#StorageSlots# < 3)
Group=Volumes
IfConditionMode=1
IfCondition=MeasureSlot3Used < 0
IfTrueAction=[!SetVariable Slot3Color "#VolumeColor3#"][!SetVariable Slot3PctColor "#TertiaryTextColor#"]
IfCondition2=(MeasureSlot3Used >= 0) && (MeasureSlot3Used < 95)
IfTrueAction2=[!SetVariable Slot3Color "#VolumeColor3#"][!SetVariable Slot3PctColor "#TextColor#"]
IfCondition3=MeasureSlot3Used >= 95
IfTrueAction3=[!SetVariable Slot3Color "#CriticalColor#"][!SetVariable Slot3PctColor "#CriticalTextColor#"]

[MeasureSlot3PctText]
; "88%", or "--%" while loading
Measure=String
String=[MeasureSlot3Used:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^-\d+$":"#Missing#%","^(\d+)$":"\1%"
UpdateDivider=30
Disabled=(#StorageSlots# < 3)
Group=Volumes

[MeasureSlot3AvailPower]
Measure=Calc
Formula=Clamp(Floor(Log(Max(MeasureSlot3Avail, 1) / 0.9995) / 3), 0, 4)
UpdateDivider=30
Disabled=(#StorageSlots# < 3)
Group=Volumes

[MeasureSlot3AvailScaled]
Measure=Calc
Formula=((MeasureSlot3Avail / 1000 ** MeasureSlot3AvailPower) >= 99.95) ? Round(MeasureSlot3Avail / 1000 ** MeasureSlot3AvailPower) : Round(MeasureSlot3Avail / 1000 ** MeasureSlot3AvailPower, 1)
UpdateDivider=30
Disabled=(#StorageSlots# < 3)
Group=Volumes

[MeasureSlot3AvailText]
Measure=String
String=[MeasureSlot3AvailScaled:1] U[MeasureSlot3AvailPower:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^-.*$":"#Missing# GB","\.0(?= U)":""," U0$":" #StorageBytes#"," U1$":" KB"," U2$":" MB"," U3$":" GB"," U4$":" TB"
UpdateDivider=30
Disabled=(#StorageSlots# < 3)
Group=Volumes

[MeasureSlot3TotalPower]
Measure=Calc
Formula=Clamp(Floor(Log(Max(MeasureSlot3Total, 1) / 0.9995) / 3), 0, 4)
UpdateDivider=30
Disabled=(#StorageSlots# < 3)
Group=Volumes

[MeasureSlot3TotalScaled]
Measure=Calc
Formula=((MeasureSlot3Total / 1000 ** MeasureSlot3TotalPower) >= 99.95) ? Round(MeasureSlot3Total / 1000 ** MeasureSlot3TotalPower) : Round(MeasureSlot3Total / 1000 ** MeasureSlot3TotalPower, 1)
UpdateDivider=30
Disabled=(#StorageSlots# < 3)
Group=Volumes

[MeasureSlot3TotalText]
Measure=String
String=[MeasureSlot3TotalScaled:1] U[MeasureSlot3TotalPower:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^-.*$":"#Missing# GB","\.0(?= U)":""," U0$":" #StorageBytes#"," U1$":" KB"," U2$":" MB"," U3$":" GB"," U4$":" TB"
UpdateDivider=30
Disabled=(#StorageSlots# < 3)
Group=Volumes

[MeasureSlot3Caption]
; "118 GB available of 995 GB"
Measure=String
String=#StorageCaption#
Substitute="%1":"[MeasureSlot3AvailText]","%2":"[MeasureSlot3TotalText]"
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 3)
Group=Volumes

[MeasureSlot3Tip]
; the volume's tooltip: "118 GB available of 995 GB (88% used)."
Measure=String
String=[MeasureSlot3Caption]#StorageTipUsed#
Substitute="{used}":"[MeasureSlot3PctText]"
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 3)
Group=Volumes

[MeasureSlot3Sentence]
Measure=String
String=[MeasureSlot3Index:0]|[MeasureSlot3Label]#StorageTipNameSep#[MeasureSlot3Tip]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^0\|.*$":"","^\d+\|":"#StorageTipJoin#"
UpdateDivider=30
Disabled=(#StorageSlots# < 3)
Group=Volumes

[MeasureSlot3PathShell]
; the path inside the eject command's double quotes: \ " $ ` escaped, so a volume's name is never read as a command
Measure=String
String=[MeasureSlot3Path]
DynamicVariables=1
Substitute='\':'\\','"':'\"','$':'\$','`':'\`'
UpdateDivider=-1
Disabled=(#StorageSlots# < 3)
Group=SlotPaths

[MeasureEject3Result]
; the eject's outcome, read once per run (only its FinishAction updates it): "in use" shows on the volume's line
Measure=String
String=[MeasureEject3]
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# < 3)
IfMatchMode=1
IfMatch=EJECT_FAILED
IfMatchAction=#EjectFailed3#

[MeasureSlot4Used]
; whole percent used, as shown; -1 while Finder's figure is not in (loading). Three exclusive states, applied at
; every update, so no colour sticks after loading; the level rule reads the number the user reads, so "95%" is red
Measure=Calc
Formula=((MeasureSlot4Total > 0) && (MeasureSlot4Avail >= 0)) ? Round((1 - MeasureSlot4Avail / MeasureSlot4Total) * 100) : -1
UpdateDivider=30
Disabled=(#StorageSlots# < 4)
Group=Volumes
IfConditionMode=1
IfCondition=MeasureSlot4Used < 0
IfTrueAction=[!SetVariable Slot4Color "#VolumeColor4#"][!SetVariable Slot4PctColor "#TertiaryTextColor#"]
IfCondition2=(MeasureSlot4Used >= 0) && (MeasureSlot4Used < 95)
IfTrueAction2=[!SetVariable Slot4Color "#VolumeColor4#"][!SetVariable Slot4PctColor "#TextColor#"]
IfCondition3=MeasureSlot4Used >= 95
IfTrueAction3=[!SetVariable Slot4Color "#CriticalColor#"][!SetVariable Slot4PctColor "#CriticalTextColor#"]

[MeasureSlot4PctText]
; "88%", or "--%" while loading
Measure=String
String=[MeasureSlot4Used:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^-\d+$":"#Missing#%","^(\d+)$":"\1%"
UpdateDivider=30
Disabled=(#StorageSlots# < 4)
Group=Volumes

[MeasureSlot4AvailPower]
Measure=Calc
Formula=Clamp(Floor(Log(Max(MeasureSlot4Avail, 1) / 0.9995) / 3), 0, 4)
UpdateDivider=30
Disabled=(#StorageSlots# < 4)
Group=Volumes

[MeasureSlot4AvailScaled]
Measure=Calc
Formula=((MeasureSlot4Avail / 1000 ** MeasureSlot4AvailPower) >= 99.95) ? Round(MeasureSlot4Avail / 1000 ** MeasureSlot4AvailPower) : Round(MeasureSlot4Avail / 1000 ** MeasureSlot4AvailPower, 1)
UpdateDivider=30
Disabled=(#StorageSlots# < 4)
Group=Volumes

[MeasureSlot4AvailText]
Measure=String
String=[MeasureSlot4AvailScaled:1] U[MeasureSlot4AvailPower:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^-.*$":"#Missing# GB","\.0(?= U)":""," U0$":" #StorageBytes#"," U1$":" KB"," U2$":" MB"," U3$":" GB"," U4$":" TB"
UpdateDivider=30
Disabled=(#StorageSlots# < 4)
Group=Volumes

[MeasureSlot4TotalPower]
Measure=Calc
Formula=Clamp(Floor(Log(Max(MeasureSlot4Total, 1) / 0.9995) / 3), 0, 4)
UpdateDivider=30
Disabled=(#StorageSlots# < 4)
Group=Volumes

[MeasureSlot4TotalScaled]
Measure=Calc
Formula=((MeasureSlot4Total / 1000 ** MeasureSlot4TotalPower) >= 99.95) ? Round(MeasureSlot4Total / 1000 ** MeasureSlot4TotalPower) : Round(MeasureSlot4Total / 1000 ** MeasureSlot4TotalPower, 1)
UpdateDivider=30
Disabled=(#StorageSlots# < 4)
Group=Volumes

[MeasureSlot4TotalText]
Measure=String
String=[MeasureSlot4TotalScaled:1] U[MeasureSlot4TotalPower:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^-.*$":"#Missing# GB","\.0(?= U)":""," U0$":" #StorageBytes#"," U1$":" KB"," U2$":" MB"," U3$":" GB"," U4$":" TB"
UpdateDivider=30
Disabled=(#StorageSlots# < 4)
Group=Volumes

[MeasureSlot4Caption]
; "118 GB available of 995 GB"
Measure=String
String=#StorageCaption#
Substitute="%1":"[MeasureSlot4AvailText]","%2":"[MeasureSlot4TotalText]"
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 4)
Group=Volumes

[MeasureSlot4Tip]
; the volume's tooltip: "118 GB available of 995 GB (88% used)."
Measure=String
String=[MeasureSlot4Caption]#StorageTipUsed#
Substitute="{used}":"[MeasureSlot4PctText]"
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 4)
Group=Volumes

[MeasureSlot4Sentence]
Measure=String
String=[MeasureSlot4Index:0]|[MeasureSlot4Label]#StorageTipNameSep#[MeasureSlot4Tip]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^0\|.*$":"","^\d+\|":"#StorageTipJoin#"
UpdateDivider=30
Disabled=(#StorageSlots# < 4)
Group=Volumes

[MeasureSlot4PathShell]
; the path inside the eject command's double quotes: \ " $ ` escaped, so a volume's name is never read as a command
Measure=String
String=[MeasureSlot4Path]
DynamicVariables=1
Substitute='\':'\\','"':'\"','$':'\$','`':'\`'
UpdateDivider=-1
Disabled=(#StorageSlots# < 4)
Group=SlotPaths

[MeasureEject4Result]
; the eject's outcome, read once per run (only its FinishAction updates it): "in use" shows on the volume's line
Measure=String
String=[MeasureEject4]
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# < 4)
IfMatchMode=1
IfMatch=EJECT_FAILED
IfMatchAction=#EjectFailed4#

; ---------------------------------------------------------------- the Small's volume
[MeasureSmallUsed]
Measure=Calc
Formula=((MeasureSmallTotal > 0) && (MeasureSmallAvail >= 0)) ? Round((1 - MeasureSmallAvail / MeasureSmallTotal) * 100) : -1
UpdateDivider=30
Disabled=(#StorageSlots# > 0)
Group=Volumes
IfConditionMode=1
IfCondition=MeasureSmallUsed < 95
IfTrueAction=[!SetVariable SmallColor "#StorageColor#"][!SetVariable SmallPctColor "#TertiaryTextColor#"]
IfCondition2=MeasureSmallUsed >= 95
IfTrueAction2=[!SetVariable SmallColor "#CriticalColor#"][!SetVariable SmallPctColor "#CriticalTextColor#"]

[MeasureSmallPctText]
Measure=String
String=[MeasureSmallUsed:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^-\d+$":"#Missing#%","^(\d+)$":"\1%"
UpdateDivider=30
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallAvailPower]
Measure=Calc
Formula=Clamp(Floor(Log(Max(MeasureSmallAvail, 1) / 0.9995) / 3), 0, 4)
UpdateDivider=30
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallAvailScaled]
Measure=Calc
Formula=((MeasureSmallAvail / 1000 ** MeasureSmallAvailPower) >= 99.95) ? Round(MeasureSmallAvail / 1000 ** MeasureSmallAvailPower) : Round(MeasureSmallAvail / 1000 ** MeasureSmallAvailPower, 1)
UpdateDivider=30
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallAvailText]
Measure=String
String=[MeasureSmallAvailScaled:1] U[MeasureSmallAvailPower:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^-.*$":"#Missing# GB","\.0(?= U)":""," U0$":" #StorageBytes#"," U1$":" KB"," U2$":" MB"," U3$":" GB"," U4$":" TB"
UpdateDivider=30
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallTotalPower]
Measure=Calc
Formula=Clamp(Floor(Log(Max(MeasureSmallTotal, 1) / 0.9995) / 3), 0, 4)
UpdateDivider=30
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallTotalScaled]
Measure=Calc
Formula=((MeasureSmallTotal / 1000 ** MeasureSmallTotalPower) >= 99.95) ? Round(MeasureSmallTotal / 1000 ** MeasureSmallTotalPower) : Round(MeasureSmallTotal / 1000 ** MeasureSmallTotalPower, 1)
UpdateDivider=30
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallTotalText]
Measure=String
String=[MeasureSmallTotalScaled:1] U[MeasureSmallTotalPower:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^-.*$":"#Missing# GB","\.0(?= U)":""," U0$":" #StorageBytes#"," U1$":" KB"," U2$":" MB"," U3$":" GB"," U4$":" TB"
UpdateDivider=30
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallCaption]
; "available of 995 GB", under the big number
Measure=String
String=#StorageSmallCaption#
Substitute="%2":"[MeasureSmallTotalText]"
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallLegend]
; "88% used"
Measure=String
String=#StorageUsed#
Substitute="%1":"[MeasureSmallPctText]"
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallTip]
; the card's tooltip: "118 GB available of 995 GB (88% used)."
Measure=String
String=#StorageCaption##StorageTipUsed#
Substitute="%1":"[MeasureSmallAvailText]","%2":"[MeasureSmallTotalText]","{used}":"[MeasureSmallPctText]"
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallGlyph]
; the header's drive: the startup disk's, or an external one's
Measure=String
String=#StorageSmallVolume#
RegExpSubstitute=1
Substitute="^.+$":"externaldrive.fill","^$":"internaldrive.fill"
UpdateDivider=-1
Disabled=(#StorageSlots# > 0)

[MeasureSmallState]
; 1 when the chosen volume is not connected: the card shows the Notice, whose link goes back to the startup disk. It
; leaves as soon as the volume is mounted again
Measure=Calc
Formula=MeasureSmallType = 1
UpdateDivider=10
Disabled=(#StorageSlots# > 0)
Group=Volumes
IfCondition=MeasureSmallState = 1
IfTrueAction=[!HideMeterGroup SmallVolume][!ShowMeterGroup Notice][!Redraw]
IfFalseAction=[!ShowMeterGroup SmallVolume][!HideMeterGroup Notice][!Redraw]

; ---------------------------------------------------------------- the Trash and the card's sentence
[MeasureTrashText]
; "12 items", "1 item", "1,248 items"
Measure=String
String=[MeasureTrash:0]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^1$":"#StorageTrashOneItem#","^(\d+)$":"\1 #StorageTrashItems#","(\d)(?=(\d{3})+(?!\d))":"\1#DigitGroup#"
UpdateDivider=10
Disabled=(#StorageShowsTrash# = 0)

[MeasureTrashTip]
; the Trash row's tooltip: "12 items."
Measure=String
String=#StorageTipTrashRow#
Substitute="{items}":"[MeasureTrashText]"
DynamicVariables=1
UpdateDivider=10
Disabled=(#StorageShowsTrash# = 0)

[MeasureTrashSentence]
; the Large's sentence ends with the Trash
Measure=String
String=#StorageTipTrash#
Substitute="{items}":"[MeasureTrashText]"
DynamicVariables=1
UpdateDivider=10
Disabled=(#StorageSlots# < 4)

[MeasureSentence]
; "Macintosh HD: 118 GB available of 995 GB (88% used). Backup: 1.1 TB available of 2 TB (45% used). 2 more volumes."
; Each size lists the parts it shows (StorageSentence)
Measure=String
String=#StorageSentence#
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# = 0)
Group=Volumes
