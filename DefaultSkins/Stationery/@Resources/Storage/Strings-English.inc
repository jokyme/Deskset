; Stationery · Storage — the widget's words in English. Original work, MIT licensed.
; Strings-Chinese.inc has the same keys. A value with a space at either end is quoted, or the INI reader would trim it.
; %1 and %2 are filled in by the widget (the space available, the disk's size); menu titles are Title Case.

[Variables]
; ---------------------------------------------------------------- menu
StorageMenuOpen=Open Storage Settings
StorageMenuEmptyTrash=Empty Trash…
; the Small's volume item, followed by the volume's name
StorageMenuVolume="Volume: "

; ---------------------------------------------------------------- the card
StorageTitle=Storage
; a volume's line (%1 available, %2 its size), and the Small's line under its big number
StorageCaption=%1 available of %2
StorageSmallCaption=available of %2
; "88% used"
StorageUsed=%1 used
; more volumes than the card shows: "+2 more"
StorageMore=+%1 more
StorageBytes=bytes
StorageTrash=Trash
StorageTrashItems=items
StorageTrashOneItem=1 item
StorageTrashEmpty=Empty
; the eject button's tooltip is StorageEjectBefore + the volume's name + StorageEjectAfter
StorageEjectBefore="Eject "
StorageEjectAfter=
StorageEjectFailed=Couldn’t eject: in use
; the Large with fewer than three disks
StorageEmptyHint=Disks you connect appear here
; the Small's volume, when it is not connected: its name, this line, and a link back to the startup disk (%1)
StorageNotConnected=Not connected
StorageShow=Show %1

; ---------------------------------------------------------------- tooltips (the card's is also its accessibility text)
; a volume: "118 GB available of 995 GB (88% used)."; the card puts the volume's name and StorageTipNameSep first
StorageTipUsed=" ({used} used)."
StorageTipNameSep=": "
; between two volumes in the card's sentence
StorageTipJoin=" "
StorageTipMore1=" 1 more volume."
StorageTipMoreN=" {n} more volumes."
StorageTipTrash=" Trash: {items}."
StorageTipTrashRow={items}.
StorageTipNotConnected=Not connected. Connect it, or choose another volume in the menu.
