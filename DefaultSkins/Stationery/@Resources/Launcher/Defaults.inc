; Stationery · Launcher — its items' defaults and the state the skin keeps. Original work, MIT licensed.
;
; Both sizes include this file before Stationery.inc (Deskset's settings folder), where the user's items are kept, so
; those win. An item is Launch<k> (k = 1…8; the Small shows 1–4): an app, folder or file (a path, ~ for the home
; folder; a symbolic link or Finder alias shows its original's icon), a link (any scheme:), shortcut:<name> (a shortcut
; from the Shortcuts app) or trash. LaunchLabel<k> renames it (empty: its own name); LaunchSymbol<k> and LaunchColor<k>
; give a link or shortcut tile its SF Symbol and one of the colours of Tiles.inc.
;
; The defaults are things the Dock does not do: Screenshot, Documents, Downloads, AirDrop; Lock Screen and Do Not
; Disturb (shortcuts), Shortcuts, and the Trash.

[Variables]
Launch1=/System/Applications/Utilities/Screenshot.app
Launch2=~/Documents
Launch3=~/Downloads
Launch4=/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app
Launch5=shortcut:Lock Screen
Launch6=shortcut:Do Not Disturb
Launch7=/System/Applications/Shortcuts.app
Launch8=trash
LaunchLabel1=
LaunchSymbol1=
LaunchColor1=
LaunchLabel2=
LaunchSymbol2=
LaunchColor2=
LaunchLabel3=
LaunchSymbol3=
LaunchColor3=
LaunchLabel4=
LaunchSymbol4=
LaunchColor4=
LaunchLabel5=
LaunchSymbol5=lock.fill
LaunchColor5=Gray
LaunchLabel6=
LaunchSymbol6=moon.fill
LaunchColor6=Indigo
LaunchLabel7=
LaunchSymbol7=
LaunchColor7=
LaunchLabel8=
LaunchSymbol8=
LaunchColor8=
; per cell, what the skin sets (every variable a formula reads has a default): the kind, the tooltip's state,
; the listing's progress, missing, the folder and name FileView lists, the tile colour, the pad, hover, a drop
Launch1Kind=0
Launch1State=Empty
Launch1Listed=0
Launch1Missing=0
Launch1Dir=/
Launch1Base=*
LaunchColorEff1=Blue
Cell1PadColor=0,0,0,1
Cell1Hover=0
Cell1Drop=0
Launch2Kind=0
Launch2State=Empty
Launch2Listed=0
Launch2Missing=0
Launch2Dir=/
Launch2Base=*
LaunchColorEff2=Blue
Cell2PadColor=0,0,0,1
Cell2Hover=0
Cell2Drop=0
Launch3Kind=0
Launch3State=Empty
Launch3Listed=0
Launch3Missing=0
Launch3Dir=/
Launch3Base=*
LaunchColorEff3=Blue
Cell3PadColor=0,0,0,1
Cell3Hover=0
Cell3Drop=0
Launch4Kind=0
Launch4State=Empty
Launch4Listed=0
Launch4Missing=0
Launch4Dir=/
Launch4Base=*
LaunchColorEff4=Blue
Cell4PadColor=0,0,0,1
Cell4Hover=0
Cell4Drop=0
Launch5Kind=0
Launch5State=Empty
Launch5Listed=0
Launch5Missing=0
Launch5Dir=/
Launch5Base=*
LaunchColorEff5=Blue
Cell5PadColor=0,0,0,1
Cell5Hover=0
Cell5Drop=0
Launch6Kind=0
Launch6State=Empty
Launch6Listed=0
Launch6Missing=0
Launch6Dir=/
Launch6Base=*
LaunchColorEff6=Blue
Cell6PadColor=0,0,0,1
Cell6Hover=0
Cell6Drop=0
Launch7Kind=0
Launch7State=Empty
Launch7Listed=0
Launch7Missing=0
Launch7Dir=/
Launch7Base=*
LaunchColorEff7=Blue
Cell7PadColor=0,0,0,1
Cell7Hover=0
Cell7Drop=0
Launch8Kind=0
Launch8State=Empty
Launch8Listed=0
Launch8Missing=0
Launch8Dir=/
Launch8Base=*
LaunchColorEff8=Blue
Cell8PadColor=0,0,0,1
Cell8Hover=0
Cell8Drop=0
; the dispatcher's trip (the action, the cell and its kind), the cell being edited, a dropped item
Fired=0
FiredAct=0
FiredCell=0
FiredKind=0
EditCell=0
DropItem=
; the Trash: macOS's own icons, empty and full
TrashEmptyIcon=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/TrashIcon.icns
TrashFullIcon=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FullTrashIcon.icns
TrashIcon=#TrashEmptyIcon#
LaunchTipTrash=
; the shortcuts that can come with the widget as files (@Resources/Launcher/Shortcuts/<name>.shortcut): the first
; click on one that is not in Shortcuts yet offers to add it
LaunchBundledShortcuts=Lock Screen|Do Not Disturb
; a tile's symbol and colour by kind: shortcuts (4) square.2.layers.3d on Purple, links (and, for the hidden tiles
; of other kinds, harmlessly) globe on Blue
LaunchSymbolDefault0=globe
LaunchColorDefault0=Blue
LaunchSymbolDefault1=globe
LaunchColorDefault1=Blue
LaunchSymbolDefault2=globe
LaunchColorDefault2=Blue
LaunchSymbolDefault3=globe
LaunchColorDefault3=Blue
LaunchSymbolDefault4=square.2.layers.3d
LaunchColorDefault4=Purple
LaunchSymbolDefault5=globe
LaunchColorDefault5=Blue
LaunchSymbolDefault6=globe
LaunchColorDefault6=Blue
LaunchSymbolDefault7=globe
LaunchColorDefault7=Blue
LaunchSymbolDefault8=globe
LaunchColorDefault8=Blue
LaunchSymbolDefault9=globe
LaunchColorDefault9=Blue
LaunchShowLabelsNext0=1
LaunchShowLabelsNext1=0
