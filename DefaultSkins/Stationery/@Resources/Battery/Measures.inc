; Stationery · Battery — what both sizes show, worked out from the readings of Source-Live.inc (or Source-Demo.inc):
; the state, the ring's colour and angle, the time left, the profile's figures and the card's sentence. Original work,
; MIT licensed.

[Variables]
; the ring and the badge: BatteryColor, CriticalColor at 20 % or less while not charging (WarningColor in Low Power
; Mode, once Deskset can tell)
LevelRGB=#BatteryColor#
; the menu's first item: Battery settings, or Energy on a Mac without a battery (menu titles are read when it opens)
BatteryOpenTitle=#BatteryMenuOpen#
; the Health value's ink: 1 when macOS recommends service
HealthInk0=#TextColor#
HealthInk1=#CriticalTextColor#

; ---------------------------------------------------------------- state
[MeasureStatusKey]
; 0 no battery · 1 charging · 2 charging with an estimate · 3 on battery, time known · 4 on battery while macOS
; estimates · 5 fully charged · 6 charging paused · 7 Low Power Mode. Until Deskset reads macOS's time to full and Low
; Power Mode, 2 and 7 do not occur, and "fully charged" against "charging paused" is judged by the charge: on power,
; not charging, 100 % or not
Measure=Calc
Formula=(MeasureStatus = 0) ? 0 : ((MeasureStatus = 1) ? 1 : ((MeasureACLine = 0) ? ((MeasureLifetime > 0) ? 3 : 4) : ((MeasurePercent >= 100) ? 5 : 6)))
UpdateDivider=2
Group=State
OnChangeAction=[!UpdateMeasureGroup State][!UpdateMeterGroup Battery][!UpdateMeter MeterCard][!Redraw]
IfCondition=MeasureStatusKey = 0
IfTrueAction=[!HideMeterGroup Battery][!ShowMeterGroup Notice][!SetVariable BatteryOpenTitle "#BatteryMenuOpenEnergy#"][!Redraw]
IfFalseAction=[!ShowMeterGroup Battery][!HideMeterGroup Notice][!SetVariable BatteryOpenTitle "#BatteryMenuOpen#"][!Redraw]
; the badge: a bolt while charging, a plug while on power and not charging, none on battery
IfCondition2=MeasureStatus = 1
IfTrueAction2=[!ShowMeter MeterBadgeBolt][!Redraw]
IfFalseAction2=[!HideMeter MeterBadgeBolt][!Redraw]
IfCondition3=(MeasureACLine = 1) && (MeasureStatus > 1)
IfTrueAction3=[!ShowMeter MeterBadgePlug][!Redraw]
IfFalseAction3=[!HideMeter MeterBadgePlug][!Redraw]

[MeasureLevel]
; 0 BatteryColor · 1 CriticalColor (20 % or less and not charging) · 2 WarningColor (Low Power Mode)
Measure=Calc
Formula=((MeasureStatus <> 1) && (MeasurePercent <= 20)) ? 1 : 0
UpdateDivider=2
Group=State
IfCondition=MeasureLevel = 0
IfTrueAction=[!SetVariable LevelRGB "#BatteryColor#"][!UpdateMeterGroup Level][!Redraw]
IfCondition2=MeasureLevel = 1
IfTrueAction2=[!SetVariable LevelRGB "#CriticalColor#"][!UpdateMeterGroup Level][!Redraw]
IfCondition3=MeasureLevel = 2
IfTrueAction3=[!SetVariable LevelRGB "#WarningColor#"][!UpdateMeterGroup Level][!Redraw]

[MeasureRingAngle]
; 0 % still shows a dot, 100 % a closed ring
Measure=Calc
Formula=Clamp(MeasurePercent * 3.6, 0.6, 359.4)
UpdateDivider=2
Group=State

[MeasureRingLarge]
Measure=Calc
Formula=MeasureRingAngle > 180
UpdateDivider=2
Group=State

