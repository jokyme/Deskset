; Stationery · Storage — the readings, from this Mac. Original work, MIT licensed.
; Source-Demo.inc has the same sections with the suite's sample values (StorageSource=Demo, for screenshots).
; Nothing here asks for a permission: FileView lists /Volumes, FreeDiskSpace reads each disk, RecycleManager counts
; the Trash's items (its size would need Full Disk Access, which the widget never asks for) and diskutil ejects.
;
; What updates when: the volume list every 10 s (FileView reads its folder only when asked) and at once after an
; eject; the disks every 30 s; the Trash every 10 s. After the list is read, its FinishAction updates the list's logic
; (VolumeList), then the volumes' paths (SlotPaths), then their space (Volumes), in that order.

; ---------------------------------------------------------------- the mounted volumes
[MeasureVolumes]
Measure=Plugin
Plugin=FileView
Path=/Volumes/
ShowDotDot=0
ShowFile=0
ShowHidden=0
ShowSystem=0
SortType=Name
Count=8
UpdateDivider=-1
FinishAction=#VolumesRead#

[MeasureVolumesTick]
; FileView reads its folder only at the first update and on "Update": ask every 10 s
Measure=Calc
Formula=1
UpdateDivider=10
OnUpdateAction=[!CommandMeasure MeasureVolumes "Update"]

[MeasureEntry1Name]
; the 1st name in /Volumes (names, not paths: Type=FolderPath would be the parent's folder)
Measure=Plugin
Plugin=FileView
Path=[MeasureVolumes]
Type=FileName
Index=1
DynamicVariables=1
UpdateDivider=-1
Group=VolumeList

[MeasureEntry2Name]
Measure=Plugin
Plugin=FileView
Path=[MeasureVolumes]
Type=FileName
Index=2
DynamicVariables=1
UpdateDivider=-1
Group=VolumeList

[MeasureEntry3Name]
Measure=Plugin
Plugin=FileView
Path=[MeasureVolumes]
Type=FileName
Index=3
DynamicVariables=1
UpdateDivider=-1
Group=VolumeList

[MeasureEntry4Name]
Measure=Plugin
Plugin=FileView
Path=[MeasureVolumes]
Type=FileName
Index=4
DynamicVariables=1
UpdateDivider=-1
Group=VolumeList

[MeasureEntry5Name]
Measure=Plugin
Plugin=FileView
Path=[MeasureVolumes]
Type=FileName
Index=5
DynamicVariables=1
UpdateDivider=-1
Group=VolumeList

[MeasureEntry6Name]
Measure=Plugin
Plugin=FileView
Path=[MeasureVolumes]
Type=FileName
Index=6
DynamicVariables=1
UpdateDivider=-1
Group=VolumeList

[MeasureEntry7Name]
Measure=Plugin
Plugin=FileView
Path=[MeasureVolumes]
Type=FileName
Index=7
DynamicVariables=1
UpdateDivider=-1
Group=VolumeList

[MeasureEntry8Name]
Measure=Plugin
Plugin=FileView
Path=[MeasureVolumes]
Type=FileName
Index=8
DynamicVariables=1
UpdateDivider=-1
Group=VolumeList

; ---------------------------------------------------------------- the startup disk (slot 1, every size)
[MeasureSlot1Avail]
; Finder's "available" space (space macOS can free included); -1 until the first reading arrives
Measure=FreeDiskSpace
Drive=/
MacAvailable=1
IgnoreRemovable=0
UpdateDivider=30
Group=Volumes

[MeasureSlot1Total]
Measure=FreeDiskSpace
Drive=/
Total=1
IgnoreRemovable=0
UpdateDivider=30
Group=Volumes

[MeasureSlot1Label]
; "Macintosh HD"; the list leaves out /Volumes' link to it by this name
Measure=FreeDiskSpace
Drive=/
Label=1
IgnoreRemovable=0
UpdateDivider=30
Group=Volumes

; ---------------------------------------------------------------- the other volumes (slots 2–4: Medium and Large)
; A slot reads the kept entry its index (Volumes.inc) points to. IgnoreRemovable=0: disk images and USB disks count
; as removable, and would read 0 without it.

[MeasureSlot2Path]
; "/Volumes/Backup/" → "/Volumes/Backup"
Measure=Plugin
Plugin=FileView
Path=[MeasureVolumes]
Type=FilePath
Index=[MeasureSlot2Index:]
RegExpSubstitute=1
Substitute="(.)/$":"\1"
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# < 2)
Group=SlotPaths

[MeasureSlot2Avail]
Measure=FreeDiskSpace
Drive=[MeasureSlot2Path]
MacAvailable=1
IgnoreRemovable=0
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 2)
Group=Volumes

[MeasureSlot2Total]
Measure=FreeDiskSpace
Drive=[MeasureSlot2Path]
Total=1
IgnoreRemovable=0
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 2)
Group=Volumes

[MeasureSlot2Label]
Measure=FreeDiskSpace
Drive=[MeasureSlot2Path]
Label=1
IgnoreRemovable=0
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 2)
Group=Volumes

[MeasureEject2]
; the disk with all its volumes, as Finder's eject button does; a network share can only be unmounted. The path is
; escaped for the shell (PathShell), and read again when the button is clicked (it updates this measure first)
Measure=Plugin
Plugin=RunCommand
Parameter=/usr/sbin/diskutil eject "[MeasureSlot2PathShell]" >/dev/null 2>&1 || /usr/sbin/diskutil unmount "[MeasureSlot2PathShell]" >/dev/null 2>&1 || echo EJECT_FAILED
DynamicVariables=1
State=Hide
Timeout=30000
UpdateDivider=-1
Disabled=(#StorageSlots# < 2)
FinishAction=[!UpdateMeasure MeasureEject2Result][!CommandMeasure MeasureVolumes "Update"]

[MeasureSlot3Path]
; "/Volumes/Backup/" → "/Volumes/Backup"
Measure=Plugin
Plugin=FileView
Path=[MeasureVolumes]
Type=FilePath
Index=[MeasureSlot3Index:]
RegExpSubstitute=1
Substitute="(.)/$":"\1"
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# < 3)
Group=SlotPaths

[MeasureSlot3Avail]
Measure=FreeDiskSpace
Drive=[MeasureSlot3Path]
MacAvailable=1
IgnoreRemovable=0
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 3)
Group=Volumes

