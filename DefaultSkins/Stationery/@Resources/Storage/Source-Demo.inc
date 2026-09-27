; Stationery · Storage — the suite's sample readings (StorageSource=Demo, screenshots). Original work, MIT licensed.
; The same sections as Source-Live.inc. /Volumes holds Backup, Macintosh HD (the startup disk's own link, left out),
; Photos and Transfer; entry 0 is the startup disk. Macintosh HD: 118 GB available of 995 GB; Backup 1.1 TB of 2 TB;
; Photos 38.4 GB of 1 TB (96 % used); Transfer 49.2 GB of 64 GB. The Trash has 12 items.

[Variables]
DemoEntry0=
DemoEntry1=Backup
DemoEntry2=Macintosh HD
DemoEntry3=Photos
DemoEntry4=Transfer
DemoEntry5=
DemoEntry6=
DemoEntry7=
DemoEntry8=
DemoLabel0=Macintosh HD
DemoLabel1=Backup
DemoLabel2=Macintosh HD
DemoLabel3=Photos
DemoLabel4=Transfer
DemoLabel5=
DemoLabel6=
DemoLabel7=
DemoLabel8=
DemoAvail0=117520000000
DemoAvail1=1100200000000
DemoAvail2=117520000000
DemoAvail3=38400000000
DemoAvail4=49200000000
DemoAvail5=0
DemoAvail6=0
DemoAvail7=0
DemoAvail8=0
DemoTotal0=994662584320
DemoTotal1=2000398934016
DemoTotal2=994662584320
DemoTotal3=1000000000000
DemoTotal4=64000000000
DemoTotal5=0
DemoTotal6=0
DemoTotal7=0
DemoTotal8=0
DemoTrash=12
; the Small's volume: 4 connected, 1 not connected (FreeDiskSpace Type)
DemoSmallType=4
; what a click on an eject button would print (EJECT_FAILED: the volume is in use)
DemoEject=EJECT_FAILED

[MeasureVolumesTick]
Measure=Calc
Formula=1
UpdateDivider=-1

[MeasureEntry1Name]
Measure=String
String=#DemoEntry1#
UpdateDivider=-1
Group=VolumeList

[MeasureEntry2Name]
Measure=String
String=#DemoEntry2#
UpdateDivider=-1
Group=VolumeList

[MeasureEntry3Name]
Measure=String
String=#DemoEntry3#
UpdateDivider=-1
Group=VolumeList

[MeasureEntry4Name]
Measure=String
String=#DemoEntry4#
UpdateDivider=-1
Group=VolumeList

[MeasureEntry5Name]
Measure=String
String=#DemoEntry5#
UpdateDivider=-1
Group=VolumeList

[MeasureEntry6Name]
Measure=String
String=#DemoEntry6#
UpdateDivider=-1
Group=VolumeList

[MeasureEntry7Name]
Measure=String
String=#DemoEntry7#
UpdateDivider=-1
Group=VolumeList

[MeasureEntry8Name]
Measure=String
String=#DemoEntry8#
UpdateDivider=-1
Group=VolumeList

[MeasureSlot1Avail]
Measure=Calc
Formula=#DemoAvail0#
UpdateDivider=30
Group=Volumes

[MeasureSlot1Total]
Measure=Calc
Formula=#DemoTotal0#
UpdateDivider=30
Group=Volumes

[MeasureSlot1Label]
Measure=String
String=#DemoLabel0#
UpdateDivider=30
Group=Volumes

[MeasureVolumes]
; the list is there at once: run what FileView's FinishAction runs, after the startup disk's name is known (the list
; leaves out its link by that name)
Measure=Calc
Formula=1
UpdateDivider=-1
OnUpdateAction=#VolumesRead#

[MeasureSlot2Path]
Measure=String
String=/Volumes/[#DemoEntry[&MeasureSlot2Index:0]]
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# < 2)
Group=SlotPaths

[MeasureSlot2Avail]
Measure=Calc
Formula=[#DemoAvail[&MeasureSlot2Index:0]]
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 2)
Group=Volumes

[MeasureSlot2Total]
Measure=Calc
Formula=[#DemoTotal[&MeasureSlot2Index:0]]
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 2)
Group=Volumes

[MeasureSlot2Label]
Measure=String
String=[#DemoLabel[&MeasureSlot2Index:0]]
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 2)
Group=Volumes

[MeasureEject2]
Measure=Plugin
Plugin=RunCommand
Parameter=echo #DemoEject#
State=Hide
UpdateDivider=-1
Disabled=(#StorageSlots# < 2)
FinishAction=[!UpdateMeasure MeasureEject2Result]

[MeasureSlot3Path]
Measure=String
String=/Volumes/[#DemoEntry[&MeasureSlot3Index:0]]
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# < 3)
Group=SlotPaths

[MeasureSlot3Avail]
Measure=Calc
Formula=[#DemoAvail[&MeasureSlot3Index:0]]
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 3)
Group=Volumes

[MeasureSlot3Total]
Measure=Calc
Formula=[#DemoTotal[&MeasureSlot3Index:0]]
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 3)
Group=Volumes

[MeasureSlot3Label]
Measure=String
String=[#DemoLabel[&MeasureSlot3Index:0]]
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 3)
Group=Volumes

[MeasureEject3]
Measure=Plugin
Plugin=RunCommand
Parameter=echo #DemoEject#
State=Hide
UpdateDivider=-1
Disabled=(#StorageSlots# < 3)
FinishAction=[!UpdateMeasure MeasureEject3Result]

[MeasureSlot4Path]
Measure=String
String=/Volumes/[#DemoEntry[&MeasureSlot4Index:0]]
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# < 4)
Group=SlotPaths

[MeasureSlot4Avail]
Measure=Calc
Formula=[#DemoAvail[&MeasureSlot4Index:0]]
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 4)
Group=Volumes

[MeasureSlot4Total]
Measure=Calc
Formula=[#DemoTotal[&MeasureSlot4Index:0]]
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 4)
Group=Volumes

[MeasureSlot4Label]
Measure=String
String=[#DemoLabel[&MeasureSlot4Index:0]]
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 4)
Group=Volumes

[MeasureEject4]
Measure=Plugin
Plugin=RunCommand
Parameter=echo #DemoEject#
State=Hide
UpdateDivider=-1
Disabled=(#StorageSlots# < 4)
FinishAction=[!UpdateMeasure MeasureEject4Result]

[MeasureTrash]
Measure=Calc
Formula=#DemoTrash#
UpdateDivider=10
Disabled=(#StorageShowsTrash# = 0)
OnChangeAction=[!UpdateMeterGroup Trash][!Redraw]

[MeasureSmallAvail]
Measure=Calc
Formula=[#DemoAvail[&MeasureSmallIndex:0]]
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallTotal]
Measure=Calc
Formula=[#DemoTotal[&MeasureSmallIndex:0]]
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallLabel]
Measure=String
String=[#DemoLabel[&MeasureSmallIndex:0]]
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallType]
Measure=Calc
Formula=#DemoSmallType#
UpdateDivider=10
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallNextEntry]
Measure=String
String=[#DemoEntry[&MeasureSmallNextIndex:0]]
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# > 0)
Group=SlotPaths

[MeasureSmallNextLabel]
Measure=String
String=[#DemoLabel[&MeasureSmallNextIndex:0]]
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# > 0)
Group=Volumes
