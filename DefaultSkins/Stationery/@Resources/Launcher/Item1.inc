; Stationery · Launcher — the measures of item 1. Original work, MIT licensed.
; The eight Item files are the same but for the number (an include takes no parameters). They split the item, tell
; its kind, list it with FileView for its Finder icon, and derive its label, tooltip, tile and shortcut.

[MeasureLaunch1Dir]
; "~/Downloads" → "~/"; "/System/Applications/Utilities/Screenshot.app/" → "/System/Applications/Utilities/"
Measure=String
String=#Launch1#
RegExpSubstitute=1
Substitute="^\s+|/+\s*$":"","^(.*/)[^/]*$":"\1"
UpdateDivider=-1
OnUpdateAction=[!SetVariable Launch1Dir "[MeasureLaunch1Dir]"]

[MeasureLaunch1Base]
; the last component; FileView cannot escape [ ] * ? or ;, so they become ?, which still matches them
Measure=String
String=#Launch1#
RegExpSubstitute=1
Substitute="^\s+|/+\s*$":"","^.*/":"","[\[\]*?;]":"?"
UpdateDivider=-1
OnUpdateAction=[!SetVariable Launch1Base "[MeasureLaunch1Base]"]

[MeasureLaunch1Kind]
; the kind: 0 empty, 1 a path, 2 a link, 3 the Trash, 4 a shortcut, 5 anything else (shown as missing). IfMatch1–6
; are exclusive; 7 and 8 refine the state set before them (they run in number order, so theirs wins): a shortcut that
; comes with the widget, a web link (its sentence names the browser)
Measure=String
String=#Launch1#
UpdateDivider=-1
IfMatch=^\s*$
IfMatchAction=[!SetVariable Launch1Kind 0][!SetVariable Launch1State Empty]
IfMatch2=(?i)^\s*trash\s*$
; the Trash's first count can arrive after this update: it is read again once it is in
IfMatchAction2=[!SetVariable Launch1Kind 3][!SetVariable Launch1State Trash][!EnableMeasure MeasureTrash][!UpdateMeasure MeasureTrash][!Delay 300][!UpdateMeasure MeasureTrash]
IfMatch3=(?i)^\s*shortcut:
IfMatchAction3=[!SetVariable Launch1Kind 4][!SetVariable Launch1State Shortcut]
IfMatch4=(?i)^\s*(?!shortcut:)[a-z][a-z0-9+.-]*:
IfMatchAction4=[!SetVariable Launch1Kind 2][!SetVariable Launch1State Link]
IfMatch5=^\s*[/~]
IfMatchAction5=[!SetVariable Launch1Kind 1][!SetVariable Launch1State Open][!EnableMeasure MeasureLaunch1Found][!EnableMeasure MeasureLaunch1Icon][!EnableMeasure MeasureLaunch1Parent][!UpdateMeasure MeasureLaunch1Parent]
IfMatch6=(?i)^\s*(?!trash\s*$)[^\s/~](?![a-z0-9+.-]*:)
IfMatchAction6=[!SetVariable Launch1Kind 5][!SetVariable Launch1State Missing][!SetVariable Launch1Missing 1]
IfMatch7=(?i)^\s*shortcut:\s*(?:#LaunchBundledShortcuts#)\s*$
IfMatchAction7=[!SetVariable Launch1State ShortcutNew]
IfMatch8=(?i)^\s*(?:https?|ftp)://
IfMatchAction8=[!SetVariable Launch1State Web]

[MeasureLaunch1Parent]
; FileView has no single-file mode: list the item's folder, filtered to the item's name. Apps and folders are folders;
; without ShowDotDot=0 ".." would be the first item
Measure=Plugin
Plugin=FileView
Path=#Launch1Dir#
WildcardSearch=#Launch1Base#
ShowFolder=1
ShowFile=1
ShowHidden=1
ShowDotDot=0
Count=1
DynamicVariables=1
UpdateDivider=-1
Disabled=1
FinishAction=[!SetVariable Launch1Listed 1][!UpdateMeasure MeasureLaunch1Found][!UpdateMeasure MeasureLaunch1Tip][!UpdateMeterGroup Cell1][!Redraw]

[MeasureLaunch1Found]
; 1 once listed and present (before its first listing the parent reads 0, which counts as found). Off until the item is
; a path, so its load-time update never touches another kind's state
Measure=Calc
Formula=(MeasureLaunch1Parent > 0) || (#Launch1Listed# = 0)
DynamicVariables=1
UpdateDivider=-1
Disabled=1
IfCondition=MeasureLaunch1Found = 0
IfTrueAction=[!SetVariable Launch1Missing 1][!SetVariable Launch1State Missing]
IfFalseAction=[!SetVariable Launch1Missing 0][!SetVariable Launch1State Open]

[MeasureLaunch1Icon]
; the Finder icon as a 256 px picture, drawn at 48 or 40 pt; FileView writes it on its own queue, and this measure sees
; the file within 2 s and draws it once
Measure=Plugin
Plugin=FileView
Path=[MeasureLaunch1Parent]
Type=Icon
Index=1
IconSize=ExtraLarge
IconPath=Icons/Launch1.png
UpdateDivider=2
Disabled=1
IfMatch=\.png$
IfMatchAction=[!UpdateMeter MeterCell1Icon][!Redraw]

[MeasureLaunch1Derived]
; the label an item gets when LaunchLabel1 is empty. The pairs apply in order to the running result, so the first
; one (a link of another scheme: "obsidian://…" → "obsidian") runs while the item is still as written. Then: the
; Trash · a shortcut's name · a web link's host · a mail address · System Settings links · a path's last part without
; ".app" · the names Finder shows for the default items
Measure=String
String=#Launch1#
RegExpSubstitute=1
Substitute="(?i)^\s*(?!(?:https?|ftp|mailto|shortcut|x-apple\.systempreferences):)([a-z][a-z0-9+.-]*):.*$":"\1","(?i)^\s*trash\s*$":"#LaunchNameTrash#","(?i)^\s*shortcut:\s*(.+?)\s*$":"\1","(?i)^\s*(?:https?|ftp)://(?:www\.)?([^/:?#]+).*$":"\1","(?i)^\s*mailto:([^?]+).*$":"\1","(?i)^\s*x-apple\.systempreferences:.*$":"#LaunchNameSystemSettings#","^\s*[/~](?:.*/)?([^/]+?)(?:\.app)?/*\s*$":"\1","^Screenshot$":"#LaunchNameScreenshot#","^Documents$":"#LaunchNameDocuments#","^Downloads$":"#LaunchNameDownloads#","^AirDrop$":"#LaunchNameAirDrop#","^Lock Screen$":"#LaunchNameLockScreen#","^Do Not Disturb$":"#LaunchNameDoNotDisturb#","^Shortcuts$":"#LaunchNameShortcuts#","^Desktop$":"#LaunchNameDesktop#","^Applications$":"#LaunchNameApplications#","^System Settings$":"#LaunchNameSystemSettings#"
UpdateDivider=-1

[MeasureLaunch1Label]
; the item's own label, else the derived one. Both sit in String=, which is taken as written, split at ␟ by fixed
; patterns, so quotes and backslashes in a name pass through
Measure=String
String=#LaunchLabel1#␟[MeasureLaunch1Derived]
RegExpSubstitute=1
Substitute="^\s*␟":"","␟.*$":""
DynamicVariables=1
UpdateDivider=-1

[MeasureLaunch1Tip]
; the sentence for the item's state, then its fields: %1 the label, %2 the Trash's count, %3 the item as written.
; Fixed patterns move each field into its place (captured in a lookahead), then the fields are cut off
Measure=String
String=[#LaunchTip[#Launch1State]]␟[MeasureLaunch1Label]␟[MeasureTrashText]␟#Launch1#
RegExpSubstitute=1
Substitute="%1(?=[^␟]*␟([^␟]*)␟)":"\1","%2(?=[^␟]*␟[^␟]*␟([^␟]*)␟)":"\1","%3(?=[^␟]*␟[^␟]*␟[^␟]*␟(.*)$)":"\1","␟.*$":""
DynamicVariables=1
UpdateDivider=-1
Group=Tips

[MeasureLaunch1Symbol]
; the tile's symbol: the item's own, or its kind's
Measure=String
String=#LaunchSymbol1#
RegExpSubstitute=1
Substitute="^\s*$":"[#LaunchSymbolDefault[#Launch1Kind]]"
DynamicVariables=1
UpdateDivider=-1

[MeasureLaunch1Color]
; the tile's colour: one of the seven of Tiles.inc; anything else, or nothing, is its kind's
Measure=String
String=#LaunchColor1#
RegExpSubstitute=1
Substitute="(?i)^(?!\s*(?:Blue|Indigo|Purple|Pink|Red|Brown|Gray)\s*$).*$":"[#LaunchColorDefault[#Launch1Kind]]","^\s+|\s+$":""
DynamicVariables=1
UpdateDivider=-1
OnUpdateAction=[!SetVariable LaunchColorEff1 "[MeasureLaunch1Color]"]

[MeasureLaunch1Shortcut]
; the shortcut's name for the shell, where it is single-quoted: ' becomes '\'' and everything else stays literal
Measure=String
String=#Launch1#
RegExpSubstitute=1
Substitute="(?i)^\s*shortcut:\s*":"","\s+$":"","'":"'\''"
UpdateDivider=-1

[MeasureLaunch1Run]
; runs the shortcut; one that comes with the widget and is not in Shortcuts yet is offered for adding (Shortcuts asks
; "Add Shortcut"); the output says which happened. State=Show: a refresh (every light/dark switch, every item edit)
; must not stop a shortcut the user started
Measure=Plugin
Plugin=RunCommand
Parameter=n='[MeasureLaunch1Shortcut]'; f="#@#Launcher/Shortcuts/$n.shortcut"; if /usr/bin/shortcuts list | /usr/bin/grep -Fxq -- "$n"; then /usr/bin/shortcuts run "$n" >/dev/null 2>&1 && echo DONE || echo FAILED; elif [ -f "$f" ]; then /usr/bin/open "$f"; echo IMPORTING; else echo MISSING; fi
DynamicVariables=1
State=Show
UpdateDivider=-1
; updated only by its FinishAction, so IfMatchMode=1 fires once per run
FinishAction=[!UpdateMeasure MeasureLaunch1Run]
IfMatchMode=1
IfMatch=^DONE
IfMatchAction=[!SetVariable Launch1State Shortcut][!SetVariable Launch1Missing 0][!UpdateMeasure MeasureLaunch1Tip][!UpdateMeterGroup Cell1][!Redraw]
IfMatch2=^IMPORTING
IfMatchAction2=[!SetVariable Launch1Missing 0][!UpdateMeterGroup Cell1][!Redraw]
IfMatch3=^MISSING
IfMatchAction3=[!SetVariable Launch1State NoShortcut][!SetVariable Launch1Missing 1][!UpdateMeasure MeasureLaunch1Tip][!UpdateMeterGroup Cell1][!Redraw]

[MeasureLaunch1Edit]
; "Edit in Shortcuts" (the tile's menu)
Measure=Plugin
Plugin=RunCommand
Parameter=/usr/bin/shortcuts view '[MeasureLaunch1Shortcut]'
DynamicVariables=1
State=Hide
UpdateDivider=-1