[MeasureSlot3Total]
Measure=FreeDiskSpace
Drive=[MeasureSlot3Path]
Total=1
IgnoreRemovable=0
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 3)
Group=Volumes

[MeasureSlot3Label]
Measure=FreeDiskSpace
Drive=[MeasureSlot3Path]
Label=1
IgnoreRemovable=0
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 3)
Group=Volumes

[MeasureEject3]
; the disk with all its volumes, as Finder's eject button does; a network share can only be unmounted. The path is
; escaped for the shell (PathShell), and read again when the button is clicked (it updates this measure first)
Measure=Plugin
Plugin=RunCommand
Parameter=/usr/sbin/diskutil eject "[MeasureSlot3PathShell]" >/dev/null 2>&1 || /usr/sbin/diskutil unmount "[MeasureSlot3PathShell]" >/dev/null 2>&1 || echo EJECT_FAILED
DynamicVariables=1
State=Hide
Timeout=30000
UpdateDivider=-1
Disabled=(#StorageSlots# < 3)
FinishAction=[!UpdateMeasure MeasureEject3Result][!CommandMeasure MeasureVolumes "Update"]

[MeasureSlot4Path]
; "/Volumes/Backup/" → "/Volumes/Backup"
Measure=Plugin
Plugin=FileView
Path=[MeasureVolumes]
Type=FilePath
Index=[MeasureSlot4Index:]
RegExpSubstitute=1
Substitute="(.)/$":"\1"
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# < 4)
Group=SlotPaths

[MeasureSlot4Avail]
Measure=FreeDiskSpace
Drive=[MeasureSlot4Path]
MacAvailable=1
IgnoreRemovable=0
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 4)
Group=Volumes

[MeasureSlot4Total]
Measure=FreeDiskSpace
Drive=[MeasureSlot4Path]
Total=1
IgnoreRemovable=0
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 4)
Group=Volumes

[MeasureSlot4Label]
Measure=FreeDiskSpace
Drive=[MeasureSlot4Path]
Label=1
IgnoreRemovable=0
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# < 4)
Group=Volumes

[MeasureEject4]
; the disk with all its volumes, as Finder's eject button does; a network share can only be unmounted. The path is
; escaped for the shell (PathShell), and read again when the button is clicked (it updates this measure first)
Measure=Plugin
Plugin=RunCommand
Parameter=/usr/sbin/diskutil eject "[MeasureSlot4PathShell]" >/dev/null 2>&1 || /usr/sbin/diskutil unmount "[MeasureSlot4PathShell]" >/dev/null 2>&1 || echo EJECT_FAILED
DynamicVariables=1
State=Hide
Timeout=30000
UpdateDivider=-1
Disabled=(#StorageSlots# < 4)
FinishAction=[!UpdateMeasure MeasureEject4Result][!CommandMeasure MeasureVolumes "Update"]

; ---------------------------------------------------------------- the Trash (Medium and Large)
[MeasureTrash]
; the number of items: counting needs no permission
Measure=Plugin
Plugin=RecycleManager
RecycleType=Count
UpdateDivider=10
Disabled=(#StorageShowsTrash# = 0)
OnChangeAction=[!UpdateMeterGroup Trash][!Redraw]

; ---------------------------------------------------------------- the Small's volume
[MeasureSmallPath]
; "/" for the startup disk, "/Volumes/<name>" for another volume. The name is the user's, so it goes in String=,
; which is taken literally. It comes before the measures that read it, so they find the volume on the first update
; (after them, the first update read an empty Drive and showed "Not connected" for a second)
Measure=String
String=#StorageSmallVolume#
RegExpSubstitute=1
Substitute="^(.+)$":"/Volumes/\1","^$":"/"
UpdateDivider=-1
Disabled=(#StorageSlots# > 0)

[MeasureSmallAvail]
Measure=FreeDiskSpace
Drive=[MeasureSmallPath]
MacAvailable=1
IgnoreRemovable=0
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallTotal]
Measure=FreeDiskSpace
Drive=[MeasureSmallPath]
Total=1
IgnoreRemovable=0
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallLabel]
Measure=FreeDiskSpace
Drive=[MeasureSmallPath]
Label=1
IgnoreRemovable=0
DynamicVariables=1
UpdateDivider=30
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallType]
; 1 "Removed": the chosen volume is not connected
Measure=FreeDiskSpace
Drive=[MeasureSmallPath]
Type=1
IgnoreRemovable=0
DynamicVariables=1
UpdateDivider=10
Disabled=(#StorageSlots# > 0)
Group=Volumes

[MeasureSmallNextEntry]
; the menu's next volume (Volumes.inc works out which)
Measure=Plugin
Plugin=FileView
Path=[MeasureVolumes]
Type=FileName
Index=[MeasureSmallNextIndex:]
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# > 0)
Group=SlotPaths

[MeasureSmallNextLabel]
Measure=FreeDiskSpace
Drive=[MeasureSmallNextPath]
Label=1
IgnoreRemovable=0
DynamicVariables=1
UpdateDivider=-1
Disabled=(#StorageSlots# > 0)
Group=Volumes
