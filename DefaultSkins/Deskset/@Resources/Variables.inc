; Deskset example skins — shared settings. Original work, MIT licensed.
;
; Every skin in this folder includes this file (and Styles.inc), so a change here restyles all of them.
; Refresh the skins after editing (menu bar icon → Refresh All).

[Variables]
; ---------------------------------------------------------------- theme
; Dark or Light. Each skin's right-click menu can switch it too (it rewrites this line).
Theme=Dark
@IncludeTheme=#@#Themes/#Theme#.inc

; ---------------------------------------------------------------- type
; "System Font" is the macOS interface typeface (San Francisco).
FontFace=System Font
; Language of day and month names: empty = English, Local = the system language, or a code such as de-DE.
Locale=
; Date formats (Time measure codes: %A weekday, %B month, %#d day without a leading zero, %Y year).
; For example %A, %#d %B %Y or %Y年%#m月%#d日.
DateFormat=%B %#d, %Y
MonthFormat=%B %Y

; ---------------------------------------------------------------- layout
PanelWidth=260
PanelRadius=16
; Inner margin; content is PanelWidth - 2 * Padding wide.
Padding=18
ContentWidth=(#PanelWidth# - 2 * #Padding#)
; Height of the rounded progress tracks.
TrackHeight=6

; ---------------------------------------------------------------- clock
; 24 or 12 (the Clock skin's right-click menu switches it).
ClockHours=24

; ---------------------------------------------------------------- calendar
; First day of the week: 0 = Sunday, 1 = Monday (the Calendar skin's right-click menu switches it).
WeekStart=0

; ---------------------------------------------------------------- hover
; The panel border brightens while the pointer is over a skin (see MouseOverAction in each skin).
PanelBorderNow=#PanelBorder#
HoverOn=[!SetVariable PanelBorderNow "#PanelBorderHover#"][!UpdateMeter MeterBackground][!Redraw]
HoverOff=[!SetVariable PanelBorderNow "#PanelBorder#"][!UpdateMeter MeterBackground][!Redraw]

; Right-click menu entry that switches the theme of every Deskset skin.
ThemeMenuAction=[!WriteKeyValue Variables Theme #ThemeNext# "#@#Variables.inc"][!RefreshGroup Deskset]
