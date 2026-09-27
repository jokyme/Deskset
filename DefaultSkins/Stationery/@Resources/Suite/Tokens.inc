; Stationery — the suite's design tokens. Original work, MIT licensed.
;
; Every Stationery widget starts its [Variables] with
;     @Include=#@#Variables.inc
;     @Include2=#@#Suite/Tokens.inc
;     @Include3=#@#Suite/Styles.inc
; This file brings in the colours of the look (Suite/Looks/<Look>.inc) and the words of the language
; (Suite/Strings-<Language>.inc), so a widget never branches on either.
;
; Units are points, origin at the card's top left. A text's FontSize is its point size × 0.75 (Deskset draws
; FontSize × 96/72), and a String meter's baseline is at Y + Padding + ascent, the ascent being 0.9668 × the point size
; for SF Pro, SF Pro Rounded and SF Mono: Y = baseline − ascent (the Ascent… tokens below).

[Variables]
@IncludeLook=#@#Suite/Looks/#Look#.inc
@IncludeStrings=#@#Suite/Strings-#Language#.inc

; ---------------------------------------------------------------- sizes, radii, spacing
; Cards: Small 170 × 170, Medium 360 × 170, Large 360 × 360, 20 apart on the desktop (a grid pitch of 190). A card
; never changes size. Each widget sets CardW and CardH after its includes, and OpenAction, the card's click (it
; opens the widget's Mac app; the tools leave it empty).
CardW=170
CardH=170
OpenAction=
CardRadius=26
; a corner that sits in the card's corner at the 16 inset (26 − 16: artwork at the padding), at the 12 inset, and
; the corner of tiles and artwork elsewhere
InnerRadius=10
InnerRadiusCompact=14
TileRadius=8
; hover pads: rows (x 8 → W − 8) and tiles
RowPadRadius=8
TilePadRadius=14
; padding: the content box is x 16 → W − 16, y 16 → H − 16 (12 for dense or full-bleed rows)
Pad=16
PadCompact=12
Gap=20
; the top band is y 16 → 30, centre line 23; content starts at y 40
BandCenterY=23
ContentTop=40
; the leading slot: symbols centred on x 26 at their natural size, text at x 41. In a Medium's detail column
; (x 176 → 344) the slot moves along: centre 186, text 201
SlotCenterX=26
SlotTextX=41
DetailX=176
DetailSlotCenterX=186
DetailTextX=201
; row pitch: 18 for 11 pt rows, 26 for 13 pt rows
RowPitchS=18
RowPitchM=26
; the last text baseline (Smalls and Mediums, Larges) and the hero baselines (46 pt, 40 pt)
LastBaseline=151
LastBaselineLarge=341
HeroBaseline=94
HeroBaselineXL=83

; ---------------------------------------------------------------- type
FontText=System
FontNumber=System Rounded
FontMono=System Mono
FontSerif=System Serif
; ascent and cap height by point size: Y = baseline − ascent; a symbol centred on a line of text has its centre at
; baseline − cap height ÷ 2. The ascents are rounded up, never down: Deskset snaps a line's baseline down to the next
; device pixel, so a baseline a hair below a whole point (94.0027 from 44.47) would land half a point low.
Ascent9=8.702
Ascent10=9.668
Ascent11=10.635
Ascent13=12.569
Ascent15=14.502
Ascent22=21.27
Ascent40=38.672
Ascent46=44.473
CapHeight9=6.34
CapHeight11=7.75
CapHeight13=9.16
CapHeight15=10.57
; a run of digits with its separators, an optional sign (U+2212 or +) and an optional % or °: the word styles set
; these in SF Pro Rounded with tabular figures. No square brackets, so section variables never read it.
DigitRun=(?:−|\+)?\d(?:\d|:|\.|,)*(?:%|°)?
; a unit: letters after a space, or at the start ("上午 7:10"), with one optional "/…" ("MB/s", "h", "min", "AM").
; The group is the unit; the spaced form takes the space with it, so the gap is set at the unit's size
UnitRun=(?:^|\s)(\p{L}+(?:/\p{L}+)?)
UnitRunSpaced=((?:^|\s)\p{L}+(?:/\p{L}+)?)
; a missing or loading value, at the value's own size, in TertiaryTextColor (never 0 for data that is missing)
Missing=--

