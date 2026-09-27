; Stationery · Launcher — the measures of item 8. Original work, MIT licensed.
; The eight Item files are the same but for the number (an include takes no parameters). They split the item, tell
; its kind, list it with FileView for its Finder icon, and derive its label, tooltip, tile and shortcut.

[MeasureLaunch8Dir]
; "~/Downloads" → "~/"; "/System/Applications/Utilities/Screenshot.app/" → "/System/Applications/Utilities/"
Measure=String
String=#Launch8#
RegExpSubstitute=1
Substitute="^\s+|/+\s*$":"","^(.*/)[^/]*$":"\1"
UpdateDivider=-1
OnUpdateAction=[!SetVariable Launch8Dir "[MeasureLaunch8Dir]"]

[MeasureLaunch8Base]
; the last component; FileView cannot escape [ ] * ? or ;, so they become ?, which still matches them
Measure=String
String=#Launch8#
RegExpSubstitute=1
Substitute="^\s+|/+\s*$":"","^.*/":"","[\[\]*?;]":"?"
UpdateDivider=-1
OnUpdateAction=[!SetVariable Launch8Base "[MeasureLaunch8Base]"]

[MeasureLaunch8Kind]
; the kind: 0 empty, 1 a path, 2 a link, 3 the Trash, 4 a shortcut, 5 anything else (shown as missing). IfMatch1–6
; are exclusive; 7 and 8 refine the state set before them (they run in number order, so theirs wins): a shortcut that
; comes with the widget, a web link (its sentence names the browser)
Measure=String
String=#Launch8#
UpdateDivider=-1
IfMatch=^\s*$
IfMatchAction=[!SetVariable Launch8Kind 0][!SetVariable Launch8State Empty]
IfMatch2=(?i)^\s*trash\s*$
; the Trash's first count can arrive after this update: it is read again once it is in
IfMatchAction2=[!SetVariable Launch8Kind 3][!SetVariable Launch8State Trash][!EnableMeasure MeasureTrash][!UpdateMeasure MeasureTrash][!Delay 300][!UpdateMeasure MeasureTrash]
IfMatch3=(?i)^\s*shortcut:
IfMatchAction3=[!SetVariable Launch8Kind 4][!SetVariable Launch8State Shortcut]
IfMatch4=(?i)^\s*(?!shortcut:)[a-z][a-z0-9+.-]*:
IfMatchAction4=[!SetVariable Launch8Kind 2][!SetVariable Launch8State Link]
IfMatch5=^\s*[/~]
IfMatchAction5=[!SetVariable Launch8Kind 1][!SetVariable Launch8State Open][!EnableMeasure MeasureLaunch8Found][!EnableMeasure MeasureLaunch8Icon][!EnableMeasure MeasureLaunch8Parent][!UpdateMeasure MeasureLaunch8Parent]
IfMatch6=(?i)^\s*(?!trash\s*$)[^\s/~](?![a-z0-9+.-]*:)
IfMatchAction6=[!SetVariable Launch8Kind 5][!SetVariable Launch8State Missing][!SetVariable Launch8Missing 1]
IfMatch7=(?i)^\s*shortcut:\s*(?:#LaunchBundledShortcuts#)\s*$
IfMatchAction7=[!SetVariable Launch8State ShortcutNew]
IfMatch8=(?i)^\s*(?:https?|ftp)://
IfMatchAction8=[!SetVariable Launch8State Web]

[MeasureLaunch8Parent]
; FileView has no single-file mode: list the item's folder, filtered to the item's name. Apps and folders are folders;
; without ShowDotDot=0 ".." would be the first item
Measure=Plugin
Plugin=FileView
Path=#Launch8Dir#
WildcardSearch=#Launch8Base#
ShowFolder=1
ShowFile=1
ShowHidden=1
ShowDotDot=0
Count=1
DynamicVariables=1
UpdateDivider=-1
Disabled=1
FinishAction=[!SetVariable Launch8Listed 1][!UpdateMeasure MeasureLaunch8Found][!UpdateMeasure MeasureLaunch8Tip][!UpdateMeterGroup Cell8][!Redraw]

[MeasureLaunch8Found]
; 1 once listed and present (before its first listing the parent reads 0, which counts as found). Off until the item is
; a path, so its load-time update never touches another kind's state
Measure=Calc
Formula=(MeasureLaunch8Parent > 0) || (#Launch8Listed# = 0)
DynamicVariables=1
UpdateDivider=-1
Disabled=1
IfCondition=MeasureLaunch8Found = 0
IfTrueAction=[!SetVariable Launch8Missing 1][!SetVariable Launch8State Missing]
IfFalseAction=[!SetVariable Launch8Missing 0][!SetVariable Launch8State Open]

[MeasureLaunch8Icon]
; the Finder icon as a 256 px picture, drawn at 48 or 40 pt; FileView writes it on its own queue, and this measure sees
; the file within 2 s and draws it once
Measure=Plugin
Plugin=FileView
Path=[MeasureLaunch8Parent]
Type=Icon
Index=1
IconSize=ExtraLarge
IconPath=Icons/Launch8.png
UpdateDivider=2
Disabled=1
IfMatch=\.png$
IfMatchAction=[!UpdateMeter MeterCell8Icon][!Redraw]

[MeasureLaunch8Derived]
; the label an item gets when LaunchLabel8 is empty. The pairs apply in order to the running result, so the first
; one (a link of another scheme: "obsidian://…" → "obsidian") runs while the item is still as written. Then: the
; Trash · a shortcut's name · a web link's host · a mail address · System Settings links · a path's last part without
; ".app" · the names Finder shows for the default items
Measure=String
String=#Launch8#
RegExpSubstitute=1
Substitute="(?i)^\s*(?!(?:https?|ftp|mailto|shortcut|x-apple\.systempreferences):)([a-z][a-z0-9+.-]*):.*$":"\1","(?i)^\s*trash\s*$":"#LaunchNameTrash#","(?i)^\s*shortcut:\s*(.+?)\s*$":"\1","(?i)^\s*(?:https?|ftp)://(?:www\.)?([^/:?#]+).*$":"\1","(?i)^\s*mailto:([^?]+).*$":"\1","(?i)^\s*x-apple\.systempreferences:.*$":"#LaunchNameSystemSettings#","^\s*[/~](?:.*/)?([^/]+?)(?:\.app)?/*\s*$":"\1","^Screenshot$":"#LaunchNameScreenshot#","^Documents$":"#LaunchNameDocuments#","^Downloads$":"#LaunchNameDownloads#","^AirDrop$":"#LaunchNameAirDrop#","^Lock Screen$":"#LaunchNameLockScreen#","^Do Not Disturb$":"#LaunchNameDoNotDisturb#","^Shortcuts$":"#LaunchNameShortcuts#","^Desktop$":"#LaunchNameDesktop#","^Applications$":"#LaunchNameApplications#","^System Settings$":"#LaunchNameSystemSettings#"
UpdateDivider=-1

[MeasureLaunch8Label]
; the item's own label, else the derived one. Both sit in String=, which is taken as written, split at ␟ by fixed
; patterns, so quotes and backslashes in a name pass through
Measure=String
String=#LaunchLabel8#␟[MeasureLaunch8Derived]
RegExpSubstitute=1
Substitute="^\s*␟":"","␟.*$":""
DynamicVariables=1
UpdateDivider=-1

[MeasureLaunch8Tip]
; the sentence for the item's state, then its fields: %1 the label, %2 the Trash's count, %3 the item as written.
; Fixed patterns move each field into its place (captured in a lookahead), then the fields are cut off
Measure=String
String=[#LaunchTip[#Launch8State]]␟[MeasureLaunch8Label]␟[MeasureTrashText]␟#Launch8#
RegExpSubstitute=1
Substitute="%1(?=[^␟]*␟([^␟]*)␟)":"\1","%2(?=[^␟]*␟[^␟]*␟([^␟]*)␟)":"\1","%3(?=[^␟]*␟[^␟]*␟[^␟]*␟(.*)$)":"\1","␟.*$":""
DynamicVariables=1
UpdateDivider=-1
Group=Tips

[MeasureLaunch8Symbol]
; the tile's symbol: the item's own, or its kind's
Measure=String
String=#LaunchSymbol8#
RegExpSubstitute=1
Substitute="^\s*$":"[#LaunchSymbolDefault[#Launch8Kind]]"
DynamicVariables=1
UpdateDivider=-1

[MeasureLaunch8Color]
; the tile's colour: one of the seven of Tiles.inc; anything else, or nothing, is its kind's
Measure=String
String=#LaunchColor8#
RegExpSubstitute=1
Substitute="(?i)^(?!\s*(?:Blue|Indigo|Purple|Pink|Red|Brown|Gray)\s*$).*$":"[#LaunchColorDefault[#Launch8Kind]]","^\s+|\s+$":""
DynamicVariables=1
UpdateDivider=-1
OnUpdateAction=[!SetVariable LaunchColorEff8 "[MeasureLaunch8Color]"]

[MeasureLaunch8Shortcut]
; the shortcut's name for the shell, where it is single-quoted: ' becomes '\'' and everything else stays literal
Measure=String
String=#Launch8#
RegExpSubstitute=1
Substitute="(?i)^\s*shortcut:\s*":"","\s+$":"","'":"'\''"
UpdateDivider=-1

[MeasureLaunch8Run]
; runs the shortcut; one that comes with the widget and is not in Shortcuts yet is offered for adding (Shortcuts asks
; "Add Shortcut"); the output says which happened. State=Show: a refresh (every light/dark switch, every item edit)
; must not stop a shortcut the user started
Measure=Plugin
Plugin=RunCommand
Parameter=n='[MeasureLaunch8Shortcut]'; f="#@#Launcher/Shortcuts/$n.shortcut"; if /usr/bin/shortcuts list | /usr/bin/grep -Fxq -- "$n"; then /usr/bin/shortcuts run "$n" >/dev/null 2>&1 && echo DONE || echo FAILED; elif [ -f "$f" ]; then /usr/bin/open "$f"; echo IMPORTING; else echo MISSING; fi
DynamicVariables=1
State=Show
UpdateDivider=-1
; updated only by its FinishAction, so IfMatchMode=1 fires once per run
FinishAction=[!UpdateMeasure MeasureLaunch8Run]
IfMatchMode=1
IfMatch=^DONE
IfMatchAction=[!SetVariable Launch8State Shortcut][!SetVariable Launch8Missing 0][!UpdateMeasure MeasureLaunch8Tip][!UpdateMeterGroup Cell8][!Redraw]
IfMatch2=^IMPORTING
IfMatchAction2=[!SetVariable Launch8Missing 0][!UpdateMeterGroup Cell8][!Redraw]
IfMatch3=^MISSING
IfMatchAction3=[!SetVariable Launch8State NoShortcut][!SetVariable Launch8Missing 1][!UpdateMeasure MeasureLaunch8Tip][!UpdateMeterGroup Cell8][!Redraw]

[MeasureLaunch8Edit]
; "Edit in Shortcuts" (the tile's menu)
Measure=Plugin
Plugin=RunCommand
Parameter=/usr/bin/shortcuts view '[MeasureLaunch8Shortcut]'
DynamicVariables=1
State=Hide
UpdateDivider=-1