; ---------------------------------------------------------------- the time left
[MeasureDurSeconds]
; with macOS's time to full: (MeasureStatusKey = 2) ? MeasureToFull : Max(MeasureLifetime, 0)
Measure=Calc
Formula=Max(MeasureLifetime, 0)
UpdateDivider=10
Group=State

[MeasureDurH]
Measure=Calc
Formula=Floor(MeasureDurSeconds / 3600)
UpdateDivider=10
Group=State

[MeasureDurM]
Measure=Calc
Formula=Floor((MeasureDurSeconds % 3600) / 60)
UpdateDivider=10
Group=State

[MeasureDuration]
; "4 h 12 min", "38 min", "5 h": units, never colons
Measure=String
String=[MeasureDurH:0] #UnitHour# [MeasureDurM:0] #UnitMinute#
DynamicVariables=1
RegExpSubstitute=1
Substitute="^0 \S+ ":""," 0 \S+$":""
UpdateDivider=10
Group=State

; ---------------------------------------------------------------- system_profiler's figures
[MeasureProfileTimer]
; runs system_profiler at the first update and every 30 minutes
Measure=Calc
Formula=1
UpdateDivider=1800
OnUpdateAction=[!CommandMeasure MeasureProfile "Run"]

[MeasureHealthText]
; "92%" (System Settings' Maximum Capacity), "--" until system_profiler answers
Measure=String
String=[MeasureProfile]
DynamicVariables=1
UpdateDivider=-1
Group=Profile
RegExpSubstitute=1
Substitute="(?s)^.*maximum_capacity=(\d+%).*$":"\1","(?s)^(?!\d+%$).*$":"--"

[MeasureCyclesText]
; "312", with a thousands separator from 1,000
Measure=String
String=[MeasureProfile]
DynamicVariables=1
UpdateDivider=-1
Group=Profile
RegExpSubstitute=1
Substitute="(?s)^.*cycle_count=(\d+).*$":"\1","(?s)^(?!\d+$).*$":"--","(\d)(?=(\d{3})+(?!\d))":"\1#DigitGroup#"

[MeasureServiceKey]
; 1 when macOS says the battery needs service: system_profiler's battery_health is neither "Good" nor "Normal"
Measure=String
String=[MeasureProfile]
DynamicVariables=1
UpdateDivider=-1
Group=Profile
RegExpSubstitute=1
Substitute="(?s)^.*battery_health=(Good|Normal)\n.*$":"0","(?s)^.*battery_health=.*$":"1","(?s)^(?!0$|1$).*$":"0"

[MeasureAdapterText]
; the adapter's watts ("96"), "--" before the first run
Measure=String
String=[MeasureProfile]
DynamicVariables=1
UpdateDivider=-1
Group=Profile
RegExpSubstitute=1
Substitute="(?s)^.*charger_watts=(\d+).*$":"\1","(?s)^(?!\d+$).*$":"--"

[MeasureAdapterName]
; "96W USB-C Power Adapter" (or just "Power adapter" when system_profiler gives no name)
Measure=String
String=[MeasureProfile]
DynamicVariables=1
UpdateDivider=-1
Group=Profile
RegExpSubstitute=1
Substitute="(?s)^.*charger_name=([^\n]*).*$":"\1","(?s)^.*=.*$":"#BatteryPowerAdapter#"

; ---------------------------------------------------------------- the card's sentence
[MeasureHealthClause]
; "Health 92%, 312 cycles.", or nothing while system_profiler has not answered
Measure=String
String=#BatteryTipHealth#
DynamicVariables=1
UpdateDivider=10
Group=Profile
RegExpSubstitute=1
Substitute="^.*--.*$":""

[MeasureSentence]
; "73%, charging: 1 h 12 min until full. Health 92%, 312 cycles."; a Mac without a battery says only that
Measure=String
String=[MeasurePercent:0]%#BatteryTipJoin#[#BatteryTipState[&MeasureStatusKey:]] [MeasureHealthClause]
DynamicVariables=1
UpdateDivider=10
Group=Profile
RegExpSubstitute=1
Substitute="^\d+%#BatteryTipJoin#(#BatteryTipState0#).*$":"\1"," +$":""