; ---------------------------------------------------------------- times and dates
; 24 h has a leading zero, as macOS; in 12 h AM/PM goes outside the big digits (CaptionTime12 in the Strings keeps
; it, in the language's order). The three date formats are in the Strings too.
TimeFormat24=%H:%M
TimeFormat12=%#I:%M

; ---------------------------------------------------------------- "Auto" settings
; "Auto" is the Mac's own setting, which Deskset gives every skin as a built-in variable: #MACCLOCKHOURS# (12 or 24,
; from Date & Time), #MACFIRSTWEEKDAY# (0 Sunday … 6 Saturday) and #MACTEMPERATUREUNIT# (C or F), both from Language &
; Region. They are right from the first load. When one of those settings changes, Deskset runs the widget's
; MacOnAppearanceChangeAction, whose default ([!Refresh]) loads it again with the new value, so keep that default.
; Hours, FirstWeekday and TempScale below are therefore fixed while a widget runs: read them anywhere, in options and
; in [Variables] values alike, with no DynamicVariables for their sake.
; ClockHours=Auto|24|12 → Hours, 24 or 12
ClockHoursAuto=#MACCLOCKHOURS#
ClockHours24=24
ClockHours12=12
Hours=[#ClockHours[#ClockHours]]
; WeekStart=Auto|0…6 → FirstWeekday, 0 Sunday … 6 Saturday
WeekStartAuto=#MACFIRSTWEEKDAY#
WeekStart0=0
WeekStart1=1
WeekStart2=2
WeekStart3=3
WeekStart4=4
WeekStart5=5
WeekStart6=6
FirstWeekday=[#WeekStart[#WeekStart]]
; TempUnit=Auto|C|F → TempScale, C or F (for MacSensors' Scale; MacWeather takes TemperatureUnit=#TempUnit# as it is)
TempUnitAuto=#MACTEMPERATUREUNIT#
TempUnitC=C
TempUnitF=F
TempScale=[#TempUnit[#TempUnit]]

; ---------------------------------------------------------------- the card's veil
; Each look has a glass veil (Veil0) and a solid one (Veil1, "Cards: Solid"). A look chosen by hand (Light, Dark or
; Clear rather than Auto) cannot set the glass's own light or dark yet, so it takes the solid veil, whose tone does
; not depend on the glass. Clear has one veil for both.
CardsSolidAuto=#UseSolidCards#
CardsSolidLight=1
CardsSolidDark=1
CardsSolidClear=1
Veil=[#Veil[#CardsSolid[#Look]]]

; ---------------------------------------------------------------- the moon
; SF Symbols by the phase's eighth (0 new … 4 full … 7 waning crescent: Round(phase × 8) % 8); add #MoonSuffix#,
; which the look sets, so the lit part is always the lighter tone. The names are in the Strings (Moon0…Moon7).
MoonSymbol0=moonphase.new.moon
MoonSymbol1=moonphase.waxing.crescent
MoonSymbol2=moonphase.first.quarter
MoonSymbol3=moonphase.waxing.gibbous
MoonSymbol4=moonphase.full.moon
MoonSymbol5=moonphase.waning.gibbous
MoonSymbol6=moonphase.last.quarter
MoonSymbol7=moonphase.waning.crescent

; ---------------------------------------------------------------- the suite's menu items
; A widget lists its own items first, then a separator and these two (titles from the Strings, current value shown):
;     ContextTitleN=#MenuLookTitle#       ContextActionN=#MenuLookAction#
;     ContextTitleN+1=#MenuCardsTitle#    ContextActionN+1=#MenuCardsAction#
; Pieces without a card show the Ink item instead. The Clock, Week Starts and Temperature items go in the widgets that
; show them. Every item writes Variables.inc and refreshes the whole suite (Group=Stationery).
MenuLookTitle=[#MenuLook[#Look]]
; until Deskset can set a widget's look itself, the item opens System Settings › Appearance, which Auto follows
MenuLookAction=["x-apple.systempreferences:com.apple.Appearance-Settings.extension"]
MenuCardsTitle=[#MenuCards[#UseSolidCards]]
MenuCardsAction=[!WriteKeyValue Variables UseSolidCards "(1 - #UseSolidCards#)" "#@#Variables.inc"][!RefreshGroup Stationery]
MenuInkTitle=[#MenuInk[#Ink]]
MenuInkAction=[!WriteKeyValue Variables Ink [#InkNext[#Ink]] "#@#Variables.inc"][!RefreshGroup Stationery]
InkNextAuto=White
InkNextWhite=Dark
InkNextDark=Auto
MenuClockTitle=[#MenuClock[#ClockHours]]
MenuClockAction=[!WriteKeyValue Variables ClockHours [#ClockHoursNext[#ClockHours]] "#@#Variables.inc"][!RefreshGroup Stationery]
ClockHoursNextAuto=24
ClockHoursNext24=12
ClockHoursNext12=Auto
MenuWeekStartTitle=[#MenuWeekStart[#WeekStart]]
MenuWeekStartAction=[!WriteKeyValue Variables WeekStart [#WeekStartNext[#WeekStart]] "#@#Variables.inc"][!RefreshGroup Stationery]
WeekStartNextAuto=0
WeekStartNext0=1
WeekStartNext1=6
WeekStartNext2=Auto
WeekStartNext3=Auto
WeekStartNext4=Auto
WeekStartNext5=Auto
WeekStartNext6=Auto
MenuTempTitle=[#MenuTemp[#TempUnit]]
MenuTempAction=[!WriteKeyValue Variables TempUnit [#TempUnitNext[#TempUnit]] "#@#Variables.inc"][!RefreshGroup Stationery]
TempUnitNextAuto=C
TempUnitNextC=F
TempUnitNextF=Auto

; ---------------------------------------------------------------- files
; what a widget's user types (to-do items, cities, launcher items, the countdown's event, the timer's state) lives
; outside the skins, so updates never touch it; a widget that keeps such text adds @Include4=#StationeryFile#
StationeryFile=#SETTINGSPATH#Stationery.inc

; ---------------------------------------------------------------- screenshots
; Pins every Time measure of the suite to one moment: a Windows timestamp (seconds since 1 January 1601, wall clock).
; Empty: the real clock. Only for screenshots; never set in a released file.
TestNow=
